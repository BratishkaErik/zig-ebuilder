// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const BuildZigZon = @import("BuildZigZon.zig");
const Dependencies = @import("Dependencies.zig");
const Logger = @import("Logger.zig");

const location = @import("location.zig");
const setup = @import("setup.zig");

const ZigProcess = @This();

/// Zig executable to use.
exe: []const u8,
env_map: *const std.process.EnvMap,
version: Version,

pub const Version = struct {
    kind: enum { release, live },
    /// Backed by `raw_string`.
    sem_ver: std.SemanticVersion,
    raw_string: []const u8,

    /// Oldest Zig version supported by zig-ebuild.eclass
    /// TODO maybe packages of other distros too? Not only ebuilds
    const oldest_supported: std.SemanticVersion = .{ .major = 0, .minor = 13, .patch = 0 };

    fn parse(raw_string: []const u8) error{ InvalidVersion, Overflow, VersionTooOld }!ZigProcess.Version {
        const sem_ver: std.SemanticVersion = try .parse(raw_string);

        if (sem_ver.order(oldest_supported).compare(.lt))
            return error.VersionTooOld;

        return .{
            .kind = if (sem_ver.pre != null) .live else .release,
            .sem_ver = sem_ver,
            .raw_string = raw_string,
        };
    }

    pub fn newPackageFormat(self: Version) bool {
        // First version to introduce new package format.
        const min_version: std.SemanticVersion = .{ .major = 0, .minor = 14, .patch = 0 };

        return switch (self.kind) {
            .live => true,
            // current >= first
            .release => self.sem_ver.order(min_version).compare(.gte),
        };
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    cwd: location.Dir,
    exe_path: []const u8,
    env_map: *const std.process.EnvMap,
    events: Logger,
) (error{ VersionCheckFailed, VersionTooOld, Overflow, InvalidVersion } || std.process.Child.RunError)!ZigProcess {
    const result_of_zig_version = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            exe_path,
            "version",
        },
        .cwd_dir = cwd.dir,
        .env_map = env_map,
        .max_output_bytes = 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            events.err(@src(), "Zig executable \"{s}\" not found. Aborting.", .{exe_path});
            return err;
        },
        else => return err,
    };
    defer {
        allocator.free(result_of_zig_version.stderr);
        allocator.free(result_of_zig_version.stdout);
    }

    if (result_of_zig_version.stderr.len != 0) {
        events.err(@src(), "Error when checking Zig version: {s}", .{result_of_zig_version.stderr});
        return error.VersionCheckFailed;
    }

    const trimmed_string = std.mem.trim(u8, result_of_zig_version.stdout, &std.ascii.whitespace);
    const version_to_parse = try allocator.dupe(u8, trimmed_string);
    errdefer allocator.free(version_to_parse);

    events.info(@src(), "Found Zig version {s}, processing...", .{version_to_parse});

    return .{
        .exe = exe_path,
        .env_map = env_map,
        .version = ZigProcess.Version.parse(version_to_parse) catch |err| switch (err) {
            error.InvalidVersion, error.Overflow => |e| {
                events.err(@src(), "Error when parsing Zig version: {s} caused by {s}.", .{ @errorName(e), version_to_parse });
                return e;
            },
            error.VersionTooOld => |e| {
                events.err(@src(), "Zig version is not supported by \"zig-ebuild.eclass\": {s} is less than {}", .{ version_to_parse, ZigProcess.Version.oldest_supported });
                return e;
            },
        },
    };
}

pub fn fetch(
    self: ZigProcess,
    allocator: std.mem.Allocator,
    cwd: location.Dir,
    args: struct {
        storage_loc: location.Dir,
        resource: BuildZigZon.Dep,
        fetch_mode: Dependencies.FetchMode,
    },
    events: Logger,
) std.process.Child.RunError!std.process.Child.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        self.exe,
        "fetch",
        "--global-cache-dir",
        args.storage_loc.string,
        switch (args.resource.storage) {
            .remote => |remote| remote.url,
            .local => |local| local.path,
        },
    });
    switch (args.fetch_mode) {
        .hashed => switch (args.resource.storage) {
            .remote => |remote| try argv.append(allocator, remote.hash),
            .local => {},
        },
        .plain => {},
        .none => @panic("unreachable"),
    }

    events.debug(@src(), "Running command: cd \"{!s}\" && {s}", .{ cwd.string, argv.items });
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd_dir = cwd.dir,
        .env_map = self.env_map,
        .max_output_bytes = 1 * 1024,
    });
}

pub fn build(
    self: ZigProcess,
    allocator: std.mem.Allocator,
    project_setup: setup.Project,
    args: struct {
        build_runner_path: []const u8,
        packages_loc: location.Dir,
        additional: [][:0]const u8,
    },
    events: Logger,
) std.process.Child.RunError!std.process.Child.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        self.exe,
        "build",
        "--build-file",
        project_setup.build_zig.string,
        "--build-runner",
        args.build_runner_path,
        "--system",
        args.packages_loc.string,
            // TODO is it truly needed? sorting JSON values works for now
            // "--seed",
            // "1",
    });
    try argv.appendSlice(allocator, args.additional);

    events.info(@src(), "Collecting information about project using \"zig build\"...", .{});
    if (args.additional.len > 0)
        events.info(@src(), "Additional args: {s}", .{args.additional});

    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd_dir = project_setup.root.dir,
        .env_map = self.env_map,
        .max_output_bytes = 1 * 1024 * 1024,
    });
}
