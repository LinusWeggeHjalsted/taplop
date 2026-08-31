//! Editor handler tests. Covers the editor input path — level-tab clicks
//! (`player_set_editor_level` → `editor_set_active_level`), which ride the
//! undo timeline like every GameState mutation, plus the pure click
//! planners and the input-side no-op gate. The framing-event round trip
//! (open → playtest → end → close against the real beginnings mission)
//! lives in main.zig. See DESIGN → Architecture → Level Editor.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const event_handlers = @import("event_handlers.zig");
const input_handlers = @import("input_handlers.zig");
const test_harness = @import("test_harness.zig");
const ui = @import("ui.zig");

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

test "player_toggle_editor_inspector: flips the open state, undo/redo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{ .{} };
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);
    // Open by default (an empty type isn't useful until populated — the
    // inspector is the first thing an author sees).
    try testing.expect(history.current_state.editor.?.inspector_open);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_toggle_editor_inspector }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expect(!history.current_state.editor.?.inspector_open);

    // The toggle rides the undo timeline (the flag lives on the Editor,
    // captured by snapshots) — undo re-opens, redo re-closes.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.editor.?.inspector_open);
    try testing.expect(history.redo(event_handlers.processEvent));
    try testing.expect(!history.current_state.editor.?.inspector_open);
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

    const seeded_selection = [_]types.Selectable{ .{ .entity_placement = 0 }, .{ .entity_placement = 2 } };
    history.current_state.editor.?.selection = &seeded_selection;

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_delete_entity_placement = .{
            .level_index = 0,
            .placement_index = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    {
        const selection = history.current_state.editor.?.selection;
        try testing.expectEqual(@as(usize, 2), selection.len);
        try testing.expectEqual(@as(u32, 0), selection[0].entity_placement);
        try testing.expectEqual(@as(u32, 1), selection[1].entity_placement);
        // The remapped entry still points at the same placement: (2,0).
        const level = history.current_state.editor.?.levels[0];
        try testing.expectEqual(types.Vector2{ .x = 2, .y = 0 }, level.entity_placements[selection[1].entity_placement].position);
    }

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
    {
        const selection = history.current_state.editor.?.selection;
        try testing.expectEqual(@as(usize, 1), selection.len);
        try testing.expectEqual(@as(u32, 0), selection[0].entity_placement);
    }
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

    const seeded_selection = [_]types.Selectable{
        .{ .tile = .{ .x = 1, .y = 1 } },
        .{ .tile = .{ .x = 2, .y = 2 } },
        .{ .decoration_placement = 0 },
    };
    history.current_state.editor.?.selection = &seeded_selection;

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
    {
        const selection = history.current_state.editor.?.selection;
        try testing.expectEqual(@as(usize, 2), selection.len);
        try testing.expectEqual(types.Vector2{ .x = 2, .y = 2 }, selection[0].tile);
    }

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
    {
        const selection = history.current_state.editor.?.selection;
        try testing.expectEqual(@as(usize, 1), selection.len);
        try testing.expectEqual(types.Vector2{ .x = 2, .y = 2 }, selection[0].tile);
    }
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

    const seeded_selection = [_]types.Selectable{
        .{ .tile = .{ .x = 5, .y = 5 } },
        .{ .tile = .{ .x = 9, .y = 9 } },
    };
    history.current_state.editor.?.selection = &seeded_selection;

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
    const selection = history.current_state.editor.?.selection;
    try testing.expectEqual(@as(usize, 1), selection.len);
    try testing.expectEqual(types.Vector2{ .x = 9, .y = 9 }, selection[0].tile);
}

// --- Editor click planners (pure, directly tested) -------------------------
// The planners are the single source of truth for a click's effect: the
// handler pushes the plan, the input layer fires only nonempty plans (a
// no-op click never reaches the event log — no undo/replay step). These
// tests pin the no-op conditions at the plan level; the handler tests above
// cover the pushed-plan behavior end to end.

test "planEditorTilePaintActions: existing tile with no covering decoration is an empty plan" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();

    const tiles = [_]types.Vector2{.{ .x = 1, .y = 1 }};
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    const editor = types.Editor{ .levels = &levels };

    try testing.expectEqual(
        @as(usize, 0),
        event_handlers.planEditorTilePaintActions(&editor, .{ .x = 1, .y = 1 }, backing.allocator()).len,
    );
    // Empty ground plans the paint.
    try testing.expectEqual(
        @as(usize, 1),
        event_handlers.planEditorTilePaintActions(&editor, .{ .x = 2, .y = 1 }, backing.allocator()).len,
    );
}

test "planEditorEntityPlacementActions: no-op conditions are empty plans" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();

    // Same-type enemy on a present tile, nothing else to clear.
    const tiles = [_]types.Vector2{.{ .x = 2, .y = 2 }};
    const placements = [_]types.EntityPlacement{.{
        .type_id = 1,
        .position = .{ .x = 2, .y = 2 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .entity_placements = &placements,
    }};
    const editor = placementTestEditor(&levels);

    try testing.expectEqual(
        @as(usize, 0),
        event_handlers.planEditorEntityPlacementActions(&editor, 1, .{ .x = 2, .y = 2 }, backing.allocator()).len,
    );
    // The '!' and '=' are never overwritten.
    const marker_levels = [_]types.EditorLevel{.{
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 4, .y = 4 },
    }};
    const marker_editor = placementTestEditor(&marker_levels);
    try testing.expectEqual(
        @as(usize, 0),
        event_handlers.planEditorEntityPlacementActions(&marker_editor, 0, .{ .x = 0, .y = 0 }, backing.allocator()).len,
    );
    try testing.expectEqual(
        @as(usize, 0),
        event_handlers.planEditorEntityPlacementActions(&marker_editor, 0, .{ .x = 4, .y = 4 }, backing.allocator()).len,
    );
}

test "planEditorEntityPlacementActions: same-type occupant on a missing tile still places the tile" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();

    // Same-type enemy but NO tile under it — the click is not a no-op (the
    // tile is placed as part of it).
    const placements = [_]types.EntityPlacement{.{
        .type_id = 1,
        .position = .{ .x = 2, .y = 2 },
    }};
    const levels = [_]types.EditorLevel{.{ .entity_placements = &placements }};
    const editor = placementTestEditor(&levels);

    const plan = event_handlers.planEditorEntityPlacementActions(
        &editor,
        1,
        .{ .x = 2, .y = 2 },
        backing.allocator(),
    );
    try testing.expectEqual(@as(usize, 1), plan.len);
    try testing.expect(plan[0].editor_event.editor_set_tile.is_floor);
}

test "planEditorItemPlacementActions: same-type item on a present tile is an empty plan" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();

    const tiles = [_]types.Vector2{.{ .x = 2, .y = 2 }};
    const placements = [_]types.ItemPlacement{.{
        .type_id = 1,
        .position = .{ .x = 2, .y = 2 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .item_placements = &placements,
    }};
    const editor = itemTestEditor(&levels);

    try testing.expectEqual(
        @as(usize, 0),
        event_handlers.planEditorItemPlacementActions(&editor, 1, .{ .x = 2, .y = 2 }, backing.allocator()).len,
    );
}

test "planEditorDecorationPlacementActions: exact duplicate is an empty plan" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();

    // The same wide decoration at the same anchor — the placement is
    // already satisfied, nothing else to change.
    const existing = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 5, .y = 5 },
    }};
    const levels = [_]types.EditorLevel{.{ .decoration_placements = &existing }};
    const editor = decorationTestEditor(&levels);

    try testing.expectEqual(
        @as(usize, 0),
        event_handlers.planEditorDecorationPlacementActions(&editor, 0, .{ .x = 5, .y = 5 }, backing.allocator()).len,
    );
    // A different type at the same anchor still replaces (delete + place).
    try testing.expectEqual(
        @as(usize, 2),
        event_handlers.planEditorDecorationPlacementActions(&editor, 1, .{ .x = 5, .y = 5 }, backing.allocator()).len,
    );
}

test "player_place_editor_decoration: exact duplicate click is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const existing = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 5, .y = 5 },
    }};
    const levels = [_]types.EditorLevel{.{ .decoration_placements = &existing }};
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

    // No duplicate stacked — the one placement is the original.
    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.decoration_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 5, .y = 5 }, level.decoration_placements[0].position);
}

test "player_place_editor_decoration: duplicate kept, other overlapping decoration deleted" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The exact duplicate (wide, type 0, anchor (7,7)) plus a single-tile
    // decoration (type 1) overlapping its anchor tile, plus a clear single
    // elsewhere.
    const existing = [_]types.DecorationPlacement{
        .{ .type_id = 0, .position = .{ .x = 7, .y = 7 } },
        .{ .type_id = 1, .position = .{ .x = 8, .y = 7 } },
        .{ .type_id = 1, .position = .{ .x = 0, .y = 9 } },
    };
    const levels = [_]types.EditorLevel{.{ .decoration_placements = &existing }};
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

    // The overlapping single is gone; the duplicate survives as the one
    // wide placement; the clear single is untouched.
    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.decoration_placements.len);
    try testing.expectEqual(@as(u32, 0), level.decoration_placements[0].type_id);
    try testing.expectEqual(types.Vector2{ .x = 7, .y = 7 }, level.decoration_placements[0].position);
    try testing.expectEqual(@as(u32, 1), level.decoration_placements[1].type_id);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 9 }, level.decoration_placements[1].position);
}

test "planEditorDeleteActions: '!' / '=' / empty ground are empty plans" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();

    const levels = [_]types.EditorLevel{.{
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 4, .y = 4 },
    }};
    const editor = types.Editor{ .levels = &levels };

    try testing.expectEqual(
        @as(usize, 0),
        event_handlers.planEditorDeleteActions(&editor, .{ .x = 0, .y = 0 }, backing.allocator()).len,
    );
    try testing.expectEqual(
        @as(usize, 0),
        event_handlers.planEditorDeleteActions(&editor, .{ .x = 4, .y = 4 }, backing.allocator()).len,
    );
    try testing.expectEqual(
        @as(usize, 0),
        event_handlers.planEditorDeleteActions(&editor, .{ .x = 9, .y = 9 }, backing.allocator()).len,
    );
}

// --- Input-side no-op gate --------------------------------------------------
// A click whose plan is empty must never fire the player action — a fired
// no-op lands in the event log and becomes an undo/replay step that
// changes nothing (the pollution this gate exists to prevent).

test "editor tool click with an empty plan fires no event" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Tile tool on an existing tile (no covering decoration) → empty plan.
    const tiles = [_]types.Vector2{.{ .x = 1, .y = 1 }};
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(editorStateWith(.{ .levels = &levels }));
    runToIdle(&history);
    history.current_state.editor.?.active_tool = .tile;

    input_handlers.handleIdleInput(&history, .{ .tile_clicked = .{ .x = 1, .y = 1 } }, .{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Positive control: empty ground fires the paint.
    input_handlers.handleIdleInput(&history, .{ .tile_clicked = .{ .x = 2, .y = 1 } }, .{});
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
}

test "editor right-click delete with an empty plan fires no event" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Empty level: a right-click at (5,5) has nothing to delete.
    const empty_levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{ .levels = &empty_levels }));
    runToIdle(&history);
    history.session.ui_state.pending_right_click = .{ .editor_delete = .{
        .position = .{ .x = 5, .y = 5 },
        .press_position = .{ .x = 100, .y = 100 },
    } };

    const pointer = input.PointerInput{ .right_released = true };
    input_handlers.handleRightClickEditorDelete(
        &history,
        pointer,
        &.{},
        .{ .position = .{ .x = 0, .y = 0 } },
        1.0,
        .{ .width = 1280, .height = 720 },
    );
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    // The pending gesture is consumed either way.
    try testing.expect(history.session.ui_state.pending_right_click == null);

    // Positive control: a bare tile at the pressed position fires.
    const tiles = [_]types.Vector2{.{ .x = 5, .y = 5 }};
    const tiled_levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var tiled_history = harness.newHistory(editorStateWith(.{ .levels = &tiled_levels }));
    runToIdle(&tiled_history);
    tiled_history.session.ui_state.pending_right_click = .{ .editor_delete = .{
        .position = .{ .x = 5, .y = 5 },
        .press_position = .{ .x = 100, .y = 100 },
    } };

    input_handlers.handleRightClickEditorDelete(
        &tiled_history,
        pointer,
        &.{},
        .{ .position = .{ .x = 0, .y = 0 } },
        1.0,
        .{ .width = 1280, .height = 720 },
    );
    try testing.expectEqual(@as(usize, 1), tiled_history.current_state.event_stack.len);
}

// --- Select-tool marquee (planEditorRegionSelectActions) --------------------

const tall_footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };

fn marqueeTestEditor(levels: []const types.EditorLevel) types.Editor {
    // Decoration 0: single tile at its placement (in-region). Decoration 1:
    // a 1-wide 2-tall column — its anchor (bottom tile) sits OUTSIDE the
    // test region while the tile above it pokes in (the footprint-
    // intersection membership rule).
    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "single", .sprite = "stone_2", .footprint = &single_footprint, .pixel_dims = .{ .x = 256, .y = 256 } },
        .{ .id = "tall", .sprite = "ruin_1", .footprint = &tall_footprint, .pixel_dims = .{ .x = 256, .y = 512 } },
    };
    return .{ .levels = levels, .decoration_types = &decoration_types };
}

test "planEditorRegionSelectActions: region adds everything inside, skips present, decorates by footprint" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 9, .y = 9 } };
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 2, .y = 1 },
    }};
    const item_placements = [_]types.ItemPlacement{.{
        .type_id = 0,
        .position = .{ .x = 3, .y = 1 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{
        .{ .type_id = 0, .position = .{ .x = 7, .y = 7 } },
        .{ .type_id = 1, .position = .{ .x = 5, .y = 10 } },
    };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 9, .y = 0 },
        .entity_placements = &entity_placements,
        .item_placements = &item_placements,
        .decoration_placements = &decoration_placements,
    }};
    var history = harness.newHistory(editorStateWith(marqueeTestEditor(&levels)));
    runToIdle(&history);

    // The (1,1) tile is already selected — the marquee must SKIP it.
    const seeded_selection = [_]types.Selectable{.{ .tile = .{ .x = 1, .y = 1 } }};
    history.current_state.editor.?.selection = &seeded_selection;

    const arena = history.current_arena.allocator();
    const editor = &history.current_state.editor.?;
    const plan = event_handlers.planEditorRegionSelectActions(
        editor,
        .{ .x = 0, .y = 0 },
        .{ .x = 9, .y = 9 },
        arena,
    );

    // The returned slice is REVERSED (LIFO convention — see the planner
    // doc): pushEvents pushes slice order, the stack pops from the end, so
    // PROCESSING + log order is the reverse of this slice: tiles, entity,
    // item, decorations, player_start, level_end — with the already-
    // selected (1,1) tile skipped and the tall decoration included via its
    // NON-anchor footprint tile (5,9).
    try testing.expectEqual(@as(usize, 8), plan.len);
    try testing.expectEqual(types.Selectable.level_end, plan[0].editor_event.editor_select.entry);
    try testing.expectEqual(types.Selectable.player_start, plan[1].editor_event.editor_select.entry);
    try testing.expectEqual(types.Selectable{ .decoration_placement = 1 }, plan[2].editor_event.editor_select.entry);
    try testing.expectEqual(types.Selectable{ .decoration_placement = 0 }, plan[3].editor_event.editor_select.entry);
    try testing.expectEqual(types.Selectable{ .ground_item_placement = 0 }, plan[4].editor_event.editor_select.entry);
    try testing.expectEqual(types.Selectable{ .entity_placement = 0 }, plan[5].editor_event.editor_select.entry);
    try testing.expectEqual(types.Selectable{ .tile = .{ .x = 9, .y = 9 } }, plan[6].editor_event.editor_select.entry);
    try testing.expectEqual(types.Selectable{ .tile = .{ .x = 2, .y = 1 } }, plan[7].editor_event.editor_select.entry);

    // Empty region (nothing there) → empty plan (no player action fires).
    const empty_plan = event_handlers.planEditorRegionSelectActions(
        editor,
        .{ .x = 20, .y = 20 },
        .{ .x = 21, .y = 21 },
        arena,
    );
    try testing.expectEqual(@as(usize, 0), empty_plan.len);
}

test "player_select_editor_region: adds the region in one undoable step" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
    }};
    var history = harness.newHistory(editorStateWith(marqueeTestEditor(&levels)));
    runToIdle(&history);

    // Marquee over (1,1)-(2,1): both tiles + the player start (0,0) is
    // OUTSIDE the region (the rect is inclusive between the corners).
    event_handlers.pushPlayerAction(
        &history.current_state,
        .{ .player_select_editor_region = .{
            .start_position = .{ .x = 1, .y = 1 },
            .end_position = .{ .x = 2, .y = 1 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    {
        const selection = history.current_state.editor.?.selection;
        try testing.expectEqual(@as(usize, 2), selection.len);
        // Processing order = plan order: tiles first.
        try testing.expectEqual(types.Selectable{ .tile = .{ .x = 1, .y = 1 } }, selection[0]);
        try testing.expectEqual(types.Selectable{ .tile = .{ .x = 2, .y = 1 } }, selection[1]);
    }

    // The whole marquee is ONE undo step (all its editor_selects share the
    // player action's idle point) — undo reverts the batch together.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);
    // Redo walks it back in.
    try testing.expect(history.redo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.selection.len);

    // Marquee over an all-already-selected region → nothing new → no
    // player action should fire from the input layer; the handler's empty
    // plan replays a crafted redundant event gracefully (selection
    // unchanged, no duplicates).
    const selection_before = history.current_state.editor.?.selection.len;
    event_handlers.pushPlayerAction(
        &history.current_state,
        .{ .player_select_editor_region = .{
            .start_position = .{ .x = 1, .y = 1 },
            .end_position = .{ .x = 2, .y = 1 },
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(selection_before, history.current_state.editor.?.selection.len);
}

test "player_delete_editor_selection: deletes everything selected except the markers and their tiles" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Entities 0 (selected) + 1 (the occupant of selected tile (5,5) —
    // unselected, swept with its tile). Item 0: the occupant of selected
    // tile (6,6), also swept. Decoration 0 (single tile at (7,7)):
    // selected. Marker tiles (0,0) + (9,9): selected but protected.
    const tiles = [_]types.Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 }, .{ .x = 6, .y = 6 },
        .{ .x = 8, .y = 8 }, .{ .x = 9, .y = 9 },
    };
    const entity_placements = [_]types.EntityPlacement{
        .{ .type_id = 0, .position = .{ .x = 1, .y = 1 } },
        .{ .type_id = 0, .position = .{ .x = 5, .y = 5 } },
    };
    const item_placements = [_]types.ItemPlacement{.{
        .type_id = 0,
        .position = .{ .x = 6, .y = 6 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 7, .y = 7 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 9, .y = 9 },
        .entity_placements = &entity_placements,
        .item_placements = &item_placements,
        .decoration_placements = &decoration_placements,
    }};
    var history = harness.newHistory(editorStateWith(marqueeTestEditor(&levels)));
    const seeded_selection = [_]types.Selectable{
        .{ .tile = .{ .x = 0, .y = 0 } },
        .player_start,
        .{ .tile = .{ .x = 9, .y = 9 } },
        .level_end,
        .{ .entity_placement = 0 },
        .{ .tile = .{ .x = 5, .y = 5 } },
        .{ .tile = .{ .x = 6, .y = 6 } },
        .{ .tile = .{ .x = 8, .y = 8 } },
        .{ .decoration_placement = 0 },
    };
    history.current_state.editor.?.selection = &seeded_selection;
    runToIdle(&history);

    // The plan (returned slice = REVERSE processing order per the LIFO
    // convention): processing runs the entity deletes high-before-low
    // (1 then 0 — index stability), then the item, then the decoration,
    // then the tile erases. The markers + their tiles plan NOTHING.
    {
        const plan = event_handlers.planEditorSelectionDeleteActions(
            &history.current_state.editor.?,
            history.current_arena.allocator(),
        );
        try testing.expectEqual(@as(usize, 7), plan.len);
        try testing.expectEqual(types.Vector2{ .x = 8, .y = 8 }, plan[0].editor_event.editor_set_tile.position);
        try testing.expectEqual(types.Vector2{ .x = 6, .y = 6 }, plan[1].editor_event.editor_set_tile.position);
        try testing.expectEqual(types.Vector2{ .x = 5, .y = 5 }, plan[2].editor_event.editor_set_tile.position);
        try testing.expectEqual(@as(u32, 0), plan[3].editor_event.editor_delete_decoration_placement.placement_index);
        try testing.expectEqual(@as(u32, 0), plan[4].editor_event.editor_delete_item_placement.placement_index);
        try testing.expectEqual(@as(u32, 0), plan[5].editor_event.editor_delete_entity_placement.placement_index);
        try testing.expectEqual(@as(u32, 1), plan[6].editor_event.editor_delete_entity_placement.placement_index);
    }

    event_handlers.pushPlayerAction(
        &history.current_state,
        .player_delete_editor_selection,
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    {
        const level = history.current_state.editor.?.levels[0];
        // Everything deletable is gone: both entities (one selected, one
        // swept with its tile), the swept item, the decoration, and the
        // three real tiles. The markers + their tiles survive.
        try testing.expectEqual(@as(usize, 0), level.entity_placements.len);
        try testing.expectEqual(@as(usize, 0), level.item_placements.len);
        try testing.expectEqual(@as(usize, 0), level.decoration_placements.len);
        try testing.expect(hasTile(level, .{ .x = 0, .y = 0 }));
        try testing.expect(hasTile(level, .{ .x = 9, .y = 9 }));
        try testing.expect(!hasTile(level, .{ .x = 5, .y = 5 }));
        try testing.expect(!hasTile(level, .{ .x = 6, .y = 6 }));
        try testing.expect(!hasTile(level, .{ .x = 8, .y = 8 }));
        try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.player_start);
        try testing.expectEqual(types.Vector2{ .x = 9, .y = 9 }, level.level_end.?);

        // The selection keeps exactly the protected remainder (the deleted
        // entries were pruned by the delete arms' reconcile; the marker
        // entries + surviving marker tiles stay).
        const selection = history.current_state.editor.?.selection;
        try testing.expectEqual(@as(usize, 4), selection.len);
        try testing.expectEqual(types.Selectable{ .tile = .{ .x = 0, .y = 0 } }, selection[0]);
        try testing.expectEqual(types.Selectable.player_start, selection[1]);
        try testing.expectEqual(types.Selectable{ .tile = .{ .x = 9, .y = 9 } }, selection[2]);
        try testing.expectEqual(types.Selectable.level_end, selection[3]);
    }

    // One undo step reverts the WHOLE deletion (all the deletes share the
    // player action's idle point): placements + tiles + the selection.
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const level = history.current_state.editor.?.levels[0];
        try testing.expectEqual(@as(usize, 2), level.entity_placements.len);
        try testing.expectEqual(@as(usize, 1), level.item_placements.len);
        try testing.expectEqual(@as(usize, 1), level.decoration_placements.len);
        try testing.expect(hasTile(level, .{ .x = 5, .y = 5 }));
        try testing.expect(hasTile(level, .{ .x = 8, .y = 8 }));
        try testing.expectEqual(@as(usize, 9), history.current_state.editor.?.selection.len);
    }
}

test "player_delete_editor_selection: an all-marker selection plans nothing (no-op gate)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
    }};
    var history = harness.newHistory(editorStateWith(marqueeTestEditor(&levels)));
    const seeded_selection = [_]types.Selectable{ .player_start, .{ .tile = .{ .x = 0, .y = 0 } } };
    history.current_state.editor.?.selection = &seeded_selection;
    runToIdle(&history);

    const plan = event_handlers.planEditorSelectionDeleteActions(
        &history.current_state.editor.?,
        history.current_arena.allocator(),
    );
    try testing.expectEqual(@as(usize, 0), plan.len);

    // Through the input layer: no player action fires (no dead undo step),
    // and the protected selection is untouched.
    input_handlers.handleIdleInput(&history, .{ .delete_editor_selection = true }, .{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.selection.len);

    // With a deletable tile selected, the same key press fires the
    // orchestrator.
    const with_deletable = [_]types.Selectable{ .player_start, .{ .tile = .{ .x = 0, .y = 0 } }, .{ .tile = .{ .x = 2, .y = 2 } } };
    history.current_state.editor.?.selection = &with_deletable;
    input_handlers.handleIdleInput(&history, .{ .delete_editor_selection = true }, .{});
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try testing.expect(history.current_state.event_stack[0].player_input_event == .player_delete_editor_selection);
}

test "player_clear_editor_selection: ctrl+D clears everything, gated on a nonempty selection, undo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
    }};
    const seeded_selection = [_]types.Selectable{
        .{ .tile = .{ .x = 1, .y = 1 } },
        .player_start,
        .{ .decoration_placement = 0 },
    };
    var history = harness.newHistory(editorStateWith(marqueeTestEditor(&levels)));
    history.current_state.editor.?.selection = &seeded_selection;
    runToIdle(&history);

    // An empty selection never fires (no dead undo step).
    history.current_state.editor.?.selection = &.{};
    input_handlers.handleIdleInput(&history, .{ .clear_editor_selection = true }, .{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // A nonempty selection fires the orchestrator; the single clear event
    // empties it; one undo step restores the selection.
    history.current_state.editor.?.selection = &seeded_selection;
    input_handlers.handleIdleInput(&history, .{ .clear_editor_selection = true }, .{});
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try testing.expect(history.current_state.event_stack[0].player_input_event == .player_clear_editor_selection);
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);

    try testing.expect(history.undo(event_handlers.processEvent));
    const selection = history.current_state.editor.?.selection;
    try testing.expectEqual(@as(usize, 3), selection.len);
    try testing.expectEqual(types.Selectable{ .tile = .{ .x = 1, .y = 1 } }, selection[0]);
    try testing.expectEqual(types.Selectable.player_start, selection[1]);
    try testing.expectEqual(types.Selectable{ .decoration_placement = 0 }, selection[2]);
}

test "player_select_editor_all: ctrl+A selects everything, skips present, one undo restores the prior selection" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Same fixture shape as the marquee region test: 3 tiles + 1 entity +
    // 1 item + 2 decorations + the '!' + the '=' = 9 selectable things.
    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 9, .y = 9 } };
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 2, .y = 1 },
    }};
    const item_placements = [_]types.ItemPlacement{.{
        .type_id = 0,
        .position = .{ .x = 3, .y = 1 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{
        .{ .type_id = 0, .position = .{ .x = 7, .y = 7 } },
        .{ .type_id = 1, .position = .{ .x = 5, .y = 10 } },
    };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 9, .y = 0 },
        .entity_placements = &entity_placements,
        .item_placements = &item_placements,
        .decoration_placements = &decoration_placements,
    }};
    var history = harness.newHistory(editorStateWith(marqueeTestEditor(&levels)));
    // Seed BEFORE runToIdle so the idle-point snapshot captures the
    // partial selection (undo replays to that snapshot).
    const seeded_selection = [_]types.Selectable{
        .{ .tile = .{ .x = 1, .y = 1 } },
        .player_start,
    };
    history.current_state.editor.?.selection = &seeded_selection;
    runToIdle(&history);

    // ctrl+A adds the other 7, skipping the present two — one player
    // action, one undo step.
    input_handlers.handleIdleInput(&history, .{ .select_editor_all = true }, .{});
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try testing.expect(
        history.current_state.event_stack[0].player_input_event == .player_select_editor_all,
    );
    runToIdle(&history);

    const selection = history.current_state.editor.?.selection;
    try testing.expectEqual(@as(usize, 9), selection.len);
    try testing.expect(selectionContainsEntry(selection, .{ .tile = .{ .x = 9, .y = 9 } }));
    try testing.expect(selectionContainsEntry(selection, .{ .entity_placement = 0 }));
    try testing.expect(selectionContainsEntry(selection, .{ .ground_item_placement = 0 }));
    try testing.expect(selectionContainsEntry(selection, .{ .decoration_placement = 0 }));
    try testing.expect(selectionContainsEntry(selection, .{ .decoration_placement = 1 }));
    try testing.expect(selectionContainsEntry(selection, .level_end));

    // One undo reverts the whole batch back to the seeded partial.
    try testing.expect(history.undo(event_handlers.processEvent));
    const restored = history.current_state.editor.?.selection;
    try testing.expectEqual(@as(usize, 2), restored.len);
    try testing.expectEqual(types.Selectable{ .tile = .{ .x = 1, .y = 1 } }, restored[0]);
    try testing.expectEqual(types.Selectable.player_start, restored[1]);
}

test "text field commit: entity name end-to-end, no-op gate, cancel" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .team = 1 } },
    };
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
    }));
    runToIdle(&history);

    const no_keys: [0]?[]const u8 = .{};
    const enter_pressed: [1]?[]const u8 = .{"Enter"};
    const escape_pressed: [1]?[]const u8 = .{"Escape"};
    const field: types.TextFieldRef = .{ .id = .entity_name, .target = .{ .entity_type = 0 } };

    // Focus (slice 3's field click does this via beginTextEdit), type
    // through the real routing path, resolve the Enter outcome.
    // loadValue seeds the caret at the END, so typing appends.
    ui.beginTextEdit(&history.session.ui_state, field, "Skeleton");
    const outcome = ui.routeTextInput(
        &history.session.ui_state.text_edit.?,
        " Knight",
        &enter_pressed,
        &no_keys,
        false,
    );
    try testing.expectEqual(types.TextEditOutcome.commit, outcome);
    input_handlers.resolveTextEditOutcome(&history, .commit);

    try testing.expectEqualStrings(
        "Skeleton Knight",
        history.current_state.editor.?.entity_types[0].template.name,
    );
    // Focus dropped, the action drained (stack empty).
    try testing.expect(history.session.ui_state.text_edit == null);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // One undo reverts to the old name (the edit rode the timeline).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings(
        "Skeleton",
        history.current_state.editor.?.entity_types[0].template.name,
    );
    // And redo re-applies it — the regression check: the commit used to
    // record no undo stop, so undo stepped PAST the edit (discarding it
    // from the future timeline) and redo had nothing to restore.
    try testing.expect(history.redo(event_handlers.processEvent));
    try testing.expectEqualStrings(
        "Skeleton Knight",
        history.current_state.editor.?.entity_types[0].template.name,
    );
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings(
        "Skeleton",
        history.current_state.editor.?.entity_types[0].template.name,
    );

    // No-op gate: a commit whose buffer equals the current value records
    // nothing (no dead undo step) — but still drops focus.
    ui.beginTextEdit(&history.session.ui_state, field, "Skeleton");
    input_handlers.resolveTextEditOutcome(&history, .commit);
    try testing.expectEqualStrings(
        "Skeleton",
        history.current_state.editor.?.entity_types[0].template.name,
    );
    try testing.expect(history.session.ui_state.text_edit == null);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Cancel: Escape discards the buffer — nothing recorded, name intact.
    ui.beginTextEdit(&history.session.ui_state, field, "Skeleton");
    const cancel_outcome = ui.routeTextInput(
        &history.session.ui_state.text_edit.?,
        " Renamed",
        &escape_pressed,
        &no_keys,
        false,
    );
    try testing.expectEqual(types.TextEditOutcome.cancel, cancel_outcome);
    input_handlers.resolveTextEditOutcome(&history, .cancel);
    try testing.expectEqualStrings(
        "Skeleton",
        history.current_state.editor.?.entity_types[0].template.name,
    );
    try testing.expect(history.session.ui_state.text_edit == null);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "text field commit: entity sprite edits ride the same path (v1 text field, picker later)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 } },
    };
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
    }));
    runToIdle(&history);

    const no_keys: [0]?[]const u8 = .{};
    const enter_pressed: [1]?[]const u8 = .{"Enter"};
    const field: types.TextFieldRef = .{ .id = .entity_sprite, .target = .{ .entity_type = 0 } };

    ui.beginTextEdit(&history.session.ui_state, field, "skeleton_1");
    const outcome = ui.routeTextInput(
        &history.session.ui_state.text_edit.?,
        "_elite",
        &enter_pressed,
        &no_keys,
        false,
    );
    try testing.expectEqual(types.TextEditOutcome.commit, outcome);
    input_handlers.resolveTextEditOutcome(&history, .commit);

    try testing.expectEqualStrings(
        "skeleton_1_elite",
        history.current_state.editor.?.entity_types[0].template.sprite,
    );
    try testing.expect(history.session.ui_state.text_edit == null);

    // One undo reverts the sprite (name untouched).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings(
        "skeleton_1",
        history.current_state.editor.?.entity_types[0].template.sprite,
    );
    try testing.expectEqualStrings(
        "Skeleton",
        history.current_state.editor.?.entity_types[0].template.name,
    );
}

test "inspector scalar clicks: color swatch + displays-weapons toggle ride the timeline" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .team = 1 }, // color_index 0, displays_weapons true
    }};
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    }));
    runToIdle(&history);

    // Swatch click: color_index 0 → 3 (the payload rode in
    // clicked_editor_color; the target is the active enemy tool).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_entity_color,
        .clicked_editor_color = 3,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 3), history.current_state.editor.?.entity_types[0].template.color_index);

    // Same-value pick never fires (no dead undo step).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_entity_color,
        .clicked_editor_color = 3,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Toggle: true → false; a flip always changes, so no gate.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_entity_displays_weapons,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(!history.current_state.editor.?.entity_types[0].template.displays_weapons);

    // One undo reverts the toggle; another reverts the color (one step per
    // committed edit).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.editor.?.entity_types[0].template.displays_weapons);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(u32, 0), history.current_state.editor.?.entity_types[0].template.color_index);

    // No enemy tool active (select tool): both clicks no-op.
    history.current_state.editor.?.active_tool = .select;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_entity_color,
        .clicked_editor_color = 5,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_entity_displays_weapons,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expectEqual(@as(u32, 0), history.current_state.editor.?.entity_types[0].template.color_index);
}

test "inspector stat commits: numeric parse, unbounded clamp, empty no-op, leading-zero no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .team = 1, .max_health = 20 },
    }};
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
    }));
    runToIdle(&history);

    const no_keys: [0]?[]const u8 = .{};
    const backspace_pressed: [1]?[]const u8 = .{"Backspace"};
    const field: types.TextFieldRef = .{ .id = .{ .entity_stat = .max_health }, .target = .{ .entity_type = 0 } };

    // Edit 20 → 25 (backspace the 0, type 5): parsed + committed.
    ui.beginTextEdit(&history.session.ui_state, field, "20");
    _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "", &backspace_pressed, &no_keys, false);
    _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "5", &no_keys, &no_keys, false);
    input_handlers.resolveTextEditOutcome(&history, .commit);
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 25), history.current_state.editor.?.entity_types[0].template.max_health);

    // Overflow clamps to u32 max (base stats are unbounded by design).
    ui.beginTextEdit(&history.session.ui_state, field, "25");
    _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "99999999999", &no_keys, &no_keys, false);
    input_handlers.resolveTextEditOutcome(&history, .commit);
    try testing.expectEqual(std.math.maxInt(u32), history.current_state.editor.?.entity_types[0].template.max_health);

    // Empty buffer commits nothing (no event, value intact, focus dropped).
    ui.beginTextEdit(&history.session.ui_state, field, "99999999999");
    for (0..11) |_| {
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "", &backspace_pressed, &no_keys, false);
    }
    input_handlers.resolveTextEditOutcome(&history, .commit);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expectEqual(std.math.maxInt(u32), history.current_state.editor.?.entity_types[0].template.max_health);
    try testing.expect(history.session.ui_state.text_edit == null);

    // Leading zeros that parse to the current value record nothing (numeric
    // would-change semantics, not a string compare). ONE undo reverts the
    // overflow commit (two would also revert the 20→25 edit).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(u32, 25), history.current_state.editor.?.entity_types[0].template.max_health);
    // Seed with the CURRENT value, move the caret to the start, then type
    // a leading zero: "025" parses to 25 == current → no event.
    ui.beginTextEdit(&history.session.ui_state, field, "25");
    const home: [2]?[]const u8 = .{ "ArrowLeft", "ArrowLeft" };
    _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "", &home, &no_keys, false);
    _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "0", &no_keys, &no_keys, false);
    try testing.expectEqualStrings("025", history.session.ui_state.text_edit.?.buffer.currentText());
    input_handlers.resolveTextEditOutcome(&history, .commit);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "inspector item commits: weapon name + damage (bounded), empty-slot and wrong-stat no-ops" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{
            .name = "Skeleton",
            .team = 1,
            .main_hand_weapon = .{ .name = "Skeleton Sword", .weapon_type = .sword, .weapon_damage = 5 },
            .coat = .{ .name = "Skeleton Coat", .health_bonus = 2, .defense_bonus = 1 },
        },
    }};
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
    }));
    runToIdle(&history);

    const no_keys: [0]?[]const u8 = .{};
    const target: types.EntityEditTarget = .{ .entity_type = 0 };

    // Weapon NAME: the whole-item event carries the edit (type + damage
    // ride along untouched); one undo restores.
    {
        const field: types.TextFieldRef = .{ .id = .{ .item_name = .main_hand }, .target = target };
        ui.beginTextEdit(&history.session.ui_state, field, "Skeleton Sword");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, " of Doom", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        const weapon = history.current_state.editor.?.entity_types[0].template.main_hand_weapon.?;
        try testing.expectEqualStrings("Skeleton Sword of Doom", weapon.name);
        try testing.expectEqual(types.WeaponType.sword, weapon.weapon_type);
        try testing.expectEqual(@as(u32, 5), weapon.weapon_damage);
        try testing.expect(history.undo(event_handlers.processEvent));
        try testing.expectEqualStrings(
            "Skeleton Sword",
            history.current_state.editor.?.entity_types[0].template.main_hand_weapon.?.name,
        );
    }

    // Weapon DAMAGE: bounded — an out-of-range buffer clamps to
    // max_weapon_damage (the parser's own bound, single-sourced).
    {
        const field: types.TextFieldRef = .{
            .id = .{ .item_stat = .{ .slot = .main_hand, .stat = .weapon_damage } },
            .target = target,
        };
        ui.beginTextEdit(&history.session.ui_state, field, "5");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "99", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(
            types.max_weapon_damage,
            history.current_state.editor.?.entity_types[0].template.main_hand_weapon.?.weapon_damage,
        );
    }

    // A stat the item kind doesn't carry commits nothing (a coat has no
    // weapon_damage) — nothing recorded, focus dropped.
    {
        const field: types.TextFieldRef = .{
            .id = .{ .item_stat = .{ .slot = .coat, .stat = .weapon_damage } },
            .target = target,
        };
        ui.beginTextEdit(&history.session.ui_state, field, "");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "7", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
        try testing.expect(history.session.ui_state.text_edit == null);
    }

    // An EMPTY slot commits nothing (no amulet to rename).
    {
        const field: types.TextFieldRef = .{ .id = .{ .item_name = .amulet }, .target = target };
        ui.beginTextEdit(&history.session.ui_state, field, "");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "Amulet", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
        try testing.expect(history.current_state.editor.?.entity_types[0].template.amulet == null);
    }
}

test "inspector slot clicks: weapon create/retype/delete, gear add/delete" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{
            .name = "Skeleton",
            .team = 1,
            .main_hand_weapon = .{ .name = "Skeleton Sword", .weapon_type = .sword, .weapon_damage = 5 },
        },
    }};
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    }));
    runToIdle(&history);

    // Weapon-type pick on the EMPTY off hand: creates the default weapon
    // ("New Axe", damage 0); one undo clears the slot again.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_weapon_type,
        .clicked_editor_gear_slot = .off_hand,
        .clicked_editor_weapon_type = .axe,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    {
        const weapon = history.current_state.editor.?.entity_types[0].template.off_hand_weapon.?;
        try testing.expectEqualStrings("New Axe", weapon.name);
        try testing.expectEqual(types.WeaponType.axe, weapon.weapon_type);
        try testing.expectEqual(@as(u32, 0), weapon.weapon_damage);
    }
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.editor.?.entity_types[0].template.off_hand_weapon == null);

    // Type pick on the EQUIPPED main hand with a DIFFERENT type: retypes
    // in place — name + damage stay.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_weapon_type,
        .clicked_editor_gear_slot = .main_hand,
        .clicked_editor_weapon_type = .spear,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    {
        const weapon = history.current_state.editor.?.entity_types[0].template.main_hand_weapon.?;
        try testing.expectEqualStrings("Skeleton Sword", weapon.name);
        try testing.expectEqual(types.WeaponType.spear, weapon.weapon_type);
        try testing.expectEqual(@as(u32, 5), weapon.weapon_damage);
    }

    // Same-type pick never fires (no dead undo step).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_weapon_type,
        .clicked_editor_gear_slot = .main_hand,
        .clicked_editor_weapon_type = .spear,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Delete clears the slot to null; delete on an empty slot is a no-op.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_item,
        .clicked_editor_gear_slot = .main_hand,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.current_state.editor.?.entity_types[0].template.main_hand_weapon == null);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_item,
        .clicked_editor_gear_slot = .main_hand,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Gear Add creates the default item ("New Amulet", zero stats);
    // add on a present item never fires.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_item,
        .clicked_editor_gear_slot = .amulet,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    {
        const amulet = history.current_state.editor.?.entity_types[0].template.amulet.?;
        try testing.expectEqualStrings("New Amulet", amulet.name);
        try testing.expectEqual(@as(u32, 0), amulet.spell_damage);
    }
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_item,
        .clicked_editor_gear_slot = .amulet,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Weapon slots don't take gear Add (their creation path is the type
    // row) — the gate holds for crafted input.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_item,
        .clicked_editor_gear_slot = .main_hand,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "inspector wheel routing: scrolls over the open panel, not elsewhere" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    // Inside the open panel (default open): one wheel-down notch = one
    // row down; wheel-up at the top clamps at 0.
    const inside: types.ScreenPosition = .{
        .x = 512,
        .y = ui.editorInspectorPanelRect().y + 100,
    };
    input_handlers.handleAnytimeInput(&history, .{ .scroll_delta = -1 }, inside, &.{});
    try testing.expectEqual(@as(i32, 1), history.session.ui_state.editor_inspector_scroll);
    input_handlers.handleAnytimeInput(&history, .{ .scroll_delta = 1 }, inside, &.{});
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_inspector_scroll);

    // Outside the panel (top-right, over no UI): the wheel belongs to the
    // camera-zoom branch — the inspector offset is untouched.
    input_handlers.handleAnytimeInput(
        &history,
        .{ .scroll_delta = -1 },
        .{ .x = 2000, .y = 300 },
        &.{},
    );
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_inspector_scroll);

    // Panel closed: the routing falls through even inside the rect.
    history.current_state.editor.?.inspector_open = false;
    input_handlers.handleAnytimeInput(&history, .{ .scroll_delta = -1 }, inside, &.{});
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_inspector_scroll);
}

test "player_select_editor_all: no-op without the select tool, and when everything is already selected" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
    }};
    var history = harness.newHistory(editorStateWith(marqueeTestEditor(&levels)));
    runToIdle(&history);

    // Not the select tool (a paint tool): the selection ops are
    // select-tool-only, so ctrl+A never fires.
    history.current_state.editor.?.active_tool = .tile;
    input_handlers.handleIdleInput(&history, .{ .select_editor_all = true }, .{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Select tool, but everything (the tile + the '!') is already
    // selected: the plan is empty, so nothing fires (no dead undo step).
    history.current_state.editor.?.active_tool = .select;
    const everything = [_]types.Selectable{ .{ .tile = .{ .x = 1, .y = 1 } }, .player_start };
    history.current_state.editor.?.selection = &everything;
    input_handlers.handleIdleInput(&history, .{ .select_editor_all = true }, .{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

/// Membership check for a `Selectable` entry in a selection slice (test-
/// local; the production `selectionContains` is file-private in
/// event_handlers.zig).
fn selectionContainsEntry(selection: []const types.Selectable, entry: types.Selectable) bool {
    for (selection) |selected| {
        if (std.meta.eql(selected, entry)) return true;
    }
    return false;
}

// --- Select-tool selection move (player_move_editor_selection) -------------

fn moveTestEditor(levels: []const types.EditorLevel) types.Editor {
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 } },
    };
    const item_types = [_]types.ItemTypeDef{.{
        .id = "Iron Sword",
        .item = .{ .weapon = .{} },
    }};
    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "single", .sprite = "stone_2", .footprint = &single_footprint, .pixel_dims = .{ .x = 256, .y = 256 } },
        .{ .id = "wide", .sprite = "ruin_1", .footprint = &two_wide_footprint, .pixel_dims = .{ .x = 512, .y = 256 } },
    };
    return .{
        .levels = levels,
        .entity_types = &entity_types,
        .item_types = &item_types,
        .decoration_types = &decoration_types,
    };
}

test "player_move_editor_selection: moves the whole selection, deselects after, one undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // No tile under the decoration at (5,5) — a legal state (decoration
    // footprint tiles are tile-free by the placement invariant; a selected
    // decoration never has a selected tile beneath it).
    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } };
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 1, .y = 1 },
    }};
    const item_placements = [_]types.ItemPlacement{.{
        .type_id = 0,
        .position = .{ .x = 2, .y = 1 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 5, .y = 5 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 9, .y = 9 },
        .entity_placements = &entity_placements,
        .item_placements = &item_placements,
        .decoration_placements = &decoration_placements,
    }};
    const seeded_selection = [_]types.Selectable{
        .{ .tile = .{ .x = 1, .y = 1 } },
        .{ .entity_placement = 0 },
        .{ .tile = .{ .x = 2, .y = 1 } },
        .{ .ground_item_placement = 0 },
        .{ .decoration_placement = 0 },
        .player_start,
    };
    var history = harness.newHistory(editorStateWith(moveTestEditor(&levels)));
    history.current_state.editor.?.selection = &seeded_selection;
    runToIdle(&history);

    // Move everything down 3 rows. The moved player start lands on empty
    // ground (0,3) — a tile is ensured under it.
    event_handlers.pushPlayerAction(
        &history.current_state,
        .{ .player_move_editor_selection = .{ .delta = .{ .x = 0, .y = 3 } } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    {
        const level = history.current_state.editor.?.levels[0];
        // Everything moved; the sources are cleared (their occupants were
        // selected, so nothing pinned the tiles).
        try testing.expectEqual(@as(usize, 1), level.entity_placements.len);
        try testing.expectEqual(types.Vector2{ .x = 1, .y = 4 }, level.entity_placements[0].position);
        try testing.expectEqual(@as(usize, 1), level.item_placements.len);
        try testing.expectEqual(types.Vector2{ .x = 2, .y = 4 }, level.item_placements[0].position);
        try testing.expectEqual(@as(usize, 1), level.decoration_placements.len);
        try testing.expectEqual(types.Vector2{ .x = 5, .y = 8 }, level.decoration_placements[0].position);
        try testing.expect(!hasTile(level, .{ .x = 1, .y = 1 }));
        try testing.expect(!hasTile(level, .{ .x = 2, .y = 1 }));
        try testing.expect(hasTile(level, .{ .x = 1, .y = 4 }));
        try testing.expect(hasTile(level, .{ .x = 2, .y = 4 }));
        // The decoration's target is tile-free by its own placement rules
        // (footprint tiles are erased when it lands).
        try testing.expect(!hasTile(level, .{ .x = 5, .y = 8 }));
        // The '!' moved to (0,3) with a tile ensured under it; the '=' and
        // the '!' old tile are untouched.
        try testing.expectEqual(types.Vector2{ .x = 0, .y = 3 }, level.player_start);
        try testing.expect(hasTile(level, .{ .x = 0, .y = 3 }));
        try testing.expectEqual(types.Vector2{ .x = 9, .y = 9 }, level.level_end.?);

        // A move deselects — nothing is reselected.
        try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);
    }

    // ONE undo step reverts the whole move: positions, tiles, the marker,
    // and the selection.
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const level = history.current_state.editor.?.levels[0];
        try testing.expectEqual(types.Vector2{ .x = 1, .y = 1 }, level.entity_placements[0].position);
        try testing.expectEqual(types.Vector2{ .x = 2, .y = 1 }, level.item_placements[0].position);
        try testing.expectEqual(types.Vector2{ .x = 5, .y = 5 }, level.decoration_placements[0].position);
        try testing.expect(hasTile(level, .{ .x = 1, .y = 1 }));
        try testing.expect(!hasTile(level, .{ .x = 1, .y = 4 }));
        try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.player_start);
        try testing.expect(!hasTile(level, .{ .x = 0, .y = 3 }));
        try testing.expectEqual(@as(usize, 6), history.current_state.editor.?.selection.len);
    }
}

test "player_move_editor_selection: an unselected occupant pins its tile (no sweep)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A selected tile whose occupant is NOT selected: the occupant pins its
    // ground — the tile stays underneath it and the moved tile lands at the
    // target instead (nothing is swept).
    const tiles = [_]types.Vector2{.{ .x = 5, .y = 5 }};
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 5, .y = 5 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .entity_placements = &entity_placements,
    }};
    const seeded_selection = [_]types.Selectable{.{ .tile = .{ .x = 5, .y = 5 } }};
    var history = harness.newHistory(editorStateWith(moveTestEditor(&levels)));
    history.current_state.editor.?.selection = &seeded_selection;
    runToIdle(&history);

    event_handlers.pushPlayerAction(
        &history.current_state,
        .{ .player_move_editor_selection = .{ .delta = .{ .x = 1, .y = 0 } } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.entity_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 5, .y = 5 }, level.entity_placements[0].position);
    try testing.expect(hasTile(level, .{ .x = 5, .y = 5 }));
    try testing.expect(hasTile(level, .{ .x = 6, .y = 5 }));
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);
}

test "player_move_editor_selection: a target on a marker drops the thing entirely" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Moving an entity (+ its tile) ONTO the '!' at (0,0): the entity plans
    // empty (markers are never overwritten) and the tile paints over an
    // existing tile (also empty) — both are deleted fully.
    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } };
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 1, .y = 1 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .entity_placements = &entity_placements,
    }};
    const seeded_selection = [_]types.Selectable{
        .{ .tile = .{ .x = 1, .y = 1 } },
        .{ .entity_placement = 0 },
    };
    var history = harness.newHistory(editorStateWith(moveTestEditor(&levels)));
    history.current_state.editor.?.selection = &seeded_selection;
    runToIdle(&history);

    event_handlers.pushPlayerAction(
        &history.current_state,
        .{ .player_move_editor_selection = .{ .delta = .{ .x = -1, .y = -1 } } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 0), level.entity_placements.len);
    try testing.expect(!hasTile(level, .{ .x = 1, .y = 1 }));
    try testing.expect(hasTile(level, .{ .x = 0, .y = 0 }));
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.player_start);
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);
}

test "player_move_editor_selection: chained placement handles targets sharing a covering decoration" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // THE chain-motivating case: a wide decoration covers both move
    // targets. Up-front planning would plan its deletion TWICE (stale
    // index → panic); the chain plans each entry against the live state —
    // the first entry's placement removes the decoration, the second
    // places cleanly.
    const wide_decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 1,
        .position = .{ .x = 4, .y = 4 },
    }};
    const entity_placements = [_]types.EntityPlacement{
        .{ .type_id = 0, .position = .{ .x = 1, .y = 1 } },
        .{ .type_id = 0, .position = .{ .x = 2, .y = 1 } },
    };
    const levels = [_]types.EditorLevel{.{
        .player_start = .{ .x = 0, .y = 0 },
        .entity_placements = &entity_placements,
        .decoration_placements = &wide_decoration_placements,
    }};
    const seeded_selection = [_]types.Selectable{
        .{ .entity_placement = 0 },
        .{ .entity_placement = 1 },
    };
    var history = harness.newHistory(editorStateWith(moveTestEditor(&levels)));
    history.current_state.editor.?.selection = &seeded_selection;
    runToIdle(&history);

    // Targets (4,4) + (5,4) — both under the wide footprint (the
    // decoration erased the tiles there when it was placed).
    event_handlers.pushPlayerAction(
        &history.current_state,
        .{ .player_move_editor_selection = .{ .delta = .{ .x = 3, .y = 3 } } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 2), level.entity_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 4, .y = 4 }, level.entity_placements[0].position);
    try testing.expectEqual(types.Vector2{ .x = 5, .y = 4 }, level.entity_placements[1].position);
    try testing.expectEqual(@as(usize, 0), level.decoration_placements.len);
    try testing.expect(hasTile(level, .{ .x = 4, .y = 4 }));
    try testing.expect(hasTile(level, .{ .x = 5, .y = 4 }));
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);
}

test "player_move_editor_selection: a moved marker takes its ground with it" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The user-report repro: the '!' stands on a real tile at (0,0); a
    // plain click selects just the singleton (no tile entry — the click
    // group for a marker is the marker alone). Moving it must erase the
    // old tile (nothing hosts the marker there anymore) and ensure a tile
    // at the new position — NOT leave the old tile behind.
    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 5, .y = 5 },
    }};
    var history = harness.newHistory(editorStateWith(moveTestEditor(&levels)));
    // Click-select shape: the singleton only.
    const seeded_selection = [_]types.Selectable{.player_start};
    history.current_state.editor.?.selection = &seeded_selection;
    runToIdle(&history);

    event_handlers.pushPlayerAction(
        &history.current_state,
        .{ .player_move_editor_selection = .{ .delta = .{ .x = 2, .y = 1 } } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    {
        const level = history.current_state.editor.?.levels[0];
        try testing.expectEqual(types.Vector2{ .x = 2, .y = 1 }, level.player_start);
        try testing.expect(!hasTile(level, .{ .x = 0, .y = 0 }));
        try testing.expect(hasTile(level, .{ .x = 2, .y = 1 }));
        // The '=' and its tile are untouched.
        try testing.expectEqual(types.Vector2{ .x = 5, .y = 5 }, level.level_end.?);
        try testing.expect(hasTile(level, .{ .x = 5, .y = 5 }));
        try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);
    }

    // One undo reverts the move AND the old tile.
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const level = history.current_state.editor.?.levels[0];
        try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.player_start);
        try testing.expect(hasTile(level, .{ .x = 0, .y = 0 }));
        try testing.expect(!hasTile(level, .{ .x = 2, .y = 1 }));
    }

    // The marquee shape (tile + marker BOTH selected) moves the same way —
    // the tile entry is protected by the marker-tile rule, and the marker
    // entry drives the erase exactly once.
    history.current_state.editor.?.selection = &seeded_selection;
    const with_tile = [_]types.Selectable{ .{ .tile = .{ .x = 0, .y = 0 } }, .player_start };
    history.current_state.editor.?.selection = &with_tile;
    event_handlers.pushPlayerAction(
        &history.current_state,
        .{ .player_move_editor_selection = .{ .delta = .{ .x = 0, .y = 2 } } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 2 }, level.player_start);
    try testing.expect(!hasTile(level, .{ .x = 0, .y = 0 }));
    try testing.expect(hasTile(level, .{ .x = 0, .y = 2 }));
}

test "editor utility-skill commit: set/clear via the wrapper, weapon skills and bad slots no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton", .template = .{} }};
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    }));
    runToIdle(&history);

    // Set slot 0 to blink (a cantrip): one undo step.
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_entity_utility_skill = .{
            .target = .{ .entity_type = 0 },
            .slot_index = 0,
            .value = .blink,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(
        types.SkillId.blink,
        history.current_state.editor.?.entity_types[0].template.equipped_utility_skills[0],
    );
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(
        @as(?types.SkillId, null),
        history.current_state.editor.?.entity_types[0].template.equipped_utility_skills[0],
    );

    // A weapon skill no-ops (the handler's defensive gate — the picker
    // never offers one and validation rejects crafted logs).
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_entity_utility_skill = .{
            .target = .{ .entity_type = 0 },
            .slot_index = 0,
            .value = .slice,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(
        @as(?types.SkillId, null),
        history.current_state.editor.?.entity_types[0].template.equipped_utility_skills[0],
    );

    // An out-of-range slot no-ops.
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_entity_utility_skill = .{
            .target = .{ .entity_type = 0 },
            .slot_index = 9,
            .value = .blink,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    var any_set = false;
    for (history.current_state.editor.?.entity_types[0].template.equipped_utility_skills) |slot| {
        if (slot != null) any_set = true;
    }
    try testing.expect(!any_set);
}

test "skill picker interaction: open, assign, same-value no-op, None clears, dropdown stays live" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton", .template = .{} }};
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    }));
    runToIdle(&history);

    // Open the picker for slot 0 (Slot 4).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_skill_picker,
        .clicked_editor_utility_slot = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_picker != null);
    try testing.expectEqual(@as(u32, 0), history.session.ui_state.editor_picker.?.utility_skill_slot);

    // The picker is a DROPDOWN, not a modal: other actions stay live
    // while it's open (and it survives them).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_inspector,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(!history.current_state.editor.?.inspector_open);
    try testing.expect(history.session.ui_state.editor_picker != null);

    // Pick blink: assigned + the picker closes; one undo step.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_utility_skill,
        .clicked_editor_skill = .blink,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_picker == null);
    try testing.expectEqual(
        types.SkillId.blink,
        history.current_state.editor.?.entity_types[0].template.equipped_utility_skills[0],
    );
    // runToIdle records the undo stop (driven directly here — the LIVE
    // path commits inside update(), whose events_processed recording
    // covers it; not the frame-level text-commit case).
    runToIdle(&history);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(
        @as(?types.SkillId, null),
        history.current_state.editor.?.entity_types[0].template.equipped_utility_skills[0],
    );

    // Reopen + pick the SAME (empty) value: closes, records nothing.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_skill_picker,
        .clicked_editor_utility_slot = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_utility_skill,
        .clicked_editor_skill = null,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_picker == null);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Assign, reopen, pick None: clears the slot (one event).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_skill_picker,
        .clicked_editor_utility_slot = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_utility_skill,
        .clicked_editor_skill = .stone_form,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(
        types.SkillId.stone_form,
        history.current_state.editor.?.entity_types[0].template.equipped_utility_skills[0],
    );
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_skill_picker,
        .clicked_editor_utility_slot = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_utility_skill,
        .clicked_editor_skill = null,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(
        @as(?types.SkillId, null),
        history.current_state.editor.?.entity_types[0].template.equipped_utility_skills[0],
    );

    // The close button's action just closes.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_skill_picker,
        .clicked_editor_utility_slot = 2,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .close_editor_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_picker == null);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "player_import_editor_player: copies the session player data, undo reverts, playtest carries the inventory" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    // The session's player data: a name, a main-hand weapon, one skill,
    // one inventory item.
    var player_data: types.PlayerData = .{ .player_name = "Tester" };
    player_data.main_hand_weapon = .{
        .name = "Test Sword",
        .weapon_type = .sword,
        .weapon_damage = 5,
    };
    player_data.equipped_utility_skills = .{ .replenish, null, null, null, null };
    player_data.inventory.slots[0] = .{ .weapon = .{
        .name = "Spare Dagger",
        .weapon_type = .dagger,
        .weapon_damage = 1,
    } };
    history.current_state.player_data = player_data;

    // The Import button's orchestrator.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .import_editor_player,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);

    const template = history.current_state.editor.?.player_def.template;
    try testing.expectEqualStrings("Tester", template.name);
    try testing.expectEqualStrings("Test Sword", template.main_hand_weapon.?.name);
    try testing.expectEqual(types.SkillId.replenish, template.equipped_utility_skills[0]);
    try testing.expectEqualStrings("Spare Dagger", template.inventory.slots[0].?.weapon.name);

    // The import rides the undo timeline — undo restores the default
    // loadout.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings("", history.current_state.editor.?.player_def.template.name);
    try testing.expect(history.current_state.editor.?.player_def.template.main_hand_weapon == null);

    // A playtest instantiates entity 0 from the template — the inventory
    // (loadout data, not a runtime field) carries into the level.
    try testing.expect(history.redo(event_handlers.processEvent));
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .start_playtest = .{ .level_index = 0 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const player_entity = &history.current_state.level.?.entities[0];
    try testing.expectEqualStrings("Tester", player_entity.name);
    try testing.expectEqualStrings("Spare Dagger", player_entity.inventory.slots[0].?.weapon.name);
}

test "player_import_editor_player: no session data imports the new-game default save" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);
    // Fresh session: player_data empty (no name) — the import falls back
    // to data/new_player.txt.
    try testing.expectEqual(@as(usize, 0), history.current_state.player_data.player_name.len);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .editor_import_player }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const template = history.current_state.editor.?.player_def.template;
    try testing.expectEqualStrings("New Player", template.name);
    try testing.expectEqualStrings("Starter Sword", template.main_hand_weapon.?.name);
    try testing.expectEqual(types.SkillId.replenish, template.equipped_utility_skills[0]);
    // The session's (empty) player data is untouched — the default save is
    // a READ source, not a session load.
    try testing.expectEqual(@as(usize, 0), history.current_state.player_data.player_name.len);
}

test "start_playtest builds its own player_data (all skills learned), end_playtest restores the session's" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const utility_skills = @import("utility_skills.zig");

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .player_def = .{ .id = "Player", .template = .{
            .name = "Editor Player",
            .equipped_utility_skills = .{ .blink, null, null, null, null },
        } },
    }));
    runToIdle(&history);

    // The session's real campaign data.
    var campaign: types.PlayerData = .{ .player_name = "Campaign Player" };
    campaign.learned_skills = &.{.replenish};
    history.current_state.player_data = campaign;

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .start_playtest = .{ .level_index = 0 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The run's player_data is BUILT from the loadout: the editor player's
    // name + every utility skill learned (tome pickups read
    // already-learned; nothing is gated).
    try testing.expectEqualStrings("Editor Player", history.current_state.player_data.player_name);
    try testing.expectEqual(
        @as(usize, utility_skills.utility_skill_ids.len),
        history.current_state.player_data.learned_skills.len,
    );
    for (utility_skills.utility_skill_ids) |skill_id| {
        try testing.expect(event_handlers.isSkillLearned(
            history.current_state.player_data.learned_skills,
            skill_id,
        ));
    }
    // The session's real data is backed up on the Editor.
    try testing.expectEqualStrings(
        "Campaign Player",
        history.current_state.editor.?.pre_playtest_player_data.?.player_name,
    );

    // In-level events mutate player_data directly (use_skill_tome,
    // salvage) — simulate one, then end the playtest.
    history.current_state.player_data.player_name = "Mutated In Playtest";
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .end_playtest }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings("Campaign Player", history.current_state.player_data.player_name);
    try testing.expect(history.current_state.editor.?.pre_playtest_player_data == null);
    try testing.expect(history.current_state.editor.?.mode == .edit);
}

test "a validation run's chained level start_playtest does not re-back-up" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{ .{}, .{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .player_def = .{ .id = "Player", .template = .{ .name = "Editor Player" } },
    }));
    runToIdle(&history);
    history.current_state.player_data = .{ .player_name = "Campaign Player" };

    // Level 1 of the validation run: backs up + builds.
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .start_validation }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings("Editor Player", history.current_state.player_data.player_name);

    // Mid-run mutation (an in-level event), then the chained next-level
    // start_playtest (mode is .validate, not .edit).
    history.current_state.player_data.player_name = "Mutated In Run";
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .start_playtest = .{ .level_index = 1 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The chained start neither rebuilt the run's data (the mutation
    // survives) nor re-captured the backup (still the campaign data).
    try testing.expectEqualStrings("Mutated In Run", history.current_state.player_data.player_name);
    try testing.expectEqualStrings(
        "Campaign Player",
        history.current_state.editor.?.pre_playtest_player_data.?.player_name,
    );

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .end_validation = .{ .success = true } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings("Campaign Player", history.current_state.player_data.player_name);
}

test "open_editor: a mission without player.txt falls back to the maxed default loadout" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A minimal mission in the harness's persistent scratch dir, WITHOUT a
    // player.txt (the custom/new-mission case).
    try harness.file_source.writeFile("missions/no_player/mission.txt",
        \\Metadata
        \\file_format_version 2
        \\mission_uuid 00000000-0000-0000-0000-000000000000
        \\name No Player Mission
        \\level_count 1
        \\
    );
    try harness.file_source.writeFile("missions/no_player/level_1.txt",
        \\Metadata
        \\file_format_version 1
        \\name No Player Level
        \\
        \\Layout
        \\!=
        \\
        \\Enemies
        \\
        \\Decorations
        \\
        \\Items
        \\
    );

    var history = harness.newHistory(null);
    runToIdle(&history);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .open_editor = .{
            .mission_path = "missions/no_player",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expect(history.current_state.editor != null);
    const template = history.current_state.editor.?.player_def.template;
    // The maxed default (data/max_player.txt): the save's name, armor at
    // the max bounds, no equipped weapons or skills, the 12-weapon
    // arsenal in the inventory.
    try testing.expectEqualStrings("New Player", template.name);
    try testing.expect(template.main_hand_weapon == null);
    try testing.expect(template.off_hand_weapon == null);
    try testing.expectEqual(types.max_spell_damage, template.amulet.?.spell_damage);
    try testing.expectEqual(types.max_health_bonus, template.coat.?.health_bonus);
    for (template.equipped_utility_skills) |slot| try testing.expect(slot == null);
    var inventory_items: u32 = 0;
    for (template.inventory.slots) |maybe_item| {
        if (maybe_item != null) inventory_items += 1;
    }
    try testing.expectEqual(@as(u32, 12), inventory_items);
}

test "toggle_editor_inspector_section: default collapsed, independent expand/collapse" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .team = 1 },
    }};
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    }));
    runToIdle(&history);

    // DEFAULT: every section collapsed — the panel shows only headers.
    input_handlers.handleAnytimeInput(&history, .{}, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(
        [_]bool{false} ** 7,
        history.session.ui_state.editor_inspector_section_expanded,
    );

    // Expand Weapons (the section id rides the click payload).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_inspector_section,
        .clicked_editor_section = .weapons,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_inspector_section_expanded[@intFromEnum(types.EditorInspectorSectionId.weapons)]);
    // Independent: nothing else expanded, no event recorded (view state,
    // off the undo timeline).
    try testing.expect(!history.session.ui_state.editor_inspector_section_expanded[@intFromEnum(types.EditorInspectorSectionId.gear)]);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Collapse it back.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_inspector_section,
        .clicked_editor_section = .weapons,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(!history.session.ui_state.editor_inspector_section_expanded[@intFromEnum(types.EditorInspectorSectionId.weapons)]);
}
