//! Private Models Example
//!
//! Demonstrates how to access private and gated models using authentication.
//!
//! Prerequisites:
//!   1. Get a HuggingFace API token from: https://huggingface.co/settings/tokens
//!   2. Set it as an environment variable: export HF_TOKEN=hf_xxxxx
//!   3. For gated models (like Llama 2), request access on the model page first
//!
//! Usage:
//!   ./private_models
//!   HF_TOKEN=hf_xxxxx ./private_models
//!   ./private_models --model meta-llama/Llama-2-7b-hf

const std = @import("std");

const hf = @import("hf-hub");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Default to a well-known gated model
    var model_id: []const u8 = "meta-llama/Llama-2-7b-hf";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i < args.len) {
                model_id = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        }
    }

    std.debug.print("Private Models Example\n", .{});
    std.debug.print("=" ** 50 ++ "\n\n", .{});

    // Initialize the HubClient (automatically reads HF_TOKEN from environment)
    std.debug.print("Initializing HuggingFace Hub client...\n", .{});
    var client = try hf.HubClient.init(allocator, null);
    defer client.deinit();

    // Check authentication status
    std.debug.print("\nChecking authentication status...\n", .{});

    if (client.isAuthenticated()) {
        std.debug.print("  ✓ Authenticated with token\n", .{});

        // Get user information
        const user_result = client.whoami();
        if (user_result) |user| {
            var u = user;
            defer client.freeUser(&u);

            std.debug.print("\n  User Information:\n", .{});
            std.debug.print("    Username: {s}\n", .{u.username});
            if (u.fullname) |fullname| {
                std.debug.print("    Name: {s}\n", .{fullname});
            }
            if (u.email) |email| {
                std.debug.print("    Email: {s}\n", .{email});
            }
            if (u.is_pro) {
                std.debug.print("    Account: PRO\n", .{});
            }
        } else |err| {
            std.debug.print("  ! Could not get user info: {}\n", .{err});
        }
    } else {
        std.debug.print("  ✗ Not authenticated\n", .{});
        std.debug.print("  Set HF_TOKEN environment variable or use --token\n", .{});
    }

    // Check access to the specified model
    std.debug.print("\nChecking access to: {s}\n", .{model_id});

    // First check if the model exists
    const exists = client.modelExists(model_id) catch |err| {
        std.debug.print("  ✗ Error checking model: {}\n", .{err});
        return;
    };

    if (!exists) {
        std.debug.print("  ✗ Model not found\n", .{});
        return;
    }
    std.debug.print("  ✓ Model exists\n", .{});

    // Try to get model info
    const model_result = client.getModelInfo(model_id);

    if (model_result) |model| {
        var m = model;
        defer client.freeModel(&m);

        std.debug.print("  ✓ Access granted\n", .{});
        std.debug.print("\n  Model Details:\n", .{});
        std.debug.print("    ID: {s}\n", .{m.id});

        if (m.author) |author| {
            std.debug.print("    Author: {s}\n", .{author});
        }
        if (m.pipeline_tag) |pipeline| {
            std.debug.print("    Pipeline: {s}\n", .{pipeline});
        }
        if (m.downloads) |downloads| {
            std.debug.print("    Downloads: {d}\n", .{downloads});
        }
        if (m.likes) |likes| {
            std.debug.print("    Likes: {d}\n", .{likes});
        }

        std.debug.print("    Private: {}\n", .{m.private});

        if (m.gated) |gated| {
            std.debug.print("    Gated: {}\n", .{gated});
        }

        // Try to list files
        std.debug.print("\n  Listing files...\n", .{});

        const files_result = client.listFiles(model_id);
        if (files_result) |files| {
            defer client.freeFileInfoSlice(files);

            std.debug.print("    Found {d} files:\n", .{files.len});

            // Show first 10 files
            const max_show = @min(files.len, 10);
            for (files[0..max_show]) |file| {
                var size_buf: [32]u8 = undefined;
                const size_str = if (file.size) |s|
                    hf.formatBytes(s, &size_buf)
                else
                    "unknown size";

                const gguf_marker: []const u8 = if (file.is_gguf) " [GGUF]" else "";
                std.debug.print("      {s} ({s}){s}\n", .{ file.filename, size_str, gguf_marker });
            }

            if (files.len > 10) {
                std.debug.print("      ... and {d} more files\n", .{files.len - 10});
            }
        } else |err| {
            std.debug.print("    ✗ Could not list files: {}\n", .{err});
        }
    } else |err| {
        switch (err) {
            error.Unauthorized => {
                std.debug.print("  ✗ Unauthorized - you need to authenticate\n", .{});
                std.debug.print("    Set HF_TOKEN environment variable with your API token\n", .{});
            },
            error.Forbidden => {
                std.debug.print("  ✗ Forbidden - you don't have access to this model\n", .{});
                std.debug.print("    For gated models, request access on the model page:\n", .{});
                std.debug.print("    https://huggingface.co/{s}\n", .{model_id});
            },
            error.NotFound => {
                std.debug.print("  ✗ Model not found\n", .{});
            },
            else => {
                std.debug.print("  ✗ Error: {}\n", .{err});
            },
        }
    }

    // Example: Programmatically set token
    std.debug.print("\n" ++ "-" ** 50 ++ "\n", .{});
    std.debug.print("Programmatic Token Example\n", .{});
    std.debug.print("-" ** 50 ++ "\n\n", .{});

    std.debug.print(
        \\You can also set the token programmatically:
        \\
        \\  // Create authenticated client
        \\  var client = try hf.createAuthenticatedClient(allocator, "hf_xxxxx");
        \\  defer client.deinit();
        \\
        \\  // Or set token later
        \\  client.setToken("hf_xxxxx");
        \\
        \\
    , .{});
}

fn printUsage() void {
    std.debug.print(
        \\Private Models Example - hf-hub-zig
        \\
        \\Demonstrates authentication for private and gated models.
        \\
        \\Usage: private_models [OPTIONS]
        \\
        \\Options:
        \\  -m, --model <ID>   Model ID to check access for
        \\                     (default: meta-llama/Llama-2-7b-hf)
        \\  -h, --help         Show this help message
        \\
        \\Environment Variables:
        \\  HF_TOKEN           HuggingFace API token for authentication
        \\
        \\Examples:
        \\  # Check access to default gated model
        \\  private_models
        \\
        \\  # Check access to specific model
        \\  private_models --model my-org/my-private-model
        \\
        \\  # With explicit token
        \\  HF_TOKEN=hf_xxxxx private_models
        \\
        \\Getting a Token:
        \\  1. Go to https://huggingface.co/settings/tokens
        \\  2. Create a new token with 'read' access
        \\  3. Export it: export HF_TOKEN=hf_xxxxx
        \\
        \\Accessing Gated Models:
        \\  1. Visit the model page (e.g., meta-llama/Llama-2-7b-hf)
        \\  2. Click "Request access" and accept the terms
        \\  3. Wait for approval (usually instant for most models)
        \\
    , .{});
}
