//! Custom Progress Callback Example
//!
//! This example demonstrates how to implement a custom progress callback
//! for download operations with hf-hub-zig.
//!
//! Features demonstrated:
//! - Custom progress callback function
//! - Progress bar with ANSI colors
//! - Speed calculation and ETA display
//! - Different progress display styles

const std = @import("std");

const hf = @import("hf-hub");

// ============================================================================
// Progress Display Styles
// ============================================================================

/// Simple percentage display
fn simpleProgress(progress: hf.DownloadProgress) void {
    const pct = progress.percentComplete();
    std.debug.print("\rDownloading: {d}%", .{pct});
}

/// Progress with speed
fn progressWithSpeed(progress: hf.DownloadProgress) void {
    const pct = progress.percentComplete();
    const speed = progress.downloadSpeed();

    var speed_buf: [32]u8 = undefined;
    const speed_str = hf.formatBytesPerSecond(speed, &speed_buf);

    std.debug.print("\r[{d:>3}%] {s}    ", .{ pct, speed_str });
}

/// Full progress bar with ETA
fn fullProgressBar(progress: hf.DownloadProgress) void {
    const pct = progress.percentComplete();
    const speed = progress.downloadSpeed();
    const bar_width: u32 = 30;
    const filled = (pct * bar_width) / 100;

    // Build the bar
    var bar: [30]u8 = undefined;
    for (0..bar_width) |i| {
        if (i < filled) {
            bar[i] = '=';
        } else if (i == filled) {
            bar[i] = '>';
        } else {
            bar[i] = ' ';
        }
    }

    // Format sizes
    var dl_buf: [32]u8 = undefined;
    const dl_str = hf.formatBytes(progress.bytes_downloaded, &dl_buf);

    var speed_buf: [32]u8 = undefined;
    const speed_str = hf.formatBytesPerSecond(speed, &speed_buf);

    // Format ETA
    if (progress.total_bytes) |total| {
        var total_buf: [32]u8 = undefined;
        const total_str = hf.formatBytes(total, &total_buf);

        if (progress.estimatedTimeRemaining()) |eta| {
            const eta_min = @as(u32, @intFromFloat(eta / 60));
            const eta_sec = @as(u32, @intFromFloat(@mod(eta, 60)));
            std.debug.print("\r[{s}] {d}% | {s}/{s} | {s} | ETA: {d}:{d:0>2}    ", .{
                bar[0..bar_width],
                pct,
                dl_str,
                total_str,
                speed_str,
                eta_min,
                eta_sec,
            });
        } else {
            std.debug.print("\r[{s}] {d}% | {s}/{s} | {s}    ", .{
                bar[0..bar_width],
                pct,
                dl_str,
                total_str,
                speed_str,
            });
        }
    } else {
        std.debug.print("\r[{s}] {s} | {s}    ", .{
            bar[0..bar_width],
            dl_str,
            speed_str,
        });
    }
}

/// Colorful progress bar using ANSI escape codes
fn colorfulProgress(progress: hf.DownloadProgress) void {
    const pct = progress.percentComplete();
    const speed = progress.downloadSpeed();
    const bar_width: u32 = 25;
    const filled = (pct * bar_width) / 100;

    // ANSI color codes
    const RESET = "\x1b[0m";
    const BOLD = "\x1b[1m";
    const CYAN = "\x1b[36m";
    const GREEN = "\x1b[32m";
    const YELLOW = "\x1b[33m";

    // Build colored bar
    var bar: [25]u8 = undefined;
    for (0..bar_width) |i| {
        bar[i] = if (i < filled) '#' else '-';
    }

    var speed_buf: [32]u8 = undefined;
    const speed_str = hf.formatBytesPerSecond(speed, &speed_buf);

    // Color based on progress
    const color = if (pct >= 100) GREEN else if (pct >= 50) CYAN else YELLOW;

    std.debug.print("\r{s}{s}[{s}{s}{s}]{s} {s}{d}%{s} @ {s}    ", .{
        BOLD,
        CYAN,
        color,
        bar[0..bar_width],
        CYAN,
        RESET,
        BOLD,
        pct,
        RESET,
        speed_str,
    });
}

/// Spinner with progress (for when total size is unknown)
fn spinnerProgress(progress: hf.DownloadProgress) void {
    const spinner_chars = [_]u8{ '|', '/', '-', '\\' };

    // Use bytes downloaded to rotate the spinner
    const spinner_idx = (progress.bytes_downloaded / 100000) % 4;
    const spinner = spinner_chars[@intCast(spinner_idx)];

    var dl_buf: [32]u8 = undefined;
    const dl_str = hf.formatBytes(progress.bytes_downloaded, &dl_buf);

    const speed = progress.downloadSpeed();
    var speed_buf: [32]u8 = undefined;
    const speed_str = hf.formatBytesPerSecond(speed, &speed_buf);

    std.debug.print("\r{c} Downloading: {s} @ {s}    ", .{ spinner, dl_str, speed_str });
}

// ============================================================================
// Main Function
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line for progress style
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var style: enum { simple, speed, full, colorful, spinner } = .full;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--simple")) {
            style = .simple;
        } else if (std.mem.eql(u8, arg, "--speed")) {
            style = .speed;
        } else if (std.mem.eql(u8, arg, "--full")) {
            style = .full;
        } else if (std.mem.eql(u8, arg, "--colorful")) {
            style = .colorful;
        } else if (std.mem.eql(u8, arg, "--spinner")) {
            style = .spinner;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        }
    }

    // Initialize client
    std.debug.print("Initializing HuggingFace Hub client...\n", .{});
    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Use a small test file for the demo
    const model_id = "bert-base-uncased";
    const filename = "config.json";

    std.debug.print("Downloading {s}/{s}\n", .{ model_id, filename });
    std.debug.print("Progress style: {s}\n\n", .{@tagName(style)});

    // Select the appropriate callback
    const callback: hf.ProgressCallback = switch (style) {
        .simple => simpleProgress,
        .speed => progressWithSpeed,
        .full => fullProgressBar,
        .colorful => colorfulProgress,
        .spinner => spinnerProgress,
    };

    // Create temp dir for download
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Download with progress
    const path = try client.downloadFileWithOptions(
        model_id,
        filename,
        "main",
        tmp_path,
        callback,
    );
    defer allocator.free(path);

    std.debug.print("\n\nDownload complete!\n", .{});
    std.debug.print("Saved to: {s}\n", .{path});
}

fn printUsage() void {
    std.debug.print(
        \\Custom Progress Callback Example - hf-hub-zig
        \\
        \\Demonstrates different progress display styles.
        \\
        \\Usage: custom_progress [--style]
        \\
        \\Progress Styles:
        \\  --simple     Basic percentage only
        \\  --speed      Percentage with download speed
        \\  --full       Full progress bar with ETA (default)
        \\  --colorful   Progress bar with ANSI colors
        \\  --spinner    Spinner for unknown file sizes
        \\
        \\Options:
        \\  -h, --help   Show this help message
        \\
        \\Examples:
        \\  custom_progress --colorful
        \\  custom_progress --spinner
        \\
    , .{});
}
