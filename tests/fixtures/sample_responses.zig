//! Sample API Responses for Testing
//!
//! This module provides mock JSON responses that mirror the HuggingFace Hub API.
//! These are used for unit testing to avoid network calls.

const std = @import("std");

/// Sample search response with multiple models
pub const SAMPLE_SEARCH_RESPONSE =
    \\[
    \\  {
    \\    "id": "TheBloke/Llama-2-7B-GGUF",
    \\    "modelId": "TheBloke/Llama-2-7B-GGUF",
    \\    "author": "TheBloke",
    \\    "lastModified": "2024-01-15T10:30:00Z",
    \\    "private": false,
    \\    "downloads": 1234567,
    \\    "likes": 2345,
    \\    "tags": ["gguf", "llama", "llama-2", "text-generation"],
    \\    "pipeline_tag": "text-generation",
    \\    "library_name": "transformers",
    \\    "siblings": [
    \\      {"rfilename": "llama-2-7b.Q4_K_M.gguf", "size": 4081004544},
    \\      {"rfilename": "llama-2-7b.Q5_K_M.gguf", "size": 4783157248},
    \\      {"rfilename": "config.json", "size": 564}
    \\    ]
    \\  },
    \\  {
    \\    "id": "TheBloke/Mistral-7B-v0.1-GGUF",
    \\    "modelId": "TheBloke/Mistral-7B-v0.1-GGUF",
    \\    "author": "TheBloke",
    \\    "lastModified": "2024-01-10T08:15:00Z",
    \\    "private": false,
    \\    "downloads": 987654,
    \\    "likes": 1234,
    \\    "tags": ["gguf", "mistral", "text-generation"],
    \\    "pipeline_tag": "text-generation"
    \\  }
    \\]
;

/// Sample single model response
pub const SAMPLE_MODEL_RESPONSE =
    \\{
    \\  "id": "bert-base-uncased",
    \\  "modelId": "bert-base-uncased",
    \\  "author": "google",
    \\  "sha": "abc123def456",
    \\  "lastModified": "2023-06-20T12:00:00Z",
    \\  "private": false,
    \\  "gated": false,
    \\  "disabled": false,
    \\  "downloads": 50000000,
    \\  "likes": 10000,
    \\  "tags": ["bert", "transformers", "pytorch", "en", "fill-mask"],
    \\  "pipeline_tag": "fill-mask",
    \\  "library_name": "transformers",
    \\  "siblings": [
    \\    {"rfilename": "config.json", "size": 570},
    \\    {"rfilename": "model.safetensors", "size": 440473133},
    \\    {"rfilename": "tokenizer.json", "size": 466062},
    \\    {"rfilename": "vocab.txt", "size": 231508}
    \\  ],
    \\  "cardData": {
    \\    "description": "BERT base model (uncased)",
    \\    "license": "apache-2.0",
    \\    "language": ["en"]
    \\  }
    \\}
;

/// Sample GGUF model with LFS info
pub const SAMPLE_GGUF_MODEL_RESPONSE =
    \\{
    \\  "id": "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
    \\  "modelId": "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
    \\  "author": "TheBloke",
    \\  "sha": "def789abc123",
    \\  "lastModified": "2024-02-01T15:30:00Z",
    \\  "private": false,
    \\  "downloads": 500000,
    \\  "likes": 750,
    \\  "tags": ["gguf", "tinyllama", "llama", "text-generation", "conversational"],
    \\  "pipeline_tag": "text-generation",
    \\  "siblings": [
    \\    {
    \\      "rfilename": "tinyllama-1.1b-chat-v1.0.Q2_K.gguf",
    \\      "size": 482939904,
    \\      "lfs": {"size": 482939904, "sha256": "abc123..."}
    \\    },
    \\    {
    \\      "rfilename": "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
    \\      "size": 668667904,
    \\      "lfs": {"size": 668667904, "sha256": "def456..."}
    \\    },
    \\    {
    \\      "rfilename": "tinyllama-1.1b-chat-v1.0.Q5_K_M.gguf",
    \\      "size": 782098432,
    \\      "lfs": {"size": 782098432, "sha256": "ghi789..."}
    \\    },
    \\    {
    \\      "rfilename": "config.json", "size": 996},
    \\    {"rfilename": "README.md", "size": 35621}
    \\  ]
    \\}
;

/// Sample user/whoami response
pub const SAMPLE_USER_RESPONSE =
    \\{
    \\  "name": "johndoe",
    \\  "fullname": "John Doe",
    \\  "email": "john@example.com",
    \\  "emailVerified": true,
    \\  "avatarUrl": "https://huggingface.co/avatars/johndoe.png",
    \\  "type": "user",
    \\  "isPro": true
    \\}
;

/// Sample user response for free account
pub const SAMPLE_USER_FREE_RESPONSE =
    \\{
    \\  "name": "freeuser",
    \\  "fullname": "Free User",
    \\  "email": "free@example.com",
    \\  "emailVerified": true,
    \\  "type": "user",
    \\  "isPro": false
    \\}
;

/// Sample private/gated model response
pub const SAMPLE_GATED_MODEL_RESPONSE =
    \\{
    \\  "id": "meta-llama/Llama-2-7b-hf",
    \\  "modelId": "meta-llama/Llama-2-7b-hf",
    \\  "author": "meta-llama",
    \\  "sha": "gated123abc",
    \\  "lastModified": "2023-07-18T00:00:00Z",
    \\  "private": false,
    \\  "gated": true,
    \\  "downloads": 10000000,
    \\  "likes": 5000,
    \\  "tags": ["llama", "llama-2", "text-generation", "pytorch"],
    \\  "pipeline_tag": "text-generation",
    \\  "library_name": "transformers"
    \\}
;

/// Sample empty search response
pub const SAMPLE_EMPTY_SEARCH_RESPONSE =
    \\[]
;

/// Sample model with minimal fields (tests optional field handling)
pub const SAMPLE_MINIMAL_MODEL_RESPONSE =
    \\{
    \\  "id": "minimal/model"
    \\}
;

/// Sample model with all optional fields null
pub const SAMPLE_MODEL_WITH_NULLS =
    \\{
    \\  "id": "test/nulls-model",
    \\  "modelId": null,
    \\  "author": null,
    \\  "downloads": null,
    \\  "likes": null,
    \\  "tags": null,
    \\  "siblings": null
    \\}
;

/// Sample siblings/files list response
pub const SAMPLE_SIBLINGS_RESPONSE =
    \\[
    \\  {"rfilename": "config.json", "size": 1024},
    \\  {"rfilename": "model.safetensors", "size": 5368709120},
    \\  {"rfilename": "tokenizer.json", "size": 2048},
    \\  {"rfilename": "model.gguf", "size": 4294967296}
    \\]
;

/// Sample error response (401 Unauthorized)
pub const SAMPLE_ERROR_UNAUTHORIZED =
    \\{
    \\  "error": "Unauthorized"
    \\}
;

/// Sample error response (404 Not Found)
pub const SAMPLE_ERROR_NOT_FOUND =
    \\{
    \\  "error": "Repository Not Found"
    \\}
;

/// Sample error response (403 Forbidden - gated model)
pub const SAMPLE_ERROR_FORBIDDEN_GATED =
    \\{
    \\  "error": "Access to model meta-llama/Llama-2-7b-hf is restricted. You must be authenticated to access it."
    \\}
;

// ============================================================================
// Test Model IDs
// ============================================================================

/// Well-known public models for integration testing
pub const TEST_PUBLIC_MODELS = [_][]const u8{
    "bert-base-uncased",
    "gpt2",
    "distilbert-base-uncased",
    "microsoft/phi-2",
};

/// Well-known GGUF models for integration testing
pub const TEST_GGUF_MODELS = [_][]const u8{
    "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
    "TheBloke/Llama-2-7B-GGUF",
    "TheBloke/Mistral-7B-v0.1-GGUF",
};

/// Well-known gated models (require authentication)
pub const TEST_GATED_MODELS = [_][]const u8{
    "meta-llama/Llama-2-7b-hf",
    "meta-llama/Llama-2-13b-hf",
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Parse a sample response for testing
pub fn parseSampleModel(allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(SampleModel) {
    return std.json.parseFromSlice(
        SampleModel,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}

/// Simplified model structure for testing
pub const SampleModel = struct {
    id: []const u8 = "",
    modelId: ?[]const u8 = null,
    author: ?[]const u8 = null,
    downloads: ?u64 = null,
    likes: ?u64 = null,
    private: bool = false,
    gated: ?bool = null,
};

// ============================================================================
// Tests
// ============================================================================

test "parse sample search response" {
    const allocator = std.testing.allocator;

    const parsed = try std.json.parseFromSlice(
        []SampleModel,
        allocator,
        SAMPLE_SEARCH_RESPONSE,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.len);
    try std.testing.expectEqualStrings("TheBloke/Llama-2-7B-GGUF", parsed.value[0].id);
    try std.testing.expectEqual(@as(?u64, 1234567), parsed.value[0].downloads);
}

test "parse sample model response" {
    const allocator = std.testing.allocator;

    const parsed = try std.json.parseFromSlice(
        SampleModel,
        allocator,
        SAMPLE_MODEL_RESPONSE,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("bert-base-uncased", parsed.value.id);
    try std.testing.expectEqualStrings("google", parsed.value.author.?);
    try std.testing.expect(!parsed.value.private);
}

test "parse minimal model response" {
    const allocator = std.testing.allocator;

    const parsed = try std.json.parseFromSlice(
        SampleModel,
        allocator,
        SAMPLE_MINIMAL_MODEL_RESPONSE,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("minimal/model", parsed.value.id);
    try std.testing.expect(parsed.value.author == null);
    try std.testing.expect(parsed.value.downloads == null);
}

test "parse empty search response" {
    const allocator = std.testing.allocator;

    const parsed = try std.json.parseFromSlice(
        []SampleModel,
        allocator,
        SAMPLE_EMPTY_SEARCH_RESPONSE,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.value.len);
}
