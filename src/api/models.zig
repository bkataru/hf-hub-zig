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
const ParsedModel = json.ParsedModel;
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
        // Build query string
        var query_parts = std.ArrayListUnmanaged(u8){};
        defer query_parts.deinit(self.allocator);

        const writer = query_parts.writer(self.allocator);

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

        // Build full URL
        const query_string = query_parts.items;
        const url = if (query_string.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}/api/models?{s}", .{ self.client.endpoint, query_string })
        else
            try std.fmt.allocPrint(self.allocator, "{s}/api/models", .{self.client.endpoint});
        defer self.allocator.free(url);

        // Make request
        var response = try self.client.get(url);
        defer response.deinit();

        // Check status
        if (!response.isSuccess()) {
            return errors.errorFromStatus(response.status_code) orelse HubError.InvalidResponse;
        }

        // Parse response using flexible JSON parsing
        const parsed_models = json.parseModels(self.allocator, response.body) catch {
            return HubError.InvalidJson;
        };
        defer self.allocator.free(parsed_models);

        // Convert to domain types
        var models = std.ArrayListUnmanaged(Model){};
        errdefer {
            for (models.items) |*m| {
                m.deinit(self.allocator);
            }
            models.deinit(self.allocator);
        }

        for (parsed_models) |*parsed_model| {
            const model = try json.toModel(self.allocator, parsed_model.*);
            // Free the parsed model fields now that we've copied to domain type
            json.freeModelFields(self.allocator, parsed_model);
            try models.append(self.allocator, model);
        }

        return SearchResult{
            .models = try models.toOwnedSlice(self.allocator),
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
        // Build full URL
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/models/{s}", .{ self.client.endpoint, model_id });
        defer self.allocator.free(url);

        // Make request
        var response = try self.client.get(url);
        defer response.deinit();

        // Check status
        if (!response.isSuccess()) {
            return errors.errorFromStatus(response.status_code) orelse HubError.InvalidResponse;
        }

        // Parse response using flexible JSON parsing
        var parsed_model = json.parseModel(self.allocator, response.body) catch {
            return HubError.InvalidJson;
        };

        // Convert to domain type
        const model = try json.toModel(self.allocator, parsed_model);

        // Free the parsed model fields now that we've copied to domain type
        json.freeModelFields(self.allocator, &parsed_model);

        return model;
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

        var files = std.ArrayListUnmanaged(FileInfo){};
        errdefer files.deinit(self.allocator);

        for (model.siblings) |sibling| {
            const file_info = FileInfo{
                .filename = try self.allocator.dupe(u8, std.fs.path.basename(sibling.rfilename)),
                .path = try self.allocator.dupe(u8, sibling.rfilename),
                .size = sibling.size,
                .blob_id = if (sibling.blob_id) |bid| try self.allocator.dupe(u8, bid) else null,
                .is_gguf = FileInfo.checkIsGguf(sibling.rfilename),
            };
            try files.append(self.allocator, file_info);
        }

        return files.toOwnedSlice(self.allocator);
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

        var gguf_files = std.ArrayListUnmanaged(FileInfo){};
        errdefer gguf_files.deinit(self.allocator);

        for (all_files) |file| {
            if (file.is_gguf) {
                const file_copy = FileInfo{
                    .filename = try self.allocator.dupe(u8, file.filename),
                    .path = try self.allocator.dupe(u8, file.path),
                    .size = file.size,
                    .blob_id = if (file.blob_id) |bid| try self.allocator.dupe(u8, bid) else null,
                    .is_gguf = true,
                };
                try gguf_files.append(self.allocator, file_copy);
            }
        }

        return gguf_files.toOwnedSlice(self.allocator);
    }

    /// Check if a model exists
    pub fn modelExists(self: *Self, model_id: []const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/models/{s}", .{ self.client.endpoint, model_id });
        defer self.allocator.free(url);

        var response = self.client.head(url) catch |err| {
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
            "{s}/{s}/resolve/{s}/{s}",
            .{ self.client.endpoint, model_id, revision, filename },
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
