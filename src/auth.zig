const std = @import("std");
const errors = @import("errors.zig");

pub const Mode = enum { byok, managed };

pub const Authorization = struct {
    mode: Mode,
    cursor_api_key: []const u8,
};

pub const Config = struct {
    auth_mode: Mode,
    gateway_access_key: ?[]const u8 = null,
    managed_cursor_key: ?[]const u8 = null,
};

pub fn presentedSecret(headers: HeaderSet) ?[]const u8 {
    if (headers.get("x-hitch-key")) |v| {
        const t = std.mem.trim(u8, v, " \t");
        if (t.len > 0) return t;
    }
    if (headers.get("x-cursor-sdk2api-key")) |v| {
        const t = std.mem.trim(u8, v, " \t");
        if (t.len > 0) return t;
    }
    if (headers.get("x-api-key")) |v| {
        const t = std.mem.trim(u8, v, " \t");
        if (t.len > 0) return t;
    }
    if (headers.get("authorization")) |v| {
        if (std.ascii.startsWithIgnoreCase(v, "Bearer ")) {
            const t = std.mem.trim(u8, v["Bearer ".len..], " \t");
            if (t.len > 0) return t;
        }
    }
    return null;
}

pub fn isLoopback(remote: []const u8) bool {
    return std.mem.eql(u8, remote, "127.0.0.1") or
        std.mem.eql(u8, remote, "::1") or
        std.mem.eql(u8, remote, "::ffff:127.0.0.1");
}

pub const Outcome = union(enum) {
    ok: Authorization,
    err: errors.Error,
};

pub fn authorizeClient(headers: HeaderSet, remote: []const u8, config: Config) Outcome {
    const presented = presentedSecret(headers) orelse {
        return .{ .err = errors.authenticationError("Provide Authorization: Bearer or x-api-key") };
    };
    if (config.auth_mode == .managed) {
        const gateway = config.gateway_access_key orelse {
            return .{ .err = errors.authenticationError("Managed auth is not configured") };
        };
        if (std.mem.eql(u8, presented, gateway)) {
            const key = config.managed_cursor_key orelse presented;
            return .{ .ok = .{ .mode = .managed, .cursor_api_key = key } };
        }
        if (config.managed_cursor_key) |managed| {
            if (std.mem.eql(u8, presented, managed)) {
                return .{ .ok = .{ .mode = .byok, .cursor_api_key = managed } };
            }
        }
        if (isLoopback(remote) and !std.mem.startsWith(u8, presented, "key_")) {
            const key = config.managed_cursor_key orelse presented;
            return .{ .ok = .{ .mode = .managed, .cursor_api_key = key } };
        }
        return .{ .err = errors.authenticationError("Invalid gateway access key") };
    }
    return .{ .ok = .{ .mode = .byok, .cursor_api_key = presented } };
}

pub const HeaderSet = struct {
    items: []const std.http.Header,

    pub fn get(self: HeaderSet, name: []const u8) ?[]const u8 {
        for (self.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

test "byok uses presented bearer" {
    const headers = HeaderSet{ .items = &.{
        .{ .name = "authorization", .value = "Bearer sk-test" },
    } };
    const auth = authorizeClient(headers, "127.0.0.1", .{ .auth_mode = .byok });
    try std.testing.expectEqual(Mode.byok, auth.ok.mode);
    try std.testing.expectEqualStrings("sk-test", auth.ok.cursor_api_key);
}

test "managed loopback accepts non-key_ tokens" {
    const headers = HeaderSet{ .items = &.{
        .{ .name = "authorization", .value = "Bearer eyJhbGciOi" },
    } };
    const auth = authorizeClient(headers, "127.0.0.1", .{
        .auth_mode = .managed,
        .gateway_access_key = "gw",
        .managed_cursor_key = "cursor-key",
    });
    try std.testing.expectEqual(Mode.managed, auth.ok.mode);
    try std.testing.expectEqualStrings("cursor-key", auth.ok.cursor_api_key);
}

test "managed rejects unknown key_ tokens" {
    const headers = HeaderSet{ .items = &.{
        .{ .name = "x-api-key", .value = "key_typo" },
    } };
    const result = authorizeClient(headers, "127.0.0.1", .{
        .auth_mode = .managed,
        .gateway_access_key = "gw",
        .managed_cursor_key = "cursor-key",
    });
    try std.testing.expectEqual(errors.Code.authentication_error, result.err.code);
    try std.testing.expectEqualStrings("Invalid gateway access key", result.err.message);
}
