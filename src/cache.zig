//! Cache management for HuggingFace Hub files
//!
//! This module provides a local file caching system following the HuggingFace Hub
//! cache structure. It handles OS-aware paths and provides utilities for managing
//! cached model files.

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const config_mod = @import("config.zig");
const types = @import("types.zig");

/// Statistics about the cache
pub const CacheStats = struct {
    /// Total number of cached files
    total_files: u64 = 0,
    /// Total size of cached files in bytes
    total_size: u64 = 0,
    /// Number of unique repositories cached
    num_repos: u64 = 0,
    /// Number of GGUF files cached
    num_gguf_files: u64 = 0,
    /// Size of GGUF files in bytes
    gguf_size: u64 = 0,
};

/// Cache entry information
pub const CacheEntry = struct {
    /// Repository ID (e.g., "meta-llama/Llama-2-7b")
    repo_id: []const u8,
    /// Filename
    filename: []const u8,
    /// Full path to cached file
    path: []const u8,
    /// File size in bytes
    size: u64,
    /// Last modification time (nanoseconds since epoch)
    mtime_ns: i128,
    /// Whether this is a GGUF file
    is_gguf: bool,

    pub fn deinit(self: *CacheEntry, allocator: Allocator) void {
        allocator.free(self.repo_id);
        allocator.free(self.filename);
        allocator.free(self.path);
    }
};

/// File caching system for HuggingFace Hub
pub const Cache = struct {
    /// Cache directory path
    cache_dir: []const u8,
    /// Allocator for memory operations
    allocator: Allocator,
    /// Whether we own the cache_dir string
    cache_dir_owned: bool,

    const Self = @This();

    /// Standard HuggingFace cache subdirectories
    const MODELS_PREFIX = "models--";
    const DATASETS_PREFIX = "datasets--";
    const SPACES_PREFIX = "spaces--";
    const SNAPSHOTS_DIR = "snapshots";
    const BLOBS_DIR = "blobs";
    const REFS_DIR = "refs";

    /// Initialize cache with explicit directory
    pub fn init(allocator: Allocator, cache_dir: []const u8) !Self {
        // Ensure cache directory exists
        try ensureDir(cache_dir);

        return Self{
            .cache_dir = cache_dir,
            .allocator = allocator,
            .cache_dir_owned = false,
        };
    }

    /// Initialize cache with default OS-specific directory
    pub fn initDefault(allocator: Allocator) !Self {
        const default_dir = try getDefaultCacheDir(allocator);
        errdefer allocator.free(default_dir);

        // Ensure cache directory exists
        try ensureDir(default_dir);

        return Self{
            .cache_dir = default_dir,
            .allocator = allocator,
            .cache_dir_owned = true,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        if (self.cache_dir_owned) {
            self.allocator.free(self.cache_dir);
        }
    }

    /// Get the cache path for a repository
    /// Returns: {cache_dir}/models--{org}--{model_name}
    pub fn getRepoCachePath(self: *Self, repo_id: []const u8) ![]u8 {
        const sanitized = try sanitizeRepoId(self.allocator, repo_id);
        defer self.allocator.free(sanitized);

        return std.fmt.allocPrint(
            self.allocator,
            "{s}" ++ std.fs.path.sep_str ++ "{s}{s}",
            .{ self.cache_dir, MODELS_PREFIX, sanitized },
        );
    }

    /// Get the snapshots directory for a repository
    pub fn getSnapshotsPath(self: *Self, repo_id: []const u8) ![]u8 {
        const repo_path = try self.getRepoCachePath(repo_id);
        defer self.allocator.free(repo_path);

        return std.fs.path.join(self.allocator, &.{ repo_path, SNAPSHOTS_DIR });
    }

    /// Get the full cache path for a specific file
    /// Returns: {cache_dir}/models--{org}--{model}/snapshots/{revision}/{filename}
    pub fn getCachePath(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) ![]u8 {
        const repo_path = try self.getRepoCachePath(repo_id);
        defer self.allocator.free(repo_path);

        return std.fs.path.join(self.allocator, &.{ repo_path, SNAPSHOTS_DIR, revision, filename });
    }

    /// Check if a file exists in the cache
    pub fn isCached(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !bool {
        const cache_path = try self.getCachePath(repo_id, filename, revision);
        defer self.allocator.free(cache_path);

        const file = fs.cwd().openFile(cache_path, .{}) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        file.close();
        return true;
    }

    /// Get the cached file path if it exists, otherwise null
    pub fn getCachedFile(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !?[]u8 {
        const cache_path = try self.getCachePath(repo_id, filename, revision);

        const file = fs.cwd().openFile(cache_path, .{}) catch |err| {
            self.allocator.free(cache_path);
            if (err == error.FileNotFound) return null;
            return err;
        };
        file.close();

        return cache_path;
    }

    /// Get the size of a cached file
    pub fn getCachedFileSize(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !?u64 {
        const cache_path = try self.getCachePath(repo_id, filename, revision);
        defer self.allocator.free(cache_path);

        const file = fs.cwd().openFile(cache_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        return stat.size;
    }

    /// Prepare a cache path for writing (create directories)
    pub fn prepareCachePath(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) ![]u8 {
        const cache_path = try self.getCachePath(repo_id, filename, revision);
        errdefer self.allocator.free(cache_path);

        // Ensure parent directories exist
        if (std.fs.path.dirname(cache_path)) |dir| {
            try ensureDir(dir);
        }

        return cache_path;
    }

    /// Get the path for a partial/incomplete download
    pub fn getPartialPath(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) ![]u8 {
        const cache_path = try self.getCachePath(repo_id, filename, revision);
        defer self.allocator.free(cache_path);

        return std.fmt.allocPrint(self.allocator, "{s}.part", .{cache_path});
    }

    /// Check if a partial download exists and get its size
    pub fn getPartialDownloadSize(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !?u64 {
        const partial_path = try self.getPartialPath(repo_id, filename, revision);
        defer self.allocator.free(partial_path);

        const file = fs.cwd().openFile(partial_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        return stat.size;
    }

    /// Move a file to the cache (from a temporary location)
    pub fn cacheFile(
        self: *Self,
        source_path: []const u8,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) ![]u8 {
        const cache_path = try self.prepareCachePath(repo_id, filename, revision);
        errdefer self.allocator.free(cache_path);

        // Copy file to cache
        try fs.cwd().copyFile(source_path, fs.cwd(), cache_path, .{});

        return cache_path;
    }

    /// Rename a partial download to the final cached file
    pub fn finalizePartialDownload(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !void {
        const cache_path = try self.getCachePath(repo_id, filename, revision);
        defer self.allocator.free(cache_path);

        const partial_path = try self.getPartialPath(repo_id, filename, revision);
        defer self.allocator.free(partial_path);

        // Rename .part file to final path
        try fs.cwd().rename(partial_path, cache_path);
    }

    /// Delete a cached file
    pub fn deleteFile(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !void {
        const cache_path = try self.getCachePath(repo_id, filename, revision);
        defer self.allocator.free(cache_path);

        fs.cwd().deleteFile(cache_path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }

    /// Delete partial download file
    pub fn deletePartial(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !void {
        const partial_path = try self.getPartialPath(repo_id, filename, revision);
        defer self.allocator.free(partial_path);

        fs.cwd().deleteFile(partial_path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }

    /// Clear the entire cache
    /// Returns the number of bytes freed
    pub fn clearAll(self: *Self) !u64 {
        var bytes_freed: u64 = 0;

        var dir = fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, MODELS_PREFIX) or
                std.mem.startsWith(u8, entry.name, DATASETS_PREFIX) or
                std.mem.startsWith(u8, entry.name, SPACES_PREFIX))
            {
                bytes_freed += try self.deleteRepoDir(entry.name);
            }
        }

        return bytes_freed;
    }

    /// Clear cache for a specific repository
    pub fn clearRepo(self: *Self, repo_id: []const u8) !u64 {
        const repo_path = try self.getRepoCachePath(repo_id);
        defer self.allocator.free(repo_path);

        return try deleteDirectoryRecursive(repo_path);
    }

    /// Clear cache for repositories matching a pattern
    /// Pattern supports:
    ///   - "*" matches any sequence of characters
    ///   - "?" matches any single character
    ///   - Exact match otherwise
    /// Examples:
    ///   - "TheBloke/*" matches all TheBloke repos
    ///   - "*GGUF*" matches any repo with GGUF in the name
    ///   - "meta-llama/Llama-2-7b" matches exactly that repo
    pub fn clearPattern(self: *Self, pattern: []const u8) !u64 {
        var bytes_freed: u64 = 0;

        var dir = fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, MODELS_PREFIX)) {
                const repo_id = try unsanitizeRepoId(self.allocator, entry.name[MODELS_PREFIX.len..]);
                defer self.allocator.free(repo_id);

                if (matchesPattern(repo_id, pattern)) {
                    bytes_freed += try self.deleteRepoDir(entry.name);
                }
            }
        }

        return bytes_freed;
    }

    /// Clear partial downloads (clean up incomplete files)
    pub fn cleanPartials(self: *Self) !u64 {
        var bytes_freed: u64 = 0;

        var dir = fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, MODELS_PREFIX)) {
                bytes_freed += try self.cleanPartialsInRepo(entry.name);
            }
        }

        return bytes_freed;
    }

    /// Get cache statistics
    pub fn stats(self: *Self) !CacheStats {
        var cache_stats = CacheStats{};

        var dir = fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return cache_stats;
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, MODELS_PREFIX)) {
                cache_stats.num_repos += 1;
                try self.collectRepoStats(entry.name, &cache_stats);
            }
        }

        return cache_stats;
    }

    /// List all cached repositories
    pub fn listRepos(self: *Self) ![][]u8 {
        var repos = std.array_list.Managed([]u8).init(self.allocator);
        errdefer {
            for (repos.items) |r| self.allocator.free(r);
            repos.deinit();
        }

        var dir = fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return try repos.toOwnedSlice();
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, MODELS_PREFIX)) {
                const repo_id = try unsanitizeRepoId(self.allocator, entry.name[MODELS_PREFIX.len..]);
                try repos.append(repo_id);
            }
        }

        return repos.toOwnedSlice();
    }

    /// List all cached files for a repository
    pub fn listRepoFiles(self: *Self, repo_id: []const u8) ![]CacheEntry {
        var entries = std.array_list.Managed(CacheEntry).init(self.allocator);
        errdefer {
            for (entries.items) |*e| e.deinit(self.allocator);
            entries.deinit();
        }

        const snapshots_path = try self.getSnapshotsPath(repo_id);
        defer self.allocator.free(snapshots_path);

        var snapshots_dir = fs.cwd().openDir(snapshots_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return try entries.toOwnedSlice();
            return err;
        };
        defer snapshots_dir.close();

        var rev_iter = snapshots_dir.iterate();
        while (try rev_iter.next()) |rev_entry| {
            if (rev_entry.kind != .directory) continue;

            const rev_path = try std.fs.path.join(self.allocator, &.{ snapshots_path, rev_entry.name });
            defer self.allocator.free(rev_path);

            var files_dir = fs.cwd().openDir(rev_path, .{ .iterate = true }) catch continue;
            defer files_dir.close();

            var file_iter = files_dir.iterate();
            while (try file_iter.next()) |file_entry| {
                if (file_entry.kind != .file) continue;

                const file_path = try std.fs.path.join(self.allocator, &.{ rev_path, file_entry.name });
                errdefer self.allocator.free(file_path);

                const file = fs.cwd().openFile(file_path, .{}) catch continue;
                defer file.close();

                const stat = try file.stat();

                const entry = CacheEntry{
                    .repo_id = try self.allocator.dupe(u8, repo_id),
                    .filename = try self.allocator.dupe(u8, file_entry.name),
                    .path = file_path,
                    .size = stat.size,
                    .mtime_ns = stat.mtime,
                    .is_gguf = types.FileInfo.checkIsGguf(file_entry.name),
                };
                try entries.append(entry);
            }
        }

        return entries.toOwnedSlice();
    }

    // ========================================================================
    // Private helpers
    // ========================================================================

    fn deleteRepoDir(self: *Self, dir_name: []const u8) !u64 {
        const full_path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, dir_name });
        defer self.allocator.free(full_path);

        return deleteDirectoryRecursive(full_path);
    }

    fn cleanPartialsInRepo(self: *Self, dir_name: []const u8) !u64 {
        var bytes_freed: u64 = 0;
        const full_path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, dir_name });
        defer self.allocator.free(full_path);

        // Walk through and delete .part files
        var dir = fs.cwd().openDir(full_path, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".part")) {
                const file_path = try std.fs.path.join(self.allocator, &.{ full_path, entry.path });
                defer self.allocator.free(file_path);

                if (fs.cwd().openFile(file_path, .{})) |file| {
                    const stat = try file.stat();
                    bytes_freed += stat.size;
                    file.close();
                    fs.cwd().deleteFile(file_path) catch {};
                } else |_| {}
            }
        }

        return bytes_freed;
    }

    fn collectRepoStats(self: *Self, dir_name: []const u8, cache_stats: *CacheStats) !void {
        const full_path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, dir_name });
        defer self.allocator.free(full_path);

        var dir = fs.cwd().openDir(full_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and !std.mem.endsWith(u8, entry.basename, ".part")) {
                const file_path = try std.fs.path.join(self.allocator, &.{ full_path, entry.path });
                defer self.allocator.free(file_path);

                if (fs.cwd().openFile(file_path, .{})) |file| {
                    defer file.close();
                    const stat = try file.stat();

                    cache_stats.total_files += 1;
                    cache_stats.total_size += stat.size;

                    if (types.FileInfo.checkIsGguf(entry.basename)) {
                        cache_stats.num_gguf_files += 1;
                        cache_stats.gguf_size += stat.size;
                    }
                } else |_| {}
            }
        }
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Get the default OS-specific cache directory
pub fn getDefaultCacheDir(allocator: Allocator) ![]u8 {
    if (comptime builtin.os.tag == .windows) {
        // Windows: Use LOCALAPPDATA
        if (std.process.getEnvVarOwned(allocator, "LOCALAPPDATA")) |local_app_data| {
            defer allocator.free(local_app_data);
            return std.fs.path.join(allocator, &.{ local_app_data, "huggingface", "hub" });
        } else |_| {}
        // Fallback to USERPROFILE
        if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |user_profile| {
            defer allocator.free(user_profile);
            return std.fs.path.join(allocator, &.{ user_profile, ".cache", "huggingface", "hub" });
        } else |_| {}
        return error.NoCacheDirectory;
    } else if (comptime builtin.os.tag == .macos) {
        // macOS: Use ~/Library/Caches
        if (std.posix.getenv("HOME")) |home| {
            return std.fs.path.join(allocator, &.{ home, "Library", "Caches", "huggingface", "hub" });
        }
        return error.NoCacheDirectory;
    } else {
        // Linux and others: Use XDG_CACHE_HOME or ~/.cache
        if (std.posix.getenv("XDG_CACHE_HOME")) |xdg_cache| {
            return std.fs.path.join(allocator, &.{ xdg_cache, "huggingface", "hub" });
        }
        if (std.posix.getenv("HOME")) |home| {
            return std.fs.path.join(allocator, &.{ home, ".cache", "huggingface", "hub" });
        }
        return error.NoCacheDirectory;
    }
}

/// Sanitize repo ID for use in filesystem path
/// Replaces '/' with '--'
fn sanitizeRepoId(allocator: Allocator, repo_id: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, repo_id.len + 1); // +1 for potential extra '-'
    var j: usize = 0;

    for (repo_id) |c| {
        if (c == '/') {
            result[j] = '-';
            j += 1;
            result[j] = '-';
            j += 1;
        } else {
            result[j] = c;
            j += 1;
        }
    }

    // Resize to actual length
    return allocator.realloc(result, j);
}

/// Convert sanitized repo ID back to original format
/// Replaces '--' with '/'
fn unsanitizeRepoId(allocator: Allocator, sanitized: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < sanitized.len) {
        if (i + 1 < sanitized.len and sanitized[i] == '-' and sanitized[i + 1] == '-') {
            try result.append('/');
            i += 2;
        } else {
            try result.append(sanitized[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

/// Ensure a directory exists, creating it if necessary
/// Simple glob pattern matching
/// Supports:
///   - "*" matches any sequence of characters (including empty)
///   - "?" matches exactly one character
///   - Other characters match literally (case-insensitive)
fn matchesPattern(text: []const u8, pattern: []const u8) bool {
    return matchesPatternRecursive(text, pattern);
}

fn matchesPatternRecursive(text: []const u8, pattern: []const u8) bool {
    var t_idx: usize = 0;
    var p_idx: usize = 0;

    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or std.ascii.toLower(pattern[p_idx]) == std.ascii.toLower(text[t_idx]))) {
            // Character match or single-char wildcard
            t_idx += 1;
            p_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            // Star wildcard - remember position and try matching zero characters first
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx) |si| {
            // Mismatch but we have a star to backtrack to
            p_idx = si + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            // Mismatch with no star to backtrack to
            return false;
        }
    }

    // Check remaining pattern characters (must all be stars)
    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

fn ensureDir(path: []const u8) !void {
    fs.cwd().makePath(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

/// Delete a directory and all its contents recursively
/// Returns the total bytes deleted
fn deleteDirectoryRecursive(path: []const u8) !u64 {
    var bytes_deleted: u64 = 0;

    // First, collect sizes
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };

    var walker = try dir.walk(std.heap.page_allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            const full_path = try std.fs.path.join(std.heap.page_allocator, &.{ path, entry.path });
            defer std.heap.page_allocator.free(full_path);

            if (fs.cwd().openFile(full_path, .{})) |file| {
                const stat = try file.stat();
                bytes_deleted += stat.size;
                file.close();
            } else |_| {}
        }
    }

    dir.close();

    // Now delete the directory
    fs.cwd().deleteTree(path) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    return bytes_deleted;
}

// ============================================================================
// Tests
// ============================================================================

test "sanitizeRepoId" {
    const allocator = std.testing.allocator;

    const result = try sanitizeRepoId(allocator, "meta-llama/Llama-2-7b");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("meta-llama--Llama-2-7b", result);
}

test "unsanitizeRepoId" {
    const allocator = std.testing.allocator;

    const result = try unsanitizeRepoId(allocator, "meta-llama--Llama-2-7b");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("meta-llama/Llama-2-7b", result);
}

test "matchesPattern - exact match" {
    try std.testing.expect(matchesPattern("TheBloke/Model", "TheBloke/Model"));
    try std.testing.expect(!matchesPattern("TheBloke/Model", "TheBloke/Other"));
}

test "matchesPattern - star wildcard" {
    try std.testing.expect(matchesPattern("TheBloke/Llama-2-7B-GGUF", "TheBloke/*"));
    try std.testing.expect(matchesPattern("TheBloke/Mistral-GGUF", "TheBloke/*"));
    try std.testing.expect(!matchesPattern("OtherOrg/Model", "TheBloke/*"));
    try std.testing.expect(matchesPattern("TheBloke/Llama-2-7B-GGUF", "*GGUF*"));
    try std.testing.expect(matchesPattern("SomeOrg/My-GGUF-Model", "*GGUF*"));
    try std.testing.expect(!matchesPattern("TheBloke/Llama-2-7B", "*GGUF*"));
}

test "matchesPattern - question mark wildcard" {
    try std.testing.expect(matchesPattern("Model-A", "Model-?"));
    try std.testing.expect(matchesPattern("Model-B", "Model-?"));
    try std.testing.expect(!matchesPattern("Model-AB", "Model-?"));
}

test "matchesPattern - case insensitive" {
    try std.testing.expect(matchesPattern("TheBloke/Model", "thebloke/model"));
    try std.testing.expect(matchesPattern("THEBLOKE/MODEL", "TheBloke/*"));
}

test "sanitize and unsanitize roundtrip" {
    const allocator = std.testing.allocator;
    const original = "TheBloke/Llama-2-7B-GGUF";

    const sanitized = try sanitizeRepoId(allocator, original);
    defer allocator.free(sanitized);

    const unsanitized = try unsanitizeRepoId(allocator, sanitized);
    defer allocator.free(unsanitized);

    try std.testing.expectEqualStrings(original, unsanitized);
}

test "CacheStats initial values" {
    const stats = CacheStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.total_files);
    try std.testing.expectEqual(@as(u64, 0), stats.total_size);
    try std.testing.expectEqual(@as(u64, 0), stats.num_repos);
}
