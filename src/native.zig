//! Native (desktop) entry point. Root source of the native exe. This is one of
//! the two files that compile against raylib (via raylib_backend.zig); the
//! shared game logic in main.zig stays raylib-free. It sets up the allocator,
//! IO, the persistent data directory (~/.ziglop by default, overridable via
//! --data-dir or $ZIGLOP_DATA), and the FileSource, then hands control to
//! main.run with a RaylibBackend. An optional --replay <path> flag loads a
//! session log and reconstructs the session before the loop starts. See
//! DESIGN → File System & IO + Logging & Replay.

const std = @import("std");
const game = @import("main.zig");
const session_setup = @import("session_setup.zig");
const RaylibBackend = @import("raylib_backend.zig").RaylibBackend;
const types = @import("types.zig");
const FileSource = @import("file_source.zig").FileSource;
const crash_dump = @import("crash_dump.zig");

/// Panic handler: dumps the live session log before trapping. See
/// crash_dump.zig.
pub const panic = crash_dump.panic;

pub fn main(init: std.process.Init.Minimal) void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Resolve and open the persistent data dir. Resolution order:
    //   1. --data-dir <path> command-line flag (explicit, per-invocation)
    //   2. $ZIGLOP_DATA env var (ambient, applies to every run)
    //   3. $HOME/.ziglop (default)
    // Created if missing. All writable artifacts (saves, logs, replays) live
    // here, and shipped-content reads check here first for player mods.
    const data_dir_override = parseStringFlag(init.args, allocator, "--data-dir");
    const replay_path = parseStringFlag(init.args, allocator, "--replay");
    const persistent_dir = openPersistentDir(io, allocator, data_dir_override) catch
        @panic("failed to open persistent data directory");
    defer persistent_dir.close(io);

    const file_source = FileSource.init(io, persistent_dir);

    // Open at half the reference resolution; the window is resizable and the
    // renderer scales reference-space content to the actual viewport.
    var backend = RaylibBackend.init(
        allocator,
        @divTrunc(types.reference_width, 2),
        @divTrunc(types.reference_height, 2),
        "Ziglop",
        &file_source,
    );
    defer backend.deinit();

    var setup = session_setup.createSessionSetup(allocator, &file_source, io, &backend);
    setup.fixupPointers();
    // Replay a session log from the command line (--replay <path>): load +
    // reconstruct the session from the event history before entering the
    // game loop. The game resumes at the end of the log. Recoverable — a
    // bad path / corrupt file surfaces a dismissible popup and the game
    // falls back to the main menu instead of crashing. See DESIGN → Logging
    // & Replay.
    if (replay_path) |path| {
        game.loadAndReconstructSession(&setup.frame_state.history, path, io);
    }
    // Open the audio device + load sfx/music after settings are available.
    // No-op-safe if the device can't open (the game runs silent). See
    // DESIGN → Audio.
    backend.initAudio(setup.frame_state.history.settings);
    game.run(&backend, &setup);
}

/// Scan argv for a string flag (`--name <value>` or `--name=<value>`) and
/// return the path (caller-owned dupe) if present. Returns null if the flag
/// isn't given. A `--name` with no following value prints a warning and is
/// treated as absent. Used for `--data-dir` and `--replay`.
fn parseStringFlag(
    args: std.process.Args,
    allocator: std.mem.Allocator,
    name: []const u8,
) ?[]u8 {
    var iter = std.process.Args.Iterator.init(args);
    defer iter.deinit();
    _ = iter.next(); // skip program name
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, name)) {
            if (iter.next()) |value| {
                return allocator.dupe(u8, value) catch @panic("failed to dupe flag value");
            }
            std.debug.print("warning: {s} given without a value; ignoring\n", .{name});
            return null;
        }
        if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') {
            const value = arg[name.len + 1 ..];
            return allocator.dupe(u8, value) catch @panic("failed to dupe flag value");
        }
    }
    return null;
}

/// Resolve and open the persistent data directory path, creating it if missing.
/// `flag_override` (from --data-dir) takes precedence over $ZIGLOP_DATA, which
/// takes precedence over the $HOME/.ziglop default. The caller closes the
/// returned Dir.
fn openPersistentDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    flag_override: ?[]const u8,
) !std.Io.Dir {
    const path = resolvePersistentPath(allocator, flag_override) catch
        @panic("could not resolve persistent data path: pass --data-dir, or set $HOME or $ZIGLOP_DATA");
    defer allocator.free(path);

    // mkdir -p then open. Idempotent — succeeds if the dir already exists.
    return std.Io.Dir.cwd().createDirPathOpen(io, path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    });
}

/// Build the persistent data dir path in priority order:
///   1. --data-dir flag value (already resolved by the caller)
///   2. $ZIGLOP_DATA (override for dev / portable installs / tests)
///   3. $HOME/.ziglop
/// Returned bytes are caller-owned. Returns an error if none are available.
fn resolvePersistentPath(
    allocator: std.mem.Allocator,
    flag_override: ?[]const u8,
) ![]u8 {
    if (flag_override) |path| return allocator.dupe(u8, path);

    // libc is linked (via raylib), so std.c.getenv is available on the native
    // target. native.zig is excluded from the headless test build, so this
    // never compiles there.
    if (std.c.getenv("ZIGLOP_DATA")) |override| {
        return allocator.dupe(u8, std.mem.sliceTo(override, 0));
    }
    if (std.c.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.ziglop", .{std.mem.sliceTo(home, 0)});
    }
    return error.EnvironmentVariableMissing;
}
