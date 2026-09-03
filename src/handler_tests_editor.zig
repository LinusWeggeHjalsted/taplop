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
const player_handlers = @import("handlers/player.zig");
const event_push = @import("event_push.zig");
const planning = @import("editor/planning.zig");
const input_handlers = @import("input_handlers.zig");
const input_gestures = @import("input_gestures.zig");
const test_harness = @import("test_harness.zig");
const ui = @import("ui.zig");
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");
const zip_writer = @import("zip_writer.zig");
const session_log = @import("session_log.zig");
const validation_replay = @import("validation_replay.zig");
const content_hash = @import("content_hash.zig");

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

    event_push.pushEvents(
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
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_active_level = .{ .level_index = 9 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.active_level_index);
}

test "editor clamp snapshot: refreshed on level switch, held across tile edits, reverted by undo" {
    // The camera clamp reads `Editor.clamp_bounds` (the snapshot — see
    // DESIGN → Platform Seam → Camera clamping): a level switch refreshes
    // it from the new active level's live tiles; a tile edit mid-level
    // must NOT touch it (mid-edit reframing is the bug this snapshot
    // exists for); undo of the switch reverts it with the tab.
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const level_0_tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 2 } };
    const level_1_tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 } };
    const levels = [_]types.EditorLevel{
        .{ .level_tiles = &level_0_tiles },
        .{ .level_tiles = &level_1_tiles },
    };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
    }));
    runToIdle(&history);
    // The starting state was crafted directly (no open_editor event), so
    // no snapshot exists yet.
    try testing.expect(history.current_state.editor.?.clamp_bounds == null);

    // Tab switch: the snapshot follows the new active level's tiles.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_level = .{ .level_index = 1 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(
        types.TileBounds{ .min_x = 1, .min_y = 1, .max_x = 1, .max_y = 1 },
        history.current_state.editor.?.clamp_bounds.?,
    );

    // A tile painted far outside the current bbox: the live tiles change,
    // the snapshot does not (the camera stays framed).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_tile = .{
            .level_index = 1,
            .position = .{ .x = 40, .y = 40 },
            .is_floor = true,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(
        types.TileBounds{ .min_x = 1, .min_y = 1, .max_x = 1, .max_y = 1 },
        history.current_state.editor.?.clamp_bounds.?,
    );

    // Undo the tile edit (still held), then undo the switch: the snapshot
    // reverts with the tab — back to the crafted starting state, which has
    // NO snapshot (it never went through open_editor; real flows always
    // do). The point: undo restores the pre-switch snapshot verbatim, it
    // doesn't re-derive one.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(
        types.TileBounds{ .min_x = 1, .min_y = 1, .max_x = 1, .max_y = 1 },
        history.current_state.editor.?.clamp_bounds.?,
    );
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.editor.?.clamp_bounds == null);
}

test "level-tab click on the active tab fires nothing (no dead undo step)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 } };
    const levels = [_]types.EditorLevel{
        .{ .level_tiles = &tiles },
        .{},
    };
    const selection = [_]types.Selectable{.{ .tile = .{ .x = 0, .y = 0 } }};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .active_level_index = 0,
        .selection = &selection,
    }));
    runToIdle(&history);

    // Re-clicking the active tab: no event, no undo step — and the
    // selection survives (a same-value event would have cleared it as a
    // side effect).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_level,
        .clicked_editor_level = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.selection.len);

    // Positive control: clicking the OTHER tab fires the switch.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_level,
        .clicked_editor_level = 1,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.active_level_index);
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

    event_push.pushEvents(
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

test "player_add_editor_entity_type: default creation, tool + inspector, undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.entity_types.len);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_add_editor_entity_type }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The shipped default (data/editor_defaults.txt): New Enemy on
    // skeleton_1, color 4, base stats 20/0/1/3, nothing equipped.
    const editor = history.current_state.editor.?;
    try testing.expectEqual(@as(usize, 1), editor.entity_types.len);
    try testing.expectEqualStrings("New Entity", editor.entity_types[0].id);
    try testing.expectEqualStrings("New Entity", editor.entity_types[0].template.name);
    try testing.expectEqualStrings("skeleton_1", editor.entity_types[0].template.sprite);
    try testing.expectEqual(@as(u32, 1), editor.entity_types[0].template.team);
    try testing.expectEqual(@as(u32, 4), editor.entity_types[0].template.color_index);
    try testing.expectEqual(@as(u32, 20), editor.entity_types[0].template.max_health);
    try testing.expectEqual(@as(u32, 3), editor.entity_types[0].template.aggro_range);
    try testing.expect(editor.entity_types[0].template.main_hand_weapon == null);

    // The new type becomes the active tool + the inspector auto-opens —
    // one undo step reverts the whole creation.
    try testing.expect(std.meta.eql(
        types.EditorToolId{ .entity_type = 0 },
        editor.active_tool,
    ));
    try testing.expect(editor.inspector_open);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.entity_types.len);
    try testing.expect(std.meta.eql(
        types.EditorToolId.select,
        history.current_state.editor.?.active_tool,
    ));
}

test "player_add_editor_decoration_type: stone_1 default, undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_add_editor_decoration_type }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The shipped default: the stone_1 prefab duplicated — footprint (0,0),
    // color 5, 256x256 dims, no layers; the palette id tracks the sprite.
    const editor = history.current_state.editor.?;
    try testing.expectEqual(@as(usize, 1), editor.decoration_types.len);
    const definition = editor.decoration_types[0];
    try testing.expectEqualStrings("stone_1", definition.id);
    try testing.expectEqualStrings("stone_1", definition.sprite);
    try testing.expectEqual(@as(usize, 1), definition.footprint.len);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, definition.footprint[0]);
    try testing.expectEqual(@as(u32, 5), definition.color_index);
    try testing.expectEqual(@as(i32, 256), definition.pixel_dims.x);
    try testing.expect(std.meta.eql(
        types.EditorToolId{ .decoration_type = 0 },
        editor.active_tool,
    ));

    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.decoration_types.len);
}

test "player_add_editor_item_type: New Sword default, undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_add_editor_item_type }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The shipped default: a New Sword (sword, 0 damage); the palette id is
    // the item name.
    const editor = history.current_state.editor.?;
    try testing.expectEqual(@as(usize, 1), editor.item_types.len);
    try testing.expectEqualStrings("New Sword", editor.item_types[0].id);
    try testing.expectEqualStrings("New Sword", editor.item_types[0].item.weapon.name);
    try testing.expectEqual(types.WeaponType.sword, editor.item_types[0].item.weapon.weapon_type);
    try testing.expectEqual(@as(u32, 0), editor.item_types[0].item.weapon.weapon_damage);
    try testing.expect(std.meta.eql(
        types.EditorToolId{ .item_type = 0 },
        editor.active_tool,
    ));

    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.item_types.len);
}

test "player_add_editor_entity_type: opens a closed inspector, clears the selection" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    const selection = [_]types.Selectable{.{ .tile = .{ .x = 0, .y = 0 } }};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .inspector_open = false,
        .active_tool = .select,
        .selection = &selection,
    }));
    runToIdle(&history);
    try testing.expect(history.current_state.editor.?.selection.len > 0);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_add_editor_entity_type }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The creation auto-opens a closed inspector, and the tool switch it
    // carries clears the selection (the editor_set_tool invariant).
    const editor = history.current_state.editor.?;
    try testing.expect(editor.inspector_open);
    try testing.expectEqual(@as(usize, 0), editor.selection.len);
}

test "editor_delete_type (entity): removes the type + placements across levels, remaps ids, fixes the tool, undo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Archer" },
        .{ .id = "Brute" },
        .{ .id = "Cadaver" },
    };
    const level_0_placements = [_]types.EntityPlacement{
        .{ .type_id = 1, .position = .{ .x = 1, .y = 1 } }, // Brute
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } }, // Archer
        .{ .type_id = 1, .position = .{ .x = 2, .y = 2 } }, // Brute
        .{ .type_id = 2, .position = .{ .x = 3, .y = 3 } }, // Cadaver
    };
    const level_1_placements = [_]types.EntityPlacement{
        .{ .type_id = 1, .position = .{ .x = 0, .y = 0 } }, // Brute
        .{ .type_id = 0, .position = .{ .x = 1, .y = 0 } }, // Archer
    };
    const levels = [_]types.EditorLevel{
        .{ .entity_placements = &level_0_placements },
        .{ .entity_placements = &level_1_placements },
    };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_level_index = 0,
        .active_tool = .{ .entity_type = 2 }, // Cadaver — above the deleted index
    }));
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_delete_editor_type = .{
            .type_kind = .entity,
            .type_id = 1, // Brute
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The type is gone; both levels lost their Brute placements; the
    // Cadaver references (type 2) remapped down to 1; the active tool
    // (entity_type 2) decremented with them.
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 2), editor.entity_types.len);
        try testing.expectEqualStrings("Archer", editor.entity_types[0].id);
        try testing.expectEqualStrings("Cadaver", editor.entity_types[1].id);

        const level_0 = editor.levels[0];
        try testing.expectEqual(@as(usize, 2), level_0.entity_placements.len);
        try testing.expectEqual(@as(u32, 0), level_0.entity_placements[0].type_id);
        try testing.expectEqual(@as(u32, 1), level_0.entity_placements[1].type_id);
        const level_1 = editor.levels[1];
        try testing.expectEqual(@as(usize, 1), level_1.entity_placements.len);
        try testing.expectEqual(@as(u32, 0), level_1.entity_placements[0].type_id);

        try testing.expect(std.meta.eql(
            types.EditorToolId{ .entity_type = 1 },
            editor.active_tool,
        ));
    }

    // One undo step restores the type, every placement, and the tool.
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 3), editor.entity_types.len);
        try testing.expectEqual(@as(usize, 4), editor.levels[0].entity_placements.len);
        try testing.expectEqual(@as(usize, 2), editor.levels[1].entity_placements.len);
        try testing.expect(std.meta.eql(
            types.EditorToolId{ .entity_type = 2 },
            editor.active_tool,
        ));
    }
}

test "editor_delete_type: deleting the active tool resets to select; the selection is pruned" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Archer" },
        .{ .id = "Brute" },
    };
    const placements = [_]types.EntityPlacement{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
        .{ .type_id = 1, .position = .{ .x = 1, .y = 0 } }, // Brute
    };
    const levels = [_]types.EditorLevel{.{ .entity_placements = &placements }};
    const selection = [_]types.Selectable{.{ .entity_placement = 1 }};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 1 }, // Brute — the deleted tool
        .selection = &selection,
    }));
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_delete_editor_type = .{
            .type_kind = .entity,
            .type_id = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The tool resets to select (a dangling type pointer is never created),
    // and the selection entry referencing the deleted placement is pruned
    // by the placement-delete arm.
    const editor = history.current_state.editor.?;
    try testing.expectEqual(@as(usize, 1), editor.entity_types.len);
    try testing.expectEqual(@as(usize, 1), editor.levels[0].entity_placements.len);
    try testing.expect(std.meta.eql(types.EditorToolId.select, editor.active_tool));
    try testing.expectEqual(@as(usize, 0), editor.selection.len);

    // Undo restores the tool + selection together with the type.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(std.meta.eql(
        types.EditorToolId{ .entity_type = 1 },
        history.current_state.editor.?.active_tool,
    ));
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.selection.len);
}

test "editor_delete_type (decoration + item kinds): placements across levels, other kinds untouched" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "stone_1", .sprite = "stone_1" },
        .{ .id = "tree_1", .sprite = "tree_1" },
    };
    const item_types = [_]types.ItemTypeDef{
        .{ .id = "New Sword", .item = .{ .weapon = .{} } },
        .{ .id = "New Amulet", .item = .{ .amulet = .{} } },
    };
    const level_0_decorations = [_]types.DecorationPlacement{
        .{ .type_id = 1, .position = .{ .x = 0, .y = 0 } }, // tree
        .{ .type_id = 0, .position = .{ .x = 2, .y = 0 } }, // stone
    };
    const level_1_decorations = [_]types.DecorationPlacement{
        .{ .type_id = 1, .position = .{ .x = 1, .y = 1 } }, // tree
    };
    const level_0_items = [_]types.ItemPlacement{
        .{ .type_id = 1, .position = .{ .x = 0, .y = 1 } }, // amulet
        .{ .type_id = 0, .position = .{ .x = 1, .y = 1 } }, // sword
    };
    const level_1_items = [_]types.ItemPlacement{
        .{ .type_id = 1, .position = .{ .x = 2, .y = 1 } }, // amulet
    };
    const levels = [_]types.EditorLevel{
        .{
            .decoration_placements = &level_0_decorations,
            .item_placements = &level_0_items,
        },
        .{
            .decoration_placements = &level_1_decorations,
            .item_placements = &level_1_items,
        },
    };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .decoration_types = &decoration_types,
        .item_types = &item_types,
    }));
    runToIdle(&history);

    // Delete the tree type: both levels' tree placements go, the item
    // placements are untouched (separate palettes).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_delete_editor_type = .{
            .type_kind = .decoration,
            .type_id = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 1), editor.decoration_types.len);
        try testing.expectEqual(@as(usize, 1), editor.levels[0].decoration_placements.len);
        try testing.expectEqual(@as(usize, 0), editor.levels[1].decoration_placements.len);
        try testing.expectEqual(@as(usize, 2), editor.levels[0].item_placements.len);
        try testing.expectEqual(@as(usize, 1), editor.levels[1].item_placements.len);
    }

    // Delete the amulet type: both levels' amulet placements go.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_delete_editor_type = .{
            .type_kind = .item,
            .type_id = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 1), editor.item_types.len);
        try testing.expectEqual(@as(usize, 1), editor.levels[0].item_placements.len);
        try testing.expectEqual(@as(u32, 0), editor.levels[0].item_placements[0].type_id);
        try testing.expectEqual(@as(usize, 0), editor.levels[1].item_placements.len);
    }

    // Two undos restore both deletions.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.item_types.len);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.decoration_types.len);
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.levels[0].decoration_placements.len);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.levels[1].decoration_placements.len);
}

test "editor_delete_type: out-of-range type id is a no-op (handler guard)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{.{ .id = "Archer" }};
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
    }));
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_delete_type = .{
            .type_kind = .entity,
            .type_id = 99,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.entity_types.len);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "player_paint_editor_tile: paints a tile on empty space, sorted into the list" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 0 } };
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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
    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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
        event_push.pushEvents(
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
    event_push.pushEvents(
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
    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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
        event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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

test "player_set_editor_decoration_color_index: sets the type's color, out-of-range type is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(decorationTestEditor(&levels)));
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_decoration_color_index = .{
            .type_id = 1,
            .value = 5,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(@as(u32, 5), history.current_state.editor.?.decoration_types[1].color_index);

    // A crafted out-of-range type id records nothing (the handler's guard).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_decoration_color_index = .{
            .type_id = 99,
            .value = 3,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 5), history.current_state.editor.?.decoration_types[1].color_index);
}

/// Push a whole-def commit (a picker pick's resolved payload). The layers
/// and color mirror the registry's tree_1 prefab; the footprint is a
/// parameter because the prune tests need shapes whose world tiles differ
/// from the type's current two-wide footprint. Payload slices are duped
/// into the current arena before pushing (the real commit site's ordering
/// rule — the payload must not point into a shorter-lived frame).
fn pushDecorationDef(
    history: *state.GameStateHistory,
    type_id: u32,
    footprint: []const types.Vector2,
) void {
    const layers = [_]types.DecorationLayer{.{
        .sprite = "tree_1_canopy",
        .color_index = 2,
        .pixel_dims = .{ .x = 512, .y = 768 },
    }};
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_decoration_def = .{
            .type_id = type_id,
            .sprite = "tree_1",
            .footprint = history.current_arena.allocator().dupe(types.Vector2, footprint) catch unreachable,
            .pixel_dims = .{ .x = 512, .y = 768 },
            .color_index = 4,
            .layers = history.current_arena.allocator().dupe(types.DecorationLayer, &layers) catch unreachable,
        } } }},
        history.current_arena.allocator(),
    );
}

test "player_set_editor_decoration_def: adopts the whole definition, id tracks the sprite" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(decorationTestEditor(&levels)));
    runToIdle(&history);

    const tree_footprint = [_]types.Vector2{.{ .x = 1, .y = 2 }};
    pushDecorationDef(&history, 0, &tree_footprint);
    runToIdle(&history);

    const adopted = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqualStrings("tree_1", adopted.id);
    try testing.expectEqualStrings("tree_1", adopted.sprite);
    try testing.expectEqual(@as(usize, 1), adopted.footprint.len);
    try testing.expectEqual(types.Vector2{ .x = 1, .y = 2 }, adopted.footprint[0]);
    try testing.expectEqual(types.Vector2{ .x = 512, .y = 768 }, adopted.pixel_dims);
    try testing.expectEqual(@as(u32, 4), adopted.color_index);
    try testing.expectEqual(@as(usize, 1), adopted.layers.len);
    try testing.expectEqualStrings("tree_1_canopy", adopted.layers[0].sprite);

    // One event = one undo step: undo restores the original definition.
    try testing.expect(history.undo(event_handlers.processEvent));
    const reverted = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqualStrings("ruin_1", reverted.sprite);
    try testing.expectEqualStrings("wide", reverted.id);
    try testing.expectEqual(@as(u32, 0), reverted.color_index);
    try testing.expectEqual(@as(usize, 0), reverted.layers.len);
}

test "player_set_editor_decoration_def: placements covered by a level tile under the new footprint are pruned" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The type starts two-wide (placement P covers P and P+1x). The new
    // footprint {(0,0),(0,1)} is two-TALL: anchor (0,1), so a placement at
    // P covers (P.x, P.y-1) and P — the tile at (5,4) sits under the NEW
    // footprint only, so the (5,5) placement is pruned while the (0,0)
    // one (new tiles (0,-1),(0,0) — clear ground) survives. The same
    // invalid placement exists on level 1: the prune runs across every
    // level.
    const tiles = [_]types.Vector2{.{ .x = 5, .y = 4 }};
    const placements = [_]types.DecorationPlacement{
        .{ .type_id = 0, .position = .{ .x = 5, .y = 5 } },
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
    };
    const level_one_placements = [_]types.DecorationPlacement{
        .{ .type_id = 0, .position = .{ .x = 5, .y = 5 } },
    };
    const levels = [_]types.EditorLevel{
        .{ .level_tiles = &tiles, .decoration_placements = &placements },
        .{ .level_tiles = &tiles, .decoration_placements = &level_one_placements },
    };
    var history = harness.newHistory(editorStateWith(decorationTestEditor(&levels)));
    runToIdle(&history);

    pushDecorationDef(&history, 0, &tall_footprint);
    runToIdle(&history);

    const first_level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), first_level.decoration_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, first_level.decoration_placements[0].position);
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.levels[1].decoration_placements.len);
    // The things under the new footprint are never touched — the tile
    // that invalidated the placement stays.
    try testing.expect(hasTile(first_level, .{ .x = 5, .y = 4 }));
}

test "player_set_editor_decoration_def: placements overlapping another decoration under the new footprint are pruned" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A single-tile decoration of the OTHER type at (5,4): clear of the
    // wide type's placement at (5,5) today (it covers (5,5),(6,5)), but
    // under the new two-tall footprint's (5,4) tile → the type-0
    // placement is pruned, the type-1 one stays.
    const placements = [_]types.DecorationPlacement{
        .{ .type_id = 0, .position = .{ .x = 5, .y = 5 } },
        .{ .type_id = 1, .position = .{ .x = 5, .y = 4 } },
    };
    const levels = [_]types.EditorLevel{.{ .decoration_placements = &placements }};
    var history = harness.newHistory(editorStateWith(decorationTestEditor(&levels)));
    runToIdle(&history);

    pushDecorationDef(&history, 0, &tall_footprint);
    runToIdle(&history);

    const level = history.current_state.editor.?.levels[0];
    try testing.expectEqual(@as(usize, 1), level.decoration_placements.len);
    try testing.expectEqual(@as(u32, 1), level.decoration_placements[0].type_id);
    try testing.expectEqual(types.Vector2{ .x = 5, .y = 4 }, level.decoration_placements[0].position);
}

test "player_set_editor_decoration_def: pruned placements are dropped from the selection, later indices remap" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // Three placements on the active level: [0] type-0 at (5,5) (pruned
    // by the tile at (5,4) under the new tall footprint), [1] type-1
    // elsewhere, [2] type-0 on clear ground. The selection holds [0] and
    // [2]; after the prune it holds the survivor at its remapped index 1.
    const tiles = [_]types.Vector2{.{ .x = 5, .y = 4 }};
    const placements = [_]types.DecorationPlacement{
        .{ .type_id = 0, .position = .{ .x = 5, .y = 5 } },
        .{ .type_id = 1, .position = .{ .x = 9, .y = 9 } },
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
    };
    const selection = [_]types.Selectable{
        .{ .decoration_placement = 0 },
        .{ .decoration_placement = 2 },
    };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .decoration_placements = &placements,
    }};
    var editor = decorationTestEditor(&levels);
    editor.selection = &selection;
    var history = harness.newHistory(editorStateWith(editor));
    runToIdle(&history);

    pushDecorationDef(&history, 0, &tall_footprint);
    runToIdle(&history);

    const pruned_editor = history.current_state.editor.?;
    try testing.expectEqual(@as(usize, 2), pruned_editor.levels[0].decoration_placements.len);
    try testing.expectEqual(@as(usize, 1), pruned_editor.selection.len);
    try testing.expectEqual(@as(u32, 1), pruned_editor.selection[0].decoration_placement);
}

test "player_set_editor_decoration_def: empty footprint or out-of-range type records nothing" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(decorationTestEditor(&levels)));
    runToIdle(&history);

    // Crafted-log defense: an empty footprint can't come from a pick
    // (prefabs are authored nonempty, custom stems get the bottom-left
    // default) — ignored, nothing changes.
    pushDecorationDef(&history, 0, &.{});
    runToIdle(&history);
    try testing.expectEqualStrings("ruin_1", history.current_state.editor.?.decoration_types[0].sprite);

    const tree_footprint = [_]types.Vector2{.{ .x = 1, .y = 2 }};
    pushDecorationDef(&history, 99, &tree_footprint);
    runToIdle(&history);
    try testing.expectEqualStrings("ruin_1", history.current_state.editor.?.decoration_types[0].sprite);
}

test "entity layer events: add appends, set replaces, remove compacts, player target ignored" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 },
    }};
    const levels = [_]types.EditorLevel{.{}};
    const target: types.EntityEditTarget = .{ .entity_type = 0 };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    }));
    runToIdle(&history);

    // Add: two layers append in order.
    for ([_][]const u8{ "chainmail", "hood" }) |layer_sprite| {
        event_push.pushEvents(
            &history.current_state,
            &.{.{ .player_input_event = .{ .player_add_editor_entity_layer = .{
                .target = target,
                .sprite = layer_sprite,
                .color_index = 2,
            } } }},
            history.current_arena.allocator(),
        );
        runToIdle(&history);
    }
    var template = history.current_state.editor.?.entity_types[0].template;
    try testing.expectEqual(@as(usize, 2), template.layers.len);
    try testing.expectEqualStrings("chainmail", template.layers[0].sprite);
    try testing.expectEqualStrings("hood", template.layers[1].sprite);

    // Set: replace layer 0 in place (order + the other layer stable).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_entity_layer = .{
            .target = target,
            .layer_index = 0,
            .sprite = "plate",
            .color_index = 4,
            } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    template = history.current_state.editor.?.entity_types[0].template;
    try testing.expectEqualStrings("plate", template.layers[0].sprite);
    try testing.expectEqual(@as(u32, 4), template.layers[0].color_index);
    try testing.expectEqualStrings("hood", template.layers[1].sprite);

    // Remove: order-preserving compact.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_remove_editor_entity_layer = .{
            .target = target,
            .layer_index = 0,
            } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    template = history.current_state.editor.?.entity_types[0].template;
    try testing.expectEqual(@as(usize, 1), template.layers.len);
    try testing.expectEqualStrings("hood", template.layers[0].sprite);

    // Crafted-log defense: the player loadout has no layers (ignored),
    // and an out-of-range layer index records nothing.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_add_editor_entity_layer = .{
            .target = .player_def,
            .sprite = "hood",
            .color_index = 2,
            } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.player_def.template.layers.len);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_remove_editor_entity_layer = .{
            .target = target,
            .layer_index = 7,
            } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.entity_types[0].template.layers.len);
}

test "decoration layer events: add/set/remove with the dims-match invariant" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The "wide" type: pixel dims 512x256 — a matching layer carries the
    // same dims, a mismatched one doesn't.
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(decorationTestEditor(&levels)));
    runToIdle(&history);

    const matching_layer = types.DecorationLayer{
        .sprite = "moss_overlay",
        .color_index = 2,
        .pixel_dims = .{ .x = 512, .y = 256 },
    };
    const mismatched_layer = types.DecorationLayer{
        .sprite = "tall_canopy",
        .color_index = 2,
        .pixel_dims = .{ .x = 512, .y = 768 },
    };

    // Add: a matching layer appends; a MISMATCHED one is ignored (the
    // load-time invariant — the level parser panics on a dims mismatch,
    // so the editor never holds one).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_add_editor_decoration_layer = .{
            .type_id = 0,
            .sprite = matching_layer.sprite,
            .color_index = matching_layer.color_index,
            .pixel_dims = matching_layer.pixel_dims,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_add_editor_decoration_layer = .{
            .type_id = 0,
            .sprite = mismatched_layer.sprite,
            .color_index = mismatched_layer.color_index,
            .pixel_dims = mismatched_layer.pixel_dims,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    var definition = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqual(@as(usize, 1), definition.layers.len);
    try testing.expectEqualStrings("moss_overlay", definition.layers[0].sprite);

    // Set: a color swap replaces in place; a mismatched set is ignored.
    var recolored = matching_layer;
    recolored.color_index = 5;
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_decoration_layer = .{
            .type_id = 0,
            .layer_index = 0,
            .sprite = recolored.sprite,
            .color_index = recolored.color_index,
            .pixel_dims = recolored.pixel_dims,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    definition = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqual(@as(u32, 5), definition.layers[0].color_index);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_decoration_layer = .{
            .type_id = 0,
            .layer_index = 0,
            .sprite = mismatched_layer.sprite,
            .color_index = mismatched_layer.color_index,
            .pixel_dims = mismatched_layer.pixel_dims,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    definition = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqualStrings("moss_overlay", definition.layers[0].sprite);

    // Remove + one undo reverts the remove; an out-of-range index or type
    // records nothing.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_remove_editor_decoration_layer = .{
            .type_id = 0,
            .layer_index = 0,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.decoration_types[0].layers.len);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.decoration_types[0].layers.len);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_remove_editor_decoration_layer = .{
            .type_id = 0,
            .layer_index = 7,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_add_editor_decoration_layer = .{
            .type_id = 99,
            .sprite = matching_layer.sprite,
            .color_index = matching_layer.color_index,
            .pixel_dims = matching_layer.pixel_dims,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.decoration_types[0].layers.len);
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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
        event_push.pushEvents(
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

    event_push.pushEvents(
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
    event_push.pushEvents(
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
    event_push.pushEvents(
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

    event_push.pushEvents(
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
            event_push.pushEvents(
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
            event_push.pushEvents(
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

    event_push.pushEvents(
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
    event_push.pushEvents(
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
    event_push.pushEvents(
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
    event_push.pushEvents(
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

    event_push.pushEvents(
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
        planning.planEditorTilePaintActions(&editor, .{ .x = 1, .y = 1 }, backing.allocator()).len,
    );
    // Empty ground plans the paint.
    try testing.expectEqual(
        @as(usize, 1),
        planning.planEditorTilePaintActions(&editor, .{ .x = 2, .y = 1 }, backing.allocator()).len,
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
        planning.planEditorEntityPlacementActions(&editor, 1, .{ .x = 2, .y = 2 }, backing.allocator()).len,
    );
    // The '!' and '=' are never overwritten.
    const marker_levels = [_]types.EditorLevel{.{
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 4, .y = 4 },
    }};
    const marker_editor = placementTestEditor(&marker_levels);
    try testing.expectEqual(
        @as(usize, 0),
        planning.planEditorEntityPlacementActions(&marker_editor, 0, .{ .x = 0, .y = 0 }, backing.allocator()).len,
    );
    try testing.expectEqual(
        @as(usize, 0),
        planning.planEditorEntityPlacementActions(&marker_editor, 0, .{ .x = 4, .y = 4 }, backing.allocator()).len,
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

    const plan = planning.planEditorEntityPlacementActions(
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
        planning.planEditorItemPlacementActions(&editor, 1, .{ .x = 2, .y = 2 }, backing.allocator()).len,
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
        planning.planEditorDecorationPlacementActions(&editor, 0, .{ .x = 5, .y = 5 }, backing.allocator()).len,
    );
    // A different type at the same anchor still replaces (delete + place).
    try testing.expectEqual(
        @as(usize, 2),
        planning.planEditorDecorationPlacementActions(&editor, 1, .{ .x = 5, .y = 5 }, backing.allocator()).len,
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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
        planning.planEditorDeleteActions(&editor, .{ .x = 0, .y = 0 }, backing.allocator()).len,
    );
    try testing.expectEqual(
        @as(usize, 0),
        planning.planEditorDeleteActions(&editor, .{ .x = 4, .y = 4 }, backing.allocator()).len,
    );
    try testing.expectEqual(
        @as(usize, 0),
        planning.planEditorDeleteActions(&editor, .{ .x = 9, .y = 9 }, backing.allocator()).len,
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
    input_gestures.handleRightClickEditorDelete(
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

    input_gestures.handleRightClickEditorDelete(
        &tiled_history,
        pointer,
        &.{},
        .{ .position = .{ .x = 0, .y = 0 } },
        1.0,
        .{ .width = 1280, .height = 720 },
    );
    try testing.expectEqual(@as(usize, 1), tiled_history.current_state.event_stack.len);
}

// --- Tile-tool paint drag (handleEditorTileDrag) ---------------------------

/// Screen position of tile (x,y)'s center for the paint-drag tests:
/// camera at the origin, zoom 1, the 1280x720 viewport — screenToTile's
/// reference mapping (center 640,360 = tile origin).
fn tileCenter(x: i32, y: i32) types.ScreenPosition {
    return .{ .x = 640 + x * 256 + 128, .y = 360 + y * 256 + 128 };
}

test "tile-tool paint drag: press paints, held paints entered tiles, visited tiles never re-fire" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{ .levels = &levels }));
    runToIdle(&history);
    history.current_state.editor.?.active_tool = .tile;

    const camera = types.Camera{ .position = .{ .x = 0, .y = 0 } };
    const viewport = input.ViewportSize{ .width = 1280, .height = 720 };

    // Press at (5,5): the tile directly under the cursor paints
    // immediately (as soon as the drag begins).
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .pressed = true, .held = true, .position = tileCenter(5, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expect(history.session.ui_state.editor_tile_drag);
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    runToIdle(&history);
    try testing.expect(hasTile(history.current_state.editor.?.levels[0], .{ .x = 5, .y = 5 }));

    // Held, pointer entered (6,5): the new tile paints.
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .held = true, .position = tileCenter(6, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    runToIdle(&history);
    try testing.expect(hasTile(history.current_state.editor.?.levels[0], .{ .x = 6, .y = 5 }));

    // Wiggling back over visited tiles fires nothing (the visited set —
    // and the re-paint would be a no-op anyway).
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .held = true, .position = tileCenter(5, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .held = true, .position = tileCenter(6, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Release ends the drag. A fresh press re-arms the visited set — and
    // on the already-painted tile it plans empty, so no event (the no-op
    // gate).
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .released = true, .position = tileCenter(6, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expect(!history.session.ui_state.editor_tile_drag);
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .pressed = true, .held = true, .position = tileCenter(5, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expect(history.session.ui_state.editor_tile_drag);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "tile-tool paint drag: defers while events drain, pauses over blocking UI, ends on tool switch" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{ .levels = &levels }));
    runToIdle(&history);
    history.current_state.editor.?.active_tool = .tile;

    const camera = types.Camera{ .position = .{ .x = 0, .y = 0 } };
    const viewport = input.ViewportSize{ .width = 1280, .height = 720 };

    // A press over blocking UI never claims — dragging out of the panel
    // onto the world paints nothing (the press wasn't a world press).
    const panel = ui.UiElement{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = tileCenter(5, 5),
        .width = 10,
        .height = 10,
    } };
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .pressed = true, .held = true, .position = tileCenter(5, 5) },
        &.{panel},
        camera,
        1.0,
        viewport,
    );
    try testing.expect(!history.session.ui_state.editor_tile_drag);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .held = true, .position = tileCenter(6, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // A world press paints — but the paint is still on the stack when the
    // pointer crosses into (6,5): the drag defers (no plan computed against
    // state with pending events). Once the stack drains, the same held
    // pointer fires.
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .pressed = true, .held = true, .position = tileCenter(5, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .held = true, .position = tileCenter(6, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    runToIdle(&history);
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .held = true, .position = tileCenter(6, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    runToIdle(&history);
    try testing.expect(hasTile(history.current_state.editor.?.levels[0], .{ .x = 5, .y = 5 }));
    try testing.expect(hasTile(history.current_state.editor.?.levels[0], .{ .x = 6, .y = 5 }));

    // Mid-drag, over a panel covering the pointer's tile: the drag pauses
    // (no paint, no visited mark — the marquee's last-valid-corner rule);
    // back over the world at the same unvisited tile it resumes.
    const panel_away = ui.UiElement{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = tileCenter(7, 5),
        .width = 10,
        .height = 10,
    } };
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .held = true, .position = tileCenter(7, 5) },
        &.{panel_away},
        camera,
        1.0,
        viewport,
    );
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .held = true, .position = tileCenter(7, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    runToIdle(&history);

    // A tool switch away from tile (crafted directly — the event path does
    // the same) ends the drag on the gesture's next call: no paint, and
    // the idle arm owns presses again.
    history.current_state.editor.?.active_tool = .select;
    input_gestures.handleEditorTileDrag(
        &history,
        .{ .held = true, .position = tileCenter(8, 5) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try testing.expect(!history.session.ui_state.editor_tile_drag);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expect(!hasTile(history.current_state.editor.?.levels[0], .{ .x = 8, .y = 5 }));
}

test "tile-tool idle arm defers while a paint drag owns the press" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{.{ .x = 1, .y = 1 }};
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(editorStateWith(.{ .levels = &levels }));
    runToIdle(&history);
    history.current_state.editor.?.active_tool = .tile;

    // While the paint drag is active, a tile_clicked (the press the gesture
    // already claimed, or a keyboard confirm) fires nothing — the gesture
    // owns the pointer press.
    history.session.ui_state.editor_tile_drag = true;
    input_handlers.handleIdleInput(&history, .{ .tile_clicked = .{ .x = 2, .y = 1 } }, .{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // No drag: the same click fires (the keyboard confirm-at-cursor path —
    // the arm still works when no drag is in progress).
    history.session.ui_state.editor_tile_drag = false;
    input_handlers.handleIdleInput(&history, .{ .tile_clicked = .{ .x = 2, .y = 1 } }, .{});
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
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
    const plan = planning.planEditorRegionSelectActions(
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
    const empty_plan = planning.planEditorRegionSelectActions(
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
    event_push.pushPlayerAction(
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
    event_push.pushPlayerAction(
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
        const plan = planning.planEditorSelectionDeleteActions(
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

    event_push.pushPlayerAction(
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

    const plan = planning.planEditorSelectionDeleteActions(
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
    const field: types.TextFieldRef = .{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } };

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

test "sprite picker: open scans the mission dir, pick sets the base sprite, same-value no-ops" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A png + a non-png in the harness's persistent scratch dir (the scan
    // filters by extension; content is irrelevant — no dims are parsed for
    // entities).
    try harness.file_source.writeFile("missions/artists_den/boss.png", "png");
    try harness.file_source.writeFile("missions/artists_den/notes.txt", "not a sprite");

    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 } },
    };
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
        .mission = .{ .path = "missions/artists_den" },
    }));
    runToIdle(&history);

    // Open the picker: the mission dir scan lands on SessionState (the
    // .txt is filtered out), the tab resets to Mission, the target rides
    // UiState.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_sprite_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_picker != null);
    try testing.expectEqual(ui.EditorPickerTarget.entity_sprite, history.session.ui_state.editor_picker.?);
    try testing.expectEqual(types.EditorSpritePickerTab.mission_local, history.session.ui_state.editor_picker_sprite_tab);
    try testing.expectEqual(@as(usize, 1), history.session.editor_mission_sprites.len);
    try testing.expectEqualStrings("boss.png", history.session.editor_mission_sprites[0]);

    // Pick the mission-local sprite: the namespaced id
    // (`custom/<mission-dir>/<stem>`) commits through the existing
    // player_set_editor_entity_sprite event (on the undo timeline).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_entity_sprite,
        .clicked_editor_sprite = "custom/artists_den/boss",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.session.ui_state.editor_picker == null);
    try testing.expectEqualStrings(
        "custom/artists_den/boss",
        history.current_state.editor.?.entity_types[0].template.sprite,
    );

    // One undo reverts the sprite.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings(
        "skeleton_1",
        history.current_state.editor.?.entity_types[0].template.sprite,
    );

    // Same-value pick closes without recording (no dead undo step).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_sprite_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_entity_sprite,
        .clicked_editor_sprite = "skeleton_1",
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_picker == null);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Tab switch: a direct UiState write.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_sprite_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_sprite_tab,
        .clicked_editor_sprite_tab = .official,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(types.EditorSpritePickerTab.official, history.session.ui_state.editor_picker_sprite_tab);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .close_editor_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_picker == null);
}

test "palette + click: default type creation, tool switch, picker routing" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A png in the mission dir so the rescan at picker-open finds one.
    try harness.file_source.writeFile("missions/artists_den/boss.png", "png");

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .mission = .{ .path = "missions/artists_den" },
    }));
    runToIdle(&history);
    // All groups expanded going in: the add's accordion must collapse the
    // two the new type doesn't belong to.
    history.session.ui_state.editor_palette_collapsed = .{ false, false, false };

    // Entities "+": the shipped default lands, becomes the active tool, and
    // the base-sprite picker opens on it (Mission tab, the mission scan).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_palette_type,
        .clicked_editor_group = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 1), editor.entity_types.len);
        try testing.expectEqualStrings("New Entity", editor.entity_types[0].id);
        try testing.expect(std.meta.eql(
            types.EditorToolId{ .entity_type = 0 },
            editor.active_tool,
        ));
    }
    try testing.expectEqual(
        ui.EditorPickerTarget.entity_sprite,
        history.session.ui_state.editor_picker.?,
    );
    try testing.expectEqual(
        types.EditorSpritePickerTab.mission_local,
        history.session.ui_state.editor_picker_sprite_tab,
    );
    try testing.expectEqual(@as(usize, 1), history.session.editor_mission_sprites.len);
    // The add expanded the Entities group (accordion) — and a 1-type
    // group's window sits at the top.
    try testing.expectEqual([3]bool{ false, true, true }, history.session.ui_state.editor_palette_collapsed);
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_palette_scroll[0]);

    // Decorations "+": the stone_1 default + the decoration picker (the
    // stale entity picker from the previous click closes).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_palette_type,
        .clicked_editor_group = 1,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.decoration_types.len);
    try testing.expectEqualStrings(
        "stone_1",
        history.current_state.editor.?.decoration_types[0].sprite,
    );
    try testing.expectEqual(
        ui.EditorPickerTarget.decoration_sprite,
        history.session.ui_state.editor_picker.?,
    );
    try testing.expectEqual([3]bool{ true, false, true }, history.session.ui_state.editor_palette_collapsed);

    // Items "+": the New Sword default, NO picker (nothing to pick) — and
    // the decoration picker from the previous click closes.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_palette_type,
        .clicked_editor_group = 2,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.item_types.len);
    try testing.expectEqualStrings(
        "New Sword",
        history.current_state.editor.?.item_types[0].item.weapon.name,
    );
    try testing.expect(history.session.ui_state.editor_picker == null);
    try testing.expectEqual([3]bool{ true, true, false }, history.session.ui_state.editor_palette_collapsed);

    // A crafted out-of-range group index does nothing (no event, no
    // picker).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_palette_type,
        .clicked_editor_group = 3,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.entity_types.len);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "palette + click: the group's window scrolls to the newly added tool" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // 9 preset enemy types: at window offset 0 the 8-cell window shows
    // types 0..7, so the appended 10th would be OUT of view without the
    // scroll-to-the-new-tool.
    var entity_types: [9]types.EntityTypeDef = undefined;
    for (&entity_types, 0..) |*type_definition, index| {
        type_definition.* = .{ .id = try std.fmt.allocPrint(
            backing.allocator(),
            "Preset {d}",
            .{index},
        ) };
    }
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
    }));
    runToIdle(&history);

    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_palette_type,
        .clicked_editor_group = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);

    try testing.expectEqual(@as(usize, 10), history.current_state.editor.?.entity_types.len);
    // Accordion: the group expands, the others collapse.
    try testing.expectEqual([3]bool{ false, true, true }, history.session.ui_state.editor_palette_collapsed);
    // 10 types in an 8-cell window: offset 10 -| 8 = 2 — the new cell is
    // the window's last visible one (the minimal scroll that shows it).
    try testing.expectEqual(@as(i32, 2), history.session.ui_state.editor_palette_scroll[0]);
}

test "palette tool delete button: input arm deletes the type + placements; fixed tools no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Archer" },
        .{ .id = "Brute" },
    };
    const placements = [_]types.EntityPlacement{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
        .{ .type_id = 1, .position = .{ .x = 1, .y = 0 } }, // Brute
    };
    const levels = [_]types.EditorLevel{.{ .entity_placements = &placements }};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 1 },
    }));
    runToIdle(&history);

    // The Brute cell's delete button: the type + its placement go, the
    // active tool (it WAS the deleted one) resets to select.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_palette_type,
        .clicked_editor_tool = .{ .entity_type = 1 },
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 1), editor.entity_types.len);
        try testing.expectEqualStrings("Archer", editor.entity_types[0].id);
        try testing.expectEqual(@as(usize, 1), editor.levels[0].entity_placements.len);
        try testing.expect(std.meta.eql(types.EditorToolId.select, editor.active_tool));
    }

    // One undo restores the deletion.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.entity_types.len);
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.levels[0].entity_placements.len);

    // The fixed tools have no delete button — a crafted select/tile-
    // targeted click does nothing.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_palette_type,
        .clicked_editor_tool = .select,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.entity_types.len);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "player_add_editor_level: appends the template level, switches to it, undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .mission = .{ .level_count = 1 },
    }));
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_add_editor_level }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The shipped template (data/default_level.txt): the minimal `!=`
    // layout — '!' at (0,0), '=' at (1,0). The markers carry their own
    // ground (the layout walk tiles under '!' and '='), so exactly those
    // two tiles and nothing else; no entries, unnamed (the tab reads
    // "Level N"). The new level becomes the active tab and level_count
    // syncs.
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 2), editor.levels.len);
        const template_level = editor.levels[1];
        try testing.expectEqual(@as(usize, 0), template_level.name.len);
        try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, template_level.player_start);
        try testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, template_level.level_end.?);
        try testing.expectEqual(@as(usize, 2), template_level.level_tiles.len);
        try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, template_level.level_tiles[0]);
        try testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, template_level.level_tiles[1]);
        try testing.expectEqual(@as(usize, 0), template_level.entity_placements.len);
        try testing.expectEqual(@as(usize, 0), template_level.decoration_placements.len);
        try testing.expectEqual(@as(usize, 0), template_level.item_placements.len);
        try testing.expectEqual(@as(usize, 1), editor.active_level_index);
        try testing.expectEqual(@as(u32, 2), editor.mission.level_count);
    }

    // One undo reverts the append + the tab switch.
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 1), editor.levels.len);
        try testing.expectEqual(@as(usize, 0), editor.active_level_index);
        try testing.expectEqual(@as(u32, 1), editor.mission.level_count);
    }
}

test "editor_delete_level: removal + active-tab adjustment + level_count sync, undo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const level_0_tiles = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const level_1_tiles = [_]types.Vector2{.{ .x = 1, .y = 0 }};
    const level_2_tiles = [_]types.Vector2{.{ .x = 2, .y = 0 }};
    const levels = [_]types.EditorLevel{
        .{ .name = "A", .level_tiles = &level_0_tiles },
        .{ .name = "B", .level_tiles = &level_1_tiles },
        .{ .name = "C", .level_tiles = &level_2_tiles },
    };
    const selection = [_]types.Selectable{.{ .tile = .{ .x = 1, .y = 0 } }};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .mission = .{ .level_count = 3 },
        .active_level_index = 1, // B
        .selection = &selection,
    }));
    runToIdle(&history);

    // Delete BELOW the active tab (A): the active tab shifts down with its
    // level, the selection survives (the active level's placements are
    // untouched).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_delete_editor_level = .{
            .level_index = 0,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 2), editor.levels.len);
        try testing.expectEqualStrings("B", editor.levels[0].name);
        try testing.expectEqualStrings("C", editor.levels[1].name);
        try testing.expectEqual(@as(usize, 0), editor.active_level_index);
        try testing.expectEqual(@as(u32, 2), editor.mission.level_count);
        try testing.expectEqual(@as(usize, 1), editor.selection.len);
    }

    // Delete the ACTIVE level (B, now index 0): the tab clamps onto C and
    // the selection clears (the editor_set_active_level semantics).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_delete_editor_level = .{
            .level_index = 0,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 1), editor.levels.len);
        try testing.expectEqualStrings("C", editor.levels[0].name);
        try testing.expectEqual(@as(usize, 0), editor.active_level_index);
        try testing.expectEqual(@as(usize, 0), editor.selection.len);
    }

    // Two undos restore both deletions (levels, tabs, selection).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const editor = history.current_state.editor.?;
        try testing.expectEqual(@as(usize, 3), editor.levels.len);
        try testing.expectEqualStrings("A", editor.levels[0].name);
        try testing.expectEqual(@as(usize, 1), editor.active_level_index);
        try testing.expectEqual(@as(u32, 3), editor.mission.level_count);
        try testing.expectEqual(@as(usize, 1), editor.selection.len);
    }
}

test "level add/delete input arms: end-to-end + the single-level delete gate" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const level_0_tiles = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const level_1_tiles = [_]types.Vector2{.{ .x = 1, .y = 0 }};
    const levels = [_]types.EditorLevel{
        .{ .name = "A", .level_tiles = &level_0_tiles },
        .{ .name = "B", .level_tiles = &level_1_tiles },
    };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .mission = .{ .level_count = 2 },
    }));
    runToIdle(&history);

    // The top-bar "+": the template level lands + becomes the active tab.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_level,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 3), history.current_state.editor.?.levels.len);
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.active_level_index);

    // A tab's ×: the level goes; the active tab (2) shifts down with the
    // levels above the delete.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_level,
        .clicked_editor_level = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.levels.len);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.active_level_index);

    // Down to one level...
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_level,
        .clicked_editor_level = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.levels.len);

    // ...and the single-level gate holds: a crafted × click does nothing
    // (no event, no undo step — the handler's ≥1-level invariant is never
    // reached).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_level,
        .clicked_editor_level = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.levels.len);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "editor save: writes the mission files, memoizes the uuid, re-save reuses it" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();

    // A fresh-mission editor state (the open_editor-null shape).
    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 1, .y = 0 },
    }};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .mission = .{ .name = "New Mission", .path = "missions/New Mission", .level_count = 1 },
        .player_def = .{ .id = "Player", .template = .{ .name = "New Player", .sprite = "player", .team = 0 } },
    }));
    runToIdle(&history);

    // The ctrl+S / Save Mission path — an anytime action, no recorded event
    // (the dump_event_log class; no undo step).
    input_handlers.handleAnytimeInput(&history, .{
        .save_editor_mission = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // The session memo carries the minted uuid + the derived dir.
    const first_save = history.session.editor_saved_mission.?;
    try testing.expectEqual(@as(usize, 36), first_save.uuid.len);
    try testing.expect(first_save.uuid[14] == '4'); // v4 version nibble
    try testing.expect(std.mem.startsWith(u8, first_save.dir_path, "missions/"));
    try testing.expect(std.mem.endsWith(u8, first_save.dir_path, "_New Mission"));

    // The files landed in the persistent dir and parse: mission.txt carries
    // the minted uuid; level_1.txt + player.txt exist.
    {
        const mission_txt = try harness.file_source.readFile(
            arena,
            try std.fmt.allocPrint(arena, "{s}/mission.txt", .{first_save.dir_path}),
        );
        const sections = try parser.parseConfigFile(mission_txt, arena);
        const mission = try loaders.loadMission(sections, arena);
        try testing.expectEqualStrings(first_save.uuid, mission.uuid);
        try testing.expectEqualStrings("New Mission", mission.name);
        try testing.expectEqual(@as(u32, 1), mission.level_count);
    }
    {
        const level_txt = try harness.file_source.readFile(
            arena,
            try std.fmt.allocPrint(arena, "{s}/level_1.txt", .{first_save.dir_path}),
        );
        const sections = try parser.parseConfigFile(level_txt, arena);
        try testing.expect(parser.findSection(sections, "Layout") != null);
    }
    {
        const player_txt = try harness.file_source.readFile(
            arena,
            try std.fmt.allocPrint(arena, "{s}/player.txt", .{first_save.dir_path}),
        );
        const sections = try parser.parseConfigFile(player_txt, arena);
        _ = try loaders.loadPlayerLoadout(sections, arena, "test/player.txt", null);
    }

    // A second save REUSES the uuid + dir (the memo — no identity churn).
    // Own the first save's strings before the second save replaces the
    // memo (it frees + re-stores them — only the session field may hold
    // the borrowed slices).
    const first_uuid = try arena.dupe(u8, first_save.uuid);
    const first_dir_path = try arena.dupe(u8, first_save.dir_path);
    input_handlers.handleAnytimeInput(&history, .{
        .save_editor_mission = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    const second_save = history.session.editor_saved_mission.?;
    try testing.expectEqualStrings(first_uuid, second_save.uuid);
    try testing.expectEqualStrings(first_dir_path, second_save.dir_path);
}

test "editor export: saves first, bundles configs + custom sprites into the zip" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();

    // A fresh-mission editor + a custom sprite dropped into the placeholder
    // mission dir (pre-save — the export must bundle it from there).
    try harness.file_source.writeFile("missions/New Mission/boss.png", "pretend png bytes");
    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 1, .y = 0 },
    }};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .mission = .{ .name = "New Mission", .path = "missions/New Mission", .level_count = 1 },
        .player_def = .{ .id = "Player", .template = .{ .name = "New Player", .sprite = "player", .team = 0 } },
    }));
    runToIdle(&history);

    // The options-button path (an anytime side effect; the save runs first).
    input_handlers.handleAnytimeInput(&history, .{
        .export_editor_mission = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);

    // The save happened (memo set) + the zip landed at
    // exported_missions/<uuid>_<name>.zip.
    const saved = history.session.editor_saved_mission.?;
    const zip_path = try std.fmt.allocPrint(
        arena,
        "exported_missions/{s}_New Mission.zip",
        .{saved.uuid},
    );
    const zip_bytes = try harness.file_source.readFile(arena, zip_path);

    // STORE entries keep names + contents verbatim in the archive — the
    // configs, the custom sprite, and the mission text are all present.
    try testing.expect(std.mem.indexOf(u8, zip_bytes, "mission.txt") != null);
    try testing.expect(std.mem.indexOf(u8, zip_bytes, "player.txt") != null);
    try testing.expect(std.mem.indexOf(u8, zip_bytes, "level_1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, zip_bytes, "boss.png") != null);
    try testing.expect(std.mem.indexOf(u8, zip_bytes, "pretend png bytes") != null);
    try testing.expect(std.mem.indexOf(u8, zip_bytes, "name New Mission") != null);
}

test "decoration sprite picker: open routing, official prefab adopt, same-def no-op, entity-picker gate" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const stone_footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &stone_footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
        .color_index = 3,
    }};
    const tree_footprint = [_]types.Vector2{.{ .x = 1, .y = 2 }};
    const tree_layers = [_]types.DecorationLayer{.{
        .sprite = "tree_1_canopy",
        .color_index = 2,
        .pixel_dims = .{ .x = 512, .y = 768 },
    }};
    const registry = [_]types.DecorationTypeDef{.{
        .id = "tree_1",
        .sprite = "tree_1",
        .footprint = &tree_footprint,
        .pixel_dims = .{ .x = 512, .y = 768 },
        .color_index = 4,
        .layers = &tree_layers,
    }};
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
        .mission = .{ .path = "missions/artists_den" },
    }));
    history.session.editor_decoration_registry = &registry;
    runToIdle(&history);

    // Open: the decoration target's sprite row opens the DECORATION picker.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_sprite_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(
        ui.EditorPickerTarget.decoration_sprite,
        history.session.ui_state.editor_picker.?,
    );

    // Official pick: the WHOLE prefab adopts — sprite, footprint, dims,
    // color, layers — and the palette label tracks the sprite.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_sprite,
        .clicked_editor_sprite = "tree_1",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.session.ui_state.editor_picker == null);
    const adopted = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqualStrings("tree_1", adopted.id);
    try testing.expectEqualStrings("tree_1", adopted.sprite);
    try testing.expectEqual(@as(usize, 1), adopted.footprint.len);
    try testing.expectEqual(types.Vector2{ .x = 1, .y = 2 }, adopted.footprint[0]);
    try testing.expectEqual(types.Vector2{ .x = 512, .y = 768 }, adopted.pixel_dims);
    try testing.expectEqual(@as(u32, 4), adopted.color_index);
    try testing.expectEqual(@as(usize, 1), adopted.layers.len);

    // One undo reverts the whole adoption.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings("stone_2", history.current_state.editor.?.decoration_types[0].sprite);

    // Re-adopt (the post-undo state differs from the prefab), then a
    // SAME-DEFINITION re-pick closes without recording (no dead undo
    // step) — reopen first (the pick closed the picker).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_sprite_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_sprite,
        .clicked_editor_sprite = "tree_1",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqualStrings("tree_1", history.current_state.editor.?.decoration_types[0].sprite);
    const events_after_adopt = history.event_history.items.len;

    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_sprite_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_sprite,
        .clicked_editor_sprite = "tree_1",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.session.ui_state.editor_picker == null);
    try testing.expectEqual(events_after_adopt, history.event_history.items.len);

    // Gate: the decoration action with the ENTITY picker open is a no-op
    // (a crafted click — the cells never emit it).
    history.session.ui_state.editor_picker = .{ .entity_sprite = {} };
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_sprite,
        .clicked_editor_sprite = "tree_1",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.session.ui_state.editor_picker != null);
    try testing.expectEqualStrings("tree_1", history.current_state.editor.?.decoration_types[0].sprite);
}

test "decoration sprite picker: mission-local pick derives dims + bottom-left default footprint" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A minimal PNG header (signature + IHDR width/height at the offsets
    // parsePngDimensions reads): 512x768 → a 2x3 sprite grid → the default
    // footprint reserves the bottom-left tile (0, 2).
    const banner_png = [_]u8{
        0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
    } ++ [_]u8{0} ** 8 ++ [_]u8{
        0, 0, 2, 0, // width 512
        0, 0, 3, 0, // height 768
    };
    try harness.file_source.writeFile("missions/artists_den/banner.png", &banner_png);

    const stone_footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &stone_footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
        .color_index = 3,
    }};
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
        .mission = .{ .path = "missions/artists_den" },
    }));
    runToIdle(&history);

    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_sprite_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_sprite,
        .clicked_editor_sprite = "custom/artists_den/banner",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);

    // The namespaced stem + PNG-derived dims + the bottom-left default
    // footprint; color stays (no authored values for a custom stem).
    const adopted = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqualStrings("custom/artists_den/banner", adopted.sprite);
    try testing.expectEqualStrings("custom/artists_den/banner", adopted.id);
    try testing.expectEqual(types.Vector2{ .x = 512, .y = 768 }, adopted.pixel_dims);
    try testing.expectEqual(@as(usize, 1), adopted.footprint.len);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 2 }, adopted.footprint[0]);
    try testing.expectEqual(@as(u32, 3), adopted.color_index);
    try testing.expectEqual(@as(usize, 0), adopted.layers.len);

    // A vanished file (the stem resolves to no PNG) commits nothing.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_sprite_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_sprite,
        .clicked_editor_sprite = "custom/artists_den/gone",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqualStrings(
        "custom/artists_den/banner",
        history.current_state.editor.?.decoration_types[0].sprite,
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
    // clicked_editor_color; the target is the active entity tool).
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

    // No entity tool active (select tool): both clicks no-op.
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
    const field: types.TextFieldRef = .{ .id = .{ .entity_stat = .max_health }, .target = .{ .entity = .{ .entity_type = 0 } } };

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
        const field: types.TextFieldRef = .{ .id = .{ .item_name = .main_hand }, .target = .{ .entity = target } };
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
            .target = .{ .entity = target },
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
            .target = .{ .entity = target },
        };
        ui.beginTextEdit(&history.session.ui_state, field, "");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "7", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
        try testing.expect(history.session.ui_state.text_edit == null);
    }

    // An EMPTY slot commits nothing (no amulet to rename).
    {
        const field: types.TextFieldRef = .{ .id = .{ .item_name = .amulet }, .target = .{ .entity = target } };
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

test "inspector item-type clicks: reset-on-change, same-pick no-op, id tracks" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const item_types = [_]types.ItemTypeDef{.{
        .id = "Iron Sword",
        .item = .{ .weapon = .{
            .name = "Iron Sword",
            .weapon_type = .sword,
            .weapon_damage = 5,
        } },
    }};
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .item_types = &item_types,
        .active_tool = .{ .item_type = 0 },
    }));
    runToIdle(&history);

    // A DIFFERENT weapon type RESETS everything (author decision — no
    // retype-keeps-identity case, unlike the entity weapon slots):
    // "New Axe", damage 0; the palette label tracks the display name.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_item_type,
        .clicked_editor_item_kind = .weapon,
        .clicked_editor_weapon_type = .axe,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    {
        const definition = history.current_state.editor.?.item_types[0];
        const weapon = definition.item.weapon;
        try testing.expectEqualStrings("New Axe", weapon.name);
        try testing.expectEqual(types.WeaponType.axe, weapon.weapon_type);
        try testing.expectEqual(@as(u32, 0), weapon.weapon_damage);
        try testing.expectEqualStrings("New Axe", definition.id);
    }

    // One undo restores the sword whole (name + type + damage + label).
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const definition = history.current_state.editor.?.item_types[0];
        try testing.expectEqualStrings("Iron Sword", definition.item.weapon.name);
        try testing.expectEqual(types.WeaponType.sword, definition.item.weapon.weapon_type);
        try testing.expectEqual(@as(u32, 5), definition.item.weapon.weapon_damage);
        try testing.expectEqualStrings("Iron Sword", definition.id);
    }

    // The SAME pick never fires (no dead undo step).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_item_type,
        .clicked_editor_item_kind = .weapon,
        .clicked_editor_weapon_type = .sword,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // A KIND switch resets too — "New Amulet", zero stats.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_item_type,
        .clicked_editor_item_kind = .amulet,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    {
        const definition = history.current_state.editor.?.item_types[0];
        try testing.expectEqualStrings("New Amulet", definition.item.amulet.name);
        try testing.expectEqual(@as(u32, 0), definition.item.amulet.spell_damage);
        try testing.expectEqualStrings("New Amulet", definition.id);
    }

    // A weapon-kind pick without its weapon-type payload (crafted input)
    // commits nothing.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_item_type,
        .clicked_editor_item_kind = .weapon,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "item-type commits: name + stat fields end-to-end, no-op gates, bounds" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const item_types = [_]types.ItemTypeDef{.{
        .id = "Leather Coat",
        .item = .{ .coat = .{ .name = "Leather Coat", .health_bonus = 3, .defense_bonus = 2 } },
    }};
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .item_types = &item_types,
        .active_tool = .{ .item_type = 0 },
    }));
    runToIdle(&history);

    const no_keys: [0]?[]const u8 = .{};

    // NAME: commit through the real focus/type/Enter path; the label
    // tracks; one undo restores name + label.
    {
        const field: types.TextFieldRef = .{ .id = .item_def_name, .target = .{ .item_type = 0 } };
        ui.beginTextEdit(&history.session.ui_state, field, "Leather Coat");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, " of Wrath", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        const definition = history.current_state.editor.?.item_types[0];
        try testing.expectEqualStrings("Leather Coat of Wrath", definition.item.coat.name);
        try testing.expectEqualStrings("Leather Coat of Wrath", definition.id);
        // The other fields ride along untouched.
        try testing.expectEqual(@as(u32, 3), definition.item.coat.health_bonus);
        try testing.expectEqual(@as(u32, 2), definition.item.coat.defense_bonus);
        try testing.expect(history.undo(event_handlers.processEvent));
        try testing.expectEqualStrings(
            "Leather Coat",
            history.current_state.editor.?.item_types[0].item.coat.name,
        );
    }

    // A name commit whose buffer equals the current value records nothing.
    {
        const field: types.TextFieldRef = .{ .id = .item_def_name, .target = .{ .item_type = 0 } };
        ui.beginTextEdit(&history.session.ui_state, field, "Leather Coat");
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
        try testing.expect(history.session.ui_state.text_edit == null);
    }

    // A STAT: bounded — an out-of-range buffer clamps to the parser's own
    // max (single-sourced `itemStatMax`).
    {
        const field: types.TextFieldRef = .{
            .id = .{ .item_def_stat = .defense_bonus },
            .target = .{ .item_type = 0 },
        };
        ui.beginTextEdit(&history.session.ui_state, field, "2");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "99", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(
            types.max_defense_bonus,
            history.current_state.editor.?.item_types[0].item.coat.defense_bonus,
        );
        // Leading-zero numeric semantics: "03" == 3 records nothing.
        ui.beginTextEdit(&history.session.ui_state, field, "5");
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    }

    // A stat the kind doesn't carry commits nothing (a coat has no
    // spell_damage); a stale palette index commits nothing (crafted
    // focus).
    {
        const wrong_stat: types.TextFieldRef = .{
            .id = .{ .item_def_stat = .spell_damage },
            .target = .{ .item_type = 0 },
        };
        ui.beginTextEdit(&history.session.ui_state, wrong_stat, "");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "7", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

        const stale_field: types.TextFieldRef = .{ .id = .item_def_name, .target = .{ .item_type = 9 } };
        ui.beginTextEdit(&history.session.ui_state, stale_field, "Ghost");
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    }
}

test "editor_set_item_def: out-of-range type id is a no-op (handler guard)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const item_types = [_]types.ItemTypeDef{.{ .id = "Iron Sword" }};
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .item_types = &item_types,
    }));
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_item_def = .{
            .type_id = 9,
            .item_kind = .amulet,
            .name = "Ghost Amulet",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings("Iron Sword", history.current_state.editor.?.item_types[0].id);

    // The crafted-log clamp: stats beyond the max_* bounds are clamped by
    // the handler (the editor never holds a state its own load path
    // would clamp away).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_item_def = .{
            .type_id = 0,
            .item_kind = .weapon,
            .weapon_type = .axe,
            .name = "Ghost Axe",
            .weapon_damage = 99,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const definition = history.current_state.editor.?.item_types[0];
        try testing.expectEqualStrings("Ghost Axe", definition.item.weapon.name);
        try testing.expectEqual(@as(u32, types.max_weapon_damage), definition.item.weapon.weapon_damage);
        try testing.expectEqualStrings("Ghost Axe", definition.id);
    }
}

test "player_set_editor_entity_team: sets the template team (0 helpers, 2 enemy teams), undo reverts; out-of-range type is a no-op" {
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

    // Team 2 — a second, mutually hostile enemy team.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_entity_team = .{
            .target = .{ .entity_type = 0 },
            .value = 2,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 2), history.current_state.editor.?.entity_types[0].template.team);

    // One undo reverts (the commit rides the timeline like every scalar).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(u32, 1), history.current_state.editor.?.entity_types[0].template.team);

    // Team 0 — a player-team helper (enemy-authorable, player-uncontrolled).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_entity_team = .{
            .target = .{ .entity_type = 0 },
            .value = 0,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 0), history.current_state.editor.?.entity_types[0].template.team);

    // A crafted out-of-range type id records nothing (the shared handler
    // guard — editorEntityTemplate returns null and the arm returns).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_entity_team = .{
            .target = .{ .entity_type = 99 },
            .value = 1,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 0), history.current_state.editor.?.entity_types[0].template.team);
}

test "inspector team commits: numeric parse, would-change gate, empty no-op" {
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
    const field: types.TextFieldRef = .{ .id = .{ .entity_stat = .team }, .target = .{ .entity = .{ .entity_type = 0 } } };

    // Edit 1 → 2 (backspace, type 2): parsed + committed.
    ui.beginTextEdit(&history.session.ui_state, field, "1");
    _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "", &backspace_pressed, &no_keys, false);
    _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "2", &no_keys, &no_keys, false);
    input_handlers.resolveTextEditOutcome(&history, .commit);
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 2), history.current_state.editor.?.entity_types[0].template.team);

    // Team 0 — the helper case — commits the same way.
    ui.beginTextEdit(&history.session.ui_state, field, "2");
    _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "", &backspace_pressed, &no_keys, false);
    _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "0", &no_keys, &no_keys, false);
    input_handlers.resolveTextEditOutcome(&history, .commit);
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 0), history.current_state.editor.?.entity_types[0].template.team);

    // Empty buffer commits nothing (no event, value intact).
    ui.beginTextEdit(&history.session.ui_state, field, "0");
    _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "", &backspace_pressed, &no_keys, false);
    input_handlers.resolveTextEditOutcome(&history, .commit);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expectEqual(@as(u32, 0), history.current_state.editor.?.entity_types[0].template.team);
    try testing.expect(history.session.ui_state.text_edit == null);

    // Same-value input (0 → "0") records nothing: two undos revert both
    // commits above.
    ui.beginTextEdit(&history.session.ui_state, field, "0");
    input_handlers.resolveTextEditOutcome(&history, .commit);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(u32, 2), history.current_state.editor.?.entity_types[0].template.team);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(u32, 1), history.current_state.editor.?.entity_types[0].template.team);
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

test "player_select_editor_all: tool-agnostic — switches to select, one undo restores tool + selection" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
    }};
    var history = harness.newHistory(editorStateWith(marqueeTestEditor(&levels)));
    // Seed the tile tool BEFORE runToIdle so the idle-point snapshot
    // captures it (undo replays to that snapshot).
    history.current_state.editor.?.active_tool = .tile;
    runToIdle(&history);

    // ctrl+A from the TILE tool: the action fires, switches to the select
    // tool (the selection can only live there), and selects everything
    // (the tile + the '!').
    input_handlers.handleIdleInput(&history, .{ .select_editor_all = true }, .{});
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try testing.expect(
        history.current_state.event_stack[0].player_input_event == .player_select_editor_all,
    );
    runToIdle(&history);
    {
        const editor = history.current_state.editor.?;
        try testing.expect(editor.active_tool == .select);
        try testing.expectEqual(@as(usize, 2), editor.selection.len);
        try testing.expect(selectionContainsEntry(editor.selection, .{ .tile = .{ .x = 1, .y = 1 } }));
        try testing.expect(selectionContainsEntry(editor.selection, .player_start));
    }

    // ONE undo step restores the previous tool AND the empty selection
    // (the switch rode the select-all's idle point).
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const editor = history.current_state.editor.?;
        try testing.expect(editor.active_tool == .tile);
        try testing.expectEqual(@as(usize, 0), editor.selection.len);
    }

    // Select tool, but everything (the tile + the '!') is already
    // selected: the plan is empty, so nothing fires (no dead undo step).
    history.current_state.editor.?.active_tool = .select;
    const everything = [_]types.Selectable{ .{ .tile = .{ .x = 1, .y = 1 } }, .player_start };
    history.current_state.editor.?.selection = &everything;
    input_handlers.handleIdleInput(&history, .{ .select_editor_all = true }, .{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

/// Membership check for a `Selectable` entry in a selection slice (test-
/// local; the production `selectionContains` lives in editor/planning.zig).
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
    event_push.pushPlayerAction(
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

    event_push.pushPlayerAction(
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

    event_push.pushPlayerAction(
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
    event_push.pushPlayerAction(
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

    event_push.pushPlayerAction(
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
    event_push.pushPlayerAction(
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
    event_push.pushEvents(
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
    event_push.pushEvents(
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
    event_push.pushEvents(
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
    event_push.pushEvents(
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

    event_push.pushEvents(
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

    event_push.pushEvents(
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
        try testing.expect(player_handlers.isSkillLearned(
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
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .end_playtest }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings("Campaign Player", history.current_state.player_data.player_name);
    try testing.expect(history.current_state.editor.?.pre_playtest_player_data == null);
    try testing.expect(history.current_state.editor.?.mode == .edit);
}

/// The mission dir the file-based validation tests run against (the
/// harness's scratch persistent dir): a small two-level mission whose
/// files deliberately differ from the in-memory editor state the tests
/// also set up — asserts can then prove the run read the FILES, not the
/// editor memory. Level 1's player starts at x=0 ('!='), level 2's at
/// x=2 ('..!='), so a test can tell which level file instantiated the
/// current level; the player.txt loadout carries a distinctive
/// damage-7 sword (the loadout format carries no name, so it reads back
/// as "Player").
const validation_fixture_path = "missions/validation_fixture";

fn writeValidationFixtureMission(harness: *Harness) !void {
    try harness.file_source.writeFile(
        validation_fixture_path ++ "/mission.txt",
        \\Metadata
        \\file_format_version 2
        \\mission_uuid 33333333-3333-3333-3333-333333333333
        \\name Validation Fixture
        \\level_count 2
        \\
    );
    try harness.file_source.writeFile(
        validation_fixture_path ++ "/level_1.txt",
        \\Metadata
        \\file_format_version 1
        \\name Fixture Level One
        \\
        \\Layout
        \\!=
        \\
    );
    try harness.file_source.writeFile(
        validation_fixture_path ++ "/level_2.txt",
        \\Metadata
        \\file_format_version 1
        \\name Fixture Level Two
        \\
        \\Layout
        \\..!=
        \\
    );
    try harness.file_source.writeFile(
        validation_fixture_path ++ "/player.txt",
        \\Metadata
        \\file_format_version 2
        \\
        \\MainHandWeapon
        \\item_name Fixture Sword
        \\weapon_type sword
        \\damage 7
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
}

test "start_validation runs the SAVED mission files, not the editor memory" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    try writeValidationFixtureMission(&harness);

    // The in-memory editor differs from the fixture files on purpose:
    // THREE levels (the fixture has two) + a bare player_def, so any
    // value the run shows can be attributed to its source.
    const levels = [_]types.EditorLevel{ .{}, .{}, .{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .player_def = .{ .id = "Player", .template = .{ .name = "Editor Player" } },
    }));
    runToIdle(&history);
    history.current_state.player_data = .{ .player_name = "Campaign Player" };

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .start_validation = .{
            .mission_path = validation_fixture_path,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The run is up, in validate mode, on the FILE's level 1: the level
    // name + the player position come from level_1.txt ('!' at x=0), not
    // from the editor's memory.
    try testing.expect(history.current_state.screen == .level);
    try testing.expect(history.current_state.editor.?.mode == .validate);
    try testing.expect(history.current_state.mission.?.validation_run);
    try testing.expectEqualStrings(validation_fixture_path, history.current_state.mission.?.path);
    try testing.expectEqualStrings("Fixture Level One", history.current_state.level.?.name);
    try testing.expectEqual(
        types.Vector2{ .x = 0, .y = 0 },
        history.current_state.level.?.entities[0].position,
    );

    // The editor is untouched (dormant): its three in-memory levels + the
    // editor player_def survive — the run never read them.
    try testing.expectEqual(@as(usize, 3), history.current_state.editor.?.levels.len);
    try testing.expectEqualStrings(
        "Editor Player",
        history.current_state.editor.?.player_def.template.name,
    );

    // The run's player data was built from the SAVED player.txt: the
    // loadout name reads back as "Player" (the format carries no name)
    // and the fixture's damage-7 sword synced onto the level player via
    // the chained start_level's build_player_from_data. Learned = every
    // utility skill (the validation player knows everything).
    try testing.expectEqualStrings("Player", history.current_state.player_data.player_name);
    try testing.expectEqual(@as(u32, 7), history.current_state.player_data.main_hand_weapon.?.weapon_damage);
    try testing.expectEqual(
        @as(u32, 7),
        history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_damage,
    );
    const utility_skills = @import("utility_skills.zig");
    try testing.expectEqual(
        @as(usize, utility_skills.utility_skill_ids.len),
        history.current_state.player_data.learned_skills.len,
    );

    // The session's real data is backed up on the Editor.
    try testing.expectEqualStrings(
        "Campaign Player",
        history.current_state.editor.?.pre_playtest_player_data.?.player_name,
    );
}

test "player_start_playtest starts the active level; the exit returns to the editor" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{ .{}, .{}, .{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .active_level_index = 1,
        .player_def = .{ .id = "Player", .template = .{ .name = "Editor Player" } },
    }));
    runToIdle(&history);
    history.current_state.player_data = .{ .player_name = "Campaign Player" };

    // The Test button's orchestrator: playtest of the ACTIVE level (1).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_start_playtest }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .level);
    try testing.expect(history.current_state.editor.?.mode == .playtest);
    try testing.expect(history.current_state.level != null);
    // 1-based gameplay index of the instantiated level: active 1 → 2.
    try testing.expectEqual(@as(u32, 2), history.current_state.mission.?.current_level_index);
    try testing.expectEqualStrings("Editor Player", history.current_state.player_data.player_name);

    // Natural level completion (end_level, default continuation) exits
    // back to the editor + restores the session's real player data.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .end_level = .{} } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .editor);
    try testing.expect(history.current_state.editor.?.mode == .edit);
    try testing.expect(history.current_state.level == null);
    try testing.expect(history.current_state.mission == null);
    try testing.expectEqualStrings("Campaign Player", history.current_state.player_data.player_name);
}

test "a validation run chains the mission's levels (turns accumulate) and completes back in the editor" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    try writeValidationFixtureMission(&harness);

    // ONE in-memory editor level (the fixture has TWO): the chaining
    // follows the file's level_count, not editor.levels.len.
    const levels = [_]types.EditorLevel{.{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .player_def = .{ .id = "Player", .template = .{ .name = "Editor Player" } },
    }));
    runToIdle(&history);
    history.current_state.player_data = .{ .player_name = "Campaign Player" };

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .start_validation = .{
            .mission_path = validation_fixture_path,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 1), history.current_state.mission.?.current_level_index);

    // Spend a turn on level 1 (the turn_end machinery, as the skip
    // orchestrators would push it — no enemies, so the round is empty).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 1), history.current_state.mission.?.turns_spent);

    // A mid-run mutation (an in-level event) — the chained level start
    // must neither rebuild the run data nor re-capture the backup.
    history.current_state.player_data.player_name = "Mutated In Run";

    // Completing level 1 chains level 2 FROM THE FILE (the editor's
    // single level is irrelevant): level_2.txt's '!' is at x=2, the
    // mission working copy persists (turns carried over), the mutation
    // survives, and the backup is still the campaign data.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .end_level = .{} } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .level);
    try testing.expectEqualStrings("Fixture Level Two", history.current_state.level.?.name);
    try testing.expectEqual(
        types.Vector2{ .x = 2, .y = 0 },
        history.current_state.level.?.entities[0].position,
    );
    try testing.expectEqual(@as(u32, 2), history.current_state.mission.?.current_level_index);
    try testing.expectEqual(@as(u32, 1), history.current_state.mission.?.turns_spent);
    try testing.expectEqualStrings("Mutated In Run", history.current_state.player_data.player_name);
    try testing.expectEqualStrings(
        "Campaign Player",
        history.current_state.editor.?.pre_playtest_player_data.?.player_name,
    );

    // Spend a turn + complete the LAST level: the run ends — editor, edit
    // mode, real data restored, run state discarded, backup cleared.
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
    try testing.expect(history.current_state.level == null);
    try testing.expect(history.current_state.mission == null);
    try testing.expectEqualStrings("Campaign Player", history.current_state.player_data.player_name);
    try testing.expect(history.current_state.editor.?.pre_playtest_player_data == null);
}

test "a validation run's exit continuation aborts to the editor (success=false)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    try writeValidationFixtureMission(&harness);

    const levels = [_]types.EditorLevel{ .{}, .{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .player_def = .{ .id = "Player", .template = .{ .name = "Editor Player" } },
    }));
    runToIdle(&history);
    history.current_state.player_data = .{ .player_name = "Campaign Player" };

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .start_validation = .{
            .mission_path = validation_fixture_path,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // Death-exit shape: the mission-fail overlay / options menu routes
    // through end_level with a non-default continuation. The run aborts —
    // no next-level chain, back to the editor, real player data restored.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .end_level = .{ .continuation = .exit_mission } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .editor);
    try testing.expect(history.current_state.editor.?.mode == .edit);
    try testing.expect(history.current_state.level == null);
    try testing.expect(history.current_state.mission == null);
    try testing.expectEqualStrings("Campaign Player", history.current_state.player_data.player_name);
    try testing.expect(history.current_state.editor.?.pre_playtest_player_data == null);
}

test "a playtest restart continuation re-runs the same level fresh" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{ .{}, .{}, .{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .active_level_index = 1,
        .player_def = .{ .id = "Player", .template = .{ .name = "Editor Player" } },
    }));
    runToIdle(&history);
    history.current_state.player_data = .{ .player_name = "Campaign Player" };

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_start_playtest }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 2), history.current_state.mission.?.current_level_index);

    // Mid-run mutation, then the restart (the mission-fail overlay's
    // "Restart Playtest"): end + fresh re-entry of the SAME level.
    history.current_state.player_data.player_name = "Mutated In Run";
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .end_level = .{ .continuation = .restart_mission } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .level);
    try testing.expect(history.current_state.editor.?.mode == .playtest);
    try testing.expectEqual(@as(u32, 2), history.current_state.mission.?.current_level_index);
    // The run data was REBUILT from the loadout (fresh run) — and the
    // session's real data is still what's backed up.
    try testing.expectEqualStrings("Editor Player", history.current_state.player_data.player_name);
    try testing.expectEqualStrings(
        "Campaign Player",
        history.current_state.editor.?.pre_playtest_player_data.?.player_name,
    );
}

test "a validation restart re-runs the whole mission from level 1 via the orchestrator" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    try writeValidationFixtureMission(&harness);

    const levels = [_]types.EditorLevel{ .{}, .{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .player_def = .{ .id = "Player", .template = .{ .name = "Editor Player" } },
    }));
    runToIdle(&history);
    history.current_state.player_data = .{ .player_name = "Campaign Player" };

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .start_validation = .{
            .mission_path = validation_fixture_path,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    // Spend a turn + advance to level 2 (the natural completion path).
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
    try testing.expectEqual(@as(u32, 2), history.current_state.mission.?.current_level_index);
    try testing.expectEqual(@as(u32, 1), history.current_state.mission.?.turns_spent);

    // Mid-run mutation, then the restart: back to level 1 with fresh run
    // data (NOT the mutated carry-over, NOT a next-level advance) — the
    // re-entry rides the player_start_validation ORCHESTRATOR (the
    // seedable-top-level rule for the validation-replay slice), which
    // re-reads the files fresh: mission counter reset, loadout rebuilt.
    history.current_state.player_data.player_name = "Mutated In Run";
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .meta_event = .{ .end_level = .{ .continuation = .restart_mission } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .level);
    try testing.expect(history.current_state.editor.?.mode == .validate);
    try testing.expectEqualStrings("Fixture Level One", history.current_state.level.?.name);
    try testing.expectEqual(@as(u32, 1), history.current_state.mission.?.current_level_index);
    try testing.expectEqual(@as(u32, 0), history.current_state.mission.?.turns_spent);
    try testing.expectEqualStrings("Player", history.current_state.player_data.player_name);
    try testing.expectEqual(
        @as(u32, 7),
        history.current_state.player_data.main_hand_weapon.?.weapon_damage,
    );
    try testing.expectEqualStrings(
        "Campaign Player",
        history.current_state.editor.?.pre_playtest_player_data.?.player_name,
    );
}

test "exit to main menu during an editor run ends the run and closes the editor" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    try writeValidationFixtureMission(&harness);

    const levels = [_]types.EditorLevel{ .{}, .{} };
    const enter_run = [_]events.Event{
        .{ .player_input_event = .player_start_playtest },
        .{ .player_input_event = .{ .player_start_validation = .{
            .mission_path = validation_fixture_path,
        } } },
    };
    for (enter_run) |start| {
        var history = harness.newHistory(editorStateWith(.{
            .levels = &levels,
            .player_def = .{ .id = "Player", .template = .{ .name = "Editor Player" } },
        }));
        runToIdle(&history);
        history.current_state.player_data = .{ .player_name = "Campaign Player" };

        event_push.pushEvents(
            &history.current_state,
            &.{start},
            history.current_arena.allocator(),
        );
        runToIdle(&history);
        try testing.expect(history.current_state.screen == .level);

        // Mid-run mutation, then the options menu's Exit to Main Menu:
        // the run ends (data restored) AND the editor session is gone —
        // the button means the main menu, not the editor.
        history.current_state.player_data.player_name = "Mutated In Run";
        event_push.pushEvents(
            &history.current_state,
            &.{.{ .meta_event = .{ .end_level = .{ .continuation = .exit_to_menu } } }},
            history.current_arena.allocator(),
        );
        runToIdle(&history);
        try testing.expect(history.current_state.screen == .main_menu);
        try testing.expect(history.current_state.editor == null);
        try testing.expect(history.current_state.level == null);
        try testing.expect(history.current_state.mission == null);
        try testing.expectEqualStrings("Campaign Player", history.current_state.player_data.player_name);
    }
}

test "a validation run's slice reconstructs from a fresh state (no editor — the cross-session shape)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    try writeValidationFixtureMission(&harness);

    // No editor at all — the cross-session shape a validation replay is
    // reconstructed in (the future server-side check; the mission files
    // ship alongside the replay). Drive the run exactly as a player
    // session would: every top-level event is a whitelisted orchestrator,
    // so the slice passes the replay-seam legality gates as-is.
    var history = harness.newHistory(null);
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_start_validation = .{
            .mission_path = validation_fixture_path,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .level);
    try testing.expect(history.current_state.editor == null);
    try testing.expect(history.current_state.mission.?.validation_run);

    // Level 1: end the turn (skip orchestrator → auto-skip attack with no
    // enemies → turn_end), then step onto the level end ('=' at x=1).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_skip_move = .{} } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 1), history.current_state.mission.?.turns_spent);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_move_action = .{
            .destination = .{ .x = 1, .y = 0 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings("Fixture Level Two", history.current_state.level.?.name);

    // Level 2: end the turn first (turn_end #2), then step onto the
    // level end ('=' at x=3). NOTE: stepping onto the level end cuts the
    // FINAL turn short — check_level_end → end_level runs before the
    // pending attack step/turn_end (the transition clears the stack) —
    // so a beeline finish contributes no turn_end; turns_spent counts
    // COMPLETED turns. The explicit skip keeps the count honest here.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_skip_move = .{} } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 2), history.current_state.mission.?.turns_spent);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_move_action = .{
            .destination = .{ .x = 3, .y = 0 },
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    // No editor existed, so end_validation lands on the main menu.
    try testing.expect(history.current_state.screen == .main_menu);
    try testing.expect(history.current_state.editor == null);
    try testing.expect(history.current_state.mission == null);

    // The slice: from the LAST player_start_validation through the end —
    // here the whole run (the only earlier event is the boot
    // open_main_menu). Restarts would make "last" matter; this run has
    // none.
    var slice_start: usize = 0;
    for (history.event_history.items, 0..) |event, index| {
        if (event == .player_input_event and event.player_input_event == .player_start_validation) {
            slice_start = index;
        }
    }
    const slice = history.event_history.items[slice_start..];
    // Derived turns == the live run's counter (one turn per level).
    try testing.expectEqual(@as(u32, 2), validation_replay.deriveValidationTurns(slice));

    // Serialize + reconstruct the slice in a SECOND fresh history: the
    // server-side validation primitive, client-side. Reconstruct to just
    // BEFORE the final end_validation so the mission is still live — the
    // replay-reproduced turn counter must equal the derived count.
    const body = try session_log.writeEventLog(slice, "20260101_000000", backing.allocator());
    const sections = try parser.parseConfigFile(body, backing.allocator());
    const log = try session_log.loadEventLog(sections, backing.allocator());
    // The reconstruction base: the post-boot state (main menu, nothing
    // queued) — the slice starts at the run's entry orchestrator, so the
    // fresh history's stack must be EMPTY (newHistory(null) queues the
    // boot open_main_menu, which the slice deliberately excludes).
    var reconstruction_start = test_harness.defaultStartingState();
    reconstruction_start.event_stack = &.{};
    var history2 = harness.newHistory(reconstruction_start);
    history2.reconstructFromEventLog(log.events, @intCast(log.events.len - 1), &event_handlers.processEvent);
    try testing.expect(history2.current_state.mission != null);
    try testing.expect(history2.current_state.mission.?.validation_run);
    try testing.expectEqual(@as(u32, 2), history2.current_state.mission.?.turns_spent);

    // The full slice (end_validation included) lands on the main menu,
    // exactly as the live no-editor run did.
    var history3 = harness.newHistory(reconstruction_start);
    history3.reconstructFromEventLog(log.events, @intCast(log.events.len), &event_handlers.processEvent);
    try testing.expect(history3.current_state.screen == .main_menu);
    try testing.expect(history3.current_state.editor == null);
    try testing.expect(history3.current_state.mission == null);
}

/// Script one full validation run through the fixture mission: push
/// start_validation, then per level either a full turn (skip + step onto
/// the level end — 1 turn_end per level) or a beeline (straight onto the
/// end — 0 turn_endsWith: the level ends before the pending attack step
/// runs). The run completes back in the editor.
fn playFixtureRunToCompletion(history: *state.GameStateHistory, beeline: bool) !void {
    // The ORCHESTRATOR (the button path — also the shape the replay slice
    // keys on: every attempt begins with player_start_validation).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_start_validation = .{
            .mission_path = validation_fixture_path,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(history);
    var level_index: u32 = 0;
    while (level_index < 2) : (level_index += 1) {
        if (!beeline) {
            event_push.pushEvents(
                &history.current_state,
                &.{.{ .player_input_event = .{ .player_skip_move = .{} } }},
                history.current_arena.allocator(),
            );
            runToIdle(history);
        }
        // The level end: x=1 on level 1, x=3 on level 2.
        const end_x: i32 = if (level_index == 0) 1 else 3;
        event_push.pushEvents(
            &history.current_state,
            &.{.{ .player_input_event = .{ .player_move_action = .{
                .destination = .{ .x = end_x, .y = 0 },
            } } }},
            history.current_arena.allocator(),
        );
        runToIdle(history);
    }
    try testing.expect(history.current_state.screen == .editor);
    try testing.expect(history.current_state.mission == null);
}

/// Read the fixture mission's validation_replay.txt + derive its turn
/// count (the file's observable state).
fn readFixtureReplay(
    harness: *Harness,
    arena: std.mem.Allocator,
) !struct { turns: u32, replay: validation_replay.ValidationReplay } {
    const bytes = try harness.file_source.readFile(
        arena,
        validation_fixture_path ++ "/validation_replay.txt",
    );
    const sections = try parser.parseConfigFile(bytes, arena);
    const replay = try validation_replay.loadValidationReplay(sections, arena);
    return .{ .turns = validation_replay.deriveValidationTurns(replay.events), .replay = replay };
}

test "the Validate button saves first and the finished run writes a reconstructable validation_replay.txt" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();

    // The editor-save test's shape, with TWO levels (each the minimal
    // '!=' layout — the save's translation is identity at the bbox).
    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const levels = [_]types.EditorLevel{
        .{ .level_tiles = &tiles, .player_start = .{ .x = 0, .y = 0 }, .level_end = .{ .x = 1, .y = 0 } },
        .{ .level_tiles = &tiles, .player_start = .{ .x = 0, .y = 0 }, .level_end = .{ .x = 1, .y = 0 } },
    };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .mission = .{ .name = "New Mission", .path = "missions/New Mission", .level_count = 2 },
        .player_def = .{ .id = "Player", .template = .{ .name = "New Player", .sprite = "player", .team = 0 } },
    }));
    runToIdle(&history);

    // The REAL button path: the input layer saves first, then pushes the
    // run with the saved dir as the payload.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .validate_editor_mission,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.current_state.screen == .level);
    const saved = history.session.editor_saved_mission.?;
    try testing.expectEqualStrings(saved.dir_path, history.current_state.mission.?.path);

    // Play it to completion: a full turn per level, then the level end.
    var level_index: u32 = 0;
    while (level_index < 2) : (level_index += 1) {
        event_push.pushEvents(
            &history.current_state,
            &.{.{ .player_input_event = .{ .player_skip_move = .{} } }},
            history.current_arena.allocator(),
        );
        runToIdle(&history);
        event_push.pushEvents(
            &history.current_state,
            &.{.{ .player_input_event = .{ .player_move_action = .{
                .destination = .{ .x = 1, .y = 0 },
            } } }},
            history.current_arena.allocator(),
        );
        runToIdle(&history);
    }
    try testing.expect(history.current_state.screen == .editor);

    // The replay landed next to the mission files, with the mission's
    // identity + the content hash of the dir the run certified.
    const replay_path = try std.fmt.allocPrint(
        arena,
        "{s}/validation_replay.txt",
        .{saved.dir_path},
    );
    const replay_bytes = try harness.file_source.readFile(arena, replay_path);
    const sections = try parser.parseConfigFile(replay_bytes, arena);
    const replay = try validation_replay.loadValidationReplay(sections, arena);
    try testing.expectEqualStrings(saved.uuid, replay.mission_uuid);
    const hash = try content_hash.computeMissionHash(&harness.file_source, arena, saved.dir_path, 2);
    const hash_hex = content_hash.hashToHex(hash);
    try testing.expectEqualStrings(&hash_hex, replay.content_hash);
    // Derived turns == the live run's completed-turn counter (one full
    // turn per level).
    try testing.expectEqual(@as(u32, 2), validation_replay.deriveValidationTurns(replay.events));
    // First validation (no prior file): auto-write — nothing stashed, no
    // manual-overwrite offer.
    try testing.expect(history.session.pending_validation_replay == null);
    try testing.expect(!history.session.validation_replay_overwrite_offered);

    // Cross-session reconstruction from the WRITTEN FILE (the server-side
    // check's client-side prototype): replay-reproduced turns == derived.
    var reconstruction_start = test_harness.defaultStartingState();
    reconstruction_start.event_stack = &.{};
    var history2 = harness.newHistory(reconstruction_start);
    history2.reconstructFromEventLog(replay.events, @intCast(replay.events.len - 1), &event_handlers.processEvent);
    try testing.expectEqual(@as(u32, 2), history2.current_state.mission.?.turns_spent);
    var history3 = harness.newHistory(reconstruction_start);
    history3.reconstructFromEventLog(replay.events, @intCast(replay.events.len), &event_handlers.processEvent);
    try testing.expect(history3.current_state.screen == .main_menu);
    try testing.expect(history3.current_state.mission == null);
}

test "the personal-best guard: first/faster/hash-mismatch write, slower keeps + stashes" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    try writeValidationFixtureMission(&harness);

    const levels = [_]types.EditorLevel{ .{}, .{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .player_def = .{ .id = "Player", .template = .{ .name = "Editor Player" } },
    }));
    runToIdle(&history);

    // Run A (2 turns): the FIRST validation — no prior file → auto-write.
    try playFixtureRunToCompletion(&history, false);
    {
        const result = try readFixtureReplay(&harness, arena);
        try testing.expectEqual(@as(u32, 2), result.turns);
    }
    try testing.expect(history.session.pending_validation_replay == null);
    try testing.expect(!history.session.validation_replay_overwrite_offered);

    // Run B (the beeline — 0 turns): strictly faster → auto-overwrite.
    try playFixtureRunToCompletion(&history, true);
    {
        const result = try readFixtureReplay(&harness, arena);
        try testing.expectEqual(@as(u32, 0), result.turns);
    }
    try testing.expect(history.session.pending_validation_replay == null);
    try testing.expect(!history.session.validation_replay_overwrite_offered);

    // Run C (2 turns again): SLOWER than the 0-turn best → keep the old
    // file, stash the new bytes, offer the manual overwrite.
    try playFixtureRunToCompletion(&history, false);
    {
        const result = try readFixtureReplay(&harness, arena);
        try testing.expectEqual(@as(u32, 0), result.turns); // the file is UNCHANGED (the best run)
    }
    try testing.expect(history.session.pending_validation_replay != null);
    try testing.expect(history.session.validation_replay_overwrite_offered);
    {
        // The stash holds the slower run's slice (2 turns) — what the
        // Overwrite Replay button would write.
        const sections = try parser.parseConfigFile(history.session.pending_validation_replay.?, arena);
        const stashed = try validation_replay.loadValidationReplay(sections, arena);
        try testing.expectEqual(@as(u32, 2), validation_replay.deriveValidationTurns(stashed.events));
    }

    // Run D after EDITING the mission: the old replay's hash no longer
    // matches (it certifies an earlier version) → auto-overwrite
    // regardless of turns — even though this run (2 turns) is slower than
    // the 0-turn file.
    try harness.file_source.writeFile(
        validation_fixture_path ++ "/level_1.txt",
        \\Metadata
        \\file_format_version 1
        \\name Fixture Level One Prime
        \\
        \\Layout
        \\!=
        \\
    );
    try playFixtureRunToCompletion(&history, false);
    {
        const result = try readFixtureReplay(&harness, arena);
        try testing.expectEqual(@as(u32, 2), result.turns); // the new run's — overwritten despite being slower
    }
    // The auto-write cleared the stash + the offer.
    try testing.expect(history.session.pending_validation_replay == null);
    try testing.expect(!history.session.validation_replay_overwrite_offered);
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
        \\Entities
        \\
        \\Decorations
        \\
        \\Items
        \\
    );

    var history = harness.newHistory(null);
    runToIdle(&history);

    event_push.pushEvents(
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
        [_]bool{false} ** @typeInfo(types.EditorInspectorSectionId).@"enum".fields.len,
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

test "entity layer picker: add via pick, re-pick keeps color, same-sprite no-op, delete, color swap" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 },
    }};
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
        .mission = .{ .path = "missions/artists_den" },
    }));
    runToIdle(&history);

    // Open in ADD mode (no layer payload) → the entity-layer picker.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_entity_layer_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(
        ui.EditorPickerTarget{ .entity_layer = null },
        history.session.ui_state.editor_picker.?,
    );

    // Pick: a new layer, color 0 (no authored source for entity layers).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_entity_layer,
        .clicked_editor_sprite = "bear",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    var template = history.current_state.editor.?.entity_types[0].template;
    try testing.expectEqual(@as(usize, 1), template.layers.len);
    try testing.expectEqualStrings("bear", template.layers[0].sprite);
    try testing.expectEqual(@as(u32, 0), template.layers[0].color_index);

    // Color swap: the whole layer value commits with the color swapped.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_entity_layer_color,
        .clicked_editor_layer = 0,
        .clicked_editor_color = 4,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    template = history.current_state.editor.?.entity_types[0].template;
    try testing.expectEqual(@as(u32, 4), template.layers[0].color_index);

    // Open in EDIT mode (layer 0) → re-pick another stem; the layer's
    // color is KEPT (the weapon-retype semantics).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_entity_layer_picker,
        .clicked_editor_layer = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(
        ui.EditorPickerTarget{ .entity_layer = 0 },
        history.session.ui_state.editor_picker.?,
    );
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_entity_layer,
        .clicked_editor_sprite = "wolf",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    template = history.current_state.editor.?.entity_types[0].template;
    try testing.expectEqualStrings("wolf", template.layers[0].sprite);
    try testing.expectEqual(@as(u32, 4), template.layers[0].color_index);

    // Same-sprite re-pick closes without recording.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_entity_layer_picker,
        .clicked_editor_layer = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    const events_before = history.event_history.items.len;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_entity_layer,
        .clicked_editor_sprite = "wolf",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(events_before, history.event_history.items.len);

    // Delete: the layer is removed, one undo restores it.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_entity_layer,
        .clicked_editor_layer = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.entity_types[0].template.layers.len);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 1), history.current_state.editor.?.entity_types[0].template.layers.len);
}

test "decoration layer picker: registry-authored color, custom dims check keeps the picker open on mismatch" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A 768x768 PNG (matching the base's dims) + a 256x256 one (mismatch).
    const png_header = struct {
        fn make(width: u32, height: u32) [24]u8 {
            var bytes = [_]u8{
                0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
            } ++ [_]u8{0} ** 8 ++ [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
            std.mem.writeInt(u32, bytes[16..20], width, .big);
            std.mem.writeInt(u32, bytes[20..24], height, .big);
            return bytes;
        }
    }.make;
    try harness.file_source.writeFile("missions/artists_den/banner.png", &png_header(768, 768));
    try harness.file_source.writeFile("missions/artists_den/small.png", &png_header(256, 256));

    // The base type is 768x768 (tree_1's real dims); the registry's
    // tree_1 prefab carries a canopy layer (color 2) at the same dims.
    const footprint = [_]types.Vector2{.{ .x = 1, .y = 2 }};
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "tree_1",
        .sprite = "tree_1",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 768, .y = 768 },
    }};
    const registry_layers = [_]types.DecorationLayer{.{
        .sprite = "tree_1_canopy",
        .color_index = 2,
        .pixel_dims = .{ .x = 768, .y = 768 },
    }};
    const registry = [_]types.DecorationTypeDef{.{
        .id = "tree_1",
        .sprite = "tree_1",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 768, .y = 768 },
        .layers = &registry_layers,
    }};
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
        .mission = .{ .path = "missions/artists_den" },
    }));
    history.session.editor_decoration_registry = &registry;
    runToIdle(&history);

    // ADD via an official stem that is a registry prefab's authored layer:
    // the color adopts the authored value (2), dims match the base.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_decoration_layer_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(
        ui.EditorPickerTarget{ .decoration_layer = null },
        history.session.ui_state.editor_picker.?,
    );
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_layer,
        .clicked_editor_sprite = "tree_1_canopy",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    var definition = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqual(@as(usize, 1), definition.layers.len);
    try testing.expectEqualStrings("tree_1_canopy", definition.layers[0].sprite);
    try testing.expectEqual(@as(u32, 2), definition.layers[0].color_index);
    try testing.expectEqual(types.Vector2{ .x = 768, .y = 768 }, definition.layers[0].pixel_dims);

    // ADD via a custom stem with MATCHING dims: resolved from the PNG,
    // color 0 (no registry match).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_decoration_layer_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_layer,
        .clicked_editor_sprite = "custom/artists_den/banner",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    definition = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqual(@as(usize, 2), definition.layers.len);
    try testing.expectEqualStrings("custom/artists_den/banner", definition.layers[1].sprite);
    try testing.expectEqual(types.Vector2{ .x = 768, .y = 768 }, definition.layers[1].pixel_dims);

    // A custom stem with MISMATCHED dims: the picker STAYS OPEN and
    // nothing records (the load-time layer invariant).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_decoration_layer_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    const events_before = history.event_history.items.len;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_layer,
        .clicked_editor_sprite = "custom/artists_den/small",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.session.ui_state.editor_picker != null);
    try testing.expectEqual(events_before, history.event_history.items.len);
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.decoration_types[0].layers.len);

    // EDIT re-pick keeps the layer's color; the color swatch commits the
    // whole layer; delete compacts.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .close_editor_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_decoration_layer_picker,
        .clicked_editor_layer = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_layer,
        .clicked_editor_sprite = "tree_1",
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    definition = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqualStrings("tree_1", definition.layers[0].sprite);
    try testing.expectEqual(@as(u32, 2), definition.layers[0].color_index);

    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_decoration_layer_color,
        .clicked_editor_layer = 0,
        .clicked_editor_color = 5,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_decoration_layer,
        .clicked_editor_layer = 1,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    definition = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqual(@as(usize, 1), definition.layers.len);
    try testing.expectEqual(@as(u32, 5), definition.layers[0].color_index);
}

test "player_set_editor_decoration_footprint: adopts + prunes, empty/out-of-bounds/bad-type ignored" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // A 512x512 type (a 2x2 sprite grid) starting WIDE ({(0,0),(1,0)} —
    // a placement at P covers P and P+1x). The NEW tall footprint
    // ({(0,0),(0,1)}, anchor (0,1)) covers (P.x, P.y-1) and P — the tile
    // at (5,4) sits under the NEW footprint only → the (5,5) placement is
    // pruned, the (0,0) one survives, the tile stays.
    const wide_footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "block",
        .sprite = "ruin_1",
        .footprint = &wide_footprint,
        .pixel_dims = .{ .x = 512, .y = 512 },
    }};
    const tiles = [_]types.Vector2{.{ .x = 5, .y = 4 }};
    const placements = [_]types.DecorationPlacement{
        .{ .type_id = 0, .position = .{ .x = 5, .y = 5 } },
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
    };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .decoration_placements = &placements,
    }};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .decoration_types = &decoration_types,
    }));
    runToIdle(&history);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_decoration_footprint = .{
            .type_id = 0,
            .value = &tall_footprint,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    const editor = history.current_state.editor.?;
    try testing.expectEqual(@as(usize, 2), editor.decoration_types[0].footprint.len);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, editor.decoration_types[0].footprint[0]);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 1 }, editor.decoration_types[0].footprint[1]);
    try testing.expectEqual(@as(usize, 1), editor.levels[0].decoration_placements.len);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, editor.levels[0].decoration_placements[0].position);
    try testing.expect(hasTile(editor.levels[0], .{ .x = 5, .y = 4 }));

    // One event = one undo step (footprint + prune together).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.levels[0].decoration_placements.len);

    // Crafted-log defense: an empty footprint, a tile outside the sprite
    // grid, and a bad type id all record nothing.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_decoration_footprint = .{
            .type_id = 0,
            .value = &.{},
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    const out_of_bounds = [_]types.Vector2{.{ .x = 5, .y = 0 }};
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_decoration_footprint = .{
            .type_id = 0,
            .value = &out_of_bounds,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_decoration_footprint = .{
            .type_id = 99,
            .value = &tall_footprint,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.decoration_types[0].footprint.len);
}

test "footprint editor input: open seeds the draft, toggles flip, confirm commits or no-ops" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    // The wide type: a 2x1 sprite grid, footprint cells (0,0) + (1,0).
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .decoration_types = decorationTestEditor(&levels).decoration_types,
        .active_tool = .{ .decoration_type = 0 },
    }));
    runToIdle(&history);

    // Open: the draft seeds from the current footprint, the picker
    // carries the type id.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_footprint_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(
        ui.EditorPickerTarget{ .decoration_footprint = 0 },
        history.session.ui_state.editor_picker.?,
    );
    try testing.expect(history.session.ui_state.editor_footprint_draft[0]);
    try testing.expect(history.session.ui_state.editor_footprint_draft[1]);
    try testing.expect(!history.session.ui_state.editor_footprint_draft[2]);

    // Toggle (1,0) off and back on: the draft is a plain UiState flip.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_footprint_tile,
        .clicked_editor_footprint_tile = 1,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(!history.session.ui_state.editor_footprint_draft[1]);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_footprint_tile,
        .clicked_editor_footprint_tile = 1,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_footprint_draft[1]);

    // An out-of-range cell (crafted) flips nothing.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_footprint_tile,
        .clicked_editor_footprint_tile = 99,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_footprint_draft[1]);

    // Confirm an UNCHANGED draft: closes, nothing records.
    const events_before = history.event_history.items.len;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .confirm_editor_footprint,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.session.ui_state.editor_picker == null);
    try testing.expectEqual(events_before, history.event_history.items.len);

    // Re-open, deselect everything: the confirm STAYS OPEN (a footprint
    // needs >= 1 tile), nothing records.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_footprint_picker,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_footprint_tile,
        .clicked_editor_footprint_tile = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_footprint_tile,
        .clicked_editor_footprint_tile = 1,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .confirm_editor_footprint,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.session.ui_state.editor_picker != null);
    try testing.expectEqual(events_before, history.event_history.items.len);

    // A CHANGED draft commits: select (0,0) only → footprint {(0,0)},
    // row-major, on the undo timeline.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_footprint_tile,
        .clicked_editor_footprint_tile = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .confirm_editor_footprint,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.session.ui_state.editor_picker == null);
    const definition = history.current_state.editor.?.decoration_types[0];
    try testing.expectEqual(@as(usize, 1), definition.footprint.len);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, definition.footprint[0]);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.decoration_types[0].footprint.len);
}

test "metadata sidebar metadata commits: names, color wheel, gradient overrides" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    var levels = [_]types.EditorLevel{ .{ .name = "First", .color_wheel_index = 1 } };
    const editor = types.Editor{ .levels = &levels, .mission = .{ .name = "Old Name" } };
    var history = harness.newHistory(editorStateWith(editor));
    runToIdle(&history);

    // Mission name (mission-scoped, no level index).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_mission_name = .{
            .name = "New Name",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings("New Name", history.current_state.editor.?.mission.name);

    // Level name + world gradient index (level-indexed, tab 0).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_level_name = .{
            .level_index = 0,
            .name = "Renamed",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings("Renamed", history.current_state.editor.?.levels[0].name);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_level_color_wheel = .{
            .level_index = 0,
            .color_wheel_index = 4,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 4), history.current_state.editor.?.levels[0].color_wheel_index);

    // Gradient overrides: a pick sets the manual index; null reverts to
    // auto-derivation (the Auto toggle). Both ride the undo timeline.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_level_enemy_gradient = .{
            .level_index = 0,
            .gradient_index = 2,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(?u32, 2), history.current_state.editor.?.levels[0].enemy_gradient_index);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_level_player_gradient = .{
            .level_index = 0,
            .gradient_index = null,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqual(@as(?u32, null), history.current_state.editor.?.levels[0].player_gradient_index);

    // One undo per commit: walking back all five reaches the state
    // before the mission-name commit (the original name).
    for (0..5) |_| try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings("Old Name", history.current_state.editor.?.mission.name);
    try testing.expectEqualStrings("First", history.current_state.editor.?.levels[0].name);
    try testing.expectEqual(@as(u32, 1), history.current_state.editor.?.levels[0].color_wheel_index);
}

test "player_toggle_editor_metadata_sidebar: flips the open state, undo restores" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);
    // CLOSED on editor open (unlike the inspector — the metadata is a
    // reference panel, not the first thing an author needs).
    try testing.expect(!history.current_state.editor.?.metadata_sidebar_open);

    event_push.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .player_toggle_editor_metadata_sidebar }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expect(history.current_state.editor.?.metadata_sidebar_open);

    // The toggle rides the undo timeline (the flag lives on the Editor).
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(!history.current_state.editor.?.metadata_sidebar_open);
}

test "metadata sidebar name fields: mission + level commits, no-op gates" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{
        .{ .name = "Level One" },
        .{ .name = "Level Two" },
    };
    const editor = types.Editor{
        .levels = &levels,
        .mission = .{ .name = "Old Mission" },
        .active_level_index = 1,
    };
    var history = harness.newHistory(editorStateWith(editor));
    runToIdle(&history);

    const no_keys: [0]?[]const u8 = .{};
    const enter_pressed: [1]?[]const u8 = .{"Enter"};

    // Mission name: type through the real routing path, resolve Enter.
    const mission_field: types.TextFieldRef = .{ .id = .mission_name, .target = .mission };
    ui.beginTextEdit(&history.session.ui_state, mission_field, "Old Mission");
    const outcome = ui.routeTextInput(
        &history.session.ui_state.text_edit.?,
        " Revised",
        &enter_pressed,
        &no_keys,
        false,
    );
    try testing.expectEqual(types.TextEditOutcome.commit, outcome);
    input_handlers.resolveTextEditOutcome(&history, .commit);
    try testing.expectEqualStrings("Old Mission Revised", history.current_state.editor.?.mission.name);
    try testing.expect(history.session.ui_state.text_edit == null);

    // Level name: the active tab is 1 — the ref target carries the index.
    const level_field: types.TextFieldRef = .{ .id = .level_name, .target = .{ .level = 1 } };
    ui.beginTextEdit(&history.session.ui_state, level_field, "Level Two");
    _ = ui.routeTextInput(
        &history.session.ui_state.text_edit.?,
        "!",
        &enter_pressed,
        &no_keys,
        false,
    );
    input_handlers.resolveTextEditOutcome(&history, .commit);
    try testing.expectEqualStrings("Level Two!", history.current_state.editor.?.levels[1].name);
    // The OTHER level is untouched (the index rode the target).
    try testing.expectEqualStrings("Level One", history.current_state.editor.?.levels[0].name);

    // One undo per commit: two undos reach the original mission name.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings("Level Two", history.current_state.editor.?.levels[1].name);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings("Old Mission", history.current_state.editor.?.mission.name);

    // No-op gate: an unchanged value never records (no dead undo step).
    ui.beginTextEdit(&history.session.ui_state, mission_field, "Old Mission");
    _ = ui.routeTextInput(
        &history.session.ui_state.text_edit.?,
        "",
        &enter_pressed,
        &no_keys,
        false,
    );
    input_handlers.resolveTextEditOutcome(&history, .commit);
    try testing.expectEqualStrings("Old Mission", history.current_state.editor.?.mission.name);
    try testing.expect(!history.undo(event_handlers.processEvent));

    // A stale level index (the level deleted mid-edit) commits nothing.
    const stale_field: types.TextFieldRef = .{ .id = .level_name, .target = .{ .level = 9 } };
    ui.beginTextEdit(&history.session.ui_state, stale_field, "Ghost");
    _ = ui.routeTextInput(
        &history.session.ui_state.text_edit.?,
        " Level",
        &enter_pressed,
        &no_keys,
        false,
    );
    input_handlers.resolveTextEditOutcome(&history, .commit);
    try testing.expectEqualStrings("Level One", history.current_state.editor.?.levels[0].name);
    try testing.expectEqualStrings("Level Two", history.current_state.editor.?.levels[1].name);
}

test "theme picker: open targets the active level, picks commit per role, auto flips" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{
        .{ .color_wheel_index = 0 },
        .{ .color_wheel_index = 2 },
    };
    const editor = types.Editor{ .levels = &levels, .active_level_index = 1 };
    var history = harness.newHistory(editorStateWith(editor));
    runToIdle(&history);

    // Open on the ENEMY row: the picker target snapshots the active tab
    // (level 1) + the role. (handleAnytimeInput's committing arms drain
    // + record their own idle points — no runToIdle needed after.)
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_level_gradient_picker,
        .clicked_editor_gradient_role = .enemy,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(
        ui.EditorPickerTarget{ .level_gradient = .{ .level_index = 1, .role = .enemy } },
        history.session.ui_state.editor_picker.?,
    );

    // A pick commits the override (auto → manual in the same commit) and
    // closes the picker.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_level_gradient,
        .clicked_editor_gradient = 4,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.session.ui_state.editor_picker == null);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expectEqual(@as(?u32, 4), history.current_state.editor.?.levels[1].enemy_gradient_index);
    // Level 0 untouched (the index rode the target).
    try testing.expectEqual(@as(?u32, null), history.current_state.editor.?.levels[0].enemy_gradient_index);

    // Same-value pick while MANUAL: closes without RECORDING — the event
    // history is the precise no-op proof (runToIdle's idle points don't
    // dedupe, so undo-step counting can't distinguish a dead step from a
    // duplicate point at an unchanged state).
    const history_len_after_pick = history.event_history.items.len;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_level_gradient_picker,
        .clicked_editor_gradient_role = .enemy,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_level_gradient,
        .clicked_editor_gradient = 4,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_picker == null);
    try testing.expectEqual(@as(?u32, 4), history.current_state.editor.?.levels[1].enemy_gradient_index.?);
    runToIdle(&history);
    try testing.expectEqual(history_len_after_pick, history.event_history.items.len);

    // The Auto button reverts the override to null (one undo step back to
    // the manual pick).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_level_gradient_auto,
        .clicked_editor_gradient_role = .enemy,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(?u32, null), history.current_state.editor.?.levels[1].enemy_gradient_index);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(?u32, 4), history.current_state.editor.?.levels[1].enemy_gradient_index.?);
    try testing.expect(history.redo(event_handlers.processEvent));
    try testing.expectEqual(@as(?u32, null), history.current_state.editor.?.levels[1].enemy_gradient_index);

    // The Auto button while ALREADY auto flips to manual by FREEZING the
    // derived index (wheel 2, 3 gradients → derived enemy = 0) — a real
    // commit, one undo back to auto.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_level_gradient_auto,
        .clicked_editor_gradient_role = .enemy,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(?u32, 0), history.current_state.editor.?.levels[1].enemy_gradient_index.?);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(?u32, null), history.current_state.editor.?.levels[1].enemy_gradient_index);
    try testing.expect(history.redo(event_handlers.processEvent));
    try testing.expectEqual(@as(?u32, 0), history.current_state.editor.?.levels[1].enemy_gradient_index.?);

    // The WORLD role: a pick sets the wheel index; the world row has no
    // Auto semantics (a crafted world Auto click never fires).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_level_gradient_picker,
        .clicked_editor_gradient_role = .world,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_level_gradient,
        .clicked_editor_gradient = 1,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 1), history.current_state.editor.?.levels[1].color_wheel_index);
    const history_len_before_world_auto = history.event_history.items.len;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .toggle_editor_level_gradient_auto,
        .clicked_editor_gradient_role = .world,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 1), history.current_state.editor.?.levels[1].color_wheel_index);
    try testing.expectEqual(history_len_before_world_auto, history.event_history.items.len);

    // A pick with no picker open (crafted click) is a no-op.
    const history_len_before_crafted = history.event_history.items.len;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_level_gradient,
        .clicked_editor_gradient = 3,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 1), history.current_state.editor.?.levels[1].color_wheel_index);
    try testing.expectEqual(history_len_before_crafted, history.event_history.items.len);
}

test "metadata sidebar wheel routing: scrolls over the open panel, not elsewhere" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);
    // The panel is CLOSED on editor open — open it for the routing check.
    history.current_state.editor.?.metadata_sidebar_open = true;

    // Inside the open panel: one wheel-down notch = one row down;
    // wheel-up at the top clamps at 0.
    const inside: types.ScreenPosition = .{
        .x = ui.editorMetadataSidebarPanelRect().x + 100,
        .y = ui.editorMetadataSidebarPanelRect().y + 100,
    };
    input_handlers.handleAnytimeInput(&history, .{ .scroll_delta = -1 }, inside, &.{});
    try testing.expectEqual(@as(i32, 1), history.session.ui_state.editor_metadata_scroll);
    input_handlers.handleAnytimeInput(&history, .{ .scroll_delta = 1 }, inside, &.{});
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_metadata_scroll);

    // Outside the panel (over the viewport): the wheel belongs to the
    // camera-zoom branch — the metadata offset is untouched.
    input_handlers.handleAnytimeInput(
        &history,
        .{ .scroll_delta = -1 },
        .{ .x = 1920, .y = 1080 },
        &.{},
    );
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_metadata_scroll);

    // Panel closed: the routing falls through even inside the rect.
    history.current_state.editor.?.metadata_sidebar_open = false;
    input_handlers.handleAnytimeInput(&history, .{ .scroll_delta = -1 }, inside, &.{});
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_metadata_scroll);
}

// --- editor mission browser ---

test "mission browser: toggle opens (scan + reset) editor-only, escape closes above the options menu" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(editorStartingState(&.{
        .{ .player_start = .{ .x = 0, .y = 0 } },
    }));
    runToIdle(&history);

    // The toggle opens the browser: fresh view state (scroll 0, local tab)
    // + both lists scanned (the official one parsed from the embedded
    // mission files — the shipped campaign is always there).
    input_handlers.handleAnytimeInput(&history, .{
        .toggle_editor_mission_browser = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_mission_browser_open);
    try testing.expectEqual(types.EditorMissionBrowserTab.local, history.session.ui_state.editor_mission_browser_tab);
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_mission_scroll_offset);
    try testing.expect(history.session.editor_official_missions.len > 0);
    try testing.expect(history.session.editor_official_missions_scanned);

    // The browser opens ON TOP of the options menu (the settings-screen
    // stacking): Escape steps back one layer — only the browser closes.
    history.session.ui_state.options_menu_open = true;
    input_handlers.handleAnytimeInput(&history, .{
        .toggle_options_menu = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(!history.session.ui_state.editor_mission_browser_open);
    try testing.expect(history.session.ui_state.options_menu_open);

    // Re-toggle while a stale scroll + tab linger: both reset on open.
    history.session.ui_state.editor_mission_scroll_offset = 7;
    history.session.ui_state.editor_mission_browser_tab = .official;
    input_handlers.handleAnytimeInput(&history, .{
        .toggle_editor_mission_browser = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_mission_browser_open);
    try testing.expectEqual(types.EditorMissionBrowserTab.local, history.session.ui_state.editor_mission_browser_tab);
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_mission_scroll_offset);
    input_handlers.handleAnytimeInput(&history, .{
        .toggle_editor_mission_browser = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(!history.session.ui_state.editor_mission_browser_open);

    // Editor-only: on a non-editor screen the toggle is a no-op (the
    // save_editor_mission discipline).
    history.current_state.screen = .main_menu;
    history.current_state.editor = null;
    input_handlers.handleAnytimeInput(&history, .{
        .toggle_editor_mission_browser = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(!history.session.ui_state.editor_mission_browser_open);
}

test "mission browser: row click opens the mission, tab switch resets scroll, wheel scrolls rows" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(editorStartingState(&.{
        .{ .player_start = .{ .x = 0, .y = 0 } },
    }));
    runToIdle(&history);

    // A local mission in the harness's scratch persistent dir: the minimal
    // valid shape (mission.txt + one level with the '!=' layout).
    harness.file_source.writeFile("missions/test_mission/mission.txt",
        "Metadata\nfile_format_version 2\nmission_uuid 11111111-1111-1111-1111-111111111111\nlevel_count 1\nname Test Mission\n") catch @panic("w1");
    harness.file_source.writeFile("missions/test_mission/level_1.txt",
        "Metadata\nfile_format_version 1\n\nLayout\n!=\n") catch @panic("w2");

    // Open the browser (scans) — the local list now carries the mission.
    input_handlers.handleAnytimeInput(&history, .{
        .toggle_editor_mission_browser = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 1), history.session.editor_local_missions.len);
    try testing.expectEqualStrings("missions/test_mission", history.session.editor_local_missions[0].path);

    // While the browser is open the wheel scrolls its rows (whole rows,
    // lower-clamped at 0 — wheel-up past the top stays; the upper clamp is
    // the builder's).
    history.session.ui_state.editor_mission_scroll_offset = 0;
    input_handlers.handleAnytimeInput(&history, .{ .scroll_delta = 1 }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(i32, 0), history.session.ui_state.editor_mission_scroll_offset);

    // A tab switch is a direct UiState write + scroll reset.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_mission_tab,
        .clicked_editor_mission_tab = .official,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(types.EditorMissionBrowserTab.official, history.session.ui_state.editor_mission_browser_tab);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_mission_tab,
        .clicked_editor_mission_tab = .local,
    }, .{ .x = 0, .y = 0 }, &.{});

    // The row click: pushes open_editor with the row's path and drains —
    // the editor swaps to the opened mission, world_generation bumps (the
    // driver's UI reset signal — the browser itself clears there), and the
    // event is on the recorded timeline (undo restores the previous
    // mission).
    const generation_before = history.current_state.world_generation;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .open_editor_mission_row,
        .clicked_editor_mission_row = 0,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expectEqualStrings("Test Mission", history.current_state.editor.?.mission.name);
    try testing.expectEqual(@as(u32, 1), history.current_state.editor.?.mission.level_count);
    try testing.expectEqual(generation_before + 1, history.current_state.world_generation);

    // Undo across the swap: the previous (fresh) editor mission returns
    // (editorStartingState's default — empty name, the fresh-mission shape).
    _ = history.undo(event_handlers.processEvent);
    try testing.expectEqualStrings("", history.current_state.editor.?.mission.name);
}

// --- editor mission browser: the zip import ---

test "mission import: a picked zip extracts into missions/, the row appears, the artifacts clean up" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    var history = harness.newHistory(editorStartingState(&.{
        .{ .player_start = .{ .x = 0, .y = 0 } },
    }));
    runToIdle(&history);

    // A mission zip (the Export Mission shape): configs + a custom sprite.
    const zip_entries = [_]zip_writer.ZipEntry{
        .{ .name = "mission.txt", .bytes =
        "Metadata\nfile_format_version 2\nmission_uuid a1b2c3d4-e5f6-7890-abcd-ef1234567890\nlevel_count 1\nname Skeleton Den\n" },
        .{ .name = "level_1.txt", .bytes = "Metadata\nfile_format_version 1\n\nLayout\n!=\n" },
        .{ .name = "boss.png", .bytes = "pretend png bytes" },
    };
    const archive = try zip_writer.writeZipArchive(&zip_entries, arena);
    harness.file_source.writeFile("imported_missions/skeleton_den.zip", archive) catch @panic("zip write");

    // The upload marker (the web JS writes this after the file lands).
    harness.file_source.writeFile(".mission_import_marker", "imported_missions/skeleton_den.zip") catch @panic("marker write");

    // Open the browser + run one anytime tick (the poll runs while open).
    input_handlers.handleAnytimeInput(&history, .{
        .toggle_editor_mission_browser = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_mission_browser_open);
    input_handlers.handleAnytimeInput(&history, .{}, .{ .x = 0, .y = 0 }, &.{});

    // The row: name + the save-convention dir path derived from the zip's
    // mission.txt (uuid + sanitized name).
    try testing.expectEqual(@as(usize, 1), history.session.editor_local_missions.len);
    const entry = history.session.editor_local_missions[0];
    try testing.expectEqualStrings("Skeleton Den", entry.name);
    try testing.expectEqualStrings(
        "missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_Skeleton Den",
        entry.path,
    );
    try testing.expectEqual(@as(u32, 1), entry.level_count);

    // The extracted files exist (one spot-check), the marker + zip are gone.
    const png = try harness.file_source.readFile(
        arena,
        "missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_Skeleton Den/boss.png",
    );
    try testing.expectEqualStrings("pretend png bytes", png);
    try testing.expect(!harness.file_source.fileExists(".mission_import_marker"));
    try testing.expect(!harness.file_source.fileExists("imported_missions/skeleton_den.zip"));
    try testing.expect(history.session.pending_error == null);
}

test "mission import: an OS-made zip with a single root folder strips it" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    var history = harness.newHistory(editorStartingState(&.{
        .{ .player_start = .{ .x = 0, .y = 0 } },
    }));
    runToIdle(&history);

    // The "compress folder" shape: every file under one root segment, plus
    // macOS junk that must be skipped.
    const zip_entries = [_]zip_writer.ZipEntry{
        .{ .name = "Skeleton Den/mission.txt", .bytes =
        "Metadata\nfile_format_version 2\nmission_uuid 22222222-2222-2222-2222-222222222222\nlevel_count 1\nname Skeleton Den\n" },
        .{ .name = "Skeleton Den/level_1.txt", .bytes = "Metadata\nfile_format_version 1\n\nLayout\n!=\n" },
        .{ .name = "__MACOSX/Skeleton Den/._mission.txt", .bytes = "junk" },
        .{ .name = "Skeleton Den/.DS_Store", .bytes = "junk" },
    };
    const archive = try zip_writer.writeZipArchive(&zip_entries, arena);
    harness.file_source.writeFile("imported_missions/os_made.zip", archive) catch @panic("zip write");
    harness.file_source.writeFile(".mission_import_marker", "imported_missions/os_made.zip") catch @panic("marker write");

    input_handlers.handleAnytimeInput(&history, .{
        .toggle_editor_mission_browser = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{}, .{ .x = 0, .y = 0 }, &.{});

    // The root stripped (mission.txt found at the stripped root), the junk
    // skipped (no stray files inside the mission dir), one row.
    try testing.expectEqual(@as(usize, 1), history.session.editor_local_missions.len);
    try testing.expectEqualStrings(
        "missions/22222222-2222-2222-2222-222222222222_Skeleton Den",
        history.session.editor_local_missions[0].path,
    );
    try testing.expect(!harness.file_source.fileExists(
        "missions/22222222-2222-2222-2222-222222222222_Skeleton Den/.DS_Store",
    ));
    try testing.expect(!harness.file_source.fileExists(
        "missions/22222222-2222-2222-2222-222222222222_Skeleton Den/_MACOSX_Skeleton Den_._mission.txt",
    ));
    try testing.expect(history.session.pending_error == null);
}

test "mission import: an unsafe entry name fails whole — popup, nothing written" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    var history = harness.newHistory(editorStartingState(&.{
        .{ .player_start = .{ .x = 0, .y = 0 } },
    }));
    runToIdle(&history);

    const zip_entries = [_]zip_writer.ZipEntry{
        .{ .name = "mission.txt", .bytes =
        "Metadata\nfile_format_version 2\nmission_uuid 33333333-3333-3333-3333-333333333333\nlevel_count 1\nname Evil\n" },
        .{ .name = "../escape.txt", .bytes = "should never be written" },
    };
    const archive = try zip_writer.writeZipArchive(&zip_entries, arena);
    harness.file_source.writeFile("imported_missions/evil.zip", archive) catch @panic("zip write");
    harness.file_source.writeFile(".mission_import_marker", "imported_missions/evil.zip") catch @panic("marker write");

    input_handlers.handleAnytimeInput(&history, .{
        .toggle_editor_mission_browser = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{}, .{ .x = 0, .y = 0 }, &.{});

    // The popup explains, the list stays empty, and NOTHING was written —
    // names are validated before the first write (never half-imported).
    try testing.expect(history.session.pending_error != null);
    try testing.expectEqual(@as(usize, 0), history.session.editor_local_missions.len);
    try testing.expect(!harness.file_source.fileExists("missions"));
    try testing.expect(!harness.file_source.fileExists("../escape.txt"));

    // The marker is consumed (no spin); the zip stays for re-inspection.
    try testing.expect(!harness.file_source.fileExists(".mission_import_marker"));
    try testing.expect(harness.file_source.fileExists("imported_missions/evil.zip"));
}

test "mission import: a zip without mission.txt pops up instead of extracting" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    var history = harness.newHistory(editorStartingState(&.{
        .{ .player_start = .{ .x = 0, .y = 0 } },
    }));
    runToIdle(&history);

    const zip_entries = [_]zip_writer.ZipEntry{
        .{ .name = "not_a_mission.txt", .bytes = "hello" },
    };
    const archive = try zip_writer.writeZipArchive(&zip_entries, arena);
    harness.file_source.writeFile("imported_missions/random.zip", archive) catch @panic("zip write");
    harness.file_source.writeFile(".mission_import_marker", "imported_missions/random.zip") catch @panic("marker write");

    input_handlers.handleAnytimeInput(&history, .{
        .toggle_editor_mission_browser = true,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{}, .{ .x = 0, .y = 0 }, &.{});

    try testing.expect(history.session.pending_error != null);
    try testing.expectEqual(@as(usize, 0), history.session.editor_local_missions.len);
    try testing.expect(!harness.file_source.fileExists(".mission_import_marker"));
}

test "editor inventory slot events: add default sword, def retype, rename, delete; undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    // Add: the default sword (the editor_defaults.txt Items entry — the
    // palette "+" default).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_add_editor_inventory_item = .{ .index = 0 } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const slot = history.current_state.editor.?.player_def.template.inventory.slots[0];
        try testing.expectEqual(types.WeaponType.sword, slot.?.weapon.weapon_type);
        try testing.expectEqualStrings("New Sword", slot.?.weapon.name);
        try testing.expectEqual(@as(u32, 0), slot.?.weapon.weapon_damage);
    }

    // One undo step reverts the add; redo walks it back in.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.editor.?.player_def.template.inventory.slots[0] == null);
    try testing.expect(history.redo(event_handlers.processEvent));
    {
        const slot = history.current_state.editor.?.player_def.template.inventory.slots[0];
        try testing.expectEqualStrings("New Sword", slot.?.weapon.name);
    }

    // Def commit (a type pick — reset-everything semantics): replace the
    // sword with a coat; the crafted-log clamp applies to stats over max.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_set_editor_inventory_item_def = .{
            .index = 0,
            .item_kind = .coat,
            .name = "Ghost Coat",
            .defense_bonus = 99,
            .health_bonus = 2,
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    {
        const slot = history.current_state.editor.?.player_def.template.inventory.slots[0];
        try testing.expectEqualStrings("Ghost Coat", slot.?.coat.name);
        try testing.expectEqual(types.max_defense_bonus, slot.?.coat.defense_bonus);
        try testing.expectEqual(@as(u32, 2), slot.?.coat.health_bonus);
    }

    // Rename: top-level string event (multi-word names are the point).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_set_editor_inventory_item_name = .{
            .index = 0,
            .value = "Wool Coat",
        } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings(
        "Wool Coat",
        history.current_state.editor.?.player_def.template.inventory.slots[0].?.coat.name,
    );

    // The slot's item never leaks onto another slot.
    try testing.expect(history.current_state.editor.?.player_def.template.inventory.slots[1] == null);

    // Delete clears to null; undo walks back through rename + def (the
    // add was undone above).
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_delete_editor_inventory_item = .{ .index = 0 } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.editor.?.player_def.template.inventory.slots[0] == null);
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqualStrings(
        "Wool Coat",
        history.current_state.editor.?.player_def.template.inventory.slots[0].?.coat.name,
    );
}

test "editor inventory item handlers: crafted-log guards no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    // An occupied slot for the occupied-add / rename / delete guards.
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_add_editor_inventory_item = .{ .index = 5 } },
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // Out-of-range index: ignored.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_add_inventory_item = .{
            .index = types.inventory_slot_count,
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // Add onto an occupied slot: a no-op (the slot keeps its item).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_add_inventory_item = .{ .index = 5 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expectEqualStrings(
        "New Sword",
        history.current_state.editor.?.player_def.template.inventory.slots[5].?.weapon.name,
    );

    // Def + name commits on an EMPTY slot: no-ops.
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_inventory_item_def = .{
            .index = 6,
            .item_kind = .amulet,
            .name = "Ghost Amulet",
        } } }},
        history.current_arena.allocator(),
    );
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_inventory_item_name = .{
            .index = 6,
            .value = "Ghost Amulet",
        } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.editor.?.player_def.template.inventory.slots[6] == null);

    // Delete on an empty slot: a no-op (null stays null, no error).
    event_push.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_delete_inventory_item = .{ .index = 6 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);
    try testing.expect(history.current_state.editor.?.player_def.template.inventory.slots[6] == null);
}

test "inventory slot clicks: select/deselect toggle, Add default sword, Delete" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    // Selection is a pure UiState write — no events ever record.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_inventory_slot,
        .clicked_editor_inventory_slot = 4,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(u32, 4), history.session.ui_state.editor_inventory_selected_slot.?);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // A repeat click deselects (the detail block collapses).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_inventory_slot,
        .clicked_editor_inventory_slot = 4,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_inventory_selected_slot == null);

    // A crafted out-of-range index never selects.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_inventory_slot,
        .clicked_editor_inventory_slot = types.inventory_slot_count,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.session.ui_state.editor_inventory_selected_slot == null);

    // Add: the default sword lands in the empty slot; a crafted Add onto
    // an occupied slot never fires.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_inventory_item,
        .clicked_editor_inventory_slot = 7,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    {
        const slot = history.current_state.editor.?.player_def.template.inventory.slots[7];
        try testing.expectEqual(types.WeaponType.sword, slot.?.weapon.weapon_type);
        try testing.expectEqualStrings("New Sword", slot.?.weapon.name);
    }
    const occupied_baseline = history.event_history.items.len;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .add_editor_inventory_item,
        .clicked_editor_inventory_slot = 7,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(occupied_baseline, history.event_history.items.len);

    // Delete clears the slot; a crafted Delete on an empty slot never
    // fires; a crafted out-of-range index never does either.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_inventory_item,
        .clicked_editor_inventory_slot = 7,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    try testing.expect(history.current_state.editor.?.player_def.template.inventory.slots[7] == null);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_inventory_item,
        .clicked_editor_inventory_slot = 7,
    }, .{ .x = 0, .y = 0 }, &.{});
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .delete_editor_inventory_item,
        .clicked_editor_inventory_slot = types.inventory_slot_count,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(
        occupied_baseline + 2,
        history.event_history.items.len,
    );
}

test "inventory item-type clicks: reset-on-change on the selected slot, same-pick and empty-selection no-ops" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const levels = [_]types.EditorLevel{.{}};
    var inventory: types.Inventory = .{};
    inventory.slots[2] = .{ .weapon = .{
        .name = "Iron Sword",
        .weapon_type = .sword,
        .weapon_damage = 5,
    } };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .player_def = .{ .id = "Player", .template = .{ .inventory = inventory } },
    }));
    runToIdle(&history);
    history.session.ui_state.editor_inventory_selected_slot = 2;

    // A DIFFERENT weapon type RESETS everything (the item tool's
    // semantics): "New Axe", damage 0.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_inventory_item_type,
        .clicked_editor_item_kind = .weapon,
        .clicked_editor_weapon_type = .axe,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    {
        const slot = history.current_state.editor.?.player_def.template.inventory.slots[2];
        try testing.expectEqualStrings("New Axe", slot.?.weapon.name);
        try testing.expectEqual(types.WeaponType.axe, slot.?.weapon.weapon_type);
        try testing.expectEqual(@as(u32, 0), slot.?.weapon.weapon_damage);
    }

    // One undo restores the sword whole.
    try testing.expect(history.undo(event_handlers.processEvent));
    {
        const slot = history.current_state.editor.?.player_def.template.inventory.slots[2];
        try testing.expectEqualStrings("Iron Sword", slot.?.weapon.name);
        try testing.expectEqual(@as(u32, 5), slot.?.weapon.weapon_damage);
    }

    // The SAME pick never fires (no dead undo step).
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_inventory_item_type,
        .clicked_editor_item_kind = .weapon,
        .clicked_editor_weapon_type = .sword,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // A KIND switch resets too — "New Amulet", zero stats.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_inventory_item_type,
        .clicked_editor_item_kind = .amulet,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);
    {
        const slot = history.current_state.editor.?.player_def.template.inventory.slots[2];
        try testing.expectEqualStrings("New Amulet", slot.?.amulet.name);
        try testing.expectEqual(@as(u32, 0), slot.?.amulet.spell_damage);
    }

    // No selection, an EMPTY selected slot, and a weapon pick without its
    // weapon-type payload (crafted input) all commit nothing.
    history.session.ui_state.editor_inventory_selected_slot = null;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_inventory_item_type,
        .clicked_editor_item_kind = .coat,
    }, .{ .x = 0, .y = 0 }, &.{});
    history.session.ui_state.editor_inventory_selected_slot = 3;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_inventory_item_type,
        .clicked_editor_item_kind = .coat,
    }, .{ .x = 0, .y = 0 }, &.{});
    history.session.ui_state.editor_inventory_selected_slot = 2;
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .select_editor_inventory_item_type,
        .clicked_editor_item_kind = .weapon,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "inventory item text fields: name + stat commits end-to-end, no-op gates, bounds" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const levels = [_]types.EditorLevel{.{}};
    var inventory: types.Inventory = .{};
    inventory.slots[2] = .{ .weapon = .{
        .name = "Iron Sword",
        .weapon_type = .sword,
        .weapon_damage = 5,
    } };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .player_def = .{ .id = "Player", .template = .{ .inventory = inventory } },
    }));
    runToIdle(&history);

    const no_keys: [0]?[]const u8 = .{};

    // The NAME: a multi-word rename commits through
    // player_set_editor_inventory_item_name.
    {
        const field: types.TextFieldRef = .{
            .id = .inventory_item_name,
            .target = .{ .inventory_slot = 2 },
        };
        ui.beginTextEdit(&history.session.ui_state, field, "");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "Spare Blade", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        runToIdle(&history);
        try testing.expectEqualStrings(
            "Spare Blade",
            history.current_state.editor.?.player_def.template.inventory.slots[2].?.weapon.name,
        );
        // An unchanged buffer commits nothing.
        ui.beginTextEdit(&history.session.ui_state, field, "Spare Blade");
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    }

    // A STAT: bounded — an out-of-range buffer clamps to the parser's own
    // max (single-sourced `itemStatMax`); leading zeros are numeric-equal
    // no-ops.
    {
        const field: types.TextFieldRef = .{
            .id = .{ .inventory_item_stat = .weapon_damage },
            .target = .{ .inventory_slot = 2 },
        };
        ui.beginTextEdit(&history.session.ui_state, field, "5");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "99", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        runToIdle(&history);
        try testing.expectEqual(
            types.max_weapon_damage,
            history.current_state.editor.?.player_def.template.inventory.slots[2].?.weapon.weapon_damage,
        );
        ui.beginTextEdit(&history.session.ui_state, field, "03");
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    }

    // A stat the kind doesn't carry (a sword has no spell damage), a
    // stale slot index, and an empty slot all commit nothing.
    {
        const wrong_stat: types.TextFieldRef = .{
            .id = .{ .inventory_item_stat = .spell_damage },
            .target = .{ .inventory_slot = 2 },
        };
        ui.beginTextEdit(&history.session.ui_state, wrong_stat, "");
        _ = ui.routeTextInput(&history.session.ui_state.text_edit.?, "7", &no_keys, &no_keys, false);
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

        const stale_field: types.TextFieldRef = .{
            .id = .inventory_item_name,
            .target = .{ .inventory_slot = types.inventory_slot_count },
        };
        ui.beginTextEdit(&history.session.ui_state, stale_field, "Ghost");
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

        const empty_field: types.TextFieldRef = .{
            .id = .inventory_item_name,
            .target = .{ .inventory_slot = 3 },
        };
        ui.beginTextEdit(&history.session.ui_state, empty_field, "Ghost");
        input_handlers.resolveTextEditOutcome(&history, .commit);
        try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    }
}

test "player_import_editor_max_player: loads the shipped max loadout, undo reverts, session data untouched" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    // The session's data is POPULATED — the max import ignores it (unlike
    // the Player data import, the source is the file, not the session).
    var player_data: types.PlayerData = .{ .player_name = "Tester" };
    player_data.main_hand_weapon = .{
        .name = "Test Sword",
        .weapon_type = .sword,
        .weapon_damage = 5,
    };
    history.current_state.player_data = player_data;

    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .import_editor_max_player,
    }, .{ .x = 0, .y = 0 }, &.{});
    runToIdle(&history);

    {
        const template = history.current_state.editor.?.player_def.template;
        try testing.expectEqualStrings("New Player", template.name);
        // The maxed gear set: every piece equipped, the authored stats.
        try testing.expectEqualStrings("Max Amulet", template.amulet.?.name);
        try testing.expectEqual(@as(u32, 10), template.amulet.?.spell_damage);
        try testing.expectEqualStrings("Max Boots", template.boots.?.name);
        try testing.expectEqual(@as(u32, 2), template.boots.?.speed_bonus);
        // Weapons + utility bar empty by design (data/max_player.txt).
        try testing.expect(template.main_hand_weapon == null);
        try testing.expect(template.equipped_utility_skills[0] == null);
        // The maxed inventory: slot 0's Max Sword, slot 11's Spare Max Staff.
        try testing.expectEqualStrings(
            "Max Sword",
            template.inventory.slots[0].?.weapon.name,
        );
        try testing.expectEqual(types.WeaponType.staff, template.inventory.slots[11].?.weapon.weapon_type);
        // The session's data is untouched — the file is a READ source.
        try testing.expectEqualStrings("Test Sword", history.current_state.player_data.main_hand_weapon.?.name);
    }

    // The import rides the undo timeline — undo restores the default
    // (empty) loadout.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expect(history.current_state.editor.?.player_def.template.amulet == null);
}

test "the validation stats screen: info populated, personal best captured, manual overwrite writes the stash" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const arena = backing.allocator();
    try writeValidationFixtureMission(&harness);

    const levels = [_]types.EditorLevel{ .{}, .{} };
    var history = harness.newHistory(editorStateWith(.{
        .levels = &levels,
        .player_def = .{ .id = "Player", .template = .{ .name = "Editor Player" } },
    }));
    runToIdle(&history);

    // Run A (the beeline — 0 turns): auto-writes (no prior file).
    try playFixtureRunToCompletion(&history, true);

    // The stats info: populated + validation-flagged, carrying the run's
    // data from the FILE-loaded mission. The clone fields are zeroed.
    {
        const info = history.current_state.last_completed_mission.?;
        try testing.expect(info.validation);
        try testing.expectEqualStrings("Validation Fixture", info.name);
        try testing.expectEqualStrings("33333333-3333-3333-3333-333333333333", info.uuid);
        try testing.expectEqualStrings(validation_fixture_path, info.path);
        try testing.expectEqual(@as(u32, 0), info.turns_spent);
        try testing.expect(!info.overwrite_offered);
    }
    // The personal-best line was captured at the write site (the file's
    // turns — this run's).
    try testing.expectEqual(@as(u32, 0), history.session.validation_personal_best_turns.?);
    // Not offered — no slower run is stashed; a stale overwrite click
    // no-ops.
    try testing.expect(!history.session.validation_replay_overwrite_offered);
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .overwrite_validation_replay,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(u32, 0), (try readFixtureReplay(&harness, arena)).turns);

    // Continue (the overlay's button path): dismiss clears the info on
    // the undo timeline.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .continue_after_mission,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expect(history.current_state.last_completed_mission == null);

    // Run B (2 turns): SLOWER than the 0-turn best → keep + stash + offer.
    try playFixtureRunToCompletion(&history, false);
    try testing.expect(history.session.validation_replay_overwrite_offered);
    // The PB line follows the FILE (still the 0-turn best).
    try testing.expectEqual(@as(u32, 0), history.session.validation_personal_best_turns.?);

    // The manual Overwrite Replay: the STASHED slower run becomes the
    // file, the offer is consumed, and the PB line follows the new file.
    input_handlers.handleAnytimeInput(&history, .{
        .options_action = .overwrite_validation_replay,
    }, .{ .x = 0, .y = 0 }, &.{});
    try testing.expectEqual(@as(u32, 2), (try readFixtureReplay(&harness, arena)).turns);
    try testing.expectEqual(@as(u32, 2), history.session.validation_personal_best_turns.?);
    try testing.expect(history.session.pending_validation_replay == null);
    try testing.expect(!history.session.validation_replay_overwrite_offered);
}
