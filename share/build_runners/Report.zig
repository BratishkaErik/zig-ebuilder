// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const Report = @This();

system_libraries: []const SystemLibrary,
system_integrations: []const SystemIntegration,
user_options: []const UserOption,

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
