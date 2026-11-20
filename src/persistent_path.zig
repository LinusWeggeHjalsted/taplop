//! The per-OS persistent data directory default - the ONE resolution site,
//! shared by the native entry (native.zig) and the dev report tools
//! (sound_report / art_report, which resolve the persistent dir to audit
//! shadowed assets; a hand-duplicated default there is the drift class
//! this module exists to prevent). Env acquisition (getenv) stays at the
//! callers - they link libc - so this module is pure over an explicit env
//! snapshot + os tag and the headless tests drive synthetic environments.
//! The settled defaults and their why: DESIGN → File System & IO →
//! Persistent path.

const std = @import("std");

/// An explicit snapshot of the environment variables the per-OS defaults
/// read. Callers fill it from `std.c.getenv` (slicing at the NUL); tests
/// pass synthetic values.
pub const Env = struct {
    /// `$ZIGLOP_DATA` - the dev / portable-install / test override. Wins
    /// over every per-OS default.
    ziglop_data: ?[]const u8 = null,
    /// `$HOME` (linux fallback, macOS).
    home: ?[]const u8 = null,
    /// `$XDG_DATA_HOME` - honored only when set and ABSOLUTE (the XDG
    /// spec: empty or relative means unset).
    xdg_data_home: ?[]const u8 = null,
    /// `%LOCALAPPDATA%` (windows).
    localappdata: ?[]const u8 = null,
    /// `%USERPROFILE%` - the windows fallback when `%LOCALAPPDATA%` is
    /// somehow missing.
    userprofile: ?[]const u8 = null,
};

/// Build the persistent data dir path in priority order:
///   1. `$ZIGLOP_DATA`
///   2. per-OS default:
///      - linux: `$XDG_DATA_HOME/ziglop`, else `$HOME/.local/share/ziglop`
///      - macOS: `$HOME/Library/Application Support/ziglop`
///      - windows: `%LOCALAPPDATA%/ziglop`, else
///        `%USERPROFILE%/AppData/Local/ziglop`
/// Forward slashes on windows: both the Zig Dir layer and raylib accept
/// them, so one separator convention serves every arm. Returned bytes are
/// caller-owned. Returns `error.EnvironmentVariableMissing` when no rule
/// has the variables it needs.
pub fn resolvePersistentPath(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]u8 {
    if (env.ziglop_data) |override| {
        if (override.len > 0) return allocator.dupe(u8, override);
    }
    switch (os_tag) {
        .macos => {
            const home = env.home orelse return error.EnvironmentVariableMissing;
            return std.fmt.allocPrint(
                allocator,
                "{s}/Library/Application Support/ziglop",
                .{home},
            );
        },
        .windows => {
            if (env.localappdata) |localappdata| {
                return std.fmt.allocPrint(allocator, "{s}/ziglop", .{localappdata});
            }
            const userprofile = env.userprofile orelse return error.EnvironmentVariableMissing;
            return std.fmt.allocPrint(
                allocator,
                "{s}/AppData/Local/ziglop",
                .{userprofile},
            );
        },
        // linux + every other tag: the XDG data dir.
        else => {
            if (env.xdg_data_home) |xdg_data_home| {
                if (xdg_data_home.len > 0 and xdg_data_home[0] == '/') {
                    return std.fmt.allocPrint(allocator, "{s}/ziglop", .{xdg_data_home});
                }
            }
            const home = env.home orelse return error.EnvironmentVariableMissing;
            return std.fmt.allocPrint(allocator, "{s}/.local/share/ziglop", .{home});
        },
    }
}

test "resolvePersistentPath: the ZIGLOP_DATA override wins over every default" {
    const allocator = std.testing.allocator;
    const resolved = try resolvePersistentPath(allocator, .linux, .{
        .ziglop_data = "/scratch/drive",
        .xdg_data_home = "/xdg",
        .home = "/home/someone",
    });
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("/scratch/drive", resolved);
}

test "resolvePersistentPath: linux honors an absolute XDG_DATA_HOME without HOME" {
    const allocator = std.testing.allocator;
    const resolved = try resolvePersistentPath(allocator, .linux, .{
        .xdg_data_home = "/data/home",
    });
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("/data/home/ziglop", resolved);
}

test "resolvePersistentPath: linux ignores empty or relative XDG_DATA_HOME (spec: unset)" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", "relative/path" }) |degenerate| {
        const resolved = try resolvePersistentPath(allocator, .linux, .{
            .xdg_data_home = degenerate,
            .home = "/home/someone",
        });
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/home/someone/.local/share/ziglop", resolved);
    }
}

test "resolvePersistentPath: linux defaults into the XDG data dir under HOME" {
    const allocator = std.testing.allocator;
    const resolved = try resolvePersistentPath(allocator, .linux, .{
        .home = "/home/someone",
    });
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("/home/someone/.local/share/ziglop", resolved);
}

test "resolvePersistentPath: macos uses Application Support" {
    const allocator = std.testing.allocator;
    const resolved = try resolvePersistentPath(allocator, .macos, .{
        .home = "/Users/someone",
    });
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(
        "/Users/someone/Library/Application Support/ziglop",
        resolved,
    );
}

test "resolvePersistentPath: windows uses LOCALAPPDATA, falls back to USERPROFILE" {
    const allocator = std.testing.allocator;
    const local = try resolvePersistentPath(allocator, .windows, .{
        .localappdata = "C:/Users/someone/AppData/Local",
    });
    defer allocator.free(local);
    try std.testing.expectEqualStrings("C:/Users/someone/AppData/Local/ziglop", local);

    const fallback = try resolvePersistentPath(allocator, .windows, .{
        .userprofile = "C:/Users/someone",
    });
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("C:/Users/someone/AppData/Local/ziglop", fallback);
}

test "resolvePersistentPath: errors when no rule has its variables" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.EnvironmentVariableMissing,
        resolvePersistentPath(allocator, .linux, .{}),
    );
    try std.testing.expectError(
        error.EnvironmentVariableMissing,
        resolvePersistentPath(allocator, .macos, .{}),
    );
    try std.testing.expectError(
        error.EnvironmentVariableMissing,
        resolvePersistentPath(allocator, .windows, .{}),
    );
}
