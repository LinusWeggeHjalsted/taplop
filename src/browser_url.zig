//! The upstream-repo link opener (the main-menu "Explore the code"
//! button): opens `build_info.repo_url` - the `origin` remote's URL,
//! normalized to https at build time (see build.zig `computeRepoUrl`) - in
//! the player's browser. A pure input-path side effect, the import_game
//! precedent: no event, nothing recorded (nothing about the game state
//! changes). Web: `window.open` through the emscripten JS seam (the
//! file_source.zig pattern); native: the platform's URL handler as a
//! best-effort child process.

const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");

/// Open the repo link in a new browser tab. Best-effort: a failed native
/// spawn logs a warning and returns (a machine without `xdg-open`/`open`
/// must never crash the game over a link). No-op when the build carries no
/// repo URL (no git / no origin remote / an unrecognized URL form - the
/// button is not emitted then either).
pub fn openRepoLink(allocator: std.mem.Allocator) void {
    if (build_info.repo_url.len == 0) return;
    if (@import("builtin").os.tag == .emscripten) {
        // Runtime-formatted (bufPrintZ gives the NUL the C extern needs),
        // matching the file_source JS seams' handling of runtime values.
        var script_buffer: [512]u8 = undefined;
        const script = std.fmt.bufPrintZ(
            &script_buffer,
            "window.open('{s}', '_blank')",
            .{build_info.repo_url},
        ) catch return;
        emscripten_run_script(script.ptr);
        return;
    }
    // The platform's URL handler: `open` on macOS, `xdg-open` on the Linux
    // desktops (a future Windows port wants `start` via cmd).
    const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
    var threaded_io = std.Io.Threaded.init(allocator, .{
        // The child needs the FULL process environment (PATH, DISPLAY,
        // DBUS, XDG_* - xdg-open's browser detection reads them all).
        // Threaded.init defaults its environ to EMPTY, which spawns
        // children with no environment at all (the exit-3 "no method
        // available" bug this field exists to fix).
        .environ = processEnviron(),
    });
    defer threaded_io.deinit();
    const result = std.process.run(allocator, threaded_io.io(), .{
        .argv = &.{ opener, build_info.repo_url },
    }) catch |open_error| {
        std.debug.print("warning: failed to open the repo link in a browser ({} - {s} missing?)\n", .{ open_error, opener });
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    // `run` succeeding does NOT mean the opener worked - it never errors on
    // a nonzero child exit (the silent-failure class that hid the empty-
    // environ bug; "no warning" was a false positive until this check).
    switch (result.term) {
        .exited => |exit_code| if (exit_code != 0) {
            std.debug.print("warning: the repo-link opener ({s}) exited with code {d}\n", .{ opener, exit_code });
        },
        else => std.debug.print("warning: the repo-link opener did not exit cleanly ({any})\n", .{result.term}),
    }
}

// The emscripten JS seam extern (the file_source.zig pattern): the symbol
// is only referenced from the comptime emscripten branch above, so native
// and the headless test build never need to resolve it.
extern fn emscripten_run_script(script: [*:0]const u8) void;

/// The process environment for spawned children (see the Threaded init
/// call above). POSIX + libc (the native game links libc via raylib): read
/// off the C `environ` global - start.zig wires an environ source only for
/// libc builds, so there is no portable fallback without it (the headless
/// test build links no libc; the branch is comptime-unreachable there,
/// which is also why the extern reference never needs to resolve). Other
/// targets: the empty environ (a degraded spawn - the opener probably
/// fails, and the term check above warns).
fn processEnviron() std.process.Environ {
    if (builtin.link_libc) {
        switch (builtin.os.tag) {
            .windows, .wasi, .emscripten, .freestanding, .other => {},
            else => {
                const c_environ = std.c.environ;
                var count: usize = 0;
                while (c_environ[count] != null) : (count += 1) {}
                return .{ .block = .{ .slice = c_environ[0..count :null] } };
            },
        }
    }
    return .empty;
}
