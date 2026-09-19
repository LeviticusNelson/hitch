const std = @import("std");

pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn obj(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

pub fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    const o = obj(v) orelse return null;
    return o.get(key);
}

pub fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const found = get(v, key) orelse return null;
    return switch (found) {
        .string => |s| s,
        else => null,
    };
}

pub fn getBool(v: std.json.Value, key: []const u8) ?bool {
    const found = get(v, key) orelse return null;
    return switch (found) {
        .bool => |b| b,
        else => null,
    };
}

pub fn isTrue(v: std.json.Value, key: []const u8) bool {
    return getBool(v, key) orelse false;
}

pub fn asStr(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn asArray(v: std.json.Value) ?[]std.json.Value {
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

pub fn collectText(v: std.json.Value, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendText(&out, allocator, v);
    return out.toOwnedSlice(allocator);
}

fn appendText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .string => |s| try out.appendSlice(allocator, s),
        .array => |a| {
            for (a.items) |item| {
                if (out.items.len > 0) try out.append(allocator, '\n');
                try appendText(out, allocator, item);
            }
        },
        .object => |o| {
            if (o.get("text")) |t| {
                if (asStr(t)) |s| {
                    try out.appendSlice(allocator, s);
                    return;
                }
            }
            if (o.get("content")) |c| {
                try appendText(out, allocator, c);
            }
        },
        else => {},
    }
}

test "getStr reads object field" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"model\":\"grok-4.6\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("grok-4.6", getStr(parsed.value, "model").?);
}
