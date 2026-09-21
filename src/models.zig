const std = @import("std");

pub const client_model_prefixes = [_][]const u8{ "cursor-cidr/", "cursor-acp/", "cursor/" };

pub const chars_per_token: u32 = 4;
pub const default_context_tokens: u32 = 128_000;
pub const output_reserve_tokens: u32 = 8_192;
pub const default_compact_fill_ratio: f64 = 0.25;
pub const min_compact_chars: u32 = 48_000;
pub const max_compact_chars: u32 = 360_000;

pub fn upstreamCursorModelId(model_id: []const u8) []const u8 {
    const id = std.mem.trim(u8, model_id, " \t\r\n");
    for (client_model_prefixes) |prefix| {
        if (std.mem.startsWith(u8, id, prefix)) return id[prefix.len..];
    }
    return id;
}

pub fn isGrokHttpClient(user_agent: ?[]const u8) bool {
    const ua = user_agent orelse return false;
    return containsIgnoreCase(ua, "grok-cli") or containsIgnoreCase(ua, "grok-build");
}

pub fn catalogModelIdsForClient(allocator: std.mem.Allocator, model_id: []const u8, user_agent: ?[]const u8) ![][]const u8 {
    const id = std.mem.trim(u8, model_id, " \t\r\n");
    if (id.len == 0) return &.{};
    if (!isGrokHttpClient(user_agent)) {
        const one = try allocator.alloc([]const u8, 1);
        one[0] = id;
        return one;
    }
    const out = try allocator.alloc([]const u8, client_model_prefixes.len);
    for (client_model_prefixes, 0..) |prefix, i| {
        out[i] = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, id });
    }
    return out;
}

pub fn contextTokensForModel(model_id: []const u8) u32 {
    const id = upstreamCursorModelId(model_id);
    if (id.len == 0) return default_context_tokens;
    if (eql(id, "composer-2.5") or eql(id, "composer-2")) return 200_000;
    if (eql(id, "grok-4.6") or eql(id, "grok-4.5")) return 256_000;
    if (starts(id, "gpt-5.4-nano") or starts(id, "gpt-5.4-mini") or starts(id, "gpt-5-mini")) return 128_000;
    if (starts(id, "gpt-5")) return 272_000;
    if (starts(id, "claude-")) return 200_000;
    if (starts(id, "gemini-")) return 1_000_000;
    if (starts(id, "grok-")) return 256_000;
    if (starts(id, "composer-")) return 200_000;
    if (starts(id, "kimi-")) return 256_000;
    if (starts(id, "glm-")) return 200_000;
    if (starts(id, "muse-")) return 128_000;
    return default_context_tokens;
}

pub fn sdkPromptMaxCharsForModel(model_id: []const u8) u32 {
    const context = contextTokensForModel(model_id);
    const usable = @max(@as(u32, 16_000), context -| output_reserve_tokens);
    const chars = @as(u32, @intFromFloat(@as(f64, @floatFromInt(usable)) * default_compact_fill_ratio)) * chars_per_token;
    return @min(max_compact_chars, @max(min_compact_chars, chars));
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn starts(a: []const u8, b: []const u8) bool {
    return std.mem.startsWith(u8, a, b);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

test "upstreamCursorModelId strips Grok wire prefixes" {
    try std.testing.expectEqualStrings("grok-4.6", upstreamCursorModelId("cursor-cidr/grok-4.6"));
    try std.testing.expectEqualStrings("grok-4.6", upstreamCursorModelId("cursor-acp/grok-4.6"));
    try std.testing.expectEqualStrings("grok-4.6", upstreamCursorModelId("cursor/grok-4.6"));
    try std.testing.expectEqualStrings("grok-4.6", upstreamCursorModelId("grok-4.6"));
}

test "catalogModelIdsForClient prefixes only Grok clients" {
    const grok = try catalogModelIdsForClient(std.testing.allocator, "grok-4.6", "grok-build/1");
    defer {
        for (grok) |id| std.testing.allocator.free(id);
        std.testing.allocator.free(grok);
    }
    try std.testing.expectEqual(@as(usize, 3), grok.len);
    try std.testing.expectEqualStrings("cursor-cidr/grok-4.6", grok[0]);

    const other = try catalogModelIdsForClient(std.testing.allocator, "grok-4.6", "curl/8");
    defer std.testing.allocator.free(other);
    try std.testing.expectEqual(@as(usize, 1), other.len);
    try std.testing.expectEqualStrings("grok-4.6", other[0]);
}

test "context window for grok family" {
    try std.testing.expectEqual(@as(u32, 256_000), contextTokensForModel("cursor-cidr/grok-4.6"));
    try std.testing.expectEqual(@as(u32, 256_000), contextTokensForModel("cursor-cidr/grok-4.7"));
    try std.testing.expectEqualStrings("grok-4.7", upstreamCursorModelId("cursor-cidr/grok-4.7"));
    try std.testing.expect(sdkPromptMaxCharsForModel("grok-4.6") >= min_compact_chars);
}
