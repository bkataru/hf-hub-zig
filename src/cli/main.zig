//! CLI Main Entrypoint for HuggingFace Hub CLI
//!
//! This is the main entry point for the hf-hub command-line interface.
//! It handles argument parsing, signal handling, and dispatches to command handlers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const hf = @import("hf-hub");
const terminal = hf.terminal;

const commands = @import("commands.zig");

/// Application exit codes
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
    network_error = 3,
    not_found = 4,
    unauthorized = 5,
    rate_limited = 6,
    io_error = 7,
    interrupted = 130,

    pub fn toInt(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

/// Global state for signal handling
var interrupted: bool = false;

/// Signal handler for graceful shutdown
fn handleSignal(sig: i32) callconv(.c) void {
    _ = sig;
    interrupted = true;

    // Print interrupt message
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print("\n{s}Interrupted. Cleaning up...{s}\n", .{
        if (terminal.isTty() and !terminal.noColorEnv()) terminal.ESC ++ "33m" else "",
        if (terminal.isTty() and !terminal.noColorEnv()) terminal.RESET else "",
    }) catch {};
}

/// Install signal handlers for graceful shutdown
fn installSignalHandlers() void {
    // Install SIGINT handler (Ctrl+C)
    if (builtin.os.tag != .windows) {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }
}

/// Check if operation was interrupted
pub fn wasInterrupted() bool {
    return interrupted;
}

/// Main entry point
pub fn main() !void {
    // Use a general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Install signal handlers
    installSignalHandlers();

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Run the CLI and get exit code
    const exit_code = run(allocator, args);

    // Exit with appropriate code
    std.process.exit(exit_code);
}

/// Run the CLI with the given arguments
/// Returns the exit code
fn run(allocator: Allocator, args: []const []const u8) u8 {
    // Skip the program name (first argument)
    const cli_args = if (args.len > 0) args[1..] else args;

    // Check for empty arguments
    if (cli_args.len == 0) {
        commands.printHelp(null);
        return ExitCode.success.toInt();
    }

    // Parse global options
    const parsed = commands.parseGlobalOptions(cli_args);
    const global_opts = parsed.opts;
    const remaining_args = parsed.remaining;

    // Handle --version flag
    if (global_opts.version) {
        commands.printVersion();
        return ExitCode.success.toInt();
    }

    // Handle --help flag with no command
    if (global_opts.help and remaining_args.len == 0) {
        commands.printHelp(null);
        return ExitCode.success.toInt();
    }

    // Check for command
    if (remaining_args.len == 0) {
        if (global_opts.help) {
            commands.printHelp(null);
            return ExitCode.success.toInt();
        }
        printError("No command specified. Use --help for usage information.", global_opts);
        return ExitCode.usage_error.toInt();
    }

    // Parse command
    const command_str = remaining_args[0];
    const command = commands.Command.fromString(command_str);

    if (command == null) {
        printErrorFmt("Unknown command: '{s}'. Use --help for available commands.", .{command_str}, global_opts);
        return ExitCode.usage_error.toInt();
    }

    // Handle --help for specific command
    if (global_opts.help) {
        commands.printHelp(command);
        return ExitCode.success.toInt();
    }

    // Get command-specific arguments (skip the command name itself)
    const command_args = if (remaining_args.len > 1) remaining_args[1..] else &[_][]const u8{};

    // Check for --help in command args
    for (command_args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            commands.printHelp(command);
            return ExitCode.success.toInt();
        }
    }

    // Run the command
    const result = commands.runCommand(allocator, command.?, command_args, global_opts) catch |err| {
        return handleError(err, global_opts);
    };

    // Check for interruption
    if (wasInterrupted()) {
        return ExitCode.interrupted.toInt();
    }

    // Process result
    if (result.success) {
        return ExitCode.success.toInt();
    } else {
        if (result.message) |msg| {
            printError(msg, global_opts);
        }
        return if (result.exit_code != 0) result.exit_code else ExitCode.general_error.toInt();
    }
}

/// Handle errors and return appropriate exit code
fn handleError(err: anyerror, global_opts: commands.GlobalOptions) u8 {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const use_color = terminal.isTty() and !terminal.noColorEnv() and !global_opts.no_color;

    // Format error message with color
    if (use_color) {
        stderr.print("{s}{s} Error:{s} ", .{
            terminal.ESC ++ "1;31m", // Bold red
            terminal.Icons.cross(true),
            terminal.RESET,
        }) catch {};
    } else {
        stderr.print("Error: ", .{}) catch {};
    }

    // Print specific error message and determine exit code
    const exit_code: ExitCode = switch (err) {
        error.NetworkError, error.ConnectionRefused, error.ConnectionResetByPeer => blk: {
            stderr.print("Network connection failed. Check your internet connection.\n", .{}) catch {};
            break :blk .network_error;
        },
        error.Timeout, error.ConnectionTimedOut => blk: {
            stderr.print("Request timed out. Try again or increase --timeout.\n", .{}) catch {};
            break :blk .network_error;
        },
        error.NotFound, error.HttpNotFound, error.FileNotFound => blk: {
            stderr.print("Resource not found. Check the model ID or filename.\n", .{}) catch {};
            break :blk .not_found;
        },
        error.Unauthorized, error.HttpUnauthorized => blk: {
            stderr.print("Authentication required. Provide a token with --token or HF_TOKEN.\n", .{}) catch {};
            break :blk .unauthorized;
        },
        error.Forbidden, error.HttpForbidden => blk: {
            stderr.print("Access denied. You may not have permission to access this resource.\n", .{}) catch {};
            break :blk .unauthorized;
        },
        error.RateLimited, error.HttpTooManyRequests => blk: {
            stderr.print("Rate limited. Please wait and try again.\n", .{}) catch {};
            break :blk .rate_limited;
        },
        error.OutOfMemory => blk: {
            stderr.print("Out of memory.\n", .{}) catch {};
            break :blk .general_error;
        },
        error.InvalidJson, error.UnexpectedToken, error.SyntaxError => blk: {
            stderr.print("Failed to parse API response. The API may have changed.\n", .{}) catch {};
            break :blk .general_error;
        },
        error.AccessDenied, error.PermissionDenied => blk: {
            stderr.print("Permission denied. Check file/directory permissions.\n", .{}) catch {};
            break :blk .io_error;
        },
        error.DiskQuota, error.NoSpaceLeft => blk: {
            stderr.print("No disk space available.\n", .{}) catch {};
            break :blk .io_error;
        },
        error.IsDir, error.NotDir => blk: {
            stderr.print("Invalid path: expected a file but got a directory, or vice versa.\n", .{}) catch {};
            break :blk .io_error;
        },
        else => blk: {
            stderr.print("{s}\n", .{@errorName(err)}) catch {};
            break :blk .general_error;
        },
    };

    // Print suggestion in verbose mode
    if (global_opts.verbose) {
        if (use_color) {
            stderr.print("{s}Tip:{s} Run with --help for usage information.\n", .{
                terminal.ESC ++ "90m", // Dim
                terminal.RESET,
            }) catch {};
        } else {
            stderr.print("Tip: Run with --help for usage information.\n", .{}) catch {};
        }
    }

    return exit_code.toInt();
}

/// Print an error message
fn printError(message: []const u8, global_opts: commands.GlobalOptions) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const use_color = terminal.isTty() and !terminal.noColorEnv() and !global_opts.no_color;

    if (use_color) {
        stderr.print("{s}{s} Error:{s} {s}\n", .{
            terminal.ESC ++ "1;31m", // Bold red
            terminal.Icons.cross(true),
            terminal.RESET,
            message,
        }) catch {};
    } else {
        stderr.print("Error: {s}\n", .{message}) catch {};
    }
}

/// Print a formatted error message
fn printErrorFmt(comptime fmt: []const u8, args: anytype, global_opts: commands.GlobalOptions) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const use_color = terminal.isTty() and !terminal.noColorEnv() and !global_opts.no_color;

    if (use_color) {
        stderr.print("{s}{s} Error:{s} ", .{
            terminal.ESC ++ "1;31m", // Bold red
            terminal.Icons.cross(true),
            terminal.RESET,
        }) catch {};
    } else {
        stderr.print("Error: ", .{}) catch {};
    }

    stderr.print(fmt ++ "\n", args) catch {};
}

// ============================================================================
// Tests
// ============================================================================

test "ExitCode values" {
    try std.testing.expectEqual(@as(u8, 0), ExitCode.success.toInt());
    try std.testing.expectEqual(@as(u8, 1), ExitCode.general_error.toInt());
    try std.testing.expectEqual(@as(u8, 2), ExitCode.usage_error.toInt());
    try std.testing.expectEqual(@as(u8, 130), ExitCode.interrupted.toInt());
}

test "run with no args shows help" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{"hf-hub"};
    const exit_code = run(allocator, args);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}

test "run with --version" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "hf-hub", "--version" };
    const exit_code = run(allocator, args);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}

test "run with --help" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "hf-hub", "--help" };
    const exit_code = run(allocator, args);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}

test "run with unknown command" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "hf-hub", "unknowncommand" };
    const exit_code = run(allocator, args);
    try std.testing.expectEqual(@as(u8, 2), exit_code); // usage_error
}

test "run with help for specific command" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "hf-hub", "--help", "search" };
    const exit_code = run(allocator, args);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}

test "wasInterrupted initial state" {
    try std.testing.expect(!wasInterrupted());
}
