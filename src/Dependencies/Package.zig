// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const Logger = @import("../Logger.zig");

const Package = @This();

/// `null` means package is pristine (does not have `build.zig.zon`).
name: ?[]const u8,
hash: []const u8,
// TODO: many urls? mirrors?
uri: std.Uri,
kind: union(ResourceType) {
    tarball: FileType,
    git_ref: []const u8,
},

const ResourceType = enum {
    tarball,
    git_ref,
};

pub fn init(
    arena: std.mem.Allocator,
    options: struct {
        name: ?[]const u8,
        hash: []const u8,
        uri: std.Uri,
    },
    events: Logger,
) error{ OutOfMemory, InvalidUri }!Package {
    var uri = options.uri;

    const kind: @FieldType(Package, "kind") = if (std.ascii.eqlIgnoreCase(uri.scheme, "https") or
        std.ascii.eqlIgnoreCase(uri.scheme, "http"))
    file: {
        try canonicalize_uri(&uri, arena, .tarball);
        const path = try uri.path.toRawMaybeAlloc(arena);
        const file_type = Package.FileType.fromPath(path) orelse {
            events.err(@src(), "Unknown tarball format: {s} (from URL {}).", .{ path, uri });
            return error.InvalidUri;
        };

        break :file .{ .tarball = file_type };
    } else if (std.ascii.eqlIgnoreCase(uri.scheme, "git+https") or
        std.ascii.eqlIgnoreCase(uri.scheme, "git+http"))
    commit: {
        try canonicalize_uri(&uri, arena, .git_ref);
        // We are assuming this is a commit, not a direct ref.
        // Which means that author called `zig fetch --save` correctly
        // and URL points to immutable data.
        //
        // In other words, we are assuming this or this:
        // * git+https://github.com/user/repo?ref=main#123456
        // * git+https://github.com/user/repo#123456
        //
        // but not this or this:
        // * git+https://github.com/user/repo#main
        // * git+https://github.com/user/repo
        const commit_component = uri.fragment orelse {
            events.err(@src(), "Invalid Git URI: {}.", .{uri});
            events.err(@src(), "This URI most likely points to mutable content.", .{});
            return error.InvalidUri;
        };
        // Assume there is no need to percent-encode it.
        const commit = try commit_component.toRawMaybeAlloc(arena);

        break :commit .{ .git_ref = commit };
    } else {
        events.err(@src(), "Unknown URI scheme: {s} (from URL {}).", .{ uri.scheme, uri });
        return error.InvalidUri;
    };

    return .{
        .name = options.name,
        .hash = options.hash,
        .kind = kind,
        .uri = uri,
    };
}

/// Change `http` to `https`, remove `www.` prefix and etc. on supported Services.
fn canonicalize_uri(
    uri: *std.Uri,
    arena: std.mem.Allocator,
    resource_type: ResourceType,
) error{OutOfMemory}!void {
    const host_component = uri.host orelse return;
    const host = try host_component.toRawMaybeAlloc(arena);

    const service = Package.Service.fromHost.get(host) orelse return;

    uri.scheme, uri.host.? = service.toComponents(resource_type);
}

/// Chooses package out of 2 hash duplicates based on several criterias:
/// 1. If URLs differ, go to step 2. Otherwise leave intact.
/// 2. If one of package is hosted on Hexops mirror and other is not,
/// change to the mirror. Otherwise go to step 3.
/// 3. If one of package is tarball/archive and other is git reference,
/// change to the tarball. Otherwise, return `null` (undecided).
/// TODO also check for compression if both of them are tarballs.
pub fn choose_best(
    arena: std.mem.Allocator,
    a: Package,
    b: Package,
    events: Logger,
) error{ OutOfMemory, InvalidUri }!?Package {
    std.debug.assert(std.mem.eql(u8, a.hash, b.hash));

    const a_url = try std.fmt.allocPrint(arena, "{}", .{a.uri});
    const b_url = try std.fmt.allocPrint(arena, "{}", .{b.uri});
    // They can be different when it is pristine package, e.g.
    // does not have own `build.zig.zon` and we set name based
    // on how it's used in consumer's `build.zig.zon`.
    if (std.mem.eql(u8, a_url, b_url)) {
        const b_name = b.name orelse return a;
        // If they have same URL and one of them have build.zig.zon,
        // surely another one have it too.
        switch (std.mem.eql(u8, a.name.?, b_name)) {
            true => {},
            false => events.warn(@src(), "Found duplicate with different name: {s}. Leaving old.", .{b_name}),
        }
        return a;
    }

    replace_service: {
        const a_host_component = a.uri.host orelse return error.InvalidUri;
        const b_host_component = b.uri.host orelse return error.InvalidUri;

        const a_host = try a_host_component.toRawMaybeAlloc(arena);
        const b_host = try b_host_component.toRawMaybeAlloc(arena);

        const a_service = Service.fromHost.get(a_host) orelse break :replace_service;
        const b_service = Service.fromHost.get(b_host) orelse break :replace_service;

        if (a_service == b_service) break :replace_service;

        if (a_service == .mach and b_service != .mach) return a;
        if (a_service != .mach and b_service == .mach) {
            events.warn(@src(), "Found more suitable mirror in duplicate: {s} instead of {s}. Replacing.", .{ b_host, a_host });
            return b;
        }
        break :replace_service;
    }

    if (a.kind == .tarball and b.kind == .git_ref) {
        return a;
    } else if (a.kind == .git_ref and b.kind == .tarball) {
        events.warn(@src(), "Found more suitable format in duplicate: tarball instead of Git commit. Replacing.", .{});
        return b;
    } else {
        // Don't know what to choose.
        return null;
    }
}

/// Mutate `self` in-place to transform Git commits to
/// tarballs where possible (and algorithm is known).
pub fn transform_git_commit_to_tarball(
    self: *Package,
    arena: std.mem.Allocator,
    events: Logger,
) error{ OutOfMemory, InvalidUri }!void {
    std.debug.assert(self.kind == .git_ref);
    const commit = self.kind.git_ref;

    // Usually of form:
    // * /user/repo
    // or:
    // * /user/repo.git
    var repository: []const u8 = try std.fmt.allocPrint(
        arena,
        // Use `{path}` for percent-encoding, other parts
        // of URI are assumed to be encoded already.
        // Doing this because ZTL template won't convert it.
        "{path}",
        .{self.uri.path},
    );
    // Canonicalize to this form:
    // * user/repo
    repository = std.mem.trimLeft(u8, repository, "/");
    if (std.mem.endsWith(u8, repository, ".git"))
        repository = repository[0 .. repository.len - ".git".len];

    const service = service: {
        const host = self.uri.host orelse {
            events.err(@src(), "Invalid Git URI: {}.", .{self.uri});
            return error.InvalidUri;
        };
        break :service Package.Service.fromHost.get(try host.toRawMaybeAlloc(arena)) orelse {
            // We don't know how to translate this service yet.
            events.warn(@src(), "Report warning below to zig-ebuilder upstream:", .{});
            events.warn(@src(), "Unknown service: {raw} (from URL {}).", .{ host, self.uri });
            return;
        };
    };

    const tarball_uri, const tarball_extension: Package.FileType = switch (service) {
        .codeberg,
        .github,
        .sourcehut,
        => .{
            try std.fmt.allocPrint(
                arena,
                "{s}/{s}/archive/{s}.tar.gz",
                .{ service.toUrl(), repository, commit },
            ),
            .@"tar.gz",
        },

        .gitlab,
        => .{
            // TODO: Change to ".tar.bz2" when/if `zig fetch` start to support it.
            try std.fmt.allocPrint(
                arena,
                "{s}/{s}/-/archive/{s}.tar.gz",
                .{ service.toUrl(), repository, commit },
            ),
            .@"tar.gz",
        },

        .mach => {
            events.warn(@src(), "Report warning below to zig-ebuilder upstream:", .{});
            events.warn(@src(), "Service {s} does not support Git commit dependencies (from URL {}).", .{ service.toUrl(), self.uri });
            return;
        },
    };

    self.uri = std.Uri.parse(tarball_uri) catch |err| {
        events.warn(@src(), "Report warning below to zig-ebuilder upstream:", .{});
        events.err(@src(), "Invalid tarball URI after transformation: \"{s}\": {s}.", .{ tarball_uri, @errorName(err) });
        return error.InvalidUri;
    };
    self.kind = .{ .tarball = tarball_extension };
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

    /// Scheme and host:
    /// * host: without trailing slash,
    ///   stripped of "www." etc. prefix if possible,
    /// scheme: prefers "https" over "http" if possible.
    fn toComponents(self: Service, resource_type: ResourceType) struct { []const u8, std.Uri.Component } {
        const scheme: []const u8 = switch (self) {
            .codeberg,
            .github,
            .gitlab,
            .mach,
            .sourcehut,
            => switch (resource_type) {
                .tarball => "https",
                .git_ref => "git+https",
            },
        };

        const host: std.Uri.Component = .{
            .raw = switch (self) {
                .codeberg => "codeberg.org",
                .github => "github.com",
                .gitlab => "gitlab.com",
                .mach => "pkg.machengine.org",
                .sourcehut => "git.sr.ht",
            },
        };
        return .{ scheme, host };
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

// Based on Zig compiler sources ("src/Package/Fetch.zig")
// as for upstream commit 21a0885ae70f1e977b91a63a8b23d705acdac618.
// SPDX-SnippetBegin
// SPDX-SnippetCopyrightText: Zig contributors
// SPDX-License-Identifier: MIT
const FileType = enum {
    tar,
    @"tar.gz",
    @"tar.bz2",
    @"tar.xz",
    @"tar.zst",
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
        if (ascii.endsWithIgnoreCase(file_path, ".jar")) return .zip;
        return null;
    }
};
// SPDX-SnippetEnd
