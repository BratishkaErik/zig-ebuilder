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

const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 1 };

fn printHelp(writer: std.io.AnyWriter) void {
    writer.print(
        \\Usage: {[prog_name]s} [flags] <path>
        \\
        \\Flags:
        \\    --help                             Print this help
        \\
        \\    --zig=[path]                       Specify Zig executable to use
        \\    --color=[on|off|auto]              Whether to use color in logs
        \\    --time=[none|time|day_time]        Whether to print "time" or "day and time" in logs
        \\    --src_loc=[on|off]                 Whether to print source location in logs
        \\    --min_level=[err|warn|info|debug]  Severity of printed logs
        \\
        \\    --zig_build_additional_args [...]  Additional args to pass for "zig build" verbatim
        \\    --fetch=[skip|plain|hashed]        Choose method for fetching: none, plain, or hashed (requires patch)
        \\    --custom_template=[path]           Specify custom ZTL template to use for generating ebuild
        \\
        \\ <path> should be a build.zig file, or directory containing it;
        \\ if none is provided, defaults to current working directory.
        \\
        \\ If "build.zig.zon" file is found nearby, `zig-ebuilder` will fetch all dependencies
        \\ (eagerly and recursively), and fill ZBS_DEPENDENCIES array.
        \\
        \\ Arguments for "zig build" may be useful if you want to enable some option that will link
        \\ system library and so show it in report by generator, if it's required to pass etc.
        \\
    , .{ .prog_name = global.prog_name }) catch {};
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

    stderr.print("Starting {s} {}\n", .{ global.prog_name, version }) catch {};

    var zig_build_additional_args: [][:0]const u8 = &.{};
    defer gpa.free(zig_build_additional_args);

    var optional_custom_template_path: ?[:0]const u8 = null;
    var file_name: ?[:0]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printHelp(stdout);
            return;
        } else if (std.mem.startsWith(u8, arg, "--zig=")) {
            const text = arg["--zig=".len..];
            global.zig_executable = if (text.len != 0) text else {
                stderr.print("Expected non-empty path to \"zig\" binary\n", .{}) catch {};
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--color=")) {
            const text = arg["--color=".len..];
            Logger.global_format.color = std.meta.stringToEnum(@FieldType(Logger.Format, "color"), text) orelse {
                stderr.print("Expected [on|off|auto] in \"{s}\", found \"{s}\"\n", .{ arg, text }) catch {};
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--time=")) {
            const text = arg["--time=".len..];
            Logger.global_format.time = std.meta.stringToEnum(@FieldType(Logger.Format, "time"), text) orelse {
                stderr.print("Expected [none|time|day_time] in \"{s}\", found \"{s}\"\n", .{ arg, text }) catch {};
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--src_loc=")) {
            const text = arg["--src_loc=".len..];
            Logger.global_format.src_loc = std.meta.stringToEnum(@FieldType(Logger.Format, "src_loc"), text) orelse {
                stderr.print("Expected [on|off] in \"{s}\", found \"{s}\"\n", .{ arg, text }) catch {};
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--min_level=")) {
            const text = arg["--min_level=".len..];
            Logger.global_format.min_level = std.meta.stringToEnum(@FieldType(Logger.Format, "min_level"), text) orelse {
                stderr.print("Expected [err|warn|info|debug] in \"{s}\", found \"{s}\"\n", .{ arg, text }) catch {};
                return;
            };
        } else if (std.mem.eql(u8, arg, "--zig_build_additional_args")) {
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
        } else if (std.mem.startsWith(u8, arg, "--fetch=")) {
            const text = arg["--fetch=".len..];
            global.fetch_mode = std.meta.stringToEnum(Dependencies.FetchMode, text) orelse {
                stderr.print("Expected [skip|plain|hashed] in \"{s}\", found \"{s}\"\n", .{ arg, text }) catch {};
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--custom_template=")) {
            const text = arg["--custom_template=".len..];
            optional_custom_template_path = if (text.len != 0) text else {
                stderr.print("Expected non-empty path to custom template\n", .{}) catch {};
                return;
            };
        } else {
            if (file_name) |previous_path| {
                stderr.print("More than 1 path at same time specified: \"{s}\" and \"{s}\".", .{ previous_path, arg }) catch {};
                stderr.writeAll("If you wanted to pass option, please make sure that '=' symbols are reproduced exactly as written in \"--help\".\n") catch {};
                return;
            }
            file_name = arg;
        }
    }

    var main_log: Logger = .{
        .shared = &.{ .scretch_pad = gpa },
        .scopes = &.{},
    };
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

    const dependencies: Dependencies = if (global.fetch_mode != .skip) fetch: {
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
