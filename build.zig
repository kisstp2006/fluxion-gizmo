// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const math = b.dependency("fluxion_math", .{ .target = target, .optimize = optimize });
    const debugdraw = b.dependency("fluxion_debugdraw", .{ .target = target, .optimize = optimize, .renderer = false });

    const mod = b.addModule("fluxion_gizmo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_math", .module = math.module("fluxion_math") },
            .{ .name = "fluxion_debugdraw", .module = debugdraw.module("fluxion_debugdraw") },
        },
    });

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "fluxion-gizmo-tests",
        .root_module = mod,
    })).step);
    test_step.dependOn(&wasmCheck(b).step);

    const docs_lib = b.addLibrary(.{ .name = "fluxion-gizmo", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation into zig-out/docs").dependOn(&install_docs.step);

    const wants_examples = b.option(bool, "examples", "Build the example (default: only when this is the root package)") orelse
        (b.pkg_hash.len == 0);
    if (!wants_examples) return;

    const rhi = b.lazyDependency("fluxion_rhi", .{ .target = target, .optimize = optimize }) orelse return;
    const shader = b.lazyDependency("fluxion_shader", .{ .target = target, .optimize = optimize }) orelse return;
    const platform = b.lazyDependency("fluxion_platform", .{ .target = target, .optimize = optimize }) orelse return;
    const image = b.lazyDependency("fluxion_image", .{ .target = target, .optimize = optimize }) orelse return;

    // A fetched debugdraw's renderer names rhi and shader by path, so it is
    // built here from its source with this package's, as the engine does.
    const debugdraw_rhi = b.createModule(.{
        .root_source_file = debugdraw.path("src/render/rhi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_debugdraw", .module = debugdraw.module("fluxion_debugdraw") },
            .{ .name = "fluxion_math", .module = math.module("fluxion_math") },
            .{ .name = "fluxion_rhi", .module = rhi.module("fluxion_rhi") },
            .{ .name = "fluxion_shader", .module = shader.module("fluxion_shader") },
        },
    });

    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/gizmos.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_gizmo", .module = mod },
            .{ .name = "fluxion_debugdraw", .module = debugdraw.module("fluxion_debugdraw") },
            .{ .name = "fluxion_debugdraw_rhi", .module = debugdraw_rhi },
            .{ .name = "fluxion_math", .module = math.module("fluxion_math") },
            .{ .name = "fluxion_rhi", .module = rhi.module("fluxion_rhi") },
            .{ .name = "fluxion_platform", .module = platform.module("fluxion_platform") },
            .{ .name = "fluxion_image", .module = image.module("fluxion_image") },
        },
    });
    const exe = b.addExecutable(.{ .name = "fluxion-gizmo-example", .root_module = example_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("example", "Boxes in space and sprites on a plane, moved, turned and scaled").dependOn(&run.step);

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "fluxion-gizmo-example-tests",
        .root_module = example_mod,
    })).step);
}

/// The library built for a browser and never run, so a change that would
/// not compile there fails the suite.
fn wasmCheck(b: *std.Build) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;
    const math = b.dependency("fluxion_math", .{ .target = target, .optimize = optimize }).module("fluxion_math");
    const debugdraw = b.dependency("fluxion_debugdraw", .{ .target = target, .optimize = optimize, .renderer = false }).module("fluxion_debugdraw");

    const gizmo = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_math", .module = math },
            .{ .name = "fluxion_debugdraw", .module = debugdraw },
        },
    });
    const check = b.addExecutable(.{
        .name = "fluxion-gizmo-wasm-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluxion_math", .module = math },
                .{ .name = "fluxion_debugdraw", .module = debugdraw },
                .{ .name = "fluxion_gizmo", .module = gizmo },
            },
        }),
    });
    check.entry = .disabled;
    check.rdynamic = true;
    return check;
}
