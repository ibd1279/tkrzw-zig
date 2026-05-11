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

    // C API library: shared module used by both static and dynamic artifacts.
    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_mod.addImport("tkrzw_zig", mod);

    const c_static = b.addLibrary(.{
        .linkage = .static,
        .name = "tkrzw",
        .root_module = c_api_mod,
    });
    b.installArtifact(c_static);

    const c_shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "tkrzw",
        .root_module = c_api_mod,
    });
    b.installArtifact(c_shared);

    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/tkrzw.h"), "tkrzw.h").step);

    // C API tests: exercise the exported tkrzw_* surface from Zig.
    const c_api_test_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_test_mod.addImport("tkrzw_zig", mod);
    const c_api_tests = b.addTest(.{ .root_module = c_api_test_mod });
    test_step.dependOn(&b.addRunArtifact(c_api_tests).step);
}
