//! Handler-drain tests for ACTING FROM THE WORLD MAP (campaign-editor
//! slice 2d, same-campaign): `player_travel_to_hub` (backtrack to a
//! discovered hub) + `player_start_mission_from_map` (the exit-tile
//! equivalence - arrive at the edge's start hub, then enter), each from a
//! hub and mid-level (the abandon ride: end_level{.exit_mission} with the
//! destination override - pickups kept, no clone). See DESIGN → Campaigns
//! & the Campaign Editor → Discovery + travel. Tier B (the harness): the
//! fixture campaign is written into the scratch persistent dir, entered
//! via player_continue (the load reads it through the reconstruction
//! cache), and the orchestrators are pushed as recorded player actions.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");
const event_push = @import("event_push.zig");
const event_handlers = @import("event_handlers.zig");
const input_handlers = @import("input_handlers.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;

/// The fixture campaign's identity + graph, mirrored in the files the
/// helper writes below. Two hubs (A = start, B = a mission destination)
/// + one mission with an A->B edge - the minimum that exercises
/// hub-to-hub travel (the official campaign is a single hub).
const hub_a_uuid = "aaaaaaaa-0000-0000-0000-000000000001";
const hub_b_uuid = "bbbbbbbb-0000-0000-0000-000000000002";
const campaign_uuid = "cccccccc-0000-0000-0000-000000000003";
const mission_uuid = "dddddddd-0000-0000-0000-000000000004";
const mission_path = "campaigns/test_campaign/missions/m1";

/// Write the fixture campaign's files under `campaigns/<campaign_dir>/`
/// (dir-parameterized: the resume tests exercise uuid-only resolution,
/// which must not care what the dir is named - the editor's cosmetic
/// dir tidy can rename it at any save).
fn writeFixtureCampaignAt(history: *state.GameStateHistory, campaign_dir: []const u8) void {
    const fs = history.file_source;
    const allocator = history.current_arena.allocator();
    const campaign_path = std.fmt.allocPrint(allocator, "campaigns/{s}/campaign.txt", .{campaign_dir}) catch
        @panic("failed to build fixture campaign path");
    fs.writeFile(
        campaign_path,
        "Metadata\nfile_format_version 5\nname Test Campaign\ncampaign_uuid " ++ campaign_uuid ++ "\nstart_hub " ++ hub_a_uuid ++ "\n\nHubs\n\nhub_uuid " ++ hub_a_uuid ++ "\nposition 0 0\n\nhub_uuid " ++ hub_b_uuid ++ "\nposition 900 0\n\nMissions\n\nmission_uuid " ++ mission_uuid ++ "\nstart_hub " ++ hub_a_uuid ++ "\ndestination_hub " ++ hub_b_uuid ++ "\n",
    ) catch @panic("write fixture campaign");
    const hub_a_path = std.fmt.allocPrint(allocator, "campaigns/{s}/hubs/hub_a/hub.txt", .{campaign_dir}) catch
        @panic("failed to build fixture hub a path");
    fs.writeFile(
        hub_a_path,
        "Metadata\nfile_format_version 5\nhub_uuid " ++ hub_a_uuid ++ "\nname Hub A\n\nLayout 3\n...\n.!E\n...\n\nExits\ncharacter_code E\nmission_uuid " ++ mission_uuid ++ "\n",
    ) catch @panic("write fixture hub a");
    const hub_b_path = std.fmt.allocPrint(allocator, "campaigns/{s}/hubs/hub_b/hub.txt", .{campaign_dir}) catch
        @panic("failed to build fixture hub b path");
    fs.writeFile(
        hub_b_path,
        "Metadata\nfile_format_version 5\nhub_uuid " ++ hub_b_uuid ++ "\nname Hub B\n\nLayout 3\n...\n.!.\n...\n",
    ) catch @panic("write fixture hub b");
    const mission_path_at_dir = std.fmt.allocPrint(allocator, "campaigns/{s}/missions/m1/mission.txt", .{campaign_dir}) catch
        @panic("failed to build fixture mission path");
    fs.writeFile(
        mission_path_at_dir,
        "Metadata\nfile_format_version 3\nmission_uuid " ++ mission_uuid ++ "\nname Map Mission\n",
    ) catch @panic("write fixture mission");
    const level_path = std.fmt.allocPrint(allocator, "campaigns/{s}/missions/m1/level_1.txt", .{campaign_dir}) catch
        @panic("failed to build fixture level path");
    fs.writeFile(
        level_path,
        "Metadata\nfile_format_version 2\n\nLayout 1\n!=\n",
    ) catch @panic("write fixture level");
}

/// Write the fixture campaign into the history's scratch persistent dir
/// (readFile resolves persistent-first, so it shadows nothing embedded)
/// and enter it: player_continue with the campaign identity populated
/// runs loadCampaignAndPushHub -> start_hub{A} -> discovered A. Returns
/// with the session in hub A.
fn enterFixtureCampaign(history: *state.GameStateHistory) void {
    writeFixtureCampaignAt(history, "test_campaign");

    history.current_state.player_data.current_campaign_uuid = campaign_uuid;
    history.current_state.player_data.current_hub = hub_a_uuid;
    event_push.pushPlayerAction(
        &history.current_state,
        .player_continue,
        history.current_arena.allocator(),
    );
    runToIdle(history);
}

test "player_continue resolves the campaign uuid by scan - the dir name never rides the save" {
    // The rename-regression shape: a save written while the campaign dir
    // carried one name resumes fine after the editor's cosmetic dir tidy
    // renamed it - PlayerData carries identity only, and the resume scan
    // resolves the uuid (DESIGN → Campaigns & the Campaign Editor →
    // Uuid→dir resolution).
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    writeFixtureCampaignAt(&history, "renamed_after_save");

    history.current_state.player_data.current_campaign_uuid = campaign_uuid;
    history.current_state.player_data.current_hub = hub_a_uuid;
    event_push.pushPlayerAction(
        &history.current_state,
        .player_continue,
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(state.Screen.hub, history.current_state.screen);
    try testing.expectEqualStrings("renamed_after_save", history.current_state.campaign.?.dir);
    try testing.expectEqualStrings("Hub A", history.current_state.hub.?.name);
    try testing.expectEqualStrings(campaign_uuid, history.current_state.player_data.current_campaign_uuid);
}

test "player_continue with an uninstalled campaign uuid is the recoverable popup" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);

    history.current_state.player_data.current_campaign_uuid = "eeeeeeee-0000-0000-0000-000000000009";
    history.current_state.player_data.current_hub = hub_a_uuid;
    event_push.pushPlayerAction(
        &history.current_state,
        .player_continue,
        history.current_arena.allocator(),
    );
    // Drain manually, stopping on load_error (runToIdle would panic - it
    // asserts no load_error for valid test content; the autosave test's
    // drain-loop shape).
    while (history.current_state.event_stack.len > 0) {
        event_handlers.processEvent(&history);
        if (history.load_error) break;
    }

    try testing.expect(history.load_error);
    try testing.expect(history.session.pending_error != null);
    try testing.expect(std.mem.indexOf(u8, history.session.pending_error.?, "not installed") != null);
    // No campaign installed, no screen transition - the revert-ready state.
    try testing.expect(history.current_state.campaign == null);
    try testing.expect(history.current_state.hub == null);
}

/// The discovery route for hub B in tests: the machinery start_hub (what
/// mission completion pushes - arrival IS discovery). Tests push it
/// directly to stand in for a completed A->B edge.
fn discoverHubB(history: *state.GameStateHistory) void {
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .start_hub = .{
            .hub_id = hub_b_uuid,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(history);
}

/// Push one map-acting orchestrator as the recorded player action (the
/// live click path's shape) + drain.
fn pushMapAction(
    history: *state.GameStateHistory,
    action: events.PlayerInputEvent,
) void {
    event_push.pushPlayerAction(&history.current_state, action, history.current_arena.allocator());
    runToIdle(history);
}

test "map travel: backtrack to a discovered hub from a hub" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    enterFixtureCampaign(&history);
    try testing.expectEqual(state.Screen.hub, history.current_state.screen);
    try testing.expectEqualStrings(hub_a_uuid, history.current_state.player_data.current_hub);

    // Standing at B (discovered via the mission-completion route), the
    // map opens over the hub; travel back to A (discovered - backtrack
    // legal) lands the session in A's hub content.
    discoverHubB(&history);
    history.current_state.ui_surfaces.openSurface(.world_map);
    pushMapAction(&history, .{ .player_travel_to_hub = .{
        .hub_uuid = hub_a_uuid,
    } });

    try testing.expectEqual(state.Screen.hub, history.current_state.screen);
    try testing.expectEqualStrings(hub_a_uuid, history.current_state.player_data.current_hub);
    try testing.expectEqualStrings("Hub A", history.current_state.hub.?.name);
    // The arrival is on the undo timeline (one click = one undo step
    // back to hub B).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings(hub_b_uuid, history.current_state.player_data.current_hub);
}

test "map travel mid-level rides the abandon cascade to the target hub" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    enterFixtureCampaign(&history);
    discoverHubB(&history);

    // Mid-level (entered from the map at B - the mission-entry arm under
    // test below): travel to A abandons the run and lands at A. No clone
    // (the clone is the record of COMPLETED runs) + the start hub's
    // discovery survives (arrival is idempotent).
    pushMapAction(&history, .{ .player_start_mission_from_map = .{
        .mission_path = mission_path,
        .end_hub_id = hub_a_uuid,
        .start_hub_id = hub_b_uuid,
    } });
    try testing.expectEqual(state.Screen.level, history.current_state.screen);
    try testing.expect(history.current_state.mission != null);

    pushMapAction(&history, .{ .player_travel_to_hub = .{
        .hub_uuid = hub_a_uuid,
    } });
    try testing.expectEqual(state.Screen.hub, history.current_state.screen);
    try testing.expectEqualStrings(hub_a_uuid, history.current_state.player_data.current_hub);
    try testing.expectEqualStrings("Hub A", history.current_state.hub.?.name);
    try testing.expectEqual(@as(usize, 0), history.current_state.player_data.clones.len);
}

test "map mission entry from a hub: arrive at the edge's start hub, then enter" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    enterFixtureCampaign(&history);
    discoverHubB(&history);

    // Standing at B, clicking the A->B edge (start hub A): the handler
    // arrives at A first (current_hub on the way in - abandoning the
    // entered mission returns there), then enters the mission with the
    // edge's destination as its end hub.
    history.current_state.ui_surfaces.openSurface(.world_map);
    pushMapAction(&history, .{ .player_start_mission_from_map = .{
        .mission_path = mission_path,
        .end_hub_id = hub_b_uuid,
        .start_hub_id = hub_a_uuid,
    } });

    try testing.expectEqual(state.Screen.level, history.current_state.screen);
    try testing.expectEqualStrings(mission_path, history.current_state.mission.?.path);
    try testing.expectEqualStrings(hub_b_uuid, history.current_state.mission.?.end_hub.?);
    try testing.expectEqualStrings(hub_a_uuid, history.current_state.player_data.current_hub);
}

test "map mission entry mid-level: abandon + re-enter with a new edge" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    enterFixtureCampaign(&history);

    // Mid-level of the mission entered at A (a dangling edge's null end
    // hub the first time), re-entering from the map with the A->B edge:
    // the old run is abandoned (end_level{exit_mission} with the start
    // hub as the arrival), the new entry carries the new edge's
    // destination, and current_hub stays the edge's start hub throughout.
    pushMapAction(&history, .{ .player_start_mission_from_map = .{
        .mission_path = mission_path,
        .end_hub_id = null,
        .start_hub_id = hub_a_uuid,
    } });
    try testing.expectEqual(state.Screen.level, history.current_state.screen);
    try testing.expect(history.current_state.mission.?.end_hub == null);

    pushMapAction(&history, .{ .player_start_mission_from_map = .{
        .mission_path = mission_path,
        .end_hub_id = hub_b_uuid,
        .start_hub_id = hub_a_uuid,
    } });
    try testing.expectEqual(state.Screen.level, history.current_state.screen);
    try testing.expectEqualStrings(mission_path, history.current_state.mission.?.path);
    try testing.expectEqualStrings(hub_b_uuid, history.current_state.mission.?.end_hub.?);
    try testing.expectEqualStrings(hub_a_uuid, history.current_state.player_data.current_hub);
    try testing.expectEqual(@as(usize, 0), history.current_state.player_data.clones.len);
}

// --- cross-campaign acting (2d step 2) ---

/// A SECOND fixture campaign (never entered - no discovered group), so
/// the cross-campaign tests exercise entering a campaign whose only
/// act-legal hub is its start hub (the reconstruction-cache read).
const hub_x_uuid = "xxxxxxxx-0000-0000-0000-000000000005";
const hub_y_uuid = "yyyyyyyy-0000-0000-0000-000000000006";
const campaign2_uuid = "zzzzzzzz-0000-0000-0000-000000000007";
const mission2_path = "campaigns/second_campaign/missions/m2";

fn writeSecondCampaign(history: *state.GameStateHistory) void {
    const fs = history.file_source;
    fs.writeFile(
        "campaigns/second_campaign/campaign.txt",
        "Metadata\nfile_format_version 5\nname Second Campaign\ncampaign_uuid " ++ campaign2_uuid ++ "\nstart_hub " ++ hub_x_uuid ++ "\n\nHubs\n\nhub_uuid " ++ hub_x_uuid ++ "\nposition 0 0\n\nhub_uuid " ++ hub_y_uuid ++ "\nposition 900 0\n",
    ) catch @panic("write second campaign");
    fs.writeFile(
        "campaigns/second_campaign/hubs/hub_x/hub.txt",
        "Metadata\nfile_format_version 5\nhub_uuid " ++ hub_x_uuid ++ "\nname Hub X\n\nLayout 3\n...\n.!.\n...\n",
    ) catch @panic("write hub x");
    fs.writeFile(
        "campaigns/second_campaign/hubs/hub_y/hub.txt",
        "Metadata\nfile_format_version 5\nhub_uuid " ++ hub_y_uuid ++ "\nname Hub Y\n\nLayout 3\n...\n.!.\n...\n",
    ) catch @panic("write hub y");
    fs.writeFile(
        "campaigns/second_campaign/missions/m2/mission.txt",
        "Metadata\nfile_format_version 3\nmission_uuid eeeeeeee-0000-0000-0000-000000000008\nname Second Mission\n",
    ) catch @panic("write second mission");
    fs.writeFile(
        "campaigns/second_campaign/missions/m2/level_1.txt",
        "Metadata\nfile_format_version 2\n\nLayout 1\n!=\n",
    ) catch @panic("write second level");
}

test "cross-campaign travel: a never-entered campaign's start hub is act-legal" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    enterFixtureCampaign(&history);
    writeSecondCampaign(&history);

    // Standing in the FIRST campaign's hub A, acting on the second
    // campaign's start hub X (discovered NOWHERE - the campaign was
    // never entered; the legality read resolved the start hub from the
    // campaign.txt through the reconstruction cache in this session's
    // harness too, via the same read validatePlayerAction does):
    // the install switches the active campaign, the arrival discovers X
    // in the NEW campaign's group (arrival IS discovery), and the session
    // lands in X's hub content.
    history.current_state.ui_surfaces.openSurface(.world_map);
    pushMapAction(&history, .{ .player_travel_to_hub = .{
        .hub_uuid = hub_x_uuid,
        .campaign_uuid = campaign2_uuid,
        .campaign_dir = "second_campaign",
    } });

    try testing.expectEqual(state.Screen.hub, history.current_state.screen);
    try testing.expectEqualStrings(hub_x_uuid, history.current_state.player_data.current_hub);
    try testing.expectEqualStrings("second_campaign", history.current_state.campaign.?.dir);
    try testing.expectEqualStrings(campaign2_uuid, history.current_state.player_data.current_campaign_uuid);
    try testing.expectEqualStrings("Hub X", history.current_state.hub.?.name);
    // The arrival created the second campaign's discovered group.
    var found_group = false;
    for (history.current_state.player_data.discovered_hubs) |group| {
        if (!std.mem.eql(u8, group.campaign_uuid, campaign2_uuid)) continue;
        found_group = true;
        try testing.expectEqual(@as(usize, 1), group.hub_uuids.len);
        try testing.expectEqualStrings(hub_x_uuid, group.hub_uuids[0]);
    }
    try testing.expect(found_group);

    // Switching back: the FIRST campaign's start hub is act-legal for
    // the same reason (its start hub, not its discovered set - hub A is
    // also discovered there, but the point is the rule composes).
    pushMapAction(&history, .{ .player_travel_to_hub = .{
        .hub_uuid = hub_a_uuid,
        .campaign_uuid = campaign_uuid,
        .campaign_dir = "test_campaign",
    } });
    try testing.expectEqual(state.Screen.hub, history.current_state.screen);
    try testing.expectEqualStrings("test_campaign", history.current_state.campaign.?.dir);
    try testing.expectEqualStrings(hub_a_uuid, history.current_state.player_data.current_hub);
    try testing.expectEqualStrings("Hub A", history.current_state.hub.?.name);
}

test "cross-campaign mission entry: installs the campaign + enters from the edge's start hub" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    enterFixtureCampaign(&history);
    writeSecondCampaign(&history);

    // From the first campaign's hub, entering the second campaign's
    // mission via the map: the install switches the campaign, the entry's
    // enter hub (the edge's start hub X) becomes current_hub on the way
    // in, and the mission's end hub rides the payload (the Y edge).
    history.current_state.ui_surfaces.openSurface(.world_map);
    pushMapAction(&history, .{ .player_start_mission_from_map = .{
        .mission_path = mission2_path,
        .end_hub_id = hub_y_uuid,
        .start_hub_id = hub_x_uuid,
        .campaign_uuid = campaign2_uuid,
        .campaign_dir = "second_campaign",
    } });

    try testing.expectEqual(state.Screen.level, history.current_state.screen);
    try testing.expectEqualStrings(mission2_path, history.current_state.mission.?.path);
    try testing.expectEqualStrings(hub_y_uuid, history.current_state.mission.?.end_hub.?);
    try testing.expectEqualStrings(hub_x_uuid, history.current_state.player_data.current_hub);
    try testing.expectEqualStrings("second_campaign", history.current_state.campaign.?.dir);
}

test "map click path: hub button + edge button drive the recorded orchestrators" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    enterFixtureCampaign(&history);
    discoverHubB(&history);

    // The consumption arms resolve the click payload against the map's
    // rendered graph (the ACTIVE campaign here - no viewed cache), fire
    // the recorded orchestrator, and the cascade plays out as in the
    // direct tests above. Hub A (index 0) is discovered (the start hub)
    // + not the player's current hub, so the click travels.
    history.current_state.ui_surfaces.openSurface(.world_map);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .travel_to_map_hub,
    }, .{ .map_hub = 0 }, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expectEqual(state.Screen.hub, history.current_state.screen);
    try testing.expectEqualStrings(hub_a_uuid, history.current_state.player_data.current_hub);

    // The edge click: the payload is an index into the campaign's edge
    // table (populated by the fixture's A->B exit); the arm resolves the
    // mission path + end hub + start hub from it.
    history.current_state.ui_surfaces.openSurface(.world_map);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .start_mission_from_map_edge,
    }, .{ .map_edge = 0 }, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expectEqual(state.Screen.level, history.current_state.screen);
    try testing.expectEqualStrings(mission_path, history.current_state.mission.?.path);
    try testing.expectEqualStrings(hub_b_uuid, history.current_state.mission.?.end_hub.?);
    try testing.expectEqualStrings(hub_a_uuid, history.current_state.player_data.current_hub);
}

test "map travel mid-level to the entering hub: abandons + returns (not a no-op)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    enterFixtureCampaign(&history);

    // Enter the mission at A, then click hub A on the map: current_hub
    // names A but the player is IN THE MISSION, not at the hub - the
    // click is a real travel (abandon + return to A), never the standing-
    // at-the-hub no-op (the regression the hands-on pass caught: the
    // click sound fired, nothing happened).
    pushMapAction(&history, .{ .player_start_mission_from_map = .{
        .mission_path = mission_path,
        .end_hub_id = hub_b_uuid,
        .start_hub_id = hub_a_uuid,
    } });
    try testing.expectEqual(state.Screen.level, history.current_state.screen);

    history.current_state.ui_surfaces.openSurface(.world_map);
    pushMapAction(&history, .{ .player_travel_to_hub = .{
        .hub_uuid = hub_a_uuid,
    } });
    try testing.expectEqual(state.Screen.hub, history.current_state.screen);
    try testing.expectEqualStrings(hub_a_uuid, history.current_state.player_data.current_hub);
    try testing.expectEqualStrings("Hub A", history.current_state.hub.?.name);

    // Standing IN hub A, clicking hub A is the no-op (the input arm
    // returns before recording anything).
    const events_before = history.event_history.items.len;
    history.current_state.ui_surfaces.openSurface(.world_map);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .travel_to_map_hub,
    }, .{ .map_hub = 0 }, .{ .x = -4096, .y = -4096 }, &.{});
    try testing.expectEqual(events_before, history.event_history.items.len);
}
