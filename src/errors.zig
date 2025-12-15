//! Error handling for hf-hub-zig
//!
//! This module defines all error types and provides context-rich error handling
//! for the HuggingFace Hub client operations.

const std = @import("std");

/// Main error set for HuggingFace Hub operations
pub const HubError = error{
    /// Network-related error (connection failed, DNS resolution, etc.)
    NetworkError,
    /// Request timed out
    Timeout,
    /// Resource not found (404)
    NotFound,
    /// Authentication required or failed (401)
    Unauthorized,
    /// Access denied to resource (403)
    Forbidden,
    /// Rate limit exceeded (429)
    RateLimited,
    /// Invalid JSON in response
    InvalidJson,
    /// Invalid request parameters
    InvalidRequest,
    /// Server error (5xx)
    ServerError,
    /// Cache-related error
    CacheError,
    /// Download failed
    DownloadError,
    /// File I/O error
    IoError,
    /// Memory allocation failed
    OutOfMemory,
    /// Invalid URL format
    InvalidUrl,
    /// TLS/SSL error
    TlsError,
    /// Response too large
    ResponseTooLarge,
    /// Operation was cancelled
    Cancelled,
    /// Invalid response from server
    InvalidResponse,
    /// Checksum verification failed
    ChecksumMismatch,
};

/// Extended error context with additional information
pub const ErrorContext = struct {
    /// The type of error that occurred
    error_type: HubError,
    /// Human-readable error message
    message: []const u8,
    /// HTTP status code if applicable
    status_code: ?u16 = null,
    /// Retry-After header value in seconds (for rate limiting)
    retry_after: ?u32 = null,
    /// Additional details about the error
    details: ?[]const u8 = null,
    /// The URL that was being accessed when the error occurred
    url: ?[]const u8 = null,
    /// Allocator used for dynamic strings (if any)
    allocator: ?std.mem.Allocator = null,
    /// Whether the message was dynamically allocated
    message_allocated: bool = false,
    /// Whether the details were dynamically allocated
    details_allocated: bool = false,

    const Self = @This();

    /// Create a new error context with a static message
    pub fn init(error_type: HubError, message: []const u8) Self {
        return Self{
            .error_type = error_type,
            .message = message,
        };
    }

    /// Create a new error context with a status code
    pub fn withStatus(error_type: HubError, message: []const u8, status_code: u16) Self {
        return Self{
            .error_type = error_type,
            .message = message,
            .status_code = status_code,
        };
    }

    /// Create a new error context for rate limiting
    pub fn rateLimited(retry_after: ?u32) Self {
        return Self{
            .error_type = HubError.RateLimited,
            .message = "Rate limit exceeded",
            .status_code = 429,
            .retry_after = retry_after,
        };
    }

    /// Check if this error is retryable
    pub fn isRetryable(self: Self) bool {
        return switch (self.error_type) {
            error.RateLimited => true,
            error.Timeout => true,
            error.ServerError => true,
            error.NetworkError => true,
            error.DownloadError => true, // May be transient
            // These are not retryable
            error.NotFound => false,
            error.Unauthorized => false,
            error.Forbidden => false,
            error.InvalidJson => false,
            error.InvalidRequest => false,
            error.CacheError => false,
            error.IoError => false,
            error.OutOfMemory => false,
            error.InvalidUrl => false,
            error.TlsError => false,
            error.ResponseTooLarge => false,
            error.Cancelled => false,
            error.InvalidResponse => false,
            error.ChecksumMismatch => false,
        };
    }

    /// Get a formatted error message
    pub fn format(self: Self, allocator: std.mem.Allocator) ![]u8 {
        var parts = std.array_list.Managed(u8).init(allocator);
        errdefer parts.deinit();

        const writer = parts.writer();

        // Error type name
        try writer.print("[{s}] ", .{@errorName(self.error_type)});

        // Main message
        try writer.print("{s}", .{self.message});

        // Status code if present
        if (self.status_code) |code| {
            try writer.print(" (HTTP {d})", .{code});
        }

        // Retry-after if present
        if (self.retry_after) |seconds| {
            try writer.print(" - Retry after {d}s", .{seconds});
        }

        // Details if present
        if (self.details) |details| {
            try writer.print("\n  Details: {s}", .{details});
        }

        // URL if present
        if (self.url) |url| {
            try writer.print("\n  URL: {s}", .{url});
        }

        return parts.toOwnedSlice();
    }

    /// Clean up any allocated memory
    pub fn deinit(self: *Self) void {
        if (self.allocator) |alloc| {
            if (self.message_allocated) {
                alloc.free(self.message);
            }
            if (self.details_allocated) {
                if (self.details) |details| {
                    alloc.free(details);
                }
            }
        }
    }
};

/// Convert an HTTP status code to an appropriate HubError
pub fn errorFromStatus(status_code: u16) ?HubError {
    return switch (status_code) {
        200...299 => null, // Success
        400 => HubError.InvalidRequest,
        401 => HubError.Unauthorized,
        403 => HubError.Forbidden,
        404 => HubError.NotFound,
        408 => HubError.Timeout,
        429 => HubError.RateLimited,
        500...599 => HubError.ServerError,
        else => HubError.InvalidResponse,
    };
}

/// Create an ErrorContext from an HTTP status code
pub fn contextFromStatus(status_code: u16, url: ?[]const u8) ErrorContext {
    const error_type = errorFromStatus(status_code) orelse HubError.InvalidResponse;
    const ctx = ErrorContext{
        .error_type = error_type,
        .message = statusMessage(status_code),
        .status_code = status_code,
        .url = url,
    };
    return ctx;
}

/// Get a human-readable message for an HTTP status code
fn statusMessage(status_code: u16) []const u8 {
    return switch (status_code) {
        400 => "Bad request - check your parameters",
        401 => "Authentication required - provide a valid HF_TOKEN",
        403 => "Access forbidden - you don't have permission to access this resource",
        404 => "Resource not found",
        408 => "Request timed out",
        429 => "Rate limit exceeded - too many requests",
        500 => "Internal server error",
        502 => "Bad gateway",
        503 => "Service temporarily unavailable",
        504 => "Gateway timeout",
        else => "Unexpected error",
    };
}

/// Parse the Retry-After header value
pub fn parseRetryAfter(header_value: []const u8) ?u32 {
    // Try parsing as an integer (seconds)
    const seconds = std.fmt.parseInt(u32, header_value, 10) catch {
        // Could be an HTTP-date, but we'll just use a default
        return null;
    };
    return seconds;
}

// Tests
test "ErrorContext.isRetryable" {
    const retryable = ErrorContext.init(HubError.RateLimited, "test");
    try std.testing.expect(retryable.isRetryable());

    const not_retryable = ErrorContext.init(HubError.NotFound, "test");
    try std.testing.expect(!not_retryable.isRetryable());
}

test "errorFromStatus" {
    try std.testing.expectEqual(@as(?HubError, null), errorFromStatus(200));
    try std.testing.expectEqual(@as(?HubError, HubError.NotFound), errorFromStatus(404));
    try std.testing.expectEqual(@as(?HubError, HubError.RateLimited), errorFromStatus(429));
    try std.testing.expectEqual(@as(?HubError, HubError.ServerError), errorFromStatus(500));
}

test "ErrorContext.format" {
    const allocator = std.testing.allocator;
    var ctx = ErrorContext{
        .error_type = HubError.NotFound,
        .message = "Model not found",
        .status_code = 404,
        .url = "https://huggingface.co/api/models/test",
    };

    const formatted = try ctx.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "NotFound") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "404") != null);
}

test "parseRetryAfter" {
    try std.testing.expectEqual(@as(?u32, 60), parseRetryAfter("60"));
    try std.testing.expectEqual(@as(?u32, null), parseRetryAfter("invalid"));
}
