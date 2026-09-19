const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const plugin_json = @embedFile("plugin-embed/plugin.json");
const hooks_json = @embedFile("plugin-embed/hooks.json");
const ensure_sh = @embedFile("plugin-embed/ensure-gateway.sh");
const hitch_md = @embedFile("plugin-embed/hitch.md");
const start_sh = @embedFile("plugin-embed/start.sh");
const stop_sh = @embedFile("plugin-embed/stop.sh");

pub fn run(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const home = init.environ_map.get("HOME") orelse return error.NoHome;
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

    const exe = try selfExePath(arena);
    const dest_bin = try std.fs.path.join(arena, &.{ plugin, "bin", "hitch" });
    try copyAbs(io, arena, exe, dest_bin);
    try chmodExec(dest_bin);
    const home_bin = try std.fs.path.join(arena, &.{ hitch_home, "bin", "hitch" });
    cwd.createDirPath(io, try std.fs.path.join(arena, &.{ hitch_home, "bin" })) catch {};
    try copyAbs(io, arena, exe, home_bin);
    try chmodExec(home_bin);

    enableInConfig(io, arena, home) catch |err| {
        std.log.warn("could not enable hitch in ~/.grok/config.toml ({t}); run: grok plugin enable hitch", .{err});
    };

    std.debug.print(
        \\hitch plugin installed
        \\  plugin  {s}
        \\  binary  {s}
        \\  start   {s}/start.sh
        \\
        \\Grok user plugins in ~/.grok/plugins/ are auto-trusted. If hitch is not listed, add it to [plugins].enabled or run:
        \\  grok plugin enable hitch
        \\
    , .{ plugin, dest_bin, hitch_home });
}

fn write(io: Io, path: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn writeExec(io: Io, path: []const u8, bytes: []const u8) !void {
    try write(io, path, bytes);
    try chmodExec(path);
}

fn chmodExec(path: []const u8) !void {
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

fn selfExePath(allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            var n: u32 = buf.len;
            if (std.c._NSGetExecutablePath(&buf, &n) != 0) return error.NameTooLong;
            const p = std.mem.sliceTo(&buf, 0);
            return allocator.dupe(u8, p);
        },
        else => {
            const n = std.posix.readlink("/proc/self/exe", &buf) catch return error.NoExe;
            return allocator.dupe(u8, buf[0..n]);
        },
    }
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
