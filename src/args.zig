// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");
const Dependencies = @import("Dependencies.zig");
const Logger = @import("Logger.zig");

pub const ParsedArgs = struct {
    prog_name: [:0]const u8,
    zig_executable: [:0]const u8,
    fetch_mode: Dependencies.FetchMode = .plain,
    zig_build_additional_args: [][:0]const u8 = &[_][:0]const u8{},
    optional_custom_template_path: ?[:0]const u8 = null,
    project_path: ?[:0]const u8 = null,
    output_file_path: ?[:0]const u8 = null,
    help: bool = false,
    _expanded_args: [][:0]const u8,

    pub fn deinit(self: *ParsedArgs, allocator: std.mem.Allocator) void {
        for (self._expanded_args) |arg| allocator.free(arg);
        allocator.free(self._expanded_args);
        allocator.free(self.zig_build_additional_args);
    }
};

pub fn parse(allocator: std.mem.Allocator, stderr: std.io.AnyWriter) !?ParsedArgs {
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    var expanded_args = std.ArrayList([:0]const u8).init(allocator);
    errdefer {
        for (expanded_args.items) |arg| allocator.free(arg);
        expanded_args.deinit();
    }

    // First arg is program name
    var prog_name: [:0]const u8 = "(name not provided)";
    if (args_iter.next()) |name| {
        prog_name = try allocator.dupeZ(u8, name);
        try expanded_args.append(prog_name);
    }

    var visited = std.StringArrayHashMap(void).init(allocator);
    defer visited.deinit();

    while (args_iter.next()) |arg| {
        expandArg(allocator, arg, &expanded_args, &visited) catch |err| {
            if (err == error.ResponseFileCycle) {
                stderr.print("Fatal: cycle detected in response files involving \"{s}\"\n", .{arg}) catch {};
            } else {
                stderr.print("Fatal: error expanding response file \"{s}\": {s}\n", .{ arg, @errorName(err) }) catch {};
            }
            return err;
        };
    }

    var res = ParsedArgs{
        .prog_name = prog_name,
        .zig_executable = "zig",
        ._expanded_args = try expanded_args.toOwnedSlice(),
    };
    errdefer {
        for (res._expanded_args) |arg| allocator.free(arg);
        allocator.free(res._expanded_args);
    }

    var i: usize = 1;
    while (i < res._expanded_args.len) : (i += 1) {
        const arg = res._expanded_args[i];
        if (std.mem.eql(u8, arg, "--fetch")) {
            i += 1;
            if (i >= res._expanded_args.len) {
                stderr.writeAll("Missing value for --fetch option\n") catch {};
                return null;
            }
            const value = res._expanded_args[i];
            res.fetch_mode = std.meta.stringToEnum(Dependencies.FetchMode, value) orelse {
                stderr.print("Invalid fetch strategy '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: none, plain, hashed\n") catch {};
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--template")) {
            i += 1;
            if (i >= res._expanded_args.len) {
                stderr.writeAll("Missing value for --template option\n") catch {};
                return null;
            }
            const value = res._expanded_args[i];
            if (std.mem.eql(u8, value, "gentoo.ebuild")) {
                res.optional_custom_template_path = null;
            } else if (value.len > 0) {
                res.optional_custom_template_path = value;
            } else {
                stderr.print("Invalid template '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: gentoo.ebuild, or provide non-empty path\n") catch {};
                return null;
            }
        } else if (std.mem.eql(u8, arg, "--output-file")) {
            i += 1;
            if (i >= res._expanded_args.len) {
                stderr.writeAll("Missing value for --output-file option\n") catch {};
                return null;
            }
            res.output_file_path = res._expanded_args[i];
        } else if (std.mem.eql(u8, arg, "--zig")) {
            i += 1;
            if (i >= res._expanded_args.len) {
                stderr.writeAll("Missing value for --zig option\n") catch {};
                return null;
            }
            const value = res._expanded_args[i];
            if (value.len == 0) {
                stderr.writeAll("Expected non-empty path after --zig option\n") catch {};
                return null;
            }
            res.zig_executable = value;
        } else if (std.mem.eql(u8, arg, "--zig-build-args")) {
            var additional_args = std.ArrayList([:0]const u8).init(allocator);
            errdefer additional_args.deinit();
            i += 1;
            while (i < res._expanded_args.len) : (i += 1) {
                try additional_args.append(res._expanded_args[i]);
            }
            if (additional_args.items.len == 0) {
                stderr.print("Expected following args after \"{s}\"\n", .{arg}) catch {};
                return null;
            }
            res.zig_build_additional_args = try additional_args.toOwnedSlice();
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= res._expanded_args.len) {
                stderr.writeAll("Missing value for --log-level option\n") catch {};
                return null;
            }
            const value = res._expanded_args[i];
            const level = std.meta.stringToEnum(@FieldType(Logger.Format, "level"), value) orelse {
                stderr.print("Invalid log level '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: err, warn, info, debug\n") catch {};
                return null;
            };
            Logger.global_format.level = level;
        } else if (std.mem.eql(u8, arg, "--log-time-format")) {
            i += 1;
            if (i >= res._expanded_args.len) {
                stderr.writeAll("Missing value for --log-time-format option\n") catch {};
                return null;
            }
            const value = res._expanded_args[i];
            const time_format = std.meta.stringToEnum(@FieldType(Logger.Format, "time_format"), value) orelse {
                stderr.print("Invalid log time format '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: none, time, day_time\n") catch {};
                return null;
            };
            Logger.global_format.time_format = time_format;
        } else if (std.mem.eql(u8, arg, "--log-color")) {
            i += 1;
            if (i >= res._expanded_args.len) {
                stderr.writeAll("Missing value for --log-color option\n") catch {};
                return null;
            }
            const value = res._expanded_args[i];
            const color = std.meta.stringToEnum(@FieldType(Logger.Format, "color"), value) orelse {
                stderr.print("Invalid log color mode '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: auto, always, never\n") catch {};
                return null;
            };
            Logger.global_format.color = color;
        } else if (std.mem.eql(u8, arg, "--log-src-location")) {
            i += 1;
            if (i >= res._expanded_args.len) {
                stderr.writeAll("Missing value for --log-src-location option\n") catch {};
                return null;
            }
            const value = res._expanded_args[i];
            const src_location = std.meta.stringToEnum(@FieldType(Logger.Format, "src_location"), value) orelse {
                stderr.print("Invalid log source location mode '{s}'\n", .{value}) catch {};
                stderr.writeAll("Choose one of: always, never\n") catch {};
                return null;
            };
            Logger.global_format.src_location = src_location;
        } else if (std.mem.eql(u8, arg, "--help")) {
            res.help = true;
            return res;
        } else {
            if (res.project_path) |previous_path| {
                stderr.print("More than 1 projects specified at the same time: \"{s}\" and \"{s}\".", .{ previous_path, arg }) catch {};
                return null;
            }
            res.project_path = arg;
        }
    }

    return res;
}

fn expandArg(allocator: std.mem.Allocator, arg: []const u8, result: *std.ArrayList([:0]const u8), visited: *std.StringArrayHashMap(void)) !void {
    if (std.mem.startsWith(u8, arg, "@")) {
        const path = arg[1..];
        if (visited.contains(path)) {
            return error.ResponseFileCycle;
        }
        try visited.put(path, {});
        defer _ = visited.swapRemove(path);

        const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
            return err;
        };
        defer allocator.free(content);

        var tokens = std.ArrayList([]const u8).init(allocator);
        defer {
            for (tokens.items) |token| allocator.free(token);
            tokens.deinit();
        }
        try tokenizeResponseFile(allocator, content, &tokens);

        for (tokens.items) |token| {
            try expandArg(allocator, token, result, visited);
        }
    } else {
        try result.append(try allocator.dupeZ(u8, arg));
    }
}

fn tokenizeResponseFile(allocator: std.mem.Allocator, content: []const u8, result: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < content.len) {
        // Skip whitespace
        while (i < content.len and std.ascii.isWhitespace(content[i])) : (i += 1) {}
        if (i >= content.len) break;

        var token = std.ArrayList(u8).init(allocator);
        errdefer token.deinit();

        var in_quotes = false;
        var quote_char: u8 = 0;

        while (i < content.len) : (i += 1) {
            const c = content[i];
            if (in_quotes) {
                if (c == quote_char) {
                    in_quotes = false;
                } else {
                    try token.append(c);
                }
            } else {
                if (c == '"' or c == '\'') {
                    in_quotes = true;
                    quote_char = c;
                } else if (std.ascii.isWhitespace(c)) {
                    break;
                } else {
                    try token.append(c);
                }
            }
        }
        try result.append(try token.toOwnedSlice());
    }
}

test "tokenizeResponseFile" {
    const allocator = std.testing.allocator;
    var result = std.ArrayList([]const u8).init(allocator);
    defer {
        for (result.items) |t| allocator.free(t);
        result.deinit();
    }

    try tokenizeResponseFile(allocator,
        \\--template "my custom template.ztl" --fetch none
    , &result);
    try std.testing.expectEqual(@as(usize, 4), result.items.len);
    try std.testing.expectEqualStrings("--template", result.items[0]);
    try std.testing.expectEqualStrings("my custom template.ztl", result.items[1]);
    try std.testing.expectEqualStrings("--fetch", result.items[2]);
    try std.testing.expectEqualStrings("none", result.items[3]);

    // Test mixed and single quotes
    for (result.items) |t| allocator.free(t);
    result.clearRetainingCapacity();
    try tokenizeResponseFile(allocator,
        \\foo'bar'"baz" 'spaces here' mixed"quotes"'test'
    , &result);
    try std.testing.expectEqual(@as(usize, 3), result.items.len);
    try std.testing.expectEqualStrings("foobarbaz", result.items[0]);
    try std.testing.expectEqualStrings("spaces here", result.items[1]);
    try std.testing.expectEqualStrings("mixedquotestest", result.items[2]);
}
