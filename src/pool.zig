const std = @import("std");
const Io = std.Io;

pub const Pool = struct {
    io: Io,
    gpa: std.mem.Allocator,
    keys: []const []const u8,
    next: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mu: Io.Mutex = .init,
    binds: std.StringHashMap([]const u8),

    pub fn init(io: Io, gpa: std.mem.Allocator, keys: []const []const u8) Pool {
        return .{
            .io = io,
            .gpa = gpa,
            .keys = keys,
            .binds = std.StringHashMap([]const u8).init(gpa),
        };
    }

    pub fn bindOrPick(self: *Pool, session_id: []const u8) ?[]const u8 {
        if (self.keys.len == 0) return null;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.binds.get(session_id)) |k| return k;
        const i = self.next.fetchAdd(1, .seq_cst) % self.keys.len;
        const key = self.keys[i];
        const sid = self.gpa.dupe(u8, session_id) catch return key;
        const val = self.gpa.dupe(u8, key) catch return key;
        self.binds.put(sid, val) catch {};
        return val;
    }

    pub fn failover(self: *Pool, session_id: []const u8, failed: []const u8) ?[]const u8 {
        if (self.keys.len < 2) return null;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var i: usize = 0;
        while (i < self.keys.len) : (i += 1) {
            if (std.mem.eql(u8, self.keys[i], failed)) continue;
            const sid = self.gpa.dupe(u8, session_id) catch return self.keys[i];
            const val = self.gpa.dupe(u8, self.keys[i]) catch return self.keys[i];
            self.binds.put(sid, val) catch {};
            return val;
        }
        return null;
    }
};

pub fn splitKeys(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        try out.append(allocator, t);
    }
    return out.toOwnedSlice(allocator);
}

test "splitKeys trims and drops empties" {
    const keys = try splitKeys(std.testing.allocator, " a, b, ,c ");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqualStrings("a", keys[0]);
    try std.testing.expectEqualStrings("c", keys[2]);
}
