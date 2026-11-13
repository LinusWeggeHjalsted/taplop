//! Test harness for `processEvent` handler tests. Builds the shared session
//! bootstrap (a FileSource + the four config loads) once, then lets a test
//! spin up any number of fresh `GameStateHistory` instances against it via
//! `newHistory` and drive them with `runToIdle`. Each handler test is a
//! scripted mini-session: push events to reach a precondition, push the event
//! under test, run to idle, assert on `current_state`.
//!
//! The test owns the backing arena (typically `std.heap.ArenaAllocator.init(
//! std.testing.allocator)`) and passes its allocator into `Harness.init`; the
//! harness loads config into that arena, and every history the harness creates
//! allocates from it too - so freeing the arena at test end reclaims everything
//! with no per-history deinit (mirrors the existing main.zig tests). The
//! harness must outlive every history it creates (a stack-local harness in the
//! test satisfies this).
//!
//! See AGENTS → Build & Test (test discovery) and TODO → Tech debt (handler
//! coverage).

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const session_setup = @import("session_setup.zig");
const file_source_mod = @import("file_source.zig");
const event_handlers = @import("event_handlers.zig");
const event_push = @import("event_push.zig");
const shared = @import("handlers/shared.zig");

const FileSource = file_source_mod.FileSource;
const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Settings = types.Settings;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const ColorThemeDefinitions = types.ColorThemeDefinitions;

/// The shared session bootstrap. Owns the loaded config arrays in the test's
/// backing arena; histories are initialized with pointers into those arrays.
pub const Harness = struct {
    /// The test's backing arena allocator (every history this harness creates
    /// allocates from it; freeing it reclaims everything).
    arena: std.mem.Allocator,
    file_source: FileSource,
    settings: Settings,
    weapon_type_definitions: [session_setup.weapon_type_count]WeaponTypeDefinition,
    color_theme_definitions: ColorThemeDefinitions,
    salvage_definitions: types.SalvageDefinitions,

    /// Initialize the bootstrap: a scratch-dir-backed FileSource + the four
    /// config loads, all allocated into `arena`. The test owns `arena`
    /// (typically `backing.allocator()` from an `ArenaAllocator` it defers).
    ///
    /// The persistent layer is a fresh scratch dir (NOT cwd): tests that drain
    /// `end_level`/`write_save` to idle push REAL autosave writes (not
    /// replay-gated), which must not plant `saves/autosave.txt` in the project
    /// root - a planted autosave then breaks the "missing autosave is
    /// recoverable" test on every subsequent run. Reads fall through to the
    /// embedded map either way, so config loads are unaffected.
    pub fn init(arena: std.mem.Allocator) Harness {
        var threaded_io = std.Io.Threaded.init(arena, .{});
        defer threaded_io.deinit();
        const io = threaded_io.io();
        const scratch = "zig-cache/test-harness-persistent";
        std.Io.Dir.cwd().deleteTree(io, scratch) catch {}; // fresh per harness
        const persistent_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
            .open_options = .{ .access_sub_paths = true, .iterate = true },
        }) catch @panic("failed to create test-harness scratch dir");
        // Leaks the dir handle + io for the process lifetime of the test run -
        // the harness's FileSource borrows both and there is no harness-wide
        // teardown hook to close them in. Test binaries are short-lived.
        const file_source = FileSource.init(io, persistent_dir);

        var startup: session_setup.StartupMemory = .{};
        return .{
            .arena = arena,
            .file_source = file_source,
            .settings = session_setup.loadSettingsFromDisk(&file_source, arena, &startup),
            .weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &startup),
            .color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &startup),
            .salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &startup),
        };
    }

    /// Create a fresh `GameStateHistory` against this harness's config + file
    /// source. The history's `weapon_type_definitions` pointer references the
    /// harness's field, so the harness must outlive the history. `starting`
    /// defaults to the main-menu start state (`defaultStartingState`) if null.
    pub fn newHistory(self: *Harness, starting: ?GameState) GameStateHistory {
        const start = starting orelse defaultStartingState();
        return GameStateHistory.init(
            self.arena,
            start,
            self.settings,
            &self.weapon_type_definitions,
            self.color_theme_definitions,
            self.salvage_definitions,
            &.{},
            &self.file_source,
            self.file_source.io,
        );
    }
};

/// The standard main-menu start state: an empty player with `open_main_menu`
/// queued on the event stack. Matches what `createSessionSetup` builds live.
pub fn defaultStartingState() GameState {
    return .{
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
}

/// A level-context GameState for combat/AI handler tests. `entities` is
/// allocated in `arena` (the harness's backing arena) as a `[]Entity` and
/// handed to the level as `[]const Entity` - handlers mutate entities via
/// `@constCast` (see `getLevelEntity`), so this matches the live mutation
/// path. `tiles` is the walkable tile set; `turn_phase` defaults to null
/// (tests that need a phase set it directly on `history.current_state.level`).
/// Entity 0 is conventionally the player (team 0); enemies are team != 0.
pub fn levelStateWithEntities(
    arena: std.mem.Allocator,
    entities: []const types.Entity,
    tiles: []const types.Vector2,
) GameState {
    const entity_slice = arena.dupe(types.Entity, entities) catch
        @panic("failed to allocate test entities");
    return .{
        .screen = .level,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = .{
            .level_tiles = tiles,
            .entities = entity_slice,
        },
        .hub = null,
    };
}

/// Mutable pointer to a level entity (mirrors `shared.getLevelEntity`).
/// Panics if there's no level - handler tests that call this implicitly assert
/// they set one up.
pub fn levelEntity(history: *GameStateHistory, entity_index: usize) *types.Entity {
    return &@constCast(history.current_state.level.?.entities)[entity_index];
}

/// Drive event processing until the stack empties (test harness: no update()
/// loop, so waits are cleared rather than timed). Mirrors the live gameLoop's
/// idle bookkeeping: on stack-empty, an idle point is recorded (snapshot +
/// compact), so a forward-played session accumulates the same idle points
/// the live loop would - which reconstruction then derives from virtual
/// depth. DEDUPED via maybeRecordIdlePoint: some commit paths drain +
/// record internally (resolveTextEditOutcome's pushPlayerActionAndDrain),
/// and an unconditional recordIdlePoint would append the same event
/// index twice - duplicate idle points make undo restore to the CURRENT
/// state (a no-op undo step) instead of the previous one.
pub fn runToIdle(history: *GameStateHistory) void {
    while (history.current_state.event_stack.len > 0) {
        event_handlers.processEvent(history);
        if (history.load_error) std.debug.panic("runToIdle: handler set load_error (test content should be valid): {s}", .{history.session.pending_error orelse "(no pending_error set)"});
        history.current_state.waiting = null;
    }
    history.maybeRecordIdlePoint(true);
}

/// Open a middle panel through the real event path (the recorded
/// `player_toggle_ui_surface`), so a fixture's later
/// inventory/gear/skills orchestrators pass the panel-open legality gate
/// on replay/undo (the check mirrors the live gate - see DESIGN →
/// Determinism → Replay PLAYER-ACTION LEGALITY).
pub fn openMiddlePanel(history: *GameStateHistory, panel_id: types.MiddlePanelId) void {
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_toggle_ui_surface = .{
            .surface = switch (panel_id) {
                .inventory => .inventory,
                .gear => .gear,
                .skills => .skills,
                .entity_inspect => .entity_inspect,
            },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(history);
}

test "harness: newHistory reaches the main menu and idles" {
    // Smoke test: the bootstrap loads, a fresh history starts at the main
    // menu, and runToIdle drains the queued open_main_menu event.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    runToIdle(&history);
    try std.testing.expectEqual(state.Screen.main_menu, history.current_state.screen);
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    // No key-validation warnings from shipped startup config (settings,
    // color themes, weapon types, salvage) - the shipped files should have
    // no unknown keys. pending_error is null.
    try std.testing.expectEqual(@as(?[]const u8, null), history.session.pending_error);
}
