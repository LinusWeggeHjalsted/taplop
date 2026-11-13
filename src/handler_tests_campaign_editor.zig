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
                .{ .handle = 0, .uuid = "a", .name = "Alpha", .position = .{ .x = -200, .y = 0 } },
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
    try testing.expectEqual(@as(?u32, 6), editor.selection);

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
    try testing.expectEqual(@as(?u32, 6), history.current_state.campaign_editor.?.selection);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_select_hub = .{ .hub = 1 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(?u32, 1), history.current_state.campaign_editor.?.selection);
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
    try testing.expectEqual(@as(?u32, null), editor.selection);

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
