//! CLI search command handler
//!
//! Search for models on HuggingFace Hub with support for filters and sorting.

const std = @import("std");
const Allocator = std.mem.Allocator;

const hf = @import("hf-hub");
const Config = hf.Config;
const terminal = hf.terminal;
const types = hf.types;
const SearchQuery = types.SearchQuery;
const SortOrder = types.SortOrder;
const HubClient = hf.HubClient;

const commands = @import("commands.zig");
const GlobalOptions = commands.GlobalOptions;
const CommandResult = commands.CommandResult;
const formatting = @import("formatting.zig");

// Import from the library module
// Local imports
/// Search command options
pub const SearchOptions = struct {
    /// Search query text
    query: []const u8 = "",
    /// Maximum results to return
    limit: u32 = 20,
    /// Pagination offset
    offset: u32 = 0,
    /// Sort order
    sort: SortOrder = .trending,
    /// Only show models with GGUF files
    gguf_only: bool = false,
    /// Filter by organization/owner
    owner: ?[]const u8 = null,
    /// Include full model details
    full: bool = false,
    /// Show help
    help: bool = false,
};

/// Parse search command options
pub fn parseOptions(args: []const []const u8) struct { opts: SearchOptions, query: ?[]const u8 } {
    var opts = SearchOptions{};
    var query: ?[]const u8 = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.limit = std.fmt.parseInt(u32, args[i], 10) catch 20;
            }
        } else if (std.mem.eql(u8, arg, "--offset")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.offset = std.fmt.parseInt(u32, args[i], 10) catch 0;
            }
        } else if (std.mem.eql(u8, arg, "--sort") or std.mem.eql(u8, arg, "-s")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.sort = SortOrder.fromString(args[i]) orelse .trending;
            }
        } else if (std.mem.eql(u8, arg, "--gguf-only") or std.mem.eql(u8, arg, "-g")) {
            opts.gguf_only = true;
        } else if (std.mem.eql(u8, arg, "--owner") or std.mem.eql(u8, arg, "-o")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.owner = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--full") or std.mem.eql(u8, arg, "-f")) {
            opts.full = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument - the search query
            if (query == null) {
                query = arg;
            }
        }
    }

    return .{ .opts = opts, .query = query };
}

/// Run the search command
pub fn run(
    allocator: Allocator,
    args: []const []const u8,
    config: *Config,
    global_opts: GlobalOptions,
) CommandResult {
    const parsed = parseOptions(args);
    const opts = parsed.opts;

    // Check for help
    if (opts.help) {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        printHelp(stdout, !global_opts.no_color);
        return CommandResult{ .success = true };
    }

    // Get search query
    const query_text = parsed.query orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        formatting.formatError(stderr, "Missing search query. Usage: hf-hub search <QUERY>", !global_opts.no_color, true) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };

    // Initialize HubClient
    var hub = HubClient.init(allocator, config.*) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        formatting.formatError(stderr, "Failed to initialize Hub client", !global_opts.no_color, true) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };
    defer hub.deinit();

    // Build search query
    const search_query = SearchQuery{
        .search = query_text,
        .author = opts.owner,
        .filter = if (opts.gguf_only) "gguf" else null,
        .sort = opts.sort,
        .limit = opts.limit,
        .offset = opts.offset,
        .full = opts.full or opts.gguf_only,
    };

    // Perform search
    var result = hub.search(search_query) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Search failed: {s}", .{@errorName(err)}) catch "Search failed";
        formatting.formatError(stderr, msg, !global_opts.no_color, true) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };
    defer hub.freeSearchResult(&result);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const use_color = !global_opts.no_color and terminal.isTty();

    // Output results
    if (global_opts.json) {
        // JSON output
        outputJson(allocator, stdout, result) catch {};
    } else {
        // Table output
        outputTable(allocator, stdout, result, opts, use_color) catch {};
    }

    return CommandResult{ .success = true };
}

/// Output results as JSON
fn outputJson(allocator: Allocator, writer: anytype, result: types.SearchResult) !void {
    _ = allocator;

    try writer.writeAll("[\n");

    for (result.models, 0..) |model, i| {
        if (i > 0) {
            try writer.writeAll(",\n");
        }

        try writer.writeAll("  {\n");
        try writer.print("    \"id\": \"{s}\"", .{model.id});

        if (model.author) |author| {
            try writer.print(",\n    \"author\": \"{s}\"", .{author});
        }

        if (model.downloads) |downloads| {
            try writer.print(",\n    \"downloads\": {d}", .{downloads});
        }

        if (model.likes) |likes| {
            try writer.print(",\n    \"likes\": {d}", .{likes});
        }

        if (model.pipeline_tag) |pipeline| {
            try writer.print(",\n    \"pipeline_tag\": \"{s}\"", .{pipeline});
        }

        // GGUF files
        var gguf_count: usize = 0;
        for (model.siblings) |sib| {
            if (types.FileInfo.checkIsGguf(sib.rfilename)) {
                gguf_count += 1;
            }
        }
        if (gguf_count > 0) {
            try writer.print(",\n    \"gguf_files\": {d}", .{gguf_count});
        }

        try writer.writeAll("\n  }");
    }

    try writer.writeAll("\n]\n");
}

/// Output results as a formatted table
fn outputTable(
    allocator: Allocator,
    writer: anytype,
    result: types.SearchResult,
    opts: SearchOptions,
    use_color: bool,
) !void {
    if (result.models.len == 0) {
        formatting.formatWarning(writer, "No models found matching your query.", use_color, true) catch {};
        return;
    }

    // Print header
    if (use_color) {
        try writer.print("\n{s}Found {d} model(s){s}\n\n", .{
            terminal.ESC ++ "1;36m",
            result.models.len,
            terminal.RESET,
        });
    } else {
        try writer.print("\nFound {d} model(s)\n\n", .{result.models.len});
    }

    // Define columns
    const columns = [_]formatting.Column{
        .{ .header = "MODEL", .min_width = 30, .max_width = 50, .color = .bright_magenta },
        .{ .header = "DOWNLOADS", .min_width = 10, .alignment = .right, .color = .green },
        .{ .header = "LIKES", .min_width = 6, .alignment = .right, .color = .yellow },
        .{ .header = "GGUF", .min_width = 4, .alignment = .right, .color = .cyan },
    };

    var table = formatting.Table.init(allocator, &columns, .{
        .use_color = use_color,
        .show_header = true,
        .border = .simple,
    }) catch return;
    defer table.deinit();

    // Add rows
    for (result.models) |model| {
        var downloads_buf: [16]u8 = undefined;
        var likes_buf: [16]u8 = undefined;
        var gguf_buf: [8]u8 = undefined;

        const downloads_str = if (model.downloads) |d|
            std.fmt.bufPrint(&downloads_buf, "{d}", .{d}) catch "-"
        else
            "-";

        const likes_str = if (model.likes) |l|
            std.fmt.bufPrint(&likes_buf, "{d}", .{l}) catch "-"
        else
            "-";

        // Count GGUF files
        var gguf_count: usize = 0;
        for (model.siblings) |sib| {
            if (types.FileInfo.checkIsGguf(sib.rfilename)) {
                gguf_count += 1;
            }
        }
        const gguf_str = if (gguf_count > 0)
            std.fmt.bufPrint(&gguf_buf, "{d}", .{gguf_count}) catch "-"
        else
            "-";

        table.addRow(&[_][]const u8{
            model.id,
            downloads_str,
            likes_str,
            gguf_str,
        }) catch continue;
    }

    table.render(writer) catch {};

    // Show pagination info
    if (opts.offset > 0 or result.models.len >= opts.limit) {
        try writer.print("\n", .{});
        if (use_color) {
            try writer.print("{s}Showing results {d}-{d}{s}", .{
                terminal.ESC ++ "90m",
                opts.offset + 1,
                opts.offset + result.models.len,
                terminal.RESET,
            });
        } else {
            try writer.print("Showing results {d}-{d}", .{
                opts.offset + 1,
                opts.offset + result.models.len,
            });
        }

        if (result.models.len >= opts.limit) {
            try writer.print(" (use --offset {d} for more)", .{opts.offset + opts.limit});
        }
        try writer.print("\n", .{});
    }

    try writer.print("\n", .{});
}

/// Print help for the search command
pub fn printHelp(writer: anytype, use_color: bool) void {
    if (use_color) {
        writer.print("\n{s}SEARCH{s} - Search for models on HuggingFace Hub\n\n", .{
            terminal.ESC ++ "1;36m",
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("\nSEARCH - Search for models on HuggingFace Hub\n\n", .{}) catch {};
    }

    writer.print("USAGE:\n", .{}) catch {};
    writer.print("    hf-hub search [OPTIONS] <QUERY>\n\n", .{}) catch {};

    writer.print("ARGUMENTS:\n", .{}) catch {};
    writer.print("    <QUERY>    Search query text\n\n", .{}) catch {};

    writer.print("OPTIONS:\n", .{}) catch {};
    const options = [_]struct { short: []const u8, long: []const u8, desc: []const u8 }{
        .{ .short = "-l", .long = "--limit <N>", .desc = "Maximum results to return (default: 20)" },
        .{ .short = "", .long = "--offset <N>", .desc = "Pagination offset (default: 0)" },
        .{ .short = "-s", .long = "--sort <SORT>", .desc = "Sort by: trending, downloads, likes, created, modified" },
        .{ .short = "-g", .long = "--gguf-only", .desc = "Only show models with GGUF files" },
        .{ .short = "-o", .long = "--owner <ORG>", .desc = "Filter by organization/owner" },
        .{ .short = "-f", .long = "--full", .desc = "Include full model details" },
        .{ .short = "-h", .long = "--help", .desc = "Show this help message" },
    };

    for (options) |opt| {
        if (opt.short.len > 0) {
            writer.print("    {s}, {s: <18} {s}\n", .{ opt.short, opt.long, opt.desc }) catch {};
        } else {
            writer.print("        {s: <18} {s}\n", .{ opt.long, opt.desc }) catch {};
        }
    }

    writer.print("\nEXAMPLES:\n", .{}) catch {};
    writer.print("    hf-hub search \"llama 7b\"\n", .{}) catch {};
    writer.print("    hf-hub search \"mistral\" --gguf-only --limit 50\n", .{}) catch {};
    writer.print("    hf-hub search \"qwen\" --sort downloads --owner Qwen\n", .{}) catch {};
    writer.print("\n", .{}) catch {};
}

// ============================================================================
// Tests
// ============================================================================

test "parseOptions - basic query" {
    const args = &[_][]const u8{"llama"};
    const result = parseOptions(args);

    try std.testing.expectEqualStrings("llama", result.query.?);
    try std.testing.expect(!result.opts.gguf_only);
}

test "parseOptions - with flags" {
    const args = &[_][]const u8{ "--gguf-only", "--limit", "50", "mistral" };
    const result = parseOptions(args);

    try std.testing.expectEqualStrings("mistral", result.query.?);
    try std.testing.expect(result.opts.gguf_only);
    try std.testing.expectEqual(@as(u32, 50), result.opts.limit);
}

test "parseOptions - help flag" {
    const args = &[_][]const u8{"--help"};
    const result = parseOptions(args);

    try std.testing.expect(result.opts.help);
    try std.testing.expect(result.query == null);
}
