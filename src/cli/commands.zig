//! CLI command dispatcher for HuggingFace Hub CLI
//!
//! This module handles command parsing and dispatches to individual command handlers.

const std = @import("std");
const Allocator = std.mem.Allocator;

const hf = @import("hf-hub");
const Config = hf.Config;
const terminal = hf.terminal;
const Color = terminal.Color;

const cache = @import("cache.zig");
const download_cmd = @import("download.zig");
const info = @import("info.zig");
const list = @import("list.zig");
const search = @import("search.zig");
const user = @import("user.zig");

// Import command modules
// Import core modules
/// CLI version
pub const VERSION = "0.1.0";

/// CLI application name
pub const APP_NAME = "hf-hub";

/// Global options that apply to all commands
pub const GlobalOptions = struct {
    /// HuggingFace API token
    token: ?[]const u8 = null,
    /// API endpoint URL
    endpoint: ?[]const u8 = null,
    /// Cache directory path
    cache_dir: ?[]const u8 = null,
    /// Request timeout in milliseconds
    timeout_ms: ?u32 = null,
    /// Disable progress bars
    no_progress: bool = false,
    /// Disable colored output
    no_color: bool = false,
    /// Output in JSON format
    json: bool = false,
    /// Show help
    help: bool = false,
    /// Show version
    version: bool = false,
    /// Verbose output
    verbose: bool = false,
};

/// Available commands
pub const Command = enum {
    search,
    download,
    list,
    info,
    cache,
    user,
    help,

    pub fn fromString(str: []const u8) ?Command {
        if (std.mem.eql(u8, str, "search")) return .search;
        if (std.mem.eql(u8, str, "download")) return .download;
        if (std.mem.eql(u8, str, "list")) return .list;
        if (std.mem.eql(u8, str, "info")) return .info;
        if (std.mem.eql(u8, str, "cache")) return .cache;
        if (std.mem.eql(u8, str, "user") or std.mem.eql(u8, str, "whoami")) return .user;
        if (std.mem.eql(u8, str, "help")) return .help;
        return null;
    }

    pub fn toString(self: Command) []const u8 {
        return switch (self) {
            .search => "search",
            .download => "download",
            .list => "list",
            .info => "info",
            .cache => "cache",
            .user => "user",
            .help => "help",
        };
    }

    pub fn description(self: Command) []const u8 {
        return switch (self) {
            .search => "Search for models on HuggingFace Hub",
            .download => "Download files from a model repository",
            .list => "List files in a model repository",
            .info => "Get detailed information about a model",
            .cache => "Manage the local cache",
            .user => "Show current user information",
            .help => "Show help information",
        };
    }
};

/// Command result
pub const CommandResult = struct {
    success: bool,
    message: ?[]const u8 = null,
    exit_code: u8 = 0,
};

/// Parse global options from command line arguments
pub fn parseGlobalOptions(args: []const []const u8) struct { opts: GlobalOptions, remaining: []const []const u8 } {
    var opts = GlobalOptions{};
    var start_idx: usize = 0;

    for (args, 0..) |arg, i| {
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                opts.help = true;
            } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                opts.version = true;
            } else if (std.mem.eql(u8, arg, "--no-progress")) {
                opts.no_progress = true;
            } else if (std.mem.eql(u8, arg, "--no-color")) {
                opts.no_color = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                opts.json = true;
            } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                opts.verbose = true;
            } else if (std.mem.eql(u8, arg, "--token")) {
                if (i + 1 < args.len) {
                    opts.token = args[i + 1];
                    start_idx = @max(start_idx, i + 2);
                }
            } else if (std.mem.eql(u8, arg, "--endpoint")) {
                if (i + 1 < args.len) {
                    opts.endpoint = args[i + 1];
                    start_idx = @max(start_idx, i + 2);
                }
            } else if (std.mem.eql(u8, arg, "--cache-dir")) {
                if (i + 1 < args.len) {
                    opts.cache_dir = args[i + 1];
                    start_idx = @max(start_idx, i + 2);
                }
            } else if (std.mem.eql(u8, arg, "--timeout")) {
                if (i + 1 < args.len) {
                    opts.timeout_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch null;
                    start_idx = @max(start_idx, i + 2);
                }
            } else {
                // Unknown global option, stop processing
                break;
            }
            start_idx = @max(start_idx, i + 1);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Short options
            if (std.mem.eql(u8, arg, "-h")) {
                opts.help = true;
            } else if (std.mem.eql(u8, arg, "-V")) {
                opts.version = true;
            } else if (std.mem.eql(u8, arg, "-v")) {
                opts.verbose = true;
            } else {
                // Unknown or command-specific option
                break;
            }
            start_idx = @max(start_idx, i + 1);
        } else {
            // First non-option argument
            break;
        }
    }

    return .{ .opts = opts, .remaining = args[start_idx..] };
}

/// Build configuration from global options
pub fn buildConfig(allocator: Allocator, opts: GlobalOptions) !Config {
    var config = try Config.fromEnv(allocator);

    // Override with command-line options
    if (opts.token) |token| {
        if (config.allocated_fields.token) {
            if (config.token) |t| allocator.free(t);
        }
        config.token = try allocator.dupe(u8, token);
        config.allocated_fields.token = true;
    }

    if (opts.endpoint) |endpoint| {
        if (config.allocated_fields.endpoint) {
            allocator.free(config.endpoint);
        }
        config.endpoint = try allocator.dupe(u8, endpoint);
        config.allocated_fields.endpoint = true;
    }

    if (opts.cache_dir) |cache_dir| {
        if (config.allocated_fields.cache_dir) {
            if (config.cache_dir) |cd| allocator.free(cd);
        }
        config.cache_dir = try allocator.dupe(u8, cache_dir);
        config.allocated_fields.cache_dir = true;
    }

    if (opts.timeout_ms) |timeout| {
        config.timeout_ms = timeout;
    }

    config.use_progress = !opts.no_progress;
    config.use_color = !opts.no_color;

    return config;
}

/// Run a command
pub fn runCommand(
    allocator: Allocator,
    command: Command,
    args: []const []const u8,
    global_opts: GlobalOptions,
) !CommandResult {
    // Build config
    var config = try buildConfig(allocator, global_opts);
    defer config.deinit();

    // Dispatch to command handler
    return switch (command) {
        .search => search.run(allocator, args, &config, global_opts),
        .download => download_cmd.run(allocator, args, &config, global_opts),
        .list => list.run(allocator, args, &config, global_opts),
        .info => info.run(allocator, args, &config, global_opts),
        .cache => cache.run(allocator, args, &config, global_opts),
        .user => user.run(allocator, args, &config, global_opts),
        .help => {
            printHelp(null);
            return CommandResult{ .success = true };
        },
    };
}

/// Print help message
pub fn printHelp(command: ?Command) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const use_color = terminal.isTty() and !terminal.noColorEnv();

    if (command) |cmd| {
        // Command-specific help
        switch (cmd) {
            .search => search.printHelp(stdout, use_color),
            .download => download_cmd.printHelp(stdout, use_color),
            .list => list.printHelp(stdout, use_color),
            .info => info.printHelp(stdout, use_color),
            .cache => cache.printHelp(stdout, use_color),
            .user => user.printHelp(stdout, use_color),
            .help => printGeneralHelp(stdout, use_color),
        }
    } else {
        printGeneralHelp(stdout, use_color);
    }
}

fn printGeneralHelp(writer: anytype, use_color: bool) void {
    if (use_color) {
        writer.print("\n{s}HuggingFace Hub CLI{s} - Download and manage GGUF models\n\n", .{
            terminal.ESC ++ "1;36m", // Bold cyan
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("\nHuggingFace Hub CLI - Download and manage GGUF models\n\n", .{}) catch {};
    }

    writer.print("USAGE:\n", .{}) catch {};
    writer.print("    {s} [OPTIONS] <COMMAND> [ARGS]\n\n", .{APP_NAME}) catch {};

    writer.print("COMMANDS:\n", .{}) catch {};
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        const cmd: Command = @enumFromInt(field.value);
        if (use_color) {
            writer.print("    {s}{s: <12}{s} {s}\n", .{
                terminal.ESC ++ "33m", // Yellow
                field.name,
                terminal.RESET,
                cmd.description(),
            }) catch {};
        } else {
            writer.print("    {s: <12} {s}\n", .{ field.name, cmd.description() }) catch {};
        }
    }

    writer.print("\nGLOBAL OPTIONS:\n", .{}) catch {};
    const options = [_]struct { short: []const u8, long: []const u8, desc: []const u8 }{
        .{ .short = "", .long = "--token <TOKEN>", .desc = "HuggingFace API token (or HF_TOKEN env)" },
        .{ .short = "", .long = "--endpoint <URL>", .desc = "API endpoint URL" },
        .{ .short = "", .long = "--cache-dir <PATH>", .desc = "Cache directory path" },
        .{ .short = "", .long = "--timeout <MS>", .desc = "Request timeout in milliseconds" },
        .{ .short = "", .long = "--no-progress", .desc = "Disable progress bars" },
        .{ .short = "", .long = "--no-color", .desc = "Disable colored output" },
        .{ .short = "", .long = "--json", .desc = "Output in JSON format" },
        .{ .short = "-v", .long = "--verbose", .desc = "Verbose output" },
        .{ .short = "-h", .long = "--help", .desc = "Show help" },
        .{ .short = "-V", .long = "--version", .desc = "Show version" },
    };

    for (options) |opt| {
        if (opt.short.len > 0) {
            writer.print("    {s}, {s: <20} {s}\n", .{ opt.short, opt.long, opt.desc }) catch {};
        } else {
            writer.print("        {s: <20} {s}\n", .{ opt.long, opt.desc }) catch {};
        }
    }

    writer.print("\nEXAMPLES:\n", .{}) catch {};
    if (use_color) {
        writer.print("    {s}${s} {s} search \"llama 7b\" --gguf-only\n", .{
            terminal.ESC ++ "90m", // Dim
            terminal.RESET,
            APP_NAME,
        }) catch {};
        writer.print("    {s}${s} {s} download TheBloke/Llama-2-7B-GGUF\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
            APP_NAME,
        }) catch {};
        writer.print("    {s}${s} {s} list meta-llama/Llama-2-7b-hf --gguf-only\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
            APP_NAME,
        }) catch {};
    } else {
        writer.print("    $ {s} search \"llama 7b\" --gguf-only\n", .{APP_NAME}) catch {};
        writer.print("    $ {s} download TheBloke/Llama-2-7B-GGUF\n", .{APP_NAME}) catch {};
        writer.print("    $ {s} list meta-llama/Llama-2-7b-hf --gguf-only\n", .{APP_NAME}) catch {};
    }

    writer.print("\nFor more information about a command, run:\n", .{}) catch {};
    writer.print("    {s} <COMMAND> --help\n\n", .{APP_NAME}) catch {};
}

/// Print version
pub fn printVersion() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const use_color = terminal.isTty() and !terminal.noColorEnv();

    if (use_color) {
        stdout.print("{s}{s}{s} version {s}{s}{s}\n", .{
            terminal.ESC ++ "1;36m", // Bold cyan
            APP_NAME,
            terminal.RESET,
            terminal.ESC ++ "33m", // Yellow
            VERSION,
            terminal.RESET,
        }) catch {};
    } else {
        stdout.print("{s} version {s}\n", .{ APP_NAME, VERSION }) catch {};
    }
}

/// Print banner (for interactive mode)
pub fn printBanner() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const use_color = terminal.isTty() and !terminal.noColorEnv();

    if (use_color) {
        stdout.print("\n", .{}) catch {};
        stdout.print("{s}  _   _ _____   _   _ _   _ ____  {s}\n", .{ terminal.ESC ++ "36m", terminal.RESET }) catch {};
        stdout.print("{s} | | | |  ___| | | | | | | | __ ) {s}\n", .{ terminal.ESC ++ "36m", terminal.RESET }) catch {};
        stdout.print("{s} | |_| | |_    | |_| | | | |  _ \\ {s}\n", .{ terminal.ESC ++ "36m", terminal.RESET }) catch {};
        stdout.print("{s} |  _  |  _|   |  _  | |_| | |_) |{s}\n", .{ terminal.ESC ++ "36m", terminal.RESET }) catch {};
        stdout.print("{s} |_| |_|_|     |_| |_|\\___/|____/ {s}\n", .{ terminal.ESC ++ "36m", terminal.RESET }) catch {};
        stdout.print("\n", .{}) catch {};
        stdout.print("{s}HuggingFace Hub CLI v{s}{s}\n\n", .{ terminal.ESC ++ "90m", VERSION, terminal.RESET }) catch {};
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Command.fromString" {
    try std.testing.expectEqual(Command.search, Command.fromString("search").?);
    try std.testing.expectEqual(Command.download, Command.fromString("download").?);
    try std.testing.expectEqual(Command.user, Command.fromString("whoami").?);
    try std.testing.expect(Command.fromString("invalid") == null);
}

test "parseGlobalOptions" {
    const args = &[_][]const u8{ "--json", "--no-color", "search", "query" };
    const result = parseGlobalOptions(args);

    try std.testing.expect(result.opts.json);
    try std.testing.expect(result.opts.no_color);
    try std.testing.expectEqual(@as(usize, 2), result.remaining.len);
}

test "GlobalOptions defaults" {
    const opts = GlobalOptions{};
    try std.testing.expect(opts.token == null);
    try std.testing.expect(!opts.no_progress);
    try std.testing.expect(!opts.no_color);
    try std.testing.expect(!opts.json);
}
