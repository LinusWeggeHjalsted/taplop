//! Handler-drain tests for the UI-surface events — the class-1 semantic
//! surface state on GameState (`ui_surfaces`), behind the
//! `toggle_ui_surface` / `inspect_entity` machinery events + their
//! `player_*` orchestrators. See DESIGN → UI Framework → UI state
//! classification. Tier B (the harness): push the orchestrator, run to
//! idle, assert on `current_state.ui_surfaces` (undo/redo restoration
//! included — the state rides the timeline).

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");
const event_handlers = @import("event_handlers.zig");
const event_push = @import("event_push.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;

test "player_toggle_ui_surface: flips the surface state, undo/redo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The options menu exists on every screen — the default main-menu
    // state needs no setup.
    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_toggle_ui_surface = .{
            .surface = .options_menu,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.ui_surfaces.options_menu_open);

    // The toggle rides the undo timeline (the surface state is captured by
    // snapshots) — undo re-closes, redo re-opens.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(!history.current_state.ui_surfaces.options_menu_open);
    try testing.expect(history.redo(event_handlers.processEvent));
    try testing.expect(history.current_state.ui_surfaces.options_menu_open);
}

test "player_inspect_entity: opens, retargets, and closes via the machinery" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entities = [_]types.Entity{ .{}, .{} };
    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &entities,
        &tiles,
    ));
    runToIdle(&history);

    const allocator = history.current_arena.allocator();
    // Open on entity 1 (the gesture resolved "no panel open").
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_inspect_entity = .{
            .entity_index = 1,
        } } }},
        allocator,
    );
    runToIdle(&history);
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.entity_inspect));
    try testing.expectEqual(@as(?u32, 1), history.current_state.ui_surfaces.inspected_entity_index);

    // Retarget on entity 0 (the gesture resolved "different entity").
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_inspect_entity = .{
            .entity_index = 0,
        } } }},
        allocator,
    );
    runToIdle(&history);
    try testing.expectEqual(@as(?u32, 0), history.current_state.ui_surfaces.inspected_entity_index);

    // Close (the gesture resolved "same entity").
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_inspect_entity = .{
            .entity_index = null,
        } } }},
        allocator,
    );
    runToIdle(&history);

    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.entity_inspect));
    try testing.expectEqual(@as(?u32, null), history.current_state.ui_surfaces.inspected_entity_index);

    // The whole open→retarget→close chain is three undo steps (one per
    // player action); undoing all three reverts to the un-opened state.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.entity_inspect));
    try testing.expectEqual(@as(?u32, 0), history.current_state.ui_surfaces.inspected_entity_index);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(?u32, 1), history.current_state.ui_surfaces.inspected_entity_index);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.entity_inspect));
}
