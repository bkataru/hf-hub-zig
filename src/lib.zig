//! HuggingFace Hub Zig Client Library
//!
//! A complete, production-ready Zig library for interacting with the HuggingFace Hub API,
//! with focus on GGUF model discovery, searching, viewing, and downloading.
//!
//! ## Quick Start
//!
//! When using as a dependency, import as "hf-hub":
//!
//! ```zig
//! const hf = @import("hf-hub");
//!
//! var client = try hf.HubClient.init(allocator, null);
//! defer client.deinit();
//!
//! // Search for GGUF models
//! var results = try client.searchGgufModels("llama");
//! defer client.freeSearchResult(&results);
//!
//! // Download a model file
//! const path = try client.downloadFile("TheBloke/Llama-2-7B-GGUF", "llama-2-7b.Q4_K_M.gguf", null);
//! defer allocator.free(path);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const api = @import("api/mod.zig");
pub const async_ops = @import("async.zig");
pub const cache = @import("cache.zig");
pub const Cache = cache.Cache;
pub const CacheStats = cache.CacheStats;
pub const client = @import("client.zig");
pub const HttpClient = client.HttpClient;
pub const config = @import("config.zig");
pub const Config = config.Config;
pub const downloader = @import("downloader.zig");
pub const DownloadResult = downloader.DownloadResult;
pub const DownloadOptions = downloader.DownloadOptions;
pub const errors = @import("errors.zig");
pub const HubError = errors.HubError;
pub const ErrorContext = errors.ErrorContext;
pub const json = @import("json.zig");
pub const progress = @import("progress.zig");
pub const ProgressBar = progress.ProgressBar;
pub const retry = @import("retry.zig");
pub const RateLimiter = retry.RateLimiter;
pub const RetryStrategy = retry.RetryStrategy;
pub const terminal = @import("terminal.zig");
pub const Color = terminal.Color;
pub const types = @import("types.zig");
pub const Model = types.Model;
pub const ModelInfo = types.ModelInfo;
pub const FileInfo = types.FileInfo;
pub const SearchQuery = types.SearchQuery;
pub const SearchResult = types.SearchResult;
pub const GgufModel = types.GgufModel;
pub const DownloadProgress = types.DownloadProgress;
pub const DownloadItem = types.DownloadItem;
pub const DownloadStatus = types.DownloadStatus;
pub const ProgressCallback = types.ProgressCallback;
pub const SortOrder = types.SortOrder;
pub const SortDirection = types.SortDirection;
pub const formatBytes = types.formatBytes;
pub const formatBytesPerSecond = types.formatBytesPerSecond;

// Core modules
// Infrastructure
// API modules
// UI/Terminal modules
// Async/Concurrent operations
// Re-export key types for convenience
/// Main HuggingFace Hub client providing a unified interface for all operations
pub const HubClient = struct {
    allocator: Allocator,
    config: Config,
    http_client: HttpClient,
    models_api: api.ModelsApi,
    files_api: api.FilesApi,
    user_api: api.UserApi,
    file_cache: Cache,
    file_downloader: downloader.Downloader,
    rate_limiter: RateLimiter,
    config_owned: bool,

    const Self = @This();

    /// Initialize a new HubClient
    /// If config is null, uses environment variables and defaults
    pub fn init(allocator: Allocator, user_config: ?Config) !Self {
        var cfg: Config = undefined;
        var config_owned = false;

        if (user_config) |c| {
            cfg = c;
        } else {
            cfg = try Config.fromEnv(allocator);
            config_owned = true;
        }
        errdefer if (config_owned) {
            var c = cfg;
            c.deinit();
        };

        var http_client = try HttpClient.init(allocator, cfg);
        errdefer http_client.deinit();

        var file_cache = if (cfg.cache_dir) |cache_dir|
            try Cache.init(allocator, cache_dir)
        else
            try Cache.initDefault(allocator);
        errdefer file_cache.deinit();

        return Self{
            .allocator = allocator,
            .config = cfg,
            .http_client = http_client,
            .models_api = api.ModelsApi.init(allocator, &http_client),
            .files_api = api.FilesApi.init(&http_client, allocator),
            .user_api = api.UserApi.init(allocator, &http_client),
            .file_cache = file_cache,
            .file_downloader = downloader.Downloader.init(allocator, &http_client),
            .rate_limiter = RateLimiter.init(cfg.max_requests_per_second),
            .config_owned = config_owned,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
        self.file_cache.deinit();
        if (self.config_owned) {
            var cfg = self.config;
            cfg.deinit();
        }
    }

    // ========================================================================
    // High-Level Search Operations
    // ========================================================================

    /// Search for models on HuggingFace Hub
    pub fn search(self: *Self, query: SearchQuery) !SearchResult {
        // Acquire rate limit token
        _ = self.rate_limiter.acquire();

        // Use internal api reference properly
        var models_api = api.ModelsApi.init(self.allocator, &self.http_client);
        return models_api.search(query);
    }

    /// Search specifically for GGUF models
    pub fn searchGgufModels(self: *Self, query_text: []const u8) !SearchResult {
        return self.search(.{
            .search = query_text,
            .filter = "gguf",
            .full = true,
            .limit = 20,
        });
    }

    /// Search with pagination
    pub fn searchPaginated(
        self: *Self,
        query_text: []const u8,
        limit: u32,
        offset: u32,
    ) !SearchResult {
        return self.search(.{
            .search = query_text,
            .limit = limit,
            .offset = offset,
            .full = true,
        });
    }

    // ========================================================================
    // Model Information Operations
    // ========================================================================

    /// Get detailed information about a model
    pub fn getModelInfo(self: *Self, model_id: []const u8) !Model {
        _ = self.rate_limiter.acquire();
        var models_api = api.ModelsApi.init(self.allocator, &self.http_client);
        return models_api.getModel(model_id);
    }

    /// List all files in a model repository
    pub fn listFiles(self: *Self, model_id: []const u8) ![]FileInfo {
        _ = self.rate_limiter.acquire();
        var models_api = api.ModelsApi.init(self.allocator, &self.http_client);
        return models_api.listFiles(model_id);
    }

    /// List only GGUF files in a model repository
    pub fn listGgufFiles(self: *Self, model_id: []const u8) ![]FileInfo {
        _ = self.rate_limiter.acquire();
        var models_api = api.ModelsApi.init(self.allocator, &self.http_client);
        return models_api.listGgufFiles(model_id);
    }

    /// Check if a model exists
    pub fn modelExists(self: *Self, model_id: []const u8) !bool {
        _ = self.rate_limiter.acquire();
        var models_api = api.ModelsApi.init(self.allocator, &self.http_client);
        return models_api.modelExists(model_id);
    }

    /// Check if a model has GGUF files
    pub fn hasGgufFiles(self: *Self, model_id: []const u8) !bool {
        _ = self.rate_limiter.acquire();
        var models_api = api.ModelsApi.init(self.allocator, &self.http_client);
        return models_api.hasGgufFiles(model_id);
    }

    // ========================================================================
    // File Operations
    // ========================================================================

    /// Get file metadata (size, etc.) without downloading
    pub fn getFileMetadata(
        self: *Self,
        model_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !FileInfo {
        _ = self.rate_limiter.acquire();
        var files_api = api.FilesApi.init(&self.http_client, self.allocator);
        return files_api.getFileMetadata(model_id, filename, revision);
    }

    /// Check if a file exists in a repository
    pub fn fileExists(
        self: *Self,
        model_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !bool {
        _ = self.rate_limiter.acquire();
        var files_api = api.FilesApi.init(&self.http_client, self.allocator);
        return files_api.fileExists(model_id, filename, revision);
    }

    /// Get download URL for a file
    pub fn getDownloadUrl(
        self: *Self,
        model_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) ![]u8 {
        var files_api = api.FilesApi.init(&self.http_client, self.allocator);
        return files_api.getDownloadUrl(model_id, filename, revision);
    }

    // ========================================================================
    // Download Operations
    // ========================================================================

    /// Download a file from a model repository
    /// Returns the path to the downloaded file
    pub fn downloadFile(
        self: *Self,
        model_id: []const u8,
        filename: []const u8,
        progress_cb: ?ProgressCallback,
    ) ![]const u8 {
        return self.downloadFileWithOptions(model_id, filename, "main", null, progress_cb);
    }

    /// Download a file with full options
    pub fn downloadFileWithOptions(
        self: *Self,
        model_id: []const u8,
        filename: []const u8,
        revision: []const u8,
        output_dir: ?[]const u8,
        progress_cb: ?ProgressCallback,
    ) ![]const u8 {
        _ = self.rate_limiter.acquire();

        // Determine output directory
        const out_dir = output_dir orelse ".";

        // Check cache first
        if (try self.file_cache.isCached(model_id, filename, revision)) {
            const cached_path = try self.file_cache.getCachedFile(model_id, filename, revision);
            if (cached_path) |path| {
                return path;
            }
        }

        // Build URL
        const url = try self.http_client.buildDownloadUrl(model_id, filename, revision);
        defer self.allocator.free(url);

        // Build output path
        const output_path = try std.fs.path.join(self.allocator, &.{ out_dir, filename });
        // We duplicate for return; ensure we free the original before returning
        defer self.allocator.free(output_path);

        // Download
        var dl = downloader.Downloader.init(self.allocator, &self.http_client);
        var result = try dl.download(url, output_path, progress_cb);
        defer result.deinit(self.allocator);

        // Return a duplicate of the path (caller owns and must free)
        return try self.allocator.dupe(u8, output_path);
    }

    /// Download to cache directory
    pub fn downloadToCache(
        self: *Self,
        model_id: []const u8,
        filename: []const u8,
        revision: []const u8,
        progress_cb: ?ProgressCallback,
    ) ![]const u8 {
        _ = self.rate_limiter.acquire();

        // Check cache first
        if (try self.file_cache.getCachedFile(model_id, filename, revision)) |cached_path| {
            return cached_path;
        }

        // Prepare cache path
        const cache_path = try self.file_cache.prepareCachePath(model_id, filename, revision);
        // We will return a duplicate; free original to avoid leaks
        defer self.allocator.free(cache_path);

        // Build URL
        const url = try self.http_client.buildDownloadUrl(model_id, filename, revision);
        defer self.allocator.free(url);

        // Download
        var dl = downloader.Downloader.init(self.allocator, &self.http_client);
        var result = try dl.download(url, cache_path, progress_cb);
        defer result.deinit(self.allocator);

        return try self.allocator.dupe(u8, cache_path);
    }

    // ========================================================================
    // User Operations
    // ========================================================================

    /// Get current authenticated user (whoami)
    pub fn whoami(self: *Self) !types.User {
        _ = self.rate_limiter.acquire();
        var user_api = api.UserApi.init(self.allocator, &self.http_client);
        return user_api.whoami();
    }

    /// Check if currently authenticated
    pub fn isAuthenticated(self: *Self) bool {
        var user_api = api.UserApi.init(self.allocator, &self.http_client);
        return user_api.isAuthenticated();
    }

    /// Check if we have access to a specific model
    pub fn hasModelAccess(self: *Self, model_id: []const u8) !bool {
        var user_api = api.UserApi.init(self.allocator, &self.http_client);
        return user_api.hasModelAccess(model_id);
    }

    // ========================================================================
    // Cache Operations
    // ========================================================================

    /// Get cache statistics
    pub fn getCacheStats(self: *Self) !CacheStats {
        return self.file_cache.stats();
    }

    /// Clear the cache
    pub fn clearCache(self: *Self) !u64 {
        return self.file_cache.clearAll();
    }

    /// Clear cache for a specific repository
    pub fn clearRepoCache(self: *Self, repo_id: []const u8) !u64 {
        return self.file_cache.clearRepo(repo_id);
    }

    /// Clear cache for repositories matching a pattern
    /// Pattern supports:
    ///   - "*" matches any sequence of characters
    ///   - "?" matches any single character
    ///   - Exact match otherwise
    /// Examples:
    ///   - "TheBloke/*" matches all TheBloke repos
    ///   - "*GGUF*" matches any repo with GGUF in the name
    pub fn clearCachePattern(self: *Self, pattern: []const u8) !u64 {
        return self.file_cache.clearPattern(pattern);
    }

    /// Clean up partial downloads
    pub fn cleanPartialDownloads(self: *Self) !u64 {
        return self.file_cache.cleanPartials();
    }

    /// Check if a file is cached
    pub fn isCached(
        self: *Self,
        model_id: []const u8,
        filename: []const u8,
        revision: []const u8,
    ) !bool {
        return self.file_cache.isCached(model_id, filename, revision);
    }

    /// Get cache directory path
    pub fn getCacheDir(self: *Self) ?[]const u8 {
        return self.config.cache_dir;
    }

    // ========================================================================
    // Utility Functions
    // ========================================================================

    /// Free a SearchResult
    pub fn freeSearchResult(self: *Self, result: *SearchResult) void {
        result.deinit(self.allocator);
    }

    /// Free a Model
    pub fn freeModel(self: *Self, model: *Model) void {
        model.deinit(self.allocator);
    }

    /// Free a FileInfo slice
    pub fn freeFileInfoSlice(self: *Self, files: []FileInfo) void {
        for (files) |*f| {
            f.deinit(self.allocator);
        }
        self.allocator.free(files);
    }

    /// Free a User
    pub fn freeUser(self: *Self, user: *types.User) void {
        user.deinit(self.allocator);
    }

    /// Get the current configuration
    pub fn getConfig(self: *Self) Config {
        return self.config;
    }

    /// Set the authentication token
    pub fn setToken(self: *Self, token: ?[]const u8) void {
        self.http_client.token = token;
    }
};

/// Convenience function to create a HubClient with default settings
pub fn createClient(allocator: Allocator) !HubClient {
    return HubClient.init(allocator, null);
}

/// Convenience function to create a HubClient with a token
pub fn createAuthenticatedClient(allocator: Allocator, token: []const u8) !HubClient {
    var cfg = try Config.fromEnv(allocator);
    const token_copy = try allocator.dupe(u8, token);
    cfg.token = token_copy;
    cfg.allocated_fields.token = true;

    return HubClient.init(allocator, cfg);
}

// ============================================================================
// Version Information
// ============================================================================

pub const version = "0.1.0";
pub const version_major = 0;
pub const version_minor = 1;
pub const version_patch = 0;

/// Get version string
pub fn getVersion() []const u8 {
    return version;
}

// ============================================================================
// Tests
// ============================================================================

test "HubClient initialization" {
    // This test just verifies the structure compiles correctly
    const allocator = std.testing.allocator;
    _ = allocator;
}

test "version info" {
    try std.testing.expectEqualStrings("0.1.0", version);
    try std.testing.expectEqual(@as(u8, 0), version_major);
}

test {
    // Run tests from all submodules
    std.testing.refAllDecls(@This());
}
