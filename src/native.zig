//! Native (desktop) entry point. Root source of the native exe. This is one
//! of the files that compile against raylib (via `raylib/backend.zig` - the
//! only directory importing raylib); the
//! shared game logic in main.zig stays raylib-free. It sets up the allocator,
//! IO, the persistent data directory (per-OS default - `$XDG_DATA_HOME`
//! or `$HOME/.local/share/ziglop` on Linux, `$HOME/Library/Application
//! Support/ziglop` on macOS - overridable
//! via --data-dir or $ZIGLOP_DATA), and the FileSource, then hands control to
//! main.run with a RaylibBackend. Optional flags: `--replay <path>` loads a
//! session-log bundle (a directory containing session_log.txt + content/ -
//! see session_log_bundle.zig) and reconstructs the session before the loop
//! starts;
//! `--diagnostics` activates the platform diagnostics log in ANY build
//! (release included - dev-mode builds default active). Also spawns the
//! console reader thread (stdin - always on; see DESIGN → Input → Console
//! input). See DESIGN → File System & IO + Logging & Replay + Platform Seam
//! → Diagnostics.

const std = @import("std");
const builtin = @import("builtin");
const game = @import("main.zig");
const session_setup = @import("session_setup.zig");
const RaylibBackend = @import("raylib/backend.zig").RaylibBackend;
const types = @import("types.zig");
const FileSource = @import("file_source.zig").FileSource;
const crash_dump = @import("crash_dump.zig");
const console = @import("console.zig");
const persistent_path = @import("persistent_path.zig");

// Forces analysis of the interposed `open` (the evdev joystick-claim
// guard - src/raylib/evdev_guard.zig) so its exported symbols join the
// link. The file self-gates to Linux, so this is a no-op on the macOS
// cross build.
comptime {
    _ = @import("raylib/evdev_guard.zig");
}

/// Panic handler: dumps the live session log before trapping. See
/// crash_dump.zig.
pub const panic = crash_dump.panic;

pub fn main(init: std.process.Init.Minimal) void {
    // Debug + ReleaseSafe: DebugAllocator (double-free detection; stack
    // traces are Debug-only - the std default zeroes them elsewhere).
    // Other release configs: libc malloc, same as the web build - at those
    // optimize levels DebugAllocator's safety is off by default
    // (std.debug.runtime_safety), leaving only its mmap-backed slowness.
    // The leak report never fires in any config: main() doesn't deinit the
    // allocator, and process-lifetime allocations are intentional, so a
    // deinit would only report false positives.
    // Design: DESIGN → Memory & Budget → Session allocator.
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = if (builtin.mode == .debug or builtin.mode == .safe)
        debug_allocator.allocator()
    else
        std.heap.c_allocator;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Resolve and open the persistent data dir. Resolution order:
    //   1. --data-dir <path> command-line flag (explicit, per-invocation)
    //   2. $ZIGLOP_DATA env var (ambient, applies to every run)
    //   3. per-OS default (the XDG data dir on Linux,
    //      $HOME/Library/Application Support/ziglop on macOS - the mac
    //      player-visible convention; see DESIGN → File System & IO)
    // Created if missing. All writable artifacts (saves, logs, replays) live
    // here, and shipped-content reads check here first for player mods.
    const data_dir_override = parseStringFlag(init.args, allocator, "--data-dir");
    const replay_path = parseStringFlag(init.args, allocator, "--replay");
    const diagnostics_requested = parseBoolFlag(init.args, allocator, "--diagnostics");
    // The resolved path outlives the Dir handle: it's stored on the session
    // for user-facing messages (the Export Save tooltip). Process-lifetime
    // allocation, never freed.
    const persistent_dir_path = resolvePersistentPath(allocator, data_dir_override) catch
        @panic("could not resolve persistent data path: pass --data-dir, or set $ZIGLOP_DATA, $XDG_DATA_HOME, or $HOME");
    const persistent_dir = openPersistentDir(io, persistent_dir_path) catch
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

    // Diagnostics activation (--diagnostics): the runtime on-switch for the
    // platform log, valid on ANY build including plain release - the binary
    // that exhibits a bug produces its own data. Dev-mode builds default
    // active (set at backend init); the flag ORs in before the first render.
    // See DESIGN → Platform Seam → Diagnostics.
    if (diagnostics_requested) {
        backend.diagnostics.enabled = true;
    }

    var setup = session_setup.createSessionSetup(allocator, &file_source, io, &backend);
    setup.fixupPointers();
    // User-facing persistent path (Export Save tooltip). Web leaves this
    // null (see SessionState.persistent_dir_path).
    setup.frame_state.history.session.persistent_dir_path = persistent_dir_path;
    // Replay a session-log bundle from the command line (--replay <path>):
    // load + reconstruct the session from the event history before entering
    // the game loop, with the bundle's embedded content as the authority
    // (the exact bytes the original session read, regardless of later file
    // changes). The game resumes at the end of the log. Recoverable - a bad
    // path / corrupt bundle surfaces a dismissible popup and the game falls
    // back to the main menu instead of crashing. See DESIGN → Logging &
    // Replay.
    if (replay_path) |path| {
        game.loadAndReconstructSession(&setup.frame_state.history, path, io);
    }
    // Console input (stdin - always on, native only; see DESIGN → Input →
    // Console input): the dump output writer goes on the queue first (the
    // MAIN thread's Io - dumps are written from frame()), then the reader
    // thread blocks on stdin lines and parses them into the queue. The
    // game's frame drain (main.frame's applyFrameCommand call) consumes one
    // command per frame. An stdin-less launch (double-click, the mac app
    // bundle) is immediate EOF - the thread exits, zero cost.
    setup.frame_state.console_queue.output = std.Io.File.stdout().writer(
        io,
        &setup.frame_state.console_queue.output_buffer,
    );
    // The console-ready prompt gates on stdin being a TTY - "a human is
    // typing at the other end". The channel itself stays always-on: a
    // piped script drives identically, just unprompted (a prompt over a
    // pipe would invite typing the script's pipe can never receive), and
    // an stdin-less launch (double-click, the mac bundle) prints nothing.
    // A failed check degrades to silent - the prompt is a convenience,
    // never a gate on the channel.
    setup.frame_state.console_queue.interactive =
        std.Io.File.stdin().isTty(io) catch false;
    console.announceConsoleInput(&setup.frame_state.console_queue);
    const console_reader = std.Thread.spawn(
        .{},
        consoleReaderThread,
        .{&setup.frame_state.console_queue},
    ) catch null;
    if (console_reader) |thread| {
        // Detached: a quit while the reader is blocked on stdin leaves the
        // thread to die with the process - joining would hang the exit
        // waiting for input that never comes.
        thread.detach();
    } else {
        std.debug.print("warning: could not spawn the console reader thread; stdin input disabled\n", .{});
    }

    // Open the audio device + load sfx/music after settings are available.
    // No-op-safe if the device can't open (the game runs silent). See
    // DESIGN → Audio.
    backend.initAudio(setup.frame_state.history.settings);
    game.run(&backend, &setup);
}

/// The console reader thread: blocks on stdin lines, parses each into the
/// session's console queue (the game's frame drain consumes one command per
/// frame). EOF - or a read error / oversized line - exits the thread; parse
/// errors report on stderr and keep reading. The queue outlives the thread
/// (it lives on the SessionSetup, which lives in main's frame for the whole
/// process).
fn consoleReaderThread(queue: *console.ConsoleQueue) void {
    // The reader thread's own Io (an Io handle is not shared across threads);
    // libc malloc backs it (libc is linked via raylib).
    var threaded_io = std.Io.Threaded.init(std.heap.c_allocator, .{});
    defer threaded_io.deinit();
    var read_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(threaded_io.io(), &read_buffer);
    while (true) {
        const line = stdin_reader.interface.takeDelimiter('\n') catch |err| {
            std.debug.print("console: stdin read ended ({s})\n", .{@errorName(err)});
            break;
        } orelse break; // EOF
        const outcome = console.parseCommandLine(line);
        switch (outcome) {
            .skip => {},
            .command => |command| queue.push(command),
            .err => std.debug.print("console: {s}\n", .{outcome.errorMessage()}),
        }
    }
}

/// Scan argv for a string flag (`--name <value>` or `--name=<value>`) and
/// return the path (caller-owned dupe) if present. Returns null if the flag
/// isn't given. A `--name` with no following value prints a warning and is
/// treated as absent. Used for `--data-dir` and `--replay`.
///
/// A leading `~/` (or a lone `~`) in the value is expanded to `$HOME` -
/// bash doesn't perform tilde expansion after `=` in command arguments, so
/// `--replay=~/.local/share/ziglop/...` would otherwise arrive with a
/// literal `~`.
fn parseStringFlag(
    args: std.process.Args,
    allocator: std.mem.Allocator,
    name: []const u8,
) ?[]u8 {
    var iter = std.process.Args.Iterator.initAllocator(args, allocator) catch return null;
    defer iter.deinit();
    _ = iter.next(); // skip program name
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, name)) {
            if (iter.next()) |value| {
                return expandTilde(allocator, value) catch
                    @panic("failed to dupe flag value");
            }
            std.debug.print("warning: {s} given without a value; ignoring\n", .{name});
            return null;
        }
        if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') {
            const value = arg[name.len + 1 ..];
            return expandTilde(allocator, value) catch
                @panic("failed to dupe flag value");
        }
    }
    return null;
}

/// Whether a boolean flag (`--name`) is present in argv. No value form -
/// presence is the whole meaning. Used for `--diagnostics`. The
/// allocator-taking iterator init is the cross-platform form (`init`
/// compiles only on non-Windows native targets).
fn parseBoolFlag(
    args: std.process.Args,
    allocator: std.mem.Allocator,
    name: []const u8,
) bool {
    var iter = std.process.Args.Iterator.initAllocator(args, allocator) catch return false;
    defer iter.deinit();
    _ = iter.next(); // skip program name
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

/// Expand a leading `~` or `~/` to `$HOME`. A value that doesn't start with
/// `~` is duped unchanged. If `~` is present but `$HOME` is unset, the value
/// is duped unchanged (the caller's file read will fail with a clear
/// FileNotFound rather than a cryptic env error). `std.c.getenv` is
/// available on the native target (libc is linked via raylib); native.zig is
/// excluded from the headless test build so this never compiles there.
fn expandTilde(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0 or value[0] != '~') return allocator.dupe(u8, value);
    const home = std.c.getenv("HOME") orelse return allocator.dupe(u8, value);
    const home_slice = std.mem.sliceTo(home, 0);
    if (value.len == 1) return allocator.dupe(u8, home_slice); // bare `~`
    // `~/...` → `$HOME/...` (drop the `~`, keep the `/`).
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ home_slice, value[1..] });
}

/// Open the persistent data directory at `path`, creating it if missing.
/// The caller closes the returned Dir.
fn openPersistentDir(
    io: std.Io,
    path: []const u8,
) !std.Io.Dir {
    // mkdir -p then open. Idempotent - succeeds if the dir already exists.
    return std.Io.Dir.cwd().createDirPathOpen(io, path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    });
}

/// Build the persistent data dir path in priority order:
///   1. --data-dir flag value (already resolved by the caller)
///   2. $ZIGLOP_DATA (override for dev / portable installs / tests)
///   3. per-OS default (the shared resolution site - persistent_path.zig;
///      it also serves the dev report tools, so the default exists once)
/// The env snapshot is eager (all five reads are cheap) so the shared
/// module stays pure over an explicit Env. libc is linked (via raylib),
/// so std.c.getenv is available on the native target; native.zig is
/// excluded from the headless test build, so this never compiles there.
/// Returned bytes are caller-owned. Returns an error if none are
/// available.
fn resolvePersistentPath(
    allocator: std.mem.Allocator,
    flag_override: ?[]const u8,
) ![]u8 {
    if (flag_override) |path| return allocator.dupe(u8, path);
    return persistent_path.resolvePersistentPath(
        allocator,
        builtin.target.os.tag,
        .{
            .ziglop_data = getenvSlice("ZIGLOP_DATA"),
            .home = getenvSlice("HOME"),
            .xdg_data_home = getenvSlice("XDG_DATA_HOME"),
            .localappdata = getenvSlice("LOCALAPPDATA"),
            .userprofile = getenvSlice("USERPROFILE"),
        },
    );
}

/// getenv as a proper slice (NUL stripped); null when unset.
fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(value, 0);
}
