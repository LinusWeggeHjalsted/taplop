//! Web (emscripten) entry point.
//!
//! Mirrors native.zig but with two platform differences:
//!   - Persistence: instead of $HOME/.ziglop, mounts an emscripten IDBFS slice
//!     at the virtual path /ziglop (backed by IndexedDB — survives browser
//!     close). FileSource reads/writes against that dir exactly like native.
//!   - Loop: instead of a blocking while-loop, registers frame() (the shared
//!     per-frame core from main.zig) via emscripten_set_main_loop_arg. The
//!     browser calls it once per requestAnimationFrame; yielding is the
//!     browser's job, so no waitTime/sleep (and no asyncify).
//! See DESIGN → Platform Seam (raylib) + "File System & IO" + the web
//! build roadmap.
//!
//! The emscripten externs are declared directly here rather than importing
//! the zemscripten root module (which has a Zig-version incompat with
//! std.testing.refAllDeclsRecursive on 0.16). The zemscripten build functions
//! (emccStep, emccDefaultFlags, etc.) are still used from build.zig.

const std = @import("std");
const game = @import("main.zig");
const session_setup = @import("session_setup.zig");
const RaylibBackend = @import("raylib_backend.zig").RaylibBackend;
const types = @import("types.zig");
const FileSource = @import("file_source.zig").FileSource;
const file_source_mod = @import("file_source.zig");
const crash_dump = @import("crash_dump.zig");

// --- Emscripten externs (minimal subset of what zemscripten wraps) ---

const MainLoopArgCallback = *const fn (arg: *anyopaque) callconv(.c) void;
extern fn emscripten_set_main_loop_arg(
    cb: MainLoopArgCallback,
    arg: *anyopaque,
    fps: c_int,
    simulate_infinite_loop: c_int,
) void;
extern fn emscripten_run_script(script: [*:0]const u8) void;
/// Evaluate a JS expression and return it as a c_int. Used to poll the
/// `__ziglopSyncfsLoaded` flag set by the IDBFS load callback (see
/// `mountPersistentDir`) — IndexedDB is async-only, so the flag is the
/// boot gate that defers startup reads until persisted state is visible.
extern fn emscripten_run_script_int(script: [*:0]const u8) c_int;

/// Panic handler: dumps the live session log before trapping. Replaces the
/// minimal `std.debug.simple_panic` (which only prints to stderr) with a
/// handler that also writes `crashes/crash_<timestamp>.txt` to the persistent
/// dir. Best-effort on web — the IDBFS flush may not complete before the tab
/// closes, so the crash file may be lost on a web crash (native is the
/// reliable path). See crash_dump.zig.
pub const panic = crash_dump.panic;

/// The virtual path where the IDBFS-backed persistent dir is mounted. Mirrors
/// the native persistent dir ($HOME/.ziglop on Linux, ~/Library/Application
/// Support/ziglop on macOS — see native.zig) — FileSource reads/writes
/// against this path.
/// The constant lives in file_source.zig (shared with the JS seams that
/// build absolute FS paths, e.g. triggerBrowserDownload).
const persistent_virtual_path = file_source_mod.persistent_mount_path;

/// Holds the session-long state the main-loop callback needs access to. The
/// emscripten callback API passes a single `*anyopaque`, so we bundle the
/// backend + boot state here and pass a pointer to this. The `setup` field is
/// `null` until the two-phase boot completes (see `frameCallback`); the
/// `backend`, `file_source`, `io`, and `allocator` references are populated
/// up front in `main()` and stay valid for the tab's lifetime (main() never
/// returns — `emscripten_set_main_loop_arg`'s `simulate_infinite_loop` halts
/// control flow, so the `defer`s in main() never run and its locals live on).
/// `file_source`/`io`/`allocator` point at those main() locals, same as the
/// backend already does (`backend.file_source`).
const WebSession = struct {
    backend: RaylibBackend,
    /// `null` until the IDBFS load lands; then `createSessionSetup` fills it
    /// and `frame()` drives it every rAF thereafter.
    setup: ?session_setup.SessionSetup = null,
    file_source: *const FileSource,
    io: std.Io,
    allocator: std.mem.Allocator,
    booted: bool = false,
};

/// Emscripten main-loop callback — called once per requestAnimationFrame.
/// Two-phase boot:
///
///   1. BOOTING (every rAF until the IDBFS load completes): poll
///      `window.__ziglopSyncfsLoaded` (set by the `syncfs(true, …)` callback
///      in `mountPersistentDir`). IndexedDB is async-only, so the in-memory
///      IDBFS layer is empty until that callback fires — startup reads
///      (`settings.txt` overlay, autosave detection) made before it would
///      race and miss persisted state every launch (falling back to
///      defaults). Until the flag is set, return without rendering — a few
///      brief blank frames (syncfs is typically <50ms). The GL clear color
///      shows; no swap needed.
///
///   2. BOOTED (first rAF after the flag is set, and every rAF after): run
///      `createSessionSetup` (settings + autosave now visible), `initAudio`,
///      `crash_dump.install`, `fixupPointers`, flip `booted`, then drive
///      `game.frame` every call. The setup step runs ONCE (gated on
///      `!booted`), so it's not repeated.
///
/// This replaces the old per-frame lazy autosave recheck (deleted from
/// `input_handlers.handleIdleInput`) — the root race is fixed at the source,
/// so the recheck poll is dead code on both platforms.
fn frameCallback(arg: *anyopaque) callconv(.c) void {
    const session: *WebSession = @ptrCast(@alignCast(arg));
    if (!session.booted) {
        // Boot gate: wait for the IDBFS load to populate the in-memory layer.
        if (emscripten_run_script_int("window.__ziglopSyncfsLoaded ? 1 : 0") == 0) return;
        // IDBFS is live — startup reads will now see persisted state. Build
        // the session setup (same sequence as native's run(), extracted into
        // createSessionSetup so both platforms stay in sync). The returned
        // SessionSetup is stored in the heap WebSession (not on a stack),
        // keeping history.weapon_type_definitions's pointer valid.
        session.setup = session_setup.createSessionSetup(
            session.allocator,
            session.file_source,
            session.io,
            &session.backend,
        );
        // Fix up the history's weapon_type_definitions pointer to point at
        // the SessionSetup's field (now in its stable heap location).
        session.setup.?.fixupPointers();
        // Open the audio device + load sfx/music after settings are
        // available. No-op-safe if the device can't open (the game runs
        // silent). See DESIGN → Audio. Web audio may require a user gesture
        // to start in some browsers; the stream simply won't play until then,
        // never crashing.
        (&session.backend).initAudio(session.setup.?.frame_state.history.settings);
        // Register the live history so a panic can dump its event log before
        // trapping (best-effort on web — see crash_dump.zig). No uninstall:
        // the tab/process closing IS the shutdown.
        crash_dump.install(&session.setup.?.frame_state.history);
        session.booted = true;
    }
    game.frame(&session.backend, &session.setup.?.frame_state);
}

/// Mount an emscripten IDBFS slice at the persistent virtual path and load any
/// existing data from IndexedDB. Runs inline JS via `emscripten_run_script`
/// (the FS object is available in the module scope). The IDBFS LOAD
/// (`syncfs(true, …)`) is ASYNC — IndexedDB has no synchronous API. It
/// populates the in-memory IDBFS layer via a callback that fires on the event
/// loop; that callback sets `window.__ziglopSyncfsLoaded`, which the main-
/// loop callback polls to gate the two-phase boot (see `frameCallback`).
/// Startup reads (settings.txt overlay, autosave detection) MUST wait for it,
/// or they race and miss persisted state every launch — falling back to
/// defaults. Writes flush to IndexedDB automatically (FileSource.writeFile
/// calls FS.syncfs after each write on emscripten). A beforeunload listener
/// fires a final best-effort flush on tab close.
fn mountPersistentDir() void {
    const script =
        \\FS.mkdir('/ziglop');
        \\FS.mount(IDBFS, {}, '/ziglop');
        \\FS.syncfs(true, function(err) {
        \\  if (err) console.error('IDBFS syncfs load failed:', err);
        \\  window.__ziglopSyncfsLoaded = true;
        \\});
        \\window.addEventListener('beforeunload', function() {
        \\  FS.syncfs(false, function(err) {
        \\    if (err) console.error('IDBFS flush on unload failed:', err);
        \\  });
        \\});
    ;
    emscripten_run_script(script);
}

/// Web entry point. Sets up allocator/IO, mounts the persistent IDBFS dir,
/// builds the FileSource + RaylibBackend, and registers the two-phase
/// `frameCallback` as the emscripten main loop — then returns. emscripten
/// keeps the module alive via `setMainLoopArg`'s `simulate_infinite_loop`
/// flag, so main()'s locals (file_source, io, allocator) live for the tab's
/// lifetime and the WebSession's pointers into them stay valid.
///
/// The session setup (config load + history + frame state) is DEFERRED into
/// the main-loop callback's boot phase — it MUST run after the IDBFS load
/// completes, or its persistent-dir reads race and miss persisted state
/// (settings.txt overlay, autosave). See `frameCallback`.
pub fn main() void {
    // NOTE: web uses c_allocator (emscripten's emmalloc via libc), NOT
    // DebugAllocator. DebugAllocator captures stack traces + uses mmap-based
    // metadata that segfaults on wasm's linear-memory model. Native keeps
    // DebugAllocator for its leak/check diagnostics; web has no need for them
    // (a tab close frees everything) and c_allocator is what Zig's own start
    // code uses for link_libc targets.
    const allocator = std.heap.c_allocator;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Mount IDBFS at /ziglop BEFORE opening the dir, then open that virtual
    // path as the persistent dir for FileSource. The syncfs LOAD is async;
    // startup reads are deferred into the boot phase until it completes.
    mountPersistentDir();
    const persistent_dir = std.Io.Dir.cwd().openDir(io, persistent_virtual_path, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch @panic("failed to open /ziglop persistent dir");
    defer persistent_dir.close(io);

    const file_source = FileSource.init(io, persistent_dir);

    // Open at half the reference resolution; the canvas is resizable and the
    // renderer scales reference-space content to the actual viewport. The
    // window appears immediately — the boot phase only gates config load +
    // the first game.frame, not the window.
    var backend = RaylibBackend.init(
        allocator,
        @divTrunc(types.reference_width, 2),
        @divTrunc(types.reference_height, 2),
        "Ziglop",
        &file_source,
    );
    defer backend.deinit();

    const session = allocator.create(WebSession) catch @panic("failed to allocate WebSession");
    session.* = .{
        .backend = backend,
        .file_source = &file_source,
        .io = io,
        .allocator = allocator,
    };

    // Register the callback and let emscripten drive the frame loop.
    // fps = -1 lets the browser use requestAnimationFrame (~monitor refresh).
    // simulate_infinite_loop = 1 keeps the module alive after main() returns
    // (and halts main's control flow so its locals — which the WebSession
    // points into — live for the tab's lifetime).
    emscripten_set_main_loop_arg(frameCallback, session, -1, 1);
}
