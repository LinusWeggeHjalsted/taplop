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

// --- campaign browser (the world map's picker) ---

test "campaign browser: opens from the map, picks view (cache), the active pick clears it" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } },
    ));
    runToIdle(&history);

    // The player is in the OFFICIAL campaign (the shipped uuid) - the
    // active-campaign pick below must clear the cache.
    history.current_state.player_data.current_campaign_uuid = "8ecb3f44-9a3d-497c-95a9-a000b8517b7d";

    // A local campaign to view: campaign.txt + a resolvable hub dir (the
    // scan-side fixtures the graph derivation reads).
    history.file_source.writeFile(
        "campaigns/zeta_lands/campaign.txt",
        "Metadata\nfile_format_version 3\ncampaign_uuid zeta-uuid\nname Zeta Lands\nstart_hub zeta-hub\n\nHubs\nhub_uuid zeta-hub\nposition 0 0\n",
    ) catch @panic("write zeta campaign");
    history.file_source.writeFile(
        "campaigns/zeta_lands/hubs/zeta_hub/hub.txt",
        "Metadata\nfile_format_version 4\nhub_uuid zeta-hub\nname Zeta Hub\n",
    ) catch @panic("write zeta hub");

    // The browser opens from the map (the top-left campaign button's
    // action): scan-on-open populates both tabs.
    history.current_state.ui_surfaces.openSurface(.world_map);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_campaign_browser,
    }, null, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.campaign_browser));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.world_map));
    try testing.expectEqual(types.CampaignBrowserTab.local, history.session.ui_state.campaign_browser_tab);
    try testing.expectEqual(@as(usize, 1), history.session.campaign_browser_local.len);
    try testing.expectEqualStrings("Zeta Lands", history.session.campaign_browser_local[0].name);
    try testing.expect(history.session.campaign_browser_official.len > 0);

    // The OFFICIAL tab's row (the main campaign = the ACTIVE campaign):
    // the pick CLEARS the cache (the map falls back to the live GameState
    // campaign) and closes the browser via the recorded toggle.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_campaign_browser_tab,
    }, .{ .campaign_browser_tab = .official }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(types.CampaignBrowserTab.official, history.session.ui_state.campaign_browser_tab);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .view_campaign_row,
    }, .{ .campaign_row = 0 }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.campaign_browser));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.world_map));
    try testing.expectEqual(@as(?types.Campaign, null), history.session.viewed_campaign);

    // A LOCAL pick: the graph derives into the cache (viewing ≠ state -
    // nothing recorded beyond the browser's own close toggle) and the
    // map stays open underneath.
    const events_before = history.event_history.items.len;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_campaign_browser,
    }, null, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_campaign_browser_tab,
    }, .{ .campaign_browser_tab = .local }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .view_campaign_row,
    }, .{ .campaign_row = 0 }, .{ .x = 0, .y = 0 }, &.{});
    const viewed = history.session.viewed_campaign;
    try testing.expect(viewed != null);
    try testing.expectEqualStrings("Zeta Lands", viewed.?.name);
    try testing.expectEqualStrings("zeta-uuid", viewed.?.uuid);
    try testing.expectEqual(@as(usize, 1), viewed.?.hubs.len);
    try testing.expectEqualStrings("Zeta Hub", viewed.?.hubs[0].name);
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.campaign_browser));

    // Only the browser's own open/close toggles recorded (two opens + two
    // closes = 4 events; the picks themselves are session-side).
    try testing.expectEqual(events_before + 4, history.event_history.items.len);
}

test "options menu open: surface toggles dispatch (map opens on top), gameplay stays paused" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .main_hand_weapon = .{
            .name = "sword",
            .weapon_type = .sword,
        } }},
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } },
    ));
    runToIdle(&history);

    // The menu open over the level. The map keybind is a surface toggle -
    // UI navigation, not gameplay - so it dispatches before the modal gate
    // and the map opens ON TOP of the menu (the stack model; the menu's
    // own buttons work the same way via options_action).
    history.current_state.ui_surfaces.openSurface(.options_menu);
    var anytime: @import("input.zig").AnytimeInput = .{};
    anytime.in_game.toggle_world_map = true;
    input_handlers.handleAnytimeInput(&history, anytime, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.world_map));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
    try testing.expectEqual(types.UiSurfaceId.world_map, history.current_state.ui_surfaces.topOverlay());

    // GAMEPLAY stays paused under the menu: swap_weapons (the fixture's
    // weapon means the no-op gate cannot mask the block) records nothing.
    var gameplay_anytime: @import("input.zig").AnytimeInput = .{};
    gameplay_anytime.in_game.swap_weapons = true;
    const events_before = history.event_history.items.len;
    input_handlers.handleAnytimeInput(&history, gameplay_anytime, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expectEqual(events_before, history.event_history.items.len);

    // Escape pops the map first, then the menu (the layered close).
    input_handlers.handleAnytimeInput(&history, .{ .escape = true }, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.world_map));
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
    input_handlers.handleAnytimeInput(&history, .{ .escape = true }, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
}

test "any fullscreen overlay pauses gameplay input (world map, tips, settings)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .main_hand_weapon = .{
            .name = "sword",
            .weapon_type = .sword,
        } }},
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } },
    ));
    runToIdle(&history);

    // The pause rule generalized: EVERY fullscreen overlay gates gameplay
    // input exactly like the options menu (the test above), not just the
    // menu. The map's own interactions still dispatch pre-gate (the
    // map-acting tests pin that half); here the gameplay arm under the
    // open overlay records nothing.
    for ([_]types.UiSurfaceId{ .world_map, .tips, .settings }) |surface| {
        history.current_state.ui_surfaces.openSurface(surface);
        var gameplay_anytime: @import("input.zig").AnytimeInput = .{};
        gameplay_anytime.in_game.swap_weapons = true;
        const events_before = history.event_history.items.len;
        input_handlers.handleAnytimeInput(&history, gameplay_anytime, null, .{ .x = -4096, .y = -4096 }, &.{});
        try testing.expectEqual(events_before, history.event_history.items.len);
        // Close through the recorded toggle (the real close path).
        event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .{ .player_toggle_ui_surface = .{
            .surface = surface,
        } } }}, history.current_arena.allocator());
        runToIdle(&history);
        try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(surface));
    }
}

test "load-save browser dispatches through the anytime path (pre-gate)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // The browser is a main-menu surface - the fresh history starts there.
    var history = harness.newHistory(null);
    runToIdle(&history);
    try testing.expect(state.Screen.main_menu == history.current_state.screen);

    // The toggle dispatches via options_action (the anytime umbrella) and
    // opens the browser - it must work while overlays pause update(), which
    // is what makes the browser's own Back button work under the uniform
    // overlay gate.
    input_handlers.handleAnytimeInput(&history, .{ .options_action = .toggle_load_save_menu }, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.load_save_menu));

    // While the browser is open, the overlay gate blocks everything below
    // the pre-gate region (anyOverlayOpen) - and the browser's Back button
    // still closes it through the same anytime path.
    try testing.expect(history.current_state.ui_surfaces.anyOverlayOpen());
    input_handlers.handleAnytimeInput(&history, .{ .options_action = .toggle_load_save_menu }, null, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.load_save_menu));
    try testing.expect(!history.current_state.ui_surfaces.anyOverlayOpen());
}
