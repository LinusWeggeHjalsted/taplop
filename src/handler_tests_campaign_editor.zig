//! Campaign-editor handler tests (slice 3b): the open/close framing
//! events against the REAL official campaign (the embedded content - the
//! open is a reconstruction-read event, so the drain exercises the cache
//! reads + the inverse projection end to end) + the fresh-campaign
//! construction + the close teardown. The harness conventions: see
//! test_harness.zig; the tier conventions: DESIGN → Testing.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const parser = @import("parser.zig");
const event_handlers = @import("event_handlers.zig");
const event_push = @import("event_push.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;

test "open_campaign_editor: the official campaign projects into the authored graph" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = "campaigns/main_campaign",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const editor = history.current_state.campaign_editor orelse {
        std.debug.print("campaign editor did not open; pending error: {s}\n", .{history.session.pending_error orelse "(none)"});
        return error.TestUnexpectedResult;
    };

    // The framing: the screen transitioned, the campaign installed.
    try testing.expectEqual(state.Screen.campaign_editor, history.current_state.screen);
    try testing.expectEqualStrings("Main Campaign", editor.campaign_name);
    try testing.expectEqualStrings("campaigns/main_campaign", editor.campaign_dir);
    try testing.expect(editor.campaign_uuid.len > 0);

    // The official campaign: ONE placed hub at the origin, the start hub.
    try testing.expectEqual(@as(usize, 1), editor.hubs.len);
    const hub = editor.hubs[0];
    try testing.expectEqualStrings("Camp at the Crossroads", hub.name);
    try testing.expectEqual(@as(i32, 0), hub.position.x);
    try testing.expectEqual(@as(i32, 0), hub.position.y);
    try testing.expectEqual(@as(?u32, 0), editor.start_hub);
    try testing.expectEqual(@as(u32, 0), hub.handle);
    // The grid carried over from hub.txt. The spawn is (0,0) by
    // construction: loadHub normalizes to spawn-relative coordinates
    // ('!' -> the origin - the bbox-growth-invariant replay invariant;
    // EditorLevel's levels load the same way, so the hub grid matches the
    // editor's own convention).
    try testing.expect(hub.grid.level_tiles.len > 0);
    try testing.expectEqual(@as(i32, 0), hub.grid.player_start.x);
    try testing.expectEqual(@as(i32, 0), hub.grid.player_start.y);

    // Four missions - the four self-loops (destination == the start hub),
    // authored directions 0/90/180/270, each with an exit placement in
    // the hub (positions from the layout's digit codes).
    try testing.expectEqual(@as(usize, 4), editor.missions.len);
    var seen_directions: [4]bool = .{ false, false, false, false };
    for (editor.missions) |mission| {
        try testing.expectEqual(@as(?u32, 0), mission.start);
        try testing.expectEqual(@as(?u32, 0), mission.destination);
        try testing.expect(mission.uuid.len > 0);
        try testing.expect(mission.name.len > 0);
        try testing.expect(mission.dir.len > 0);
        // Authored direction = 0/90/180/270 (the auto-spread default would
        // be 360 * index / 4 = 0/90/180/270 too - the official content
        // AUTHORS them, so the value is present either way; assert the
        // class shape, one of the four).
        const direction = mission.direction orelse return error.TestUnexpectedResult;
        try testing.expect(direction % 90 == 0 and direction < 360);
        seen_directions[@intCast(direction / 90)] = true;
    }
    try testing.expect(seen_directions[0] and seen_directions[1] and seen_directions[2] and seen_directions[3]);
    try testing.expectEqual(@as(usize, 4), hub.exit_placements.len);
    // Each placement addresses a distinct mission (one marker per mission).
    for (hub.exit_placements, 0..) |placement, index| {
        for (hub.exit_placements[index + 1 ..]) |other| {
            try testing.expect(placement.mission != other.mission);
        }
    }

    // The campaign-shared decoration palette: the official hub's nine
    // distinct definitions (A-I in the shipped layout) dedup in; the
    // shipped 'A' (ruin_10) is PLACED TWICE, so ten placements address
    // nine types.
    try testing.expectEqual(@as(usize, 9), editor.decoration_types.len);
    try testing.expectEqual(@as(usize, 10), hub.grid.decoration_placements.len);

    // Handle mint: 1 hub + 4 missions consumed handles 0-4.
    try testing.expectEqual(@as(u32, 5), editor.next_handle);
}

test "open_campaign_editor: null dir opens the fresh default campaign" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = null,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const editor = history.current_state.campaign_editor.?;
    try testing.expectEqual(state.Screen.campaign_editor, history.current_state.screen);
    try testing.expectEqualStrings("New Campaign", editor.campaign_name);
    // Identity is empty until the first save (the write-only mint).
    try testing.expectEqual(@as(usize, 0), editor.campaign_uuid.len);
    try testing.expectEqual(@as(usize, 0), editor.campaign_dir.len);

    // ONE hub: the start hub at the map origin with the single-'!' default
    // grid - one tile, the spawn on it.
    try testing.expectEqual(@as(usize, 1), editor.hubs.len);
    const hub = editor.hubs[0];
    try testing.expectEqualStrings("New Hub", hub.name);
    try testing.expectEqual(@as(?u32, 0), editor.start_hub);
    try testing.expectEqual(@as(usize, 1), hub.grid.level_tiles.len);
    try testing.expectEqual(@as(i32, 0), hub.grid.player_start.x);
    try testing.expectEqual(@as(i32, 0), hub.grid.player_start.y);
    try testing.expectEqual(@as(usize, 0), editor.missions.len);
    try testing.expectEqual(@as(u32, 1), editor.next_handle);
}

test "close_campaign_editor: the scope swap discards the editor state" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = null,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor != null);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .close_campaign_editor }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(state.Screen.main_menu, history.current_state.screen);
    try testing.expect(history.current_state.campaign_editor == null);

    // Undo restores the editor session (the close is a plain timeline
    // event - the state was captured by the snapshot before it).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.campaign_editor != null);
    try testing.expectEqual(state.Screen.campaign_editor, history.current_state.screen);
}

test "open_campaign_editor: an unreadable campaign dir surfaces the recoverable error" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(null);
    runToIdle(&history);
    const screen_before = history.current_state.screen;

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = "campaigns/does_not_exist",
        } } }},
        history.current_arena.allocator(),
    );
    // Drain manually, stopping on load_error (runToIdle would panic - it
    // asserts no load_error for valid test content; the autosave test's
    // recoverable-read pattern).
    while (history.current_state.event_stack.len > 0) {
        event_handlers.processEvent(&history);
        if (history.load_error) break;
    }

    // The recoverable-read path: the pending error is set, the editor
    // stays unset, the screen never transitioned (the drain reverted).
    try testing.expect(history.session.pending_error != null);
    try testing.expect(history.current_state.campaign_editor == null);
    try testing.expectEqual(screen_before, history.current_state.screen);
}

/// A constructed campaign-editor state (the event-machinery tests' shape -
/// no file dependence): hubs Alpha + Beta, four missions covering the edge
/// classes, on the campaign editor screen.
fn campaignEditorEventFixtureState() state.GameState {
    return .{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Fixture",
            .campaign_dir = "campaigns/fixture",
            .start_hub = 0,
            .hubs = &.{
                .{
                    .handle = 0,
                    .uuid = "a",
                    .name = "Alpha",
                    .position = .{ .x = -200, .y = 0 },
                    .exit_placements = &.{
                        .{ .mission = 2, .position = .{ .x = 1, .y = 1 } },
                        .{ .mission = 5, .position = .{ .x = 2, .y = 2 } },
                    },
                },
                .{ .handle = 1, .uuid = "b", .name = "Beta", .position = .{ .x = 400, .y = 300 } },
            },
            .missions = &.{
                .{ .handle = 2, .uuid = "m1", .name = "One", .start = 0, .destination = 1 },
                .{ .handle = 3, .uuid = "m2", .name = "Loop", .start = 0, .destination = 0 },
                .{ .handle = 4, .uuid = "m3", .name = "Back", .start = 1, .destination = 0 },
                .{ .handle = 5, .uuid = "m4", .name = "Two", .start = 0, .destination = 1 },
            },
            .next_handle = 6,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
}

test "campaign editor events: place/select/move/rename + the tool-switch clear" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);

    // The hub tool: selecting it clears the selection (the editor_set_tool
    // invariant) even though the fixture had none set.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_tool = .{ .tool = .hub } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(types.CampaignEditorToolId.hub, history.current_state.campaign_editor.?.active_tool);

    // Place: the default template - name "New Hub", the single-'!' grid,
    // a fresh handle - and placing SELECTS it.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_place_hub = .{
            .position = .{ .x = 100, .y = 200 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const editor = history.current_state.campaign_editor.?;
    try testing.expectEqual(@as(usize, 3), editor.hubs.len);
    const placed = editor.hubs[2];
    try testing.expectEqual(@as(u32, 6), placed.handle);
    try testing.expectEqualStrings("New Hub", placed.name);
    try testing.expectEqual(@as(i32, 100), placed.position.x);
    try testing.expectEqual(@as(i32, 200), placed.position.y);
    try testing.expectEqual(@as(usize, 1), placed.grid.level_tiles.len);
    try testing.expectEqual(@as(u32, 7), editor.next_handle);
    try testing.expectEqual(@as(?types.CampaignEditorSelection, .{ .hub = 6 }), editor.selection);

    // Rename + move: copy-on-write rebuilds, handle-stable.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_hub_name = .{
            .hub = 6,
            .name = "Crossing",
        } } }},
        history.current_arena.allocator(),
    );
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_hub_position = .{
            .hub = 6,
            .position = .{ .x = 300, .y = -50 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings("Crossing", history.current_state.campaign_editor.?.hubs[2].name);
    try testing.expectEqual(@as(i32, 300), history.current_state.campaign_editor.?.hubs[2].position.x);

    // Switching back to select keeps the selection; a select event
    // retargets it.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_tool = .{ .tool = .select } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(?types.CampaignEditorSelection, .{ .hub = 6 }), history.current_state.campaign_editor.?.selection);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_select_hub = .{ .hub = 1 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(?types.CampaignEditorSelection, .{ .hub = 1 }), history.current_state.campaign_editor.?.selection);
}

test "campaign editor events: delete hub orphans touching missions with frozen ghosts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_select_hub = .{ .hub = 0 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // Delete Alpha: every touching mission orphans with Alpha's position
    // frozen into its dead-end ghost slot; handles stay stable; the
    // selection on the deleted hub clears.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_delete_hub = .{ .hub = 0 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const editor = history.current_state.campaign_editor.?;

    try testing.expectEqual(@as(usize, 1), editor.hubs.len);
    try testing.expectEqual(@as(u32, 1), editor.hubs[0].handle);
    try testing.expectEqual(@as(?types.CampaignEditorSelection, null), editor.selection);

    // m1 (0->1): start-orphaned - ghost start, LIVE destination.
    try testing.expectEqual(@as(?u32, null), editor.missions[0].start);
    try testing.expectEqual(types.Vector2{ .x = -200, .y = 0 }, editor.missions[0].orphan_start_position.?);
    try testing.expectEqual(@as(?u32, 1), editor.missions[0].destination);
    try testing.expect(editor.missions[0].orphan_destination_position == null);

    // m2 (0->0 self-loop): fully orphaned - BOTH ghosts frozen.
    try testing.expectEqual(@as(?u32, null), editor.missions[1].start);
    try testing.expectEqual(@as(?u32, null), editor.missions[1].destination);
    try testing.expectEqual(types.Vector2{ .x = -200, .y = 0 }, editor.missions[1].orphan_start_position.?);
    try testing.expectEqual(types.Vector2{ .x = -200, .y = 0 }, editor.missions[1].orphan_destination_position.?);

    // m3 (1->0): end-orphaned - live start, ghost destination.
    try testing.expectEqual(@as(?u32, 1), editor.missions[2].start);
    try testing.expectEqual(@as(?u32, null), editor.missions[2].destination);
    try testing.expectEqual(types.Vector2{ .x = -200, .y = 0 }, editor.missions[2].orphan_destination_position.?);

    // Handles untouched (deletion-stable references, no remap).
    try testing.expectEqual(@as(u32, 2), editor.missions[0].handle);
    try testing.expectEqual(@as(u32, 5), editor.missions[3].handle);
}

test "campaign editor events: start-hub radio + campaign name + background dims" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);

    // The radio toggle: one write, the previous start is simply replaced.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_start_hub = .{ .hub = 1 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(?u32, 1), history.current_state.campaign_editor.?.start_hub);

    // The campaign rename.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_campaign_name = .{
            .name = "Renamed",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings("Renamed", history.current_state.campaign_editor.?.campaign_name);

    // The background pick: stem stored + dims resolved against the REAL
    // embedded content (the official campaign's map.png - the current art
    // is 994x998).
    var history_two = harness.newHistory(campaignEditorEventFixtureState());
    history_two.current_state.campaign_editor.?.campaign_dir = "campaigns/main_campaign";
    event_push.pushEvents(
        &history_two.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_background = .{
            .stem = "map",
        } } }},
        history_two.current_arena.allocator(),
    );
    runToIdle(&history_two);
    const with_background = history_two.current_state.campaign_editor.?;
    try testing.expectEqualStrings("map", with_background.background_stem);
    try testing.expectEqual(types.Vector2{ .x = 994, .y = 998 }, with_background.background_dims.?);
}

test "campaign editor background picker: open, pick (stem + dims + close in one undo step), undo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);
    // The official campaign's content dir so the real map.png resolves.
    history.current_state.campaign_editor.?.campaign_dir = "campaigns/main_campaign";

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_open_picker = .{
            .picker = .background,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.picker == .background);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_campaign_background = .{
            .stem = "map",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const editor = history.current_state.campaign_editor.?;
    try testing.expectEqualStrings("map", editor.background_stem);
    try testing.expectEqual(types.Vector2{ .x = 994, .y = 998 }, editor.background_dims.?);
    // The pick + close are ONE undo step: undo restores the open picker
    // AND the pre-pick background.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.campaign_editor.?.picker == .background);
    try testing.expectEqual(@as(usize, 0), history.current_state.campaign_editor.?.background_stem.len);

    // The Back button's close.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_close_campaign_picker }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.picker == null);
}

test "campaign editor: exit to main menu via the options menu path, sidebar toggles, defaults" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);

    // The editor's panel defaults mirror the mission editor's: inspector
    // OPEN, metadata CLOSED.
    try testing.expect(history.current_state.campaign_editor.?.inspector_open);
    try testing.expect(!history.current_state.campaign_editor.?.metadata_sidebar_open);

    // The sidebar toggles ride the timeline (the player_toggle_editor_*
    // convention): one event each flips the flag; undo restores.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_toggle_campaign_metadata_sidebar }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.metadata_sidebar_open);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(!history.current_state.campaign_editor.?.metadata_sidebar_open);

    // Exit to Main Menu (the options-menu button): close_campaign_editor
    // owns the teardown + transition - the campaign editor state is
    // discarded, the screen is the main menu.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_exit_to_menu }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(state.Screen.main_menu, history.current_state.screen);
    try testing.expect(history.current_state.campaign_editor == null);
}

test "campaign editor mission events: place (anchor minting), re-attach, delete, import" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);

    // Place a self-loop (the mission tool's same-hub draw): the fresh
    // template (name "New Mission", the anchor dir), wired both ends,
    // selected.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_place_mission = .{
            .start = 0,
            .destination = 0,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    var editor = history.current_state.campaign_editor.?;
    try testing.expectEqual(@as(usize, 5), editor.missions.len);
    const placed = editor.missions[4];
    try testing.expectEqual(@as(u32, 6), placed.handle);
    try testing.expectEqualStrings("New Mission", placed.name);
    try testing.expectEqualStrings("New Mission", placed.dir);
    try testing.expectEqual(@as(?u32, 0), placed.start);
    try testing.expectEqual(@as(?u32, 0), placed.destination);
    try testing.expectEqual(@as(?types.CampaignEditorSelection, .{ .mission = 6 }), editor.selection);

    // A second place mints the NEXT anchor (uniqueness among the entries).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_place_mission = .{
            .start = 0,
            .destination = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    editor = history.current_state.campaign_editor.?;
    try testing.expectEqualStrings("New Mission 2", editor.missions[5].dir);

    // The direction set (the direction field's commit).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_mission_direction = .{
            .mission = 6,
            .direction = 270,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    editor = history.current_state.campaign_editor.?;
    try testing.expectEqual(@as(?u32, 270), editor.missions[4].direction);

    // Re-attach m1's start (0 -> 1): the start moves, its ghost clears,
    // and its exit MARKER drops from the old start hub (the placement
    // removal - the new hub has no marker until placed, slice 4).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_reattach_mission = .{
            .mission = 2,
            .end = .start,
            .hub = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    editor = history.current_state.campaign_editor.?;
    try testing.expectEqual(@as(?u32, 1), editor.missions[0].start);
    try testing.expect(editor.missions[0].orphan_start_position == null);
    try testing.expectEqual(@as(usize, 1), editor.hubs[0].exit_placements.len); // m1's marker gone, m4's stays

    // Delete m4 (its start IS hub 0 - its marker lives there): the entry
    // + its marker in the start hub go together.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_delete_mission = .{
            .mission = 5,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    editor = history.current_state.campaign_editor.?;
    try testing.expectEqual(@as(usize, 0), editor.hubs[0].exit_placements.len);
    var found_m4 = false;
    for (editor.missions) |mission| {
        if (mission.handle == 5) found_m4 = true;
    }
    try testing.expect(!found_m4);

    // An import lands UNWIRED + selected (the author re-attaches it).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_import_mission = .{
            .uuid = "u9",
            .dir = "imported",
            .name = "Imported",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    editor = history.current_state.campaign_editor.?;
    const imported = editor.missions[editor.missions.len - 1];
    try testing.expectEqualStrings("u9", imported.uuid);
    try testing.expectEqualStrings("imported", imported.dir);
    try testing.expect(imported.start == null);
    try testing.expect(imported.destination == null);
    try testing.expectEqual(@as(?types.CampaignEditorSelection, .{ .mission = imported.handle }), editor.selection);
}

test "campaign editor: the mission tool's draw gesture - arm, place, cancel via clean right-click" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    history.current_state.campaign_editor.?.active_tool = .mission;
    runToIdle(&history);

    const input_handlers_mod = @import("input_handlers.zig");

    // The first hub click ARMS (no event recorded).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_hub },
        .{ .editor_campaign_hub = 0 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expect(history.session.ui_state.campaign_mission_draw != null);
    try testing.expectEqual(@as(u32, 0), history.session.ui_state.campaign_mission_draw.?.start_hub);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // The second hub click PLACES (same hub = a self-loop) + clears the
    // draw - the arm drains inline (pushPlayerActionAndDrain), so the
    // state is post-drain here.
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_hub },
        .{ .editor_campaign_hub = 0 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expect(history.session.ui_state.campaign_mission_draw == null);
    const editor = history.current_state.campaign_editor.?;
    try testing.expectEqual(@as(usize, 5), editor.missions.len);
    try testing.expectEqual(@as(?u32, 0), editor.missions[4].start);
    try testing.expectEqual(@as(?u32, 0), editor.missions[4].destination);

    // Re-arm + a clean right-click cancels the draw (no event, no
    // delete): the cancel-mode pending owns the release.
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_hub },
        .{ .editor_campaign_hub = 1 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expect(history.session.ui_state.campaign_mission_draw != null);
    const input_gestures_mod = @import("input_gestures.zig");
    input_gestures_mod.handleCampaignMapRightClick(
        &history,
        .{ .right_pressed = true, .right_held = true, .position = .{ .x = 2032, .y = 1032 } },
        &.{},
    );
    input_gestures_mod.handleCampaignMapRightClick(
        &history,
        .{ .right_released = true, .position = .{ .x = 2032, .y = 1032 } },
        &.{},
    );
    try testing.expect(history.session.ui_state.campaign_mission_draw == null);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    // The right-click was consumed by the CANCEL - hub 1 (Beta) survived.
    try testing.expectEqual(@as(usize, 2), history.current_state.campaign_editor.?.hubs.len);
}

test "saveCampaignEditor: the full round trip - save, reopen, compare; a copy; the deletion reconciliation" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A compact authored graph exercising every projection arm: two hubs
    // (grids + NPCs + decorations + exit markers), a wired mission with
    // an authored direction, a dangling mission, an orphan with ghosts,
    // and a fresh campaign identity (everything mints at save).
    var history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Round Trip",
            .start_hub = 0,
            .hubs = &.{
                .{
                    .handle = 0,
                    .name = "Alpha",
                    .position = .{ .x = -200, .y = 0 },
                    .grid = .{
                        .level_tiles = &.{
                            .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
                            .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 },
                        },
                        .player_start = .{ .x = 0, .y = 0 },
                        .decoration_placements = &.{.{ .type_id = 0, .position = .{ .x = 2, .y = 0 } }},
                    },
                    .npc_placements = &.{.{ .npc_type = .dream_guide, .position = .{ .x = 1, .y = 1 } }},
                    .exit_placements = &.{
                        .{ .mission = 2, .position = .{ .x = 1, .y = 0 } },
                        .{ .mission = 3, .position = .{ .x = 0, .y = 1 } },
                    },
                },
                .{
                    .handle = 1,
                    .name = "Beta",
                    .position = .{ .x = 400, .y = 300 },
                    .grid = .{
                        .level_tiles = &.{.{ .x = 0, .y = 0 }},
                        .player_start = .{ .x = 0, .y = 0 },
                    },
                },
            },
            .missions = &.{
                .{ .handle = 2, .name = "One", .dir = "New Mission", .start = 0, .destination = 1, .direction = 90 },
                .{ .handle = 3, .name = "Beyond", .dir = "New Mission 2", .start = 0 },
                .{ .handle = 4, .name = "Salvage", .dir = "New Mission 3", .destination = 1, .orphan_start_position = .{ .x = -600, .y = -300 } },
            },
            .decoration_types = &.{
                .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
            },
            .next_handle = 5,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    const campaign_editor_io = @import("campaign_editor/io.zig");

    // The in-place save of a FRESH campaign: everything mints.
    campaign_editor_io.saveCampaignEditor(&history, .in_place);
    try testing.expect(history.session.pending_error == null);
    // The memo values are SNAPSHOT into the test's arena: the reopen
    // below clears the memos (freeing their backing strings), and the
    // later assertions must not read freed bytes.
    const campaign_memo_raw = campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?;
    const campaign_memo = types.CampaignSaveMemo{
        .handle = campaign_memo_raw.handle,
        .uuid = backing.allocator().dupe(u8, campaign_memo_raw.uuid) catch unreachable,
        .dir = backing.allocator().dupe(u8, campaign_memo_raw.dir) catch unreachable,
    };
    try testing.expect(campaign_memo.uuid.len > 0);
    try testing.expect(std.mem.startsWith(u8, campaign_memo.dir, "campaigns/"));
    const hub_memo_raw = campaign_editor_io.campaignSaveMemoFor(&history, 0).?;
    const hub_memo = types.CampaignSaveMemo{
        .handle = hub_memo_raw.handle,
        .uuid = backing.allocator().dupe(u8, hub_memo_raw.uuid) catch unreachable,
        .dir = backing.allocator().dupe(u8, hub_memo_raw.dir) catch unreachable,
    };
    try testing.expect(std.mem.startsWith(u8, hub_memo.dir, hub_memo.uuid));
    const mission_memo_raw = campaign_editor_io.campaignSaveMemoFor(&history, 2).?;
    const mission_memo = types.CampaignSaveMemo{
        .handle = mission_memo_raw.handle,
        .uuid = backing.allocator().dupe(u8, mission_memo_raw.uuid) catch unreachable,
        .dir = backing.allocator().dupe(u8, mission_memo_raw.dir) catch unreachable,
    };
    try testing.expect(std.mem.startsWith(u8, mission_memo.dir, mission_memo.uuid));

    // Reopen the saved campaign through the ordinary open path: the
    // inverse projection reconstructs the graph.
    const saved_campaign_dir = history.current_arena.allocator().dupe(u8, campaign_memo.dir) catch unreachable;
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = saved_campaign_dir,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    if (history.session.pending_error) |error_message| {
        std.debug.print("REOPEN ERROR: {s}\n", .{error_message});
    }
    const reloaded = history.current_state.campaign_editor.?;

    try testing.expectEqualStrings("Round Trip", reloaded.campaign_name);
    try testing.expectEqualStrings(campaign_memo.uuid, reloaded.campaign_uuid);
    try testing.expectEqual(@as(usize, 2), reloaded.hubs.len);
    try testing.expectEqualStrings("Alpha", reloaded.hubs[0].name);
    try testing.expectEqualStrings(hub_memo.uuid, reloaded.hubs[0].uuid);
    try testing.expectEqual(types.Vector2{ .x = -200, .y = 0 }, reloaded.hubs[0].position);
    try testing.expectEqual(@as(usize, 1), reloaded.hubs[0].npc_placements.len);
    try testing.expectEqual(@as(usize, 1), reloaded.hubs[0].grid.decoration_placements.len);
    try testing.expectEqual(@as(usize, 2), reloaded.hubs[0].exit_placements.len);
    try testing.expectEqual(@as(usize, 1), reloaded.decoration_types.len);

    try testing.expectEqual(@as(usize, 3), reloaded.missions.len);
    // The wired mission: both ends + the authored direction.
    var one: ?types.CampaignMissionEdit = null;
    var beyond: ?types.CampaignMissionEdit = null;
    var salvage: ?types.CampaignMissionEdit = null;
    for (reloaded.missions) |mission| {
        if (std.mem.eql(u8, mission.name, "One")) one = mission;
        if (std.mem.eql(u8, mission.name, "Beyond")) beyond = mission;
        if (std.mem.eql(u8, mission.name, "Salvage")) salvage = mission;
    }
    try testing.expect(one != null);
    try testing.expectEqualStrings(mission_memo.uuid, one.?.uuid);
    try testing.expect(one.?.start != null and one.?.destination != null);
    try testing.expectEqual(@as(?u32, 90), one.?.direction);
    // The dangling mission: a start, no destination, a marker.
    try testing.expect(beyond != null);
    try testing.expect(beyond.?.start != null and beyond.?.destination == null);
    // The orphan: no start, its ghost frozen + the live destination.
    try testing.expect(salvage != null);
    try testing.expect(salvage.?.start == null);
    try testing.expectEqual(types.Vector2{ .x = -600, .y = -300 }, salvage.?.orphan_start_position.?);
    try testing.expect(salvage.?.destination != null);

    // Save As Copy: a fresh campaign identity, last-wins - the session
    // continues saving the copy (a third in-place save reuses the COPY's
    // memo, not the original's).
    campaign_editor_io.saveCampaignEditor(&history, .as_copy);
    const copy_memo_raw = campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?;
    const copy_memo = types.CampaignSaveMemo{
        .handle = copy_memo_raw.handle,
        .uuid = backing.allocator().dupe(u8, copy_memo_raw.uuid) catch unreachable,
        .dir = backing.allocator().dupe(u8, copy_memo_raw.dir) catch unreachable,
    };
    const copy_campaign_dir = backing.allocator().dupe(u8, copy_memo.dir) catch unreachable;
    try testing.expect(!std.mem.eql(u8, copy_memo.uuid, campaign_memo.uuid));
    try testing.expect(!std.mem.eql(u8, copy_memo.dir, campaign_memo.dir));
    campaign_editor_io.saveCampaignEditor(&history, .in_place);
    try testing.expectEqualStrings(
        copy_memo.dir,
        campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?.dir,
    );

    // The deletion reconciliation: move the start hub to Beta first
    // (the input layer vetoes deleting the start hub - the raw event
    // here would otherwise leave a dangling start_hub the save rejects),
    // then delete Alpha (its dir is memo'd - the state dir is empty),
    // save, and its dir leaves the disk while the missions orphan; an
    // UNDO before the save restores it instead.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_start_hub = .{ .hub = 1 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_delete_hub = .{ .hub = 0 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    // The deleted dir was recorded (the memo's dir - the state's is
    // empty).
    try testing.expect(history.session.campaign_deleted_dirs.len == 1);
    try testing.expectEqualStrings(hub_memo.dir, history.session.campaign_deleted_dirs[0]);
    // UNDO the delete, then save: the restored hub's dir is back in the
    // graph (via its memo) - nothing is deleted from disk.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 2), history.current_state.campaign_editor.?.hubs.len);
    // The raw-pushed events share one idle window - the single undo may
    // have reverted the delete AND the start reassignment. Re-establish
    // the start on Beta (the radio write is idempotent) so the save's
    // start-hub lookup is valid either way.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_start_hub = .{ .hub = 1 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    campaign_editor_io.saveCampaignEditor(&history, .in_place);
    // The reopen still finds Alpha's dir (delete-then-undo-then-save kept
    // it): reopen from the copy dir (the session's current identity).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = copy_campaign_dir,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 2), history.current_state.campaign_editor.?.hubs.len);
    try testing.expectEqualStrings("Alpha", history.current_state.campaign_editor.?.hubs[0].name);

    // And the real deletion: delete Alpha again, save - the dir goes.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_delete_hub = .{ .hub = 0 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const debug_editor = history.current_state.campaign_editor.?;
        std.debug.print("PRE-FINAL-SAVE: start={?d} hubs={d} names:", .{ debug_editor.start_hub, debug_editor.hubs.len });
        for (debug_editor.hubs) |hub| std.debug.print(" {s}({d})", .{ hub.name, hub.handle });
        std.debug.print("\n", .{});
    }
    // The second delete leaves the start on Beta (the reload resolved
    // it); the save + reopen confirm the deletion stuck.
    campaign_editor_io.saveCampaignEditor(&history, .in_place);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = copy_campaign_dir,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.campaign_editor.?.hubs.len);
    try testing.expectEqualStrings("Beta", history.current_state.campaign_editor.?.hubs[0].name);
}

test "saveCampaignEditor: an official-origin campaign forks - fresh identity, whole-dir carry, no shadow" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    const campaign_editor_io = @import("campaign_editor/io.zig");
    const campaign_editor_handlers = @import("campaign_editor/handlers.zig");
    const file_source_mod = @import("file_source.zig");

    // Open the REAL official campaign (embedded content - its files do
    // not exist in the harness's persistent dir, which is what makes it
    // official-origin).
    var history = harness.newHistory(null);
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = "campaigns/main_campaign",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const opened = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
    const official_campaign_uuid = try arena.dupe(u8, opened.campaign_uuid);
    const official_hub_uuid = try arena.dupe(u8, opened.hubs[0].uuid);

    // The save FORKS: a fresh campaign identity + dir, never the official
    // path.
    campaign_editor_io.saveCampaignEditor(&history, .in_place);
    try testing.expect(history.session.pending_error == null);
    const campaign_memo = campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?;
    const fork_dir = try arena.dupe(u8, campaign_memo.dir);
    const fork_uuid = try arena.dupe(u8, campaign_memo.uuid);
    try testing.expect(!std.mem.eql(u8, fork_dir, "campaigns/main_campaign"));
    try testing.expect(!std.mem.eql(u8, fork_uuid, official_campaign_uuid));

    // No shadow: the official campaign's own dir stays embedded-only.
    try testing.expect(!file_source_mod.persistentFileExists(&harness.file_source, "campaigns/main_campaign/campaign.txt"));

    // The campaign-root carry: the background PNG re-created under the
    // fork (a real PNG - the reopen below resolves its dims).
    try testing.expect(file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/map.png", .{fork_dir}),
    ));

    // The hub forked: a fresh uuid + canonical dir, hub.txt under it
    // carrying the minted identity.
    const hub_memo_raw = campaign_editor_io.campaignSaveMemoFor(&history, 0).?;
    // Snapshot into the test arena: the reopen below clears the session
    // memos (freeing their backing strings) - the assertion must not
    // read freed bytes.
    const hub_memo_uuid = try arena.dupe(u8, hub_memo_raw.uuid);
    const hub_memo_dir = try arena.dupe(u8, hub_memo_raw.dir);
    try testing.expect(!std.mem.eql(u8, hub_memo_uuid, official_hub_uuid));
    const fork_hub_txt = try harness.file_source.readFile(
        arena,
        try std.fmt.allocPrint(arena, "{s}/hubs/{s}/hub.txt", .{ fork_dir, hub_memo_dir }),
    );
    {
        const sections = try parser.parseConfigFile(fork_hub_txt, arena, &parser.hub_sections);
        try testing.expectEqualStrings(
            hub_memo_uuid,
            parser.findValue(parser.findSection(sections, "Metadata").?.entry_groups[0].pairs, "hub_uuid") orelse "",
        );
    }

    // Every mission forked with its files carried: fresh uuids (none of
    // the official mission uuids), levels + player.txt re-created under
    // the minted dirs, and the hub's Exits reference the MINTED uuids.
    for (opened.missions, 1..) |official_mission, mission_handle| {
        const mission_memo = campaign_editor_io.campaignSaveMemoFor(&history, @intCast(mission_handle)).?;
        try testing.expect(!std.mem.eql(u8, mission_memo.uuid, official_mission.uuid));
        const mission_dir_path = try std.fmt.allocPrint(
            arena,
            "{s}/missions/{s}",
            .{ fork_dir, mission_memo.dir },
        );
        try testing.expect(file_source_mod.persistentFileExists(
            &harness.file_source,
            try std.fmt.allocPrint(arena, "{s}/level_1.txt", .{mission_dir_path}),
        ));
        try testing.expect(file_source_mod.persistentFileExists(
            &harness.file_source,
            try std.fmt.allocPrint(arena, "{s}/player.txt", .{mission_dir_path}),
        ));
        const mission_txt = try harness.file_source.readFile(
            arena,
            try std.fmt.allocPrint(arena, "{s}/mission.txt", .{mission_dir_path}),
        );
        try testing.expect(std.mem.indexOf(u8, mission_txt, mission_memo.uuid) != null);
        try testing.expect(std.mem.indexOf(u8, fork_hub_txt, mission_memo.uuid) != null);
    }

    // The fork lists as a LOCAL campaign (the official one does not).
    const local_campaigns = try harness.file_source.listCampaigns(arena);
    try testing.expectEqual(@as(usize, 1), local_campaigns.len);
    try testing.expectEqualStrings(fork_dir, local_campaigns[0].dir);
    try testing.expectEqualStrings("Main Campaign", local_campaigns[0].name);
    file_source_mod.freeCampaigns(arena, local_campaigns);

    // The background scan reads the EFFECTIVE dir (the fork): with the
    // current stem cleared, the carried map.png is the only source that
    // can offer "map".
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_campaign_background = .{
            .stem = "",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    campaign_editor_handlers.rescanCampaignBackgroundStems(&history);
    try testing.expectEqual(@as(usize, 1), history.session.campaign_background_stems.len);
    try testing.expectEqualStrings("map", history.session.campaign_background_stems[0]);
    // Restore the background (the None above was only the scan probe) -
    // the reopen asserts its dims resolve against the carried PNG.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_campaign_background = .{
            .stem = "map",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // A second save in the session is stable (the memo - no re-fork).
    campaign_editor_io.saveCampaignEditor(&history, .in_place);
    try testing.expectEqualStrings(fork_dir, campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?.dir);

    // The reopen through the ordinary open path: the fork loads with its
    // minted identity, the full graph, and the carried background's dims.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = fork_dir,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const fork_editor = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(fork_uuid, fork_editor.campaign_uuid);
    try testing.expectEqualStrings(fork_dir, fork_editor.campaign_dir);
    try testing.expectEqual(@as(usize, 1), fork_editor.hubs.len);
    try testing.expectEqual(@as(usize, 4), fork_editor.missions.len);
    try testing.expect(fork_editor.background_dims != null);
    try testing.expectEqualStrings(hub_memo_uuid, fork_editor.hubs[0].uuid);
}

test "campaignImportDir: an official-origin campaign imports into the minted fork dir; a local campaign into its own" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    const campaign_editor_io = @import("campaign_editor/io.zig");

    // The official-origin campaign: the import dir is a freshly minted
    // fork (never the official path), stable across calls (the memo), and
    // the effective dir follows it.
    var history = harness.newHistory(null);
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = "campaigns/main_campaign",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const editor = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
        const import_dir_one = campaign_editor_io.campaignImportDir(&history, arena, editor);
        const import_dir_two = campaign_editor_io.campaignImportDir(&history, arena, editor);
        try testing.expect(!std.mem.eql(u8, import_dir_one, "campaigns/main_campaign"));
        try testing.expectEqualStrings(import_dir_one, import_dir_two);
        try testing.expectEqualStrings(import_dir_one, campaign_editor_io.effectiveCampaignDir(&history, editor));
    }

    // A local campaign: its own dir, nothing minted.
    harness.file_source.writeFile(
        "campaigns/local_test/campaign.txt",
        "Metadata\nfile_format_version 3\ncampaign_uuid 99999999-9999-9999-9999-999999999999\nname Local Test\n",
    ) catch @panic("write local campaign");
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_campaign_editor = .{
            .campaign_dir = "campaigns/local_test",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const editor = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(
            "campaigns/local_test",
            campaign_editor_io.campaignImportDir(&history, arena, editor),
        );
    }
}
