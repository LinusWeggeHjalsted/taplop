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

/// A minimal editor-screen starting state (editor default: no palette, no
/// levels).
fn editorStartingState(levels: []const types.EditorLevel) state.GameState {
    return editorStateWith(.{ .levels = levels });
}

/// An editor-screen starting state carrying a full `Editor` (palette +
/// levels) — the placement-click tests need palette + placements.
fn editorStateWith(editor: types.Editor) state.GameState {
    return .{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = editor,
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

/// Two palette entity types (a Skeleton and a Wolf) for the placement
/// tests — retyping needs a second type to switch to.
fn placementTestEditor(
    levels: []const types.EditorLevel,
) types.Editor {
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 } },
        .{ .id = "Wolf", .template = .{ .name = "Wolf", .sprite = "wolf", .team = 1 } },
    };
    return .{ .levels = levels, .entity_types = &entity_types };
}

test "player_place_editor_entity: empty tile → enemy placed on it" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{.{ .x = 2, .y = 2 }};
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(editorStateWith(placementTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_entity = .{
            .type_id = 1,
            .position = .{ .x = 2, .y = 2 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.entity_placements.len);
    try testing.expectEqual(@as(u32, 1), level.entity_placements[0].type_id);
    try testing.expectEqual(types.Vector2{ .x = 2, .y = 2 }, level.entity_placements[0].position);
    // The tile was already there — untouched.
    try testing.expectEqual(@as(usize, 1), level.level_tiles.len);
}

test "player_place_editor_entity: no tile → tile placed + enemy on top" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(placementTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_entity = .{
            .type_id = 0,
            .position = .{ .x = 3, .y = 1 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expect(hasTile(level, .{ .x = 3, .y = 1 }));
    try testing.expectEqual(@as(usize, 1), level.entity_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 3, .y = 1 }, level.entity_placements[0].position);
}

test "player_place_editor_entity: decoration + missing tile → both handled, one undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const footprint = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 256, .y = 256 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 1, .y = 0 },
    }};
    const levels = [_]types.EditorLevel{.{
        .decoration_placements = &decoration_placements,
    }};
    var editor = placementTestEditor(&levels);
    editor.decoration_types = &decoration_types;
    var history = harness.newHistory(editorStateWith(editor));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_entity = .{
            .type_id = 0,
            .position = .{ .x = 1, .y = 0 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 0), level.decoration_placements.len);
    try testing.expect(hasTile(level, .{ .x = 1, .y = 0 }));
    try testing.expectEqual(@as(usize, 1), level.entity_placements.len);

    // One click = one idle point: a single undo reverts decoration + tile
    // + enemy together.
    try testing.expect(history.undo(event_handlers.processEvent));
    const reverted = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), reverted.decoration_placements.len);
    try testing.expect(!hasTile(reverted, .{ .x = 1, .y = 0 }));
    try testing.expectEqual(@as(usize, 0), reverted.entity_placements.len);
}

test "player_place_editor_entity: player start and level end are no-ops" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 4, .y = 0 },
    }};
    var history = harness.newHistory(editorStateWith(placementTestEditor(&levels)));
    runToIdle(&history);

    for ([_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 } }) |position| {
        event_handlers.pushEvents(
            &history.current_state,
            &.{.{ .player_input_event = .{ .player_place_editor_entity = .{
                .type_id = 0,
                .position = position,
            } } }},
            history.current_arena.allocator(),
        );
        runToIdle(&history);
    }

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 0), level.entity_placements.len);
    try testing.expectEqual(@as(usize, 2), level.level_tiles.len);
}

test "player_place_editor_entity: existing enemy is retyped in place, same type is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{.{ .x = 1, .y = 1 }};
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0, // Skeleton
        .position = .{ .x = 1, .y = 1 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .entity_placements = &entity_placements,
    }};
    var history = harness.newHistory(editorStateWith(placementTestEditor(&levels)));
    runToIdle(&history);

    // Different type → retyped in place: same index, same position, new
    // type_id, placement count unchanged.
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_entity = .{
            .type_id = 1, // Wolf
            .position = .{ .x = 1, .y = 1 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    var level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.entity_placements.len);
    try testing.expectEqual(@as(u32, 1), level.entity_placements[0].type_id);
    try testing.expectEqual(types.Vector2{ .x = 1, .y = 1 }, level.entity_placements[0].position);

    // Same type again → nothing to do (no do-nothing undo step).
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_entity = .{
            .type_id = 1,
            .position = .{ .x = 1, .y = 1 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.entity_placements.len);
    try testing.expectEqual(@as(u32, 1), level.entity_placements[0].type_id);
}

test "player_place_editor_entity: ground item on the tile is deleted, enemy placed" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{.{ .x = 2, .y = 0 }};
    const item_placements = [_]types.ItemPlacement{
        .{ .type_id = 0, .position = .{ .x = 2, .y = 0 } }, // deleted
        .{ .type_id = 0, .position = .{ .x = 5, .y = 5 } }, // untouched
    };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .item_placements = &item_placements,
    }};
    var history = harness.newHistory(editorStateWith(placementTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_entity = .{
            .type_id = 0,
            .position = .{ .x = 2, .y = 0 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.item_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 5, .y = 5 }, level.item_placements[0].position);
    try testing.expectEqual(@as(usize, 1), level.entity_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 2, .y = 0 }, level.entity_placements[0].position);
}

test "editor_set_entity_placement_type: retypes without touching position or count" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_placements = [_]types.EntityPlacement{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
        .{ .type_id = 0, .position = .{ .x = 1, .y = 0 } },
    };
    const levels = [_]types.EditorLevel{.{ .entity_placements = &entity_placements }};
    var history = harness.newHistory(editorStateWith(placementTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_entity_placement_type = .{
            .level_index = 0,
            .placement_index = 1,
            .type_id = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.entity_placements.len);
    try testing.expectEqual(@as(u32, 0), level.entity_placements[0].type_id);
    try testing.expectEqual(@as(u32, 1), level.entity_placements[1].type_id);
    try testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, level.entity_placements[1].position);
}

test "editor_delete_item_placement: removes the placement, order preserved" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const item_placements = [_]types.ItemPlacement{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
        .{ .type_id = 0, .position = .{ .x = 1, .y = 1 } },
        .{ .type_id = 0, .position = .{ .x = 2, .y = 2 } },
    };
    const levels = [_]types.EditorLevel{.{ .item_placements = &item_placements }};
    var history = harness.newHistory(editorStateWith(placementTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_delete_item_placement = .{
            .level_index = 0,
            .placement_index = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.item_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.item_placements[0].position);
    try testing.expectEqual(types.Vector2{ .x = 2, .y = 2 }, level.item_placements[1].position);
}

/// A 2-wide footprint {(0,0),(1,0)} anchored at (0,0): a placement at P
/// covers P and P+(1,0).
const two_wide_footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
const single_footprint = [_]types.Vector2{.{ .x = 0, .y = 0 }};

fn decorationTestEditor(levels: []const types.EditorLevel) types.Editor {
    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "wide", .sprite = "ruin_1", .footprint = &two_wide_footprint, .pixel_dims = .{ .x = 512, .y = 256 } },
        .{ .id = "single", .sprite = "stone_2", .footprint = &single_footprint, .pixel_dims = .{ .x = 256, .y = 256 } },
    };
    return .{ .levels = levels, .decoration_types = &decoration_types };
}

test "player_place_editor_decoration: empty ground → placement at the anchor position" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(decorationTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_decoration = .{
            .type_id = 0,
            .position = .{ .x = 5, .y = 5 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.decoration_placements.len);
    try testing.expectEqual(@as(u32, 0), level.decoration_placements[0].type_id);
    try testing.expectEqual(types.Vector2{ .x = 5, .y = 5 }, level.decoration_placements[0].position);
}

test "player_place_editor_decoration: player start or level end under ANY footprint tile is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The wide footprint covers (x, y) and (x+1, y): placing at (-1, 0)
    // covers the player start (0, 0) via the NON-anchor tile; placing at
    // (3, 4) covers the level end (4, 4) the same way.
    const levels = [_]types.EditorLevel{.{
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 4, .y = 4 },
    }};
    var history = harness.newHistory(editorStateWith(decorationTestEditor(&levels)));
    runToIdle(&history);

    for ([_]types.Vector2{ .{ .x = -1, .y = 0 }, .{ .x = 3, .y = 4 } }) |position| {
        event_handlers.pushEvents(
            &history.current_state,
            &.{.{ .player_input_event = .{ .player_place_editor_decoration = .{
                .type_id = 0,
                .position = position,
            } } }},
            history.current_arena.allocator(),
        );
        runToIdle(&history);
    }

    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.levels[0].decoration_placements.len);
}

test "player_place_editor_decoration: covered tiles + occupants are cleared, one undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Tiles under BOTH footprint tiles, an entity standing on one, a ground
    // item on the other, plus an untouched tile + item elsewhere.
    const tiles = [_]types.Vector2{ .{ .x = 5, .y = 5 }, .{ .x = 6, .y = 5 }, .{ .x = 9, .y = 9 } };
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 } },
    };
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 5, .y = 5 },
    }};
    const item_placements = [_]types.ItemPlacement{
        .{ .type_id = 0, .position = .{ .x = 6, .y = 5 } }, // on a covered tile
        .{ .type_id = 0, .position = .{ .x = 9, .y = 9 } }, // untouched
    };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .entity_placements = &entity_placements,
        .item_placements = &item_placements,
    }};
    var editor = decorationTestEditor(&levels);
    editor.entity_types = &entity_types;
    var history = harness.newHistory(editorStateWith(editor));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_decoration = .{
            .type_id = 0,
            .position = .{ .x = 5, .y = 5 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.decoration_placements.len);
    try testing.expect(!hasTile(level, .{ .x = 5, .y = 5 }));
    try testing.expect(!hasTile(level, .{ .x = 6, .y = 5 }));
    try testing.expect(hasTile(level, .{ .x = 9, .y = 9 }));
    try testing.expectEqual(@as(usize, 0), level.entity_placements.len);
    try testing.expectEqual(@as(usize, 1), level.item_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 9, .y = 9 }, level.item_placements[0].position);

    // One click = one idle point: a single undo restores both tiles, the
    // entity, the item, and removes the decoration.
    try testing.expect(history.undo(event_handlers.processEvent));
    const reverted = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 0), reverted.decoration_placements.len);
    try testing.expect(hasTile(reverted, .{ .x = 5, .y = 5 }));
    try testing.expect(hasTile(reverted, .{ .x = 6, .y = 5 }));
    try testing.expectEqual(@as(usize, 1), reverted.entity_placements.len);
    try testing.expectEqual(@as(usize, 2), reverted.item_placements.len);
}

test "player_place_editor_decoration: overlapping other decorations are deleted" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Existing single-tile decorations at (7,7) — overlaps the new wide
    // footprint's anchor tile — and (0,9), clear of it.
    const existing_placements = [_]types.DecorationPlacement{
        .{ .type_id = 1, .position = .{ .x = 7, .y = 7 } },
        .{ .type_id = 1, .position = .{ .x = 0, .y = 9 } },
    };
    const levels = [_]types.EditorLevel{.{
        .decoration_placements = &existing_placements,
    }};
    var history = harness.newHistory(editorStateWith(decorationTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_decoration = .{
            .type_id = 0,
            .position = .{ .x = 7, .y = 7 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.decoration_placements.len);
    // The survivor is the non-overlapping single at (0,9); the new wide
    // decoration is appended after it.
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 9 }, level.decoration_placements[0].position);
    try testing.expectEqual(@as(u32, 0), level.decoration_placements[1].type_id);
    try testing.expectEqual(types.Vector2{ .x = 7, .y = 7 }, level.decoration_placements[1].position);
}

test "editor_delete_entity_placement: removes the placement, order preserved" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_placements = [_]types.EntityPlacement{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
        .{ .type_id = 0, .position = .{ .x = 1, .y = 1 } },
        .{ .type_id = 0, .position = .{ .x = 2, .y = 2 } },
    };
    const levels = [_]types.EditorLevel{.{ .entity_placements = &entity_placements }};
    var history = harness.newHistory(editorStateWith(placementTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_delete_entity_placement = .{
            .level_index = 0,
            .placement_index = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.entity_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.entity_placements[0].position);
    try testing.expectEqual(types.Vector2{ .x = 2, .y = 2 }, level.entity_placements[1].position);
}

/// Two palette item types for the ground-item placement tests — retyping
/// needs a second type to switch to.
fn itemTestEditor(levels: []const types.EditorLevel) types.Editor {
    const item_types = [_]types.ItemTypeDef{
        .{ .id = "Iron Sword", .item = .{ .weapon = .{} } },
        .{ .id = "Boots", .item = .{ .boots = .{ .name = "Boots" } } },
    };
    return .{ .levels = levels, .item_types = &item_types };
}

test "player_place_editor_item: no tile → tile placed + item on top" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(itemTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_item = .{
            .type_id = 0,
            .position = .{ .x = 3, .y = 1 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expect(hasTile(level, .{ .x = 3, .y = 1 }));
    try testing.expectEqual(@as(usize, 1), level.item_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 3, .y = 1 }, level.item_placements[0].position);
}

test "player_place_editor_item: empty tile → item placed on it" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{.{ .x = 2, .y = 2 }};
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(editorStateWith(itemTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_item = .{
            .type_id = 1,
            .position = .{ .x = 2, .y = 2 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.level_tiles.len);
    try testing.expectEqual(@as(usize, 1), level.item_placements.len);
    try testing.expectEqual(@as(u32, 1), level.item_placements[0].type_id);
}

test "player_place_editor_item: decoration footprint → decoration deleted, tile + item placed, one undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const existing_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 1, .y = 0 },
    }};
    const levels = [_]types.EditorLevel{.{
        .decoration_placements = &existing_placements,
    }};
    var editor = itemTestEditor(&levels);
    const decoration_editor = decorationTestEditor(&levels);
    editor.decoration_types = decoration_editor.decoration_types;
    var history = harness.newHistory(editorStateWith(editor));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_item = .{
            .type_id = 0,
            .position = .{ .x = 1, .y = 0 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 0), level.decoration_placements.len);
    try testing.expect(hasTile(level, .{ .x = 1, .y = 0 }));
    try testing.expectEqual(@as(usize, 1), level.item_placements.len);

    try testing.expect(history.undo(event_handlers.processEvent));
    const reverted = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), reverted.decoration_placements.len);
    try testing.expect(!hasTile(reverted, .{ .x = 1, .y = 0 }));
    try testing.expectEqual(@as(usize, 0), reverted.item_placements.len);
}

test "player_place_editor_item: player start and level end are no-ops" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 4, .y = 0 },
    }};
    var history = harness.newHistory(editorStateWith(itemTestEditor(&levels)));
    runToIdle(&history);

    for ([_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 } }) |position| {
        event_handlers.pushEvents(
            &history.current_state,
            &.{.{ .player_input_event = .{ .player_place_editor_item = .{
                .type_id = 0,
                .position = position,
            } } }},
            history.current_arena.allocator(),
        );
        runToIdle(&history);
    }

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 0), level.item_placements.len);
    try testing.expectEqual(@as(usize, 2), level.level_tiles.len);
}

test "player_place_editor_item: enemy on the tile is deleted, item placed" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 2, .y = 0 }, .{ .x = 5, .y = 5 } };
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 } },
    };
    const entity_placements = [_]types.EntityPlacement{
        .{ .type_id = 0, .position = .{ .x = 2, .y = 0 } }, // deleted
        .{ .type_id = 0, .position = .{ .x = 5, .y = 5 } }, // untouched
    };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .entity_placements = &entity_placements,
    }};
    var editor = itemTestEditor(&levels);
    editor.entity_types = &entity_types;
    var history = harness.newHistory(editorStateWith(editor));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_item = .{
            .type_id = 0,
            .position = .{ .x = 2, .y = 0 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.entity_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 5, .y = 5 }, level.entity_placements[0].position);
    try testing.expectEqual(@as(usize, 1), level.item_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 2, .y = 0 }, level.item_placements[0].position);
}

test "player_place_editor_item: existing item is retyped in place, same type is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{.{ .x = 1, .y = 1 }};
    const item_placements = [_]types.ItemPlacement{.{
        .type_id = 0, // Iron Sword
        .position = .{ .x = 1, .y = 1 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .item_placements = &item_placements,
    }};
    var history = harness.newHistory(editorStateWith(itemTestEditor(&levels)));
    runToIdle(&history);

    // Different type → retyped in place: same index, same position, new
    // type_id, placement count unchanged.
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_item = .{
            .type_id = 1, // Boots
            .position = .{ .x = 1, .y = 1 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    var level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.item_placements.len);
    try testing.expectEqual(@as(u32, 1), level.item_placements[0].type_id);
    try testing.expectEqual(types.Vector2{ .x = 1, .y = 1 }, level.item_placements[0].position);

    // Same type again → nothing to do (no do-nothing undo step).
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_item = .{
            .type_id = 1,
            .position = .{ .x = 1, .y = 1 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.item_placements.len);
    try testing.expectEqual(@as(u32, 1), level.item_placements[0].type_id);
}

test "editor_set_item_placement_type: retypes without touching position or count" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const item_placements = [_]types.ItemPlacement{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
        .{ .type_id = 0, .position = .{ .x = 1, .y = 0 } },
    };
    const levels = [_]types.EditorLevel{.{ .item_placements = &item_placements }};
    var history = harness.newHistory(editorStateWith(itemTestEditor(&levels)));
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_item_placement_type = .{
            .level_index = 0,
            .placement_index = 1,
            .type_id = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.item_placements.len);
    try testing.expectEqual(@as(u32, 0), level.item_placements[0].type_id);
    try testing.expectEqual(@as(u32, 1), level.item_placements[1].type_id);
    try testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, level.item_placements[1].position);
}

test "player_delete_editor_at: one thing per click, occupant before tile" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A tile with an enemy on it, a tile with an item, a bare tile, and
    // empty ground. One right-click each.
    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 1 } };
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 } },
    };
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 1, .y = 1 },
    }};
    const item_placements = [_]types.ItemPlacement{.{
        .type_id = 0,
        .position = .{ .x = 2, .y = 1 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .entity_placements = &entity_placements,
        .item_placements = &item_placements,
    }};
    var editor = itemTestEditor(&levels);
    editor.entity_types = &entity_types;
    var history = harness.newHistory(editorStateWith(editor));
    runToIdle(&history);

    const pushDelete = struct {
        fn call(history_: *state.GameStateHistory, position: types.Vector2) void {
            event_handlers.pushEvents(
                &history_.current_state,
                &.{.{ .player_input_event = .{ .player_delete_editor_at = .{
                    .position = position,
                } } }},
                history_.current_arena.allocator(),
            );
        }
    }.call;

    // Enemy tile: the enemy goes, the tile stays.
    pushDelete(&history, .{ .x = 1, .y = 1 });
    runToIdle(&history);
    var level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 0), level.entity_placements.len);
    try testing.expect(hasTile(level, .{ .x = 1, .y = 1 }));

    // Item tile: the item goes, the tile stays.
    pushDelete(&history, .{ .x = 2, .y = 1 });
    runToIdle(&history);
    level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 0), level.item_placements.len);
    try testing.expect(hasTile(level, .{ .x = 2, .y = 1 }));

    // Bare tile: the tile goes.
    pushDelete(&history, .{ .x = 3, .y = 1 });
    runToIdle(&history);
    level = history.current_state.editor.?.levels[0];
    try testing.expect(!hasTile(level, .{ .x = 3, .y = 1 }));

    // Empty ground: no-op.
    pushDelete(&history, .{ .x = 9, .y = 9 });
    runToIdle(&history);
    level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.level_tiles.len);
}

test "player_delete_editor_at: player start / level end / decoration cases" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // '!' and '=' sit on tiles — a right-click on them must not delete the
    // tile underneath. A covering decoration is deleted instead of the
    // (nonexistent) tile.
    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 } };
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 1, // single-tile footprint
        .position = .{ .x = 7, .y = 7 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 4, .y = 0 },
        .decoration_placements = &decoration_placements,
    }};
    const decoration_editor = decorationTestEditor(&levels);
    var editor = itemTestEditor(&levels);
    editor.decoration_types = decoration_editor.decoration_types;
    var history = harness.newHistory(editorStateWith(editor));
    runToIdle(&history);

    const pushDelete = struct {
        fn call(history_: *state.GameStateHistory, position: types.Vector2) void {
            event_handlers.pushEvents(
                &history_.current_state,
                &.{.{ .player_input_event = .{ .player_delete_editor_at = .{
                    .position = position,
                } } }},
                history_.current_arena.allocator(),
            );
        }
    }.call;

    // '!' / '=': no-op — their tiles survive.
    pushDelete(&history, .{ .x = 0, .y = 0 });
    runToIdle(&history);
    pushDelete(&history, .{ .x = 4, .y = 0 });
    runToIdle(&history);
    var level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.level_tiles.len);

    // Covering decoration: deleted.
    pushDelete(&history, .{ .x = 7, .y = 7 });
    runToIdle(&history);
    level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 0), level.decoration_placements.len);
}

test "editor deletes prune the selection and remap shifted indices" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Three entities at (0,0), (1,0), (2,0). The selection holds the
    // placements at indices 0 and 2; deleting index 1 must leave the
    // selection pointing at the SAME placements (0 and the former 2,
    // remapped to 1).
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 } },
    };
    const entity_placements = [_]types.EntityPlacement{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
        .{ .type_id = 0, .position = .{ .x = 1, .y = 0 } },
        .{ .type_id = 0, .position = .{ .x = 2, .y = 0 } },
    };
    const levels = [_]types.EditorLevel{.{ .entity_placements = &entity_placements }};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
    }));
    runToIdle(&history);

    const selection = &history.session.ui_state.editor_selection;
    try selection.append(history.backing_allocator, .{ .entity_placement = 0 });
    try selection.append(history.backing_allocator, .{ .entity_placement = 2 });

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_delete_entity_placement = .{
            .level_index = 0,
            .placement_index = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(@as(usize, 2), selection.items.len);
    try testing.expectEqual(@as(u32, 0), selection.items[0].entity_placement);
    try testing.expectEqual(@as(u32, 1), selection.items[1].entity_placement);
    // The remapped entry still points at the same placement: (2,0).
    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(types.Vector2{ .x = 2, .y = 0 }, level.entity_placements[selection.items[1].entity_placement].position);

    // Deleting a SELECTED placement removes its entry outright.
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_delete_entity_placement = .{
            .level_index = 0,
            .placement_index = 0,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), selection.items.len);
    try testing.expectEqual(@as(u32, 0), selection.items[0].entity_placement);
}

test "editor deletes prune selected tiles and decorations" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 } };
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 7, .y = 7 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .decoration_placements = &decoration_placements,
    }};
    const decoration_editor = decorationTestEditor(&levels);
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .decoration_types = decoration_editor.decoration_types,
    }));
    runToIdle(&history);

    const selection = &history.session.ui_state.editor_selection;
    try selection.append(history.backing_allocator, .{ .tile = .{ .x = 1, .y = 1 } });
    try selection.append(history.backing_allocator, .{ .tile = .{ .x = 2, .y = 2 } });
    try selection.append(history.backing_allocator, .{ .decoration_placement = 0 });

    // Erasing a selected tile removes just that tile entry (the other tile
    // + the decoration stay).
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_tile = .{
            .level_index = 0,
            .position = .{ .x = 1, .y = 1 },
            .is_floor = false,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 2), selection.items.len);
    try testing.expectEqual(types.Vector2{ .x = 2, .y = 2 }, selection.items[0].tile);

    // Deleting the selected decoration removes its entry.
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_delete_decoration_placement = .{
            .level_index = 0,
            .placement_index = 0,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), selection.items.len);
    try testing.expectEqual(types.Vector2{ .x = 2, .y = 2 }, selection.items[0].tile);
}

test "player_place_editor_decoration: cascaded tile erases prune selected tiles" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A selected tile under the wide decoration's footprint gets erased by
    // the placement — the selection entry must go with it.
    const tiles = [_]types.Vector2{ .{ .x = 5, .y = 5 }, .{ .x = 9, .y = 9 } };
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(editorStateWith(decorationTestEditor(&levels)));
    runToIdle(&history);

    const selection = &history.session.ui_state.editor_selection;
    try selection.append(history.backing_allocator, .{ .tile = .{ .x = 5, .y = 5 } });
    try selection.append(history.backing_allocator, .{ .tile = .{ .x = 9, .y = 9 } });

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_place_editor_decoration = .{
            .type_id = 0,
            .position = .{ .x = 5, .y = 5 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The covered tile (5,5) was erased + pruned; the clear tile survives.
    try testing.expectEqual(@as(usize, 1), selection.items.len);
    try testing.expectEqual(types.Vector2{ .x = 9, .y = 9 }, selection.items[0].tile);
}
