const std = @import("std");
const Io = std.Io;
const encode = @import("encode.zig");
const jsonx = @import("jsonx.zig");
const models = @import("models.zig");
const protocol = @import("protocol.zig");

pub const Sink = struct {
    ctx: *anyopaque = undefined,
    on_text: ?*const fn (*anyopaque, []const u8) void = null,
    on_thinking: ?*const fn (*anyopaque, []const u8) void = null,
};

pub const Bridge = struct {
    io: Io,
    gpa: std.mem.Allocator,
    client: std.http.Client,
    base_url: []const u8,
    bearer: []const u8,
    api_key: []const u8,
    workspace: []const u8,
    child: ?std.process.Child = null,
    agents: std.StringHashMap([]const u8) = undefined,
    mu: Io.Mutex = .init,

    pub fn unary(self: *Bridge, arena: std.mem.Allocator, path: []const u8, payload: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base_url, path });
        const authz = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.bearer});
        var aw: std.Io.Writer.Allocating = .init(arena);
        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .headers = .{
                .authorization = .{ .override = authz },
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = &.{
                .{ .name = "Connect-Protocol-Version", .value = "1" },
            },
            .response_writer = &aw.writer,
            .keep_alive = true,
            .redirect_behavior = .unhandled,
        });
        const body = try aw.toOwnedSlice();
        if (@intFromEnum(result.status) >= 400) {
            std.log.warn("bridge {s} status={d} body={s}", .{ path, @intFromEnum(result.status), body });
            return error.BridgeRpcFailed;
        }
        return body;
    }

    pub fn ping(self: *Bridge, arena: std.mem.Allocator) !void {
        const body = try self.unary(arena, "/sdk.v1.SdkBridgeControlService/Ping", "{}");
        if (std.mem.indexOf(u8, body, "pong") == null) return error.BridgePingFailed;
    }

    pub fn listModels(self: *Bridge, arena: std.mem.Allocator) ![]const []const u8 {
        const payload = try std.fmt.allocPrint(arena, "{{\"options\":{{\"apiKey\":{f}}}}}", .{std.json.fmt(self.api_key, .{})});
        const body = try self.unary(arena, "/sdk.v1.SdkCursorService/ListModels", payload);
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
        var ids = std.ArrayList([]const u8).empty;
        if (jsonx.asArray(jsonx.get(parsed.value, "items") orelse .null)) |items| {
            for (items) |item| {
                if (jsonx.getStr(item, "id")) |id| try ids.append(arena, id);
            }
        }
        return ids.toOwnedSlice(arena);
    }

    pub fn run(self: *Bridge, arena: std.mem.Allocator, parsed: protocol.Parsed, session_id: []const u8, message_id: []const u8, now: i64) !encode.Turn {
        return self.runStreaming(arena, parsed, session_id, message_id, now, .{});
    }

    pub fn runStreaming(
        self: *Bridge,
        arena: std.mem.Allocator,
        parsed: protocol.Parsed,
        session_id: []const u8,
        message_id: []const u8,
        now: i64,
        sink: Sink,
    ) !encode.Turn {
        const agent_id = try self.ensureAgent(arena, parsed, session_id);
        const prompt = if (parsed.continuation.len > 0)
            try formatToolResultsFn(arena, parsed)
        else
            clip(parsed.flatten_text, models.sdkPromptMaxCharsForModel(parsed.upstream_model));
        const send_json = try std.fmt.allocPrint(arena,
            "{{\"agentId\":{f},\"message\":{{\"text\":{f}}},\"options\":{{\"enableDeltas\":true}}}}",
            .{ std.json.fmt(agent_id, .{}), std.json.fmt(prompt, .{}) },
        );
        var collected = Collected{};
        try self.sendCollect(arena, send_json, sink, &collected);
        var tools = try arena.alloc(encode.ToolCall, collected.tools.items.len);
        for (collected.tools.items, 0..) |t, i| tools[i] = t;
        const stop: []const u8 = if (collected.tools.items.len > 0) "tool_use" else "end_turn";
        return .{
            .message_id = message_id,
            .session_id = session_id,
            .model = parsed.model,
            .created_at = now,
            .text = try arena.dupe(u8, collected.text.items),
            .thinking = try arena.dupe(u8, collected.thinking.items),
            .tools = tools,
            .input_tokens = protocol.estimateInputTokens(parsed),
            .output_tokens = @max(@as(u32, 1), @as(u32, @intCast(@min(collected.text.items.len, 16_000) / 4))),
            .stop_reason = stop,
        };
    }

    fn ensureAgent(self: *Bridge, arena: std.mem.Allocator, parsed: protocol.Parsed, session_id: []const u8) ![]const u8 {
        self.mu.lockUncancelable(self.io);
        if (self.agents.get(session_id)) |id| {
            self.mu.unlock(self.io);
            return id;
        }
        self.mu.unlock(self.io);
        const create = try std.fmt.allocPrint(arena,
            "{{\"options\":{{\"model\":{{\"id\":{f}{s}}},\"apiKey\":{f},\"local\":{{\"cwd\":[{f}]{s}}},\"disallowedTools\":[\"shell\",\"read\",\"edit\",\"task\",\"webSearch\",\"webFetch\"]}}}}",
            .{
                std.json.fmt(parsed.upstream_model, .{}),
                try effortJson(arena, parsed.effort),
                std.json.fmt(self.api_key, .{}),
                std.json.fmt(self.workspace, .{}),
                try customToolsJson(arena, parsed.tools),
            },
        );
        const created = try self.unary(arena, "/sdk.v1.SdkAgentService/CreateAgent", create);
        const created_json = try std.json.parseFromSlice(std.json.Value, arena, created, .{});
        const agent_id = jsonx.getStr(created_json.value, "agentId") orelse return error.BridgeCreateFailed;
        const durable = try self.gpa.dupe(u8, agent_id);
        const sid = try self.gpa.dupe(u8, session_id);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.agents.put(sid, durable);
        return durable;
    }

    fn sendCollect(self: *Bridge, arena: std.mem.Allocator, send_json: []const u8, sink: Sink, collected: *Collected) !void {
        const framed = try frame(arena, send_json);
        const url = try std.fmt.allocPrint(arena, "{s}/sdk.v1.SdkAgentService/Send", .{self.base_url});
        const uri = try std.Uri.parse(url);
        const authz = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.bearer});
        var req = try self.client.request(.POST, uri, .{
            .headers = .{
                .authorization = .{ .override = authz },
                .content_type = .{ .override = "application/connect+json" },
            },
            .extra_headers = &.{
                .{ .name = "Connect-Protocol-Version", .value = "1" },
            },
            .keep_alive = true,
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();
        try req.sendBodyComplete(framed);
        var redirect: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect);
        if (@intFromEnum(response.head.status) >= 400) return error.BridgeRpcFailed;
        var transfer: [4096]u8 = undefined;
        const reader = response.reader(&transfer);
        while (true) {
            const payload = readFrame(reader, arena) catch |err| switch (err) {
                error.EndStream => break,
                else => return err,
            } orelse break;
            applyEnvelope(arena, payload, sink, collected) catch {};
        }
    }

    fn formatToolResults(_: *Bridge, arena: std.mem.Allocator, parsed: protocol.Parsed) ![]u8 {
        return formatToolResultsFn(arena, parsed);
    }
};

const Collected = struct {
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(encode.ToolCall) = .empty,
};

fn formatToolResultsFn(arena: std.mem.Allocator, parsed: protocol.Parsed) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (parsed.continuation) |c| {
        try out.appendSlice(arena, "tool_result ");
        try out.appendSlice(arena, c.call_id);
        try out.appendSlice(arena, ": ");
        try out.appendSlice(arena, c.output);
        try out.append(arena, '\n');
    }
    if (parsed.last_user_text.len > 0) {
        try out.appendSlice(arena, parsed.last_user_text);
    }
    return out.toOwnedSlice(arena);
}

fn effortJson(arena: std.mem.Allocator, effort: ?[]const u8) ![]const u8 {
    const e = effort orelse return "";
    return std.fmt.allocPrint(arena, ",\"params\":[{{\"id\":\"effort\",\"value\":{f}}}]", .{std.json.fmt(e, .{})});
}

fn customToolsJson(arena: std.mem.Allocator, tools: []const protocol.Tool) ![]const u8 {
    if (tools.len == 0) return "";
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(arena, ",\"customTools\":{");
    for (tools, 0..) |tool, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, try std.fmt.allocPrint(arena,
            "{f}:{{\"description\":{f},\"inputSchema\":{s}}}",
            .{ std.json.fmt(tool.sdk_name, .{}), std.json.fmt(tool.description, .{}), tool.schema_json },
        ));
    }
    try out.append(arena, '}');
    return out.toOwnedSlice(arena);
}

fn frame(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 5 + json.len);
    out[0] = 0;
    std.mem.writeInt(u32, out[1..5], @intCast(json.len), .big);
    @memcpy(out[5..], json);
    return out;
}

fn readFrame(reader: *std.Io.Reader, arena: std.mem.Allocator) !?[]u8 {
    var header: [5]u8 = undefined;
    reader.readSliceAll(&header) catch return null;
    const flags = header[0];
    const len = std.mem.readInt(u32, header[1..5], .big);
    const payload = try arena.alloc(u8, len);
    try reader.readSliceAll(payload);
    if (flags & 0x02 != 0) {
        if (std.mem.indexOf(u8, payload, "\"error\"") != null) return error.BridgeStreamError;
        return error.EndStream;
    }
    return payload;
}

fn applyEnvelope(arena: std.mem.Allocator, payload: []const u8, sink: Sink, collected: *Collected) !void {
    if (payload.len == 0 or payload[0] != '{') return;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, payload, .{}) catch return;
    if (jsonx.get(parsed.value, "interactionUpdate")) |upd| {
        const typ = jsonx.getStr(upd, "type") orelse return;
        const piece = blk: {
            const u = jsonx.get(upd, "update") orelse break :blk "";
            break :blk jsonx.getStr(u, "text") orelse jsonx.getStr(u, "delta") orelse "";
        };
        if (piece.len == 0) return;
        if (std.mem.eql(u8, typ, "text-delta") or std.mem.eql(u8, typ, "text_delta")) {
            try collected.text.appendSlice(arena, piece);
            if (sink.on_text) |fn_ptr| fn_ptr(sink.ctx, piece);
        } else if (std.mem.indexOf(u8, typ, "thinking") != null) {
            try collected.thinking.appendSlice(arena, piece);
            if (sink.on_thinking) |fn_ptr| fn_ptr(sink.ctx, piece);
        }
        return;
    }
    if (jsonx.get(parsed.value, "sdkMessage")) |msg| {
        const typ = jsonx.getStr(msg, "type") orelse return;
        const m = jsonx.get(msg, "message") orelse return;
        if (std.mem.eql(u8, typ, "assistant")) {
            const piece = jsonx.getStr(m, "text") orelse jsonx.collectText(m, arena) catch "";
            if (piece.len > 0 and collected.text.items.len == 0) {
                try collected.text.appendSlice(arena, piece);
                if (sink.on_text) |fn_ptr| fn_ptr(sink.ctx, piece);
            }
        } else if (std.mem.eql(u8, typ, "thinking")) {
            const piece = jsonx.getStr(m, "text") orelse jsonx.getStr(m, "thinking") orelse jsonx.collectText(m, arena) catch "";
            if (piece.len > 0 and collected.thinking.items.len == 0) {
                try collected.thinking.appendSlice(arena, piece);
                if (sink.on_thinking) |fn_ptr| fn_ptr(sink.ctx, piece);
            }
        } else if (std.mem.eql(u8, typ, "tool_call")) {
            const call_id = jsonx.getStr(m, "callId") orelse jsonx.getStr(m, "id") orelse jsonx.getStr(m, "toolCallId") orelse return;
            const name = jsonx.getStr(m, "name") orelse jsonx.getStr(m, "toolName") orelse "";
            const args = jsonx.getStr(m, "arguments") orelse jsonx.getStr(m, "input") orelse "{}";
            try collected.tools.append(arena, .{ .id = call_id, .name = name, .arguments = args });
        }
        return;
    }
    if (jsonx.get(parsed.value, "result")) |res| {
        const inner = jsonx.get(res, "result") orelse res;
        const final_text = jsonx.getStr(inner, "text") orelse jsonx.getStr(inner, "result") orelse "";
        if (final_text.len > 0 and collected.text.items.len == 0) {
            try collected.text.appendSlice(arena, final_text);
            if (sink.on_text) |fn_ptr| fn_ptr(sink.ctx, final_text);
        }
    }
}

fn clip(text: []const u8, max: u32) []const u8 {
    if (text.len <= max) return text;
    return text[text.len - max ..];
}

pub fn findBridgeBinary(env: *const std.process.Environ.Map, allocator: std.mem.Allocator) ?[]const u8 {
    if (env.get("CURSOR_SDK_BRIDGE")) |p| {
        if (p.len > 0) return p;
    }
    const home = env.get("HOME") orelse return null;
    const candidate = std.fs.path.join(allocator, &.{ home, ".cursor-sdk2api-zig", "bridge", "v1.0.30", "bin", "cursor-sdk-bridge" }) catch return null;
    if (candidate.len == 0) return null;
    return candidate;
}

pub fn spawn(
    io: Io,
    gpa: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    bin: []const u8,
    workspace: []const u8,
    api_key: []const u8,
    tool_callback_url: []const u8,
    tool_callback_token: []const u8,
) !Bridge {
    std.Io.Dir.cwd().createDirPath(io, workspace) catch {};
    const child = try std.process.spawn(io, .{
        .argv = &.{
            bin,
            "--workspace",
            workspace,
            "--tool-callback-url",
            tool_callback_url,
            "--tool-callback-auth-token",
            tool_callback_token,
        },
        .stderr = .pipe,
        .stdout = .ignore,
    });
    const stderr = child.stderr orelse return error.BridgeNoStderr;
    var buf: [8192]u8 = undefined;
    var reader = stderr.readerStreaming(io, &buf);
    const ready = try waitReady(&reader.interface, gpa);
    const token = try readToken(io, gpa, ready.auth_token_file);
    const br = Bridge{
        .io = io,
        .gpa = gpa,
        .client = .{ .allocator = gpa, .io = io },
        .base_url = ready.url,
        .bearer = token,
        .api_key = api_key,
        .workspace = workspace,
        .child = child,
        .agents = std.StringHashMap([]const u8).init(gpa),
    };
    _ = env;
    return br;
}

const Ready = struct {
    url: []u8,
    auth_token_file: []u8,
};

fn waitReady(reader: *std.Io.Reader, gpa: std.mem.Allocator) !Ready {
    const prefix = "cursor-sdk-bridge ready ";
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch return error.BridgeReadyTimeout;
        if (std.mem.startsWith(u8, line, prefix)) {
            const json = std.mem.trim(u8, line[prefix.len..], " \r\n");
            var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
            const url = try gpa.dupe(u8, jsonx.getStr(parsed.value, "url") orelse return error.BridgeReadyInvalid);
            const file = try gpa.dupe(u8, jsonx.getStr(parsed.value, "authTokenFile") orelse return error.BridgeReadyInvalid);
            parsed.deinit();
            return .{ .url = url, .auth_token_file = file };
        }
    }
}

fn readToken(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [128]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    const data = try reader.interface.allocRemaining(gpa, .limited(4096));
    return try gpa.dupe(u8, std.mem.trim(u8, data, " \t\r\n"));
}

test "connect frame round-trip length" {
    const framed = try frame(std.testing.allocator, "{\"a\":1}");
    defer std.testing.allocator.free(framed);
    try std.testing.expectEqual(@as(u8, 0), framed[0]);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, framed[1..5], .big));
}
