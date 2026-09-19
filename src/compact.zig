const std = @import("std");
const errors = @import("errors.zig");
const digest = @import("digest.zig");

pub const token_prefix = "csgw1.";
pub const ttl_seconds: i64 = 7 * 24 * 60 * 60;

pub const Store = struct {
    secret: [32]u8,
    now_secs: i64,

    pub fn mint(self: Store, allocator: std.mem.Allocator, compact_id: []const u8, model: []const u8) !Minted {
        const exp = self.now_secs + ttl_seconds;
        const canonical = try std.fmt.allocPrint(allocator, "{{\"account\":\"local\",\"compactId\":\"{s}\",\"exp\":{d},\"model\":\"{s}\",\"v\":1}}", .{
            compact_id, exp, model,
        });
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, canonical, &self.secret);
        const payload_b64 = try base64Url(allocator, canonical);
        const mac_b64 = try base64Url(allocator, &mac);
        const token = try std.fmt.allocPrint(allocator, "{s}{s}.{s}", .{ token_prefix, payload_b64, mac_b64 });
        return .{ .token = token, .compact_id = compact_id, .exp = exp };
    }

    pub fn verify(self: Store, allocator: std.mem.Allocator, token: []const u8) union(enum) { ok: void, err: errors.Error } {
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, token_prefix) or std.mem.startsWith(u8, trimmed, "v3.")) {
            return .{ .err = errors.invalidRequest("invalid compact token") };
        }
        const rest = trimmed[token_prefix.len..];
        const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return .{ .err = errors.invalidRequest("invalid compact token") };
        const payload_b64 = rest[0..dot];
        const mac_b64 = rest[dot + 1 ..];
        const canonical = decodeBase64Url(allocator, payload_b64) catch return .{ .err = errors.invalidRequest("invalid compact token") };
        const presented = decodeBase64Url(allocator, mac_b64) catch return .{ .err = errors.invalidRequest("invalid compact token") };
        if (presented.len != 32) return .{ .err = errors.sessionConflict("This compact context is no longer available.") };
        var expected: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, canonical, &self.secret);
        var presented_mac: [32]u8 = undefined;
        @memcpy(&presented_mac, presented[0..32]);
        if (!std.crypto.timing_safe.eql([32]u8, expected, presented_mac)) {
            return .{ .err = errors.sessionConflict("This compact context is no longer available.") };
        }
        _ = digest.sha256Hex(canonical);
        return .ok;
    }
};

pub const Minted = struct {
    token: []const u8,
    compact_id: []const u8,
    exp: i64,
};

fn base64Url(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const size = encoder.calcSize(bytes.len);
    const buf = try allocator.alloc(u8, size);
    _ = encoder.encode(buf, bytes);
    return buf;
}

fn decodeBase64Url(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = try decoder.calcSizeForSlice(text);
    const buf = try allocator.alloc(u8, size);
    try decoder.decode(buf, text);
    return buf;
}

test "compact token round-trips HMAC" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var secret: [32]u8 = undefined;
    @memset(&secret, 7);
    const store = Store{ .secret = secret, .now_secs = 1_000 };
    const minted = try store.mint(arena.allocator(), "cmp_abc", "grok-4.6");
    try std.testing.expect(std.mem.startsWith(u8, minted.token, "csgw1."));
    try std.testing.expect(store.verify(arena.allocator(), minted.token) == .ok);
}
