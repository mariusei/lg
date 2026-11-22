const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const git = @import("git.zig");

// Extern declarations for utf8proc (used instead of @cImport, which was
// removed in Zig 0.17). Only the three symbols we need.
const utf8proc_uint8_t = u8;
extern fn utf8proc_NFC(str: [*c]const utf8proc_uint8_t) callconv(.c) [*c]utf8proc_uint8_t;
extern fn free(ptr: [*c]utf8proc_uint8_t) callconv(.c) void;

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
    const a_nfc = utf8proc_NFC(a.ptr);
    if (a_nfc == null) return false;
    defer free(a_nfc);

    const b_nfc = utf8proc_NFC(b.ptr);
    if (b_nfc == null) {
        return false;
    }
    defer free(b_nfc);

    // Compare normalized strings
    // Both are null-terminated C strings
    const a_len = std.mem.len(a_nfc);
    const b_len = std.mem.len(b_nfc);

    if (a_len != b_len) return false;

    return std.mem.eql(u8, a_nfc[0..a_len], b_nfc[0..b_len]);
}

// ─── Platform-specific stat ─────────────────────────────────────────────
// Linux: raw statx syscall (glibc/musl both support it; std.c.Stat is void
//        on linux in Zig 0.17).
// macOS/other POSIX: libc fstatat — x86_64 needs the legacy $INODE64
//        symbol, so we declare our own.
// Windows: std.Io.Dir.statFile (GetFileInformationByHandle under the hood);
//        uid/gid don't exist there and mode is synthesized from the
//        readonly attribute and the file extension for executables.

extern "c" fn fstatat(dirfd: std.posix.fd_t, path: [*:0]const u8, buf: *std.c.Stat, flags: u32) c_int;
extern "c" fn @"fstatat$INODE64"(dirfd: std.posix.fd_t, path: [*:0]const u8, buf: *std.c.Stat, flags: u32) c_int;
const c_fstatat = if (builtin.os.tag == .macos and builtin.cpu.arch == .x86_64)
    @"fstatat$INODE64"
else
    fstatat;

fn cFstatat(dirfd: std.posix.fd_t, path: []const u8, flags: u32) !std.c.Stat {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    var stat_buf: std.c.Stat = undefined;
    const rc = c_fstatat(dirfd, path_z, &stat_buf, flags);
    if (rc != 0) {
        return switch (std.posix.errno(rc)) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTDIR => error.NotDir,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            else => error.StatFailed,
        };
    }
    return stat_buf;
}

/// Normalized per-entry metadata, filled by statEntry on every platform.
const StatInfo = struct {
    mode: u32,
    uid: u32,
    gid: u32,
    ino: u64,
    size: u64,
    mtime_ns: i128,
    executable: bool,
};

fn linuxStatEntry(dirfd: std.posix.fd_t, name: []const u8, follow: bool) !StatInfo {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (name.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..name.len], name);
    path_buf[name.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    var stx: std.os.linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else std.os.linux.AT.SYMLINK_NOFOLLOW;
    const rc = std.os.linux.statx(@intCast(dirfd), path_z, flags, std.os.linux.STATX.BASIC_STATS, &stx);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .ACCES => return error.AccessDenied,
        .NOTDIR => return error.NotDir,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        else => return error.StatFailed,
    }
    return .{
        .mode = stx.mode,
        .uid = stx.uid,
        .gid = stx.gid,
        .ino = stx.ino,
        .size = stx.size,
        .mtime_ns = @as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec,
        .executable = (stx.mode & 0o111) != 0,
    };
}

fn statEntry(io: std.Io, dir: std.Io.Dir, name: []const u8, follow: bool) !StatInfo {
    if (comptime builtin.os.tag == .windows) {
        const st = try dir.statFile(io, name, .{ .follow_symlinks = follow });
        const is_exec = st.kind == .file and hasExecutableExtension(name);
        const readonly = (@as(u32, @intFromEnum(st.permissions)) & 1) != 0; // FILE_ATTRIBUTE_READONLY
        var mode: u32 = if (st.kind == .directory) 0o755 else if (readonly) 0o444 else 0o666;
        if (is_exec) mode |= 0o111;
        return .{
            .mode = mode,
            .uid = 0,
            .gid = 0,
            .ino = @intCast(st.inode),
            .size = st.size,
            .mtime_ns = @intCast(st.mtime.nanoseconds),
            .executable = is_exec,
        };
    } else if (comptime builtin.os.tag == .linux) {
        return linuxStatEntry(dir.handle, name, follow);
    } else {
        const st = try cFstatat(dir.handle, name, if (follow) 0 else std.posix.AT.SYMLINK_NOFOLLOW);
        const mtime_ts = st.mtime();
        return .{
            .mode = @intCast(st.mode),
            .uid = @intCast(st.uid),
            .gid = @intCast(st.gid),
            .ino = @intCast(st.ino),
            .size = if (st.size < 0) 0 else @min(@as(u64, @intCast(st.size)), std.math.maxInt(u64)),
            .mtime_ns = @as(i128, mtime_ts.sec) * std.time.ns_per_s + mtime_ts.nsec,
            .executable = (st.mode & 0o111) != 0,
        };
    }
}

fn hasExecutableExtension(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    const execs = [_][]const u8{ ".exe", ".com", ".bat", ".cmd", ".ps1" };
    for (execs) |e| {
        if (ext.len == e.len and std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// Check whether a regular file starts with "#!".
/// Returns true on any read failure: we only flag files we positively
/// inspected, to avoid false positives on unreadable executables.
fn hasShebang(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    const file = dir.openFile(io, name, .{}) catch return true;
    defer file.close(io);
    var buf: [2]u8 = undefined;
    const n = file.readStreaming(io, &.{&buf}) catch return true;
    if (n < 2) return false;
    return buf[0] == '#' and buf[1] == '!';
}

/// List files in directory based on config.
/// Returns owned slice of FileInfo - caller must free each FileInfo.name and the slice itself.
pub fn listFiles(
    io: std.Io,
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

    // Open directory
    var dir = try std.Io.Dir.cwd().openDir(io, config.dir_path, .{ .iterate = true });
    defer dir.close(io);

    // Add current directory entry when -d is used (like C version)
    if (config.calc_dir_sizes) {
        const root_stat = statEntry(io, dir, ".", false) catch |err| {
            std.debug.print("Error: couldn't stat directory '{s}': {}\n", .{ config.dir_path, err });
            return err;
        };

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, "."),
            .mode = root_stat.mode,
            .size = 0, // filled in later by calculateDirSizes
            .mtime = root_stat.mtime_ns,
            .uid = root_stat.uid,
            .gid = root_stat.gid,
            .git_status = .clean, // Current dir doesn't have git status
            .kind = .directory,
            .inode = root_stat.ino,
        });
    }

    // Iterate entries
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
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

        // Get file metadata (symlinks not followed: prevents symlink loop attacks)
        const st = statEntry(io, dir, entry.name, false) catch |err| {
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
            .file => .{ .file = .{ .executable = st.executable } },
            else => continue, // Skip special files (device, named_pipe, etc.)
        };

        // Anomaly detection (Scenario B). Costs at most one extra stat per
        // symlink and a 2-byte read per executable; nothing else.
        var anomalies = types.Anomaly{};
        switch (kind) {
            .symlink => {
                // The stat above did not follow the link; follow it now to
                // detect dangling targets.
                _ = statEntry(io, dir, entry.name, true) catch {
                    anomalies.broken_symlink = true;
                };
            },
            .file => |f| {
                if (st.size == 0) anomalies.empty_file = true;
                if (f.executable and !hasShebang(io, dir, entry.name)) {
                    anomalies.exec_without_shebang = true;
                }
            },
            .directory => {},
        }

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .mode = st.mode,
            .size = st.size,
            .mtime = st.mtime_ns,
            .uid = st.uid,
            .gid = st.gid,
            .git_status = git_status,
            .kind = kind,
            .inode = st.ino,
            .anomalies = anomalies,
        });
    }

    // Calculate directory sizes if requested
    if (config.calc_dir_sizes) {
        try calculateDirSizes(io, allocator, config.dir_path, list.items);
    }

    return list.toOwnedSlice(allocator);
}

/// Calculate directory sizes natively (no external `du`).
/// Sums the logical size of regular files; symlinks are not followed.
fn calculateDirSizes(
    io: std.Io,
    allocator: std.mem.Allocator,
    base_path: []const u8,
    files: []types.FileInfo,
) !void {
    for (files) |*file| {
        if (file.kind != .directory) continue;

        const full_path = if (std.mem.eql(u8, file.name, "."))
            try allocator.dupe(u8, base_path)
        else
            try std.fs.path.join(allocator, &.{ base_path, file.name });
        defer allocator.free(full_path);

        var dir = std.Io.Dir.cwd().openDir(io, full_path, .{ .iterate = true }) catch |err| {
            std.debug.print("Warning: couldn't open {s} for size calculation: {}\n", .{ full_path, err });
            continue;
        };
        defer dir.close(io);
        file.size = dirSizeWalk(io, dir);
    }
}

/// Recursively sum the size of regular files under `dir`.
fn dirSizeWalk(io: std.Io, dir: std.Io.Dir) u64 {
    var total: u64 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                total += dirSizeWalk(io, sub);
            },
            .file => {
                const st = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
                total += st.size;
            },
            else => {},
        }
    }
    return total;
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
