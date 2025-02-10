// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const Report = @This();

system_libraries: []const SystemLibrary,
system_integrations: []const SystemIntegration,
user_options: []const UserOption,
/// If `null`, means that build runner does not support it.
/// Currently it works on `live` but not 0.13.0 .
/// Will be changed to non-optional once 0.14 is released
/// and set as minimum supported version.
used_dependencies_hashes: ?[]const []const u8,

pub const SystemLibrary = struct {
    name: []const u8,
    used_by: []const []const u8,
};

pub const SystemIntegration = struct {
    name: []const u8,
    enabled: bool,
};

pub const UserOption = struct {
    name: []const u8,
    description: []const u8,
    type: []const u8,
    values: ?[]const []const u8,
};
