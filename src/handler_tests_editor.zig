//! Editor handler tests. Covers the editor input path — level-tab clicks
//! (`player_set_editor_level` → `editor_set_active_level`), which ride the
//! undo timeline like every GameState mutation. The framing-event round
//! trip (open → playtest → end → close against the real beginnings
//! mission) lives in main.zig. See DESIGN → Architecture → Level Editor.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const event_handlers = @import("event_handlers.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;

/// A minimal editor-screen starting state with `level_count` empty levels.
fn editorStartingState(levels: []const types.EditorLevel) state.GameState {
    return .{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = levels },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
}

/// Does the level's tile list contain `position`?
fn hasTile(level: types.EditorLevel, position: types.Vector2) bool {
    for (level.level_tiles) |tile| {
        if (tile.x == position.x and tile.y == position.y) return true;
    }
    return false;
}

test "player_set_editor_level: switches the active level, undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{ .{}, .{}, .{} };
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.active_level_index);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_level = .{ .level_index = 2 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.active_level_index);

    // The switch rides the undo timeline (the Editor is part of GameState,
    // captured by snapshots) — undo walks back to level 0.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.active_level_index);
}

test "player_set_editor_level: out-of-range index is a no-op (handler guard)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{ .{} };
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    // The inline editor_set_active_level handler guards the range (an
    // out-of-range index leaves active_level_index unchanged).
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_active_level = .{ .level_index = 9 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.active_level_index);
}

test "player_paint_editor_tile: paints a tile on empty space, sorted into the list" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 0 } };
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_paint_editor_tile = .{
            .position = .{ .x = 1, .y = 2 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 3), level.level_tiles.len);
    try testing.expect(hasTile(level, .{ .x = 1, .y = 2 }));
    // Insert keeps tileBefore (row-major) canonical order: (0,0), (1,2), (3,0).
    try testing.expectEqual(types.Vector2{ .x = 1, .y = 2 }, level.level_tiles[1]);
}

test "player_paint_editor_tile: existing tile is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{.{ .x = 1, .y = 1 }};
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_paint_editor_tile = .{
            .position = .{ .x = 1, .y = 1 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.level_tiles.len);
}

test "player_paint_editor_tile: replaces a covering decoration, one undo reverts both" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Footprint {(0,0),(1,0)} anchored at (0,0): a placement at (4,1)
    // covers (4,1) and (5,1). Paint at (5,1) → decoration deleted + tile.
    const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 4, .y = 1 },
    }};
    const levels = [_]types.EditorLevel{.{
        .decoration_placements = &decoration_placements,
    }};
    var history = harness.newHistory(.{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{
            .levels = &levels,
            .decoration_types = &decoration_types,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_paint_editor_tile = .{
            .position = .{ .x = 5, .y = 1 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 0), level.decoration_placements.len);
    try testing.expect(hasTile(level, .{ .x = 5, .y = 1 }));

    // The delete + place sub-events share one idle point, so ONE undo
    // reverts the whole click (decoration back, tile gone).
    try testing.expect(history.undo(event_handlers.processEvent));
    const reverted = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), reverted.decoration_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 4, .y = 1 }, reverted.decoration_placements[0].position);
    try testing.expect(!hasTile(reverted, .{ .x = 5, .y = 1 }));
}

test "player_paint_editor_tile: deletes ALL covering decorations, others intact" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Both types cover (2,1) when placed at (1,1) / (2,1): type A's
    // footprint {(0,0),(1,0)} covers (1,1)+(2,1); type B's single-tile
    // footprint covers (2,1). Five placements; the two covering ones sit
    // at indices 1 and 3 so index-stability (delete high before low) is
    // exercised.
    const footprint_wide = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const footprint_single = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "wide", .sprite = "wide", .footprint = &footprint_wide, .pixel_dims = .{ .x = 512, .y = 256 } },
        .{ .id = "single", .sprite = "single", .footprint = &footprint_single, .pixel_dims = .{ .x = 256, .y = 256 } },
    };
    const decoration_placements = [_]types.DecorationPlacement{
        .{ .type_id = 1, .position = .{ .x = 0, .y = 0 } }, // index 0: untouched
        .{ .type_id = 0, .position = .{ .x = 1, .y = 1 } }, // index 1: covers (2,1)
        .{ .type_id = 1, .position = .{ .x = 9, .y = 9 } }, // index 2: untouched
        .{ .type_id = 1, .position = .{ .x = 2, .y = 1 } }, // index 3: covers (2,1)
        .{ .type_id = 0, .position = .{ .x = 8, .y = 8 } }, // index 4: untouched
    };
    const levels = [_]types.EditorLevel{.{
        .decoration_placements = &decoration_placements,
    }};
    var history = harness.newHistory(.{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{
            .levels = &levels,
            .decoration_types = &decoration_types,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_paint_editor_tile = .{
            .position = .{ .x = 2, .y = 1 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 3), level.decoration_placements.len);
    try testing.expect(hasTile(level, .{ .x = 2, .y = 1 }));
    // Order preserved; the survivors are the three non-covering placements.
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.decoration_placements[0].position);
    try testing.expectEqual(types.Vector2{ .x = 9, .y = 9 }, level.decoration_placements[1].position);
    try testing.expectEqual(types.Vector2{ .x = 8, .y = 8 }, level.decoration_placements[2].position);
}

test "editor_set_tile: erase arm removes a tile, absent tile is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 0 } };
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_tile = .{
            .level_index = 0,
            .position = .{ .x = 1, .y = 2 },
            .is_floor = false,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    var level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.level_tiles.len);
    try testing.expect(!hasTile(level, .{ .x = 1, .y = 2 }));

    // Erasing a tile that isn't there is an idempotent no-op.
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_tile = .{
            .level_index = 0,
            .position = .{ .x = 7, .y = 7 },
            .is_floor = false,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.level_tiles.len);
}

test "editor_delete_decoration_placement: removes the placement, order preserved" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const footprint = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "single",
        .sprite = "single",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 256, .y = 256 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
        .{ .type_id = 0, .position = .{ .x = 1, .y = 1 } },
        .{ .type_id = 0, .position = .{ .x = 2, .y = 2 } },
    };
    const levels = [_]types.EditorLevel{.{
        .decoration_placements = &decoration_placements,
    }};
    var history = harness.newHistory(.{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{
            .levels = &levels,
            .decoration_types = &decoration_types,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_delete_decoration_placement = .{
            .level_index = 0,
            .placement_index = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.decoration_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.decoration_placements[0].position);
    try testing.expectEqual(types.Vector2{ .x = 2, .y = 2 }, level.decoration_placements[1].position);
}
