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
const WeaponType = types.WeaponType;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const ColorThemeDefinitions = types.ColorThemeDefinitions;
const Settings = types.Settings;
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
    // on this frame. Mouse takes precedence when it moved; otherwise the
    // cursor holds (arrow-key nudging lands in a later step). A pointer over
    // blocking UI, or over a non-tile, clears the cursor. Runs before
    // input_handlers.handleAnytimeInput/input_handlers.handleIdleInput so the idle path sees the fresh
    // cursor (auto_target_at_cursor reads it).
    input_handlers.resolveTileCursor(history, player_input, ui_elements);

    // Always handle anytime input first (toggle_options_menu always works,
    // but other inputs are blocked when the options menu is open)
    input_handlers.handleAnytimeInput(history, player_input.anytime);

    // Options menu pauses the game
    if (history.session.ui_state.options_menu_open) return;

    // Drag lifecycle runs anytime (not gated on the event stack) so the player
    // can rearrange inventory / gear / skills even while turns resolve. Hit-
    // tested against the previous frame's UI.
    input_handlers.handleDrag(history, player_input.pointer, ui_elements);

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
/// platform-seam note in build.zig.
/// Per-session mutable state that lives across frames — extracted from the
/// old blocking gameLoop so the per-frame body can be shared between platform
/// drivers (native: blocking while-loop; web: emscripten_set_main_loop).
/// See AGENTS.md "Platform Seam (raylib)" + the web build roadmap.
pub const FrameState = struct {
    history: GameStateHistory,
    previous_view_state: ?types.ViewState = null,
    /// Per-frame arena: everything a ViewState points at is allocated here and
    /// reset (retaining capacity) at the start of the next render.
    frame_arena: std.heap.ArenaAllocator,
    /// Last render time (real-clock microseconds) for the render-interval gate.
    last_render_time: u64,
};

/// Drain budget: process events for at most this long per frame before
/// returning control to the driver. Long enough that a typical small-level
/// drain completes in one frame on both platforms; short enough that the
/// window/tab stays responsive during a big drain (the driver regains control
/// each frame to poll input + render). Native was previously uncapped (a big
/// drain blocked the main thread); web would have frozen one rAF per event.
/// 10ms is a starting value, tunable later.
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
    const camera = view_mod.computeCamera(&history.current_state, camera_zoom);
    const player_input = input.translateInput(
        platform_input,
        &history.session.input_state,
        history.settings,
        camera,
    );

    // Real-clock delta since the last frame (NOT frame-rate based), so the
    // wait timer drains in real time regardless of how often frame() is called.
    const delta_microseconds = backend.deltaMicroseconds();

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
        history.current_state.event_stack.len > 0 and
        backend.realClockMicroseconds() - drain_start < drain_budget_microseconds)
    {
        const screen_before_update = history.current_state.screen;
        const had_events = history.current_state.event_stack.len > 0;
        update(history, player_input, frame_state.previous_view_state, delta_microseconds);
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
    if (history.current_state.waiting != null or history.current_state.event_stack.len == 0) {
        const screen_before_update = history.current_state.screen;
        update(history, player_input, frame_state.previous_view_state, delta_microseconds);
        if (history.current_state.screen != screen_before_update) {
            history.session.ui_state = .{};
            history.session.tile_cursor = null;
        }
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
    const drain_in_progress = history.current_state.event_stack.len > 0 and
        history.current_state.waiting == null;
    if (!drain_in_progress and since_last_render >= render_interval) {
        _ = frame_state.frame_arena.reset(.retain_capacity);
        frame_state.previous_view_state = view_mod.view(
            &history.current_state,
            &history.session,
            history.color_theme_definitions,
            history.weapon_type_definitions,
            camera,
            camera_zoom,
            history.event_history.items,
            history.levelStartEventIndex(),
            history.current_event_index,
            frame_state.frame_arena.allocator(),
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
    const idle_yield_seconds: f64 = 0.0001; // 0.1ms — see TODO analysis
    while (!backend.shouldClose()) {
        frame(backend, frame_state);
        if (frame_state.history.current_state.event_stack.len == 0 or
            frame_state.history.current_state.waiting != null)
        {
            backend.waitTime(idle_yield_seconds);
        }
    }
}

const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;

/// Load settings from data/settings.txt. Returns default settings on failure.
pub fn loadSettingsFromDisk(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
) Settings {
    const parsed = parser.parseConfigFileFromPath(
        file_source,
        "data/settings.txt",
        allocator,
    ) catch return .{ .input_bindings = &.{} };

    return parser.loadSettings(parsed.sections, allocator) catch .{ .input_bindings = &.{} };
}

/// Load color theme definitions from data/color_themes.txt.
/// Returns a default with no gradients on failure.
pub fn loadColorThemeDefinitionsFromDisk(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
) ColorThemeDefinitions {
    const parsed = parser.parseConfigFileFromPath(
        file_source,
        "data/color_themes.txt",
        allocator,
    ) catch return .{
        .lightest = .{ .r = 255, .g = 255, .b = 240 },
        .darkest = .{ .r = 20, .g = 15, .b = 25 },
        .gradients = &.{},
    };

    return parser.loadColorThemeDefinitions(
        parsed.sections,
        allocator,
    ) catch .{
        .lightest = .{ .r = 255, .g = 255, .b = 240 },
        .darkest = .{ .r = 20, .g = 15, .b = 25 },
        .gradients = &.{},
    };
}

/// Load all weapon type definitions from data/weapon_types/.
/// Each file is named after its WeaponType enum value (e.g. sword.txt).
pub fn loadWeaponTypeDefinitions(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
) [weapon_type_count]WeaponTypeDefinition {
    var definitions: [weapon_type_count]WeaponTypeDefinition = undefined;
    const fields = @typeInfo(WeaponType).@"enum".fields;

    inline for (fields, 0..) |field, index| {
        const file_path = "data/weapon_types/" ++ field.name ++ ".txt";
        const parsed = parser.parseConfigFileFromPath(
            file_source,
            file_path,
            allocator,
        ) catch @panic("failed to read weapon type file: " ++ file_path);

        definitions[index] = parser.loadWeaponTypeDefinition(
            parsed.sections,
        ) catch @panic("failed to parse weapon type file: " ++ file_path);
    }

    return definitions;
}

/// Load salvage definitions from data/salvage.txt.
/// Panics on failure since salvage data is required.
pub fn loadSalvageDefinitionsFromDisk(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
) types.SalvageDefinitions {
    const parsed = parser.parseConfigFileFromPath(
        file_source,
        "data/salvage.txt",
        allocator,
    ) catch @panic("failed to read salvage.txt");

    return parser.loadSalvageDefinitions(
        parsed.sections,
        allocator,
    ) catch @panic("failed to parse salvage.txt");
}

/// Owns the session-long setup state (config definitions + FrameState) that
/// both platform drivers need. The `weapon_type_definitions` array is stored
/// BY VALUE here (not on the caller's stack) because GameStateHistory holds a
/// pointer to it — the pointer must remain valid for the whole session. On
/// native, the SessionSetup lives on run()'s stack for the game's duration;
/// on web, it's heap-allocated (the WebSession owns it) since main() returns
/// immediately. fixupPointers() must be called once the struct is in its final
/// memory location, so the history's pointer points to the right place.
pub const SessionSetup = struct {
    weapon_type_definitions: [weapon_type_count]WeaponTypeDefinition,
    frame_state: FrameState,

    /// Point history.weapon_type_definitions at this struct's field. Must be
    /// called after the SessionSetup is in its final memory location (stack of
    /// the native driver, or heap-allocated for web).
    pub fn fixupPointers(self: *SessionSetup) void {
        self.frame_state.history.weapon_type_definitions = &self.weapon_type_definitions;
    }
};

/// Shared session setup: load all config, build the initial GameState, init the
/// history, and create the FrameState. Both native (run) and web (web.main)
/// call this instead of duplicating the load + init sequence. The caller is
/// responsible for placing the returned SessionSetup in a stable location and
/// calling fixupPointers() before driving frame().
pub fn createSessionSetup(
    allocator: std.mem.Allocator,
    file_source: *const FileSource,
    io: std.Io,
    backend: anytype,
) SessionSetup {
    const settings = loadSettingsFromDisk(file_source, allocator);
    backend.applyVsync(settings.vsync);
    const weapon_type_definitions = loadWeaponTypeDefinitions(file_source, allocator);
    const color_theme_definitions = loadColorThemeDefinitionsFromDisk(file_source, allocator);
    const salvage_definitions = loadSalvageDefinitionsFromDisk(file_source, allocator);

    const starting_game_state = GameState{
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

    // Create the history with a temporary pointer to weapon_type_definitions
    // (a local). The caller fixes this up via fixupPointers() once the
    // SessionSetup is in its final location. The temporary pointer is fine
    // because createSessionSetup hasn't returned yet — both the local and the
    // returned struct's field hold the same array value at this point.
    const history = GameStateHistory.init(
        allocator,
        starting_game_state,
        settings,
        &weapon_type_definitions,
        color_theme_definitions,
        salvage_definitions,
        file_source,
        io,
    );

    return .{
        .weapon_type_definitions = weapon_type_definitions,
        .frame_state = .{
            .history = history,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .last_render_time = backend.realClockMicroseconds(),
        },
    };
}

/// Entry point shared by every platform: load config, build the initial
/// GameState, and run the backend-driven game loop. The `backend` provides
/// window/clock/input/rendering (see gameLoop). Called by the native entry in
/// native.zig — never from wasm/test builds, so this stays out of the
/// raylib-free compiles even though it is `pub`.
pub fn run(
    backend: anytype,
    allocator: std.mem.Allocator,
    file_source: *const FileSource,
    io: std.Io,
) void {
    var setup = createSessionSetup(allocator, file_source, io, backend);
    setup.fixupPointers();
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

    const settings = loadSettingsFromDisk(&file_source, arena);
    const weapon_type_definitions = loadWeaponTypeDefinitions(&file_source, arena);
    const color_theme_definitions = loadColorThemeDefinitionsFromDisk(&file_source, arena);
    const salvage_definitions = loadSalvageDefinitionsFromDisk(&file_source, arena);

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
