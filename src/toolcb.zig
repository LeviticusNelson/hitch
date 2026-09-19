const std = @import("std");
const Io = std.Io;

/// Host for SdkCustomToolCallbackService so official cursor-sdk-bridge
/// will accept local.customTools. Grok executes tools; we hold or return
/// a host-handled placeholder.
pub const Server = struct {
    io: Io,
    gpa: std.mem.Allocator,
    token: []const u8,
    port: u16,
};

pub fn acceptLoop(io: Io, listener: *Io.net.Server, token: []const u8, gpa: std.mem.Allocator) void {
    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.log.err("tool callback accept: {t}", .{err});
            return;
        };
        handleConn(io, stream, token, gpa);
    }
}

fn handleConn(io: Io, stream: Io.net.Stream, token: []const u8, gpa: std.mem.Allocator) void {
    defer stream.close(io);
    var recv_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    var request = server.receiveHead() catch return;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    serve(&request, token, arena) catch |err| {
        std.log.err("tool callback: {t}", .{err});
    };
}

fn serve(request: *std.http.Server.Request, token: []const u8, arena: std.mem.Allocator) !void {
    const path = request.head.target;
    std.log.info("toolcb {s} {s}", .{ @tagName(request.head.method), path });
    if (request.head.method != .POST) {
        try request.respond("{\"code\":\"unimplemented\"}\n", .{ .status = .not_found });
        return;
    }
    var presented: []const u8 = "";
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) presented = h.value;
    }
    const want = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
    if (!std.mem.eql(u8, presented, want)) {
        try request.respond("{\"code\":\"unauthenticated\",\"message\":\"Unauthorized\"}\n", .{ .status = .unauthorized });
        return;
    }
    var tmp: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&tmp);
    _ = reader.allocRemaining(arena, .limited(1 * 1024 * 1024)) catch {};
    // Host tools run in Grok. Acknowledge so a model that calls a tool does not hang the bridge.
    const body =
        \\{"result":{"content":[{"type":"text","text":"Host tool; the Grok client will send the real result on the next turn."}]}}
    ;
    try request.respond(body, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}
