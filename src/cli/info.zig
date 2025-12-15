//! CLI info command - Display detailed information about a model
//!
//! Usage: hf-hub info [OPTIONS] <MODEL_ID>

const std = @import("std");
const Allocator = std.mem.Allocator;

const hf = @import("hf-hub");
const api = hf.api;
const HttpClient = hf.HttpClient;
const Config = hf.Config;
const terminal = hf.terminal;
const types = hf.types;
const Model = types.Model;
const FileInfo = types.FileInfo;

const commands = @import("commands.zig");
const GlobalOptions = commands.GlobalOptions;
const CommandResult = commands.CommandResult;
const formatting = @import("formatting.zig");

/// Info command options
pub const InfoOptions = struct {
    /// Model ID to get info for
    model_id: ?[]const u8 = null,
    /// Show help
    help: bool = false,
    /// Include file list
    include_files: bool = false,
    /// Only show GGUF files
    gguf_only: bool = false,
};

/// Parse info command options
pub fn parseOptions(args: []const []const u8) InfoOptions {
    var opts = InfoOptions{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--files") or std.mem.eql(u8, arg, "-f")) {
            opts.include_files = true;
        } else if (std.mem.eql(u8, arg, "--gguf-only")) {
            opts.gguf_only = true;
            opts.include_files = true;
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

/// Run the info command
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

    // Parse options
    const opts = parseOptions(args);

    // Show help if requested
    if (opts.help) {
        printHelp(stdout, use_color);
        return CommandResult{ .success = true };
    }

    // Validate model ID
    if (opts.model_id == null) {
        formatting.formatError(stderr, "Missing required argument: MODEL_ID", use_color, use_unicode) catch {};
        stderr.print("\nUsage: hf-hub info <MODEL_ID> [OPTIONS]\n", .{}) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    }

    const model_id = opts.model_id.?;

    // Initialize HTTP client
    var http_client = HttpClient.init(allocator, config.*) catch {
        formatting.formatError(stderr, "Failed to initialize HTTP client", use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };
    defer http_client.deinit();

    // Get model info
    var models_api = api.ModelsApi.init(allocator, &http_client);

    var model = models_api.getModel(model_id) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to get model info: {s}", .{@errorName(err)}) catch "Failed to get model info";
        formatting.formatError(stderr, msg, use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };
    defer model.deinit(allocator);

    // Output results
    if (global_opts.json) {
        outputJson(stdout, model) catch {};
    } else {
        outputFormatted(stdout, model, opts, use_color, allocator) catch {};
    }

    return CommandResult{ .success = true };
}

/// Output model info as JSON
fn outputJson(writer: anytype, model: Model) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"id\": \"{s}\"", .{model.id});

    if (model.author) |author| {
        try writer.print(",\n  \"author\": \"{s}\"", .{author});
    }

    if (model.sha) |sha| {
        try writer.print(",\n  \"sha\": \"{s}\"", .{sha});
    }

    try writer.print(",\n  \"private\": {s}", .{if (model.private) "true" else "false"});

    if (model.gated) |gated| {
        try writer.print(",\n  \"gated\": {s}", .{if (gated) "true" else "false"});
    }

    if (model.downloads) |downloads| {
        try writer.print(",\n  \"downloads\": {d}", .{downloads});
    }

    if (model.likes) |likes| {
        try writer.print(",\n  \"likes\": {d}", .{likes});
    }

    if (model.library_name) |lib| {
        try writer.print(",\n  \"library_name\": \"{s}\"", .{lib});
    }

    if (model.pipeline_tag) |pipeline| {
        try writer.print(",\n  \"pipeline_tag\": \"{s}\"", .{pipeline});
    }

    if (model.last_modified) |lm| {
        try writer.print(",\n  \"last_modified\": \"{s}\"", .{lm});
    }

    // Tags
    if (model.tags.len > 0) {
        try writer.writeAll(",\n  \"tags\": [");
        for (model.tags, 0..) |tag, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{tag});
        }
        try writer.writeAll("]");
    }

    // Files count
    try writer.print(",\n  \"files_count\": {d}", .{model.siblings.len});

    // GGUF files count
    var gguf_count: usize = 0;
    for (model.siblings) |sib| {
        if (FileInfo.checkIsGguf(sib.rfilename)) {
            gguf_count += 1;
        }
    }
    try writer.print(",\n  \"gguf_files_count\": {d}", .{gguf_count});

    try writer.writeAll("\n}\n");
}

/// Output model info with formatting
fn outputFormatted(
    writer: anytype,
    model: Model,
    opts: InfoOptions,
    use_color: bool,
    allocator: Allocator,
) !void {
    // Print header
    if (use_color) {
        try writer.print("\n{s}╔══ Model Information ══╗{s}\n\n", .{
            terminal.ESC ++ "1;36m",
            terminal.RESET,
        });
    } else {
        try writer.print("\n=== Model Information ===\n\n", .{});
    }

    // Model ID
    try printField(writer, "Model ID", model.id, use_color, .magenta);

    // Author
    if (model.author) |author| {
        try printField(writer, "Author", author, use_color, .cyan);
    } else if (model.getOwner()) |owner| {
        try printField(writer, "Author", owner, use_color, .cyan);
    }

    // Pipeline tag
    if (model.pipeline_tag) |pipeline| {
        try printField(writer, "Pipeline", pipeline, use_color, .blue);
    }

    // Library
    if (model.library_name) |lib| {
        try printField(writer, "Library", lib, use_color, .yellow);
    }

    // Last modified
    if (model.last_modified) |lm| {
        try printField(writer, "Last Modified", lm, use_color, null);
    }

    try writer.writeAll("\n");

    // Stats section
    if (use_color) {
        try writer.print("{s}── Statistics ──{s}\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        });
    } else {
        try writer.print("-- Statistics --\n", .{});
    }

    // Downloads
    if (model.downloads) |downloads| {
        var buf: [32]u8 = undefined;
        const downloads_str = std.fmt.bufPrint(&buf, "{d}", .{downloads}) catch "?";
        try printField(writer, "Downloads", downloads_str, use_color, .green);
    }

    // Likes
    if (model.likes) |likes| {
        var buf: [32]u8 = undefined;
        const likes_str = std.fmt.bufPrint(&buf, "{d}", .{likes}) catch "?";
        try printField(writer, "Likes", likes_str, use_color, .yellow);
    }

    // File counts
    var gguf_count: usize = 0;
    var total_size: u64 = 0;
    for (model.siblings) |sib| {
        if (FileInfo.checkIsGguf(sib.rfilename)) {
            gguf_count += 1;
        }
        if (sib.size) |size| {
            total_size += size;
        }
    }

    var files_buf: [64]u8 = undefined;
    const files_str = std.fmt.bufPrint(&files_buf, "{d} ({d} GGUF)", .{ model.siblings.len, gguf_count }) catch "?";
    try printField(writer, "Files", files_str, use_color, null);

    if (total_size > 0) {
        var size_buf: [32]u8 = undefined;
        const size_str = types.formatBytes(total_size, &size_buf);
        try printField(writer, "Total Size", size_str, use_color, .green);
    }

    // Flags
    if (model.private or (model.gated != null and model.gated.?)) {
        try writer.writeAll("\n");
        if (model.private) {
            if (use_color) {
                try writer.print("  {s}🔒 Private{s}\n", .{ terminal.ESC ++ "33m", terminal.RESET });
            } else {
                try writer.print("  [Private]\n", .{});
            }
        }
        if (model.gated != null and model.gated.?) {
            if (use_color) {
                try writer.print("  {s}🔐 Gated (requires access){s}\n", .{ terminal.ESC ++ "33m", terminal.RESET });
            } else {
                try writer.print("  [Gated]\n", .{});
            }
        }
    }

    // Tags
    if (model.tags.len > 0) {
        try writer.writeAll("\n");
        if (use_color) {
            try writer.print("{s}── Tags ──{s}\n", .{
                terminal.ESC ++ "90m",
                terminal.RESET,
            });
        } else {
            try writer.print("-- Tags --\n", .{});
        }

        try writer.writeAll("  ");
        for (model.tags, 0..) |tag, i| {
            if (i > 0 and i % 5 == 0) {
                try writer.writeAll("\n  ");
            }
            if (use_color) {
                try writer.print("{s}{s}{s} ", .{
                    terminal.ESC ++ "34m",
                    tag,
                    terminal.RESET,
                });
            } else {
                try writer.print("[{s}] ", .{tag});
            }
        }
        try writer.writeAll("\n");
    }

    // Files section
    if (opts.include_files and model.siblings.len > 0) {
        try writer.writeAll("\n");
        if (use_color) {
            try writer.print("{s}── Files ──{s}\n", .{
                terminal.ESC ++ "90m",
                terminal.RESET,
            });
        } else {
            try writer.print("-- Files --\n", .{});
        }

        // Create table for files
        const columns = [_]formatting.Column{
            .{ .header = "Filename", .min_width = 40, .max_width = 60, .color = .bright_white },
            .{ .header = "Size", .min_width = 12, .alignment = .right, .color = .green },
        };

        var table = try formatting.Table.init(allocator, &columns, .{
            .use_color = use_color,
            .show_header = true,
        });
        defer table.deinit();

        for (model.siblings) |sib| {
            if (opts.gguf_only and !FileInfo.checkIsGguf(sib.rfilename)) {
                continue;
            }

            var size_buf: [32]u8 = undefined;
            const size_str = if (sib.size) |s| types.formatBytes(s, &size_buf) else "-";

            try table.addRow(&[_][]const u8{
                sib.rfilename,
                size_str,
            });
        }

        try table.render(writer);
    }

    try writer.writeAll("\n");
}

/// Print a field with label and value
fn printField(
    writer: anytype,
    label: []const u8,
    value: []const u8,
    use_color: bool,
    value_color: ?terminal.Color,
) !void {
    if (use_color) {
        try writer.print("  {s}{s: <14}{s} ", .{
            terminal.ESC ++ "1m",
            label,
            terminal.RESET,
        });

        if (value_color) |vc| {
            const color_code = switch (vc) {
                .magenta => terminal.ESC ++ "35m",
                .cyan => terminal.ESC ++ "36m",
                .blue => terminal.ESC ++ "34m",
                .yellow => terminal.ESC ++ "33m",
                .green => terminal.ESC ++ "32m",
                else => terminal.ESC ++ "37m",
            };
            try writer.print("{s}{s}{s}\n", .{ color_code, value, terminal.RESET });
        } else {
            try writer.print("{s}\n", .{value});
        }
    } else {
        try writer.print("  {s: <14} {s}\n", .{ label, value });
    }
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

/// Print help for the info command
pub fn printHelp(writer: anytype, use_color: bool) void {
    if (use_color) {
        writer.print("\n{s}hf-hub info{s} - Display detailed information about a model\n\n", .{
            terminal.ESC ++ "1;36m",
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("\nhf-hub info - Display detailed information about a model\n\n", .{}) catch {};
    }

    writer.print("USAGE:\n", .{}) catch {};
    writer.print("    hf-hub info [OPTIONS] <MODEL_ID>\n\n", .{}) catch {};

    writer.print("ARGUMENTS:\n", .{}) catch {};
    writer.print("    <MODEL_ID>    Model ID (e.g., meta-llama/Llama-2-7b-hf)\n\n", .{}) catch {};

    writer.print("OPTIONS:\n", .{}) catch {};
    const options = [_]struct { opt: []const u8, desc: []const u8 }{
        .{ .opt = "-f, --files", .desc = "Include file listing" },
        .{ .opt = "    --gguf-only", .desc = "Only show GGUF files (implies --files)" },
        .{ .opt = "    --json", .desc = "Output in JSON format" },
        .{ .opt = "-h, --help", .desc = "Show this help message" },
    };

    for (options) |opt| {
        writer.print("    {s: <20} {s}\n", .{ opt.opt, opt.desc }) catch {};
    }

    writer.print("\nEXAMPLES:\n", .{}) catch {};
    writer.print("    hf-hub info meta-llama/Llama-2-7b-hf\n", .{}) catch {};
    writer.print("    hf-hub info TheBloke/Llama-2-7B-GGUF --files\n", .{}) catch {};
    writer.print("    hf-hub info mistral/Mistral-7B-v0.1 --json\n", .{}) catch {};
    writer.print("\n", .{}) catch {};
}

// ============================================================================
// Tests
// ============================================================================

test "parseOptions - basic" {
    const args = &[_][]const u8{"meta-llama/Llama-2-7b"};
    const opts = parseOptions(args);

    try std.testing.expect(opts.model_id != null);
    try std.testing.expectEqualStrings("meta-llama/Llama-2-7b", opts.model_id.?);
    try std.testing.expect(!opts.include_files);
}

test "parseOptions - with files flag" {
    const args = &[_][]const u8{ "test/model", "--files" };
    const opts = parseOptions(args);

    try std.testing.expect(opts.include_files);
}

test "parseOptions - gguf only implies files" {
    const args = &[_][]const u8{ "test/model", "--gguf-only" };
    const opts = parseOptions(args);

    try std.testing.expect(opts.gguf_only);
    try std.testing.expect(opts.include_files);
}

test "parseOptions - help flag" {
    const args = &[_][]const u8{"--help"};
    const opts = parseOptions(args);

    try std.testing.expect(opts.help);
}
