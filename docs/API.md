# hf-hub-zig API Reference

This document provides complete API documentation for the hf-hub-zig library.

## Table of Contents

- [HubClient](#hubclient)
- [Configuration](#configuration)
- [Types](#types)
- [Error Handling](#error-handling)
- [Rate Limiting & Retry](#rate-limiting--retry)
- [Cache](#cache)
- [Progress Tracking](#progress-tracking)

---

## HubClient

The main entry point for all Hub operations.

### Initialization

```zig
const hf = @import("hf-hub");

// Initialize with default configuration (reads from environment)
var client = try hf.HubClient.init(allocator, null);
defer client.deinit();

// Initialize with custom configuration
var config = try hf.Config.fromEnv(allocator);
config.timeout_ms = 60000;
var client = try hf.HubClient.init(allocator, config);
defer client.deinit();
```

### Search Methods

#### `search(query: SearchQuery) !SearchResult`

Search for models on HuggingFace Hub.

```zig
var results = try client.search(.{
    .search = "llama",
    .limit = 20,
    .sort = .downloads,
    .filter = "gguf",
});
defer client.freeSearchResult(&results);

for (results.models) |model| {
    std.debug.print("{s}: {?d} downloads\n", .{ model.id, model.downloads });
}
```

#### `searchGgufModels(query_text: []const u8) !SearchResult`

Search specifically for GGUF models.

```zig
var results = try client.searchGgufModels("mistral 7b");
defer client.freeSearchResult(&results);
```

#### `searchPaginated(query_text: []const u8, limit: u32, offset: u32) !SearchResult`

Search with pagination support.

```zig
// Get page 2 (20 results starting at offset 20)
var page2 = try client.searchPaginated("llama", 20, 20);
defer client.freeSearchResult(&page2);
```

### Model Information Methods

#### `getModelInfo(model_id: []const u8) !Model`

Get detailed information about a specific model.

```zig
var model = try client.getModelInfo("TheBloke/Llama-2-7B-GGUF");
defer client.freeModel(&model);

std.debug.print("Model: {s}\n", .{model.id});
std.debug.print("Author: {s}\n", .{model.author orelse "unknown"});
std.debug.print("Downloads: {?d}\n", .{model.downloads});
```

#### `listFiles(model_id: []const u8) ![]FileInfo`

List all files in a model repository.

```zig
var files = try client.listFiles("TheBloke/Llama-2-7B-GGUF");
defer client.freeFileInfoSlice(files);

for (files) |file| {
    std.debug.print("{s} ({?d} bytes)\n", .{ file.filename, file.size });
}
```

#### `listGgufFiles(model_id: []const u8) ![]FileInfo`

List only GGUF files in a model repository.

```zig
var gguf_files = try client.listGgufFiles("TheBloke/Llama-2-7B-GGUF");
defer client.freeFileInfoSlice(gguf_files);
```

#### `modelExists(model_id: []const u8) !bool`

Check if a model exists on the Hub.

```zig
if (try client.modelExists("meta-llama/Llama-2-7b-hf")) {
    std.debug.print("Model exists!\n", .{});
}
```

#### `hasGgufFiles(model_id: []const u8) !bool`

Check if a model has any GGUF files.

```zig
if (try client.hasGgufFiles("TheBloke/Llama-2-7B-GGUF")) {
    std.debug.print("Has GGUF files!\n", .{});
}
```

### File Operations

#### `getFileMetadata(model_id, filename, revision) !FileInfo`

Get metadata for a specific file without downloading.

```zig
const metadata = try client.getFileMetadata(
    "TheBloke/Llama-2-7B-GGUF",
    "llama-2-7b.Q4_K_M.gguf",
    "main",
);
std.debug.print("Size: {?d} bytes\n", .{metadata.size});
```

#### `fileExists(model_id, filename, revision) !bool`

Check if a specific file exists in a repository.

```zig
if (try client.fileExists("TheBloke/Llama-2-7B-GGUF", "model.gguf", "main")) {
    // File exists
}
```

#### `getDownloadUrl(model_id, filename, revision) ![]u8`

Get the direct download URL for a file.

```zig
const url = try client.getDownloadUrl(
    "TheBloke/Llama-2-7B-GGUF",
    "llama-2-7b.Q4_K_M.gguf",
    "main",
);
defer allocator.free(url);
```

### Download Methods

#### `downloadFile(model_id, filename, progress_cb) ![]const u8`

Download a file to the current directory.

```zig
const path = try client.downloadFile(
    "TheBloke/Llama-2-7B-GGUF",
    "llama-2-7b.Q4_K_M.gguf",
    null,  // no progress callback
);
defer allocator.free(path);
std.debug.print("Downloaded to: {s}\n", .{path});
```

With progress callback:

```zig
const path = try client.downloadFile(
    "TheBloke/Llama-2-7B-GGUF",
    "llama-2-7b.Q4_K_M.gguf",
    struct {
        fn callback(progress: hf.DownloadProgress) void {
            const pct = progress.percentComplete();
            const speed = progress.downloadSpeed();
            std.debug.print("\r{d}% @ {d:.1} MB/s", .{ pct, speed / 1024 / 1024 });
        }
    }.callback,
);
```

#### `downloadFileWithOptions(model_id, filename, revision, output_dir, progress_cb) ![]const u8`

Download with full control over options.

```zig
const path = try client.downloadFileWithOptions(
    "TheBloke/Llama-2-7B-GGUF",
    "llama-2-7b.Q4_K_M.gguf",
    "main",        // revision
    "/models",     // output directory
    null,          // progress callback
);
```

#### `downloadToCache(model_id, filename, revision, progress_cb) ![]const u8`

Download to the cache directory (HF-compatible structure).

```zig
const cached_path = try client.downloadToCache(
    "TheBloke/Llama-2-7B-GGUF",
    "llama-2-7b.Q4_K_M.gguf",
    "main",
    null,
);
// File is now in ~/.cache/huggingface/hub/models--TheBloke--Llama-2-7B-GGUF/...
```

### User/Authentication Methods

#### `whoami() !User`

Get information about the currently authenticated user.

```zig
var user = try client.whoami();
defer client.freeUser(&user);

std.debug.print("Logged in as: {s}\n", .{user.username});
if (user.is_pro) {
    std.debug.print("PRO account\n", .{});
}
```

#### `isAuthenticated() bool`

Check if the client has an authentication token.

```zig
if (client.isAuthenticated()) {
    std.debug.print("Authenticated\n", .{});
} else {
    std.debug.print("Anonymous access\n", .{});
}
```

#### `hasModelAccess(model_id: []const u8) !bool`

Check if the current user has access to a model.

```zig
if (try client.hasModelAccess("meta-llama/Llama-2-7b-hf")) {
    std.debug.print("You have access!\n", .{});
}
```

### Cache Methods

#### `getCacheStats() !CacheStats`

Get cache statistics.

```zig
const stats = try client.getCacheStats();
std.debug.print("Repos: {d}\n", .{stats.num_repos});
std.debug.print("Files: {d}\n", .{stats.total_files});
std.debug.print("Size: {d} bytes\n", .{stats.total_size});
std.debug.print("GGUF files: {d}\n", .{stats.num_gguf_files});
```

#### `clearCache() !u64`

Clear the entire cache. Returns bytes freed.

```zig
const freed = try client.clearCache();
std.debug.print("Freed {d} bytes\n", .{freed});
```

#### `clearRepoCache(repo_id: []const u8) !u64`

Clear cache for a specific repository.

```zig
const freed = try client.clearRepoCache("TheBloke/Llama-2-7B-GGUF");
```

#### `cleanPartialDownloads() !u64`

Remove incomplete `.part` files.

```zig
const freed = try client.cleanPartialDownloads();
```

#### `isCached(model_id, filename, revision) !bool`

Check if a file is in the cache.

```zig
if (try client.isCached("TheBloke/Llama-2-7B-GGUF", "model.gguf", "main")) {
    std.debug.print("File is cached\n", .{});
}
```

#### `getCacheDir() ?[]const u8`

Get the cache directory path.

```zig
if (client.getCacheDir()) |dir| {
    std.debug.print("Cache at: {s}\n", .{dir});
}
```

### Utility Methods

#### `setToken(token: ?[]const u8) void`

Set or update the authentication token.

```zig
client.setToken("hf_xxxxxxxxxxxxx");
```

#### `getConfig() Config`

Get the current configuration.

```zig
const config = client.getConfig();
std.debug.print("Endpoint: {s}\n", .{config.endpoint});
```

---

## Configuration

### Config struct

```zig
pub const Config = struct {
    endpoint: []const u8 = "https://huggingface.co",
    token: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    timeout_ms: u32 = 30000,
    max_retries: u8 = 3,
    max_requests_per_second: u32 = 10,
    use_progress: bool = true,
};
```

### Loading Configuration

```zig
// From environment variables
var config = try hf.Config.fromEnv(allocator);
defer config.deinit();

// Default configuration
var config = try hf.Config.default(allocator);
defer config.deinit();
```

### Environment Variables

| Variable | Field | Default |
|----------|-------|---------|
| `HF_TOKEN` | `token` | `null` |
| `HF_ENDPOINT` | `endpoint` | `https://huggingface.co` |
| `HF_HOME` | `cache_dir` | OS-specific |
| `HF_TIMEOUT` | `timeout_ms` | `30000` |

---

## Types

### SearchQuery

```zig
pub const SearchQuery = struct {
    search: []const u8 = "",
    author: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    sort: ?SortOrder = null,
    direction: ?SortDirection = null,
    limit: u32 = 20,
    offset: u32 = 0,
    full: bool = false,
};
```

### SortOrder

```zig
pub const SortOrder = enum {
    trending,
    downloads,
    likes,
    created,
    modified,
};
```

### SearchResult

```zig
pub const SearchResult = struct {
    models: []Model,
    total: ?u32 = null,
    
    pub fn deinit(self: *SearchResult, allocator: Allocator) void;
};
```

### Model

```zig
pub const Model = struct {
    id: []const u8,
    author: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    private: bool = false,
    gated: ?bool = null,
    disabled: bool = false,
    library_name: ?[]const u8 = null,
    pipeline_tag: ?[]const u8 = null,
    downloads: ?u64 = null,
    likes: ?u64 = null,
    trending_score: ?f64 = null,
    tags: ?[][]const u8 = null,
    siblings: ?[]Sibling = null,
    
    pub fn deinit(self: *Model, allocator: Allocator) void;
};
```

### FileInfo

```zig
pub const FileInfo = struct {
    filename: []const u8,
    path: []const u8,
    size: ?u64 = null,
    blob_id: ?[]const u8 = null,
    is_gguf: bool = false,
    
    pub fn deinit(self: *FileInfo, allocator: Allocator) void;
    pub fn checkIsGguf(filename: []const u8) bool;
};
```

### User

```zig
pub const User = struct {
    username: []const u8,
    name: []const u8,
    fullname: ?[]const u8 = null,
    avatar_url: ?[]const u8 = null,
    email: ?[]const u8 = null,
    email_verified: bool = false,
    account_type: ?[]const u8 = null,
    is_pro: bool = false,
    
    pub fn deinit(self: *User, allocator: Allocator) void;
};
```

### DownloadProgress

```zig
pub const DownloadProgress = struct {
    bytes_downloaded: u64,
    total_bytes: ?u64,
    start_time_ns: i128,
    current_time_ns: i128,
    
    pub fn percentComplete(self: DownloadProgress) u8;
    pub fn downloadSpeed(self: DownloadProgress) f64;  // bytes/sec
    pub fn estimatedTimeRemaining(self: DownloadProgress) ?f64;  // seconds
};
```

### CacheStats

```zig
pub const CacheStats = struct {
    total_files: u64 = 0,
    total_size: u64 = 0,
    num_repos: u64 = 0,
    num_gguf_files: u64 = 0,
    gguf_size: u64 = 0,
};
```

---

## Error Handling

### HubError

```zig
pub const HubError = error{
    NetworkError,
    Timeout,
    NotFound,
    Unauthorized,
    Forbidden,
    RateLimited,
    InvalidJson,
    InvalidRequest,
    ServerError,
    CacheError,
    DownloadError,
    IoError,
    OutOfMemory,
};
```

### ErrorContext

```zig
pub const ErrorContext = struct {
    error_type: HubError,
    message: []const u8,
    status_code: ?u16 = null,
    retry_after: ?u32 = null,
    url: ?[]const u8 = null,
    
    pub fn init(error_type: HubError, message: []const u8) ErrorContext;
    pub fn isRetryable(self: ErrorContext) bool;
    pub fn format(self: *ErrorContext, allocator: Allocator) ![]u8;
};
```

### Retryable Errors

The following errors are considered retryable:
- `RateLimited` (429)
- `Timeout`
- `ServerError` (5xx)
- `NetworkError`

Non-retryable:
- `NotFound` (404)
- `Unauthorized` (401)
- `Forbidden` (403)
- `InvalidJson`
- `InvalidRequest`

---

## Rate Limiting & Retry

### RateLimiter

Token bucket rate limiter.

```zig
// Default: 10 requests/second
var limiter = hf.RateLimiter.initDefault();

// Custom rate
var limiter = hf.RateLimiter.init(20);  // 20 req/sec

// Acquire a token (waits if needed)
const wait_time = limiter.acquire();
```

### RetryStrategy

Exponential backoff with jitter.

```zig
var strategy = hf.RetryStrategy.init();

// Or with custom config
var strategy = hf.RetryStrategy.initWithConfig(.{
    .max_retries = 5,
    .base_delay_ms = 200,
    .max_delay_ms = 30000,
    .backoff_multiplier = 2.0,
    .jitter_enabled = true,
});

// Calculate delay for attempt N
const delay_ms = strategy.calculateDelay(attempt_number);
```

---

## Cache

### Cache struct

```zig
// Initialize with custom directory
var cache = try hf.Cache.init(allocator, "/path/to/cache");
defer cache.deinit();

// Initialize with default directory
var cache = try hf.Cache.initDefault(allocator);
defer cache.deinit();
```

### Cache Operations

```zig
// Check if cached
const is_cached = try cache.isCached(repo_id, filename, revision);

// Get cached file path
if (try cache.getCachedFile(repo_id, filename, revision)) |path| {
    // Use cached file
}

// Prepare path for download
const target_path = try cache.prepareCachePath(repo_id, filename, revision);

// Get statistics
const stats = try cache.stats();

// Clear all
const freed = try cache.clearAll();

// Clear specific repo
const freed = try cache.clearRepo(repo_id);

// Clean partial downloads
const freed = try cache.cleanPartials();
```

---

## Progress Tracking

### ProgressCallback

```zig
pub const ProgressCallback = *const fn(DownloadProgress) void;
```

### Example Progress Display

```zig
fn showProgress(progress: hf.DownloadProgress) void {
    const pct = progress.percentComplete();
    const speed = progress.downloadSpeed();
    const eta = progress.estimatedTimeRemaining();
    
    var speed_buf: [32]u8 = undefined;
    const speed_str = hf.formatBytesPerSecond(speed, &speed_buf);
    
    if (eta) |e| {
        std.debug.print("\r[{d:>3}%] {s}/s ETA: {d:.0}s", .{ pct, speed_str, e });
    } else {
        std.debug.print("\r[{d:>3}%] {s}/s", .{ pct, speed_str });
    }
}

const path = try client.downloadFile(model_id, filename, showProgress);
```

### ProgressBar (CLI)

For CLI applications, use the built-in progress bar:

```zig
var bar = hf.ProgressBar.init(total_bytes, "Downloading");
bar.update(bytes_so_far);
bar.finish();
```

---

## Utility Functions

### Byte Formatting

```zig
var buf: [32]u8 = undefined;

// Format bytes (e.g., "1.50 GB")
const size_str = hf.formatBytes(1610612736, &buf);

// Format speed (e.g., "10.5 MB/s")
const speed_str = hf.formatBytesPerSecond(11010048, &buf);
```

### Convenience Functions

```zig
// Create a client with defaults
var client = try hf.createClient(allocator);
defer client.deinit();

// Create an authenticated client
var client = try hf.createAuthenticatedClient(allocator, "hf_token");
defer client.deinit();

// Get library version
const version = hf.getVersion();  // "0.1.0"
```

---

## Thread Safety

The `HubClient` is **not** thread-safe. Each thread should have its own client instance.

For concurrent downloads, use the `async` module:

```zig
const async_ops = hf.async_ops;

var ctx = try async_ops.AsyncContext.init(allocator, 4);  // 4 threads
defer ctx.deinit();

const items = &[_]hf.DownloadItem{
    .{ .repo_id = "model1", .filename = "file1.gguf", .output_dir = "." },
    .{ .repo_id = "model2", .filename = "file2.gguf", .output_dir = "." },
};

const results = try ctx.batchDownload(items, null);
```

---

## Memory Management

All types that allocate memory have a `deinit` method:

```zig
var model = try client.getModelInfo("repo/model");
defer client.freeModel(&model);  // or model.deinit(allocator)

var results = try client.search(.{ .search = "llama" });
defer client.freeSearchResult(&results);

var files = try client.listFiles("repo/model");
defer client.freeFileInfoSlice(files);
```

The `HubClient` provides convenience methods for freeing:
- `freeSearchResult(&result)`
- `freeModel(&model)`
- `freeFileInfoSlice(files)`
- `freeUser(&user)`
