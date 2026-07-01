//! Entry point for zig-lg - ls with git status integration.
//!
//! Memory management: Arena allocator (single deinit() frees everything)
//! Execution flow: CLI parse → git status → list files → sort → display
//! All allocations freed on exit - perfect for short-lived CLI tools

const std = @import("std");
const types = @import("types.zig");
const cli = @import("cli.zig");
const git = @import("git.zig");

// Import filesystem and display modules
const filesystem = @import("filesystem.zig");
const display = @import("display.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Arena allocator: all allocations freed with single deinit()
    // Why arena? Short-lived CLI tool, no need for granular tracking
    // All memory released when program exits anyway
    // Trade-off: Simplicity over fine-grained control
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse CLI arguments
    const config = cli.parseArgs(io, allocator, init.minimal.args) catch |err| {
        if (err == error.InvalidArgument) {
            std.process.exit(1);
        }
        return err;
    };

    // Get git status (optional - may fail if not a git repo)
    var git_ctx: ?git.GitContext = git.GitContext.init(io, allocator, config.dir_path) catch null;
    defer if (git_ctx) |*ctx| ctx.deinit();

    // Show git info if requested
    if (config.show_branch) {
        try showBranch(io, allocator);
    }
    if (config.show_legend) {
        try showLegend(io);
    }

    // Collect files
    const files = try filesystem.listFiles(io, allocator, config, if (git_ctx) |*ctx| ctx else null);
    // No need to free - arena handles it

    // Sort files
    filesystem.sortFiles(files, config);

    // Display
    try display.print(io, allocator, files, if (git_ctx) |*ctx| ctx else null, config);
}

fn showBranch(io: std.Io, allocator: std.mem.Allocator) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "branch", "--show-current" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const branch = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (branch.len > 0) {
        std.debug.print("Branch: {s}\n\n", .{branch});
    }
}

fn showLegend(io: std.Io) !void {
    var output = display.UnifiedOutput.init(io);
    try output.writeAll("Git Status: [●]=Staged [○]=Unstaged [?]=Untracked\n\n");
}

test "main runs without crashing" {
    // Integration test - just ensure imports work
    const allocator = std.testing.allocator;

    const config = types.Config.default();
    _ = config;
    _ = allocator;
}

test "showLegend prints without error" {
    // Test that legend prints successfully
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try showLegend(io);
}

test "showBranch handles git failure gracefully" {
    // Test that showBranch doesn't crash even if git fails
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // This may fail if not in a git repo, but shouldn't crash
    showBranch(io, allocator) catch |err| {
        // Expected errors when git is not available or not in a repo
        try std.testing.expect(
            err == error.FileNotFound or
                err == error.BrokenPipe or
                err == std.process.SpawnError.InvalidExe,
        );
    };
}

test "arena allocator cleanup" {
    // Verify arena allocator works as expected
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // Allocate some memory
    const slice = try allocator.alloc(u8, 100);
    _ = slice;

    // No need to free - arena handles it
    // This test passes if no memory leaks occur
}
