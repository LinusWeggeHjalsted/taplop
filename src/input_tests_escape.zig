//! Tests for the Escape overlay chain (`handleEscapeKey`, reached via
//! `handleAnytimeInput`'s `escape` arm): Escape closes the topmost open
//! overlay - the announcements first (mission complete / fail, fixed
//! above the stack), then the TOP of the overlay stack (the last opened,
//! the same one that draws on top - any overlay, any stacking order); a
//! derived test walks the surface enum itself, so a new stackable surface
//! gets its layered-close coverage automatically. With nothing open,
//! Escape opens the options menu on ANY screen (the main-menu variant
//! carries its own entries). See DESIGN → Input → Escape overlay chain.

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
    history.current_state.ui_surfaces.openSurface(.options_menu);
    history.current_state.ui_surfaces.openSurface(.settings);
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.settings));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));

    // ...and a second Escape steps back out of the options menu.
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
}

test "escape: every stackable surface closes alone, derived from the surface enum" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    // Derived expectations: the test walks every UiSurfaceId itself (minus
    // the escape-excluded middle panels), so a new stackable surface is
    // exercised the moment it is added - no per-surface test to remember.
    // The options menu + world map ride open UNDER the surface under test
    // (it is opened LAST, on top): each close must be layered (the surface
    // under test flips, nothing beneath it does). The options menu is
    // skipped as the surface under test because closing it is the
    // whole-walk behavior the dedicated tests below already pin; the world
    // map is skipped because it is one of the riders (the dedicated
    // topmost-overlay tests below cover it as the surface under test).
    inline for (@typeInfo(types.UiSurfaceId).@"enum".field_names) |field_name| {
        const surface = @field(types.UiSurfaceId, field_name);
        if (comptime input_handlers.escapeExcluded(surface)) continue;
        if (surface == .options_menu or surface == .world_map) continue;

        history.current_state.ui_surfaces.openSurface(.options_menu);
        history.current_state.ui_surfaces.openSurface(.world_map);
        history.current_state.ui_surfaces.openSurface(surface);
        pressEscape(&history);

        try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(surface));
        try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
        try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.world_map));

        // Reset for the next surface (direct state writes, same as the
        // forcing above - the forced state never went through the
        // timeline).
        history.current_state.ui_surfaces.closeAll();
    }
}

test "escape: pops the topmost overlay regardless of kind (the map over the menu)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    // The stack, not a fixed kind ladder, decides: with the world map
    // opened AFTER the options menu, the map is the topmost overlay and
    // Escape closes IT first - the menu underneath survives.
    history.current_state.ui_surfaces.openSurface(.options_menu);
    history.current_state.ui_surfaces.openSurface(.world_map);
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.world_map));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));

    // ...and the reverse opening order flips which one Escape takes.
    history.current_state.ui_surfaces.closeAll();
    history.current_state.ui_surfaces.openSurface(.world_map);
    history.current_state.ui_surfaces.openSurface(.options_menu);
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.world_map));
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
    history.current_state.ui_surfaces.openSurface(.options_menu);
    history.current_state.ui_surfaces.openSurface(.tips);
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.tips));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));

    // On the main menu, tips also sits above the main-menu overlays (its
    // view rung: just above them, under mission fail/complete): with both
    // up, tips closes first.
    history.current_state.screen = .main_menu;
    history.current_state.ui_surfaces.openSurface(.credits);
    history.current_state.ui_surfaces.openSurface(.tips);
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.tips));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.credits));
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
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
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
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));

    // A second Escape closes it.
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));

    // Credits + load-save browser each close on Escape.
    history.current_state.ui_surfaces.openSurface(.credits);
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.credits));

    history.current_state.ui_surfaces.openSurface(.load_save_menu);
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.load_save_menu));
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
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
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.credits));

    // The credits Back button reuses the action to close.
    var anytime_close: input.AnytimeInput = .{};
    anytime_close.options_action = .open_credits;
    input_handlers.handleAnytimeInput(&history, anytime_close, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.credits));

    // Exit Game: a request flag for the game loop's exit condition - not
    // a state transform, nothing recorded.
    var anytime_exit: input.AnytimeInput = .{};
    anytime_exit.options_action = .exit_game;
    input_handlers.handleAnytimeInput(&history, anytime_exit, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(history.session.quit_requested);
}

test "toggling a covered overlay raises it (the map behind tips)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    // The scenario that motivated the raise semantics, end to end through
    // the recorded path: open the map (keybind/top-bar button), open tips
    // (the top-bar `?`), then fire the map toggle AGAIN - the icon reads
    // as "bring to front", so the covered map RAISES to the top instead
    // of closing invisibly behind tips.
    var open_map: input.AnytimeInput = .{};
    open_map.in_game.toggle_world_map = true;
    input_handlers.handleAnytimeInput(&history, open_map, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.world_map));

    var open_tips: input.AnytimeInput = .{};
    open_tips.options_action = .open_tips;
    input_handlers.handleAnytimeInput(&history, open_tips, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.tips));

    input_handlers.handleAnytimeInput(&history, open_map, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.world_map));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.tips));
    try testing.expectEqual(types.UiSurfaceId.world_map, history.current_state.ui_surfaces.topOverlay());

    // Escape pops the raised map first; tips survives beneath it.
    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.world_map));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.tips));
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

    // Both overlays open: the combat log opened last (draws on top), so
    // the first Escape closes it and leaves the world map open.
    history.current_state.ui_surfaces.openSurface(.world_map);
    history.current_state.ui_surfaces.openSurface(.full_combat_log);
    pressEscape(&history);
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.world_map));
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.full_combat_log));

    pressEscape(&history);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.world_map));
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.full_combat_log));
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
    // the player was in when the mission started), as a hub uuid. The
    // loaded campaign resolves uuid -> dir for the start_hub read.
    const campaign = types.Campaign{
        .uuid = "8ecb3f44-9a3d-497c-95a9-a000b8517b7d",
        .dir = "main_campaign",
        .hubs = &.{
            .{ .uuid = "03aeefda-c68b-4853-b65a-d46edb9790f1", .dir = "camp_at_the_crossroads", .position = .{ .x = 0, .y = 0 } },
        },
    };
    history.current_state.campaign = campaign;
    history.current_state.player_data.current_hub = "03aeefda-c68b-4853-b65a-d46edb9790f1";
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
