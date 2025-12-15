//! Batch Download Example
//!
//! This example demonstrates how to download multiple GGUF files from
//! different models using the hf-hub-zig library.
//!
//! Run with:
//!   zig build-exe examples/batch_download.zig -M hf-hub=src/lib.zig
//!   # or just reference as an example

const std = @import("std");

const hf = @import("hf-hub");

/// Information about a file to download
const DownloadTask = struct {
    model_id: []const u8,
    filename: []const u8,
    description: []const u8,
};

/// List of files to download
const downloads = [_]DownloadTask{
    .{
        .model_id = "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
        .filename = "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
        .description = "TinyLlama 1.1B Q4_K_M",
    },
    // Add more models here as needed
    // .{
    //     .model_id = "TheBloke/Mistral-7B-Instruct-v0.2-GGUF",
    //     .filename = "mistral-7b-instruct-v0.2.Q4_K_M.gguf",
    //     .description = "Mistral 7B Instruct Q4_K_M",
    // },
};

/// Progress callback with file name context
const ProgressContext = struct {
    name: []const u8,
    last_pct: u8 = 0,

    fn callback(progress: hf.DownloadProgress) void {
        const pct = progress.percentComplete();
        // Only print every 10%
        if (pct >= 10 and @mod(pct, 10) == 0) {
            const speed = progress.downloadSpeed();
            var speed_buf: [32]u8 = undefined;
            const speed_str = hf.formatBytesPerSecond(speed, &speed_buf);
            std.debug.print("\r  Progress: {d}% @ {s}     ", .{ pct, speed_str });
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize HubClient
    std.debug.print("Initializing HuggingFace Hub client...\n", .{});
    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Get output directory from args or use current directory
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const output_dir = if (args.len > 1) args[1] else ".";
    std.debug.print("Output directory: {s}\n\n", .{output_dir});

    // Track statistics
    var successful: usize = 0;
    var failed: usize = 0;
    var total_bytes: u64 = 0;

    const start_time = std.time.nanoTimestamp();

    // Download each file
    for (downloads, 0..) |task, i| {
        std.debug.print("[{d}/{d}] {s}\n", .{ i + 1, downloads.len, task.description });
        std.debug.print("  Model: {s}\n", .{task.model_id});
        std.debug.print("  File: {s}\n", .{task.filename});

        // Check if already cached
        if (client.isCached(task.model_id, task.filename, "main") catch false) {
            std.debug.print("  Status: Already cached, skipping\n\n", .{});
            successful += 1;
            continue;
        }

        // Get file size first
        const metadata = client.getFileMetadata(task.model_id, task.filename, "main") catch |err| {
            std.debug.print("  Error getting metadata: {}\n\n", .{err});
            failed += 1;
            continue;
        };

        if (metadata.size) |size| {
            var size_buf: [32]u8 = undefined;
            std.debug.print("  Size: {s}\n", .{hf.formatBytes(size, &size_buf)});
        }

        // Download
        std.debug.print("  Downloading...\n", .{});
        const path = client.downloadFileWithOptions(
            task.model_id,
            task.filename,
            "main",
            output_dir,
            ProgressContext.callback,
        ) catch |err| {
            std.debug.print("\n  Error: {}\n\n", .{err});
            failed += 1;
            continue;
        };
        defer allocator.free(path);

        std.debug.print("\n  Saved to: {s}\n", .{path});

        // Update stats
        successful += 1;
        if (metadata.size) |size| {
            total_bytes += size;
        }

        std.debug.print("\n", .{});
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_secs = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000_000.0;

    // Print summary
    std.debug.print("=" ** 50 ++ "\n", .{});
    std.debug.print("Download Summary\n", .{});
    std.debug.print("=" ** 50 ++ "\n", .{});
    std.debug.print("  Successful: {d}\n", .{successful});
    std.debug.print("  Failed: {d}\n", .{failed});

    var total_buf: [32]u8 = undefined;
    std.debug.print("  Total size: {s}\n", .{hf.formatBytes(total_bytes, &total_buf)});
    std.debug.print("  Time: {d:.1} seconds\n", .{elapsed_secs});

    if (total_bytes > 0 and elapsed_secs > 0) {
        const avg_speed = @as(f64, @floatFromInt(total_bytes)) / elapsed_secs;
        var speed_buf: [32]u8 = undefined;
        std.debug.print("  Avg speed: {s}\n", .{hf.formatBytesPerSecond(avg_speed, &speed_buf)});
    }
}
