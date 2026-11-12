//! Handler-drain tests for the UI-surface events - the class-1 semantic
//! surface state on GameState (`ui_surfaces`), behind the
//! `toggle_ui_surface` / `inspect_entity` machinery events + their
//! `player_*` orchestrators. See DESIGN → UI Framework → UI state
//! classification. Tier B (the harness): push the orchestrator, run to
//! idle, assert on `current_state.ui_surfaces` (undo/redo restoration
//! included - the state rides the timeline).

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
const input_handlers = @import("input_handlers.zig");

test "player_toggle_ui_surface: flips the surface state, undo/redo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The options menu exists on every screen - the default main-menu
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
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));

    // The toggle rides the undo timeline (the surface state is captured by
    // snapshots) - undo re-closes, redo re-opens.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
    try testing.expect(history.redo(event_handlers.processEvent));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
}

test "surface-gated orchestrators: a recorded panel open makes the action replay-legal" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The legality mirror of the live pointer gate (see DESIGN →
    // Determinism → Replay PLAYER-ACTION LEGALITY): a salvage whose
    // inventory panel was never OPENED is an illegal log - so the panel
    // open must be a RECORDED action for the replay to pass validation.
    var history = harness.newHistory(.{
        .screen = .hub,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = .{ .player = .{} },
    });
    runToIdle(&history);
    const weapon: types.Weapon = .{ .name = "salvage pin", .weapon_type = .sword, .weapon_damage = 4 };
    history.current_state.hub.?.player.inventory.slots[0] = .{ .weapon = weapon };

    // Open the inventory panel through the recorded surface event, then
    // salvage - the replay (undo below) re-runs the recorded open + the
    // salvage and the legality gate passes.
    test_harness.openMiddlePanel(&history, .inventory);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_salvage_inventory_item = .{
            .inventory_slot_index = 0,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(
        @as(?types.Item, null),
        history.current_state.hub.?.player.inventory.slots[0],
    );

    // The undo replays through the recorded open + salvage (validation
    // included) and restores the item.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.hub.?.player.inventory.slots[0] != null);
    try testing.expectEqualStrings(
        "salvage pin",
        history.current_state.hub.?.player.inventory.slots[0].?.weapon.name,
    );
}

test "tips surface: flips via the toggle orchestrator, undo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The tips overlay is legal on any screen (opened from the global
    // top bar) - the default main-menu state needs no setup.
    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_toggle_ui_surface = .{
            .surface = .tips,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.tips));

    // Class-1: the surface rides the undo timeline.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.tips));
    try testing.expect(history.redo(event_handlers.processEvent));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.tips));
}

test "cycle_tips: steps + wraps the viewed tip on UiState, off the timeline" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(null);
    // The tips list is history-loaded in production; the test writes the
    // field directly (the harness passes an empty list). Static strings -
    // the arena-backed history never runs the deinit that frees them.
    history.tips = &.{ "alpha", "beta", "gamma" };
    runToIdle(&history);

    // Cycling while the panel is CLOSED is a no-op (the consumption
    // guard).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .cycle_tips,
    }, .{ .tips_direction = .next }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.session.ui_state.tips_index);

    // Open the surface, then cycle: next steps forward, wraps at the end,
    // previous wraps at the start. No timeline step (a view affordance -
    // the click pushes no event beyond itself, so nothing becomes
    // undoable).
    history.current_state.ui_surfaces.openSurface(.tips);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .cycle_tips,
    }, .{ .tips_direction = .next }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .cycle_tips,
    }, .{ .tips_direction = .next }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 2), history.session.ui_state.tips_index);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .cycle_tips,
    }, .{ .tips_direction = .next }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.session.ui_state.tips_index);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .cycle_tips,
    }, .{ .tips_direction = .previous }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 2), history.session.ui_state.tips_index);
    try testing.expect(!history.canUndo());

    // A single-tip list no-ops (nothing to cycle).
    history.tips = &.{"only"};
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .cycle_tips,
    }, .{ .tips_direction = .next }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 2), history.session.ui_state.tips_index);
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
