// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");
const ztl = @import("ztl");

const BuildZigZon = @import("BuildZigZon.zig");
const Dependencies = @import("Dependencies.zig");
const Logger = @import("Logger.zig");
const Report = @import("Report");
const Timestamp = @import("Timestamp.zig");
const ZigProcess = @import("ZigProcess.zig");

const location = @import("location.zig");
const reporter = @import("reporter.zig");
const setup = @import("setup.zig");

const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

fn printHelp(writer: std.io.AnyWriter) void {
    writer.print(
        \\zig-ebuilder {[version]}
        \\System package managers specification generator for Zig projects.
        \\
        \\USAGE:
        \\    {[prog_name]s} [OPTIONS] [path-to-project]
        \\
        \\ARGUMENTS:
        \\    [path-to-project]             build.zig file, or directory containing it
        \\                                  (default: current directory)
        \\
        \\GENERATOR OPTIONS:
        \\    --fetch <strategy>            Dependency resolution strategy (default: plain)
        \\                                  (possible values: none, plain, hashed)
        \\    --template <template>         Specify ZTL template to use (default: gentoo.ebuild)
        \\                                  (possible values: gentoo.ebuild, [custom file path])
        \\
        \\ZIG OPTIONS:
        \\    --zig <path-to-exe>           Path to Zig executable (default: get from PATH)
        \\    --zig-build-args <args>...    Additional arguments for "zig build"
        \\
        \\LOGGING OPTIONS:
        \\    --log-level <level>           Minimum logging level (default: info)
        \\                                  (possible values: err, warn, info, debug)
        \\    --log-time-format <format>    Show time in this format (default: none)
        \\                                  (possible values: none, time, day_time)
        \\    --log-color <when>            Color output mode (default: auto)
        \\                                  (possible values: auto, always, never)
        \\    --log-src-location <when>     Show source location (default: never)
        \\                                  (possible values: always, never)
        \\
        \\GENERAL OPTIONS:
        \\    --help                        Display this help and exit
        \\
        \\NOTES:
        \\ * If "build.zig.zon" file exist, dependencies will be
        \\ resolved from it according to the `--fetch` strategy.
        \\ * 'hashed' fetch strategy needs Zig patching, see README for more info.
        \\
    , .{ .version = version, .prog_name = global.prog_name }) catch {};
}

var global: struct {
    prog_name: [:0]const u8,
    zig_executable: [:0]const u8,
    fetch_mode: Dependencies.FetchMode,
} = .{
    .prog_name = "(name not provided)",
    .zig_executable = "zig",
    .fetch_mode = .plain,
};

pub fn main() !void {
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .enable_memory_limit = true,
        .thread_safe = true,
    }) = .init;
    defer switch (gpa_instance.deinit()) {
        .ok => {},
        .leak => @panic("Memory leak detected!"),
    };
    const gpa = gpa_instance.allocator();

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();
    // For consistent output of "reuse lint" and "reuse spdx"
    try env_map.put("LC_ALL", "en_US.UTF-8");

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    if (args.next()) |name| global.prog_name = name;

    const stdout_file = std.io.getStdOut();
    const stderr_file = std.io.getStdErr();
    const stdout = stdout_file.writer().any();
    const stderr = stderr_file.writer().any();

    var zig_build_additional_args: [][:0]const u8 = &.{};
    defer gpa.free(zig_build_additional_args);

    var optional_custom_template_path: ?[:0]const u8 = null;
    var file_name: ?[:0]const u8 = null;
    while (args.next()) |arg| {
        // Generator options.
        if (std.mem.eql(u8, arg, "--fetch")) {
            const value = args.next() orelse {
                stderr.writeAll("Missing value for --fetch option\n") catch {};
                return;
            };
            const fetch_strategy = std.meta.stringToEnum(Dependencies.FetchMode, value) orelse {
                stderr.print("Invalid fetch strategy '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: none, plain, hashed\n") catch {};
                return;
            };
            global.fetch_mode = fetch_strategy;
        } else if (std.mem.eql(u8, arg, "--template")) {
            const value = args.next() orelse {
                stderr.writeAll("Missing value for --template option\n") catch {};
                return;
            };

            if (std.mem.eql(u8, value, "gentoo.ebuild")) {
                // TODO change this when other distros are added.
                optional_custom_template_path = null;
            } else if (value.len > 0) {
                optional_custom_template_path = value;
            } else {
                stderr.print("Invalid template '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: gentoo.ebuild, or provide non-empty path\n") catch {};
            }
        }
        // Zig options.
        else if (std.mem.eql(u8, arg, "--zig")) {
            const value = args.next() orelse {
                stderr.writeAll("Missing value for --zig option\n") catch {};
                return;
            };
            global.zig_executable = if (value.len != 0) value else {
                stderr.writeAll("Expected non-empty path after --zig option\n") catch {};
                return;
            };
        } else if (std.mem.eql(u8, arg, "--zig-build-args")) {
            var additional_args: std.ArrayListUnmanaged([:0]const u8) = .empty;
            errdefer additional_args.deinit(gpa);
            while (args.next()) |zig_build_arg| {
                try additional_args.append(gpa, zig_build_arg);
            }
            if (additional_args.items.len == 0) {
                stderr.print("Expected following args after \"{s}\"\n", .{arg}) catch {};
                return;
            }
            zig_build_additional_args = try additional_args.toOwnedSlice(gpa);
        }
        // Logging options.
        else if (std.mem.eql(u8, arg, "--log-level")) {
            const value = args.next() orelse {
                stderr.writeAll("Missing value for --log-level option\n") catch {};
                return;
            };
            const level = std.meta.stringToEnum(@FieldType(Logger.Format, "level"), value) orelse {
                stderr.print("Invalid log level '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: err, warn, info, debug\n") catch {};
                return;
            };
            Logger.global_format.level = level;
        } else if (std.mem.eql(u8, arg, "--log-time-format")) {
            const value = args.next() orelse {
                stderr.writeAll("Missing value for --log-time-format option\n") catch {};
                return;
            };
            const time_format = std.meta.stringToEnum(@FieldType(Logger.Format, "time_format"), value) orelse {
                stderr.print("Invalid log time format '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: none, time, day_time\n") catch {};
                return;
            };
            Logger.global_format.time_format = time_format;
        } else if (std.mem.eql(u8, arg, "--log-color")) {
            const value = args.next() orelse {
                stderr.writeAll("Missing value for --log-color option\n") catch {};
                return;
            };
            const color = std.meta.stringToEnum(@FieldType(Logger.Format, "color"), value) orelse {
                stderr.print("Invalid log color mode '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: auto, always, never\n") catch {};
                return;
            };
            Logger.global_format.color = color;
        } else if (std.mem.eql(u8, arg, "--log-src-location")) {
            const value = args.next() orelse {
                stderr.writeAll("Missing value for --log-src-location option\n") catch {};
                return;
            };
            const src_location = std.meta.stringToEnum(@FieldType(Logger.Format, "src_location"), value) orelse {
                stderr.print("Invalid log source location mode '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: always, never\n") catch {};
                return;
            };
            Logger.global_format.src_location = src_location;
        }
        // General options.
        else if (std.mem.eql(u8, arg, "--help")) {
            printHelp(stdout);
            return;
        } else {
            if (file_name) |previous_path| {
                stderr.print("More than 1 projects specified at the same time: \"{s}\" and \"{s}\".", .{ previous_path, arg }) catch {};
                return;
            }
            file_name = arg;
        }
    }

    var main_log: Logger = .{
        .shared = &.{ .scretch_pad = gpa },
        .scopes = &.{},
    };

    main_log.info(@src(), "Starting {s} {}", .{ global.prog_name, version });

    var file_events = try main_log.child("file");
    defer file_events.deinit();
    var file_searching_events = try file_events.child("searching");
    defer file_searching_events.deinit();

    const cwd: location.Dir = .cwd();

    const initial_file_path: []const u8 = if (file_name) |path| blk: {
        const stat = cwd.dir.statFile(path) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    file_searching_events.err(@src(), "File or directory \"{s}\" not found.", .{path});
                },
                else => |e| {
                    file_searching_events.err(@src(), "Error when checking type of \"{s}\": {s}.", .{ path, @errorName(e) });
                },
            }
            return err;
        };

        switch (stat.kind) {
            .file => {
                file_searching_events.info(@src(), "\"{s}\" is a file, trying to open it...", .{path});
                break :blk try gpa.dupe(u8, path);
            },
            .directory => {
                file_searching_events.info(@src(), "\"{s}\" is a directory, trying to find \"build.zig\" file inside...", .{path});
                break :blk try std.fs.path.join(gpa, &.{ path, "build.zig" });
            },
            .sym_link => {
                file_searching_events.err(@src(), "Can't resolve symlink \"{s}\".", .{path});
                return error.FileNotFound;
            },
            //
            .block_device,
            .character_device,
            .named_pipe,
            .unix_domain_socket,
            .whiteout,
            .door,
            .event_port,
            .unknown,
            => |tag| {
                file_searching_events.err(@src(), "\"{s}\" is not a file or directory, but instead it's \"{s}\".", .{ path, @tagName(tag) });
                return error.FileNotFound;
            },
        }
    } else cwd: {
        file_searching_events.info(@src(), "No location given, trying to open \"build.zig\" in current directory...", .{});
        break :cwd try gpa.dupe(u8, "build.zig");
    };
    defer gpa.free(initial_file_path);

    var project_setup: setup.Project = try .open(
        cwd,
        initial_file_path,
        gpa,
        file_searching_events,
    );
    defer project_setup.deinit(gpa);

    file_searching_events.info(@src(), "Successfully found \"build.zig\" file!", .{});

    const zig_process = try ZigProcess.init(gpa, cwd, global.zig_executable, &env_map, main_log);
    defer gpa.free(zig_process.version.raw_string);

    var generator_setup: setup.Generator = try .makeOpen(cwd, env_map, gpa, main_log);
    defer generator_setup.deinit(gpa);

    const template_text = if (optional_custom_template_path) |custom_template_path|
        cwd.dir.readFileAlloc(gpa, custom_template_path, 1 * 1024 * 1024) catch |err| {
            file_searching_events.err(@src(), "Error when searching custom template: {s} caused by \"{s}\".", .{ @errorName(err), custom_template_path });

            return error.InvalidTemplate;
        }
    else
        generator_setup.templates.dir.readFileAlloc(gpa, "gentoo.ebuild.ztl", 1 * 1024 * 1024) catch |err| {
            file_searching_events.err(@src(), "Error when searching default \"gentoo\" template: \"{s}\".", .{@errorName(err)});

            return error.InvalidTemplate;
        };
    defer gpa.free(template_text);

    var template: ztl.Template(void) = .init(gpa, {});
    defer template.deinit();

    var template_errors: ztl.CompileErrorReport = .{};
    template.compile(template_text, .{ .error_report = &template_errors }) catch |err| {
        file_searching_events.err(@src(), "Error when loading file: {s} caused by \"{s}\": {}", .{
            @errorName(err),
            if (optional_custom_template_path) |custom_template_path| custom_template_path else "(default template)",
            template_errors,
        });
        return error.InvalidTemplate;
    };

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const dependencies: Dependencies = if (global.fetch_mode != .none) fetch: {
        const build_zig_zon_loc = if (project_setup.build_zig_zon) |build_zig_zon| build_zig_zon else {
            file_searching_events.err(@src(), "\"build.zig.zon\" was not found. Skipping fetching.", .{});
            break :fetch .empty;
        };
        file_searching_events.info(@src(), "Found \"build.zig.zon\" file nearby, proceeding to fetch dependencies.", .{});

        const project_build_zig_zon_struct: BuildZigZon = try .read(arena, zig_process.version, build_zig_zon_loc, file_events);
        break :fetch try .collect(
            gpa,
            arena,
            //
            project_setup,
            project_build_zig_zon_struct,
            generator_setup,
            file_events,
            global.fetch_mode,
            zig_process,
        );
    } else .empty;
    defer dependencies.deinit(gpa);

    file_events.debug(
        @src(),
        "packages = {}",
        .{std.json.fmt(dependencies.packages, .{ .whitespace = .indent_4 })},
    );

    var git_commit_packages_count: usize = 0;
    for (dependencies.packages) |package| switch (package.kind) {
        .tarball => continue,
        .git_ref => git_commit_packages_count += 1,
    };

    const optional_tarball_tarball: ?[]const u8 = if (git_commit_packages_count > 0) path: {
        var archive_arena_instance: std.heap.ArenaAllocator = .init(gpa);
        const archive_arena = archive_arena_instance.allocator();
        defer archive_arena_instance.deinit();

        // Used for generated tarball-tarball name.
        const project_name = dependencies.root_package_name;
        const project_version = dependencies.root_package_version;

        const tarball_tarball_path = try std.fmt.allocPrint(
            archive_arena,
            "{s}-{s}-git_dependencies.tar.gz",
            .{ project_name, project_version },
        );

        main_log.warn(@src(), "Found dependencies that were not translated from Git commit to tarball format: {d} items. Packing them into one archive...", .{git_commit_packages_count});
        main_log.warn(@src(), "Packing them into one archive {s} ...", .{tarball_tarball_path});

        var tarballs_loc = try generator_setup.cache.makeOpenDir(archive_arena, "git_commit_tarballs");
        defer tarballs_loc.deinit(archive_arena);

        var memory: std.ArrayListUnmanaged(u8) = .empty;
        const memory_writer = memory.writer(archive_arena);

        try Dependencies.pack_git_commits_to_tarball_tarball(
            archive_arena,
            zig_process.version,
            dependencies.packages,
            generator_setup.packages,
            memory_writer,
            main_log,
        );

        main_log.warn(@src(), "Writing to disk...", .{});
        try tarballs_loc.dir.writeFile(.{
            .sub_path = tarball_tarball_path,
            .data = memory.items,
        });

        break :path try std.fs.path.join(arena, &.{ tarballs_loc.string, tarball_tarball_path });
    } else null;

    main_log.info(@src(), "Running \"zig build\" with custom build runner. Arguments are in DEBUG.", .{});
    const report: Report = try reporter.collect(
        gpa,
        //
        &env_map,
        generator_setup,
        main_log,
        zig_build_additional_args,
        project_setup,
        zig_process,
        arena,
    );

    const DownloadableDependency = struct {
        name: []const u8,
        url: []const u8,
        // with_args: []const []const []const u8,
    };

    const downloadable_dependencies = downloadable_dependencies: {
        var tarballs: std.ArrayListUnmanaged(DownloadableDependency) = try .initCapacity(arena, dependencies.packages.len);
        defer tarballs.deinit(arena);
        var git_commits: std.ArrayListUnmanaged(DownloadableDependency) = try .initCapacity(arena, dependencies.packages.len);
        defer git_commits.deinit(arena);

        const new_package_hash_format = zig_process.version.newPackageFormat();

        for (dependencies.packages) |package| {
            const used = if (report.used_dependencies_hashes) |used_hashes| check_hash: {
                for (used_hashes) |used_hash| {
                    if (std.mem.eql(u8, package.hash, used_hash))
                        break :check_hash true;
                } else break :check_hash false;
            } else true; // Not supported by 0.13
            // TODO need some mechanism for "zig.eclass" maybe?
            // so that we can make conditional deps here.
            // For now all dependencies are assumed as used.
            _ = used;

            switch (package.kind) {
                .tarball => |kind| {
                    // New package hash format in 0.14 already has name
                    const dependency_file_name = try if (new_package_hash_format)
                        std.fmt.allocPrint(
                            arena,
                            "{s}.{s}",
                            .{ package.hash, @tagName(kind) },
                        )
                    else
                        std.fmt.allocPrint(
                            arena,
                            "{s}-{s}.{s}",
                            .{ package.name orelse "pristine_package", package.hash, @tagName(kind) },
                        );

                    tarballs.appendAssumeCapacity(.{
                        .name = dependency_file_name,
                        .url = try std.fmt.allocPrint(arena, "{}", .{package.uri}),
                    });
                },
                .git_ref => {
                    // New package hash format in 0.14 already has "pristine" notion: N-V
                    const dependency_file_name = if (new_package_hash_format)
                        try std.fmt.allocPrint(
                            arena,
                            "{s}.tar.gz",
                            .{package.hash},
                        )
                    else
                        try std.fmt.allocPrint(
                            arena,
                            "{s}-{s}.tar.gz",
                            .{ package.name orelse "pristine_package", package.hash },
                        );

                    git_commits.appendAssumeCapacity(.{
                        // Assume they are in tarball-tarball already.
                        .name = dependency_file_name,
                        .url = "",
                    });
                },
            }
        }

        break :downloadable_dependencies .{
            .tarball = try tarballs.toOwnedSlice(arena),
            .git_commits = try git_commits.toOwnedSlice(arena),
        };
    };
    main_log.info(@src(), "Used tarballs: {d}, used git commits: {d}", .{
        downloadable_dependencies.tarball.len,
        downloadable_dependencies.git_commits.len,
    });

    const context = .{
        .generator_version = try std.fmt.allocPrint(gpa, "{}", .{version}),
        .year = year: {
            const time: Timestamp = .now();
            break :year time.year;
        },
        .zig_slot = switch (zig_process.version.kind) {
            .live => "9999",
            .release => try std.fmt.allocPrint(arena, "{d}.{d}", .{ zig_process.version.sem_ver.major, zig_process.version.sem_ver.minor }),
        },
        .dependencies = downloadable_dependencies,
        .tarball_tarball = optional_tarball_tarball,
        .report = report,
    };
    defer gpa.free(context.generator_version);

    main_log.info(@src(), "Writing generated ebuild to STDOUT...", .{});

    var render_errors: ztl.RenderErrorReport = .{};
    defer render_errors.deinit();

    template.render(stdout, context, .{ .error_report = &render_errors }) catch |err| {
        file_searching_events.err(@src(), "Error when rendering template: {s} caused by: {}", .{
            @errorName(err),
            render_errors,
        });
        return error.InvalidTemplate;
    };

    main_log.info(@src(), "Generated ebuild was written to STDOUT.", .{});
    main_log.info(@src(), "Note (if using default template): license header there (with \"Gentoo Authors\" and GNU GPLv2) is just an convenience default for making ebuilds for ::gentoo and ::guru repos easier, you can relicense output however you want.", .{});

    if (optional_tarball_tarball) |tarball_tarball_path| {
        main_log.warn(@src(), "Note: it appears your project has Git commit dependencies that generator was unable to convert, please host \"{s}\" somewhere and add it to SRC_URI.", .{tarball_tarball_path});
    }
}
