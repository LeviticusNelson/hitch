const std = @import("std");
const auth = @import("auth.zig");

pub const version = "0.1.0";
pub const sdk_version = "1.0.30";

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8081,
    auth_mode: auth.Mode = .byok,
    gateway_access_key: ?[]const u8 = null,
    managed_cursor_key: ?[]const u8 = null,
    cursor_api_key: ?[]const u8 = null,
    cursor_sdk_bridge: ?[]const u8 = null,
    state_dir: []const u8 = "",
    workspace_dir: []const u8 = "",
    max_body_bytes: usize = 8 * 1024 * 1024,
    fake_cursor: bool = false,
    instance_id: ?[]const u8 = null,
    tool_callback_port: u16 = 18771,
    managed_cursor_keys: []const []const u8 = &.{},
    max_active_runs: u32 = 32,
    // BYOK/daily-driver traffic shares one Cursor key, so the per-key cap must
    // not be far below the global cap or Grok 429s itself (subagents, compact).
    max_runs_per_key: u32 = 32,
    capacity_wait_ms: u32 = 15_000,
    capacity_poll_ms: u32 = 200,

    pub fn fromEnv(env: *const std.process.Environ.Map, allocator: std.mem.Allocator) !Config {
        var c: Config = .{};
        if (env.get("HOST")) |h| c.host = h;
        if (env.get("PORT")) |p| c.port = std.fmt.parseInt(u16, p, 10) catch c.port;
        if (env.get("AUTH_MODE")) |m| {
            if (std.mem.eql(u8, m, "managed")) c.auth_mode = .managed;
        }
        c.gateway_access_key = emptyToNull(env.get("GATEWAY_ACCESS_KEY"));
        c.managed_cursor_key = emptyToNull(env.get("MANAGED_CURSOR_KEY"));
        c.cursor_api_key = emptyToNull(env.get("CURSOR_API_KEY"));
        c.cursor_sdk_bridge = emptyToNull(env.get("CURSOR_SDK_BRIDGE"));
        if (env.get("MAX_BODY_BYTES")) |n| c.max_body_bytes = std.fmt.parseInt(usize, n, 10) catch c.max_body_bytes;
        c.fake_cursor = isTruthy(env.get("FAKE_CURSOR"));
        c.instance_id = emptyToNull(env.get("INSTANCE_ID"));
        if (env.get("TOOL_CALLBACK_PORT")) |p| c.tool_callback_port = std.fmt.parseInt(u16, p, 10) catch c.tool_callback_port;
        if (env.get("MAX_ACTIVE_RUNS")) |n| c.max_active_runs = std.fmt.parseInt(u32, n, 10) catch c.max_active_runs;
        if (env.get("MAX_RUNS_PER_KEY")) |n| c.max_runs_per_key = std.fmt.parseInt(u32, n, 10) catch c.max_runs_per_key;
        if (env.get("CAPACITY_WAIT_MS")) |n| c.capacity_wait_ms = std.fmt.parseInt(u32, n, 10) catch c.capacity_wait_ms;
        if (env.get("CAPACITY_POLL_MS")) |n| c.capacity_poll_ms = std.fmt.parseInt(u32, n, 10) catch c.capacity_poll_ms;
        if (env.get("MANAGED_CURSOR_KEYS")) |raw| {
            c.managed_cursor_keys = try splitComma(allocator, raw);
        } else if (c.managed_cursor_key) |one| {
            const one_list = try allocator.alloc([]const u8, 1);
            one_list[0] = one;
            c.managed_cursor_keys = one_list;
        }
        c.state_dir = env.get("STATE_DIR") orelse try homeJoin(allocator, env, ".hitch");
        c.workspace_dir = env.get("WORKSPACE_DIR") orelse try std.fs.path.join(allocator, &.{ c.state_dir, "workspace" });
        return c;
    }
};

fn emptyToNull(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    const t = std.mem.trim(u8, s, " \t");
    return if (t.len == 0) null else t;
}

fn isTruthy(v: ?[]const u8) bool {
    const s = v orelse return false;
    return std.mem.eql(u8, s, "1") or std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "yes");
}

fn splitComma(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        try out.append(allocator, t);
    }
    return out.toOwnedSlice(allocator);
}

fn homeJoin(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8) ![]u8 {
    const home = env.get("HOME") orelse "/tmp";
    return std.fs.path.join(allocator, &.{ home, name });
}

test "PORT parses" {
    try std.testing.expectEqual(@as(u16, 8081), (Config{}).port);
}
