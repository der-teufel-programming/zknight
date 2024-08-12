const std = @import("std");
const tests = @import("tests/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize = b.option(
        bool,
        "sanitize",
        "The interpreter will error on some of UB (default true in debug builds)",
    ) orelse (optimize == .Debug);

    const exe = b.addExecutable(.{
        .name = "zknight",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    var opts = b.addOptions();
    opts.addOption(bool, "sanitize", sanitize);

    exe.root_module.addOptions("build_options", opts);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    const source_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });

    const run_source_tests = b.addRunArtifact(source_tests);
    test_step.dependOn(&run_source_tests.step);

    tests.addTests(b, test_step, exe);
}
