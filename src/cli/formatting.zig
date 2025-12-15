//! CLI formatting utilities for table and output display
//!
//! This module provides formatting utilities for CLI output:
//! - Table formatting with column alignment
//! - JSON pretty-printing with syntax highlighting
//! - Human-readable size and time formatting
//! - Colored status indicators

const std = @import("std");
const Allocator = std.mem.Allocator;

const hf = @import("hf-hub");
const terminal = hf.terminal;
const Color = terminal.Color;
const Style = terminal.Style;
const Icons = terminal.Icons;
const types = hf.types;

// ============================================================================
// Table Formatting
// ============================================================================

/// Column alignment options
pub const Alignment = enum {
    left,
    right,
    center,
};

/// Column definition for tables
pub const Column = struct {
    /// Column header text
    header: []const u8,
    /// Minimum width (0 for auto)
    min_width: u16 = 0,
    /// Maximum width (0 for unlimited)
    max_width: u16 = 0,
    /// Alignment
    alignment: Alignment = .left,
    /// Color for values in this column
    color: ?Color = null,
};

/// Table formatting options
pub const TableOptions = struct {
    /// Whether to use colors
    use_color: bool = true,
    /// Whether to show header
    show_header: bool = true,
    /// Header color
    header_color: Color = .bright_white,
    /// Header style
    header_style: Style = .bold,
    /// Column separator
    separator: []const u8 = "  ",
    /// Whether to use Unicode box drawing
    use_unicode: bool = true,
    /// Truncation indicator
    truncate_indicator: []const u8 = "…",
    /// Alternate row color (for readability)
    alternate_color: ?Color = .bright_black,
    /// Border style (none, simple, box)
    border: BorderStyle = .none,
};

/// Border style for tables
pub const BorderStyle = enum {
    none,
    simple,
    box,
};

/// Table formatter
pub const Table = struct {
    allocator: Allocator,
    columns: []const Column,
    rows: std.array_list.Managed([][]const u8),
    options: TableOptions,
    computed_widths: []u16,

    const Self = @This();

    /// Create a new table
    pub fn init(allocator: Allocator, columns: []const Column, options: TableOptions) !Self {
        var computed_widths = try allocator.alloc(u16, columns.len);
        for (columns, 0..) |col, i| {
            computed_widths[i] = @intCast(@max(col.min_width, col.header.len));
        }

        return Self{
            .allocator = allocator,
            .columns = columns,
            .rows = std.array_list.Managed([][]const u8).init(allocator),
            .options = options,
            .computed_widths = computed_widths,
        };
    }

    /// Clean up
    pub fn deinit(self: *Self) void {
        for (self.rows.items) |row| {
            self.allocator.free(row);
        }
        self.rows.deinit();
        self.allocator.free(self.computed_widths);
    }

    /// Add a row to the table
    pub fn addRow(self: *Self, values: []const []const u8) !void {
        if (values.len != self.columns.len) {
            return error.ColumnCountMismatch;
        }

        // Update computed widths
        for (values, 0..) |val, i| {
            const visible_len = terminal.visibleLength(val);
            self.computed_widths[i] = @max(self.computed_widths[i], @as(u16, @intCast(visible_len)));
        }

        // Copy values
        var row = try self.allocator.alloc([]const u8, values.len);
        for (values, 0..) |val, i| {
            row[i] = try self.allocator.dupe(u8, val);
        }

        try self.rows.append(row);
    }

    /// Render the table to a writer
    pub fn render(self: *Self, writer: anytype) !void {
        // Apply max_width constraints
        for (self.columns, 0..) |col, i| {
            if (col.max_width > 0) {
                self.computed_widths[i] = @min(self.computed_widths[i], col.max_width);
            }
        }

        // Render header
        if (self.options.show_header) {
            try self.renderHeader(writer);
        }

        // Render rows
        for (self.rows.items, 0..) |row, row_idx| {
            try self.renderRow(writer, row, row_idx);
        }
    }

    fn renderHeader(self: *Self, writer: anytype) !void {
        if (self.options.use_color) {
            try writer.print("{s}{s}", .{
                styleCode(self.options.header_style),
                colorCode(self.options.header_color),
            });
        }

        for (self.columns, 0..) |col, i| {
            if (i > 0) {
                try writer.writeAll(self.options.separator);
            }
            try self.writeAligned(writer, col.header, self.computed_widths[i], col.alignment);
        }

        if (self.options.use_color) {
            try writer.writeAll(terminal.RESET);
        }
        try writer.writeAll("\n");

        // Underline
        if (self.options.border == .simple) {
            for (self.computed_widths, 0..) |width, i| {
                if (i > 0) {
                    try writer.writeAll(self.options.separator);
                }
                for (0..width) |_| {
                    try writer.writeAll("-");
                }
            }
            try writer.writeAll("\n");
        }
    }

    fn renderRow(self: *Self, writer: anytype, row: [][]const u8, row_idx: usize) !void {
        // Alternate row coloring
        const use_alternate = self.options.use_color and
            self.options.alternate_color != null and
            row_idx % 2 == 1;

        if (use_alternate) {
            try writer.print("{s}", .{colorCode(self.options.alternate_color.?)});
        }

        for (self.columns, 0..) |col, i| {
            if (i > 0) {
                try writer.writeAll(self.options.separator);
            }

            // Apply column color
            if (self.options.use_color and col.color != null and !use_alternate) {
                try writer.print("{s}", .{colorCode(col.color.?)});
            }

            const value = if (i < row.len) row[i] else "";
            try self.writeAligned(writer, value, self.computed_widths[i], col.alignment);

            if (self.options.use_color and col.color != null and !use_alternate) {
                try writer.writeAll(terminal.RESET);
            }
        }

        if (use_alternate) {
            try writer.writeAll(terminal.RESET);
        }
        try writer.writeAll("\n");
    }

    fn writeAligned(self: *Self, writer: anytype, text: []const u8, width: u16, alignment: Alignment) !void {
        const visible_len = terminal.visibleLength(text);
        const w = @as(usize, width);

        if (visible_len > w) {
            // Truncate
            var written: usize = 0;
            var i: usize = 0;
            while (i < text.len and written < w - 1) {
                // Skip ANSI sequences
                if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
                    const start = i;
                    i += 2;
                    while (i < text.len) {
                        const c = text[i];
                        i += 1;
                        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                            break;
                        }
                    }
                    try writer.writeAll(text[start..i]);
                } else {
                    try writer.writeByte(text[i]);
                    written += 1;
                    i += 1;
                }
            }
            try writer.writeAll(self.options.truncate_indicator);
            // Pad remaining
            const remaining = w - written - 1;
            for (0..remaining) |_| {
                try writer.writeByte(' ');
            }
        } else {
            const padding = w - visible_len;

            switch (alignment) {
                .left => {
                    try writer.writeAll(text);
                    for (0..padding) |_| {
                        try writer.writeByte(' ');
                    }
                },
                .right => {
                    for (0..padding) |_| {
                        try writer.writeByte(' ');
                    }
                    try writer.writeAll(text);
                },
                .center => {
                    const left_pad = padding / 2;
                    const right_pad = padding - left_pad;
                    for (0..left_pad) |_| {
                        try writer.writeByte(' ');
                    }
                    try writer.writeAll(text);
                    for (0..right_pad) |_| {
                        try writer.writeByte(' ');
                    }
                },
            }
        }
    }
};

// ============================================================================
// Status Formatting
// ============================================================================

/// Format a success message
pub fn formatSuccess(writer: anytype, message: []const u8, use_color: bool, use_unicode: bool) !void {
    const icon = Icons.check(use_unicode);
    if (use_color) {
        try writer.print("{s}{s}{s} {s}\n", .{
            colorCode(.bright_green),
            icon,
            terminal.RESET,
            message,
        });
    } else {
        try writer.print("{s} {s}\n", .{ icon, message });
    }
}

/// Format an error message
pub fn formatError(writer: anytype, message: []const u8, use_color: bool, use_unicode: bool) !void {
    const icon = Icons.cross(use_unicode);
    if (use_color) {
        try writer.print("{s}{s}{s} {s}\n", .{
            colorCode(.bright_red),
            icon,
            terminal.RESET,
            message,
        });
    } else {
        try writer.print("{s} {s}\n", .{ icon, message });
    }
}

/// Format a warning message
pub fn formatWarning(writer: anytype, message: []const u8, use_color: bool, use_unicode: bool) !void {
    const icon = Icons.warning(use_unicode);
    if (use_color) {
        try writer.print("{s}{s}{s} {s}\n", .{
            colorCode(.bright_yellow),
            icon,
            terminal.RESET,
            message,
        });
    } else {
        try writer.print("{s} {s}\n", .{ icon, message });
    }
}

/// Format an info message
pub fn formatInfo(writer: anytype, message: []const u8, use_color: bool, use_unicode: bool) !void {
    const icon = Icons.info(use_unicode);
    if (use_color) {
        try writer.print("{s}{s}{s} {s}\n", .{
            colorCode(.bright_cyan),
            icon,
            terminal.RESET,
            message,
        });
    } else {
        try writer.print("{s} {s}\n", .{ icon, message });
    }
}

// ============================================================================
// Value Formatting
// ============================================================================

/// Format a number with color based on value
pub fn formatNumber(buf: []u8, value: u64, use_color: bool) []const u8 {
    if (use_color) {
        const color_code = if (value >= 1_000_000)
            colorCode(.bright_green)
        else if (value >= 10_000)
            colorCode(.green)
        else if (value >= 1_000)
            colorCode(.yellow)
        else
            colorCode(.white);

        return std.fmt.bufPrint(buf, "{s}{d}{s}", .{
            color_code,
            value,
            terminal.RESET,
        }) catch "";
    } else {
        return std.fmt.bufPrint(buf, "{d}", .{value}) catch "";
    }
}

/// Format a file size with color
pub fn formatSize(buf: []u8, bytes: u64, use_color: bool) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (value >= 1024 and unit_idx < units.len - 1) {
        value /= 1024;
        unit_idx += 1;
    }

    if (use_color) {
        const color_code = if (unit_idx >= 3)
            colorCode(.bright_green)
        else if (unit_idx >= 2)
            colorCode(.green)
        else if (unit_idx >= 1)
            colorCode(.cyan)
        else
            colorCode(.white);

        if (unit_idx == 0) {
            return std.fmt.bufPrint(buf, "{s}{d} {s}{s}", .{
                color_code,
                bytes,
                units[0],
                terminal.RESET,
            }) catch "";
        } else {
            return std.fmt.bufPrint(buf, "{s}{d:.2} {s}{s}", .{
                color_code,
                value,
                units[unit_idx],
                terminal.RESET,
            }) catch "";
        }
    } else {
        if (unit_idx == 0) {
            return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch "";
        } else {
            return std.fmt.bufPrint(buf, "{d:.2} {s}", .{ value, units[unit_idx] }) catch "";
        }
    }
}

/// Format a model ID with org/name coloring
pub fn formatModelId(buf: []u8, model_id: []const u8, use_color: bool) []const u8 {
    if (std.mem.indexOf(u8, model_id, "/")) |slash_idx| {
        const org = model_id[0..slash_idx];
        const name = model_id[slash_idx + 1 ..];

        if (use_color) {
            return std.fmt.bufPrint(buf, "{s}{s}{s}/{s}{s}{s}", .{
                colorCode(.cyan),
                org,
                terminal.RESET,
                colorCode(.bright_magenta),
                name,
                terminal.RESET,
            }) catch model_id;
        }
    }
    return model_id;
}

/// Format a tag with color
pub fn formatTag(buf: []u8, tag: []const u8, use_color: bool) []const u8 {
    if (use_color) {
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{
            colorCode(.bright_blue),
            tag,
            terminal.RESET,
        }) catch tag;
    }
    return tag;
}

// ============================================================================
// JSON Formatting with Syntax Highlighting
// ============================================================================

/// JSON syntax highlighting options
pub const JsonHighlight = struct {
    key_color: Color = .bright_cyan,
    string_color: Color = .green,
    number_color: Color = .yellow,
    bool_color: Color = .magenta,
    null_color: Color = .bright_black,
    bracket_color: Color = .white,
};

/// Pretty print JSON with optional syntax highlighting
pub fn formatJsonPretty(
    allocator: Allocator,
    json_str: []const u8,
    use_color: bool,
    highlight: JsonHighlight,
) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var indent_level: usize = 0;
    var in_string = false;
    var i: usize = 0;

    while (i < json_str.len) {
        const c = json_str[i];

        if (in_string) {
            try result.append(c);
            if (c == '"' and (i == 0 or json_str[i - 1] != '\\')) {
                in_string = false;
                if (use_color) {
                    try result.appendSlice(terminal.RESET);
                }
            }
        } else {
            switch (c) {
                '"' => {
                    in_string = true;
                    // Check if this is a key (followed by :)
                    const is_key = isJsonKey(json_str, i);
                    if (use_color) {
                        const color_code = if (is_key) highlight.key_color else highlight.string_color;
                        try result.appendSlice(colorCode(color_code));
                    }
                    try result.append(c);
                },
                '{', '[' => {
                    if (use_color) {
                        try result.appendSlice(colorCode(highlight.bracket_color));
                    }
                    try result.append(c);
                    if (use_color) {
                        try result.appendSlice(terminal.RESET);
                    }
                    indent_level += 1;
                    try result.append('\n');
                    try appendIndent(&result, indent_level);
                },
                '}', ']' => {
                    indent_level -|= 1;
                    try result.append('\n');
                    try appendIndent(&result, indent_level);
                    if (use_color) {
                        try result.appendSlice(colorCode(highlight.bracket_color));
                    }
                    try result.append(c);
                    if (use_color) {
                        try result.appendSlice(terminal.RESET);
                    }
                },
                ':' => {
                    try result.appendSlice(": ");
                },
                ',' => {
                    try result.append(c);
                    try result.append('\n');
                    try appendIndent(&result, indent_level);
                },
                ' ', '\t', '\n', '\r' => {
                    // Skip whitespace (we add our own)
                },
                else => {
                    // Check for keywords and numbers
                    if (c >= '0' and c <= '9' or c == '-') {
                        if (use_color) {
                            try result.appendSlice(colorCode(highlight.number_color));
                        }
                        // Read entire number
                        while (i < json_str.len) {
                            const nc = json_str[i];
                            if ((nc >= '0' and nc <= '9') or nc == '.' or nc == '-' or nc == '+' or nc == 'e' or nc == 'E') {
                                try result.append(nc);
                                i += 1;
                            } else {
                                break;
                            }
                        }
                        if (use_color) {
                            try result.appendSlice(terminal.RESET);
                        }
                        continue;
                    } else if (std.mem.startsWith(u8, json_str[i..], "true")) {
                        if (use_color) {
                            try result.appendSlice(colorCode(highlight.bool_color));
                        }
                        try result.appendSlice("true");
                        if (use_color) {
                            try result.appendSlice(terminal.RESET);
                        }
                        i += 4;
                        continue;
                    } else if (std.mem.startsWith(u8, json_str[i..], "false")) {
                        if (use_color) {
                            try result.appendSlice(colorCode(highlight.bool_color));
                        }
                        try result.appendSlice("false");
                        if (use_color) {
                            try result.appendSlice(terminal.RESET);
                        }
                        i += 5;
                        continue;
                    } else if (std.mem.startsWith(u8, json_str[i..], "null")) {
                        if (use_color) {
                            try result.appendSlice(colorCode(highlight.null_color));
                        }
                        try result.appendSlice("null");
                        if (use_color) {
                            try result.appendSlice(terminal.RESET);
                        }
                        i += 4;
                        continue;
                    } else {
                        try result.append(c);
                    }
                },
            }
        }

        i += 1;
    }

    return result.toOwnedSlice();
}

fn isJsonKey(json: []const u8, quote_pos: usize) bool {
    // Skip past the string
    var i = quote_pos + 1;
    var escaped = false;

    while (i < json.len) {
        const c = json[i];
        if (escaped) {
            escaped = false;
        } else if (c == '\\') {
            escaped = true;
        } else if (c == '"') {
            // Found end of string, look for colon
            i += 1;
            while (i < json.len) {
                const nc = json[i];
                if (nc == ':') return true;
                if (nc != ' ' and nc != '\t' and nc != '\n' and nc != '\r') return false;
                i += 1;
            }
            return false;
        }
        i += 1;
    }
    return false;
}

fn appendIndent(list: *std.array_list.Managed(u8), level: usize) !void {
    for (0..level * 2) |_| {
        try list.append(' ');
    }
}

// ============================================================================
// Header/Banner Formatting
// ============================================================================

/// Print a styled header
pub fn printHeader(writer: anytype, text: []const u8, use_color: bool) !void {
    if (use_color) {
        try writer.print("\n{s}{s}{s} {s} {s}{s}\n\n", .{
            colorCode(.bright_cyan),
            styleCode(.bold),
            "═══",
            text,
            "═══",
            terminal.RESET,
        });
    } else {
        try writer.print("\n=== {s} ===\n\n", .{text});
    }
}

/// Print a section separator
pub fn printSeparator(writer: anytype, use_color: bool, width: u16) !void {
    if (use_color) {
        try writer.print("{s}", .{colorCode(.bright_black)});
    }

    for (0..width) |_| {
        try writer.writeAll("─");
    }

    if (use_color) {
        try writer.print("{s}", .{terminal.RESET});
    }
    try writer.writeAll("\n");
}

/// Print a key-value pair
pub fn printKeyValue(writer: anytype, key: []const u8, value: []const u8, use_color: bool) !void {
    if (use_color) {
        try writer.print("{s}{s}{s}{s}: {s}\n", .{
            colorCode(.bright_white),
            styleCode(.bold),
            key,
            terminal.RESET,
            value,
        });
    } else {
        try writer.print("{s}: {s}\n", .{ key, value });
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

fn colorCode(c: Color) []const u8 {
    return switch (c) {
        .black => "\x1b[30m",
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .blue => "\x1b[34m",
        .magenta => "\x1b[35m",
        .cyan => "\x1b[36m",
        .white => "\x1b[37m",
        .default => "\x1b[39m",
        .bright_black => "\x1b[90m",
        .bright_red => "\x1b[91m",
        .bright_green => "\x1b[92m",
        .bright_yellow => "\x1b[93m",
        .bright_blue => "\x1b[94m",
        .bright_magenta => "\x1b[95m",
        .bright_cyan => "\x1b[96m",
        .bright_white => "\x1b[97m",
    };
}

fn styleCode(s: Style) []const u8 {
    return switch (s) {
        .reset => "\x1b[0m",
        .bold => "\x1b[1m",
        .dim => "\x1b[2m",
        .italic => "\x1b[3m",
        .underline => "\x1b[4m",
        .blink => "\x1b[5m",
        .reverse => "\x1b[7m",
        .hidden => "\x1b[8m",
        .strikethrough => "\x1b[9m",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "formatSize" {
    var buf: [64]u8 = undefined;

    const bytes = formatSize(&buf, 1024, false);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "KB") != null);

    const mb = formatSize(&buf, 1024 * 1024, false);
    try std.testing.expect(std.mem.indexOf(u8, mb, "MB") != null);
}

test "formatNumber" {
    var buf: [64]u8 = undefined;

    const small = formatNumber(&buf, 100, false);
    try std.testing.expectEqualStrings("100", small);

    const large = formatNumber(&buf, 1000000, false);
    try std.testing.expectEqualStrings("1000000", large);
}

test "Alignment enum" {
    try std.testing.expect(@intFromEnum(Alignment.left) == 0);
    try std.testing.expect(@intFromEnum(Alignment.right) == 1);
    try std.testing.expect(@intFromEnum(Alignment.center) == 2);
}
