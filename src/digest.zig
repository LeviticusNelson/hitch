const std = @import("std");

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn sha256HexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex = sha256Hex(bytes);
    return allocator.dupe(u8, hex[0..]);
}

/// Transcript minus the latest `user: …` block.
pub fn stripLastUserBlock(flatten_text: []const u8, last_user_text: []const u8) []const u8 {
    var prefix = flatten_text;
    if (last_user_text.len > 0 and std.mem.endsWith(u8, flatten_text, last_user_text)) {
        prefix = flatten_text[0 .. flatten_text.len - last_user_text.len];
        const labels = [_][]const u8{ "\nuser: ", "user: " };
        for (labels) |lab| {
            if (std.mem.endsWith(u8, prefix, lab)) {
                prefix = prefix[0 .. prefix.len - lab.len];
                break;
            }
        }
    }
    return prefix;
}

pub fn lineageKey(model_id: []const u8, system_text: []const u8, prefix: []const u8) [64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(model_id);
    h.update("\n");
    h.update(system_text);
    h.update("\n");
    h.update(prefix);
    var out: [32]u8 = undefined;
    h.final(&out);
    return std.fmt.bytesToHex(out, .lower);
}

test "sha256Hex is stable" {
    const a = sha256Hex("hello");
    const b = sha256Hex("hello");
    try std.testing.expectEqualSlices(u8, a[0..], b[0..]);
}

test "lineageKey of turn-2 prefix matches turn-1 full flatten" {
    const turn1 = "user: hi";
    const stored = lineageKey("grok-4.7", "sys", turn1);
    const prefix = stripLastUserBlock("user: hi\nuser: next", "next");
    try std.testing.expectEqualStrings("user: hi", prefix);
    const looked = lineageKey("grok-4.7", "sys", prefix);
    try std.testing.expectEqualSlices(u8, stored[0..], looked[0..]);
    const other = lineageKey("claude-opus-4-8", "sys", prefix);
    try std.testing.expect(!std.mem.eql(u8, stored[0..], other[0..]));
}
