//! CLI user command for HuggingFace Hub
//!
//! Shows information about the currently authenticated user (whoami).

const std = @import("std");
const Allocator = std.mem.Allocator;

const hf = @import("hf-hub");
const UserApi = hf.api.UserApi;
const HttpClient = hf.HttpClient;
const Config = hf.Config;
const terminal = hf.terminal;
const types = hf.types;

const commands = @import("commands.zig");
const GlobalOptions = commands.GlobalOptions;
const CommandResult = commands.CommandResult;
const formatting = @import("formatting.zig");

/// User command options
pub const UserCmdOptions = struct {
    /// Show help
    help: bool = false,
    /// JSON output
    json_output: bool = false,
};

/// Parse user command options
pub fn parseOptions(args: []const []const u8, global_opts: GlobalOptions) UserCmdOptions {
    var opts = UserCmdOptions{
        .json_output = global_opts.json,
    };

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json_output = true;
        }
    }

    return opts;
}

/// Run the user command
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
    const opts = parseOptions(args, global_opts);

    // Show help if requested
    if (opts.help) {
        printHelp(stdout, use_color);
        return CommandResult{ .success = true };
    }

    // Check if token is configured
    if (config.token == null) {
        formatting.formatError(
            stderr,
            "No authentication token found. Set HF_TOKEN environment variable or use --token.",
            use_color,
            use_unicode,
        ) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    }

    // Initialize HTTP client
    var http_client = HttpClient.init(allocator, config.*) catch {
        formatting.formatError(stderr, "Failed to initialize HTTP client", use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };
    defer http_client.deinit();

    // Get user info
    var user_api = UserApi.init(allocator, &http_client);
    var user = user_api.whoami() catch |err| {
        var buf: [256]u8 = undefined;
        const msg = switch (err) {
            error.Unauthorized => "Authentication failed. Please check your token.",
            error.NetworkError => "Network error. Please check your connection.",
            else => std.fmt.bufPrint(&buf, "Failed to get user info: {s}", .{@errorName(err)}) catch "Failed to get user info",
        };
        formatting.formatError(stderr, msg, use_color, use_unicode) catch {};
        return CommandResult{ .success = false, .exit_code = 1 };
    };
    defer user.deinit(allocator);

    // Output results
    if (opts.json_output) {
        outputJson(stdout, user) catch {};
    } else {
        outputFormatted(stdout, user, use_color) catch {};
    }

    return CommandResult{ .success = true };
}

/// Output user info as JSON
fn outputJson(writer: anytype, user: types.User) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"username\": \"{s}\"", .{user.username});

    if (user.name) |name| {
        try writer.print(",\n  \"name\": \"{s}\"", .{name});
    }

    if (user.fullname) |fullname| {
        try writer.print(",\n  \"fullname\": \"{s}\"", .{fullname});
    }

    if (user.email) |email| {
        try writer.print(",\n  \"email\": \"{s}\"", .{email});
        try writer.print(",\n  \"email_verified\": {s}", .{if (user.email_verified) "true" else "false"});
    }

    if (user.avatar_url) |avatar| {
        try writer.print(",\n  \"avatar_url\": \"{s}\"", .{avatar});
    }

    if (user.account_type) |acc_type| {
        try writer.print(",\n  \"type\": \"{s}\"", .{acc_type});
    }

    try writer.print(",\n  \"is_pro\": {s}", .{if (user.is_pro) "true" else "false"});

    try writer.writeAll("\n}\n");
}

/// Output user info in formatted style
fn outputFormatted(writer: anytype, user: types.User, use_color: bool) !void {
    try writer.writeAll("\n");

    // Header
    if (use_color) {
        try writer.print("{s}Logged in as:{s}\n\n", .{
            terminal.ESC ++ "1m",
            terminal.RESET,
        });
    } else {
        try writer.print("Logged in as:\n\n", .{});
    }

    // Username (main identity)
    if (use_color) {
        try writer.print("  {s}Username:{s}  {s}{s}{s}\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
            terminal.ESC ++ "1;36m",
            user.username,
            terminal.RESET,
        });
    } else {
        try writer.print("  Username:  {s}\n", .{user.username});
    }

    // Display name
    if (user.fullname orelse user.name) |display_name| {
        if (use_color) {
            try writer.print("  {s}Name:{s}      {s}\n", .{
                terminal.ESC ++ "90m",
                terminal.RESET,
                display_name,
            });
        } else {
            try writer.print("  Name:      {s}\n", .{display_name});
        }
    }

    // Email
    if (user.email) |email| {
        const verified_indicator = if (user.email_verified) " ✓" else "";
        if (use_color) {
            try writer.print("  {s}Email:{s}     {s}{s}{s}{s}\n", .{
                terminal.ESC ++ "90m",
                terminal.RESET,
                email,
                if (user.email_verified) terminal.ESC ++ "32m" else "",
                verified_indicator,
                terminal.RESET,
            });
        } else {
            try writer.print("  Email:     {s}{s}\n", .{ email, verified_indicator });
        }
    }

    // Account type and pro status
    const account_type = user.account_type orelse "user";
    const pro_badge = if (user.is_pro) " [PRO]" else "";
    if (use_color) {
        try writer.print("  {s}Type:{s}      {s}{s}{s}{s}\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
            account_type,
            if (user.is_pro) terminal.ESC ++ "33m" else "",
            pro_badge,
            terminal.RESET,
        });
    } else {
        try writer.print("  Type:      {s}{s}\n", .{ account_type, pro_badge });
    }

    // Profile URL
    if (use_color) {
        try writer.print("\n  {s}Profile:{s}   https://huggingface.co/{s}\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
            user.username,
        });
    } else {
        try writer.print("\n  Profile:   https://huggingface.co/{s}\n", .{user.username});
    }

    try writer.writeAll("\n");
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

/// Print help for the user command
pub fn printHelp(writer: anytype, use_color: bool) void {
    if (use_color) {
        writer.print("\n{s}USER{s} - Show current user information\n\n", .{
            terminal.ESC ++ "1;33m",
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("\nUSER - Show current user information\n\n", .{}) catch {};
    }

    writer.print("USAGE:\n", .{}) catch {};
    writer.print("    hf-hub user [OPTIONS]\n", .{}) catch {};
    writer.print("    hf-hub whoami [OPTIONS]\n\n", .{}) catch {};

    writer.print("DESCRIPTION:\n", .{}) catch {};
    writer.print("    Shows information about the currently authenticated user.\n", .{}) catch {};
    writer.print("    Requires a valid HuggingFace API token.\n\n", .{}) catch {};

    writer.print("OPTIONS:\n", .{}) catch {};
    const options = [_]struct { opt: []const u8, desc: []const u8 }{
        .{ .opt = "--json", .desc = "Output in JSON format" },
        .{ .opt = "-h, --help", .desc = "Show this help message" },
    };

    for (options) |opt| {
        if (use_color) {
            writer.print("    {s}{s: <20}{s} {s}\n", .{
                terminal.ESC ++ "36m",
                opt.opt,
                terminal.RESET,
                opt.desc,
            }) catch {};
        } else {
            writer.print("    {s: <20} {s}\n", .{ opt.opt, opt.desc }) catch {};
        }
    }

    writer.print("\nAUTHENTICATION:\n", .{}) catch {};
    writer.print("    Set your HuggingFace token using one of these methods:\n\n", .{}) catch {};
    writer.print("    1. Environment variable:\n", .{}) catch {};
    writer.print("       export HF_TOKEN=hf_xxxxxxxxxxxxx\n\n", .{}) catch {};
    writer.print("    2. Command line:\n", .{}) catch {};
    writer.print("       hf-hub --token hf_xxxxxxxxxxxxx user\n\n", .{}) catch {};
    writer.print("    Get your token at: https://huggingface.co/settings/tokens\n\n", .{}) catch {};

    writer.print("EXAMPLES:\n", .{}) catch {};
    if (use_color) {
        writer.print("    {s}${s} hf-hub user\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
        writer.print("    {s}${s} hf-hub whoami --json\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
        writer.print("    {s}${s} HF_TOKEN=hf_xxx hf-hub user\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("    $ hf-hub user\n", .{}) catch {};
        writer.print("    $ hf-hub whoami --json\n", .{}) catch {};
        writer.print("    $ HF_TOKEN=hf_xxx hf-hub user\n", .{}) catch {};
    }

    writer.print("\n", .{}) catch {};
}

// ============================================================================
// Tests
// ============================================================================

test "parseOptions - default values" {
    const args = &[_][]const u8{};
    const global_opts = commands.GlobalOptions{};
    const opts = parseOptions(args, global_opts);

    try std.testing.expect(!opts.help);
    try std.testing.expect(!opts.json_output);
}

test "parseOptions - help flag" {
    const args = &[_][]const u8{"--help"};
    const global_opts = commands.GlobalOptions{};
    const opts = parseOptions(args, global_opts);

    try std.testing.expect(opts.help);
}

test "parseOptions - json flag" {
    const args = &[_][]const u8{"--json"};
    const global_opts = commands.GlobalOptions{};
    const opts = parseOptions(args, global_opts);

    try std.testing.expect(opts.json_output);
}

test "parseOptions - global json flag" {
    const args = &[_][]const u8{};
    const global_opts = commands.GlobalOptions{ .json = true };
    const opts = parseOptions(args, global_opts);

    try std.testing.expect(opts.json_output);
}
