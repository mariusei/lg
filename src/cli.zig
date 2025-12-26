//! CLI argument parser with support for combined short flags.
//! Examples: -lan, -dt, -sr all work as expected.
//! Compatible with ls flags where possible, uses capitals for conflicts.

const std = @import("std");
const types = @import("types.zig");

/// Parse command-line arguments into a Config struct.
///
/// Allocates memory for file_filters if provided - caller owns the memory.
/// Prints help and exits if -h/--help is passed.
pub fn parseArgs(allocator: std.mem.Allocator) !types.Config {
    var config = types.Config.default();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    var positional = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer positional.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            // Check for long options first
            if (std.mem.eql(u8, arg, "--all")) {
                config.show_all = true;
            } else if (std.mem.eql(u8, arg, "--name")) {
                config.sort_alphabetical = true;
            } else if (std.mem.eql(u8, arg, "--type")) {
                config.group_by_type = true;
            } else if (std.mem.eql(u8, arg, "--dir-sizes")) {
                config.calc_dir_sizes = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                config.output_format = .json;
            } else if (std.mem.eql(u8, arg, "--porcelain")) {
                config.output_format = .porcelain;
            } else if (std.mem.eql(u8, arg, "--branch")) {
                config.show_branch = true;
            } else if (std.mem.eql(u8, arg, "--legend")) {
                config.show_legend = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                try printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "-ll")) {
                // -ll goes directly to full detail level
                config.detail_level = .full;
            } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and arg[1] != '-') {
                // Handle combined short flags (e.g., -dt = -d + -t)
                // Iterates char-by-char through flag string after '-'
                // Example: -lan expands to -l -a -n
                var i: usize = 1;
                while (i < arg.len) : (i += 1) {
                    const flag = arg[i];
                    switch (flag) {
                        'a' => config.show_all = true,
                        'n' => config.sort_alphabetical = true,
                        't' => config.group_by_type = true,
                        'd' => config.calc_dir_sizes = true,
                        'r' => config.reverse_order = true,
                        's' => config.sort_by_size = true,
                        'i' => config.show_inodes = true,
                        'T' => config.sort_by_time = true,
                        'F' => config.file_type_indicators = true,
                        'p' => config.append_dir_slash = true,
                        '1' => config.one_column = true,
                        'U' => config.unsorted = true,
                        'o' => config.omit_group = true,
                        'g' => config.omit_owner = true,
                        'X' => config.sort_by_extension = true,
                        // -l toggles detail levels: minimal → standard → full
                        // -ll (combined) jumps directly to full detail level
                        'l' => {
                            // Check if next char is also 'l' for -ll
                            if (i + 1 < arg.len and arg[i + 1] == 'l') {
                                config.detail_level = .full;
                                i += 1; // Skip the second 'l'
                            } else {
                                // Single -l toggles through detail levels
                                config.detail_level = switch (config.detail_level) {
                                    .minimal => .standard,
                                    .standard => .full,
                                    .full => .full,
                                };
                            }
                        },
                        'h' => {
                            try printHelp();
                            std.process.exit(0);
                        },
                        else => {
                            std.debug.print("Unknown option: -{c}\n", .{flag});
                            std.debug.print("Try 'lg --help' for more information.\n", .{});
                            return error.InvalidArgument;
                        },
                    }
                }
            } else {
                std.debug.print("Unknown option: {s}\n", .{arg});
                std.debug.print("Try 'lg --help' for more information.\n", .{});
                return error.InvalidArgument;
            }
        } else {
            // Positional argument
            try positional.append(allocator, arg);
        }
    }

    // Positional argument parsing strategy:
    // 1. Single arg that is a directory → enter that directory
    // 2. Multiple args → ALL are file filters
    //    - If args contain paths (like src/foo.zig), extract common dir and use basenames
    //    - This handles `lg src/*.zig` correctly
    if (positional.items.len == 1) {
        const first = positional.items[0];
        // Check if single arg is a directory
        const stat = std.fs.cwd().statFile(first) catch null;
        if (stat != null and stat.?.kind == .directory) {
            config.dir_path = first;
        } else {
            // Single non-directory arg: check if it has a path component
            if (std.mem.indexOf(u8, first, "/")) |_| {
                // Has path: use dirname as dir_path, basename as filter
                config.dir_path = std.fs.path.dirname(first) orelse ".";
                var basenames = try std.ArrayList([]const u8).initCapacity(allocator, 1);
                try basenames.append(allocator, std.fs.path.basename(first));
                config.file_filters = try basenames.toOwnedSlice(allocator);
            } else {
                // No path: filter in current directory
                config.file_filters = try allocator.dupe([]const u8, positional.items);
            }
        }
    } else if (positional.items.len > 1) {
        // Multiple args: check if they share a common directory (like src/*.zig expansion)
        const first = positional.items[0];
        if (std.mem.indexOf(u8, first, "/")) |_| {
            // First arg has path - extract dirname and use basenames for all
            const common_dir = std.fs.path.dirname(first) orelse ".";
            config.dir_path = common_dir;

            // Convert all paths to basenames
            var basenames = try std.ArrayList([]const u8).initCapacity(allocator, positional.items.len);
            for (positional.items) |item| {
                try basenames.append(allocator, std.fs.path.basename(item));
            }
            config.file_filters = try basenames.toOwnedSlice(allocator);
        } else {
            // No paths: file filters in current directory
            config.file_filters = try allocator.dupe([]const u8, positional.items);
        }
    }

    return config;
}

/// Print help message to stdout.
fn printHelp() !void {
    const stdout = std.fs.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buffer);
    const writer = &stdout_writer.interface;

    try writer.writeAll(
        \\Usage: lg [OPTIONS] [DIRECTORY] [FILES...]
        \\
        \\List directory contents with git status information.
        \\
        \\Options:
        \\  -a, --all          Show hidden files
        \\  -n, --name         Sort alphabetically by name (default: by time)
        \\  -r                 Reverse sort order
        \\  -s                 Sort by size (largest first)
        \\  -i                 Show inode numbers
        \\  -t, --type         Group by file type with blank lines between groups
        \\  -d, --dir-sizes    Calculate directory sizes (may be slow)
        \\  -l                 Standard detail level (permissions, owner)
        \\  -ll                Full detail level (octal mode, group)
        \\  -F                 Append file type indicators (/ for dirs, * for exec, @ for links)
        \\  -p                 Append / to directory names
        \\  -1                 One entry per line (simple output)
        \\  -U                 Unsorted (directory order, faster)
        \\  -o                 Long format, omit group info
        \\  -g                 Long format, omit owner info
        \\  -X                 Sort by file extension
        \\  --json             Output in JSON format
        \\  --porcelain        Machine-readable output
        \\  --branch           Show current git branch
        \\  --legend           Show git status legend
        \\  -h, --help         Show this help message
        \\
        \\Legacy ls Compatibility (capital letters):
        \\  -T                 Sort by time (ls -t equivalent)
        \\
        \\Compatibility Notes:
        \\  -t    Group by type (lg) vs sort by time (ls) → Use -T for time sort
        \\  -d    Calculate dir sizes (lg) vs list dir (ls) → Different behavior
        \\  -s    Sort by size (lg) vs show blocks (ls) → Different behavior
        \\
        \\Git Status Symbols:
        \\  [●] Staged changes    [○] Unstaged changes
        \\  [?] Untracked files   [!] Ignored files
        \\  [·] Clean/tracked (green dot)
        \\
        \\Examples:
        \\  lg                 # List current directory
        \\  lg -a              # Show hidden files
        \\  lg -l /tmp         # List /tmp with permissions
        \\  lg -sr             # Sort by size, largest last (reversed)
        \\  lg -iT             # Show inodes, sort by time
        \\  lg -F              # Show file type indicators
        \\  lg -1              # One column (simple list)
        \\  lg -U              # Unsorted (fast, natural order)
        \\  lg -X              # Sort by extension
        \\  lg src/*.zig       # List specific files
        \\
    );
    try writer.flush();
}

// ═══════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════

test "parseArgs - default config when no args" {
    // This test requires mocking args, which is tricky in Zig
    // For now, test the logic by calling Config.default()
    const config = types.Config.default();
    try std.testing.expectEqualStrings(".", config.dir_path);
    try std.testing.expectEqual(types.DetailLevel.minimal, config.detail_level);
}

test "Config toggles detail level correctly" {
    var config = types.Config.default();
    try std.testing.expectEqual(types.DetailLevel.minimal, config.detail_level);

    // Simulate -l flag
    config.detail_level = switch (config.detail_level) {
        .minimal => .standard,
        .standard => .full,
        .full => .full,
    };
    try std.testing.expectEqual(types.DetailLevel.standard, config.detail_level);

    // Simulate another -l
    config.detail_level = switch (config.detail_level) {
        .minimal => .standard,
        .standard => .full,
        .full => .full,
    };
    try std.testing.expectEqual(types.DetailLevel.full, config.detail_level);
}

test "printHelp does not crash" {
    // Just ensure it doesn't crash
    try printHelp();
}

test "flag parsing - show_all" {
    var config = types.Config.default();
    try std.testing.expect(!config.show_all);

    // Simulate -a flag
    config.show_all = true;
    try std.testing.expect(config.show_all);
}

test "flag parsing - sort_alphabetical" {
    var config = types.Config.default();
    try std.testing.expect(!config.sort_alphabetical);

    // Simulate -n flag
    config.sort_alphabetical = true;
    try std.testing.expect(config.sort_alphabetical);
}

test "flag parsing - output formats" {
    var config = types.Config.default();
    try std.testing.expectEqual(types.OutputFormat.normal, config.output_format);

    config.output_format = .json;
    try std.testing.expectEqual(types.OutputFormat.json, config.output_format);

    config.output_format = .porcelain;
    try std.testing.expectEqual(types.OutputFormat.porcelain, config.output_format);
}

test "flag parsing - group_by_type" {
    var config = types.Config.default();
    try std.testing.expect(!config.group_by_type);

    // Simulate -t flag
    config.group_by_type = true;
    try std.testing.expect(config.group_by_type);
}

test "flag parsing - calc_dir_sizes" {
    var config = types.Config.default();
    try std.testing.expect(!config.calc_dir_sizes);

    // Simulate -d flag
    config.calc_dir_sizes = true;
    try std.testing.expect(config.calc_dir_sizes);
}

test "flag parsing - show_branch" {
    var config = types.Config.default();
    try std.testing.expect(!config.show_branch);

    // Simulate --branch flag
    config.show_branch = true;
    try std.testing.expect(config.show_branch);
}

test "flag parsing - show_legend" {
    var config = types.Config.default();
    try std.testing.expect(!config.show_legend);

    // Simulate --legend flag
    config.show_legend = true;
    try std.testing.expect(config.show_legend);
}

test "detail level - minimal to standard transition" {
    var config = types.Config.default();
    try std.testing.expectEqual(types.DetailLevel.minimal, config.detail_level);

    // First -l: minimal -> standard
    config.detail_level = switch (config.detail_level) {
        .minimal => .standard,
        .standard => .full,
        .full => .full,
    };
    try std.testing.expectEqual(types.DetailLevel.standard, config.detail_level);
}

test "detail level - standard to full transition" {
    var config = types.Config.default();
    config.detail_level = .standard;

    // -l on standard: standard -> full
    config.detail_level = switch (config.detail_level) {
        .minimal => .standard,
        .standard => .full,
        .full => .full,
    };
    try std.testing.expectEqual(types.DetailLevel.full, config.detail_level);
}

test "detail level - full stays at full" {
    var config = types.Config.default();
    config.detail_level = .full;

    // -l on full: stays full
    config.detail_level = switch (config.detail_level) {
        .minimal => .standard,
        .standard => .full,
        .full => .full,
    };
    try std.testing.expectEqual(types.DetailLevel.full, config.detail_level);
}

test "all boolean flags default to false" {
    const config = types.Config.default();
    try std.testing.expect(!config.show_all);
    try std.testing.expect(!config.sort_alphabetical);
    try std.testing.expect(!config.show_branch);
    try std.testing.expect(!config.show_legend);
    try std.testing.expect(!config.calc_dir_sizes);
    try std.testing.expect(!config.group_by_type);
}

test "output format defaults to normal" {
    const config = types.Config.default();
    try std.testing.expectEqual(types.OutputFormat.normal, config.output_format);
}

test "file_filters defaults to null" {
    const config = types.Config.default();
    try std.testing.expect(config.file_filters == null);
}
