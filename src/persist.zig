const std = @import("std");
const Io = std.Io;
const jsonx = @import("jsonx.zig");

pub const ToolRec = struct {
    call_id: []const u8,
    name: []const u8,
    args: []const u8,
};

pub const Record = struct {
    session_id: []const u8,
    agent_id: []const u8,
    model: []const u8,
    effort: []const u8 = "",
    lineage: []const u8 = "",
    tools: []ToolRec = &.{},
};

pub fn encodeRecord(allocator: std.mem.Allocator, rec: Record) ![]u8 {
    var tools = std.ArrayList(u8).empty;
    try tools.append(allocator, '[');
    for (rec.tools, 0..) |t, i| {
        if (i > 0) try tools.append(allocator, ',');
        try tools.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            "{{\"call_id\":{f},\"name\":{f},\"args\":{f}}}",
            .{ std.json.fmt(t.call_id, .{}), std.json.fmt(t.name, .{}), std.json.fmt(t.args, .{}) },
        ));
    }
    try tools.append(allocator, ']');
    return std.fmt.allocPrint(allocator,
        "{{\"session_id\":{f},\"agent_id\":{f},\"model\":{f},\"effort\":{f},\"lineage\":{f},\"tools\":{s}}}\n",
        .{
            std.json.fmt(rec.session_id, .{}),
            std.json.fmt(rec.agent_id, .{}),
            std.json.fmt(rec.model, .{}),
            std.json.fmt(rec.effort, .{}),
            std.json.fmt(rec.lineage, .{}),
            tools.items,
        },
    );
}

pub fn decodeRecord(allocator: std.mem.Allocator, line: []const u8) !Record {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.Empty;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    const v = parsed.value;
    const session_id = jsonx.getStr(v, "session_id") orelse return error.BadRecord;
    const agent_id = jsonx.getStr(v, "agent_id") orelse return error.BadRecord;
    const model = jsonx.getStr(v, "model") orelse "";
    var tools = std.ArrayList(ToolRec).empty;
    if (jsonx.asArray(jsonx.get(v, "tools") orelse .null)) |arr| {
        for (arr) |item| {
            try tools.append(allocator, .{
                .call_id = jsonx.getStr(item, "call_id") orelse continue,
                .name = jsonx.getStr(item, "name") orelse "",
                .args = jsonx.getStr(item, "args") orelse "{}",
            });
        }
    }
    return .{
        .session_id = session_id,
        .agent_id = agent_id,
        .model = model,
        .effort = jsonx.getStr(v, "effort") orelse "",
        .lineage = jsonx.getStr(v, "lineage") orelse "",
        .tools = try tools.toOwnedSlice(allocator),
    };
}

pub fn upsertFile(io: Io, path: []const u8, rec: Record, allocator: std.mem.Allocator) !void {
    const existing = readAll(io, allocator, path) catch &.{};
    var kept = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        const other = decodeRecord(allocator, line) catch continue;
        if (std.mem.eql(u8, other.session_id, rec.session_id)) continue;
        try kept.appendSlice(allocator, line);
        try kept.append(allocator, '\n');
    }
    try kept.appendSlice(allocator, try encodeRecord(allocator, rec));
    try writeAll(io, path, kept.items);
}

pub fn removeSession(io: Io, path: []const u8, session_id: []const u8, allocator: std.mem.Allocator) void {
    const existing = readAll(io, allocator, path) catch return;
    var kept = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        const other = decodeRecord(allocator, line) catch continue;
        if (std.mem.eql(u8, other.session_id, session_id)) continue;
        kept.appendSlice(allocator, line) catch return;
        kept.append(allocator, '\n') catch return;
    }
    writeAll(io, path, kept.items) catch {};
}

pub fn loadAll(io: Io, path: []const u8, allocator: std.mem.Allocator) ![]Record {
    const existing = readAll(io, allocator, path) catch return &.{};
    var out = std.ArrayList(Record).empty;
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        const rec = decodeRecord(allocator, line) catch continue;
        try out.append(allocator, rec);
    }
    return out.toOwnedSlice(allocator);
}

fn readAll(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return error.Missing;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    return reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
}

fn writeAll(io: Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

test "pending record round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rec = Record{
        .session_id = "ses_1",
        .agent_id = "ag_1",
        .model = "grok-4.6",
        .effort = "high",
        .lineage = "abc",
        .tools = &.{.{ .call_id = "c1", .name = "lookup", .args = "{}" }},
    };
    const line = try encodeRecord(arena.allocator(), rec);
    const back = try decodeRecord(arena.allocator(), line);
    try std.testing.expectEqualStrings("ses_1", back.session_id);
    try std.testing.expectEqualStrings("c1", back.tools[0].call_id);
    try std.testing.expectEqualStrings("lookup", back.tools[0].name);
}
