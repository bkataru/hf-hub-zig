//! CLI cache command for cache management
//!
//! Manages the local HuggingFace Hub cache directory.
//!
//! Subcommands:
//!   info   - Show cache statistics
//!   clear  - Clear the cache
//!   clean  - Remove partial/corrupted downloads
//!   dir    - Print cache directory path

const std = @import("std");
const Allocator = std.mem.Allocator;

const hf = @import("hf-hub");
const Cache = hf.Cache;
const CacheStats = hf.CacheStats;
const Config = hf.Config;
const terminal = hf.terminal;
const types = hf.types;

const commands = @import("commands.zig");
const GlobalOptions = commands.GlobalOptions;
const CommandResult = commands.CommandResult;
const formatting = @import("formatting.zig");

/// Cache subcommands
pub const CacheSubcommand = enum {
    info,
    clear,
    clean,
    dir,
    help,

    pub fn fromString(s: []const u8) ?CacheSubcommand {
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "clear")) return .clear;
        if (std.mem.eql(u8, s, "clean")) return .clean;
        if (std.mem.eql(u8, s, "dir")) return .dir;
        if (std.mem.eql(u8, s, "help")) return .help;
        return null;
    }
};

/// Cache command options
pub const CacheOptions = struct {
    /// Subcommand to run
    subcommand: ?CacheSubcommand = null,
    /// Pattern for clear command
    pattern: ?[]const u8 = null,
    /// Force operation without confirmation
    force: bool = false,
    /// Show help
    help: bool = false,
};

/// Parse cache command options
pub fn parseOptions(args: []const []const u8) CacheOptions {
    var opts = CacheOptions{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "--pattern") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.pattern = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Subcommand
            if (opts.subcommand == null) {
                opts.subcommand = CacheSubcommand.fromString(arg);
            }
        }

        i += 1;
    }

    return opts;
}

/// Run the cache command
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

    // Show help if requested or no subcommand
    if (opts.help or opts.subcommand == null) {
        printHelp(stdout, use_color);
        return CommandResult{ .success = true };
    }

    // Get cache directory
    const cache_dir = config.cache_dir orelse {
        formatting.formatError(stderr, "Cache directory not configured", use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };

    // Execute subcommand
    return switch (opts.subcommand.?) {
        .info => runInfo(allocator, cache_dir, global_opts, use_color, use_unicode),
        .clear => runClear(allocator, cache_dir, opts, global_opts, use_color, use_unicode),
        .clean => runClean(allocator, cache_dir, global_opts, use_color, use_unicode),
        .dir => runDir(cache_dir, global_opts),
        .help => blk: {
            printHelp(stdout, use_color);
            break :blk CommandResult{ .success = true };
        },
    };
}

/// Run the 'info' subcommand - show cache statistics
fn runInfo(
    allocator: Allocator,
    cache_dir: []const u8,
    global_opts: GlobalOptions,
    use_color: bool,
    use_unicode: bool,
) CommandResult {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var file_cache = Cache.init(allocator, cache_dir) catch {
        formatting.formatError(stderr, "Failed to access cache directory", use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };
    defer file_cache.deinit();

    const stats = file_cache.stats() catch {
        formatting.formatError(stderr, "Failed to read cache statistics", use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };

    if (global_opts.json) {
        // JSON output
        stdout.print("{{\n", .{}) catch {};
        stdout.print("  \"cache_dir\": \"{s}\",\n", .{cache_dir}) catch {};
        stdout.print("  \"total_files\": {d},\n", .{stats.total_files}) catch {};
        stdout.print("  \"total_size\": {d},\n", .{stats.total_size}) catch {};
        stdout.print("  \"num_repos\": {d},\n", .{stats.num_repos}) catch {};
        stdout.print("  \"gguf_files\": {d},\n", .{stats.num_gguf_files}) catch {};
        stdout.print("  \"gguf_size\": {d}\n", .{stats.gguf_size}) catch {};
        stdout.print("}}\n", .{}) catch {};
    } else {
        // Human-readable output
        if (use_color) {
            stdout.print("\n{s}Cache Statistics{s}\n\n", .{
                terminal.ESC ++ "1;36m",
                terminal.RESET,
            }) catch {};
        } else {
            stdout.print("\nCache Statistics\n\n", .{}) catch {};
        }

        var size_buf: [32]u8 = undefined;
        var gguf_size_buf: [32]u8 = undefined;

        const total_size_str = types.formatBytes(stats.total_size, &size_buf);
        const gguf_size_str = types.formatBytes(stats.gguf_size, &gguf_size_buf);

        printKeyValue(stdout, "Cache directory", cache_dir, use_color);
        printKeyValueNumber(stdout, "Repositories", stats.num_repos, use_color);
        printKeyValueNumber(stdout, "Total files", stats.total_files, use_color);
        printKeyValue(stdout, "Total size", total_size_str, use_color);
        printKeyValueNumber(stdout, "GGUF files", stats.num_gguf_files, use_color);
        printKeyValue(stdout, "GGUF size", gguf_size_str, use_color);

        stdout.print("\n", .{}) catch {};
    }

    return CommandResult{ .success = true };
}

/// Run the 'clear' subcommand - clear the cache
fn runClear(
    allocator: Allocator,
    cache_dir: []const u8,
    opts: CacheOptions,
    global_opts: GlobalOptions,
    use_color: bool,
    use_unicode: bool,
) CommandResult {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Confirmation prompt (unless --force)
    if (!opts.force and !global_opts.json) {
        if (use_color) {
            stdout.print("{s}⚠{s}  This will delete all cached files", .{
                terminal.ESC ++ "33m",
                terminal.RESET,
            }) catch {};
        } else {
            stdout.print("Warning: This will delete all cached files", .{}) catch {};
        }

        if (opts.pattern) |pattern| {
            stdout.print(" matching '{s}'", .{pattern}) catch {};
        }
        stdout.print(".\n", .{}) catch {};
        stdout.print("Use --force to skip this confirmation.\n\n", .{}) catch {};

        // For now, just return without clearing
        // In a full implementation, we'd prompt for input
        return CommandResult{ .success = true };
    }

    var file_cache = Cache.init(allocator, cache_dir) catch {
        formatting.formatError(stderr, "Failed to access cache directory", use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };
    defer file_cache.deinit();

    // Clear cache
    const bytes_freed = if (opts.pattern) |pattern| blk: {
        break :blk file_cache.clearPattern(pattern) catch {
            formatting.formatError(stderr, "Failed to clear cache with pattern", use_color, use_unicode) catch {};
            return CommandResult{ .success = false, .exit_code = 1 };
        };
    } else blk: {
        break :blk file_cache.clearAll() catch {
            formatting.formatError(stderr, "Failed to clear cache", use_color, use_unicode) catch {};
            return CommandResult{ .success = false, .exit_code = 1 };
        };
    };

    if (global_opts.json) {
        stdout.print("{{\"bytes_freed\": {d}}}\n", .{bytes_freed}) catch {};
    } else {
        var size_buf: [32]u8 = undefined;
        const freed_str = types.formatBytes(bytes_freed, &size_buf);

        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Cache cleared, freed {s}", .{freed_str}) catch "Cache cleared";
        formatting.formatSuccess(stdout, msg, use_color, use_unicode) catch {};
    }

    return CommandResult{ .success = true };
}

/// Run the 'clean' subcommand - remove partial downloads
fn runClean(
    allocator: Allocator,
    cache_dir: []const u8,
    global_opts: GlobalOptions,
    use_color: bool,
    use_unicode: bool,
) CommandResult {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var file_cache = Cache.init(allocator, cache_dir) catch {
        formatting.formatError(stderr, "Failed to access cache directory", use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };
    defer file_cache.deinit();

    const bytes_freed = file_cache.cleanPartials() catch {
        formatting.formatError(stderr, "Failed to clean partial downloads", use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };

    if (global_opts.json) {
        stdout.print("{{\"bytes_freed\": {d}}}\n", .{bytes_freed}) catch {};
    } else {
        var size_buf: [32]u8 = undefined;
        const freed_str = types.formatBytes(bytes_freed, &size_buf);

        if (bytes_freed > 0) {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Cleaned partial downloads, freed {s}", .{freed_str}) catch "Cleaned";
            formatting.formatSuccess(stdout, msg, use_color, use_unicode) catch {};
        } else {
            formatting.formatInfo(stdout, "No partial downloads found", use_color, use_unicode) catch {};
        }
    }

    return CommandResult{ .success = true };
}

/// Run the 'dir' subcommand - print cache directory path
fn runDir(
    cache_dir: []const u8,
    global_opts: GlobalOptions,
) CommandResult {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (global_opts.json) {
        stdout.print("{{\"cache_dir\": \"{s}\"}}\n", .{cache_dir}) catch {};
    } else {
        stdout.print("{s}\n", .{cache_dir}) catch {};
    }

    return CommandResult{ .success = true };
}

/// Print a key-value pair
fn printKeyValue(writer: anytype, key: []const u8, value: []const u8, use_color: bool) void {
    if (use_color) {
        writer.print("  {s}{s: <18}{s} {s}\n", .{
            terminal.ESC ++ "1m",
            key,
            terminal.RESET,
            value,
        }) catch {};
    } else {
        writer.print("  {s: <18} {s}\n", .{ key, value }) catch {};
    }
}

/// Print a key-value pair with a number value
fn printKeyValueNumber(writer: anytype, key: []const u8, value: u64, use_color: bool) void {
    var buf: [32]u8 = undefined;
    const value_str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "?";
    printKeyValue(writer, key, value_str, use_color);
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

/// Print help for the cache command
pub fn printHelp(writer: anytype, use_color: bool) void {
    if (use_color) {
        writer.print("\n{s}hf-hub cache{s} - Manage the local cache\n\n", .{
            terminal.ESC ++ "1;36m",
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("\nhf-hub cache - Manage the local cache\n\n", .{}) catch {};
    }

    writer.print("USAGE:\n", .{}) catch {};
    writer.print("    hf-hub cache <SUBCOMMAND> [OPTIONS]\n\n", .{}) catch {};

    writer.print("SUBCOMMANDS:\n", .{}) catch {};
    const subcommands = [_]struct { name: []const u8, desc: []const u8 }{
        .{ .name = "info", .desc = "Show cache statistics" },
        .{ .name = "clear", .desc = "Clear the cache (with optional pattern)" },
        .{ .name = "clean", .desc = "Remove partial/corrupted downloads" },
        .{ .name = "dir", .desc = "Print cache directory path" },
    };

    for (subcommands) |sub| {
        if (use_color) {
            writer.print("    {s}{s: <12}{s} {s}\n", .{
                terminal.ESC ++ "33m",
                sub.name,
                terminal.RESET,
                sub.desc,
            }) catch {};
        } else {
            writer.print("    {s: <12} {s}\n", .{ sub.name, sub.desc }) catch {};
        }
    }

    writer.print("\nOPTIONS:\n", .{}) catch {};
    writer.print("    -f, --force          Skip confirmation prompts\n", .{}) catch {};
    writer.print("    -p, --pattern <PAT>  Filter by pattern (for clear)\n", .{}) catch {};
    writer.print("    -h, --help           Show this help message\n", .{}) catch {};

    writer.print("\nEXAMPLES:\n", .{}) catch {};
    if (use_color) {
        writer.print("    {s}${s} hf-hub cache info\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
        writer.print("    {s}${s} hf-hub cache clear --force\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
        writer.print("    {s}${s} hf-hub cache clean\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("    $ hf-hub cache info\n", .{}) catch {};
        writer.print("    $ hf-hub cache clear --force\n", .{}) catch {};
        writer.print("    $ hf-hub cache clean\n", .{}) catch {};
    }
    writer.print("\n", .{}) catch {};
}

// ============================================================================
// Tests
// ============================================================================

test "CacheSubcommand.fromString" {
    try std.testing.expectEqual(CacheSubcommand.info, CacheSubcommand.fromString("info").?);
    try std.testing.expectEqual(CacheSubcommand.clear, CacheSubcommand.fromString("clear").?);
    try std.testing.expectEqual(CacheSubcommand.clean, CacheSubcommand.fromString("clean").?);
    try std.testing.expectEqual(CacheSubcommand.dir, CacheSubcommand.fromString("dir").?);
    try std.testing.expect(CacheSubcommand.fromString("invalid") == null);
}

test "parseOptions - info subcommand" {
    const args = &[_][]const u8{"info"};
    const opts = parseOptions(args);

    try std.testing.expect(opts.subcommand != null);
    try std.testing.expectEqual(CacheSubcommand.info, opts.subcommand.?);
}

test "parseOptions - clear with force" {
    const args = &[_][]const u8{ "clear", "--force" };
    const opts = parseOptions(args);

    try std.testing.expectEqual(CacheSubcommand.clear, opts.subcommand.?);
    try std.testing.expect(opts.force);
}

test "parseOptions - clear with pattern" {
    const args = &[_][]const u8{ "clear", "--pattern", "llama*" };
    const opts = parseOptions(args);

    try std.testing.expectEqual(CacheSubcommand.clear, opts.subcommand.?);
    try std.testing.expectEqualStrings("llama*", opts.pattern.?);
}
