const std = @import("std");
const Io = std.Io;
const encode = @import("encode.zig");
const jsonx = @import("jsonx.zig");
const models = @import("models.zig");
const protocol = @import("protocol.zig");

pub const Bridge = struct {
    io: Io,
    gpa: std.mem.Allocator,
    client: std.http.Client,
    base_url: []const u8,
    bearer: []const u8,
    api_key: []const u8,
    workspace: []const u8,
    child: ?std.process.Child = null,

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

        const clipped = clip(parsed.flatten_text, models.sdkPromptMaxCharsForModel(parsed.upstream_model));
        const send_json = try std.fmt.allocPrint(arena,
            "{{\"agentId\":{f},\"message\":{{\"text\":{f}}},\"options\":{{\"enableDeltas\":true}}}}",
            .{ std.json.fmt(agent_id, .{}), std.json.fmt(clipped, .{}) },
        );
        const text = try self.sendCollect(arena, send_json);
        return .{
            .message_id = message_id,
            .session_id = session_id,
            .model = parsed.model,
            .created_at = now,
            .text = text,
            .input_tokens = protocol.estimateInputTokens(parsed),
            .output_tokens = @max(@as(u32, 1), @as(u32, @intCast(@min(text.len, 16_000) / 4))),
        };
    }

    fn sendCollect(self: *Bridge, arena: std.mem.Allocator, send_json: []const u8) ![]u8 {
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
        var transfer: [4096]u8 = undefined;
        const reader = response.reader(&transfer);
        var text = std.ArrayList(u8).empty;
        while (true) {
            const payload = readFrame(reader, arena) catch |err| switch (err) {
                error.EndStream => break,
                else => return err,
            } orelse break;
            appendDelta(&text, arena, payload) catch {};
        }
        return text.toOwnedSlice(arena);
    }
};

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

fn appendDelta(text: *std.ArrayList(u8), arena: std.mem.Allocator, payload: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, payload, .{}) catch return;
    if (jsonx.get(parsed.value, "interactionUpdate")) |upd| {
        const typ = jsonx.getStr(upd, "type") orelse return;
        if (std.mem.eql(u8, typ, "text-delta") or std.mem.eql(u8, typ, "text_delta")) {
            if (jsonx.get(upd, "update")) |u| {
                const piece = jsonx.getStr(u, "text") orelse jsonx.getStr(u, "delta") orelse return;
                try text.appendSlice(arena, piece);
            }
        }
        return;
    }
    if (jsonx.get(parsed.value, "sdkMessage")) |msg| {
        const typ = jsonx.getStr(msg, "type") orelse return;
        if (std.mem.eql(u8, typ, "assistant") or std.mem.eql(u8, typ, "thinking")) {
            if (jsonx.get(msg, "message")) |m| {
                const piece = jsonx.getStr(m, "text") orelse jsonx.collectText(m, arena) catch return;
                if (piece.len > 0 and text.items.len == 0) try text.appendSlice(arena, piece);
            }
        }
        return;
    }
    if (jsonx.get(parsed.value, "result")) |res| {
        if (jsonx.get(res, "result")) |inner| {
            if (jsonx.getStr(inner, "result")) |final_text| {
                if (text.items.len == 0) try text.appendSlice(arena, final_text);
            }
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
    return candidate;
}

pub fn spawn(io: Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, bin: []const u8, workspace: []const u8, api_key: []const u8) !Bridge {
    std.Io.Dir.cwd().createDirPath(io, workspace) catch {};
    const child = try std.process.spawn(io, .{
        .argv = &.{ bin, "--workspace", workspace },
        .stderr = .pipe,
        .stdout = .ignore,
    });
    const stderr = child.stderr orelse return error.BridgeNoStderr;
    var buf: [8192]u8 = undefined;
    var reader = stderr.readerStreaming(io, &buf);
    const ready = try waitReady(&reader.interface, gpa);
    const token = try readToken(io, gpa, ready.auth_token_file);
    const bridge = Bridge{
        .io = io,
        .gpa = gpa,
        .client = .{ .allocator = gpa, .io = io },
        .base_url = ready.url,
        .bearer = token,
        .api_key = api_key,
        .workspace = workspace,
        .child = child,
    };
    _ = env;
    return bridge;
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
