//! Pick a listen port that no other process is serving, and publish the one
//! hitch actually bound so scripts and clients can find it.
//!
//! `reuse_address` (SO_REUSEADDR + SO_REUSEPORT) lets 127.0.0.1:PORT co-bind
//! under another process's wildcard *:PORT listener (macOS). Clients that
//! reach the wildcard (::1, a LAN address, or 127.0.0.1 while hitch is down)
//! then talk to the other service. So a port counts as taken when anything
//! already accepts on 127.0.0.1 or ::1 for it. A free port is still bound with
//! `reuse_address` so TIME_WAIT from a previous hitch does not force a hop.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Bound = struct {
    server: Io.net.Server,
    port: u16,
    configured_port: u16,
};

/// The configured port, then up to `span` ports above it, then 0 (OS-assigned).
/// `span == 0` with `fallback == false` yields only the configured port.
pub fn candidates(buf: []u16, base: u16, span: u16, fallback: bool) []u16 {
    var n: usize = 0;
    if (buf.len == 0) return buf[0..0];
    buf[n] = base;
    n += 1;
    if (!fallback or base == 0) return buf[0..n];
    var i: u32 = 1;
    while (i <= span and n < buf.len) : (i += 1) {
        const p = @as(u32, base) + i;
        if (p > std.math.maxInt(u16)) break;
        buf[n] = @intCast(p);
        n += 1;
    }
    if (n < buf.len) {
        buf[n] = 0;
        n += 1;
    }
    return buf[0..n];
}

/// True when some process already accepts TCP on `port` at the probe host or ::1.
pub fn portServed(io: Io, probe_host: []const u8, port: u16) bool {
    if (port == 0) return false;
    const v4 = Io.net.IpAddress.parse(probe_host, port) catch Io.net.IpAddress{ .ip4 = .loopback(port) };
    if (accepts(io, v4)) return true;
    const v6 = Io.net.IpAddress{ .ip6 = .loopback(port) };
    return accepts(io, v6);
}

fn accepts(io: Io, addr: Io.net.IpAddress) bool {
    const stream = addr.connect(io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

/// Host to probe for an existing listener: the bind host, or loopback for a wildcard bind.
pub fn probeHost(host: []const u8) []const u8 {
    if (std.mem.eql(u8, host, "0.0.0.0") or std.mem.eql(u8, host, "::") or host.len == 0) return "127.0.0.1";
    return host;
}

pub const BindError = error{ NoFreePort, InvalidListenAddress };

/// Bind the first candidate port that nothing else serves.
pub fn bindFirst(io: Io, host: []const u8, ports: []const u16) BindError!Bound {
    const probe = probeHost(host);
    const configured = if (ports.len > 0) ports[0] else 0;
    for (ports) |port| {
        if (portServed(io, probe, port)) {
            std.log.warn("listen {s}:{d} skipped: another process already serves it", .{ host, port });
            continue;
        }
        var addr = Io.net.IpAddress.parse(host, port) catch return error.InvalidListenAddress;
        const server = addr.listen(io, .{ .reuse_address = port != 0 }) catch |err| {
            std.log.warn("listen {s}:{d} failed ({t})", .{ host, port, err });
            continue;
        };
        addr = server.socket.address;
        return .{ .server = server, .port = addr.getPort(), .configured_port = configured };
    }
    return error.NoFreePort;
}

pub fn selfPid() i64 {
    return switch (builtin.os.tag) {
        .linux => if (builtin.link_libc) std.c.getpid() else std.os.linux.getpid(),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => std.c.getpid(),
    };
}

/// JSON published at `<state_dir>/endpoint.json`.
pub fn endpointJson(
    arena: std.mem.Allocator,
    host: []const u8,
    port: u16,
    configured_port: u16,
    pid: i64,
    instance_id: []const u8,
    version: []const u8,
) ![]u8 {
    const url_host = if (std.mem.eql(u8, host, "0.0.0.0") or host.len == 0) "127.0.0.1" else host;
    const base = try std.fmt.allocPrint(arena, "http://{s}:{d}", .{ url_host, port });
    return std.fmt.allocPrint(arena,
        "{{\"service\":\"hitch\",\"pid\":{d},\"host\":{f},\"port\":{d},\"configured_port\":{d},\"fallback\":{s},\"base_url\":{f},\"health_url\":{f},\"instance_id\":{f},\"version\":{f}}}\n",
        .{
            pid,
            std.json.fmt(host, .{}),
            port,
            configured_port,
            if (port != configured_port) "true" else "false",
            std.json.fmt(try std.fmt.allocPrint(arena, "{s}/v1", .{base}), .{}),
            std.json.fmt(try std.fmt.allocPrint(arena, "{s}/health", .{base}), .{}),
            std.json.fmt(instance_id, .{}),
            std.json.fmt(version, .{}),
        },
    );
}

/// Write `<state_dir>/endpoint.json` and `<state_dir>/port` atomically (temp file + rename).
pub fn publish(io: Io, arena: std.mem.Allocator, state_dir: []const u8, json: []const u8, port: u16) !void {
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, state_dir) catch {};
    try writeAtomic(io, arena, state_dir, "endpoint.json", json);
    try writeAtomic(io, arena, state_dir, "port", try std.fmt.allocPrint(arena, "{d}\n", .{port}));
}

fn writeAtomic(io: Io, arena: std.mem.Allocator, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const final = try std.fs.path.join(arena, &.{ dir, name });
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{final});
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try cwd.rename(tmp, cwd, final, io);
}

test "candidates: configured port, the next span ports, then OS-assigned" {
    var buf: [16]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{ 8080, 8081, 8082, 8083, 0 }, candidates(&buf, 8080, 3, true));
    try std.testing.expectEqualSlices(u16, &.{8080}, candidates(&buf, 8080, 3, false));
    try std.testing.expectEqualSlices(u16, &.{0}, candidates(&buf, 0, 3, true));
    try std.testing.expectEqualSlices(u16, &.{ 65534, 65535, 0 }, candidates(&buf, 65534, 5, true));
}

test "bindFirst skips a port another process already serves" {
    const io = std.testing.io;
    // Occupy a free port the way Redpanda/OrbStack did: someone else is listening.
    var squat_addr = Io.net.IpAddress{ .ip4 = .loopback(0) };
    var squatter = try squat_addr.listen(io, .{});
    defer squatter.deinit(io);
    const taken = squatter.socket.address.getPort();

    var buf: [8]u16 = undefined;
    var bound = try bindFirst(io, "127.0.0.1", candidates(&buf, taken, 3, true));
    defer bound.server.deinit(io);
    try std.testing.expect(bound.port != taken);
    try std.testing.expect(bound.port != 0);
    try std.testing.expectEqual(taken, bound.configured_port);
    try std.testing.expect(portServed(io, "127.0.0.1", bound.port));
}

test "bindFirst keeps the configured port when it is free" {
    const io = std.testing.io;
    var probe_addr = Io.net.IpAddress{ .ip4 = .loopback(0) };
    var probe = try probe_addr.listen(io, .{});
    const free = probe.socket.address.getPort();
    probe.deinit(io);

    var buf: [8]u16 = undefined;
    var bound = try bindFirst(io, "127.0.0.1", candidates(&buf, free, 3, true));
    defer bound.server.deinit(io);
    try std.testing.expectEqual(free, bound.port);
}

test "bindFirst without fallback fails instead of sharing" {
    const io = std.testing.io;
    var squat_addr = Io.net.IpAddress{ .ip4 = .loopback(0) };
    var squatter = try squat_addr.listen(io, .{});
    defer squatter.deinit(io);
    var buf: [8]u16 = undefined;
    try std.testing.expectError(error.NoFreePort, bindFirst(io, "127.0.0.1", candidates(&buf, squatter.socket.address.getPort(), 3, false)));
}

test "endpointJson names the bound port and flags a fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = try endpointJson(arena.allocator(), "127.0.0.1", 8081, 8080, 42, "inst_x", "0.2.2");
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), j, .{});
    try std.testing.expectEqual(@as(i64, 8081), parsed.value.object.get("port").?.integer);
    try std.testing.expectEqualStrings("http://127.0.0.1:8081/v1", parsed.value.object.get("base_url").?.string);
    try std.testing.expect(parsed.value.object.get("fallback").?.bool);
}
