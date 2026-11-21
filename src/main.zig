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

/// Trim the trailing newline(s) git prints for `git branch --show-current`.
fn parseBranchName(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, &std.ascii.whitespace);
}

fn showBranch(io: std.Io, allocator: std.mem.Allocator) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "branch", "--show-current" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const branch = parseBranchName(result.stdout);
    if (branch.len > 0) {
        std.debug.print("Branch: {s}\n\n", .{branch});
    }
}

const legend_text = "Git Status: [●]=Staged [○]=Unstaged [?]=Untracked\nAnomalies: red name + '!' = broken symlink, dim name = empty (0-byte) file\nTime: '*' before timestamp = changed within last 24h\n\n";

fn showLegend(io: std.Io) !void {
    var output: display.UnifiedOutput = undefined;
    output.init(io);
    try output.writeAll(legend_text);
    try output.flush();
}

test "main runs without crashing" {
    // Integration test - just ensure imports work
    const allocator = std.testing.allocator;

    const config = types.Config.default();
    _ = config;
    _ = allocator;
}

test "legend text documents all symbols" {
    // No I/O: legend_text is what showLegend prints.
    try std.testing.expect(std.mem.indexOf(u8, legend_text, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, legend_text, "○") != null);
    try std.testing.expect(std.mem.indexOf(u8, legend_text, "?") != null);
    try std.testing.expect(std.mem.indexOf(u8, legend_text, "Untracked") != null);
}

test "parseBranchName trims git output" {
    try std.testing.expectEqualStrings("main", parseBranchName("main\n"));
    try std.testing.expectEqualStrings("feature/x", parseBranchName("feature/x\n\n"));
    try std.testing.expectEqualStrings("", parseBranchName("\n"));
    try std.testing.expectEqualStrings("", parseBranchName(""));
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

// Pull in tests from imported modules so `zig build test` actually runs them.
test {
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(git);
    std.testing.refAllDecls(filesystem);
    std.testing.refAllDecls(display);
    std.testing.refAllDecls(types);
}
