//! The upstream-repo link click (the main-menu repo-link button): web
//! opens the repo in a NEW browser tab; native queues the URL for the
//! platform clipboard (SessionState.pending_clipboard_text - frame()
//! drains it and the backend applies it via raylib's SetClipboardText).
//! A pure input-path side effect, the import_game precedent: no event,
//! nothing recorded. The URL is `build_info.repo_url` - the `origin`
//! remote's address, normalized to https at build time (see build.zig
//! computeRepoUrl).
//!
//! WHY no process spawn on native (the earlier xdg-open/open design was
//! removed): three runtime bugs in twenty lines (a zero Io.Limit rejects
//! even an empty stream; Threaded.init defaults its environ to EMPTY so
//! the child got no PATH/DISPLAY and exited 3; std.process.run never
//! errors on a nonzero child exit - each invisible to the compiler), plus
//! a frame-blocking wait on the child and per-OS opener binaries we would
//! own forever, untestable headless. The clipboard is one raylib call
//! behind the existing backend seam. History in DONE.md.

const std = @import("std");
const build_info = @import("build_info");
const state = @import("state.zig");

/// Handle the repo-link button's click. No-op when the build carries no
/// repo URL (the button is not emitted then either).
pub fn handleRepoLinkClick(history: *state.GameStateHistory) void {
    if (build_info.repo_url.len == 0) return;
    if (@import("builtin").os.tag == .emscripten) {
        // '_blank' is spec-defined to create a NEW browsing context - it
        // can never navigate the game tab (which would kill the in-memory
        // session; the unsafe forms are `location = url` and '_self').
        // 'noopener' is opener hygiene; a popup-blocked call no-ops in the
        // safe direction. Runtime-formatted (bufPrintZ gives the NUL the C
        // extern needs) - the file_source JS-seam pattern.
        var script_buffer: [512]u8 = undefined;
        const script = std.fmt.bufPrintZ(
            &script_buffer,
            "window.open('{s}', '_blank', 'noopener')",
            .{build_info.repo_url},
        ) catch return;
        emscripten_run_script(script.ptr);
        return;
    }
    // Native: queue the clipboard copy - drained by frame() and applied
    // via the backend (raylib's SetClipboardText, cross-platform by
    // construction - the platform seam owns the platform).
    history.session.queueClipboardText(history.backing_allocator, build_info.repo_url);
}

// The emscripten JS seam extern (the file_source.zig pattern): the symbol
// is only referenced from the comptime emscripten branch above, so native
// and the headless test build never need to resolve it.
extern fn emscripten_run_script(script: [*:0]const u8) void;
