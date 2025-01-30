// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: 0BSD

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_bin = b.option(bool, "no-bin", "Do not output anything, trigger analysis only (useful for incremental compilation) (default: false)") orelse false;

    const dep_opts = .{ .target = target, .optimize = optimize };
    const mod_mustache =
        b.dependency("mustache", dep_opts)
        .module("mustache");
    const mod_ztl =
        b.dependency("ztl", dep_opts)
        .module("ztl");

    const mod_Report = b.addModule("Report", .{
        .root_source_file = b.path("share/build_runners/Report.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mustache", .module = mod_mustache },
            .{ .name = "ztl", .module = mod_ztl },
            .{ .name = "Report", .module = mod_Report },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zig-ebuilder",
        .root_module = main_mod,
    });
    b.installDirectory(std.Build.Step.InstallDir.Options{
        .install_dir = .{ .custom = "share" },
        .install_subdir = "zig-ebuilder",
        .source_dir = b.path("share/"),
    });
    if (no_bin)
        b.getInstallStep().dependOn(&exe.step)
    else
        b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = main_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
