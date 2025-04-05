// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const BuildZigZon = @import("BuildZigZon.zig");
const Logger = @import("Logger.zig");
const ZigProcess = @import("ZigProcess.zig");

const location = @import("location.zig");
const setup = @import("setup.zig");

const Dependencies = @This();
pub const Package = @import("Dependencies/Package.zig");
pub const FetchMode = enum { none, plain, hashed };

/// Value of `name` field in `build.zig.zon`,
/// or empty if no `build.zig.zon`.
root_package_name: []const u8,

/// Value of `version` field in `build.zig.zon`,
/// or empty if no `build.zig.zon`.
root_package_version: []const u8,

/// Sorted alphabetically. Can contain only remote URIs.
packages: []const Package,

pub const empty: Dependencies = .{
    .root_package_name = "",
    .root_package_version = "",
    .packages = &[0]Package{},
};

pub fn deinit(self: Dependencies, allocator: std.mem.Allocator) void {
    allocator.free(self.root_package_name);
    allocator.free(self.root_package_version);
}

pub fn collect(
    /// All data allocated by this allocator is saved.
    gpa: std.mem.Allocator,
    /// All data allocated by this allocator should be cleaned by caller.
    arena: std.mem.Allocator,
    //
    project_setup: setup.Project,
    project_build_zig_zon_struct: BuildZigZon,
    generator_setup: setup.Generator,
    file_events: Logger,
    fetch_mode: FetchMode,
    zig_process: ZigProcess,
) !Dependencies {
    // Key is `hash`, used to detect duplicates and existing entries.
    var packages: std.StringArrayHashMapUnmanaged(Package) = .empty;
    //defer packages.deinit(arena);

    var fifo: std.fifo.LinearFifo(struct { location.Dir, BuildZigZon }, .Dynamic) = .init(arena);
    defer fifo.deinit();
    try fifo.writeItem(.{ project_setup.root, project_build_zig_zon_struct });

    var is_project_root = true;
    while (fifo.readItem()) |pair| {
        var cwd, const build_zig_zon_struct = pair;
        defer {
            if (is_project_root == false) cwd.deinit(arena);
            is_project_root = false;
        }

        file_events.debug(@src(), "build_zig_zon_struct: {any}", .{std.json.fmt(build_zig_zon_struct, .{ .whitespace = .indent_2 })});

        const dependencies = build_zig_zon_struct.dependencies orelse continue;

        var all_paths: std.ArrayListUnmanaged(struct {
            name: []const u8,
            storage: union(enum) {
                remote: struct { hash: []const u8, uri: std.Uri },
                local: []const u8,
            },
        }) = try .initCapacity(arena, dependencies.map.count());
        defer all_paths.deinit(arena);

        var fetchable: struct {
            start: ?usize = null,
            count: usize = 0,
        } = .{};
        for (dependencies.map.values(), 0..) |resource, i| switch (resource.storage) {
            .local => continue,
            .remote => {
                if (fetchable.start == null)
                    fetchable.start = i;

                fetchable.count += 1;
            },
        };

        for (dependencies.map.keys(), dependencies.map.values(), 1..) |key, resource, i| {
            switch (fetch_mode) {
                .none => @panic("unreachable"),
                .hashed, .plain => {},
            }

            switch (resource.storage) {
                .remote => |remote| {
                    file_events.info(@src(), "Fetching \"{s}\" [{d}/{d}]...", .{ key, i - fetchable.start.?, fetchable.count });

                    const uri = std.Uri.parse(remote.url) catch |err| {
                        file_events.err(@src(), "Invalid URI: \"{s}\": {s}.", .{ remote.url, @errorName(err) });
                        return error.InvalidUri;
                    };

                    const result_of_fetch = try zig_process.fetch(
                        arena,
                        cwd,
                        .{
                            .storage_loc = generator_setup.dependencies_storage,
                            .resource = resource,
                            .fetch_mode = fetch_mode,
                        },
                        file_events,
                    );
                    defer {
                        arena.free(result_of_fetch.stderr);
                    }

                    if (result_of_fetch.stderr.len != 0) {
                        file_events.err(@src(), "Error when fetching dependency \"{s}\". Details are in DEBUG.", .{key});
                        file_events.debug(@src(), "{s}", .{result_of_fetch.stderr});
                        return error.FetchFailed;
                    }

                    all_paths.appendAssumeCapacity(.{
                        .name = key,
                        .storage = .{
                            .remote = .{
                                .uri = uri,
                                .hash = std.mem.trim(u8, result_of_fetch.stdout, &std.ascii.whitespace),
                            },
                        },
                    });
                },
                .local => |local| all_paths.appendAssumeCapacity(.{
                    .name = key,
                    .storage = .{
                        .local = local.path,
                    },
                }),
            }
        }

        for (all_paths.items) |item| {
            var package_loc = switch (item.storage) {
                .local => |sub_path| try cwd.openDir(arena, sub_path),
                .remote => |remote| try generator_setup.packages.openDir(arena, remote.hash),
            };
            errdefer package_loc.deinit(arena);

            file_events.debug(@src(), "searching {s}...", .{package_loc.string});

            const next_build_zig_zon_struct: BuildZigZon = zon: {
                const package_build_zig_zon_loc = package_loc.openFile(arena, "build.zig.zon") catch |err| switch (err) {
                    // It might be a plain package, without build.zig.zon
                    error.FileNotFound => break :zon .{
                        .name = "", // replaced later when needed.
                        .dependencies = null,
                        // After that, all is ignored RN.
                        .version = .{ .major = 0, .minor = 0, .patch = 0 },
                        .version_raw = "",
                        .minimum_zig_version = null,
                        .minimum_zig_version_raw = null,
                        .paths = &.{""},
                    },
                    else => |e| return e,
                };
                defer package_build_zig_zon_loc.deinit(arena);

                const next_file_events = try file_events.child(item.name);
                defer next_file_events.deinit();

                break :zon try .read(arena, zig_process.version, package_build_zig_zon_loc, next_file_events);
            };

            try fifo.writeItem(.{ package_loc, next_build_zig_zon_struct });
            switch (item.storage) {
                .local => continue,
                .remote => |remote| {
                    const dep_name = if (next_build_zig_zon_struct.name.len > 0)
                        next_build_zig_zon_struct.name
                    else
                        null;

                    const dep_events = try file_events.child(dep_name orelse "pristine package");
                    defer dep_events.deinit();

                    const new_package: Package = try .init(
                        arena,
                        .{
                            .name = dep_name,
                            .hash = remote.hash,
                            .uri = remote.uri,
                        },
                        dep_events,
                    );

                    const gop = try packages.getOrPut(arena, new_package.hash);
                    if (gop.found_existing == false) {
                        gop.value_ptr.* = new_package;
                    } else {
                        const existing_package = gop.value_ptr.*;
                        gop.value_ptr.* = try Package.choose_best(arena, existing_package, new_package, dep_events) orelse new: {
                            dep_events.warn(@src(), "Report warning below to zig-ebuilder upstream:", .{});
                            dep_events.warn(@src(), "Found duplicate and can't decide between two. Replacing.", .{});
                            break :new new_package;
                        };
                    }
                },
            }
        }
    }
    file_events.info(@src(), "Packages count: {d}", .{packages.count()});

    // Mutate `packages` in-place to transform Git commits to
    // tarballs where possible (and algorithm is known).
    for (packages.values()) |*dep| {
        switch (dep.kind) {
            .tarball => continue,
            .git_ref => {},
        }

        const dep_events = try file_events.child(dep.name orelse "pristine package");
        defer dep_events.deinit();

        try dep.transform_git_commit_to_tarball(arena, dep_events);
    }

    // Sort:
    // * alphabetically,
    // * "pristine packages" to the end, ordered inside by hash.
    const Sort = struct {
        values: []const Package,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            const a = ctx.values[a_index];
            const b = ctx.values[b_index];

            if (a.name == null and b.name == null) return switch (std.mem.order(u8, a.hash, b.hash)) {
                .lt => true, // leave intact
                .eq => false, // order does not matter
                .gt => false, // swap
            };
            if (a.name == null and b.name != null) return false; // swap
            if (a.name != null and b.name == null) return true; // leave intact

            return switch (std.mem.order(u8, a.name.?, b.name.?)) {
                .lt => true, // leave intact
                .eq => false, // order does not matter
                .gt => false, // swap
            };
        }
    };
    packages.sort(Sort{ .values = packages.values() });

    return .{
        .root_package_name = try gpa.dupe(u8, project_build_zig_zon_struct.name),
        .root_package_version = try gpa.dupe(u8, project_build_zig_zon_struct.version_raw),
        .packages = packages.values(),
    };
}

// Tarball-tarball creation logic below.

fn pack_directory_to_tar_gz(
    arena: std.mem.Allocator,
    directory: std.fs.Dir,
    compression_level: std.compress.flate.deflate.Level,
) ![]u8 {
    const tar = tar: {
        var memory: std.ArrayListUnmanaged(u8) = .empty;
        const memory_writer = memory.writer(arena).any();

        var tar = std.tar.writer(memory_writer);
        {
            var walker = try directory.walk(arena);
            defer walker.deinit();
            while (try walker.next()) |entry|
                try tar.writeEntry(entry);
            try tar.finish();
        }

        break :tar memory.items;
    };
    var tar_fbs = std.io.fixedBufferStream(tar);
    const tar_reader = tar_fbs.reader();

    const tar_gz = tar_gz: {
        var memory: std.ArrayListUnmanaged(u8) = .empty;
        const memory_writer = memory.writer(arena);

        try std.compress.gzip.compress(tar_reader, memory_writer, .{ .level = compression_level });
        break :tar_gz memory.items;
    };

    return tar_gz;
}

/// Resulting tarball has following structure:
/// <written to the writer>:
/// * dependency_1-hash.tar.gz
/// * dependency_2-hash.tar.gz
pub fn pack_git_commits_to_tarball_tarball(
    arena: std.mem.Allocator,
    zig_version: ZigProcess.Version,
    packages: []const Package,
    packages_loc: location.Dir,
    writer: anytype,
    events: Logger,
) !void {
    // TODO maybe play with more compression, or make it configurable?
    const compression_level: std.compress.flate.deflate.Level = .default;

    var memory: std.ArrayListUnmanaged(u8) = .empty;
    const memory_writer = memory.writer(arena).any();
    var tar = std.tar.writer(memory_writer);
    tar.mtime_now = 1; // For consistent hashing IIRC.

    const new_package_hash_format = zig_version.newPackageFormat();

    for (packages) |package| {
        switch (package.kind) {
            .tarball => continue,
            .git_ref => {},
        }

        var package_dir = try packages_loc.dir.openDir(package.hash, .{ .iterate = true });
        defer package_dir.close();

        const file_name = try if (new_package_hash_format)
            std.fmt.allocPrint(arena, "{s}.tar.gz", .{package.hash})
        else
            std.fmt.allocPrint(arena, "{s}-{s}.tar.gz", .{ package.name orelse "pristine_package", package.hash });

        events.warn(@src(), "Packing {s} ...", .{file_name});
        const file_content_in_memory = try pack_directory_to_tar_gz(arena, package_dir, compression_level);

        try tar.writeFileBytes(file_name, file_content_in_memory, .{});
    }
    try tar.finish();

    var tar_fbs = std.io.fixedBufferStream(memory.items);
    const tar_reader = tar_fbs.reader();
    events.warn(@src(), "Compressing all into tarball-tarball...", .{});
    try std.compress.gzip.compress(tar_reader, writer, .{ .level = compression_level });
}
