//! Simple Search Example
//!
//! Demonstrates basic search functionality with hf-hub-zig.
//!
//! Build: zig build
//! Run:   zig build run -- examples/simple_search.zig
//!
//! Or compile directly:
//!   zig build-exe examples/simple_search.zig -I src
//!
//! Usage:
//!   ./simple_search "llama 7b"
//!   ./simple_search "mistral" --gguf-only
//!   ./simple_search "code" --limit 5

const std = @import("std");

const hf = @import("hf-hub");

pub fn main() !void {
    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var query: []const u8 = "llama";
    var limit: u32 = 10;
    var gguf_only = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--gguf-only")) {
            gguf_only = true;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i < args.len) {
                limit = std.fmt.parseInt(u32, args[i], 10) catch 10;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            query = arg;
        }
    }

    // Initialize the HubClient
    std.debug.print("Initializing HuggingFace Hub client...\n", .{});

    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Perform the search
    std.debug.print("Searching for: \"{s}\"\n\n", .{query});

    var results = if (gguf_only)
        try client.searchGgufModels(query)
    else
        try client.search(.{
            .search = query,
            .limit = limit,
            .sort = .downloads,
            .full = true,
        });
    defer client.freeSearchResult(&results);

    // Display results
    if (results.models.len == 0) {
        std.debug.print("No models found.\n", .{});
        return;
    }

    std.debug.print("Found {d} models:\n", .{results.models.len});
    std.debug.print("{s}\n", .{"=" ** 80});

    for (results.models, 0..) |model, idx| {
        std.debug.print("\n{d}. {s}\n", .{ idx + 1, model.id });

        if (model.author) |author| {
            std.debug.print("   Author: {s}\n", .{author});
        }

        if (model.downloads) |downloads| {
            std.debug.print("   Downloads: {d}\n", .{downloads});
        }

        if (model.likes) |likes| {
            std.debug.print("   Likes: {d}\n", .{likes});
        }

        if (model.pipeline_tag) |pipeline| {
            std.debug.print("   Pipeline: {s}\n", .{pipeline});
        }

        if (model.private) {
            std.debug.print("   Private: yes\n", .{});
        }

        // Count GGUF files
        if (model.siblings) |siblings| {
            var gguf_count: usize = 0;
            for (siblings) |sib| {
                if (std.mem.endsWith(u8, sib.rfilename, ".gguf") or
                    std.mem.endsWith(u8, sib.rfilename, ".GGUF"))
                {
                    gguf_count += 1;
                }
            }
            if (gguf_count > 0) {
                std.debug.print("   GGUF files: {d}\n", .{gguf_count});
            }
        }
    }

    std.debug.print("\n{s}\n", .{"=" ** 80});
    std.debug.print("Total: {d} models\n", .{results.models.len});
}

fn printUsage() void {
    std.debug.print(
        \\Simple Search Example - hf-hub-zig
        \\
        \\Usage: simple_search [OPTIONS] <QUERY>
        \\
        \\Arguments:
        \\  <QUERY>       Search query string (default: "llama")
        \\
        \\Options:
        \\  --gguf-only   Only search for GGUF models
        \\  --limit <N>   Maximum number of results (default: 10)
        \\  -h, --help    Show this help message
        \\
        \\Examples:
        \\  simple_search "llama 7b"
        \\  simple_search "mistral" --gguf-only
        \\  simple_search "code assistant" --limit 5
        \\
        \\Environment Variables:
        \\  HF_TOKEN      Set authentication token for private models
        \\
    , .{});
}
