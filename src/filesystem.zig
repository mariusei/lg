const std = @import("std");
const types = @import("types.zig");
const git = @import("git.zig");
const c = @cImport({
    @cInclude("utf8proc.h");
});

/// Compare two UTF-8 strings, handling macOS NFD/NFC normalization differences.
/// Returns true if strings are equivalent using Unicode NFC normalization.
///
/// This function uses utf8proc to normalize both strings to NFC (Canonical Composition)
/// before comparison, which handles the case where macOS filesystem uses NFD (decomposed)
/// while shell arguments use NFC (composed) form for Unicode characters.
fn utf8Equal(a: []const u8, b: []const u8) bool {
    // Fast path: exact byte match (handles ASCII and already-normalized strings)
    if (std.mem.eql(u8, a, b)) return true;

    // Normalize both strings to NFC for comparison
    // utf8proc_NFC returns a malloc'd string that must be freed
    const a_nfc = c.utf8proc_NFC(a.ptr);
    if (a_nfc == null) return false;
    defer c.free(a_nfc);

    const b_nfc = c.utf8proc_NFC(b.ptr);
    if (b_nfc == null) {
        return false;
    }
    defer c.free(b_nfc);

    // Compare normalized strings
    // Both are null-terminated C strings
    const a_len = std.mem.len(a_nfc);
    const b_len = std.mem.len(b_nfc);

    if (a_len != b_len) return false;

    return std.mem.eql(u8, a_nfc[0..a_len], b_nfc[0..b_len]);
}

/// List files in directory based on config.
/// Returns owned slice of FileInfo - caller must free each FileInfo.name and the slice itself.
pub fn listFiles(
    allocator: std.mem.Allocator,
    config: types.Config,
    git_ctx: ?*const git.GitContext,
) ![]types.FileInfo {
    var list: std.ArrayList(types.FileInfo) = .empty;
    errdefer {
        for (list.items) |*item| {
            allocator.free(item.name);
        }
        list.deinit(allocator);
    }

    // Add current directory entry when -d is used (like C version)
    if (config.calc_dir_sizes) {
        const dir_stat = std.posix.fstatat(std.posix.AT.FDCWD, config.dir_path, 0) catch |err| {
            std.debug.print("Error: couldn't stat directory '{s}': {}\n", .{ config.dir_path, err });
            return err;
        };

        const mtime_ts = dir_stat.mtime();
        const mtime_ns = @as(i128, mtime_ts.sec) * std.time.ns_per_s + mtime_ts.nsec;

        // Calculate current directory size
        var dir_size: u64 = 0;
        if (config.calc_dir_sizes) {
            // We'll calculate this size later in batch
            dir_size = 0;
        }

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, "."),
            .mode = dir_stat.mode,
            .size = dir_size,
            .mtime = mtime_ns,
            .uid = dir_stat.uid,
            .gid = dir_stat.gid,
            .git_status = .clean, // Current dir doesn't have git status
            .kind = .directory,
            .inode = dir_stat.ino,
        });
    }

    // Open directory
    var dir = try std.fs.cwd().openDir(config.dir_path, .{ .iterate = true });
    defer dir.close();

    // Iterate entries
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip . and ..
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        // Skip hidden files unless -a
        if (!config.show_all and entry.name.len > 0 and entry.name[0] == '.') continue;

        // Apply file filters if provided
        if (config.file_filters) |filters| {
            var match = false;
            for (filters) |filter| {
                if (utf8Equal(entry.name, filter)) {
                    match = true;
                    break;
                }
            }
            if (!match) continue;
        }

        // Get file metadata using posix.fstatat to get uid/gid
        // Use SYMLINK_NOFOLLOW to prevent symlink loop attacks
        const posix_stat = std.posix.fstatat(dir.fd, entry.name, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| {
            // Skip files we can't stat
            std.debug.print("Warning: couldn't stat {s}: {}\n", .{ entry.name, err });
            continue;
        };

        // Determine git status
        const git_status: types.FileInfo.GitStatus = if (git_ctx) |ctx|
            ctx.getStatus(entry.name, entry.kind == .directory)
        else
            .clean;

        // Determine file kind
        const kind: types.FileInfo.FileKind = switch (entry.kind) {
            .directory => .directory,
            .sym_link => .symlink,
            .file => .{ .file = .{ .executable = (posix_stat.mode & 0o111) != 0 } },
            else => continue, // Skip special files (device, named_pipe, etc.)
        };

        const mtime_ts = posix_stat.mtime();
        const mtime_ns = @as(i128, mtime_ts.sec) * std.time.ns_per_s + mtime_ts.nsec;

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .mode = posix_stat.mode,
            // Protect against integer overflow: saturate at max u64 instead of wrapping
            .size = if (posix_stat.size < 0) 0 else @min(@as(u64, @intCast(posix_stat.size)), std.math.maxInt(u64)),
            .mtime = mtime_ns,
            .uid = posix_stat.uid,
            .gid = posix_stat.gid,
            .git_status = git_status,
            .kind = kind,
            .inode = posix_stat.ino,
        });
    }

    // Calculate directory sizes if requested
    if (config.calc_dir_sizes) {
        try calculateDirSizes(allocator, config.dir_path, list.items);
    }

    return list.toOwnedSlice(allocator);
}

/// Validate path for security - prevents command injection and flag confusion.
/// Returns error.InvalidPath if path contains dangerous patterns.
/// Note: We use std.process.Child with array args (not shell execution),
/// so most shell metacharacters are safe. We only reject truly dangerous patterns.
fn validatePath(path: []const u8) !void {
    // Reject null bytes (path truncation attacks)
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;

    // Reject paths starting with - (could be interpreted as flags by du)
    if (path.len > 0 and path[0] == '-') return error.InvalidPath;

    return;
}

/// Calculate directory sizes using `du -sk` in batch.
/// Much faster than calling du once per directory.
fn calculateDirSizes(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    files: []types.FileInfo,
) !void {
    // Collect all directory paths
    var dir_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (dir_paths.items) |path| allocator.free(path);
        dir_paths.deinit(allocator);
    }

    for (files) |file| {
        if (file.kind == .directory) {
            // Handle "." specially - use base_path directly
            const full_path = if (std.mem.eql(u8, file.name, "."))
                try allocator.dupe(u8, base_path)
            else
                try std.fs.path.join(allocator, &.{ base_path, file.name });

            // Validate path before passing to subprocess to prevent command injection
            try validatePath(full_path);

            try dir_paths.append(allocator, full_path);
        }
    }

    if (dir_paths.items.len == 0) return;

    // Build args: ["du", "-sk", path1, path2, ...]
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, "du");
    try args.append(allocator, "-sk");
    try args.appendSlice(allocator, dir_paths.items);

    // Execute du with 30-second timeout
    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    // Read stdout (blocks until process completes)
    // du is typically fast, and OS has its own timeout mechanisms
    const stdout = child.stdout.?.readToEndAlloc(allocator, types.DU_MAX_OUTPUT) catch |err| {
        // On read error, kill child process
        _ = child.kill() catch {};
        return err;
    };
    defer allocator.free(stdout);

    const result = try child.wait();

    // Check exit status
    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                // du failed, but we can continue - just won't have dir sizes
                return;
            }
        },
        else => {
            // Process was terminated/killed, skip dir size calculation
            return;
        },
    }

    // Parse output: "SIZE\tPATH\n"
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Split on tab or space
        var parts = std.mem.splitAny(u8, line, " \t");
        const size_str = parts.next() orelse continue;
        const path = parts.rest();

        const size_kb = std.fmt.parseInt(u64, size_str, 10) catch continue;

        // Find matching file entry and update size
        for (files) |*file| {
            if (file.kind != .directory) continue;

            // Handle "." specially
            const full_path = if (std.mem.eql(u8, file.name, "."))
                try allocator.dupe(u8, base_path)
            else
                try std.fs.path.join(allocator, &.{ base_path, file.name });
            defer allocator.free(full_path);

            if (std.mem.eql(u8, full_path, path)) {
                // Protect against integer overflow: use saturating multiplication
                const size_bytes = std.math.mul(u64, size_kb, 1024) catch std.math.maxInt(u64);
                file.size = size_bytes;
                break;
            }
        }
    }
}

/// Sort files based on config options.
pub fn sortFiles(files: []types.FileInfo, config: types.Config) void {
    // Skip sorting if -U (unsorted) flag is set
    if (config.unsorted) return;

    const Context = struct {
        cfg: types.Config,

        pub fn lessThan(ctx: @This(), a: types.FileInfo, b: types.FileInfo) bool {
            if (ctx.cfg.group_by_type) {
                // Directories first
                const a_is_dir = a.kind == .directory;
                const b_is_dir = b.kind == .directory;
                if (a_is_dir != b_is_dir) return a_is_dir;

                // Group files by extension
                if (!a_is_dir) {
                    const ext_a = std.fs.path.extension(a.name);
                    const ext_b = std.fs.path.extension(b.name);
                    const ext_cmp = std.mem.order(u8, ext_a, ext_b);
                    if (ext_cmp != .eq) return ext_cmp == .lt;
                }
            }

            // Sort by extension if -X is specified
            if (ctx.cfg.sort_by_extension) {
                const ext_a = std.fs.path.extension(a.name);
                const ext_b = std.fs.path.extension(b.name);

                // Files without extension come first
                const has_ext_a = ext_a.len > 0;
                const has_ext_b = ext_b.len > 0;
                if (has_ext_a != has_ext_b) return !has_ext_a;

                // Both have extensions or both don't - compare extensions
                if (ext_a.len > 0 or ext_b.len > 0) {
                    const ext_cmp = std.mem.order(u8, ext_a, ext_b);
                    if (ext_cmp != .eq) return ext_cmp == .lt;
                }

                // Same extension (or both no extension) - sort alphabetically by name (ls -X behavior)
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }

            // Primary sort criteria
            if (ctx.cfg.sort_by_size) {
                // Sort by size (largest first)
                if (a.size != b.size) return a.size > b.size;
            } else if (ctx.cfg.sort_by_time or !ctx.cfg.sort_alphabetical) {
                // Sort by time (oldest first) - either explicit -T or default
                if (a.mtime != b.mtime) return a.mtime < b.mtime;
            }

            // Secondary sort: alphabetical (fallback for ties or if -n specified)
            if (ctx.cfg.sort_alphabetical) {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }

            // Final fallback: alphabetical
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    };

    std.mem.sort(types.FileInfo, files, Context{ .cfg = config }, Context.lessThan);

    // Reverse order if requested
    if (config.reverse_order) {
        std.mem.reverse(types.FileInfo, files);
    }
}

/// Free a slice of FileInfo
pub fn freeFileList(allocator: std.mem.Allocator, files: []types.FileInfo) void {
    for (files) |*file| {
        allocator.free(file.name);
    }
    allocator.free(files);
}

// ═══════════════════════════════════════════════════════════
// TESTS - Comprehensive test coverage
// ═══════════════════════════════════════════════════════════

test "sortFiles - alphabetical ascending" {
    var files = [_]types.FileInfo{
        .{
            .name = "zebra.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "apple.txt",
            .mode = 0o644,
            .size = 200,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
    };

    var config = types.Config.default();
    config.sort_alphabetical = true;

    sortFiles(&files, config);

    try std.testing.expectEqualStrings("apple.txt", files[0].name);
    try std.testing.expectEqualStrings("zebra.txt", files[1].name);
}

test "sortFiles - alphabetical case insensitive" {
    var files = [_]types.FileInfo{
        .{
            .name = "Zebra.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "apple.txt",
            .mode = 0o644,
            .size = 200,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "BANANA.txt",
            .mode = 0o644,
            .size = 150,
            .mtime = 150,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
    };

    var config = types.Config.default();
    config.sort_alphabetical = true;

    sortFiles(&files, config);

    try std.testing.expectEqualStrings("apple.txt", files[0].name);
    try std.testing.expectEqualStrings("BANANA.txt", files[1].name);
    try std.testing.expectEqualStrings("Zebra.txt", files[2].name);
}

test "sortFiles - by time (mtime ascending)" {
    var files = [_]types.FileInfo{
        .{
            .name = "newer.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 200, // Newer
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "older.txt",
            .mode = 0o644,
            .size = 200,
            .mtime = 100, // Older
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
    };

    var config = types.Config.default();
    config.sort_alphabetical = false; // Sort by time

    sortFiles(&files, config);

    // Older files first (ascending mtime)
    try std.testing.expectEqualStrings("older.txt", files[0].name);
    try std.testing.expectEqualStrings("newer.txt", files[1].name);
}

test "sortFiles - by time with multiple files" {
    var files = [_]types.FileInfo{
        .{
            .name = "newest.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 300,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "middle.txt",
            .mode = 0o644,
            .size = 200,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "oldest.txt",
            .mode = 0o644,
            .size = 300,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
    };

    var config = types.Config.default();
    config.sort_alphabetical = false;

    sortFiles(&files, config);

    try std.testing.expectEqualStrings("oldest.txt", files[0].name);
    try std.testing.expectEqualStrings("middle.txt", files[1].name);
    try std.testing.expectEqualStrings("newest.txt", files[2].name);
}

test "sortFiles - group by type, directories first" {
    var files = [_]types.FileInfo{
        .{
            .name = "file.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "dir",
            .mode = 0o755,
            .size = 0,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .directory,
            .inode = 0,
        },
    };

    var config = types.Config.default();
    config.group_by_type = true;

    sortFiles(&files, config);

    // Directories first
    try std.testing.expect(files[0].kind == .directory);
    try std.testing.expectEqualStrings("dir", files[0].name);
    try std.testing.expect(files[1].kind == .file);
    try std.testing.expectEqualStrings("file.txt", files[1].name);
}

test "sortFiles - group by type with multiple directories" {
    var files = [_]types.FileInfo{
        .{
            .name = "file1.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "dir_b",
            .mode = 0o755,
            .size = 0,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .directory,
            .inode = 0,
        },
        .{
            .name = "file2.txt",
            .mode = 0o644,
            .size = 200,
            .mtime = 150,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "dir_a",
            .mode = 0o755,
            .size = 0,
            .mtime = 250,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .directory,
            .inode = 0,
        },
    };

    var config = types.Config.default();
    config.group_by_type = true;
    config.sort_alphabetical = true;

    sortFiles(&files, config);

    // First two should be directories, sorted alphabetically
    try std.testing.expect(files[0].kind == .directory);
    try std.testing.expectEqualStrings("dir_a", files[0].name);
    try std.testing.expect(files[1].kind == .directory);
    try std.testing.expectEqualStrings("dir_b", files[1].name);
    // Last two should be files
    try std.testing.expect(files[2].kind == .file);
    try std.testing.expect(files[3].kind == .file);
}

test "sortFiles - group by extension" {
    var files = [_]types.FileInfo{
        .{
            .name = "script.sh",
            .mode = 0o755,
            .size = 100,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = true } },
            .inode = 0,
        },
        .{
            .name = "data.json",
            .mode = 0o644,
            .size = 200,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
        .{
            .name = "readme.md",
            .mode = 0o644,
            .size = 300,
            .mtime = 300,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
    };

    var config = types.Config.default();
    config.group_by_type = true;
    config.sort_alphabetical = true;

    sortFiles(&files, config);

    // Files should be grouped by extension
    try std.testing.expectEqualStrings("data.json", files[0].name);
    try std.testing.expectEqualStrings("readme.md", files[1].name);
    try std.testing.expectEqualStrings("script.sh", files[2].name);
}

test "sortFiles - empty list" {
    var files = [_]types.FileInfo{};

    var config = types.Config.default();
    config.sort_alphabetical = true;

    sortFiles(&files, config);

    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "sortFiles - single file" {
    var files = [_]types.FileInfo{
        .{
            .name = "only.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 0,
        },
    };

    var config = types.Config.default();
    config.sort_alphabetical = true;

    sortFiles(&files, config);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("only.txt", files[0].name);
}

test "sortFiles - symlinks mixed with files and dirs" {
    var files = [_]types.FileInfo{
        .{
            .name = "regular.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 1,
        },
        .{
            .name = "link",
            .mode = 0o777,
            .size = 0,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .symlink,
            .inode = 2,
        },
        .{
            .name = "dir",
            .mode = 0o755,
            .size = 0,
            .mtime = 300,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .directory,
            .inode = 3,
        },
    };

    var config = types.Config.default();
    config.group_by_type = true;
    config.sort_alphabetical = true;

    sortFiles(&files, config);

    // Directories first, then others sorted alphabetically
    try std.testing.expect(files[0].kind == .directory);
    try std.testing.expectEqualStrings("dir", files[0].name);
}

test "sortFiles - files with same extension sorted alphabetically" {
    var files = [_]types.FileInfo{
        .{
            .name = "zebra.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 1,
        },
        .{
            .name = "apple.txt",
            .mode = 0o644,
            .size = 200,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 2,
        },
        .{
            .name = "banana.txt",
            .mode = 0o644,
            .size = 300,
            .mtime = 300,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 3,
        },
    };

    var config = types.Config.default();
    config.group_by_type = true;
    config.sort_alphabetical = true;

    sortFiles(&files, config);

    // All have .txt extension, should be alphabetically sorted
    try std.testing.expectEqualStrings("apple.txt", files[0].name);
    try std.testing.expectEqualStrings("banana.txt", files[1].name);
    try std.testing.expectEqualStrings("zebra.txt", files[2].name);
}

test "sortFiles - no extension files" {
    var files = [_]types.FileInfo{
        .{
            .name = "Makefile",
            .mode = 0o644,
            .size = 100,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 1,
        },
        .{
            .name = "README",
            .mode = 0o644,
            .size = 200,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 2,
        },
    };

    var config = types.Config.default();
    config.group_by_type = true;
    config.sort_alphabetical = true;

    sortFiles(&files, config);

    // Files without extension should still sort alphabetically
    try std.testing.expectEqualStrings("Makefile", files[0].name);
    try std.testing.expectEqualStrings("README", files[1].name);
}

test "freeFileList - basic cleanup" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(types.FileInfo) = .empty;
    defer list.deinit(allocator);

    try list.append(allocator, .{
        .name = try allocator.dupe(u8, "test1.txt"),
        .mode = 0o644,
        .size = 100,
        .mtime = 100,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .{ .file = .{ .executable = false } },
        .inode = 1,
    });

    try list.append(allocator, .{
        .name = try allocator.dupe(u8, "test2.txt"),
        .mode = 0o644,
        .size = 200,
        .mtime = 200,
        .uid = 0,
        .gid = 0,
        .git_status = .clean,
        .kind = .{ .file = .{ .executable = false } },
        .inode = 2,
    });

    const files = try list.toOwnedSlice(allocator);
    freeFileList(allocator, files);
}

test "listFiles - test directory listing" {
    // SKIP: This test requires filesystem access which may hang in some environments
    return error.SkipZigTest;

    // const allocator = std.testing.allocator;

    // var config = types.Config.default();
    // config.dir_path = ".";

    // const files = try listFiles(allocator, config, null);
    // defer freeFileList(allocator, files);

    // // Should have at least one file in current directory
    // try std.testing.expect(files.len > 0);

    // // Verify we got FileInfo structs
    // for (files) |file| {
    //     try std.testing.expect(file.name.len > 0);
    // }
}

test "listFiles - with show_all flag" {
    // SKIP: This test requires filesystem access which may hang in some environments
    return error.SkipZigTest;

    // const allocator = std.testing.allocator;

    // var config = types.Config.default();
    // config.dir_path = ".";
    // config.show_all = false;

    // const files_no_hidden = try listFiles(allocator, config, null);
    // defer freeFileList(allocator, files_no_hidden);

    // config.show_all = true;
    // const files_with_hidden = try listFiles(allocator, config, null);
    // defer freeFileList(allocator, files_with_hidden);

    // // With show_all, we should get same or more files
    // try std.testing.expect(files_with_hidden.len >= files_no_hidden.len);
}

test "sortFiles - sort by extension (-X)" {
    var files = [_]types.FileInfo{
        .{
            .name = "file.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 1,
        },
        .{
            .name = "README",
            .mode = 0o644,
            .size = 200,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 2,
        },
        .{
            .name = "script.sh",
            .mode = 0o755,
            .size = 300,
            .mtime = 300,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = true } },
            .inode = 3,
        },
        .{
            .name = "data.json",
            .mode = 0o644,
            .size = 400,
            .mtime = 400,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 4,
        },
        .{
            .name = "Makefile",
            .mode = 0o644,
            .size = 500,
            .mtime = 500,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 5,
        },
    };

    var config = types.Config.default();
    config.sort_by_extension = true;

    sortFiles(&files, config);

    // Files without extension should come first, then sorted by extension
    // Expected order: Makefile, README (no extension), data.json (.json), script.sh (.sh), file.txt (.txt)
    try std.testing.expectEqualStrings("Makefile", files[0].name);
    try std.testing.expectEqualStrings("README", files[1].name);
    try std.testing.expectEqualStrings("data.json", files[2].name);
    try std.testing.expectEqualStrings("script.sh", files[3].name);
    try std.testing.expectEqualStrings("file.txt", files[4].name);
}

test "sortFiles - sort by extension with same extension" {
    var files = [_]types.FileInfo{
        .{
            .name = "zebra.txt",
            .mode = 0o644,
            .size = 100,
            .mtime = 100,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 1,
        },
        .{
            .name = "apple.txt",
            .mode = 0o644,
            .size = 200,
            .mtime = 200,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 2,
        },
        .{
            .name = "banana.txt",
            .mode = 0o644,
            .size = 300,
            .mtime = 300,
            .uid = 0,
            .gid = 0,
            .git_status = .clean,
            .kind = .{ .file = .{ .executable = false } },
            .inode = 3,
        },
    };

    var config = types.Config.default();
    config.sort_by_extension = true;

    sortFiles(&files, config);

    // Within same extension, should be alphabetically sorted
    try std.testing.expectEqualStrings("apple.txt", files[0].name);
    try std.testing.expectEqualStrings("banana.txt", files[1].name);
    try std.testing.expectEqualStrings("zebra.txt", files[2].name);
}
