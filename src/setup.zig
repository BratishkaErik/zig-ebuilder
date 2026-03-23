// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const Logger = @import("Logger.zig");

const location = @import("location.zig");

const setup = @This();

pub const Generator = struct {
    /// Absolute.
    cache: location.Dir,
    /// Absolute, sub-dir of `cache`.
    dependencies_storage: location.Dir,
    /// Absolute, sub-dir of `dependencies_storage`.
    packages: location.Dir,

    /// Absolute.
    prefix: location.Dir,
    /// Absolute, sub-dir of `prefix`.
    share: location.Dir,
    /// Absolute, sub-dir of `share`.
    build_runners: location.Dir,
    /// Absolute, sub-dir of `share`.
    templates: location.Dir,

    pub fn deinit(self: *setup.Generator, allocator: std.mem.Allocator) void {
        self.templates.deinit(allocator);
        self.build_runners.deinit(allocator);
        self.share.deinit(allocator);
        self.prefix.deinit(allocator);

        self.packages.deinit(allocator);
        self.dependencies_storage.deinit(allocator);
        self.cache.deinit(allocator);
    }

    pub fn makeOpen(
        cwd: location.Dir,
        env_map: std.process.EnvMap,
        allocator: std.mem.Allocator,
        events: Logger,
    ) (error{ OutOfMemory, CacheNotFound } ||
        std.fs.Dir.MakeError ||
        std.fs.Dir.OpenError ||
        std.fs.File.OpenError ||
        std.fs.SelfExePathError)!setup.Generator {
        const self_exe_dir_path = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(self_exe_dir_path);
        std.debug.assert(std.fs.path.isAbsolute(self_exe_dir_path));
        events.debug(@src(), "self_exe_dir = {s}", .{self_exe_dir_path});

        const cache_path = cache_path: {
            // Try XDG_CACHE_HOME first (cross-platform override)
            if (env_map.get("XDG_CACHE_HOME")) |xdg_cache_home| xdg: {
                // Per spec, ${XDG_CACHE_HOME} must be set and non empty.
                // And also be an absolute path.
                if (xdg_cache_home.len == 0) {
                    events.err(@src(), "XDG_CACHE_HOME is set but content is empty, ignoring.", .{});
                    break :xdg;
                } else if (!std.fs.path.isAbsolute(xdg_cache_home)) {
                    events.err(@src(), "XDG_CACHE_HOME is set but content is not an absolute path, ignoring.", .{});
                    break :xdg;
                }

                break :cache_path try std.fs.path.join(allocator, &.{ xdg_cache_home, "zig-ebuilder" });
            }

            // Platform-specific cache directories
            switch (@import("builtin").os.tag) {
                .windows => {
                    // Windows: use LOCALAPPDATA (typically C:\Users\<user>\AppData\Local)
                    const local_app_data = env_map.get("LOCALAPPDATA") orelse {
                        events.err(@src(), "LOCALAPPDATA is not set, aborting.", .{});
                        return error.CacheNotFound;
                    };
                    if (local_app_data.len == 0) {
                        events.err(@src(), "LOCALAPPDATA is set but content is empty, aborting.", .{});
                        return error.CacheNotFound;
                    } else if (!std.fs.path.isAbsolute(local_app_data)) {
                        events.err(@src(), "LOCALAPPDATA is set but content is not an absolute path, aborting.", .{});
                        return error.CacheNotFound;
                    }
                    break :cache_path try std.fs.path.join(allocator, &.{ local_app_data, "zig-ebuilder" });
                },
                .macos => {
                    // macOS: use ~/Library/Caches
                    const home = env_map.get("HOME") orelse {
                        events.err(@src(), "HOME is not set, aborting.", .{});
                        return error.CacheNotFound;
                    };
                    if (home.len == 0) {
                        events.err(@src(), "HOME is set but content is empty, aborting.", .{});
                        return error.CacheNotFound;
                    } else if (!std.fs.path.isAbsolute(home)) {
                        events.err(@src(), "HOME is set but content is not an absolute path, aborting.", .{});
                        return error.CacheNotFound;
                    }
                    break :cache_path try std.fs.path.join(allocator, &.{ home, "Library", "Caches", "zig-ebuilder" });
                },
                else => {
                    // Linux/BSD/others: use ~/.cache (XDG default)
                    const home = env_map.get("HOME") orelse {
                        events.err(@src(), "Neither XDG_CACHE_HOME nor HOME is set, aborting.", .{});
                        return error.CacheNotFound;
                    };
                    if (home.len == 0) {
                        events.err(@src(), "XDG_CACHE_HOME is not set, HOME is set but content empty, aborting.", .{});
                        return error.CacheNotFound;
                    } else if (!std.fs.path.isAbsolute(home)) {
                        events.err(@src(), "XDG_CACHE_HOME is not set, HOME is set but content is not an absolute path, aborting.", .{});
                        return error.CacheNotFound;
                    }
                    break :cache_path try std.fs.path.join(allocator, &.{ home, ".cache", "zig-ebuilder" });
                },
            }
        };
        defer allocator.free(cache_path);
        std.debug.assert(std.fs.path.isAbsolute(cache_path));

        const paths = .{
            .cache = cache_path,
            .dependencies_storage = "deps",
            .packages = "p",

            .prefix = std.fs.path.dirname(self_exe_dir_path) orelse ".",
            .share = "share/zig-ebuilder",
            .build_runners = "build_runners",
            .templates = "templates",
        };
        events.debug(@src(), "paths = {}", .{std.json.fmt(paths, .{ .whitespace = .indent_2 })});

        events.info(@src(), "Opening cache directory \"{s}\"...", .{cache_path});

        var cache = cwd.makeOpenDir(allocator, paths.cache) catch |err| {
            events.err(@src(), "Error when creating directory \"{s}\": {s}. Aborting.", .{ paths.cache, @errorName(err) });
            return err;
        };
        errdefer cache.deinit(allocator);

        var dependencies_storage = cache.makeOpenDir(allocator, paths.dependencies_storage) catch |err| {
            events.err(@src(), "Error when creating directory \"{s}\": {s}. Aborting.", .{ paths.dependencies_storage, @errorName(err) });
            return err;
        };
        errdefer dependencies_storage.deinit(allocator);

        var packages = dependencies_storage.makeOpenDir(allocator, paths.packages) catch |err| {
            events.err(@src(), "Error when creating directory \"{s}\": {s}. Aborting.", .{ paths.packages, @errorName(err) });
            return err;
        };
        errdefer packages.deinit(allocator);

        var prefix = cwd.openDir(allocator, paths.prefix) catch |err| {
            events.err(@src(), "Error when opening install prefix \"{s}\": {s}. Aborting.", .{ paths.prefix, @errorName(err) });
            return err;
        };
        errdefer prefix.deinit(allocator);

        var share = prefix.openDir(allocator, paths.share) catch |err| {
            events.err(@src(), "Error when opening install prefix \"{s}\" sub-dir \"{s}\": {s}. Aborting.", .{ paths.prefix, paths.share, @errorName(err) });
            return err;
        };
        errdefer share.deinit(allocator);

        var build_runners = share.openDir(allocator, paths.build_runners) catch |err| {
            events.err(@src(), "Error when opening build runners directory \"{s}{c}{s}\": {s}. Aborting.", .{ paths.prefix, std.fs.path.sep, paths.build_runners, @errorName(err) });
            return err;
        };
        errdefer build_runners.deinit(allocator);

        var templates = share.openDir(allocator, paths.templates) catch |err| {
            events.err(@src(), "Error when opening templates directory \"{s}{c}{s}\": {s}. Aborting.", .{ paths.prefix, std.fs.path.sep, paths.templates, @errorName(err) });
            return err;
        };
        errdefer templates.deinit(allocator);

        return .{
            .cache = cache,
            .dependencies_storage = dependencies_storage,
            .packages = packages,

            .prefix = prefix,
            .share = share,
            .build_runners = build_runners,
            .templates = templates,
        };
    }
};

pub const Project = struct {
    /// Relative to `cwd`.
    root: location.Dir,

    /// Relative to `root`.
    build_zig: location.File,
    /// Relative to `root`.
    build_zig_zon: ?location.File,

    pub fn deinit(self: *setup.Project, allocator: std.mem.Allocator) void {
        if (self.build_zig_zon) |build_zig_zon| build_zig_zon.deinit(allocator);
        self.build_zig.deinit(allocator);
        self.root.deinit(allocator);
    }

    pub fn open(
        cwd: location.Dir,
        initial_build_zig_path: []const u8,
        allocator: std.mem.Allocator,
        events: Logger,
    ) (error{OutOfMemory} || std.fs.Dir.OpenError || std.fs.File.OpenError)!setup.Project {
        const paths = .{
            .root = std.fs.path.dirname(initial_build_zig_path) orelse ".",
            .build_zig = std.fs.path.basename(initial_build_zig_path),
            .build_zig_zon = "build.zig.zon",
        };
        events.debug(@src(), "paths = {}", .{std.json.fmt(paths, .{ .whitespace = .indent_2 })});

        var root = cwd.openDir(allocator, paths.root) catch |err| {
            events.err(@src(), "Error when opening project \"{s}\": {s}. Aborting.", .{ paths.root, @errorName(err) });
            return err;
        };
        errdefer root.deinit(allocator);

        const build_zig_path_relative_to_root = try allocator.dupe(u8, paths.build_zig);
        errdefer allocator.free(build_zig_path_relative_to_root);

        const build_zig: location.File = .{
            .string = build_zig_path_relative_to_root,
            .file = root.dir.openFile(build_zig_path_relative_to_root, .{}) catch |err| {
                events.err(@src(), "Error when opening file \"{s}\": {s}. Aborting.", .{ build_zig_path_relative_to_root, @errorName(err) });
                return err;
            },
        };
        errdefer build_zig.file.close();

        const build_zig_zon_path_relative_to_root = try allocator.dupe(u8, paths.build_zig_zon);
        errdefer allocator.free(build_zig_zon_path_relative_to_root);

        const build_zig_zon: location.File = .{
            .string = build_zig_zon_path_relative_to_root,
            .file = root.dir.openFile(build_zig_zon_path_relative_to_root, .{}) catch |err| {
                events.err(@src(), "Error when opening file \"{s}\": {s}. Ignoring.", .{ build_zig_zon_path_relative_to_root, @errorName(err) });
                allocator.free(build_zig_zon_path_relative_to_root);
                return .{
                    .root = root,
                    .build_zig = build_zig,
                    .build_zig_zon = null,
                };
            },
        };
        errdefer build_zig_zon.file.close();

        return .{
            .root = root,
            .build_zig = build_zig,
            .build_zig_zon = build_zig_zon,
        };
    }
};
