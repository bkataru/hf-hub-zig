//! File Downloader with streaming, progress tracking, and resume support
//!
//! This module provides efficient file downloads with:
//! - Streaming to disk (no loading entire file into memory)
//! - Resumable downloads using Range headers
//! - Progress callbacks with real-time statistics
//! - Configurable chunk sizes and timeouts

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

const client_mod = @import("client.zig");
const HttpClient = client_mod.HttpClient;
const Config = @import("config.zig").Config;
const errors = @import("errors.zig");
const HubError = errors.HubError;
const types = @import("types.zig");
const DownloadProgress = types.DownloadProgress;
const ProgressCallback = types.ProgressCallback;

/// Download options configuration
pub const DownloadOptions = struct {
    /// Whether to resume partial downloads
    resume_download: bool = true,
    /// Chunk size for reading (default 8KB)
    chunk_size: u32 = 8192,
    /// Whether to verify SHA256 checksum (if available)
    verify_checksum: bool = false,
    /// Expected SHA256 hash (optional)
    expected_sha256: ?[]const u8 = null,
    /// Timeout per chunk in milliseconds
    chunk_timeout_ms: u32 = 30_000,
    /// Whether to create parent directories
    create_dirs: bool = true,
    /// Suffix for partial download files
    part_suffix: []const u8 = ".part",
};

/// Result of a download operation
pub const DownloadResult = struct {
    /// Final path of the downloaded file
    path: []const u8,
    /// Total bytes downloaded in this session
    bytes_downloaded: u64,
    /// Total file size
    total_size: u64,
    /// Whether the download was resumed
    was_resumed: bool,
    /// Whether checksum was verified
    checksum_verified: bool,
    /// SHA256 hash of the file (if computed)
    sha256: ?[64]u8 = null,

    pub fn deinit(self: *DownloadResult, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

/// Context for progress callback during download
const ProgressContext = struct {
    callback: ?ProgressCallback,
    filename: []const u8,
    start_time_ns: i128,
    start_byte: u64,
};

/// Progress callback function that bridges to user callback
fn progressBridge(ctx: *const ProgressContext, bytes_so_far: u64, total: ?u64) void {
    if (ctx.callback) |cb| {
        const progress = DownloadProgress{
            .bytes_downloaded = bytes_so_far,
            .total_bytes = total,
            .start_time_ns = ctx.start_time_ns,
            .current_time_ns = std.time.nanoTimestamp(),
            .filename = ctx.filename,
        };
        cb(progress);
    }
}

/// File downloader with streaming and progress support
pub const Downloader = struct {
    allocator: Allocator,
    client: *HttpClient,
    options: DownloadOptions,

    const Self = @This();

    /// Initialize a new downloader
    pub fn init(allocator: Allocator, http_client: *HttpClient) Self {
        return Self{
            .allocator = allocator,
            .client = http_client,
            .options = .{},
        };
    }

    /// Initialize with custom options
    pub fn initWithOptions(allocator: Allocator, http_client: *HttpClient, options: DownloadOptions) Self {
        return Self{
            .allocator = allocator,
            .client = http_client,
            .options = options,
        };
    }

    /// Download a file from a URL to the specified output path
    /// Returns the final file size
    pub fn download(
        self: *Self,
        url: []const u8,
        output_path: []const u8,
        progress_cb: ?ProgressCallback,
    ) !DownloadResult {
        return self.downloadWithOptions(url, output_path, progress_cb, self.options);
    }

    /// Download with custom options
    pub fn downloadWithOptions(
        self: *Self,
        url: []const u8,
        output_path: []const u8,
        progress_cb: ?ProgressCallback,
        options: DownloadOptions,
    ) !DownloadResult {
        // Create parent directories if needed
        if (options.create_dirs) {
            if (std.fs.path.dirname(output_path)) |dir| {
                fs.cwd().makePath(dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return HubError.IoError,
                };
            }
        }

        // Check for existing partial download
        const part_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ output_path, options.part_suffix });
        defer self.allocator.free(part_path);

        var start_byte: u64 = 0;
        var was_resumed = false;

        // Check if we should resume
        if (options.resume_download) {
            if (fs.cwd().statFile(part_path)) |stat| {
                start_byte = stat.size;
                was_resumed = true;
            } else |_| {
                // No partial file, start from beginning
            }
        }

        // Open output file (append if resuming, create otherwise)
        var file = fs.cwd().openFile(part_path, .{
            .mode = .write_only,
        }) catch |err| switch (err) {
            error.FileNotFound => try fs.cwd().createFile(part_path, .{}),
            else => return HubError.IoError,
        };
        defer file.close();

        // Seek to end if resuming
        if (start_byte > 0) {
            file.seekTo(start_byte) catch return HubError.IoError;
        }

        // Set up progress context
        const start_time = std.time.nanoTimestamp();
        const ctx = ProgressContext{
            .callback = progress_cb,
            .filename = std.fs.path.basename(output_path),
            .start_time_ns = start_time,
            .start_byte = start_byte,
        };

        // Perform the download
        const result = try self.client.downloadToFileWithProgress(
            url,
            file,
            if (start_byte > 0) start_byte else null,
            &ctx,
            progressBridge,
        );

        // Rename .part file to final filename
        fs.cwd().rename(part_path, output_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Delete existing file and retry
                fs.cwd().deleteFile(output_path) catch {};
                fs.cwd().rename(part_path, output_path) catch return HubError.IoError;
            },
            else => return HubError.IoError,
        };

        return DownloadResult{
            .path = try self.allocator.dupe(u8, output_path),
            .bytes_downloaded = result.bytes_downloaded,
            .total_size = start_byte + result.bytes_downloaded,
            .was_resumed = was_resumed,
            .checksum_verified = false,
        };
    }

    /// Download a file from a HuggingFace repository
    pub fn downloadFromRepo(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        output_dir: []const u8,
        revision: []const u8,
        progress_cb: ?ProgressCallback,
    ) !DownloadResult {
        // Build the download URL
        const url = try self.client.buildDownloadUrl(repo_id, filename, revision);
        defer self.allocator.free(url);

        // Build output path
        const output_path = try std.fs.path.join(self.allocator, &.{ output_dir, filename });
        defer self.allocator.free(output_path);

        return self.download(url, output_path, progress_cb);
    }

    /// Check if a partial download exists for a file
    pub fn hasPartialDownload(self: *Self, output_path: []const u8) !bool {
        const part_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ output_path, self.options.part_suffix });
        defer self.allocator.free(part_path);

        if (fs.cwd().statFile(part_path)) |_| {
            return true;
        } else |_| {
            return false;
        }
    }

    /// Get the size of an existing partial download
    pub fn getPartialSize(self: *Self, output_path: []const u8) !?u64 {
        const part_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ output_path, self.options.part_suffix });
        defer self.allocator.free(part_path);

        if (fs.cwd().statFile(part_path)) |stat| {
            return stat.size;
        } else |_| {
            return null;
        }
    }

    /// Delete a partial download file
    pub fn deletePartial(self: *Self, output_path: []const u8) !void {
        const part_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ output_path, self.options.part_suffix });
        defer self.allocator.free(part_path);

        fs.cwd().deleteFile(part_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return HubError.IoError,
        };
    }

    /// Verify a downloaded file's checksum
    pub fn verifyChecksum(self: *Self, file_path: []const u8, expected_sha256: []const u8) !bool {
        _ = self;

        var file = fs.cwd().openFile(file_path, .{}) catch return HubError.IoError;
        defer file.close();

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [8192]u8 = undefined;

        while (true) {
            const bytes_read = file.read(&buf) catch return HubError.IoError;
            if (bytes_read == 0) break;
            hasher.update(buf[0..bytes_read]);
        }

        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        // Convert to hex string
        var hex_buf: [64]u8 = undefined;
        const hex_hash = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch return false;

        return std.mem.eql(u8, hex_hash, expected_sha256);
    }
};

/// Simple progress printer for CLI use
pub fn defaultProgressCallback(progress: DownloadProgress) void {
    const percent = progress.percentComplete();
    var speed_buf: [32]u8 = undefined;
    var eta_buf: [32]u8 = undefined;

    const speed = progress.formatSpeed(&speed_buf);
    const eta = progress.formatEta(&eta_buf);

    var size_buf: [32]u8 = undefined;
    const downloaded = types.formatBytes(progress.bytes_downloaded, &size_buf);

    if (progress.total_bytes) |total| {
        var total_buf: [32]u8 = undefined;
        const total_str = types.formatBytes(total, &total_buf);

        std.debug.print("\r{s}: {s}/{s} ({d}%) - {s} - ETA: {s}    ", .{
            progress.filename,
            downloaded,
            total_str,
            percent,
            speed,
            eta,
        });
    } else {
        std.debug.print("\r{s}: {s} - {s}    ", .{
            progress.filename,
            downloaded,
            speed,
        });
    }
}

/// Batch downloader for multiple files
pub const BatchDownloader = struct {
    allocator: Allocator,
    downloader: Downloader,
    results: std.ArrayList(BatchResult),

    pub const BatchResult = struct {
        filename: []const u8,
        success: bool,
        result: ?DownloadResult,
        error_message: ?[]const u8,

        pub fn deinit(self: *BatchResult, allocator: Allocator) void {
            allocator.free(self.filename);
            if (self.result) |*r| {
                var res = r.*;
                res.deinit(allocator);
            }
            if (self.error_message) |msg| {
                allocator.free(msg);
            }
        }
    };

    pub fn init(allocator: Allocator, http_client: *HttpClient) BatchDownloader {
        return BatchDownloader{
            .allocator = allocator,
            .downloader = Downloader.init(allocator, http_client),
            .results = std.ArrayList(BatchResult).init(allocator),
        };
    }

    pub fn deinit(self: *BatchDownloader) void {
        for (self.results.items) |*r| {
            r.deinit(self.allocator);
        }
        self.results.deinit();
    }

    /// Download multiple files sequentially
    pub fn downloadAll(
        self: *BatchDownloader,
        items: []const types.DownloadItem,
        progress_cb: ?ProgressCallback,
    ) ![]BatchResult {
        for (items) |item| {
            const result = self.downloadOne(item, progress_cb);
            try self.results.append(result);
        }

        return self.results.items;
    }

    fn downloadOne(self: *BatchDownloader, item: types.DownloadItem, progress_cb: ?ProgressCallback) BatchResult {
        const url = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/resolve/{s}/{s}",
            .{ self.downloader.client.endpoint, item.repo_id, item.revision, item.filename },
        ) catch {
            return BatchResult{
                .filename = self.allocator.dupe(u8, item.filename) catch item.filename,
                .success = false,
                .result = null,
                .error_message = self.allocator.dupe(u8, "Failed to allocate URL") catch null,
            };
        };
        defer self.allocator.free(url);

        const output_path = std.fs.path.join(self.allocator, &.{ item.output_dir, item.filename }) catch {
            return BatchResult{
                .filename = self.allocator.dupe(u8, item.filename) catch item.filename,
                .success = false,
                .result = null,
                .error_message = self.allocator.dupe(u8, "Failed to build output path") catch null,
            };
        };
        defer self.allocator.free(output_path);

        const download_result = self.downloader.download(url, output_path, progress_cb) catch |err| {
            return BatchResult{
                .filename = self.allocator.dupe(u8, item.filename) catch item.filename,
                .success = false,
                .result = null,
                .error_message = self.allocator.dupe(u8, @errorName(err)) catch null,
            };
        };

        return BatchResult{
            .filename = self.allocator.dupe(u8, item.filename) catch item.filename,
            .success = true,
            .result = download_result,
            .error_message = null,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DownloadOptions defaults" {
    const options = DownloadOptions{};
    try std.testing.expect(options.resume_download);
    try std.testing.expectEqual(@as(u32, 8192), options.chunk_size);
    try std.testing.expect(!options.verify_checksum);
    try std.testing.expectEqualStrings(".part", options.part_suffix);
}

test "DownloadProgress calculations" {
    const start = std.time.nanoTimestamp();
    std.Thread.sleep(10 * std.time.ns_per_ms); // Sleep 10ms

    const progress = DownloadProgress{
        .bytes_downloaded = 1024 * 1024, // 1 MB
        .total_bytes = 10 * 1024 * 1024, // 10 MB
        .start_time_ns = start,
        .current_time_ns = std.time.nanoTimestamp(),
        .filename = "test.gguf",
    };

    try std.testing.expectEqual(@as(u8, 10), progress.percentComplete());
    try std.testing.expect(progress.downloadSpeed() > 0);
    try std.testing.expect(progress.estimatedTimeRemaining() != null);
}

test "DownloadProgress formatSpeed" {
    const progress = DownloadProgress{
        .bytes_downloaded = 1024 * 1024,
        .total_bytes = 10 * 1024 * 1024,
        .start_time_ns = 0,
        .current_time_ns = std.time.ns_per_s, // 1 second elapsed
        .filename = "test.gguf",
    };

    var buf: [32]u8 = undefined;
    const speed = progress.formatSpeed(&buf);

    // Should be approximately 1 MB/s
    try std.testing.expect(speed.len > 0);
}
