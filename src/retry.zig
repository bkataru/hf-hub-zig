//! Retry logic with exponential backoff and rate limiting.
//!
//! This module provides:
//! - RetryStrategy: Exponential backoff with jitter for failed requests
//! - RateLimiter: Token bucket rate limiting (max 10 req/sec by default)

const std = @import("std");

const errors = @import("errors.zig");
const HubError = errors.HubError;
const ErrorContext = errors.ErrorContext;

/// Configuration for retry behavior
pub const RetryConfig = struct {
    /// Maximum number of retry attempts
    max_retries: u8 = 3,
    /// Base delay in milliseconds
    base_delay_ms: u32 = 100,
    /// Maximum delay in milliseconds
    max_delay_ms: u32 = 10_000,
    /// Backoff multiplier (delay = base * multiplier^attempt)
    backoff_multiplier: f32 = 2.0,
    /// Whether to add random jitter to delays
    jitter_enabled: bool = true,
    /// Maximum jitter as a fraction of delay (0.0 to 1.0)
    jitter_fraction: f32 = 0.25,
};

/// Strategy for retrying failed operations with exponential backoff
pub const RetryStrategy = struct {
    config: RetryConfig,
    prng: std.Random.DefaultPrng,

    const Self = @This();

    /// Create a new retry strategy with default configuration
    pub fn init() Self {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch {
            // Fallback to timestamp-based seed
            seed = @intCast(@as(u128, @bitCast(std.time.nanoTimestamp())) & 0xFFFFFFFFFFFFFFFF);
        };

        return Self{
            .config = .{},
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Create a retry strategy with custom configuration
    pub fn initWithConfig(config: RetryConfig) Self {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch {
            seed = @intCast(@as(u128, @bitCast(std.time.nanoTimestamp())) & 0xFFFFFFFFFFFFFFFF);
        };

        return Self{
            .config = config,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Calculate delay for a given attempt number (0-indexed)
    pub fn calculateDelay(self: *Self, attempt: u8) u32 {
        if (attempt >= self.config.max_retries) {
            return self.config.max_delay_ms;
        }

        // Calculate base exponential delay
        const multiplier = std.math.pow(f32, self.config.backoff_multiplier, @floatFromInt(attempt));
        var delay: f32 = @as(f32, @floatFromInt(self.config.base_delay_ms)) * multiplier;

        // Add jitter if enabled
        if (self.config.jitter_enabled) {
            const max_jitter = delay * self.config.jitter_fraction;
            const jitter = self.prng.random().float(f32) * max_jitter * 2.0 - max_jitter;
            delay += jitter;
        }

        // Clamp to max delay
        const clamped = @min(delay, @as(f32, @floatFromInt(self.config.max_delay_ms)));
        return @intFromFloat(@max(clamped, 1.0));
    }

    /// Calculate delay respecting a Retry-After header value
    pub fn calculateDelayWithRetryAfter(self: *Self, attempt: u8, retry_after_sec: ?u32) u32 {
        const base_delay = self.calculateDelay(attempt);

        if (retry_after_sec) |ra| {
            // Use the larger of calculated delay or server-specified delay
            const server_delay_ms = ra * 1000;
            return @max(base_delay, server_delay_ms);
        }

        return base_delay;
    }

    /// Check if an error should be retried
    pub fn shouldRetry(self: Self, error_ctx: ErrorContext, attempt: u8) bool {
        if (attempt >= self.config.max_retries) {
            return false;
        }
        return error_ctx.isRetryable();
    }

    /// Sleep for the calculated delay
    pub fn sleep(self: *Self, attempt: u8) void {
        const delay_ms = self.calculateDelay(attempt);
        const delay_ns = @as(u64, delay_ms) * std.time.ns_per_ms;
        std.Thread.sleep(delay_ns);
    }

    /// Sleep respecting Retry-After header
    pub fn sleepWithRetryAfter(self: *Self, attempt: u8, retry_after_sec: ?u32) void {
        const delay_ms = self.calculateDelayWithRetryAfter(attempt, retry_after_sec);
        const delay_ns = @as(u64, delay_ms) * std.time.ns_per_ms;
        std.Thread.sleep(delay_ns);
    }

    /// Execute an operation with retry logic
    /// The operation function should return an error or a value
    pub fn execute(
        self: *Self,
        comptime T: type,
        comptime operation: fn (*anyopaque) anyerror!T,
        context: *anyopaque,
    ) !T {
        var attempt: u8 = 0;

        while (true) {
            const result = operation(context);
            if (result) |value| {
                return value;
            } else |err| {
                if (attempt >= self.config.max_retries) {
                    return err;
                }

                // Check if error is retryable based on type
                const retryable = switch (err) {
                    error.NetworkError, error.Timeout, error.ServerError, error.RateLimited => true,
                    else => false,
                };

                if (!retryable) {
                    return err;
                }

                self.sleep(attempt);
                attempt += 1;
            }
        }
    }
};

/// Token bucket rate limiter for controlling request rate
pub const RateLimiter = struct {
    /// Maximum requests per second
    max_requests_per_second: u32,
    /// Time of last request in nanoseconds
    last_request_ns: i128,
    /// Tokens available (for bursting)
    tokens: f64,
    /// Maximum tokens (bucket size)
    max_tokens: f64,
    /// Mutex for thread safety
    mutex: std.Thread.Mutex,

    const Self = @This();

    /// Create a new rate limiter with specified requests per second
    pub fn init(max_requests_per_second: u32) Self {
        const max_tokens = @as(f64, @floatFromInt(max_requests_per_second));
        return Self{
            .max_requests_per_second = max_requests_per_second,
            .last_request_ns = std.time.nanoTimestamp(),
            .tokens = max_tokens, // Start with full bucket
            .max_tokens = max_tokens,
            .mutex = .{},
        };
    }

    /// Create a rate limiter with default 10 req/sec
    pub fn initDefault() Self {
        return init(10);
    }

    /// Acquire a token, blocking if necessary
    /// Returns the time waited in milliseconds
    pub fn acquire(self: *Self) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.last_request_ns;

        // Refill tokens based on elapsed time
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const new_tokens = elapsed_sec * @as(f64, @floatFromInt(self.max_requests_per_second));
        self.tokens = @min(self.tokens + new_tokens, self.max_tokens);
        self.last_request_ns = now;

        // Check if we have a token
        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return 0;
        }

        // Calculate wait time to get a token
        const tokens_needed = 1.0 - self.tokens;
        const wait_sec = tokens_needed / @as(f64, @floatFromInt(self.max_requests_per_second));
        const wait_ns: u64 = @intFromFloat(wait_sec * 1_000_000_000.0);

        // Unlock before sleeping, then relock
        self.mutex.unlock();
        std.Thread.sleep(wait_ns);
        self.mutex.lock();

        // Update state after waiting
        self.last_request_ns = std.time.nanoTimestamp();
        self.tokens = 0; // We just used the token we waited for

        return wait_ns / std.time.ns_per_ms;
    }

    /// Try to acquire a token without blocking
    /// Returns true if token was acquired, false otherwise
    pub fn tryAcquire(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.last_request_ns;

        // Refill tokens
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const new_tokens = elapsed_sec * @as(f64, @floatFromInt(self.max_requests_per_second));
        self.tokens = @min(self.tokens + new_tokens, self.max_tokens);
        self.last_request_ns = now;

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }

        return false;
    }

    /// Get current token count (for monitoring)
    pub fn availableTokens(self: *Self) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.last_request_ns;

        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const new_tokens = elapsed_sec * @as(f64, @floatFromInt(self.max_requests_per_second));
        return @min(self.tokens + new_tokens, self.max_tokens);
    }

    /// Reset the rate limiter (refill all tokens)
    pub fn reset(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.tokens = self.max_tokens;
        self.last_request_ns = std.time.nanoTimestamp();
    }
};

/// Combined retry and rate limiting context for HTTP requests
pub const RequestThrottler = struct {
    retry_strategy: RetryStrategy,
    rate_limiter: RateLimiter,

    const Self = @This();

    /// Initialize with default settings (3 retries, 10 req/sec)
    pub fn init() Self {
        return Self{
            .retry_strategy = RetryStrategy.init(),
            .rate_limiter = RateLimiter.initDefault(),
        };
    }

    /// Initialize with custom settings
    pub fn initWithConfig(retry_config: RetryConfig, max_rps: u32) Self {
        return Self{
            .retry_strategy = RetryStrategy.initWithConfig(retry_config),
            .rate_limiter = RateLimiter.init(max_rps),
        };
    }

    /// Acquire rate limit token and return (for manual request handling)
    pub fn acquireToken(self: *Self) u64 {
        return self.rate_limiter.acquire();
    }

    /// Get the retry strategy for manual retry handling
    pub fn getRetryStrategy(self: *Self) *RetryStrategy {
        return &self.retry_strategy;
    }

    /// Get the rate limiter for monitoring
    pub fn getRateLimiter(self: *Self) *RateLimiter {
        return &self.rate_limiter;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RetryStrategy.calculateDelay - basic exponential backoff" {
    var strategy = RetryStrategy.initWithConfig(.{
        .base_delay_ms = 100,
        .backoff_multiplier = 2.0,
        .jitter_enabled = false,
        .max_delay_ms = 10_000,
    });

    // Attempt 0: 100 * 2^0 = 100ms
    try std.testing.expectEqual(@as(u32, 100), strategy.calculateDelay(0));
    // Attempt 1: 100 * 2^1 = 200ms
    try std.testing.expectEqual(@as(u32, 200), strategy.calculateDelay(1));
    // Attempt 2: 100 * 2^2 = 400ms
    try std.testing.expectEqual(@as(u32, 400), strategy.calculateDelay(2));
}

test "RetryStrategy.calculateDelay - respects max delay" {
    var strategy = RetryStrategy.initWithConfig(.{
        .base_delay_ms = 1000,
        .backoff_multiplier = 10.0,
        .jitter_enabled = false,
        .max_delay_ms = 5_000,
    });

    // Should be capped at 5000ms
    const delay = strategy.calculateDelay(5);
    try std.testing.expect(delay <= 5_000);
}

test "RetryStrategy.calculateDelay - jitter adds variance" {
    var strategy = RetryStrategy.initWithConfig(.{
        .base_delay_ms = 100,
        .backoff_multiplier = 2.0,
        .jitter_enabled = true,
        .jitter_fraction = 0.5,
        .max_delay_ms = 10_000,
    });

    // With jitter, delays should vary
    var delays: [10]u32 = undefined;
    for (&delays) |*d| {
        d.* = strategy.calculateDelay(1);
    }

    // Check that not all delays are identical (with high probability)
    var all_same = true;
    for (delays[1..]) |d| {
        if (d != delays[0]) {
            all_same = false;
            break;
        }
    }
    // It's extremely unlikely all 10 random delays are identical
    try std.testing.expect(!all_same);
}

test "RetryStrategy.calculateDelayWithRetryAfter - uses server value when larger" {
    var strategy = RetryStrategy.initWithConfig(.{
        .base_delay_ms = 100,
        .backoff_multiplier = 2.0,
        .jitter_enabled = false,
        .max_delay_ms = 60_000,
    });

    // Server says retry after 30 seconds
    const delay = strategy.calculateDelayWithRetryAfter(0, 30);
    try std.testing.expect(delay >= 30_000);
}

test "RateLimiter.init" {
    const limiter = RateLimiter.init(10);
    try std.testing.expectEqual(@as(u32, 10), limiter.max_requests_per_second);
}

test "RateLimiter.tryAcquire - respects burst capacity" {
    var limiter = RateLimiter.init(5);

    // Should be able to acquire up to max_tokens initially
    var acquired: u32 = 0;
    for (0..10) |_| {
        if (limiter.tryAcquire()) {
            acquired += 1;
        }
    }

    // Should have acquired approximately 5 tokens (the burst capacity)
    try std.testing.expect(acquired >= 4);
    try std.testing.expect(acquired <= 6);
}

test "ErrorContext.isRetryable" {
    const retryable = ErrorContext.init(HubError.RateLimited, "rate limited");
    try std.testing.expect(retryable.isRetryable());

    const not_retryable = ErrorContext.init(HubError.NotFound, "not found");
    try std.testing.expect(!not_retryable.isRetryable());

    const timeout = ErrorContext.init(HubError.Timeout, "timeout");
    try std.testing.expect(timeout.isRetryable());

    const server_error = ErrorContext.init(HubError.ServerError, "server error");
    try std.testing.expect(server_error.isRetryable());
}

test "RequestThrottler.init" {
    var throttler = RequestThrottler.init();

    // Should be able to get rate limiter
    const limiter = throttler.getRateLimiter();
    try std.testing.expectEqual(@as(u32, 10), limiter.max_requests_per_second);

    // Should be able to get retry strategy
    const strategy = throttler.getRetryStrategy();
    try std.testing.expectEqual(@as(u8, 3), strategy.config.max_retries);
}
