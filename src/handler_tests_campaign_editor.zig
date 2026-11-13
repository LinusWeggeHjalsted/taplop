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
