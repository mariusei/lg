const std = @import("std");
const types = @import("types.zig");

pub const GitContext = struct {
    allocator: std.mem.Allocator,
    statuses: std.StringHashMap(types.FileInfo.GitStatus),
    rel_prefix: []const u8,

    /// Initialize GitContext by loading git status for the given directory.
    /// Returns error if not a git repository or git command fails.
    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8) !GitContext {
        var self = GitContext{
            .allocator = allocator,
            .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
            .rel_prefix = &.{},
        };

        // Load git status - git itself will handle if not a repo
        try self.load(dir_path);
        return self;
    }

    pub fn deinit(self: *GitContext) void {
        // Free all keys in the hashmap (they are duplicated strings)
        var it = self.statuses.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.statuses.deinit();
    }

    /// Execute `git status --porcelain=v2` and parse output into hash map
    fn load(self: *GitContext, dir_path: []const u8) !void {
        var child = std.process.Child.init(
            &.{ "git", "status", "--porcelain=v2" },
            self.allocator,
        );
        // TODO: Add environment variable isolation for security
        // (requires inheriting current env + adding security vars)
        child.cwd = dir_path;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        // Read stdout (blocks until process completes or pipe closes)
        // Git has its own timeout mechanisms, no need for manual timeout
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, types.GIT_STATUS_MAX_OUTPUT);
        defer self.allocator.free(stdout);

        // Wait for process to complete
        const result = try child.wait();
        switch (result) {
            .Exited => |code| if (code != 0) return error.GitCommandFailed,
            else => return error.GitCommandFailed,
        }

        // Parse porcelain v2 format
        var lines = std.mem.splitScalar(u8, stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            if (line[0] == '1' or line[0] == '2') {
                // Tracked file entry
                try self.parseTrackedFile(line);
            } else if (line[0] == '?') {
                // Untracked file entry
                try self.parseUntrackedFile(line);
            }
            // Ignore other lines (e.g., '# branch.oid ...', '# branch.head ...', etc.)
            // This is safe - git porcelain v2 format specifies these are metadata lines
        }
    }

    /// Parse tracked file line: "1 XY sub <mH> <mI> <mW> <hH> <hI> <path>"
    fn parseTrackedFile(self: *GitContext, line: []const u8) !void {
        // Format: "1 XY sub ...fields... path"
        // We need: XY (2 chars) and path (everything after 8th field)

        var iter = std.mem.splitScalar(u8, line, ' ');
        _ = iter.next(); // Skip "1" or "2"

        const xy = iter.next() orelse return error.InvalidFormat;
        if (xy.len < 2) return error.InvalidFormat;

        // Skip exactly 6 more fields (sub, mH, mI, mW, hH, hI)
        // Then everything remaining is the path (which may contain spaces)
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            _ = iter.next() orelse return error.InvalidFormat;
        }

        // Get index where path starts
        const path_start = iter.index orelse return error.InvalidFormat;
        const final_path = line[path_start..];

        const status = parseStatusChars(xy[0], xy[1]);

        // Duplicate the path string since git output will be freed
        const owned_path = try self.allocator.dupe(u8, final_path);
        try self.statuses.put(owned_path, status);
    }

    /// Parse untracked file line: "? <path>"
    fn parseUntrackedFile(self: *GitContext, line: []const u8) !void {
        const path = std.mem.trim(u8, line[1..], &std.ascii.whitespace);
        if (path.len == 0) return error.InvalidFormat;

        // Duplicate the path string since git output will be freed
        const owned_path = try self.allocator.dupe(u8, path);
        try self.statuses.put(owned_path, .untracked);
    }

    /// Convert git status XY codes to our GitStatus enum
    fn parseStatusChars(staged: u8, unstaged: u8) types.FileInfo.GitStatus {
        // Prioritize unstaged over staged - unstaged changes are more urgent/visible
        // Users should see what needs attention first
        if (unstaged != '.' and unstaged != ' ') {
            return switch (unstaged) {
                'M' => .unstaged_modified,
                'A' => .unstaged_added,
                'D' => .unstaged_deleted,
                'R' => .unstaged_renamed,
                'C' => .unstaged_copied,
                else => .clean,
            };
        }

        if (staged != '.' and staged != ' ') {
            return switch (staged) {
                'M' => .staged_modified,
                'A' => .staged_added,
                'D' => .staged_deleted,
                'R' => .staged_renamed,
                'C' => .staged_copied,
                else => .clean,
            };
        }

        return .clean;
    }

    /// Get git status for a specific filename.
    /// Returns .clean if file not found in git status.
    /// For directories, checks if any files inside have changes.
    pub fn getStatus(self: *const GitContext, filename: []const u8, is_dir: bool) types.FileInfo.GitStatus {
        // Try exact match first
        if (self.statuses.get(filename)) |status| {
            return status;
        }

        // For directories, check for trailing slash variant
        if (is_dir) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const with_slash = std.fmt.bufPrint(&buf, "{s}/", .{filename}) catch return .clean;

            if (self.statuses.get(with_slash)) |status| {
                return status;
            }

            // Check if any files inside the directory have changes
            return self.checkDirForChanges(filename);
        }

        // Check if current directory itself is untracked (./)
        // When git runs from inside an untracked directory, it reports "./" as untracked
        // All files within should inherit that status
        if (self.statuses.get("./")) |status| {
            if (status == .untracked) {
                return .untracked;
            }
        }

        return .clean;
    }

    /// Check if a directory contains any files with git changes
    /// Returns the most "urgent" status found (unstaged > staged > untracked)
    fn checkDirForChanges(self: *const GitContext, dir_path: []const u8) types.FileInfo.GitStatus {
        var best_status: types.FileInfo.GitStatus = .clean;
        var priority: u8 = 0; // 0=none, 1=staged, 2=untracked, 3=unstaged

        // Create prefix to match files in this directory
        var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}/", .{dir_path}) catch return .clean;

        // Iterate through all git entries to find matches
        var iter = self.statuses.iterator();
        while (iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                const status = entry.value_ptr.*;

                // Determine priority of this status (unstaged > staged > untracked)
                const current_priority: u8 = switch (status) {
                    .unstaged_modified, .unstaged_added, .unstaged_deleted, .unstaged_renamed, .unstaged_copied => 3,
                    .staged_modified, .staged_added, .staged_deleted, .staged_renamed, .staged_copied => 2,
                    .untracked => 1,
                    else => 0,
                };

                if (current_priority > priority) {
                    best_status = status;
                    priority = current_priority;
                }
            }
        }

        return best_status;
    }
};

// ═══════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════

test "GitContext parseStatusChars - staged modifications" {
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_modified, GitContext.parseStatusChars('M', '.'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_added, GitContext.parseStatusChars('A', '.'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_deleted, GitContext.parseStatusChars('D', '.'));
}

test "GitContext parseStatusChars - unstaged modifications" {
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_modified, GitContext.parseStatusChars('.', 'M'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_added, GitContext.parseStatusChars('.', 'A'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_deleted, GitContext.parseStatusChars('.', 'D'));
}

test "GitContext parseStatusChars - unstaged takes priority" {
    // When both staged and unstaged exist, unstaged wins (more urgent to see uncommitted changes)
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_deleted, GitContext.parseStatusChars('M', 'D'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_modified, GitContext.parseStatusChars('A', 'M'));
}

test "GitContext parseStatusChars - clean state" {
    try std.testing.expectEqual(types.FileInfo.GitStatus.clean, GitContext.parseStatusChars('.', '.'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.clean, GitContext.parseStatusChars(' ', ' '));
    try std.testing.expectEqual(types.FileInfo.GitStatus.clean, GitContext.parseStatusChars('.', ' '));
}

test "GitContext parseStatusChars - all staged status codes" {
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_modified, GitContext.parseStatusChars('M', '.'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_added, GitContext.parseStatusChars('A', '.'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_deleted, GitContext.parseStatusChars('D', '.'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_renamed, GitContext.parseStatusChars('R', '.'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_copied, GitContext.parseStatusChars('C', '.'));
}

test "GitContext parseStatusChars - all unstaged status codes" {
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_modified, GitContext.parseStatusChars('.', 'M'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_added, GitContext.parseStatusChars('.', 'A'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_deleted, GitContext.parseStatusChars('.', 'D'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_renamed, GitContext.parseStatusChars('.', 'R'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_copied, GitContext.parseStatusChars('.', 'C'));
}

test "GitContext parseStatusChars - unknown codes default to clean" {
    try std.testing.expectEqual(types.FileInfo.GitStatus.clean, GitContext.parseStatusChars('X', '.'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.clean, GitContext.parseStatusChars('.', 'Y'));
    try std.testing.expectEqual(types.FileInfo.GitStatus.clean, GitContext.parseStatusChars('?', '!'));
}

test "GitContext parseTrackedFile - valid format" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    // Format: "1 XY sub <mH> <mI> <mW> <hH> <hI> <path>"
    try ctx.parseTrackedFile("1 M. N... 100644 100644 100644 abc123 def456 src/main.zig");

    const status = ctx.statuses.get("src/main.zig");
    try std.testing.expect(status != null);
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_modified, status.?);
}

test "GitContext parseTrackedFile - unstaged modification" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    try ctx.parseTrackedFile("1 .M N... 100644 100644 100644 abc123 def456 test/file.txt");

    const status = ctx.statuses.get("test/file.txt");
    try std.testing.expect(status != null);
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_modified, status.?);
}

test "GitContext parseTrackedFile - path with spaces" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    // Note: Git escapes spaces in paths, but we'll handle the simple case
    // In real git output, this would be escaped
    try ctx.parseTrackedFile("1 A. N... 100644 100644 100644 abc123 def456 my file.txt");

    const status = ctx.statuses.get("my file.txt");
    try std.testing.expect(status != null);
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_added, status.?);
}

test "GitContext parseUntrackedFile - valid format" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    try ctx.parseUntrackedFile("? untracked.txt");

    const status = ctx.statuses.get("untracked.txt");
    try std.testing.expect(status != null);
    try std.testing.expectEqual(types.FileInfo.GitStatus.untracked, status.?);
}

test "GitContext parseUntrackedFile - directory" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    try ctx.parseUntrackedFile("? build/");

    const status = ctx.statuses.get("build/");
    try std.testing.expect(status != null);
    try std.testing.expectEqual(types.FileInfo.GitStatus.untracked, status.?);
}

test "GitContext getStatus - exact match" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    const owned_path = try allocator.dupe(u8, "test.txt");
    try ctx.statuses.put(owned_path, .unstaged_modified);

    const status = ctx.getStatus("test.txt", false);
    try std.testing.expectEqual(types.FileInfo.GitStatus.unstaged_modified, status);
}

test "GitContext getStatus - not found returns clean" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer ctx.statuses.deinit();

    const status = ctx.getStatus("nonexistent.txt", false);
    try std.testing.expectEqual(types.FileInfo.GitStatus.clean, status);
}

test "GitContext getStatus - directory with trailing slash" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    const owned_path = try allocator.dupe(u8, "src/");
    try ctx.statuses.put(owned_path, .untracked);

    // Query without trailing slash
    const status = ctx.getStatus("src", true);
    try std.testing.expectEqual(types.FileInfo.GitStatus.untracked, status);
}

test "GitContext getStatus - directory exact match without slash" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    const owned_path = try allocator.dupe(u8, "build");
    try ctx.statuses.put(owned_path, .untracked);

    const status = ctx.getStatus("build", true);
    try std.testing.expectEqual(types.FileInfo.GitStatus.untracked, status);
}

test "GitContext parseTrackedFile - staged added" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    try ctx.parseTrackedFile("1 A. N... 000000 100644 100644 000000 abc123 new_file.zig");

    const status = ctx.statuses.get("new_file.zig");
    try std.testing.expect(status != null);
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_added, status.?);
}

test "GitContext parseTrackedFile - staged deleted" {
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    try ctx.parseTrackedFile("1 D. N... 100644 000000 000000 abc123 000000 deleted.zig");

    const status = ctx.statuses.get("deleted.zig");
    try std.testing.expect(status != null);
    try std.testing.expectEqual(types.FileInfo.GitStatus.staged_deleted, status.?);
}

test "GitContext init and deinit - memory safety" {
    const allocator = std.testing.allocator;

    // This test verifies that init/deinit properly manage memory
    // We'll skip actual git execution since it may fail in test environment
    // Instead we test the structure creation and cleanup

    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };

    // Manually add some entries to test cleanup
    const path1 = try allocator.dupe(u8, "test1.zig");
    const path2 = try allocator.dupe(u8, "test2.zig");

    try ctx.statuses.put(path1, .unstaged_modified);
    try ctx.statuses.put(path2, .staged_added);

    // deinit should free all keys
    ctx.deinit();
}

test "GitContext getStatus - files inherit untracked from current directory" {
    // When git runs from inside an untracked directory, it reports "./" as untracked.
    // All files within should inherit that untracked status.
    const allocator = std.testing.allocator;
    var ctx = GitContext{
        .allocator = allocator,
        .statuses = std.StringHashMap(types.FileInfo.GitStatus).init(allocator),
        .rel_prefix = &.{},
    };
    defer {
        var it = ctx.statuses.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        ctx.statuses.deinit();
    }

    // Simulate git status from an untracked directory: "? ./"
    const owned_path = try allocator.dupe(u8, "./");
    try ctx.statuses.put(owned_path, .untracked);

    // Any file lookup should return untracked (not clean)
    const status = ctx.getStatus("some_file.txt", false);
    try std.testing.expectEqual(types.FileInfo.GitStatus.untracked, status);
}
