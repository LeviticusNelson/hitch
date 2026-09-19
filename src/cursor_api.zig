const std = @import("std");
const Io = std.Io;
const jsonx = @import("jsonx.zig");

pub const base_url = "https://api.cursor.com";

pub const Model = struct {
    id: []const u8,
    display_name: []const u8,
    description: []const u8 = "",
};

pub const Identity = struct {
    api_key_name: []const u8 = "",
    user_email: []const u8 = "",
    user_id: []const u8 = "",
    created_at: []const u8 = "",
    first_name: []const u8 = "",
    last_name: []const u8 = "",
};

pub const Catalog = struct {
    io: Io,
    gpa: std.mem.Allocator,
    client: std.http.Client,
    api_key: []const u8,

    pub fn get(self: *Catalog, arena: std.mem.Allocator, path: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ base_url, path });
        const authz = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key});
        var aw: std.Io.Writer.Allocating = .init(arena);
        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = authz },
            },
            .response_writer = &aw.writer,
            .keep_alive = true,
            .redirect_behavior = .unhandled,
        });
        const body = try aw.toOwnedSlice();
        if (@intFromEnum(result.status) >= 400) {
            std.log.warn("cursor api {s} status={d}", .{ path, @intFromEnum(result.status) });
            return error.CursorApiFailed;
        }
        return body;
    }

    pub fn listModels(self: *Catalog, arena: std.mem.Allocator) ![]Model {
        const body = try self.get(arena, "/v1/models");
        return parseModels(arena, body);
    }

    pub fn me(self: *Catalog, arena: std.mem.Allocator) !Identity {
        const body = try self.get(arena, "/v1/me");
        return parseMe(arena, body);
    }
};

pub fn parseModels(allocator: std.mem.Allocator, body: []const u8) ![]Model {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    const root = parsed.value;
    const list = jsonx.asArray(jsonx.get(root, "items") orelse jsonx.get(root, "data") orelse .null) orelse return error.BadCatalog;
    var out = std.ArrayList(Model).empty;
    for (list) |item| {
        const id = jsonx.getStr(item, "id") orelse continue;
        if (id.len == 0) continue;
        try out.append(allocator, .{
            .id = id,
            .display_name = jsonx.getStr(item, "displayName") orelse jsonx.getStr(item, "display_name") orelse id,
            .description = jsonx.getStr(item, "description") orelse "",
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn parseMe(allocator: std.mem.Allocator, body: []const u8) !Identity {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    const root = parsed.value;
    var ident: Identity = .{};
    ident.api_key_name = jsonx.getStr(root, "apiKeyName") orelse jsonx.getStr(root, "api_key_name") orelse "";
    ident.user_email = jsonx.getStr(root, "userEmail") orelse "";
    ident.created_at = jsonx.getStr(root, "createdAt") orelse "";
    ident.first_name = jsonx.getStr(root, "userFirstName") orelse "";
    ident.last_name = jsonx.getStr(root, "userLastName") orelse "";
    if (jsonx.get(root, "userId")) |id| {
        ident.user_id = switch (id) {
            .string => |s| s,
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            else => "",
        };
    }
    return ident;
}

test "parseModels reads items catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const models = try parseModels(arena.allocator(),
        \\{"items":[{"id":"grok-4.6","displayName":"Grok 4.6","description":"xAI"},{"id":"composer-2.5","displayName":"Composer 2.5"}]}
    );
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("grok-4.6", models[0].id);
    try std.testing.expectEqualStrings("Grok 4.6", models[0].display_name);
}

test "parseMe reads apiKeyName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ident = try parseMe(arena.allocator(),
        \\{"apiKeyName":"work","userId":42,"userEmail":"a@b.c","createdAt":"2026-01-01T00:00:00.000Z"}
    );
    try std.testing.expectEqualStrings("work", ident.api_key_name);
    try std.testing.expectEqualStrings("42", ident.user_id);
    try std.testing.expectEqualStrings("a@b.c", ident.user_email);
}
