//! JSON parsing helpers for HuggingFace Hub API responses.
//!
//! This module provides utilities for parsing JSON responses from the
//! HuggingFace Hub API using Zig's std.json with resilient defaults.
//!
//! The HuggingFace API can return fields in multiple formats:
//! - `language` can be a string ("en") or array (["en", "fr"])
//! - `datasets` can be a string or array
//! This module handles both cases gracefully.

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
// Flexible Parsing for Models (handles string/array polymorphism)
// ============================================================================

/// Parsed model with all fields properly converted
pub const ParsedModel = struct {
    id: []const u8,
    model_id: ?[]const u8 = null,
    author: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    private: bool = false,
    gated: ?bool = null,
    disabled: bool = false,
    library_name: ?[]const u8 = null,
    tags: ?[][]const u8 = null,
    pipeline_tag: ?[]const u8 = null,
    siblings: ?[]OwnedSibling = null,
    downloads: ?u64 = null,
    likes: ?u64 = null,
    trending_score: ?f64 = null,
    // Card data fields - flattened for easier handling
    description: ?[]const u8 = null,
    license: ?[]const u8 = null,
    language: ?[][]const u8 = null,
    datasets: ?[][]const u8 = null,
};

/// Parse a JSON string into a model, handling polymorphic fields
pub fn parseModel(allocator: Allocator, json_str: []const u8) !ParsedModel {
    // First, parse as dynamic JSON to handle polymorphic fields
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_str,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        return mapJsonError(err);
    };
    defer parsed.deinit();

    return parseModelFromValue(allocator, parsed.value);
}

/// Parse a model from a JSON Value
fn parseModelFromValue(allocator: Allocator, value: std.json.Value) !ParsedModel {
    if (value != .object) {
        return JsonError.InvalidJson;
    }

    const obj = value.object;

    var model = ParsedModel{
        .id = try dupeString(allocator, getStringField(obj, "id") orelse ""),
    };
    errdefer allocator.free(model.id);

    // Simple string fields
    if (getStringField(obj, "modelId")) |v| {
        model.model_id = try allocator.dupe(u8, v);
    }
    if (getStringField(obj, "author")) |v| {
        model.author = try allocator.dupe(u8, v);
    }
    if (getStringField(obj, "sha")) |v| {
        model.sha = try allocator.dupe(u8, v);
    }
    if (getStringField(obj, "lastModified")) |v| {
        model.last_modified = try allocator.dupe(u8, v);
    }
    if (getStringField(obj, "library_name")) |v| {
        model.library_name = try allocator.dupe(u8, v);
    }
    if (getStringField(obj, "pipeline_tag")) |v| {
        model.pipeline_tag = try allocator.dupe(u8, v);
    }

    // Boolean fields
    model.private = getBoolField(obj, "private") orelse false;
    model.gated = getBoolField(obj, "gated");
    model.disabled = getBoolField(obj, "disabled") orelse false;

    // Numeric fields
    model.downloads = getIntField(obj, "downloads");
    model.likes = getIntField(obj, "likes");
    model.trending_score = getFloatField(obj, "trendingScore");

    // Array fields
    if (obj.get("tags")) |tags_val| {
        model.tags = try parseStringArray(allocator, tags_val);
    }

    // Parse siblings
    if (obj.get("siblings")) |siblings_val| {
        model.siblings = try parseSiblingsFromValue(allocator, siblings_val);
    }

    // Parse cardData - handle polymorphic fields
    if (obj.get("cardData")) |card_val| {
        if (card_val == .object) {
            const card_obj = card_val.object;

            if (getStringField(card_obj, "description")) |v| {
                model.description = try allocator.dupe(u8, v);
            }
            if (getStringField(card_obj, "license")) |v| {
                model.license = try allocator.dupe(u8, v);
            }

            // Handle language - can be string or array
            if (card_obj.get("language")) |lang_val| {
                model.language = try parseStringOrArray(allocator, lang_val);
            }

            // Handle datasets - can be string or array
            if (card_obj.get("datasets")) |ds_val| {
                model.datasets = try parseStringOrArray(allocator, ds_val);
            }
        }
    }

    return model;
}

/// Parse a string that can be either a single string or an array of strings
fn parseStringOrArray(allocator: Allocator, value: std.json.Value) !?[][]const u8 {
    switch (value) {
        .string => |s| {
            // Single string - wrap in array
            var result = try allocator.alloc([]const u8, 1);
            result[0] = try allocator.dupe(u8, s);
            return result;
        },
        .array => |arr| {
            // Array of strings
            var result = try allocator.alloc([]const u8, arr.items.len);
            var count: usize = 0;
            errdefer {
                for (result[0..count]) |item| {
                    allocator.free(item);
                }
                allocator.free(result);
            }
            for (arr.items) |item| {
                if (item == .string) {
                    result[count] = try allocator.dupe(u8, item.string);
                    count += 1;
                }
            }
            if (count < result.len) {
                // Resize if some items weren't strings
                const final = try allocator.realloc(result, count);
                return final;
            }
            return result;
        },
        .null => return null,
        else => return null,
    }
}

/// Parse an array of strings
fn parseStringArray(allocator: Allocator, value: std.json.Value) !?[][]const u8 {
    if (value != .array) return null;

    const arr = value.array;
    var result = try allocator.alloc([]const u8, arr.items.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |item| {
            allocator.free(item);
        }
        allocator.free(result);
    }

    for (arr.items) |item| {
        if (item == .string) {
            result[count] = try allocator.dupe(u8, item.string);
            count += 1;
        }
    }

    if (count == 0) {
        allocator.free(result);
        return null;
    }

    if (count < result.len) {
        return try allocator.realloc(result, count);
    }
    return result;
}

/// Sibling with owned strings for proper memory management
pub const OwnedSibling = struct {
    rfilename: []const u8,
    size: ?u64 = null,
    blob_id: ?[]const u8 = null,

    pub fn deinit(self: *OwnedSibling, alloc: Allocator) void {
        alloc.free(self.rfilename);
        if (self.blob_id) |bid| alloc.free(bid);
    }
};

/// Parse siblings array from JSON Value - returns owned copies of strings
fn parseSiblingsFromValue(allocator: Allocator, value: std.json.Value) !?[]OwnedSibling {
    if (value != .array) return null;

    const arr = value.array;
    if (arr.items.len == 0) return null;

    var result = try allocator.alloc(OwnedSibling, arr.items.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |*sib| {
            sib.deinit(allocator);
        }
        allocator.free(result);
    }

    for (arr.items) |item| {
        if (item == .object) {
            const obj = item.object;
            const rfilename = getStringField(obj, "rfilename") orelse continue;

            result[count] = OwnedSibling{
                .rfilename = try allocator.dupe(u8, rfilename),
                .size = getIntField(obj, "size"),
                .blob_id = if (getStringField(obj, "blobId")) |bid| try allocator.dupe(u8, bid) else null,
            };
            count += 1;
        }
    }

    if (count == 0) {
        allocator.free(result);
        return null;
    }

    if (count < result.len) {
        return try allocator.realloc(result, count);
    }
    return result;
}

// ============================================================================
// Parsing Functions
// ============================================================================

/// Parse a JSON string into an array of models (search results)
pub fn parseModels(allocator: Allocator, json_str: []const u8) ![]ParsedModel {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_str,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        return mapJsonError(err);
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        return JsonError.InvalidJson;
    }

    const arr = parsed.value.array;
    var result = try allocator.alloc(ParsedModel, arr.items.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |*m| {
            freeModelFields(allocator, m);
        }
        allocator.free(result);
    }

    for (arr.items) |item| {
        result[count] = try parseModelFromValue(allocator, item);
        count += 1;
    }

    return result;
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

/// Free model fields that were allocated
pub fn freeModelFields(allocator: Allocator, model: *ParsedModel) void {
    allocator.free(model.id);
    if (model.model_id) |v| allocator.free(v);
    if (model.author) |v| allocator.free(v);
    if (model.sha) |v| allocator.free(v);
    if (model.last_modified) |v| allocator.free(v);
    if (model.library_name) |v| allocator.free(v);
    if (model.pipeline_tag) |v| allocator.free(v);
    if (model.description) |v| allocator.free(v);
    if (model.license) |v| allocator.free(v);

    if (model.tags) |tags| {
        for (tags) |tag| allocator.free(tag);
        allocator.free(tags);
    }
    if (model.language) |langs| {
        for (langs) |lang| allocator.free(lang);
        allocator.free(langs);
    }
    if (model.datasets) |ds| {
        for (ds) |d| allocator.free(d);
        allocator.free(ds);
    }
    if (model.siblings) |sibs| {
        for (sibs) |*sib| {
            var s = sib.*;
            s.deinit(allocator);
        }
        allocator.free(sibs);
    }
}

// ============================================================================
// Conversion Functions (Parsed -> Domain Types)
// ============================================================================

/// Convert RawSibling to types.Sibling with owned memory
pub fn toSibling(allocator: Allocator, raw: RawSibling) !types.Sibling {
    return types.Sibling{
        .rfilename = try allocator.dupe(u8, raw.rfilename),
        .size = if (raw.lfs) |lfs| lfs.size else raw.size,
        .blob_id = if (raw.blobId) |bid| try allocator.dupe(u8, bid) else null,
    };
}

/// Convert ParsedModel to types.Model with owned memory
pub fn toModel(allocator: Allocator, raw: ParsedModel) !types.Model {
    var model = types.Model{
        .id = try allocator.dupe(u8, raw.id),
        .model_id = if (raw.model_id) |mid| try allocator.dupe(u8, mid) else null,
        .author = if (raw.author) |a| try allocator.dupe(u8, a) else null,
        .sha = if (raw.sha) |s| try allocator.dupe(u8, s) else null,
        .last_modified = if (raw.last_modified) |lm| try allocator.dupe(u8, lm) else null,
        .private = raw.private,
        .gated = raw.gated,
        .disabled = raw.disabled,
        .library_name = if (raw.library_name) |ln| try allocator.dupe(u8, ln) else null,
        .pipeline_tag = if (raw.pipeline_tag) |pt| try allocator.dupe(u8, pt) else null,
        .downloads = raw.downloads,
        .likes = raw.likes,
        .trending_score = raw.trending_score,
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
            siblings[i] = types.Sibling{
                .rfilename = try allocator.dupe(u8, sib.rfilename),
                .size = sib.size,
                .blob_id = if (sib.blob_id) |bid| try allocator.dupe(u8, bid) else null,
            };
        }
        model.siblings = siblings;
    }

    // Convert card data
    if (raw.description != null or raw.license != null or raw.language != null or raw.datasets != null) {
        model.card_data = try toCardData(allocator, raw);
    }

    return model;
}

/// Convert parsed card data fields to types.CardData with owned memory
pub fn toCardData(allocator: Allocator, raw: ParsedModel) !types.CardData {
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
    return std.json.Stringify.valueAlloc(allocator, value, .{}) catch |err| {
        return mapJsonError(err);
    };
}

/// Convert a value to pretty-printed JSON string
pub fn stringifyPretty(allocator: Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 }) catch |err| {
        return mapJsonError(err);
    };
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

/// Helper to duplicate a string
fn dupeString(allocator: Allocator, s: []const u8) ![]const u8 {
    return allocator.dupe(u8, s);
}

/// Get a string field from a JSON object
fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) {
            return val.string;
        }
    }
    return null;
}

/// Get a boolean field from a JSON object
fn getBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    if (obj.get(key)) |val| {
        if (val == .bool) {
            return val.bool;
        }
    }
    return null;
}

/// Get an integer field from a JSON object
fn getIntField(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    if (obj.get(key)) |val| {
        if (val == .integer) {
            if (val.integer >= 0) {
                return @intCast(val.integer);
            }
        }
    }
    return null;
}

/// Get a float field from a JSON object
fn getFloatField(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    if (obj.get(key)) |val| {
        switch (val) {
            .float => return val.float,
            .integer => return @floatFromInt(val.integer),
            else => return null,
        }
    }
    return null;
}

/// Extract a string field from a JSON object, returning null if not found
pub fn getOptionalString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    return getStringField(obj.object, key);
}

/// Extract a required string field from a JSON object
pub fn getRequiredString(obj: std.json.Value, key: []const u8) ![]const u8 {
    return getOptionalString(obj, key) orelse return JsonError.MissingField;
}

/// Extract an optional integer field from a JSON object
pub fn getOptionalInt(comptime T: type, obj: std.json.Value, key: []const u8) ?T {
    if (obj != .object) return null;
    if (getIntField(obj.object, key)) |val| {
        return @intCast(val);
    }
    return null;
}

/// Extract an optional boolean field from a JSON object
pub fn getOptionalBool(obj: std.json.Value, key: []const u8) ?bool {
    if (obj != .object) return null;
    return getBoolField(obj.object, key);
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

    const parsed = try parseModel(allocator, json);
    defer {
        var m = parsed;
        freeModelFields(allocator, &m);
    }

    try std.testing.expectEqualStrings("test/model", parsed.id);
    try std.testing.expectEqual(@as(?u64, 1000), parsed.downloads);
    try std.testing.expectEqual(@as(?u64, 50), parsed.likes);
}

test "parseModel - with cardData string language" {
    const allocator = std.testing.allocator;
    const json =
        \\{"id":"test/model","cardData":{"language":"en","license":"mit"}}
    ;

    const parsed = try parseModel(allocator, json);
    defer {
        var m = parsed;
        freeModelFields(allocator, &m);
    }

    try std.testing.expectEqualStrings("test/model", parsed.id);
    try std.testing.expectEqualStrings("mit", parsed.license.?);
    try std.testing.expect(parsed.language != null);
    try std.testing.expectEqual(@as(usize, 1), parsed.language.?.len);
    try std.testing.expectEqualStrings("en", parsed.language.?[0]);
}

test "parseModel - with cardData array language" {
    const allocator = std.testing.allocator;
    const json =
        \\{"id":"test/model","cardData":{"language":["en","fr","de"]}}
    ;

    const parsed = try parseModel(allocator, json);
    defer {
        var m = parsed;
        freeModelFields(allocator, &m);
    }

    try std.testing.expect(parsed.language != null);
    try std.testing.expectEqual(@as(usize, 3), parsed.language.?.len);
    try std.testing.expectEqualStrings("en", parsed.language.?[0]);
    try std.testing.expectEqualStrings("fr", parsed.language.?[1]);
    try std.testing.expectEqualStrings("de", parsed.language.?[2]);
}

test "parseModel - with siblings" {
    const allocator = std.testing.allocator;
    const json =
        \\{"id":"test/model","siblings":[{"rfilename":"model.gguf","size":1024}]}
    ;

    const parsed = try parseModel(allocator, json);
    defer {
        var m = parsed;
        freeModelFields(allocator, &m);
    }

    try std.testing.expect(parsed.siblings != null);
    try std.testing.expectEqual(@as(usize, 1), parsed.siblings.?.len);
    try std.testing.expectEqualStrings("model.gguf", parsed.siblings.?[0].rfilename);
    try std.testing.expectEqual(@as(?u64, 1024), parsed.siblings.?[0].size);
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

    const models = try parseModels(allocator, json);
    defer {
        for (models) |*m| {
            var model = m.*;
            freeModelFields(allocator, &model);
        }
        allocator.free(models);
    }

    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("model1", models[0].id);
    try std.testing.expectEqualStrings("model2", models[1].id);
    try std.testing.expectEqualStrings("model3", models[2].id);
}

test "toModel - conversion with owned memory" {
    const allocator = std.testing.allocator;
    const json =
        \\{"id":"test/model","downloads":500}
    ;

    const parsed = try parseModel(allocator, json);
    defer {
        var m = parsed;
        freeModelFields(allocator, &m);
    }

    var model = try toModel(allocator, parsed);
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

test "parseModel - handles missing optional fields" {
    const allocator = std.testing.allocator;
    // JSON with minimal fields
    const json =
        \\{"id":"minimal/model"}
    ;

    const parsed = try parseModel(allocator, json);
    defer {
        var m = parsed;
        freeModelFields(allocator, &m);
    }

    try std.testing.expectEqualStrings("minimal/model", parsed.id);
    try std.testing.expect(parsed.author == null);
    try std.testing.expect(parsed.downloads == null);
    try std.testing.expect(parsed.tags == null);
}
