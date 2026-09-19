const std = @import("std");
const Io = std.Io;

const auth = @import("auth.zig");
const bridge = @import("bridge.zig");
const compact_mod = @import("compact.zig");
const config_mod = @import("config.zig");
const cursor_api = @import("cursor_api.zig");
const encode = @import("encode.zig");
const engine = @import("engine.zig");
const errors = @import("errors.zig");
const grok_summary = @import("grok_summary.zig");
const httpx = @import("httpx.zig");
const ids = @import("ids.zig");
const jsonx = @import("jsonx.zig");
const models = @import("models.zig");
const protocol = @import("protocol.zig");
const toolcb = @import("toolcb.zig");

const version = config_mod.version;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config_mod.Config.fromEnv(init.environ_map, arena);
    std.Io.Dir.cwd().createDirPath(io, cfg.state_dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, cfg.workspace_dir) catch {};

    var secret: [32]u8 = undefined;
    io.random(&secret);

    const instance = try ids.instanceId(io, arena, cfg.instance_id);
    var catalog_store: cursor_api.Catalog = undefined;
    var app = httpx.App{
        .io = io,
        .gpa = arena,
        .config = cfg,
        .compact = .{ .secret = secret, .now_secs = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, 1_000_000_000)) },
        .instance_id = instance,
        .sdk_version = config_mod.sdk_version,
        .use_fake = cfg.fake_cursor or cfg.cursor_api_key == null,
        .bridge = null,
        .catalog = null,
    };

    if (cfg.cursor_api_key) |key| {
        catalog_store = .{
            .io = io,
            .gpa = arena,
            .client = .{ .allocator = arena, .io = io },
            .api_key = key,
        };
        app.catalog = &catalog_store;
    }

    var group: Io.Group = .init;
    defer group.cancel(io);

    var cb_server: Io.net.Server = undefined;
    var cb_url: []const u8 = "";
    var cb_token: []const u8 = "";
    if (!cfg.fake_cursor and cfg.cursor_api_key != null) {
        var tok: [16]u8 = undefined;
        io.random(&tok);
        const hex = std.fmt.bytesToHex(tok, .lower);
        cb_token = try arena.dupe(u8, hex[0..]);
        cb_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{cfg.tool_callback_port});
        const cb_addr = Io.net.IpAddress.parse("127.0.0.1", cfg.tool_callback_port) catch |err| {
            std.log.err("tool callback address: {t}", .{err});
            return err;
        };
        cb_server = try cb_addr.listen(io, .{ .reuse_address = true });
        group.async(io, toolcb.acceptLoop, .{ io, &cb_server, cb_token, arena });
        std.log.info("tool callback {s}", .{cb_url});
    }

    var live_bridge: ?bridge.Bridge = null;
    var bridge_client: httpx.BridgeClient = undefined;
    if (!cfg.fake_cursor) {
        if (bridge.findBridgeBinary(init.environ_map, arena)) |bin| {
            if (cfg.cursor_api_key) |key| {
                if (bridge.spawn(io, arena, init.environ_map, bin, cfg.workspace_dir, key, cb_url, cb_token)) |spawned| {
                    live_bridge = spawned;
                } else |err| {
                    std.log.warn("official sdk-bridge spawn failed ({t}); catalog stays native, inference unavailable", .{err});
                }
                if (live_bridge) |*b| {
                    var ping_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer ping_arena.deinit();
                    if (b.ping(ping_arena.allocator())) |_| {
                        bridge_client = .{
                            .unary = bridgeUnary,
                            .run = bridgeRun,
                            .impl = b,
                        };
                        app.bridge = &bridge_client;
                        app.cursor_bridge = b;
                        app.use_fake = false;
                    } else |err| {
                        std.log.warn("official sdk-bridge ping failed ({t}); catalog stays native, inference unavailable", .{err});
                    }
                }
            }
        } else if (cfg.cursor_api_key != null) {
            std.log.warn("no cursor-sdk-bridge binary; GET /v1/models is native HTTPS. Inference needs scripts/fetch-bridge.sh (not Cloud Agents)", .{});
        }
    }

    const address = Io.net.IpAddress.parse(cfg.host, cfg.port) catch |err| {
        std.log.err("invalid listen address {s}:{d}: {t}", .{ cfg.host, cfg.port, err });
        return err;
    };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.socket.close(io);

    std.log.info("cursor-sdk2api-zig listening http://{s}:{d} version={s} catalog={s} inference={s}", .{
        cfg.host,
        cfg.port,
        version,
        if (app.catalog != null) "native" else "fake",
        if (app.use_fake) "fake" else if (app.cursor_bridge != null) "sdk-bridge" else "unavailable",
    });

    while (true) {
        const stream = try listener.accept(io);
        group.async(io, accept, .{ io, &app, stream });
    }
}

fn accept(io: Io, app: *httpx.App, stream: Io.net.Stream) void {
    defer stream.close(io);
    var recv_buffer: [65536]u8 = undefined;
    var send_buffer: [16384]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    var request = server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => {
            std.log.err("closing http connection: {t}", .{err});
            return;
        },
    };
    httpx.handle(app, &request);
}

fn bridgeUnary(client: *httpx.BridgeClient, allocator: std.mem.Allocator, path: []const u8, payload: []const u8) anyerror![]u8 {
    const impl: *bridge.Bridge = @ptrCast(@alignCast(client.impl));
    return impl.unary(allocator, path, payload);
}

fn bridgeRun(client: *httpx.BridgeClient, allocator: std.mem.Allocator, parsed: protocol.Parsed, session_id: []const u8, message_id: []const u8, now: i64) anyerror!encode.Turn {
    const impl: *bridge.Bridge = @ptrCast(@alignCast(client.impl));
    return impl.run(allocator, parsed, session_id, message_id, now);
}

test {
    _ = auth;
    _ = compact_mod;
    _ = config_mod;
    _ = encode;
    _ = engine;
    _ = errors;
    _ = grok_summary;
    _ = httpx;
    _ = ids;
    _ = jsonx;
    _ = models;
    _ = protocol;
    _ = bridge;
    _ = cursor_api;
    _ = @import("session.zig");
    _ = toolcb;
}

fn pathOnly(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

test "pathOnly strips query" {
    try std.testing.expectEqualStrings("/health", pathOnly("/health?x=1"));
    try std.testing.expectEqualStrings("/v1/models", pathOnly("/v1/models"));
}
