//! Files API operations for HuggingFace Hub
//!
//! This module provides operations for working with files in HuggingFace repositories,
//! including getting file metadata, listing files, and generating download URLs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const HttpClient = @import("../client.zig").HttpClient;
const Response = @import("../client.zig").Response;
const errors = @import("../errors.zig");
const HubError = errors.HubError;
const types = @import("../types.zig");
const FileInfo = types.FileInfo;

/// Files API for working with repository files
pub const FilesApi = struct {
    client: *HttpClient,
    allocator: Allocator,

    const Self = @This();

    /// Initialize the Files API
    pub fn init(client: *HttpClient, allocator: Allocator) Self {
        return Self{
            .client = client,
            .allocator = allocator,
        };
    }

    /// Get metadata for a specific file in a repository
    /// Uses HEAD request to get file size and other metadata without downloading
    pub fn getFileMetadata(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !FileInfo {
        // Build the resolve URL: /{repo_id}/resolve/{revision}/{filename}
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/resolve/{s}/{s}",
            .{ self.client.endpoint, repo_id, revision, filename },
        );
        defer self.allocator.free(url);

        var response = try self.client.head(url);
        defer response.deinit();

        if (!response.isSuccess()) {
            if (errors.errorFromStatus(response.status_code)) |err| {
                return err;
            }
            return HubError.InvalidResponse;
        }

        // Extract metadata from headers
        const content_length = response.getContentLength();
        const etag = response.getHeader("etag");

        return FileInfo{
            .filename = try self.allocator.dupe(u8, std.fs.path.basename(filename)),
            .path = try self.allocator.dupe(u8, filename),
            .size = content_length,
            .etag = if (etag) |e| try self.allocator.dupe(u8, e) else null,
            .is_gguf = FileInfo.checkIsGguf(filename),
            .is_lfs = content_length != null and content_length.? > 10 * 1024 * 1024, // Assume LFS for files > 10MB
        };
    }

    /// Check if a file exists in a repository
    pub fn fileExists(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !bool {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/resolve/{s}/{s}",
            .{ self.client.endpoint, repo_id, revision, filename },
        );
        defer self.allocator.free(url);

        var response = self.client.head(url) catch |err| {
            switch (err) {
                HubError.NotFound => return false,
                else => return err,
            }
        };
        defer response.deinit();

        return response.status_code == 200;
    }

    /// Build a download URL for a file
    /// The returned URL can be used for streaming downloads
    pub fn getDownloadUrl(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/resolve/{s}/{s}",
            .{ self.client.endpoint, repo_id, revision, filename },
        );
    }

    /// Get download URLs for multiple files
    pub fn getDownloadUrls(
        self: *Self,
        repo_id: []const u8,
        filenames: []const []const u8,
        revision: []const u8,
    ) ![][]u8 {
        var urls = try self.allocator.alloc([]u8, filenames.len);
        errdefer {
            for (urls[0..filenames.len]) |url| {
                self.allocator.free(url);
            }
            self.allocator.free(urls);
        }

        for (filenames, 0..) |filename, i| {
            urls[i] = try self.getDownloadUrl(repo_id, filename, revision);
        }

        return urls;
    }

    /// Get file size by making a HEAD request
    pub fn getFileSize(
        self: *Self,
        repo_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !?u64 {
        const metadata = try self.getFileMetadata(repo_id, filename, revision);
        defer {
            self.allocator.free(metadata.filename);
            self.allocator.free(metadata.path);
            if (metadata.etag) |e| self.allocator.free(e);
        }
        return metadata.size;
    }

    /// Filter files by extension
    pub fn filterByExtension(
        self: *Self,
        files: []const FileInfo,
        extension: []const u8,
    ) ![]FileInfo {
        var result = std.ArrayListUnmanaged(FileInfo){};
        errdefer result.deinit(self.allocator);

        for (files) |file| {
            if (std.mem.endsWith(u8, file.filename, extension) or
                std.mem.endsWith(u8, file.path, extension))
            {
                try result.append(self.allocator, file);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Get only GGUF files from a list
    pub fn filterGgufFiles(
        self: *Self,
        files: []const FileInfo,
    ) ![]FileInfo {
        var result = std.ArrayListUnmanaged(FileInfo){};
        errdefer result.deinit(self.allocator);

        for (files) |file| {
            if (file.is_gguf or FileInfo.checkIsGguf(file.path)) {
                try result.append(self.allocator, file);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Calculate total size of files
    pub fn calculateTotalSize(files: []const FileInfo) u64 {
        var total: u64 = 0;
        for (files) |file| {
            if (file.size) |size| {
                total += size;
            }
        }
        return total;
    }

    /// Sort files by size (ascending)
    pub fn sortBySize(files: []FileInfo) void {
        std.mem.sort(FileInfo, files, {}, struct {
            fn lessThan(_: void, a: FileInfo, b: FileInfo) bool {
                const a_size = a.size orelse 0;
                const b_size = b.size orelse 0;
                return a_size < b_size;
            }
        }.lessThan);
    }

    /// Sort files by name (alphabetically)
    pub fn sortByName(files: []FileInfo) void {
        std.mem.sort(FileInfo, files, {}, struct {
            fn lessThan(_: void, a: FileInfo, b: FileInfo) bool {
                return std.mem.lessThan(u8, a.filename, b.filename);
            }
        }.lessThan);
    }
};

/// Utility to parse LFS pointer files
pub const LfsPointer = struct {
    version: []const u8,
    oid: []const u8,
    size: u64,

    /// Check if content looks like an LFS pointer
    pub fn isLfsPointer(content: []const u8) bool {
        return std.mem.startsWith(u8, content, "version https://git-lfs.github.com/spec/");
    }

    /// Parse LFS pointer content
    pub fn parse(allocator: Allocator, content: []const u8) !?LfsPointer {
        if (!isLfsPointer(content)) {
            return null;
        }

        var version: ?[]const u8 = null;
        var oid: ?[]const u8 = null;
        var size: ?u64 = null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "version ")) {
                version = try allocator.dupe(u8, line[8..]);
            } else if (std.mem.startsWith(u8, line, "oid sha256:")) {
                oid = try allocator.dupe(u8, line[11..]);
            } else if (std.mem.startsWith(u8, line, "size ")) {
                size = std.fmt.parseInt(u64, line[5..], 10) catch null;
            }
        }

        if (version != null and oid != null and size != null) {
            return LfsPointer{
                .version = version.?,
                .oid = oid.?,
                .size = size.?,
            };
        }

        // Clean up partial allocations
        if (version) |v| allocator.free(v);
        if (oid) |o| allocator.free(o);

        return null;
    }

    pub fn deinit(self: *LfsPointer, allocator: Allocator) void {
        allocator.free(self.version);
        allocator.free(self.oid);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FileInfo.checkIsGguf" {
    try std.testing.expect(FileInfo.checkIsGguf("model.gguf"));
    try std.testing.expect(FileInfo.checkIsGguf("path/to/model.gguf"));
    try std.testing.expect(FileInfo.checkIsGguf("MODEL.GGUF"));
    try std.testing.expect(!FileInfo.checkIsGguf("model.bin"));
    try std.testing.expect(!FileInfo.checkIsGguf("model.safetensors"));
}

test "FilesApi.calculateTotalSize" {
    const files = [_]FileInfo{
        .{ .filename = "a.gguf", .path = "a.gguf", .size = 1000 },
        .{ .filename = "b.gguf", .path = "b.gguf", .size = 2000 },
        .{ .filename = "c.gguf", .path = "c.gguf", .size = null },
    };

    const total = FilesApi.calculateTotalSize(&files);
    try std.testing.expectEqual(@as(u64, 3000), total);
}

test "LfsPointer.isLfsPointer" {
    const lfs_content =
        \\version https://git-lfs.github.com/spec/v1
        \\oid sha256:abc123
        \\size 1024
    ;
    try std.testing.expect(LfsPointer.isLfsPointer(lfs_content));
    try std.testing.expect(!LfsPointer.isLfsPointer("regular file content"));
}

test "LfsPointer.parse" {
    const allocator = std.testing.allocator;
    const lfs_content =
        \\version https://git-lfs.github.com/spec/v1
        \\oid sha256:abc123def456
        \\size 1048576
    ;

    var pointer = (try LfsPointer.parse(allocator, lfs_content)).?;
    defer pointer.deinit(allocator);

    try std.testing.expectEqualStrings("https://git-lfs.github.com/spec/v1", pointer.version);
    try std.testing.expectEqualStrings("abc123def456", pointer.oid);
    try std.testing.expectEqual(@as(u64, 1048576), pointer.size);
}

test "FilesApi.sortBySize" {
    var files = [_]FileInfo{
        .{ .filename = "large.gguf", .path = "large.gguf", .size = 5000 },
        .{ .filename = "small.gguf", .path = "small.gguf", .size = 100 },
        .{ .filename = "medium.gguf", .path = "medium.gguf", .size = 1000 },
    };

    FilesApi.sortBySize(&files);

    try std.testing.expectEqualStrings("small.gguf", files[0].filename);
    try std.testing.expectEqualStrings("medium.gguf", files[1].filename);
    try std.testing.expectEqualStrings("large.gguf", files[2].filename);
}

test "FilesApi.sortByName" {
    var files = [_]FileInfo{
        .{ .filename = "charlie.gguf", .path = "charlie.gguf" },
        .{ .filename = "alpha.gguf", .path = "alpha.gguf" },
        .{ .filename = "bravo.gguf", .path = "bravo.gguf" },
    };

    FilesApi.sortByName(&files);

    try std.testing.expectEqualStrings("alpha.gguf", files[0].filename);
    try std.testing.expectEqualStrings("bravo.gguf", files[1].filename);
    try std.testing.expectEqualStrings("charlie.gguf", files[2].filename);
}
