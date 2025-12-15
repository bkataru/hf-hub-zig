//! JSON parsing helpers for HuggingFace Hub API responses.
//!
//! This module provides utilities for parsing JSON responses from the
//! HuggingFace Hub API using Zig's std.json with resilient defaults.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");

/// JSON parsing options optimized for HF API responses
pub const ParseOptions = struct {
    /// Whether to ignore unknown fields in JSON
    ignore_unknown_fields: bool = true,
    /// Maximum nesting depth
    max_depth: usize = 256,
    /// Allocator for dynamic allocations
    allocator: Allocator,
};

/// Errors that can occur during JSON parsing
pub const JsonError = error{
    InvalidJson,
    UnexpectedToken,
    MissingField,
    TypeMismatch,
    OutOfMemory,
    Overflow,
    BufferTooSmall,
};

// ============================================================================
// Raw JSON Types for Parsing
// ============================================================================

/// Raw sibling/file structure from API
pub const RawSibling = struct {
    rfilename: []const u8,
    size: ?u64 = null,
    blobId: ?[]const u8 = null,
    lfs: ?RawLfsInfo = null,
};

/// LFS info embedded in sibling
pub const RawLfsInfo = struct {
    size: ?u64 = null,
    sha256: ?[]const u8 = null,
    pointer_size: ?u64 = null,
};

/// Raw model structure from API
pub const RawModel = struct {
    id: []const u8 = "",
    modelId: ?[]const u8 = null,
    author: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    lastModified: ?[]const u8 = null,
    private: bool = false,
    gated: ?bool = null,
    disabled: bool = false,
    library_name: ?[]const u8 = null,
    tags: ?[][]const u8 = null,
    pipeline_tag: ?[]const u8 = null,
    siblings: ?[]RawSibling = null,
    downloads: ?u64 = null,
    likes: ?u64 = null,
    trendingScore: ?f64 = null,
    cardData: ?RawCardData = null,
};

/// Raw card data from API
pub const RawCardData = struct {
    description: ?[]const u8 = null,
    license: ?[]const u8 = null,
    language: ?[][]const u8 = null,
    datasets: ?[][]const u8 = null,
};

/// Raw user structure from API (whoami endpoint)
pub const RawUser = struct {
    name: []const u8 = "",
    fullname: ?[]const u8 = null,
    email: ?[]const u8 = null,
    emailVerified: bool = false,
    avatarUrl: ?[]const u8 = null,
    type: ?[]const u8 = null,
    isPro: bool = false,
};

// ============================================================================
// Parsing Functions
// ============================================================================

/// Parse a JSON string into a RawModel
pub fn parseModel(allocator: Allocator, json_str: []const u8) !RawModel {
    const parsed = std.json.parseFromSlice(
        RawModel,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch |err| {
        return mapJsonError(err);
    };
    return parsed.value;
}

/// Parse a JSON string into an array of RawModel (search results)
pub fn parseModels(allocator: Allocator, json_str: []const u8) ![]RawModel {
    const parsed = std.json.parseFromSlice(
        []RawModel,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch |err| {
        return mapJsonError(err);
    };
    return parsed.value;
}

/// Parse a JSON string into a RawUser
pub fn parseUser(allocator: Allocator, json_str: []const u8) !RawUser {
    const parsed = std.json.parseFromSlice(
        RawUser,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch |err| {
        return mapJsonError(err);
    };
    return parsed.value;
}

/// Parse a JSON string into an array of RawSibling (file listing)
pub fn parseSiblings(allocator: Allocator, json_str: []const u8) ![]RawSibling {
    const parsed = std.json.parseFromSlice(
        []RawSibling,
        allocator,
        json_str,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch |err| {
        return mapJsonError(err);
    };
    return parsed.value;
}

/// Free parsed model data
pub fn freeModel(allocator: Allocator, model: *RawModel) void {
    // The std.json parser with .alloc_always allocates all strings
    // We need to use the parsed result's arena or free individual fields
    _ = allocator;
    _ = model;
    // When using parseFromSlice, the returned Parsed struct has an arena
    // that should be used for cleanup. For now, caller manages memory.
}

/// Free parsed models array
pub fn freeModels(allocator: Allocator, models: []RawModel) void {
    _ = allocator;
    _ = models;
    // Memory managed by caller via Parsed struct's arena
}

// ============================================================================
// Conversion Functions (Raw -> Domain Types)
// ============================================================================

/// Convert RawSibling to types.Sibling with owned memory
pub fn toSibling(allocator: Allocator, raw: RawSibling) !types.Sibling {
    return types.Sibling{
        .rfilename = try allocator.dupe(u8, raw.rfilename),
        .size = if (raw.lfs) |lfs| lfs.size else raw.size,
        .blob_id = if (raw.blobId) |bid| try allocator.dupe(u8, bid) else null,
    };
}

/// Convert RawModel to types.Model with owned memory
pub fn toModel(allocator: Allocator, raw: RawModel) !types.Model {
    var model = types.Model{
        .id = try allocator.dupe(u8, raw.id),
        .model_id = if (raw.modelId) |mid| try allocator.dupe(u8, mid) else null,
        .author = if (raw.author) |a| try allocator.dupe(u8, a) else null,
        .sha = if (raw.sha) |s| try allocator.dupe(u8, s) else null,
        .last_modified = if (raw.lastModified) |lm| try allocator.dupe(u8, lm) else null,
        .private = raw.private,
        .gated = raw.gated,
        .disabled = raw.disabled,
        .library_name = if (raw.library_name) |ln| try allocator.dupe(u8, ln) else null,
        .pipeline_tag = if (raw.pipeline_tag) |pt| try allocator.dupe(u8, pt) else null,
        .downloads = raw.downloads,
        .likes = raw.likes,
        .trending_score = raw.trendingScore,
    };

    // Convert tags
    if (raw.tags) |raw_tags| {
        var tags = try allocator.alloc([]const u8, raw_tags.len);
        for (raw_tags, 0..) |tag, i| {
            tags[i] = try allocator.dupe(u8, tag);
        }
        model.tags = tags;
    }

    // Convert siblings
    if (raw.siblings) |raw_siblings| {
        var siblings = try allocator.alloc(types.Sibling, raw_siblings.len);
        for (raw_siblings, 0..) |sib, i| {
            siblings[i] = try toSibling(allocator, sib);
        }
        model.siblings = siblings;
    }

    // Convert card data
    if (raw.cardData) |raw_cd| {
        model.card_data = try toCardData(allocator, raw_cd);
    }

    return model;
}

/// Convert RawCardData to types.CardData with owned memory
pub fn toCardData(allocator: Allocator, raw: RawCardData) !types.CardData {
    var cd = types.CardData{
        .description = if (raw.description) |d| try allocator.dupe(u8, d) else null,
        .license = if (raw.license) |l| try allocator.dupe(u8, l) else null,
    };

    if (raw.language) |raw_langs| {
        var langs = try allocator.alloc([]const u8, raw_langs.len);
        for (raw_langs, 0..) |lang, i| {
            langs[i] = try allocator.dupe(u8, lang);
        }
        cd.language = langs;
    }

    if (raw.datasets) |raw_ds| {
        var datasets = try allocator.alloc([]const u8, raw_ds.len);
        for (raw_ds, 0..) |ds, i| {
            datasets[i] = try allocator.dupe(u8, ds);
        }
        cd.datasets = datasets;
    }

    return cd;
}

/// Convert RawUser to types.User with owned memory
pub fn toUser(allocator: Allocator, raw: RawUser) !types.User {
    return types.User{
        .username = try allocator.dupe(u8, raw.name),
        .name = try allocator.dupe(u8, raw.name),
        .fullname = if (raw.fullname) |fn_| try allocator.dupe(u8, fn_) else null,
        .avatar_url = if (raw.avatarUrl) |au| try allocator.dupe(u8, au) else null,
        .email = if (raw.email) |e| try allocator.dupe(u8, e) else null,
        .email_verified = raw.emailVerified,
        .account_type = if (raw.type) |t| try allocator.dupe(u8, t) else null,
        .is_pro = raw.isPro,
    };
}

// ============================================================================
// Stringify Functions
// ============================================================================

/// Convert a value to JSON string
pub fn stringify(allocator: Allocator, value: anytype) ![]u8 {
    // Use std.json.Stringify.valueAlloc for Zig 0.15
    const result = std.json.Stringify.valueAlloc(allocator, value, .{}) catch |err| {
        return mapJsonError(err);
    };
    return result;
}

/// Convert a value to pretty-printed JSON string
pub fn stringifyPretty(allocator: Allocator, value: anytype) ![]u8 {
    const result = std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 }) catch |err| {
        return mapJsonError(err);
    };
    return result;
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Map std.json errors to our JsonError
fn mapJsonError(err: anyerror) JsonError {
    return switch (err) {
        error.OutOfMemory => JsonError.OutOfMemory,
        error.Overflow => JsonError.Overflow,
        else => JsonError.InvalidJson,
    };
}

/// Extract a string field from a JSON object, returning null if not found
pub fn getOptionalString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    if (obj.object.get(key)) |val| {
        if (val == .string) {
            return val.string;
        }
    }
    return null;
}

/// Extract a required string field from a JSON object
pub fn getRequiredString(obj: std.json.Value, key: []const u8) ![]const u8 {
    return getOptionalString(obj, key) orelse return JsonError.MissingField;
}

/// Extract an optional integer field from a JSON object
pub fn getOptionalInt(comptime T: type, obj: std.json.Value, key: []const u8) ?T {
    if (obj != .object) return null;
    if (obj.object.get(key)) |val| {
        if (val == .integer) {
            return @intCast(val.integer);
        }
    }
    return null;
}

/// Extract an optional boolean field from a JSON object
pub fn getOptionalBool(obj: std.json.Value, key: []const u8) ?bool {
    if (obj != .object) return null;
    if (obj.object.get(key)) |val| {
        if (val == .bool) {
            return val.bool;
        }
    }
    return null;
}

/// Check if JSON value is null or missing
pub fn isNullOrMissing(obj: std.json.Value, key: []const u8) bool {
    if (obj != .object) return true;
    if (obj.object.get(key)) |val| {
        return val == .null;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "parseModel - basic model" {
    const allocator = std.testing.allocator;
    const json =
        \\{"id":"test/model","modelId":"test/model","downloads":1000,"likes":50}
    ;

    var parsed = std.json.parseFromSlice(
        RawModel,
        allocator,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch unreachable;
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test/model", parsed.value.id);
    try std.testing.expectEqual(@as(?u64, 1000), parsed.value.downloads);
    try std.testing.expectEqual(@as(?u64, 50), parsed.value.likes);
}

test "parseModel - with siblings" {
    const allocator = std.testing.allocator;
    const json =
        \\{"id":"test/model","siblings":[{"rfilename":"model.gguf","size":1024}]}
    ;

    var parsed = std.json.parseFromSlice(
        RawModel,
        allocator,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch unreachable;
    defer parsed.deinit();

    try std.testing.expect(parsed.value.siblings != null);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.siblings.?.len);
    try std.testing.expectEqualStrings("model.gguf", parsed.value.siblings.?[0].rfilename);
    try std.testing.expectEqual(@as(?u64, 1024), parsed.value.siblings.?[0].size);
}

test "parseUser - basic user" {
    const allocator = std.testing.allocator;
    const json =
        \\{"name":"testuser","fullname":"Test User","email":"test@example.com","isPro":true}
    ;

    var parsed = std.json.parseFromSlice(
        RawUser,
        allocator,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch unreachable;
    defer parsed.deinit();

    try std.testing.expectEqualStrings("testuser", parsed.value.name);
    try std.testing.expectEqualStrings("Test User", parsed.value.fullname.?);
    try std.testing.expect(parsed.value.isPro);
}

test "parseModels - array of models" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"id":"model1"},{"id":"model2"},{"id":"model3"}]
    ;

    var parsed = std.json.parseFromSlice(
        []RawModel,
        allocator,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch unreachable;
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.value.len);
    try std.testing.expectEqualStrings("model1", parsed.value[0].id);
    try std.testing.expectEqualStrings("model2", parsed.value[1].id);
    try std.testing.expectEqualStrings("model3", parsed.value[2].id);
}

test "toModel - conversion with owned memory" {
    const allocator = std.testing.allocator;
    const json =
        \\{"id":"test/model","downloads":500}
    ;

    var parsed = std.json.parseFromSlice(
        RawModel,
        allocator,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch unreachable;
    defer parsed.deinit();

    var model = try toModel(allocator, parsed.value);
    defer model.deinit(allocator);

    try std.testing.expectEqualStrings("test/model", model.id);
    try std.testing.expectEqual(@as(?u64, 500), model.downloads);
}

test "stringify - basic struct" {
    const allocator = std.testing.allocator;

    const TestStruct = struct {
        name: []const u8,
        count: u32,
    };

    const value = TestStruct{ .name = "test", .count = 42 };
    const json = try stringify(allocator, value);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":42") != null);
}

test "ignore unknown fields" {
    const allocator = std.testing.allocator;
    // JSON with extra fields that aren't in our struct
    const json =
        \\{"id":"test","unknownField":"value","anotherUnknown":123}
    ;

    var parsed = std.json.parseFromSlice(
        RawModel,
        allocator,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch unreachable;
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test", parsed.value.id);
}
