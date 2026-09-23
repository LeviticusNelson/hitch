const std = @import("std");
const Io = std.Io;
const jsonx = @import("jsonx.zig");

pub const Server = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8,
};

pub fn looksLikeMcpFailure(output: []const u8) bool {
    if (output.len == 0) return false;
    const needles = [_][]const u8{
        "mcp server",
        "mcp error",
        "failed to connect",
        "connection refused",
        "server disconnected",
        "not connected",
        "server error",
        "could not connect",
    };
    var lower_buf: [4096]u8 = undefined;
    const n = @min(output.len, lower_buf.len);
    for (output[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..n];
    for (needles) |needle| {
        if (std.mem.indexOf(u8, lower, needle) != null) return true;
    }
    return false;
}

pub fn pickServer(servers: []const Server, tool_name: []const u8, args_json: []const u8, output: []const u8) ?Server {
    if (serverNamed(servers, tool_name)) |s| return s;
    if (std.mem.eql(u8, tool_name, "use_tool")) {
        var buf: [128]u8 = undefined;
        if (jsonFieldCopy(args_json, "server", &buf) orelse jsonFieldCopy(args_json, "server_name", &buf)) |name| {
            if (serverNamed(servers, name)) |s| return s;
        }
    }
    for (servers) |s| {
        if (std.mem.indexOf(u8, tool_name, s.name) != null) return s;
        if (std.mem.indexOf(u8, output, s.name) != null) return s;
    }
    return null;
}

fn serverNamed(servers: []const Server, name: []const u8) ?Server {
    for (servers) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

fn jsonFieldCopy(json: []const u8, key: []const u8, buf: []u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch return null;
    defer parsed.deinit();
    const s = jsonx.getStr(parsed.value, key) orelse return null;
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

pub fn loadUserServers(io: Io, gpa: std.mem.Allocator) []const Server {
    const home = std.c.getenv("HOME") orelse return &.{};
    const path = std.fs.path.join(gpa, &.{ std.mem.span(home), ".cursor", "mcp.json" }) catch return &.{};
    defer gpa.free(path);
    return loadFile(io, gpa, path) catch &.{};
}

fn loadFile(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]const Server {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return &.{};
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    const data = reader.interface.allocRemaining(gpa, .limited(1024 * 1024)) catch return &.{};
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return &.{};
    const root = jsonx.get(parsed.value, "mcpServers") orelse return &.{};
    var out = std.ArrayList(Server).empty;
    switch (root) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const command = jsonx.getStr(entry.value_ptr.*, "command") orelse continue;
                var args = std.ArrayList([]const u8).empty;
                if (jsonx.asArray(jsonx.get(entry.value_ptr.*, "args") orelse .null)) |arr| {
                    for (arr) |item| {
                        if (item == .string) try args.append(gpa, try gpa.dupe(u8, item.string));
                    }
                }
                try out.append(gpa, .{
                    .name = try gpa.dupe(u8, entry.key_ptr.*),
                    .command = try gpa.dupe(u8, command),
                    .args = try args.toOwnedSlice(gpa),
                });
            }
        },
        else => {},
    }
    return out.toOwnedSlice(gpa);
}

pub fn tryCall(io: Io, gpa: std.mem.Allocator, server: Server, tool_name: []const u8, args_json: []const u8) ?[]u8 {
    var name_buf: [256]u8 = undefined;
    var args_buf: [8192]u8 = undefined;
    const inner = if (std.mem.eql(u8, tool_name, "use_tool"))
        jsonFieldCopy(args_json, "tool_name", &name_buf) orelse jsonFieldCopy(args_json, "name", &name_buf) orelse tool_name
    else
        tool_name;
    const inner_args = if (std.mem.eql(u8, tool_name, "use_tool"))
        jsonFieldCopy(args_json, "tool_input", &args_buf) orelse jsonFieldCopy(args_json, "arguments", &args_buf) orelse "{}"
    else
        args_json;
    var argv = std.ArrayList([]const u8).empty;
    argv.append(gpa, server.command) catch return null;
    for (server.args) |a| argv.append(gpa, a) catch return null;
    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    var proc = child;
    defer _ = proc.wait(io) catch {};
    const stdin = proc.stdin orelse return null;
    const stdout = proc.stdout orelse return null;
    var in_buf: [1024]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var writer = stdin.writerStreaming(io, &in_buf);
    var reader = stdout.readerStreaming(io, &out_buf);
    const init_msg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"hitch\",\"version\":\"0.2.1\"}}}";
    writeMsg(&writer.interface, init_msg) catch return null;
    _ = readMsg(gpa, &reader.interface) orelse return null;
    writeMsg(&writer.interface, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") catch return null;
    const call = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":{f},\"arguments\":{s}}}}}", .{
        std.json.fmt(inner, .{}),
        if (inner_args.len > 0 and inner_args[0] == '{') inner_args else "{}",
    }) catch return null;
    writeMsg(&writer.interface, call) catch return null;
    const body = readMsg(gpa, &reader.interface) orelse return null;
    return extractText(gpa, body);
}

fn writeMsg(w: *std.Io.Writer, json: []const u8) !void {
    try w.print("Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
    try w.flush();
}

fn readMsg(gpa: std.mem.Allocator, r: *std.Io.Reader) ?[]u8 {
    var len: usize = 0;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch return null;
        if (line.len <= 2) break;
        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
            const num = std.mem.trim(u8, trimmed["Content-Length:".len..], " ");
            len = std.fmt.parseInt(usize, num, 10) catch return null;
        }
    }
    if (len == 0 or len > 1024 * 1024) return null;
    const buf = gpa.alloc(u8, len) catch return null;
    r.readSliceAll(buf) catch return null;
    return buf;
}

fn extractText(gpa: std.mem.Allocator, body: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    const result = jsonx.get(parsed.value, "result") orelse return null;
    if (jsonx.asArray(jsonx.get(result, "content") orelse .null)) |content| {
        var out = std.ArrayList(u8).empty;
        for (content) |item| {
            const text = jsonx.getStr(item, "text") orelse continue;
            out.appendSlice(gpa, text) catch return null;
            out.append(gpa, '\n') catch return null;
        }
        if (out.items.len == 0) return null;
        return out.toOwnedSlice(gpa) catch null;
    }
    const text = jsonx.getStr(result, "text") orelse return null;
    return gpa.dupe(u8, text) catch null;
}

pub fn maybeFallback(io: Io, gpa: std.mem.Allocator, tool_name: []const u8, args_json: []const u8, client_output: []const u8) ?[]u8 {
    if (!looksLikeMcpFailure(client_output)) return null;
    const servers = loadUserServers(io, gpa);
    const server = pickServer(servers, tool_name, args_json, client_output) orelse return null;
    std.log.info("mcp fallback server={s} tool={s}", .{ server.name, tool_name });
    return tryCall(io, gpa, server, tool_name, args_json);
}

test "mcp failure text is recognized and a server name matches" {
    try std.testing.expect(looksLikeMcpFailure("MCP server bitbucket disconnected"));
    try std.testing.expect(!looksLikeMcpFailure("file not found"));
    const servers = [_]Server{
        .{ .name = "bitbucket", .command = "echo", .args = &.{} },
        .{ .name = "linear", .command = "echo", .args = &.{} },
    };
    const picked = pickServer(&servers, "use_tool", "{\"server\":\"linear\",\"tool_name\":\"list\"}", "mcp server error");
    try std.testing.expectEqualStrings("linear", picked.?.name);
}
