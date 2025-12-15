//! CLI download command for HuggingFace Hub
//!
//! Downloads files from HuggingFace model repositories.

const std = @import("std");
const Allocator = std.mem.Allocator;

const hf = @import("hf-hub");
const Config = hf.Config;
const HubClient = hf.HubClient;
const terminal = hf.terminal;
const progress_mod = hf.progress;
const ProgressBar = progress_mod.ProgressBar;
const types = hf.types;
const DownloadProgress = types.DownloadProgress;
const FileInfo = types.FileInfo;

const commands = @import("commands.zig");
const GlobalOptions = commands.GlobalOptions;
const CommandResult = commands.CommandResult;
const formatting = @import("formatting.zig");

/// Download command options
pub const DownloadCmdOptions = struct {
    /// Model ID (required)
    model_id: ?[]const u8 = null,
    /// Specific file to download (optional)
    filename: ?[]const u8 = null,
    /// Output directory
    output_dir: []const u8 = ".",
    /// Revision/branch
    revision: []const u8 = "main",
    /// Whether to use cache
    use_cache: bool = true,
    /// Whether to resume partial downloads
    resume_download: bool = true,
    /// Number of parallel downloads
    parallel: u8 = 1,
    /// Filter pattern for files
    filter: ?[]const u8 = null,
    /// Only download GGUF files
    gguf_only: bool = false,
    /// Show help
    help: bool = false,
};

/// Run the download command
pub fn run(
    allocator: Allocator,
    args: []const []const u8,
    config: *Config,
    global_opts: GlobalOptions,
) !CommandResult {
    // Parse command-specific options
    var opts = DownloadCmdOptions{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.output_dir = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--revision") or std.mem.eql(u8, arg, "-r")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.revision = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            opts.use_cache = false;
        } else if (std.mem.eql(u8, arg, "--no-resume")) {
            opts.resume_download = false;
        } else if (std.mem.eql(u8, arg, "--parallel") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.parallel = std.fmt.parseInt(u8, args[i], 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "--filter") or std.mem.eql(u8, arg, "-f")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.filter = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--gguf-only")) {
            opts.gguf_only = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument
            if (opts.model_id == null) {
                opts.model_id = arg;
            } else if (opts.filename == null) {
                opts.filename = arg;
            }
        }

        i += 1;
    }

    // Show help if requested
    if (opts.help) {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        printHelp(stdout, !global_opts.no_color and terminal.isTty());
        return CommandResult{ .success = true };
    }

    // Validate required options
    if (opts.model_id == null) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try formatting.formatError(stderr, "Missing required argument: MODEL_ID", !global_opts.no_color, true);
        try stderr.print("\nUsage: hf-hub download <MODEL_ID> [FILE] [OPTIONS]\n", .{});
        try stderr.print("Run 'hf-hub download --help' for more information.\n", .{});
        return CommandResult{ .success = false, .exit_code = 1 };
    }

    const model_id = opts.model_id.?;

    // Initialize HubClient
    var hub = try HubClient.init(allocator, config.*);
    defer hub.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const use_color = !global_opts.no_color and terminal.isTty();
    const use_progress = !global_opts.no_progress and terminal.isTty();

    // Print header
    if (!global_opts.json) {
        if (use_color) {
            try stdout.print("\n{s}Downloading from {s}{s}{s}\n\n", .{
                terminal.ESC ++ "1m",
                terminal.ESC ++ "36m",
                model_id,
                terminal.RESET,
            });
        } else {
            try stdout.print("\nDownloading from {s}\n\n", .{model_id});
        }
    }

    // Get list of files to download
    var files_to_download = std.array_list.Managed(FileInfo).init(allocator);
    defer {
        for (files_to_download.items) |*f| {
            f.deinit(allocator);
        }
        files_to_download.deinit();
    }

    if (opts.filename) |filename| {
        // Download specific file
        const file_info = FileInfo{
            .filename = try allocator.dupe(u8, std.fs.path.basename(filename)),
            .path = try allocator.dupe(u8, filename),
            .is_gguf = FileInfo.checkIsGguf(filename),
        };
        try files_to_download.append(file_info);
    } else {
        // Get file list from API
        const all_files = if (opts.gguf_only)
            try hub.listGgufFiles(model_id)
        else
            try hub.listFiles(model_id);

        // Apply filter if specified
        for (all_files) |file| {
            var include = true;

            if (opts.filter) |filter| {
                include = std.mem.indexOf(u8, file.path, filter) != null;
            }

            if (include) {
                try files_to_download.append(file);
            } else {
                var f = file;
                f.deinit(allocator);
            }
        }
        allocator.free(all_files);
    }

    if (files_to_download.items.len == 0) {
        try formatting.formatWarning(stdout, "No files found to download", use_color, true);
        return CommandResult{ .success = true };
    }

    // Print file list
    if (!global_opts.json) {
        try stdout.print("Found {d} file(s) to download:\n", .{files_to_download.items.len});
        for (files_to_download.items) |file| {
            var size_buf: [32]u8 = undefined;
            const size_str = if (file.size) |s| types.formatBytes(s, &size_buf) else "unknown";
            if (use_color) {
                try stdout.print("  {s}•{s} {s} ({s})\n", .{
                    terminal.ESC ++ "36m",
                    terminal.RESET,
                    file.path,
                    size_str,
                });
            } else {
                try stdout.print("  • {s} ({s})\n", .{ file.path, size_str });
            }
        }
        try stdout.print("\n", .{});
    }

    // Create output directory if needed
    std.fs.cwd().makePath(opts.output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            try formatting.formatError(stdout, "Failed to create output directory", use_color, true);
            return CommandResult{ .success = false, .exit_code = 1 };
        },
    };

    // Download files
    var success_count: u32 = 0;
    var fail_count: u32 = 0;
    var total_bytes: u64 = 0;

    var progress_bar = ProgressBar.init();

    for (files_to_download.items) |file| {
        // Build output path
        const output_path = try std.fs.path.join(allocator, &.{ opts.output_dir, file.path });
        defer allocator.free(output_path);

        // Create parent directories for the file
        if (std.fs.path.dirname(output_path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    try formatting.formatError(stdout, "Failed to create directory", use_color, true);
                    fail_count += 1;
                    continue;
                },
            };
        }

        // Progress callback
        const callback: ?types.ProgressCallback = if (use_progress) blk: {
            break :blk struct {
                fn cb(prog: DownloadProgress) void {
                    var bar = ProgressBar.init();
                    bar.render(prog);
                }
            }.cb;
        } else null;

        // Download using HubClient
        const downloaded_path = hub.downloadFileWithOptions(
            model_id,
            file.path,
            opts.revision,
            opts.output_dir,
            callback,
        ) catch |err| {
            if (!global_opts.json) {
                progress_bar.clearLine();
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Failed to download {s}: {s}", .{ file.path, @errorName(err) }) catch "Download failed";
                try formatting.formatError(stdout, err_msg, use_color, true);
            }
            fail_count += 1;
            continue;
        };
        defer allocator.free(downloaded_path);

        // Success
        if (!global_opts.json) {
            progress_bar.clearLine();
            progress_bar.complete(file.path, file.size orelse 0);
        }

        total_bytes += file.size orelse 0;
        success_count += 1;
    }

    // Print summary
    if (!global_opts.json) {
        try stdout.print("\n", .{});
        var size_buf: [32]u8 = undefined;
        const total_size_str = types.formatBytes(total_bytes, &size_buf);

        if (fail_count == 0) {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Downloaded {d} file(s), {s} total", .{ success_count, total_size_str }) catch "Download complete";
            try formatting.formatSuccess(stdout, msg, use_color, true);
        } else {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Downloaded {d} file(s), {d} failed", .{ success_count, fail_count }) catch "Download complete with errors";
            try formatting.formatWarning(stdout, msg, use_color, true);
        }
    } else {
        // JSON output
        try stdout.print("{{\"success\":{d},\"failed\":{d},\"bytes\":{d}}}\n", .{ success_count, fail_count, total_bytes });
    }

    return CommandResult{
        .success = fail_count == 0,
        .exit_code = if (fail_count == 0) 0 else 1,
    };
}

/// Print help for the download command
pub fn printHelp(writer: anytype, use_color: bool) void {
    if (use_color) {
        writer.print("\n{s}DOWNLOAD{s} - Download files from a HuggingFace model repository\n\n", .{
            terminal.ESC ++ "1;33m",
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("\nDOWNLOAD - Download files from a HuggingFace model repository\n\n", .{}) catch {};
    }

    writer.print("USAGE:\n", .{}) catch {};
    writer.print("    hf-hub download <MODEL_ID> [FILE] [OPTIONS]\n\n", .{}) catch {};

    writer.print("ARGUMENTS:\n", .{}) catch {};
    writer.print("    MODEL_ID    Model ID (e.g., meta-llama/Llama-2-7b)\n", .{}) catch {};
    writer.print("    FILE        Specific file to download (optional)\n\n", .{}) catch {};

    writer.print("OPTIONS:\n", .{}) catch {};
    const options = [_]struct { opt: []const u8, desc: []const u8 }{
        .{ .opt = "-o, --output <DIR>", .desc = "Output directory (default: current dir)" },
        .{ .opt = "-r, --revision <REV>", .desc = "Git revision/branch (default: main)" },
        .{ .opt = "    --no-cache", .desc = "Don't use cached files" },
        .{ .opt = "    --no-resume", .desc = "Don't resume partial downloads" },
        .{ .opt = "-p, --parallel <N>", .desc = "Number of parallel downloads (default: 1)" },
        .{ .opt = "-f, --filter <PATTERN>", .desc = "Only download files matching pattern" },
        .{ .opt = "    --gguf-only", .desc = "Only download .gguf files" },
        .{ .opt = "-h, --help", .desc = "Show this help message" },
    };

    for (options) |opt| {
        if (use_color) {
            writer.print("    {s}{s: <24}{s} {s}\n", .{
                terminal.ESC ++ "36m",
                opt.opt,
                terminal.RESET,
                opt.desc,
            }) catch {};
        } else {
            writer.print("    {s: <24} {s}\n", .{ opt.opt, opt.desc }) catch {};
        }
    }

    writer.print("\nEXAMPLES:\n", .{}) catch {};
    if (use_color) {
        writer.print("    {s}${s} hf-hub download TheBloke/Llama-2-7B-GGUF\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
        writer.print("    {s}${s} hf-hub download TheBloke/Llama-2-7B-GGUF llama-2-7b.Q4_K_M.gguf\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
        writer.print("    {s}${s} hf-hub download meta-llama/Llama-2-7b --gguf-only -o ./models\n", .{
            terminal.ESC ++ "90m",
            terminal.RESET,
        }) catch {};
    } else {
        writer.print("    $ hf-hub download TheBloke/Llama-2-7B-GGUF\n", .{}) catch {};
        writer.print("    $ hf-hub download TheBloke/Llama-2-7B-GGUF llama-2-7b.Q4_K_M.gguf\n", .{}) catch {};
        writer.print("    $ hf-hub download meta-llama/Llama-2-7b --gguf-only -o ./models\n", .{}) catch {};
    }

    writer.print("\n", .{}) catch {};
}
