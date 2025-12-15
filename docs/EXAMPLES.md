# hf-hub-zig Examples

This document provides detailed examples for common use cases.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Search Operations](#search-operations)
- [Downloading Files](#downloading-files)
- [Progress Tracking](#progress-tracking)
- [Cache Management](#cache-management)
- [Authentication](#authentication)
- [Error Handling](#error-handling)
- [Batch Operations](#batch-operations)

---

## Basic Usage

### Initialize a Client

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize with defaults (reads HF_TOKEN from environment)
    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Now you can use the client
    std.debug.print("Client initialized!\n", .{});
}
```

### Initialize with Custom Configuration

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create custom config
    var config = try hf.Config.fromEnv(allocator);
    config.timeout_ms = 60000;  // 60 second timeout
    config.max_retries = 5;

    var client = try hf.HubClient.init(allocator, config);
    defer client.deinit();
}
```

---

## Search Operations

### Simple Search

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Search for models
    var results = try client.search(.{ .search = "llama" });
    defer client.freeSearchResult(&results);

    std.debug.print("Found {d} models:\n", .{results.models.len});
    for (results.models) |model| {
        std.debug.print("  - {s}\n", .{model.id});
    }
}
```

### Search for GGUF Models

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Search specifically for GGUF models
    var results = try client.searchGgufModels("mistral 7b");
    defer client.freeSearchResult(&results);

    std.debug.print("Found {d} GGUF models:\n\n", .{results.models.len});

    for (results.models) |model| {
        std.debug.print("Model: {s}\n", .{model.id});
        if (model.downloads) |d| {
            std.debug.print("  Downloads: {d}\n", .{d});
        }
        if (model.likes) |l| {
            std.debug.print("  Likes: {d}\n", .{l});
        }
        std.debug.print("\n", .{});
    }
}
```

### Advanced Search with Filters

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Search with all options
    var results = try client.search(.{
        .search = "code assistant",
        .author = "TheBloke",          // Filter by author
        .filter = "gguf",              // Filter by tag
        .sort = .downloads,            // Sort by downloads
        .direction = .desc,            // Descending order
        .limit = 10,                   // Max 10 results
        .offset = 0,                   // Start from first result
        .full = true,                  // Include full details
    });
    defer client.freeSearchResult(&results);

    for (results.models) |model| {
        std.debug.print("{s}: {?d} downloads\n", .{ model.id, model.downloads });
    }
}
```

### Paginated Search

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    const page_size: u32 = 10;
    var offset: u32 = 0;
    var total_found: usize = 0;

    // Fetch multiple pages
    while (true) {
        var results = try client.searchPaginated("llama gguf", page_size, offset);
        defer client.freeSearchResult(&results);

        if (results.models.len == 0) break;

        for (results.models) |model| {
            total_found += 1;
            std.debug.print("{d}. {s}\n", .{ total_found, model.id });
        }

        if (results.models.len < page_size) break;
        offset += page_size;

        // Stop after 3 pages for this example
        if (offset >= 30) break;
    }

    std.debug.print("\nTotal: {d} models\n", .{total_found});
}
```

---

## Downloading Files

### Download a Single File

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Download without progress callback
    const path = try client.downloadFile(
        "TheBloke/Llama-2-7B-GGUF",
        "llama-2-7b.Q4_K_M.gguf",
        null,
    );
    defer allocator.free(path);

    std.debug.print("Downloaded to: {s}\n", .{path});
}
```

### Download to Specific Directory

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    const path = try client.downloadFileWithOptions(
        "TheBloke/Llama-2-7B-GGUF",
        "llama-2-7b.Q4_K_M.gguf",
        "main",           // revision
        "/home/user/models",  // output directory
        null,             // progress callback
    );
    defer allocator.free(path);

    std.debug.print("Downloaded to: {s}\n", .{path});
}
```

### Download to Cache

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Download to HF cache directory
    const cached_path = try client.downloadToCache(
        "TheBloke/Llama-2-7B-GGUF",
        "llama-2-7b.Q4_K_M.gguf",
        "main",
        null,
    );
    // Note: cached_path is managed by cache, don't free it

    std.debug.print("Cached at: {s}\n", .{cached_path});

    // Next time, it will return the cached path immediately
    const same_path = try client.downloadToCache(
        "TheBloke/Llama-2-7B-GGUF",
        "llama-2-7b.Q4_K_M.gguf",
        "main",
        null,
    );
    std.debug.print("From cache: {s}\n", .{same_path});
}
```

---

## Progress Tracking

### Simple Progress Callback

```zig
const std = @import("std");
const hf = @import("hf-hub");

fn showProgress(progress: hf.DownloadProgress) void {
    const pct = progress.percentComplete();
    std.debug.print("\rDownloading: {d}%", .{pct});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    const path = try client.downloadFile(
        "TheBloke/Llama-2-7B-GGUF",
        "llama-2-7b.Q4_K_M.gguf",
        showProgress,
    );
    defer allocator.free(path);

    std.debug.print("\nDownload complete: {s}\n", .{path});
}
```

### Detailed Progress with Speed and ETA

```zig
const std = @import("std");
const hf = @import("hf-hub");

fn detailedProgress(progress: hf.DownloadProgress) void {
    const pct = progress.percentComplete();
    const speed = progress.downloadSpeed();

    // Format speed
    var speed_buf: [32]u8 = undefined;
    const speed_str = hf.formatBytesPerSecond(speed, &speed_buf);

    // Format downloaded/total
    var dl_buf: [32]u8 = undefined;
    const dl_str = hf.formatBytes(progress.bytes_downloaded, &dl_buf);

    if (progress.total_bytes) |total| {
        var total_buf: [32]u8 = undefined;
        const total_str = hf.formatBytes(total, &total_buf);

        if (progress.estimatedTimeRemaining()) |eta| {
            const eta_min = @as(u32, @intFromFloat(eta / 60));
            const eta_sec = @as(u32, @intFromFloat(@mod(eta, 60)));
            std.debug.print("\r[{d:>3}%] {s} / {s}  {s}  ETA: {d}m {d}s   ", .{
                pct, dl_str, total_str, speed_str, eta_min, eta_sec,
            });
        } else {
            std.debug.print("\r[{d:>3}%] {s} / {s}  {s}   ", .{
                pct, dl_str, total_str, speed_str,
            });
        }
    } else {
        std.debug.print("\r{s}  {s}   ", .{ dl_str, speed_str });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    std.debug.print("Downloading llama-2-7b.Q4_K_M.gguf...\n", .{});

    const path = try client.downloadFile(
        "TheBloke/Llama-2-7B-GGUF",
        "llama-2-7b.Q4_K_M.gguf",
        detailedProgress,
    );
    defer allocator.free(path);

    std.debug.print("\n\nComplete! Saved to: {s}\n", .{path});
}
```

### Progress Bar with ANSI Colors

```zig
const std = @import("std");
const hf = @import("hf-hub");

fn coloredProgressBar(progress: hf.DownloadProgress) void {
    const pct = progress.percentComplete();
    const bar_width: u32 = 40;
    const filled = (pct * bar_width) / 100;

    // ANSI colors
    const CYAN = "\x1b[36m";
    const GREEN = "\x1b[32m";
    const RESET = "\x1b[0m";
    const BOLD = "\x1b[1m";

    // Build progress bar
    var bar: [40]u8 = undefined;
    for (0..bar_width) |i| {
        bar[i] = if (i < filled) '=' else ' ';
    }

    const speed = progress.downloadSpeed();
    var speed_buf: [32]u8 = undefined;
    const speed_str = hf.formatBytesPerSecond(speed, &speed_buf);

    std.debug.print("\r{s}{s}[{s}{s}{s}]{s} {s}{d}%{s} {s}", .{
        BOLD, CYAN, GREEN, bar[0..bar_width], CYAN, RESET,
        BOLD, pct, RESET, speed_str,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    _ = try client.downloadFile(
        "TheBloke/Llama-2-7B-GGUF",
        "config.json",  // Small file for testing
        coloredProgressBar,
    );

    std.debug.print("\n", .{});
}
```

---

## Cache Management

### Check Cache Status

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Get cache statistics
    const stats = try client.getCacheStats();

    std.debug.print("Cache Statistics:\n", .{});
    std.debug.print("  Directory: {s}\n", .{client.getCacheDir() orelse "not set"});
    std.debug.print("  Repositories: {d}\n", .{stats.num_repos});
    std.debug.print("  Total files: {d}\n", .{stats.total_files});

    var size_buf: [32]u8 = undefined;
    std.debug.print("  Total size: {s}\n", .{hf.formatBytes(stats.total_size, &size_buf)});
    std.debug.print("  GGUF files: {d}\n", .{stats.num_gguf_files});
    std.debug.print("  GGUF size: {s}\n", .{hf.formatBytes(stats.gguf_size, &size_buf)});
}
```

### Check if File is Cached

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    const model_id = "TheBloke/Llama-2-7B-GGUF";
    const filename = "llama-2-7b.Q4_K_M.gguf";

    if (try client.isCached(model_id, filename, "main")) {
        std.debug.print("File is cached!\n", .{});
    } else {
        std.debug.print("File not in cache, downloading...\n", .{});
        _ = try client.downloadToCache(model_id, filename, "main", null);
        std.debug.print("Downloaded and cached.\n", .{});
    }
}
```

### Clear Cache

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Clear specific repository
    const freed1 = try client.clearRepoCache("TheBloke/Llama-2-7B-GGUF");
    var buf: [32]u8 = undefined;
    std.debug.print("Cleared repo cache, freed {s}\n", .{hf.formatBytes(freed1, &buf)});

    // Clean partial downloads
    const freed2 = try client.cleanPartialDownloads();
    std.debug.print("Cleaned partials, freed {s}\n", .{hf.formatBytes(freed2, &buf)});

    // Clear entire cache
    const freed3 = try client.clearCache();
    std.debug.print("Cleared all cache, freed {s}\n", .{hf.formatBytes(freed3, &buf)});
}
```

---

## Authentication

### Using Environment Variable

```bash
# Set the token in your shell
export HF_TOKEN="hf_xxxxxxxxxxxxxxxxxxxxx"
```

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Token is automatically read from HF_TOKEN
    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    if (client.isAuthenticated()) {
        var user = try client.whoami();
        defer client.freeUser(&user);
        std.debug.print("Logged in as: {s}\n", .{user.username});
    } else {
        std.debug.print("Not authenticated\n", .{});
    }
}
```

### Setting Token Programmatically

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create authenticated client
    var client = try hf.createAuthenticatedClient(allocator, "hf_xxxxxxxxxxxxx");
    defer client.deinit();

    // Or set token after creation
    client.setToken("hf_new_token_xxxxx");
}
```

### Accessing Private/Gated Models

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.createAuthenticatedClient(allocator, "hf_xxxxx");
    defer client.deinit();

    const model_id = "meta-llama/Llama-2-7b-hf";  // Gated model

    // Check access
    if (try client.hasModelAccess(model_id)) {
        std.debug.print("You have access to {s}\n", .{model_id});

        // List files
        var files = try client.listFiles(model_id);
        defer client.freeFileInfoSlice(files);

        for (files) |file| {
            std.debug.print("  {s}\n", .{file.filename});
        }
    } else {
        std.debug.print("No access to {s}. Request access on HuggingFace.\n", .{model_id});
    }
}
```

---

## Error Handling

### Basic Error Handling

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    const result = client.getModelInfo("nonexistent/model");

    if (result) |model| {
        defer client.freeModel(&model);
        std.debug.print("Found: {s}\n", .{model.id});
    } else |err| {
        switch (err) {
            error.NotFound => std.debug.print("Model not found\n", .{}),
            error.Unauthorized => std.debug.print("Authentication required\n", .{}),
            error.Forbidden => std.debug.print("Access denied\n", .{}),
            error.NetworkError => std.debug.print("Network error\n", .{}),
            error.Timeout => std.debug.print("Request timed out\n", .{}),
            else => std.debug.print("Error: {}\n", .{err}),
        }
    }
}
```

### Retry Logic Example

```zig
const std = @import("std");
const hf = @import("hf-hub");

fn downloadWithRetry(
    client: *hf.HubClient,
    model_id: []const u8,
    filename: []const u8,
    max_attempts: u8,
) ![]const u8 {
    var strategy = hf.RetryStrategy.init();
    var attempt: u8 = 0;

    while (attempt < max_attempts) : (attempt += 1) {
        const result = client.downloadFile(model_id, filename, null);

        if (result) |path| {
            return path;
        } else |err| {
            const ctx = hf.ErrorContext.init(err, "Download failed");

            if (!ctx.isRetryable()) {
                return err;
            }

            if (attempt < max_attempts - 1) {
                const delay = strategy.calculateDelay(attempt);
                std.debug.print("Attempt {d} failed, retrying in {d}ms...\n", .{ attempt + 1, delay });
                std.time.sleep(delay * std.time.ns_per_ms);
            }
        }
    }

    return error.DownloadError;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    const path = try downloadWithRetry(
        &client,
        "TheBloke/Llama-2-7B-GGUF",
        "config.json",
        3,
    );
    defer allocator.free(path);

    std.debug.print("Downloaded: {s}\n", .{path});
}
```

---

## Batch Operations

### Download Multiple Files

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    const model_id = "TheBloke/Llama-2-7B-GGUF";

    // List GGUF files
    var files = try client.listGgufFiles(model_id);
    defer client.freeFileInfoSlice(files);

    std.debug.print("Downloading {d} GGUF files...\n", .{files.len});

    for (files, 0..) |file, i| {
        std.debug.print("[{d}/{d}] {s}... ", .{ i + 1, files.len, file.filename });

        const path = client.downloadFile(model_id, file.filename, null) catch |err| {
            std.debug.print("FAILED: {}\n", .{err});
            continue;
        };
        defer allocator.free(path);

        std.debug.print("OK\n", .{});
    }

    std.debug.print("Done!\n", .{});
}
```

### Search and Download Workflow

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Step 1: Search for models
    std.debug.print("Searching for Mistral GGUF models...\n", .{});
    var results = try client.searchGgufModels("mistral 7b instruct");
    defer client.freeSearchResult(&results);

    if (results.models.len == 0) {
        std.debug.print("No models found.\n", .{});
        return;
    }

    // Step 2: Get the top result
    const top_model = results.models[0];
    std.debug.print("Top result: {s}\n", .{top_model.id});

    // Step 3: List GGUF files
    std.debug.print("Listing GGUF files...\n", .{});
    var files = try client.listGgufFiles(top_model.id);
    defer client.freeFileInfoSlice(files);

    // Step 4: Find Q4_K_M quantization
    var target_file: ?hf.FileInfo = null;
    for (files) |file| {
        if (std.mem.indexOf(u8, file.filename, "Q4_K_M") != null) {
            target_file = file;
            break;
        }
    }

    if (target_file) |file| {
        std.debug.print("Found: {s}\n", .{file.filename});

        if (file.size) |size| {
            var buf: [32]u8 = undefined;
            std.debug.print("Size: {s}\n", .{hf.formatBytes(size, &buf)});
        }

        // Step 5: Download
        std.debug.print("Downloading...\n", .{});
        const path = try client.downloadFile(
            top_model.id,
            file.filename,
            struct {
                fn cb(p: hf.DownloadProgress) void {
                    std.debug.print("\r{d}%", .{p.percentComplete()});
                }
            }.cb,
        );
        defer allocator.free(path);

        std.debug.print("\nSaved to: {s}\n", .{path});
    } else {
        std.debug.print("No Q4_K_M quantization found.\n", .{});
    }
}
```

---

## Working with Model Information

### Get Detailed Model Info

```zig
const std = @import("std");
const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    var model = try client.getModelInfo("TheBloke/Llama-2-7B-GGUF");
    defer client.freeModel(&model);

    std.debug.print("Model: {s}\n", .{model.id});
    std.debug.print("Author: {s}\n", .{model.author orelse "unknown"});

    if (model.downloads) |d| std.debug.print("Downloads: {d}\n", .{d});
    if (model.likes) |l| std.debug.print("Likes: {d}\n", .{l});
    if (model.pipeline_tag) |p| std.debug.print("Pipeline: {s}\n", .{p});
    if (model.library_name) |l| std.debug.print("Library: {s}\n", .{l});

    std.debug.print("Private: {}\n", .{model.private});

    if (model.tags) |tags| {
        std.debug.print("Tags: ", .{});
        for (tags, 0..) |tag, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{tag});
        }
        std.debug.print("\n", .{});
    }

    if (model.siblings) |siblings| {
        std.debug.print("\nFiles ({d}):\n", .{siblings.len});
        for (siblings) |sib| {
            if (sib.size) |size| {
                var buf: [32]u8 = undefined;
                std.debug.print("  {s} ({s})\n", .{ sib.rfilename, hf.formatBytes(size, &buf) });
            } else {
                std.debug.print("  {s}\n", .{sib.rfilename});
            }
        }
    }
}
```

---

## Best Practices

### 1. Always Clean Up Resources

```zig
var client = try hf.HubClient.init(allocator, null);
defer client.deinit();  // Always defer cleanup

var results = try client.search(.{ .search = "llama" });
defer client.freeSearchResult(&results);  // Free result memory
```

### 2. Check for Cached Files First

```zig
if (try client.isCached(model_id, filename, "main")) {
    // Use cached version
} else {
    // Download
}
```

### 3. Use Appropriate Timeouts

```zig
var config = try hf.Config.fromEnv(allocator);
config.timeout_ms = 120000;  // 2 minutes for large files
```

### 4. Handle Rate Limiting Gracefully

The library handles rate limiting automatically, but you can check:

```zig
// If you get RateLimited error, wait and retry
if (err == error.RateLimited) {
    std.time.sleep(60 * std.time.ns_per_s);  // Wait 1 minute
    // Retry...
}
```

### 5. Use Progress Callbacks for Large Downloads

```zig
// Always show progress for files > 100MB
if (file.size orelse 0 > 100 * 1024 * 1024) {
    _ = try client.downloadFile(model_id, filename, showProgress);
} else {
    _ = try client.downloadFile(model_id, filename, null);
}
```
