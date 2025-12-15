//! User API operations for HuggingFace Hub
//!
//! This module provides operations for user-related API endpoints,
//! including authentication verification and user info retrieval.

const std = @import("std");
const Allocator = std.mem.Allocator;

const client_mod = @import("../client.zig");
const HttpClient = client_mod.HttpClient;
const Response = client_mod.Response;
const errors = @import("../errors.zig");
const HubError = errors.HubError;
const json = @import("../json.zig");
const types = @import("../types.zig");

/// User API client for HuggingFace Hub
pub const UserApi = struct {
    client: *HttpClient,
    allocator: Allocator,

    const Self = @This();

    /// Initialize User API
    pub fn init(allocator: Allocator, http_client: *HttpClient) Self {
        return Self{
            .client = http_client,
            .allocator = allocator,
        };
    }

    /// Get current authenticated user information (whoami)
    /// Requires a valid HF_TOKEN to be set
    pub fn whoami(self: *Self) !types.User {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/whoami", .{self.client.endpoint});
        defer self.allocator.free(url);

        var response = try self.client.get(url);
        defer response.deinit();

        // Check for errors
        if (!response.isSuccess()) {
            if (errors.errorFromStatus(response.status_code)) |err| {
                return err;
            }
            return HubError.InvalidResponse;
        }

        // Parse JSON response
        const parsed = std.json.parseFromSlice(
            json.RawUser,
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch {
            return HubError.InvalidJson;
        };
        defer parsed.deinit();

        // Convert to domain type with owned memory
        return json.toUser(self.allocator, parsed.value);
    }

    /// Check if the current token is valid
    /// Returns true if authenticated, false otherwise
    pub fn isAuthenticated(self: *Self) bool {
        const url = std.fmt.allocPrint(self.allocator, "{s}/api/whoami", .{self.client.endpoint}) catch {
            return false;
        };
        defer self.allocator.free(url);

        var response = self.client.get(url) catch {
            return false;
        };
        defer response.deinit();

        return response.isSuccess();
    }

    /// Get the username of the currently authenticated user
    /// Returns null if not authenticated
    pub fn getUsername(self: *Self) !?[]const u8 {
        const user = self.whoami() catch |err| {
            if (err == HubError.Unauthorized) {
                return null;
            }
            return err;
        };

        // Return just the username, caller owns the memory
        return user.username;
    }

    /// Verify that the token has access to a specific model
    /// This is useful for checking access to gated/private models
    pub fn hasModelAccess(self: *Self, model_id: []const u8) !bool {
        // Try to get model info - if it succeeds, we have access
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/models/{s}", .{ self.client.endpoint, model_id });
        defer self.allocator.free(url);

        var response = self.client.get(url) catch |err| {
            if (err == HubError.NetworkError or err == HubError.Timeout) {
                return err;
            }
            return false;
        };
        defer response.deinit();

        return response.isSuccess();
    }

    /// Get access token info (if available from the API)
    pub fn getTokenInfo(self: *Self) !TokenInfo {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/whoami", .{self.client.endpoint});
        defer self.allocator.free(url);

        var response = try self.client.get(url);
        defer response.deinit();

        if (!response.isSuccess()) {
            if (errors.errorFromStatus(response.status_code)) |err| {
                return err;
            }
            return HubError.InvalidResponse;
        }

        // Parse the full response including token-related fields
        const parsed = std.json.parseFromSlice(
            RawTokenInfo,
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch {
            return HubError.InvalidJson;
        };
        defer parsed.deinit();

        return TokenInfo{
            .username = try self.allocator.dupe(u8, parsed.value.name),
            .token_type = if (parsed.value.auth) |auth|
                if (auth.accessToken) |at|
                    if (at.role) |role| try self.allocator.dupe(u8, role) else null
                else
                    null
            else
                null,
            .is_pro = parsed.value.isPro,
        };
    }
};

/// Token information
pub const TokenInfo = struct {
    username: []const u8,
    token_type: ?[]const u8 = null, // "read", "write", etc.
    is_pro: bool = false,

    pub fn deinit(self: *TokenInfo, allocator: Allocator) void {
        allocator.free(self.username);
        if (self.token_type) |tt| {
            allocator.free(tt);
        }
    }
};

/// Raw token info from API (for parsing)
const RawTokenInfo = struct {
    name: []const u8 = "",
    isPro: bool = false,
    auth: ?RawAuthInfo = null,
};

const RawAuthInfo = struct {
    accessToken: ?RawAccessToken = null,
};

const RawAccessToken = struct {
    role: ?[]const u8 = null,
    displayName: ?[]const u8 = null,
};

// ============================================================================
// Tests
// ============================================================================

test "UserApi initialization" {
    // This is a compile-time test to ensure the API structure is correct
    const allocator = std.testing.allocator;
    var http_client = try HttpClient.initDefault(allocator);
    defer http_client.deinit();

    const api = UserApi.init(allocator, &http_client);
    _ = api;
}

test "TokenInfo deinit" {
    const allocator = std.testing.allocator;

    var info = TokenInfo{
        .username = try allocator.dupe(u8, "testuser"),
        .token_type = try allocator.dupe(u8, "read"),
        .is_pro = true,
    };
    defer info.deinit(allocator);

    try std.testing.expectEqualStrings("testuser", info.username);
    try std.testing.expectEqualStrings("read", info.token_type.?);
    try std.testing.expect(info.is_pro);
}
