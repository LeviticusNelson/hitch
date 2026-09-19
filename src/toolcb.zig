const std = @import("std");
const Io = std.Io;
const ids = @import("ids.zig");
const jsonx = @import("jsonx.zig");
const rawhttp = @import("rawhttp.zig");

/// Host for SdkCustomToolCallbackService. Grok executes tools; we hold the
/// bridge CallCustomTool RPC until Grok POSTs function_call_output.
pub const Waiter = struct {
    call_id: []u8,
    name: []u8,
    args_json: []u8,
    agent_id: []u8,
    result: ?[]u8 = null,
    done: bool = false,
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
};

pub const Hub = struct {
    io: Io,
    gpa: std.mem.Allocator,
    token: []const u8 = "",
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
    by_id: std.StringHashMap(*Waiter),

    pub fn init(io: Io, gpa: std.mem.Allocator) Hub {
        return .{
            .io = io,
            .gpa = gpa,
            .by_id = std.StringHashMap(*Waiter).init(gpa),
        };
    }

    pub fn announce(self: *Hub, call: ParsedCall) !*Waiter {
        const w = try self.gpa.create(Waiter);
        w.* = .{
            .call_id = try self.gpa.dupe(u8, call.tool_call_id),
            .name = try self.gpa.dupe(u8, call.tool_name),
            .args_json = try self.gpa.dupe(u8, call.args_json),
            .agent_id = try self.gpa.dupe(u8, call.agent_id),
        };
        self.mu.lockUncancelable(self.io);
        try self.by_id.put(w.call_id, w);
        self.cond.broadcast(self.io);
        self.mu.unlock(self.io);
        std.log.info("toolcb hold {s} id={s}", .{ w.name, w.call_id });
        return w;
    }

    pub fn wait(self: *Hub, w: *Waiter) ?[]const u8 {
        w.mu.lockUncancelable(self.io);
        defer w.mu.unlock(self.io);
        while (!w.done) {
            w.cond.waitUncancelable(self.io, &w.mu);
        }
        return w.result;
    }

    pub fn get(self: *Hub, call_id: []const u8) ?*Waiter {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.by_id.get(call_id);
    }

    pub fn fulfill(self: *Hub, call_id: []const u8, output: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        const w = self.by_id.get(call_id) orelse {
            self.mu.unlock(self.io);
            return false;
        };
        self.mu.unlock(self.io);
        const copy = self.gpa.dupe(u8, output) catch return false;
        w.mu.lockUncancelable(self.io);
        if (!w.done) {
            w.result = copy;
            w.done = true;
            w.cond.signal(self.io);
        } else {
            self.gpa.free(copy);
        }
        w.mu.unlock(self.io);
        std.log.info("toolcb fulfill id={s} bytes={d}", .{ call_id, output.len });
        return true;
    }

    pub fn forget(self: *Hub, w: *Waiter) void {
        self.mu.lockUncancelable(self.io);
        _ = self.by_id.remove(w.call_id);
        self.mu.unlock(self.io);
        if (w.result) |r| self.gpa.free(r);
        self.gpa.free(w.call_id);
        self.gpa.free(w.name);
        self.gpa.free(w.args_json);
        self.gpa.free(w.agent_id);
        self.gpa.destroy(w);
    }

    pub fn unresolvedCount(self: *Hub, agent_id: []const u8) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var n: usize = 0;
        var it = self.by_id.valueIterator();
        while (it.next()) |ptr| {
            const w = ptr.*;
            if (w.done) continue;
            if (agent_id.len > 0 and w.agent_id.len > 0 and !std.mem.eql(u8, w.agent_id, agent_id)) continue;
            n += 1;
        }
        return n;
    }

    pub fn snapshotUnresolved(self: *Hub, arena: std.mem.Allocator, agent_id: []const u8) ![]WaiterSnap {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var out = std.ArrayList(WaiterSnap).empty;
        var it = self.by_id.valueIterator();
        while (it.next()) |ptr| {
            const w = ptr.*;
            if (w.done) continue;
            if (agent_id.len > 0 and w.agent_id.len > 0 and !std.mem.eql(u8, w.agent_id, agent_id)) continue;
            try out.append(arena, .{
                .call_id = try arena.dupe(u8, w.call_id),
                .name = try arena.dupe(u8, w.name),
                .args_json = try arena.dupe(u8, w.args_json),
            });
        }
        return out.toOwnedSlice(arena);
    }

    pub fn unresolvedIds(self: *Hub, arena: std.mem.Allocator, agent_id: []const u8) ![][]const u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var out = std.ArrayList([]const u8).empty;
        var it = self.by_id.valueIterator();
        while (it.next()) |ptr| {
            const w = ptr.*;
            if (w.done) continue;
            if (agent_id.len > 0 and w.agent_id.len > 0 and !std.mem.eql(u8, w.agent_id, agent_id)) continue;
            try out.append(arena, try arena.dupe(u8, w.call_id));
        }
        return out.toOwnedSlice(arena);
    }
};

pub const WaiterSnap = struct {
    call_id: []const u8,
    name: []const u8,
    args_json: []const u8,
};

pub const ParsedCall = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    agent_id: []const u8,
    args_json: []const u8,
};

pub fn parseCall(arena: std.mem.Allocator, body: []const u8) !ParsedCall {
    var payload = body;
    if (payload.len >= 5 and payload[0] != '{') {
        const len = std.mem.readInt(u32, payload[1..5], .big);
        const start: usize = 5;
        const end = @min(payload.len, start + len);
        payload = payload[start..end];
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, payload, .{});
    const tool_name = jsonx.getStr(parsed.value, "toolName") orelse jsonx.getStr(parsed.value, "tool_name") orelse "";
    var tool_call_id = jsonx.getStr(parsed.value, "toolCallId") orelse jsonx.getStr(parsed.value, "tool_call_id") orelse "";
    const agent_id = jsonx.getStr(parsed.value, "agentId") orelse jsonx.getStr(parsed.value, "agent_id") orelse "";
    const args_val = jsonx.get(parsed.value, "args") orelse jsonx.get(parsed.value, "arguments") orelse .null;
    const args_json = switch (args_val) {
        .null => "{}",
        .string => |s| s,
        else => try jsonx.stringify(arena, args_val),
    };
    tool_call_id = firstLine(tool_call_id);
    const tool_name_clean = firstLine(tool_name);
    if (tool_call_id.len == 0) {
        tool_call_id = try std.fmt.allocPrint(arena, "call_{s}", .{tool_name_clean});
    }
    return .{
        .tool_name = tool_name_clean,
        .tool_call_id = tool_call_id,
        .agent_id = firstLine(agent_id),
        .args_json = args_json,
    };
}

fn firstLine(s: []const u8) []const u8 {
    const nl = std.mem.indexOfAny(u8, s, "\r\n") orelse return s;
    return s[0..nl];
}

pub fn acceptLoop(io: Io, listener: *Io.net.Server, hub: *Hub) void {
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.log.err("tool callback accept: {t}", .{err});
            return;
        };
        group.async(io, handleConn, .{ io, stream, hub });
    }
}

fn handleConn(io: Io, stream: Io.net.Stream, hub: *Hub) void {
    defer stream.close(io);
    var recv_buffer: [65536]u8 = undefined;
    var send_buffer: [16384]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    var arena_state = std.heap.ArenaAllocator.init(hub.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const incoming = rawhttp.readIncoming(
        &conn_reader.interface,
        &conn_writer.interface,
        arena,
        64 * 1024,
        1 * 1024 * 1024,
    ) catch |err| {
        const peek = conn_reader.interface.buffered();
        if (err == error.Incomplete and peek.len == 0) return;
        std.log.err("toolcb parse: {t} first={s}", .{ err, rawhttp.previewLine(peek) });
        return;
    };
    var reply = rawhttp.Reply{ .writer = &conn_writer.interface };
    serve(hub, incoming, &reply, arena) catch |err| {
        std.log.err("tool callback: {t}", .{err});
        if (!reply.started) {
            reply.json(500, "{\"code\":\"internal\"}\n", &.{.{ .name = "content-type", .value = "application/json" }}) catch {};
        }
    };
}

fn serve(hub: *Hub, req: rawhttp.Incoming, reply: *rawhttp.Reply, arena: std.mem.Allocator) !void {
    std.log.info("toolcb {s} {s}", .{ @tagName(req.method), req.path });
    if (req.method != .POST) {
        try reply.json(404, "{\"code\":\"unimplemented\"}\n", &.{.{ .name = "content-type", .value = "application/json" }});
        return;
    }
    const presented = rawhttp.header(req, "authorization") orelse "";
    const want = try std.fmt.allocPrint(arena, "Bearer {s}", .{hub.token});
    if (hub.token.len > 0 and !std.mem.eql(u8, presented, want)) {
        try reply.json(401, "{\"code\":\"unauthenticated\",\"message\":\"Unauthorized\"}\n", &.{.{ .name = "content-type", .value = "application/json" }});
        return;
    }
    var call = try parseCall(arena, req.body);
    if (call.tool_call_id.len == 0) {
        call.tool_call_id = try ids.hexId(hub.io, "call_", arena);
    }
    const w = try hub.announce(call);
    const output = hub.wait(w) orelse "";
    const body = try std.fmt.allocPrint(arena,
        "{{\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}]}}}}",
        .{std.json.fmt(output, .{})},
    );
    try reply.json(200, body, &.{.{ .name = "content-type", .value = "application/json" }});
    hub.forget(w);
}

test "parseCall reads camelCase Connect JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const call = try parseCall(arena.allocator(),
        \\{"toolName":"bash","toolCallId":"call_1","agentId":"agt_1","args":{"command":"echo hi"}}
    );
    try std.testing.expectEqualStrings("bash", call.tool_name);
    try std.testing.expectEqualStrings("call_1", call.tool_call_id);
    try std.testing.expectEqualStrings("agt_1", call.agent_id);
    try std.testing.expect(std.mem.indexOf(u8, call.args_json, "echo hi") != null);
}

test "parseCall unwraps connect+json frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = "{\"toolName\":\"read\",\"toolCallId\":\"c2\"}";
    var framed = try std.testing.allocator.alloc(u8, 5 + json.len);
    defer std.testing.allocator.free(framed);
    framed[0] = 0;
    std.mem.writeInt(u32, framed[1..5], @intCast(json.len), .big);
    @memcpy(framed[5..], json);
    const call = try parseCall(arena.allocator(), framed);
    try std.testing.expectEqualStrings("read", call.tool_name);
    try std.testing.expectEqualStrings("c2", call.tool_call_id);
}
