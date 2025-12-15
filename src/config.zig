//! Configuration management for HuggingFace Hub client.
//! Reads settings from environment variables and provides OS-aware defaults.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// Configuration for the HuggingFace Hub client.
pub const Config = struct {
    /// HuggingFace Hub API endpoint.
    endpoint: []const u8 = "https://huggingface.co",

    /// API token for authentication (optional, for private models).
    token: ?[]const u8 = null,

    /// Local cache directory for downloaded files.
    cache_dir: ?[]const u8 = null,

    /// Request timeout in milliseconds.
    timeout_ms: u32 = 30_000,

    /// Maximum number of retry attempts for failed requests.
    max_retries: u8 = 3,

    /// Whether to show progress indicators.
    use_progress: bool = true,

    /// Whether to use colored output.
    use_color: bool = true,

    /// Maximum requests per second (rate limiting).
    max_requests_per_second: u32 = 10,

    /// Maximum concurrent download threads.
    max_concurrent_downloads: u8 = 4,

    allocator: ?Allocator = null,

    /// Tracks which fields were allocated and need to be freed.
    allocated_fields: AllocatedFields = .{},

    const AllocatedFields = struct {
        endpoint: bool = false,
        token: bool = false,
        cache_dir: bool = false,
    };

    /// Creates a configuration from environment variables.
    /// Environment variables:
    /// - HF_TOKEN: API token for authentication
    /// - HF_ENDPOINT: Override API endpoint
    /// - HF_HOME: Override cache directory
    /// - HF_TIMEOUT: Request timeout in milliseconds
    /// - NO_COLOR: Disable colored output if set
    pub fn fromEnv(allocator: Allocator) !Config {
        var config = Config{
            .allocator = allocator,
        };

        // Read HF_TOKEN
        if (getEnvVarOwned(allocator, "HF_TOKEN")) |token| {
            config.token = token;
            config.allocated_fields.token = true;
        } else |_| {}

        // Read HF_ENDPOINT
        if (getEnvVarOwned(allocator, "HF_ENDPOINT")) |endpoint| {
            config.endpoint = endpoint;
            config.allocated_fields.endpoint = true;
        } else |_| {}

        // Read HF_HOME for cache directory
        if (getEnvVarOwned(allocator, "HF_HOME")) |home| {
            defer allocator.free(home);
            const cache_path = try std.fs.path.join(allocator, &.{ home, "hub" });
            config.cache_dir = cache_path;
            config.allocated_fields.cache_dir = true;
        } else |_| {
            // Use OS-specific default cache directory
            const default_cache = try getDefaultCacheDir(allocator);
            config.cache_dir = default_cache;
            config.allocated_fields.cache_dir = true;
        }

        // Read HF_TIMEOUT
        if (getEnvVarOwned(allocator, "HF_TIMEOUT")) |timeout_str| {
            defer allocator.free(timeout_str);
            if (std.fmt.parseInt(u32, timeout_str, 10)) |timeout| {
                config.timeout_ms = timeout;
            } else |_| {
                // Invalid timeout, keep default
            }
        } else |_| {}

        // Check NO_COLOR
        if (getEnvVarOwned(allocator, "NO_COLOR")) |no_color| {
            allocator.free(no_color);
            config.use_color = false;
        } else |_| {}

        return config;
    }

    /// Creates a default configuration without reading environment.
    pub fn default(allocator: Allocator) !Config {
        var config = Config{
            .allocator = allocator,
        };

        // Set default cache directory
        const default_cache = try getDefaultCacheDir(allocator);
        config.cache_dir = default_cache;
        config.allocated_fields.cache_dir = true;

        return config;
    }

    /// Frees any allocated memory in the configuration.
    pub fn deinit(self: *Config) void {
        if (self.allocator) |allocator| {
            if (self.allocated_fields.endpoint) {
                allocator.free(self.endpoint);
            }
            if (self.allocated_fields.token) {
                if (self.token) |token| {
                    allocator.free(token);
                }
            }
            if (self.allocated_fields.cache_dir) {
                if (self.cache_dir) |cache_dir| {
                    allocator.free(cache_dir);
                }
            }
        }
        self.* = .{};
    }

    /// Creates a copy of the configuration with new allocator ownership.
    pub fn clone(self: Config, allocator: Allocator) !Config {
        var new_config = Config{
            .timeout_ms = self.timeout_ms,
            .max_retries = self.max_retries,
            .use_progress = self.use_progress,
            .use_color = self.use_color,
            .max_requests_per_second = self.max_requests_per_second,
            .max_concurrent_downloads = self.max_concurrent_downloads,
            .allocator = allocator,
        };

        // Clone endpoint
        const endpoint_copy = try allocator.dupe(u8, self.endpoint);
        new_config.endpoint = endpoint_copy;
        new_config.allocated_fields.endpoint = true;

        // Clone token if present
        if (self.token) |token| {
            const token_copy = try allocator.dupe(u8, token);
            new_config.token = token_copy;
            new_config.allocated_fields.token = true;
        }

        // Clone cache_dir if present
        if (self.cache_dir) |cache_dir| {
            const cache_dir_copy = try allocator.dupe(u8, cache_dir);
            new_config.cache_dir = cache_dir_copy;
            new_config.allocated_fields.cache_dir = true;
        }

        return new_config;
    }

    /// Validates the configuration.
    pub fn validate(self: Config) !void {
        // Validate endpoint URL
        if (self.endpoint.len == 0) {
            return error.InvalidEndpoint;
        }
        if (!std.mem.startsWith(u8, self.endpoint, "http://") and
            !std.mem.startsWith(u8, self.endpoint, "https://"))
        {
            return error.InvalidEndpoint;
        }

        // Validate timeout
        if (self.timeout_ms == 0) {
            return error.InvalidTimeout;
        }

        // Validate rate limit
        if (self.max_requests_per_second == 0) {
            return error.InvalidRateLimit;
        }
    }
};

/// Gets an environment variable value (cross-platform).
/// Returns an owned slice that must be freed by the caller.
fn getEnvVarOwned(allocator: Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name);
}

/// Returns the OS-specific default cache directory.
/// Windows: %LOCALAPPDATA%\huggingface\hub
/// macOS: ~/Library/Caches/huggingface/hub
/// Linux/others: ~/.cache/huggingface/hub
fn getDefaultCacheDir(allocator: Allocator) ![]const u8 {
    if (comptime builtin.os.tag == .windows) {
        // Windows: Use LOCALAPPDATA
        if (getEnvVarOwned(allocator, "LOCALAPPDATA")) |local_app_data| {
            defer allocator.free(local_app_data);
            return try std.fs.path.join(allocator, &.{ local_app_data, "huggingface", "hub" });
        } else |_| {}
        // Fallback to USERPROFILE
        if (getEnvVarOwned(allocator, "USERPROFILE")) |user_profile| {
            defer allocator.free(user_profile);
            return try std.fs.path.join(allocator, &.{ user_profile, ".cache", "huggingface", "hub" });
        } else |_| {}
        return error.NoCacheDirectory;
    } else if (comptime builtin.os.tag == .macos) {
        // macOS: Use ~/Library/Caches
        if (getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return try std.fs.path.join(allocator, &.{ home, "Library", "Caches", "huggingface", "hub" });
        } else |_| {}
        return error.NoCacheDirectory;
    } else {
        // Linux and others: Use XDG_CACHE_HOME or ~/.cache
        if (getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |xdg_cache| {
            defer allocator.free(xdg_cache);
            return try std.fs.path.join(allocator, &.{ xdg_cache, "huggingface", "hub" });
        } else |_| {}
        if (getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return try std.fs.path.join(allocator, &.{ home, ".cache", "huggingface", "hub" });
        } else |_| {}
        return error.NoCacheDirectory;
    }
}

/// Ensures the cache directory exists, creating it if necessary.
pub fn ensureCacheDir(config: Config) !void {
    if (config.cache_dir) |cache_dir| {
        std.fs.cwd().makePath(cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

/// Returns a model-specific cache path within the cache directory.
/// Format: {cache_dir}/models--{org}--{model_name}
pub fn getModelCachePath(allocator: Allocator, config: Config, repo_id: []const u8) ![]const u8 {
    const cache_dir = config.cache_dir orelse return error.NoCacheDirectory;

    // Replace '/' with '--' in repo_id for directory name
    var sanitized = try allocator.alloc(u8, repo_id.len);
    defer allocator.free(sanitized);

    for (repo_id, 0..) |char, i| {
        sanitized[i] = if (char == '/') '-' else char;
    }

    // Build: models--{sanitized_repo_id}
    const model_dir_name = try std.fmt.allocPrint(allocator, "models--{s}", .{sanitized});
    defer allocator.free(model_dir_name);

    return try std.fs.path.join(allocator, &.{ cache_dir, model_dir_name });
}

// Tests
test "Config default values" {
    const config = Config{};
    try std.testing.expectEqualStrings("https://huggingface.co", config.endpoint);
    try std.testing.expect(config.token == null);
    try std.testing.expect(config.timeout_ms == 30_000);
    try std.testing.expect(config.max_retries == 3);
    try std.testing.expect(config.use_progress == true);
    try std.testing.expect(config.use_color == true);
    try std.testing.expect(config.max_requests_per_second == 10);
    try std.testing.expect(config.max_concurrent_downloads == 4);
}

test "Config validation - valid config" {
    const config = Config{};
    try config.validate();
}

test "Config validation - empty endpoint" {
    const config = Config{ .endpoint = "" };
    try std.testing.expectError(error.InvalidEndpoint, config.validate());
}

test "Config validation - invalid endpoint protocol" {
    const config = Config{ .endpoint = "ftp://example.com" };
    try std.testing.expectError(error.InvalidEndpoint, config.validate());
}

test "Config validation - zero timeout" {
    const config = Config{ .timeout_ms = 0 };
    try std.testing.expectError(error.InvalidTimeout, config.validate());
}

test "Config clone" {
    const allocator = std.testing.allocator;

    var original = Config{
        .endpoint = "https://test.com",
        .token = "test-token",
        .timeout_ms = 5000,
    };

    var cloned = try original.clone(allocator);
    defer cloned.deinit();

    try std.testing.expectEqualStrings("https://test.com", cloned.endpoint);
    try std.testing.expectEqualStrings("test-token", cloned.token.?);
    try std.testing.expect(cloned.timeout_ms == 5000);
}
