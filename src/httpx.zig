const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const compact_mod = @import("compact.zig");
const config_mod = @import("config.zig");
const encode = @import("encode.zig");
const engine = @import("engine.zig");
const errors = @import("errors.zig");
const grok_summary = @import("grok_summary.zig");
const ids = @import("ids.zig");
const jsonx = @import("jsonx.zig");
const models = @import("models.zig");
const protocol = @import("protocol.zig");

pub const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    config: config_mod.Config,
    compact: compact_mod.Store,
    instance_id: []const u8,
    sdk_version: []const u8,
    use_fake: bool,
    bridge: ?*BridgeClient = null,
};

pub const BridgeClient = struct {
    unary: *const fn (*BridgeClient, std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
    run: *const fn (*BridgeClient, std.mem.Allocator, protocol.Parsed, []const u8, []const u8, i64) anyerror!encode.Turn,
    impl: *anyopaque,
};

pub fn handle(app: *App, request: *std.http.Server.Request) void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    serve(app, request, arena) catch |err| {
        std.log.err("request failed: {t}", .{err});
        const body = encode.publicErrorJson(arena, errors.upstreamError("internal error"), "req_unknown") catch return;
        request.respond(body, .{
            .status = .internal_server_error,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }) catch {};
    };
}

fn serve(app: *App, request: *std.http.Server.Request, arena: std.mem.Allocator) !void {
    var headers_buf: [48]std.http.Header = undefined;
    const headers = copyHeaders(request, arena, &headers_buf) catch return error.OutOfMemory;
    const path = pathOnly(request.head.target);
    const method = request.head.method;
    const request_id = headers.get("x-request-id") orelse try ids.requestId(app.io, arena);
    const session_hint = headers.get("x-cursor-session-id");
    const user_agent = headers.get("user-agent");

    if (method == .GET and (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/"))) {
        const body = try encode.healthJson(arena, config_mod.version, app.instance_id, app.sdk_version, true);
        return sendJson(request, .ok, body, request_id, null);
    }

    const body_bytes = try readBody(request, arena, app.config.max_body_bytes);

    if (method == .GET and (std.mem.eql(u8, path, "/v1/models") or std.mem.eql(u8, path, "/v1/models-v2"))) {
        const authorized = auth.authorizeClient(headers, "127.0.0.1", .{
            .auth_mode = app.config.auth_mode,
            .gateway_access_key = app.config.gateway_access_key,
            .managed_cursor_key = app.config.managed_cursor_key,
        });
        if (authorized == .err and app.config.auth_mode != .managed) {
            return sendErr(request, authorized.err, request_id, path, false);
        }
        const json = try modelsJson(app, arena, user_agent);
        return sendJson(request, .ok, json, request_id, null);
    }

    const authorized = auth.authorizeClient(headers, "127.0.0.1", .{
        .auth_mode = app.config.auth_mode,
        .gateway_access_key = app.config.gateway_access_key,
        .managed_cursor_key = app.config.managed_cursor_key,
    });
    const cred = switch (authorized) {
        .ok => |a| a,
        .err => |e| return sendErr(request, e, request_id, path, false),
    };
    _ = cred;

    if (method == .GET and std.mem.eql(u8, path, "/v1/account")) {
        const json = try accountJson(app, arena);
        return sendJson(request, .ok, json, request_id, null);
    }

    if (method != .POST) {
        return sendErr(request, errors.notFound("No route"), request_id, path, false);
    }

    if (body_bytes.len == 0) {
        return sendErr(request, errors.invalidRequest("JSON body is required"), request_id, path, isOpenAi(path));
    }
    const parsed_json = std.json.parseFromSliceLeaky(std.json.Value, arena, body_bytes, .{}) catch {
        return sendErr(request, errors.invalidRequest("Request body must be valid JSON"), request_id, path, isOpenAi(path));
    };

    if (std.mem.eql(u8, path, "/v1/messages/count_tokens")) {
        const parsed = protocol.parseMessages(arena, parsed_json);
        const p = switch (parsed) {
            .ok => |v| v,
            .err => |e| return sendErr(request, e, request_id, path, false),
        };
        const n = protocol.estimateInputTokens(p);
        const json = try std.fmt.allocPrint(arena, "{{\"input_tokens\":{d}}}", .{n});
        return sendJson(request, .ok, json, request_id, null);
    }

    const parsed = if (std.mem.eql(u8, path, "/v1/messages"))
        protocol.parseMessages(arena, parsed_json)
    else if (std.mem.eql(u8, path, "/v1/chat/completions"))
        protocol.parseChat(arena, parsed_json)
    else if (std.mem.eql(u8, path, "/v1/responses") or std.mem.eql(u8, path, "/v1/responses/compact"))
        protocol.parseResponses(arena, parsed_json)
    else
        return sendErr(request, errors.notFound("No route"), request_id, path, false);
    const p = switch (parsed) {
        .ok => |v| v,
        .err => |e| return sendErr(request, e, request_id, path, isOpenAi(path)),
    };

    if (std.mem.eql(u8, path, "/v1/responses/compact") or p.compaction_trigger) {
        const compact_id = try ids.compactId(app.io, arena);
        const minted = app.compact.mint(arena, compact_id, p.model) catch {
            return sendErr(request, errors.upstreamError("compact failed"), request_id, path, true);
        };
        const sid = session_hint orelse try ids.sessionId(app.io, arena);
        const json = try encode.encodeCompaction(arena, minted.compact_id, minted.token, p.model, unixNow(app.io), sid, protocol.estimateInputTokens(p));
        if (!p.stream) return sendJson(request, .ok, json, request_id, sid);
        return writeCompactSse(request, arena, json, request_id, sid);
    }

    if (grok_summary.isGrokCompactSummaryRequest(p)) {
        const sid = session_hint orelse try ids.sessionId(app.io, arena);
        const mid = try ids.messageId(app.io, arena);
        const summary = try grok_summary.buildGrokCompactSummary(arena, p);
        const turn = encode.Turn{
            .message_id = mid,
            .session_id = sid,
            .model = p.model,
            .created_at = unixNow(app.io),
            .text = summary,
            .input_tokens = protocol.estimateInputTokens(p),
            .output_tokens = 16,
        };
        return writeTurn(request, arena, p, turn, request_id);
    }

    const sid = session_hint orelse try ids.sessionId(app.io, arena);
    const mid = try ids.messageId(app.io, arena);
    const now = unixNow(app.io);
    const turn = if (app.use_fake or app.bridge == null)
        try engine.Fake.run(arena, p, sid, mid, now)
    else
        try app.bridge.?.run(app.bridge.?, arena, p, sid, mid, now);

    return writeTurn(request, arena, p, turn, request_id);
}

fn writeTurn(request: *std.http.Server.Request, arena: std.mem.Allocator, parsed: protocol.Parsed, turn: encode.Turn, request_id: []const u8) !void {
    if (!parsed.stream) {
        const json = switch (parsed.kind) {
            .responses => try encode.encodeResponse(arena, turn),
            .messages => try encode.encodeMessage(arena, turn),
            .chat => try encode.encodeChat(arena, turn),
        };
        return sendJson(request, .ok, json, request_id, turn.session_id);
    }
    var buf: [2048]u8 = undefined;
    var body = try request.respondStreaming(&buf, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache, no-transform" },
                .{ .name = "x-accel-buffering", .value = "no" },
                .{ .name = "x-request-id", .value = request_id },
                .{ .name = "x-cursor-session-id", .value = turn.session_id },
            },
        },
    });
    switch (parsed.kind) {
        .responses => try writeResponsesSse(&body, arena, turn),
        .messages => try writeMessagesSse(&body, arena, turn),
        .chat => try writeChatSse(&body, arena, turn, parsed.include_usage),
    }
    try body.end();
}

fn writeResponsesSse(body: *std.http.BodyWriter, arena: std.mem.Allocator, turn: encode.Turn) !void {
    const json = try encode.encodeResponse(arena, turn);
    var seq: u32 = 0;
    try writeSse(body, try encode.sseEvent(arena, "response.created", "{\"response\":{\"status\":\"in_progress\"}}", seq));
    seq += 1;
    try writeSse(body, try encode.sseEvent(arena, "response.in_progress", "{\"response\":{\"status\":\"in_progress\"}}", seq));
    seq += 1;
    if (turn.thinking.len > 0) {
        try writeSse(body, try encode.sseEvent(arena, "response.reasoning_summary_text.delta", try std.fmt.allocPrint(arena, "{{\"delta\":{f}}}", .{std.json.fmt(turn.thinking, .{})}), seq));
        seq += 1;
    }
    if (turn.text.len > 0) {
        try writeSse(body, try encode.sseEvent(arena, "response.output_text.delta", try std.fmt.allocPrint(arena, "{{\"delta\":{f}}}", .{std.json.fmt(turn.text, .{})}), seq));
        seq += 1;
    }
    try writeSse(body, try encode.sseEvent(arena, "response.completed", try std.fmt.allocPrint(arena, "{{\"response\":{s}}}", .{json}), seq));
}

fn writeMessagesSse(body: *std.http.BodyWriter, arena: std.mem.Allocator, turn: encode.Turn) !void {
    try writeSse(body, try encode.sseEvent(arena, "message_start", try std.fmt.allocPrint(arena,
        "{{\"type\":\"message_start\",\"message\":{{\"id\":{f},\"type\":\"message\",\"role\":\"assistant\",\"model\":{f},\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{{\"input_tokens\":0,\"output_tokens\":0}},\"cursor_session_id\":{f}}}}}",
        .{ std.json.fmt(turn.message_id, .{}), std.json.fmt(turn.model, .{}), std.json.fmt(turn.session_id, .{}) },
    ), 0));
    if (turn.thinking.len > 0) {
        try writeSse(body, "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n");
        try writeSse(body, try std.fmt.allocPrint(arena, "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"thinking_delta\",\"thinking\":{f}}}}}\n\n", .{std.json.fmt(turn.thinking, .{})}));
        try writeSse(body, "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n");
    }
    const idx: u8 = if (turn.thinking.len > 0) 1 else 0;
    try writeSse(body, try std.fmt.allocPrint(arena, "event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n", .{idx}));
    if (turn.text.len > 0) {
        try writeSse(body, try std.fmt.allocPrint(arena, "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"text_delta\",\"text\":{f}}}}}\n\n", .{ idx, std.json.fmt(turn.text, .{}) }));
    }
    try writeSse(body, try std.fmt.allocPrint(arena, "event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{idx}));
    for (turn.tools, 0..) |tool, i| {
        const tindex = idx + 1 + i;
        try writeSse(body, try std.fmt.allocPrint(arena, "event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":{f},\"name\":{f},\"input\":{{}}}}}}\n\n", .{ tindex, std.json.fmt(tool.id, .{}), std.json.fmt(tool.name, .{}) }));
        try writeSse(body, try std.fmt.allocPrint(arena, "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{f}}}}}\n\n", .{ tindex, std.json.fmt(tool.arguments, .{}) }));
        try writeSse(body, try std.fmt.allocPrint(arena, "event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{tindex}));
    }
    const stop: []const u8 = if (turn.tools.len > 0) "tool_use" else "end_turn";
    try writeSse(body, try std.fmt.allocPrint(arena, "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\",\"stop_sequence\":null}},\"usage\":{{\"output_tokens\":{d}}}}}\n\n", .{ stop, turn.output_tokens }));
    try writeSse(body, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n");
}

fn writeChatSse(body: *std.http.BodyWriter, arena: std.mem.Allocator, turn: encode.Turn, include_usage: bool) !void {
    const id = try ids.chatCompletionId(turn.message_id, arena);
    try writeSse(body, try encode.sseData(arena, try std.fmt.allocPrint(arena,
        "{{\"id\":{f},\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":{f},\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\"}},\"finish_reason\":null}}]}}",
        .{ std.json.fmt(id, .{}), turn.created_at, std.json.fmt(turn.model, .{}) },
    )));
    if (turn.thinking.len > 0) {
        try writeSse(body, try encode.sseData(arena, try std.fmt.allocPrint(arena,
            "{{\"id\":{f},\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":{f},\"choices\":[{{\"index\":0,\"delta\":{{\"reasoning_content\":{f}}},\"finish_reason\":null}}]}}",
            .{ std.json.fmt(id, .{}), turn.created_at, std.json.fmt(turn.model, .{}), std.json.fmt(turn.thinking, .{}) },
        )));
    }
    if (turn.text.len > 0) {
        try writeSse(body, try encode.sseData(arena, try std.fmt.allocPrint(arena,
            "{{\"id\":{f},\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":{f},\"choices\":[{{\"index\":0,\"delta\":{{\"content\":{f}}},\"finish_reason\":null}}]}}",
            .{ std.json.fmt(id, .{}), turn.created_at, std.json.fmt(turn.model, .{}), std.json.fmt(turn.text, .{}) },
        )));
    }
    const finish: []const u8 = if (turn.tools.len > 0) "tool_calls" else "stop";
    try writeSse(body, try encode.sseData(arena, try std.fmt.allocPrint(arena,
        "{{\"id\":{f},\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":{f},\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{s}\"}}]}}",
        .{ std.json.fmt(id, .{}), turn.created_at, std.json.fmt(turn.model, .{}), finish },
    )));
    if (include_usage) {
        try writeSse(body, try encode.sseData(arena, try std.fmt.allocPrint(arena,
            "{{\"id\":{f},\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":{f},\"choices\":[],\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}}}}",
            .{ std.json.fmt(id, .{}), turn.created_at, std.json.fmt(turn.model, .{}), turn.input_tokens, turn.output_tokens, turn.input_tokens + turn.output_tokens },
        )));
    }
    try writeSse(body, "data: [DONE]\n\n");
}

fn writeCompactSse(request: *std.http.Server.Request, arena: std.mem.Allocator, json: []const u8, request_id: []const u8, session_id: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var body = try request.respondStreaming(&buf, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
                .{ .name = "x-request-id", .value = request_id },
                .{ .name = "x-cursor-session-id", .value = session_id },
            },
        },
    });
    try writeSse(&body, try encode.sseEvent(arena, "response.created", "{\"response\":{\"status\":\"in_progress\"}}", 0));
    try writeSse(&body, try encode.sseEvent(arena, "response.completed", try std.fmt.allocPrint(arena, "{{\"response\":{s}}}", .{json}), 1));
    try body.end();
}

fn writeSse(body: *std.http.BodyWriter, bytes: []const u8) !void {
    try body.writer.writeAll(bytes);
    try body.flush();
}

fn modelsJson(app: *App, arena: std.mem.Allocator, user_agent: ?[]const u8) ![]u8 {
    _ = app;
    const ids_list = try engine.Fake.listModels(arena);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(arena, "{\"object\":\"list\",\"data\":[");
    var first = true;
    for (ids_list) |id| {
        const aliases = try models.catalogModelIdsForClient(arena, id, user_agent);
        for (aliases) |alias| {
            if (!first) try out.append(arena, ',');
            first = false;
            try out.appendSlice(arena, try std.fmt.allocPrint(arena,
                "{{\"id\":{f},\"object\":\"model\",\"display_name\":{f},\"context_tokens\":{d},\"compact_max_chars\":{d}}}",
                .{
                    std.json.fmt(alias, .{}),
                    std.json.fmt(id, .{}),
                    models.contextTokensForModel(alias),
                    models.sdkPromptMaxCharsForModel(alias),
                },
            ));
        }
    }
    try out.appendSlice(arena, "],\"status\":\"ok\",\"cache\":{\"stale\":false}}");
    return out.toOwnedSlice(arena);
}

fn accountJson(app: *App, arena: std.mem.Allocator) ![]u8 {
    _ = app;
    return arena.dupe(u8,
        "{\"status\":\"ok\",\"identity\":{\"api_key_name\":\"cursor-sdk2api-zig\"},\"runtime\":{\"default_profile\":\"sdk\",\"sand_selectable\":false,\"applies_to_new_sessions\":true},\"capabilities\":{\"identity\":true}}",
    );
}

fn sendJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8, request_id: []const u8, session_id: ?[]const u8) !void {
    if (session_id) |sid| {
        return request.respond(body, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json; charset=utf-8" },
                .{ .name = "x-request-id", .value = request_id },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-cursor-session-id", .value = sid },
            },
        });
    }
    return request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
            .{ .name = "x-request-id", .value = request_id },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

fn sendErr(request: *std.http.Server.Request, err: errors.Error, request_id: []const u8, path: []const u8, openai: bool) !void {
    _ = path;
    const json = if (openai)
        try encode.openaiError(std.heap.page_allocator, err, request_id)
    else
        try encode.publicErrorJson(std.heap.page_allocator, err, request_id);
    defer std.heap.page_allocator.free(json);
    const status: std.http.Status = @enumFromInt(err.http_status);
    try request.respond(json, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
            .{ .name = "x-request-id", .value = request_id },
        },
    });
}

fn isOpenAi(path: []const u8) bool {
    return std.mem.eql(u8, path, "/v1/chat/completions") or
        std.mem.eql(u8, path, "/v1/responses") or
        std.mem.eql(u8, path, "/v1/responses/compact");
}

fn unixNow(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, 1_000_000_000));
}

fn pathOnly(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

fn copyHeaders(request: *std.http.Server.Request, arena: std.mem.Allocator, buf: []std.http.Header) !auth.HeaderSet {
    var n: usize = 0;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (n >= buf.len) break;
        buf[n] = .{
            .name = try arena.dupe(u8, h.name),
            .value = try arena.dupe(u8, h.value),
        };
        n += 1;
    }
    return .{ .items = buf[0..n] };
}

fn readBody(request: *std.http.Server.Request, arena: std.mem.Allocator, max: usize) ![]u8 {
    if (!request.head.method.requestHasBody()) return "";
    var tmp: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&tmp);
    return reader.allocRemaining(arena, .limited(max)) catch |err| switch (err) {
        error.StreamTooLong => return error.StreamTooLong,
        else => return err,
    };
}

test "pathOnly strips query" {
    try std.testing.expectEqualStrings("/health", pathOnly("/health?x=1"));
}
