const std = @import("std");
const errors = @import("errors.zig");
const ids = @import("ids.zig");
const jsonx = @import("jsonx.zig");
const protocol = @import("protocol.zig");

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
    kind: protocol.ToolKind = .function,
};

pub const Turn = struct {
    message_id: []const u8,
    session_id: []const u8,
    model: []const u8,
    created_at: i64,
    text: []const u8,
    thinking: []const u8 = "",
    tools: []const ToolCall = &.{},
    input_tokens: u32 = 1,
    output_tokens: u32 = 1,
    stop_reason: []const u8 = "end_turn",
};

pub fn publicError(allocator: std.mem.Allocator, err: errors.Error, request_id: []const u8) ![]u8 {
    return jsonx.stringify(allocator, .{
        .type = "error",
        .error_ = .{ .type = @tagName(err.code), .message = err.message },
        .request_id = request_id,
    });
}

pub fn openaiError(allocator: std.mem.Allocator, err: errors.Error, request_id: []const u8) ![]u8 {
    _ = request_id;
    return std.fmt.allocPrint(allocator,
        "{{\"error\":{{\"message\":{f},\"type\":\"{s}\",\"param\":null,\"code\":\"{s}\"}}}}",
        .{ std.json.fmt(err.message, .{}), err.code.openaiType(), @tagName(err.code) },
    );
}

/// std.json.Stringify uses field names as-is, so `error_` would leak. Build by hand.
pub fn publicErrorJson(allocator: std.mem.Allocator, err: errors.Error, request_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "{{\"type\":\"error\",\"error\":{{\"type\":\"{s}\",\"message\":{f}}},\"request_id\":{f}}}",
        .{ @tagName(err.code), std.json.fmt(err.message, .{}), std.json.fmt(request_id, .{}) },
    );
}

pub fn healthJson(
    allocator: std.mem.Allocator,
    version: []const u8,
    instance_id: []const u8,
    sdk_version: []const u8,
    accepting: bool,
    catalog: []const u8,
    inference: []const u8,
) ![]u8 {
    const status = if (accepting) "ok" else "not_ready";
    return std.fmt.allocPrint(allocator,
        "{{\"status\":\"{s}\",\"service\":\"cursor-sdk2api-zig\",\"version\":\"{s}\",\"sdk_version\":\"{s}\",\"runtime\":\"zig\",\"instance_id\":\"{s}\",\"cursor\":{{\"catalog\":\"{s}\",\"inference\":\"{s}\",\"cloud_agents\":false}},\"readiness\":{{\"accepting_sessions\":{s},\"shutting_down\":false}},\"capabilities\":{{\"messages\":true,\"count_tokens\":true,\"chat_completions\":true,\"responses\":true,\"streaming\":true,\"thinking\":true,\"images\":true,\"tools\":true,\"parallel_tools\":true,\"replay\":true,\"agent_resume\":true,\"pending_tool_restart_resume\":true,\"ordinary_turn_coordinator\":true,\"streaming_impl\":\"sdk_onDelta\",\"store_backend\":\"jsonl\"}}}}",
        .{ status, version, sdk_version, instance_id, catalog, inference, if (accepting) "true" else "false" },
    );
}

pub fn encodeResponse(allocator: std.mem.Allocator, turn: Turn) ![]u8 {
    const id = try ids.responseId(turn.message_id, allocator);
    const status: []const u8 = if (std.mem.eql(u8, turn.stop_reason, "tool_use")) "completed" else if (std.mem.eql(u8, turn.stop_reason, "max_tokens")) "incomplete" else "completed";
    var output = std.ArrayList(u8).empty;
    try output.append(allocator, '[');
    var first = true;
    if (turn.thinking.len > 0) {
        const rs = try ids.reasoningItemId(turn.message_id, allocator);
        try comma(&output, allocator, &first);
        try output.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            "{{\"id\":{f},\"type\":\"reasoning\",\"summary\":[{{\"type\":\"summary_text\",\"text\":{f}}}]}}",
            .{ std.json.fmt(rs, .{}), std.json.fmt(turn.thinking, .{}) },
        ));
    }
    if (turn.text.len > 0 or turn.tools.len == 0) {
        try comma(&output, allocator, &first);
        try output.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            "{{\"id\":{f},\"type\":\"message\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":{f},\"annotations\":[]}}]}}",
            .{ std.json.fmt(turn.message_id, .{}), std.json.fmt(turn.text, .{}) },
        ));
    }
    for (turn.tools) |tool| {
        try comma(&output, allocator, &first);
        const item_id = try ids.functionCallItemId(tool.id, allocator);
        if (tool.kind == .custom) {
            try output.appendSlice(allocator, try std.fmt.allocPrint(allocator,
                "{{\"id\":{f},\"type\":\"custom_tool_call\",\"status\":\"completed\",\"call_id\":{f},\"name\":{f},\"input\":{f}}}",
                .{ std.json.fmt(item_id, .{}), std.json.fmt(tool.id, .{}), std.json.fmt(tool.name, .{}), std.json.fmt(tool.arguments, .{}) },
            ));
        } else {
            try output.appendSlice(allocator, try std.fmt.allocPrint(allocator,
                "{{\"id\":{f},\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":{f},\"name\":{f},\"arguments\":{f}}}",
                .{ std.json.fmt(item_id, .{}), std.json.fmt(tool.id, .{}), std.json.fmt(tool.name, .{}), std.json.fmt(tool.arguments, .{}) },
            ));
        }
    }
    try output.append(allocator, ']');
    return std.fmt.allocPrint(allocator,
        "{{\"id\":{f},\"object\":\"response\",\"created_at\":{d},\"status\":\"{s}\",\"error\":null,\"incomplete_details\":null,\"model\":{f},\"output\":{s},\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"total_tokens\":{d},\"input_tokens_details\":{{\"cached_tokens\":0}},\"output_tokens_details\":{{\"reasoning_tokens\":0}},\"usage_status\":\"unavailable\"}},\"cursor_session_id\":{f}}}",
        .{
            std.json.fmt(id, .{}),
            turn.created_at,
            status,
            std.json.fmt(turn.model, .{}),
            output.items,
            turn.input_tokens,
            turn.output_tokens,
            turn.input_tokens + turn.output_tokens,
            std.json.fmt(turn.session_id, .{}),
        },
    );
}

pub fn encodeMessage(allocator: std.mem.Allocator, turn: Turn) ![]u8 {
    var content = std.ArrayList(u8).empty;
    try content.append(allocator, '[');
    var first = true;
    if (turn.thinking.len > 0) {
        try comma(&content, allocator, &first);
        try content.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            "{{\"type\":\"thinking\",\"thinking\":{f}}}",
            .{std.json.fmt(turn.thinking, .{})},
        ));
    }
    if (turn.text.len > 0 or turn.tools.len == 0) {
        try comma(&content, allocator, &first);
        try content.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            "{{\"type\":\"text\",\"text\":{f}}}",
            .{std.json.fmt(turn.text, .{})},
        ));
    }
    for (turn.tools) |tool| {
        try comma(&content, allocator, &first);
        try content.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            "{{\"type\":\"tool_use\",\"id\":{f},\"name\":{f},\"input\":{s}}}",
            .{ std.json.fmt(tool.id, .{}), std.json.fmt(tool.name, .{}), if (tool.arguments.len > 0) tool.arguments else "{}" },
        ));
    }
    try content.append(allocator, ']');
    const stop: []const u8 = if (turn.tools.len > 0) "tool_use" else turn.stop_reason;
    return std.fmt.allocPrint(allocator,
        "{{\"id\":{f},\"type\":\"message\",\"role\":\"assistant\",\"model\":{f},\"content\":{s},\"stop_reason\":\"{s}\",\"stop_sequence\":null,\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d}}},\"cursor_session_id\":{f}}}",
        .{
            std.json.fmt(turn.message_id, .{}),
            std.json.fmt(turn.model, .{}),
            content.items,
            stop,
            turn.input_tokens,
            turn.output_tokens,
            std.json.fmt(turn.session_id, .{}),
        },
    );
}

pub fn encodeChat(allocator: std.mem.Allocator, turn: Turn) ![]u8 {
    const id = try ids.chatCompletionId(turn.message_id, allocator);
    const finish: []const u8 = if (turn.tools.len > 0) "tool_calls" else if (std.mem.eql(u8, turn.stop_reason, "max_tokens")) "length" else "stop";
    var tool_calls: []const u8 = "null";
    if (turn.tools.len > 0) {
        var buf = std.ArrayList(u8).empty;
        try buf.append(allocator, '[');
        for (turn.tools, 0..) |tool, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator,
                "{{\"id\":{f},\"type\":\"function\",\"function\":{{\"name\":{f},\"arguments\":{f}}}}}",
                .{ std.json.fmt(tool.id, .{}), std.json.fmt(tool.name, .{}), std.json.fmt(tool.arguments, .{}) },
            ));
        }
        try buf.append(allocator, ']');
        tool_calls = buf.items;
    }
    const content_json = if (turn.tools.len > 0 and turn.text.len == 0) "null" else try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(turn.text, .{})});
    const reasoning = if (turn.thinking.len > 0)
        try std.fmt.allocPrint(allocator, ",\"reasoning_content\":{f}", .{std.json.fmt(turn.thinking, .{})})
    else
        "";
    const tool_field = if (turn.tools.len > 0)
        try std.fmt.allocPrint(allocator, ",\"tool_calls\":{s}", .{tool_calls})
    else
        "";
    return std.fmt.allocPrint(allocator,
        "{{\"id\":{f},\"object\":\"chat.completion\",\"created\":{d},\"model\":{f},\"choices\":[{{\"index\":0,\"message\":{{\"role\":\"assistant\",\"content\":{s}{s}{s}}},\"finish_reason\":\"{s}\"}}],\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}},\"cursor_session_id\":{f}}}",
        .{
            std.json.fmt(id, .{}),
            turn.created_at,
            std.json.fmt(turn.model, .{}),
            content_json,
            reasoning,
            tool_field,
            finish,
            turn.input_tokens,
            turn.output_tokens,
            turn.input_tokens + turn.output_tokens,
            std.json.fmt(turn.session_id, .{}),
        },
    );
}

pub fn encodeCompaction(allocator: std.mem.Allocator, compact_id: []const u8, token: []const u8, model: []const u8, created_at: i64, session_id: []const u8, input_tokens: u32) ![]u8 {
    const resp_id = if (std.mem.startsWith(u8, compact_id, "cmp_"))
        try std.fmt.allocPrint(allocator, "resp_{s}", .{compact_id[4..]})
    else
        compact_id;
    return std.fmt.allocPrint(allocator,
        "{{\"id\":{f},\"object\":\"response\",\"created_at\":{d},\"status\":\"completed\",\"error\":null,\"incomplete_details\":null,\"model\":{f},\"output\":[{{\"id\":{f},\"type\":\"compaction\",\"encrypted_content\":{f}}}],\"usage\":{{\"input_tokens\":{d},\"output_tokens\":1,\"total_tokens\":{d},\"input_tokens_details\":{{\"cached_tokens\":0}},\"output_tokens_details\":{{\"reasoning_tokens\":0}},\"usage_status\":\"unavailable\"}},\"cursor_session_id\":{f}}}",
        .{
            std.json.fmt(resp_id, .{}),
            created_at,
            std.json.fmt(model, .{}),
            std.json.fmt(compact_id, .{}),
            std.json.fmt(token, .{}),
            input_tokens,
            input_tokens + 1,
            std.json.fmt(session_id, .{}),
        },
    );
}

pub fn sseEvent(allocator: std.mem.Allocator, event: []const u8, data_json: []const u8, sequence: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "event: {s}\ndata: {s}\n\n", .{
        event,
        try std.fmt.allocPrint(allocator, "{s}", .{try injectSequence(allocator, data_json, event, sequence)}),
    });
}

fn injectSequence(allocator: std.mem.Allocator, data_json: []const u8, event: []const u8, sequence: u32) ![]u8 {
    if (data_json.len >= 2 and data_json[0] == '{') {
        return std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\",\"sequence_number\":{d},{s}", .{
            event,
            sequence,
            data_json[1..],
        });
    }
    return try allocator.dupe(u8, data_json);
}

pub fn sseData(allocator: std.mem.Allocator, data_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {s}\n\n", .{data_json});
}

fn comma(out: *std.ArrayList(u8), allocator: std.mem.Allocator, first: *bool) !void {
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
}

test "encodeResponse includes output_text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = try encodeResponse(arena.allocator(), .{
        .message_id = "msg_1",
        .session_id = "ses_1",
        .model = "grok-4.6",
        .created_at = 1,
        .text = "hi",
    });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"object\":\"response\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"resp_1\"") != null);
}

test "publicErrorJson uses error field" {
    const json = try publicErrorJson(std.testing.allocator, errors.invalidRequest("model is required"), "req_1");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"invalid_request\"") != null);
}
