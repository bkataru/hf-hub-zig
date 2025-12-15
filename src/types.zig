//! Core data types for HuggingFace Hub API
//!
//! This module defines all the data structures used to represent
//! HuggingFace Hub API responses and query parameters.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Repository type on HuggingFace Hub
pub const RepoType = enum {
    model,
    dataset,
    space,

    pub fn toString(self: RepoType) []const u8 {
        return switch (self) {
            .model => "model",
            .dataset => "dataset",
            .space => "space",
        };
    }

    pub fn fromString(s: []const u8) ?RepoType {
        if (std.mem.eql(u8, s, "model")) return .model;
        if (std.mem.eql(u8, s, "dataset")) return .dataset;
        if (std.mem.eql(u8, s, "space")) return .space;
        return null;
    }
};

/// File/sibling information from HuggingFace API
pub const Sibling = struct {
    /// Relative filename in the repository (e.g., "model.gguf")
    rfilename: []const u8,
    /// File size in bytes (may be null for some files)
    size: ?u64 = null,
    /// Blob ID for the file
    blob_id: ?[]const u8 = null,

    pub fn deinit(self: *Sibling, allocator: Allocator) void {
        allocator.free(self.rfilename);
        if (self.blob_id) |bid| {
            allocator.free(bid);
        }
    }
};

/// Detailed file information
pub const FileInfo = struct {
    /// Filename (without path)
    filename: []const u8,
    /// Full relative path in the repository
    path: []const u8,
    /// File size in bytes
    size: ?u64 = null,
    /// Blob ID / SHA for the file
    blob_id: ?[]const u8 = null,
    /// ETag from server (for caching)
    etag: ?[]const u8 = null,
    /// Whether this is a GGUF file (computed from filename)
    is_gguf: bool = false,
    /// Whether this is an LFS file
    is_lfs: bool = false,

    /// Check if filename ends with .gguf
    pub fn checkIsGguf(filename: []const u8) bool {
        return std.mem.endsWith(u8, filename, ".gguf") or
            std.mem.endsWith(u8, filename, ".GGUF");
    }

    /// Create FileInfo from a Sibling
    pub fn fromSibling(sibling: Sibling) FileInfo {
        const filename = std.fs.path.basename(sibling.rfilename);
        return FileInfo{
            .filename = filename,
            .path = sibling.rfilename,
            .size = sibling.size,
            .blob_id = sibling.blob_id,
            .is_gguf = checkIsGguf(sibling.rfilename),
        };
    }

    pub fn deinit(self: *FileInfo, allocator: Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.path);
        if (self.blob_id) |bid| allocator.free(bid);
        if (self.etag) |et| allocator.free(et);
    }

    /// Format file size as human-readable string
    pub fn formatSize(self: FileInfo, buf: []u8) []const u8 {
        if (self.size) |size| {
            return formatBytes(size, buf);
        }
        return "unknown";
    }
};

/// Model information from HuggingFace API
pub const Model = struct {
    /// Model ID (e.g., "meta-llama/Llama-2-7b-hf")
    id: []const u8,
    /// Model ID (same as id, for API compatibility)
    model_id: ?[]const u8 = null,
    /// Author/organization name
    author: ?[]const u8 = null,
    /// Repository SHA/commit
    sha: ?[]const u8 = null,
    /// Last modification timestamp
    last_modified: ?[]const u8 = null,
    /// Whether the model is private
    private: bool = false,
    /// Whether the model is gated (requires agreement)
    gated: ?bool = null,
    /// Whether the model is disabled
    disabled: bool = false,
    /// Model library name (e.g., "transformers")
    library_name: ?[]const u8 = null,
    /// Model tags
    tags: [][]const u8 = &[_][]const u8{},
    /// Pipeline tag (e.g., "text-generation")
    pipeline_tag: ?[]const u8 = null,
    /// Files/siblings in the repository
    siblings: []Sibling = &[_]Sibling{},
    /// Download count
    downloads: ?u64 = null,
    /// Like count
    likes: ?u64 = null,
    /// Trending score
    trending_score: ?f64 = null,
    /// Model card data (description, etc.)
    card_data: ?CardData = null,

    pub fn deinit(self: *Model, allocator: Allocator) void {
        allocator.free(self.id);
        if (self.model_id) |mid| allocator.free(mid);
        if (self.author) |a| allocator.free(a);
        if (self.sha) |s| allocator.free(s);
        if (self.last_modified) |lm| allocator.free(lm);
        if (self.library_name) |ln| allocator.free(ln);
        if (self.pipeline_tag) |pt| allocator.free(pt);

        for (self.tags) |tag| {
            allocator.free(tag);
        }
        if (self.tags.len > 0) {
            allocator.free(self.tags);
        }

        for (self.siblings) |*sib| {
            var s = sib.*;
            s.deinit(allocator);
        }
        if (self.siblings.len > 0) {
            allocator.free(self.siblings);
        }

        if (self.card_data) |*cd| {
            var c = cd.*;
            c.deinit(allocator);
        }
    }

    /// Get the organization/owner from the model ID
    pub fn getOwner(self: Model) ?[]const u8 {
        if (std.mem.indexOf(u8, self.id, "/")) |idx| {
            return self.id[0..idx];
        }
        return null;
    }

    /// Get the model name from the model ID
    pub fn getName(self: Model) []const u8 {
        if (std.mem.indexOf(u8, self.id, "/")) |idx| {
            return self.id[idx + 1 ..];
        }
        return self.id;
    }

    /// Check if model has any GGUF files
    pub fn hasGgufFiles(self: Model) bool {
        for (self.siblings) |sib| {
            if (FileInfo.checkIsGguf(sib.rfilename)) {
                return true;
            }
        }
        return false;
    }

    /// Get list of GGUF files
    pub fn getGgufFiles(self: Model, allocator: Allocator) ![]FileInfo {
        var gguf_files = std.array_list.Managed(FileInfo).init(allocator);
        errdefer gguf_files.deinit();

        for (self.siblings) |sib| {
            if (FileInfo.checkIsGguf(sib.rfilename)) {
                try gguf_files.append(FileInfo.fromSibling(sib));
            }
        }

        return gguf_files.toOwnedSlice();
    }
};

/// Model card data
pub const CardData = struct {
    /// Model description
    description: ?[]const u8 = null,
    /// License
    license: ?[]const u8 = null,
    /// Language tags
    language: [][]const u8 = &[_][]const u8{},
    /// Dataset tags
    datasets: [][]const u8 = &[_][]const u8{},

    pub fn deinit(self: *CardData, allocator: Allocator) void {
        if (self.description) |d| allocator.free(d);
        if (self.license) |l| allocator.free(l);
        for (self.language) |lang| allocator.free(lang);
        if (self.language.len > 0) allocator.free(self.language);
        for (self.datasets) |ds| allocator.free(ds);
        if (self.datasets.len > 0) allocator.free(self.datasets);
    }
};

/// Detailed model information (extended version of Model)
pub const ModelInfo = struct {
    /// Base model data
    model: Model,
    /// Repository type
    repo_type: RepoType = .model,
    /// Full description text
    description: ?[]const u8 = null,
    /// README content
    readme: ?[]const u8 = null,

    pub fn deinit(self: *ModelInfo, allocator: Allocator) void {
        self.model.deinit(allocator);
        if (self.description) |d| allocator.free(d);
        if (self.readme) |r| allocator.free(r);
    }
};

/// Search query parameters
pub const SearchQuery = struct {
    /// Search text
    search: []const u8 = "",
    /// Filter by author/organization
    author: ?[]const u8 = null,
    /// Filter string (e.g., "gguf")
    filter: ?[]const u8 = null,
    /// Sort order
    sort: SortOrder = .trending,
    /// Sort direction
    direction: SortDirection = .descending,
    /// Maximum results to return
    limit: u32 = 20,
    /// Pagination offset
    offset: u32 = 0,
    /// Include full model info (siblings, etc.)
    full: bool = false,
    /// Include config info
    config: bool = false,
};

/// Sort order for search results
pub const SortOrder = enum {
    trending,
    downloads,
    likes,
    created,
    modified,

    pub fn toString(self: SortOrder) []const u8 {
        return switch (self) {
            .trending => "trendingScore",
            .downloads => "downloads",
            .likes => "likes",
            .created => "createdAt",
            .modified => "lastModified",
        };
    }

    pub fn fromString(s: []const u8) ?SortOrder {
        if (std.mem.eql(u8, s, "trending")) return .trending;
        if (std.mem.eql(u8, s, "downloads")) return .downloads;
        if (std.mem.eql(u8, s, "likes")) return .likes;
        if (std.mem.eql(u8, s, "created")) return .created;
        if (std.mem.eql(u8, s, "modified")) return .modified;
        return null;
    }
};

/// Sort direction
pub const SortDirection = enum {
    ascending,
    descending,

    pub fn toInt(self: SortDirection) i8 {
        return switch (self) {
            .ascending => 1,
            .descending => -1,
        };
    }
};

/// Search result container
pub const SearchResult = struct {
    /// List of matching models
    models: []Model,
    /// Total count (if available)
    total: ?u64 = null,
    /// Query limit used
    limit: u32,
    /// Query offset used
    offset: u32,

    pub fn deinit(self: *SearchResult, allocator: Allocator) void {
        for (self.models) |*model| {
            model.deinit(allocator);
        }
        if (self.models.len > 0) {
            allocator.free(self.models);
        }
    }

    /// Check if there are more results
    pub fn hasMore(self: SearchResult) bool {
        if (self.total) |total| {
            return self.offset + self.models.len < total;
        }
        return self.models.len >= self.limit;
    }
};

/// GGUF-specific model representation
pub const GgufModel = struct {
    /// Model ID
    id: []const u8,
    /// Model description
    description: ?[]const u8 = null,
    /// Author/organization
    author: ?[]const u8 = null,
    /// GGUF files in the model
    gguf_files: []FileInfo,
    /// Last modified timestamp
    last_modified: ?[]const u8 = null,
    /// Download count
    downloads: ?u64 = null,
    /// Like count
    likes: ?u64 = null,
    /// Tags
    tags: [][]const u8 = &[_][]const u8{},

    pub fn deinit(self: *GgufModel, allocator: Allocator) void {
        allocator.free(self.id);
        if (self.description) |d| allocator.free(d);
        if (self.author) |a| allocator.free(a);
        if (self.last_modified) |lm| allocator.free(lm);
        for (self.gguf_files) |*f| f.deinit(allocator);
        if (self.gguf_files.len > 0) allocator.free(self.gguf_files);
        for (self.tags) |t| allocator.free(t);
        if (self.tags.len > 0) allocator.free(self.tags);
    }

    /// Create from a Model
    pub fn fromModel(model: Model, allocator: Allocator) !GgufModel {
        const gguf_files = try model.getGgufFiles(allocator);
        return GgufModel{
            .id = model.id,
            .description = if (model.card_data) |cd| cd.description else null,
            .author = model.author,
            .gguf_files = gguf_files,
            .last_modified = model.last_modified,
            .downloads = model.downloads,
            .likes = model.likes,
            .tags = model.tags,
        };
    }
};

/// User information from HuggingFace API
pub const User = struct {
    /// Username
    username: []const u8,
    /// Display name
    name: ?[]const u8 = null,
    /// Full name
    fullname: ?[]const u8 = null,
    /// Avatar URL
    avatar_url: ?[]const u8 = null,
    /// Email (if available)
    email: ?[]const u8 = null,
    /// Whether email is verified
    email_verified: bool = false,
    /// Account type
    account_type: ?[]const u8 = null,
    /// Whether user is pro
    is_pro: bool = false,

    pub fn deinit(self: *User, allocator: Allocator) void {
        allocator.free(self.username);
        if (self.name) |n| allocator.free(n);
        if (self.fullname) |fn_| allocator.free(fn_);
        if (self.avatar_url) |au| allocator.free(au);
        if (self.email) |e| allocator.free(e);
        if (self.account_type) |at| allocator.free(at);
    }
};

/// Download item for batch operations
pub const DownloadItem = struct {
    /// Repository ID (e.g., "meta-llama/Llama-2-7b")
    repo_id: []const u8,
    /// Filename to download
    filename: []const u8,
    /// Output directory
    output_dir: []const u8,
    /// Revision/branch (default: "main")
    revision: []const u8 = "main",
};

/// Download status
pub const DownloadStatus = enum {
    pending,
    downloading,
    success,
    failed,
    skipped,
    cached,
};

/// Download result
pub const DownloadResult = struct {
    /// The download item
    item: DownloadItem,
    /// Status of the download
    status: DownloadStatus,
    /// Final file path (if successful)
    path: ?[]const u8 = null,
    /// Error message (if failed)
    error_message: ?[]const u8 = null,
    /// Bytes downloaded
    bytes_downloaded: u64 = 0,
    /// Total bytes
    total_bytes: ?u64 = null,
};

/// Download progress information
pub const DownloadProgress = struct {
    /// Bytes downloaded so far
    bytes_downloaded: u64,
    /// Total bytes to download (null if unknown)
    total_bytes: ?u64,
    /// Start time in nanoseconds
    start_time_ns: i128,
    /// Current time in nanoseconds
    current_time_ns: i128,
    /// Filename being downloaded
    filename: []const u8 = "",
    /// Index in batch (for concurrent downloads)
    batch_index: ?u32 = null,

    /// Calculate percentage complete (0-100)
    pub fn percentComplete(self: DownloadProgress) u8 {
        if (self.total_bytes) |total| {
            if (total == 0) return 100;
            const pct = (self.bytes_downloaded * 100) / total;
            return @intCast(@min(pct, 100));
        }
        return 0;
    }

    /// Calculate download speed in bytes per second
    pub fn downloadSpeed(self: DownloadProgress) f64 {
        const elapsed_ns = self.current_time_ns - self.start_time_ns;
        if (elapsed_ns <= 0) return 0;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.bytes_downloaded)) / elapsed_sec;
    }

    /// Estimate time remaining in seconds
    pub fn estimatedTimeRemaining(self: DownloadProgress) ?f64 {
        if (self.total_bytes) |total| {
            const remaining = total - self.bytes_downloaded;
            const speed = self.downloadSpeed();
            if (speed > 0) {
                return @as(f64, @floatFromInt(remaining)) / speed;
            }
        }
        return null;
    }

    /// Format speed as human-readable string
    pub fn formatSpeed(self: DownloadProgress, buf: []u8) []const u8 {
        const speed = self.downloadSpeed();
        return formatBytesPerSecond(speed, buf);
    }

    /// Format ETA as human-readable string
    pub fn formatEta(self: DownloadProgress, buf: []u8) []const u8 {
        if (self.estimatedTimeRemaining()) |eta| {
            return formatDuration(eta, buf);
        }
        return "unknown";
    }
};

/// Progress callback function type
pub const ProgressCallback = *const fn (progress: DownloadProgress) void;

// ============================================================================
// Utility Functions
// ============================================================================

/// Format bytes as human-readable string (e.g., "1.5 GB")
pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    var value: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (value >= 1024 and unit_idx < units.len - 1) {
        value /= 1024;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2} {s}", .{ value, units[unit_idx] }) catch "?";
    }
}

/// Format bytes per second as human-readable string
pub fn formatBytesPerSecond(bytes_per_sec: f64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B/s", "KB/s", "MB/s", "GB/s" };
    var value: f64 = bytes_per_sec;
    var unit_idx: usize = 0;

    while (value >= 1024 and unit_idx < units.len - 1) {
        value /= 1024;
        unit_idx += 1;
    }

    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit_idx] }) catch "?";
}

/// Format duration in seconds as human-readable string
pub fn formatDuration(seconds: f64, buf: []u8) []const u8 {
    if (seconds < 0) return "unknown";

    const total_secs: u64 = @intFromFloat(seconds);
    const hours = total_secs / 3600;
    const mins = (total_secs % 3600) / 60;
    const secs = total_secs % 60;

    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ hours, mins, secs }) catch "?";
    } else if (mins > 0) {
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ mins, secs }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "?";
    }
}

// ============================================================================
// Tests
// ============================================================================

test "FileInfo.checkIsGguf" {
    try std.testing.expect(FileInfo.checkIsGguf("model.gguf"));
    try std.testing.expect(FileInfo.checkIsGguf("some/path/model.gguf"));
    try std.testing.expect(FileInfo.checkIsGguf("MODEL.GGUF"));
    try std.testing.expect(!FileInfo.checkIsGguf("model.bin"));
    try std.testing.expect(!FileInfo.checkIsGguf("model.safetensors"));
    try std.testing.expect(!FileInfo.checkIsGguf("gguf.txt"));
}

test "formatBytes" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("0 B", formatBytes(0, &buf));
    try std.testing.expectEqualStrings("100 B", formatBytes(100, &buf));
    try std.testing.expectEqualStrings("1.00 KB", formatBytes(1024, &buf));
    try std.testing.expectEqualStrings("1.50 MB", formatBytes(1024 * 1024 + 512 * 1024, &buf));
    try std.testing.expectEqualStrings("1.00 GB", formatBytes(1024 * 1024 * 1024, &buf));
}

test "formatDuration" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("0s", formatDuration(0, &buf));
    try std.testing.expectEqualStrings("45s", formatDuration(45, &buf));
    try std.testing.expectEqualStrings("5m 30s", formatDuration(330, &buf));
    try std.testing.expectEqualStrings("1h 30m 45s", formatDuration(5445, &buf));
}

test "SortOrder.toString" {
    try std.testing.expectEqualStrings("downloads", SortOrder.downloads.toString());
    try std.testing.expectEqualStrings("trendingScore", SortOrder.trending.toString());
}

test "RepoType.fromString" {
    try std.testing.expectEqual(RepoType.model, RepoType.fromString("model").?);
    try std.testing.expectEqual(RepoType.dataset, RepoType.fromString("dataset").?);
    try std.testing.expect(RepoType.fromString("invalid") == null);
}
