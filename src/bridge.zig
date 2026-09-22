const std = @import("std");
const Io = std.Io;
const digest = @import("digest.zig");
const encode = @import("encode.zig");
const jsonx = @import("jsonx.zig");
const models = @import("models.zig");
const persist = @import("persist.zig");
const pool_mod = @import("pool.zig");
const protocol = @import("protocol.zig");
const toolcb = @import("toolcb.zig");

const BoundAgent = struct {
    id: []const u8,
    model: []const u8,
};

pub const Sink = struct {
    ctx: *anyopaque = undefined,
    on_text: ?*const fn (*anyopaque, []const u8) void = null,
    on_thinking: ?*const fn (*anyopaque, []const u8) void = null,
};

pub const Bridge = struct {
    io: Io,
    gpa: std.mem.Allocator,
    client: std.http.Client,
    base_url: []const u8,
    bearer: []const u8,
    api_key: []const u8,
    workspace: []const u8,
    child: ?std.process.Child = null,
    agents: std.StringHashMap(BoundAgent) = undefined,
    efforts: std.StringHashMap([]const u8) = undefined,
    lives: std.StringHashMap(*Live) = undefined,
    lineage: std.StringHashMap([]const u8) = undefined,
    hub: *toolcb.Hub,
    group: *Io.Group,
    mu: Io.Mutex = .init,
    last_err: []const u8 = "",
    persist_path: []const u8 = "",
    pool: ?*pool_mod.Pool = null,

    pub fn unary(self: *Bridge, arena: std.mem.Allocator, path: []const u8, payload: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base_url, path });
        const authz = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.bearer});
        var aw: std.Io.Writer.Allocating = .init(arena);
        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .headers = .{
                .authorization = .{ .override = authz },
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = &.{
                .{ .name = "Connect-Protocol-Version", .value = "1" },
            },
            .response_writer = &aw.writer,
            .keep_alive = true,
            .redirect_behavior = .unhandled,
        });
        const body = try aw.toOwnedSlice();
        if (@intFromEnum(result.status) >= 400) {
            std.log.warn("bridge {s} status={d} body={s}", .{ path, @intFromEnum(result.status), body });
            return error.BridgeRpcFailed;
        }
        return body;
    }

    pub fn ping(self: *Bridge, arena: std.mem.Allocator) !void {
        const body = try self.unary(arena, "/sdk.v1.SdkBridgeControlService/Ping", "{}");
        if (std.mem.indexOf(u8, body, "pong") == null) return error.BridgePingFailed;
    }

    pub fn listModels(self: *Bridge, arena: std.mem.Allocator) ![]const []const u8 {
        const payload = try std.fmt.allocPrint(arena, "{{\"options\":{{\"apiKey\":{f}}}}}", .{std.json.fmt(self.api_key, .{})});
        const body = try self.unary(arena, "/sdk.v1.SdkCursorService/ListModels", payload);
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
        var ids = std.ArrayList([]const u8).empty;
        if (jsonx.asArray(jsonx.get(parsed.value, "items") orelse .null)) |items| {
            for (items) |item| {
                if (jsonx.getStr(item, "id")) |id| try ids.append(arena, id);
            }
        }
        return ids.toOwnedSlice(arena);
    }

    pub fn run(self: *Bridge, arena: std.mem.Allocator, parsed: protocol.Parsed, session_id: []const u8, message_id: []const u8, now: i64) !encode.Turn {
        return self.runStreaming(arena, parsed, session_id, message_id, now, .{});
    }

    pub fn runStreaming(
        self: *Bridge,
        arena: std.mem.Allocator,
        parsed: protocol.Parsed,
        session_id: []const u8,
        message_id: []const u8,
        now: i64,
        sink: Sink,
    ) !encode.Turn {
        self.last_err = "";
        if (parsed.continuation.len > 0) {
            var restored = false;
            if (self.liveForContinuation(session_id, parsed.continuation) == null) {
                restored = (self.restorePending(arena, parsed, session_id) catch null) != null;
            }
            try self.preflightContinuation(arena, parsed, session_id);
            const live = self.liveForContinuation(session_id, parsed.continuation);
            const live_ptr = live orelse {
                self.last_err = try std.fmt.allocPrint(arena, "unknown tool_use_id: {s}", .{parsed.continuation[0].call_id});
                return error.UnknownToolId;
            };
            try self.applyContinuation(arena, live_ptr, parsed);
            if (restored) {
                const send_json_tmp = try std.fmt.allocPrint(arena,
                    "{{\"agentId\":{f},\"message\":{{\"text\":\"\"}},\"options\":{{\"enableDeltas\":true{s}}}}}",
                    .{ std.json.fmt(live_ptr.agent_id, .{}), try sendLocalSuffix(arena, parsed.tools, true) },
                );
                live_ptr.send_json = try self.gpa.dupe(u8, send_json_tmp);
                self.group.concurrent(self.io, sendLoop, .{live_ptr}) catch self.group.async(self.io, sendLoop, .{live_ptr});
            }
            live_ptr.setSink(sink);
            defer live_ptr.setSink(.{});
            return self.waitBoundary(arena, live_ptr, parsed, message_id, session_id, now, true);
        }

        const prefix = digest.stripLastUserBlock(parsed.flatten_text, parsed.last_user_text);
        const sent_effort = models.cursorEffortParam(parsed.upstream_model, parsed.effort) orelse "";
        const policy = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ parsed.upstream_model, sent_effort });
        const lookup = digest.lineageKey(policy, parsed.system_text, prefix);
        self.mu.lockUncancelable(self.io);
        const same_model = if (self.agents.get(session_id)) |bound| std.mem.eql(u8, bound.model, parsed.upstream_model) else false;
        const known = same_model or self.lineage.get(lookup[0..]) != null;
        self.mu.unlock(self.io);
        const agent_id = try self.ensureAgent(arena, parsed, session_id);
        const raw_prompt = if (known and parsed.last_user_text.len > 0) parsed.last_user_text else parsed.flatten_text;
        const prompt = clip(raw_prompt, models.sdkPromptMaxCharsForModel(parsed.upstream_model));
        const images_json = try imagesJson(arena, parsed.images);
        const send_json_tmp = try std.fmt.allocPrint(arena,
            "{{\"agentId\":{f},\"message\":{{\"text\":{f}{s}}},\"options\":{{\"enableDeltas\":true{s}}}}}",
            .{ std.json.fmt(agent_id, .{}), std.json.fmt(prompt, .{}), images_json, try sendLocalSuffix(arena, parsed.tools, false) },
        );
        const live = try self.gpa.create(Live);
        live.* = .{
            .bridge = self,
            .io = self.io,
            .gpa = self.gpa,
            .arena_state = std.heap.ArenaAllocator.init(self.gpa),
            .send_json = try self.gpa.dupe(u8, send_json_tmp),
            .sink = sink,
            .agent_id = try self.gpa.dupe(u8, agent_id),
            .session_id = try self.gpa.dupe(u8, session_id),
            .catalog = try dupeTools(self.gpa, parsed.tools),
        };
        self.mu.lockUncancelable(self.io);
        try self.lives.put(live.session_id, live);
        self.mu.unlock(self.io);
        self.group.concurrent(self.io, sendLoop, .{live}) catch self.group.async(self.io, sendLoop, .{live});
        defer live.setSink(.{});
        return self.waitBoundary(arena, live, parsed, message_id, session_id, now, false);
    }

    pub fn forgetSession(self: *Bridge, session_id: []const u8) void {
        if (self.persist_path.len > 0) {
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            persist.removeSession(self.io, self.persist_path, session_id, scratch.allocator());
            scratch.deinit();
        }
        self.mu.lockUncancelable(self.io);
        const agent = self.agents.get(session_id);
        _ = self.agents.remove(session_id);
        _ = self.lives.remove(session_id);
        if (agent) |bound| {
            var drop = std.ArrayList([]const u8).empty;
            var it = self.lineage.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.value_ptr.*, bound.id)) drop.append(self.gpa, e.key_ptr.*) catch {};
            }
            for (drop.items) |k| _ = self.lineage.remove(k);
            if (drop.items.len > 0) self.gpa.free(drop.items);
            self.mu.unlock(self.io);
            self.hub.cancelAgent(bound.id);
            std.log.info("forget session={s} agent={s}", .{ session_id, bound.id });
            return;
        }
        self.mu.unlock(self.io);
    }

    fn getLive(self: *Bridge, session_id: []const u8) ?*Live {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.lives.get(session_id);
    }

    /// Fail closed before SSE: orphan function_call_output is unknown tool_use_id, not a 200 stream.
    pub fn preflightContinuation(self: *Bridge, arena: std.mem.Allocator, parsed: protocol.Parsed, session_id: []const u8) !void {
        if (parsed.continuation.len == 0) return;
        const live = self.liveForContinuation(session_id, parsed.continuation) orelse {
            self.last_err = try std.fmt.allocPrint(arena, "unknown tool_use_id: {s}", .{parsed.continuation[0].call_id});
            return error.UnknownToolId;
        };
        const hub_pending = try self.hub.unresolvedIds(arena, live.agent_id);
        const published = try copyIds(arena, live.published_ids.items);
        const pending = protocol.continuationRequiredIds(published, hub_pending);
        const pool: []const protocol.ToolResult = if (parsed.all_outputs.len > 0) parsed.all_outputs else parsed.continuation;
        const live_results = try protocol.selectPendingResults(arena, pool, pending);
        if (pending.len == 0 or live_results.len == 0) {
            if (self.continuationAlreadyApplied(parsed.continuation)) return;
            self.last_err = try std.fmt.allocPrint(arena, "unknown tool_use_id: {s}", .{parsed.continuation[0].call_id});
            return error.UnknownToolId;
        }
        if (live_results.len != pending.len) {
            self.last_err = try std.fmt.allocPrint(arena, "missing tool_result for: {s}", .{try joinIds(arena, pending)});
            return error.MissingToolResult;
        }
    }

    fn liveByAgent(self: *Bridge, agent_id: []const u8) ?*Live {
        if (agent_id.len == 0) return null;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var it = self.lives.valueIterator();
        while (it.next()) |ptr| {
            const live = ptr.*;
            if (std.mem.eql(u8, live.agent_id, agent_id)) return live;
        }
        return null;
    }

    pub fn liveForContinuation(self: *Bridge, session_id: []const u8, continuation: []const protocol.ToolResult) ?*Live {
        if (self.getLive(session_id)) |live| return live;
        for (continuation) |c| {
            const agent_id = if (self.hub.get(c.call_id)) |w| w.agent_id else self.hub.spentAgent(c.call_id) orelse continue;
            if (self.liveByAgent(agent_id)) |live| return live;
        }
        return null;
    }

    fn continuationAlreadyApplied(self: *Bridge, continuation: []const protocol.ToolResult) bool {
        if (continuation.len == 0) return false;
        for (continuation) |c| {
            if (!self.hub.isSpent(c.call_id)) return false;
        }
        return true;
    }

    fn applyContinuation(self: *Bridge, arena: std.mem.Allocator, live: *Live, parsed: protocol.Parsed) !void {
        const hub_pending = try self.hub.unresolvedIds(arena, live.agent_id);
        const published = try copyIds(arena, live.published_ids.items);
        const pending = protocol.continuationRequiredIds(published, hub_pending);
        const pool: []const protocol.ToolResult = if (parsed.all_outputs.len > 0) parsed.all_outputs else parsed.continuation;
        const live_results = try protocol.selectPendingResults(arena, pool, pending);
        std.log.info("continue pending={d} published={d} hub={d} trailing={d} outputs={d} live={d}", .{
            pending.len,
            published.len,
            hub_pending.len,
            parsed.continuation.len,
            pool.len,
            live_results.len,
        });
        if (pending.len == 0) {
            if (self.continuationAlreadyApplied(parsed.continuation)) {
                std.log.info("continuation already applied id={s}", .{parsed.continuation[0].call_id});
                return;
            }
            if (parsed.continuation.len > 0) {
                self.last_err = try std.fmt.allocPrint(arena, "unknown tool_use_id: {s}", .{parsed.continuation[0].call_id});
                return error.UnknownToolId;
            }
            self.last_err = "Session is not waiting for tool results";
            return error.SessionLost;
        }
        if (live_results.len != pending.len) {
            var missing = std.ArrayList([]const u8).empty;
            var provided = std.StringHashMap(void).init(arena);
            for (live_results) |c| try provided.put(c.call_id, {});
            for (pending) |id| {
                if (provided.get(id) == null) try missing.append(arena, id);
            }
            // Grok sent ids that are not pending and none of the pending ids: unknown.
            if (live_results.len == 0 and parsed.continuation.len > 0) {
                self.last_err = try std.fmt.allocPrint(arena, "unknown tool_use_id: {s}", .{parsed.continuation[0].call_id});
                return error.UnknownToolId;
            }
            self.last_err = try std.fmt.allocPrint(arena, "missing tool_result for: {s}", .{try joinIds(arena, missing.items)});
            return error.MissingToolResult;
        }
        live.resetSegment();
        for (live_results) |c| {
            if (!self.hub.fulfill(c.call_id, c.output)) {
                self.last_err = try std.fmt.allocPrint(arena, "unknown tool_use_id: {s}", .{c.call_id});
                return error.UnknownToolId;
            }
            if (self.hub.get(c.call_id)) |w| {
                if (w.from_restore) self.hub.forget(w);
            }
        }
    }

    fn waitBoundary(
        self: *Bridge,
        arena: std.mem.Allocator,
        live: *Live,
        parsed: protocol.Parsed,
        message_id: []const u8,
        session_id: []const u8,
        now: i64,
        after_tool: bool,
    ) !encode.Turn {
        // Parallel CallCustomTool RPCs arrive a few dozen ms apart. A tool that
        // shows up after reasoning has already started streaming is still a
        // tool_use boundary — returning end_turn here deadlocks Cursor on the
        // held CallCustomTool. After the bridge stream ends, wait ~160ms for a
        // straggler execute before closing with no tools.
        var last_n: usize = 0;
        var stable_ticks: u32 = 0;
        var late_ticks: u32 = 0;
        var logged_tools = false;
        var last_progress = nowMs(self.io);
        var last_chars: usize = 0;
        while (true) {
            if (live.failed) return error.BridgeRpcFailed;
            const finished = live.finished or live.batchReady();
            const n = self.hub.unresolvedCount(live.agent_id);
            live.mu.lockUncancelable(self.io);
            const chars = live.text.items.len + live.thinking.items.len;
            live.mu.unlock(self.io);
            if (n > 0 and !logged_tools) {
                std.log.info("waitBoundary tools n={d} finished={d} agent={s}", .{
                    n,
                    @intFromBool(finished),
                    live.agent_id,
                });
                logged_tools = true;
            }
            if (n != last_n) {
                last_n = n;
                stable_ticks = 0;
                late_ticks = 0;
                last_progress = nowMs(self.io);
            } else if (chars != last_chars) {
                last_chars = chars;
                last_progress = nowMs(self.io);
            } else if (n > 0) {
                stable_ticks += 1;
            } else if (finished) {
                late_ticks += 1;
            }
            if (protocol.waitBoundaryDone(n, finished, stable_ticks, late_ticks)) break;
            // n>0: Grok still answering tools. Do not time out.
            // A new Send with no tokens at all: 45s. After a tool result, chars
            // was cleared, so that 45s cutoff would return an empty turn.
            const idle = nowMs(self.io) - last_progress;
            if (protocol.waitBoundaryIdleTimedOut(n, finished, chars, after_tool, idle, 45_000)) {
                std.log.warn("waitBoundary idle timeout agent={s} chars={d}", .{ live.agent_id, chars });
                break;
            }
            if (after_tool and n == 0 and !finished and chars == 0 and idle > 180_000) {
                std.log.warn("waitBoundary post-tool quiet agent={s}", .{live.agent_id});
                break;
            }
            sleepMs(self.io, if (n > 0 or finished) 20 else 5);
        }
        const snaps = try self.hub.snapshotUnresolved(arena, live.agent_id);
        live.replacePublished(snaps) catch {};
        self.savePending(arena, live, parsed, snaps);
        live.mu.lockUncancelable(self.io);
        const text = try arena.dupe(u8, live.text.items);
        const thinking = try arena.dupe(u8, live.thinking.items);
        live.mu.unlock(self.io);
        var tools = try arena.alloc(encode.ToolCall, snaps.len);
        for (snaps, 0..) |s, i| {
            const restored = restoreTool(live.catalog, s.name);
            tools[i] = .{
                .id = s.call_id,
                .name = restored.name,
                .arguments = s.args_json,
                .kind = restored.kind,
                .namespace = restored.namespace,
            };
        }
        const stop: []const u8 = if (tools.len > 0) "tool_use" else "end_turn";
        return .{
            .message_id = message_id,
            .session_id = session_id,
            .model = parsed.model,
            .created_at = now,
            .text = text,
            .thinking = thinking,
            .tools = tools,
            .input_tokens = protocol.estimateInputTokens(parsed),
            .output_tokens = @max(@as(u32, 1), @as(u32, @intCast(@min(text.len, 16_000) / 4))),
            .stop_reason = stop,
        };
    }

    fn ensureAgent(self: *Bridge, arena: std.mem.Allocator, parsed: protocol.Parsed, session_id: []const u8) ![]const u8 {
        const model = parsed.upstream_model;
        const sent_effort = models.cursorEffortParam(model, parsed.effort) orelse "";
        const policy = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ model, sent_effort });
        self.mu.lockUncancelable(self.io);
        if (self.agents.get(session_id)) |bound| {
            const effort_ok = if (self.efforts.get(session_id)) |prev| sent_effort.len == 0 or std.mem.eql(u8, prev, sent_effort) else true;
            if (!std.mem.eql(u8, bound.model, model) or !effort_ok) {
                _ = self.agents.remove(session_id);
                _ = self.efforts.remove(session_id);
            }
        }
        const prefix = digest.stripLastUserBlock(parsed.flatten_text, parsed.last_user_text);
        const lookup = digest.lineageKey(policy, parsed.system_text, prefix);
        if (self.lineage.get(lookup[0..])) |existing| {
            const sid_copy = self.gpa.dupe(u8, session_id) catch {
                self.mu.unlock(self.io);
                return error.OutOfMemory;
            };
            const model_copy = self.gpa.dupe(u8, model) catch {
                self.mu.unlock(self.io);
                return error.OutOfMemory;
            };
            self.agents.put(sid_copy, .{ .id = existing, .model = model_copy }) catch {};
            self.mu.unlock(self.io);
            return existing;
        }
        if (self.agents.get(session_id)) |bound| {
            if (std.mem.eql(u8, bound.model, model)) {
                self.mu.unlock(self.io);
                return bound.id;
            }
        }
        if (sent_effort.len > 0) {
            const key = self.gpa.dupe(u8, session_id) catch {
                self.mu.unlock(self.io);
                return error.OutOfMemory;
            };
            const val = self.gpa.dupe(u8, sent_effort) catch {
                self.mu.unlock(self.io);
                return error.OutOfMemory;
            };
            self.efforts.put(key, val) catch {};
        }
        self.mu.unlock(self.io);
        var api_key = self.api_key;
        if (self.pool) |p| {
            if (p.bindOrPick(session_id)) |picked| api_key = picked;
        }
        const tools_field: []const u8 = if (parsed.tools.len > 0) ",\"tools\":{\"names\":[\"mcp\"]}" else "";
        const created = self.createAgent(arena, parsed, api_key, tools_field) catch |err| blk: {
            if (self.pool) |p| {
                if (p.failover(session_id, api_key)) |next_key| {
                    break :blk self.createAgent(arena, parsed, next_key, tools_field) catch return err;
                }
            }
            return err;
        };
        const created_json = try std.json.parseFromSlice(std.json.Value, arena, created, .{});
        const agent_id = jsonx.getStr(created_json.value, "agentId") orelse return error.BridgeCreateFailed;
        const durable = try self.gpa.dupe(u8, agent_id);
        const sid = try self.gpa.dupe(u8, session_id);
        const store = digest.lineageKey(policy, parsed.system_text, parsed.flatten_text);
        const lin_key = try self.gpa.dupe(u8, store[0..]);
        const model_owned = try self.gpa.dupe(u8, model);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.agents.put(sid, .{ .id = durable, .model = model_owned });
        self.lineage.put(lin_key, durable) catch {};
        std.log.info("create agent model={s} session={s}", .{ model, session_id });
        return durable;
    }

    fn createAgent(self: *Bridge, arena: std.mem.Allocator, parsed: protocol.Parsed, api_key: []const u8, tools_field: []const u8) ![]u8 {
        const create = try std.fmt.allocPrint(arena,
            "{{\"options\":{{\"model\":{{\"id\":{f}{s}}},\"apiKey\":{f},\"local\":{{\"cwd\":[{f}]{s}}},\"disallowedTools\":[\"shell\",\"read\",\"edit\",\"task\",\"webSearch\",\"webFetch\"]{s}}}}}",
            .{
                std.json.fmt(parsed.upstream_model, .{}),
                try effortJson(arena, models.cursorEffortParam(parsed.upstream_model, parsed.effort)),
                std.json.fmt(api_key, .{}),
                std.json.fmt(self.workspace, .{}),
                try customToolsJson(arena, parsed.tools),
                tools_field,
            },
        );
        return self.unary(arena, "/sdk.v1.SdkAgentService/CreateAgent", create);
    }

    pub fn restorePending(self: *Bridge, arena: std.mem.Allocator, parsed: protocol.Parsed, session_id: []const u8) !?*Live {
        if (self.persist_path.len == 0) return null;
        const recs = persist.loadAll(self.io, self.persist_path, arena) catch return null;
        var match: ?persist.Record = null;
        for (recs) |rec| {
            if (std.mem.eql(u8, rec.session_id, session_id)) {
                match = rec;
                break;
            }
            for (rec.tools) |t| {
                for (parsed.continuation) |c| {
                    if (std.mem.eql(u8, t.call_id, c.call_id)) {
                        match = rec;
                        break;
                    }
                }
            }
        }
        const rec = match orelse return null;
        for (rec.tools) |t| {
            const w = self.hub.announce(.{
                .tool_name = t.name,
                .tool_call_id = t.call_id,
                .agent_id = rec.agent_id,
                .args_json = t.args,
            }) catch continue;
            w.from_restore = true;
        }
        const live = try self.gpa.create(Live);
        live.* = .{
            .bridge = self,
            .io = self.io,
            .gpa = self.gpa,
            .arena_state = std.heap.ArenaAllocator.init(self.gpa),
            .send_json = try self.gpa.dupe(u8, "{}"),
            .agent_id = try self.gpa.dupe(u8, rec.agent_id),
            .session_id = try self.gpa.dupe(u8, rec.session_id),
        };
        var snaps = try arena.alloc(toolcb.WaiterSnap, rec.tools.len);
        for (rec.tools, 0..) |t, i| {
            snaps[i] = .{ .call_id = t.call_id, .name = t.name, .args_json = t.args };
        }
        live.replacePublished(snaps) catch {};
        const sid = try self.gpa.dupe(u8, rec.session_id);
        const aid = try self.gpa.dupe(u8, rec.agent_id);
        self.mu.lockUncancelable(self.io);
        const model_owned = self.gpa.dupe(u8, rec.model) catch rec.model;
        self.agents.put(sid, .{ .id = aid, .model = model_owned }) catch {};
        self.lives.put(live.session_id, live) catch {};
        self.mu.unlock(self.io);
        std.log.info("restore pending session={s} agent={s} tools={d}", .{ rec.session_id, rec.agent_id, rec.tools.len });
        return live;
    }

    fn savePending(self: *Bridge, arena: std.mem.Allocator, live: *Live, parsed: protocol.Parsed, snaps: []const toolcb.WaiterSnap) void {
        if (self.persist_path.len == 0) return;
        if (snaps.len == 0) {
            persist.removeSession(self.io, self.persist_path, live.session_id, arena);
            return;
        }
        var tools = arena.alloc(persist.ToolRec, snaps.len) catch return;
        for (snaps, 0..) |s, i| {
            tools[i] = .{ .call_id = s.call_id, .name = s.name, .args = s.args_json };
        }
        const rec = persist.Record{
            .session_id = live.session_id,
            .agent_id = live.agent_id,
            .model = parsed.model,
            .effort = parsed.effort orelse "",
            .tools = tools,
        };
        persist.upsertFile(self.io, self.persist_path, rec, arena) catch |err| {
            std.log.warn("persist pending failed ({t})", .{err});
        };
    }

    fn sendCollect(self: *Bridge, arena: std.mem.Allocator, send_json: []const u8, live: *Live) !void {
        const framed = try frame(arena, send_json);
        const url = try std.fmt.allocPrint(arena, "{s}/sdk.v1.SdkAgentService/Send", .{self.base_url});
        const uri = try std.Uri.parse(url);
        const authz = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.bearer});
        var req = try self.client.request(.POST, uri, .{
            .headers = .{
                .authorization = .{ .override = authz },
                .content_type = .{ .override = "application/connect+json" },
            },
            .extra_headers = &.{
                .{ .name = "Connect-Protocol-Version", .value = "1" },
            },
            .keep_alive = true,
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();
        try req.sendBodyComplete(framed);
        var redirect: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect);
        if (@intFromEnum(response.head.status) >= 400) return error.BridgeRpcFailed;
        var transfer: [4096]u8 = undefined;
        const reader = response.reader(&transfer);
        while (true) {
            const payload = readFrame(reader, arena) catch |err| switch (err) {
                error.EndStream => break,
                else => return err,
            } orelse break;
            applyEnvelope(arena, payload, live) catch {};
        }
    }
};

const Live = struct {
    bridge: *Bridge,
    io: Io,
    gpa: std.mem.Allocator,
    arena_state: std.heap.ArenaAllocator,
    send_json: []u8,
    sink: Sink = .{},
    mu: Io.Mutex = .init,
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    finished: bool = false,
    failed: bool = false,
    agent_id: []u8,
    session_id: []u8,
    catalog: []protocol.Tool = &.{},
    published_ids: std.ArrayList([]u8) = .empty,
    batch_ready: bool = false,

    fn setSink(self: *Live, sink: Sink) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.sink = sink;
    }

    fn resetSegment(self: *Live) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.text.clearRetainingCapacity();
        self.thinking.clearRetainingCapacity();
        self.finished = false;
        self.failed = false;
        self.batch_ready = false;
    }

    fn finish(self: *Live) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.finished = true;
        self.batch_ready = true;
    }

    fn markBatchReady(self: *Live) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.batch_ready = true;
    }

    fn batchReady(self: *Live) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.batch_ready;
    }

    fn fail(self: *Live) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.failed = true;
        self.finished = true;
        self.batch_ready = true;
    }

    fn replacePublished(self: *Live, snaps: []const toolcb.WaiterSnap) !void {
        for (self.published_ids.items) |id| self.gpa.free(id);
        self.published_ids.clearRetainingCapacity();
        for (snaps) |s| {
            try self.published_ids.append(self.gpa, try self.gpa.dupe(u8, s.call_id));
        }
    }
};

fn sendLoop(live: *Live) void {
    const arena = live.arena_state.allocator();
    live.bridge.sendCollect(arena, live.send_json, live) catch {
        live.fail();
        return;
    };
    live.finish();
}

fn effortJson(arena: std.mem.Allocator, effort: ?[]const u8) ![]const u8 {
    const e = effort orelse return "";
    return std.fmt.allocPrint(arena, ",\"params\":[{{\"id\":\"effort\",\"value\":{f}}}]", .{std.json.fmt(e, .{})});
}

fn customToolsObject(arena: std.mem.Allocator, tools: []const protocol.Tool) ![]const u8 {
    if (tools.len == 0) return "";
    var out = std.ArrayList(u8).empty;
    try out.append(arena, '{');
    for (tools, 0..) |tool, i| {
        if (i > 0) try out.append(arena, ',');
        const schema = if (tool.schema_json.len > 0) tool.schema_json else "{\"type\":\"object\",\"properties\":{}}";
        try out.appendSlice(arena, try std.fmt.allocPrint(arena,
            "{f}:{{\"description\":{f},\"inputSchema\":{s}}}",
            .{ std.json.fmt(tool.sdk_name, .{}), std.json.fmt(tool.description, .{}), schema },
        ));
    }
    try out.append(arena, '}');
    return out.toOwnedSlice(arena);
}

fn customToolsJson(arena: std.mem.Allocator, tools: []const protocol.Tool) ![]const u8 {
    const obj = try customToolsObject(arena, tools);
    if (obj.len == 0) return "";
    return std.fmt.allocPrint(arena, ",\"customTools\":{s}", .{obj});
}

/// Node gold passes local.customTools on every Agent.send, not only CreateAgent.
/// Without it, follow-up turns (e.g. /learn curation) lose Grok tool schemas and
/// the model invents args or Cursor-native tools (GetDynamicTools).
fn sendLocalSuffix(arena: std.mem.Allocator, tools: []const protocol.Tool, force: bool) ![]const u8 {
    const obj = try customToolsObject(arena, tools);
    if (!force and obj.len == 0) return "";
    if (force and obj.len == 0) return ",\"local\":{\"force\":true}";
    if (force) {
        return std.fmt.allocPrint(arena, ",\"local\":{{\"force\":true,\"customTools\":{s}}}", .{obj});
    }
    return std.fmt.allocPrint(arena, ",\"local\":{{\"customTools\":{s}}}", .{obj});
}

fn frame(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 5 + json.len);
    out[0] = 0;
    std.mem.writeInt(u32, out[1..5], @intCast(json.len), .big);
    @memcpy(out[5..], json);
    return out;
}

fn readFrame(reader: *std.Io.Reader, arena: std.mem.Allocator) !?[]u8 {
    var header: [5]u8 = undefined;
    reader.readSliceAll(&header) catch return null;
    const flags = header[0];
    const len = std.mem.readInt(u32, header[1..5], .big);
    const payload = try arena.alloc(u8, len);
    try reader.readSliceAll(payload);
    if (flags & 0x02 != 0) {
        if (std.mem.indexOf(u8, payload, "\"error\"") != null) return error.BridgeStreamError;
        return error.EndStream;
    }
    return payload;
}

fn applyEnvelope(arena: std.mem.Allocator, payload: []const u8, live: *Live) !void {
    if (payload.len == 0 or payload[0] != '{') return;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, payload, .{}) catch return;
    if (jsonx.get(parsed.value, "interactionUpdate")) |upd| {
        const typ = jsonx.getStr(upd, "type") orelse return;
        if (std.mem.eql(u8, typ, "turn-ended") or std.mem.eql(u8, typ, "turn_ended")) {
            live.markBatchReady();
            return;
        }
        const piece = blk: {
            const u = jsonx.get(upd, "update") orelse break :blk "";
            break :blk jsonx.getStr(u, "text") orelse jsonx.getStr(u, "delta") orelse "";
        };
        if (piece.len == 0) return;
        if (std.mem.eql(u8, typ, "text-delta") or std.mem.eql(u8, typ, "text_delta")) {
            appendLive(live, .text, piece);
        } else if (std.mem.indexOf(u8, typ, "thinking") != null) {
            appendLive(live, .thinking, piece);
        }
        return;
    }
    if (jsonx.get(parsed.value, "sdkMessage")) |msg| {
        const typ = jsonx.getStr(msg, "type") orelse return;
        const m = jsonx.get(msg, "message") orelse return;
        if (std.mem.eql(u8, typ, "assistant")) {
            const piece = jsonx.getStr(m, "text") orelse jsonx.collectText(m, arena) catch "";
            live.mu.lockUncancelable(live.io);
            const empty = live.text.items.len == 0;
            live.mu.unlock(live.io);
            if (piece.len > 0 and empty) appendLive(live, .text, piece);
        } else if (std.mem.eql(u8, typ, "thinking")) {
            const piece = jsonx.getStr(m, "text") orelse jsonx.getStr(m, "thinking") orelse jsonx.collectText(m, arena) catch "";
            live.mu.lockUncancelable(live.io);
            const empty = live.thinking.items.len == 0;
            live.mu.unlock(live.io);
            if (piece.len > 0 and empty) appendLive(live, .thinking, piece);
        }
        return;
    }
    if (jsonx.get(parsed.value, "result")) |res| {
        const inner = jsonx.get(res, "result") orelse res;
        const final_text = jsonx.getStr(inner, "text") orelse jsonx.getStr(inner, "result") orelse "";
        live.mu.lockUncancelable(live.io);
        const empty = live.text.items.len == 0;
        live.mu.unlock(live.io);
        if (final_text.len > 0 and empty) appendLive(live, .text, final_text);
    }
}

const LiveKind = enum { text, thinking };

fn appendLive(live: *Live, kind: LiveKind, piece: []const u8) void {
    live.mu.lockUncancelable(live.io);
    const sink = live.sink;
    switch (kind) {
        .text => live.text.appendSlice(live.gpa, piece) catch {},
        .thinking => live.thinking.appendSlice(live.gpa, piece) catch {},
    }
    live.mu.unlock(live.io);
    switch (kind) {
        .text => if (sink.on_text) |fn_ptr| fn_ptr(sink.ctx, piece),
        .thinking => if (sink.on_thinking) |fn_ptr| fn_ptr(sink.ctx, piece),
    }
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

fn sleepMs(io: Io, ms: i64) void {
    const d: Io.Clock.Duration = .{ .raw = .fromMilliseconds(ms), .clock = .real };
    d.sleep(io) catch {};
}

fn copyIds(arena: std.mem.Allocator, ids: []const []u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, ids.len);
    for (ids, 0..) |id, i| out[i] = id;
    return out;
}

fn joinIds(arena: std.mem.Allocator, ids: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (ids, 0..) |id, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, id);
    }
    return out.toOwnedSlice(arena);
}

fn dupeTools(gpa: std.mem.Allocator, tools: []const protocol.Tool) ![]protocol.Tool {
    const out = try gpa.alloc(protocol.Tool, tools.len);
    for (tools, 0..) |t, i| {
        out[i] = .{
            .name = try gpa.dupe(u8, t.name),
            .sdk_name = try gpa.dupe(u8, t.sdk_name),
            .description = try gpa.dupe(u8, t.description),
            .schema_json = try gpa.dupe(u8, t.schema_json),
            .kind = t.kind,
            .namespace = try gpa.dupe(u8, t.namespace),
        };
    }
    return out;
}

fn restoreTool(catalog: []const protocol.Tool, sdk_name: []const u8) struct {
    name: []const u8,
    namespace: []const u8,
    kind: protocol.ToolKind,
} {
    for (catalog) |t| {
        if (std.mem.eql(u8, t.sdk_name, sdk_name) or std.mem.eql(u8, t.name, sdk_name)) {
            return .{ .name = t.name, .namespace = t.namespace, .kind = t.kind };
        }
    }
    return .{ .name = sdk_name, .namespace = "", .kind = .function };
}

// Connect JSON for sdk.v1.SdkImage: the `data` field is a oneof, so the wire
// shape is nested {"data":{"data":...,"mimeType":...}}, not the flat TS SDK
// API shape {"data":...,"mimeType":...}. Flat JSON fails with
// "cannot decode message sdk.v1.SdkImageData from JSON".
fn imagesJson(arena: std.mem.Allocator, images: []const protocol.Image) ![]const u8 {
    if (images.len == 0) return "";
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(arena, ",\"images\":[");
    for (images, 0..) |img, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, try std.fmt.allocPrint(arena,
            "{{\"data\":{{\"data\":{f},\"mimeType\":{f}}}}}",
            .{ std.json.fmt(img.data, .{}), std.json.fmt(img.mime_type, .{}) },
        ));
    }
    try out.append(arena, ']');
    return out.items;
}

fn clip(text: []const u8, max: u32) []const u8 {
    if (text.len <= max) return text;
    return text[text.len - max ..];
}

pub fn findBridgeBinary(env: *const std.process.Environ.Map, allocator: std.mem.Allocator) ?[]const u8 {
    if (env.get("CURSOR_SDK_BRIDGE")) |p| {
        if (p.len > 0) return p;
    }
    const home = env.get("HOME") orelse return null;
    return std.fs.path.join(allocator, &.{ home, ".hitch", "bridge", "v1.0.30", "bin", "cursor-sdk-bridge" }) catch null;
}

pub fn spawn(
    io: Io,
    gpa: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    bin: []const u8,
    workspace: []const u8,
    api_key: []const u8,
    tool_callback_url: []const u8,
    tool_callback_token: []const u8,
    hub: *toolcb.Hub,
    group: *Io.Group,
) !Bridge {
    std.Io.Dir.cwd().createDirPath(io, workspace) catch {};
    const child = try std.process.spawn(io, .{
        .argv = &.{
            bin,
            "--workspace",
            workspace,
            "--tool-callback-url",
            tool_callback_url,
            "--tool-callback-auth-token",
            tool_callback_token,
        },
        .stderr = .pipe,
        .stdout = .ignore,
    });
    const stderr = child.stderr orelse return error.BridgeNoStderr;
    var buf: [8192]u8 = undefined;
    var reader = stderr.readerStreaming(io, &buf);
    const ready = try waitReady(&reader.interface, gpa);
    const token = try readToken(io, gpa, ready.auth_token_file);
    const br = Bridge{
        .io = io,
        .gpa = gpa,
        .client = .{ .allocator = gpa, .io = io },
        .base_url = ready.url,
        .bearer = token,
        .api_key = api_key,
        .workspace = workspace,
        .child = child,
        .agents = std.StringHashMap(BoundAgent).init(gpa),
        .efforts = std.StringHashMap([]const u8).init(gpa),
        .lives = std.StringHashMap(*Live).init(gpa),
        .lineage = std.StringHashMap([]const u8).init(gpa),
        .hub = hub,
        .group = group,
    };
    _ = env;
    return br;
}

const Ready = struct {
    url: []u8,
    auth_token_file: []u8,
};

fn waitReady(reader: *std.Io.Reader, gpa: std.mem.Allocator) !Ready {
    const prefix = "cursor-sdk-bridge ready ";
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch return error.BridgeReadyTimeout;
        if (std.mem.startsWith(u8, line, prefix)) {
            const json = std.mem.trim(u8, line[prefix.len..], " \r\n");
            var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
            const url = try gpa.dupe(u8, jsonx.getStr(parsed.value, "url") orelse return error.BridgeReadyInvalid);
            const file = try gpa.dupe(u8, jsonx.getStr(parsed.value, "authTokenFile") orelse return error.BridgeReadyInvalid);
            parsed.deinit();
            return .{ .url = url, .auth_token_file = file };
        }
    }
}

fn readToken(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [128]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    const data = try reader.interface.allocRemaining(gpa, .limited(4096));
    return try gpa.dupe(u8, std.mem.trim(u8, data, " \t\r\n"));
}

test "connect frame round-trip length" {
    const framed = try frame(std.testing.allocator, "{\"a\":1}");
    defer std.testing.allocator.free(framed);
    try std.testing.expectEqual(@as(u8, 0), framed[0]);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, framed[1..5], .big));
}

test "sendLocalSuffix keeps Grok required fields on every Send" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tools = [_]protocol.Tool{.{
        .name = "run_terminal_command",
        .sdk_name = "run_terminal_command",
        .description = "Run a bash command",
        .schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"}},\"required\":[\"command\",\"description\"]}",
    }};
    const suffix = try sendLocalSuffix(arena.allocator(), &tools, false);
    try std.testing.expect(std.mem.indexOf(u8, suffix, "\"customTools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, suffix, "\"required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, suffix, "description") != null);
    const forced = try sendLocalSuffix(arena.allocator(), &tools, true);
    try std.testing.expect(std.mem.indexOf(u8, forced, "\"force\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, forced, "\"customTools\"") != null);
    try std.testing.expectEqualStrings("", try sendLocalSuffix(arena.allocator(), &.{}, false));
}
