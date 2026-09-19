const std = @import("std");
const Io = std.Io;

const version = "0.1.0";
const default_host = "127.0.0.1";
const default_port: u16 = 8081;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const host = init.environ_map.get("HOST") orelse default_host;
    const port = parsePort(init.environ_map.get("PORT")) orelse default_port;

    const address = Io.net.IpAddress.parse(host, port) catch |err| {
        std.log.err("invalid listen address {s}:{d}: {t}", .{ host, port, err });
        return err;
    };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.socket.close(io);

    std.log.info("cursor-sdk2api-zig listening http://{s}:{d} version={s}", .{ host, port, version });

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = try listener.accept(io);
        group.async(io, accept, .{ io, arena, stream });
    }
}

fn parsePort(raw: ?[]const u8) ?u16 {
    const s = raw orelse return null;
    return std.fmt.parseInt(u16, s, 10) catch null;
}

fn accept(io: Io, arena: std.mem.Allocator, stream: Io.net.Stream) void {
    defer stream.close(io);

    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.err("closing http connection: {t}", .{err});
                return;
            },
        };
        serve(&request, arena) catch |err| {
            std.log.err("unable to serve {s}: {t}", .{ request.head.target, err });
            return;
        };
    }
}

fn serve(request: *std.http.Server.Request, arena: std.mem.Allocator) !void {
    const path = pathOnly(request.head.target);
    if (request.head.method == .GET and (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/"))) {
        const body = try std.fmt.allocPrint(arena,
            "{{\"status\":\"ok\",\"service\":\"cursor-sdk2api-zig\",\"version\":\"{s}\",\"runtime\":\"zig\"}}\n",
            .{version},
        );
        try request.respond(body, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    const body = "{\"error\":{\"type\":\"not_found\",\"message\":\"No route\"}}\n";
    try request.respond(body, .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

fn pathOnly(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

test "pathOnly strips query" {
    try std.testing.expectEqualStrings("/health", pathOnly("/health?x=1"));
    try std.testing.expectEqualStrings("/v1/models", pathOnly("/v1/models"));
}
