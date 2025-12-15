//! Models API for HuggingFace Hub
//!
//! This module provides operations for searching, listing, and retrieving
//! information about models on the HuggingFace Hub.

const std = @import("std");
const Allocator = std.mem.Allocator;

const client_mod = @import("../client.zig");
const HttpClient = client_mod.HttpClient;
const QueryParam = client_mod.QueryParam;
const buildQueryString = client_mod.buildQueryString;
const urlEncode = client_mod.urlEncode;
const errors = @import("../errors.zig");
const HubError = errors.HubError;
const ErrorContext = errors.ErrorContext;
const json = @import("../json.zig");
const RawModel = json.RawModel;
const types = @import("../types.zig");
const Model = types.Model;
const ModelInfo = types.ModelInfo;
const FileInfo = types.FileInfo;
const SearchQuery = types.SearchQuery;
const SearchResult = types.SearchResult;
const Sibling = types.Sibling;

/// Models API client
pub const ModelsApi = struct {
    allocator: Allocator,
    client: *HttpClient,

    const Self = @This();

    /// Initialize the Models API
    pub fn init(allocator: Allocator, http_client: *HttpClient) Self {
        return Self{
            .allocator = allocator,
            .client = http_client,
        };
    }

    /// Search for models on HuggingFace Hub
    pub fn search(self: *Self, query: SearchQuery) !SearchResult {
        // Build query string directly to avoid buffer lifetime issues
        var query_parts = std.array_list.Managed(u8).init(self.allocator);
        defer query_parts.deinit();

        const writer = query_parts.writer();

        // Search text
        if (query.search.len > 0) {
            const encoded_search = try urlEncode(self.allocator, query.search);
            defer self.allocator.free(encoded_search);
            try writer.print("search={s}", .{encoded_search});
        }

        // Author filter
        if (query.author) |author| {
            if (query_parts.items.len > 0) try writer.writeByte('&');
            const encoded_author = try urlEncode(self.allocator, author);
            defer self.allocator.free(encoded_author);
            try writer.print("author={s}", .{encoded_author});
        }

        // Filter string (e.g., "gguf")
        if (query.filter) |filter| {
            if (query_parts.items.len > 0) try writer.writeByte('&');
            const encoded_filter = try urlEncode(self.allocator, filter);
            defer self.allocator.free(encoded_filter);
            try writer.print("filter={s}", .{encoded_filter});
        }

        // Sort order
        if (query_parts.items.len > 0) try writer.writeByte('&');
        try writer.print("sort={s}", .{query.sort.toString()});

        // Limit
        if (query_parts.items.len > 0) try writer.writeByte('&');
        try writer.print("limit={d}", .{query.limit});

        // Offset (skip)
        if (query.offset > 0) {
            if (query_parts.items.len > 0) try writer.writeByte('&');
            try writer.print("skip={d}", .{query.offset});
        }

        // Full info
        if (query.full) {
            if (query_parts.items.len > 0) try writer.writeByte('&');
            try writer.writeAll("full=true");
        }

        // Config info
        if (query.config) {
            if (query_parts.items.len > 0) try writer.writeByte('&');
            try writer.writeAll("config=true");
        }

        // Get query string
        const query_string = try query_parts.toOwnedSlice();
        defer self.allocator.free(query_string);

        // Make request
        var response = try self.client.get("/api/models", query_string);
        defer response.deinit();

        // Check status
        if (!response.isSuccess()) {
            return errors.errorFromStatus(response.status_code) orelse HubError.InvalidResponse;
        }

        // Parse response - it's an array of models
        var parsed = std.json.parseFromSlice(
            []RawModel,
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch {
            return HubError.InvalidJson;
        };
        defer parsed.deinit();

        // Convert to domain types
        var models = std.array_list.Managed(Model).init(self.allocator);
        errdefer {
            for (models.items) |*m| {
                m.deinit(self.allocator);
            }
            models.deinit();
        }

        for (parsed.value) |raw_model| {
            const model = try json.toModel(self.allocator, raw_model);
            try models.append(model);
        }

        return SearchResult{
            .models = try models.toOwnedSlice(),
            .total = null, // API doesn't return total count
            .limit = query.limit,
            .offset = query.offset,
        };
    }

    /// Search specifically for GGUF models
    pub fn searchGguf(self: *Self, search_text: []const u8, limit: u32) !SearchResult {
        const query = SearchQuery{
            .search = search_text,
            .filter = "gguf",
            .limit = limit,
            .full = true,
        };
        return self.search(query);
    }

    /// Get detailed information about a specific model
    pub fn getModel(self: *Self, model_id: []const u8) !Model {
        // Build path
        const path = try std.fmt.allocPrint(self.allocator, "/api/models/{s}", .{model_id});
        defer self.allocator.free(path);

        // Make request
        var response = try self.client.get(path, null);
        defer response.deinit();

        // Check status
        if (!response.isSuccess()) {
            return errors.errorFromStatus(response.status_code) orelse HubError.InvalidResponse;
        }

        // Parse response
        var parsed = std.json.parseFromSlice(
            RawModel,
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch {
            return HubError.InvalidJson;
        };
        defer parsed.deinit();

        // Convert to domain type
        return json.toModel(self.allocator, parsed.value);
    }

    /// Get extended model info (includes repo type, readme, etc.)
    pub fn getModelInfo(self: *Self, model_id: []const u8) !ModelInfo {
        const model = try self.getModel(model_id);
        return ModelInfo{
            .model = model,
            .repo_type = .model,
            .description = if (model.card_data) |cd| cd.description else null,
            .readme = null, // Would need separate API call to fetch
        };
    }

    /// List all files in a model repository
    pub fn listFiles(self: *Self, model_id: []const u8) ![]FileInfo {
        const model = try self.getModel(model_id);
        defer {
            var m = model;
            m.deinit(self.allocator);
        }

        var files = std.array_list.Managed(FileInfo).init(self.allocator);
        errdefer files.deinit();

        for (model.siblings) |sibling| {
            const file_info = FileInfo{
                .filename = try self.allocator.dupe(u8, std.fs.path.basename(sibling.rfilename)),
                .path = try self.allocator.dupe(u8, sibling.rfilename),
                .size = sibling.size,
                .blob_id = if (sibling.blob_id) |bid| try self.allocator.dupe(u8, bid) else null,
                .is_gguf = FileInfo.checkIsGguf(sibling.rfilename),
            };
            try files.append(file_info);
        }

        return files.toOwnedSlice();
    }

    /// List only GGUF files in a model repository
    pub fn listGgufFiles(self: *Self, model_id: []const u8) ![]FileInfo {
        const all_files = try self.listFiles(model_id);
        defer {
            for (all_files) |*f| {
                var file = f.*;
                file.deinit(self.allocator);
            }
            self.allocator.free(all_files);
        }

        var gguf_files = std.array_list.Managed(FileInfo).init(self.allocator);
        errdefer gguf_files.deinit();

        for (all_files) |file| {
            if (file.is_gguf) {
                const file_copy = FileInfo{
                    .filename = try self.allocator.dupe(u8, file.filename),
                    .path = try self.allocator.dupe(u8, file.path),
                    .size = file.size,
                    .blob_id = if (file.blob_id) |bid| try self.allocator.dupe(u8, bid) else null,
                    .is_gguf = true,
                };
                try gguf_files.append(file_copy);
            }
        }

        return gguf_files.toOwnedSlice();
    }

    /// Check if a model exists
    pub fn modelExists(self: *Self, model_id: []const u8) !bool {
        const path = try std.fmt.allocPrint(self.allocator, "/api/models/{s}", .{model_id});
        defer self.allocator.free(path);

        var response = self.client.head(path) catch |err| {
            if (err == HubError.NotFound) return false;
            return err;
        };
        defer response.deinit();

        return response.status_code == 200;
    }

    /// Check if a model has any GGUF files
    pub fn hasGgufFiles(self: *Self, model_id: []const u8) !bool {
        const model = try self.getModel(model_id);
        defer {
            var m = model;
            m.deinit(self.allocator);
        }
        return model.hasGgufFiles();
    }

    /// Get file metadata (size, etag) via HEAD request
    pub fn getFileMetadata(self: *Self, model_id: []const u8, filename: []const u8, revision: []const u8) !FileInfo {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/resolve/{s}/{s}",
            .{ model_id, revision, filename },
        );
        defer self.allocator.free(url);

        var response = try self.client.head(url);
        defer response.deinit();

        if (!response.isSuccess()) {
            return errors.errorFromStatus(response.status_code) orelse HubError.InvalidResponse;
        }

        return FileInfo{
            .filename = try self.allocator.dupe(u8, std.fs.path.basename(filename)),
            .path = try self.allocator.dupe(u8, filename),
            .size = response.getContentLength(),
            .etag = if (response.getHeader("etag")) |etag| try self.allocator.dupe(u8, etag) else null,
            .is_gguf = FileInfo.checkIsGguf(filename),
        };
    }

    /// Get the download URL for a file
    pub fn getDownloadUrl(self: *Self, model_id: []const u8, filename: []const u8, revision: []const u8) ![]u8 {
        return self.client.buildDownloadUrl(model_id, filename, revision);
    }
};

/// Free a slice of FileInfo
pub fn freeFileInfoSlice(allocator: Allocator, files: []FileInfo) void {
    for (files) |*f| {
        var file = f.*;
        file.deinit(allocator);
    }
    allocator.free(files);
}

/// Free a SearchResult
pub fn freeSearchResult(allocator: Allocator, result: *SearchResult) void {
    result.deinit(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "SearchQuery defaults" {
    const query = SearchQuery{};
    try std.testing.expectEqual(@as(u32, 20), query.limit);
    try std.testing.expectEqual(@as(u32, 0), query.offset);
    try std.testing.expect(!query.full);
}

test "FileInfo.checkIsGguf" {
    try std.testing.expect(FileInfo.checkIsGguf("model.gguf"));
    try std.testing.expect(FileInfo.checkIsGguf("path/to/model.gguf"));
    try std.testing.expect(!FileInfo.checkIsGguf("model.bin"));
    try std.testing.expect(!FileInfo.checkIsGguf("model.safetensors"));
}
