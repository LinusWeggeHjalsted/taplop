//! Autosave handler tests. Covers the `player_continue` main-menu action
//! (populated vs empty PlayerData branches) and the autosave push on
//! `end_level` / `end_hub` (the write fires after the player-entity →
//! PlayerData sync, before the continuation). The disk-write itself
//! (`write_save` side effect) is `!replaying`-gated and not exercised here —
//! these tests inspect the event stack the orchestrators push, not the file
//! write, so they don't touch disk. See DESIGN → File System & IO (autosave).

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const events = @import("events.zig");
const event_handlers = @import("event_handlers.zig");
const state_mod = @import("state.zig");
const test_harness = @import("test_harness.zig");
const writers = @import("writers.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;
const Vector2 = types.Vector2;

const three_by_three = [_]Vector2{
    .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
    .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
    .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 },
};

// `player_continue` with populated PlayerData resumes directly from in-memory
// data — no file read. loadCampaignAndPushHub pushes start_hub, so after
// runToIdle the screen is the hub.
test "player_continue: populated PlayerData resumes at current_hub" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const start = test_harness.defaultStartingState();
    var history = harness.newHistory(start);
    // Populate PlayerData as if returning from a mid-session exit-to-menu.
    history.current_state.player_data.current_campaign = "main_campaign";
    history.current_state.player_data.current_hub = "camp_at_the_crossroads";
    runToIdle(&history);

    event_handlers.pushPlayerAction(
        &history.current_state,
        .player_continue,
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(state_mod.Screen.hub, history.current_state.screen);
    try testing.expect(history.current_state.hub != null);
}

// `player_continue` with empty PlayerData pushes `load_save` pointing at the
// autosave (the fresh-launch branch). We inspect the pushed stack rather than
// running to idle, since the autosave file doesn't exist in the test env and
// load_save would set load_error.
test "player_continue: empty PlayerData pushes load_save on the autosave" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    runToIdle(&history);

    event_handlers.pushPlayerAction(
        &history.current_state,
        .player_continue,
        history.current_arena.allocator(),
    );
    // Process the player_continue orchestrator; its handler pushes load_save.
    event_handlers.processEvent(&history);

    try testing.expect(history.current_state.event_stack.len > 0);
    const top = history.current_state.event_stack[history.current_state.event_stack.len - 1];
    try testing.expectEqual(@as(std.meta.Tag(events.Event), .meta_event), std.meta.activeTag(top));
    try testing.expectEqual(@as(std.meta.Tag(events.MetaEvent), .load_save), std.meta.activeTag(top.meta_event));
    try testing.expectEqualStrings(writers.autosave_path, top.meta_event.load_save.save_path);
}

// `player_continue` (empty branch) when the autosave is MISSING must be
// recoverable — popup + revert, not a crash. The harness FileSource uses cwd
// as the persistent dir, and there is no `saves/autosave.txt` in the project
// root, so readReconstructionFile returns FileNotFound (now propagated as an
// error instead of panicking). load_save catches it → failReconstructionRead
// (load_error + pending_error) + clears session.autosave_available so Continue
// disappears after the user dismisses the popup. See DESIGN → Error Handling
// → context 2.
test "player_continue: missing autosave is recoverable (popup + hide Continue)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    history.session.autosave_available = true; // simulate a fresh launch that detected an autosave
    runToIdle(&history);

    event_handlers.pushPlayerAction(
        &history.current_state,
        .player_continue,
        history.current_arena.allocator(),
    );
    // Drain the orchestrator + the pushed load_save. load_save's read fails →
    // failReconstructionRead sets load_error and returns. Stop on load_error
    // (runToIdle would panic — it asserts no load_error for valid test content).
    while (history.current_state.event_stack.len > 0) {
        event_handlers.processEvent(&history);
        if (history.load_error) break;
    }

    try testing.expect(history.load_error);
    try testing.expect(history.session.pending_error != null);
    // autosave_available cleared so the user doesn't retry into the same error.
    try testing.expect(!history.session.autosave_available);
    // Screen never left the main menu (load_save returned before
    // loadCampaignAndPushHub). The revert in the live drain loop would restore
    // the snapshot; here we just confirm no hub was loaded.
    try testing.expectEqual(state_mod.Screen.main_menu, history.current_state.screen);
    try testing.expect(history.current_state.hub == null);
}

// `end_level` pushes the autosave write after the sync. Inspect the stack
// after one processEvent: build_data_from_player on top (runs first, LIFO),
// write_save{autosave} below it (runs second, reads synced data). No mission
// → no continuation, so the stack is exactly those two.
test "end_level: pushes build_data_from_player then write_save on the autosave" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .end_level = .{} } }},
        history.current_arena.allocator(),
    );
    event_handlers.processEvent(&history);

    // Stack top = build_data_from_player (runs first), below = write_save.
    try testing.expectEqual(@as(usize, 2), history.current_state.event_stack.len);
    const top = history.current_state.event_stack[1];
    const below = history.current_state.event_stack[0];
    try testing.expectEqual(@as(std.meta.Tag(events.Event), .super_event), std.meta.activeTag(top));
    try testing.expectEqual(@as(std.meta.Tag(events.SuperEvent), .build_data_from_player), std.meta.activeTag(top.super_event));
    try testing.expectEqual(@as(std.meta.Tag(events.Event), .meta_event), std.meta.activeTag(below));
    try testing.expectEqual(@as(std.meta.Tag(events.MetaEvent), .write_save), std.meta.activeTag(below.meta_event));
    try testing.expectEqualStrings(writers.autosave_path, below.meta_event.write_save.save_path);
}

// `end_hub` pushes the autosave write after the sync, same shape as end_level.
test "end_hub: pushes build_data_from_player then write_save on the autosave" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A hub context: screen = hub with a minimal hub loaded is overkill here —
    // end_hub doesn't read hub fields, it only pushes the sync + autosave. Use
    // a main-menu start state and push end_hub directly.
    var history = harness.newHistory(null);
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .end_hub }},
        history.current_arena.allocator(),
    );
    event_handlers.processEvent(&history);

    try testing.expectEqual(@as(usize, 2), history.current_state.event_stack.len);
    const top = history.current_state.event_stack[1];
    const below = history.current_state.event_stack[0];
    try testing.expectEqual(@as(std.meta.Tag(events.SuperEvent), .build_data_from_player), std.meta.activeTag(top.super_event));
    try testing.expectEqual(@as(std.meta.Tag(events.MetaEvent), .write_save), std.meta.activeTag(below.meta_event));
    try testing.expectEqualStrings(writers.autosave_path, below.meta_event.write_save.save_path);
}

// `save_game` (the Save Player File button) writes BOTH the timestamped save
// AND the autosave, so a mid-mission save then quit then Continue doesn't
// lose loot picked up since the last hub/level transition. In a level/hub
// the stack is: build_data_from_player (runs first, LIFO), write_save
// {timestamped}, write_save {autosave}. We inspect the stack after one
// processEvent.
test "save_game: pushes timestamped write + autosave write after sync" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    runToIdle(&history);

    event_handlers.pushPlayerAction(
        &history.current_state,
        .{ .save_game = .{ .save_path = "saves/save_TEST.txt" } },
        history.current_arena.allocator(),
    );
    event_handlers.processEvent(&history);

    // Stack after the player action was popped: [autosave, timestamped, sync]
    // (pushEvents appends in order; pop is from the end). LIFO pops sync
    // first → run order is sync, timestamped write, autosave write.
    try testing.expectEqual(@as(usize, 3), history.current_state.event_stack.len);
    const sync = history.current_state.event_stack[2];
    const timestamped = history.current_state.event_stack[1];
    const autosave = history.current_state.event_stack[0];
    try testing.expectEqual(@as(std.meta.Tag(events.SuperEvent), .build_data_from_player), std.meta.activeTag(sync.super_event));
    try testing.expectEqual(@as(std.meta.Tag(events.MetaEvent), .write_save), std.meta.activeTag(timestamped.meta_event));
    try testing.expectEqualStrings("saves/save_TEST.txt", timestamped.meta_event.write_save.save_path);
    try testing.expectEqual(@as(std.meta.Tag(events.MetaEvent), .write_save), std.meta.activeTag(autosave.meta_event));
    try testing.expectEqualStrings(writers.autosave_path, autosave.meta_event.write_save.save_path);
}
