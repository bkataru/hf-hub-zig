# Development Guide

This document covers building, testing, and contributing to hf-hub-zig.

## Prerequisites

- **Zig 0.15.2** or later
- Git
- Network access (for integration tests)
- A HuggingFace account (optional, for testing authenticated features)

## Getting Started

### Clone the Repository

```bash
git clone https://github.com/bkataru/hf-hub-zig.git
cd hf-hub-zig
```

### Build

```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Release with debug info
zig build -Doptimize=ReleaseSafe
```

The CLI binary is output to `zig-out/bin/hf-hub`.

### Run Tests

```bash
# Run all unit tests
zig build test

# Run integration tests (requires network)
zig build test-integration

# Run a specific test by name
zig build test -- --test-filter "Config.default"
```

### Run the CLI

```bash
# Via build system
zig build run -- search "llama"

# Or run the binary directly after building
./zig-out/bin/hf-hub search "llama"
```

## Project Structure

```
hf-hub-zig/
├── build.zig                 # Build configuration
├── build.zig.zon             # Package metadata
├── src/
│   ├── lib.zig               # Library root (HubClient)
│   ├── client.zig            # HTTP client wrapper
│   ├── config.zig            # Configuration management
│   ├── errors.zig            # Error types
│   ├── types.zig             # Core data structures
│   ├── json.zig              # JSON parsing helpers
│   ├── cache.zig             # File caching system
│   ├── downloader.zig        # Streaming downloads
│   ├── retry.zig             # Retry logic & rate limiting
│   ├── progress.zig          # Progress bar rendering
│   ├── terminal.zig          # ANSI colors & terminal utils
│   ├── async.zig             # Thread pool for concurrency
│   ├── api/
│   │   ├── mod.zig           # API module exports
│   │   ├── models.zig        # Model search/info API
│   │   ├── files.zig         # File metadata API
│   │   └── user.zig          # User/auth API
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
│   ├── integration_tests.zig # Network tests
│   └── fixtures/             # Test data
├── examples/                 # Example programs
└── docs/                     # Documentation
```

## Architecture Overview

### Layered Design

```
┌─────────────────────────────────────────────────────────┐
│                         CLI                              │
│         (src/cli/*.zig - command handlers)              │
├─────────────────────────────────────────────────────────┤
│                      HubClient                           │
│            (src/lib.zig - unified API)                  │
├─────────────────────────────────────────────────────────┤
│     API Layer          │     Download Layer             │
│   (src/api/*.zig)      │   (src/downloader.zig)        │
│   - ModelsApi          │   - Streaming                  │
│   - FilesApi           │   - Progress tracking          │
│   - UserApi            │   - Resume support             │
├────────────────────────┴─────────────────────────────────┤
│                    HTTP Client                           │
│           (src/client.zig - std.http wrapper)           │
├─────────────────────────────────────────────────────────┤
│    Rate Limiter    │    Retry Strategy    │    Cache    │
│   (src/retry.zig)  │    (src/retry.zig)   │(src/cache)  │
└─────────────────────────────────────────────────────────┘
```

### Key Components

1. **HttpClient** (`src/client.zig`)
   - Wraps `std.http.Client`
   - Handles TLS, headers, timeouts
   - Connection pooling

2. **HubClient** (`src/lib.zig`)
   - Main entry point for library users
   - Coordinates API, cache, and download operations
   - Provides high-level convenience methods

3. **API Modules** (`src/api/*.zig`)
   - Low-level API operations
   - Direct mapping to HF Hub endpoints

4. **Downloader** (`src/downloader.zig`)
   - Streaming downloads with chunking
   - Partial download resume via `.part` files
   - Progress callbacks

5. **Cache** (`src/cache.zig`)
   - HF-compatible cache structure
   - File lookup and statistics

6. **Retry/RateLimiter** (`src/retry.zig`)
   - Token bucket rate limiting
   - Exponential backoff with jitter

## Adding Features

### Adding a New CLI Command

1. Create `src/cli/mycommand.zig`:

```zig
const std = @import("std");
const hf = @import("hf-hub");
const commands = @import("commands.zig");

pub const MyCommandOptions = struct {
    // command-specific options
};

pub fn parseOptions(args: []const []const u8) MyCommandOptions {
    // parse arguments
}

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    config: *hf.Config,
    global_opts: commands.GlobalOptions,
) commands.CommandResult {
    // implementation
}

pub fn printHelp(writer: anytype, use_color: bool) void {
    // help text
}
```

2. Add to `src/cli/commands.zig`:

```zig
const mycommand = @import("mycommand.zig");

pub const Command = enum {
    // ...
    mycommand,
};

// Add case in dispatch function
```

3. Add to `src/cli/main.zig` help text.

### Adding a New API Operation

1. Add function to appropriate API module (e.g., `src/api/models.zig`):

```zig
pub fn newOperation(self: *ModelsApi, param: []const u8) !Result {
    const path = try std.fmt.allocPrint(self.allocator, "/api/endpoint/{s}", .{param});
    defer self.allocator.free(path);
    
    const response = try self.client.get(path, null);
    defer response.deinit(self.allocator);
    
    // Parse and return
}
```

2. Expose through `HubClient` in `src/lib.zig`:

```zig
pub fn newOperation(self: *Self, param: []const u8) !Result {
    _ = self.rate_limiter.acquire();
    var api = api.ModelsApi.init(self.allocator, &self.http_client);
    return api.newOperation(param);
}
```

### Adding a New Type

1. Add to `src/types.zig`:

```zig
pub const NewType = struct {
    field1: []const u8,
    field2: ?u64 = null,
    
    pub fn deinit(self: *NewType, allocator: Allocator) void {
        allocator.free(self.field1);
    }
};
```

2. Add JSON parsing to `src/json.zig` if needed:

```zig
pub const RawNewType = struct {
    field1: []const u8 = "",
    field2: ?u64 = null,
};

pub fn toNewType(allocator: Allocator, raw: RawNewType) !types.NewType {
    return .{
        .field1 = try allocator.dupe(u8, raw.field1),
        .field2 = raw.field2,
    };
}
```

## Testing

### Unit Tests

Located in `src/*.zig` files and `tests/unit_tests.zig`.

```zig
test "descriptive test name" {
    const allocator = std.testing.allocator;
    
    // Test implementation
    try std.testing.expectEqual(expected, actual);
    try std.testing.expectEqualStrings("expected", actual);
}
```

Run specific tests:
```bash
zig build test -- --test-filter "Config"
```

### Integration Tests

Located in `tests/integration_tests.zig`. These require network access.

```zig
test "integration - search models" {
    // Skip if no network
    if (std.posix.getenv("SKIP_NETWORK_TESTS") != null) return;
    
    const allocator = std.testing.allocator;
    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();
    
    // Test real API calls
}
```

### Test Fixtures

Place mock data in `tests/fixtures/`:
- JSON response samples
- Model IDs for testing

## Code Style

### General Guidelines

1. **Error handling**: Always handle errors explicitly. Use `errdefer` for cleanup.

2. **Memory management**: Every allocation should have a clear owner and cleanup path.

3. **Naming**:
   - snake_case for functions and variables
   - PascalCase for types
   - SCREAMING_CASE for constants

4. **Comments**: Use doc comments (`///`) for public API.

### Formatting

Zig has a built-in formatter:

```bash
zig fmt src/
zig fmt tests/
```

### Error Messages

Provide context in error messages:

```zig
std.log.err("Failed to download {s}: {}", .{ filename, err });
```

## Debugging

### Enable Debug Logging

```zig
const std = @import("std");
pub const log_level: std.log.Level = .debug;
```

### Common Issues

1. **Connection timeouts**: Increase `HF_TIMEOUT` or check network.

2. **Rate limiting**: The library handles this automatically with backoff.

3. **Memory leaks**: Run tests with `std.testing.allocator` which detects leaks.

4. **JSON parsing failures**: Enable debug logging to see raw responses.

## Release Process

1. Update version in:
   - `build.zig.zon`
   - `src/lib.zig` (version constants)
   - `README.md` (if mentioned)

2. Run full test suite:
   ```bash
   zig build test
   zig build test-integration
   ```

3. Build release binaries:
   ```bash
   zig build -Doptimize=ReleaseFast
   ```

4. Tag the release:
   ```bash
   git tag -a v0.1.0 -m "Release v0.1.0"
   git push origin v0.1.0
   ```

## Contributing

### Pull Request Process

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes
4. Add/update tests
5. Run `zig fmt` and `zig build test`
6. Submit PR with clear description

### Commit Messages

Use conventional commits:

```
feat: add batch download support
fix: handle rate limit headers correctly
docs: update API reference
test: add integration tests for search
refactor: simplify cache path logic
```

### Review Checklist

- [ ] Code compiles without warnings
- [ ] All tests pass
- [ ] New features have tests
- [ ] Documentation updated
- [ ] No memory leaks (verified with testing allocator)
- [ ] Error cases handled

## Resources

- [Zig Documentation](https://ziglang.org/documentation/0.15.0/)
- [Zig Standard Library](https://ziglang.org/documentation/0.15.0/std/)
- [HuggingFace Hub API](https://huggingface.co/docs/hub/api)
- [HuggingFace Hub Python Client](https://github.com/huggingface/huggingface_hub) (reference)

## Getting Help

- Open an issue on GitHub
- Check existing issues and discussions
- Review the examples in `examples/`
