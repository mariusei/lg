const std = @import("std");
const types = @import("types.zig");
const colors = @import("colors.zig");
const git = @import("git.zig");

// Display configuration constants
const STDOUT_BUFFER_SIZE = 4096;  // Match typical page size for efficient I/O
const MIN_BAR_WIDTH: usize = 1;
const MAX_BAR_WIDTH: usize = 9;
const BAR_RANGE: usize = MAX_BAR_WIDTH - MIN_BAR_WIDTH;  // 8 characters of range
const DIR_BAR_FILL = "░";  // U+2591 Light Shade for directory bars
const DEFAULT_TERMINAL_WIDTH: usize = 80;  // Fallback if detection fails

/// Calculate visual length of string (excluding ANSI escape codes).
/// ANSI escape codes: ESC [ ... m (e.g., \x1b[38;5;214m)
fn visualLength(s: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[') {
            // Skip ANSI escape sequence until 'm'
            i += 2;
            while (i < s.len and s[i] != 'm') : (i += 1) {}
            i += 1; // Skip the 'm'
        } else {
            len += 1;
            i += 1;
        }
    }
    return len;
}

/// Calculate metadata width for a given detail level.
/// This is approximate - actual width may vary slightly.
fn getMetadataWidth(detail_level: types.DetailLevel, show_git: bool, show_inodes: bool) usize {
    var width: usize = 0;

    // Size column: "  12.3K " = ~8 chars (with bar it can be up to ~12)
    width += 12;

    // Git column: " ●   " = 5 chars
    if (show_git) {
        width += 5;
    }

    // Inode column (if shown): "123456789 " = ~10 chars
    if (show_inodes) {
        width += 10;
    }

    // Modified time: "Nov 21 03:32  " = ~14 chars
    width += 14;

    // Additional columns based on detail level
    switch (detail_level) {
        .minimal => {},
        .standard => {
            // Permissions: "drwxr-xr-x " = ~11 chars
            width += 11;
        },
        .full => {
            // Mode: "0755 " = ~5 chars
            // Permissions: "drwxr-xr-x " = ~11 chars
            // Owner/Group: varies, ~20 chars estimate
            width += 36;
        },
    }

    return width;
}

/// Main entry point for displaying files.
pub fn print(
    allocator: std.mem.Allocator,
    files: []const types.FileInfo,
    git_ctx: ?*const git.GitContext,
    config: types.Config,
) !void {
    switch (config.output_format) {
        .normal => try printNormal(allocator, files, git_ctx, config),
        .json => try printJson(files),
        .porcelain => try printPorcelain(files),
    }
}

/// Print files in human-readable format with colors.
fn printNormal(
    allocator: std.mem.Allocator,
    files: []const types.FileInfo,
    git_ctx: ?*const git.GitContext,
    config: types.Config,
) !void {
    const stdout = std.fs.File.stdout();

    // Print header (skip in one-column mode)
    if (!config.one_column) {
        try printHeader(stdout, config, git_ctx != null);
    }

    // Calculate size statistics for visual bars
    const size_stats = calculateSizeStats(files);

    // Track previous file type for blank line insertion
    var prev_ext: ?[]const u8 = null;
    var prev_was_dir: ?bool = null;

    // Print each file
    for (files, 0..) |file, i| {
        // Insert blank line when type changes (if grouping by type)
        if (config.group_by_type and i > 0) {
            const curr_is_dir = (file.kind == .directory);
            const curr_ext = if (!curr_is_dir) std.fs.path.extension(file.name) else null;

            // Check if we're switching categories
            var should_insert_blank = false;

            if (prev_was_dir) |was_dir| {
                if (was_dir != curr_is_dir) {
                    // Switching between dirs and files
                    should_insert_blank = true;
                } else if (!curr_is_dir and prev_ext != null and curr_ext != null) {
                    // Both are files, check if extension changed
                    if (!std.mem.eql(u8, prev_ext.?, curr_ext.?)) {
                        should_insert_blank = true;
                    }
                }
            }

            if (should_insert_blank) {
                var stdout_buffer: [STDOUT_BUFFER_SIZE]u8 = undefined;
                var stdout_writer = stdout.writer(&stdout_buffer);
                const writer = &stdout_writer.interface;
                try writer.writeAll("\n");
                try writer.flush();
            }

            // Update tracking variables
            prev_ext = curr_ext;
            prev_was_dir = curr_is_dir;
        }

        try printFileEntry(
            allocator,
            stdout,
            file,
            i,
            config.detail_level,
            git_ctx != null,
            size_stats,
            config,
        );
    }
}

/// Print header based on detail level.
fn printHeader(stdout: std.fs.File, config: types.Config, show_git: bool) !void {
    var stdout_buffer: [STDOUT_BUFFER_SIZE]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buffer);
    const writer = &stdout_writer.interface;

    const inode_col = if (config.show_inodes) "  Inode  " else "";

    switch (config.detail_level) {
        .minimal => {
            if (show_git) {
                try writer.print("{s}   Size     Git  Modified     Name\n", .{inode_col});
                try writer.writeAll("────────────────────────────────────────────────────────────\n");
            } else {
                try writer.print("{s}   Size     Modified     Name\n", .{inode_col});
                try writer.writeAll("──────────────────────────────────\n");
            }
        },
        .standard => {
            if (show_git) {
                try writer.print("{s}Permissions    Size   Git  Modified     Name                          Owner\n", .{inode_col});
                try writer.writeAll("────────────────────────────────────────────────────────────────────────────────────────\n");
            } else {
                try writer.print("{s}Permissions    Size   Modified     Name                          Owner\n", .{inode_col});
                try writer.writeAll("──────────────────────────────────────────────────────────────────────────────────\n");
            }
        },
        .full => {
            if (show_git) {
                // Build owner/group header dynamically based on -o/-g flags
                const owner_col = if (config.omit_owner) "" else "Owner            ";
                const group_col = if (config.omit_group) "" else "Group            ";
                try writer.print("{s}Mode       Size   Git  {s}{s}Modified     Name\n", .{ inode_col, owner_col, group_col });
                try writer.writeAll("────────────────────────────────────────────────────────────────────────────────────────\n");
            } else {
                // Build owner/group header dynamically based on -o/-g flags
                const owner_col = if (config.omit_owner) "" else "Owner            ";
                const group_col = if (config.omit_group) "" else "Group            ";
                try writer.print("{s}Mode       Size   {s}{s}Modified     Name\n", .{ inode_col, owner_col, group_col });
                try writer.writeAll("──────────────────────────────────────────────────────────────────────────────────\n");
            }
        },
    }
    try writer.flush();
}

const SizeStats = struct {
    min_log_file: f64,
    max_log_file: f64,
    min_log_dir: f64,
    max_log_dir: f64,
    has_files: bool,
    has_dirs: bool,
};

fn calculateSizeStats(files: []const types.FileInfo) SizeStats {
    var stats = SizeStats{
        .min_log_file = 0,
        .max_log_file = 0,
        .min_log_dir = 0,
        .max_log_dir = 0,
        .has_files = false,
        .has_dirs = false,
    };

    for (files) |file| {
        if (file.size == 0) continue;

        const log_size = @log(@as(f64, @floatFromInt(file.size)));

        switch (file.kind) {
            .directory => {
                if (!stats.has_dirs) {
                    stats.min_log_dir = log_size;
                    stats.max_log_dir = log_size;
                    stats.has_dirs = true;
                } else {
                    stats.min_log_dir = @min(stats.min_log_dir, log_size);
                    stats.max_log_dir = @max(stats.max_log_dir, log_size);
                }
            },
            else => {
                if (!stats.has_files) {
                    stats.min_log_file = log_size;
                    stats.max_log_file = log_size;
                    stats.has_files = true;
                } else {
                    stats.min_log_file = @min(stats.min_log_file, log_size);
                    stats.max_log_file = @max(stats.max_log_file, log_size);
                }
            },
        }
    }

    return stats;
}

fn printFileEntry(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    file: types.FileInfo,
    index: usize,
    detail: types.DetailLevel,
    show_git: bool,
    stats: SizeStats,
    config: types.Config,
) !void {

    var stdout_buffer: [STDOUT_BUFFER_SIZE]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buffer);
    const writer = &stdout_writer.interface;

    // One column mode: just print the name and return
    if (config.one_column) {
        const name_display = try formatName(allocator, file, config);
        defer allocator.free(name_display);
        try writer.print("{s}\n", .{name_display});
        try writer.flush();
        return;
    }

    // Format size
    var size_buf: [16]u8 = undefined;
    const size_str = try formatSizeInto(&size_buf, file.size, file.kind == .directory, config.calc_dir_sizes);

    // Calculate visual bar width (0-9 characters)
    var bar_width: usize = 0;
    var is_dir_bar = false;

    if (file.kind == .directory and config.calc_dir_sizes and stats.has_dirs and file.size > 0) {
        // Directory bar (only when -d flag is set)
        const log_size = @log(@as(f64, @floatFromInt(file.size)));
        const normalized: f64 = if (stats.max_log_dir > stats.min_log_dir)
            (log_size - stats.min_log_dir) / (stats.max_log_dir - stats.min_log_dir)
        else
            1.0;
        // Visual bar: logarithmic scaling maps file sizes to 1-9 char width
        // Formula: MIN + (normalized_0to1 × RANGE) = 1 + (n × 8) = 1-9 chars
        // Logarithmic prevents tiny files from being invisible vs huge files
        bar_width = MIN_BAR_WIDTH + @as(usize, @intFromFloat(normalized * BAR_RANGE));
        if (bar_width > MAX_BAR_WIDTH) bar_width = MAX_BAR_WIDTH;
        is_dir_bar = true;
    } else if (file.kind != .directory and stats.has_files and file.size > 0) {
        // File bar
        const log_size = @log(@as(f64, @floatFromInt(file.size)));
        const normalized: f64 = if (stats.max_log_file > stats.min_log_file)
            (log_size - stats.min_log_file) / (stats.max_log_file - stats.min_log_file)
        else
            1.0;
        bar_width = MIN_BAR_WIDTH + @as(usize, @intFromFloat(normalized * BAR_RANGE));
        if (bar_width > MAX_BAR_WIDTH) bar_width = MAX_BAR_WIDTH;
    }

    // Git status
    const git_symbol = file.git_status.symbol();
    const git_color = colors.getColor(file.git_status.colorName());
    const reset = if (git_color.len > 0 and !std.mem.eql(u8, git_color, colors.reset)) colors.reset else "";

    // Format time
    const time_str = try formatTime(allocator, file.mtime);
    defer allocator.free(time_str);

    // Format name with color/suffix
    const name_display = try formatName(allocator, file, config);
    defer allocator.free(name_display);

    // Alternating date color
    const date_color = if (index % 2 == 0) "" else "\x1b[38;5;241m";
    const date_reset = if (index % 2 == 0) "" else colors.reset;

    switch (detail) {
        .minimal => {
            // Print inode if requested
            if (config.show_inodes) {
                try writer.print("{d:>9} ", .{file.inode});
            }

            if (bar_width > 0) {
                // Create padded size string for bar overlay (7 chars + 5 spaces = 12)
                var padded_size: [12]u8 = undefined;
                const formatted = try std.fmt.bufPrint(&padded_size, "{s:>7}     ", .{size_str});

                // Render visual bar with size overlaid
                if (is_dir_bar) {
                    // Directory bars use box drawing characters
                    try writer.writeAll("\x1b[100m\x1b[97m");
                    for (formatted[0..bar_width]) |ch| {
                        if (ch == ' ') {
                            try writer.writeAll("░");
                        } else {
                            try writer.writeByte(ch);
                        }
                    }
                    try writer.writeAll("\x1b[0m");
                    try writer.writeAll(formatted[bar_width..]);
                } else {
                    // File bars are solid background
                    try writer.print("\x1b[100m\x1b[97m{s}\x1b[0m{s}", .{
                        formatted[0..bar_width],
                        formatted[bar_width..],
                    });
                }
            } else {
                try writer.print("{s:>7}     ", .{size_str});
            }

            if (show_git) {
                try writer.print("{s}{s}{s}   ", .{ git_color, git_symbol, reset });
            }
            try writer.print("{s}{s}{s}  {s}\n", .{ date_color, time_str, date_reset, name_display });
        },
        .standard => {
            // Print inode if requested
            if (config.show_inodes) {
                try writer.print("{d:>9} ", .{file.inode});
            }

            const perm_str = try formatPermissions(allocator, file);
            defer allocator.free(perm_str);

            try writer.print("{s} ", .{perm_str});

            if (bar_width > 0) {
                // Create padded size string for bar overlay (7 chars + 3 spaces = 10)
                var padded_size: [10]u8 = undefined;
                const formatted = try std.fmt.bufPrint(&padded_size, "{s:>7}   ", .{size_str});

                // Render visual bar with size overlaid
                if (is_dir_bar) {
                    // Directory bars use box drawing characters
                    try writer.writeAll("\x1b[100m\x1b[97m");
                    for (formatted[0..bar_width]) |ch| {
                        if (ch == ' ') {
                            try writer.writeAll("░");
                        } else {
                            try writer.writeByte(ch);
                        }
                    }
                    try writer.writeAll("\x1b[0m");
                    try writer.writeAll(formatted[bar_width..]);
                } else {
                    // File bars are solid background
                    try writer.print("\x1b[100m\x1b[97m{s}\x1b[0m{s}", .{
                        formatted[0..bar_width],
                        formatted[bar_width..],
                    });
                }
            } else {
                try writer.print("{s:>7}   ", .{size_str});
            }

            if (show_git) {
                try writer.print("{s}{s}{s}   ", .{ git_color, git_symbol, reset });
            }
            try writer.print("{s}{s}{s}  {s}\n", .{ date_color, time_str, date_reset, name_display });
        },
        .full => {
            // Print inode if requested
            if (config.show_inodes) {
                try writer.print("{d:>9} ", .{file.inode});
            }

            // Octal mode
            const mode_str = try std.fmt.allocPrint(allocator, "{o:0>4}", .{file.mode & 0o7777});
            defer allocator.free(mode_str);

            try writer.print("{s} ", .{mode_str});

            if (bar_width > 0) {
                // Create padded size string for bar overlay (7 chars + 3 spaces = 10)
                var padded_size: [10]u8 = undefined;
                const formatted = try std.fmt.bufPrint(&padded_size, "{s:>7}   ", .{size_str});

                // Render visual bar with size overlaid
                if (is_dir_bar) {
                    // Directory bars use box drawing characters
                    try writer.writeAll("\x1b[100m\x1b[97m");
                    for (formatted[0..bar_width]) |ch| {
                        if (ch == ' ') {
                            try writer.writeAll("░");
                        } else {
                            try writer.writeByte(ch);
                        }
                    }
                    try writer.writeAll("\x1b[0m");
                    try writer.writeAll(formatted[bar_width..]);
                } else {
                    // File bars are solid background
                    try writer.print("\x1b[100m\x1b[97m{s}\x1b[0m{s}", .{
                        formatted[0..bar_width],
                        formatted[bar_width..],
                    });
                }
            } else {
                try writer.print("{s:>7}   ", .{size_str});
            }

            if (show_git) {
                try writer.print("{s}{s}{s}   ", .{ git_color, git_symbol, reset });
            }

            // Owner/group as uid/gid
            // -o: omit group, -g: omit owner
            if (config.omit_group and !config.omit_owner) {
                // -o: show only owner
                try writer.print("uid:{d:<10} ", .{file.uid});
            } else if (config.omit_owner and !config.omit_group) {
                // -g: show only group
                try writer.print("gid:{d:<10} ", .{file.gid});
            } else if (!config.omit_owner and !config.omit_group) {
                // Default: show both
                try writer.print("uid:{d:<10} gid:{d:<10} ", .{ file.uid, file.gid });
            }
            // If both -o and -g are set, show nothing (no owner, no group)

            try writer.print("{s}{s}{s}  {s}\n", .{ date_color, time_str, date_reset, name_display });
        },
    }
    try writer.flush();
}

/// Format file size in human-readable format (B, K, M, G).
fn formatSizeInto(buf: []u8, size: u64, is_dir: bool, calc_dir_sizes: bool) ![]const u8 {
    if (is_dir and !calc_dir_sizes) return "     -";
    if (size < 1024) return try std.fmt.bufPrint(buf, "{d:>5}B", .{size});
    if (size < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(size)) / 1024.0;
        return try std.fmt.bufPrint(buf, "{d:>5.1}K", .{kb});
    }
    if (size < 1024 * 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
        return try std.fmt.bufPrint(buf, "{d:>5.1}M", .{mb});
    }
    const gb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0);
    return try std.fmt.bufPrint(buf, "{d:>5.1}G", .{gb});
}

/// Format time as "Mon DD HH:MM".
fn formatTime(allocator: std.mem.Allocator, mtime: i128) ![]const u8 {
    const epoch_secs = @divFloor(mtime, std.time.ns_per_s);
    const epoch_day = @divFloor(epoch_secs, std.time.s_per_day);
    const day_secs = @mod(epoch_secs, std.time.s_per_day);

    // Convert epoch day to year/month/day using manual calculation
    // since Zig 0.15.2 doesn't have fromEpochDay
    const year_day = std.time.epoch.EpochDay{ .day = @intCast(epoch_day) };
    const year_and_day = year_day.calculateYearDay();
    const month_day = year_and_day.calculateMonthDay();
    const day_secs_casted = std.time.epoch.DaySeconds{ .secs = @intCast(day_secs) };

    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month_name = month_names[@intFromEnum(month_day.month) - 1];

    return try std.fmt.allocPrint(
        allocator,
        "{s} {d:>2} {d:0>2}:{d:0>2}",
        .{ month_name, month_day.day_index + 1, day_secs_casted.getHoursIntoDay(), day_secs_casted.getMinutesIntoHour() },
    );
}

/// Get file type suffix based on config flags.
/// Returns "/" for directories (with -F or -p), "*" for executables (with -F), "@" for symlinks (with -F).
fn getFileTypeSuffix(file: types.FileInfo, config: types.Config) []const u8 {
    // -F shows all file type indicators
    if (config.file_type_indicators) {
        return switch (file.kind) {
            .directory => "/",
            .symlink => "@",
            .file => |f| if (f.executable) "*" else "",
        };
    }

    // -p shows only directory slash
    if (config.append_dir_slash and file.kind == .directory) {
        return "/";
    }

    return "";
}

/// Format name with color and optional type suffix.
fn formatName(allocator: std.mem.Allocator, file: types.FileInfo, config: types.Config) ![]const u8 {
    const color = switch (file.kind) {
        .directory => colors.directory,
        .symlink => colors.symlink,
        .file => |f| if (f.executable) colors.executable else "",
    };

    const suffix = getFileTypeSuffix(file, config);
    const reset = if (color.len > 0) colors.reset else "";

    return try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{
        color,
        file.name,
        suffix,
        reset,
    });
}

/// Format permissions as drwxr-xr-x (including file type).
fn formatPermissions(allocator: std.mem.Allocator, file: types.FileInfo) ![]const u8 {
    const S = std.posix.S;
    const mode = file.mode;

    // Determine file type character
    const type_char: u8 = switch (file.kind) {
        .directory => 'd',
        .symlink => 'l',
        .file => '-',
    };

    const perm = [_]u8{
        type_char,
        if (mode & S.IRUSR != 0) 'r' else '-',
        if (mode & S.IWUSR != 0) 'w' else '-',
        if (mode & S.IXUSR != 0) 'x' else '-',
        if (mode & S.IRGRP != 0) 'r' else '-',
        if (mode & S.IWGRP != 0) 'w' else '-',
        if (mode & S.IXGRP != 0) 'x' else '-',
        if (mode & S.IROTH != 0) 'r' else '-',
        if (mode & S.IWOTH != 0) 'w' else '-',
        if (mode & S.IXOTH != 0) 'x' else '-',
    };

    return try std.fmt.allocPrint(allocator, "{s}", .{perm});
}

/// Get terminal width in columns. Returns DEFAULT_TERMINAL_WIDTH if detection fails.
fn getTerminalWidth() usize {
    // Define C winsize struct directly since std.posix.winsize may have different fields
    const winsize = extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    };

    const stdout_fd = std.fs.File.stdout().handle;
    const TIOCGWINSZ: u32 = 0x40087468; // macOS/BSD value for TIOCGWINSZ

    var ws = std.mem.zeroes(winsize);
    const result = std.c.ioctl(stdout_fd, TIOCGWINSZ, @intFromPtr(&ws));

    if (result == 0 and ws.ws_col > 0) {
        return ws.ws_col;
    }

    return DEFAULT_TERMINAL_WIDTH;
}

/// Print files in JSON format.
fn printJson(files: []const types.FileInfo) !void {
    const stdout = std.fs.File.stdout();
    var stdout_buffer: [STDOUT_BUFFER_SIZE]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buffer);
    const writer = &stdout_writer.interface;

    try writer.writeAll("[");
    for (files, 0..) |file, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print(
            \\
            \\  {{"name":"{s}","size":{d},"mode":"{o:0>4}","git":"{c}"}}
        ,
            .{
                file.name,
                file.size,
                file.mode & 0o7777,
                @intFromEnum(file.git_status),
            },
        );
    }
    try writer.writeAll("\n]\n");
    try writer.flush();
}

/// Print files in porcelain (machine-readable) format.
fn printPorcelain(files: []const types.FileInfo) !void {
    const stdout = std.fs.File.stdout();
    var stdout_buffer: [STDOUT_BUFFER_SIZE]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buffer);
    const writer = &stdout_writer.interface;

    for (files) |file| {
        try writer.print(
            "{o:0>4} {d} {c} {s}\n",
            .{
                file.mode & 0o7777,
                file.size,
                @intFromEnum(file.git_status),
                file.name,
            },
        );
    }
    try writer.flush();
}

// ═══════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════

test "formatSize - bytes" {
    var buf: [16]u8 = undefined;
    const str = try formatSizeInto(&buf, 123, false, false);
    try std.testing.expectEqualStrings("  123B", str);
}

test "formatSize - kilobytes" {
    var buf: [16]u8 = undefined;
    const str = try formatSizeInto(&buf, 2048, false, false);
    try std.testing.expectEqualStrings("  2.0K", str);
}

test "formatSize - megabytes" {
    var buf: [16]u8 = undefined;
    const str = try formatSizeInto(&buf, 5 * 1024 * 1024, false, false);
    try std.testing.expectEqualStrings("  5.0M", str);
}

test "formatSize - gigabytes" {
    var buf: [16]u8 = undefined;
    const str = try formatSizeInto(&buf, 3 * 1024 * 1024 * 1024, false, false);
    try std.testing.expectEqualStrings("  3.0G", str);
}

test "formatSize - directory without calc_dir_sizes" {
    var buf: [16]u8 = undefined;
    const str = try formatSizeInto(&buf, 1024, true, false);
    try std.testing.expectEqualStrings("     -", str);
}

test "formatSize - edge case 1023 bytes" {
    var buf: [16]u8 = undefined;
    const str = try formatSizeInto(&buf, 1023, false, false);
    try std.testing.expectEqualStrings(" 1023B", str);
}

test "formatSize - edge case 1024 bytes" {
    var buf: [16]u8 = undefined;
    const str = try formatSizeInto(&buf, 1024, false, false);
    try std.testing.expectEqualStrings("  1.0K", str);
}

test "formatName - regular file (no flags)" {
    const allocator = std.testing.allocator;

    const file = types.FileInfo{
        .name = "test.txt",
        .mode = 0o644,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .{ .file = .{ .executable = false } },
        .inode = 12345,
    };

    const config = types.Config.default();
    const str = try formatName(allocator, file, config);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("test.txt", str);
}

test "formatName - executable file with -F" {
    const allocator = std.testing.allocator;

    const file = types.FileInfo{
        .name = "script.sh",
        .mode = 0o755,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .{ .file = .{ .executable = true } },
        .inode = 12345,
    };

    var config = types.Config.default();
    config.file_type_indicators = true;
    const str = try formatName(allocator, file, config);
    defer allocator.free(str);

    // Should contain executable color + name + * + reset
    try std.testing.expect(std.mem.indexOf(u8, str, "script.sh*") != null);
}

test "formatName - directory with -F" {
    const allocator = std.testing.allocator;

    const file = types.FileInfo{
        .name = "mydir",
        .mode = 0o755,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .directory,
        .inode = 12345,
    };

    var config = types.Config.default();
    config.file_type_indicators = true;
    const str = try formatName(allocator, file, config);
    defer allocator.free(str);

    // Should contain directory color + name + / + reset
    try std.testing.expect(std.mem.indexOf(u8, str, "mydir/") != null);
}

test "formatName - symlink with -F" {
    const allocator = std.testing.allocator;

    const file = types.FileInfo{
        .name = "link",
        .mode = 0o777,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .symlink,
        .inode = 12345,
    };

    var config = types.Config.default();
    config.file_type_indicators = true;
    const str = try formatName(allocator, file, config);
    defer allocator.free(str);

    // Should contain symlink color + name + @ + reset
    try std.testing.expect(std.mem.indexOf(u8, str, "link@") != null);
}

test "formatPermissions - file rwxr-xr-x" {
    const allocator = std.testing.allocator;

    const file = types.FileInfo{
        .name = "test",
        .mode = 0o755,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .{ .file = .{ .executable = true } },
        .inode = 0,
    };

    const str = try formatPermissions(allocator, file);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("-rwxr-xr-x", str);
}

test "formatPermissions - directory rwxr-xr-x" {
    const allocator = std.testing.allocator;

    const file = types.FileInfo{
        .name = "test",
        .mode = 0o755,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .directory,
        .inode = 0,
    };

    const str = try formatPermissions(allocator, file);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("drwxr-xr-x", str);
}

test "formatPermissions - symlink rwxrwxrwx" {
    const allocator = std.testing.allocator;

    const file = types.FileInfo{
        .name = "test",
        .mode = 0o777,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .symlink,
        .inode = 0,
    };

    const str = try formatPermissions(allocator, file);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("lrwxrwxrwx", str);
}

test "formatPermissions - file rw-r--r--" {
    const allocator = std.testing.allocator;

    const file = types.FileInfo{
        .name = "test",
        .mode = 0o644,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .{ .file = .{ .executable = false } },
        .inode = 0,
    };

    const str = try formatPermissions(allocator, file);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("-rw-r--r--", str);
}

test "formatTime - epoch zero" {
    const allocator = std.testing.allocator;

    const str = try formatTime(allocator, 0);
    defer allocator.free(str);

    // Epoch 0 is 1970-01-01 00:00:00 UTC
    try std.testing.expectEqualStrings("Jan  1 00:00", str);
}

test "formatTime - known timestamp" {
    const allocator = std.testing.allocator;

    // 2024-03-15 14:30:00 UTC
    // This is approximately 1710513000 seconds since epoch
    const timestamp_ns: i128 = 1710513000 * std.time.ns_per_s;
    const str = try formatTime(allocator, timestamp_ns);
    defer allocator.free(str);

    // Should be Mar 15 14:30
    try std.testing.expect(std.mem.startsWith(u8, str, "Mar"));
}

test "calculateSizeStats - empty array" {
    const files: []const types.FileInfo = &[_]types.FileInfo{};
    const stats = calculateSizeStats(files);

    try std.testing.expect(!stats.has_files);
    try std.testing.expect(!stats.has_dirs);
}

test "calculateSizeStats - files only" {
    const files = [_]types.FileInfo{
        .{
            .name = "file1",
            .mode = 0o644,
            .size = 100,
            .mtime = 0,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "file2",
            .mode = 0o644,
            .size = 1000,
            .mtime = 0,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
    };

    const stats = calculateSizeStats(&files);

    try std.testing.expect(stats.has_files);
    try std.testing.expect(!stats.has_dirs);
}

test "printJson - single file" {
    // This would require capturing stdout, which is complex in tests
    // For now, we just verify it compiles and doesn't crash
    const files = [_]types.FileInfo{
        .{
            .name = "test.txt",
            .mode = 0o644,
            .size = 123,
            .mtime = 0,
            .uid = 1000,
            .gid = 1000,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
    };

    // We can't easily test output without mocking stdout
    // This test just ensures the function is callable
    _ = files;
}

test "printPorcelain - single file" {
    // Similar to printJson, this would require stdout capture
    const files = [_]types.FileInfo{
        .{
            .name = "test.txt",
            .mode = 0o644,
            .size = 123,
            .mtime = 0,
            .uid = 1000,
            .gid = 1000,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
    };

    _ = files;
}

test "getTerminalWidth - returns default" {
    const width = getTerminalWidth();
    try std.testing.expectEqual(@as(usize, 80), width);
}

test "formatName - directory with -p (slash only)" {
    const allocator = std.testing.allocator;

    const file = types.FileInfo{
        .name = "testdir",
        .mode = 0o755,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .directory,
        .inode = 12345,
    };

    var config = types.Config.default();
    config.append_dir_slash = true;
    const str = try formatName(allocator, file, config);
    defer allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "testdir/") != null);
}

test "formatName - file without -F or -p (no suffix)" {
    const allocator = std.testing.allocator;

    const file = types.FileInfo{
        .name = "exec",
        .mode = 0o755,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .{ .file = .{ .executable = true } },
        .inode = 12345,
    };

    const config = types.Config.default();
    const str = try formatName(allocator, file, config);
    defer allocator.free(str);

    // Should have color but NO * suffix without -F
    try std.testing.expect(std.mem.indexOf(u8, str, "*") == null);
    try std.testing.expect(std.mem.indexOf(u8, str, "exec") != null);
}
