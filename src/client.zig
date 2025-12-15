//! HTTP Client for HuggingFace Hub API
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

    /// Initialize with just an allocator and default config
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
    pub fn get(self: *Self, url: []const u8) !Response {
        return self.request(.GET, url, null);
    }

    /// Perform a POST request
    pub fn post(self: *Self, url: []const u8, body: ?[]const u8) !Response {
        return self.request(.POST, url, body);
    }

    /// Perform a HEAD request
    pub fn head(self: *Self, url: []const u8) !Response {
        return self.request(.HEAD, url, null);
    }

    /// Build full URL from endpoint and path
    fn buildUrl(self: *Self, path: []const u8) ![]u8 {
        // If path already starts with http, return as-is
        if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
            return self.allocator.dupe(u8, path);
        }
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.endpoint, path });
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
        const response = req.receiveHead(&redirect_buffer) catch |err| {
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
            var transfer_buffer: [8192]u8 align(8) = undefined;
            var mutable_response = response;
            const body_reader = mutable_response.reader(&transfer_buffer);
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

    /// Download a file using streaming - reads directly to a file
    /// This is the safe way to do streaming downloads - keeps everything in one scope
    /// Note: Uses streamRemaining with FileStreamWriter due to Zig 0.15.2 readSliceShort bug
    pub fn downloadToFile(
        self: *Self,
        url: []const u8,
        file: std.fs.File,
        start_byte: ?u64,
    ) !StreamingResult {
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
        defer req.deinit();

        // Send request without body
        req.sendBodiless() catch |err| {
            return mapConnectionError(err);
        };

        // Receive response head
        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            return mapConnectionError(err);
        };

        // Check status
        const status_code = @intFromEnum(response.head.status);
        if (status_code >= 400) {
            if (errors.errorFromStatus(status_code)) |err| {
                return err;
            }
            return HubError.InvalidResponse;
        }

        // Get content-length from response headers
        const content_length: ?u64 = response.head.content_length;

        // Use streamRemaining with our file writer wrapper (works around Zig 0.15.2 readSliceShort bug)
        var transfer_buffer: [8192]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);

        // Create a buffered file writer
        var file_write_buf: [8192]u8 = undefined;
        var file_writer = file.writer(&file_write_buf);

        const bytes_downloaded = body_reader.streamRemaining(&file_writer.interface) catch {
            return HubError.NetworkError;
        };

        // Flush remaining data
        file_writer.interface.flush() catch {
            return HubError.IoError;
        };

        return StreamingResult{
            .status_code = status_code,
            .content_length = content_length,
            .bytes_downloaded = bytes_downloaded,
        };
    }

    /// Download a file using streaming with a callback for progress
    /// Uses stream() in chunks to report progress periodically (workaround for Zig 0.15.2 readSliceShort bug)
    pub fn downloadToFileWithProgress(
        self: *Self,
        url: []const u8,
        file: std.fs.File,
        start_byte: ?u64,
        progress_ctx: anytype,
        progress_fn: *const fn (ctx: @TypeOf(progress_ctx), bytes_so_far: u64, total: ?u64) void,
    ) !StreamingResult {
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

        // Create request
        var req = self.http_client.request(.GET, uri, .{
            .headers = headers,
            .extra_headers = extra_headers_buf[0..extra_headers_len],
            .redirect_behavior = .init(@as(u16, @intCast(self.max_redirects))),
        }) catch |err| {
            return mapConnectionError(err);
        };
        defer req.deinit();

        // Send request without body
        req.sendBodiless() catch |err| {
            return mapConnectionError(err);
        };

        // Receive response head
        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            return mapConnectionError(err);
        };

        // Check status
        const status_code = @intFromEnum(response.head.status);
        if (status_code >= 400) {
            if (errors.errorFromStatus(status_code)) |err| {
                return err;
            }
            return HubError.InvalidResponse;
        }

        // Get content-length from response headers
        const content_length: ?u64 = response.head.content_length;

        // Set up body reader
        var transfer_buffer: [8192]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);

        // Create buffered file writer
        var file_write_buf: [8192]u8 = undefined;
        var file_writer = file.writer(&file_write_buf);

        // Download in chunks with progress reporting
        // Report progress every 64KB to avoid overwhelming the callback
        const chunk_threshold: u64 = 65536;
        var total_downloaded: u64 = 0;
        var last_report: u64 = 0;

        // Use stream() with limited chunks
        while (true) {
            const chunk_size = chunk_threshold - (total_downloaded - last_report);
            const limit = std.Io.Limit.limited(chunk_size);

            const bytes_streamed = body_reader.stream(&file_writer.interface, limit) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return HubError.NetworkError,
            };

            if (bytes_streamed == 0) break;
            total_downloaded += bytes_streamed;

            // Report progress if we've crossed the threshold
            if (total_downloaded - last_report >= chunk_threshold) {
                progress_fn(progress_ctx, (start_byte orelse 0) + total_downloaded, content_length);
                last_report = total_downloaded;
            }
        }

        // Flush remaining data
        file_writer.interface.flush() catch {
            return HubError.IoError;
        };

        // Final progress callback to ensure 100% is reported
        progress_fn(progress_ctx, (start_byte orelse 0) + total_downloaded, content_length);

        return StreamingResult{
            .status_code = status_code,
            .content_length = content_length,
            .bytes_downloaded = total_downloaded,
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

/// Result of a streaming download
pub const StreamingResult = struct {
    status_code: u16,
    content_length: ?u64,
    bytes_downloaded: u64,
};

/// Map connection errors to HubError
fn mapConnectionError(err: anyerror) HubError {
    return switch (err) {
        error.ConnectionRefused => HubError.NetworkError,
        error.ConnectionResetByPeer => HubError.NetworkError,
        error.ConnectionTimedOut => HubError.Timeout,
        error.NetworkUnreachable => HubError.NetworkError,
        error.HostLacksNetworkAddresses => HubError.NetworkError,
        error.TemporaryNameServerFailure => HubError.NetworkError,
        error.NameServerFailure => HubError.NetworkError,
        error.UnknownHostName => HubError.InvalidUrl,
        error.TlsAlertUnknownCa => HubError.TlsError,
        error.TlsAlertDecodeError => HubError.TlsError,
        error.OutOfMemory => HubError.OutOfMemory,
        else => HubError.NetworkError,
    };
}

/// URL-encode a string
pub fn urlEncode(allocator: Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    for (input) |c| {
        if (isUnreserved(c)) {
            try result.append(allocator, c);
        } else {
            try result.writer(allocator).print("%{X:0>2}", .{c});
        }
    }

    return result.toOwnedSlice(allocator);
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

/// Build a query string from key-value pairs
pub fn buildQueryString(allocator: Allocator, params: []const QueryParam) ![]u8 {
    if (params.len == 0) return allocator.dupe(u8, "");

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    for (params, 0..) |param, i| {
        if (i > 0) try result.append(allocator, '&');

        const encoded_key = try urlEncode(allocator, param.key);
        defer allocator.free(encoded_key);
        const encoded_value = try urlEncode(allocator, param.value);
        defer allocator.free(encoded_value);

        try result.appendSlice(allocator, encoded_key);
        try result.append(allocator, '=');
        try result.appendSlice(allocator, encoded_value);
    }

    return result.toOwnedSlice(allocator);
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

    // Test simple string
    const simple = try urlEncode(allocator, "hello");
    defer allocator.free(simple);
    try std.testing.expectEqualStrings("hello", simple);

    // Test string with spaces
    const with_spaces = try urlEncode(allocator, "hello world");
    defer allocator.free(with_spaces);
    try std.testing.expectEqualStrings("hello%20world", with_spaces);

    // Test special characters
    const special = try urlEncode(allocator, "a=b&c=d");
    defer allocator.free(special);
    try std.testing.expectEqualStrings("a%3Db%26c%3Dd", special);
}

test "buildQueryString" {
    const allocator = std.testing.allocator;

    const params = [_]QueryParam{
        .{ .key = "search", .value = "hello world" },
        .{ .key = "limit", .value = "10" },
    };

    const qs = try buildQueryString(allocator, &params);
    defer allocator.free(qs);

    try std.testing.expectEqualStrings("search=hello%20world&limit=10", qs);
}

test "HeaderMap operations" {
    const allocator = std.testing.allocator;

    var headers = HeaderMap.init(allocator);
    defer headers.deinit();

    try headers.put("content-type", "application/json");
    try headers.put("authorization", "Bearer token123");

    try std.testing.expectEqualStrings("application/json", headers.get("content-type").?);
    try std.testing.expectEqualStrings("Bearer token123", headers.get("authorization").?);
    try std.testing.expect(headers.get("nonexistent") == null);
}

test "Response.isSuccess" {
    const allocator = std.testing.allocator;

    const headers = HeaderMap.init(allocator);

    var response_200 = Response{
        .status_code = 200,
        .headers = headers,
        .body = &[_]u8{},
        .allocator = allocator,
    };
    try std.testing.expect(response_200.isSuccess());

    response_200.status_code = 201;
    try std.testing.expect(response_200.isSuccess());

    response_200.status_code = 404;
    try std.testing.expect(!response_200.isSuccess());

    response_200.status_code = 500;
    try std.testing.expect(!response_200.isSuccess());
}
