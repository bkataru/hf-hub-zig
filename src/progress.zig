//! Progress bar rendering with ANSI colors and animations
//!
//! This module provides a beautiful, animated progress bar with:
//! - Colorful output using ANSI escape codes
//! - Real-time speed and ETA display
//! - Support for multiple concurrent progress bars
//! - Graceful degradation for non-TTY environments

const std = @import("std");

const types = @import("types.zig");
const DownloadProgress = types.DownloadProgress;

/// ANSI color codes for terminal output
pub const Color = enum(u8) {
    reset = 0,
    bold = 1,
    dim = 2,
    italic = 3,
    underline = 4,

    // Foreground colors
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,

    // Bright foreground colors
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,

    // Background colors
    bg_black = 40,
    bg_red = 41,
    bg_green = 42,
    bg_yellow = 43,
    bg_blue = 44,
    bg_magenta = 45,
    bg_cyan = 46,
    bg_white = 47,

    pub fn code(self: Color) u8 {
        return @intFromEnum(self);
    }
};

/// Style configuration for the progress bar
pub const ProgressStyle = struct {
    /// Character for filled portion of the bar
    filled: []const u8 = "█",
    /// Character for empty portion of the bar
    empty: []const u8 = "░",
    /// Character for the progress head
    head: []const u8 = "▓",
    /// Left bracket
    left_bracket: []const u8 = "[",
    /// Right bracket
    right_bracket: []const u8 = "]",
    /// Color for the filled portion
    filled_color: Color = .cyan,
    /// Color for the empty portion
    empty_color: Color = .bright_black,
    /// Color for percentage
    percent_color: Color = .bright_white,
    /// Color for speed
    speed_color: Color = .green,
    /// Color for ETA
    eta_color: Color = .yellow,
    /// Color for filename
    filename_color: Color = .magenta,
    /// Color for completed bar
    complete_color: Color = .bright_green,
    /// Color for error
    error_color: Color = .bright_red,
    /// Width of the progress bar (excluding text)
    bar_width: u16 = 30,
    /// Whether to show percentage
    show_percent: bool = true,
    /// Whether to show speed
    show_speed: bool = true,
    /// Whether to show ETA
    show_eta: bool = true,
    /// Whether to show filename
    show_filename: bool = true,
    /// Whether to show downloaded/total size
    show_size: bool = true,
    /// Spinner frames for indeterminate progress
    spinner_frames: []const []const u8 = &[_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
};

/// Progress bar renderer
pub const ProgressBar = struct {
    style: ProgressStyle,
    use_color: bool,
    is_tty: bool,
    writer: std.fs.File.DeprecatedWriter,
    spinner_frame: usize = 0,
    last_update_ns: i128 = 0,
    update_interval_ns: i128 = 50 * std.time.ns_per_ms, // Update every 50ms

    const Self = @This();

    /// Create a new progress bar with default style
    pub fn init() Self {
        return initWithStyle(.{});
    }

    /// Create a new progress bar with custom style
    pub fn initWithStyle(style: ProgressStyle) Self {
        const stdout_file = std.fs.File.stdout();
        const is_tty = stdout_file.isTty();

        return Self{
            .style = style,
            .use_color = is_tty and !isNoColor(),
            .is_tty = is_tty,
            .writer = stdout_file.deprecatedWriter(),
        };
    }

    /// Render a progress update
    pub fn render(self: *Self, progress: DownloadProgress) void {
        // Throttle updates
        const now = std.time.nanoTimestamp();
        if (now - self.last_update_ns < self.update_interval_ns) {
            return;
        }
        self.last_update_ns = now;

        if (self.is_tty) {
            self.renderTty(progress);
        } else {
            self.renderPlain(progress);
        }
    }

    /// Render a complete message
    pub fn complete(self: *Self, filename: []const u8, total_size: u64) void {
        if (self.is_tty) {
            self.clearLine();
        }

        var size_buf: [32]u8 = undefined;
        const size_str = types.formatBytes(total_size, &size_buf);

        if (self.use_color) {
            self.writer.print("{s} {s}{s}{s} {s}[{s}]{s} Downloaded {s}{s}{s}\n", .{
                self.colorCode(.bright_green),
                "✓",
                self.colorCode(.reset),
                self.colorCode(.magenta),
                filename,
                self.colorCode(.reset),
                self.colorCode(.dim),
                self.colorCode(.green),
                size_str,
                self.colorCode(.reset),
            }) catch {};
        } else {
            self.writer.print("✓ {s} Downloaded {s}\n", .{ filename, size_str }) catch {};
        }
    }

    /// Render an error message
    pub fn renderError(self: *Self, filename: []const u8, message: []const u8) void {
        if (self.is_tty) {
            self.clearLine();
        }

        if (self.use_color) {
            self.writer.print("{s}✗{s} {s}{s}{s}: {s}{s}{s}\n", .{
                self.colorCode(.bright_red),
                self.colorCode(.reset),
                self.colorCode(.magenta),
                filename,
                self.colorCode(.reset),
                self.colorCode(.red),
                message,
                self.colorCode(.reset),
            }) catch {};
        } else {
            self.writer.print("✗ {s}: {s}\n", .{ filename, message }) catch {};
        }
    }

    /// Clear the current line (for TTY only)
    pub fn clearLine(self: *Self) void {
        if (self.is_tty) {
            self.writer.print("\r\x1b[2K", .{}) catch {};
        }
    }

    /// Move cursor up N lines
    pub fn cursorUp(self: *Self, n: u16) void {
        if (self.is_tty and n > 0) {
            self.writer.print("\x1b[{d}A", .{n}) catch {};
        }
    }

    /// Move cursor down N lines
    pub fn cursorDown(self: *Self, n: u16) void {
        if (self.is_tty and n > 0) {
            self.writer.print("\x1b[{d}B", .{n}) catch {};
        }
    }

    /// Hide cursor
    pub fn hideCursor(self: *Self) void {
        if (self.is_tty) {
            self.writer.print("\x1b[?25l", .{}) catch {};
        }
    }

    /// Show cursor
    pub fn showCursor(self: *Self) void {
        if (self.is_tty) {
            self.writer.print("\x1b[?25h", .{}) catch {};
        }
    }

    // ========================================================================
    // Private rendering methods
    // ========================================================================

    fn renderTty(self: *Self, progress: DownloadProgress) void {
        self.clearLine();

        var line_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&line_buf);
        const line_writer = fbs.writer();

        // Filename
        if (self.style.show_filename) {
            if (self.use_color) {
                line_writer.print("{s}", .{self.colorCode(.magenta)}) catch {};
            }
            // Truncate filename if too long
            const max_name_len: usize = 20;
            const name = progress.filename;
            if (name.len > max_name_len) {
                line_writer.print("{s}…", .{name[0 .. max_name_len - 1]}) catch {};
            } else {
                line_writer.print("{s}", .{name}) catch {};
                // Pad with spaces
                const padding = max_name_len - name.len;
                for (0..padding) |_| {
                    line_writer.writeByte(' ') catch {};
                }
            }
            if (self.use_color) {
                line_writer.print("{s}", .{self.colorCode(.reset)}) catch {};
            }
            line_writer.print(" ", .{}) catch {};
        }

        // Progress bar
        const percent = progress.percentComplete();
        const filled_width = (@as(u32, percent) * self.style.bar_width) / 100;
        const empty_width = self.style.bar_width - @as(u16, @intCast(filled_width));

        line_writer.print("{s}", .{self.style.left_bracket}) catch {};

        // Filled portion
        if (self.use_color) {
            const color = if (percent >= 100) self.style.complete_color else self.style.filled_color;
            line_writer.print("{s}", .{self.colorCode(color)}) catch {};
        }
        for (0..filled_width) |_| {
            line_writer.print("{s}", .{self.style.filled}) catch {};
        }

        // Empty portion
        if (self.use_color) {
            line_writer.print("{s}", .{self.colorCode(self.style.empty_color)}) catch {};
        }
        for (0..empty_width) |_| {
            line_writer.print("{s}", .{self.style.empty}) catch {};
        }

        if (self.use_color) {
            line_writer.print("{s}", .{self.colorCode(.reset)}) catch {};
        }
        line_writer.print("{s} ", .{self.style.right_bracket}) catch {};

        // Percentage
        if (self.style.show_percent) {
            if (self.use_color) {
                line_writer.print("{s}", .{self.colorCode(self.style.percent_color)}) catch {};
            }
            line_writer.print("{d:3}%", .{percent}) catch {};
            if (self.use_color) {
                line_writer.print("{s}", .{self.colorCode(.reset)}) catch {};
            }
            line_writer.print(" ", .{}) catch {};
        }

        // Size
        if (self.style.show_size) {
            var downloaded_buf: [16]u8 = undefined;
            const downloaded = types.formatBytes(progress.bytes_downloaded, &downloaded_buf);

            if (progress.total_bytes) |total| {
                var total_buf: [16]u8 = undefined;
                const total_str = types.formatBytes(total, &total_buf);
                if (self.use_color) {
                    line_writer.print("{s}", .{self.colorCode(.dim)}) catch {};
                }
                line_writer.print("{s}/{s}", .{ downloaded, total_str }) catch {};
                if (self.use_color) {
                    line_writer.print("{s}", .{self.colorCode(.reset)}) catch {};
                }
            } else {
                if (self.use_color) {
                    line_writer.print("{s}", .{self.colorCode(.dim)}) catch {};
                }
                line_writer.print("{s}", .{downloaded}) catch {};
                if (self.use_color) {
                    line_writer.print("{s}", .{self.colorCode(.reset)}) catch {};
                }
            }
            line_writer.print(" ", .{}) catch {};
        }

        // Speed
        if (self.style.show_speed) {
            var speed_buf: [16]u8 = undefined;
            const speed = progress.formatSpeed(&speed_buf);
            if (self.use_color) {
                line_writer.print("{s}", .{self.colorCode(self.style.speed_color)}) catch {};
            }
            line_writer.print("{s}", .{speed}) catch {};
            if (self.use_color) {
                line_writer.print("{s}", .{self.colorCode(.reset)}) catch {};
            }
            line_writer.print(" ", .{}) catch {};
        }

        // ETA
        if (self.style.show_eta) {
            var eta_buf: [16]u8 = undefined;
            const eta = progress.formatEta(&eta_buf);
            if (!std.mem.eql(u8, eta, "unknown")) {
                if (self.use_color) {
                    line_writer.print("{s}", .{self.colorCode(self.style.eta_color)}) catch {};
                }
                line_writer.print("ETA {s}", .{eta}) catch {};
                if (self.use_color) {
                    line_writer.print("{s}", .{self.colorCode(.reset)}) catch {};
                }
            }
        }

        const written = fbs.getWritten();
        self.writer.writeAll(written) catch {};
    }

    fn renderPlain(self: *Self, progress: DownloadProgress) void {
        const percent = progress.percentComplete();
        var size_buf: [32]u8 = undefined;
        const downloaded = types.formatBytes(progress.bytes_downloaded, &size_buf);

        if (progress.total_bytes) |total| {
            var total_buf: [32]u8 = undefined;
            const total_str = types.formatBytes(total, &total_buf);
            self.writer.print("{s}: {d}% ({s}/{s})\n", .{
                progress.filename,
                percent,
                downloaded,
                total_str,
            }) catch {};
        } else {
            self.writer.print("{s}: {s}\n", .{ progress.filename, downloaded }) catch {};
        }
    }

    fn colorCode(self: *Self, color: Color) []const u8 {
        if (!self.use_color) return "";

        const codes = struct {
            const reset = "\x1b[0m";
            const bold = "\x1b[1m";
            const dim = "\x1b[2m";
            const italic = "\x1b[3m";
            const underline = "\x1b[4m";
            const black = "\x1b[30m";
            const red = "\x1b[31m";
            const green = "\x1b[32m";
            const yellow = "\x1b[33m";
            const blue = "\x1b[34m";
            const magenta = "\x1b[35m";
            const cyan = "\x1b[36m";
            const white = "\x1b[37m";
            const bright_black = "\x1b[90m";
            const bright_red = "\x1b[91m";
            const bright_green = "\x1b[92m";
            const bright_yellow = "\x1b[93m";
            const bright_blue = "\x1b[94m";
            const bright_magenta = "\x1b[95m";
            const bright_cyan = "\x1b[96m";
            const bright_white = "\x1b[97m";
            const bg_black = "\x1b[40m";
            const bg_red = "\x1b[41m";
            const bg_green = "\x1b[42m";
            const bg_yellow = "\x1b[43m";
            const bg_blue = "\x1b[44m";
            const bg_magenta = "\x1b[45m";
            const bg_cyan = "\x1b[46m";
            const bg_white = "\x1b[47m";
        };

        return switch (color) {
            .reset => codes.reset,
            .bold => codes.bold,
            .dim => codes.dim,
            .italic => codes.italic,
            .underline => codes.underline,
            .black => codes.black,
            .red => codes.red,
            .green => codes.green,
            .yellow => codes.yellow,
            .blue => codes.blue,
            .magenta => codes.magenta,
            .cyan => codes.cyan,
            .white => codes.white,
            .bright_black => codes.bright_black,
            .bright_red => codes.bright_red,
            .bright_green => codes.bright_green,
            .bright_yellow => codes.bright_yellow,
            .bright_blue => codes.bright_blue,
            .bright_magenta => codes.bright_magenta,
            .bright_cyan => codes.bright_cyan,
            .bright_white => codes.bright_white,
            .bg_black => codes.bg_black,
            .bg_red => codes.bg_red,
            .bg_green => codes.bg_green,
            .bg_yellow => codes.bg_yellow,
            .bg_blue => codes.bg_blue,
            .bg_magenta => codes.bg_magenta,
            .bg_cyan => codes.bg_cyan,
            .bg_white => codes.bg_white,
        };
    }
};

/// Multi-progress bar for concurrent downloads
pub const MultiProgressBar = struct {
    bars: std.array_list.Managed(BarState),
    allocator: std.mem.Allocator,
    style: ProgressStyle,
    use_color: bool,
    is_tty: bool,
    writer: std.fs.File.DeprecatedWriter,
    lines_rendered: u16 = 0,

    const BarState = struct {
        filename: []const u8,
        progress: DownloadProgress,
        complete: bool = false,
        has_error: bool = false,
        error_message: ?[]const u8 = null,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const stdout_file = std.fs.File.stdout();
        return Self{
            .bars = std.array_list.Managed(BarState).init(allocator),
            .allocator = allocator,
            .style = .{},
            .use_color = stdout_file.isTty() and !isNoColor(),
            .is_tty = stdout_file.isTty(),
            .writer = stdout_file.deprecatedWriter(),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.bars.items) |bar| {
            self.allocator.free(bar.filename);
            if (bar.error_message) |msg| {
                self.allocator.free(msg);
            }
        }
        self.bars.deinit();
    }

    /// Add a new progress bar
    pub fn addBar(self: *Self, filename: []const u8) !usize {
        const filename_copy = try self.allocator.dupe(u8, filename);
        try self.bars.append(.{
            .filename = filename_copy,
            .progress = .{
                .bytes_downloaded = 0,
                .total_bytes = null,
                .start_time_ns = std.time.nanoTimestamp(),
                .current_time_ns = std.time.nanoTimestamp(),
                .filename = filename_copy,
            },
        });
        return self.bars.items.len - 1;
    }

    /// Update a specific progress bar
    pub fn update(self: *Self, index: usize, progress: DownloadProgress) void {
        if (index < self.bars.items.len) {
            self.bars.items[index].progress = progress;
            self.render();
        }
    }

    /// Mark a bar as complete
    pub fn markComplete(self: *Self, index: usize) void {
        if (index < self.bars.items.len) {
            self.bars.items[index].complete = true;
            self.render();
        }
    }

    /// Mark a bar as errored
    pub fn markError(self: *Self, index: usize, message: []const u8) void {
        if (index < self.bars.items.len) {
            self.bars.items[index].has_error = true;
            self.bars.items[index].error_message = self.allocator.dupe(u8, message) catch null;
            self.render();
        }
    }

    /// Render all progress bars
    pub fn render(self: *Self) void {
        if (!self.is_tty) return;

        // Move cursor up to overwrite previous output
        if (self.lines_rendered > 0) {
            self.writer.print("\x1b[{d}A", .{self.lines_rendered}) catch {};
        }

        for (self.bars.items) |bar| {
            self.writer.print("\x1b[2K", .{}) catch {}; // Clear line
            self.renderSingleBar(bar);
            self.writer.print("\n", .{}) catch {};
        }

        self.lines_rendered = @intCast(self.bars.items.len);
    }

    fn renderSingleBar(self: *Self, bar: BarState) void {
        var single = ProgressBar.initWithStyle(self.style);
        single.use_color = self.use_color;

        if (bar.has_error) {
            single.renderError(bar.filename, bar.error_message orelse "Unknown error");
        } else if (bar.complete) {
            single.complete(bar.filename, bar.progress.bytes_downloaded);
        } else {
            single.renderTty(bar.progress);
        }
    }

    /// Finish and show final state
    pub fn finish(self: *Self) void {
        if (self.is_tty) {
            self.writer.print("\x1b[?25h", .{}) catch {}; // Show cursor
        }
    }
};

/// Check if NO_COLOR environment variable is set
fn isNoColor() bool {
    return std.process.hasEnvVarConstant("NO_COLOR");
}

/// Format a colored string
pub fn colorize(color: Color, text: []const u8, buf: []u8) []const u8 {
    const code_num = color.code();
    const result = std.fmt.bufPrint(buf, "\x1b[{d}m{s}\x1b[0m", .{ code_num, text }) catch return text;
    return result;
}

/// Print a success message
pub fn printSuccess(message: []const u8) void {
    const stdout_file = std.fs.File.stdout();
    const writer = stdout_file.deprecatedWriter();
    if (stdout_file.isTty() and !isNoColor()) {
        writer.print("\x1b[92m✓\x1b[0m {s}\n", .{message}) catch {};
    } else {
        writer.print("✓ {s}\n", .{message}) catch {};
    }
}

/// Print an error message
pub fn printError(message: []const u8) void {
    const stderr_file = std.fs.File.stderr();
    const writer = stderr_file.deprecatedWriter();
    if (stderr_file.isTty() and !isNoColor()) {
        writer.print("\x1b[91m✗\x1b[0m {s}\n", .{message}) catch {};
    } else {
        writer.print("✗ {s}\n", .{message}) catch {};
    }
}

/// Print a warning message
pub fn printWarning(message: []const u8) void {
    const stderr_file = std.fs.File.stderr();
    const writer = stderr_file.deprecatedWriter();
    if (stderr_file.isTty() and !isNoColor()) {
        writer.print("\x1b[93m⚠\x1b[0m {s}\n", .{message}) catch {};
    } else {
        writer.print("⚠ {s}\n", .{message}) catch {};
    }
}

/// Print an info message
pub fn printInfo(message: []const u8) void {
    const stdout_file = std.fs.File.stdout();
    const writer = stdout_file.deprecatedWriter();
    if (stdout_file.isTty() and !isNoColor()) {
        writer.print("\x1b[96mℹ\x1b[0m {s}\n", .{message}) catch {};
    } else {
        writer.print("ℹ {s}\n", .{message}) catch {};
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Color enum values" {
    try std.testing.expectEqual(@as(u8, 0), Color.reset.code());
    try std.testing.expectEqual(@as(u8, 31), Color.red.code());
    try std.testing.expectEqual(@as(u8, 92), Color.bright_green.code());
}

test "ProgressStyle defaults" {
    const style = ProgressStyle{};
    try std.testing.expectEqualStrings("█", style.filled);
    try std.testing.expectEqualStrings("░", style.empty);
    try std.testing.expectEqual(@as(u16, 30), style.bar_width);
}

test "ProgressBar initialization" {
    const bar = ProgressBar.init();
    _ = bar;
}

test "colorize function" {
    var buf: [64]u8 = undefined;
    const result = colorize(.green, "test", &buf);
    try std.testing.expect(result.len > 4); // "test" plus escape codes
}
