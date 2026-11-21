const std = @import("std");
const types = @import("types.zig");
const colors = @import("colors.zig");
const git = @import("git.zig");

// libc externs for localtime conversion (matches `ls -l`), in place of @cImport
// (removed in Zig 0.17). Layout matches Darwin and glibc struct tm.
const time_t = c_long;
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern fn localtime_r(timep: *const time_t, result: *Tm) callconv(.c) ?*Tm;
extern fn time(tloc: ?*time_t) callconv(.c) time_t;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) callconv(.c) c_int;
extern fn tzset() callconv(.c) void;

// Display configuration constants
const STDOUT_BUFFER_SIZE = 4096; // Match typical page size for efficient I/O
const MIN_BAR_WIDTH: usize = 1;
const MAX_BAR_WIDTH: usize = 9;
const BAR_RANGE: usize = MAX_BAR_WIDTH - MIN_BAR_WIDTH; // 8 characters of range
const DIR_BAR_FILL = "░"; // U+2591 Light Shade for directory bars

/// Unified buffered output writer for consistent stdout handling
/// Solves terminal emulator parsing issues by using single buffer/flush
pub const UnifiedOutput = struct {
    stdout: std.Io.File,
    buffer: [STDOUT_BUFFER_SIZE]u8,
    writer: std.Io.File.Writer,

    /// Create unified output with configured buffer size.
    /// Takes the destination by pointer: the writer stores a pointer into
    /// `self.buffer`, so the struct must not move after init.
    pub fn init(self: *UnifiedOutput, io: std.Io) void {
        self.* = .{
            .stdout = std.Io.File.stdout(),
            .buffer = undefined,
            .writer = undefined,
        };
        self.writer = self.stdout.writer(io, &self.buffer);
    }

    /// Write formatted string
    pub fn print(self: *UnifiedOutput, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.interface.print(fmt, args);
    }

    /// Write raw bytes
    pub fn writeAll(self: *UnifiedOutput, data: []const u8) !void {
        try self.writer.interface.writeAll(data);
    }

    /// Write newline
    pub fn writeByte(self: *UnifiedOutput, byte: u8) !void {
        try self.writer.interface.writeByte(byte);
    }

    /// Flush output (call once at end of complete output)
    pub fn flush(self: *UnifiedOutput) !void {
        try self.writer.interface.flush();
    }
};

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
        } else if ((s[i] & 0xC0) == 0x80) {
            // UTF-8 continuation byte: not a column of its own
            i += 1;
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
    io: std.Io,
    allocator: std.mem.Allocator,
    files: []const types.FileInfo,
    git_ctx: ?*const git.GitContext,
    config: types.Config,
) !void {
    var output: UnifiedOutput = undefined;
    output.init(io);

    switch (config.output_format) {
        .normal => try printNormal(allocator, files, git_ctx, config, &output),
        .json => try printJson(allocator, files, &output),
        .porcelain => try printPorcelain(files, &output, config.nul_terminated),
    }

    try output.flush();
}

/// Print files in human-readable format with colors.
fn printNormal(
    allocator: std.mem.Allocator,
    files: []const types.FileInfo,
    git_ctx: ?*const git.GitContext,
    config: types.Config,
    output: *UnifiedOutput,
) !void {
    // The "." entry added by -d is list-bookkeeping, not a listing entry:
    // hide it here and keep only its size (used for the Total line below).
    var root_size: ?u64 = null;
    var visible: std.ArrayList(types.FileInfo) = .empty;
    defer visible.deinit(allocator);
    for (files) |file| {
        if (std.mem.eql(u8, file.name, ".") and file.kind == .directory) {
            root_size = file.size;
            continue;
        }
        try visible.append(allocator, file);
    }
    const shown = visible.items;

    // Print header (skip in one-column mode)
    if (!config.one_column) {
        try printHeader(config, git_ctx != null, output);
    }

    // Calculate size statistics for visual bars
    const size_stats = calculateSizeStats(shown);

    // Track previous file type for blank line insertion
    var prev_ext: ?[]const u8 = null;
    var prev_was_dir: ?bool = null;

    // Print each file (excluding the hidden "." bookkeeping entry)
    for (shown, 0..) |file, i| {
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
                try output.writeAll("\n");
            }

            // Update tracking variables
            prev_ext = curr_ext;
            prev_was_dir = curr_is_dir;
        }

        try printFileEntry(
            allocator,
            file,
            i,
            config.detail_level,
            git_ctx != null,
            size_stats,
            config,
            output,
        );
    }

    // Scenario D: total size line when -d is active. Suppressed in one-column
    // mode, where stdout must stay machine-consumable names-only.
    // root_size is du(cwd) carried in by the hidden "." entry; summing the
    // visible rows instead would undercount hidden files.
    if (config.calc_dir_sizes and !config.one_column) {
        var total: u64 = root_size orelse 0;
        if (root_size == null) {
            for (shown) |file| total +|= file.size;
        }
        var size_buf: [32]u8 = undefined;
        const size_str = std.mem.trimStart(u8, try formatSizeInto(&size_buf, total, false, true), " ");
        const dim = if (config.use_color) colors.dim else "";
        const reset = if (config.use_color) colors.reset else "";
        try output.print("{s}Total: {s}{s}\n", .{ dim, size_str, reset });
    }

    // Scenario C: one-line git summary at the bottom of the listing.
    // Suppressed in one-column mode for the same reason.
    if (!config.one_column) {
        if (git_ctx) |ctx| try printGitSummary(ctx, config, output);
    }
}

/// Print a one-line summary of staged/unstaged/untracked counts and, when
/// upstream is configured, ahead/behind. Prints nothing when the repo is
/// clean and in sync (or has no upstream and nothing outstanding).
fn printGitSummary(git_ctx: *const git.GitContext, config: types.Config, output: *UnifiedOutput) !void {
    const s = git_ctx.summary;
    var parts: [5][]const u8 = undefined;
    var buf: [5][32]u8 = undefined;
    var n: usize = 0;

    if (s.staged > 0) {
        parts[n] = std.fmt.bufPrint(&buf[n], "{d} staged", .{s.staged}) catch unreachable;
        n += 1;
    }
    if (s.unstaged > 0) {
        parts[n] = std.fmt.bufPrint(&buf[n], "{d} unstaged", .{s.unstaged}) catch unreachable;
        n += 1;
    }
    if (s.untracked > 0) {
        parts[n] = std.fmt.bufPrint(&buf[n], "{d} untracked", .{s.untracked}) catch unreachable;
        n += 1;
    }
    if (s.has_upstream and s.ahead > 0) {
        parts[n] = std.fmt.bufPrint(&buf[n], "{d} ahead", .{s.ahead}) catch unreachable;
        n += 1;
    }
    if (s.has_upstream and s.behind > 0) {
        parts[n] = std.fmt.bufPrint(&buf[n], "{d} behind", .{s.behind}) catch unreachable;
        n += 1;
    }
    if (n == 0) return;

    const dim = if (config.use_color) colors.dim else "";
    const reset = if (config.use_color) colors.reset else "";
    try output.writeAll(dim);
    for (parts[0..n], 0..) |part, i| {
        if (i > 0) try output.writeAll(" · ");
        try output.writeAll(part);
    }
    try output.writeAll(reset);
    try output.writeAll("\n");
}

/// Print header based on detail level.
fn printHeader(
    config: types.Config,
    show_git: bool,
    output: *UnifiedOutput,
) !void {
    const inode_col = if (config.show_inodes) "  Inode  " else "";

    switch (config.detail_level) {
        .minimal => {
            if (show_git) {
                try output.print("{s}   Size     Git  Modified     Name\n", .{inode_col});
                try output.writeAll("────────────────────────────────────────────────────────────\n");
            } else {
                try output.print("{s}   Size     Modified     Name\n", .{inode_col});
                try output.writeAll("──────────────────────────────────\n");
            }
        },
        .standard => {
            if (show_git) {
                try output.print("{s}Permissions    Size   Git  Modified     Name                          Owner\n", .{inode_col});
                try output.writeAll("────────────────────────────────────────────────────────────────────────────────────────\n");
            } else {
                try output.print("{s}Permissions    Size   Modified     Name                          Owner\n", .{inode_col});
                try output.writeAll("──────────────────────────────────────────────────────────────────────────────────\n");
            }
        },
        .full => {
            if (show_git) {
                // Build owner/group header dynamically based on -o/-g flags
                const owner_col = if (config.omit_owner) "" else "Owner            ";
                const group_col = if (config.omit_group) "" else "Group            ";
                try output.print("{s}Mode       Size   Git  {s}{s}Modified     Name\n", .{ inode_col, owner_col, group_col });
                try output.writeAll("────────────────────────────────────────────────────────────────────────────────────────\n");
            } else {
                // Build owner/group header dynamically based on -o/-g flags
                const owner_col = if (config.omit_owner) "" else "Owner            ";
                const group_col = if (config.omit_group) "" else "Group            ";
                try output.print("{s}Mode       Size   {s}{s}Modified     Name\n", .{ inode_col, owner_col, group_col });
                try output.writeAll("──────────────────────────────────────────────────────────────────────────────────\n");
            }
        },
    }
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
    file: types.FileInfo,
    index: usize,
    detail: types.DetailLevel,
    show_git: bool,
    stats: SizeStats,
    config: types.Config,
    output: *UnifiedOutput,
) !void {
    // One column mode: just print the name and return
    if (config.one_column) {
        const name_display = try formatName(allocator, file, config);
        defer allocator.free(name_display);
        try output.print("{s}\n", .{name_display});
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
    const use_color = config.use_color;
    const git_symbol = file.git_status.symbol();
    const git_color = if (use_color) colors.getColor(file.git_status.colorName()) else "";
    const reset = if (use_color and git_color.len > 0 and !std.mem.eql(u8, git_color, colors.reset)) colors.reset else "";

    // Format time
    const now_secs: i64 = @intCast(time(null));
    const time_str = try formatTimeRel(allocator, file.mtime, now_secs);
    defer allocator.free(time_str);

    // Format name with color/suffix
    const name_display = try formatName(allocator, file, config);
    defer allocator.free(name_display);

    // Alternating date color
    const date_alt = use_color and index % 2 == 1;
    const date_color = if (date_alt) "\x1b[38;5;241m" else "";
    const date_reset = if (date_alt) colors.reset else "";

    switch (detail) {
        .minimal => {
            // Print inode if requested
            if (config.show_inodes) {
                try output.print("{d:>9} ", .{file.inode});
            }

            if (bar_width > 0 and use_color) {
                // Create padded size string for bar overlay (7 chars + 5 spaces = 12)
                var padded_size: [12]u8 = undefined;
                const formatted = try std.fmt.bufPrint(&padded_size, "{s:>7}     ", .{size_str});

                // Render visual bar with size overlaid
                if (is_dir_bar) {
                    // Directory bars use box drawing characters
                    try output.writeAll("\x1b[100m\x1b[97m");
                    for (formatted[0..bar_width]) |ch| {
                        if (ch == ' ') {
                            try output.writeAll("░");
                        } else {
                            try output.writeByte(ch);
                        }
                    }
                    try output.writeAll("\x1b[0m");
                    try output.writeAll(formatted[bar_width..]);
                } else {
                    // File bars are solid background
                    try output.print("\x1b[100m\x1b[97m{s}\x1b[0m{s}", .{
                        formatted[0..bar_width],
                        formatted[bar_width..],
                    });
                }
            } else {
                try output.print("{s:>7}     ", .{size_str});
            }

            if (show_git) {
                try output.print("{s}{s}{s}   ", .{ git_color, git_symbol, reset });
            }
            try output.print("{s}{s}{s}  {s}\n", .{ date_color, time_str, date_reset, name_display });
        },
        .standard => {
            // Print inode if requested
            if (config.show_inodes) {
                try output.print("{d:>9} ", .{file.inode});
            }

            const perm_str = try formatPermissions(allocator, file);
            defer allocator.free(perm_str);

            try output.print("{s} ", .{perm_str});

            if (bar_width > 0 and use_color) {
                // Create padded size string for bar overlay (7 chars + 3 spaces = 10)
                var padded_size: [10]u8 = undefined;
                const formatted = try std.fmt.bufPrint(&padded_size, "{s:>7}   ", .{size_str});

                // Render visual bar with size overlaid
                if (is_dir_bar) {
                    // Directory bars use box drawing characters
                    try output.writeAll("\x1b[100m\x1b[97m");
                    for (formatted[0..bar_width]) |ch| {
                        if (ch == ' ') {
                            try output.writeAll("░");
                        } else {
                            try output.writeByte(ch);
                        }
                    }
                    try output.writeAll("\x1b[0m");
                    try output.writeAll(formatted[bar_width..]);
                } else {
                    // File bars are solid background
                    try output.print("\x1b[100m\x1b[97m{s}\x1b[0m{s}", .{
                        formatted[0..bar_width],
                        formatted[bar_width..],
                    });
                }
            } else {
                try output.print("{s:>7}   ", .{size_str});
            }

            if (show_git) {
                try output.print("{s}{s}{s}   ", .{ git_color, git_symbol, reset });
            }
            try output.print("{s}{s}{s}  {s}\n", .{ date_color, time_str, date_reset, name_display });
        },
        .full => {
            // Print inode if requested
            if (config.show_inodes) {
                try output.print("{d:>9} ", .{file.inode});
            }

            // Octal mode
            const mode_str = try std.fmt.allocPrint(allocator, "{o:0>4}", .{file.mode & 0o7777});
            defer allocator.free(mode_str);

            try output.print("{s} ", .{mode_str});

            if (bar_width > 0 and use_color) {
                // Create padded size string for bar overlay (7 chars + 3 spaces = 10)
                var padded_size: [10]u8 = undefined;
                const formatted = try std.fmt.bufPrint(&padded_size, "{s:>7}   ", .{size_str});

                // Render visual bar with size overlaid
                if (is_dir_bar) {
                    // Directory bars use box drawing characters
                    try output.writeAll("\x1b[100m\x1b[97m");
                    for (formatted[0..bar_width]) |ch| {
                        if (ch == ' ') {
                            try output.writeAll("░");
                        } else {
                            try output.writeByte(ch);
                        }
                    }
                    try output.writeAll("\x1b[0m");
                    try output.writeAll(formatted[bar_width..]);
                } else {
                    // File bars are solid background
                    try output.print("\x1b[100m\x1b[97m{s}\x1b[0m{s}", .{
                        formatted[0..bar_width],
                        formatted[bar_width..],
                    });
                }
            } else {
                try output.print("{s:>7}   ", .{size_str});
            }

            if (show_git) {
                try output.print("{s}{s}{s}   ", .{ git_color, git_symbol, reset });
            }

            // Owner/group as uid/gid
            // -o: omit group, -g: omit owner
            if (config.omit_group and !config.omit_owner) {
                // -o: show only owner
                try output.print("uid:{d:<10} ", .{file.uid});
            } else if (config.omit_owner and !config.omit_group) {
                // -g: show only group
                try output.print("gid:{d:<10} ", .{file.gid});
            } else if (!config.omit_owner and !config.omit_group) {
                // Default: show both
                try output.print("uid:{d:<10} gid:{d:<10} ", .{ file.uid, file.gid });
            }
            // If both -o and -g are set, show nothing (no owner, no group)

            try output.print("{s}{s}{s}  {s}\n", .{ date_color, time_str, date_reset, name_display });
        },
    }
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

    // Convert to the local timezone via libc so output matches `ls -l`
    // (respects the active timezone and DST through the system tz database).
    var time_val: time_t = @intCast(epoch_secs);
    var tm_result: Tm = undefined;
    if (localtime_r(&time_val, &tm_result) == null) return error.TimeConversionFailed;

    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month_name = month_names[@intCast(tm_result.tm_mon)];

    // Cast the signed C int fields to unsigned so the `{d}` formatter does not
    // prefix a `+` sign (the fields are always non-negative for a valid date).
    return try std.fmt.allocPrint(
        allocator,
        "{s} {d:>2} {d:0>2}:{d:0>2}",
        .{
            month_name,
            @as(u32, @intCast(tm_result.tm_mday)),
            @as(u32, @intCast(tm_result.tm_hour)),
            @as(u32, @intCast(tm_result.tm_min)),
        },
    );
}

/// Format mtime for the Modified column.
/// Younger than 7 days: compact relative time ("15m", "3t", "6d"; t = timer).
/// Younger than 24h: additionally prefixed with "• " as a recency marker.
/// Older (or future mtimes, e.g. clock skew): absolute "Mon DD HH:MM" as before.
/// Result is right-padded with spaces to a visual width of 12 (the width of
/// the absolute format) so the name column stays aligned.
fn formatTimeRel(allocator: std.mem.Allocator, mtime: i128, now_secs: i64) ![]const u8 {
    const REL_WIDTH: usize = 12;
    const epoch_secs = @divFloor(mtime, std.time.ns_per_s);
    const age: i128 = @as(i128, @intCast(now_secs)) - epoch_secs;

    if (age >= 0 and age < 7 * 86400) {
        const body = if (age < 3600)
            try std.fmt.allocPrint(allocator, "{d}m", .{@divFloor(age, 60)})
        else if (age < 86400)
            try std.fmt.allocPrint(allocator, "{d}t", .{@divFloor(age, 3600)})
        else
            try std.fmt.allocPrint(allocator, "{d}d", .{@divFloor(age, 86400)});
        defer allocator.free(body);

        const core = if (age < 86400)
            try std.fmt.allocPrint(allocator, "• {s}", .{body})
        else
            try allocator.dupe(u8, body);
        defer allocator.free(core);

        const visual = visualLength(core);
        if (visual >= REL_WIDTH) return try allocator.dupe(u8, core);
        const padding = try allocator.alloc(u8, REL_WIDTH - visual);
        defer allocator.free(padding);
        @memset(padding, ' ');
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ core, padding });
    }

    return try formatTime(allocator, mtime);
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
    // Anomaly styling (Scenario B): broken symlink -> red name + " !" suffix;
    // 0-byte regular file -> dimmed name. Broken symlink wins over dim.
    const anomaly_color: []const u8 = if (file.anomalies.broken_symlink)
        colors.anomaly_broken
    else if (file.anomalies.empty_file)
        colors.dim
    else
        "";

    const color = if (!config.use_color)
        ""
    else if (anomaly_color.len > 0)
        anomaly_color
    else switch (file.kind) {
        .directory => colors.directory,
        .symlink => colors.symlink,
        .file => |f| if (f.executable) colors.executable else "",
    };

    const suffix = getFileTypeSuffix(file, config);
    const reset = if (color.len > 0) colors.reset else "";
    // The bang marker is printed in red when color is on so it stays visible
    // even when the rest of the line is styled; in plain output it is plain.
    if (file.anomalies.broken_symlink) {
        const bang_color = if (config.use_color) colors.anomaly_broken else "";
        const bang_reset = if (config.use_color) colors.reset else "";
        return try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s} !{s}", .{
            color,
            file.name,
            suffix,
            if (reset.len > 0) reset else "",
            bang_color,
            bang_reset,
        });
    }

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

/// Escape a string for inclusion inside a JSON double-quoted string.
/// Follows RFC 8259: quote, backslash and control characters must be escaped.
fn escapeJsonAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, s.len + 16);
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            '\x08' => try buf.appendSlice(allocator, "\\b"),
            '\x0c' => try buf.appendSlice(allocator, "\\f"),
            else => {
                if (ch < 0x20) {
                    var hex: [6]u8 = undefined;
                    const escaped = try std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{ch});
                    try buf.appendSlice(allocator, escaped);
                } else {
                    // Bytes >= 0x20 are copied verbatim. Multi-byte UTF-8
                    // sequences pass through unchanged, which is valid JSON.
                    try buf.append(allocator, ch);
                }
            },
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Print files in JSON format.
fn printJson(allocator: std.mem.Allocator, files: []const types.FileInfo, output: *UnifiedOutput) !void {
    try output.writeAll("[");
    var json_first = true;
    for (files) |file| {
        // The "." entry from -d is list bookkeeping, not a real entry.
        if (std.mem.eql(u8, file.name, ".") and file.kind == .directory) continue;
        if (!json_first) {
            try output.writeAll(",");
        }
        json_first = false;
        const escaped_name = try escapeJsonAlloc(allocator, file.name);
        defer allocator.free(escaped_name);
        try output.print(
            \\
            \\  {{"name":"{s}","size":{d},"mode":"{o:0>4}","git":"{c}","anomalies":[
        ,
            .{
                escaped_name,
                file.size,
                file.mode & 0o7777,
                @backingInt(file.git_status),
            },
        );
        var anomaly_first = true;
        const anomaly_names = [_][]const u8{ "broken_symlink", "empty_file", "exec_without_shebang" };
        const anomaly_flags = [_]bool{
            file.anomalies.broken_symlink,
            file.anomalies.empty_file,
            file.anomalies.exec_without_shebang,
        };
        for (anomaly_flags, anomaly_names) |flag, name| {
            if (!flag) continue;
            if (!anomaly_first) try output.writeAll(",");
            anomaly_first = false;
            try output.print("\"{s}\"", .{name});
        }
        try output.writeAll("]}");
    }
    try output.writeAll("\n]\n");
}

/// Print files in porcelain (machine-readable) format.
/// When nul_terminated is set, records end with NUL instead of LF so the
/// output can be piped to `xargs -0` even for filenames containing newlines.
fn printPorcelain(files: []const types.FileInfo, output: *UnifiedOutput, nul_terminated: bool) !void {
    const terminator: u8 = if (nul_terminated) 0 else '\n';
    for (files) |file| {
        if (std.mem.eql(u8, file.name, ".") and file.kind == .directory) continue;
        try output.print(
            "{o:0>4} {d} {c} {s}",
            .{
                file.mode & 0o7777,
                file.size,
                @backingInt(file.git_status),
                file.name,
            },
        );
        try output.writeByte(terminator);
    }
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

test "formatName - broken symlink is red with bang suffix" {
    const allocator = std.testing.allocator;

    var file = types.FileInfo{
        .name = "dangling",
        .mode = 0o777,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .symlink,
        .inode = 12345,
    };
    file.anomalies.broken_symlink = true;

    // No color: plain name + " !" suffix, no escape codes
    var config = types.Config.default();
    config.use_color = false;
    const plain = try formatName(allocator, file, config);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("dangling !", plain);

    // With color: red name and red bang
    config.use_color = true;
    const colored = try formatName(allocator, file, config);
    defer allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, colors.anomaly_broken) != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "dangling") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, " !") != null);
}

test "formatName - empty file is dimmed when color is on" {
    const allocator = std.testing.allocator;

    var file = types.FileInfo{
        .name = "empty.txt",
        .mode = 0o644,
        .size = 0,
        .mtime = 0,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .{ .file = .{ .executable = false } },
        .inode = 12345,
    };
    file.anomalies.empty_file = true;

    var config = types.Config.default();
    config.use_color = true;
    const colored = try formatName(allocator, file, config);
    defer allocator.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, colors.dim) != null);

    config.use_color = false;
    const plain = try formatName(allocator, file, config);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("empty.txt", plain);
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

// Pin the timezone to UTC so formatTime tests are deterministic regardless of
// the machine running them. formatTime now renders in local time via libc.
fn forceUtcTimezone() void {
    _ = setenv("TZ", "UTC", 1);
    tzset();
}

test "formatTime - epoch zero" {
    const allocator = std.testing.allocator;
    forceUtcTimezone();

    const str = try formatTime(allocator, 0);
    defer allocator.free(str);

    // Epoch 0 is 1970-01-01 00:00:00 UTC
    try std.testing.expectEqualStrings("Jan  1 00:00", str);
}

test "formatTime - known timestamp" {
    const allocator = std.testing.allocator;
    forceUtcTimezone();

    // 2024-03-15 14:30:00 UTC
    // This is approximately 1710513000 seconds since epoch
    const timestamp_ns: i128 = 1710513000 * std.time.ns_per_s;
    const str = try formatTime(allocator, timestamp_ns);
    defer allocator.free(str);

    // Should be Mar 15 14:30 in UTC
    try std.testing.expectEqualStrings("Mar 15 14:30", str);
}

test "formatTimeRel - minutes ago carries bullet marker" {
    const allocator = std.testing.allocator;
    forceUtcTimezone();

    const now: i64 = 1_800_000_000; // fixed point in time
    const mtime: i128 = @as(i128, now - 15 * 60) * std.time.ns_per_s;
    const str = try formatTimeRel(allocator, mtime, now);
    defer allocator.free(str);

    // "• 15m" left-aligned, padded to 12 visual columns
    try std.testing.expectEqualStrings("• 15m       ", str);
    try std.testing.expectEqual(@as(usize, 12), visualLength(str));
}

test "formatTimeRel - hours ago carries bullet marker" {
    const allocator = std.testing.allocator;
    forceUtcTimezone();

    const now: i64 = 1_800_000_000;
    const mtime: i128 = @as(i128, now - 3 * 3600) * std.time.ns_per_s;
    const str = try formatTimeRel(allocator, mtime, now);
    defer allocator.free(str);

    try std.testing.expectEqualStrings("• 3t        ", str);
    try std.testing.expectEqual(@as(usize, 12), visualLength(str));
}

test "formatTimeRel - days ago has no marker" {
    const allocator = std.testing.allocator;
    forceUtcTimezone();

    const now: i64 = 1_800_000_000;
    const mtime: i128 = @as(i128, now - 3 * 86400) * std.time.ns_per_s;
    const str = try formatTimeRel(allocator, mtime, now);
    defer allocator.free(str);

    try std.testing.expectEqualStrings("3d          ", str);
    try std.testing.expectEqual(@as(usize, 12), visualLength(str));
}

test "formatTimeRel - under a day boundary keeps hours, not days" {
    const allocator = std.testing.allocator;
    forceUtcTimezone();

    const now: i64 = 1_800_000_000;
    // 23h59m ago: still hours, with marker
    const mtime: i128 = @as(i128, now - (23 * 3600 + 59 * 60)) * std.time.ns_per_s;
    const str = try formatTimeRel(allocator, mtime, now);
    defer allocator.free(str);

    try std.testing.expectEqualStrings("• 23t       ", str);
}

test "formatTimeRel - 7 days or older falls back to absolute" {
    const allocator = std.testing.allocator;
    forceUtcTimezone();

    const now: i64 = 1_800_000_000;
    const mtime: i128 = @as(i128, now - 7 * 86400) * std.time.ns_per_s;
    const str = try formatTimeRel(allocator, mtime, now);
    defer allocator.free(str);

    // Falls back to the absolute format; exact date depends on tz, so just
    // check it is not a relative string.
    try std.testing.expect(std.mem.indexOf(u8, str, "•") == null);
    try std.testing.expectEqual(@as(usize, 12), str.len);
}

test "formatTimeRel - future mtime falls back to absolute" {
    const allocator = std.testing.allocator;
    forceUtcTimezone();

    const now: i64 = 1_800_000_000;
    const mtime: i128 = @as(i128, now + 3600) * std.time.ns_per_s;
    const str = try formatTimeRel(allocator, mtime, now);
    defer allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "•") == null);
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

test "UnifiedOutput - writer buffer points into the instance, not a dead stack frame" {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var output: UnifiedOutput = undefined;
    output.init(io);

    // The writer's buffer slice must refer to output.buffer, not to the
    // stack frame of init(). If init returned by value, the writer would
    // dangle after init returned.
    const writer_buf_ptr = @intFromPtr(output.writer.interface.buffer.ptr);
    const self_buf_ptr = @intFromPtr(&output.buffer);
    try std.testing.expectEqual(self_buf_ptr, writer_buf_ptr);
    try std.testing.expectEqual(@as(usize, STDOUT_BUFFER_SIZE), output.writer.interface.buffer.len);
}

test "escapeJsonAlloc - escapes quote, backslash and control chars" {
    const allocator = std.testing.allocator;

    const input = "quote\"back\\slash\nnewline\ttab\x01";
    const escaped = try escapeJsonAlloc(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("quote\\\"back\\\\slash\\nnewline\\ttab\\u0001", escaped);
}

test "escapeJsonAlloc - plain utf-8 passes through" {
    const allocator = std.testing.allocator;

    const input = "norsk: æøå ✓ 日本語";
    const escaped = try escapeJsonAlloc(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings(input, escaped);
}
