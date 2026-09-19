const std = @import("std");
const protocol = @import("protocol.zig");

const summary_open = "Output the final summary inside a single <summary>";
const summary_task = "faithful, concise summary of the conversation so far";
const max_summary_chars: usize = 8_000;
const max_query: usize = 400;
const max_note: usize = 500;

pub fn isGrokCompactSummaryRequest(parsed: protocol.Parsed) bool {
    return std.mem.indexOf(u8, parsed.last_user_text, summary_open) != null and
        std.mem.indexOf(u8, parsed.last_user_text, summary_task) != null;
}

/// Extractive successor brief, matching Node grok-compact-summary.ts.
/// Do not dump flatten_text: the tail is the summarizer prompt itself, which
/// made Grok show empty `<summary></summary>` and stop instead of continuing.
pub fn buildGrokCompactSummary(allocator: std.mem.Allocator, parsed: protocol.Parsed) ![]u8 {
    const src = parsed.flatten_text;
    var queries = std.ArrayList([]const u8).empty;
    var notes = std.ArrayList([]const u8).empty;

    var q_it = QueryIter{ .text = src };
    while (q_it.next()) |q| {
        if (isCompactPrompt(q)) continue;
        try queries.append(allocator, clipFront(q, max_query));
    }

    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= src.len) : (i += 1) {
        if (i != src.len and src[i] != '\n') continue;
        const line = src[line_start..i];
        line_start = i + 1;
        const asst = "assistant: ";
        if (line.len > asst.len and std.mem.startsWith(u8, line, asst)) {
            const body = stripTags(line[asst.len..]);
            if (body.len == 0 or isCompactPrompt(body)) continue;
            try notes.append(allocator, clipFront(body, max_note));
        }
    }

    const q_slice = queries.items;
    const n_slice = notes.items;
    const recent_q = if (q_slice.len > 4) q_slice[q_slice.len - 4 ..] else q_slice;
    const recent_n = if (n_slice.len > 6) n_slice[n_slice.len - 6 ..] else n_slice;

    var body = std.ArrayList(u8).empty;
    if (recent_q.len > 0) {
        try body.appendSlice(allocator, "User requests: ");
        for (recent_q, 0..) |q, idx| {
            if (idx > 0) try body.appendSlice(allocator, " | ");
            try body.appendSlice(allocator, q);
        }
        try body.appendSlice(allocator, "\n\n");
    }
    if (recent_n.len > 0) {
        try body.appendSlice(allocator, "Recent work:\n");
        for (recent_n) |n| {
            try body.appendSlice(allocator, "- ");
            try body.appendSlice(allocator, n);
            try body.append(allocator, '\n');
        }
        try body.append(allocator, '\n');
    }
    try body.appendSlice(allocator, "Continue the unfinished task from the latest user request. Do not stop after summarizing.");
    const clipped = clipFront(body.items, max_summary_chars);
    return std.fmt.allocPrint(allocator, "<summary>\n{s}\n</summary>", .{clipped});
}

const QueryIter = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(self: *QueryIter) ?[]const u8 {
        const open = "<user_query>";
        const close = "</user_query>";
        while (self.pos < self.text.len) {
            const rel = std.mem.indexOf(u8, self.text[self.pos..], open) orelse return null;
            const start = self.pos + rel + open.len;
            const end_rel = std.mem.indexOf(u8, self.text[start..], close) orelse {
                self.pos = self.text.len;
                return null;
            };
            const end = start + end_rel;
            self.pos = end + close.len;
            const q = std.mem.trim(u8, self.text[start..end], " \t\r\n");
            if (q.len > 0) return q;
        }
        return null;
    }
};

fn isCompactPrompt(text: []const u8) bool {
    return std.mem.indexOf(u8, text, summary_open) != null or
        std.mem.indexOf(u8, text, summary_task) != null;
}

fn stripTags(text: []const u8) []const u8 {
    // Flatten already uses "assistant: "; drop leftover markup by returning trim.
    return std.mem.trim(u8, text, " \t\r\n");
}

fn clipFront(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    return text[0..max];
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

test "compact summary keeps user_query and not the summarizer prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const flatten =
        \\user: <user_query>default aggregate to 30 days but keep lifetime</user_query>
        \\assistant: Looking at the admin report query.
        \\user: Output the final summary inside a single <summary> faithful, concise summary of the conversation so far
    ;
    const parsed = protocol.Parsed{
        .kind = .responses,
        .model = "grok-4.6",
        .upstream_model = "grok-4.6",
        .stream = false,
        .system_text = "",
        .last_user_text = "Output the final summary inside a single <summary> faithful, concise summary of the conversation so far",
        .flatten_text = flatten,
        .tools = &.{},
        .continuation = &.{},
        .all_outputs = &.{},
        .compaction_trigger = false,
        .compaction_token = null,
        .include_usage = true,
        .effort = null,
        .raw = .null,
    };
    const out = try buildGrokCompactSummary(arena.allocator(), parsed);
    try std.testing.expect(std.mem.indexOf(u8, out, "<summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "default aggregate to 30 days") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Continue the unfinished task") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, summary_open) == null);
}
