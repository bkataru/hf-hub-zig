//! Terminal utilities for colored output and cursor control
//!
//! This module provides ANSI escape code utilities for:
//! - Colored text output (foreground and background)
//! - Text styling (bold, dim, italic, underline)
//! - Cursor control (movement, visibility, clearing)
//! - Terminal detection and capability checking

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Standard I/O Helpers (Zig 0.15 compatibility)
// ============================================================================

/// Get stdout writer (Zig 0.15 compatible)
pub fn stdout() std.fs.File.DeprecatedWriter {
    return std.fs.File.stdout().deprecatedWriter();
}

/// Get stderr writer (Zig 0.15 compatible)
pub fn stderr() std.fs.File.DeprecatedWriter {
    return std.fs.File.stderr().deprecatedWriter();
}

/// Get environment variable (Zig 0.15 compatible, cross-platform)
/// For compile-time known keys, use std.process.hasEnvVarConstant instead.
/// This function only works on POSIX systems.
pub fn getEnvPosix(key: [:0]const u8) ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) {
        @compileError("Use std.process.hasEnvVarConstant or std.process.getEnvVarOwned on Windows");
    }
    return std.posix.getenv(key);
}

/// Check if an environment variable is set (cross-platform, compile-time key)
pub fn hasEnvVar(comptime key: []const u8) bool {
    return std.process.hasEnvVarConstant(key);
}

/// ANSI foreground colors
pub const Color = enum(u8) {
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    default = 39,
    // Bright variants
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,

    pub fn toCode(self: Color) u8 {
        return @intFromEnum(self);
    }

    pub fn toBgCode(self: Color) u8 {
        return @intFromEnum(self) + 10;
    }
};

/// Text style modifiers
pub const Style = enum(u8) {
    reset = 0,
    bold = 1,
    dim = 2,
    italic = 3,
    underline = 4,
    blink = 5,
    reverse = 7,
    hidden = 8,
    strikethrough = 9,

    pub fn toCode(self: Style) u8 {
        return @intFromEnum(self);
    }
};

// ============================================================================
// Terminal State
// ============================================================================

/// Global terminal state
pub const Terminal = struct {
    /// Whether terminal supports colors
    colors_enabled: bool,
    /// Whether terminal supports Unicode
    unicode_enabled: bool,
    /// Whether output is a TTY
    is_tty: bool,
    /// Terminal width (columns)
    width: u16,
    /// Terminal height (rows)
    height: u16,

    const Self = @This();

    /// Detect terminal capabilities
    pub fn detect() Self {
        const is_tty = isTty();
        const colors = is_tty and !noColorEnv();
        const unicode = detectUnicode();
        const size = getTerminalSize();

        return Self{
            .colors_enabled = colors,
            .unicode_enabled = unicode,
            .is_tty = is_tty,
            .width = size.width,
            .height = size.height,
        };
    }

    /// Create a terminal with colors disabled
    pub fn noColor() Self {
        return Self{
            .colors_enabled = false,
            .unicode_enabled = false,
            .is_tty = false,
            .width = 80,
            .height = 24,
        };
    }
};

/// Check if stdout is a terminal
pub fn isTty() bool {
    if (comptime builtin.os.tag == .windows) {
        // On Windows, check if stdout handle is a console
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch return false;
        var mode: std.os.windows.DWORD = undefined;
        return std.os.windows.kernel32.GetConsoleMode(handle, &mode) != 0;
    } else {
        return std.posix.isatty(std.posix.STDOUT_FILENO);
    }
}

/// Check if NO_COLOR environment variable is set
pub fn noColorEnv() bool {
    return std.process.hasEnvVarConstant("NO_COLOR");
}

/// Detect if terminal supports Unicode
fn detectUnicode() bool {
    if (comptime builtin.os.tag == .windows) {
        // Windows Terminal and modern consoles support Unicode
        if (std.process.hasEnvVarConstant("WT_SESSION")) return true;
        if (std.process.hasEnvVarConstant("TERM_PROGRAM")) return true;
        return false;
    } else {
        // Check LANG/LC_ALL for UTF-8
        const lang = std.posix.getenv("LANG") orelse
            std.posix.getenv("LC_ALL") orelse "";
        return std.mem.indexOf(u8, lang, "UTF-8") != null or
            std.mem.indexOf(u8, lang, "utf-8") != null or
            std.mem.indexOf(u8, lang, "utf8") != null;
    }
}

/// Get terminal size
fn getTerminalSize() struct { width: u16, height: u16 } {
    if (comptime builtin.os.tag == .windows) {
        // Use Windows Console API
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch {
            return .{ .width = 80, .height = 24 };
        };
        var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(handle, &info) != 0) {
            const width: u16 = @intCast(info.srWindow.Right - info.srWindow.Left + 1);
            const height: u16 = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1);
            return .{ .width = width, .height = height };
        }
        return .{ .width = 80, .height = 24 };
    } else {
        // Use TIOCGWINSZ ioctl
        var ws: std.posix.winsize = undefined;
        const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0) {
            return .{ .width = ws.ws_col, .height = ws.ws_row };
        }
        // Fallback to environment variables
        if (std.posix.getenv("COLUMNS")) |cols| {
            if (std.fmt.parseInt(u16, cols, 10)) |w| {
                if (std.posix.getenv("LINES")) |lines| {
                    if (std.fmt.parseInt(u16, lines, 10)) |h| {
                        return .{ .width = w, .height = h };
                    } else |_| {}
                }
                return .{ .width = w, .height = 24 };
            } else |_| {}
        }
        return .{ .width = 80, .height = 24 };
    }
}

// ============================================================================
// ANSI Escape Sequences
// ============================================================================

/// ANSI escape sequence prefix
pub const ESC = "\x1b[";

/// Reset all formatting
pub const RESET = ESC ++ "0m";

/// Clear from cursor to end of line
pub const CLEAR_LINE = ESC ++ "2K";

/// Clear entire line and move to start
pub const CLEAR_LINE_AND_RETURN = ESC ++ "2K\r";

/// Move cursor to beginning of line
pub const CARRIAGE_RETURN = "\r";

/// Hide cursor
pub const CURSOR_HIDE = ESC ++ "?25l";

/// Show cursor
pub const CURSOR_SHOW = ESC ++ "?25h";

/// Move cursor up N lines
pub fn cursorUp(buf: []u8, n: u16) []const u8 {
    return std.fmt.bufPrint(buf, ESC ++ "{d}A", .{n}) catch ESC ++ "1A";
}

/// Move cursor down N lines
pub fn cursorDown(buf: []u8, n: u16) []const u8 {
    return std.fmt.bufPrint(buf, ESC ++ "{d}B", .{n}) catch ESC ++ "1B";
}

/// Move cursor right N columns
pub fn cursorForward(buf: []u8, n: u16) []const u8 {
    return std.fmt.bufPrint(buf, ESC ++ "{d}C", .{n}) catch ESC ++ "1C";
}

/// Move cursor left N columns
pub fn cursorBack(buf: []u8, n: u16) []const u8 {
    return std.fmt.bufPrint(buf, ESC ++ "{d}D", .{n}) catch ESC ++ "1D";
}

/// Move cursor to column N
pub fn cursorToColumn(buf: []u8, col: u16) []const u8 {
    return std.fmt.bufPrint(buf, ESC ++ "{d}G", .{col}) catch ESC ++ "1G";
}

/// Move cursor to position (row, col)
pub fn cursorTo(buf: []u8, row: u16, col: u16) []const u8 {
    return std.fmt.bufPrint(buf, ESC ++ "{d};{d}H", .{ row, col }) catch ESC ++ "1;1H";
}

/// Save cursor position
pub const CURSOR_SAVE = ESC ++ "s";

/// Restore cursor position
pub const CURSOR_RESTORE = ESC ++ "u";

// ============================================================================
// Styled Output
// ============================================================================

/// Format text with a single color
pub fn color(buf: []u8, text: []const u8, fg: Color) []const u8 {
    return std.fmt.bufPrint(buf, ESC ++ "{d}m{s}" ++ RESET, .{ fg.toCode(), text }) catch text;
}

/// Format text with foreground and background colors
pub fn colorBg(buf: []u8, text: []const u8, fg: Color, bg: Color) []const u8 {
    return std.fmt.bufPrint(buf, ESC ++ "{d};{d}m{s}" ++ RESET, .{ fg.toCode(), bg.toBgCode(), text }) catch text;
}

/// Format text with style
pub fn styled(buf: []u8, text: []const u8, style: Style) []const u8 {
    return std.fmt.bufPrint(buf, ESC ++ "{d}m{s}" ++ RESET, .{ style.toCode(), text }) catch text;
}

/// Format text with color and style
pub fn styledColor(buf: []u8, text: []const u8, fg: Color, style: Style) []const u8 {
    return std.fmt.bufPrint(buf, ESC ++ "{d};{d}m{s}" ++ RESET, .{ style.toCode(), fg.toCode(), text }) catch text;
}

/// Writer that adds color codes
pub const ColorWriter = struct {
    inner: std.fs.File.Writer,
    enabled: bool,

    const Self = @This();

    pub fn init(writer: std.fs.File.Writer, enabled: bool) Self {
        return Self{
            .inner = writer,
            .enabled = enabled,
        };
    }

    pub fn write(self: Self, bytes: []const u8) !usize {
        return self.inner.write(bytes);
    }

    pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
        try self.inner.print(fmt, args);
    }

    pub fn setColor(self: Self, fg: Color) !void {
        if (self.enabled) {
            try self.inner.print(ESC ++ "{d}m", .{fg.toCode()});
        }
    }

    pub fn setStyle(self: Self, style: Style) !void {
        if (self.enabled) {
            try self.inner.print(ESC ++ "{d}m", .{style.toCode()});
        }
    }

    pub fn reset(self: Self) !void {
        if (self.enabled) {
            try self.inner.writeAll(RESET);
        }
    }

    pub fn clearLine(self: Self) !void {
        if (self.enabled) {
            try self.inner.writeAll(CLEAR_LINE_AND_RETURN);
        }
    }

    /// Write colored text
    pub fn writeColored(self: Self, text: []const u8, fg: Color) !void {
        if (self.enabled) {
            try self.inner.print(ESC ++ "{d}m{s}" ++ RESET, .{ fg.toCode(), text });
        } else {
            try self.inner.writeAll(text);
        }
    }

    /// Write styled and colored text
    pub fn writeStyled(self: Self, text: []const u8, fg: Color, style: Style) !void {
        if (self.enabled) {
            try self.inner.print(ESC ++ "{d};{d}m{s}" ++ RESET, .{ style.toCode(), fg.toCode(), text });
        } else {
            try self.inner.writeAll(text);
        }
    }
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Print colored text to stdout
pub fn printColored(comptime fg: Color, comptime fmt: []const u8, args: anytype) void {
    const stdout_writer = std.fs.File.stdout().deprecatedWriter();
    if (isTty() and !noColorEnv()) {
        stdout_writer.print(ESC ++ "{d}m" ++ fmt ++ RESET, .{fg.toCode()} ++ args) catch {};
    } else {
        stdout_writer.print(fmt, args) catch {};
    }
}

/// Status indicator icons
pub const Icons = struct {
    // Unicode variants
    pub const check_unicode = "✓";
    pub const cross_unicode = "✗";
    pub const warning_unicode = "⚠";
    pub const info_unicode = "ℹ";
    pub const arrow_unicode = "→";
    pub const bullet_unicode = "•";
    pub const spinner_unicode = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    pub const progress_filled_unicode = "█";
    pub const progress_empty_unicode = "░";
    pub const progress_partial_unicode = [_][]const u8{ " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

    // ASCII fallback variants
    pub const check_ascii = "+";
    pub const cross_ascii = "x";
    pub const warning_ascii = "!";
    pub const info_ascii = "i";
    pub const arrow_ascii = "->";
    pub const bullet_ascii = "*";
    pub const spinner_ascii = [_][]const u8{ "|", "/", "-", "\\" };
    pub const progress_filled_ascii = "#";
    pub const progress_empty_ascii = "-";

    /// Get appropriate icon based on Unicode support
    pub fn check(unicode: bool) []const u8 {
        return if (unicode) check_unicode else check_ascii;
    }

    pub fn cross(unicode: bool) []const u8 {
        return if (unicode) cross_unicode else cross_ascii;
    }

    pub fn warning(unicode: bool) []const u8 {
        return if (unicode) warning_unicode else warning_ascii;
    }

    pub fn info(unicode: bool) []const u8 {
        return if (unicode) info_unicode else info_ascii;
    }

    pub fn arrow(unicode: bool) []const u8 {
        return if (unicode) arrow_unicode else arrow_ascii;
    }

    pub fn bullet(unicode: bool) []const u8 {
        return if (unicode) bullet_unicode else bullet_ascii;
    }

    pub fn spinner(unicode: bool, frame: usize) []const u8 {
        if (unicode) {
            return spinner_unicode[frame % spinner_unicode.len];
        } else {
            return spinner_ascii[frame % spinner_ascii.len];
        }
    }

    pub fn progressFilled(unicode: bool) []const u8 {
        return if (unicode) progress_filled_unicode else progress_filled_ascii;
    }

    pub fn progressEmpty(unicode: bool) []const u8 {
        return if (unicode) progress_empty_unicode else progress_empty_ascii;
    }
};

/// Semantic colors for different message types
pub const Semantic = struct {
    pub const success = Color.green;
    pub const error_color = Color.red;
    pub const warning = Color.yellow;
    pub const info = Color.cyan;
    pub const highlight = Color.magenta;
    pub const muted = Color.bright_black;
    pub const header = Color.bright_white;
    pub const value = Color.bright_cyan;
};

/// Strip ANSI escape codes from a string
pub fn stripAnsi(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\x1b' and i + 1 < input.len and input[i + 1] == '[') {
            // Skip until we find a letter (end of escape sequence)
            i += 2;
            while (i < input.len) {
                const c = input[i];
                i += 1;
                if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                    break;
                }
            }
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

/// Calculate visible length of string (excluding ANSI codes)
pub fn visibleLength(input: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == '\x1b' and i + 1 < input.len and input[i + 1] == '[') {
            // Skip escape sequence
            i += 2;
            while (i < input.len) {
                const c = input[i];
                i += 1;
                if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                    break;
                }
            }
        } else {
            len += 1;
            i += 1;
        }
    }

    return len;
}

// ============================================================================
// Tests
// ============================================================================

test "Color codes" {
    try std.testing.expectEqual(@as(u8, 31), Color.red.toCode());
    try std.testing.expectEqual(@as(u8, 32), Color.green.toCode());
    try std.testing.expectEqual(@as(u8, 41), Color.red.toBgCode());
}

test "Style codes" {
    try std.testing.expectEqual(@as(u8, 0), Style.reset.toCode());
    try std.testing.expectEqual(@as(u8, 1), Style.bold.toCode());
}

test "color formatting" {
    var buf: [256]u8 = undefined;
    const result = color(&buf, "test", .red);
    try std.testing.expect(std.mem.indexOf(u8, result, "31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "test") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "0m") != null);
}

test "visibleLength" {
    const plain = "hello";
    try std.testing.expectEqual(@as(usize, 5), visibleLength(plain));

    const colored = "\x1b[31mhello\x1b[0m";
    try std.testing.expectEqual(@as(usize, 5), visibleLength(colored));

    const styled_text = "\x1b[1;32mtest\x1b[0m";
    try std.testing.expectEqual(@as(usize, 4), visibleLength(styled_text));
}

test "stripAnsi" {
    const allocator = std.testing.allocator;

    const colored = "\x1b[31mhello\x1b[0m world";
    const stripped = try stripAnsi(allocator, colored);
    defer allocator.free(stripped);

    try std.testing.expectEqualStrings("hello world", stripped);
}

test "Icons fallback" {
    try std.testing.expectEqualStrings("✓", Icons.check(true));
    try std.testing.expectEqualStrings("+", Icons.check(false));
    try std.testing.expectEqualStrings("✗", Icons.cross(true));
    try std.testing.expectEqualStrings("x", Icons.cross(false));
}

test "Terminal.noColor" {
    const term = Terminal.noColor();
    try std.testing.expect(!term.colors_enabled);
    try std.testing.expect(!term.is_tty);
    try std.testing.expectEqual(@as(u16, 80), term.width);
}
