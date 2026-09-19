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

test "sha256Hex is stable" {
    const a = sha256Hex("hello");
    const b = sha256Hex("hello");
    try std.testing.expectEqualSlices(u8, a[0..], b[0..]);
}
