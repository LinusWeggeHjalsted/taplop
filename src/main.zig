//! Platform-agnostic composition root. Owns the uncapped game loop
//! (`gameLoop`/`run`), the per-iteration `update` step that ties input
//! polling, event processing, and view construction together, and startup
//! config loading (settings, color themes, weapon types, salvage tables).
//! Never imports raylib — the platform driver (`native.zig`/`web.zig`)
//! calls `run` with a duck-typed backend and drives `frame` per platform.
//! See AGENTS → Platform Seam for the frame/driver split and the
//! budget-driven drain.

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const combat_log = @import("combat_log.zig");
const state = @import("state.zig");
const functions = @import("functions.zig");
const input = @import("input.zig");
const parser = @import("parser.zig");
const lookups = @import("generated_lookups.zig");
const ui = @import("ui.zig");
const event_handlers = @import("event_handlers.zig");
const input_handlers = @import("input_handlers.zig");
const view_mod = @import("view.zig");
const build_info = @import("build_info");
const file_source_mod = @import("file_source.zig");

const FileSource = file_source_mod.FileSource;

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;
const MetaEvent = events.MetaEvent;
const PlayerInput = input.PlayerInput;
const Vector2 = types.Vector2;
const Entity = types.Entity;
const SkillId = types.SkillId;
const Editor = types.Editor;
const ReplayViewer = types.ReplayViewer;
const Level = types.Level;
const session_setup = @import("session_setup.zig");
const FrameState = session_setup.FrameState;
const Skill = @import("skills/skill.zig").Skill;
const SkillType = types.SkillType;
const utility_skill_count = types.utility_skill_count;

// ============================================================
// Core functions
// ============================================================

// `export` makes these visible to JS when compiled to WASM.
// The build.zig `export_symbol_names` list must include them too.

/// Handle inputs that can interrupt regardless of event stack state.
/// Map a completed drag (source slot → target slot) to the player event it
/// produces, or null for an invalid / no-op drop. The switch on the source
/// enforces the item/skill domain split: item sources (inventory/gear) only
/// yield events for item targets, skill sources (skill_bar/learned_skill) only
/// for skill targets — everything cross-domain or nonsensical falls to null.
/// Process the next event on the stack, with player input handling.
fn update(
    history: *GameStateHistory,
    input_this_tick: PlayerInput,
    previous_view_state: ?types.ViewState,
    delta_microseconds: u64,
    camera: types.Camera,
    camera_zoom: f32,
    viewport: input.ViewportSize,
) void {
    var player_input = input_this_tick;

    // The UI drawn last frame is what the pointer is over this frame. Used to
    // resolve clicks into actions and to arbitrate world vs UI clicks.
    const ui_elements: []const ui.UiElement =
        if (previous_view_state) |view_state| view_state.ui_elements else &.{};

    // Resolve a primary-button press over the UI. A press on a Button folds its
    // Action into the input (so a click drives the same path as the keybind); a
    // press on any blocking UI surface consumes the world click so it does not
    // also act on the level/hub behind it (world/UI arbitration).
    if (player_input.pointer.pressed) {
        const pointer_position = player_input.pointer.position;
        if (ui.buttonAt(ui_elements, pointer_position)) |button| {
            input.applyAction(&player_input, button.action);
            player_input.idle.tile_clicked = null;
            player_input.idle.confirm = false;
        } else if (ui.blockingElementAt(ui_elements, pointer_position) != null) {
            player_input.idle.tile_clicked = null;
            player_input.idle.confirm = false;
        }
    }

    // Tile-cursor resolution: decide what tile (if any) the logical cursor is
    // on this frame. Mouse takes precedence when it moved (cursor follows it,
    // cleared over blocking UI or a non-tile); otherwise arrow keys nudge the
    // cursor one tile (snapping to the player's tile if null). Runs before
    // input_handlers.handleAnytimeInput/input_handlers.handleIdleInput so the
    // idle path sees the fresh cursor (auto_target_at_cursor reads it).
    input_handlers.resolveTileCursor(history, player_input, ui_elements);

    // Always handle anytime input first (toggle_options_menu always works,
    // but other inputs are blocked when the options menu is open)
    input_handlers.handleAnytimeInput(history, player_input.anytime);

    // Options menu pauses the game
    if (history.session.ui_state.options_menu_open) return;

    // Recoverable error popup pauses the game (modal — same as options).
    // handleAnytimeInput already cleared it if `dismiss_error` fired this
    // frame, so a dismiss releases the modal within the same frame.
    if (history.session.pending_error != null) return;

    // Drag lifecycle runs anytime (not gated on the event stack) so the player
    // can rearrange inventory / gear / skills even while turns resolve. Hit-
    // tested against the previous frame's UI.
    input_handlers.handleDrag(history, player_input.pointer, ui_elements);

    // Camera pan (right-drag) runs anytime alongside the inventory drag. Needs
    // the camera (with current pan) for the drag-start anchor; subsequent pan
    // updates use the stored anchor, so the camera passed here is the frame's
    // input camera. See handleCameraPan.
    input_handlers.handleCameraPan(history, player_input.pointer, ui_elements, camera, camera_zoom, viewport);

    // Turn-flow pause: while waiting, drain the timer and stall event
    // processing until it elapses. Anytime input and drag above still run, so
    // undo/redo/options remain responsive mid-wait (undo rebuilds state and
    // clears the wait via replay). Not skippable: no input can shorten it.
    if (history.current_state.waiting) |*wait_state| {
        if (wait_state.remaining_microseconds > delta_microseconds) {
            wait_state.remaining_microseconds -= delta_microseconds;
            return;
        }
        history.current_state.waiting = null;
        // Wait elapsed this tick; fall through to process the next event.
    }

    if (history.current_state.event_stack.len > 0) {
        // Process next pushed event
        event_handlers.processEvent(history);
    } else {
        // Stack empty — accept gameplay input
        input_handlers.handleIdleInput(history, player_input.idle, player_input.modifiers);
    }
}

/// Build a ViewState describing what to render for the current game state.
/// The frame_allocator is a per-frame arena — everything the ViewState
/// points at is allocated from it and lives until the next frame.

/// Drain budget: process events for at most this long per frame before
/// returning control to the driver. Long enough that a typical small-level
/// drain completes in one frame on both platforms; short enough that the
/// window/tab stays responsive during a big drain (the driver regains control
/// each frame to poll input + render). Native was previously uncapped (a big
/// drain blocked the main thread); web would have frozen one rAF per event.
/// 10ms is a starting value.
const drain_budget_microseconds: u64 = 10 * std.time.ms_per_s;

/// One frame's worth of work — the platform-agnostic core, shared by both the
/// native and web drivers. Gameplay outcome depends on event order + real-
/// clock wait deltas, both identical across platforms; only wall-clock drain
/// duration differs (native drains as fast as the CPU allows within the
/// budget, web drains within the budget per requestAnimationFrame). This
/// function NEVER yields/sleeps — scheduling is the driver's job (native
/// sleeps via backend.waitTime; web lets the browser schedule rAFs).
pub fn frame(backend: anytype, frame_state: *FrameState) void {
    const history = &frame_state.history;

    const platform_input = backend.pollInput();
    // Camera is derived (centered on the player), computed each frame so input
    // (screenToTile) and rendering (tileToTile) stay in sync.
    const camera_zoom = history.settings.camera_zoom;
    // Input camera: computed BEFORE the drain, reflecting the previously-
    // rendered view (the player clicks against what's on screen). Includes
    // the current camera pan so screenToTile maps clicks against the panned
    // view. The render camera is recomputed post-update below so it tracks
    // the state being drawn (see the render gate).
    const camera = view_mod.computeCamera(&history.current_state, camera_zoom, history.session.camera_pan);
    const player_input = input.translateInput(
        platform_input,
        &history.session.input_state,
        history.settings,
        camera,
    );

    // Real-clock delta since the last frame (NOT frame-rate based), so the
    // wait timer drains in real time regardless of how often frame() is called.
    const delta_microseconds = backend.deltaMicroseconds();

    // Player position before the drain, for the pan-recenter check: if the
    // player moved this frame (a move event in the drain, or a click-to-move
    // in the idle update), clear the camera pan so the camera recenters on
    // the player. Grabbing the pre-drain position lets us detect the move
    // without inspecting events.
    const player_position_before = view_mod.playerPosition(&history.current_state);

    // Drain: call update() repeatedly until the stack empties, a wait
    // activates, or the drain budget elapses — whichever comes first. update()
    // handles one event OR one idle input per call (plus anytime input, drag,
    // and the wait-timer drain); when the stack is empty, the final update()
    // processes one idle input and the drain then exits via the empty-stack
    // check. This is the one behavior change from the old single-update-per-
    // iteration loop: a multi-event drain now completes within a single frame
    // (within the budget) instead of one event per iteration. The old round-
    // trip test's runToIdle helper already drains to empty the same way, so
    // reconstruction semantics are unchanged.
    const drain_start = backend.realClockMicroseconds();
    while (history.current_state.waiting == null and
        history.session.pending_error == null and
        history.current_state.event_stack.len > 0 and
        backend.realClockMicroseconds() - drain_start < drain_budget_microseconds)
    {
        const screen_before_update = history.current_state.screen;
        const had_events = history.current_state.event_stack.len > 0;
        update(history, player_input, frame_state.previous_view_state, delta_microseconds, camera, camera_zoom, platform_input.viewport);

        // A reconstruction-read handler failed during the event just
        // processed. Revert to the last idle-point snapshot (guaranteed
        // exact — it was just taken, no snapshots since — and stack-empty by
        // construction), trim the failed transaction's recorded events, and
        // exit the drain. The handler already set session.pending_error with
        // a descriptive message (it survives the revert — SessionState is
        // off GameState). See AGENTS → Error Handling → three contexts.
        if (history.load_error) {
            history.load_error = false;
            const last_idle_event_index = history.idle_points.items[history.current_idle_index];
            history.restoreTo(last_idle_event_index, &event_handlers.processEvent);
            history.event_history.shrinkRetainingCapacity(history.current_event_index);
            break;
        }

        const has_events = history.current_state.event_stack.len > 0;

        // UI panels/drag and the tile cursor are transient view/input state,
        // not part of the undoable GameState. Reset them whenever the screen
        // changes (transitions and undo/redo across a screen boundary both
        // run inside update()). Input state is deliberately left alone — it
        // is live hardware state. The tile cursor is scoped to a level/hub's
        // tile grid, so a screen transition invalidates it.
        if (history.current_state.screen != screen_before_update) {
            history.session.ui_state = .{};
            history.session.tile_cursor = null;
            history.session.camera_pan = null;
            history.session.camera_pan_anchor = null;
        }

        if (had_events and !has_events) {
            // Stack just emptied — record the idle point (snapshot + compact
            // current_arena so per-turn churn and any exited level/hub are
            // reclaimed instead of accumulating across the session). Shared
            // with reconstruction via recordIdlePoint.
            history.recordIdlePoint();
        }
    }

    // Idle/wait frame: the stack is empty or a wait is active, so there are no
    // events to drain. Run one update() to handle idle input (and anytime
    // input / drag / wait-timer drain, which update() does every call).
    // Mirrors the old loop's single update() on idle iterations.
    if (history.current_state.waiting != null or
        history.session.pending_error != null or
        history.current_state.event_stack.len == 0)
    {
        const screen_before_update = history.current_state.screen;
        update(history, player_input, frame_state.previous_view_state, delta_microseconds, camera, camera_zoom, platform_input.viewport);
        if (history.current_state.screen != screen_before_update) {
            history.session.ui_state = .{};
            history.session.tile_cursor = null;
            history.session.camera_pan = null;
            history.session.camera_pan_anchor = null;
        }
    }

    // Player-move recenter: if the player's tile changed this frame (a move
    // event in the drain or a click-to-move in the idle update), clear the
    // camera pan so the camera recenters on the player. Pan drifts off the
    // player while looking around; a move is the natural "look, then go" hand-
    // off back to player-centered framing.
    const player_position_after = view_mod.playerPosition(&history.current_state);
    if (player_position_after.x != player_position_before.x or
        player_position_after.y != player_position_before.y)
    {
        history.session.camera_pan = null;
        history.session.camera_pan_anchor = null;
    }

    // Render gate: only build+render a frame when enough real time has elapsed
    // since the last render AND we're not mid-drain. During an active event
    // drain (stack non-empty, no wait) we skip rendering — intermediate states
    // flash by in <1ms and aren't worth a frame, and vsync (swapScreenBuffer)
    // blocks the thread for a full refresh, frame-locking the drain to the
    // render rate. We render when the drain completes (stack empties) or
    // pauses (a wait is active). render_interval is 0 when uncapped.
    const render_interval = backend.renderIntervalMicroseconds(history.settings);
    const now = backend.realClockMicroseconds();
    const since_last_render = now - frame_state.last_render_time;
    // A pending error pauses the drain (the modal popup blocks event
    // processing) — treat it like a wait for render-gate purposes so the
    // popup is visible. See AGENTS → Error Handling.
    const drain_in_progress = history.current_state.event_stack.len > 0 and
        history.current_state.waiting == null and
        history.session.pending_error == null;
    if (!drain_in_progress and since_last_render >= render_interval) {
        // Render camera is computed from the POST-update current_state, NOT the
        // pre-update camera used for input above. The input camera must reflect
        // the previously-rendered view (clicks are made against what's on
        // screen); the render camera must track the state being drawn. Without
        // this recompute, a move completed this frame draws the player at the
        // new position under a camera still centered on the old one — a
        // one-frame glitch where the player appears jumped/shifted before the
        // camera catches up next frame. computeCamera is cheap; recompute it
        // here so render never lags the state by a frame.
        const render_camera = view_mod.computeCamera(&history.current_state, camera_zoom, history.session.camera_pan);
        _ = frame_state.frame_arena.reset(.retain_capacity);
        frame_state.previous_view_state = view_mod.view(
            &history.current_state,
            &history.session,
            history.settings,
            history.color_theme_definitions,
            history.weapon_type_definitions,
            .{
                .camera = render_camera,
                .camera_zoom = camera_zoom,
                .event_history = history.event_history.items,
                .level_start_index = history.levelStartEventIndex(),
                .current_event_index = history.current_event_index,
                .frame_allocator = frame_state.frame_arena.allocator(),
            },
        );
        backend.render(frame_state.previous_view_state.?, platform_input.viewport);

        // Advance last_render to the most recent ideal frame boundary so the
        // schedule never drifts — a slightly-late frame self-corrects on the
        // next, and a long hitch skips missed frames (no burst-rendering)
        // while staying phase-aligned. `elapsed % interval` is how far past
        // the last ideal boundary we are; subtract it from `now`.
        const elapsed = now - frame_state.last_render_time;
        frame_state.last_render_time = if (render_interval == 0)
            now
        else
            now - (elapsed % render_interval);
    }
}

/// Native driver: a blocking while-loop that calls frame() each iteration and
/// yields (sleeps ~0.1ms) when idle so the loop doesn't busy-spin at 100% CPU.
/// The web driver (web.zig) replaces this with
/// emscripten_set_main_loop(frame_callback, -1, true) — the browser schedules
/// frames and handles yielding, so no sleep is needed there. Both drivers call
/// the SAME frame() function, so gameplay outcome is identical across platforms.
fn gameLoop(backend: anytype, frame_state: *FrameState) void {
    // Idle/wait yield: when the stack is empty OR a wait is active, there's no
    // event-drain work to do — only the wait timer (drained by real-clock
    // deltas on wake) and anytime input (undo/redo/options, handled every
    // frame()) need attention. Sleep briefly so the loop doesn't busy-spin at
    // 100% CPU. 0.1ms keeps input latency ~0.1ms (well under a 60Hz frame) at
    // ~10% CPU on one core. During active event drains the loop spins freely
    // (useful work, no yield). Web doesn't sleep at all — the browser's rAF
    // scheduling IS the yield.
    const idle_yield_seconds: f64 = 0.0001; // 0.1ms — see AGENTS → Platform Seam (idle yield)
    while (!backend.shouldClose()) {
        frame(backend, frame_state);
        if (frame_state.history.current_state.event_stack.len == 0 or
            frame_state.history.current_state.waiting != null)
        {
            backend.waitTime(idle_yield_seconds);
        }
    }
}

/// Entry point shared by every platform: drive the backend-driven game loop
/// against a session the caller has already set up. The caller (native.zig /
/// web.zig) builds the `SessionSetup` via `session_setup.createSessionSetup`,
/// places it in a stable location, and calls `fixupPointers()` before handing
/// it here. The `backend` provides window/clock/input/rendering (see
/// gameLoop). Never called from wasm/test builds, so this stays out of the
/// raylib-free compiles even though it is `pub`.
pub fn run(
    backend: anytype,
    setup: *session_setup.SessionSetup,
) void {
    defer setup.frame_state.frame_arena.deinit();
    gameLoop(backend, &setup.frame_state);
}


/// Drive event processing until the stack empties (test harness: no update()
/// loop, so waits are cleared rather than timed). Mirrors the live gameLoop's
/// idle bookkeeping: on stack-empty, recordIdlePoint (snapshot + compact), so
/// a forward-played session accumulates the same idle points the live loop
/// would — which reconstruction then derives from virtual depth.
fn runToIdle(history: *GameStateHistory) void {
    while (history.current_state.event_stack.len > 0) {
        event_handlers.processEvent(history);
        if (history.load_error) @panic("runToIdle: handler set load_error (test content should be valid)");
        history.current_state.waiting = null;
    }
    history.recordIdlePoint();
}

test "session log round-trips through reconstruction (forward play == replay)" {
    const allocator = std.testing.allocator;

    // One arena backs the whole test: every sub-arena the histories spin up is
    // freed at once, so no GameStateHistory deinit is needed.
    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    // Forward-play a short scripted session (main menu -> new game -> hub ->
    // one hub move) into history1, recording events as it goes.
    var history1 = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history1);
    event_handlers.pushEvents(&history1.current_state, &.{.{ .meta_event = .start_new_game }}, history1.current_arena.allocator());
    runToIdle(&history1);
    event_handlers.pushEvents(&history1.current_state, &.{.{ .hub_event = .{ .move_player = .{ .destination = .{ .x = 1, .y = 0 } } } }}, history1.current_arena.allocator());
    runToIdle(&history1);
    try std.testing.expectEqual(state.Screen.hub, history1.current_state.screen);

    // Serialize -> parse -> load the recorded history.
    const body = try parser.writeEventLog(history1.event_history.items, "20260101_000000", arena);
    const sections = try parser.parseConfigFile(body, arena);
    const log = try parser.loadEventLog(sections, arena);
    input_handlers.warnIfSessionLogFromDifferentBuild(log.game_version); // same build -> silent

    // Reconstruct into a fresh history2 from the loaded log and compare the
    // final states: faithful reconstruction means replay == forward play.
    var history2 = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    history2.reconstructFromEventLog(log.events, @intCast(log.events.len), &event_handlers.processEvent);

    try std.testing.expectEqualDeep(history1.current_state, history2.current_state);

    // Virtual-depth reconstruction must derive the SAME idle points the live
    // loop recorded (not serialized — derived from the event stream). This is
    // what makes a loaded session undo/redo "as if played live".
    try std.testing.expectEqualSlices(
        u32,
        history1.idle_points.items,
        history2.idle_points.items,
    );

    // Undo on the reconstructed session should walk back through the derived
    // idle points to the start, mirroring live play. Reconstruct to the end
    // lands at the last idle point; undoing reaches index 0.
    try std.testing.expectEqual(
        history2.idle_points.items.len - 1,
        history2.current_idle_index,
    );
    while (history2.undo(&event_handlers.processEvent)) {}
    try std.testing.expectEqual(@as(u32, 0), history2.current_idle_index);
}

test "replay verification: clean replay through the slow path passes" {
    // The natural-stack replay loops (state.zig) verify before each dispatch
    // that the event about to run (stack top) matches the recorded stream.
    // On undo/redo the slow path (restoreTo -> replayTo) only fires when no
    // exact snapshot exists, so here we force it: forward-play a session, then
    // NULL every snapshot + checkpoint so any undo/redo replays the whole
    // history from initial_state. A clean replay must verify every event
    // without tripping the panic — this is the positive integration proof
    // that the check is wired and sound. (A tampered event_history would trip
    // the panic; deepEqual/firstDiffField unit tests in deep_copy.zig prove
    // the comparison detects that.)
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);
    event_handlers.pushEvents(&history.current_state, &.{.{ .meta_event = .start_new_game }}, history.current_arena.allocator());
    runToIdle(&history);
    event_handlers.pushEvents(&history.current_state, &.{.{ .hub_event = .{ .move_player = .{ .destination = .{ .x = 1, .y = 0 } } } }}, history.current_arena.allocator());
    runToIdle(&history);
    try std.testing.expectEqual(state.Screen.hub, history.current_state.screen);

    // Evict every restore point so undo/redo take the replay slow path.
    for (&history.snapshots) |*slot| slot.* = null;
    for (&history.checkpoints) |*slot| slot.* = null;

    // Undo back to the start: each step replays from initial_state through
    // every event up to the target idle point, running verifyReplayStep on
    // each. A clean replay must not panic.
    while (history.undo(&event_handlers.processEvent)) {}
    try std.testing.expectEqual(@as(u32, 0), history.current_idle_index);

    // Redo forward to the end: same slow-path replay + verification.
    while (history.redo(&event_handlers.processEvent)) {}
    try std.testing.expectEqual(
        history.idle_points.items.len - 1,
        history.current_idle_index,
    );
    try std.testing.expectEqual(state.Screen.hub, history.current_state.screen);
}

test "reconstruction cache: undo replay reads original bytes after the file is overwritten" {
    // The reconstruction cache makes replay deterministic regardless of later
    // file changes (the editor-saves-overwrite-mid-session case). A live
    // reconstruction read caches its bytes; a replay of that event returns the
    // cached bytes, not whatever is on disk now. This is the within-session
    // guarantee; cross-session (reconstructFromEventLog) falls back to disk
    // because the cache starts empty (see cross_session_replay).
    const allocator = std.testing.allocator;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir under the project's zig-cache so it's writable
    // and easy to clean up. FileSource reads hit this dir first (no embedded
    // override for a non-data/non-assets path).
    const scratch_path = "zig-cache/test-recon-cache";
    const persistent_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch_path) catch {};
    const file_source = FileSource.init(io, persistent_dir);

    // Write version 1 of a custom file (not under data//assets/ so writeFile accepts it).
    file_source.writeFile("custom_mission.txt", "version1") catch @panic("failed to write v1");

    // Minimal history: readReconstructionFile touches current_event_index,
    // replaying, cross_session_replay, reconstruction_cache, history_arena,
    // and file_source — the rest is left undefined (the method never reads it).
    var history: GameStateHistory = undefined;
    history.backing_allocator = allocator;
    history.history_arena = std.heap.ArenaAllocator.init(allocator);
    defer history.history_arena.deinit();
    history.reconstruction_cache = .empty;
    history.file_source = &file_source;
    history.replaying = false;
    history.cross_session_replay = false;

    // Simulate a live reconstruction read at event index 0: processEvent
    // increments current_event_index to 1 before dispatching the handler, so
    // the event under handling is at index 0 = current_event_index - 1.
    history.current_event_index = 1;
    const live_bytes = history.readReconstructionFile("custom_mission.txt");
    try std.testing.expectEqualStrings("version1", live_bytes);

    // Overwrite the file on disk (e.g. an editor save) with different bytes.
    file_source.writeFile("custom_mission.txt", "version2") catch @panic("failed to write v2");

    // Replay the same event: replaying=true, same event index. Must return the
    // CACHED version1 bytes, not the new version2 on disk.
    history.replaying = true;
    history.current_event_index = 1;
    const replayed_bytes = history.readReconstructionFile("custom_mission.txt");
    try std.testing.expectEqualStrings("version1", replayed_bytes);
}

test "editor building blocks: open -> playtest -> end -> close round-trips" {
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);

    // Open the editor on the shipped first_mission.
    event_handlers.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .open_editor = .{
        .mission_path = "data/campaigns/main_campaign/missions/first_mission",
    } } }}, history.current_arena.allocator());
    runToIdle(&history);

    // Editor is populated: screen is .editor, mission loaded, levels array
    // has the mission's level_count entries, mode is .edit. The palette is
    // reference-based: first_mission's level_1 has one enemy (Skeleton
    // Warrior at char '1'), so entity_types has one entry and the level has
    // one placement referencing it. player_def carries the player loadout
    // from player.txt.
    try std.testing.expectEqual(state.Screen.editor, history.current_state.screen);
    try std.testing.expect(history.current_state.editor != null);
    const editor = &history.current_state.editor.?;
    try std.testing.expectEqual(@as(usize, 1), editor.levels.len); // first_mission has 1 level
    try std.testing.expectEqual(types.EditorMode.edit, editor.mode);
    try std.testing.expectEqual(@as(usize, 1), editor.entity_types.len); // one enemy type (Skeleton Warrior)
    try std.testing.expectEqual(@as(usize, 1), editor.levels[0].entity_placements.len);
    try std.testing.expectEqual(@as(u32, 0), editor.levels[0].entity_placements[0].type_id);
    try std.testing.expect(std.mem.eql(u8, "Player", editor.player_def.template.name));
    try std.testing.expect(std.mem.eql(u8, "player", editor.player_def.template.sprite));

    // Start a playtest on level 0.
    event_handlers.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .start_playtest = .{
        .level_index = 0,
    } } }}, history.current_arena.allocator());
    runToIdle(&history);

    // Gameplay is live: screen is .level, current.level populated (entity 0
    // = player from player_def at the '!', entity 1 = the skeleton from the
    // palette type at its placement), editor dormant with mode .playtest.
    try std.testing.expectEqual(state.Screen.level, history.current_state.screen);
    try std.testing.expect(history.current_state.level != null);
    try std.testing.expectEqual(@as(usize, 2), history.current_state.level.?.entities.len); // player + 1 enemy
    try std.testing.expect(std.mem.eql(u8, "Player", history.current_state.level.?.entities[0].name));
    try std.testing.expect(std.mem.eql(u8, "skeleton_1", history.current_state.level.?.entities[1].sprite));
    try std.testing.expectEqual(types.EditorMode.playtest, history.current_state.editor.?.mode);
    try std.testing.expect(history.current_state.editor != null); // dormant, not cleared

    // End the playtest (simulating the player completing the level — in live
    // play, end_level's guard pushes end_playtest; here we push it directly).
    event_handlers.pushEvents(&history.current_state, &.{.{ .meta_event = .end_playtest }}, history.current_arena.allocator());
    runToIdle(&history);

    // Back in the editor: screen .editor, level + mission cleared (discard
    // semantics), mode .edit, editor's levels array untouched.
    try std.testing.expectEqual(state.Screen.editor, history.current_state.screen);
    try std.testing.expect(history.current_state.level == null);
    try std.testing.expect(history.current_state.mission == null);
    try std.testing.expectEqual(types.EditorMode.edit, history.current_state.editor.?.mode);
    try std.testing.expectEqual(@as(usize, 1), history.current_state.editor.?.levels.len);

    // Close the editor.
    event_handlers.pushEvents(&history.current_state, &.{.{ .meta_event = .close_editor }}, history.current_arena.allocator());
    runToIdle(&history);
    try std.testing.expectEqual(state.Screen.main_menu, history.current_state.screen);
    try std.testing.expect(history.current_state.editor == null);
}

test "turn counters: per-mission increments, cumulative skipped in editor mode" {
    // The player's turn_end (entity_index == 0) increments the per-mission
    // turns_spent (scoped to the current playthrough) and the cumulative
    // player_data.turns (lifetime). In editor playtest/validate the
    // cumulative counter is SKIPPED (discard-semantics — the editor session
    // must not inflate the player's real turn count); the per-mission
    // counter still increments (discarded with the mission on exit). This
    // uses the editor playtest path to enter a level and take one turn.
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);

    // Open editor + start playtest on first_mission level 0.
    event_handlers.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .open_editor = .{
        .mission_path = "data/campaigns/main_campaign/missions/first_mission",
    } } }}, history.current_arena.allocator());
    runToIdle(&history);
    event_handlers.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .start_playtest = .{
        .level_index = 0,
    } } }}, history.current_arena.allocator());
    runToIdle(&history);

    try std.testing.expectEqual(state.Screen.level, history.current_state.screen);
    try std.testing.expectEqual(@as(u32, 0), history.current_state.mission.?.turns_spent);
    try std.testing.expectEqual(@as(u32, 0), history.current_state.player_data.turns);

    // Skip the player's move phase (goes to attack phase), then skip the
    // attack phase (pushes turn_end entity_index 0). The per-mission counter
    // increments; the cumulative counter does NOT (editor mode).
    event_handlers.pushEvents(&history.current_state, &.{.{ .level_event = .{ .player_skip_move = .{} } }}, history.current_arena.allocator());
    runToIdle(&history);
    event_handlers.pushEvents(&history.current_state, &.{.{ .level_event = .player_skip_attack }}, history.current_arena.allocator());
    runToIdle(&history);

    try std.testing.expectEqual(@as(u32, 1), history.current_state.mission.?.turns_spent);
    try std.testing.expectEqual(@as(u32, 0), history.current_state.player_data.turns);

    // End the playtest (discard semantics — counters are discarded with the
    // mission; player_data.turns was never touched).
    event_handlers.pushEvents(&history.current_state, &.{.{ .meta_event = .end_playtest }}, history.current_arena.allocator());
    runToIdle(&history);
    try std.testing.expectEqual(state.Screen.editor, history.current_state.screen);
}

test "reconstruction read failure: handler sets load_error, drain loop reverts state + trims history" {
    // A broken mission file (invalid content) causes start_mission's parse
    // to fail. The handler sets load_error + pending_error and returns. The
    // drain loop (simulated here) reverts to the last idle-point snapshot,
    // trims the failed transaction's recorded events, and the popup message
    // survives (it's on SessionState, off GameState). See AGENTS → Error
    // Handling → three contexts.
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir with a broken mission.txt shadow.
    const scratch = "zig-cache/test-recon-read-fail";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Write a broken mission.txt at the first_mission path (shadows the
    // embedded copy). Invalid content → parseConfigFile fails.
    dir.createDirPath(io, "data/campaigns/main_campaign/missions/first_mission") catch
        @panic("failed to create mission dir");
    dir.writeFile(io, .{
        .sub_path = "data/campaigns/main_campaign/missions/first_mission/mission.txt",
        .data = "this is not valid config",
    }) catch @panic("failed to write broken mission");

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);

    // We're at the main menu (idle). Record the pre-action state for later
    // comparison.
    const pre_event_index = history.current_event_index;
    const pre_idle_index = history.current_idle_index;
    try std.testing.expectEqual(@as(?[]const u8, null), history.session.pending_error);

    // Push start_mission pointing at the broken mission.
    event_handlers.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .start_mission = .{
        .mission_path = "data/campaigns/main_campaign/missions/first_mission",
        .start_hub_id = null,
        .end_hub_id = null,
    } } }}, history.current_arena.allocator());

    // Process one event (start_mission). The parse fails → load_error is set,
    // pending_error is set, and processEvent returns without mutating state
    // further (mission stays null, screen stays main_menu).
    event_handlers.processEvent(&history);
    try std.testing.expect(history.load_error);
    try std.testing.expect(history.session.pending_error != null);
    try std.testing.expect(history.current_state.mission == null);
    try std.testing.expectEqual(state.Screen.main_menu, history.current_state.screen);

    // Simulate the drain loop's revert: restore to the last idle-point
    // snapshot, trim the failed transaction's recorded events, clear the flag.
    history.load_error = false;
    const last_idle_event_index = history.idle_points.items[history.current_idle_index];
    history.restoreTo(last_idle_event_index, &event_handlers.processEvent);
    history.event_history.shrinkRetainingCapacity(history.current_event_index);

    // State is fully reverted: back at the main menu, event index restored,
    // event_history trimmed (the failed start_mission event is gone).
    try std.testing.expectEqual(pre_event_index, history.current_event_index);
    try std.testing.expectEqual(pre_idle_index, history.current_idle_index);
    try std.testing.expectEqual(pre_event_index, history.event_history.items.len);
    try std.testing.expectEqual(state.Screen.main_menu, history.current_state.screen);
    try std.testing.expect(history.current_state.mission == null);

    // The popup message survived the revert (SessionState is off GameState).
    try std.testing.expect(history.session.pending_error != null);
}

test "write_save failure: sets pending_error, no crash, no state corruption" {
    // A write_save event whose target dir parent is a FILE (not a dir)
    // fails on ensureParentDirs (createDirPath can't make a dir where a
    // file exists). The handler surfaces pending_error and returns instead
    // of panicking. State is unchanged (the save just didn't happen — no
    // revert needed for a failed write). See AGENTS → Error Handling.
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir with a file at "saves" (so writing to
    // "saves/test_save.txt" fails — ensureParentDirs can't create the
    // "saves" dir because a file with that name exists).
    const scratch = "zig-cache/test-write-save-fail";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    dir.writeFile(io, .{ .sub_path = "saves", .data = "i am a file not a dir" }) catch
        @panic("failed to create blocker file");
    const file_source = FileSource.init(io, dir);

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{ .current_campaign = "test_campaign", .player_name = "Test" },
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);

    try std.testing.expectEqual(@as(?[]const u8, null), history.session.pending_error);

    // Push write_save to "saves/test_save.txt" — ensureParentDirs tries to
    // create the "saves" dir, fails because "saves" is a file.
    event_handlers.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .write_save = .{
        .save_path = "saves/test_save.txt",
    } } }}, history.current_arena.allocator());
    event_handlers.processEvent(&history);

    // The write failed → pending_error is set, load_error is NOT (writes
    // don't need a revert — state is fine, just the file didn't write).
    try std.testing.expect(history.session.pending_error != null);
    try std.testing.expect(!history.load_error);

    // State is unchanged — the save didn't happen, but player_data is intact.
    try std.testing.expectEqualStrings("Test", history.current_state.player_data.player_name);

    history.session.clearPendingError();
}
