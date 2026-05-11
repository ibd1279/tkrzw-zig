const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("tkrzw_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("tkrzw_zig", mod);

    const exe = b.addExecutable(.{
        .name = "tkrzw-box",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
}
