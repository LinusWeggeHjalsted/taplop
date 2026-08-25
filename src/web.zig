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
//! See AGENTS.md "Platform Seam (raylib)" + "File System & IO" + the web
//! build roadmap.
//!
//! The emscripten externs are declared directly here rather than importing
//! the zemscripten root module (which has a Zig-version incompat with
//! std.testing.refAllDeclsRecursive on 0.16). The zemscripten build functions
//! (emccStep, emccDefaultFlags, etc.) are still used from build.zig.

const std = @import("std");
const rl = @import("raylib");
const game = @import("main.zig");
const session_setup = @import("session_setup.zig");
const RaylibBackend = @import("raylib_backend.zig").RaylibBackend;
const types = @import("types.zig");
const FileSource = @import("file_source.zig").FileSource;
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

/// Panic handler: dumps the live session log before trapping. Replaces the
/// minimal `std.debug.simple_panic` (which only prints to stderr) with a
/// handler that also writes `crashes/crash_<timestamp>.txt` to the persistent
/// dir. Best-effort on web — the IDBFS flush may not complete before the tab
/// closes, so the crash file may be lost on a web crash (native is the
/// reliable path). See crash_dump.zig.
pub const panic = crash_dump.panic;

/// The virtual path where the IDBFS-backed persistent dir is mounted. Mirrors
/// $HOME/.ziglop on native — FileSource reads/writes against this path.
const persistent_virtual_path = "/ziglop";

/// Holds the session-long state the main-loop callback needs access to. The
/// emscripten callback API passes a single `*anyopaque`, so we bundle the
/// backend + SessionSetup here and pass a pointer to this. The SessionSetup
/// (which owns the weapon_type_definitions array + FrameState) MUST be
/// heap-allocated because main() returns immediately — a stack-local
/// SessionSetup would leave dangling pointers (history.weapon_type_definitions
/// points into it). Heap allocation via c_allocator lives until the tab closes.
const WebSession = struct {
    backend: RaylibBackend,
    setup: session_setup.SessionSetup,
};

/// Emscripten main-loop callback — called once per requestAnimationFrame.
/// Casts the userdata back to the session and calls the shared frame(). The
/// browser handles yielding (returning from this callback = yield), so unlike
/// the native driver we never call backend.waitTime here.
fn frameCallback(arg: *anyopaque) callconv(.c) void {
    const session: *WebSession = @ptrCast(@alignCast(arg));
    game.frame(&session.backend, &session.setup.frame_state);
}

/// Mount an emscripten IDBFS slice at the persistent virtual path and load any
/// existing data from IndexedDB. Runs inline JS via emscripten_run_script
/// (the FS object is available in the module scope). The syncfs load is
/// async; a miss on a read before it completes just means "no prior data",
/// which is the correct result for a first run. Writes flush to IndexedDB
/// automatically (FileSource.writeFile calls FS.syncfs after each write on
/// emscripten). A beforeunload listener fires a final best-effort flush on
/// tab close.
fn mountPersistentDir() void {
    const script =
        \\FS.mkdir('/ziglop');
        \\FS.mount(IDBFS, {}, '/ziglop');
        \\FS.syncfs(true, function(err) {
        \\  if (err) console.error('IDBFS syncfs load failed:', err);
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
/// builds the FileSource + RaylibBackend + FrameState, registers the shared
/// frame() as the emscripten main loop, and returns — emscripten keeps the
/// module alive via setMainLoopArg's simulate_infinite_loop flag.
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
    // path as the persistent dir for FileSource.
    mountPersistentDir();
    const persistent_dir = std.Io.Dir.cwd().openDir(io, persistent_virtual_path, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch @panic("failed to open /ziglop persistent dir");
    defer persistent_dir.close(io);

    const file_source = FileSource.init(io, persistent_dir);

    // Open at half the reference resolution; the canvas is resizable and the
    // renderer scales reference-space content to the actual viewport.
    var backend = RaylibBackend.init(
        allocator,
        @divTrunc(types.reference_width, 2),
        @divTrunc(types.reference_height, 2),
        "Ziglop",
        &file_source,
    );
    defer backend.deinit();

    // Shared session setup (config load + starting state + history + frame
    // state) — the same sequence as native's run(), extracted into
    // createSessionSetup so both platforms stay in sync. The returned
    // SessionSetup is placed in the heap-allocated WebSession (not on main()'s
    // stack, which would leave dangling pointers after main() returns).
    const setup = session_setup.createSessionSetup(allocator, &file_source, io, &backend);

    const session = allocator.create(WebSession) catch @panic("failed to allocate WebSession");
    session.* = .{
        .backend = backend,
        .setup = setup,
    };
    // Fix up the history's weapon_type_definitions pointer to point at the
    // SessionSetup's field (now in its stable heap location).
    session.setup.fixupPointers();

    // Open the audio device + load sfx/music after settings are available.
    // No-op-safe if the device can't open (the game runs silent). See
    // DESIGN → Audio. Web audio may require a user gesture to start in some
    // browsers; the stream simply won't play until then, never crashing.
    (&session.backend).initAudio(session.setup.frame_state.history.settings);

    // Register the live history so a panic can dump its event log before
    // trapping (best-effort on web — see crash_dump.zig). No uninstall: the
    // tab/process closing IS the shutdown.
    crash_dump.install(&session.setup.frame_state.history);

    // Register the callback and let emscripten drive the frame loop.
    // fps = -1 lets the browser use requestAnimationFrame (~monitor refresh).
    // simulate_infinite_loop = 1 keeps the module alive after main() returns.
    emscripten_set_main_loop_arg(frameCallback, session, -1, 1);
}
