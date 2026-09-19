const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    const exe = b.addExecutable(.{
        .name = "cursor-sdk2api-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Zig adapter library for the official cursor-sdk-bridge. There is no C ABI
    // to link: the binary is a Bun executable, and the contract is sdk.v1 Connect.
    const sdk_mod = b.addModule("cursor-sdk-bridge", .{
        .root_source_file = b.path("src/sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sdk_lib = b.addLibrary(.{
        .name = "cursor-sdk-bridge",
        .linkage = .static,
        .root_module = sdk_mod,
    });
    b.installArtifact(sdk_lib);
    const sdk_tests = b.addTest(.{ .root_module = sdk_mod });
    const run_sdk_tests = b.addRunArtifact(sdk_tests);

    const run_step = b.step("run", "Run the gateway on :8081");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_sdk_tests.step);
}
