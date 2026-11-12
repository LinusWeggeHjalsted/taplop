//! Tests for the Escape overlay chain (`handleEscapeKey`, reached via
//! `handleAnytimeInput`'s `escape` arm): Escape closes the
//! topmost open overlay - a walk down `escape_ladder`, which mirrors the
//! view's z-order (settings, tips, load-save browser, credits, world map /
//! full combat log, options menu) and fires the mission fail/complete
//! overlay's primary button; a derived test walks the ladder itself, so a
//! new toggle rung gets its layered-close coverage automatically. With
//! nothing open, Escape opens the options menu
//! on ANY screen (the main-menu variant carries its own entries). See
//! DESIGN → Input → Escape overlay chain.

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
    anytime.escape = true;
    input_handlers.handleAnytimeInput(history, anytime, null, .{ .x = -4096, .y = -4096 }, &.{});
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
    history.current_state.ui_surfaces.options_menu_open = true;
    history.current_state.ui_surfaces.settings_open = true;
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.settings_open);
    try testing.expect(history.current_state.ui_surfaces.options_menu_open);

    // ...and a second Escape steps back out of the options menu.
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.options_menu_open);
}

test "escape: every toggle rung closes alone, derived from the ladder" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    // Derived expectations: the test walks escape_ladder itself, so a new
    // toggle rung is exercised the moment it's added - no per-rung test to
    // remember. The options menu + a full-screen overlay ride open UNDER
    // every rung: each close must be layered (the rung's own bit flips,
    // nothing beneath it does). The options menu is skipped as a rung
    // because closing it is the whole-walk behavior the dedicated tests
    // below already pin.
    for (input_handlers.escape_ladder) |rung| {
        const surface = switch (rung) {
            .toggle_surface => |rung_surface| rung_surface,
            else => continue,
        };
        if (surface == .options_menu) continue;

        history.current_state.ui_surfaces.open_full_screen_overlays[0] = .world_map;
        history.current_state.ui_surfaces.options_menu_open = true;
        history.current_state.ui_surfaces.toggle(surface);
        pressEscape(&history);

        try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(surface));
        try testing.expect(history.current_state.ui_surfaces.options_menu_open);
        try testing.expect(history.current_state.ui_surfaces.open_full_screen_overlays[0] == .world_map);

        // Reset for the next rung (direct bit flips, same as the forcing
        // above - the forced state never went through the timeline).
        history.current_state.ui_surfaces.closeAll();
    }
}

test "escape: tips closes alone, above the options menu and the main-menu overlays" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    // The tips rung is the one tips shipped without (the chain-mirror drift
    // that turned escape_ladder into a table). Tips opens on top of the
    // options menu on any screen: Escape closes only the tips layer.
    history.current_state.ui_surfaces.options_menu_open = true;
    history.current_state.ui_surfaces.tips_open = true;
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.tips_open);
    try testing.expect(history.current_state.ui_surfaces.options_menu_open);

    // On the main menu, tips also sits above the main-menu overlays (its
    // view rung: just above them, under mission fail/complete): with both
    // up, tips closes first.
    history.current_state.screen = .main_menu;
    history.current_state.ui_surfaces.credits_open = true;
    history.current_state.ui_surfaces.tips_open = true;
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.tips_open);
    try testing.expect(history.current_state.ui_surfaces.credits_open);
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
    try testing.expect(history.current_state.ui_surfaces.options_menu_open);
}

test "escape: main menu opens + closes the options menu; closes credits + load-save browser" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    // Nothing open on the main menu → Escape opens the options menu (the
    // main-menu variant: Settings/Credits/Exit Game, not the session
    // verbs).
    pressEscape(&history);
    try testing.expect(history.current_state.ui_surfaces.options_menu_open);

    // A second Escape closes it.
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.options_menu_open);

    // Credits + load-save browser each close on Escape.
    history.current_state.ui_surfaces.credits_open = true;
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.credits_open);

    history.current_state.ui_surfaces.load_save_menu_open = true;
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.load_save_menu_open);
    try testing.expect(!history.current_state.ui_surfaces.options_menu_open);
}

test "options menu on the main menu: credits toggles via options_action; exit game requests the quit" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    // The credits + exit-game buttons live in the options menu, so they
    // route through the anytime options_action path (idle input is gated
    // while the menu is open).
    var anytime: input.AnytimeInput = .{};
    anytime.options_action = .open_credits;
    input_handlers.handleAnytimeInput(&history, anytime, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(history.current_state.ui_surfaces.credits_open);

    // The credits Back button reuses the action to close.
    var anytime_close: input.AnytimeInput = .{};
    anytime_close.options_action = .open_credits;
    input_handlers.handleAnytimeInput(&history, anytime_close, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(!history.current_state.ui_surfaces.credits_open);

    // Exit Game: a request flag for the game loop's exit condition - not
    // a state transform, nothing recorded.
    var anytime_exit: input.AnytimeInput = .{};
    anytime_exit.options_action = .exit_game;
    input_handlers.handleAnytimeInput(&history, anytime_exit, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(history.session.quit_requested);
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
    history.current_state.ui_surfaces.open_full_screen_overlays[0] = .world_map;
    history.current_state.ui_surfaces.open_full_screen_overlays[1] = .full_combat_log;
    pressEscape(&history);
    try testing.expect(history.current_state.ui_surfaces.open_full_screen_overlays[0] == .world_map);
    try testing.expect(history.current_state.ui_surfaces.open_full_screen_overlays[1] == null);

    pressEscape(&history);
    try testing.expect(history.current_state.ui_surfaces.open_full_screen_overlays[0] == null);
    try testing.expect(history.current_state.ui_surfaces.open_full_screen_overlays[1] == null);
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
    // The entering hub (the mission-exit path reads current_hub - the hub
    // the player was in when the mission started).
    history.current_state.player_data.current_hub = "camp_at_the_crossroads";
    history.current_state.mission = .{
        .name = "beginnings",
        .path = "campaigns/main_campaign/missions/beginnings",
        .level_count = 1,
        .current_level_index = 1,
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
        .path = "campaigns/main_campaign/missions/beginnings",
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
