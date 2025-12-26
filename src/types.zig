//! Core type definitions for zig-lg.
//!
//! Config: User preferences from CLI (flags, paths, output format)
//! FileInfo: Per-file metadata + git status + file kind
//! GitStatus: Enum with priority system (unstaged > staged > untracked > clean)
//! FileKind: Union enum distinguishing dirs, symlinks, executable vs regular files

const std = @import("std");

// ═══════════════════════════════════════════════════════════
// Buffer Size Constants
// ═══════════════════════════════════════════════════════════

/// Buffer size for stdout buffering (legend, branch info, etc.)
pub const STDOUT_BUFFER_SIZE = 512;

/// Max output size for git status command (1MB should be sufficient)
pub const GIT_STATUS_MAX_OUTPUT = 1024 * 1024;

/// Max output size for du command (10MB for large directory trees)
pub const DU_MAX_OUTPUT = 10 * 1024 * 1024;

pub const DetailLevel = enum {
    minimal,
    standard,
    full,
};

pub const OutputFormat = enum {
    normal,
    json,
    porcelain,
};

pub const Config = struct {
    dir_path: []const u8,
    detail_level: DetailLevel,
    output_format: OutputFormat,
    show_all: bool,              // -a: Include hidden files (starting with .)
    sort_alphabetical: bool,
    show_branch: bool,
    show_legend: bool,
    calc_dir_sizes: bool,        // -d: Run du -sk (slow on large dirs!)
    group_by_type: bool,         // -t: Group dirs first, then by extension (adds blank lines)
    file_filters: ?[]const []const u8,
    // Phase 1 flags
    reverse_order: bool,
    sort_by_size: bool,
    show_inodes: bool,
    sort_by_time: bool,
    // Phase 2 flags (Step 1)
    file_type_indicators: bool,  // -F
    append_dir_slash: bool,      // -p
    one_column: bool,            // -1
    unsorted: bool,              // -U
    // Phase 2 flags (Step 2)
    omit_group: bool,            // -o
    omit_owner: bool,            // -g
    sort_by_extension: bool,     // -X: Sort by file extension (like ls -X)

    pub fn default() Config {
        return .{
            .dir_path = ".",
            .detail_level = .minimal,
            .output_format = .normal,
            .show_all = false,
            .sort_alphabetical = false,
            .show_branch = false,
            .show_legend = false,
            .calc_dir_sizes = false,
            .group_by_type = false,
            .file_filters = null,
            .reverse_order = false,
            .sort_by_size = false,
            .show_inodes = false,
            .sort_by_time = false,
            .file_type_indicators = false,
            .append_dir_slash = false,
            .one_column = false,
            .unsorted = false,
            .omit_group = false,
            .omit_owner = false,
            .sort_by_extension = false,
        };
    }
};

pub const FileInfo = struct {
    name: []const u8,
    mode: std.posix.mode_t,
    size: u64,
    mtime: i128,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
    git_status: GitStatus,
    kind: FileKind,
    inode: u64,

    // FileKind: Tagged union for file type discrimination
    // - file: Regular file (may or may not be executable)
    // - directory: Directory entry
    // - symlink: Symbolic link
    pub const FileKind = union(enum) {
        file: struct { executable: bool },
        directory,
        symlink,
    };

    // GitStatus priority system (for conflict resolution):
    // 1. Unstaged changes (most urgent - uncommitted work)
    // 2. Staged changes (ready to commit)
    // 3. Untracked files (not yet added)
    // 4. Clean (no changes)
    // Discriminant values map to git status short format characters
    pub const GitStatus = enum(u8) {
        clean = ' ',
        staged_modified = 'M',
        unstaged_modified = 'm',
        staged_added = 'A',
        unstaged_added = 'a',
        staged_deleted = 'D',
        unstaged_deleted = 'd',
        staged_renamed = 'R',
        unstaged_renamed = 'r',
        staged_copied = 'C',
        unstaged_copied = 'c',
        untracked = '?',
        ignored = '!',

        pub fn symbol(self: GitStatus) []const u8 {
            return switch (self) {
                .staged_modified, .staged_added, .staged_deleted, .staged_renamed, .staged_copied => " ●",
                .unstaged_modified, .unstaged_added, .unstaged_deleted, .unstaged_renamed, .unstaged_copied => " ○",
                .untracked => " ?",
                .ignored => " !",
                .clean => " ·",
            };
        }

        pub fn colorName(self: GitStatus) []const u8 {
            // Return color name that will be looked up in colors.zig
            return switch (self) {
                .staged_modified => "git_staged_modified",
                .unstaged_modified => "git_unstaged_modified",
                .staged_added => "git_staged_added",
                .unstaged_added => "git_unstaged_added",
                .staged_deleted => "git_staged_deleted",
                .unstaged_deleted => "git_unstaged_deleted",
                .staged_renamed => "git_staged_renamed",
                .unstaged_renamed => "git_unstaged_renamed",
                .staged_copied => "git_staged_copied",
                .unstaged_copied => "git_unstaged_copied",
                .untracked => "git_untracked",
                .ignored => "git_ignored",
                .clean => "git_clean",
            };
        }
    };
};

// ═══════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════

test "Config.default creates valid config" {
    const config = Config.default();
    try std.testing.expectEqualStrings(".", config.dir_path);
    try std.testing.expectEqual(DetailLevel.minimal, config.detail_level);
    try std.testing.expect(config.file_filters == null);
}

test "Config.default has expected defaults" {
    const config = Config.default();
    try std.testing.expectEqual(OutputFormat.normal, config.output_format);
    try std.testing.expectEqual(false, config.show_all);
    try std.testing.expectEqual(false, config.sort_alphabetical);
    try std.testing.expectEqual(false, config.show_branch);
    try std.testing.expectEqual(false, config.show_legend);
    try std.testing.expectEqual(false, config.calc_dir_sizes);
    try std.testing.expectEqual(false, config.group_by_type);
}

test "DetailLevel enum has three variants" {
    try std.testing.expectEqual(DetailLevel.minimal, .minimal);
    try std.testing.expectEqual(DetailLevel.standard, .standard);
    try std.testing.expectEqual(DetailLevel.full, .full);
}

test "OutputFormat enum has three variants" {
    try std.testing.expectEqual(OutputFormat.normal, .normal);
    try std.testing.expectEqual(OutputFormat.json, .json);
    try std.testing.expectEqual(OutputFormat.porcelain, .porcelain);
}

test "GitStatus.symbol returns correct symbols" {
    try std.testing.expectEqualStrings(" ●", FileInfo.GitStatus.staged_modified.symbol());
    try std.testing.expectEqualStrings(" ○", FileInfo.GitStatus.unstaged_modified.symbol());
    try std.testing.expectEqualStrings(" ?", FileInfo.GitStatus.untracked.symbol());
    try std.testing.expectEqualStrings(" ·", FileInfo.GitStatus.clean.symbol());
}

test "GitStatus.symbol staged vs unstaged distinction" {
    // All staged statuses should have solid dot
    try std.testing.expectEqualStrings(" ●", FileInfo.GitStatus.staged_added.symbol());
    try std.testing.expectEqualStrings(" ●", FileInfo.GitStatus.staged_deleted.symbol());
    try std.testing.expectEqualStrings(" ●", FileInfo.GitStatus.staged_renamed.symbol());
    try std.testing.expectEqualStrings(" ●", FileInfo.GitStatus.staged_copied.symbol());

    // All unstaged statuses should have hollow dot
    try std.testing.expectEqualStrings(" ○", FileInfo.GitStatus.unstaged_added.symbol());
    try std.testing.expectEqualStrings(" ○", FileInfo.GitStatus.unstaged_deleted.symbol());
    try std.testing.expectEqualStrings(" ○", FileInfo.GitStatus.unstaged_renamed.symbol());
    try std.testing.expectEqualStrings(" ○", FileInfo.GitStatus.unstaged_copied.symbol());
}

test "GitStatus.symbol special statuses" {
    try std.testing.expectEqualStrings(" !", FileInfo.GitStatus.ignored.symbol());
}

test "GitStatus.colorName returns valid names" {
    try std.testing.expectEqualStrings("git_staged_added", FileInfo.GitStatus.staged_added.colorName());
    try std.testing.expectEqualStrings("git_untracked", FileInfo.GitStatus.untracked.colorName());
}

test "GitStatus.colorName for all staged statuses" {
    try std.testing.expectEqualStrings("git_staged_modified", FileInfo.GitStatus.staged_modified.colorName());
    try std.testing.expectEqualStrings("git_staged_added", FileInfo.GitStatus.staged_added.colorName());
    try std.testing.expectEqualStrings("git_staged_deleted", FileInfo.GitStatus.staged_deleted.colorName());
    try std.testing.expectEqualStrings("git_staged_renamed", FileInfo.GitStatus.staged_renamed.colorName());
    try std.testing.expectEqualStrings("git_staged_copied", FileInfo.GitStatus.staged_copied.colorName());
}

test "GitStatus.colorName for all unstaged statuses" {
    try std.testing.expectEqualStrings("git_unstaged_modified", FileInfo.GitStatus.unstaged_modified.colorName());
    try std.testing.expectEqualStrings("git_unstaged_added", FileInfo.GitStatus.unstaged_added.colorName());
    try std.testing.expectEqualStrings("git_unstaged_deleted", FileInfo.GitStatus.unstaged_deleted.colorName());
    try std.testing.expectEqualStrings("git_unstaged_renamed", FileInfo.GitStatus.unstaged_renamed.colorName());
    try std.testing.expectEqualStrings("git_unstaged_copied", FileInfo.GitStatus.unstaged_copied.colorName());
}

test "GitStatus.colorName for clean returns git_clean" {
    try std.testing.expectEqualStrings("git_clean", FileInfo.GitStatus.clean.colorName());
}

test "FileKind can be directory" {
    const kind: FileInfo.FileKind = .directory;
    try std.testing.expect(kind == .directory);
}

test "FileKind can be executable file" {
    const kind: FileInfo.FileKind = .{ .file = .{ .executable = true } };
    try std.testing.expect(kind.file.executable);
}

test "FileKind can be non-executable file" {
    const kind: FileInfo.FileKind = .{ .file = .{ .executable = false } };
    try std.testing.expect(!kind.file.executable);
}

test "FileKind can be symlink" {
    const kind: FileInfo.FileKind = .symlink;
    try std.testing.expect(kind == .symlink);
}

test "FileInfo can be constructed" {
    const info = FileInfo{
        .name = "test.txt",
        .mode = 0o644,
        .size = 1024,
        .mtime = 0,
        .uid = 1000,
        .gid = 1000,
        .git_status = .clean,
        .kind = .{ .file = .{ .executable = false } },
        .inode = 12345,
    };
    try std.testing.expectEqualStrings("test.txt", info.name);
    try std.testing.expectEqual(@as(u64, 1024), info.size);
    try std.testing.expectEqual(FileInfo.GitStatus.clean, info.git_status);
}

test "GitStatus enum discriminants match char values" {
    try std.testing.expectEqual(@as(u8, ' '), @intFromEnum(FileInfo.GitStatus.clean));
    try std.testing.expectEqual(@as(u8, 'M'), @intFromEnum(FileInfo.GitStatus.staged_modified));
    try std.testing.expectEqual(@as(u8, 'm'), @intFromEnum(FileInfo.GitStatus.unstaged_modified));
    try std.testing.expectEqual(@as(u8, '?'), @intFromEnum(FileInfo.GitStatus.untracked));
    try std.testing.expectEqual(@as(u8, '!'), @intFromEnum(FileInfo.GitStatus.ignored));
}
