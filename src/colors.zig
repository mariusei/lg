//! ANSI 256-color definitions for file types and git status.
//! Uses muted colors for better readability on dark terminals.
//!
//! Color scheme:
//! - File types: Blue (dirs), Green (exec), Cyan (symlinks)
//! - Git staged: Orange/green/red/purple/cyan (214/34/167/141/73)
//! - Git unstaged: Dimmed versions (178/28/131/97/66)
//! - Git special: Gray scale for untracked/ignored

const std = @import("std");

// ANSI color codes as comptime constants
pub const reset = "\x1b[0m";

// ANSI 256-color format: ESC[38;5;{color_number}m
// Staged vs unstaged: Brighter (214) vs dimmed (178) for same operation
// Why muted? High-contrast colors distract from actual content
// Color pairings:
//   Modified: Orange (214/178)
//   Added: Green (34/28)
//   Deleted: Red (167/131)
//   Renamed: Purple (141/97)
//   Copied: Cyan (73/66)
// Git status colors (muted to not distract)
pub const git_staged_modified = "\x1b[38;5;214m"; // Orange
pub const git_unstaged_modified = "\x1b[38;5;178m"; // Dimmed orange
pub const git_staged_added = "\x1b[38;5;34m"; // Muted green
pub const git_unstaged_added = "\x1b[38;5;28m"; // Darker green
pub const git_staged_deleted = "\x1b[38;5;167m"; // Muted red
pub const git_unstaged_deleted = "\x1b[38;5;131m"; // Dimmed red
pub const git_staged_renamed = "\x1b[38;5;141m"; // Muted purple
pub const git_unstaged_renamed = "\x1b[38;5;97m"; // Dimmed purple
pub const git_staged_copied = "\x1b[38;5;73m"; // Muted cyan
pub const git_unstaged_copied = "\x1b[38;5;66m"; // Dimmed cyan
pub const git_untracked = "\x1b[38;5;245m"; // Light gray
pub const git_ignored = "\x1b[38;5;240m"; // Dark gray
pub const git_clean = "\x1b[38;5;34m"; // Muted green (same as staged_added)

// File type colors
pub const symlink = "\x1b[36m"; // Cyan
pub const directory = "\x1b[34m"; // Blue
pub const executable = "\x1b[32m"; // Green

// Linear search through color names - acceptable performance tradeoff
// Called once per file (not hot path)
// 14 comparisons worst-case << git subprocess overhead (~10ms)
// Alternative: HashMap would add 50+ LOC for negligible gain
// Helper function to get color by name (for GitStatus.colorName())
pub fn getColor(name: []const u8) []const u8 {
    // Use comptime string comparison for efficiency
    if (std.mem.eql(u8, name, "reset")) return reset;
    if (std.mem.eql(u8, name, "git_staged_modified")) return git_staged_modified;
    if (std.mem.eql(u8, name, "git_unstaged_modified")) return git_unstaged_modified;
    if (std.mem.eql(u8, name, "git_staged_added")) return git_staged_added;
    if (std.mem.eql(u8, name, "git_unstaged_added")) return git_unstaged_added;
    if (std.mem.eql(u8, name, "git_staged_deleted")) return git_staged_deleted;
    if (std.mem.eql(u8, name, "git_unstaged_deleted")) return git_unstaged_deleted;
    if (std.mem.eql(u8, name, "git_staged_renamed")) return git_staged_renamed;
    if (std.mem.eql(u8, name, "git_unstaged_renamed")) return git_unstaged_renamed;
    if (std.mem.eql(u8, name, "git_staged_copied")) return git_staged_copied;
    if (std.mem.eql(u8, name, "git_unstaged_copied")) return git_unstaged_copied;
    if (std.mem.eql(u8, name, "git_untracked")) return git_untracked;
    if (std.mem.eql(u8, name, "git_ignored")) return git_ignored;
    if (std.mem.eql(u8, name, "git_clean")) return git_clean;
    if (std.mem.eql(u8, name, "symlink")) return symlink;
    if (std.mem.eql(u8, name, "directory")) return directory;
    if (std.mem.eql(u8, name, "executable")) return executable;
    return reset; // Default
}

// ═══════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════

test "getColor returns correct ANSI codes" {
    try std.testing.expectEqualStrings("\x1b[0m", getColor("reset"));
    try std.testing.expectEqualStrings("\x1b[38;5;214m", getColor("git_staged_modified"));
    try std.testing.expectEqualStrings("\x1b[34m", getColor("directory"));
}

test "unknown color returns reset" {
    try std.testing.expectEqualStrings(reset, getColor("nonexistent"));
}

test "getColor returns all git staged colors" {
    try std.testing.expectEqualStrings(git_staged_modified, getColor("git_staged_modified"));
    try std.testing.expectEqualStrings(git_staged_added, getColor("git_staged_added"));
    try std.testing.expectEqualStrings(git_staged_deleted, getColor("git_staged_deleted"));
    try std.testing.expectEqualStrings(git_staged_renamed, getColor("git_staged_renamed"));
    try std.testing.expectEqualStrings(git_staged_copied, getColor("git_staged_copied"));
}

test "getColor returns all git unstaged colors" {
    try std.testing.expectEqualStrings(git_unstaged_modified, getColor("git_unstaged_modified"));
    try std.testing.expectEqualStrings(git_unstaged_added, getColor("git_unstaged_added"));
    try std.testing.expectEqualStrings(git_unstaged_deleted, getColor("git_unstaged_deleted"));
    try std.testing.expectEqualStrings(git_unstaged_renamed, getColor("git_unstaged_renamed"));
    try std.testing.expectEqualStrings(git_unstaged_copied, getColor("git_unstaged_copied"));
}

test "getColor returns special git statuses" {
    try std.testing.expectEqualStrings(git_untracked, getColor("git_untracked"));
    try std.testing.expectEqualStrings(git_ignored, getColor("git_ignored"));
}

test "getColor returns file type colors" {
    try std.testing.expectEqualStrings(symlink, getColor("symlink"));
    try std.testing.expectEqualStrings(directory, getColor("directory"));
    try std.testing.expectEqualStrings(executable, getColor("executable"));
}

test "all ANSI codes start with escape sequence" {
    const colors = [_][]const u8{
        reset,
        git_staged_modified,
        git_unstaged_modified,
        git_staged_added,
        git_unstaged_added,
        git_staged_deleted,
        git_unstaged_deleted,
        git_staged_renamed,
        git_unstaged_renamed,
        git_staged_copied,
        git_unstaged_copied,
        git_untracked,
        git_ignored,
        symlink,
        directory,
        executable,
    };

    for (colors) |color| {
        try std.testing.expect(std.mem.startsWith(u8, color, "\x1b["));
    }
}

test "reset code is standard ANSI reset" {
    try std.testing.expectEqualStrings("\x1b[0m", reset);
}

test "getColor is case sensitive" {
    try std.testing.expectEqualStrings(reset, getColor("RESET")); // Should return default
    try std.testing.expectEqualStrings(reset, getColor("Directory")); // Should return default
}
