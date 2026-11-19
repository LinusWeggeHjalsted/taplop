//! Autosave handler tests. Covers the `player_continue` main-menu action
//! (populated vs empty PlayerData branches) and the autosave push on
//! `end_level` / `end_hub` (the write fires after the player-entity →
//! PlayerData sync, before the continuation). The disk-write itself
//! (`write_save` side effect) is `!replaying`-gated and not exercised here -
//! these tests inspect the event stack the orchestrators push, not the file
//! write, so they don't touch disk. See DESIGN → File System & IO (autosave).

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const events = @import("events.zig");
const event_handlers = @import("event_handlers.zig");
const event_push = @import("event_push.zig");
const state_mod = @import("state.zig");
const test_harness = @import("test_harness.zig");
const writers = @import("writers.zig");
const parser = @import("parser.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;
const Vector2 = types.Vector2;
const FileSource = @import("file_source.zig").FileSource;

const three_by_three = [_]Vector2{
    .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
    .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
    .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 },
};

// `player_continue` with populated PlayerData resumes directly from in-memory
// data - no file read. loadCampaignAndPushHub pushes start_hub, so after
// runToIdle the screen is the hub.
test "player_continue: populated PlayerData resumes at current_hub" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const start = test_harness.defaultStartingState();
    var history = harness.newHistory(start);
    // Populate PlayerData as if returning from a mid-session exit-to-menu.
    // The campaign + hub are DERIVED from the shipped new_player.txt (the
    // fixture the real start_new_game reads) - authored content, never
    // pinned (a campaign swap would otherwise rot this test).
    var current_campaign_uuid: []const u8 = "";
    var current_hub: []const u8 = "";
    {
        const arena = backing.allocator();
        const bytes = harness.file_source.readFile(
            arena,
            "data/new_player.txt",
        ) catch @panic("failed to read new_player.txt");
        const sections = parser.parseConfigFile(
            bytes,
            arena,
            &parser.player_save_sections,
        ) catch @panic("failed to parse new_player.txt");
        const info = parser.findSection(sections, "Info").?;
        current_campaign_uuid = parser.findValue(info.entry_groups[0].pairs, "current_campaign_uuid").?;
        current_hub = parser.findValue(info.entry_groups[0].pairs, "current_hub").?;
    }
    history.current_state.player_data.current_campaign_uuid = current_campaign_uuid;
    history.current_state.player_data.current_hub = current_hub;
    runToIdle(&history);

    event_push.pushPlayerAction(
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

    event_push.pushPlayerAction(
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
// recoverable - popup + revert, not a crash. The harness FileSource uses cwd
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

    event_push.pushPlayerAction(
        &history.current_state,
        .player_continue,
        history.current_arena.allocator(),
    );
    // Drain the orchestrator + the pushed load_save. load_save's read fails →
    // failReconstructionRead sets load_error and returns. Stop on load_error
    // (runToIdle would panic - it asserts no load_error for valid test content).
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

    event_push.pushEvents(
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

    // A hub context: screen = hub with a minimal hub loaded is overkill here -
    // end_hub doesn't read hub fields, it only pushes the sync + autosave. Use
    // a main-menu start state and push end_hub directly.
    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushEvents(
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

    event_push.pushPlayerAction(
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

// `export_game` (the autosave half - the zip + download are an input-path
// side effect, not an event): with a level live, the orchestrator pushes
// the autosave write after the sync - mid-level progress rides in the
// exported zip. No timestamped write (Export Save's spam-free sibling).
test "export_game: a live level pushes the autosave write after sync" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    runToIdle(&history);

    event_push.pushPlayerAction(
        &history.current_state,
        .export_game,
        history.current_arena.allocator(),
    );
    event_handlers.processEvent(&history);

    // Stack after the player action was popped: [autosave, sync] (LIFO pops
    // sync first → run order is sync, autosave write - the save_game
    // ordering, minus the timestamped write).
    try testing.expectEqual(@as(usize, 2), history.current_state.event_stack.len);
    const sync = history.current_state.event_stack[1];
    const autosave = history.current_state.event_stack[0];
    try testing.expectEqual(@as(std.meta.Tag(events.SuperEvent), .build_data_from_player), std.meta.activeTag(sync.super_event));
    try testing.expectEqual(@as(std.meta.Tag(events.MetaEvent), .write_save), std.meta.activeTag(autosave.meta_event));
    try testing.expectEqualStrings(writers.autosave_path, autosave.meta_event.write_save.save_path);
}

// `export_game` with NO game in progress (the main-menu/options-menu
// context): no pushes at all - the folder zip alone (the input-path side
// effect) is the whole export; the event stack stays empty.
test "export_game: no game in progress pushes nothing" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null); // main-menu start
    runToIdle(&history);

    event_push.pushPlayerAction(
        &history.current_state,
        .export_game,
        history.current_arena.allocator(),
    );
    event_handlers.processEvent(&history);

    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

// ───────────── backup_autosave (disk-touching, temp-dir isolated) ─────────────
// See DESIGN → File System & IO (Autosave). These tests write real files,
// so they use a temp-dir-backed FileSource (reassigned on the harness after
// init) instead of the cwd-backed default - no files leak into the project
// root. `newHistory` reads `&self.file_source` at call time, and the config
// arrays are already loaded from embedded data, so reassigning the field
// before `newHistory` gives the history a temp-dir source with real config.

// `backup_autosave`: when an autosave exists, the handler copies it to a
// timestamped `saves/autosave-YYYYMMDD_HHMMSS.txt`. We seed a fake autosave,
// push the event, then scan the saves/ dir for one matching file and verify
// its contents match the original. The timestamp is unpredictable, so the
// scan is by prefix + file-extension.
test "backup_autosave: copies existing autosave to a timestamped backup" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var threaded_io = std.Io.Threaded.init(backing.allocator(), .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const scratch = "zig-cache/test-backup-autosave";
    const temp_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    harness.file_source = FileSource.init(io, temp_dir);

    // Seed a fake autosave in the temp dir.
    const autosave_contents = "Metadata\nfile_format_version 1\nplayer_name Old Save\n";
    harness.file_source.writeFile(writers.autosave_path, autosave_contents) catch @panic("seed autosave");

    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .backup_autosave }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // Scan saves/ for a backup file and verify its contents.
    const saves_dir = temp_dir.openDir(io, "saves", .{ .iterate = true }) catch @panic("open saves dir");
    defer std.Io.Dir.close(saves_dir, io);
    var it = saves_dir.iterate();
    var found = false;
    while (it.next(io) catch @panic("iterate saves")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "autosave-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const backup_path = std.fmt.allocPrint(testing.allocator, "saves/{s}", .{entry.name}) catch @panic("alloc backup path");
        defer testing.allocator.free(backup_path);
        const backup_bytes = harness.file_source.readFile(testing.allocator, backup_path) catch @panic("read backup");
        defer testing.allocator.free(backup_bytes);
        try testing.expectEqualStrings(autosave_contents, backup_bytes);
        found = true;
        break;
    }
    try testing.expect(found);
}

// `backup_autosave`: when no autosave exists, the handler is a no-op - no
// backup file is written. Uses the same temp-dir isolation.
test "backup_autosave: no autosave present is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var threaded_io = std.Io.Threaded.init(backing.allocator(), .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const scratch = "zig-cache/test-backup-autosave-noop";
    const temp_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    harness.file_source = FileSource.init(io, temp_dir);

    // No autosave seeded. The backup handler should detect this via
    // fileExists and skip. We need a saves/ dir to exist (so openDir doesn't
    // error in the scan) - create it by writing a dummy file then removing it.
    temp_dir.createDirPath(io, "saves") catch @panic("create saves dir");

    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .backup_autosave }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // No backup file should exist. Scan saves/ (empty → no matches).
    const saves_dir = temp_dir.openDir(io, "saves", .{ .iterate = true }) catch @panic("open saves dir");
    defer std.Io.Dir.close(saves_dir, io);
    var it = saves_dir.iterate();
    while (it.next(io) catch @panic("iterate saves")) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "autosave-")) {
            try testing.expect(false); // found a backup when none expected
        }
    }
}

// `start_new_game` must push `backup_autosave` so it runs BEFORE
// `start_hub`'s `transitionScreen(.hub)` clears the event stack. This test
// runs the full orchestrator to idle against a temp-dir FileSource seeded
// with a fake autosave, then verifies a backup file appeared - the
// regression test for the transitionScreen stack-clear bug (pushing
// backup_autosave before loadCampaignAndPushHub left it below start_hub on
// the stack; start_hub ran first and cleared the stack, wiping the backup).
test "start_new_game: backs up existing autosave before start_hub clears the stack" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var threaded_io = std.Io.Threaded.init(backing.allocator(), .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const scratch = "zig-cache/test-start-new-game-backup";
    const temp_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    harness.file_source = FileSource.init(io, temp_dir);

    // Seed a fake autosave in the temp dir.
    const autosave_contents = "Metadata\nfile_format_version 1\nplayer_name Old Save\n";
    harness.file_source.writeFile(writers.autosave_path, autosave_contents) catch @panic("seed autosave");

    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushPlayerAction(
        &history.current_state,
        .start_new_game,
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The new game should have loaded successfully (we're at the hub).
    try testing.expectEqual(state_mod.Screen.hub, history.current_state.screen);

    // A backup file should exist in saves/ matching autosave-*.txt.
    const saves_dir = temp_dir.openDir(io, "saves", .{ .iterate = true }) catch @panic("open saves dir");
    defer std.Io.Dir.close(saves_dir, io);
    var it = saves_dir.iterate();
    var found = false;
    while (it.next(io) catch @panic("iterate saves")) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "autosave-") and std.mem.endsWith(u8, entry.name, ".txt")) {
            const backup_path = std.fmt.allocPrint(testing.allocator, "saves/{s}", .{entry.name}) catch @panic("alloc backup path");
            defer testing.allocator.free(backup_path);
            const backup_bytes = harness.file_source.readFile(testing.allocator, backup_path) catch @panic("read backup");
            defer testing.allocator.free(backup_bytes);
            try testing.expectEqualStrings(autosave_contents, backup_bytes);
            found = true;
            break;
        }
    }
    try testing.expect(found);
}
