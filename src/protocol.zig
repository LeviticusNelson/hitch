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
    compaction_trigger: bool,
    compaction_token: ?[]const u8,
    include_usage: bool,
    effort: ?[]const u8,
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
    var trigger = false;
    var token: ?[]const u8 = null;

    if (jsonx.getStr(body, "instructions")) |s| appendLine(&system, allocator, s) catch return oom();
    if (jsonx.getStr(body, "system")) |s| appendLine(&system, allocator, s) catch return oom();

    const input = jsonx.get(body, "input").?;
    if (jsonx.asStr(input)) |text| {
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return fail("input must be a non-empty string or item array");
        appendLine(&last_user, allocator, text) catch return oom();
        appendNamed(&flatten, allocator, "user", text) catch return oom();
    } else if (jsonx.asArray(input)) |items| {
        if (items.len == 0) return fail("input must be a non-empty string or item array");
        var saw_tool_output = false;
        var saw_later_user = false;
        for (items) |item| {
            const typ = itemType(item) orelse return fail("input item must include type");
            if (isUnsupportedMedia(typ)) return failAlloc(allocator, "{s} is not supported", .{typ});
            if (std.mem.eql(u8, typ, "compaction_trigger")) {
                trigger = true;
                continue;
            }
            if (std.mem.eql(u8, typ, "compaction")) {
                token = jsonx.getStr(item, "encrypted_content") orelse {
                    return fail("compaction item must include encrypted_content");
                };
                last_user.clearRetainingCapacity();
                continue;
            }
            if (std.mem.eql(u8, typ, "function_call_output") or std.mem.eql(u8, typ, "custom_tool_call_output")) {
                const call_id = jsonx.getStr(item, "call_id") orelse return fail("tool call output must include call_id");
                const output = toolOutputText(allocator, jsonx.get(item, "output")) catch return fail("function_call_output.output must be a string or content array");
                continuation.append(allocator, .{ .call_id = call_id, .output = output }) catch return oom();
                appendNamed(&flatten, allocator, "tool_result", output) catch return oom();
                saw_tool_output = true;
                continue;
            }
            if (std.mem.eql(u8, typ, "function_call") or std.mem.eql(u8, typ, "custom_tool_call")) {
                const name = jsonx.getStr(item, "name") orelse "";
                const args = jsonx.getStr(item, "arguments") orelse jsonx.getStr(item, "input") orelse "";
                appendNamed(&flatten, allocator, "assistant_tool", name) catch return oom();
                appendLine(&flatten, allocator, args) catch return oom();
                continue;
            }
            if (std.mem.eql(u8, typ, "reasoning")) {
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
                if (saw_tool_output) saw_later_user = true;
                last_user.clearRetainingCapacity();
                appendLine(&last_user, allocator, text) catch return oom();
                appendNamed(&flatten, allocator, "user", text) catch return oom();
                continue;
            }
            if (std.mem.eql(u8, role.?, "assistant")) {
                appendNamed(&flatten, allocator, "assistant", text) catch return oom();
                continue;
            }
            return failAlloc(allocator, "unsupported input item type: {s}", .{typ});
        }
        if (saw_tool_output and saw_later_user) {
            return fail("function_call_output mixed with a later user/message item");
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
        .compaction_trigger = trigger or jsonx.isTrue(body, "compaction_trigger"),
        .compaction_token = token,
        .include_usage = true,
        .effort = effortOf(body),
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
            continuation.append(allocator, .{ .call_id = call_id, .output = output }) catch return oom();
            appendNamed(&flatten, allocator, "tool_result", output) catch return oom();
            continue;
        }
        const text = jsonx.collectText(jsonx.get(msg, "content") orelse .null, allocator) catch return oom();
        if (std.mem.eql(u8, role, "user")) {
            last_user.clearRetainingCapacity();
            appendLine(&last_user, allocator, text) catch return oom();
            continuation.clearRetainingCapacity();
            appendNamed(&flatten, allocator, "user", text) catch return oom();
            continue;
        }
        if (std.mem.eql(u8, role, "assistant")) {
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
        .compaction_trigger = false,
        .compaction_token = null,
        .include_usage = kind != .chat,
        .effort = effortOf(body),
        .raw = body,
    } };
}

pub fn estimateInputTokens(parsed: Parsed) u32 {
    const chars = parsed.system_text.len + parsed.flatten_text.len;
    const text = @as(u32, @intCast((chars + 3) / 4));
    const overhead = @as(u32, @intCast(parsed.tools.len * 8 + 4));
    return @max(@as(u32, 1), text + overhead);
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

test "messages requires model and messages" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"messages\":[]}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("model is required", parseMessages(std.testing.allocator, parsed.value).err.message);
}
