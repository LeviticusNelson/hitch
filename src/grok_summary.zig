const std = @import("std");
const protocol = @import("protocol.zig");

const summary_open = "Output the final summary inside a single <summary>";
const summary_task = "faithful, concise summary of the conversation so far";
const max_summary_chars: usize = 8_000;

pub fn isGrokCompactSummaryRequest(parsed: protocol.Parsed) bool {
    return std.mem.indexOf(u8, parsed.last_user_text, summary_open) != null and
        std.mem.indexOf(u8, parsed.last_user_text, summary_task) != null;
}

pub fn buildGrokCompactSummary(allocator: std.mem.Allocator, parsed: protocol.Parsed) ![]u8 {
    const clipped = clip(parsed.flatten_text, max_summary_chars);
    return std.fmt.allocPrint(allocator, "<summary>\nContinue from the latest user request.\n{s}\n</summary>", .{clipped});
}

fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    return text[text.len - max ..];
}

test "detects Grok compact summary prompt" {
    const parsed = protocol.Parsed{
        .kind = .responses,
        .model = "grok-4.6",
        .upstream_model = "grok-4.6",
        .stream = true,
        .system_text = "",
        .last_user_text = "Output the final summary inside a single <summary> faithful, concise summary of the conversation so far",
        .flatten_text = "user: hi",
        .tools = &.{},
        .continuation = &.{},
        .all_outputs = &.{},
        .compaction_trigger = false,
        .compaction_token = null,
        .include_usage = true,
        .effort = null,
        .raw = .null,
    };
    try std.testing.expect(isGrokCompactSummaryRequest(parsed));
}
