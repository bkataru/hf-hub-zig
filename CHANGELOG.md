# Changelog

All notable changes to hf-hub-zig will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-12-15

### Added
- Initial release of hf-hub-zig
- **Library Features:**
  - `HubClient` - Unified client for all HuggingFace Hub operations
  - Model search with GGUF filtering and sorting
  - File listing and metadata retrieval
  - Streaming downloads with progress tracking
  - Resume support for interrupted downloads
  - Token-based authentication for private models
  - Smart local caching (HF-compatible structure)
  - Automatic rate limiting (token bucket algorithm)
  - Retry logic with exponential backoff
- **CLI Commands:**
  - `search` - Find models with powerful filtering
  - `download` - Download files with parallel support
  - `list` - List repository files
  - `info` - Get model details
  - `cache` - Manage local cache (info, clear, clean, dir)
  - `user` - Show authenticated user info
- **Documentation:**
  - Complete API reference
  - CLI reference guide
  - Development guide
  - Usage examples

### Fixed
- **Zig 0.15.2 Compatibility:**
  - Updated `callconv(.C)` to `callconv(.c)` for signal handlers
  - Fixed `sigemptyset` function call for new POSIX API
  - Updated `winsize` struct field access (`ws_col` → `col`, `ws_row` → `row`)
  - Fixed HTTP client to use `std.Io.Limit` enum with `.unlimited` variant
  - Fixed response content-length access via `response.head.content_length`
  - Fixed response reader mutability requirements

### Technical Notes
- Built with Zig 0.15.2
- Pure Zig implementation with zero external dependencies
- Uses `std.http.Client` for HTTP operations
- Uses `std.Io.Reader` for streaming downloads

[0.1.0]: https://github.com/bkataru/hf-hub-zig/releases/tag/v0.1.0
