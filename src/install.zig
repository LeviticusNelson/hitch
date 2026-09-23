const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const plugin_json = @embedFile("plugin-embed/plugin.json");
const hooks_json = @embedFile("plugin-embed/hooks.json");
const ensure_sh = @embedFile("plugin-embed/ensure-gateway.sh");
const hitch_md = @embedFile("plugin-embed/hitch.md");
const start_sh = @embedFile("plugin-embed/start.sh");
const stop_sh = @embedFile("plugin-embed/stop.sh");
const env_example = @embedFile("plugin-embed/env.example");
const fetch_bridge_sh = @embedFile("plugin-embed/fetch-bridge.sh");

const exe_name = if (builtin.os.tag == .windows) "hitch.exe" else "hitch";

pub fn run(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const home = homeDir(init.environ_map) orelse return error.NoHome;
    const plugin = try std.fs.path.join(arena, &.{ home, ".grok", "plugins", "hitch" });
    const hitch_home = try std.fs.path.join(arena, &.{ home, ".hitch" });
    const cwd = Io.Dir.cwd();

    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ plugin, "hooks" }));
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ plugin, "commands" }));
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ plugin, "bin" }));
    try cwd.createDirPath(io, hitch_home);
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ hitch_home, "plugin" }));

    try write(io, try std.fs.path.join(arena, &.{ plugin, "plugin.json" }), plugin_json);
    try write(io, try std.fs.path.join(arena, &.{ plugin, "hooks", "hooks.json" }), hooks_json);
    try writeExec(io, try std.fs.path.join(arena, &.{ plugin, "hooks", "ensure-gateway.sh" }), ensure_sh);
    try write(io, try std.fs.path.join(arena, &.{ plugin, "commands", "hitch.md" }), hitch_md);
    try writeExec(io, try std.fs.path.join(arena, &.{ hitch_home, "start.sh" }), start_sh);
    try writeExec(io, try std.fs.path.join(arena, &.{ hitch_home, "stop.sh" }), stop_sh);
    try writeExec(io, try std.fs.path.join(arena, &.{ hitch_home, "fetch-bridge.sh" }), fetch_bridge_sh);
    const env_path = try std.fs.path.join(arena, &.{ hitch_home, "env" });
    if (!fileExists(io, env_path)) {
        try write(io, env_path, env_example);
    }
    try write(io, try std.fs.path.join(arena, &.{ hitch_home, "env.example" }), env_example);

    const exe = try std.process.executablePathAlloc(io, arena);
    const dest_bin = try std.fs.path.join(arena, &.{ plugin, "bin", exe_name });
    try copyAbs(io, arena, exe, dest_bin);
    try chmodExec(dest_bin);
    const home_bin = try std.fs.path.join(arena, &.{ hitch_home, "bin", exe_name });
    cwd.createDirPath(io, try std.fs.path.join(arena, &.{ hitch_home, "bin" })) catch {};
    try copyAbs(io, arena, exe, home_bin);
    try chmodExec(home_bin);

    // Plugin hooks load after SessionStart, so opening Grok never runs them.
    // A user hook in ~/.grok/hooks is always trusted and runs on session start.
    const hooks_dir = try std.fs.path.join(arena, &.{ home, ".grok", "hooks" });
    try cwd.createDirPath(io, hooks_dir);
    const ensure_path = try std.fs.path.join(arena, &.{ plugin, "hooks", "ensure-gateway.sh" });
    const user_hook = try std.fmt.allocPrint(arena,
        \\{{
        \\  "hooks": {{
        \\    "SessionStart": [{{"hooks": [{{"type": "command", "command": "{s}", "timeout": 45}}]}}],
        \\    "UserPromptSubmit": [{{"hooks": [{{"type": "command", "command": "{s}", "timeout": 45}}]}}],
        \\    "StopFailure": [{{"hooks": [{{"type": "command", "command": "{s}", "timeout": 45}}]}}]
        \\  }}
        \\}}
        \\
    , .{ ensure_path, ensure_path, ensure_path });
    try write(io, try std.fs.path.join(arena, &.{ hooks_dir, "hitch.json" }), user_hook);

    enableInConfig(io, arena, home) catch |err| {
        std.log.warn("could not enable hitch in ~/.grok/config.toml ({t}); run: grok plugin enable hitch", .{err});
    };

    std.debug.print(
        \\hitch plugin installed
        \\  plugin  {s}
        \\  binary  {s}
        \\  start   {s}/start.sh
        \\  env     {s}/env
        \\  bridge  {s}/fetch-bridge.sh
        \\
        \\Edit ~/.hitch/env and set CURSOR_API_KEY, then:
        \\  ~/.hitch/fetch-bridge.sh
        \\  ~/.hitch/start.sh
        \\
        \\Grok user plugins in ~/.grok/plugins/ are auto-trusted. If hitch is not listed, add it to [plugins].enabled or run:
        \\  grok plugin enable hitch
        \\
    , .{ plugin, dest_bin, hitch_home, hitch_home, hitch_home });
}

fn homeDir(env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("HOME")) |h| if (h.len > 0) return h;
    if (env.get("USERPROFILE")) |h| if (h.len > 0) return h;
    return null;
}

fn fileExists(io: Io, path: []const u8) bool {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn write(io: Io, path: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn writeExec(io: Io, path: []const u8, bytes: []const u8) !void {
    try write(io, path, bytes);
    try chmodExec(path);
}

fn chmodExec(path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    _ = std.c.chmod(z, 0o755);
}

fn copyAbs(io: Io, arena: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const file = Io.Dir.cwd().openFile(io, from, .{}) catch |err| {
        std.log.err("open self binary {s}: {t}", .{ from, err });
        return err;
    };
    defer file.close(io);
    var rbuf: [16 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &rbuf);
    const data = try reader.interface.allocRemaining(arena, .limited(64 * 1024 * 1024));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = to, .data = data });
}

fn enableInConfig(io: Io, arena: std.mem.Allocator, home: []const u8) !void {
    const path = try std.fs.path.join(arena, &.{ home, ".grok", "config.toml" });
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    var rbuf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &rbuf);
    const toml = reader.interface.allocRemaining(arena, .limited(2 * 1024 * 1024)) catch return;
    if (std.mem.indexOf(u8, toml, "\"hitch\"") != null) return;
    const needle = "enabled = [";
    const at = std.mem.indexOf(u8, toml, needle) orelse return;
    var i = at + needle.len;
    while (i < toml.len and (toml[i] == ' ' or toml[i] == '\t')) i += 1;
    const insert = "\n    \"hitch\",";
    const out = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ toml[0..i], insert, toml[i..] });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out });
}
