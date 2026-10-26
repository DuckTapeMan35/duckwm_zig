const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- modules ----
    // duckwm's own files (src/upstream, from scripts/sync).
    const protocol_mod = b.addModule("protocol", .{
        .root_source_file = b.path("src/upstream/protocol.zig"),
        .target = target,
    });
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/upstream/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_mod.addImport("protocol", protocol_mod);

    // The library: `b.dependency("duckwm", .{}).module("duckwm")`.
    const duckwm_mod = b.addModule("duckwm", .{
        .root_source_file = b.path("src/duckwm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    duckwm_mod.addImport("protocol", protocol_mod);
    duckwm_mod.addImport("duckwm_client", core_mod);

    // ---- libduckwm, for C ----
    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_mod.addImport("protocol", protocol_mod);
    c_mod.addImport("duckwm_client", core_mod);
    c_mod.addImport("duckwm", duckwm_mod);
    const libduckwm = b.addLibrary(.{ .name = "duckwm", .linkage = .static, .root_module = c_mod });
    const libduckwm_so = b.addLibrary(.{ .name = "duckwm", .linkage = .dynamic, .root_module = c_mod });
    b.installArtifact(libduckwm);
    b.installArtifact(libduckwm_so);
    b.installFile("include/duckwm.h", "include/duckwm.h");
    b.installFile("dist/duckwm.pc", "lib/pkgconfig/duckwm.pc");

    // zig build c: include/duckwm.h and src/c_types.zig from protocol.zig.
    const gen_c = b.addExecutable(.{
        .name = "gen_c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_c.zig"),
            .target = b.graph.host,
        }),
    });
    const run_gen_c = b.addRunArtifact(gen_c);
    const update_c = b.addUpdateSourceFiles();
    update_c.addCopyFileToSource(run_gen_c.addOutputFileArg("duckwm.h"), "include/duckwm.h");
    update_c.addCopyFileToSource(run_gen_c.addOutputFileArg("c_types.zig"), "src/c_types.zig");
    b.step("c", "Regenerate include/duckwm.h and src/c_types.zig").dependOn(&update_c.step);

    // ---- examples ----
    const examples_step = b.step("examples", "Build the examples");
    const example_zig = b.addExecutable(.{
        .name = "example-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/zig/example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "duckwm", .module = duckwm_mod }},
        }),
    });
    examples_step.dependOn(&b.addInstallArtifact(example_zig, .{}).step);

    const example_c = b.addExecutable(.{
        .name = "example-c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    example_c.root_module.addCSourceFile(.{
        .file = b.path("examples/c/example.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-pedantic", "-Werror" },
    });
    example_c.root_module.addIncludePath(b.path("include"));
    example_c.root_module.linkLibrary(libduckwm);
    examples_step.dependOn(&b.addInstallArtifact(example_c, .{}).step);

    // ---- tests ----
    const test_step = b.step("test", "Run tests");
    for ([_]*std.Build.Module{ core_mod, duckwm_mod, c_mod }) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
}
