const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcp_exe = b.addExecutable(.{
        .name = "zcp",
        .root_source_file = b.path("src/zcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(zcp_exe);

    const zcp_run_cmd = b.addRunArtifact(zcp_exe);
    zcp_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        zcp_run_cmd.addArgs(args);
    }

    const zcp_run_step = b.step("run-zcp", "Run the zcp app");
    zcp_run_step.dependOn(&zcp_run_cmd.step);

    const lz_exe = b.addExecutable(.{
        .name = "lz",
        .root_source_file = b.path("src/lz.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lz_exe);

    const lz_run_cmd = b.addRunArtifact(lz_exe);
    lz_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        lz_run_cmd.addArgs(args);
    }

    const lz_run_step = b.step("run-lz", "Run the lz app");
    lz_run_step.dependOn(&lz_run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
