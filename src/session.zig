const std = @import("std");
const Io = std.Io;
const encode = @import("encode.zig");

pub const PendingTool = struct {
    call_id: []u8,
    name: []u8,
    args: []u8,
    result: ?[]u8 = null,
};

pub const Session = struct {
    id: []u8,
    agent_id: []u8,
    model: []u8,
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(PendingTool) = .empty,
    done: bool = false,
    failed: ?[]const u8 = null,
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
};

pub const Registry = struct {
    io: Io,
    gpa: std.mem.Allocator,
    mu: Io.Mutex = .init,
    by_id: std.StringHashMap(*Session),
    by_agent: std.StringHashMap(*Session),

    pub fn init(io: Io, gpa: std.mem.Allocator) Registry {
        return .{
            .io = io,
            .gpa = gpa,
            .by_id = std.StringHashMap(*Session).init(gpa),
            .by_agent = std.StringHashMap(*Session).init(gpa),
        };
    }

    pub fn getOrCreate(self: *Registry, session_id: []const u8, model: []const u8) !*Session {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.by_id.get(session_id)) |s| return s;
        const s = try self.gpa.create(Session);
        s.* = .{
            .id = try self.gpa.dupe(u8, session_id),
            .agent_id = try self.gpa.dupe(u8, ""),
            .model = try self.gpa.dupe(u8, model),
        };
        try self.by_id.put(s.id, s);
        return s;
    }

    pub fn bindAgent(self: *Registry, s: *Session, agent_id: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const copy = try self.gpa.dupe(u8, agent_id);
        s.agent_id = copy;
        try self.by_agent.put(copy, s);
    }

    pub fn byAgent(self: *Registry, agent_id: []const u8) ?*Session {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.by_agent.get(agent_id);
    }

    pub fn bySession(self: *Registry, session_id: []const u8) ?*Session {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.by_id.get(session_id);
    }
};

pub fn snapshotTurn(s: *Session, arena: std.mem.Allocator, message_id: []const u8, now: i64) !encode.Turn {
    var tools = try arena.alloc(encode.ToolCall, s.tools.items.len);
    for (s.tools.items, 0..) |t, i| {
        tools[i] = .{
            .id = t.call_id,
            .name = t.name,
            .arguments = t.args,
        };
    }
    const stop: []const u8 = if (s.tools.items.len > 0 and !s.done) "tool_use" else "end_turn";
    return .{
        .message_id = message_id,
        .session_id = s.id,
        .model = s.model,
        .created_at = now,
        .text = try arena.dupe(u8, s.text.items),
        .thinking = try arena.dupe(u8, s.thinking.items),
        .tools = tools,
        .stop_reason = stop,
        .input_tokens = 1,
        .output_tokens = @max(@as(u32, 1), @as(u32, @intCast(@min(s.text.items.len, 16_000) / 4))),
    };
}
