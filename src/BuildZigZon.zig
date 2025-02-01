// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const Logger = @import("Logger.zig");

const location = @import("location.zig");

const BuildZigZon = @This();

name: []const u8,
version: std.SemanticVersion,
/// For deinitialization.
version_raw: []const u8,
/// Optional.
minimum_zig_version: ?std.SemanticVersion,
/// For deinitialization.
minimum_zig_version_raw: ?[]const u8,
/// Optional.
dependencies: ?std.json.ArrayHashMap(Dep),
paths: []const []const u8,

pub const Dep = struct {
    storage: Storage,
    lazy: ?bool,

    const Storage = union(enum) {
        local: struct {
            path: []const u8,
        },
        remote: struct {
            url: []const u8,
            hash: []const u8,
        },

        fn deinit(self: Storage, allocator: std.mem.Allocator) void {
            switch (self) {
                .local => |local| allocator.free(local.path),
                .remote => |remote| {
                    allocator.free(remote.url);
                    allocator.free(remote.hash);
                },
            }
        }
    };
};

pub fn deinit(self: *BuildZigZon, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    allocator.free(self.version_raw);
    if (self.minimum_zig_version_raw) |minimum_zig_version_raw|
        allocator.free(minimum_zig_version_raw);

    if (self.dependencies) |*dependencies| {
        for (dependencies.map.keys(), dependencies.map.values()) |key, value| {
            allocator.free(key);
            value.storage.deinit(allocator);
        }
        dependencies.deinit(allocator);
    }

    for (self.paths) |path| allocator.free(path);
    allocator.free(self.paths);
}

pub fn read(
    allocator: std.mem.Allocator,
    loc: location.File,
    file_parsing_events: Logger,
) (error{ OutOfMemory, InvalidBuildZigZon } || std.fs.File.ReadError)!BuildZigZon {
    const file_content = std.zig.readSourceFileToEndAlloc(allocator, loc.file, null) catch |err| switch (err) {
        error.UnsupportedEncoding => {
            file_parsing_events.err(@src(), "Unsupported encoding (not UTF-8) on file: {s}", .{loc.string});
            return error.InvalidBuildZigZon;
        },
        error.FileTooBig => {
            file_parsing_events.err(@src(), "File too big: {s}", .{loc.string});
            return error.OutOfMemory;
        },
        else => |e| {
            file_parsing_events.err(@src(), "Error when loading file: {s} caused by \"{s}\".", .{ @errorName(e), loc.string });
            return e;
        },
    };
    defer allocator.free(file_content);

    var ast: std.zig.Ast = try .parse(allocator, file_content, .zon);
    defer ast.deinit(allocator);

    const zoir = try std.zig.ZonGen.generate(allocator, ast);
    defer zoir.deinit(allocator);

    if (zoir.hasCompileErrors()) {
        file_parsing_events.err(@src(), "Invalid ZON file: {d} errors", .{zoir.compile_errors.len});
        for (zoir.compile_errors, 1..) |compile_error, i| {
            const error_msg = compile_error.msg.get(zoir);
            file_parsing_events.err(@src(), "[{d}] error: {s}", .{ i, error_msg });

            const notes = compile_error.getNotes(zoir);
            for (notes) |note| {
                const note_msg = note.msg.get(zoir);
                file_parsing_events.err(@src(), "[{d}] note: {s}", .{ i, note_msg });
            }
        }
        return error.InvalidBuildZigZon;
    }

    const parser: Parser = .{
        .allocator = allocator,
        .zoir = zoir,
    };
    return try parser.parse(file_parsing_events);
}

/// For specific file.
const Parser = struct {
    allocator: std.mem.Allocator,
    zoir: std.zig.Zoir,

    fn parse(self: *const Parser, file_parsing_events: Logger) error{ OutOfMemory, InvalidBuildZigZon }!BuildZigZon {
        std.debug.assert(self.zoir.hasCompileErrors() == false);
        const allocator = self.allocator;

        const root_struct = switch (std.zig.Zoir.Node.Index.get(.root, self.zoir)) {
            .struct_literal => |struct_literal| struct_literal,
            else => |not_a_struct| {
                file_parsing_events.err(@src(), "Not a struct: {}", .{not_a_struct});
                return error.InvalidBuildZigZon;
            },
        };
        file_parsing_events.debug(@src(), "root_struct = {}", .{std.json.fmt(root_struct, .{ .whitespace = .indent_4 })});

        var result: BuildZigZon = .{
            .name = undefined,
            .version = undefined,
            .version_raw = undefined,
            .minimum_zig_version = null,
            .minimum_zig_version_raw = null,
            .dependencies = null,
            .paths = &.{},
        };

        file_parsing_events.debug(@src(), "Found {d} top-level fields, parsing...", .{root_struct.names.len});

        const top_level_fields_parsing_events = try file_parsing_events.child("fields");
        defer top_level_fields_parsing_events.deinit();

        std.debug.assert(root_struct.names.len == root_struct.vals.len);
        for (root_struct.names, 0..) |field_name_i, _i| {
            const field = .{
                .name = try allocator.dupe(u8, field_name_i.get(self.zoir)),
                .value = root_struct.vals.at(@intCast(_i)).get(self.zoir),
            };
            defer allocator.free(field.name);

            const field_parsing_events = try top_level_fields_parsing_events.child(field.name);
            defer field_parsing_events.deinit();

            const TopLevelField = enum { name, version, minimum_zig_version, dependencies, paths, unknown };
            const top_level_field_type = std.meta.stringToEnum(TopLevelField, field.name) orelse .unknown;

            switch (top_level_field_type) {
                .name => {
                    result.name = switch (field.value) {
                        .string_literal => |string_literal| try allocator.dupe(u8, string_literal),
                        else => |not_a_string| {
                            field_parsing_events.err(@src(), "Not a string: {}", .{not_a_string});
                            return error.InvalidBuildZigZon;
                        },
                    };
                    field_parsing_events.debug(@src(), "Valid string: \"{s}\"", .{result.name});
                    continue;
                },
                inline .version, .minimum_zig_version => |tag| {
                    const version_string = switch (field.value) {
                        .string_literal => |string_literal| try allocator.dupe(u8, string_literal),
                        else => |not_a_string| {
                            field_parsing_events.err(@src(), "Not a string: {}", .{not_a_string});
                            return error.InvalidBuildZigZon;
                        },
                    };
                    errdefer allocator.free(version_string);
                    @field(result, @tagName(tag) ++ "_raw") = version_string;

                    const sem_ver = std.SemanticVersion.parse(version_string) catch |err| {
                        field_parsing_events.err(@src(), "Invalid std.SemanticVersion: {s} because of {s}", .{ @errorName(err), version_string });
                        return error.InvalidBuildZigZon;
                    };

                    @field(result, @tagName(tag)) = sem_ver;
                    field_parsing_events.debug(@src(), "Valid std.SemanticVersion: {}", .{sem_ver});
                    continue;
                },
                .dependencies => {
                    const dependencies_struct = switch (field.value) {
                        .struct_literal => |struct_literal| struct_literal,
                        .empty_literal => {
                            field_parsing_events.warn(@src(), "Declared but empty, skipping", .{});
                            continue;
                        },
                        else => |not_a_struct| {
                            field_parsing_events.err(@src(), "Not a struct: {}", .{not_a_struct});
                            return error.InvalidBuildZigZon;
                        },
                    };

                    field_parsing_events.debug(@src(), "Found {d} dependencies, parsing...", .{root_struct.names.len});
                    std.debug.assert(dependencies_struct.names.len == dependencies_struct.vals.len);

                    var deps: std.StringArrayHashMapUnmanaged(BuildZigZon.Dep) = .empty;
                    try deps.ensureTotalCapacity(allocator, dependencies_struct.names.len);
                    for (dependencies_struct.names, 0..) |dependency_name_i, __i| {
                        const dependency = .{
                            .name = try allocator.dupe(u8, dependency_name_i.get(self.zoir)),
                            .value = dependencies_struct.vals.at(@intCast(__i)).get(self.zoir),
                        };
                        errdefer allocator.free(dependency.name);

                        const dependency_parsing_events = try field_parsing_events.child(dependency.name);
                        defer dependency_parsing_events.deinit();

                        const dependency_struct = switch (dependency.value) {
                            .struct_literal => |struct_literal| struct_literal,
                            .empty_literal => {
                                field_parsing_events.warn(@src(), "Declared but empty, exiting!", .{});
                                return error.InvalidBuildZigZon;
                            },
                            else => |not_a_struct| {
                                dependency_parsing_events.err(@src(), "Not a struct: {}", .{not_a_struct});
                                return error.InvalidBuildZigZon;
                            },
                        };

                        var url: ?[]const u8 = null;
                        var hash: ?[]const u8 = null;
                        var path: ?[]const u8 = null;
                        var lazy: ?bool = null;
                        std.debug.assert(dependency_struct.names.len == dependency_struct.vals.len);
                        for (dependency_struct.names, 0..) |dependency_field_name_i, ___i| {
                            const dependency_field = .{
                                .name = try allocator.dupe(u8, dependency_field_name_i.get(self.zoir)),
                                .value = dependency_struct.vals.at(@intCast(___i)).get(self.zoir),
                            };
                            defer allocator.free(dependency_field.name);

                            const dependency_field_parsing_events = try dependency_parsing_events.child(dependency_field.name);
                            defer dependency_field_parsing_events.deinit();

                            const DepField = enum { url, hash, path, lazy, unknown };
                            const dep_field_type = std.meta.stringToEnum(DepField, dependency_field.name) orelse .unknown;

                            switch (dep_field_type) {
                                .url => url = switch (dependency_field.value) {
                                    .string_literal => |string_literal| try allocator.dupe(u8, string_literal),
                                    else => |not_a_string| {
                                        dependency_field_parsing_events.err(@src(), "Not a string: {}", .{not_a_string});
                                        return error.InvalidBuildZigZon;
                                    },
                                },
                                .hash => hash = switch (dependency_field.value) {
                                    .string_literal => |string_literal| try allocator.dupe(u8, string_literal),
                                    else => |not_a_string| {
                                        dependency_field_parsing_events.err(@src(), "Not a string: {}", .{not_a_string});
                                        return error.InvalidBuildZigZon;
                                    },
                                },
                                .path => path = switch (dependency_field.value) {
                                    .string_literal => |string_literal| try allocator.dupe(u8, string_literal),
                                    else => |not_a_string| {
                                        dependency_field_parsing_events.err(@src(), "Not a string: {}", .{not_a_string});
                                        return error.InvalidBuildZigZon;
                                    },
                                },
                                .lazy => lazy = switch (dependency_field.value) {
                                    .true => true,
                                    .false => false,
                                    else => |not_a_boolean| {
                                        dependency_field_parsing_events.err(@src(), "Not a boolean: {}", .{not_a_boolean});
                                        return error.InvalidBuildZigZon;
                                    },
                                },
                                .unknown => {
                                    dependency_field_parsing_events.warn(@src(), "Unknown type, skipping", .{});
                                    continue;
                                },
                            }
                        }

                        if (url != null and path != null) {
                            dependency_parsing_events.err(@src(), "Can't have both \"url\" and \"path\" fields together", .{});
                            return error.InvalidBuildZigZon;
                        }

                        if (url != null and hash == null) {
                            dependency_parsing_events.err(@src(), "Missing \"hash\" field for \"url\"-based dependency", .{});
                            return error.InvalidBuildZigZon;
                        }

                        if (path != null and hash != null) {
                            dependency_parsing_events.err(@src(), "Can't have both \"path\" and \"hash\" fields together. Note: only \"url\"-based dependencies can have \"hash\"", .{});
                            return error.InvalidBuildZigZon;
                        }

                        const storage: BuildZigZon.Dep.Storage = if (url) |remote| remote: {
                            std.debug.assert(hash != null);
                            std.debug.assert(path == null);

                            // Normalize: '.url = "file://blabla"' to '.path = "blabla"'
                            const uri = std.Uri.parse(remote) catch |err| {
                                dependency_parsing_events.err(@src(), "Invalid URI \"{s}\": {s}", .{ remote, @errorName(err) });
                                return error.InvalidBuildZigZon;
                            };
                            break :remote if (std.ascii.eqlIgnoreCase(uri.scheme, "file"))
                                .{ .local = .{ .path = try uri.path.toRawMaybeAlloc(allocator) } }
                            else
                                .{ .remote = .{ .url = remote, .hash = hash.? } };
                        } else if (path != null) local: {
                            std.debug.assert(url == null);
                            std.debug.assert(hash == null);
                            break :local .{ .local = .{ .path = path.? } };
                        } else {
                            dependency_parsing_events.err(@src(), "Dependency has no \"url\" neither \"path\" field, unknown type of location", .{});
                            return error.InvalidBuildZigZon;
                        };

                        try deps.put(allocator, dependency.name, .{
                            .lazy = lazy,
                            .storage = storage,
                        });
                    }

                    const Sort = struct {
                        values: []const Dep,

                        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                            const a = ctx.values[a_index];
                            const b = ctx.values[b_index];

                            return switch (a.storage) {
                                .local => switch (b.storage) {
                                    .local => false,
                                    .remote => true,
                                },
                                .remote => false,
                            };
                        }
                    };
                    deps.sort(Sort{ .values = deps.values() });

                    result.dependencies = .{ .map = deps };
                    continue;
                },
                .paths => {
                    const paths_array = switch (field.value) {
                        .array_literal => |array_literal| array_literal,
                        .empty_literal => {
                            field_parsing_events.err(@src(), "Declared but empty, exiting!", .{});
                            return error.InvalidBuildZigZon;
                        },
                        else => |not_an_array| {
                            field_parsing_events.err(@src(), "Not an array: {}", .{not_an_array});
                            return error.InvalidBuildZigZon;
                        },
                    };

                    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
                    try paths.ensureTotalCapacity(allocator, paths_array.len);
                    errdefer paths.deinit(allocator);

                    for (0..paths_array.len) |__i| {
                        const path = switch (paths_array.at(@intCast(__i)).get(self.zoir)) {
                            .string_literal => |string_literal| try allocator.dupe(u8, string_literal),
                            else => |not_a_string| {
                                field_parsing_events.err(@src(), "Not a string: {}", .{not_a_string});
                                return error.InvalidBuildZigZon;
                            },
                        };
                        paths.appendAssumeCapacity(path);
                    }

                    result.paths = try paths.toOwnedSlice(allocator);
                    continue;
                },
                .unknown => {
                    field_parsing_events.warn(@src(), "Unknown type, skipping", .{});
                    continue;
                },
            }
        }

        return result;
    }
};
