//! Web (emscripten) entry point.
//!
//! Mirrors native.zig but with two platform differences:
//!   - Persistence: instead of the native per-OS default (persistent_path.zig -
//!     e.g. ~/.local/share/ziglop on Linux), the persistent dir is an
//!     in-memory (MEMFS) mount at the virtual path /ziglop - SESSION-SCOPED
//!     (see DESIGN → File System & IO → Web storage model): browser storage
//!     is NEVER touched by the game, nothing persists between sessions by
//!     design (a refresh is a session end), and cross-session data lives in
//!     Import Game / Export Game (ziglop.zip round-trips). Within the
//!     session, FileSource reads/writes the mount exactly like native.
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
const RaylibBackend = @import("raylib/backend.zig").RaylibBackend;
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

/// Panic handler: dumps the live session log before trapping. Replaces the
/// minimal `std.debug.simple_panic` (which only prints to stderr) with a
/// handler that also writes `crashes/crash_<timestamp>.txt` to the persistent
/// dir. Best-effort on web - the persistent dir is in-memory only (the
/// session-scoped storage model), so a crash bundle is a session artifact:
/// catch it with Export Game before refreshing, or it is gone (native is the
/// reliable path). See crash_dump.zig.
pub const panic = crash_dump.panic;

/// The virtual path where the in-memory persistent dir is mounted. Mirrors
/// the native persistent dir (the per-OS default - persistent_path.zig). - FileSource reads/writes
/// against this path.
/// The constant lives in file_source.zig (shared with the JS seams that
/// build absolute FS paths, e.g. triggerBrowserDownload).
const persistent_virtual_path = file_source_mod.persistent_mount_path;

/// Holds the session-long state the main-loop callback needs access to. The
/// emscripten callback API passes a single `*anyopaque`, so we bundle
/// everything here and pass a pointer to this. All fields are populated in
/// `main()` before the main loop is registered, and stay valid for the tab's
/// lifetime (main() never returns - `emscripten_set_main_loop_arg`'s
/// `simulate_infinite_loop` halts control flow, so the `defer`s in main()
/// never run and its locals live on). `file_source`/`io`/`allocator` point at
/// those main() locals, same as the backend already does
/// (`backend.file_source`). The `setup` is created after the struct (it
/// borrows `&session.backend`), on the heap-allocated WebSession - not on a
/// stack - keeping `history.weapon_type_definitions`'s pointer valid.
const WebSession = struct {
    backend: RaylibBackend,
    setup: session_setup.SessionSetup = undefined,
    file_source: *const FileSource,
    io: std.Io,
    allocator: std.mem.Allocator,
};

/// Emscripten main-loop callback - called once per requestAnimationFrame:
/// one `game.frame`, then (if an Import Game completed this frame) the
/// session RE-BOOT at the frame boundary: `game.frame` has returned, so
/// nothing holds references into the old history (a mid-frame swap would
/// be a use-after-free), and the next rAF runs against the fresh boot with
/// everything the imported folder carries applied (the main menu re-renders
/// with the imported autosave's Continue button).
fn frameCallback(arg: *anyopaque) callconv(.c) void {
    const session: *WebSession = @ptrCast(@alignCast(arg));
    game.frame(&session.backend, &session.setup.frame_state);
    // Import Game completed this frame - the re-boot happens NOW, between
    // frames: nothing renders or reads input against the old history by
    // construction (see DESIGN → File System & IO → Web storage model).
    if (session.setup.frame_state.history.session.pending_import_reboot) {
        rebootSession(session);
    }
}

/// The session boot sequence - shared by `main` (first boot) and the
/// Import Game re-boot: build the SessionSetup (all config loads + the
/// fresh history), fix up the weapon-type pointer to its stable home,
/// open the audio device + load sfx/music (settings are loaded), and
/// install the crash-dump hook (the live history a panic dumps). The
/// previous setup must be torn down FIRST on the re-boot path
/// (`rebootSession` does).
fn bootSession(session: *WebSession) void {
    session.setup = session_setup.createSessionSetup(
        session.allocator,
        session.file_source,
        session.io,
        &session.backend,
    );
    // Fix up the history's weapon_type_definitions pointer to point at
    // the SessionSetup's field (now in its stable heap location).
    session.setup.fixupPointers();
    (&session.backend).initAudio(session.setup.frame_state.history.settings);
    crash_dump.install(&session.setup.frame_state.history);
    // The audio queue watchdog (see installAudioLeadWatchdog) - after
    // initAudio so the node exists; per boot so a re-boot re-wraps the
    // fresh node. ALL web builds (the Release-scale banking is exactly the
    // player-facing case).
    installAudioLeadWatchdog();
}

/// Best-effort: resume the re-boot's fresh AudioContext immediately (it
/// was created in a rAF callback - outside a user-gesture handler - so it
/// starts suspended; see the AudioContext console warnings). The Import Game
/// click already gave the page user activation, so browsers that allow
/// sticky-activation resumes close the audio gap right here; ones that
/// require an in-gesture resume reject this (harmless no-op) and miniaudio's
/// own re-registered unlock listener (touchend/click) recovers on the next
/// click - the same one-click sleep as first boot. Reaches into
/// window.miniaudio's device list (the same internals miniaudio's own
/// unlock handler walks) - a raylib/miniaudio upgrade that changes this
/// shape degrades to the no-op + next-click path, never a crash.
fn tryResumeWebAudio() void {
    const script =
        "(function() {" ++
        "  var m = window.miniaudio;" ++
        "  if (!m || !m.devices) return;" ++
        "  for (var i = 0; i < m.devices.length; i++) {" ++
        "    var d = m.devices[i];" ++
        "    if (d && d.webaudio && d.webaudio.state === 'suspended') d.webaudio.resume();" ++
        "  }" ++
        "})();";
    emscripten_run_script(script);
}

/// Re-boot after a completed Import Game: everything the imported folder
/// carries applies (settings, shadow data/ trees, the imported autosave →
/// the Continue button). Runs at the FRAME BOUNDARY only (frameCallback,
/// after `game.frame` returned - see there for the use-after-free story).
/// The old session is torn down, not leaked (`freeSessionSetup`: history
/// deinit + the tracked startup memory), the crash hook uninstalled first
/// (it would point at freed history), audio torn down + re-opened by the
/// boot with the NEW settings. The discarded session's live progress is
/// included in the discard (an import replaces the session - DESIGN →
/// File System & IO → Web storage model).
fn rebootSession(session: *WebSession) void {
    crash_dump.uninstall();
    session.backend.deinitAudio();
    session_setup.freeSessionSetup(&session.setup);
    bootSession(session);
    tryResumeWebAudio();
}

/// Mount the persistent virtual path as a plain in-memory (MEMFS)
/// directory - the session-scoped storage model (see DESIGN → File System
/// & IO → Web storage model): the persistent dir lives ONLY in the tab's
/// memory for the session; browser storage is NEVER touched by the game
/// (no IDBFS, no syncfs - nothing persists between sessions by design, a
/// refresh is a session end). Cross-session data lives in Import Game /
/// Export Game (ziglop.zip round-trips).
fn mountPersistentDir() void {
    const script =
        \\FS.mkdir('/ziglop');
        \\FS.mount(MEMFS, {}, '/ziglop');
    ;
    emscripten_run_script(script);
}

/// The watchdog wraps the node's callback (a runtime property swap - no
/// raylib/miniaudio source is touched) and watches the queue depth on
/// every fill (AudioProcessingEvent.playbackTime vs the context clock).
/// The trip detector is SUSTAINED ELEVATION: the lead exceeding ~60ms on 3
/// consecutive fills. A banked queue lifts the lead above the healthy
/// envelope and HOLDS it (it never drains) - while scheduling jitter
/// spikes are single fills, and the tight ~0-20ms schedule a rebuilt node
/// runs jitters -66..+35ms around zero (measured) - so persistence is the
/// one signal that separates them. 60ms sits above both schedule shapes'
/// healthy envelopes (miniaudio's original ~30-64ms, the rebuilt node's
/// ~0-20ms) and below the banked depth (~90ms release, ~2s debug); the
/// 3-fill streak completes fast inside a burst (fills arrive
/// back-to-back after a main-thread block). On a trip it REBUILDS the
/// node - a fresh ScriptProcessorNode starts a clean schedule (measured
/// to run ~0-20ms ahead, TIGHTER than miniaudio's original ~30-64ms - the
/// repair lands at better-than-baseline latency) and the stale
/// pre-mixed queue is dropped with the old node. The wrapper is
/// reattached, so miniaudio's wasm-side mixing state is untouched. Costs
/// when it fires: the music skips forward by the banked depth (right
/// after a load, when a gap is least noticed) and any sound triggered
/// during the block is LOST rather than played seconds late - the right
/// trade for feel. Verified outcomes (release, probe-verified): one trip
/// per load, ~15-45ms onset totals after the repair, no false trips at
/// steady state. Known limitation (accepted, degrades-safe): the install
/// reads miniaudio's internal device layout
/// (`window.miniaudio.devices[0].scriptNode`) - a raylib upgrade that
/// reshapes it makes the watchdog find nothing and quietly no-op back to
/// the banked-queue bug, never a crash. The structural fix (AudioWorklet:
/// mixing off-thread, blocks become silent ring-buffer underruns that
/// recover instantly) is deferred to the web hosting milestone - see
/// TODO → Platform Layer. Installed per boot from bootSession (a
/// re-boot's fresh node needs re-wrapping).
fn installAudioLeadWatchdog() void {
    const script =
        "(function() {" ++
        "  var m = window.miniaudio;" ++
        "  var d = m && m.devices && m.devices[0];" ++
        "  if (!d || !d.scriptNode || d.scriptNode.__ziglopWatchdog) return;" ++
        "  d.scriptNode.__ziglopWatchdog = true;" ++
        "  var last_lead = null;" ++
        "  var high_streak = 0;" ++
        "  var orig = d.scriptNode.onaudioprocess;" ++
        "  d.scriptNode.onaudioprocess = function(e) {" ++
        "    orig(e);" ++
        "    if (!d.webaudio || d.webaudio.state !== 'running' ||" ++
        "        typeof e.playbackTime !== 'number') { last_lead = null; high_streak = 0; return; }" ++
        "    var lead = (e.playbackTime - d.webaudio.currentTime) * 1000;" ++
        // The trip detector: SUSTAINED elevation. A banked queue (the
        // missed fills delivered as a burst after a main-thread block)
        // lifts the lead above the healthy envelope and HOLDS it there
        // for every fill thereafter (it never drains - production and
        // consumption both run 1x) - while scheduling jitter spikes are
        // single fills. Trip when the lead exceeds ~60ms on 3 consecutive
        // fills: 60ms sits above the healthy envelopes measured on both
        // schedule shapes (miniaudio's original ~30-64ms, and the tight
        // ~0-15ms schedule a rebuilt node runs - its jitter measured
        // -66..+35ms around zero, which is why per-fill delta detectors
        // false-trip on it) and below the banked depth (~90ms release,
        // ~2s debug); 3 consecutive fills filters every transient while
        // still catching real banking fast (fills arrive back-to-back
        // inside a burst, so the streak completes within the burst).
        "    if (lead > 60) { high_streak += 1; } else { high_streak = 0; }" ++
        "    last_lead = lead;" ++
        "    if (high_streak < 3) return;" ++
        "    high_streak = 0;" ++
        "    var old = d.scriptNode;" ++
        "    if (old !== e.target) return;" ++
        "    console.warn('[ziglop] audio queue banked ' + lead.toFixed(0) +" ++
        "      'ms of playback ahead - rebuilding the audio node (the queue never drains; see the web-audio latency notes)');" ++
        "    var fresh = d.webaudio.createScriptProcessor(old.bufferSize, 0, old.channelCount || 2);" ++
        "    fresh.onaudioprocess = old.onaudioprocess;" ++
        "    fresh.connect(d.webaudio.destination);" ++
        "    d.scriptNode = fresh;" ++
        "    old.disconnect();" ++
        "    last_lead = null;" ++
        "  };" ++
        "})();";
    emscripten_run_script(script);
}

/// Web entry point. Sets up allocator/IO, mounts the in-memory persistent
/// dir, builds the FileSource + RaylibBackend, runs the FULL session setup
/// synchronously (same sequence as native's run(), extracted into
/// createSessionSetup so both platforms stay in sync), and registers
/// `frameCallback` as the emscripten main loop - then returns. emscripten
/// keeps the module alive via `setMainLoopArg`'s `simulate_infinite_loop`
/// flag, so main()'s locals (file_source, io, allocator) live for the tab's
/// lifetime and the WebSession's pointers into them stay valid.
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

    // Mount the in-memory persistent dir BEFORE opening it, then open that
    // virtual path as the persistent dir for FileSource. Both are
    // synchronous - no boot gate, no deferred setup.
    mountPersistentDir();
    const persistent_dir = std.Io.Dir.cwd().openDir(io, persistent_virtual_path, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch @panic("failed to open /ziglop persistent dir");
    defer persistent_dir.close(io);

    const file_source = FileSource.init(io, persistent_dir);

    // Open at half the reference resolution; the canvas is resizable and the
    // renderer scales reference-space content to the actual viewport. The
    // window appears immediately.
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

    // Build + boot the session (the shared boot sequence - the re-boot
    // after an Import Game re-runs this exact sequence; see bootSession).
    // The SessionSetup is stored in the heap WebSession (not on a stack),
    // keeping history.weapon_type_definitions's pointer valid.
    bootSession(session);

    // Register the callback and let emscripten drive the frame loop.
    // fps = -1 lets the browser use requestAnimationFrame (~monitor refresh).
    // simulate_infinite_loop = 1 keeps the module alive after main() returns
    // (and halts main's control flow so its locals - which the WebSession
    // points into - live for the tab's lifetime).
    emscripten_set_main_loop_arg(frameCallback, session, -1, 1);
}
