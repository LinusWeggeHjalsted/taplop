//! The upstream-repo link opener (the main-menu "Explore the code"
//! button): opens `build_info.repo_url` - the `origin` remote's URL,
//! normalized to https at build time (see build.zig `computeRepoUrl`) - in
//! the player's browser. A pure input-path side effect, the import_game
//! precedent: no event, nothing recorded (nothing about the game state
//! changes). Web: `window.open` through the emscripten JS seam (the
//! file_source.zig pattern); native: the platform's URL handler as a
//! best-effort child process.

const std = @import("std");
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
    const opener = if (@import("builtin").os.tag == .macos) "open" else "xdg-open";
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const result = std.process.run(allocator, threaded_io.io(), .{
        .argv = &.{ opener, build_info.repo_url },
    }) catch |open_error| {
        std.debug.print("warning: failed to open the repo link in a browser ({} - {s} missing?)\n", .{ open_error, opener });
        return;
    };
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

// The emscripten JS seam extern (the file_source.zig pattern): the symbol
// is only referenced from the comptime emscripten branch above, so native
// and the headless test build never need to resolve it.
extern fn emscripten_run_script(script: [*:0]const u8) void;
