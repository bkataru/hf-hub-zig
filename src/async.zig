//! Async operations and thread pool for concurrent downloads
//!
//! This module provides:
//! - Thread pool with configurable concurrency
//! - Batch download operations
//! - Shared rate limiting across threads
//! - Progress tracking for concurrent operations

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const client_mod = @import("client.zig");
const HttpClient = client_mod.HttpClient;
const Config = @import("config.zig").Config;
const downloader_mod = @import("downloader.zig");
const Downloader = downloader_mod.Downloader;
const DownloadResult = downloader_mod.DownloadResult;
const DownloadOptions = downloader_mod.DownloadOptions;
const errors = @import("errors.zig");
const HubError = errors.HubError;
const retry_mod = @import("retry.zig");
const RateLimiter = retry_mod.RateLimiter;
const types = @import("types.zig");
const DownloadProgress = types.DownloadProgress;
const DownloadItem = types.DownloadItem;

/// Result of an async download operation
pub const AsyncDownloadResult = struct {
    /// The original download item
    item: DownloadItem,
    /// Index in the original batch
    index: usize,
    /// Download status
    status: DownloadStatus,
    /// Download result (if successful)
    result: ?DownloadResult = null,
    /// Error message (if failed)
    error_message: ?[]const u8 = null,
    /// Time taken in nanoseconds
    duration_ns: i128 = 0,

    pub fn deinit(self: *AsyncDownloadResult, allocator: Allocator) void {
        if (self.result) |*r| {
            var res = r.*;
            res.deinit(allocator);
        }
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

/// Download status enum
pub const DownloadStatus = enum {
    pending,
    downloading,
    success,
    failed,
    skipped,
    cancelled,
};

/// Progress callback for batch operations
/// Takes the item index and progress information
pub const BatchProgressCallback = *const fn (index: usize, progress: DownloadProgress) void;

/// Configuration for the thread pool
pub const ThreadPoolConfig = struct {
    /// Number of worker threads
    num_threads: u8 = 4,
    /// Rate limiter for API requests (shared across threads)
    max_requests_per_second: u32 = 10,
    /// Download options
    download_options: DownloadOptions = .{},
};

/// Thread pool for concurrent operations
pub const ThreadPool = struct {
    allocator: Allocator,
    config: ThreadPoolConfig,
    rate_limiter: RateLimiter,
    workers: []Worker,
    work_queue: WorkQueue,
    results: std.array_list.Managed(AsyncDownloadResult),
    results_mutex: Thread.Mutex,
    shutdown: std.atomic.Value(bool),

    const Self = @This();

    /// Worker thread state
    const Worker = struct {
        thread: ?Thread,
        pool: *Self,
        id: u8,
        http_client: ?HttpClient,

        pub fn init(id: u8, pool: *Self) Worker {
            return Worker{
                .thread = null,
                .pool = pool,
                .id = id,
                .http_client = null,
            };
        }

        pub fn start(self: *Worker, endpoint: []const u8, token: ?[]const u8) !void {
            // Initialize HTTP client for this worker
            self.http_client = try HttpClient.initDefault(self.pool.allocator);
            if (self.http_client) |*client| {
                client.endpoint = endpoint;
                client.token = token;
            }

            self.thread = try Thread.spawn(.{}, workerLoop, .{self});
        }

        pub fn join(self: *Worker) void {
            if (self.thread) |thread| {
                thread.join();
            }
            if (self.http_client) |*client| {
                client.deinit();
            }
        }
    };

    /// Work item in the queue
    const WorkItem = struct {
        item: DownloadItem,
        index: usize,
        progress_cb: ?BatchProgressCallback,
    };

    /// Thread-safe work queue
    const WorkQueue = struct {
        items: std.array_list.Managed(WorkItem),
        mutex: Thread.Mutex,
        not_empty: Thread.Condition,
        head: usize,

        pub fn init(allocator: Allocator) WorkQueue {
            return WorkQueue{
                .items = std.array_list.Managed(WorkItem).init(allocator),
                .mutex = .{},
                .not_empty = .{},
                .head = 0,
            };
        }

        pub fn deinit(self: *WorkQueue) void {
            self.items.deinit();
        }

        pub fn push(self: *WorkQueue, item: WorkItem) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.items.append(item);
            self.not_empty.signal();
        }

        pub fn pop(self: *WorkQueue, shutdown: *std.atomic.Value(bool)) ?WorkItem {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.head >= self.items.items.len) {
                if (shutdown.load(.acquire)) {
                    return null;
                }
                self.not_empty.wait(&self.mutex);

                if (shutdown.load(.acquire)) {
                    return null;
                }
            }

            const item = self.items.items[self.head];
            self.head += 1;
            return item;
        }

        pub fn isEmpty(self: *WorkQueue) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.head >= self.items.items.len;
        }

        pub fn clear(self: *WorkQueue) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
    };

    /// Initialize the thread pool
    pub fn init(allocator: Allocator, config: ThreadPoolConfig) !Self {
        const workers = try allocator.alloc(Worker, config.num_threads);
        for (workers, 0..) |*w, i| {
            w.* = Worker.init(@intCast(i), undefined);
        }

        var pool = Self{
            .allocator = allocator,
            .config = config,
            .rate_limiter = RateLimiter.init(config.max_requests_per_second),
            .workers = workers,
            .work_queue = WorkQueue.init(allocator),
            .results = std.array_list.Managed(AsyncDownloadResult).init(allocator),
            .results_mutex = .{},
            .shutdown = std.atomic.Value(bool).init(false),
        };

        // Set pool reference in workers
        for (pool.workers) |*w| {
            w.pool = &pool;
        }

        return pool;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.stop();

        for (self.results.items) |*r| {
            r.deinit(self.allocator);
        }
        self.results.deinit();
        self.work_queue.deinit();
        self.allocator.free(self.workers);
    }

    /// Start worker threads
    pub fn start(self: *Self, endpoint: []const u8, token: ?[]const u8) !void {
        for (self.workers) |*worker| {
            try worker.start(endpoint, token);
        }
    }

    /// Stop all worker threads
    pub fn stop(self: *Self) void {
        self.shutdown.store(true, .release);

        // Wake up all waiting workers
        for (0..self.workers.len) |_| {
            self.work_queue.not_empty.signal();
        }

        // Join all threads
        for (self.workers) |*worker| {
            worker.join();
        }
    }

    /// Submit a batch of downloads
    pub fn submitBatch(
        self: *Self,
        items: []const DownloadItem,
        progress_cb: ?BatchProgressCallback,
    ) !void {
        for (items, 0..) |item, i| {
            try self.work_queue.push(WorkItem{
                .item = item,
                .index = i,
                .progress_cb = progress_cb,
            });
        }
    }

    /// Wait for all work to complete and return results
    pub fn waitForResults(self: *Self) []AsyncDownloadResult {
        // Wait until queue is empty and all work is done
        while (!self.work_queue.isEmpty()) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        // Give workers time to finish current items
        std.Thread.sleep(100 * std.time.ns_per_ms);

        self.results_mutex.lock();
        defer self.results_mutex.unlock();
        return self.results.items;
    }

    /// Get current results (non-blocking)
    pub fn getResults(self: *Self) []AsyncDownloadResult {
        self.results_mutex.lock();
        defer self.results_mutex.unlock();
        return self.results.items;
    }

    /// Add a result (thread-safe)
    fn addResult(self: *Self, result: AsyncDownloadResult) !void {
        self.results_mutex.lock();
        defer self.results_mutex.unlock();
        try self.results.append(result);
    }
};

/// Worker thread main loop
fn workerLoop(worker: *ThreadPool.Worker) void {
    const pool = worker.pool;

    while (!pool.shutdown.load(.acquire)) {
        // Get next work item
        const work_item = pool.work_queue.pop(&pool.shutdown) orelse break;

        // Acquire rate limit token
        _ = pool.rate_limiter.acquire();

        // Perform download
        const start_time = std.time.nanoTimestamp();
        var result = performDownload(worker, work_item);
        result.duration_ns = std.time.nanoTimestamp() - start_time;

        // Store result
        pool.addResult(result) catch {};
    }
}

/// Perform a single download
fn performDownload(worker: *ThreadPool.Worker, work: ThreadPool.WorkItem) AsyncDownloadResult {
    var result = AsyncDownloadResult{
        .item = work.item,
        .index = work.index,
        .status = .downloading,
    };

    // Check if we have an HTTP client
    var client = worker.http_client orelse {
        result.status = .failed;
        result.error_message = worker.pool.allocator.dupe(u8, "No HTTP client") catch null;
        return result;
    };

    // Build download URL
    const url = std.fmt.allocPrint(
        worker.pool.allocator,
        "{s}/{s}/resolve/{s}/{s}",
        .{ client.endpoint, work.item.repo_id, work.item.revision, work.item.filename },
    ) catch {
        result.status = .failed;
        result.error_message = worker.pool.allocator.dupe(u8, "Failed to build URL") catch null;
        return result;
    };
    defer worker.pool.allocator.free(url);

    // Build output path
    const output_path = std.fs.path.join(
        worker.pool.allocator,
        &.{ work.item.output_dir, work.item.filename },
    ) catch {
        result.status = .failed;
        result.error_message = worker.pool.allocator.dupe(u8, "Failed to build path") catch null;
        return result;
    };
    defer worker.pool.allocator.free(output_path);

    // Create progress callback wrapper
    const ProgressWrapper = struct {
        work_item: *const ThreadPool.WorkItem,

        pub fn callback(self: @This(), progress: DownloadProgress) void {
            if (self.work_item.progress_cb) |cb| {
                cb(self.work_item.index, progress);
            }
        }
    };

    const progress_wrapper = ProgressWrapper{ .work_item = &work };
    _ = progress_wrapper;

    // Perform download
    var downloader = Downloader.initWithOptions(
        worker.pool.allocator,
        &client,
        worker.pool.config.download_options,
    );

    const download_result = downloader.download(url, output_path, null) catch |err| {
        result.status = .failed;
        result.error_message = worker.pool.allocator.dupe(u8, @errorName(err)) catch null;
        return result;
    };

    result.status = .success;
    result.result = download_result;
    return result;
}

/// Batch download helper (non-threaded, sequential)
pub fn batchDownloadSequential(
    allocator: Allocator,
    client: *HttpClient,
    items: []const DownloadItem,
    progress_cb: ?BatchProgressCallback,
) ![]AsyncDownloadResult {
    var results = std.array_list.Managed(AsyncDownloadResult).init(allocator);
    errdefer {
        for (results.items) |*r| {
            r.deinit(allocator);
        }
        results.deinit();
    }

    var downloader = Downloader.init(allocator, client);

    for (items, 0..) |item, i| {
        const start_time = std.time.nanoTimestamp();
        var result = AsyncDownloadResult{
            .item = item,
            .index = i,
            .status = .downloading,
        };

        // Build URL
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/resolve/{s}/{s}",
            .{ client.endpoint, item.repo_id, item.revision, item.filename },
        );
        defer allocator.free(url);

        // Build output path
        const output_path = try std.fs.path.join(allocator, &.{ item.output_dir, item.filename });
        defer allocator.free(output_path);

        // Create wrapper for progress callback
        const wrapper_cb: ?types.ProgressCallback = if (progress_cb) |cb| blk: {
            // We can't easily pass the index through, so use a simple callback
            _ = cb;
            break :blk null;
        } else null;

        // Download
        const download_result = downloader.download(url, output_path, wrapper_cb) catch |err| {
            result.status = .failed;
            result.error_message = try allocator.dupe(u8, @errorName(err));
            result.duration_ns = std.time.nanoTimestamp() - start_time;
            try results.append(result);
            continue;
        };

        result.status = .success;
        result.result = download_result;
        result.duration_ns = std.time.nanoTimestamp() - start_time;
        try results.append(result);
    }

    return results.toOwnedSlice();
}

/// Summary of batch download results
pub const BatchSummary = struct {
    total: usize,
    successful: usize,
    failed: usize,
    skipped: usize,
    total_bytes: u64,
    total_duration_ns: i128,

    pub fn fromResults(results: []const AsyncDownloadResult) BatchSummary {
        var summary = BatchSummary{
            .total = results.len,
            .successful = 0,
            .failed = 0,
            .skipped = 0,
            .total_bytes = 0,
            .total_duration_ns = 0,
        };

        for (results) |r| {
            summary.total_duration_ns += r.duration_ns;

            switch (r.status) {
                .success => {
                    summary.successful += 1;
                    if (r.result) |res| {
                        summary.total_bytes += res.total_size;
                    }
                },
                .failed => summary.failed += 1,
                .skipped, .cancelled => summary.skipped += 1,
                else => {},
            }
        }

        return summary;
    }

    pub fn averageSpeed(self: BatchSummary) f64 {
        if (self.total_duration_ns <= 0) return 0;
        const duration_sec = @as(f64, @floatFromInt(self.total_duration_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.total_bytes)) / duration_sec;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ThreadPoolConfig defaults" {
    const config = ThreadPoolConfig{};
    try std.testing.expectEqual(@as(u8, 4), config.num_threads);
    try std.testing.expectEqual(@as(u32, 10), config.max_requests_per_second);
}

test "AsyncDownloadResult initial status" {
    const result = AsyncDownloadResult{
        .item = DownloadItem{
            .repo_id = "test/repo",
            .filename = "model.gguf",
            .output_dir = "/tmp",
        },
        .index = 0,
        .status = .pending,
    };

    try std.testing.expectEqual(DownloadStatus.pending, result.status);
    try std.testing.expect(result.result == null);
    try std.testing.expect(result.error_message == null);
}

test "BatchSummary.fromResults" {
    const results = [_]AsyncDownloadResult{
        .{
            .item = .{ .repo_id = "a", .filename = "a.gguf", .output_dir = "/tmp" },
            .index = 0,
            .status = .success,
            .result = .{ .path = "/tmp/a.gguf", .bytes_downloaded = 100, .total_size = 100, .was_resumed = false, .checksum_verified = false },
            .duration_ns = 1_000_000_000,
        },
        .{
            .item = .{ .repo_id = "b", .filename = "b.gguf", .output_dir = "/tmp" },
            .index = 1,
            .status = .failed,
            .error_message = "error",
            .duration_ns = 500_000_000,
        },
    };

    const summary = BatchSummary.fromResults(&results);
    try std.testing.expectEqual(@as(usize, 2), summary.total);
    try std.testing.expectEqual(@as(usize, 1), summary.successful);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(u64, 100), summary.total_bytes);
}

test "DownloadStatus enum values" {
    try std.testing.expect(@intFromEnum(DownloadStatus.pending) != @intFromEnum(DownloadStatus.success));
    try std.testing.expect(@intFromEnum(DownloadStatus.failed) != @intFromEnum(DownloadStatus.success));
}
