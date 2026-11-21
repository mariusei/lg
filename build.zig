const std = @import("std");

const build_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose build.zig.zon's version to the binary so --version stays in sync.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", build_zon.version);

    // Executable
    const exe = b.addExecutable(.{
        .name = "lg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // utf8proc is vendored (vendor/utf8proc, MIT/Expat) so the build needs
    // no system library and cross-compilation works out of the box.
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/utf8proc/utf8proc.c"), .flags = &.{"-DUTF8PROC_EXPORTS"} });
    exe.root_module.addIncludePath(b.path("vendor/utf8proc"));
    exe.root_module.link_libc = true;
    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Forward CLI args to the app
    run_cmd.addPassthruArgs();

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

    unit_tests.root_module.addCSourceFile(.{ .file = b.path("vendor/utf8proc/utf8proc.c"), .flags = &.{"-DUTF8PROC_EXPORTS"} });
    unit_tests.root_module.addIncludePath(b.path("vendor/utf8proc"));
    unit_tests.root_module.link_libc = true;
    unit_tests.root_module.addOptions("build_options", build_options);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
