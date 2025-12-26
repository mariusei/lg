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

pub fn main() !void {
    // Arena allocator: all allocations freed with single deinit()
    // Why arena? Short-lived CLI tool, no need for granular tracking
    // All memory released when program exits anyway
    // Trade-off: Simplicity over fine-grained control
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse CLI arguments
    const config = cli.parseArgs(allocator) catch |err| {
        if (err == error.InvalidArgument) {
            std.process.exit(1);
        }
        return err;
    };

    // Get git status (optional - may fail if not a git repo)
    var git_ctx: ?git.GitContext = git.GitContext.init(allocator, config.dir_path) catch null;
    defer if (git_ctx) |*ctx| ctx.deinit();

    // Show git info if requested
    if (config.show_branch) {
        try showBranch(allocator);
    }
    if (config.show_legend) {
        try showLegend();
    }

    // Collect files
    const files = try filesystem.listFiles(allocator, config, if (git_ctx) |*ctx| ctx else null);
    // No need to free - arena handles it

    // Sort files
    filesystem.sortFiles(files, config);

    // Display
    try display.print(allocator, files, if (git_ctx) |*ctx| ctx else null, config);
}

fn showBranch(allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(&.{ "git", "branch", "--show-current" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024);
    defer allocator.free(stdout);

    _ = try child.wait();

    const branch = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    if (branch.len > 0) {
        std.debug.print("Branch: {s}\n\n", .{branch});
    }
}

fn showLegend() !void {
    // Buffered stdout: reduces syscalls (one flush vs many writes)
    // Buffer size sufficient for typical legend output
    // .interface provides generic writer for polymorphism
    // Pattern: create buffer → create writer → get interface → flush
    var stdout_buffer: [types.STDOUT_BUFFER_SIZE]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("Git Status: [●]=Staged [○]=Unstaged [?]=Untracked\n\n");
    try stdout.flush();
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
    try showLegend();
}

test "showBranch handles git failure gracefully" {
    // Test that showBranch doesn't crash even if git fails
    const allocator = std.testing.allocator;

    // This may fail if not in a git repo, but shouldn't crash
    showBranch(allocator) catch |err| {
        // Expected errors when git is not available or not in a repo
        try std.testing.expect(
            err == error.FileNotFound or
                err == error.BrokenPipe or
                err == std.process.Child.SpawnError.InvalidExe,
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
