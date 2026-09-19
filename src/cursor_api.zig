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

pub const ListResult = struct {
    models: []Model,
    stale: bool,
};

/// Prefer a live fetch, then the last full catalog, then the tiny fake list.
/// Never replace a populated live cache with Fake's 4 ids (GET /v1/models flake).
pub fn chooseModels(live: ?[]Model, cached: []const Model, fake: []const Model) struct { models: []const Model, stale: bool } {
    if (live) |m| {
        if (m.len > 0) return .{ .models = m, .stale = false };
    }
    if (cached.len > 0) return .{ .models = cached, .stale = true };
    return .{ .models = fake, .stale = true };
}

pub const Catalog = struct {
    io: Io,
    gpa: std.mem.Allocator,
    client: std.http.Client,
    api_key: []const u8,
    mu: Io.Mutex = .init,
    cached: []Model = &.{},
    cached_at_ms: i64 = 0,
    ttl_ms: i64 = 5 * 60 * 1000,

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

    pub fn listModels(self: *Catalog, arena: std.mem.Allocator) !ListResult {
        const now = nowMs(self);
        self.mu.lockUncancelable(self.io);
        const fresh = self.cached.len > 0 and now - self.cached_at_ms >= 0 and now - self.cached_at_ms < self.ttl_ms;
        if (fresh) {
            const copy = copyModels(arena, self.cached) catch {
                self.mu.unlock(self.io);
                return error.OutOfMemory;
            };
            self.mu.unlock(self.io);
            return .{ .models = copy, .stale = false };
        }
        self.mu.unlock(self.io);

        const live = self.fetchLive(arena);
        if (live) |models| {
            if (models.len > 0) {
                self.mu.lockUncancelable(self.io);
                self.storeCache(models) catch {};
                self.mu.unlock(self.io);
                return .{ .models = models, .stale = false };
            }
        } else |_| {}

        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.cached.len > 0) {
            return .{ .models = try copyModels(arena, self.cached), .stale = true };
        }
        return error.CursorApiFailed;
    }

    pub fn warm(self: *Catalog, arena: std.mem.Allocator) void {
        const result = self.listModels(arena) catch |err| {
            std.log.warn("catalog warm failed ({t}); GET /v1/models will retry", .{err});
            return;
        };
        std.log.info("catalog warm n={d} stale={d}", .{ result.models.len, @intFromBool(result.stale) });
    }

    fn fetchLive(self: *Catalog, arena: std.mem.Allocator) ![]Model {
        const body = try self.get(arena, "/v1/models");
        return parseModels(arena, body);
    }

    fn storeCache(self: *Catalog, models: []const Model) !void {
        const copy = try copyModels(self.gpa, models);
        self.clearCache();
        self.cached = copy;
        self.cached_at_ms = nowMs(self);
    }

    fn clearCache(self: *Catalog) void {
        for (self.cached) |m| {
            self.gpa.free(m.id);
            self.gpa.free(m.display_name);
            self.gpa.free(m.description);
        }
        if (self.cached.len > 0) self.gpa.free(self.cached);
        self.cached = &.{};
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

fn nowMs(self: *Catalog) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_ms));
}

fn copyModels(allocator: std.mem.Allocator, models: []const Model) ![]Model {
    const copy = try allocator.alloc(Model, models.len);
    var i: usize = 0;
    errdefer {
        for (copy[0..i]) |m| {
            allocator.free(m.id);
            allocator.free(m.display_name);
            allocator.free(m.description);
        }
        allocator.free(copy);
    }
    while (i < models.len) : (i += 1) {
        copy[i] = .{
            .id = try allocator.dupe(u8, models[i].id),
            .display_name = try allocator.dupe(u8, models[i].display_name),
            .description = try allocator.dupe(u8, models[i].description),
        };
    }
    return copy;
}

test "chooseModels never replaces a full cache with the fake four" {
    const live_empty: []Model = &.{};
    var cached = [_]Model{
        .{ .id = "grok-4.6", .display_name = "Cursor Grok 4.6" },
        .{ .id = "composer-2.5", .display_name = "Composer 2.5" },
    };
    var fake = [_]Model{
        .{ .id = "grok-4.6", .display_name = "grok-4.6" },
        .{ .id = "composer-2", .display_name = "composer-2" },
        .{ .id = "composer-2.5", .display_name = "composer-2.5" },
        .{ .id = "default", .display_name = "default" },
    };
    const miss = chooseModels(live_empty, &cached, &fake);
    try std.testing.expect(miss.stale);
    try std.testing.expectEqual(@as(usize, 2), miss.models.len);
    try std.testing.expectEqualStrings("grok-4.6", miss.models[0].id);

    var live = [_]Model{.{ .id = "gpt-5.4", .display_name = "GPT-5.4" }};
    const hit = chooseModels(live[0..], &cached, &fake);
    try std.testing.expect(!hit.stale);
    try std.testing.expectEqual(@as(usize, 1), hit.models.len);

    const none = chooseModels(null, &.{}, &fake);
    try std.testing.expect(none.stale);
    try std.testing.expectEqual(@as(usize, 4), none.models.len);
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
