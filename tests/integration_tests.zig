//! Integration tests for hf-hub-zig library
//!
//! These tests require network access and make real API calls to HuggingFace Hub.
//! They are skipped by default in CI and can be run manually with:
//!
//!   zig build test-integration
//!
//! Set HF_TOKEN environment variable for tests that require authentication.
//!
//! To skip these tests (e.g., in CI without network), set:
//!   SKIP_NETWORK_TESTS=1

const std = @import("std");
const testing = std.testing;

const hf = @import("hf-hub");

var it_progress_called: bool = false;
fn it_cb(_: hf.DownloadProgress) void {
    it_progress_called = true;
}

// ============================================================================
// Test Utilities
// ============================================================================

/// Cross-platform environment variable check
fn hasEnvVar(allocator: std.mem.Allocator, name: []const u8) bool {
    const value = std.process.getEnvVarOwned(allocator, name) catch return false;
    allocator.free(value);
    return true;
}

/// Cross-platform environment variable getter (returns owned slice)
fn getEnvVar(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch return null;
}

fn shouldSkipNetworkTests(allocator: std.mem.Allocator) bool {
    return hasEnvVar(allocator, "SKIP_NETWORK_TESTS");
}

fn skipIfNoNetwork(allocator: std.mem.Allocator) !void {
    if (shouldSkipNetworkTests(allocator)) {
        return error.SkipZigTest;
    }
}

// ============================================================================
// Search Integration Tests
// ============================================================================

test "integration - search models returns results" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    var results = try client.search(.{
        .search = "llama",
        .limit = 5,
    });
    defer client.freeSearchResult(&results);

    // Should find at least one model
    try testing.expect(results.models.len > 0);
    try testing.expect(results.models.len <= 5);

    // First model should have an ID
    try testing.expect(results.models[0].id.len > 0);
}

test "integration - search GGUF models" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    var results = try client.searchGgufModels("mistral");
    defer client.freeSearchResult(&results);

    // Should find GGUF models
    try testing.expect(results.models.len > 0);
}

test "integration - search with pagination" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Get first page
    var page1 = try client.searchPaginated("llama", 5, 0);
    defer client.freeSearchResult(&page1);

    // Get second page
    var page2 = try client.searchPaginated("llama", 5, 5);
    defer client.freeSearchResult(&page2);

    // Both pages should have results
    try testing.expect(page1.models.len > 0);
    try testing.expect(page2.models.len > 0);

    // Results should be different (if there are enough models)
    if (page1.models.len > 0 and page2.models.len > 0) {
        try testing.expect(!std.mem.eql(u8, page1.models[0].id, page2.models[0].id));
    }
}

// ============================================================================
// Model Info Integration Tests
// ============================================================================

test "integration - get model info" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Use a well-known public model
    var model = try client.getModelInfo("google-bert/bert-base-uncased");
    defer client.freeModel(&model);

    try testing.expectEqualStrings("google-bert/bert-base-uncased", model.id);
    try testing.expect(!model.private);
}

test "integration - model exists" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Well-known model should exist
    const exists = try client.modelExists("google-bert/bert-base-uncased");
    try testing.expect(exists);

    // Non-existent model should not exist
    const not_exists = try client.modelExists("definitely-not-a-real-model-12345");
    try testing.expect(!not_exists);
}

test "integration - list model files" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    const files = try client.listFiles("google-bert/bert-base-uncased");
    defer client.freeFileInfoSlice(files);

    // Should have some files
    try testing.expect(files.len > 0);

    // Should have common files like config.json
    var has_config = false;
    for (files) |file| {
        if (std.mem.eql(u8, file.filename, "config.json")) {
            has_config = true;
            break;
        }
    }
    try testing.expect(has_config);
}

// ============================================================================
// Download Integration Tests
// ============================================================================

test "integration - download small file" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Create temp directory for download
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Download a small file (config.json is usually small)
    const path = try client.downloadFileWithOptions(
        "google-bert/bert-base-uncased",
        "config.json",
        "main",
        tmp_path,
        null,
    );
    defer allocator.free(path);

    // File should exist
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    // File should have content
    const stat = try file.stat();
    try testing.expect(stat.size > 0);
}

test "integration - download with progress callback" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    it_progress_called = false;

    const path = try client.downloadFileWithOptions(
        "google-bert/bert-base-uncased",
        "config.json",
        "main",
        tmp_path,
        it_cb,
    );
    defer allocator.free(path);

    // Progress callback should have been called
    try testing.expect(it_progress_called);
}

// ============================================================================
// User/Auth Integration Tests
// ============================================================================

test "integration - check authentication status" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // This should not crash regardless of auth status
    const is_auth = client.isAuthenticated();
    _ = is_auth;
}

test "integration - whoami with token" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    // Skip if no token available
    const token = getEnvVar(allocator, "HF_TOKEN") orelse return error.SkipZigTest;
    defer allocator.free(token);

    var client = try hf.createAuthenticatedClient(allocator, token);
    defer client.deinit();

    var user = try client.whoami();
    defer client.freeUser(&user);

    // Should have a username
    try testing.expect(user.username.len > 0);
}

// ============================================================================
// Cache Integration Tests
// ============================================================================

test "integration - cache workflow" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    // Create temp directory for cache
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create config with custom cache dir
    var config = try hf.Config.fromEnv(allocator);
    defer config.deinit();

    // Replace cache_dir
    if (config.cache_dir) |old| {
        if (config.allocated_fields.cache_dir) {
            allocator.free(old);
        }
    }
    config.cache_dir = try allocator.dupe(u8, tmp_path);
    config.allocated_fields.cache_dir = true;

    var client = try hf.HubClient.init(allocator, config);
    defer client.deinit();

    // Initially not cached
    const model_id = "bert-base-uncased";
    const filename = "config.json";
    const revision = "main";

    var is_cached = try client.isCached(model_id, filename, revision);
    try testing.expect(!is_cached);

    // Download to cache
    const cached_path = try client.downloadToCache(model_id, filename, revision, null);
    defer allocator.free(cached_path);

    // Now should be cached
    is_cached = try client.isCached(model_id, filename, revision);
    try testing.expect(is_cached);

    // Clear cache
    const freed = try client.clearCache();
    try testing.expect(freed > 0);

    // Should no longer be cached
    is_cached = try client.isCached(model_id, filename, revision);
    try testing.expect(!is_cached);
}

// ============================================================================
// Error Handling Integration Tests
// ============================================================================

test "integration - handle not found error" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    const result = client.getModelInfo("this-model-definitely-does-not-exist-12345");

    if (result) |_| {
        // Should not succeed
        try testing.expect(false);
    } else |err| {
        // Depending on Hub behavior, could be NotFound or Unauthorized
        const is_expected = (err == error.NotFound) or (err == error.Unauthorized);
        try testing.expect(is_expected);
    }
}

test "integration - handle unauthorized for private model without token" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    // Skip if we have a token (can't test unauthorized)
    if (hasEnvVar(allocator, "HF_TOKEN")) return error.SkipZigTest;

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Try to access a gated model without authentication
    // Note: This test might become flaky if the model becomes public
    const result = client.getModelInfo("meta-llama/Llama-2-7b-hf");

    if (result) |model| {
        // If it succeeds, the model might have become public
        var m = model;
        client.freeModel(&m);
    } else |err| {
        // Expected to fail with Unauthorized or Forbidden for gated models
        const is_expected = (err == error.Unauthorized) or
            (err == error.Forbidden) or
            (err == error.NotFound);
        try testing.expect(is_expected);
    }
}

// ============================================================================
// Rate Limiting Tests
// ============================================================================

test "integration - rate limiter prevents overwhelming API" {
    const allocator = testing.allocator;
    try skipIfNoNetwork(allocator);

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Make several rapid requests - should not get rate limited
    // because the client has built-in rate limiting
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const exists = try client.modelExists("google-bert/bert-base-uncased");
        try testing.expect(exists);
    }
}
