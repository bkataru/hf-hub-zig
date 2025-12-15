const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module - can be used as dependency via zig fetch
    const lib_mod = b.addModule("hf-hub", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CLI module
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("hf-hub", lib_mod);

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "hf-hub",
        .root_module = cli_mod,
    });
    b.installArtifact(exe);

    // Run command: zig build run -- <args>
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the CLI application");
    run_step.dependOn(&run_cmd.step);

    // Library unit tests
    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_unit_tests = b.addTest(.{
        .name = "lib-tests",
        .root_module = lib_test_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Unit tests from tests directory
    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_mod.addImport("hf-hub", lib_mod);
    const unit_tests = b.addTest(.{
        .name = "unit-tests",
        .root_module = unit_test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests (requires network)
    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_test_mod.addImport("hf-hub", lib_mod);
    const integration_tests = b.addTest(.{
        .name = "integration-tests",
        .root_module = integration_test_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const integration_test_step = b.step("test-integration", "Run integration tests (requires network)");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Documentation generation
    const docs_lib = b.addLibrary(.{
        .name = "hf-hub-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
