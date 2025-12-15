//! HTTP Client wrapper for HuggingFace Hub API
//!
//! This module provides a high-level HTTP client built on top of Zig's std.http.Client
//! with support for authentication, timeouts, redirects, and streaming responses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;

const Config = @import("config.zig").Config;
const errors = @import("errors.zig");
const HubError = errors.HubError;
const ErrorContext = errors.ErrorContext;

/// HTTP response wrapper
pub const Response = struct {
    /// HTTP status code
    status_code: u16,
    /// Response headers
    headers: HeaderMap,
    /// Response body (owned by caller)
    body: []u8,
    /// Allocator used for body
    allocator: Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.body);
        self.headers.deinit();
    }

    /// Check if response is successful (2xx)
    pub fn isSuccess(self: Self) bool {
        return self.status_code >= 200 and self.status_code < 300;
    }

    /// Get a specific header value
    pub fn getHeader(self: Self, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// Get Content-Length header as u64
    pub fn getContentLength(self: Self) ?u64 {
        if (self.getHeader("content-length")) |value| {
            return std.fmt.parseInt(u64, value, 10) catch null;
        }
        return null;
    }

    /// Get Retry-After header as u32 (seconds)
    pub fn getRetryAfter(self: Self) ?u32 {
        if (self.getHeader("retry-after")) |value| {
            return std.fmt.parseInt(u32, value, 10) catch null;
        }
        return null;
    }
};

/// Simple header map
pub const HeaderMap = struct {
    entries: std.StringHashMap([]const u8),
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .entries = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.entries.put(key_copy, value_copy);
    }

    pub fn get(self: Self, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }
};

/// HTTP client for HuggingFace Hub API
pub const HttpClient = struct {
    allocator: Allocator,
    /// Base endpoint URL (e.g., "https://huggingface.co")
    endpoint: []const u8,
    /// Optional authentication token
    token: ?[]const u8,
    /// User-Agent string
    user_agent: []const u8,
    /// Request timeout in milliseconds
    timeout_ms: u32,
    /// Maximum redirects to follow
    max_redirects: u8 = 5,
    /// Underlying HTTP client
    http_client: http.Client,
    /// Whether we own the endpoint string
    endpoint_owned: bool = false,

    const Self = @This();
    const DEFAULT_USER_AGENT = "hf-hub-zig/0.1.0";
    const DEFAULT_TIMEOUT_MS: u32 = 30_000;
    const MAX_RESPONSE_SIZE: usize = 100 * 1024 * 1024; // 100 MB max for non-streaming

    /// Initialize a new HTTP client
    pub fn init(allocator: Allocator, config: Config) !Self {
        const client = http.Client{ .allocator = allocator };

        return Self{
            .allocator = allocator,
            .endpoint = config.endpoint,
            .token = config.token,
            .user_agent = DEFAULT_USER_AGENT,
            .timeout_ms = config.timeout_ms,
            .http_client = client,
        };
    }

    /// Initialize with default configuration
    pub fn initDefault(allocator: Allocator) !Self {
        const client = http.Client{ .allocator = allocator };

        return Self{
            .allocator = allocator,
            .endpoint = "https://huggingface.co",
            .token = null,
            .user_agent = DEFAULT_USER_AGENT,
            .timeout_ms = DEFAULT_TIMEOUT_MS,
            .http_client = client,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }

    /// Perform a GET request
    pub fn get(self: *Self, path: []const u8, query: ?[]const u8) !Response {
        const url = try self.buildUrl(path, query);
        defer self.allocator.free(url);

        return self.request(.GET, url, null);
    }

    /// Perform a POST request
    pub fn post(self: *Self, path: []const u8, body: ?[]const u8) !Response {
        const url = try self.buildUrl(path, null);
        defer self.allocator.free(url);

        return self.request(.POST, url, body);
    }

    /// Perform a HEAD request
    pub fn head(self: *Self, path: []const u8) !Response {
        const url = try self.buildUrl(path, null);
        defer self.allocator.free(url);

        return self.request(.HEAD, url, null);
    }

    /// Build full URL from path and optional query
    fn buildUrl(self: *Self, path: []const u8, query: ?[]const u8) ![]u8 {
        if (query) |q| {
            if (std.mem.indexOf(u8, path, "?") != null) {
                return std.fmt.allocPrint(self.allocator, "{s}{s}&{s}", .{ self.endpoint, path, q });
            } else {
                return std.fmt.allocPrint(self.allocator, "{s}{s}?{s}", .{ self.endpoint, path, q });
            }
        } else {
            return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.endpoint, path });
        }
    }

    /// Perform an HTTP request
    pub fn request(self: *Self, method: http.Method, url: []const u8, body: ?[]const u8) !Response {
        const uri = Uri.parse(url) catch return HubError.InvalidUrl;

        // Build headers
        const headers = http.Client.Request.Headers{
            .user_agent = .{ .override = self.user_agent },
            .accept_encoding = .{ .override = "identity" },
        };

        // Prepare extra headers for authorization
        var extra_headers_buf: [2]http.Header = undefined;
        var extra_headers_len: usize = 0;

        // Store auth value in a persistent buffer
        var auth_storage: [512]u8 = undefined;
        if (self.token) |token| {
            const auth_value = std.fmt.bufPrint(&auth_storage, "Bearer {s}", .{token}) catch {
                return HubError.OutOfMemory;
            };
            extra_headers_buf[extra_headers_len] = .{
                .name = "Authorization",
                .value = auth_value,
            };
            extra_headers_len += 1;
        }

        extra_headers_buf[extra_headers_len] = .{
            .name = "Accept",
            .value = "application/json",
        };
        extra_headers_len += 1;

        // Create request (Zig 0.15 API)
        var req = self.http_client.request(method, uri, .{
            .headers = headers,
            .extra_headers = extra_headers_buf[0..extra_headers_len],
            .redirect_behavior = .init(@as(u16, @intCast(self.max_redirects))),
        }) catch |err| {
            return mapConnectionError(err);
        };
        defer req.deinit();

        // Send request
        if (body) |b| {
            // Send with body
            var body_buf: [8192]u8 = undefined;
            @memcpy(body_buf[0..b.len], b);
            req.sendBodyComplete(body_buf[0..b.len]) catch |err| {
                return mapConnectionError(err);
            };
        } else {
            // Send without body
            req.sendBodiless() catch |err| {
                return mapConnectionError(err);
            };
        }

        // Receive response head
        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            return mapConnectionError(err);
        };

        // Parse response headers
        var response_headers = HeaderMap.init(self.allocator);
        errdefer response_headers.deinit();

        // Extract important headers from the response
        var header_iter = response.head.iterateHeaders();
        while (header_iter.next()) |header| {
            // Store lowercase header name for consistent lookup
            var lower_name_buf: [256]u8 = undefined;
            const lower_name = std.ascii.lowerString(&lower_name_buf, header.name);
            try response_headers.put(lower_name, header.value);
        }

        // Read response body
        const status_code = @intFromEnum(response.head.status);
        var response_body: []u8 = &[_]u8{};

        if (method != .HEAD) {
            var transfer_buffer: [8192]u8 = undefined;
            const body_reader = response.reader(&transfer_buffer);
            response_body = body_reader.allocRemaining(self.allocator, std.io.Limit.limited(MAX_RESPONSE_SIZE)) catch |err| {
                switch (err) {
                    error.StreamTooLong => return HubError.ResponseTooLarge,
                    else => return HubError.NetworkError,
                }
            };
        }

        return Response{
            .status_code = status_code,
            .headers = response_headers,
            .body = response_body,
            .allocator = self.allocator,
        };
    }

    /// Perform a GET request and return raw URL for streaming
    /// Returns a request object that the caller can read from
    pub fn getStreaming(
        self: *Self,
        url: []const u8,
        start_byte: ?u64,
    ) !StreamingRequest {
        const uri = Uri.parse(url) catch return HubError.InvalidUrl;

        // Build headers
        const headers = http.Client.Request.Headers{
            .user_agent = .{ .override = self.user_agent },
            .accept_encoding = .{ .override = "identity" },
        };

        // Prepare extra headers
        var extra_headers_buf: [3]http.Header = undefined;
        var extra_headers_len: usize = 0;

        // Store auth value in a persistent buffer
        var auth_storage: [512]u8 = undefined;
        if (self.token) |token| {
            const auth_value = std.fmt.bufPrint(&auth_storage, "Bearer {s}", .{token}) catch {
                return HubError.OutOfMemory;
            };
            extra_headers_buf[extra_headers_len] = .{
                .name = "Authorization",
                .value = auth_value,
            };
            extra_headers_len += 1;
        }

        extra_headers_buf[extra_headers_len] = .{
            .name = "Accept",
            .value = "*/*",
        };
        extra_headers_len += 1;

        // Range header for resume support
        var range_buf: [64]u8 = undefined;
        if (start_byte) |sb| {
            const range_value = std.fmt.bufPrint(&range_buf, "bytes={d}-", .{sb}) catch {
                return HubError.OutOfMemory;
            };
            extra_headers_buf[extra_headers_len] = .{
                .name = "Range",
                .value = range_value,
            };
            extra_headers_len += 1;
        }

        // Create request (Zig 0.15 API)
        var req = self.http_client.request(.GET, uri, .{
            .headers = headers,
            .extra_headers = extra_headers_buf[0..extra_headers_len],
            .redirect_behavior = .init(@as(u16, @intCast(self.max_redirects))),
        }) catch |err| {
            return mapConnectionError(err);
        };

        // Send request without body
        req.sendBodiless() catch |err| {
            req.deinit();
            return mapConnectionError(err);
        };

        // Receive response head
        var redirect_buffer: [4096]u8 = undefined;
        const response = req.receiveHead(&redirect_buffer) catch |err| {
            req.deinit();
            return mapConnectionError(err);
        };

        // Check status
        const status_code = @intFromEnum(response.head.status);
        if (status_code >= 400) {
            req.deinit();
            if (errors.errorFromStatus(status_code)) |err| {
                return err;
            }
            return HubError.InvalidResponse;
        }

        // Get content-length from response headers
        var content_length: ?u64 = null;
        var header_iter = response.head.iterateHeaders();
        while (header_iter.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
                content_length = std.fmt.parseInt(u64, header.value, 10) catch null;
                break;
            }
        }

        return StreamingRequest{
            .request = req,
            .response = response,
            .status_code = status_code,
            .content_length = content_length,
        };
    }

    /// Build a download URL for a file in a repository
    pub fn buildDownloadUrl(self: *Self, repo_id: []const u8, filename: []const u8, revision: []const u8) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/resolve/{s}/{s}",
            .{ self.endpoint, repo_id, revision, filename },
        );
    }

    /// Build API URL for model info
    pub fn buildModelUrl(self: *Self, model_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/api/models/{s}",
            .{ self.endpoint, model_id },
        );
    }
};

/// Streaming request wrapper
pub const StreamingRequest = struct {
    request: http.Client.Request,
    response: http.Client.Response,
    status_code: u16,
    content_length: ?u64,
    transfer_buffer: [8192]u8 = undefined,

    const Self = @This();

    /// Get the response reader
    pub fn reader(self: *Self) *std.io.Reader {
        return self.response.reader(&self.transfer_buffer);
    }

    /// Get Content-Length from response
    pub fn getContentLength(self: *Self) ?u64 {
        return self.content_length;
    }

    /// Clean up
    pub fn deinit(self: *Self) void {
        self.request.deinit();
    }
};

/// Map low-level errors to HubError
fn mapConnectionError(err: anyerror) HubError {
    return switch (err) {
        error.ConnectionRefused => HubError.NetworkError,
        error.ConnectionResetByPeer => HubError.NetworkError,
        error.ConnectionTimedOut => HubError.Timeout,
        error.NetworkUnreachable => HubError.NetworkError,
        error.HostUnreachable => HubError.NetworkError,
        error.UnknownHostName => HubError.NetworkError,
        error.TemporaryNameServerFailure => HubError.NetworkError,
        error.ServerNameNotKnown => HubError.NetworkError,
        error.TlsInitializationFailed => HubError.TlsError,
        error.CertificateIssue => HubError.TlsError,
        error.EndOfStream => HubError.NetworkError,
        error.Timeout => HubError.Timeout,
        else => HubError.NetworkError,
    };
}

/// URL encode a string
pub fn urlEncode(allocator: Allocator, input: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    for (input) |c| {
        if (isUnreserved(c)) {
            try result.append(c);
        } else {
            try result.append('%');
            const hex = "0123456789ABCDEF";
            try result.append(hex[c >> 4]);
            try result.append(hex[c & 0x0F]);
        }
    }

    return result.toOwnedSlice();
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

/// Build query string from key-value pairs
pub fn buildQueryString(allocator: Allocator, params: []const QueryParam) ![]u8 {
    if (params.len == 0) return try allocator.dupe(u8, "");

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    for (params, 0..) |param, i| {
        if (i > 0) try result.append('&');

        const encoded_key = try urlEncode(allocator, param.key);
        defer allocator.free(encoded_key);
        try result.appendSlice(encoded_key);

        try result.append('=');

        const encoded_value = try urlEncode(allocator, param.value);
        defer allocator.free(encoded_value);
        try result.appendSlice(encoded_value);
    }

    return result.toOwnedSlice();
}

pub const QueryParam = struct {
    key: []const u8,
    value: []const u8,
};

// ============================================================================
// Tests
// ============================================================================

test "urlEncode basic" {
    const allocator = std.testing.allocator;

    const simple = try urlEncode(allocator, "hello");
    defer allocator.free(simple);
    try std.testing.expectEqualStrings("hello", simple);

    const with_space = try urlEncode(allocator, "hello world");
    defer allocator.free(with_space);
    try std.testing.expectEqualStrings("hello%20world", with_space);

    const special = try urlEncode(allocator, "key=value&other");
    defer allocator.free(special);
    try std.testing.expectEqualStrings("key%3Dvalue%26other", special);
}

test "buildQueryString" {
    const allocator = std.testing.allocator;

    const params = [_]QueryParam{
        .{ .key = "search", .value = "llama 2" },
        .{ .key = "limit", .value = "10" },
    };

    const query = try buildQueryString(allocator, &params);
    defer allocator.free(query);
    try std.testing.expectEqualStrings("search=llama%202&limit=10", query);
}

test "HeaderMap operations" {
    const allocator = std.testing.allocator;

    var headers = HeaderMap.init(allocator);
    defer headers.deinit();

    try headers.put("Content-Type", "application/json");
    try headers.put("Authorization", "Bearer token123");

    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("Bearer token123", headers.get("Authorization").?);
    try std.testing.expect(headers.get("X-Unknown") == null);
}

test "Response.isSuccess" {
    var headers = HeaderMap.init(std.testing.allocator);
    defer headers.deinit();

    var response = Response{
        .status_code = 200,
        .headers = headers,
        .body = &[_]u8{},
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(response.isSuccess());

    response.status_code = 404;
    try std.testing.expect(!response.isSuccess());

    response.status_code = 299;
    try std.testing.expect(response.isSuccess());
}
