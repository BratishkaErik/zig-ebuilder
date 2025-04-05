// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const Timestamp = @import("Timestamp.zig");

const Logger = @This();

const Level = enum(u2) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,

    pub fn description(comptime self: Level) struct { std.io.tty.Color, []const u8 } {
        return switch (self) {
            // zig fmt: off
            .err =>   .{ .red,    "ERROR  " },
            .warn =>  .{ .yellow, "WARNING" },
            .info =>  .{ .cyan,   "INFO   " },
            .debug => .{ .green,  "DEBUG  " },
            // zig fmt: on
        };
    }
};

shared: *const struct {
    scretch_pad: std.mem.Allocator,
},
scopes: [][]const u8,

// Make output more useful for screen readers, diff'ing and so on.
pub const Format = struct {
    color: enum { auto, always, never },
    time_format: enum { none, time, day_time },
    src_location: enum { always, never },
    level: Level,
};

pub var global_format: Format = .{
    // Default values:
    .color = .auto,
    .time_format = .none,
    .src_location = .never,
    .level = .info,
};

pub fn deinit(self: @This()) void {
    self.shared.scretch_pad.free(self.scopes);
}

pub fn child(self: @This(), scope: []const u8) error{OutOfMemory}!Logger {
    const allocator = self.shared.scretch_pad; // alias
    var array_list: std.ArrayListUnmanaged([]const u8) = try .initCapacity(allocator, self.scopes.len + 1);
    errdefer array_list.deinit(allocator);

    array_list.appendSliceAssumeCapacity(self.scopes);
    array_list.appendAssumeCapacity(scope);

    return .{
        .shared = self.shared,
        .scopes = try array_list.toOwnedSlice(allocator),
    };
}

fn log(
    self: @This(),
    src: std.builtin.SourceLocation,
    comptime message_level: Level,
    comptime spec: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > @intFromEnum(global_format.level)) return;

    const stderr = std.io.getStdErr();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    const config: std.io.tty.Config = switch (global_format.color) {
        .always => config: {
            if (@import("builtin").os.tag == .windows) windows: {
                if (stderr.isTty() == false) break :windows;

                var screen_info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
                if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(stderr.handle, &screen_info) == std.os.windows.FALSE) break :windows;
                break :config .{ .windows_api = .{
                    .handle = stderr.handle,
                    .reset_attributes = screen_info.wAttributes,
                } };
            }

            break :config .escape_codes;
        },
        .never => .no_color,
        .auto => std.io.tty.detectConfig(stderr),
    };
    var bw = std.io.bufferedWriter(stderr.writer());
    const writer = bw.writer();

    if (global_format.time_format != .none) {
        const time: Timestamp = .now();

        config.setColor(writer, .bright_black) catch {};
        switch (global_format.time_format) {
            .none => @panic("unreachable (report to upstream of zig-ebuilder)"),
            .time => writer.print("{time}", .{time}) catch {},
            .day_time => writer.print("{[stamp]day} {[stamp]time}", .{ .stamp = time }) catch {},
        }
        config.setColor(writer, .reset) catch {};
        writer.writeByte(' ') catch {};
    }

    const color, const text = comptime message_level.description();
    config.setColor(writer, color) catch {};
    writer.writeAll(text) catch return;
    config.setColor(writer, .reset) catch {};
    writer.writeByte(' ') catch {};

    switch (global_format.src_location) {
        .never => {},
        .always => {
            config.setColor(writer, .bright_black) catch {};
            writer.print("{s}@{s}:{d}:", .{ src.module, src.file, src.line }) catch {};
            config.setColor(writer, .reset) catch {};
            writer.writeByte(' ') catch {};
        },
    }

    if (self.scopes.len > 0) {
        writer.writeByte('[') catch return;
        for (self.scopes, 0..) |scope, i| {
            writer.print("{s}{s}", .{ scope, if (i < self.scopes.len -| 1) " => " else "" }) catch {};
        }
        writer.writeAll("] ") catch return;
    }

    writer.print(spec ++ "\n", args) catch return;
    bw.flush() catch return;
}

pub fn err(
    self: @This(),
    src: std.builtin.SourceLocation,
    comptime spec: []const u8,
    args: anytype,
) void {
    self.log(src, .err, spec, args);
}

pub fn warn(
    self: @This(),
    src: std.builtin.SourceLocation,
    comptime spec: []const u8,
    args: anytype,
) void {
    self.log(src, .warn, spec, args);
}

pub fn info(
    self: @This(),
    src: std.builtin.SourceLocation,
    comptime spec: []const u8,
    args: anytype,
) void {
    self.log(src, .info, spec, args);
}

pub fn debug(
    self: @This(),
    src: std.builtin.SourceLocation,
    comptime spec: []const u8,
    args: anytype,
) void {
    self.log(src, .debug, spec, args);
}
