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
    const arena = backing.allocator();

    var history = harness.newHistory(null);
    runToIdle(&history);

    // The official campaign dir, DERIVED from the embedded map (the
    // campaign is authored content built in place - the projection test
    // asserts the INVERSE-PROJECTION CONTRACT, never the content).
    const official_campaign_dir = test_harness.officialCampaignDir(arena);
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = official_campaign_dir,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const editor = history.current_state.campaign_editor orelse {
        std.debug.print("campaign editor did not open; pending error: {s}\n", .{history.session.pending_error orelse "(none)"});
        return error.TestUnexpectedResult;
    };

    // The framing: the screen transitioned, the campaign installed, its
    // identity + dir carried from the content.
    try testing.expectEqual(state.Screen.campaign_editor, history.current_state.screen);
    try testing.expect(editor.campaign_name.len > 0);
    try testing.expectEqualStrings(official_campaign_dir, editor.campaign_dir);
    try testing.expect(editor.campaign_uuid.len > 0);

    // The projection contract: at least one placed hub with a resolved
    // start hub; every hub has a uuid, a grid, and a spawn normalized to
    // the origin ('!' -> the origin - loadHub's convention, the
    // bbox-growth-invariant replay invariant; EditorLevel's levels load
    // the same way).
    try testing.expect(editor.hubs.len > 0);
    // The start hub names a placed hub when set (an authored campaign
    // mid-build may legitimately lack one - a validation finding, not a
    // load failure).
    if (editor.start_hub) |start_hub| {
        var start_hub_resolves = false;
        for (editor.hubs) |hub| {
            if (hub.handle == start_hub) start_hub_resolves = true;
        }
        try testing.expect(start_hub_resolves);
    }

    for (editor.hubs) |hub| {
        try testing.expect(hub.uuid.len > 0);
        try testing.expect(hub.grid.level_tiles.len > 0);
        try testing.expectEqual(@as(i32, 0), hub.grid.player_start.x);
        try testing.expectEqual(@as(i32, 0), hub.grid.player_start.y);
        // Exit placements address distinct missions (one marker per
        // mission) + valid mission handles (mission handles sit in the
        // [hubs.len, hubs.len + missions.len) range - the mint order).
        for (hub.grid.exit_placements, 0..) |placement, index| {
            try testing.expect(placement.mission >= editor.hubs.len);
            try testing.expect(
                placement.mission < editor.hubs.len + editor.missions.len,
            );
            for (hub.grid.exit_placements[index + 1 ..]) |other| {
                try testing.expect(placement.mission != other.mission);
            }
        }
        // The dedup contract: at most one decoration type per distinct
        // definition, every placement references a minted type.
        for (hub.grid.decoration_placements) |placement| {
            try testing.expect(placement.type_id < editor.decoration_types.len);
        }
    }

    // Every mission has full identity (uuid + name + dir); wiring is
    // authored state (a mid-build campaign may carry stubs/orphans -
    // validation findings, never load failures), so the contract is only
    // that a set end, when present, names a placed hub.
    try testing.expect(editor.missions.len > 0);
    for (editor.missions) |mission| {
        try testing.expect(mission.uuid.len > 0);
        try testing.expect(mission.name.len > 0);
        try testing.expect(mission.dir.len > 0);
        if (mission.start) |start| try testing.expect(start < editor.hubs.len);
        if (mission.destination) |destination| try testing.expect(destination < editor.hubs.len);
        if (mission.direction) |direction| try testing.expect(direction < 360);
    }

    // Handle mint: every hub + mission consumed a distinct handle
    // (next_handle is exactly past them).
    try testing.expectEqual(
        @as(u32, @intCast(editor.hubs.len + editor.missions.len)),
        editor.next_handle,
    );
}

test "open_campaign_editor: null dir opens the fresh default campaign" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = null,
        } },
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

    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = null,
        } },
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

    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = "campaigns/does_not_exist",
        } },
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
                    .grid = .{
                        .exit_placements = &.{
                            .{ .mission = 2, .position = .{ .x = 1, .y = 1 } },
                            .{ .mission = 5, .position = .{ .x = 2, .y = 2 } },
                        },
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

    // The background pick: stem stored + dims resolved against a PNG the
    // TEST wrote (the shipped art is authored content - a campaign
    // mid-build may carry no background at all, so the dims resolution is
    // exercised against a synthetic PNG with KNOWN dims, never the
    // shipped map).
    var history_two = harness.newHistory(campaignEditorEventFixtureState());
    harness.file_source.writeFile(
        "campaigns/bg_dims_fixture/map.png",
        &test_harness.pngHeaderBytes(640, 480),
    ) catch @panic("write fixture map.png");
    history_two.current_state.campaign_editor.?.campaign_dir = "campaigns/bg_dims_fixture";
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
    try testing.expectEqual(types.Vector2{ .x = 640, .y = 480 }, with_background.background_dims.?);
}

test "campaign editor background picker: open, pick (stem + dims + close in one undo step), undo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);
    // A fixture campaign dir with a synthetic PNG (known dims - the
    // shipped art is authored content, never pinned; a mid-build
    // campaign may carry no background at all).
    harness.file_source.writeFile(
        "campaigns/bg_pick_fixture/map.png",
        &test_harness.pngHeaderBytes(640, 480),
    ) catch @panic("write fixture map.png");
    history.current_state.campaign_editor.?.campaign_dir = "campaigns/bg_pick_fixture";

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_open_picker = .{
            .picker = .background,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.picker == .background);

    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_set_campaign_background = .{
            .stem = "map",
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const editor = history.current_state.campaign_editor.?;
    try testing.expectEqualStrings("map", editor.background_stem);
    try testing.expectEqual(types.Vector2{ .x = 640, .y = 480 }, editor.background_dims.?);
    // The pick + close are ONE undo step: undo restores the open picker
    // AND the pre-pick background.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.campaign_editor.?.picker == .background);
    try testing.expectEqual(@as(usize, 0), history.current_state.campaign_editor.?.background_stem.len);

    // The Back button's close.
    event_push.pushPlayerAction(
        &history.current_state,
        .player_close_campaign_picker,
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
    event_push.pushPlayerAction(
        &history.current_state,
        .player_toggle_campaign_metadata_sidebar,
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.metadata_sidebar_open);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(!history.current_state.campaign_editor.?.metadata_sidebar_open);

    // Exit to Main Menu (the options-menu button): close_campaign_editor
    // owns the teardown + transition - the campaign editor state is
    // discarded, the screen is the main menu.
    event_push.pushPlayerAction(
        &history.current_state,
        .player_exit_to_menu,
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
    try testing.expectEqual(@as(usize, 1), editor.hubs[0].grid.exit_placements.len); // m1's marker gone, m4's stays

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
    try testing.expectEqual(@as(usize, 0), editor.hubs[0].grid.exit_placements.len);
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

test "campaign editor: right-click on a mission edge deletes the mission (the edge + its marker)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);

    const input_gestures_mod = @import("input_gestures.zig");
    const ui = @import("ui.zig");

    // The mission-edge button under the pointer: the same element the map
    // view emits (a spriteless button carrying the mission handle).
    const buttons = [_]ui.UiElement{.{ .button = .{
        .screen_position = .{ .x = 2000, .y = 1000 },
        .width = 100,
        .height = 100,
        .action = .select_editor_campaign_mission,
        .payload = .{ .editor_campaign_mission = 2 },
    } }};

    // The press records the mission (a clean click acts on what was under
    // the pointer when the button went down).
    input_gestures_mod.handleCampaignMapRightClick(
        &history,
        .{ .right_pressed = true, .right_held = true, .position = .{ .x = 2050, .y = 1050 } },
        &buttons,
    );
    // The clean release deletes: the mission entry + its exit marker in
    // its start hub go together (the mission IS the edge).
    input_gestures_mod.handleCampaignMapRightClick(
        &history,
        .{ .right_released = true, .position = .{ .x = 2050, .y = 1050 } },
        &buttons,
    );
    runToIdle(&history);

    const editor = history.current_state.campaign_editor.?;
    try testing.expectEqual(@as(usize, 3), editor.missions.len);
    for (editor.missions) |mission| {
        try testing.expect(mission.handle != 2);
    }
    // The deleted mission's marker left Alpha with it; the surviving
    // marker for mission 5 stays.
    try testing.expectEqual(@as(usize, 1), editor.hubs[0].grid.exit_placements.len);
    try testing.expectEqual(@as(u32, 5), editor.hubs[0].grid.exit_placements[0].mission);
    // The deletion is a recorded player action - undo restores the edge
    // and its marker.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 4), history.current_state.campaign_editor.?.missions.len);
    try testing.expectEqual(@as(usize, 2), history.current_state.campaign_editor.?.hubs[0].grid.exit_placements.len);
}

test "campaign editor: the inspector panel owns the wheel" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);

    const input_handlers_mod = @import("input_handlers.zig");
    const ui = @import("ui.zig");

    // Inside the open panel (open by default): one wheel-down notch =
    // one row down; wheel-up at the top clamps at 0 (the mission editor's
    // exact model - the shared panel rect, the shared scroll state).
    const inside: types.ScreenPosition = .{
        .x = 512,
        .y = ui.editorInspectorPanelRect().y + 100,
    };
    input_handlers_mod.handleAnytimeInput(&history, .{ .scroll_delta = -1 }, null, inside, &.{});
    try testing.expectEqual(@as(i32, 1), history.session.ui_state.editor_inspector_scroll);
    input_handlers_mod.handleAnytimeInput(&history, .{ .scroll_delta = 1 }, null, inside, &.{});
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_inspector_scroll);

    // Outside the panel (top-right, over no UI): the offset is untouched.
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .scroll_delta = -1 },
        null,
        .{ .x = 2000, .y = 300 },
        &.{},
    );
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_inspector_scroll);

    // Panel closed: the routing falls through even inside the rect.
    history.current_state.campaign_editor.?.inspector_open = false;
    input_handlers_mod.handleAnytimeInput(&history, .{ .scroll_delta = -1 }, null, inside, &.{});
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_inspector_scroll);
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

test "campaign editor: a mission edge click selects under ANY tool; an armed draw cancels on it" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);

    const input_handlers_mod = @import("input_handlers.zig");

    // A HUB-TOOL click on an edge selects it (the click-on-a-hub rule,
    // extended to edges: placement never fires on an existing thing).
    history.current_state.campaign_editor.?.active_tool = .hub;
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_mission },
        .{ .editor_campaign_mission = 2 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expectEqual(
        @as(?types.CampaignEditorSelection, .{ .mission = 2 }),
        history.current_state.campaign_editor.?.selection,
    );

    // The no-op gate: re-selecting the selected mission records nothing
    // (past the double-click window - a same-clock repeat would drill in).
    history.session.session_clock = 1_000_000;
    const log_length = history.event_history.items.len;
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_mission },
        .{ .editor_campaign_mission = 2 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expectEqual(log_length, history.event_history.items.len);

    // The mission tool UNARMED: an edge click selects too (any tool).
    history.current_state.campaign_editor.?.active_tool = .mission;
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_mission },
        .{ .editor_campaign_mission = 5 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expectEqual(
        @as(?types.CampaignEditorSelection, .{ .mission = 5 }),
        history.current_state.campaign_editor.?.selection,
    );

    // The ARMED draw is the one exception: the draw owns the map, and an
    // edge click cancels it - never a select (the empty-canvas rule).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_hub },
        .{ .editor_campaign_hub = 0 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expect(history.session.ui_state.campaign_mission_draw != null);
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_mission },
        .{ .editor_campaign_mission = 2 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expect(history.session.ui_state.campaign_mission_draw == null);
    try testing.expectEqual(
        @as(?types.CampaignEditorSelection, .{ .mission = 5 }),
        history.current_state.campaign_editor.?.selection,
    );
}

test "campaign editor: a double-click on a hub or mission drills into its editor" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);
    const input_handlers_mod = @import("input_handlers.zig");

    // Click 1 (select tool): selects the hub + seeds the pending double.
    history.current_state.campaign_editor.?.active_tool = .select;
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_hub },
        .{ .editor_campaign_hub = 0 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expectEqual(
        @as(?types.CampaignEditorSelection, .{ .hub = 0 }),
        history.current_state.campaign_editor.?.selection,
    );
    try testing.expect(history.session.ui_state.last_campaign_click != null);

    // A SLOW second click (past the threshold window): the re-select
    // no-ops, no drill-in - the click only re-seeds the pending.
    history.session.session_clock = 1_000_000;
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_hub },
        .{ .editor_campaign_hub = 0 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expectEqual(state.Screen.campaign_editor, history.current_state.screen);

    // A FAST second click (within the window): drills into the hub
    // editor - the recorded orchestrator, the inspector button's own.
    history.session.session_clock = 1_100_000;
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_hub },
        .{ .editor_campaign_hub = 0 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expectEqual(state.Screen.hub_editor, history.current_state.screen);
    try testing.expectEqual(@as(u32, 0), history.current_state.hub_editor.?.hub);
    try testing.expect(history.current_state.campaign_editor != null);
    try testing.expect(history.session.ui_state.last_campaign_click == null);

    // Undo returns to the map (the drill-in is a recorded action).
    runToIdle(&history);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(state.Screen.campaign_editor, history.current_state.screen);

    // The mission twin: a click-click on a never-saved mission (the
    // fresh-template hand-off branch) drills into the mission editor.
    var fresh_history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Local",
            .campaign_uuid = "cu",
            .campaign_dir = "campaigns/local",
            .start_hub = 0,
            .hubs = &.{.{
                .handle = 0,
                .name = "Alpha",
                .position = .{ .x = 0, .y = 0 },
                .grid = .{
                    .level_tiles = &.{.{ .x = 0, .y = 0 }},
                    .player_start = .{ .x = 0, .y = 0 },
                },
            }},
            .missions = &.{.{ .handle = 3, .dir = "New Mission", .name = "Renamed On Map", .start = 0, .destination = 0 }},
            .next_handle = 4,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&fresh_history);
    input_handlers_mod.handleAnytimeInput(
        &fresh_history,
        .{ .options_action = .select_editor_campaign_mission },
        .{ .editor_campaign_mission = 3 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expectEqual(
        @as(?types.CampaignEditorSelection, .{ .mission = 3 }),
        fresh_history.current_state.campaign_editor.?.selection,
    );
    fresh_history.session.session_clock = 100_000;
    input_handlers_mod.handleAnytimeInput(
        &fresh_history,
        .{ .options_action = .select_editor_campaign_mission },
        .{ .editor_campaign_mission = 3 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expectEqual(state.Screen.editor, fresh_history.current_state.screen);
    try testing.expectEqual(@as(u32, 3), fresh_history.current_state.editor.?.campaign_mission.?);
    try testing.expect(fresh_history.current_state.campaign_editor != null);
    try testing.expect(fresh_history.session.ui_state.last_campaign_click == null);
}

test "hub editor: an inferred inspector target commits to the inferred type" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const input_handlers_mod = @import("input_handlers.zig");

    // The SELECT tool with a single decoration placement selected: the
    // keep-colors toggle commits to the INFERRED type (the placement's
    // type 1), not any active tool.
    {
        const selection = [_]types.Selectable{.{ .decoration_placement = 0 }};
        var history = harness.newHistory(.{
            .screen = .hub_editor,
            .event_stack = &.{},
            .player_data = .{},
            .camera = null,
            .editor = null,
            .campaign_editor = .{
                .campaign_name = "Local",
                .campaign_uuid = "cu",
                .campaign_dir = "campaigns/local",
                .start_hub = 0,
                .hubs = &.{.{ .handle = 0, .name = "Alpha", .position = .{ .x = 0, .y = 0 }, .grid = .{
                    .decoration_placements = &.{.{ .type_id = 1, .position = .{ .x = 0, .y = 0 } }},
                } }},
                .decoration_types = &.{
                    .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
                    .{ .id = "rock", .sprite = "rock_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
                },
                .next_handle = 1,
            },
            .hub_editor = .{
                .hub = 0,
                .active_tool = .select,
                .selection = &selection,
            },
            .replay_viewer = null,
            .campaign = null,
            .mission = null,
            .level = null,
            .hub = null,
        });
        runToIdle(&history);
        input_handlers_mod.handleAnytimeInput(
            &history,
            .{ .options_action = .toggle_editor_decoration_keep_original_colors },
            null,
            .{ .x = 512, .y = 624 },
            &.{},
        );
        try testing.expect(history.current_state.campaign_editor.?.decoration_types[1].keep_original_colors);
        try testing.expect(!history.current_state.campaign_editor.?.decoration_types[0].keep_original_colors);
    }

    // An AMBIGUOUS selection (two placements of different types): no
    // inferred target - the commit no-ops.
    {
        const ambiguous = [_]types.Selectable{ .{ .decoration_placement = 0 }, .{ .decoration_placement = 1 } };
        var history = harness.newHistory(.{
            .screen = .hub_editor,
            .event_stack = &.{},
            .player_data = .{},
            .camera = null,
            .editor = null,
            .campaign_editor = .{
                .campaign_name = "Local",
                .campaign_uuid = "cu",
                .campaign_dir = "campaigns/local",
                .start_hub = 0,
                .hubs = &.{.{ .handle = 0, .name = "Alpha", .position = .{ .x = 0, .y = 0 }, .grid = .{
                    .decoration_placements = &.{
                        .{ .type_id = 1, .position = .{ .x = 0, .y = 0 } },
                        .{ .type_id = 0, .position = .{ .x = 1, .y = 0 } },
                    },
                } }},
                .decoration_types = &.{
                    .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
                    .{ .id = "rock", .sprite = "rock_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
                },
                .next_handle = 1,
            },
            .hub_editor = .{
                .hub = 0,
                .active_tool = .select,
                .selection = &ambiguous,
            },
            .replay_viewer = null,
            .campaign = null,
            .mission = null,
            .level = null,
            .hub = null,
        });
        runToIdle(&history);
        input_handlers_mod.handleAnytimeInput(
            &history,
            .{ .options_action = .toggle_editor_decoration_keep_original_colors },
            null,
            .{ .x = 512, .y = 624 },
            &.{},
        );
        try testing.expect(!history.current_state.campaign_editor.?.decoration_types[0].keep_original_colors);
        try testing.expect(!history.current_state.campaign_editor.?.decoration_types[1].keep_original_colors);
    }
}

test "saveCampaignEditor: the full round trip - save, reopen, compare; the deletion reconciliation" {
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
                        .npc_placements = &.{.{ .npc_type = .dream_guide, .position = .{ .x = 1, .y = 1 } }},
                        .exit_placements = &.{
                            .{ .mission = 2, .position = .{ .x = 1, .y = 0 } },
                            .{ .mission = 3, .position = .{ .x = 0, .y = 1 } },
                        },
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
    _ = campaign_editor_io.saveCampaignEditor(&history);
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
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = saved_campaign_dir,
        } },
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
    try testing.expectEqual(@as(usize, 1), reloaded.hubs[0].grid.npc_placements.len);
    try testing.expectEqual(@as(usize, 1), reloaded.hubs[0].grid.decoration_placements.len);
    try testing.expectEqual(@as(usize, 2), reloaded.hubs[0].grid.exit_placements.len);
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

    // The reopen dir for the deletion assertions below (the first save's
    // dir, backing-owned - the reopens span current-arena frames).
    const reopen_dir = backing.allocator().dupe(u8, campaign_memo.dir) catch unreachable;
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
    _ = campaign_editor_io.saveCampaignEditor(&history);
    // The reopen still finds Alpha's dir (delete-then-undo-then-save kept
    // it).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = reopen_dir,
        } },
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
    // The second delete leaves the start on Beta (the reload resolved
    // it); the save + reopen confirm the deletion stuck.
    _ = campaign_editor_io.saveCampaignEditor(&history);
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = reopen_dir,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.campaign_editor.?.hubs.len);
    try testing.expectEqualStrings("Beta", history.current_state.campaign_editor.?.hubs[0].name);
}

test "validateSavedCampaign: the file-level findings popup + the clean success" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const session_log = @import("session_log.zig");
    const content_hash = @import("content_hash.zig");
    const campaign_editor_io = @import("campaign_editor/io.zig");

    // A campaign with every finding class: a fully wired + marked
    // self-loop (clean), a marked STUB (start, no destination), and an
    // ORPHAN (no start). No mission has a validation replay yet.
    var history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Validate Me",
            .start_hub = 0,
            .hubs = &.{
                .{
                    .handle = 0,
                    .name = "Alpha",
                    .position = .{ .x = 0, .y = 0 },
                    .grid = .{
                        .level_tiles = &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } },
                        .player_start = .{ .x = 0, .y = 0 },
                        .exit_placements = &.{
                            .{ .mission = 2, .position = .{ .x = 1, .y = 0 } },
                            .{ .mission = 3, .position = .{ .x = 2, .y = 0 } },
                        },
                    },
                },
            },
            .missions = &.{
                .{ .handle = 2, .name = "One", .dir = "New Mission", .start = 0, .destination = 0 },
                .{ .handle = 3, .name = "Stub", .dir = "New Mission 2", .start = 0 },
                .{ .handle = 4, .name = "Orphan", .dir = "New Mission 3" },
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

    // Save first (the Validate contract) - the returned dir is the
    // certification target.
    const saved_dir = campaign_editor_io.saveCampaignEditor(&history) orelse
        return error.TestUnexpectedResult;
    try testing.expect(history.session.pending_error == null);

    // Phase 1 - the findings: the stub, the orphan, and every declared
    // mission unvalidated (no replay on disk). The wired self-loop is
    // clean (marked + destined + reachable).
    campaign_editor_io.validateSavedCampaign(&history, saved_dir);
    const findings = history.session.pending_error orelse
        return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, findings, "no destination hub set (a dangling stub") != null);
    // The orphan warning names the mission by UUID (the derive reads
    // campaign.txt only - names live in the mission table); the replay
    // findings below use the resolved names.
    try testing.expect(std.mem.indexOf(u8, findings, "has no start hub - it is not wired into the graph (an orphan)") != null);
    try testing.expect(std.mem.indexOf(u8, findings, "mission 'One': no validation replay") != null);
    try testing.expect(std.mem.indexOf(u8, findings, "mission 'Stub': no validation replay") != null);
    try testing.expect(std.mem.indexOf(u8, findings, "mission 'Orphan': no validation replay") != null);
    try testing.expect(std.mem.indexOf(u8, findings, "unstartable") == null);

    // Phase 2 - the replays resolve: writing each mission's validation
    // replay (its minted uuid + the CURRENT content hash - the exact
    // artifact writeValidationReplay produces) removes the unvalidated
    // findings; the GRAPH findings (the stub, the orphan) remain - they
    // are wiring defects, not replay defects. The full clean-success
    // case is phase 3.
    history.session.pending_error = null;
    for ([_]u32{ 2, 3, 4 }) |handle| {
        const memo = campaign_editor_io.campaignSaveMemoFor(&history, handle) orelse
            return error.TestUnexpectedResult;
        const mission_path = std.fmt.allocPrint(backing.allocator(), "{s}/missions/{s}", .{ saved_dir, memo.dir }) catch
            return error.TestUnexpectedResult;
        const hash = try content_hash.computeMissionHash(history.file_source, backing.allocator(), mission_path);
        const hash_hex = content_hash.hashToHex(hash);
        const replay_events = [_]events.Event{
            .{ .player_input_event = .{ .player_start_validation = .{ .mission_path = "" } } },
            .{ .meta_event = .{ .end_validation = .{ .success = true } } },
        };
        const replay_body = try session_log.writeEventLogWithMetadata(
            replay_events[0..],
            "20260101_000000",
            &.{
                .{ .name = "mission_uuid", .value = memo.uuid },
                .{ .name = "content_hash", .value = &hash_hex },
            },
            backing.allocator(),
        );
        const replay_path = std.fmt.allocPrint(backing.allocator(), "{s}/validation_replay.txt", .{mission_path}) catch
            return error.TestUnexpectedResult;
        history.file_source.writeFile(replay_path, replay_body) catch
            return error.TestUnexpectedResult;
    }
    campaign_editor_io.validateSavedCampaign(&history, saved_dir);
    const replays_resolved = history.session.pending_error orelse
        return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, replays_resolved, "no validation replay") == null);
    try testing.expect(std.mem.indexOf(u8, replays_resolved, "no destination hub set") != null);

    // Phase 3 - the clean success: a second campaign, fully wired +
    // marked, its single mission's replay written after save.
    var clean_history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Clean",
            .start_hub = 0,
            .hubs = &.{
                .{
                    .handle = 0,
                    .name = "Alpha",
                    .position = .{ .x = 0, .y = 0 },
                    .grid = .{
                        .level_tiles = &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } },
                        .player_start = .{ .x = 0, .y = 0 },
                        .exit_placements = &.{
                            .{ .mission = 1, .position = .{ .x = 1, .y = 0 } },
                        },
                    },
                },
            },
            .missions = &.{
                .{ .handle = 1, .name = "One", .dir = "New Mission", .start = 0, .destination = 0 },
            },
            .next_handle = 2,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&clean_history);
    const clean_dir = campaign_editor_io.saveCampaignEditor(&clean_history) orelse
        return error.TestUnexpectedResult;
    const clean_memo = campaign_editor_io.campaignSaveMemoFor(&clean_history, 1) orelse
        return error.TestUnexpectedResult;
    const clean_mission_path = std.fmt.allocPrint(backing.allocator(), "{s}/missions/{s}", .{ clean_dir, clean_memo.dir }) catch
        return error.TestUnexpectedResult;
    const clean_hash = try content_hash.computeMissionHash(clean_history.file_source, backing.allocator(), clean_mission_path);
    const clean_hash_hex = content_hash.hashToHex(clean_hash);
    const clean_events = [_]events.Event{
        .{ .player_input_event = .{ .player_start_validation = .{ .mission_path = "" } } },
        .{ .meta_event = .{ .end_validation = .{ .success = true } } },
    };
    const clean_replay = try session_log.writeEventLogWithMetadata(
        clean_events[0..],
        "20260101_000000",
        &.{
            .{ .name = "mission_uuid", .value = clean_memo.uuid },
            .{ .name = "content_hash", .value = &clean_hash_hex },
        },
        backing.allocator(),
    );
    const clean_replay_path = std.fmt.allocPrint(backing.allocator(), "{s}/validation_replay.txt", .{clean_mission_path}) catch
        return error.TestUnexpectedResult;
    clean_history.file_source.writeFile(clean_replay_path, clean_replay) catch
        return error.TestUnexpectedResult;

    campaign_editor_io.validateSavedCampaign(&clean_history, clean_dir);
    try testing.expectEqualStrings("Campaign validated - no findings.", clean_history.session.pending_error orelse
        return error.TestUnexpectedResult);
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
    // official-origin). The dir is DERIVED from the embedded map (authored
    // content - never pinned).
    const official_campaign_dir = test_harness.officialCampaignDir(arena);
    var history = harness.newHistory(null);
    runToIdle(&history);
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = official_campaign_dir,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const opened = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
    const official_campaign_uuid = try arena.dupe(u8, opened.campaign_uuid);
    const official_hub_uuid = try arena.dupe(u8, opened.hubs[0].uuid);

    // The save FORKS: a fresh campaign identity + dir, never the official
    // path.
    _ = campaign_editor_io.saveCampaignEditor(&history);
    try testing.expect(history.session.pending_error == null);
    const campaign_memo = campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?;
    const fork_dir = try arena.dupe(u8, campaign_memo.dir);
    const fork_uuid = try arena.dupe(u8, campaign_memo.uuid);
    try testing.expect(!std.mem.eql(u8, fork_dir, official_campaign_dir));
    try testing.expect(!std.mem.eql(u8, fork_uuid, official_campaign_uuid));

    // No shadow: the official campaign's own dir stays embedded-only.
    try testing.expect(!file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/campaign.txt", .{official_campaign_dir}),
    ));

    // The campaign-root carry, DERIVED: every ROOT FILE of the opened dir
    // (the embedded map's file set - campaign.txt, background PNGs when
    // the campaign ships them) is re-created under the fork.
    const opened_root_files = try harness.file_source.listDirFiles(arena, official_campaign_dir);
    defer file_source_mod.freeDirFiles(arena, opened_root_files);
    try testing.expect(opened_root_files.len > 0);
    for (opened_root_files) |file_name| {
        try testing.expect(file_source_mod.persistentFileExists(
            &harness.file_source,
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ fork_dir, file_name }),
        ));
    }

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
    // Memo lookups ride the mission's own HANDLE (the mint order is
    // hubs-then-missions - never a hand-counted index).
    for (opened.missions) |official_mission| {
        const mission_memo = campaign_editor_io.campaignSaveMemoFor(&history, official_mission.handle).?;
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
    }
    // The forked hub.txt references the MINTED uuids of exactly the
    // missions whose exit markers live in that hub (derived from the
    // hub's own grid - only its own exits can appear in its file).
    for (opened.hubs[0].grid.exit_placements) |placement| {
        const mission_memo = campaign_editor_io.campaignSaveMemoFor(&history, placement.mission).?;
        try testing.expect(std.mem.indexOf(u8, fork_hub_txt, mission_memo.uuid) != null);
    }

    // The fork lists as a LOCAL campaign (the official one does not),
    // carrying the opened campaign's name (derived - the rename-free
    // fork keeps the authored name).
    const local_campaigns = try harness.file_source.listCampaigns(arena);
    try testing.expectEqual(@as(usize, 1), local_campaigns.len);
    try testing.expectEqualStrings(fork_dir, local_campaigns[0].dir);
    try testing.expectEqualStrings(opened.campaign_name, local_campaigns[0].name);
    file_source_mod.freeCampaigns(arena, local_campaigns);

    // The background scan reads the EFFECTIVE dir (the fork): a PNG
    // written into the fork (the hand-installed / carried-art shape) is
    // offered with the current stem cleared (the None-independence
    // property - the old scan hid non-stem PNGs).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_set_campaign_background = .{
            .stem = "",
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    harness.file_source.writeFile(
        try std.fmt.allocPrint(arena, "{s}/probe.png", .{fork_dir}),
        &test_harness.pngHeaderBytes(128, 128),
    ) catch @panic("write fork probe.png");
    campaign_editor_handlers.rescanCampaignBackgroundStems(&history);
    var probe_offered = false;
    for (history.session.campaign_background_stems) |stem| {
        if (std.mem.eql(u8, stem, "probe")) probe_offered = true;
    }
    try testing.expect(probe_offered);

    // A second save in the session is stable (the memo - no re-fork).
    _ = campaign_editor_io.saveCampaignEditor(&history);
    try testing.expectEqualStrings(fork_dir, campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?.dir);

    // The reopen through the ordinary open path: the fork loads with its
    // minted identity + the full graph (hub/mission counts derived from
    // the opened campaign).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = fork_dir,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const fork_editor = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(fork_uuid, fork_editor.campaign_uuid);
    try testing.expectEqualStrings(fork_dir, fork_editor.campaign_dir);
    try testing.expectEqual(opened.hubs.len, fork_editor.hubs.len);
    try testing.expectEqual(opened.missions.len, fork_editor.missions.len);
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
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = test_harness.officialCampaignDir(arena),
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const editor = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
        const import_dir_one = campaign_editor_io.campaignImportDir(&history, arena, editor);
        const import_dir_two = campaign_editor_io.campaignImportDir(&history, arena, editor);
        try testing.expect(!std.mem.eql(u8, import_dir_one, editor.campaign_dir));
        try testing.expectEqualStrings(import_dir_one, import_dir_two);
        try testing.expectEqualStrings(import_dir_one, campaign_editor_io.effectiveCampaignDir(&history, editor));
    }

    // A local campaign: its own dir, nothing minted.
    harness.file_source.writeFile(
        "campaigns/local_test/campaign.txt",
        "Metadata\nfile_format_version 5\ncampaign_uuid 99999999-9999-9999-9999-999999999999\nname Local Test\n",
    ) catch @panic("write local campaign");
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = "campaigns/local_test",
        } },
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

test "campaign editor pickers: an open picker switches to the requested kind; same-kind no-ops" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);
    // A real campaign dir (derived) so the background rescan has a dir; the
    // local-mission rescan reads the harness's empty persistent missions/.
    history.current_state.campaign_editor.?.campaign_dir = test_harness.officialCampaignDir(backing.allocator());

    const input_handlers_mod = @import("input_handlers.zig");

    // Open the background picker (the metadata sidebar's button).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .open_campaign_background_picker },
        null,
        .{ .x = 0, .y = 0 },
        &.{},
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.picker == .background);
    const index_after_open = history.current_event_index;

    // Re-firing the SAME kind: the no-op gate (no dead undo step).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .open_campaign_background_picker },
        null,
        .{ .x = 0, .y = 0 },
        &.{},
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.picker == .background);
    try testing.expectEqual(index_after_open, history.current_event_index);

    // Firing the OTHER kind (the mission inspector's Import button, with
    // the background picker still up): SWITCHES - a recorded event chain
    // (the orchestrator + its child), so the index strictly moves.
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .open_campaign_import_picker },
        null,
        .{ .x = 0, .y = 0 },
        &.{},
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.picker == .import_mission);
    try testing.expect(index_after_open < history.current_event_index);

    // And back again.
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .open_campaign_background_picker },
        null,
        .{ .x = 0, .y = 0 },
        &.{},
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.picker == .background);
}

test "campaign editor background scan: the campaign dir's PNGs are offered whatever the current stem" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const campaign_editor_handlers = @import("campaign_editor/handlers.zig");

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);
    // A fixture campaign dir with PNGs (the scan's subject): background
    // set to None (the fixture's empty stem), so the PNGs must still be
    // offered (the old scan offered them only through the current-stem
    // append, so choosing None hid them). The shipped art is authored
    // content - the scan mechanics run against synthetic PNGs with known
    // stems, never the shipped map.
    history.current_state.campaign_editor.?.campaign_dir = "campaigns/bg_scan_fixture";
    harness.file_source.writeFile(
        "campaigns/bg_scan_fixture/map.png",
        &test_harness.pngHeaderBytes(640, 480),
    ) catch @panic("write fixture map.png");
    harness.file_source.writeFile(
        "campaigns/bg_scan_fixture/banner.png",
        &test_harness.pngHeaderBytes(256, 256),
    ) catch @panic("write fixture banner.png");

    campaign_editor_handlers.rescanCampaignBackgroundStems(&history);
    try testing.expectEqual(@as(usize, 2), history.session.campaign_background_stems.len);
    for (history.session.campaign_background_stems) |stem| {
        try testing.expect(
            std.mem.eql(u8, stem, "map") or std.mem.eql(u8, stem, "banner"),
        );
    }

    // A later PNG in the same dir appears on rescan (the fork/hand-
    // installed shape - one row per distinct stem).
    harness.file_source.writeFile(
        "campaigns/bg_scan_fixture/extra.png",
        &test_harness.pngHeaderBytes(128, 128),
    ) catch @panic("write fixture extra.png");
    campaign_editor_handlers.rescanCampaignBackgroundStems(&history);
    try testing.expectEqual(@as(usize, 3), history.session.campaign_background_stems.len);
}

test "campaign editor: the tool keybind path - the bridged click switches the active tool, undo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);

    const input_handlers_mod = @import("input_handlers.zig");

    // Digit2's bridged pair - exactly what translateInput produces for
    // the campaign_hub_tool keybind (the click arm serves keybind and
    // cell click through the same options_action + payload).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_campaign_tool },
        .{ .editor_campaign_tool = .hub },
        .{ .x = 0, .y = 0 },
        &.{},
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.active_tool == .hub);

    // The switch rides the undo timeline (the tool cell's click
    // convention).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.campaign_editor.?.active_tool == .select);
}

test "campaign editor: the Tab chords cycle the three map tools, undo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(campaignEditorEventFixtureState());
    runToIdle(&history);

    const input_handlers_mod = @import("input_handlers.zig");

    // Forward: select -> hub -> mission -> select (wraps).
    input_handlers_mod.handleAnytimeInput(&history, .{ .cycle_editor_tool_forward = true }, null, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.active_tool == .hub);
    input_handlers_mod.handleAnytimeInput(&history, .{ .cycle_editor_tool_forward = true }, null, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.active_tool == .mission);
    input_handlers_mod.handleAnytimeInput(&history, .{ .cycle_editor_tool_forward = true }, null, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.active_tool == .select);

    // Backward: select -> mission (wraps) -> hub.
    input_handlers_mod.handleAnytimeInput(&history, .{ .cycle_editor_tool_backward = true }, null, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.active_tool == .mission);
    input_handlers_mod.handleAnytimeInput(&history, .{ .cycle_editor_tool_backward = true }, null, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.active_tool == .hub);

    // Each switch rides the undo timeline.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.campaign_editor.?.active_tool == .mission);
}

test "hub editor framing: open drills in, close returns, the scope rule owns the state" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A campaign with one placed hub carrying a real grid (two tiles +
    // the spawn + an NPC + an exit marker + a decoration), so the
    // drill-in has content to snapshot against.
    var history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Drill",
            .start_hub = 0,
            .hubs = &.{.{
                .handle = 0,
                .name = "Alpha",
                .position = .{ .x = 0, .y = 0 },
                .grid = .{
                    .level_tiles = &.{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 2 } },
                    .player_start = .{ .x = 0, .y = 0 },
                    .decoration_placements = &.{.{ .type_id = 0, .position = .{ .x = 3, .y = 2 } }},
                    .npc_placements = &.{.{ .npc_type = .dream_guide, .position = .{ .x = 3, .y = 2 } }},
                    .exit_placements = &.{.{ .mission = 5, .position = .{ .x = 0, .y = 0 } }},
                },
            }},
            .missions = &.{.{ .handle = 5, .name = "One", .start = 0, .destination = 0 }},
            .decoration_types = &.{
                .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
            },
            .next_handle = 6,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // The open orchestrator (the hub inspector's button): drills in. The
    // clamp snapshot covers the grid's tiles (0,0 .. 3,2); the campaign
    // graph SURVIVES (the .hub_editor scope carries campaign_editor -
    // edits write through into it by handle).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_hub_editor = .{
            .hub = 0,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(state.Screen.hub_editor, history.current_state.screen);
    const hub_editor = history.current_state.hub_editor orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), hub_editor.hub);
    try testing.expectEqual(types.TileBounds{ .min_x = 0, .min_y = 0, .max_x = 3, .max_y = 2 }, hub_editor.clamp_bounds.?);
    try testing.expect(history.current_state.campaign_editor != null);

    // A crafted dead handle no-ops (the defensive convention - no
    // transition, no state).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_hub_editor = .{
            .hub = 99,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(state.Screen.hub_editor, history.current_state.screen);

    // The close (the world-map return button): back to the campaign map,
    // the scope rule dropping the drill-in state; the graph untouched.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .close_hub_editor }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(state.Screen.campaign_editor, history.current_state.screen);
    try testing.expect(history.current_state.hub_editor == null);
    try testing.expect(history.current_state.campaign_editor != null);
    try testing.expect(history.current_state.campaign_editor.?.hubs.len == 1);

    // Undo restores the drill-in (the close is a plain timeline event).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(state.Screen.hub_editor, history.current_state.screen);
    try testing.expect(history.current_state.hub_editor != null);

    // Exit-to-menu from the drill-in discards the whole editing session
    // (the scope swap clears hub_editor AND campaign_editor).
    event_push.pushPlayerAction(
        &history.current_state,
        .player_exit_to_menu,
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(state.Screen.main_menu, history.current_state.screen);
    try testing.expect(history.current_state.hub_editor == null);
    try testing.expect(history.current_state.campaign_editor == null);
}

test "hub editor events: tile paint, selection, the move chain over the drilled-in hub grid" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Drill",
            .start_hub = 0,
            .hubs = &.{.{
                .handle = 0,
                .name = "Alpha",
                .position = .{ .x = 0, .y = 0 },
                .grid = .{
                    .level_tiles = &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } },
                    .player_start = .{ .x = 0, .y = 0 },
                },
            }},
            .next_handle = 1,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // Drill in.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_hub_editor = .{ .hub = 0 } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(state.Screen.hub_editor, history.current_state.screen);

    // Tile paint on empty ground: the tile lands in the AUTHORED graph (the
    // write-through - the hub grid in campaign_editor, not a copy).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_paint_hub_tile = .{
            .position = .{ .x = 5, .y = 5 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const hubs = history.current_state.campaign_editor.?.hubs;
        try testing.expectEqual(@as(usize, 3), hubs[0].grid.level_tiles.len);
    }

    // The tool switch: tile -> select clears nothing (no selection yet);
    // a switch away from select with a selection takes it along.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_set_hub_tool = .{
            .tool = .select,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // Select the spawn ('!' singleton group).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_replace_hub_selection = .{
            .position = .{ .x = 0, .y = 0 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.hub_editor.?.selection.len);
    try testing.expectEqual(types.Selectable.player_start, history.current_state.hub_editor.?.selection[0]);

    // Move the selection (the spawn) by one tile: the chained
    // hub_commit_selection_move paints the ground at the target, moves the
    // spawn, and clears the selection. One undo step reverts the whole
    // move.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_move_hub_selection = .{
            .delta = .{ .x = 1, .y = 0 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const hubs = history.current_state.campaign_editor.?.hubs;
        try testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, hubs[0].grid.player_start);
        try testing.expectEqual(@as(usize, 0), history.current_state.hub_editor.?.selection.len);
    }

    // Undo the move: the spawn returns, the selection returns.
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const hubs = history.current_state.campaign_editor.?.hubs;
        try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, hubs[0].grid.player_start);
        try testing.expectEqual(@as(usize, 1), history.current_state.hub_editor.?.selection.len);
    }

    // The crafted-log belt: a dead drill-in handle no-ops every edit (the
    // state is untouched, no panic).
    history.current_state.hub_editor.?.hub = 99;
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_paint_hub_tile = .{
            .position = .{ .x = 9, .y = 9 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const hubs = history.current_state.campaign_editor.?.hubs;
        try testing.expectEqual(@as(usize, 3), hubs[0].grid.level_tiles.len);
    }
}

test "hub editor events: the decoration placement + delete + selection reconcile over the hub grid" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(.{
        .screen = .hub_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Drill",
            .start_hub = 0,
            .hubs = &.{.{
                .handle = 0,
                .name = "Alpha",
                .position = .{ .x = 0, .y = 0 },
                .grid = .{
                    .level_tiles = &.{.{ .x = 0, .y = 0 }},
                    .player_start = .{ .x = 0, .y = 0 },
                },
            }},
            .decoration_types = &.{
                .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
                .{ .id = "rock", .sprite = "rock_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
            },
            .next_handle = 1,
        },
        .hub_editor = .{ .hub = 0, .active_tool = .select },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // Place two decorations (the move chain's re-placement path + 4-5's
    // tool call the same event) at tile-free ground. The stack is LIFO -
    // the batch is pushed in REVERSE so the placements land in authoring
    // order [tree, rock].
    event_push.pushEvents(
        &history.current_state,
        &.{
            .{ .hub_editor_event = .{ .hub_place_decoration = .{ .type_id = 1, .position = .{ .x = 4, .y = 0 } } } },
            .{ .hub_editor_event = .{ .hub_place_decoration = .{ .type_id = 0, .position = .{ .x = 3, .y = 0 } } } },
        },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const hubs = history.current_state.campaign_editor.?.hubs;
        try testing.expectEqual(@as(usize, 2), hubs[0].grid.decoration_placements.len);
    }

    // Select BOTH decorations (the replace plan over the first's tile
    // grabs its group), then delete the LOWER one: the selection's higher
    // index shifts down (the reconcile) - the surviving entry still points
    // at the right placement.
    event_push.pushEvents(
        &history.current_state,
        &.{
            .{ .hub_editor_event = .{ .hub_select = .{ .entry = .{ .decoration_placement = 0 } } } },
            .{ .hub_editor_event = .{ .hub_select = .{ .entry = .{ .decoration_placement = 1 } } } },
        },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .hub_editor_event = .{ .hub_delete_decoration_placement = .{
            .placement_index = 0,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const hubs = history.current_state.campaign_editor.?.hubs;
        try testing.expectEqual(@as(usize, 1), hubs[0].grid.decoration_placements.len);
        try testing.expectEqual(@as(u32, 1), hubs[0].grid.decoration_placements[0].type_id);
        const selection = history.current_state.hub_editor.?.selection;
        try testing.expectEqual(@as(usize, 1), selection.len);
        try testing.expectEqual(@as(u32, 0), selection[0].decoration_placement);
    }

    // The placement invariant: placing onto a TILE is the fail-fast class
    // (the planners clear occupants first - reaching here occupied is a
    // logic bug).
    // (Asserted by the panic path - not unit-testable per the no-
    // expectPanics convention; the hub-readiness planning test pins the
    // no-op ordering that keeps it unreachable.)
}

test "hub editor events: the NPC placement, the exit-marker upsert + delete over the drilled-in hub" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(.{
        .screen = .hub_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Drill",
            .start_hub = 0,
            .hubs = &.{.{
                .handle = 0,
                .name = "Alpha",
                .position = .{ .x = 0, .y = 0 },
                .grid = .{
                    .level_tiles = &.{.{ .x = 0, .y = 0 }},
                    .player_start = .{ .x = 0, .y = 0 },
                },
            }},
            .missions = &.{.{ .handle = 5, .name = "One", .start = 0, .destination = 0 }},
            .next_handle = 6,
        },
        .hub_editor = .{ .hub = 0, .active_tool = .select },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // The NPC tool click (the orchestrator): places the NPC + its ground
    // tile in one plan.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_place_hub_npc = .{
            .npc_type = .dream_guide,
            .position = .{ .x = 3, .y = 0 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const grid = history.current_state.campaign_editor.?.hubs[0].grid;
        try testing.expectEqual(@as(usize, 1), grid.npc_placements.len);
        try testing.expectEqual(types.NpcType.dream_guide, grid.npc_placements[0].npc_type);
        try testing.expectEqual(@as(usize, 2), grid.level_tiles.len); // the ground ensured
    }

    // The mission tool click (the orchestrator): the upsert creates the
    // marker + its ground; the co-located NPC yields.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_place_hub_exit_marker = .{
            .mission = 5,
            .position = .{ .x = 3, .y = 0 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const grid = history.current_state.campaign_editor.?.hubs[0].grid;
        try testing.expectEqual(@as(usize, 1), grid.exit_placements.len);
        try testing.expectEqual(types.Vector2{ .x = 3, .y = 0 }, grid.exit_placements[0].position);
        try testing.expectEqual(@as(usize, 0), grid.npc_placements.len); // yielded to the marker
    }

    // Placing the same mission elsewhere MOVES the marker (the upsert).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_place_hub_exit_marker = .{
            .mission = 5,
            .position = .{ .x = 4, .y = 0 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const grid = history.current_state.campaign_editor.?.hubs[0].grid;
        try testing.expectEqual(@as(usize, 1), grid.exit_placements.len);
        try testing.expectEqual(types.Vector2{ .x = 4, .y = 0 }, grid.exit_placements[0].position);
    }

    // The right-click delete's marker tier (the orchestrator): the
    // marker goes, the graph wiring survives, the ground stays.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_delete_hub_at = .{
            .position = .{ .x = 4, .y = 0 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const editor = history.current_state.campaign_editor.?;
        try testing.expectEqual(@as(usize, 0), editor.hubs[0].grid.exit_placements.len);
        try testing.expectEqual(@as(usize, 1), editor.missions.len); // the mission survives
        try testing.expectEqual(@as(usize, 3), editor.hubs[0].grid.level_tiles.len); // the ground survives ((0,0) + both marker grounds)
    }

    // A crafted mission tool for a NON-outgoing mission is rejected at
    // the tool switch (the editor_set_tool posture).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_set_hub_tool = .{
            .tool = .{ .mission = 99 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.hub_editor.?.active_tool == .select);
}

test "hub editor events: the decoration-type delete cascade + the granular edits over the campaign palette" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(.{
        .screen = .hub_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Drill",
            .start_hub = 0,
            .hubs = &.{
                .{
                    .handle = 0,
                    .name = "Alpha",
                    .position = .{ .x = 0, .y = 0 },
                    .grid = .{
                        .level_tiles = &.{.{ .x = 0, .y = 0 }},
                        .player_start = .{ .x = 0, .y = 0 },
                        // type 0 at (1,0) + type 1 at (2,0) + type 2 at (3,0):
                        // the delete of type 0 removes the first, decrements
                        // the others' type ids.
                        .decoration_placements = &.{
                            .{ .type_id = 0, .position = .{ .x = 1, .y = 0 } },
                            .{ .type_id = 1, .position = .{ .x = 2, .y = 0 } },
                            .{ .type_id = 2, .position = .{ .x = 3, .y = 0 } },
                        },
                    },
                },
                .{
                    .handle = 1,
                    .name = "Beta",
                    .position = .{ .x = 400, .y = 0 },
                    .grid = .{
                        .level_tiles = &.{.{ .x = 0, .y = 0 }},
                        .player_start = .{ .x = 0, .y = 0 },
                        // The SAME type placed in ANOTHER hub - the cascade
                        // crosses hubs.
                        .decoration_placements = &.{.{ .type_id = 0, .position = .{ .x = 1, .y = 1 } }},
                    },
                },
            },
            .decoration_types = &.{
                .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
                .{ .id = "rock", .sprite = "rock_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
                .{ .id = "bush", .sprite = "bush_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
            },
            .next_handle = 2,
        },
        .hub_editor = .{ .hub = 0, .active_tool = .{ .decoration_type = 0 }, .selection = &.{.{ .decoration_placement = 2 }} },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // The granular edits first: the color + the keep-colors flag.
    event_push.pushEvents(
        &history.current_state,
        &.{
            .{ .hub_editor_event = .{ .hub_set_decoration_color_index = .{ .type_id = 1, .value = 3 } } },
            .{ .hub_editor_event = .{ .hub_set_decoration_keep_original_colors = .{ .type_id = 1, .value = true } } },
        },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 3), history.current_state.campaign_editor.?.decoration_types[1].color_index);
    try testing.expect(history.current_state.campaign_editor.?.decoration_types[1].keep_original_colors);

    // The delete cascade: type 0 removed; its placements pruned from BOTH
    // hubs; the higher type ids (1, 2 -> 0, 1) decremented everywhere; the
    // selection's index 2 (type 2's placement, above one removed) shifts
    // to 1; the ACTIVE TOOL (the deleted type) resets to select.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_delete_hub_decoration_type = .{
            .type_id = 0,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const editor = history.current_state.campaign_editor.?;
        try testing.expectEqual(@as(usize, 2), editor.decoration_types.len); // rock + bush
        try testing.expectEqualStrings("rock_1", editor.decoration_types[0].sprite);
        // Alpha's placements: type 0's gone; the others decremented.
        const alpha = editor.hubs[0].grid.decoration_placements;
        try testing.expectEqual(@as(usize, 2), alpha.len);
        try testing.expectEqual(@as(u32, 0), alpha[0].type_id); // was 1 (rock)
        try testing.expectEqual(types.Vector2{ .x = 2, .y = 0 }, alpha[0].position);
        try testing.expectEqual(@as(u32, 1), alpha[1].type_id); // was 2 (bush)
        // Beta's placement (type 0) pruned cross-hub.
        try testing.expectEqual(@as(usize, 0), editor.hubs[1].grid.decoration_placements.len);
        // The selection shifted; the tool reset.
        const hub_editor = history.current_state.hub_editor.?;
        try testing.expectEqual(@as(usize, 1), hub_editor.selection.len);
        try testing.expectEqual(@as(u32, 1), hub_editor.selection[0].decoration_placement);
        try testing.expect(hub_editor.active_tool == .select);
    }

    // One undo step reverts the whole cascade (the atomic-event design).
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const editor = history.current_state.campaign_editor.?;
        try testing.expectEqual(@as(usize, 3), editor.decoration_types.len);
        try testing.expectEqual(@as(usize, 3), editor.hubs[0].grid.decoration_placements.len);
        try testing.expectEqual(@as(usize, 1), editor.hubs[1].grid.decoration_placements.len);
    }
}

test "hub editor: the surface-polymorphic decoration commits route to the campaign palette" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(.{
        .screen = .hub_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Drill",
            .start_hub = 0,
            .hubs = &.{.{
                .handle = 0,
                .name = "Alpha",
                .position = .{ .x = 0, .y = 0 },
                .grid = .{
                    .level_tiles = &.{.{ .x = 0, .y = 0 }},
                    .player_start = .{ .x = 0, .y = 0 },
                },
            }},
            .decoration_types = &.{
                .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
                .{ .id = "rock", .sprite = "rock_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
            },
            .next_handle = 1,
        },
        .hub_editor = .{ .hub = 0, .active_tool = .{ .decoration_type = 0 } },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // The hub inspector's swatch + keep-colors rows emit the MISSION
    // actions; the consumption + orchestrator route them per screen to
    // the hub events (the 4-5d reuse). The orchestrator arms are the
    // contract here: the same player events that edit the mission
    // palette on .editor edit the CAMPAIGN palette on .hub_editor.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_set_editor_decoration_color_index = .{
            .type_id = 1,
            .value = 2,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 2), history.current_state.campaign_editor.?.decoration_types[1].color_index);
    try testing.expectEqual(@as(u32, 0), history.current_state.campaign_editor.?.decoration_types[0].color_index);

    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_set_editor_decoration_keep_original_colors = .{
            .type_id = 1,
            .value = true,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.decoration_types[1].keep_original_colors);

    // An out-of-range type id no-ops defensively (the hub handler's
    // bound) instead of corrupting the palette.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_set_editor_decoration_color_index = .{
            .type_id = 99,
            .value = 4,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 2), history.current_state.campaign_editor.?.decoration_types[1].color_index);

    // Each commit is its own undo step, reverting to the prior palette.
    // The out-of-range no-op is still a RECORDED event (a handler no-op
    // is not a timeline skip), so it owns an undo step too.
    try testing.expect(history.undo(event_handlers.processEvent)); // the out-of-range no-op
    try testing.expect(history.undo(event_handlers.processEvent)); // the keep-colors commit
    try testing.expect(!history.current_state.campaign_editor.?.decoration_types[1].keep_original_colors);
    try testing.expectEqual(@as(u32, 2), history.current_state.campaign_editor.?.decoration_types[1].color_index);
    try testing.expect(history.undo(event_handlers.processEvent)); // the color commit
    try testing.expectEqual(@as(u32, 0), history.current_state.campaign_editor.?.decoration_types[1].color_index);
}

test "hub editor: the sprite-picker pick commits the whole def + the cross-hub placement prune" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var history = harness.newHistory(.{
        .screen = .hub_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Drill",
            .start_hub = 0,
            .hubs = &.{
                .{
                    .handle = 0,
                    .name = "Alpha",
                    .position = .{ .x = 0, .y = 0 },
                    .grid = .{
                        .level_tiles = &.{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 0 } },
                        .player_start = .{ .x = 0, .y = 0 },
                        // A tree_1 placement on the tile (3,0) - the new
                        // footprint (2 tiles wide) invalidates it.
                        .decoration_placements = &.{.{ .type_id = 0, .position = .{ .x = 3, .y = 0 } }},
                    },
                },
            },
            .decoration_types = &.{
                .{ .id = "tree_1", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }}, .pixel_dims = .{ .x = 256, .y = 256 } },
            },
            .next_handle = 1,
        },
        .hub_editor = .{ .hub = 0, .active_tool = .{ .decoration_type = 0 } },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // The picker open (the surface-polymorphic sprite button) + the pick:
    // a registry prefab adoption (the whole def incl. the flag).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_open_hub_picker = .{
            .target = .{ .decoration_sprite = {} },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.hub_editor.?.picker != null);

    // The pick (the orchestrator the consumption site would push - the
    // def construction itself is exercised via the handler contract):
    // adopt a 2-tile-wide footprint that invalidates the (3,0) placement.
    const new_footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_set_hub_decoration_def = .{
            .type_id = 0,
            .sprite = "bush_1",
            .footprint = &new_footprint,
            .pixel_dims = .{ .x = 512, .y = 256 },
            .color_index = 2,
            .keep_original_colors = false,
            .layers = &.{},
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const editor = history.current_state.campaign_editor.?;
        try testing.expectEqualStrings("bush_1", editor.decoration_types[0].sprite);
        try testing.expectEqual(@as(usize, 2), editor.decoration_types[0].footprint.len);
        // The placement pruned: the (3,0) tile is covered by the new
        // 2-wide footprint at (3,0).
        try testing.expectEqual(@as(usize, 0), editor.hubs[0].grid.decoration_placements.len);
        // The picker closed by the commit's child event... the
        // consumption site pushes the close; the direct orchestrator
        // here doesn't - the picker state is orthogonal to the def.
    }

    // Undo: the def + the placement return in one step.
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const editor = history.current_state.campaign_editor.?;
        try testing.expectEqualStrings("tree_1", editor.decoration_types[0].sprite);
        try testing.expectEqual(@as(usize, 1), editor.hubs[0].grid.decoration_placements.len);
    }
}

test "hub editor: the footprint editor flow - open seeds the draft, tile toggles flip it, confirm commits the whole def" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const input_handlers_mod = @import("input_handlers.zig");

    var history = harness.newHistory(.{
        .screen = .hub_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Drill",
            .start_hub = 0,
            .hubs = &.{.{ .handle = 0, .name = "Alpha", .position = .{ .x = 0, .y = 0 }, .grid = .{} }},
            // A 512x256 sprite -> a 2x1 tile grid, footprint {0,0}.
            .decoration_types = &.{.{
                .id = "tree_1",
                .sprite = "tree_1",
                .footprint = &.{.{ .x = 0, .y = 0 }},
                .pixel_dims = .{ .x = 512, .y = 256 },
            }},
            .next_handle = 1,
        },
        .hub_editor = .{ .hub = 0, .active_tool = .{ .decoration_type = 0 } },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // The open arm (the surface-polymorphic footprint button): seeds the
    // draft from the committed footprint + opens the HUB picker.
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .open_editor_footprint_picker },
        null,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    const hub_editor = &(history.current_state.hub_editor.?);
    try testing.expect(hub_editor.picker != null);
    try testing.expectEqual(@as(u32, 0), hub_editor.picker.?.decoration_footprint);
    try testing.expect(history.session.ui_state.editor_footprint_draft[0]);
    try testing.expect(!history.session.ui_state.editor_footprint_draft[1]);

    // A tile toggle flips one draft cell (a direct UiState write, off the
    // timeline).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .toggle_editor_footprint_tile },
        .{ .editor_footprint_tile = 1 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .toggle_editor_footprint_tile },
        .{ .editor_footprint_tile = 0 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    try testing.expect(!history.session.ui_state.editor_footprint_draft[0]);
    try testing.expect(history.session.ui_state.editor_footprint_draft[1]);

    // The confirm: the whole-def commit route (the base sprite pick's
    // path - one recorded player event, the close as its child).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .confirm_editor_footprint },
        null,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    {
        const editor = history.current_state.campaign_editor.?;
        try testing.expectEqual(@as(usize, 1), editor.decoration_types[0].footprint.len);
        try testing.expectEqual(@as(i32, 1), editor.decoration_types[0].footprint[0].x);
        try testing.expectEqual(@as(i32, 0), editor.decoration_types[0].footprint[0].y);
        // The sprite + dims ride along unchanged (the whole-def route).
        try testing.expectEqualStrings("tree_1", editor.decoration_types[0].sprite);
        try testing.expectEqual(@as(i32, 512), editor.decoration_types[0].pixel_dims.x);
        // The picker closed (the commit's close child).
        try testing.expect(history.current_state.hub_editor.?.picker == null);
    }

    // One undo step reverts the footprint change (the whole-def event).
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const editor = history.current_state.campaign_editor.?;
        try testing.expectEqual(@as(usize, 1), editor.decoration_types[0].footprint.len);
        try testing.expectEqual(@as(i32, 0), editor.decoration_types[0].footprint[0].x);
    }

    // The UNCHANGED-draft confirm closes without committing; the EMPTY
    // draft stays open (a footprint reserves at least one tile).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .open_editor_footprint_picker },
        null,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    try testing.expect(history.current_state.hub_editor.?.picker != null);
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .confirm_editor_footprint },
        null,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    try testing.expect(history.current_state.hub_editor.?.picker == null);
    {
        const editor = history.current_state.campaign_editor.?;
        try testing.expectEqual(@as(i32, 0), editor.decoration_types[0].footprint[0].x);
    }
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .open_editor_footprint_picker },
        null,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .toggle_editor_footprint_tile },
        .{ .editor_footprint_tile = 0 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .confirm_editor_footprint },
        null,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    // The empty draft keeps the editor open - the confirm visibly
    // doesn't take.
    try testing.expect(history.current_state.hub_editor.?.picker != null);
}

test "hub editor: the layer machinery - add adopts the registry authoring, color swaps, delete removes, all via the whole-def commit" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const input_handlers_mod = @import("input_handlers.zig");

    var history = harness.newHistory(.{
        .screen = .hub_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Drill",
            .start_hub = 0,
            .hubs = &.{.{ .handle = 0, .name = "Alpha", .position = .{ .x = 0, .y = 0 }, .grid = .{} }},
            // A tree_1-shaped base: 768x768 (the real shipped dims), so
            // a shipped layer stem resolves + matches.
            .decoration_types = &.{.{
                .id = "tree_1",
                .sprite = "tree_1",
                .footprint = &.{.{ .x = 0, .y = 2 }},
                .pixel_dims = .{ .x = 768, .y = 768 },
            }},
            .next_handle = 1,
        },
        .hub_editor = .{ .hub = 0, .active_tool = .{ .decoration_type = 0 } },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // A recorded event first: the reconstruction-cache reads below (the
    // registry load) key against the PREVIOUS event index, and the
    // fixture starts with none (at runtime a session always has history
    // by the time an editor opens).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .toggle_hub_inspector },
        null,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);

    // The add-layer open (the surface-polymorphic layer button, null
    // payload): the HUB picker opens in layer-ADD mode + the registry is
    // ensured (the adoption source).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .open_editor_decoration_layer_picker },
        null,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    {
        const hub_editor = &(history.current_state.hub_editor.?);
        try testing.expect(hub_editor.picker != null);
        try testing.expect(hub_editor.picker.? == .decoration_layer);
        try testing.expect(hub_editor.picker.?.decoration_layer == null);
    }
    try testing.expect(history.session.editor_decoration_registry.len > 0);

    // The ADD pick (a real shipped layer stem): the registry's authored
    // color + draw side for the stem, else the defaults; committed via
    // the whole-def event (the close is its child).
    const picked_sprite = "tree_1_canopy";
    const expected_color: u32 = blk: {
        for (history.session.editor_decoration_registry) |definition| {
            for (definition.layers) |layer| {
                if (std.mem.eql(u8, layer.sprite, picked_sprite)) break :blk layer.color_index;
            }
        }
        break :blk 0;
    };
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_decoration_layer },
        .{ .editor_sprite = picked_sprite },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    {
        const editor = history.current_state.campaign_editor.?;
        try testing.expectEqual(@as(usize, 1), editor.decoration_types[0].layers.len);
        const added = editor.decoration_types[0].layers[0];
        try testing.expectEqualStrings(picked_sprite, added.sprite);
        try testing.expectEqual(expected_color, added.color_index);
        try testing.expectEqual(@as(i32, 768), added.pixel_dims.x);
        // The base + footprint ride along unchanged (the whole-def route).
        try testing.expectEqualStrings("tree_1", editor.decoration_types[0].sprite);
        try testing.expectEqual(@as(usize, 1), editor.decoration_types[0].footprint.len);
        // The picker closed (the commit's close child).
        try testing.expect(history.current_state.hub_editor.?.picker == null);
    }

    // The layer's color swatch: the whole-def route again; a same-color
    // pick never fires.
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_decoration_layer_color },
        .{ .editor_layer_color = .{ .layer_index = 0, .color_index = 4 } },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 4), history.current_state.campaign_editor.?.decoration_types[0].layers[0].color_index);
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_decoration_layer_color },
        .{ .editor_layer_color = .{ .layer_index = 0, .color_index = 4 } },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 4), history.current_state.campaign_editor.?.decoration_types[0].layers[0].color_index);

    // The layer delete: the def with the layer list minus the index.
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .delete_editor_decoration_layer },
        .{ .editor_layer = 0 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.campaign_editor.?.decoration_types[0].layers.len);

    // Each commit is its own undo step (the whole-def events).
    try testing.expect(history.undo(event_handlers.processEvent)); // the delete
    try testing.expectEqual(@as(usize, 1), history.current_state.campaign_editor.?.decoration_types[0].layers.len);
    try testing.expect(history.undo(event_handlers.processEvent)); // the color swap
    try testing.expectEqual(expected_color, history.current_state.campaign_editor.?.decoration_types[0].layers[0].color_index);
    try testing.expect(history.undo(event_handlers.processEvent)); // the add
    try testing.expectEqual(@as(usize, 0), history.current_state.campaign_editor.?.decoration_types[0].layers.len);
}

test "hub editor: the metadata sidebar's gradient rows - world pick, enemy auto freeze + revert, all one-undo commits" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const input_handlers_mod = @import("input_handlers.zig");

    var history = harness.newHistory(.{
        .screen = .hub_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Drill",
            .start_hub = 0,
            .hubs = &.{.{ .handle = 0, .name = "Alpha", .position = .{ .x = 0, .y = 0 }, .grid = .{} }},
            .next_handle = 1,
        },
        .hub_editor = .{ .hub = 0 },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // The world row's open: the HUB theme picker opens with the role.
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .open_editor_level_gradient_picker },
        .{ .editor_gradient_role = .world },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    {
        const hub_editor = &(history.current_state.hub_editor.?);
        try testing.expect(hub_editor.picker != null);
        try testing.expect(hub_editor.picker.? == .hub_gradient);
        try testing.expect(hub_editor.picker.?.hub_gradient.role == .world);
    }

    // The world pick: the grid's color wheel commits (the commit chains
    // its close - pick + close is one undo step, the mission arm's rule).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_level_gradient },
        .{ .editor_gradient = 3 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    {
        const hub = history.current_state.campaign_editor.?.hubs[0];
        try testing.expectEqual(@as(u32, 3), hub.grid.color_wheel_index);
        try testing.expect(history.current_state.hub_editor.?.picker == null);
    }

    // The enemy Auto toggle: a TRUE toggle both ways - manual freezes the
    // derived index, a second click reverts to the null override.
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .toggle_editor_level_gradient_auto },
        .{ .editor_gradient_role = .enemy },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    {
        const loaders = @import("loaders.zig");
        const derived_enemy_index: u32 = loaders.autoDerivedGradientIndex(
            history.color_theme_definitions,
            3,
            .enemy,
        );
        const hub = history.current_state.campaign_editor.?.hubs[0];
        try testing.expect(hub.grid.enemy_gradient_index != null);
        // The frozen value is the DERIVED index for wheel 3 - derived
        // through the same helper the arm uses (not a hand-picked number).
        try testing.expectEqual(derived_enemy_index, hub.grid.enemy_gradient_index.?);
    }
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .toggle_editor_level_gradient_auto },
        .{ .editor_gradient_role = .enemy },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    try testing.expect(history.current_state.campaign_editor.?.hubs[0].grid.enemy_gradient_index == null);

    // The enemy pick while on auto flips to manual in the same commit
    // (the explicit pick IS the manual choice).
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .open_editor_level_gradient_picker },
        .{ .editor_gradient_role = .enemy },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    input_handlers_mod.handleAnytimeInput(
        &history,
        .{ .options_action = .select_editor_level_gradient },
        .{ .editor_gradient = 5 },
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 5), history.current_state.campaign_editor.?.hubs[0].grid.enemy_gradient_index.?);

    // The undo ladder: every recorded action (each open + each commit) is
    // an idle point, walking back through the enemy pick's open, the
    // revert, the freeze, the world commit, the world open.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.campaign_editor.?.hubs[0].grid.enemy_gradient_index == null);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.campaign_editor.?.hubs[0].grid.enemy_gradient_index == null);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.campaign_editor.?.hubs[0].grid.enemy_gradient_index != null);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(u32, 3), history.current_state.campaign_editor.?.hubs[0].grid.color_wheel_index);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(u32, 0), history.current_state.campaign_editor.?.hubs[0].grid.color_wheel_index);
}

test "saveHubEditor: the drill-in save self-serves a fresh campaign's identity (no full save needed)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    const campaign_editor_io = @import("campaign_editor/io.zig");
    const file_source_mod = @import("file_source.zig");

    // A FRESH campaign (no uuid, no dir) with one hub drilled in.
    var history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Fresh",
            .start_hub = 0,
            .hubs = &.{.{
                .handle = 0,
                .name = "Alpha",
                .position = .{ .x = 0, .y = 0 },
                .grid = .{
                    .level_tiles = &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } },
                    .player_start = .{ .x = 0, .y = 0 },
                },
            }},
            .next_handle = 1,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_hub_editor = .{
            .hub = 0,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The hub-only save succeeds on the never-saved campaign (the old
    // "save the campaign first" gate is gone): the identities mint HERE
    // and writeFile mkdir-p materializes the dirs.
    campaign_editor_io.saveHubEditor(&history);
    try testing.expect(history.session.pending_error == null);
    const campaign_memo = campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?;
    const campaign_dir = try arena.dupe(u8, campaign_memo.dir);
    const campaign_uuid = try arena.dupe(u8, campaign_memo.uuid);
    try testing.expect(campaign_uuid.len > 0);
    try testing.expect(std.mem.startsWith(u8, campaign_dir, "campaigns/"));
    const hub_memo = campaign_editor_io.campaignSaveMemoFor(&history, 0).?;
    const hub_dir = try arena.dupe(u8, hub_memo.dir);
    try testing.expect(std.mem.startsWith(u8, hub_dir, hub_memo.uuid));

    // The hub file landed under the minted campaign dir, carrying its
    // minted identity; the campaign itself stays UNLISTED (no
    // campaign.txt - the first full save's business; a dir without one
    // never lists).
    const hub_txt = try harness.file_source.readFile(
        arena,
        try std.fmt.allocPrint(arena, "{s}/hubs/{s}/hub.txt", .{ campaign_dir, hub_dir }),
    );
    {
        const sections = try parser.parseConfigFile(hub_txt, arena, &parser.hub_sections);
        try testing.expectEqualStrings(
            hub_memo.uuid,
            parser.findValue(parser.findSection(sections, "Metadata").?.entry_groups[0].pairs, "hub_uuid") orelse "",
        );
    }
    try testing.expect(!file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/campaign.txt", .{campaign_dir}),
    ));
    try testing.expectEqual(@as(usize, 0), (try harness.file_source.listCampaigns(arena)).len);

    // The subsequent FULL save reconciles under the SAME identities (the
    // memos win): campaign.txt lands on the minted dir, the hub keeps
    // its hub-save minted dir, the campaign lists.
    _ = campaign_editor_io.saveCampaignEditor(&history);
    try testing.expect(history.session.pending_error == null);
    try testing.expect(file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/campaign.txt", .{campaign_dir}),
    ));
    const hub_memo_after = campaign_editor_io.campaignSaveMemoFor(&history, 0).?;
    try testing.expectEqualStrings(hub_dir, hub_memo_after.dir);
    try testing.expectEqual(@as(usize, 1), (try harness.file_source.listCampaigns(arena)).len);
}

test "saveHubEditor: an official-origin hub save forks (the root carry) and the later full save heals it" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    const campaign_editor_io = @import("campaign_editor/io.zig");
    const file_source_mod = @import("file_source.zig");

    // Open the REAL official campaign (embedded content - its files do
    // not exist in the harness's persistent dir, which is what makes it
    // official-origin) and drill into its first hub. The dir is DERIVED
    // (authored content - never pinned).
    const official_campaign_dir = test_harness.officialCampaignDir(arena);
    var history = harness.newHistory(null);
    runToIdle(&history);
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = official_campaign_dir,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const opened = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
    const official_hub_uuid = try arena.dupe(u8, opened.hubs[0].uuid);

    // The hub-only save FORKS instead of refusing (the old gate): a
    // fresh campaign identity + the root carry, the hub minted under it,
    // the official dir never shadowed.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_hub_editor = .{
            .hub = opened.hubs[0].handle,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    campaign_editor_io.saveHubEditor(&history);
    try testing.expect(history.session.pending_error == null);
    const campaign_memo = campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?;
    const fork_dir = try arena.dupe(u8, campaign_memo.dir);
    try testing.expect(!std.mem.eql(u8, fork_dir, official_campaign_dir));
    // The root carry, DERIVED: every root file of the opened dir exists
    // under the fork (background PNGs included when the campaign ships
    // them - the map-specific assertion became the derived file set).
    const opened_root_files = try harness.file_source.listDirFiles(arena, official_campaign_dir);
    defer file_source_mod.freeDirFiles(arena, opened_root_files);
    for (opened_root_files) |file_name| {
        // The hub-save's root carry is MINUS campaign.txt (a carried one
        // would make the half-born fork list - asserted unlisted below).
        if (std.mem.eql(u8, file_name, "campaign.txt")) continue;
        try testing.expect(file_source_mod.persistentFileExists(
            &harness.file_source,
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ fork_dir, file_name }),
        ));
    }
    const hub_memo = campaign_editor_io.campaignSaveMemoFor(&history, opened.hubs[0].handle).?;
    const hub_uuid = try arena.dupe(u8, hub_memo.uuid);
    const hub_dir = try arena.dupe(u8, hub_memo.dir);
    try testing.expect(!std.mem.eql(u8, hub_uuid, official_hub_uuid));
    try testing.expect(file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/hubs/{s}/hub.txt", .{ fork_dir, hub_dir }),
    ));
    try testing.expect(!file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/campaign.txt", .{official_campaign_dir}),
    ));
    // The fork is unlisted until its first full save (no campaign.txt).
    try testing.expectEqual(@as(usize, 0), (try harness.file_source.listCampaigns(arena)).len);

    // The later FULL save heals the fork: campaign.txt lands, every
    // mission forks with a fresh identity, the drilled hub KEEPS its
    // hub-save identity (the memo wins), and the rewritten hub.txt
    // references the forked missions.
    _ = campaign_editor_io.saveCampaignEditor(&history);
    try testing.expect(history.session.pending_error == null);
    try testing.expect(file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/campaign.txt", .{fork_dir}),
    ));
    try testing.expectEqual(@as(usize, 1), (try harness.file_source.listCampaigns(arena)).len);
    const hub_memo_after = campaign_editor_io.campaignSaveMemoFor(&history, opened.hubs[0].handle).?;
    try testing.expectEqualStrings(hub_uuid, hub_memo_after.uuid);
    const healed_hub_txt = try harness.file_source.readFile(
        arena,
        try std.fmt.allocPrint(arena, "{s}/hubs/{s}/hub.txt", .{ fork_dir, hub_memo_after.dir }),
    );
    for (opened.missions) |official_mission| {
        const mission_memo = campaign_editor_io.campaignSaveMemoFor(&history, official_mission.handle).?;
        try testing.expect(!std.mem.eql(u8, mission_memo.uuid, official_mission.uuid));
    }
    // The rewritten hub.txt references the MINTED uuids of exactly the
    // missions whose exit markers live in the drilled hub (derived from
    // the hub's own grid - only its own exits can appear in its file).
    for (opened.hubs[0].grid.exit_placements) |placement| {
        const mission_memo = campaign_editor_io.campaignSaveMemoFor(&history, placement.mission).?;
        try testing.expect(std.mem.indexOf(u8, healed_hub_txt, mission_memo.uuid) != null);
    }
}

test "mission editor hand-off: the on-disk open adopts the graph name + context; close returns; the foreign-open clears" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    const campaign_editor_io = @import("campaign_editor/io.zig");

    // The REAL official campaign: its missions are on-disk content the
    // hand-off loads through the reconstruction cache. The dir is DERIVED
    // (authored content - never pinned).
    const official_campaign_dir = test_harness.officialCampaignDir(arena);
    var history = harness.newHistory(null);
    runToIdle(&history);
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = official_campaign_dir,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const opened = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
    const mission = opened.missions[0];

    // The input layer's path computation (memo-aware; no memos exist
    // yet, so it resolves the state identity): the campaign's missions/
    // dir + the mission's dir.
    const mission_path = campaign_editor_io.campaignMissionEditorPath(
        &history,
        opened,
        mission,
        arena,
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "{s}/missions/{s}", .{ official_campaign_dir, mission.dir }),
        mission_path,
    );

    // The hand-off open: the mission editor in campaign context. The
    // graph's name is adopted over the file's (identical here - the
    // official mission was never renamed), the mission's real content
    // loads, and the campaign survives below.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_mission_editor = .{
            .mission = mission.handle,
            .mission_path = mission_path,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(state.Screen.editor, history.current_state.screen);
    const editor = history.current_state.editor orelse return error.TestUnexpectedResult;
    try testing.expectEqual(mission.handle, editor.campaign_mission.?);
    try testing.expectEqualStrings(mission.name, editor.mission.name);
    try testing.expect(editor.levels.len > 0);
    try testing.expect(history.current_state.campaign_editor != null);

    // The return: back to the campaign map, the scope rule dropping the
    // editor payload (context included); the graph untouched.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .close_mission_editor = {} } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(state.Screen.campaign_editor, history.current_state.screen);
    try testing.expect(history.current_state.editor == null);
    try testing.expect(history.current_state.campaign_editor != null);
    try testing.expect(history.current_state.campaign_editor.?.missions.len == opened.missions.len);

    // Undo restores the hand-off (the close is a plain timeline event).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(state.Screen.editor, history.current_state.screen);
    try testing.expect(history.current_state.editor.?.campaign_mission != null);

    // The foreign-open rule: opening other content from within the
    // hand-off (the editor browser's rows) clears the campaign below -
    // the replacement payload carries no context, so the campaign would
    // linger alive-but-orphaned otherwise. Undo restores both.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_editor = .{
            .mission_path = null,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(state.Screen.editor, history.current_state.screen);
    try testing.expect(history.current_state.editor != null);
    try testing.expect(history.current_state.editor.?.campaign_mission == null);
    try testing.expect(history.current_state.campaign_editor == null);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.editor.?.campaign_mission != null);
    try testing.expect(history.current_state.campaign_editor != null);
}

test "the drill-in mission editor's validation run keeps the campaign context" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The run's fixture: a saved single-level mission (start_validation
    // is file-based - mission.txt + level_1.txt + player.txt).
    try harness.file_source.writeFile("missions/runfixture/mission.txt",
        \\Metadata
        \\file_format_version 3
        \\mission_uuid 44444444-4444-4444-4444-444444444444
        \\name Run Fixture
        \\
    );
    try harness.file_source.writeFile("missions/runfixture/level_1.txt",
        \\Metadata
        \\file_format_version 1
        \\name Run Fixture Level
        \\
        \\Layout
        \\!=
        \\
    );
    try harness.file_source.writeFile("missions/runfixture/player.txt",
        \\Metadata
        \\file_format_version 2
        \\
        \\MainHandWeapon
        \\
        \\OffHandWeapon
        \\
        \\Amulet
        \\
        \\Coat
        \\
        \\Gloves
        \\
        \\Pants
        \\
        \\Boots
        \\
        \\UtilitySkills
        \\
    );

    // A local campaign whose single mission is never-saved (the
    // fresh-template hand-off - no uuid, so the OPEN reads no files).
    var history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Local",
            .campaign_uuid = "cu",
            .campaign_dir = "campaigns/local",
            .start_hub = 0,
            .hubs = &.{.{ .handle = 0, .name = "Alpha", .position = .{ .x = 0, .y = 0 } }},
            .missions = &.{.{ .handle = 3, .dir = "New Mission", .name = "Draft", .start = 0, .destination = 0 }},
            .next_handle = 4,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // The hand-off: the fresh-template branch (mission_path null), the
    // campaign context live on the editor payload.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_mission_editor = .{
            .mission = 3,
            .mission_path = null,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .editor);
    try testing.expect(history.current_state.editor.?.campaign_mission != null);
    try testing.expect(history.current_state.campaign_editor != null);

    // The validation run: start_validation reads the fixture files and
    // transitions to the level screen - the authored campaign graph
    // SURVIVES the run's level scope (the .level scope carries
    // campaign_editor, the same reasoning as its editor carry).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .start_validation = .{
            .mission_path = "missions/runfixture",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .level);
    try testing.expect(history.current_state.campaign_editor != null);

    // End the begun turn + complete the (single) level: the run ends -
    // back on the mission editor with the campaign context intact (the
    // 5b save belt + the world-map return work again).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .end_level = .{} } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .editor);
    try testing.expect(history.current_state.editor.?.mode == .edit);
    try testing.expect(history.current_state.editor.?.campaign_mission != null);
    try testing.expect(history.current_state.campaign_editor != null);
}

test "mission editor hand-off: a never-saved mission opens the fresh template at the campaign anchor" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A local campaign dir with a never-saved mission (no uuid, the
    // temp anchor dir).
    var history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Local",
            .campaign_uuid = "cu",
            .campaign_dir = "campaigns/local",
            .start_hub = 0,
            .hubs = &.{.{
                .handle = 0,
                .name = "Alpha",
                .position = .{ .x = 0, .y = 0 },
                .grid = .{
                    .level_tiles = &.{.{ .x = 0, .y = 0 }},
                    .player_start = .{ .x = 0, .y = 0 },
                },
            }},
            .missions = &.{.{ .handle = 3, .dir = "New Mission", .name = "Renamed On Map", .start = 0, .destination = 0 }},
            .next_handle = 4,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);
    const campaign_editor_io = @import("campaign_editor/io.zig");

    // The input layer: a never-saved mission has no path (the
    // fresh-template signal).
    const campaign = history.current_state.campaign_editor.?;
    try testing.expect(campaign_editor_io.campaignMissionEditorPath(
        &history,
        campaign,
        campaign.missions[0],
        backing.allocator(),
    ) == null);

    // The hand-off: the fresh template at the campaign's missions/
    // anchor, the GRAPH's name adopted (a map rename that was never
    // full-saved beats the would-be file name).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_mission_editor = .{
            .mission = 3,
            .mission_path = null,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(state.Screen.editor, history.current_state.screen);
    const editor = history.current_state.editor orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 3), editor.campaign_mission.?);
    try testing.expectEqualStrings("Renamed On Map", editor.mission.name);
    try testing.expectEqualStrings("campaigns/local/missions/New Mission", editor.mission.path);
    try testing.expectEqual(@as(usize, 1), editor.levels.len);
}

test "mission editor hand-off save: campaign-context ctrl+S writes into the campaign, the full save never clobbers it" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    const campaign_editor_io = @import("campaign_editor/io.zig");
    const mission_io = @import("editor/mission_io.zig");
    const editor_handlers_mod = @import("editor/handlers.zig");
    const file_source_mod = @import("file_source.zig");

    // A FRESH campaign (no dir) with one hub + one never-saved mission.
    var history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Fresh",
            .start_hub = 0,
            .hubs = &.{.{
                .handle = 0,
                .name = "Alpha",
                .position = .{ .x = 0, .y = 0 },
                .grid = .{
                    .level_tiles = &.{.{ .x = 0, .y = 0 }},
                    .player_start = .{ .x = 0, .y = 0 },
                },
            }},
            .missions = &.{.{ .handle = 3, .dir = "New Mission", .name = "First Steps", .start = 0, .destination = 0 }},
            .next_handle = 4,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // The hand-off: the fresh-template branch.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_mission_editor = .{
            .mission = 3,
            .mission_path = null,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.editor.?.campaign_mission != null);

    // Author content in the hand-off: paint a tile (a level the
    // default template does not have) + rename the mission (the
    // dual-write path).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_tile = .{
            .level_index = 0,
            .position = .{ .x = 5, .y = 5 },
            .is_floor = true,
        } } }},
        history.current_arena.allocator(),
    );
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_mission_name = .{
            .name = "First Steps Renamed",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The dual-write: the campaign graph's entry tracks the editor's
    // rename (both live).
    {
        var graph_name: ?[]const u8 = null;
        for (history.current_state.campaign_editor.?.missions) |mission| {
            if (mission.handle == 3) graph_name = mission.name;
        }
        try testing.expectEqualStrings("First Steps Renamed", graph_name.?);
    }

    // The campaign-context save: the identity self-serves (the campaign
    // mints HERE), the mission lands under the campaign's missions/,
    // and the mission memo records (the full save resolves the same
    // identity in place).
    const saved_dir = mission_io.saveEditorMission(&history);
    try testing.expect(saved_dir != null);
    try testing.expect(history.session.pending_error == null);
    const campaign_memo = campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?;
    const campaign_dir = try arena.dupe(u8, campaign_memo.dir);
    try testing.expect(std.mem.startsWith(u8, campaign_dir, "campaigns/"));
    const mission_memo = campaign_editor_io.campaignSaveMemoFor(&history, 3).?;
    const mission_uuid = try arena.dupe(u8, mission_memo.uuid);
    const mission_dir_name = try arena.dupe(u8, mission_memo.dir);
    try testing.expect(std.mem.startsWith(u8, mission_dir_name, mission_uuid));
    try testing.expectEqualStrings(
        saved_dir.?,
        try std.fmt.allocPrint(arena, "{s}/missions/{s}", .{ campaign_dir, mission_dir_name }),
    );
    // The written files: mission.txt (the rich projection - the graph
    // name via the dual-write), player.txt, and the AUTHORED level_1.
    try testing.expect(file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/mission.txt", .{saved_dir.?}),
    ));
    try testing.expect(file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/player.txt", .{saved_dir.?}),
    ));
    const saved_level = try harness.file_source.readFile(
        arena,
        try std.fmt.allocPrint(arena, "{s}/level_1.txt", .{saved_dir.?}),
    );
    try testing.expect(std.mem.indexOf(u8, saved_level, "Layout") != null);

    // The full save: campaign.txt lands, the mission keeps its memo
    // identity (no re-mint), and the AUTHORED level is not clobbered
    // with the default template (the memo-existence skip) - the
    // hand-off's own level_1 (with the painted 5 5 tile) survives.
    _ = campaign_editor_io.saveCampaignEditor(&history);
    try testing.expect(history.session.pending_error == null);
    try testing.expect(file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/campaign.txt", .{campaign_dir}),
    ));
    const mission_memo_after = campaign_editor_io.campaignSaveMemoFor(&history, 3).?;
    try testing.expectEqualStrings(mission_uuid, mission_memo_after.uuid);
    const full_saved_level = try harness.file_source.readFile(
        arena,
        try std.fmt.allocPrint(arena, "{s}/level_1.txt", .{saved_dir.?}),
    );
    try testing.expectEqualStrings(saved_level, full_saved_level);

    // The map-rename sync (the regression a lean-write skip would
    // break): return from the hand-off, rename ON THE MAP, full save -
    // mission.txt carries the map's name (the graph is the sole
    // name-editing site once the payload is gone; the load
    // denormalizes the name FROM mission.txt).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .close_mission_editor = {} } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_set_mission_name = .{
            .mission = 3,
            .name = "Map Rename",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    _ = campaign_editor_io.saveCampaignEditor(&history);
    const mission_txt = try harness.file_source.readFile(
        arena,
        try std.fmt.allocPrint(arena, "{s}/mission.txt", .{saved_dir.?}),
    );
    {
        const sections = try parser.parseConfigFile(mission_txt, arena, &parser.mission_sections);
        const loaded = try @import("loaders.zig").loadMission(sections, arena);
        try testing.expectEqualStrings("Map Rename", loaded.name);
        try testing.expectEqualStrings(mission_uuid, loaded.uuid);
    }
    _ = editor_handlers_mod;
}

test "mission editor hand-off save: an official-origin campaign forks at the hand-off save" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    const campaign_editor_io = @import("campaign_editor/io.zig");
    const mission_io = @import("editor/mission_io.zig");
    const file_source_mod = @import("file_source.zig");

    // Open the REAL official campaign (dir derived - authored content,
    // never pinned), hand off its first mission.
    const official_campaign_dir = test_harness.officialCampaignDir(arena);
    var history = harness.newHistory(null);
    runToIdle(&history);
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = official_campaign_dir,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const opened = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
    const official_mission = opened.missions[0];
    const official_uuid = try arena.dupe(u8, official_mission.uuid);

    const mission_path = campaign_editor_io.campaignMissionEditorPath(
        &history,
        opened,
        official_mission,
        arena,
    ).?;
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_mission_editor = .{
            .mission = official_mission.handle,
            .mission_path = mission_path,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The hand-off save FORKS: a fresh campaign identity (the official
    // dir is embedded + read-only), the root carry lands the opened
    // dir's files under the fork (derived set - background PNGs when
    // shipped), and the mission re-homes with a FRESH uuid (the
    // official identity never shadows - the campaign-editor fork rule).
    const saved_dir = mission_io.saveEditorMission(&history);
    try testing.expect(saved_dir != null);
    try testing.expect(history.session.pending_error == null);
    const campaign_memo = campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?;
    const fork_dir = try arena.dupe(u8, campaign_memo.dir);
    try testing.expect(!std.mem.eql(u8, fork_dir, official_campaign_dir));
    try testing.expect(std.mem.startsWith(u8, saved_dir.?, fork_dir));
    const carried_root_files = try harness.file_source.listDirFiles(arena, official_campaign_dir);
    defer file_source_mod.freeDirFiles(arena, carried_root_files);
    for (carried_root_files) |file_name| {
        // The hand-off's root carry is MINUS campaign.txt (a carried one
        // would make the half-born fork list - asserted invisible below).
        if (std.mem.eql(u8, file_name, "campaign.txt")) continue;
        try testing.expect(file_source_mod.persistentFileExists(
            &harness.file_source,
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ fork_dir, file_name }),
        ));
    }
    const mission_memo = campaign_editor_io.campaignSaveMemoFor(&history, official_mission.handle).?;
    try testing.expect(!std.mem.eql(u8, mission_memo.uuid, official_uuid));
    try testing.expect(std.mem.startsWith(u8, saved_dir.?, try std.fmt.allocPrint(
        arena,
        "{s}/missions/",
        .{fork_dir},
    )));

    // The official campaign's own files stay embedded-only.
    try testing.expect(!file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/campaign.txt", .{official_campaign_dir}),
    ));

    // The fork stays INVISIBLE after the hand-off save: no campaign.txt
    // until the full save (the in-place gate on the graph write - a dir
    // without a readable campaign.txt never lists).
    try testing.expect(!file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/campaign.txt", .{fork_dir}),
    ));
}

test "campaign export + import: the zip round trip through exported_campaigns/ and the marker poll" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    const campaign_editor_io = @import("campaign_editor/io.zig");
    const file_source_mod = @import("file_source.zig");
    const zip_reader = @import("zip_reader.zig");

    // A fresh campaign with one hub + one hand-off-saved mission (the
    // full save materializes everything persistently).
    var history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "Zipped",
            .start_hub = 0,
            .hubs = &.{.{
                .handle = 0,
                .name = "Alpha",
                .position = .{ .x = 0, .y = 0 },
                .grid = .{
                    .level_tiles = &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } },
                    .player_start = .{ .x = 0, .y = 0 },
                },
            }},
            .missions = &.{.{ .handle = 3, .dir = "New Mission", .name = "One", .start = 0, .destination = 0 }},
            .next_handle = 4,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);
    _ = campaign_editor_io.saveCampaignEditor(&history);
    try testing.expect(history.session.pending_error == null);
    const campaign_memo = campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?;
    const campaign_uuid = try arena.dupe(u8, campaign_memo.uuid);

    // The export: the full save runs again (idempotent), then the whole
    // campaign dir bundles into exported_campaigns/<uuid>_<name>.zip.
    campaign_editor_io.exportCampaignEditor(&history);
    try testing.expect(history.session.pending_error == null);
    const zip_path = try std.fmt.allocPrint(arena, "exported_campaigns/{s}_Zipped.zip", .{campaign_uuid});
    const zip_bytes = try harness.file_source.readFile(arena, zip_path);
    {
        const headers = try zip_reader.readZipEntryHeaders(zip_bytes, arena);
        var has_campaign_txt = false;
        var has_hub_txt = false;
        var has_mission_txt = false;
        for (headers) |header| {
            if (std.mem.eql(u8, header.name, "campaign.txt")) has_campaign_txt = true;
            if (std.mem.endsWith(u8, header.name, "hub.txt")) has_hub_txt = true;
            if (std.mem.endsWith(u8, header.name, "/mission.txt")) has_mission_txt = true;
            // The archive names are the campaign's own content paths
            // minus the campaign dir prefix.
            try testing.expect(!std.mem.startsWith(u8, header.name, "campaigns/"));
        }
        try testing.expect(has_campaign_txt);
        try testing.expect(has_hub_txt);
        try testing.expect(has_mission_txt);
    }

    // The import: a fresh harness (a clean persistent dir), the zip
    // staged + the marker naming it - the poll extracts into campaigns/
    // and the rescan shows the row.
    var harness2 = Harness.init(backing.allocator());
    var history2 = harness2.newHistory(null);
    runToIdle(&history2);
    try harness2.file_source.writeFile("imported_campaigns/picked.zip", zip_bytes);
    try harness2.file_source.writeFile(file_source_mod.campaign_import_marker_path, "imported_campaigns/picked.zip");
    campaign_editor_io.pollCampaignImportMarker(&history2);
    try testing.expect(history2.session.pending_error == null);
    const imported_dir = try std.fmt.allocPrint(arena, "campaigns/{s}_Zipped", .{campaign_uuid});
    try testing.expect(file_source_mod.persistentFileExists(
        &harness2.file_source,
        try std.fmt.allocPrint(arena, "{s}/campaign.txt", .{imported_dir}),
    ));
    const local_campaigns = try harness2.file_source.listCampaigns(arena);
    try testing.expectEqual(@as(usize, 1), local_campaigns.len);
    try testing.expectEqualStrings(imported_dir, local_campaigns[0].dir);
    // The rescan populated the browser's session list.
    try testing.expectEqual(@as(usize, 1), history2.session.campaign_browser_local.len);

    // The marker is consumed (a second poll no-ops).
    campaign_editor_io.pollCampaignImportMarker(&history2);
    try testing.expect(history2.session.pending_error == null);
}

test "campaign import: an OS-wrapped zip strips the root folder; a re-import is idempotent" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    const campaign_editor_io = @import("campaign_editor/io.zig");
    const file_source_mod = @import("file_source.zig");
    const zip_writer = @import("zip_writer.zig");

    // A hand-built campaign zip wrapped in a single root folder (the OS
    // "compress folder" shape) - the exported-zip counterpart with the
    // same identity.
    var entries: std.ArrayList(zip_writer.ZipEntry) = .empty;
    try entries.append(arena, .{
        .name = "My Campaign/campaign.txt",
        .bytes = "Metadata\nfile_format_version 5\nname Wrapped\ncampaign_uuid cu-wrapped\nstart_hub hu\n\nHubs\n\nhub_uuid hu\nposition 0 0\n",
    });
    try entries.append(arena, .{
        .name = "My Campaign/hubs/h/hub.txt",
        .bytes = "Metadata\nfile_format_version 5\nname Home\nhub_uuid hu\n\nLayout 1\n!\n",
    });
    const archive = try zip_writer.writeZipArchive(entries.items, arena);

    var history = harness.newHistory(null);
    runToIdle(&history);
    try harness.file_source.writeFile("imported_campaigns/wrapped.zip", archive);
    try harness.file_source.writeFile(file_source_mod.campaign_import_marker_path, "imported_campaigns/wrapped.zip");
    campaign_editor_io.pollCampaignImportMarker(&history);
    try testing.expect(history.session.pending_error == null);
    const imported_dir = "campaigns/cu-wrapped_Wrapped";
    try testing.expect(file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/campaign.txt", .{imported_dir}),
    ));
    try testing.expect(file_source_mod.persistentFileExists(
        &harness.file_source,
        try std.fmt.allocPrint(arena, "{s}/hubs/h/hub.txt", .{imported_dir}),
    ));

    // The re-import of the same zip: the same target dir, idempotent
    // (never a second dir, never refused).
    try harness.file_source.writeFile("imported_campaigns/wrapped2.zip", archive);
    try harness.file_source.writeFile(file_source_mod.campaign_import_marker_path, "imported_campaigns/wrapped2.zip");
    campaign_editor_io.pollCampaignImportMarker(&history);
    try testing.expect(history.session.pending_error == null);
    const local_campaigns = try harness.file_source.listCampaigns(arena);
    try testing.expectEqual(@as(usize, 1), local_campaigns.len);
    try testing.expectEqualStrings(imported_dir, local_campaigns[0].dir);
}

test "saveCampaignEditor: the campaign root follows the campaign name (cosmetic dir tidy)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const campaign_uuid = "11111111-2222-3333-4444-555555555555";
    const old_dir = "campaigns/11111111-2222-3333-4444-555555555555_Old Name";
    const new_dir = "campaigns/11111111-2222-3333-4444-555555555555_New Name";

    // Seed the persistent tier with the campaign under its OLD name. The
    // file's CONTENT doesn't matter here (the save writes from state) -
    // its EXISTENCE is what routes the identity resolution in-place
    // instead of minting a fork.
    const file_source_mod = @import("file_source.zig");
    const seeded_campaign = "Metadata\nfile_format_version 5\nname Old Name\n";
    harness.file_source.writeFile("campaigns/11111111-2222-3333-4444-555555555555_Old Name/campaign.txt", seeded_campaign) catch
        @panic("seed write failed");

    var history = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "New Name",
            .campaign_uuid = campaign_uuid,
            .campaign_dir = old_dir,
            .start_hub = 0,
            .hubs = &.{
                .{
                    .handle = 0,
                    .name = "Alpha",
                    .position = .{ .x = 0, .y = 0 },
                    .grid = .{
                        .level_tiles = &.{.{ .x = 0, .y = 0 }},
                        .player_start = .{ .x = 0, .y = 0 },
                    },
                },
            },
            .missions = &.{},
            .decoration_types = &.{},
            .next_handle = 1,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    const campaign_editor_io = @import("campaign_editor/io.zig");
    const saved_dir = campaign_editor_io.saveCampaignEditor(&history) orelse {
        if (history.session.pending_error) |error_message| {
            std.debug.print("SAVE ERROR: {s}\n", .{error_message});
        }
        return error.SaveFailed;
    };

    // The root followed the rename: the save reports the NEW dir, the
    // old one is gone, and campaign.txt inside carries the new name.
    try testing.expectEqualStrings(new_dir, saved_dir);
    try testing.expect(!file_source_mod.persistentFileExists(history.file_source, old_dir ++ "/campaign.txt"));
    try testing.expect(file_source_mod.persistentFileExists(history.file_source, new_dir ++ "/campaign.txt"));
    const saved_txt = history.file_source.readFile(backing.allocator(), new_dir ++ "/campaign.txt") catch
        return error.CouldNotReadSavedCampaign;
    try testing.expect(std.mem.indexOf(u8, saved_txt, "name New Name\n") != null);

    // The session continues under the RENAMED dir (the memo carries it
    // forward - last-wins, the fork memo's rule; the state still holds
    // the original dir).
    const memo = campaign_editor_io.campaignSaveMemoFor(&history, types.campaign_save_memo_handle).?;
    try testing.expectEqualStrings(new_dir, memo.dir);
    try testing.expectEqualStrings(campaign_uuid, memo.uuid);

    // A SECOND save resolves the memo (no further rename - the dir is
    // already canonical) and stays in place.
    const second_dir = campaign_editor_io.saveCampaignEditor(&history) orelse return error.SaveFailed;
    try testing.expectEqualStrings(new_dir, second_dir);
    try testing.expect(file_source_mod.persistentFileExists(history.file_source, new_dir ++ "/campaign.txt"));

    // The collision rule: a sibling campaign already owning the canonical
    // target keeps the old dir (no rename, no data loss) - the
    // duplicate-uuid sibling rule's mirror at the campaign root.
    const colliding_uuid = "99999999-8888-7777-6666-000000000000";
    const colliding_dir = "campaigns/99999999-8888-7777-6666-000000000000_New Name";
    harness.file_source.writeFile("campaigns/99999999-8888-7777-6666-000000000000_New Name/campaign.txt", seeded_campaign) catch
        @panic("seed write failed");
    var history2 = harness.newHistory(.{
        .screen = .campaign_editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .campaign_editor = .{
            .campaign_name = "New Name",
            .campaign_uuid = colliding_uuid,
            .campaign_dir = "campaigns/99999999-8888-7777-6666-000000000000_Other Name",
            .start_hub = 0,
            .hubs = &.{
                .{
                    .handle = 0,
                    .name = "Alpha",
                    .position = .{ .x = 0, .y = 0 },
                    .grid = .{
                        .level_tiles = &.{.{ .x = 0, .y = 0 }},
                        .player_start = .{ .x = 0, .y = 0 },
                    },
                },
            },
            .missions = &.{},
            .decoration_types = &.{},
            .next_handle = 1,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history2);
    // The opened dir must exist for the in-place branch.
    harness.file_source.writeFile("campaigns/99999999-8888-7777-6666-000000000000_Other Name/campaign.txt", seeded_campaign) catch
        @panic("seed write failed");
    const collision_saved = campaign_editor_io.saveCampaignEditor(&history2) orelse return error.SaveFailed;
    try testing.expectEqualStrings("campaigns/99999999-8888-7777-6666-000000000000_Other Name", collision_saved);
    try testing.expect(file_source_mod.persistentFileExists(history2.file_source, colliding_dir ++ "/campaign.txt"));
    try testing.expect(file_source_mod.persistentFileExists(history2.file_source, "campaigns/99999999-8888-7777-6666-000000000000_Other Name/campaign.txt"));
}

test "mission hand-off save: an in-place campaign's table references the persisted mission in the same save" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    const campaign_editor_io = @import("campaign_editor/io.zig");
    const mission_io = @import("editor/mission_io.zig");

    // A seeded PERSISTENT campaign (listed: campaign.txt present) with one
    // hub and NO missions. The hub dir + hub.txt keep the hub's identity
    // in-place at the graph write (resolveContentIdentity's
    // persistent-config rule).
    const campaign_uuid = "aaaaaaa1-0000-0000-0000-000000000001";
    const hub_uuid = "hhhhhhh1-0000-0000-0000-000000000001";
    harness.file_source.writeFile("campaigns/inplace_test/campaign.txt",
        \\Metadata
        \\file_format_version 5
        \\name Inplace Test
        \\campaign_uuid aaaaaaa1-0000-0000-0000-000000000001
        \\start_hub hhhhhhh1-0000-0000-0000-000000000001
        \\
        \\Hubs
        \\hub_uuid hhhhhhh1-0000-0000-0000-000000000001
        \\position 0 0
        \\
    ) catch @panic("seed campaign write failed");
    harness.file_source.writeFile("campaigns/inplace_test/hubs/hhhhhhh1-0000-0000-0000-000000000001_Seed Hub/hub.txt",
        \\Metadata
        \\file_format_version 5
        \\name Seed Hub
        \\hub_uuid hhhhhhh1-0000-0000-0000-000000000001
        \\
        \\Layout 2
        \\.!
        \\..
        \\
    ) catch @panic("seed hub write failed");

    var history = harness.newHistory(null);
    runToIdle(&history);
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_campaign_editor = .{
            .campaign_dir = "campaigns/inplace_test",
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    if (history.session.pending_error) |error_message| {
        std.debug.print("OPEN ERROR: {s}\n", .{error_message});
        return error.TestUnexpectedResult;
    }
    const opened = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
    const hub_handle = opened.hubs[0].handle;

    // The motivating authoring flow's live half: place a FRESH mission
    // edge (no identity yet - it mints at the save), then hand off to
    // the mission editor (the fresh-template branch, no mission_path).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .campaign_editor_event = .{ .editor_campaign_place_mission = .{
            .start = hub_handle,
            .destination = hub_handle,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const campaign_now = history.current_state.campaign_editor orelse return error.TestUnexpectedResult;
    const placed_handle = campaign_now.missions[0].handle;
    try testing.expect(campaign_now.missions[0].uuid.len == 0);

    event_push.pushPlayerAction(
        &history.current_state,
        .{ .open_mission_editor = .{
            .mission = placed_handle,
            .mission_path = null,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    if (history.session.pending_error) |error_message| {
        std.debug.print("HAND-OFF OPEN ERROR: {s}\n", .{error_message});
        return error.TestUnexpectedResult;
    }

    // The hand-off save: the mission dir lands under the OPENED campaign,
    // and the table write must reference it in the SAME save.
    const saved_dir = mission_io.saveEditorMission(&history);
    try testing.expect(saved_dir != null);
    try testing.expect(history.session.pending_error == null);
    try testing.expect(std.mem.startsWith(u8, saved_dir.?, "campaigns/inplace_test/missions/"));

    const mission_memo = campaign_editor_io.campaignSaveMemoFor(&history, placed_handle).?;
    const mission_uuid = try arena.dupe(u8, mission_memo.uuid);
    try testing.expect(std.mem.indexOf(u8, saved_dir.?, mission_uuid) != null);

    const campaign_txt = history.file_source.readFile(arena, "campaigns/inplace_test/campaign.txt") catch
        return error.CouldNotReadCampaign;
    const mission_reference = try std.fmt.allocPrint(arena, "mission_uuid {s}", .{mission_uuid});
    try std.testing.expect(std.mem.indexOf(u8, campaign_txt, mission_reference) != null);
    // The hub stayed IN-PLACE (its seeded identity - no re-mint).
    const hub_reference = try std.fmt.allocPrint(arena, "hub_uuid {s}", .{hub_uuid});
    try std.testing.expect(std.mem.indexOf(u8, campaign_txt, hub_reference) != null);
    // The campaign identity is the seeded one (no fork).
    try std.testing.expect(std.mem.indexOf(u8, campaign_txt, campaign_uuid) != null);
}
