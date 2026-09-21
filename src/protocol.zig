const std = @import("std");
const errors = @import("errors.zig");
const jsonx = @import("jsonx.zig");
const models = @import("models.zig");

pub const Kind = enum { responses, messages, chat };

pub const ToolKind = enum { function, custom };

pub const Tool = struct {
    name: []const u8,
    sdk_name: []const u8,
    description: []const u8,
    schema_json: []const u8,
    kind: ToolKind = .function,
    namespace: []const u8 = "",
};

pub const ToolResult = struct {
    call_id: []const u8,
    output: []const u8,
};

pub const Image = struct {
    mime_type: []const u8 = "image/png",
    data: []const u8,
};

pub const ToolChoiceKind = enum { auto, required, named };

pub const Parsed = struct {
    kind: Kind,
    model: []const u8,
    upstream_model: []const u8,
    stream: bool,
    system_text: []const u8,
    last_user_text: []const u8,
    flatten_text: []const u8,
    tools: []Tool,
    continuation: []ToolResult,
    /// Every function_call_output in the request, including historical ones.
    /// Live continuation is pending ∩ all_outputs (see selectPendingResults).
    all_outputs: []ToolResult,
    compaction_trigger: bool,
    compaction_token: ?[]const u8,
    include_usage: bool,
    effort: ?[]const u8,
    images: []Image = &.{},
    tool_choice: ToolChoiceKind = .auto,
    tool_choice_name: []const u8 = "",
    parallel_tools: bool = true,
    cursor_params_json: []const u8 = "",
    raw: std.json.Value,
};

pub const Outcome = union(enum) {
    ok: Parsed,
    err: errors.Error,
};

pub fn parseResponses(allocator: std.mem.Allocator, body: std.json.Value) Outcome {
    if (jsonx.obj(body) == null) return fail("JSON object body is required");
    if (rejectUnsupportedResponses(body)) |err| return .{ .err = err };

    const model = jsonx.getStr(body, "model") orelse return fail("model is required");
    if (std.mem.trim(u8, model, " \t").len == 0) return fail("model is required");
    if (jsonx.get(body, "input") == null) {
        if (jsonx.get(body, "messages") != null) {
            return fail("Responses requires input; use /v1/chat/completions for messages");
        }
        return fail("input is required");
    }

    var system = std.ArrayList(u8).empty;
    var flatten = std.ArrayList(u8).empty;
    var last_user = std.ArrayList(u8).empty;
    var tools_list = std.ArrayList(Tool).empty;
    var continuation = std.ArrayList(ToolResult).empty;
    var all_outputs = std.ArrayList(ToolResult).empty;
    var trigger = false;
    var token: ?[]const u8 = null;
    var images = std.ArrayList(Image).empty;

    if (jsonx.getStr(body, "instructions")) |s| appendLine(&system, allocator, s) catch return oom();
    if (jsonx.getStr(body, "system")) |s| appendLine(&system, allocator, s) catch return oom();

    const input = jsonx.get(body, "input").?;
    if (jsonx.asStr(input)) |text| {
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return fail("input must be a non-empty string or item array");
        appendLine(&last_user, allocator, text) catch return oom();
        appendNamed(&flatten, allocator, "user", text) catch return oom();
    } else if (jsonx.asArray(input)) |items| {
        if (items.len == 0) return fail("input must be a non-empty string or item array");
        for (items) |item| {
            const typ = itemType(item) orelse return fail("input item must include type");
            if (isUnsupportedMedia(typ)) return failAlloc(allocator, "{s} is not supported", .{typ});
            if (std.mem.eql(u8, typ, "input_image") or std.mem.eql(u8, typ, "image_url") or std.mem.eql(u8, typ, "image")) {
                continuation.clearRetainingCapacity();
                switch (parseImagePart(allocator, item)) {
                    .skip => {},
                    .ok => |img| {
                        images.append(allocator, img) catch return oom();
                        appendNamed(&flatten, allocator, "user", "[image]") catch return oom();
                    },
                    .err => |e| return .{ .err = e },
                }
                continue;
            }
            if (std.mem.eql(u8, typ, "compaction_trigger")) {
                // Node flushResults(): only the trailing function_call_output batch is live continuation.
                continuation.clearRetainingCapacity();
                trigger = true;
                continue;
            }
            if (std.mem.eql(u8, typ, "compaction")) {
                continuation.clearRetainingCapacity();
                token = jsonx.getStr(item, "encrypted_content") orelse {
                    return fail("compaction item must include encrypted_content");
                };
                last_user.clearRetainingCapacity();
                continue;
            }
            if (std.mem.eql(u8, typ, "function_call_output") or std.mem.eql(u8, typ, "custom_tool_call_output") or std.mem.eql(u8, typ, "tool_result")) {
                const taken = takeOutput(allocator, item) orelse return fail("tool call output must include call_id");
                continuation.append(allocator, taken) catch return oom();
                all_outputs.append(allocator, taken) catch return oom();
                appendNamed(&flatten, allocator, "tool_result", taken.output) catch return oom();
                continue;
            }
            if (std.mem.eql(u8, typ, "function_call") or std.mem.eql(u8, typ, "custom_tool_call")) {
                continuation.clearRetainingCapacity();
                const name = jsonx.getStr(item, "name") orelse "";
                const args = jsonx.getStr(item, "arguments") orelse jsonx.getStr(item, "input") orelse "";
                appendNamed(&flatten, allocator, "assistant_tool", name) catch return oom();
                appendLine(&flatten, allocator, args) catch return oom();
                continue;
            }
            if (std.mem.eql(u8, typ, "reasoning")) {
                continuation.clearRetainingCapacity();
                continue;
            }
            if (std.mem.eql(u8, typ, "additional_tools")) {
                if (jsonx.asArray(jsonx.get(item, "tools") orelse .null)) |more| {
                    for (more) |t| parseAdditionalTool(allocator, t, &tools_list) catch |err| {
                        return switch (err) {
                            error.OutOfMemory => oom(),
                            else => fail("unsupported additional_tools type; only client-executed function, custom, and namespace tools are supported"),
                        };
                    };
                } else return fail("additional_tools.tools must be an array");
                continue;
            }
            const role = jsonx.getStr(item, "role");
            const text = jsonx.collectText(jsonx.get(item, "content") orelse jsonx.get(item, "text") orelse item, allocator) catch return oom();
            if (role != null and (std.mem.eql(u8, role.?, "system") or std.mem.eql(u8, role.?, "developer"))) {
                appendLine(&system, allocator, text) catch return oom();
                continue;
            }
            if (std.mem.eql(u8, typ, "input_text") or role == null or std.mem.eql(u8, role.?, "user")) {
                const content_val = jsonx.get(item, "content") orelse jsonx.get(item, "text") orelse item;
                const nested = switch (scanUserContent(allocator, content_val, &all_outputs, &images)) {
                    .ok => |s| s,
                    .err => |e| return .{ .err = e },
                };
                if (nested.results.len > 0 and nested.has_text) {
                    return fail("mixed new text and tool_result in the latest user turn is not allowed");
                }
                if (nested.results.len > 0) {
                    // User turn that is only tool_result blocks is live continuation.
                    continuation.clearRetainingCapacity();
                    continuation.appendSlice(allocator, nested.results) catch return oom();
                    for (nested.results) |r| {
                        appendNamed(&flatten, allocator, "tool_result", r.output) catch return oom();
                    }
                    continue;
                }
                // Later user/message after historical function_call_output is a completed
                // follow-up (Node flushResults), not a mixed latest turn.
                continuation.clearRetainingCapacity();
                last_user.clearRetainingCapacity();
                appendLine(&last_user, allocator, text) catch return oom();
                appendNamed(&flatten, allocator, "user", text) catch return oom();
                continue;
            }
            if (std.mem.eql(u8, role.?, "assistant")) {
                continuation.clearRetainingCapacity();
                appendNamed(&flatten, allocator, "assistant", text) catch return oom();
                continue;
            }
            return failAlloc(allocator, "unsupported input item type: {s}", .{typ});
        }
    } else {
        return fail("input must be a non-empty string or item array");
    }

    if (jsonx.asArray(jsonx.get(body, "tools") orelse .null)) |listed| {
        for (listed) |t| {
            parseResponsesTool(allocator, t, &tools_list) catch {
                const typ = jsonx.getStr(t, "type") orelse "unknown";
                return failAlloc(allocator, "unsupported Responses tool type: {s}; hosted tools (web_search, file_search, x_search, computer, shell, apply_patch) are not implemented", .{typ});
            };
        }
    }

    if (last_user.items.len == 0 and continuation.items.len == 0 and !trigger) {
        if (token != null) return fail("input must include a user message after compact context, or a compaction_trigger");
        return fail("input must include a user message or function_call_output");
    }

    const choice = switch (toolChoiceOf(body)) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };

    const system_text = system.toOwnedSlice(allocator) catch return oom();
    if (system_text.len > 0) {
        var prefixed = std.ArrayList(u8).empty;
        appendNamed(&prefixed, allocator, "system", system_text) catch return oom();
        prefixed.appendSlice(allocator, flatten.items) catch return oom();
        flatten.deinit(allocator);
        flatten = prefixed;
    }

    return .{ .ok = .{
        .kind = .responses,
        .model = std.mem.trim(u8, model, " \t"),
        .upstream_model = models.upstreamCursorModelId(std.mem.trim(u8, model, " \t")),
        .stream = jsonx.isTrue(body, "stream"),
        .system_text = system_text,
        .last_user_text = last_user.toOwnedSlice(allocator) catch return oom(),
        .flatten_text = flatten.toOwnedSlice(allocator) catch return oom(),
        .tools = tools_list.toOwnedSlice(allocator) catch return oom(),
        .continuation = continuation.toOwnedSlice(allocator) catch return oom(),
        .all_outputs = all_outputs.toOwnedSlice(allocator) catch return oom(),
        .compaction_trigger = trigger or jsonx.isTrue(body, "compaction_trigger"),
        .compaction_token = token,
        .include_usage = true,
        .effort = effortOf(body),
        .images = images.toOwnedSlice(allocator) catch return oom(),
        .tool_choice = choice.kind,
        .tool_choice_name = choice.name,
        .parallel_tools = choice.parallel,
        .cursor_params_json = cursorParamsOf(body),
        .raw = body,
    } };
}

pub fn parseMessages(allocator: std.mem.Allocator, body: std.json.Value) Outcome {
    if (jsonx.obj(body) == null) return fail("JSON object body is required");
    const model = jsonx.getStr(body, "model") orelse return fail("model is required");
    const messages = jsonx.asArray(jsonx.get(body, "messages") orelse .null) orelse {
        return fail("messages must be a non-empty array");
    };
    if (messages.len == 0) return fail("messages must be a non-empty array");
    return parseTranscript(allocator, .messages, body, model, messages, jsonx.get(body, "system"));
}

pub fn parseChat(allocator: std.mem.Allocator, body: std.json.Value) Outcome {
    if (jsonx.obj(body) == null) return fail("JSON object body is required");
    if (jsonx.get(body, "n")) |n| {
        const ok = switch (n) {
            .integer => |i| i == 1,
            .float => |f| f == 1,
            else => false,
        };
        if (!ok) return fail("n must be 1");
    }
    const model = jsonx.getStr(body, "model") orelse return fail("model is required");
    const messages = jsonx.asArray(jsonx.get(body, "messages") orelse .null) orelse {
        return fail("messages must be a non-empty array");
    };
    if (messages.len == 0) return fail("messages must be a non-empty array");
    var parsed = parseTranscript(allocator, .chat, body, model, messages, jsonx.get(body, "system"));
    switch (parsed) {
        .ok => |*p| {
            if (jsonx.get(body, "stream_options")) |opts| {
                p.include_usage = jsonx.isTrue(opts, "include_usage");
            } else p.include_usage = false;
        },
        .err => {},
    }
    return parsed;
}

fn parseTranscript(
    allocator: std.mem.Allocator,
    kind: Kind,
    body: std.json.Value,
    model: []const u8,
    messages: []std.json.Value,
    system_field: ?std.json.Value,
) Outcome {
    var system = std.ArrayList(u8).empty;
    var flatten = std.ArrayList(u8).empty;
    var last_user = std.ArrayList(u8).empty;
    var continuation = std.ArrayList(ToolResult).empty;
    var tools_list = std.ArrayList(Tool).empty;
    var all_outputs = std.ArrayList(ToolResult).empty;
    var images = std.ArrayList(Image).empty;

    if (system_field) |sys| {
        const text = jsonx.collectText(sys, allocator) catch return oom();
        appendLine(&system, allocator, text) catch return oom();
    }

    for (messages) |msg| {
        const role = jsonx.getStr(msg, "role") orelse return fail("each message must be an object");
        if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "developer")) {
            const text = jsonx.collectText(jsonx.get(msg, "content") orelse .null, allocator) catch return oom();
            appendLine(&system, allocator, text) catch return oom();
            continue;
        }
        if (std.mem.eql(u8, role, "tool") or std.mem.eql(u8, role, "function")) {
            const call_id = jsonx.getStr(msg, "tool_call_id") orelse jsonx.getStr(msg, "call_id") orelse jsonx.getStr(msg, "id") orelse {
                return fail("trailing tool message requires tool_call_id, call_id, or id");
            };
            const output = jsonx.collectText(jsonx.get(msg, "content") orelse .null, allocator) catch return oom();
            const taken: ToolResult = .{ .call_id = call_id, .output = output };
            continuation.append(allocator, taken) catch return oom();
            all_outputs.append(allocator, taken) catch return oom();
            appendNamed(&flatten, allocator, "tool_result", output) catch return oom();
            continue;
        }
        const content_val = jsonx.get(msg, "content") orelse .null;
        if (std.mem.eql(u8, role, "user")) {
            if (jsonx.asArray(content_val)) |parts| {
                for (parts) |part| {
                    switch (parseImagePart(allocator, part)) {
                        .skip => {},
                        .ok => |img| {
                            images.append(allocator, img) catch return oom();
                            appendNamed(&flatten, allocator, "user", "[image]") catch return oom();
                        },
                        .err => |e| return .{ .err = e },
                    }
                }
            }
            const text = jsonx.collectText(content_val, allocator) catch return oom();
            last_user.clearRetainingCapacity();
            appendLine(&last_user, allocator, text) catch return oom();
            continuation.clearRetainingCapacity();
            appendNamed(&flatten, allocator, "user", text) catch return oom();
            continue;
        }
        const text = jsonx.collectText(content_val, allocator) catch return oom();
        if (std.mem.eql(u8, role, "assistant")) {
            continuation.clearRetainingCapacity();
            appendNamed(&flatten, allocator, "assistant", text) catch return oom();
            if (jsonx.asArray(jsonx.get(msg, "tool_calls") orelse .null)) |calls| {
                for (calls) |call| {
                    const name = jsonx.getStr(jsonx.get(call, "function") orelse call, "name") orelse "";
                    appendNamed(&flatten, allocator, "assistant_tool", name) catch return oom();
                }
            }
            continue;
        }
        return failAlloc(allocator, "unsupported message.role: {s}", .{role});
    }

    if (jsonx.asArray(jsonx.get(body, "tools") orelse .null)) |listed| {
        for (listed) |t| {
            parseChatOrMessageTool(allocator, t, &tools_list) catch return fail("tool name must match [a-zA-Z0-9_-]{1,128}");
        }
    }

    const choice = switch (toolChoiceOf(body)) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };

    const system_text = system.toOwnedSlice(allocator) catch return oom();
    if (system_text.len > 0) {
        var prefixed = std.ArrayList(u8).empty;
        appendNamed(&prefixed, allocator, "system", system_text) catch return oom();
        prefixed.appendSlice(allocator, flatten.items) catch return oom();
        flatten.deinit(allocator);
        flatten = prefixed;
    }

    return .{ .ok = .{
        .kind = kind,
        .model = std.mem.trim(u8, model, " \t"),
        .upstream_model = models.upstreamCursorModelId(std.mem.trim(u8, model, " \t")),
        .stream = jsonx.isTrue(body, "stream"),
        .system_text = system_text,
        .last_user_text = last_user.toOwnedSlice(allocator) catch return oom(),
        .flatten_text = flatten.toOwnedSlice(allocator) catch return oom(),
        .tools = tools_list.toOwnedSlice(allocator) catch return oom(),
        .continuation = continuation.toOwnedSlice(allocator) catch return oom(),
        .all_outputs = all_outputs.toOwnedSlice(allocator) catch return oom(),
        .compaction_trigger = false,
        .compaction_token = null,
        .include_usage = kind != .chat,
        .effort = effortOf(body),
        .images = images.toOwnedSlice(allocator) catch return oom(),
        .tool_choice = choice.kind,
        .tool_choice_name = choice.name,
        .parallel_tools = choice.parallel,
        .cursor_params_json = cursorParamsOf(body),
        .raw = body,
    } };
}

/// Live tool results for a pending Cursor turn: outputs whose call_id is still
/// unresolved. Historical function_call_outputs stay in the transcript.
/// Grok often interleaves function_call with function_call_output for parallel
/// tools, so the trailing batch may be length 1 while all N results are in the
/// request — Node gold's last-user-message rule drops the siblings.
pub fn selectPendingResults(
    allocator: std.mem.Allocator,
    outputs: []const ToolResult,
    pending: []const []const u8,
) ![]ToolResult {
    var by_id = std.StringHashMap([]const u8).init(allocator);
    for (outputs) |o| {
        try by_id.put(o.call_id, o.output);
    }
    var out = std.ArrayList(ToolResult).empty;
    for (pending) |id| {
        if (by_id.get(id)) |output| {
            try out.append(allocator, .{ .call_id = id, .output = output });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Ids Grok must fulfill this POST: the batch already sent on SSE, not
/// CallCustomTool waiters that arrived after that snapshot. Late waiters
/// belong on the next waitBoundary. Fall back to hub unresolved when no
/// batch has been published yet.
pub fn continuationRequiredIds(published: []const []const u8, unresolved: []const []const u8) []const []const u8 {
    return if (published.len > 0) published else unresolved;
}

/// Orphan function_call_output (smoke / fail-closed) has no extra transcript.
/// A Grok retry after hitch restart still has historical outputs or a user turn;
/// Node gold recoverFromTranscript instead of 422 unknown tool_use_id.
pub fn canRecoverUnknownContinuation(p: Parsed) bool {
    if (p.last_user_text.len > 0) return true;
    return p.all_outputs.len > p.continuation.len;
}

/// When to leave waitBoundary.
/// - tools in flight: settle ~160ms, or ~40ms after the bridge stream has ended
/// - no tools, stream ended: wait ~160ms for a late CallCustomTool, then end_turn
/// - no tools, still streaming: keep waiting
pub fn waitBoundaryDone(n: usize, finished: bool, stable_ticks: u32, late_ticks: u32) bool {
    if (n > 0) {
        if (finished) return stable_ticks >= 2;
        return stable_ticks >= 8;
    }
    return finished and late_ticks >= 8;
}

/// Cursor Send after a tool resume can sit with no waiters and no end event.
/// Tools in flight (n > 0) wait for Grok. Finished streams use waitBoundaryDone.
pub fn waitBoundaryIdleTimedOut(n: usize, finished: bool, idle_ms: i64, limit_ms: i64) bool {
    if (n > 0 or finished) return false;
    return idle_ms > limit_ms;
}

const UserContentScan = struct {
    results: []ToolResult,
    has_text: bool,
};

const ImageOutcome = union(enum) {
    skip,
    ok: Image,
    err: errors.Error,
};

const Choice = struct {
    kind: ToolChoiceKind = .auto,
    name: []const u8 = "",
    parallel: bool = true,
};

fn scanUserContent(
    allocator: std.mem.Allocator,
    content: std.json.Value,
    all_outputs: *std.ArrayList(ToolResult),
    images: *std.ArrayList(Image),
) union(enum) { ok: UserContentScan, err: errors.Error } {
    const parts = jsonx.asArray(content) orelse return .{ .ok = .{ .results = &.{}, .has_text = false } };
    var results = std.ArrayList(ToolResult).empty;
    var has_text = false;
    for (parts) |part| {
        if (takeOutput(allocator, part)) |o| {
            all_outputs.append(allocator, o) catch return .{ .err = errors.upstreamError("out of memory") };
            results.append(allocator, o) catch return .{ .err = errors.upstreamError("out of memory") };
            continue;
        }
        switch (parseImagePart(allocator, part)) {
            .skip => {},
            .ok => |img| {
                images.append(allocator, img) catch return .{ .err = errors.upstreamError("out of memory") };
                continue;
            },
            .err => |e| return .{ .err = e },
        }
        const t = jsonx.collectText(part, allocator) catch return .{ .err = errors.upstreamError("out of memory") };
        if (std.mem.trim(u8, t, " \t\r\n").len > 0) has_text = true;
    }
    return .{ .ok = .{
        .results = results.toOwnedSlice(allocator) catch return .{ .err = errors.upstreamError("out of memory") },
        .has_text = has_text,
    } };
}

fn parseImagePart(allocator: std.mem.Allocator, part: std.json.Value) ImageOutcome {
    _ = allocator;
    const typ = jsonx.getStr(part, "type") orelse return .skip;
    if (!std.mem.eql(u8, typ, "input_image") and !std.mem.eql(u8, typ, "image_url") and !std.mem.eql(u8, typ, "image")) {
        return .skip;
    }
    if (jsonx.get(part, "file_id")) |v| {
        if (v != .null) return .{ .err = errors.invalidRequest("input_image.file_id is not supported; use a base64 data URL") };
    }
    if (jsonx.get(part, "source")) |src| {
        if (jsonx.getStr(src, "data")) |data| {
            const mime = jsonx.getStr(src, "media_type") orelse "image/png";
            if (data.len == 0) return .{ .err = errors.invalidRequest("input_image.image_url must be a base64 data URL; remote URLs are not fetched") };
            return .{ .ok = .{ .mime_type = mime, .data = data } };
        }
    }
    const url = readImageUrl(part) orelse {
        return .{ .err = errors.invalidRequest("input_image requires image_url") };
    };
    if (std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://") or std.mem.startsWith(u8, url, "//")) {
        return .{ .err = errors.invalidRequest("input_image.image_url must be a base64 data URL; remote URLs are not fetched") };
    }
    const parsed = parseDataUrl(url) orelse {
        return .{ .err = errors.invalidRequest("input_image.image_url must be a base64 data URL; remote URLs are not fetched") };
    };
    return .{ .ok = .{ .mime_type = parsed.mime, .data = parsed.data } };
}

fn readImageUrl(part: std.json.Value) ?[]const u8 {
    if (jsonx.getStr(part, "image_url")) |s| return s;
    if (jsonx.get(part, "image_url")) |v| {
        if (jsonx.getStr(v, "url")) |s| return s;
    }
    if (jsonx.getStr(part, "image")) |s| return s;
    if (jsonx.getStr(part, "url")) |s| return s;
    return null;
}

fn parseDataUrl(url: []const u8) ?struct { mime: []const u8, data: []const u8 } {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "data:")) return null;
    const rest = trimmed["data:".len..];
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    const meta = rest[0..comma];
    const data = rest[comma + 1 ..];
    if (std.mem.indexOf(u8, meta, "base64") == null) return null;
    var mime: []const u8 = "image/png";
    if (std.mem.indexOfScalar(u8, meta, ';')) |semi| {
        const m = std.mem.trim(u8, meta[0..semi], " \t");
        if (m.len > 0) mime = m;
    } else {
        const m = std.mem.trim(u8, meta, " \t");
        if (m.len > 0 and !std.ascii.eqlIgnoreCase(m, "base64")) mime = m;
    }
    if (data.len == 0) return null;
    return .{ .mime = mime, .data = data };
}

fn toolChoiceOf(body: std.json.Value) union(enum) { ok: Choice, err: errors.Error } {
    var choice: Choice = .{};
    if (jsonx.getBool(body, "parallel_tool_calls")) |p| choice.parallel = p;
    if (jsonx.isTrue(body, "disable_parallel_tool_use")) choice.parallel = false;
    const tc = jsonx.get(body, "tool_choice") orelse return .{ .ok = choice };
    if (jsonx.asStr(tc)) |s| {
        if (std.mem.eql(u8, s, "auto")) return .{ .ok = choice };
        if (std.mem.eql(u8, s, "required") or std.mem.eql(u8, s, "any")) {
            choice.kind = .required;
            return .{ .ok = choice };
        }
        if (std.mem.eql(u8, s, "none")) {
            return .{ .err = errors.invalidRequest("tool_choice none is not supported") };
        }
    }
    if (jsonx.getStr(tc, "type")) |typ| {
        if (std.mem.eql(u8, typ, "none")) {
            return .{ .err = errors.invalidRequest("tool_choice none is not supported") };
        }
        if (std.mem.eql(u8, typ, "function") or std.mem.eql(u8, typ, "tool")) {
            const name = jsonx.getStr(jsonx.get(tc, "function") orelse tc, "name") orelse jsonx.getStr(tc, "name") orelse {
                return .{ .err = errors.invalidRequest("tool_choice function requires name") };
            };
            choice.kind = .named;
            choice.name = name;
            return .{ .ok = choice };
        }
        if (std.mem.eql(u8, typ, "any") or std.mem.eql(u8, typ, "required")) {
            choice.kind = .required;
            return .{ .ok = choice };
        }
    }
    return .{ .ok = choice };
}

fn cursorParamsOf(body: std.json.Value) []const u8 {
    if (jsonx.get(body, "cursor_model_params")) |_| {
        return "present";
    }
    return "";
}

fn takeOutput(allocator: std.mem.Allocator, item: std.json.Value) ?ToolResult {
    const typ = jsonx.getStr(item, "type");
    const is_out = if (typ) |t|
        std.mem.eql(u8, t, "function_call_output") or
            std.mem.eql(u8, t, "custom_tool_call_output") or
            std.mem.eql(u8, t, "tool_result")
    else
        (jsonx.get(item, "call_id") != null and jsonx.get(item, "output") != null) or
            jsonx.get(item, "tool_call_id") != null;
    if (!is_out) return null;
    const call_id = jsonx.getStr(item, "call_id") orelse jsonx.getStr(item, "tool_call_id") orelse return null;
    const output = toolOutputText(allocator, jsonx.get(item, "output") orelse jsonx.get(item, "content")) catch return null;
    return .{ .call_id = call_id, .output = output };
}

pub fn estimateInputTokens(parsed: Parsed) u32 {
    const chars = parsed.system_text.len + parsed.flatten_text.len;
    const text = @as(u32, @intCast((chars + 3) / 4));
    const overhead = @as(u32, @intCast(parsed.tools.len * 8 + 4));
    const images = @as(u32, @intCast(parsed.images.len * 1_600));
    return @max(@as(u32, 1), text + overhead + images);
}

fn parseAdditionalTool(allocator: std.mem.Allocator, tool: std.json.Value, tools: *std.ArrayList(Tool)) !void {
    const typ = jsonx.getStr(tool, "type") orelse "function";
    if (std.mem.eql(u8, typ, "namespace")) return parseNamespaceTools(allocator, tool, tools);
    return parseResponsesTool(allocator, tool, tools);
}

fn parseNamespaceTools(allocator: std.mem.Allocator, tool: std.json.Value, tools: *std.ArrayList(Tool)) !void {
    const ns = jsonx.getStr(tool, "name") orelse return error.BadTool;
    if (ns.len == 0 or ns.len > 96 or !validToolName(ns)) return error.BadTool;
    const children = jsonx.asArray(jsonx.get(tool, "tools") orelse .null) orelse return error.BadTool;
    if (children.len == 0) return error.BadTool;
    for (children) |child| {
        try parseResponsesTool(allocator, child, tools);
        var added = &tools.items[tools.items.len - 1];
        added.namespace = ns;
        if (std.mem.startsWith(u8, added.name, "mcp__") or qualifiedAlready(ns, added.name)) {
            added.sdk_name = added.name;
        } else {
            added.sdk_name = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ ns, added.name });
        }
        if (!validToolName(added.sdk_name)) return error.BadTool;
        if (duplicateSdkName(tools.items[0 .. tools.items.len - 1], added.sdk_name)) {
            _ = tools.pop();
        }
    }
}

fn qualifiedAlready(namespace: []const u8, name: []const u8) bool {
    if (name.len < namespace.len + 2) return false;
    if (!std.mem.startsWith(u8, name, namespace)) return false;
    return name[namespace.len] == '_' and name[namespace.len + 1] == '_';
}

fn duplicateSdkName(existing: []const Tool, sdk_name: []const u8) bool {
    for (existing) |t| {
        if (std.mem.eql(u8, t.sdk_name, sdk_name) or std.mem.eql(u8, t.name, sdk_name)) return true;
    }
    return false;
}

fn parseResponsesTool(allocator: std.mem.Allocator, tool: std.json.Value, tools: *std.ArrayList(Tool)) !void {
    const typ = jsonx.getStr(tool, "type") orelse "function";
    if (std.mem.eql(u8, typ, "web_search") or std.mem.eql(u8, typ, "file_search") or
        std.mem.eql(u8, typ, "x_search") or std.mem.eql(u8, typ, "computer") or
        std.mem.eql(u8, typ, "shell") or std.mem.eql(u8, typ, "apply_patch"))
    {
        return error.HostedTool;
    }
    if (std.mem.eql(u8, typ, "custom")) {
        const name = jsonx.getStr(tool, "name") orelse return error.BadTool;
        if (!validToolName(name)) return error.BadTool;
        if (duplicateSdkName(tools.items, name)) return;
        try tools.append(allocator, .{
            .name = name,
            .sdk_name = name,
            .description = jsonx.getStr(tool, "description") orelse "",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"input\":{\"type\":\"string\"}},\"required\":[\"input\"]}",
            .kind = .custom,
        });
        return;
    }
    if (!std.mem.eql(u8, typ, "function")) return error.HostedTool;
    const nested = jsonx.get(tool, "function") orelse tool;
    const name = jsonx.getStr(tool, "name") orelse jsonx.getStr(nested, "name") orelse return error.BadTool;
    if (!validToolName(name)) return error.BadTool;
    const schema_json = if (jsonx.get(tool, "parameters") orelse jsonx.get(nested, "parameters")) |schema|
        jsonx.stringify(allocator, schema) catch return error.OutOfMemory
    else
        "{\"type\":\"object\",\"properties\":{}}";
    if (duplicateSdkName(tools.items, name)) return;
    try tools.append(allocator, .{
        .name = name,
        .sdk_name = name,
        .description = jsonx.getStr(tool, "description") orelse jsonx.getStr(nested, "description") orelse "",
        .schema_json = schema_json,
        .kind = .function,
    });
}

fn parseChatOrMessageTool(allocator: std.mem.Allocator, tool: std.json.Value, tools: *std.ArrayList(Tool)) !void {
    const nested = jsonx.get(tool, "function") orelse tool;
    const name = jsonx.getStr(tool, "name") orelse jsonx.getStr(nested, "name") orelse return error.BadTool;
    if (!validToolName(name)) return error.BadTool;
    const schema_json = if (jsonx.get(nested, "parameters") orelse jsonx.get(tool, "input_schema") orelse jsonx.get(nested, "input_schema")) |schema|
        jsonx.stringify(allocator, schema) catch return error.OutOfMemory
    else
        "{\"type\":\"object\",\"properties\":{}}";
    try tools.append(allocator, .{
        .name = name,
        .sdk_name = name,
        .description = jsonx.getStr(nested, "description") orelse jsonx.getStr(tool, "description") orelse "",
        .schema_json = schema_json,
        .kind = .function,
    });
}

fn validToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn rejectUnsupportedResponses(body: std.json.Value) ?errors.Error {
    if (jsonx.get(body, "previous_response_id")) |v| {
        if (v != .null) {
            if (jsonx.asStr(v)) |s| {
                if (s.len > 0) {
                    return errors.invalidRequest("previous_response_id is not supported; use function_call_output.call_id to resume a pending tool turn, or x-cursor-session-id for a completed follow-up");
                }
            } else {
                return errors.invalidRequest("previous_response_id is not supported; use function_call_output.call_id to resume a pending tool turn, or x-cursor-session-id for a completed follow-up");
            }
        }
    }
    if (jsonx.isTrue(body, "store")) return errors.invalidRequest("store=true is not supported");
    if (jsonx.isTrue(body, "background")) return errors.invalidRequest("background mode is not supported");
    if (jsonx.get(body, "conversation")) |v| {
        if (v != .null) return errors.invalidRequest("conversation is not supported");
    }
    if (jsonx.get(body, "include")) |inc| {
        if (jsonx.asArray(inc)) |items| {
            for (items) |item| {
                const s = jsonx.asStr(item) orelse return errors.invalidRequest("include must be an array if provided");
                if (!std.mem.eql(u8, s, "reasoning.encrypted_content")) {
                    return errors.invalidRequest("unsupported include expansion");
                }
            }
        } else if (inc != .null) {
            return errors.invalidRequest("include must be an array if provided");
        }
    }
    return null;
}

fn itemType(item: std.json.Value) ?[]const u8 {
    if (jsonx.getStr(item, "type")) |t| return t;
    if (jsonx.get(item, "role") != null) return "message";
    if (jsonx.get(item, "call_id") != null and jsonx.get(item, "output") != null) return "function_call_output";
    if (jsonx.get(item, "call_id") != null and jsonx.get(item, "name") != null) return "function_call";
    return null;
}

fn isUnsupportedMedia(typ: []const u8) bool {
    const blocked = [_][]const u8{ "input_file", "input_audio", "input_video", "document", "audio", "video", "file" };
    for (blocked) |b| if (std.mem.eql(u8, typ, b)) return true;
    return false;
}

fn toolOutputText(allocator: std.mem.Allocator, output: ?std.json.Value) ![]const u8 {
    const v = output orelse return "";
    if (jsonx.asStr(v)) |s| return s;
    return jsonx.collectText(v, allocator);
}

fn effortOf(body: std.json.Value) ?[]const u8 {
    if (jsonx.getStr(body, "reasoning_effort")) |s| return s;
    if (jsonx.get(body, "reasoning")) |r| return jsonx.getStr(r, "effort");
    return null;
}

fn fail(message: []const u8) Outcome {
    return .{ .err = errors.invalidRequest(message) };
}

fn failAlloc(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Outcome {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return oom();
    return .{ .err = errors.invalidRequest(msg) };
}

fn oom() Outcome {
    return .{ .err = errors.upstreamError("out of memory") };
}

fn appendLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, text);
}

fn appendNamed(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, text: []const u8) !void {
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, ": ");
    try out.appendSlice(allocator, text);
}

test "responses rejects previous_response_id" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"model":"grok-4.6","input":"hi","previous_response_id":"resp_1"}
    , .{});
    defer parsed.deinit();
    const out = parseResponses(std.testing.allocator, parsed.value);
    try std.testing.expectEqual(errors.Code.invalid_request, out.err.code);
}

test "responses rejects store=true" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"model":"grok-4.6","input":"hi","store":true}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("store=true is not supported", parseResponses(std.testing.allocator, parsed.value).err.message);
}

test "responses accepts string input and strips prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"cursor-cidr/grok-4.6","input":"hello","stream":true}
    , .{});
    const out = parseResponses(arena.allocator(), parsed.value);
    try std.testing.expectEqualStrings("cursor-cidr/grok-4.6", out.ok.model);
    try std.testing.expectEqualStrings("grok-4.6", out.ok.upstream_model);
    try std.testing.expectEqualStrings("hello", out.ok.last_user_text);
    try std.testing.expect(out.ok.stream);
}

test "additional_tools namespace is qualified for the SDK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","input":[{"type":"input_text","text":"hi"},{"type":"additional_tools","tools":[{"type":"namespace","name":"linear","tools":[{"type":"function","name":"list_issues","parameters":{"type":"object"}}]}]}]}
    , .{});
    const out = parseResponses(arena.allocator(), parsed.value);
    try std.testing.expectEqual(@as(usize, 1), out.ok.tools.len);
    try std.testing.expectEqualStrings("list_issues", out.ok.tools[0].name);
    try std.testing.expectEqualStrings("linear__list_issues", out.ok.tools[0].sdk_name);
    try std.testing.expectEqualStrings("linear", out.ok.tools[0].namespace);
}

test "responses continuation from function_call_output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","input":[{"type":"function_call_output","call_id":"call_1","output":"ok"}]}
    , .{});
    const out = parseResponses(arena.allocator(), parsed.value);
    try std.testing.expectEqual(@as(usize, 1), out.ok.continuation.len);
    try std.testing.expectEqualStrings("call_1", out.ok.continuation[0].call_id);
}

test "responses continuation keeps only the trailing function_call_output batch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","input":[{"type":"input_text","text":"hi"},{"type":"function_call","call_id":"call-05694079-2a65-43aa-89ce-d7a82c38f262-3","name":"list_dir","arguments":"{}"},{"type":"function_call_output","call_id":"call-05694079-2a65-43aa-89ce-d7a82c38f262-3","output":"ok"},{"type":"function_call","call_id":"call-5574c341-8c01-4501-8631-fa5859cdbd0a-4","name":"write","arguments":"{}"},{"type":"function_call_output","call_id":"call-5574c341-8c01-4501-8631-fa5859cdbd0a-4","output":"wrote"}]}
    , .{});
    const out = parseResponses(arena.allocator(), parsed.value);
    try std.testing.expectEqual(@as(usize, 1), out.ok.continuation.len);
    try std.testing.expectEqualStrings("call-5574c341-8c01-4501-8631-fa5859cdbd0a-4", out.ok.continuation[0].call_id);
}

test "responses continuation keeps parallel trailing function_call_outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","input":[{"type":"function_call","call_id":"c1","name":"list_dir","arguments":"{}"},{"type":"function_call","call_id":"c2","name":"write","arguments":"{}"},{"type":"function_call_output","call_id":"c1","output":"a"},{"type":"function_call_output","call_id":"c2","output":"b"}]}
    , .{});
    const out = parseResponses(arena.allocator(), parsed.value);
    try std.testing.expectEqual(@as(usize, 2), out.ok.continuation.len);
    try std.testing.expectEqualStrings("c1", out.ok.continuation[0].call_id);
    try std.testing.expectEqualStrings("c2", out.ok.continuation[1].call_id);
    try std.testing.expectEqual(@as(usize, 2), out.ok.all_outputs.len);
}

test "interleaved parallel function_call_outputs keep all ids in all_outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","input":[{"type":"function_call","call_id":"c1","name":"web_search","arguments":"{}"},{"type":"function_call_output","call_id":"c1","output":"a"},{"type":"function_call","call_id":"c2","name":"web_search","arguments":"{}"},{"type":"function_call_output","call_id":"c2","output":"b"},{"type":"function_call","call_id":"c3","name":"web_search","arguments":"{}"},{"type":"function_call_output","call_id":"c3","output":"c"},{"type":"function_call","call_id":"c4","name":"read_file","arguments":"{}"},{"type":"function_call_output","call_id":"c4","output":"d"}]}
    , .{});
    const out = parseResponses(arena.allocator(), parsed.value);
    try std.testing.expectEqual(@as(usize, 1), out.ok.continuation.len);
    try std.testing.expectEqualStrings("c4", out.ok.continuation[0].call_id);
    try std.testing.expectEqual(@as(usize, 4), out.ok.all_outputs.len);
    const pending = [_][]const u8{ "c1", "c2", "c3", "c4" };
    const live = try selectPendingResults(arena.allocator(), out.ok.all_outputs, &pending);
    try std.testing.expectEqual(@as(usize, 4), live.len);
    try std.testing.expectEqualStrings("a", live[0].output);
    try std.testing.expectEqualStrings("d", live[3].output);
}

test "waitBoundaryDone flushes tools after reasoning and waits for a late CallCustomTool" {
    try std.testing.expect(!waitBoundaryDone(0, false, 0, 0));
    try std.testing.expect(!waitBoundaryDone(0, true, 0, 7));
    try std.testing.expect(waitBoundaryDone(0, true, 0, 8));
    try std.testing.expect(!waitBoundaryDone(1, false, 7, 0));
    try std.testing.expect(waitBoundaryDone(1, false, 8, 0));
    try std.testing.expect(!waitBoundaryDone(2, true, 1, 0));
    try std.testing.expect(waitBoundaryDone(2, true, 2, 0));
}

test "waitBoundaryIdleTimedOut only when Cursor sends nothing" {
    try std.testing.expect(!waitBoundaryIdleTimedOut(1, false, 60_000, 45_000));
    try std.testing.expect(!waitBoundaryIdleTimedOut(0, true, 60_000, 45_000));
    try std.testing.expect(!waitBoundaryIdleTimedOut(0, false, 45_000, 45_000));
    try std.testing.expect(waitBoundaryIdleTimedOut(0, false, 45_001, 45_000));
}

test "continuationRequiredIds uses published batch over later hub waiters" {
    const published = [_][]const u8{ "a", "b" };
    const unresolved = [_][]const u8{ "a", "b", "late" };
    const required = continuationRequiredIds(&published, &unresolved);
    try std.testing.expectEqual(@as(usize, 2), required.len);
    try std.testing.expectEqualStrings("a", required[0]);
    try std.testing.expectEqualStrings("b", required[1]);
    const empty: []const []const u8 = &.{};
    const fallback = continuationRequiredIds(empty, &unresolved);
    try std.testing.expectEqual(@as(usize, 3), fallback.len);
}

test "canRecoverUnknownContinuation needs history beyond the live batch" {
    var one = [_]ToolResult{.{ .call_id = "x", .output = "nope" }};
    const orphan = testParsed(one[0..], one[0..], "");
    try std.testing.expect(!canRecoverUnknownContinuation(orphan));
    var live = [_]ToolResult{.{ .call_id = "new", .output = "b" }};
    var hist = [_]ToolResult{
        .{ .call_id = "old", .output = "a" },
        .{ .call_id = "new", .output = "b" },
    };
    const history = testParsed(live[0..], hist[0..], "");
    try std.testing.expect(canRecoverUnknownContinuation(history));
    const follow_up = testParsed(one[0..], one[0..], "next question");
    try std.testing.expect(canRecoverUnknownContinuation(follow_up));
}

fn testParsed(continuation: []ToolResult, all_outputs: []ToolResult, last_user: []const u8) Parsed {
    return .{
        .kind = .responses,
        .model = "x",
        .upstream_model = "x",
        .stream = true,
        .system_text = "",
        .last_user_text = last_user,
        .flatten_text = last_user,
        .tools = &.{},
        .continuation = continuation,
        .all_outputs = all_outputs,
        .compaction_trigger = false,
        .compaction_token = null,
        .include_usage = false,
        .effort = null,
        .raw = .null,
    };
}

test "selectPendingResults ignores historical outputs that are not pending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outputs = [_]ToolResult{
        .{ .call_id = "old", .output = "stale" },
        .{ .call_id = "new", .output = "fresh" },
    };
    const pending = [_][]const u8{"new"};
    const live = try selectPendingResults(arena.allocator(), &outputs, &pending);
    try std.testing.expectEqual(@as(usize, 1), live.len);
    try std.testing.expectEqualStrings("new", live[0].call_id);
}

test "user message of only tool_result blocks is continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","input":[{"type":"function_call","call_id":"c1","name":"a","arguments":"{}"},{"type":"function_call","call_id":"c2","name":"b","arguments":"{}"},{"type":"message","role":"user","content":[{"type":"function_call_output","call_id":"c1","output":"one"},{"type":"function_call_output","call_id":"c2","output":"two"}]}]}
    , .{});
    const out = parseResponses(arena.allocator(), parsed.value);
    try std.testing.expectEqual(@as(usize, 2), out.ok.continuation.len);
    try std.testing.expectEqual(@as(usize, 2), out.ok.all_outputs.len);
    try std.testing.expectEqualStrings("c1", out.ok.continuation[0].call_id);
    try std.testing.expectEqualStrings("c2", out.ok.continuation[1].call_id);
}

test "responses follow-up after historical function_call_output is not mixed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","input":[{"type":"input_text","text":"hi"},{"type":"function_call","call_id":"call_old","name":"write","arguments":"{}"},{"type":"function_call_output","call_id":"call_old","output":"wrote"},{"type":"message","role":"assistant","content":"done"},{"type":"message","role":"user","content":"run it"}]}
    , .{});
    const out = parseResponses(arena.allocator(), parsed.value);
    try std.testing.expectEqual(@as(usize, 0), out.ok.continuation.len);
    try std.testing.expectEqualStrings("run it", out.ok.last_user_text);
}

test "responses continuation after a later user keeps only the trailing batch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","input":[{"type":"message","role":"user","content":"old request"},{"type":"function_call","call_id":"call_old","name":"lookup","arguments":"{}"},{"type":"function_call_output","call_id":"call_old","output":"old result"},{"type":"message","role":"assistant","content":"old answer"},{"type":"message","role":"user","content":"latest request"},{"type":"function_call","call_id":"call_latest","name":"lookup","arguments":"{}"},{"type":"function_call_output","call_id":"call_latest","output":"latest result"}]}
    , .{});
    const out = parseResponses(arena.allocator(), parsed.value);
    try std.testing.expectEqual(@as(usize, 1), out.ok.continuation.len);
    try std.testing.expectEqualStrings("call_latest", out.ok.continuation[0].call_id);
    try std.testing.expectEqualStrings("latest request", out.ok.last_user_text);
}

test "messages continuation keeps only trailing tool results after the last assistant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"list_dir"}}]},{"role":"tool","tool_call_id":"c1","content":"ok"},{"role":"assistant","content":"","tool_calls":[{"id":"c2","type":"function","function":{"name":"write"}}]},{"role":"tool","tool_call_id":"c2","content":"wrote"}]}
    , .{});
    const out = parseMessages(arena.allocator(), parsed.value);
    try std.testing.expectEqual(@as(usize, 1), out.ok.continuation.len);
    try std.testing.expectEqualStrings("c2", out.ok.continuation[0].call_id);
}

test "messages requires model and messages" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"messages\":[]}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("model is required", parseMessages(std.testing.allocator, parsed.value).err.message);
}

test "responses base64 input_image is accepted and remote URL is 422" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ok_raw = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"what is this"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]}]}
    , .{});
    const ok = parseResponses(arena.allocator(), ok_raw.value);
    try std.testing.expectEqual(@as(usize, 1), ok.ok.images.len);
    try std.testing.expectEqualStrings("image/png", ok.ok.images[0].mime_type);
    try std.testing.expectEqualStrings("AAAA", ok.ok.images[0].data);

    const bad_raw = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","input":[{"type":"input_image","image_url":"https://example.com/x.png"}]}
    , .{});
    const bad = parseResponses(arena.allocator(), bad_raw.value);
    try std.testing.expectEqual(@as(u16, 422), bad.err.http_status);
    try std.testing.expect(std.mem.indexOf(u8, bad.err.message, "base64 data URL") != null);
}

test "chat image_url remote is 422 and tool_choice none is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const img = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://x"}}]}]}
    , .{});
    try std.testing.expectEqual(@as(u16, 422), parseChat(arena.allocator(), img.value).err.http_status);

    const none = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"model":"grok-4.6","messages":[{"role":"user","content":"hi"}],"tool_choice":"none"}
    , .{});
    try std.testing.expectEqual(@as(u16, 422), parseChat(arena.allocator(), none.value).err.http_status);
}
