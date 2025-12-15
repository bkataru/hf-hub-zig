# hf-hub-zig

Zig library and CLI for interacting with the HuggingFace Hub API, with a focus on GGUF model discovery, searching, viewing, and downloading.

## Features

- 🔍 **Search** - Find GGUF models with powerful filtering and sorting
- 📥 **Download** - Stream large files with resume support and progress tracking
- ⚡ **Fast** - Concurrent downloads with configurable thread pool
- 🔒 **Secure** - Token-based authentication for private models
- 💾 **Cache** - Smart local caching system (HF-compatible structure)
- 🎨 **Beautiful CLI** - Vibrant, colorful terminal output with ANSI colors
- 📦 **Zero Dependencies** - Pure Zig implementation using only std library
- 🔄 **Resilient** - Automatic retries with exponential backoff and rate limiting

## Requirements

- Zig 0.15.2 or later

## Quick Start

### As a Library

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .hf_hub_zig = .{
        .url = "https://github.com/bkataru/hf-hub-zig/archive/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const hf_hub_dep = b.dependency("hf_hub_zig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("hf-hub", hf_hub_dep.module("hf-hub"));
```

Usage in your code:

```zig
const hf = @import("hf-hub");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize client (reads HF_TOKEN from environment automatically)
    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Search for GGUF models
    var results = try client.searchGgufModels("llama");
    defer client.freeSearchResult(&results);

    for (results.models) |model| {
        std.debug.print("{s} - {?d} downloads\n", .{ model.id, model.downloads });
    }
}
```

### CLI Installation

```bash
# Build from source
zig build -Doptimize=ReleaseFast

# The binary will be at zig-out/bin/hf-hub
# Copy to your PATH
cp zig-out/bin/hf-hub ~/.local/bin/
```

### CLI Usage

```bash
# Search for models
hf-hub search "llama 7b" --gguf-only --limit 10

# List files in a model
hf-hub list TheBloke/Llama-2-7B-GGUF

# Download a specific file
hf-hub download TheBloke/Llama-2-7B-GGUF llama-2-7b.Q4_K_M.gguf

# Download all GGUF files with parallel downloads
hf-hub download TheBloke/Llama-2-7B-GGUF --gguf-only --parallel 4

# Get model info
hf-hub info meta-llama/Llama-2-7b-hf

# Show current authenticated user
hf-hub user

# Manage cache
hf-hub cache info
hf-hub cache clear --force
hf-hub cache clear --pattern "TheBloke/*" --force
hf-hub cache clean  # Remove partial downloads
hf-hub cache dir    # Print cache directory path
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HF_TOKEN` | HuggingFace API token for private models | None |
| `HF_ENDPOINT` | API endpoint URL | `https://huggingface.co` |
| `HF_HOME` | Cache directory | `~/.cache/huggingface/hub` (Unix) or `%LOCALAPPDATA%\huggingface\hub` (Windows) |
| `HF_TIMEOUT` | Request timeout in milliseconds | `30000` |
| `NO_COLOR` | Disable colored output when set | Not set |

## Building

```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run unit tests
zig build test

# Run integration tests (requires network access)
zig build test-integration

# Generate documentation
zig build docs

# Run the CLI directly
zig build run -- search "mistral"
```

## Library API

The main entry point is `HubClient`:

```zig
const hf = @import("hf-hub");

// Initialize with default config (reads from environment)
var client = try hf.HubClient.init(allocator, null);
defer client.deinit();

// Or with custom config
var config = try hf.Config.fromEnv(allocator);
config.timeout_ms = 60000;
var client = try hf.HubClient.init(allocator, config);
```

### Search Operations

```zig
// Search for any models
var results = try client.search(.{ .search = "llama", .limit = 20 });
defer client.freeSearchResult(&results);

// Search specifically for GGUF models
var gguf_results = try client.searchGgufModels("mistral 7b");
defer client.freeSearchResult(&gguf_results);

// Paginated search
var page2 = try client.searchPaginated("llama", 20, 20);  // limit=20, offset=20
defer client.freeSearchResult(&page2);
```

### Model Information

```zig
// Get model details
var model = try client.getModelInfo("TheBloke/Llama-2-7B-GGUF");
defer client.freeModel(&model);

// List all files
var files = try client.listFiles("TheBloke/Llama-2-7B-GGUF");
defer client.freeFileInfoSlice(files);

// List only GGUF files
var gguf_files = try client.listGgufFiles("TheBloke/Llama-2-7B-GGUF");
defer client.freeFileInfoSlice(gguf_files);

// Check if model exists
const exists = try client.modelExists("some/model");
```

### Downloads

```zig
// Download to current directory
const path = try client.downloadFile(
    "TheBloke/Llama-2-7B-GGUF",
    "llama-2-7b.Q4_K_M.gguf",
    null,  // no progress callback
);
defer allocator.free(path);

// Download with progress callback
const path = try client.downloadFile(
    "TheBloke/Llama-2-7B-GGUF",
    "llama-2-7b.Q4_K_M.gguf",
    struct {
        fn callback(progress: hf.DownloadProgress) void {
            std.debug.print("\rDownloading: {d}%", .{progress.percentComplete()});
        }
    }.callback,
);

// Download to cache directory
const cached_path = try client.downloadToCache(
    "TheBloke/Llama-2-7B-GGUF",
    "llama-2-7b.Q4_K_M.gguf",
    "main",
    null,
);
```

### Cache Management

```zig
// Get cache stats
const stats = try client.getCacheStats();
std.debug.print("Cached: {d} files, {d} bytes\n", .{ stats.total_files, stats.total_size });

// Check if file is cached
const is_cached = try client.isCached("TheBloke/Llama-2-7B-GGUF", "model.gguf", "main");

// Clear entire cache
const freed = try client.clearCache();

// Clear specific repo
const freed = try client.clearRepoCache("TheBloke/Llama-2-7B-GGUF");

// Clean partial downloads
const freed = try client.cleanPartialDownloads();
```

### User/Authentication

```zig
// Check if authenticated
if (client.isAuthenticated()) {
    // Get user info
    var user = try client.whoami();
    defer client.freeUser(&user);
    std.debug.print("Logged in as: {s}\n", .{user.username});
}

// Check access to a model
const has_access = try client.hasModelAccess("meta-llama/Llama-2-7b-hf");
```

## Project Structure

```
hf-hub-zig/
├── build.zig                 # Build configuration
├── build.zig.zon             # Package metadata
├── src/
│   ├── lib.zig               # Library public API (HubClient)
│   ├── client.zig            # HTTP client wrapper
│   ├── config.zig            # Configuration management
│   ├── errors.zig            # Error types and handling
│   ├── types.zig             # Core data structures
│   ├── json.zig              # JSON parsing helpers
│   ├── cache.zig             # Local file caching
│   ├── downloader.zig        # Streaming downloads
│   ├── retry.zig             # Retry logic & rate limiting
│   ├── progress.zig          # Progress bar rendering
│   ├── terminal.zig          # ANSI colors & terminal utils
│   ├── async.zig             # Thread pool for concurrency
│   ├── api/
│   │   ├── mod.zig           # API module exports
│   │   ├── models.zig        # Model search/info operations
│   │   ├── files.zig         # File metadata operations
│   │   └── user.zig          # User/auth operations
│   └── cli/
│       ├── main.zig          # CLI entry point
│       ├── commands.zig      # Command dispatcher
│       ├── search.zig        # search command
│       ├── download.zig      # download command
│       ├── list.zig          # list command
│       ├── info.zig          # info command
│       ├── cache.zig         # cache command
│       ├── user.zig          # user command
│       └── formatting.zig    # Output formatting
├── tests/
│   ├── unit_tests.zig        # Unit tests
│   ├── integration_tests.zig # Network integration tests
│   └── fixtures/             # Test data
├── examples/                 # Example programs
└── docs/                     # Documentation
```

## Documentation

- [API Reference](docs/API.md) - Complete library API documentation
- [CLI Reference](docs/CLI.md) - CLI commands and options
- [Development Guide](docs/DEVELOPMENT.md) - Building, testing, contributing
- [Examples](docs/EXAMPLES.md) - Detailed usage examples

## Rate Limiting

The library implements automatic rate limiting (10 requests/second by default) and retry logic with exponential backoff:

- **Rate Limiting**: Token bucket algorithm, configurable requests per second
- **Retries**: 3 attempts with exponential backoff (100ms base, 2x multiplier)
- **Respects `Retry-After`**: Honors server-provided retry delays

## Cache Structure

The cache follows HuggingFace's standard structure:

```
~/.cache/huggingface/hub/
├── models--{org}--{model}/
│   ├── snapshots/
│   │   └── {revision}/
│   │       ├── model.gguf
│   │       └── config.json
│   └── refs/
│       └── main
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `zig build test`
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) for details.
