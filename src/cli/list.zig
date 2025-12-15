//! CLI list command - List files in a model repository
//!
//! Usage: hf-hub list [OPTIONS] <MODEL_ID>
//!
//! Options:
//!   --gguf-only          Only show GGUF files
//!   --json               Output in JSON format
//!   --size-format <FMT>  Format: human (default), bytes, kb, mb, gb
//!   -h, --help           Show help

const std = @import("std");
const Allocator = std.mem.Allocator;

const hf = @import("hf-hub");
const Config = hf.Config;
const HubClient = hf.HubClient;
const terminal = hf.terminal;
const types = hf.types;
const FileInfo = types.FileInfo;

const commands = @import("commands.zig");
const GlobalOptions = commands.GlobalOptions;
const CommandResult = commands.CommandResult;
const formatting = @import("formatting.zig");

/// List command options
pub const ListOptions = struct {
    /// Model ID to list files for
    model_id: ?[]const u8 = null,
    /// Only show GGUF files
    gguf_only: bool = false,
    /// Output in JSON format
    json_output: bool = false,
    /// Size format (human, bytes, kb, mb, gb)
    size_format: SizeFormat = .human,
    /// Show help
    help: bool = false,
    /// Revision/branch
    revision: []const u8 = "main",
};

/// Size format options
pub const SizeFormat = enum {
    human,
    bytes,
    kb,
    mb,
    gb,

    pub fn fromString(s: []const u8) ?SizeFormat {
        if (std.mem.eql(u8, s, "human")) return .human;
        if (std.mem.eql(u8, s, "bytes")) return .bytes;
        if (std.mem.eql(u8, s, "kb")) return .kb;
        if (std.mem.eql(u8, s, "mb")) return .mb;
        if (std.mem.eql(u8, s, "gb")) return .gb;
        return null;
    }
};

/// Parse list command options
pub fn parseOptions(args: []const []const u8) ListOptions {
    var opts = ListOptions{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--gguf-only")) {
            opts.gguf_only = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json_output = true;
        } else if (std.mem.eql(u8, arg, "--revision") or std.mem.eql(u8, arg, "-r")) {
            if (i + 1 < args.len) {
                opts.revision = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--size-format")) {
            if (i + 1 < args.len) {
                if (SizeFormat.fromString(args[i + 1])) |fmt| {
                    opts.size_format = fmt;
                }
                i += 1;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument - model ID
            if (opts.model_id == null) {
                opts.model_id = arg;
            }
        }

        i += 1;
    }

    return opts;
}

/// Run the list command
pub fn run(
    allocator: Allocator,
    args: []const []const u8,
    config: *Config,
    global_opts: GlobalOptions,
) CommandResult {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const use_color = !global_opts.no_color and terminal.isTty();
    const use_unicode = detectUnicode();

    // Parse command-specific options
    var opts = parseOptions(args);
    opts.json_output = opts.json_output or global_opts.json;

    // Show help if requested
    if (opts.help) {
        printHelp(stdout, use_color);
        return CommandResult{ .success = true };
    }

    // Validate model ID
    if (opts.model_id == null) {
        formatting.formatError(stderr, "Missing required argument: MODEL_ID", use_color, use_unicode) catch {};
        stderr.print("\nUsage: hf-hub list <MODEL_ID> [OPTIONS]\n", .{}) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    }

    const model_id = opts.model_id.?;

    // Initialize HubClient
    var hub = HubClient.init(allocator, config.*) catch {
        formatting.formatError(stderr, "Failed to initialize Hub client", use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };
    defer hub.deinit();

    // Get file list
    const files = if (opts.gguf_only)
        hub.listGgufFiles(model_id) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Failed to list files: {s}", .{@errorName(err)}) catch "Failed to list files";
            formatting.formatError(stderr, msg, use_color, use_unicode) catch {};
            return CommandResult{ .success = false, .exit_code = 1 };
        }
    else
        hub.listFiles(model_id) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Failed to list files: {s}", .{@errorName(err)}) catch "Failed to list files";
            formatting.formatError(stderr, msg, use_color, use_unicode) catch {};
            return CommandResult{ .success = false, .exit_code = 1 };
        };
    defer hub.freeFileInfoSlice(files);

    // Output results
    if (opts.json_output) {
        outputJson(stdout, files, allocator) catch {
            formatting.formatError(stderr, "Failed to output JSON", use_color, use_unicode) catch {};
            return CommandResult{ .success = false, .exit_code = 1 };
        };
    } else {
        outputTable(stdout, files, model_id, opts, use_color, allocator) catch {
            formatting.formatError(stderr, "Failed to output table", use_color, use_unicode) catch {};
            return CommandResult{ .success = false, .exit_code = 1 };
        };
    }

    return CommandResult{ .success = true };
}

/// Output files as JSON
fn outputJson(writer: anytype, files: []const FileInfo, allocator: Allocator) !void {
    _ = allocator;

    try writer.writeAll("[\n");
    for (files, 0..) |file, i| {
        try writer.writeAll("  {\n");
        try writer.print("    \"filename\": \"{s}\",\n", .{file.filename});
        try writer.print("    \"path\": \"{s}\",\n", .{file.path});
        if (file.size) |size| {
            try writer.print("    \"size\": {d},\n", .{size});
        } else {
            try writer.writeAll("    \"size\": null,\n");
        }
        try writer.print("    \"is_gguf\": {s}", .{if (file.is_gguf) "true" else "false"});
        if (file.blob_id) |bid| {
            try writer.writeAll(",\n");
            try writer.print("    \"blob_id\": \"{s}\"\n", .{bid});
        } else {
            try writer.writeAll("\n");
        }
        if (i < files.len - 1) {
            try writer.writeAll("  },\n");
        } else {
            try writer.writeAll("  }\n");
        }
    }
    try writer.writeAll("]\n");
}

/// Output files as a formatted table
fn outputTable(
    writer: anytype,
    files: []const FileInfo,
    model_id: []const u8,
    opts: ListOptions,
    use_color: bool,
    allocator: Allocator,
) !void {
    // Print header
    if (use_color) {
        try writer.print("\n{s}Files in {s}{s}\n", .{
            terminal.ESC ++ "1;36m",
            model_id,
            terminal.RESET,
        });
    } else {
        try writer.print("\nFiles in {s}\n", .{model_id});
    }

    if (files.len == 0) {
        if (opts.gguf_only) {
            try writer.writeAll("No GGUF files found.\n\n");
        } else {
            try writer.writeAll("No files found.\n\n");
        }
        return;
    }

    // Calculate total size
    var total_size: u64 = 0;
    var gguf_count: usize = 0;
    for (files) |file| {
        if (file.size) |size| {
            total_size += size;
        }
        if (file.is_gguf) {
            gguf_count += 1;
        }
    }

    // Print summary
    var size_buf: [32]u8 = undefined;
    const total_str = formatting.formatSize(&size_buf, total_size, false);
    if (use_color) {
        try writer.print("{s}{d} files ({d} GGUF) • {s}{s}\n\n", .{
            terminal.ESC ++ "90m",
            files.len,
            gguf_count,
            total_str,
            terminal.RESET,
        });
    } else {
        try writer.print("{d} files ({d} GGUF) • {s}\n\n", .{ files.len, gguf_count, total_str });
    }

    // Create table
    const columns = [_]formatting.Column{
        .{ .header = "Filename", .min_width = 30, .max_width = 50, .color = if (use_color) .bright_magenta else null },
        .{ .header = "Size", .min_width = 12, .alignment = .right, .color = if (use_color) .green else null },
        .{ .header = "Type", .min_width = 8 },
    };

    var table = try formatting.Table.init(allocator, &columns, .{
        .use_color = use_color,
        .show_header = true,
        .border = .simple,
    });
    defer table.deinit();

    // Add rows
    for (files) |file| {
        var file_size_buf: [32]u8 = undefined;
        const size_str = if (file.size) |size|
            formatSizeWithOption(&file_size_buf, size, opts.size_format)
        else
            "-";

        const type_str = if (file.is_gguf) "GGUF" else "";

        try table.addRow(&[_][]const u8{
            file.path,
            size_str,
            type_str,
        });
    }

    // Render table
    try table.render(writer);
    try writer.writeAll("\n");
}

/// Format size according to the specified format option
fn formatSizeWithOption(buf: []u8, bytes: u64, format: SizeFormat) []const u8 {
    return switch (format) {
        .bytes => std.fmt.bufPrint(buf, "{d}", .{bytes}) catch "?",
        .kb => std.fmt.bufPrint(buf, "{d:.2} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0}) catch "?",
        .mb => std.fmt.bufPrint(buf, "{d:.2} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "?",
        .gb => std.fmt.bufPrint(buf, "{d:.2} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)}) catch "?",
        .human => blk: {
            const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
            var value: f64 = @floatFromInt(bytes);
            var unit_idx: usize = 0;

            while (value >= 1024 and unit_idx < units.len - 1) {
                value /= 1024;
                unit_idx += 1;
            }

            if (unit_idx == 0) {
                break :blk std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch "?";
            } else {
                break :blk std.fmt.bufPrint(buf, "{d:.2} {s}", .{ value, units[unit_idx] }) catch "?";
            }
        },
    };
}

/// Detect unicode support
fn detectUnicode() bool {
    if (@import("builtin").os.tag == .windows) {
        return std.process.hasEnvVarConstant("WT_SESSION");
    } else {
        const lang = std.posix.getenv("LANG") orelse "";
        return std.mem.indexOf(u8, lang, "UTF-8") != null;
    }
}

/// Print help for the list command
pub fn printHelp(writer: anytype, use_color: bool) void {
    if (use_color) {
        writer.print("\n{s}hf-hub list{s} - List files in a model repository\n\n", .{
            terminal.ESC ++ "1;36m",
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("\nhf-hub list - List files in a model repository\n\n", .{}) catch {};
    }

    writer.print("USAGE:\n", .{}) catch {};
    writer.print("    hf-hub list [OPTIONS] <MODEL_ID>\n\n", .{}) catch {};

    writer.print("ARGUMENTS:\n", .{}) catch {};
    writer.print("    <MODEL_ID>    Model ID (e.g., meta-llama/Llama-2-7b-hf)\n\n", .{}) catch {};

    writer.print("OPTIONS:\n", .{}) catch {};
    const options = [_]struct { opt: []const u8, desc: []const u8 }{
        .{ .opt = "--gguf-only", .desc = "Only show GGUF files" },
        .{ .opt = "--json", .desc = "Output in JSON format" },
        .{ .opt = "--revision, -r <REV>", .desc = "Repository revision (default: main)" },
        .{ .opt = "--size-format <FMT>", .desc = "Size format: human, bytes, kb, mb, gb" },
        .{ .opt = "-h, --help", .desc = "Show this help message" },
    };

    for (options) |opt| {
        writer.print("    {s: <25} {s}\n", .{ opt.opt, opt.desc }) catch {};
    }

    writer.print("\nEXAMPLES:\n", .{}) catch {};
    if (use_color) {
        writer.print("    {s}${s} hf-hub list meta-llama/Llama-2-7b-hf\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
        writer.print("    {s}${s} hf-hub list TheBloke/Llama-2-7B-GGUF --gguf-only\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
        writer.print("    {s}${s} hf-hub list mistral/Mistral-7B-v0.1 --json\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("    $ hf-hub list meta-llama/Llama-2-7b-hf\n", .{}) catch {};
        writer.print("    $ hf-hub list TheBloke/Llama-2-7B-GGUF --gguf-only\n", .{}) catch {};
        writer.print("    $ hf-hub list mistral/Mistral-7B-v0.1 --json\n", .{}) catch {};
    }
    writer.print("\n", .{}) catch {};
}

// ============================================================================
// Tests
// ============================================================================

test "parseOptions - basic" {
    const args = &[_][]const u8{ "meta-llama/Llama-2-7b", "--gguf-only" };
    const opts = parseOptions(args);

    try std.testing.expect(opts.model_id != null);
    try std.testing.expectEqualStrings("meta-llama/Llama-2-7b", opts.model_id.?);
    try std.testing.expect(opts.gguf_only);
    try std.testing.expect(!opts.json_output);
}

test "parseOptions - json output" {
    const args = &[_][]const u8{ "test/model", "--json" };
    const opts = parseOptions(args);

    try std.testing.expect(opts.json_output);
}

test "parseOptions - size format" {
    const args = &[_][]const u8{ "test/model", "--size-format", "mb" };
    const opts = parseOptions(args);

    try std.testing.expectEqual(SizeFormat.mb, opts.size_format);
}

test "SizeFormat.fromString" {
    try std.testing.expectEqual(SizeFormat.human, SizeFormat.fromString("human").?);
    try std.testing.expectEqual(SizeFormat.bytes, SizeFormat.fromString("bytes").?);
    try std.testing.expectEqual(SizeFormat.gb, SizeFormat.fromString("gb").?);
    try std.testing.expect(SizeFormat.fromString("invalid") == null);
}

test "formatSizeWithOption" {
    var buf: [32]u8 = undefined;

    const bytes_result = formatSizeWithOption(&buf, 1024, .bytes);
    try std.testing.expectEqualStrings("1024", bytes_result);

    const kb_result = formatSizeWithOption(&buf, 2048, .kb);
    try std.testing.expect(std.mem.indexOf(u8, kb_result, "KB") != null);
}
