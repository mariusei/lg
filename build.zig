const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Option to statically link utf8proc (for standalone distribution)
    const static_utf8proc = b.option(bool, "static-utf8proc", "Statically link utf8proc library") orelse false;

    // Executable
    const exe = b.addExecutable(.{
        .name = "lg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link with utf8proc for Unicode normalization
    exe.linkSystemLibrary("utf8proc");
    exe.linkLibC();

    if (static_utf8proc) {
        // Prefer static linking when requested
        exe.root_module.link_libc = true;
    }

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Forward CLI args to the app
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link with utf8proc for Unicode normalization (same as exe)
    unit_tests.linkSystemLibrary("utf8proc");
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
