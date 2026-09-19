const std = @import("std");
const encode = @import("encode.zig");
const protocol = @import("protocol.zig");

pub const Fake = struct {
    pub fn listModels(allocator: std.mem.Allocator) ![]const []const u8 {
        const ids = [_][]const u8{ "grok-4.6", "composer-2", "composer-2.5", "default" };
        return allocator.dupe([]const u8, &ids);
    }

    pub fn run(allocator: std.mem.Allocator, parsed: protocol.Parsed, session_id: []const u8, message_id: []const u8, now: i64) !encode.Turn {
        if (parsed.continuation.len > 0) {
            return .{
                .message_id = message_id,
                .session_id = session_id,
                .model = parsed.model,
                .created_at = now,
                .text = "ok",
                .input_tokens = protocol.estimateInputTokens(parsed),
                .output_tokens = 1,
            };
        }
        if (parsed.tools.len > 0 and std.mem.startsWith(u8, parsed.last_user_text, "CALL ")) {
            const name = nameFromCall(parsed.last_user_text, parsed.tools[0].name);
            const call = try allocator.alloc(encode.ToolCall, 1);
            call[0] = .{
                .id = "call_fake_1",
                .name = name,
                .arguments = "{}",
                .kind = parsed.tools[0].kind,
            };
            return .{
                .message_id = message_id,
                .session_id = session_id,
                .model = parsed.model,
                .created_at = now,
                .text = "",
                .tools = call,
                .input_tokens = protocol.estimateInputTokens(parsed),
                .output_tokens = 8,
                .stop_reason = "tool_use",
            };
        }
        const text = if (parsed.last_user_text.len > 0) parsed.last_user_text else "ok";
        return .{
            .message_id = message_id,
            .session_id = session_id,
            .model = parsed.model,
            .created_at = now,
            .text = text,
            .input_tokens = protocol.estimateInputTokens(parsed),
            .output_tokens = @max(@as(u32, 1), @as(u32, @intCast(@min(text.len, 4096) / 4))),
        };
    }
};

fn nameFromCall(text: []const u8, fallback: []const u8) []const u8 {
    const rest = text["CALL ".len..];
    const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
    if (end == 0) return fallback;
    return rest[0..end];
}

test "fake echoes last user text" {
    const parsed = protocol.Parsed{
        .kind = .responses,
        .model = "grok-4.6",
        .upstream_model = "grok-4.6",
        .stream = false,
        .system_text = "",
        .last_user_text = "hello zig",
        .flatten_text = "user: hello zig",
        .tools = &.{},
        .continuation = &.{},
        .all_outputs = &.{},
        .compaction_trigger = false,
        .compaction_token = null,
        .include_usage = true,
        .effort = null,
        .raw = .null,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const turn = try Fake.run(arena.allocator(), parsed, "ses_1", "msg_1", 1);
    try std.testing.expectEqualStrings("hello zig", turn.text);
}
