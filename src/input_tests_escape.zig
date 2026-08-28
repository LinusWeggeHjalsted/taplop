//! Tests for the Escape overlay chain (`handleEscapeKey`, reached via
//! `handleAnytimeInput`'s `toggle_options_menu` arm): Escape closes the
//! topmost open overlay (settings, load-save browser, credits, world map /
//! full combat log, options menu) or fires the mission fail/complete
//! overlay's primary button; with nothing open it opens the options menu
//! (level/hub only). See DESIGN → Input → Escape overlay chain.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const events = @import("events.zig");
const input_handlers = @import("input_handlers.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;

const three_by_three = [_]types.Vector2{
    .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
    .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
    .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 },
};

/// Drive one handleAnytimeInput call with only the Escape action set. No UI
/// elements + a far-away pointer, so nothing but the escape chain can react.
fn pressEscape(history: *state.GameStateHistory) void {
    var anytime: input.AnytimeInput = .{};
    anytime.toggle_options_menu = true;
    input_handlers.handleAnytimeInput(history, anytime, .{ .x = -4096, .y = -4096 }, &.{});
}

test "escape: settings closes alone, options menu beneath stays open" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    // In-game drill-in: settings sits on top of the options menu. Escape
    // steps back to the menu, closing only the settings layer...
    history.session.ui_state.options_menu_open = true;
    history.session.ui_state.settings_open = true;
    pressEscape(&history);
    try testing.expect(!history.session.ui_state.settings_open);
    try testing.expect(history.session.ui_state.options_menu_open);

    // ...and a second Escape steps back out of the options menu.
    pressEscape(&history);
    try testing.expect(!history.session.ui_state.options_menu_open);
}

test "escape: with nothing open, opens the options menu (level)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    pressEscape(&history);
    try testing.expect(history.session.ui_state.options_menu_open);
}

test "escape: main menu no-op with no overlay; closes credits + load-save browser" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    // No overlay up on the main menu → Escape does nothing (the options
    // menu's entries are meaningless there).
    pressEscape(&history);
    try testing.expect(!history.session.ui_state.options_menu_open);

    // Credits + load-save browser each close on Escape.
    history.session.ui_state.credits_open = true;
    pressEscape(&history);
    try testing.expect(!history.session.ui_state.credits_open);

    history.session.ui_state.load_save_menu_open = true;
    pressEscape(&history);
    try testing.expect(!history.session.ui_state.load_save_menu_open);
    try testing.expect(!history.session.ui_state.options_menu_open);
}

test "escape: closes the topmost full-screen overlay only" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    // Both overlays open: slot 1 (full combat log) draws on top, so the
    // first Escape closes it and leaves the world map open.
    history.session.ui_state.open_full_screen_overlays[0] = .world_map;
    history.session.ui_state.open_full_screen_overlays[1] = .full_combat_log;
    pressEscape(&history);
    try testing.expect(history.session.ui_state.open_full_screen_overlays[0] == .world_map);
    try testing.expect(history.session.ui_state.open_full_screen_overlays[1] == null);

    pressEscape(&history);
    try testing.expect(history.session.ui_state.open_full_screen_overlays[0] == null);
    try testing.expect(history.session.ui_state.open_full_screen_overlays[1] == null);
}

test "escape: mission fail exits the mission" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        // Dead player (entity 0) → the view-derived mission_fail overlay.
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .max_health = 20, .current_health = 0 }},
        &three_by_three,
    ));
    history.current_state.player_data.current_campaign = "main_campaign";
    history.current_state.mission = .{
        .name = "beginnings",
        .path = "data/campaigns/main_campaign/missions/beginnings",
        .level_count = 1,
        .current_level_index = 1,
        .start_hub = "camp_at_the_crossroads",
    };
    test_harness.runToIdle(&history);

    // Escape ≡ the overlay's Exit Mission button: the player_exit_mission
    // orchestrator is recorded first, then drains (end_level → end_mission →
    // start_hub), leaving the player in the mission's start hub.
    pressEscape(&history);
    try testing.expect(history.current_state.event_stack.len == 0);
    try testing.expect(history.event_history.items.len >= 1);
    const first = history.event_history.items[0];
    try testing.expectEqual(
        @as(std.meta.Tag(@TypeOf(first)), .player_input_event),
        std.meta.activeTag(first),
    );
    try testing.expectEqual(
        @as(std.meta.Tag(events.PlayerInputEvent), .player_exit_mission),
        std.meta.activeTag(first.player_input_event),
    );
    try testing.expectEqual(state.Screen.hub, history.current_state.screen);
    try testing.expect(history.current_state.level == null);
}

test "escape: mission complete continues (dismisses the overlay)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    // The overlay is view-derived from last_completed_mission (live it shows
    // in the hub post-mission; the chain only reads the field). Escape ≡ the
    // Continue button: dismiss_mission_complete lands on the undo timeline
    // and clears the field.
    history.current_state.last_completed_mission = .{
        .name = "beginnings",
        .path = "data/campaigns/main_campaign/missions/beginnings",
    };
    pressEscape(&history);
    try testing.expect(history.current_state.last_completed_mission == null);
    try testing.expectEqual(@as(usize, 1), history.event_history.items.len);
    const first = history.event_history.items[0];
    try testing.expectEqual(
        @as(std.meta.Tag(events.PlayerInputEvent), .dismiss_mission_complete),
        std.meta.activeTag(first.player_input_event),
    );
}
