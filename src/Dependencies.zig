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

/// Value of `name` field in `build.zig.zon` .
root_package_name: []const u8,

/// URLs that are successfully parsed or translated to tarball URLs.
tarball: []const VendorUri,
/// URLs that are needed to be packaged by maintainer themselves.
git_commit: []const GitCommitDep,

pub const empty: Dependencies = .{
    .root_package_name = &[0]u8{},
    .tarball = &[0]VendorUri{},
    .git_commit = &[0]GitCommitDep{},
};

pub fn deinit(self: Dependencies, allocator: std.mem.Allocator) void {
    allocator.free(self.root_package_name);
    for (self.tarball) |tarball| {
        allocator.free(tarball.name);
        allocator.free(tarball.url);
    }
    allocator.free(self.tarball);

    for (self.git_commit) |git_commit| {
        allocator.free(git_commit.hash);
        allocator.free(git_commit.name);
    }
    allocator.free(self.git_commit);
}

pub const FetchMode = enum { skip, plain, hashed };

pub fn createGitCommitDependenciesTarball(
    arena: std.mem.Allocator,
    git_commits: []const GitCommitDep,
    packages_loc: location.Dir,
    writer: anytype,
) !void {
    var full_tar_content: std.ArrayListUnmanaged(u8) = .empty;
    defer full_tar_content.deinit(arena);
    var full_tar = std.tar.writer(full_tar_content.writer(arena).any());
    full_tar.mtime_now = 1;

    for (git_commits) |git_commit_dependency| {
        const archive_file_name = try git_commit_dependency.toFileName(arena);
        defer arena.free(archive_file_name);

        const uncompressed_content = uncompressed_content: {
            var tar_content: std.ArrayListUnmanaged(u8) = .empty;
            errdefer tar_content.deinit(arena);
            const tar_content_writer = tar_content.writer(arena).any();

            var tar = std.tar.writer(tar_content_writer);

            var iterate_dir = try packages_loc.dir.openDir(git_commit_dependency.hash, .{ .iterate = true });
            defer iterate_dir.close();

            var walker = try iterate_dir.walk(arena);
            defer walker.deinit();
            while (try walker.next()) |entry| {
                try tar.writeEntry(entry);
            }
            try tar.finish();

            break :uncompressed_content try tar_content.toOwnedSlice(arena);
        };
        defer arena.free(uncompressed_content);

        const compressed_content = compressed_content: {
            var tar_gz_content: std.ArrayListUnmanaged(u8) = .empty;
            errdefer tar_gz_content.deinit(arena);

            var uncompressed_content_fbs = std.io.fixedBufferStream(uncompressed_content);
            const uncompressed_content_reader = uncompressed_content_fbs.reader();

            try std.compress.gzip.compress(uncompressed_content_reader, tar_gz_content.writer(arena), .{ .level = .default });
            break :compressed_content try tar_gz_content.toOwnedSlice(arena);
        };
        defer arena.free(compressed_content);

        try full_tar.writeFileBytes(archive_file_name, compressed_content, .{});
    }
    try full_tar.finish();

    var tar_reader_fbs = std.io.fixedBufferStream(full_tar_content.items);
    try std.compress.gzip.compress(tar_reader_fbs.reader(), writer, .{ .level = .default });
}

const VendorUri = struct {
    name: []const u8,
    /// TODO: many urls? mirrors?
    url: []const u8,
};

const GitCommitDep = struct {
    name: []const u8,
    hash: []const u8,

    fn toFileName(self: GitCommitDep, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}-{s}.{s}", .{ self.name, self.hash, @tagName(FileType.@"tar.gz") });
    }
};

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
    // Keyed by `hash`
    var vendor_urls_map: std.StringArrayHashMapUnmanaged(VendorUri) = .empty;
    defer vendor_urls_map.deinit(arena);

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
                remote: struct { url: []const u8, hash: []const u8 },
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
                .skip => @panic("unreachable"),
                .hashed, .plain => {},
            }

            switch (resource.storage) {
                .remote => |remote| {
                    file_events.info(@src(), "Fetching \"{s}\" [{d}/{d}]...", .{ key, i - fetchable.start.?, fetchable.count });

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
                                .url = remote.url,
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

            var next_build_zig_zon_struct: BuildZigZon = zon: {
                const package_build_zig_zon_loc = package_loc.openFile(arena, "build.zig.zon") catch |err| switch (err) {
                    // It might be a plain package, without build.zig.zon
                    error.FileNotFound => break :zon .{
                        .name = "", // replaced below
                        // After that, all is ignored RN.
                        .version = .{ .major = 0, .minor = 0, .patch = 0 },
                        .version_raw = "",
                        .minimum_zig_version = null,
                        .minimum_zig_version_raw = null,
                        .dependencies = null,
                        .paths = &.{""},
                    },
                    else => |e| return e,
                };
                defer package_build_zig_zon_loc.deinit(arena);

                const next_file_events = try file_events.child(item.name);
                defer next_file_events.deinit();

                break :zon try .read(arena, zig_process.version, package_build_zig_zon_loc, next_file_events);
            };
            if (next_build_zig_zon_struct.name.len == 0)
                next_build_zig_zon_struct.name = item.name;

            try fifo.writeItem(.{ package_loc, next_build_zig_zon_struct });
            switch (item.storage) {
                .local => continue,
                .remote => |remote| {
                    const new: VendorUri = .{
                        .name = next_build_zig_zon_struct.name,
                        .url = remote.url,
                    };

                    const result = try vendor_urls_map.getOrPut(arena, remote.hash);
                    result.value_ptr.* = if (result.found_existing == false) new else resolve_conflict: {
                        const old = result.value_ptr.*;
                        switch (std.mem.eql(u8, old.url, new.url)) {
                            true => {
                                // TODO maybe also compare names?
                                file_events.warn(@src(), "Found 2 package variants with identical URLs. Ignoring names, leaving old. Old name: {s}, new name: {s}, URL: {s}", .{ old.name, new.name, old.url });
                                break :resolve_conflict old;
                            },
                            else => {
                                const old_uri = std.Uri.parse(old.url) catch |err| {
                                    file_events.err(@src(), "Invalid URI \"{s}\": {s}", .{ old.url, @errorName(err) });
                                    return error.InvalidBuildZigZon;
                                };
                                const new_uri = std.Uri.parse(new.url) catch |err| {
                                    file_events.err(@src(), "Invalid URI \"{s}\": {s}", .{ new.url, @errorName(err) });
                                    return error.InvalidBuildZigZon;
                                };

                                if ((std.ascii.eqlIgnoreCase(old_uri.scheme, "https") or
                                    std.ascii.eqlIgnoreCase(old_uri.scheme, "http")) and
                                    (std.ascii.eqlIgnoreCase(new_uri.scheme, "git+https") or
                                        std.ascii.eqlIgnoreCase(new_uri.scheme, "git+http")))
                                {
                                    file_events.warn(@src(), "Found 2 package variants with different URIs: tarball and Git commit. Leaving tarball. Tarball variant: {any}, commit variant: {any}", .{
                                        std.json.fmt(old, .{ .whitespace = .indent_2 }),
                                        std.json.fmt(new, .{ .whitespace = .indent_2 }),
                                    });
                                    break :resolve_conflict old;
                                } else if ((std.ascii.eqlIgnoreCase(old_uri.scheme, "git+https") or
                                    std.ascii.eqlIgnoreCase(old_uri.scheme, "git+http")) and
                                    (std.ascii.eqlIgnoreCase(new_uri.scheme, "https") or
                                        std.ascii.eqlIgnoreCase(new_uri.scheme, "http")))
                                {
                                    file_events.warn(@src(), "Found 2 package variants with different URIs: Git commit and tarball. Changing to tarball. Commit variant: {any}, tarball variant: {any}", .{
                                        std.json.fmt(old, .{ .whitespace = .indent_2 }),
                                        std.json.fmt(new, .{ .whitespace = .indent_2 }),
                                    });
                                    break :resolve_conflict new;
                                } else {
                                    service_map: {
                                        const old_host = try old_uri.host.?.toRawMaybeAlloc(arena);
                                        const new_host = try new_uri.host.?.toRawMaybeAlloc(arena);
                                        const old_service = Service.fromHost.get(old_host) orelse break :service_map;
                                        const new_service = Service.fromHost.get(new_host) orelse break :service_map;

                                        if (old_service == .github and new_service == .mach) {
                                            file_events.warn(@src(), "Found 2 package variants with different services: GitHub and Hexops mirror. Changing to Hexops mirror. GitHub variant: {any}, Hexops variant: {any}", .{
                                                std.json.fmt(old, .{ .whitespace = .indent_2 }),
                                                std.json.fmt(new, .{ .whitespace = .indent_2 }),
                                            });
                                            break :resolve_conflict new;
                                        } else if (old_service == .mach and new_service == .github) {
                                            file_events.warn(@src(), "Found 2 package variants with different services: Hexops mirror and GitHub. Leaving Hexops mirror. Hexops variant: {any}, GitHub variant: {any}", .{
                                                std.json.fmt(old, .{ .whitespace = .indent_2 }),
                                                std.json.fmt(new, .{ .whitespace = .indent_2 }),
                                            });
                                            break :resolve_conflict old;
                                        }
                                    }

                                    std.debug.panic("TODO (please report to upstream of zig-ebuilder): resolve conflict: existing: {any}, new: {any}", .{
                                        std.json.fmt(old, .{ .whitespace = .indent_2 }),
                                        std.json.fmt(new, .{ .whitespace = .indent_2 }),
                                    });
                                }
                            },
                        }
                    };
                },
            }
        }
    }

    file_events.info(@src(), "Vendor URLs count: {d}", .{vendor_urls_map.count()});

    const Sort = struct {
        keys: []VendorUri,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return switch (std.mem.order(u8, ctx.keys[a_index].name, ctx.keys[b_index].name)) {
                .lt => true,
                .eq => false,
                .gt => false,
            };
        }
    };

    vendor_urls_map.sort(Sort{ .keys = vendor_urls_map.values() });

    var array: std.ArrayListUnmanaged(VendorUri) = try .initCapacity(gpa, vendor_urls_map.count());
    errdefer array.deinit(gpa);

    var packaging_needed: std.ArrayListUnmanaged(GitCommitDep) = try .initCapacity(gpa, vendor_urls_map.count());
    errdefer packaging_needed.deinit(gpa);

    for (vendor_urls_map.keys(), vendor_urls_map.values()) |hash, dep| {
        const uri = std.Uri.parse(dep.url) catch @panic("unreachable (report to upstream of zig-ebuilder)");

        var name: std.ArrayListUnmanaged(u8) = .empty;
        defer name.deinit(gpa);
        var url: std.ArrayListUnmanaged(u8) = .empty;
        defer url.deinit(gpa);

        const name_writer = name.writer(gpa);
        const url_writer = url.writer(gpa);

        // Print everything 'raw' so that Mustache template
        // can percent-encode it by itself.
        const ext: FileType = if (std.ascii.eqlIgnoreCase(uri.scheme, "git+https") or std.ascii.eqlIgnoreCase(uri.scheme, "git+http")) git: {
            // Assuming it is a commit. If "zig fetch" was called by author:
            // * with "--save" option: tags are rewritten as commits,
            // * with "--save-exact" option: tags are not rewritten.
            const commit = uri.fragment orelse @panic("TODO: what to do with exact-saved mutable data (like git+https://...#<tag>)? They should really point to immutable data (like what zig fetch --save would do here, using \"?ref=<tag>#commit\") but IDK how to message it to the authors...");
            const host = try uri.host.?.toRawMaybeAlloc(arena);
            const service = Service.fromHost.get(host) orelse {
                packaging_needed.appendAssumeCapacity(.{
                    .name = try GitCommitDep.toFileName(.{ .name = dep.name, .hash = hash }, gpa),
                    .hash = try gpa.dupe(u8, hash),
                });
                continue;
            };

            var repository = try uri.path.toRawMaybeAlloc(arena);
            std.debug.assert(std.mem.startsWith(u8, repository, "/"));
            switch (service) {
                .codeberg, .github, .sourcehut, .gitlab => if (std.mem.endsWith(u8, repository, ".git")) {
                    repository = repository[0 .. repository.len - ".git".len];
                },
                .mach => @panic("unreachable: Hexops do not mirror Git repositories"),
            }

            switch (service) {
                .codeberg, .github, .sourcehut => |s| {
                    try url_writer.print("{s}{s}/archive/{raw}.tar.gz", .{ s.toUrl(), repository, commit });
                    break :git .@"tar.gz";
                },
                .gitlab => |s| {
                    // TODO: Change to ".tar.bz2" when/if `zig fetch` start to support it.
                    try url_writer.print("{s}{s}/-/archive/{raw}.tar.gz", .{ s.toUrl(), repository, commit });
                    break :git .@"tar.gz";
                },
                .mach => @panic("unreachable: Hexops do not mirror Git repositories"),
            }
        }
            // If not a commit, then tarball.
            else tarball: {
                try url_writer.print("{s}", .{dep.url});
                break :tarball FileType.fromPath(dep.url) orelse std.debug.panic("Unknown tarball extension for: {s}", .{dep.url});
            };

        if (zig_process.version.kind == .live)
            // Hash already includes name (if applicable) on 0.14.
            try name_writer.print("{s}.{s}", .{ hash, @tagName(ext) })
        else
            try name_writer.print("{s}-{s}.{s}", .{ dep.name, hash, @tagName(ext) });

        array.appendAssumeCapacity(.{
            .name = try name.toOwnedSlice(gpa),
            .url = try url.toOwnedSlice(gpa),
        });
    }

    return .{
        .root_package_name = try gpa.dupe(u8, project_build_zig_zon_struct.name),
        .tarball = try array.toOwnedSlice(gpa),
        .git_commit = try packaging_needed.toOwnedSlice(gpa),
    };
}

/// Known services with relatively stable links to archives or
/// source code.
const Service = enum {
    /// Codeberg.
    codeberg,
    /// GitHub main instance (not Enterprise).
    github,
    /// GitLab official instance.
    gitlab,
    /// Hexops mirror for Zig releases and Mach projects.
    mach,
    /// SourceHut Git instance.
    sourcehut,

    /// Base URL, without trailing slash,
    /// stripped of "www." etc. prefix if possible,
    /// and prefers "https" over "http" if possible.
    fn toUrl(self: Service) []const u8 {
        return switch (self) {
            .codeberg => "https://codeberg.org",
            .github => "https://github.com",
            .gitlab => "https://gitlab.com",
            .mach => "https://pkg.machengine.org",
            .sourcehut => "https://git.sr.ht",
        };
    }

    const fromHost: std.StaticStringMap(Service) = .initComptime(.{
        .{ "codeberg.org", .codeberg },
        .{ "www.codeberg.org", .codeberg },

        .{ "github.com", .github },
        .{ "www.github.com", .github },

        .{ "gitlab.com", .gitlab },
        .{ "www.gitlab.com", .gitlab },

        // As of 2024 no "www." variant or redirect:
        .{ "pkg.machengine.org", .mach },

        // As of 2024 no "www." variant or redirect:
        .{ "git.sr.ht", .sourcehut },
    });
};

// Copied from Zig compiler sources ("src/package/Fetch.zig"
// as for upstream commit ea527f7a850f0200681630d8f36131eca31ef48b).
// SPDX-SnippetBegin
// SPDX-SnippetCopyrightText: Zig contributors
// SPDX-License-Identifier: MIT
const FileType = enum {
    tar,
    @"tar.gz",
    @"tar.bz2",
    @"tar.xz",
    @"tar.zst",
    git_pack,
    zip,

    fn fromPath(file_path: []const u8) ?@This() {
        const ascii = std.ascii;
        if (ascii.endsWithIgnoreCase(file_path, ".tar")) return .tar;
        // TODO enable when/if `zig fetch` starts to support it.
        // if (ascii.endsWithIgnoreCase(file_path, ".tar.bz2")) return .@"tar.bz2";
        if (ascii.endsWithIgnoreCase(file_path, ".tgz")) return .@"tar.gz";
        if (ascii.endsWithIgnoreCase(file_path, ".tar.gz")) return .@"tar.gz";
        if (ascii.endsWithIgnoreCase(file_path, ".txz")) return .@"tar.xz";
        if (ascii.endsWithIgnoreCase(file_path, ".tar.xz")) return .@"tar.xz";
        if (ascii.endsWithIgnoreCase(file_path, ".tzst")) return .@"tar.zst";
        if (ascii.endsWithIgnoreCase(file_path, ".tar.zst")) return .@"tar.zst";
        if (ascii.endsWithIgnoreCase(file_path, ".zip")) return .zip;
        return null;
    }
};
// SPDX-SnippetEnd
