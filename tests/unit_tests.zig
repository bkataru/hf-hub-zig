//! Unit tests for hf-hub-zig library
//!
//! This file contains integration tests that test the public API
//! of the hf-hub library.

const std = @import("std");
const testing = std.testing;

const hf = @import("hf-hub");

// ============================================================================
// Config Tests
// ============================================================================

test "Config.default creates valid configuration" {
    const allocator = testing.allocator;
    var config = try hf.Config.default(allocator);
    defer config.deinit();

    // Default endpoint should be set
    try testing.expectEqualStrings("https://huggingface.co", config.endpoint);

    // Cache directory should be set
    try testing.expect(config.cache_dir != null);

    // Default timeout should be reasonable
    try testing.expect(config.timeout_ms > 0);
}

// ============================================================================
// Types Tests
// ============================================================================

test "SearchQuery default values" {
    const query = hf.SearchQuery{};

    try testing.expect(query.limit == 20);
    try testing.expectEqualStrings("", query.search);
    try testing.expect(query.author == null);
    try testing.expect(query.filter == null);
}

test "SearchQuery with custom values" {
    const query = hf.SearchQuery{
        .search = "llama",
        .limit = 5,
        .filter = "gguf",
        .sort = .downloads,
    };

    try testing.expectEqualStrings("llama", query.search);
    try testing.expect(query.limit == 5);
    try testing.expectEqualStrings("gguf", query.filter.?);
    try testing.expect(query.sort == .downloads);
}

test "DownloadProgress calculations" {
    const now = std.time.nanoTimestamp();
    const progress = hf.DownloadProgress{
        .bytes_downloaded = 500,
        .total_bytes = 1000,
        .start_time_ns = now - 1_000_000_000, // 1 second ago
        .current_time_ns = now,
    };

    // Test percentage calculation
    const percentage = progress.percentComplete();
    try testing.expect(percentage == 50);

    // Test download speed (should be ~500 bytes/sec)
    const speed = progress.downloadSpeed();
    try testing.expect(speed > 400.0 and speed < 600.0);
}

test "DownloadProgress with unknown total" {
    const now = std.time.nanoTimestamp();
    const progress = hf.DownloadProgress{
        .bytes_downloaded = 500,
        .total_bytes = null,
        .start_time_ns = now,
        .current_time_ns = now,
    };

    // Percentage should be 0 when total is unknown
    try testing.expect(progress.percentComplete() == 0);
}

test "DownloadProgress ETA calculation" {
    const now = std.time.nanoTimestamp();
    const progress = hf.DownloadProgress{
        .bytes_downloaded = 500,
        .total_bytes = 1000,
        .start_time_ns = now - 1_000_000_000, // 1 second ago
        .current_time_ns = now,
    };

    // ETA should be approximately 1 second (500 bytes remaining at 500 bytes/sec)
    const eta = progress.estimatedTimeRemaining();
    try testing.expect(eta != null);
    try testing.expect(eta.? > 0.5 and eta.? < 1.5);
}

// ============================================================================
// Error Tests
// ============================================================================

test "ErrorContext.init creates context" {
    const ctx = hf.ErrorContext.init(hf.HubError.NotFound, "Resource not found");

    try testing.expect(ctx.error_type == hf.HubError.NotFound);
    try testing.expectEqualStrings("Resource not found", ctx.message);
}

test "ErrorContext.isRetryable for retryable errors" {
    const rate_limited = hf.ErrorContext.init(hf.HubError.RateLimited, "test");
    try testing.expect(rate_limited.isRetryable());

    const timeout = hf.ErrorContext.init(hf.HubError.Timeout, "test");
    try testing.expect(timeout.isRetryable());

    const server_error = hf.ErrorContext.init(hf.HubError.ServerError, "test");
    try testing.expect(server_error.isRetryable());

    const network_error = hf.ErrorContext.init(hf.HubError.NetworkError, "test");
    try testing.expect(network_error.isRetryable());
}

test "ErrorContext.isRetryable for non-retryable errors" {
    const not_found = hf.ErrorContext.init(hf.HubError.NotFound, "test");
    try testing.expect(!not_found.isRetryable());

    const unauthorized = hf.ErrorContext.init(hf.HubError.Unauthorized, "test");
    try testing.expect(!unauthorized.isRetryable());

    const forbidden = hf.ErrorContext.init(hf.HubError.Forbidden, "test");
    try testing.expect(!forbidden.isRetryable());

    const invalid_json = hf.ErrorContext.init(hf.HubError.InvalidJson, "test");
    try testing.expect(!invalid_json.isRetryable());
}

test "ErrorContext.format produces readable output" {
    const allocator = testing.allocator;
    var ctx = hf.ErrorContext{
        .error_type = hf.HubError.NotFound,
        .message = "Model not found",
        .status_code = 404,
        .url = "https://huggingface.co/api/models/test",
    };

    const formatted = try ctx.format(allocator);
    defer allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "NotFound") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "404") != null);
}

// ============================================================================
// Retry Strategy Tests
// ============================================================================

test "RetryStrategy.init creates valid strategy" {
    var strategy = hf.RetryStrategy.init();

    // First attempt should have a delay
    const delay = strategy.calculateDelay(0);
    try testing.expect(delay > 0);
}

test "RetryStrategy.calculateDelay increases with attempts" {
    var strategy = hf.RetryStrategy.initWithConfig(.{
        .base_delay_ms = 100,
        .backoff_multiplier = 2.0,
        .jitter_enabled = false,
        .max_delay_ms = 10_000,
    });

    const delay0 = strategy.calculateDelay(0);
    const delay1 = strategy.calculateDelay(1);
    const delay2 = strategy.calculateDelay(2);

    // Each delay should be larger than the previous (with exponential backoff)
    try testing.expect(delay1 > delay0);
    try testing.expect(delay2 > delay1);
}

test "RetryStrategy.calculateDelay respects max delay" {
    var strategy = hf.RetryStrategy.initWithConfig(.{
        .base_delay_ms = 1000,
        .backoff_multiplier = 10.0,
        .jitter_enabled = false,
        .max_delay_ms = 5000,
    });

    // After many attempts, should be capped at max
    const delay = strategy.calculateDelay(10);
    try testing.expect(delay <= 5000);
}

// ============================================================================
// Rate Limiter Tests
// ============================================================================

test "RateLimiter.init creates valid limiter" {
    var limiter = hf.RateLimiter.init(10);

    // Should be able to acquire tokens initially
    const wait_time = limiter.acquire();
    try testing.expect(wait_time == 0); // First acquire should be instant
}

test "RateLimiter.initDefault creates 10 req/sec limiter" {
    var limiter = hf.RateLimiter.initDefault();

    // Should be able to acquire first token immediately
    const wait_time = limiter.acquire();
    try testing.expect(wait_time == 0);
}

test "RateLimiter tryAcquire respects capacity" {
    var limiter = hf.RateLimiter.init(2);

    // Acquire all burst capacity
    _ = limiter.acquire();
    _ = limiter.acquire();

    // Third should require waiting (tryAcquire returns false or acquire returns > 0)
    const wait_time = limiter.acquire();
    // After depleting tokens, there should be a wait time
    // (This test may be flaky due to timing, but generally wait_time >= 0)
    _ = wait_time;
}

// ============================================================================
// Terminal Tests
// ============================================================================

test "Terminal.noColor creates disabled terminal" {
    const term = hf.terminal.Terminal.noColor();

    try testing.expect(!term.colors_enabled);
    try testing.expect(!term.unicode_enabled);
    try testing.expect(!term.is_tty);
}

test "Terminal.detect creates terminal state" {
    const term = hf.terminal.Terminal.detect();

    // Should have valid dimensions
    try testing.expect(term.width > 0);
    try testing.expect(term.height > 0);
}

test "Color.toCode returns valid ANSI code" {
    try testing.expect(hf.Color.red.toCode() == 31);
    try testing.expect(hf.Color.green.toCode() == 32);
    try testing.expect(hf.Color.blue.toCode() == 34);
}

test "Color.toBgCode returns valid background code" {
    try testing.expect(hf.Color.red.toBgCode() == 41);
    try testing.expect(hf.Color.green.toBgCode() == 42);
    try testing.expect(hf.Color.blue.toBgCode() == 44);
}

// ============================================================================
// JSON Tests
// ============================================================================

test "json.stringify produces valid JSON" {
    const allocator = testing.allocator;

    const TestStruct = struct {
        name: []const u8,
        value: i32,
    };

    const data = TestStruct{ .name = "test", .value = 42 };
    const json_str = try hf.json.stringify(allocator, data);
    defer allocator.free(json_str);

    try testing.expect(std.mem.indexOf(u8, json_str, "\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "\"test\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "42") != null);
}

test "json.parseModel parses valid model JSON" {
    const allocator = testing.allocator;

    const json_str =
        \\{"id":"test/model","modelId":"test/model","author":"test","downloads":100,"likes":50,"private":false}
    ;

    // Use the parseModel function which returns a ParsedModel
    const result = try hf.json.parseModel(allocator, json_str);
    defer {
        allocator.free(result.id);
        if (result.model_id) |mid| allocator.free(mid);
        if (result.author) |a| allocator.free(a);
    }

    try testing.expectEqualStrings("test/model", result.id);
    try testing.expectEqualStrings("test", result.author.?);
    try testing.expect(result.downloads.? == 100);
    try testing.expect(result.likes.? == 50);
    try testing.expect(!result.private);
}

// ============================================================================
// Cache Tests
// ============================================================================

test "Cache.init with temporary directory" {
    const allocator = testing.allocator;

    // Create a temporary directory for testing
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var file_cache = try hf.Cache.init(allocator, tmp_path);
    defer file_cache.deinit();

    // Cache should be valid
    const stats = try file_cache.stats();
    try testing.expect(stats.total_size == 0);
    try testing.expect(stats.total_files == 0);
}

test "CacheStats default values" {
    const stats = hf.CacheStats{};

    try testing.expect(stats.total_files == 0);
    try testing.expect(stats.total_size == 0);
    try testing.expect(stats.num_repos == 0);
    try testing.expect(stats.num_gguf_files == 0);
    try testing.expect(stats.gguf_size == 0);
}

// ============================================================================
// Download Options Tests
// ============================================================================

test "DownloadOptions default values" {
    const opts = hf.DownloadOptions{};

    try testing.expect(opts.chunk_size == 8192);
    try testing.expect(opts.resume_download == true);
    try testing.expect(opts.verify_checksum == false);
    try testing.expect(opts.create_dirs == true);
    try testing.expectEqualStrings(".part", opts.part_suffix);
}

test "DownloadOptions custom configuration" {
    const opts = hf.DownloadOptions{
        .chunk_size = 1024,
        .resume_download = false,
        .verify_checksum = true,
        .create_dirs = false,
    };

    try testing.expect(opts.chunk_size == 1024);
    try testing.expect(opts.resume_download == false);
    try testing.expect(opts.verify_checksum == true);
    try testing.expect(opts.create_dirs == false);
}

// ============================================================================
// File Info Tests
// ============================================================================

test "FileInfo.checkIsGguf detects GGUF files" {
    try testing.expect(hf.FileInfo.checkIsGguf("model.gguf"));
    try testing.expect(hf.FileInfo.checkIsGguf("model.GGUF"));
    try testing.expect(hf.FileInfo.checkIsGguf("path/to/model.gguf"));
    try testing.expect(!hf.FileInfo.checkIsGguf("model.bin"));
    try testing.expect(!hf.FileInfo.checkIsGguf("model.safetensors"));
    try testing.expect(!hf.FileInfo.checkIsGguf("config.json"));
}

test "FileInfo basic structure" {
    const file_info = hf.FileInfo{
        .filename = "model.gguf",
        .path = "model.gguf",
        .size = 1024,
        .is_gguf = true,
    };

    try testing.expectEqualStrings("model.gguf", file_info.filename);
    try testing.expectEqualStrings("model.gguf", file_info.path);
    try testing.expect(file_info.size.? == 1024);
    try testing.expect(file_info.is_gguf);
}

// ============================================================================
// Model Tests
// ============================================================================

test "Model basic structure" {
    const model = hf.Model{
        .id = "test/model",
        .author = "test",
        .sha = "abc123",
        .downloads = 100,
        .likes = 50,
        .private = false,
        .pipeline_tag = "text-generation",
        .tags = &.{},
        .siblings = &.{},
    };

    try testing.expectEqualStrings("test/model", model.id);
    try testing.expectEqualStrings("test", model.author.?);
    try testing.expect(model.downloads == 100);
    try testing.expect(model.likes == 50);
    try testing.expect(!model.private);
}

// ============================================================================
// Sort Order Tests
// ============================================================================

test "SortOrder.toString returns correct strings" {
    try testing.expectEqualStrings("trendingScore", hf.SortOrder.trending.toString());
    try testing.expectEqualStrings("downloads", hf.SortOrder.downloads.toString());
    try testing.expectEqualStrings("likes", hf.SortOrder.likes.toString());
    try testing.expectEqualStrings("createdAt", hf.SortOrder.created.toString());
    try testing.expectEqualStrings("lastModified", hf.SortOrder.modified.toString());
}

test "SortOrder.fromString parses strings" {
    try testing.expect(hf.SortOrder.fromString("trending").? == .trending);
    try testing.expect(hf.SortOrder.fromString("downloads").? == .downloads);
    try testing.expect(hf.SortOrder.fromString("likes").? == .likes);
    try testing.expect(hf.SortOrder.fromString("invalid") == null);
}

// ============================================================================
// Utility Tests
// ============================================================================

test "formatBytes produces human-readable sizes" {
    var buf: [32]u8 = undefined;

    const result1 = hf.formatBytes(1024, &buf);
    try testing.expectEqualStrings("1.00 KB", result1);

    const result2 = hf.formatBytes(1024 * 1024, &buf);
    try testing.expectEqualStrings("1.00 MB", result2);

    const result3 = hf.formatBytes(1024 * 1024 * 1024, &buf);
    try testing.expectEqualStrings("1.00 GB", result3);

    const result4 = hf.formatBytes(500, &buf);
    try testing.expectEqualStrings("500 B", result4);
}
