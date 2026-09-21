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
const digest = @import("digest.zig");
const jsonx = @import("jsonx.zig");
const models = @import("models.zig");
const pool_mod = @import("pool.zig");
const protocol = @import("protocol.zig");
const cursor_api = @import("cursor_api.zig");
const bridge_mod = @import("bridge.zig");
const rawhttp = @import("rawhttp.zig");

pub const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    config: config_mod.Config,
    compact: compact_mod.Store,
    instance_id: []const u8,
    sdk_version: []const u8,
    use_fake: bool,
    bridge: ?*BridgeClient = null,
    catalog: ?*cursor_api.Catalog = null,
    cursor_bridge: ?*bridge_mod.Bridge = null,
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_runs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    replay_mu: Io.Mutex = .init,
    replay: std.StringHashMap([]u8) = undefined,
    runs_by_key: std.StringHashMap(u32) = undefined,
    pool: ?*pool_mod.Pool = null,
};

pub const BridgeClient = struct {
    unary: *const fn (*BridgeClient, std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
    run: *const fn (*BridgeClient, std.mem.Allocator, protocol.Parsed, []const u8, []const u8, i64) anyerror!encode.Turn,
    impl: *anyopaque,
};

pub fn handle(app: *App, req: rawhttp.Incoming, reply: *rawhttp.Reply) void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    serve(app, req, reply, arena) catch |err| {
        if (err == error.WriteFailed) {
            std.log.info("client closed mid-stream", .{});
            return;
        }
        std.log.err("request failed: {t}", .{err});
        if (!reply.started) {
            const body = encode.publicErrorJson(arena, errors.upstreamError("internal error"), "req_unknown") catch return;
            reply.json(500, body, &.{.{ .name = "content-type", .value = "application/json" }}) catch {};
        }
    };
}

fn serve(app: *App, req: rawhttp.Incoming, reply: *rawhttp.Reply, arena: std.mem.Allocator) !void {
    var headers_buf: [128]std.http.Header = undefined;
    const headers = headerSet(req, &headers_buf);
    const path = req.path;
    const method = req.method;
    if (!(method == .GET and std.mem.eql(u8, path, "/health"))) {
        std.log.info("{s} {s}", .{ @tagName(method), path });
    }
    const request_id = headers.get("x-request-id") orelse try ids.requestId(app.io, arena);
    const session_hint = headers.get("x-cursor-session-id");
    const user_agent = headers.get("user-agent");

    if (method == .GET and (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/v1"))) {
        const catalog_mode: []const u8 = if (app.catalog != null) "native" else "fake";
        const inference_mode: []const u8 = if (app.use_fake) "fake" else if (app.cursor_bridge != null) "sdk-bridge" else "unavailable";
        const shutting = app.shutting_down.load(.seq_cst);
        const body = try encode.healthJson(
            arena,
            config_mod.version,
            app.instance_id,
            app.sdk_version,
            !shutting,
            catalog_mode,
            inference_mode,
            shutting,
            app.active_runs.load(.seq_cst),
            app.config.max_active_runs,
            app.config.max_runs_per_key,
            app.config.auth_mode == .managed,
        );
        return sendJson(reply, .ok, body, request_id, null);
    }

    const body_bytes = req.body;

    if (method == .GET and (std.mem.eql(u8, path, "/v1/models") or std.mem.eql(u8, path, "/v1/models-v2"))) {
        const authorized = auth.authorizeClient(headers, "127.0.0.1", .{
            .auth_mode = app.config.auth_mode,
            .gateway_access_key = app.config.gateway_access_key,
            .managed_cursor_key = app.config.managed_cursor_key,
        });
        if (authorized == .err and app.config.auth_mode != .managed) {
            return sendErr(reply, authorized.err, request_id, path, false);
        }
        const json = try modelsJson(app, arena, user_agent);
        return sendJson(reply, .ok, json, request_id, null);
    }

    const authorized = auth.authorizeClient(headers, "127.0.0.1", .{
        .auth_mode = app.config.auth_mode,
        .gateway_access_key = app.config.gateway_access_key,
        .managed_cursor_key = app.config.managed_cursor_key,
    });
    const cred = switch (authorized) {
        .ok => |a| a,
        .err => |e| return sendErr(reply, e, request_id, path, false),
    };

    if (method == .GET and std.mem.eql(u8, path, "/v1/account")) {
        const json = try accountJson(app, arena);
        return sendJson(reply, .ok, json, request_id, null);
    }

    if (method == .OPTIONS) {
        return reply.empty(204, &.{
            .{ .name = "access-control-allow-origin", .value = "*" },
            .{ .name = "access-control-allow-headers", .value = "*" },
            .{ .name = "access-control-allow-methods", .value = "GET,POST,OPTIONS" },
        });
    }

    if (method != .POST) {
        std.log.warn("no route for {s} {s}", .{ @tagName(method), path });
        return sendErr(reply, errors.notFound("No route"), request_id, path, isOpenAi(path));
    }

    if (body_bytes.len == 0) {
        return sendErr(reply, errors.invalidRequest("JSON body is required"), request_id, path, isOpenAi(path));
    }
    const parsed_json = std.json.parseFromSliceLeaky(std.json.Value, arena, body_bytes, .{}) catch {
        return sendErr(reply, errors.invalidRequest("Request body must be valid JSON"), request_id, path, isOpenAi(path));
    };

    if (std.mem.eql(u8, path, "/v1/messages/count_tokens")) {
        const parsed = protocol.parseMessages(arena, parsed_json);
        const p = switch (parsed) {
            .ok => |v| v,
            .err => |e| return sendErr(reply, e, request_id, path, false),
        };
        const n = protocol.estimateInputTokens(p);
        const json = try std.fmt.allocPrint(arena, "{{\"input_tokens\":{d}}}", .{n});
        return sendJson(reply, .ok, json, request_id, null);
    }

    const parsed = if (std.mem.eql(u8, path, "/v1/messages"))
        protocol.parseMessages(arena, parsed_json)
    else if (std.mem.eql(u8, path, "/v1/chat/completions"))
        protocol.parseChat(arena, parsed_json)
    else if (isResponsesPath(path) or isCompactPath(path))
        protocol.parseResponses(arena, parsed_json)
    else {
        std.log.warn("no route for {s} {s}", .{ @tagName(method), path });
        return sendErr(reply, errors.notFound("No route"), request_id, path, isOpenAi(path));
    };
    var p = switch (parsed) {
        .ok => |v| v,
        .err => |e| return sendErr(reply, e, request_id, path, isOpenAi(path)),
    };
    std.log.info("{s} tools={d} continuation={d} outputs={d} stream={s} session={s}", .{
        path,
        p.tools.len,
        p.continuation.len,
        p.all_outputs.len,
        if (p.stream) "1" else "0",
        session_hint orelse "-",
    });

    const req_hash = digest.sha256Hex(req.body);
    if (!p.stream) {
        if (lookupReplay(app, req_hash[0..])) |cached| {
            return sendJson(reply, .ok, cached, request_id, session_hint);
        }
    }
    const need_slot = occupiesRunSlot(path, p);
    if (need_slot) {
        if (waitBeginRun(app, cred.cursor_api_key)) |err| {
            return sendErr(reply, err, request_id, path, isOpenAi(path));
        }
    }
    defer if (need_slot) endRun(app, cred.cursor_api_key);

    if (isCompactPath(path) or p.compaction_trigger) {
        const compact_id = try ids.compactId(app.io, arena);
        const minted = app.compact.mint(arena, compact_id, p.model) catch {
            return sendErr(reply, errors.upstreamError("compact failed"), request_id, path, true);
        };
        const sid = session_hint orelse try ids.sessionId(app.io, arena);
        const json = try encode.encodeCompaction(arena, minted.compact_id, minted.token, p.model, unixNow(app.io), sid, protocol.estimateInputTokens(p));
        if (!p.stream) return sendJson(reply, .ok, json, request_id, sid);
        return writeCompactSse(reply, arena, json, request_id, sid);
    }

    if (grok_summary.isGrokCompactSummaryRequest(p)) {
        std.log.info("grok compact-summary intercept session={s}", .{session_hint orelse "-"});
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
        return writeTurn(app, reply, arena, p, turn, request_id, req_hash[0..]);
    }

    const sid = session_hint orelse try ids.sessionId(app.io, arena);
    const mid = try ids.messageId(app.io, arena);
    const now = unixNow(app.io);

    if (app.use_fake) {
        const turn = try engine.Fake.run(arena, p, sid, mid, now);
        return writeTurn(app, reply, arena, p, turn, request_id, req_hash[0..]);
    }
    const br = app.cursor_bridge orelse {
        return sendErr(
            reply,
            errors.upstreamError("Cursor local inference needs official cursor-sdk-bridge (Bun-compiled SDK). The Grok HTTP stack is Zig; Cursor does not publish a Zig executor. Set CURSOR_SDK_BRIDGE or run scripts/fetch-bridge.sh."),
            request_id,
            path,
            isOpenAi(path),
        );
    };

    if (!p.stream) {
        const turn = (try runBridge(br, arena, p, sid, mid, now, .{}, reply, request_id, path)) orelse return;
        return writeTurn(app, reply, arena, p, turn, request_id, req_hash[0..]);
    }

    if (p.continuation.len > 0) {
        if (br.liveForContinuation(sid, p.continuation) == null) {
            _ = br.restorePending(arena, p, sid) catch null;
        }
        br.preflightContinuation(arena, p, sid) catch |err| {
            const recoverable = (err == error.UnknownToolId or err == error.MissingToolResult) and
                protocol.canRecoverUnknownContinuation(p);
            if (!recoverable) {
                const msg = if (br.last_err.len > 0) br.last_err else @errorName(err);
                const gw = switch (err) {
                    error.UnknownToolId, error.MissingToolResult => errors.invalidRequest(msg),
                    else => return err,
                };
                return sendErr(reply, gw, request_id, path, isOpenAi(path));
            }
            std.log.warn("continuation lost ({s}); recovering as new turn outputs={d} trailing={d}", .{
                if (br.last_err.len > 0) br.last_err else @errorName(err),
                p.all_outputs.len,
                p.continuation.len,
            });
            p.continuation = &.{};
        };
    }

    try reply.beginSse(&.{
        .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
        .{ .name = "x-request-id", .value = request_id },
        .{ .name = "x-cursor-session-id", .value = sid },
    });
    var seq: u32 = 0;
    var box = SseBox{ .body = reply, .arena = arena, .seq = &seq, .kind = p.kind, .message_id = mid };
    if (p.kind == .responses) {
        const created_payload = try wrapInProgress(arena, mid, sid, p.model, now);
        try writeSse(reply, try encode.sseEvent(arena, "response.created", created_payload, seq));
        seq += 1;
        try writeSse(reply, try encode.sseEvent(arena, "response.in_progress", created_payload, seq));
        seq += 1;
    } else if (p.kind == .messages) {
        try writeSse(reply, try encode.sseEvent(arena, "message_start", try std.fmt.allocPrint(arena,
            "{{\"type\":\"message_start\",\"message\":{{\"id\":{f},\"type\":\"message\",\"role\":\"assistant\",\"model\":{f},\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{{\"input_tokens\":0,\"output_tokens\":0}},\"cursor_session_id\":{f}}}}}",
            .{ std.json.fmt(mid, .{}), std.json.fmt(p.model, .{}), std.json.fmt(sid, .{}) },
        ), 0));
        seq += 1;
    }
    const turn = (try runBridge(br, arena, p, sid, mid, now, .{
        .ctx = &box,
        .on_text = sseOnText,
        .on_thinking = sseOnThinking,
    }, reply, request_id, path)) orelse return;
    if (reply.dead) {
        br.forgetSession(sid);
        return;
    }
    if (turn.tools.len > 0) try writeFunctionCallSse(reply, arena, turn, &seq, box.next_output);
    switch (p.kind) {
        .responses => {
            const json = try encode.encodeResponse(arena, turn);
            try writeSse(reply, try encode.sseEvent(arena, "response.completed", try std.fmt.allocPrint(arena, "{{\"response\":{s}}}", .{json}), seq));
        },
        .messages => {
            const stop: []const u8 = if (turn.tools.len > 0) "tool_use" else "end_turn";
            try writeSse(reply, try std.fmt.allocPrint(arena, "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\",\"stop_sequence\":null}},\"usage\":{{\"output_tokens\":{d}}}}}\n\n", .{ stop, turn.output_tokens }));
            try writeSse(reply, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n");
        },
        .chat => {
            try writeChatSse(reply, arena, turn, p.include_usage);
        },
    }
    try reply.end();
}

const SseBox = struct {
    body: *rawhttp.Reply,
    arena: std.mem.Allocator,
    seq: *u32,
    kind: protocol.Kind,
    message_id: []const u8 = "",
    opened_reasoning: bool = false,
    opened_message: bool = false,
    next_output: u32 = 0,
    reason_index: u32 = 0,
    message_index: u32 = 0,
};

fn boxEmit(box: *SseBox, event: []const u8, data_json: []const u8) void {
    const ev = encode.sseEvent(box.arena, event, data_json, box.seq.*) catch return;
    writeSse(box.body, ev) catch {
        box.body.dead = true;
        return;
    };
    box.seq.* += 1;
}

fn sseOnText(ctx: *anyopaque, piece: []const u8) void {
    const box: *SseBox = @ptrCast(@alignCast(ctx));
    if (piece.len == 0) return;
    if (box.kind == .responses) {
        if (!box.opened_message) {
            box.opened_message = true;
            box.message_index = box.next_output;
            box.next_output += 1;
            const added = std.fmt.allocPrint(box.arena,
                "{{\"output_index\":{d},\"item\":{{\"id\":{f},\"type\":\"message\",\"status\":\"in_progress\",\"role\":\"assistant\",\"content\":[]}}}}",
                .{ box.message_index, std.json.fmt(box.message_id, .{}) },
            ) catch return;
            boxEmit(box, "response.output_item.added", added);
            const part = std.fmt.allocPrint(box.arena,
                "{{\"item_id\":{f},\"output_index\":{d},\"content_index\":0,\"part\":{{\"type\":\"output_text\",\"text\":\"\",\"annotations\":[]}}}}",
                .{ std.json.fmt(box.message_id, .{}), box.message_index },
            ) catch return;
            boxEmit(box, "response.content_part.added", part);
        }
        const data = std.fmt.allocPrint(box.arena,
            "{{\"item_id\":{f},\"output_index\":{d},\"content_index\":0,\"delta\":{f}}}",
            .{ std.json.fmt(box.message_id, .{}), box.message_index, std.json.fmt(piece, .{}) },
        ) catch return;
        boxEmit(box, "response.output_text.delta", data);
    } else if (box.kind == .messages) {
        const ev = std.fmt.allocPrint(box.arena, "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{f}}}}}\n\n", .{std.json.fmt(piece, .{})}) catch return;
        writeSse(box.body, ev) catch return;
    }
}

fn sseOnThinking(ctx: *anyopaque, piece: []const u8) void {
    const box: *SseBox = @ptrCast(@alignCast(ctx));
    if (piece.len == 0) return;
    if (box.kind == .responses) {
        const item_id = ids.reasoningItemId(box.message_id, box.arena) catch return;
        if (!box.opened_reasoning) {
            box.opened_reasoning = true;
            box.reason_index = box.next_output;
            box.next_output += 1;
            const added = std.fmt.allocPrint(box.arena,
                "{{\"output_index\":{d},\"item\":{{\"id\":{f},\"type\":\"reasoning\",\"summary\":[]}}}}",
                .{ box.reason_index, std.json.fmt(item_id, .{}) },
            ) catch return;
            boxEmit(box, "response.output_item.added", added);
            const part = std.fmt.allocPrint(box.arena,
                "{{\"item_id\":{f},\"output_index\":{d},\"summary_index\":0,\"part\":{{\"type\":\"summary_text\",\"text\":{f}}}}}",
                .{ std.json.fmt(item_id, .{}), box.reason_index, std.json.fmt(piece, .{}) },
            ) catch return;
            boxEmit(box, "response.reasoning_summary_part.added", part);
            return;
        }
        const data = std.fmt.allocPrint(box.arena,
            "{{\"item_id\":{f},\"output_index\":{d},\"summary_index\":0,\"delta\":{f}}}",
            .{ std.json.fmt(item_id, .{}), box.reason_index, std.json.fmt(piece, .{}) },
        ) catch return;
        boxEmit(box, "response.reasoning_summary_text.delta", data);
    }
}

fn runBridge(
    br: *bridge_mod.Bridge,
    arena: std.mem.Allocator,
    parsed: protocol.Parsed,
    session_id: []const u8,
    message_id: []const u8,
    now: i64,
    sink: bridge_mod.Sink,
    reply: *rawhttp.Reply,
    request_id: []const u8,
    path: []const u8,
) !?encode.Turn {
    return br.runStreaming(arena, parsed, session_id, message_id, now, sink) catch |err| {
        const msg = if (br.last_err.len > 0) br.last_err else @errorName(err);
        const gw = switch (err) {
            error.UnknownToolId, error.MissingToolResult => errors.invalidRequest(msg),
            error.SessionLost => errors.sessionLost(msg),
            error.SessionConflict => errors.sessionConflict(msg),
            error.BridgeRpcFailed => errors.upstreamError(msg),
            else => return err,
        };
        if (err == error.BridgeRpcFailed) br.forgetSession(session_id);
        if (reply.started) {
            const json = try encode.publicErrorJson(arena, gw, request_id);
            try writeSse(reply, try encode.sseEvent(arena, "error", json, 0));
            try reply.end();
            return null;
        }
        try sendErr(reply, gw, request_id, path, isOpenAi(path));
        return null;
    };
}

fn writeFunctionCallSse(reply: *rawhttp.Reply, arena: std.mem.Allocator, turn: encode.Turn, seq: *u32, start_index: u32) !void {
    var output_index = start_index;
    for (turn.tools) |tool| {
        const item_id = try ids.functionCallItemId(tool.id, arena);
        const ns = if (tool.namespace.len > 0)
            try std.fmt.allocPrint(arena, ",\"namespace\":{f}", .{std.json.fmt(tool.namespace, .{})})
        else
            "";
        if (tool.kind == .custom) {
            try writeSse(reply, try encode.sseEvent(arena, "response.output_item.added", try std.fmt.allocPrint(arena,
                "{{\"output_index\":{d},\"item\":{{\"id\":{f},\"type\":\"custom_tool_call\",\"status\":\"in_progress\",\"call_id\":{f},\"name\":{f},\"input\":\"\"}}}}",
                .{ output_index, std.json.fmt(item_id, .{}), std.json.fmt(tool.id, .{}), std.json.fmt(tool.name, .{}) },
            ), seq.*));
            seq.* += 1;
            try writeSse(reply, try encode.sseEvent(arena, "response.custom_tool_call_input.done", try std.fmt.allocPrint(arena,
                "{{\"item_id\":{f},\"output_index\":{d},\"input\":{f}{s}}}",
                .{ std.json.fmt(item_id, .{}), output_index, std.json.fmt(tool.arguments, .{}), ns },
            ), seq.*));
            seq.* += 1;
        } else {
            try writeSse(reply, try encode.sseEvent(arena, "response.output_item.added", try std.fmt.allocPrint(arena,
                "{{\"output_index\":{d},\"item\":{{\"id\":{f},\"type\":\"function_call\",\"status\":\"in_progress\",\"call_id\":{f},\"name\":{f},\"arguments\":\"\"}}}}",
                .{ output_index, std.json.fmt(item_id, .{}), std.json.fmt(tool.id, .{}), std.json.fmt(tool.name, .{}) },
            ), seq.*));
            seq.* += 1;
            try writeSse(reply, try encode.sseEvent(arena, "response.function_call_arguments.delta", try std.fmt.allocPrint(arena,
                "{{\"item_id\":{f},\"output_index\":{d},\"delta\":{f}}}",
                .{ std.json.fmt(item_id, .{}), output_index, std.json.fmt(tool.arguments, .{}) },
            ), seq.*));
            seq.* += 1;
            try writeSse(reply, try encode.sseEvent(arena, "response.function_call_arguments.done", try std.fmt.allocPrint(arena,
                "{{\"item_id\":{f},\"output_index\":{d},\"name\":{f},\"arguments\":{f}{s}}}",
                .{ std.json.fmt(item_id, .{}), output_index, std.json.fmt(tool.name, .{}), std.json.fmt(tool.arguments, .{}), ns },
            ), seq.*));
            seq.* += 1;
        }
        if (tool.kind == .custom) {
            try writeSse(reply, try encode.sseEvent(arena, "response.output_item.done", try std.fmt.allocPrint(arena,
                "{{\"output_index\":{d},\"item\":{{\"id\":{f},\"type\":\"custom_tool_call\",\"status\":\"completed\",\"call_id\":{f},\"name\":{f},\"input\":{f}{s}}}}}",
                .{ output_index, std.json.fmt(item_id, .{}), std.json.fmt(tool.id, .{}), std.json.fmt(tool.name, .{}), std.json.fmt(tool.arguments, .{}), ns },
            ), seq.*));
        } else {
            try writeSse(reply, try encode.sseEvent(arena, "response.output_item.done", try std.fmt.allocPrint(arena,
                "{{\"output_index\":{d},\"item\":{{\"id\":{f},\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":{f},\"name\":{f},\"arguments\":{f}{s}}}}}",
                .{ output_index, std.json.fmt(item_id, .{}), std.json.fmt(tool.id, .{}), std.json.fmt(tool.name, .{}), std.json.fmt(tool.arguments, .{}), ns },
            ), seq.*));
        }
        seq.* += 1;
        output_index += 1;
    }
}

fn writeTurn(app: *App, reply: *rawhttp.Reply, arena: std.mem.Allocator, parsed: protocol.Parsed, turn: encode.Turn, request_id: []const u8, req_hash: []const u8) !void {
    if (!parsed.stream) {
        const json = switch (parsed.kind) {
            .responses => try encode.encodeResponse(arena, turn),
            .messages => try encode.encodeMessage(arena, turn),
            .chat => try encode.encodeChat(arena, turn),
        };
        storeReplay(app, req_hash, json);
        return sendJson(reply, .ok, json, request_id, turn.session_id);
    }
    try reply.beginSse(&.{
        .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
        .{ .name = "x-request-id", .value = request_id },
        .{ .name = "x-cursor-session-id", .value = turn.session_id },
    });
    switch (parsed.kind) {
        .responses => try writeResponsesSse(reply, arena, turn),
        .messages => try writeMessagesSse(reply, arena, turn),
        .chat => try writeChatSse(reply, arena, turn, parsed.include_usage),
    }
    try reply.end();
}

fn wrapInProgress(arena: std.mem.Allocator, message_id: []const u8, session_id: []const u8, model: []const u8, now: i64) ![]u8 {
    const inner = try encode.encodeInProgress(arena, .{
        .message_id = message_id,
        .session_id = session_id,
        .model = model,
        .created_at = now,
        .text = "",
    });
    return std.fmt.allocPrint(arena, "{{\"response\":{s}}}", .{inner});
}

fn writeResponsesSse(body: *rawhttp.Reply, arena: std.mem.Allocator, turn: encode.Turn) !void {
    const json = try encode.encodeResponse(arena, turn);
    var seq: u32 = 0;
    const created_payload = try wrapInProgress(arena, turn.message_id, turn.session_id, turn.model, turn.created_at);
    try writeSse(body, try encode.sseEvent(arena, "response.created", created_payload, seq));
    seq += 1;
    try writeSse(body, try encode.sseEvent(arena, "response.in_progress", created_payload, seq));
    seq += 1;
    var output_index: u32 = 0;
    if (turn.thinking.len > 0) {
        const rs = try ids.reasoningItemId(turn.message_id, arena);
        try writeSse(body, try encode.sseEvent(arena, "response.output_item.added", try std.fmt.allocPrint(arena,
            "{{\"output_index\":{d},\"item\":{{\"id\":{f},\"type\":\"reasoning\",\"summary\":[]}}}}",
            .{ output_index, std.json.fmt(rs, .{}) },
        ), seq));
        seq += 1;
        try writeSse(body, try encode.sseEvent(arena, "response.reasoning_summary_text.delta", try std.fmt.allocPrint(arena,
            "{{\"item_id\":{f},\"output_index\":{d},\"summary_index\":0,\"delta\":{f}}}",
            .{ std.json.fmt(rs, .{}), output_index, std.json.fmt(turn.thinking, .{}) },
        ), seq));
        seq += 1;
        output_index += 1;
    }
    if (turn.text.len > 0) {
        try writeSse(body, try encode.sseEvent(arena, "response.output_item.added", try std.fmt.allocPrint(arena,
            "{{\"output_index\":{d},\"item\":{{\"id\":{f},\"type\":\"message\",\"status\":\"in_progress\",\"role\":\"assistant\",\"content\":[]}}}}",
            .{ output_index, std.json.fmt(turn.message_id, .{}) },
        ), seq));
        seq += 1;
        try writeSse(body, try encode.sseEvent(arena, "response.output_text.delta", try std.fmt.allocPrint(arena,
            "{{\"item_id\":{f},\"output_index\":{d},\"content_index\":0,\"delta\":{f}}}",
            .{ std.json.fmt(turn.message_id, .{}), output_index, std.json.fmt(turn.text, .{}) },
        ), seq));
        seq += 1;
    }
    try writeSse(body, try encode.sseEvent(arena, "response.completed", try std.fmt.allocPrint(arena, "{{\"response\":{s}}}", .{json}), seq));
}

fn writeMessagesSse(body: *rawhttp.Reply, arena: std.mem.Allocator, turn: encode.Turn) !void {
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

fn writeChatSse(body: *rawhttp.Reply, arena: std.mem.Allocator, turn: encode.Turn, include_usage: bool) !void {
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

fn writeCompactSse(reply: *rawhttp.Reply, arena: std.mem.Allocator, json: []const u8, request_id: []const u8, session_id: []const u8) !void {
    try reply.beginSse(&.{
        .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
        .{ .name = "x-request-id", .value = request_id },
        .{ .name = "x-cursor-session-id", .value = session_id },
    });
    try writeSse(reply, try encode.sseEvent(arena, "response.created", try std.fmt.allocPrint(arena, "{{\"response\":{s}}}", .{json}), 0));
    try writeSse(reply, try encode.sseEvent(arena, "response.completed", try std.fmt.allocPrint(arena, "{{\"response\":{s}}}", .{json}), 1));
    try reply.end();
}

fn writeSse(body: *rawhttp.Reply, bytes: []const u8) !void {
    try body.writeAll(bytes);
}

fn modelsJson(app: *App, arena: std.mem.Allocator, user_agent: ?[]const u8) ![]u8 {
    var listed = std.ArrayList(cursor_api.Model).empty;
    var live_ok = false;
    var stale_cache = false;
    if (app.catalog) |cat| {
        if (cat.listModels(arena)) |result| {
            if (result.models.len > 0) {
                try listed.appendSlice(arena, result.models);
                live_ok = true;
                stale_cache = result.stale;
            }
        } else |_| {}
    }
    if (!live_ok) {
        const ids_list = try engine.Fake.listModels(arena);
        for (ids_list) |id| {
            try listed.append(arena, .{ .id = id, .display_name = id });
        }
        stale_cache = true;
    }
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(arena, "{\"object\":\"list\",\"data\":[");
    var first = true;
    for (listed.items) |item| {
        const aliases = try models.catalogModelIdsForClient(arena, item.id, user_agent);
        for (aliases) |alias| {
            if (!first) try out.append(arena, ',');
            first = false;
            try out.appendSlice(arena, try std.fmt.allocPrint(arena,
                "{{\"id\":{f},\"object\":\"model\",\"created\":0,\"display_name\":{f},\"description\":{f},\"context_tokens\":{d},\"compact_max_chars\":{d}}}",
                .{
                    std.json.fmt(alias, .{}),
                    std.json.fmt(item.display_name, .{}),
                    std.json.fmt(item.description, .{}),
                    models.contextTokensForModel(alias),
                    models.sdkPromptMaxCharsForModel(alias),
                },
            ));
        }
    }
    const stale: []const u8 = if (stale_cache) "true" else "false";
    try out.appendSlice(arena, "],\"status\":\"ok\",\"cache\":{\"stale\":");
    try out.appendSlice(arena, stale);
    try out.appendSlice(arena, "}}");
    return out.toOwnedSlice(arena);
}

fn accountJson(app: *App, arena: std.mem.Allocator) ![]u8 {
    if (app.catalog) |cat| {
        if (cat.me(arena)) |ident| {
            return std.fmt.allocPrint(arena,
                "{{\"status\":\"ok\",\"identity\":{{\"api_key_name\":{f},\"user_id\":{f},\"created_at\":{f},\"first_name\":{f},\"last_name\":{f},\"user_email\":{f}}},\"runtime\":{{\"default_profile\":\"sdk\",\"sand_selectable\":false,\"applies_to_new_sessions\":true}},\"capabilities\":{{\"identity\":true}}}}",
                .{
                    std.json.fmt(ident.api_key_name, .{}),
                    std.json.fmt(ident.user_id, .{}),
                    std.json.fmt(ident.created_at, .{}),
                    std.json.fmt(ident.first_name, .{}),
                    std.json.fmt(ident.last_name, .{}),
                    std.json.fmt(ident.user_email, .{}),
                },
            );
        } else |_| {}
    }
    return arena.dupe(u8,
        "{\"status\":\"ok\",\"identity\":{\"api_key_name\":\"hitch\"},\"runtime\":{\"default_profile\":\"sdk\",\"sand_selectable\":false,\"applies_to_new_sessions\":true},\"capabilities\":{\"identity\":true}}",
    );
}

fn sendJson(reply: *rawhttp.Reply, status: std.http.Status, body: []const u8, request_id: []const u8, session_id: ?[]const u8) !void {
    if (session_id) |sid| {
        return reply.json(@intFromEnum(status), body, &.{
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
            .{ .name = "x-request-id", .value = request_id },
            .{ .name = "x-cursor-session-id", .value = sid },
        });
    }
    return reply.json(@intFromEnum(status), body, &.{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "x-request-id", .value = request_id },
    });
}

fn sendErr(reply: *rawhttp.Reply, err: errors.Error, request_id: []const u8, path: []const u8, openai: bool) !void {
    _ = path;
    const json = if (openai)
        try encode.openaiError(std.heap.page_allocator, err, request_id)
    else
        try encode.publicErrorJson(std.heap.page_allocator, err, request_id);
    defer std.heap.page_allocator.free(json);
    try reply.json(err.http_status, json, &.{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "x-request-id", .value = request_id },
    });
}

fn isOpenAi(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/chat/completions") != null or
        std.mem.indexOf(u8, path, "/responses") != null;
}

fn isResponsesPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/v1/responses") or std.mem.endsWith(u8, path, "/v1/responses");
}

fn isCompactPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/v1/responses/compact") or std.mem.endsWith(u8, path, "/v1/responses/compact");
}

fn unixNow(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, 1_000_000_000));
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

fn sleepMs(io: Io, ms: i64) void {
    const d: Io.Clock.Duration = .{ .raw = .fromMilliseconds(ms), .clock = .real };
    d.sleep(io) catch {};
}

/// Node gold counts creating/running/resuming only. Local compact, Grok
/// compact-summary intercept, and awaiting tool_result continuation do not.
fn occupiesRunSlot(path: []const u8, p: protocol.Parsed) bool {
    if (isCompactPath(path) or p.compaction_trigger) return false;
    if (p.continuation.len > 0) return false;
    if (grok_summary.isGrokCompactSummaryRequest(p)) return false;
    return true;
}

fn waitBeginRun(app: *App, key: []const u8) ?errors.Error {
    if (app.shutting_down.load(.seq_cst)) {
        return errors.rateLimited("Gateway is draining; new runs are not accepted");
    }
    if (beginRun(app, key) == null) return null;
    const wait_ms: i64 = app.config.capacity_wait_ms;
    if (wait_ms == 0) return capacityError(app);
    std.log.info("waiting for run slot up to {d}ms (global={d}/{d})", .{
        wait_ms,
        app.active_runs.load(.seq_cst),
        app.config.max_active_runs,
    });
    const start = nowMs(app.io);
    const poll: i64 = @max(@as(i64, 1), app.config.capacity_poll_ms);
    while (nowMs(app.io) - start < wait_ms) {
        if (app.shutting_down.load(.seq_cst)) {
            return errors.rateLimited("Gateway is draining; new runs are not accepted");
        }
        sleepMs(app.io, poll);
        if (beginRun(app, key) == null) return null;
    }
    return capacityError(app);
}

fn capacityError(app: *App) errors.Error {
    if (app.active_runs.load(.seq_cst) >= app.config.max_active_runs) {
        return errors.rateLimited("global_active_runs limit reached");
    }
    return errors.rateLimited("per-credential run limit reached");
}

fn beginRun(app: *App, key: []const u8) ?errors.Error {
    app.replay_mu.lockUncancelable(app.io);
    defer app.replay_mu.unlock(app.io);
    const global = app.active_runs.load(.seq_cst);
    if (global >= app.config.max_active_runs) {
        return errors.rateLimited("global_active_runs limit reached");
    }
    if (app.runs_by_key.getPtr(key)) |n| {
        if (n.* >= app.config.max_runs_per_key) {
            return errors.rateLimited("per-credential run limit reached");
        }
        n.* += 1;
        _ = app.active_runs.fetchAdd(1, .seq_cst);
        return null;
    }
    const owned = app.gpa.dupe(u8, key) catch {
        return errors.upstreamError("capacity tracking failed");
    };
    app.runs_by_key.put(owned, 1) catch {
        app.gpa.free(owned);
        return errors.upstreamError("capacity tracking failed");
    };
    _ = app.active_runs.fetchAdd(1, .seq_cst);
    return null;
}

fn endRun(app: *App, key: []const u8) void {
    app.replay_mu.lockUncancelable(app.io);
    defer app.replay_mu.unlock(app.io);
    if (app.active_runs.load(.seq_cst) > 0) {
        _ = app.active_runs.fetchSub(1, .seq_cst);
    }
    const n = app.runs_by_key.getPtr(key) orelse return;
    if (n.* > 1) {
        n.* -= 1;
        return;
    }
    if (app.runs_by_key.fetchRemove(key)) |kv| {
        app.gpa.free(kv.key);
    }
}

fn lookupReplay(app: *App, hex: []const u8) ?[]const u8 {
    app.replay_mu.lockUncancelable(app.io);
    defer app.replay_mu.unlock(app.io);
    return app.replay.get(hex);
}

fn storeReplay(app: *App, hex: []const u8, json: []const u8) void {
    app.replay_mu.lockUncancelable(app.io);
    defer app.replay_mu.unlock(app.io);
    if (app.replay.count() >= 64) return;
    const key = app.gpa.dupe(u8, hex) catch return;
    const val = app.gpa.dupe(u8, json) catch return;
    app.replay.put(key, val) catch {};
}

fn pathOnly(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

fn headerSet(req: rawhttp.Incoming, buf: []std.http.Header) auth.HeaderSet {
    const n = @min(req.headers.len, buf.len);
    for (req.headers[0..n], 0..) |h, i| {
        buf[i] = .{ .name = h.name, .value = h.value };
    }
    return .{ .items = buf[0..n] };
}

test "pathOnly strips query" {
    try std.testing.expectEqualStrings("/health", pathOnly("/health?x=1"));
}

fn testParsed(continuation: []protocol.ToolResult, compact: bool, last_user: []const u8) protocol.Parsed {
    return .{
        .kind = .responses,
        .model = "cursor-cidr/grok-4.6",
        .upstream_model = "grok-4.6",
        .stream = true,
        .system_text = "",
        .last_user_text = last_user,
        .flatten_text = last_user,
        .tools = &.{},
        .continuation = continuation,
        .all_outputs = &.{},
        .compaction_trigger = compact,
        .compaction_token = null,
        .include_usage = false,
        .effort = null,
        .raw = .null,
    };
}

test "occupiesRunSlot skips compact, continuation, grok summary" {
    var results = [_]protocol.ToolResult{.{ .call_id = "call_1", .output = "{}" }};
    try std.testing.expect(!occupiesRunSlot("/v1/responses/compact", testParsed(&.{}, false, "hi")));
    try std.testing.expect(!occupiesRunSlot("/v1/responses", testParsed(&.{}, true, "hi")));
    try std.testing.expect(!occupiesRunSlot("/v1/responses", testParsed(results[0..], false, "hi")));
    try std.testing.expect(!occupiesRunSlot(
        "/v1/responses",
        testParsed(&.{}, false, "Output the final summary inside a single <summary> faithful, concise summary of the conversation so far"),
    ));
    try std.testing.expect(occupiesRunSlot("/v1/responses", testParsed(&.{}, false, "hello")));
}
