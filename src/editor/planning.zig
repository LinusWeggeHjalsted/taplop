//! Pure editor click/selection planning: the `planEditor*Actions`
//! planners (one per tool), the selection algebra (value equality,
//! contains, with-entry / without-entry / without-tile), and
//! `activeEditorLevel`. Everything here is a pure function of the Editor
//! state - a planner computes the sub-event list its click would push;
//! the editor event handlers push the plan, and the input layer fires
//! the player action only when the plan is nonempty, so a click that
//! would change nothing never reaches the event log (no undo/replay
//! step). See DESIGN → Level Editor → Active-tool model + Selection
//! model.

const std = @import("std");
const types = @import("../types.zig");
const events = @import("../events.zig");
const functions = @import("../functions.zig");
const loaders = @import("../loaders.zig");

const Event = events.Event;
const Vector2 = types.Vector2;

/// Value equality over `Selectable` (tag + payload). Unions don't support
/// `==` in Zig, so the comparison is spelled out.
fn selectableEqual(a: types.Selectable, b: types.Selectable) bool {
    return switch (a) {
        .tile => |position| b == .tile and
            b.tile.x == position.x and b.tile.y == position.y,
        .entity_placement => |index| b == .entity_placement and b.entity_placement == index,
        .decoration_placement => |index| b == .decoration_placement and b.decoration_placement == index,
        .ground_item_placement => |index| b == .ground_item_placement and b.ground_item_placement == index,
        .player_start => b == .player_start,
        .level_end => b == .level_end,
    };
}

pub fn selectionContains(items: []const types.Selectable, entry: types.Selectable) bool {
    for (items) |existing| {
        if (selectableEqual(existing, entry)) return true;
    }
    return false;
}

/// The selection with `entry` appended (a fresh slice - `Editor.selection`
/// is replaced wholesale, never mutated in place, so deepCopy snapshots
/// stay sound).
pub fn selectionWithEntry(
    selection: []const types.Selectable,
    entry: types.Selectable,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    const grown = allocator.alloc(types.Selectable, selection.len + 1) catch
        @panic("failed to allocate editor selection");
    @memcpy(grown[0..selection.len], selection);
    grown[selection.len] = entry;
    return grown;
}

/// The selection without its first entry equal to `entry` (the original
/// slice when absent - a deselect of a non-selected entry is an
/// idempotent no-op).
pub fn selectionWithoutEntry(
    selection: []const types.Selectable,
    entry: types.Selectable,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    for (selection, 0..) |existing, index| {
        if (selectableEqual(existing, entry)) {
            const shrunk = allocator.alloc(types.Selectable, selection.len - 1) catch
                @panic("failed to allocate editor selection");
            @memcpy(shrunk[0..index], selection[0..index]);
            @memcpy(shrunk[index..], selection[index + 1 ..]);
            return shrunk;
        }
    }
    return selection;
}

/// The selection without its tile entry at `position` (a tile entry is
/// position-keyed, not index-keyed - nothing to remap; other kinds pass
/// through). Returns the original slice when no such entry exists.
pub fn selectionWithoutTile(
    selection: []const types.Selectable,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    var has_tile = false;
    for (selection) |selected| switch (selected) {
        .tile => |tile_position| {
            if (tile_position.x == position.x and tile_position.y == position.y) has_tile = true;
        },
        else => {},
    };
    if (!has_tile) return selection;

    const rebuilt = allocator.alloc(types.Selectable, selection.len) catch
        @panic("failed to allocate editor selection");
    var length: usize = 0;
    for (selection) |selected| switch (selected) {
        .tile => |tile_position| {
            if (tile_position.x == position.x and tile_position.y == position.y) continue;
            rebuilt[length] = selected;
            length += 1;
        },
        else => {
            rebuilt[length] = selected;
            length += 1;
        },
    };
    return rebuilt[0..length];
}

/// The active level, or null when the editor has no levels or the active
/// index is out of range - the click planners no-op on null (defensive:
/// live input can't produce it, crafted session logs can).
pub fn activeEditorLevel(editor: *const types.Editor) ?*const types.EditorLevel {
    if (editor.levels.len == 0) return null;
    if (editor.active_level_index >= editor.levels.len) return null;
    return &editor.levels[editor.active_level_index];
}

/// Pure planners for the editor click orchestrators (tile paint, the three
/// placement tools, the right-click delete). Each computes the sub-event list
/// its click would push from the live editor state: the handler pushes the
/// plan, and the input layer fires the player action only when the plan is
/// nonempty - a click that would change nothing never reaches the event log,
/// so it can't create an undo or replay step (see DESIGN → Level Editor →
/// Active-tool model). One planner per tool is the single source of truth for
/// both sides (no duplicated no-op conditions to drift); the handlers keep
/// the empty-plan return as the defensive path for crafted or pre-change
/// session logs. Directly unit-testable (the AGENTS → Testing discipline
/// bool-helper convention).
///
/// Tile-paint click (tile tool active): one click = one tile. The effect is
/// computed from state - no-op (empty plan) when a tile is already there
/// (entities / items / the '!' / '=' sit ON tiles, so they never block a
/// paint); every decoration whose footprint covers the position is deleted
/// first (replace, not block - see DESIGN → Decorations & Footprint →
/// Placement invariant). The array is ordered for LIFO draining (set_tile
/// first, deletes in ascending placement order → the deletes process in
/// DESCENDING order - required for index-stable removal, since deleting a
/// lower index first would shift the pending higher ones - and the tile
/// lands last). All sub-events land between two idle points, so one undo
/// reverts the whole click.
pub fn planEditorTilePaintActions(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    for (level.level_tiles) |tile| {
        if (tile.x == position.x and tile.y == position.y) return &.{};
    }
    var pushes: std.ArrayList(Event) = .empty;
    pushes.append(allocator, .{ .editor_event = .{ .editor_set_tile = .{
        .level_index = @intCast(editor.active_level_index),
        .position = position,
        .is_floor = true,
    } } }) catch @panic("failed to allocate editor paint plan");
    for (level.decoration_placements, 0..) |placement, placement_index| {
        const type_definition = editor.decoration_types[placement.type_id];
        if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
            pushes.append(allocator, .{ .editor_event = .{ .editor_delete_decoration_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } } }) catch @panic("failed to allocate editor paint plan");
        }
    }
    return pushes.items;
}

/// Enemy-tool click: place the palette entity type at the clicked tile,
/// replacing whatever occupies it. Occupant semantics (see DESIGN → Level
/// Editor → Active-tool model, placement tools): player start / level end →
/// no-op (never overwritten); covering decorations → deleted; missing tile
/// → placed; co-located ground item → deleted; existing enemy → RETYPED in
/// place (`editor_set_entity_placement_type`, not delete + re-place - stable
/// identity); same type already there → nothing to do (the plan is empty
/// only when the tile is also present and nothing needs clearing). The
/// array is ordered for LIFO draining (the REVERSE of processing order; the
/// per-kind delete lists ascend so they process descending - index-stable
/// removal). All sub-events share one idle point - one undo reverts the
/// whole click. The one-thing-per-tile invariant is enforced at
/// `editor_place_entity` (panic on an occupied tile) - the deletes above run
/// first, so the place lands on a cleared tile.
pub fn planEditorEntityPlacementActions(
    editor: *const types.Editor,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    if (type_id >= editor.entity_types.len) return &.{};
    const level = activeEditorLevel(editor) orelse return &.{};

    // The '!' and '=' are singletons, movable never deletable - an enemy
    // never overwrites them.
    if (level.player_start.x == position.x and level.player_start.y == position.y) return &.{};
    if (level.level_end) |level_end_position| {
        if (level_end_position.x == position.x and level_end_position.y == position.y) return &.{};
    }

    // Is a tile already there (the enemy stands ON a tile - a missing one
    // is placed as part of the click)?
    var tile_present = false;
    for (level.level_tiles) |tile| {
        if (tile.x == position.x and tile.y == position.y) {
            tile_present = true;
            break;
        }
    }

    // Co-located entity placement, if any (invariant: at most one - the
    // loop degrades gracefully if that's ever violated).
    var occupant_index: ?usize = null;
    for (level.entity_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            occupant_index = placement_index;
            break;
        }
    }

    var pushes: std.ArrayList(Event) = .empty;
    if (occupant_index == null) {
        pushes.append(allocator, .{ .editor_event = .{ .editor_place_entity = .{
            .level_index = @intCast(editor.active_level_index),
            .type_id = type_id,
            .position = position,
        } } }) catch @panic("failed to allocate editor place plan");
    } else if (level.entity_placements[occupant_index.?].type_id != type_id) {
        // Same type already there - no branch taken (nothing to do).
        pushes.append(allocator, .{ .editor_event = .{ .editor_set_entity_placement_type = .{
            .level_index = @intCast(editor.active_level_index),
            .placement_index = @intCast(occupant_index.?),
            .type_id = type_id,
        } } }) catch @panic("failed to allocate editor place plan");
    }
    if (!tile_present) {
        pushes.append(allocator, .{ .editor_event = .{ .editor_set_tile = .{
            .level_index = @intCast(editor.active_level_index),
            .position = position,
            .is_floor = true,
        } } }) catch @panic("failed to allocate editor place plan");
    }
    for (level.item_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            pushes.append(allocator, .{ .editor_event = .{ .editor_delete_item_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } } }) catch @panic("failed to allocate editor place plan");
        }
    }
    for (level.decoration_placements, 0..) |placement, placement_index| {
        const type_definition = editor.decoration_types[placement.type_id];
        if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
            pushes.append(allocator, .{ .editor_event = .{ .editor_delete_decoration_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } } }) catch @panic("failed to allocate editor place plan");
        }
    }
    return pushes.items;
}

/// Decoration-tool click: place the palette decoration with its ANCHOR tile
/// (bottom-most-then-left-most footprint tile) at the clicked position,
/// replacing whatever occupies the footprint's world tiles. The INVERSE of
/// the tile/enemy placements - a decoration's footprint tiles are TILE-FREE,
/// so covered tiles are ERASED rather than placed: the '!' / '=' under ANY
/// footprint tile → no-op (never overwritten); an EXACT DUPLICATE (same type
/// at the same anchor → identical footprint) already satisfies the
/// placement - the plan skips the place and the duplicate's own delete, so
/// no duplicate ever stacks (other overlapping decorations still get
/// deleted); tiles under footprint tiles → erased, along with the entities /
/// ground items standing on them; other decorations whose footprints overlap
/// ANY footprint tile → deleted; then the placement lands
/// (`editor_place_decoration` enforces footprint-tile exclusivity). The
/// array is ordered for LIFO draining (the REVERSE of processing order; each
/// delete list ascends so it processes descending - index-stable). All
/// sub-events share one idle point - one undo reverts the whole click.
pub fn planEditorDecorationPlacementActions(
    editor: *const types.Editor,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    if (type_id >= editor.decoration_types.len) return &.{};
    const type_definition = editor.decoration_types[type_id];
    const footprint_tiles = loaders.decorationFootprintWorldTiles(
        type_definition.footprint,
        position,
        allocator,
    );
    if (footprint_tiles.len == 0) return &.{};
    const level = activeEditorLevel(editor) orelse return &.{};

    // The '!' / '=' under any footprint tile → never overwritten.
    for (footprint_tiles) |tile| {
        if (tile.x == level.player_start.x and tile.y == level.player_start.y) return &.{};
        if (level.level_end) |level_end_position| {
            if (tile.x == level_end_position.x and tile.y == level_end_position.y) return &.{};
        }
    }

    // An exact duplicate (same type at the same anchor) already satisfies
    // the placement - skip the place and the duplicate's own delete; the
    // other arms below still fire (overlap cleanup, tile erasure).
    var duplicate_present = false;
    for (level.decoration_placements) |placement| {
        if (placement.type_id == type_id and
            placement.position.x == position.x and
            placement.position.y == position.y)
        {
            duplicate_present = true;
            break;
        }
    }

    var pushes: std.ArrayList(Event) = .empty;
    if (!duplicate_present) {
        pushes.append(allocator, .{ .editor_event = .{ .editor_place_decoration = .{
            .level_index = @intCast(editor.active_level_index),
            .type_id = type_id,
            .position = position,
        } } }) catch @panic("failed to allocate editor place plan");
    }
    // Erase every covered tile that has one.
    for (footprint_tiles) |tile| {
        if (functions.tileListContains(level.level_tiles, tile)) {
            pushes.append(allocator, .{ .editor_event = .{ .editor_set_tile = .{
                .level_index = @intCast(editor.active_level_index),
                .position = tile,
                .is_floor = false,
            } } }) catch @panic("failed to allocate editor place plan");
        }
    }
    // Entities + items standing on covered tiles (they sit ON tiles, so
    // this fires for covered tiles that had one - looping all footprint
    // tiles is robust either way).
    for (level.entity_placements, 0..) |placement, placement_index| {
        if (functions.tileListContains(footprint_tiles, placement.position)) {
            pushes.append(allocator, .{ .editor_event = .{ .editor_delete_entity_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } } }) catch @panic("failed to allocate editor place plan");
        }
    }
    for (level.item_placements, 0..) |placement, placement_index| {
        if (functions.tileListContains(footprint_tiles, placement.position)) {
            pushes.append(allocator, .{ .editor_event = .{ .editor_delete_item_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } } }) catch @panic("failed to allocate editor place plan");
        }
    }
    // Overlapping other decorations: an existing footprint covering any of
    // the new footprint's world tiles (set intersection - checking this
    // direction is complete). The exact duplicate is skipped (it IS the
    // placement being satisfied).
    for (level.decoration_placements, 0..) |placement, placement_index| {
        if (duplicate_present and
            placement.type_id == type_id and
            placement.position.x == position.x and
            placement.position.y == position.y) continue;
        const other_definition = editor.decoration_types[placement.type_id];
        var overlaps = false;
        for (footprint_tiles) |tile| {
            if (loaders.decorationFootprintCovers(other_definition.footprint, placement.position, tile, allocator)) {
                overlaps = true;
                break;
            }
        }
        if (overlaps) {
            pushes.append(allocator, .{ .editor_event = .{ .editor_delete_decoration_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } } }) catch @panic("failed to allocate editor place plan");
        }
    }
    return pushes.items;
}

/// Ground-item-tool click: place the palette item type at the clicked tile
/// - the same occupant replacement as the entity tool, with the roles swapped
/// for the two placement kinds: an existing ground item is RETYPED in place
/// (`editor_set_item_placement_type`) and an enemy on the tile is DELETED
/// (the item can't coexist with it). The '!' / '=' → no-op; covering
/// decorations → deleted; a missing tile → placed (the item sits ON a
/// tile). The array is ordered for LIFO draining (the REVERSE of processing
/// order; each delete list ascends so it processes descending - index-
/// stable). All sub-events share one idle point - one undo reverts the
/// whole click.
pub fn planEditorItemPlacementActions(
    editor: *const types.Editor,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    if (type_id >= editor.item_types.len) return &.{};
    const level = activeEditorLevel(editor) orelse return &.{};

    // The '!' and '=' are singletons, movable never deletable - a ground
    // item never overwrites them.
    if (level.player_start.x == position.x and level.player_start.y == position.y) return &.{};
    if (level.level_end) |level_end_position| {
        if (level_end_position.x == position.x and level_end_position.y == position.y) return &.{};
    }

    var tile_present = false;
    for (level.level_tiles) |tile| {
        if (tile.x == position.x and tile.y == position.y) {
            tile_present = true;
            break;
        }
    }

    // Co-located item placement, if any (invariant: at most one - the loop
    // degrades gracefully if that's ever violated).
    var occupant_index: ?usize = null;
    for (level.item_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            occupant_index = placement_index;
            break;
        }
    }

    var pushes: std.ArrayList(Event) = .empty;
    if (occupant_index == null) {
        pushes.append(allocator, .{ .editor_event = .{ .editor_place_item = .{
            .level_index = @intCast(editor.active_level_index),
            .type_id = type_id,
            .position = position,
        } } }) catch @panic("failed to allocate editor place plan");
    } else if (level.item_placements[occupant_index.?].type_id != type_id) {
        // Same type already there - no branch taken (nothing to do).
        pushes.append(allocator, .{ .editor_event = .{ .editor_set_item_placement_type = .{
            .level_index = @intCast(editor.active_level_index),
            .placement_index = @intCast(occupant_index.?),
            .type_id = type_id,
        } } }) catch @panic("failed to allocate editor place plan");
    }
    if (!tile_present) {
        pushes.append(allocator, .{ .editor_event = .{ .editor_set_tile = .{
            .level_index = @intCast(editor.active_level_index),
            .position = position,
            .is_floor = true,
        } } }) catch @panic("failed to allocate editor place plan");
    }
    // An enemy on the tile is deleted (an item can't coexist with it - one
    // thing per placed tile).
    for (level.entity_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            pushes.append(allocator, .{ .editor_event = .{ .editor_delete_entity_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } } }) catch @panic("failed to allocate editor place plan");
        }
    }
    for (level.decoration_placements, 0..) |placement, placement_index| {
        const type_definition = editor.decoration_types[placement.type_id];
        if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
            pushes.append(allocator, .{ .editor_event = .{ .editor_delete_decoration_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } } }) catch @panic("failed to allocate editor place plan");
        }
    }
    return pushes.items;
}

/// One-event plan for the delete cascade's early-return arms.
fn singleEditorDeletePlan(
    editor_event: events.EditorEvent,
    allocator: std.mem.Allocator,
) []const Event {
    return allocator.dupe(Event, &.{.{ .editor_event = editor_event }}) catch
        @panic("failed to allocate editor delete plan");
}

/// Editor right-click: the tool-independent delete - ONE thing per click,
/// priority: enemy / ground-item occupant (at most one by the one-thing-per-
/// tile invariant; an entity wins if both are somehow present), then
/// covering decoration(s) (all of them - consistent with every other editor
/// flow; overlapping footprints are a degenerate hand-authored case), then
/// the bare tile. The '!' / '=' are never deleted (checked first - they sit
/// ON tiles, so the bare-tile erase must not fire under them), and empty
/// ground is a no-op (empty plan). One delete = one undo step by
/// construction.
pub fn planEditorDeleteActions(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};

    // The '!' / '=' are singletons, movable never deletable - and their
    // tiles survive too.
    if (level.player_start.x == position.x and level.player_start.y == position.y) return &.{};
    if (level.level_end) |level_end_position| {
        if (level_end_position.x == position.x and level_end_position.y == position.y) return &.{};
    }

    // Occupant first (progressive delete: the item/enemy goes, the tile
    // survives for the next click).
    for (level.entity_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            return singleEditorDeletePlan(.{ .editor_delete_entity_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } }, allocator);
        }
    }
    for (level.item_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            return singleEditorDeletePlan(.{ .editor_delete_item_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } }, allocator);
        }
    }
    // Covering decoration(s): ascending array → descending processing
    // (index-stable).
    var covering: std.ArrayList(Event) = .empty;
    for (level.decoration_placements, 0..) |placement, placement_index| {
        const type_definition = editor.decoration_types[placement.type_id];
        if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
            covering.append(allocator, .{ .editor_event = .{ .editor_delete_decoration_placement = .{
                .level_index = @intCast(editor.active_level_index),
                .placement_index = @intCast(placement_index),
            } } }) catch @panic("failed to allocate editor delete plan");
        }
    }
    if (covering.items.len > 0) return covering.items;
    // Bare tile.
    if (functions.tileListContains(level.level_tiles, position)) {
        return singleEditorDeletePlan(.{ .editor_set_tile = .{
            .level_index = @intCast(editor.active_level_index),
            .position = position,
            .is_floor = false,
        } }, allocator);
    }
    // Nothing there - no-op.
    return &.{};
}

/// Select-tool click planner: toggle the clicked thing's GROUP in the
/// selection. A click's group is everything that toggles together: the
/// '!' / '=' singletons; a covering decoration (the FIRST - exactly what
/// the hover preview outlines); or the tile INCLUDING anything standing
/// on it (entity / ground-item placements). Anything from the group
/// already selected → the plan deselects every PRESENT entry (clicking a
/// selected tile deselects the tile AND its occupant); nothing selected →
/// the plan selects the whole group. Empty ground selects nothing (empty
/// plan - no player action fires). One event per entry (granular by
/// design - see DESIGN → Architecture → Level Editor → Selection model);
/// they share the click's idle point, so one undo step reverts the whole
/// click.
/// The select tool's click GROUP at `position`: everything that acts as
/// one unit - the '!' / '=' singletons; a covering decoration (the FIRST -
/// exactly what the hover preview outlines); or the tile INCLUDING
/// anything standing on it (entity / ground-item placements). Empty ground
/// → an empty group. Shared by the toggle (shift+click) and replace (plain
/// click) planners; the group order is tile, entity, item. Also the
/// would-be POST-REPLACE selection the move-drag gate evaluates an
/// unselected-claim drag against (see `editorSelectionMoveVetoed`) - pub
/// for that import.
pub fn editorClickGroup(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    const level = activeEditorLevel(editor) orelse return &.{};

    var group: [3]types.Selectable = undefined;
    var group_length: usize = 0;

    if (level.player_start.x == position.x and level.player_start.y == position.y) {
        group[0] = .player_start;
        group_length = 1;
    } else if (level.level_end) |level_end_position| {
        if (level_end_position.x == position.x and level_end_position.y == position.y) {
            group[0] = .level_end;
            group_length = 1;
        }
    }
    if (group_length == 0) {
        // A covering decoration (the first - matching the hover preview).
        for (level.decoration_placements, 0..) |placement, placement_index| {
            const type_definition = editor.decoration_types[placement.type_id];
            if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
                group[0] = .{ .decoration_placement = @intCast(placement_index) };
                group_length = 1;
                break;
            }
        }
    }
    if (group_length == 0) {
        // The tile including anything standing on it. Empty ground (no
        // tile, no occupants) selects nothing.
        for (level.level_tiles) |tile| {
            if (tile.x == position.x and tile.y == position.y) {
                group[group_length] = .{ .tile = position };
                group_length += 1;
                break;
            }
        }
        for (level.entity_placements, 0..) |placement, placement_index| {
            if (placement.position.x == position.x and placement.position.y == position.y) {
                group[group_length] = .{ .entity_placement = @intCast(placement_index) };
                group_length += 1;
            }
        }
        for (level.item_placements, 0..) |placement, placement_index| {
            if (placement.position.x == position.x and placement.position.y == position.y) {
                group[group_length] = .{ .ground_item_placement = @intCast(placement_index) };
                group_length += 1;
            }
        }
    }

    const entries = allocator.alloc(types.Selectable, group_length) catch
        @panic("failed to allocate editor click group");
    @memcpy(entries, group[0..group_length]);
    return entries;
}

/// Would a select-tool click at `position` grab anything - i.e. is the
/// click group there nonempty (a tile, an entity / item placement, a
/// covering decoration, or a '!' / '=' singleton; empty ground is not)?
/// Thin wrapper over the group resolution so the claim condition and the
/// click semantics share one source of truth. Used by the move-drag
/// gesture (`handleEditorMoveDrag`) - pub for that import only.
pub fn editorClickGroupNonempty(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) bool {
    return editorClickGroup(editor, position, allocator).len > 0;
}

pub fn planEditorSelectionActions(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const group = editorClickGroup(editor, position, allocator);
    if (group.len == 0) return &.{};

    // Toggle direction: anything present → deselect every present entry;
    // nothing present → select the whole group.
    var any_present = false;
    for (group) |entry| {
        if (selectionContains(editor.selection, entry)) {
            any_present = true;
            break;
        }
    }
    // The event stack is LIFO - push the group REVERSED so the entries
    // process (and land in the recorded log) in group order: tile, then
    // entity, then item.
    var plan: std.ArrayList(Event) = .empty;
    var group_index = group.len;
    while (group_index > 0) {
        group_index -= 1;
        const entry = group[group_index];
        const variant = if (any_present)
            Event{ .editor_event = .{ .editor_deselect = .{ .entry = entry } } }
        else
            Event{ .editor_event = .{ .editor_select = .{ .entry = entry } } };
        plan.append(allocator, variant) catch @panic("failed to allocate editor selection plan");
    }
    return plan.items;
}

/// Plain-click (no Shift) planner: REPLACE the selection with the clicked
/// group - the whole selection is cleared, then the group is selected.
/// Empty ground → the clear alone (the clicky deselect-all). A click that
/// would change nothing (the selection IS exactly the group, or empty
/// ground with an already-empty selection) plans empty - no player action
/// fires. Built forward in processing order (clear first, then the
/// group's selects in group order) and reversed for the LIFO push, so the
/// clear processes first and the final selection reads in group order.
pub fn planEditorReplaceSelectionActions(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const group = editorClickGroup(editor, position, allocator);

    // The selection is already exactly the group (also covers empty
    // ground + empty selection) → nothing to do.
    if (group.len == editor.selection.len) {
        var all_present = true;
        for (group) |entry| {
            if (!selectionContains(editor.selection, entry)) {
                all_present = false;
                break;
            }
        }
        if (all_present) return &.{};
    }

    var plan: std.ArrayList(Event) = .empty;
    if (editor.selection.len > 0) {
        plan.append(allocator, .{ .editor_event = .editor_clear_selection }) catch
            @panic("failed to allocate editor selection plan");
    }
    for (group) |entry| {
        plan.append(allocator, .{ .editor_event = .{ .editor_select = .{ .entry = entry } } }) catch
            @panic("failed to allocate editor selection plan");
    }
    std.mem.reverse(Event, plan.items);
    return plan.items;
}

/// Select-tool marquee planner: ADD every selectable thing inside the
/// inclusive rectangle spanned by the two corner tiles (order-
/// independent), skipping entries already in the selection (an add,
/// never a remove - the plain click toggles). Region membership: level
/// tiles / entity / item placements by position; a decoration when ANY
/// of its footprint tiles is inside (matching the click hit-testing - if
/// you can click it, you can marquee it); the '!' / '=' singletons by
/// their tile. Deterministic order - tiles, entities, items, decorations,
/// singletons, each in stored order - and the list is REVERSED before
/// returning (the event stack is LIFO) so the entries process + land in
/// the log in plan order. An empty plan (nothing in the region, or
/// everything already selected) means no player action fires.
/// Select-tool Delete-key planner: fan the selection out into the per-entry
/// delete events (the same machinery the right-click delete composes). The
/// '!' / '=' entries are NEVER deletable (skipped) and the tiles under them
/// survive too (a marker needs its ground). A selected tile takes its
/// OCCUPANT with it - an entity/item placement standing on it is deleted
/// even when unselected (unreachable via today's UI - clicks and marquees
/// always grab tile + occupants together - but craftable in a log and
/// reachable once deselect features land; an occupant can't stand on
/// nothing).
///
/// Index stability: the delete set is computed from the ORIGINAL state
/// (selected placements + swept occupants, deduped per kind), and the
/// processing order - the reversed LIFO push - runs each placement kind
/// HIGH-BEFORE-LOW, so a removal never shifts an index a later event still
/// addresses (same reasoning as the covering-decoration deletes in
/// `planEditorDeleteActions`). Tile erases are position-keyed (safe any
/// time) and process last. The selection reconcile runs inside each delete
/// arm, keeping the selection consistent mid-batch; stale entries (out-of-
/// range indices, absent tiles) are skipped defensively. Everything shares
/// the player action's idle point - one undo step reverts the whole
/// deletion.
/// Which selection-deletion policy a plan runs - see
/// `planEditorSelectionDeleteActions` / `planEditorSelectionMoveDeleteActions`.
const SelectionDeleteMode = enum {
    /// The Delete key: a selected tile's OCCUPANT is swept with it (an
    /// occupant can't stand on nothing).
    delete_key,
    /// A selection move's clear phase: an UNSELECTED occupant PINS its
    /// tile - the tile stays underneath it and the moved tile lands at
    /// the target instead (only selected things are backed up + moved;
    /// a selected occupant is deleted via its own entry, so the erase
    /// proceeds normally under it).
    selection_move,
};

pub fn planEditorSelectionDeleteActions(
    editor: *const types.Editor,
    allocator: std.mem.Allocator,
) []const Event {
    return planSelectionDelete(editor, allocator, .delete_key);
}

/// The selection move's clear phase (see `player_move_editor_selection`):
/// same shape as the Delete key's plan, but a selected tile with an
/// UNSELECTED occupant is not erased at all (the occupant pins its
/// ground) and no occupants are swept.
/// Does the select tool's selection cover `position` - i.e. would a plain
/// press there start a MOVE drag? Mirrors the click group resolution: a
/// selected tile / entity / item at the position, a selected decoration
/// whose footprint covers it, or a selected '!' / '=' at it. Used by the
/// move-drag gesture (`handleEditorMoveDrag`).
pub fn editorSelectionContainsPosition(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) bool {
    const level = activeEditorLevel(editor) orelse return false;
    for (editor.selection) |selected| {
        switch (selected) {
            .tile => |tile_position| {
                if (tile_position.x == position.x and tile_position.y == position.y) return true;
            },
            .entity_placement => |index| {
                if (index < level.entity_placements.len) {
                    const placement = level.entity_placements[index];
                    if (placement.position.x == position.x and placement.position.y == position.y) return true;
                }
            },
            .ground_item_placement => |index| {
                if (index < level.item_placements.len) {
                    const placement = level.item_placements[index];
                    if (placement.position.x == position.x and placement.position.y == position.y) return true;
                }
            },
            .decoration_placement => |index| {
                if (index < level.decoration_placements.len) {
                    const placement = level.decoration_placements[index];
                    if (loaders.decorationFootprintCovers(
                        editor.decoration_types[placement.type_id].footprint,
                        placement.position,
                        position,
                        allocator,
                    )) return true;
                }
            },
            .player_start => {
                if (level.player_start.x == position.x and level.player_start.y == position.y) return true;
            },
            .level_end => {
                if (level.level_end) |level_end_position| {
                    if (level_end_position.x == position.x and level_end_position.y == position.y) return true;
                }
            },
        }
    }
    return false;
}

fn translatedPosition(position: Vector2, delta: Vector2) Vector2 {
    return .{ .x = position.x + delta.x, .y = position.y + delta.y };
}

/// Would a selection move by `delta` land a marker on the other marker?
/// '!' and '=' take one cell each in the layout format, so a
/// `player_start == level_end` level has no file representation - the
/// move is vetoed whole. The veto is on the FINAL positions (translated
/// when selected, current when not): moving both markers together
/// preserves their offset (never vetoed - and a pre-existing overlap can
/// only ever be resolved by moving one marker alone, never created),
/// while moving one onto the stationary other vetoes. `selection` is the
/// selection the move will actually plan against - the current one, or
/// the click group an unselected-claim drag's replace will have installed
/// by the time the move runs (the move-drag gate's two call sites).
pub fn editorSelectionMoveVetoed(
    editor: *const types.Editor,
    selection: []const types.Selectable,
    delta: Vector2,
) bool {
    const level = activeEditorLevel(editor) orelse return false;
    const level_end_position = level.level_end orelse return false;
    const final_player_start = if (selectionContains(selection, .player_start))
        translatedPosition(level.player_start, delta)
    else
        level.player_start;
    const final_level_end = if (selectionContains(selection, .level_end))
        translatedPosition(level_end_position, delta)
    else
        level_end_position;
    return final_player_start.x == final_level_end.x and
        final_player_start.y == final_level_end.y;
}

/// The selection-move plan - the move orchestrator's whole push list: the
/// translated selection as the commit-chain worklist
/// (`editor_commit_selection_move`), then the clear phase
/// (`planEditorSelectionMoveDeleteActions`). Shared by the
/// `player_move_editor_selection` handler (the entries build lives here,
/// not inline in the handler - the other tools' shape) and the input-side
/// no-op gate (via `editorSelectionMoveVetoed`). EMPTY when the move is
/// vetoed - the drag never fires (no dead undo step), not a partial move
/// (the flag silently staying behind while the rest moves would be easy
/// to miss).
pub fn planEditorSelectionMoveActions(
    editor: *const types.Editor,
    delta: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};

    if (editorSelectionMoveVetoed(editor, editor.selection, delta)) return &.{};

    var entries: std.ArrayList(types.EditorSelectionMoveEntry) = .empty;
    for (editor.selection) |selected| {
        switch (selected) {
            .entity_placement => |index| {
                if (index < level.entity_placements.len) {
                    const placement = level.entity_placements[index];
                    entries.append(allocator, .{ .entity = .{
                        .type_id = placement.type_id,
                        .position = translatedPosition(placement.position, delta),
                    } }) catch @panic("failed to allocate editor selection move entries");
                }
            },
            .decoration_placement => |index| {
                if (index < level.decoration_placements.len) {
                    const placement = level.decoration_placements[index];
                    entries.append(allocator, .{ .decoration = .{
                        .type_id = placement.type_id,
                        .position = translatedPosition(placement.position, delta),
                    } }) catch @panic("failed to allocate editor selection move entries");
                }
            },
            .ground_item_placement => |index| {
                if (index < level.item_placements.len) {
                    const placement = level.item_placements[index];
                    entries.append(allocator, .{ .item = .{
                        .type_id = placement.type_id,
                        .position = translatedPosition(placement.position, delta),
                    } }) catch @panic("failed to allocate editor selection move entries");
                }
            },
            .tile => |position| {
                entries.append(allocator, .{ .tile = translatedPosition(position, delta) }) catch
                    @panic("failed to allocate editor selection move entries");
            },
            .player_start => {
                entries.append(allocator, .{ .player_start = translatedPosition(level.player_start, delta) }) catch
                    @panic("failed to allocate editor selection move entries");
            },
            .level_end => {
                if (level.level_end) |level_end_position| {
                    entries.append(allocator, .{ .level_end = translatedPosition(level_end_position, delta) }) catch
                        @panic("failed to allocate editor selection move entries");
                }
            },
        }
    }

    var plan: std.ArrayList(Event) = .empty;
    plan.append(allocator, .{ .editor_event = .{ .editor_commit_selection_move = .{
        .entries = entries.items,
        .next_index = 0,
    } } }) catch @panic("failed to allocate editor selection move plan");
    plan.appendSlice(allocator, planEditorSelectionMoveDeleteActions(editor, allocator)) catch
        @panic("failed to allocate editor selection move plan");
    return plan.items;
}

fn planEditorSelectionMoveDeleteActions(
    editor: *const types.Editor,
    allocator: std.mem.Allocator,
) []const Event {
    return planSelectionDelete(editor, allocator, .selection_move);
}

fn planSelectionDelete(
    editor: *const types.Editor,
    allocator: std.mem.Allocator,
    mode: SelectionDeleteMode,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    const level_index: u32 = @intCast(editor.active_level_index);

    // The delete set per placement kind (selected entries + swept
    // occupants, deduped) + the erasable tile positions.
    var entity_indices: std.ArrayList(u32) = .empty;
    var item_indices: std.ArrayList(u32) = .empty;
    var decoration_indices: std.ArrayList(u32) = .empty;
    var tile_positions: std.ArrayList(Vector2) = .empty;

    for (editor.selection) |selected| {
        switch (selected) {
            .entity_placement => |index| appendIndexIfNew(&entity_indices, index, allocator),
            .ground_item_placement => |index| appendIndexIfNew(&item_indices, index, allocator),
            .decoration_placement => |index| appendIndexIfNew(&decoration_indices, index, allocator),
            .player_start, .level_end => {
                // The Delete key never touches markers - and their tiles
                // stay (the marker isn't going anywhere; see the tile arm's
                // protection below). A MOVE takes the selected marker's
                // ground with it: nothing hosts the marker at the old
                // position anymore, so the tile is erased like any other
                // selected tile (the place phase ensures a tile under the
                // new position).
                if (mode == .delete_key) continue;
                const marker_position: Vector2 = if (selected == .player_start)
                    level.player_start
                else
                    (level.level_end orelse continue);
                if (!functions.tileListContains(level.level_tiles, marker_position)) continue;
                // The OTHER marker still standing on the same tile keeps
                // its ground (both markers selected → both moving →
                // neither remains; the marker's own tile arm protection
                // already skipped this erase, so no duplicate).
                if (selected == .player_start) {
                    if (level.level_end) |level_end_position| {
                        if (level_end_position.x == marker_position.x and level_end_position.y == marker_position.y and
                            !selectionContains(editor.selection, .level_end)) continue;
                    }
                } else {
                    if (level.player_start.x == marker_position.x and level.player_start.y == marker_position.y and
                        !selectionContains(editor.selection, .player_start)) continue;
                }
                // An unselected occupant pins its ground (defensive - the
                // placement rules never put anything on a marker tile).
                if (selectionMoveOccupantPinsTile(level, editor.selection, marker_position)) continue;
                tile_positions.append(allocator, marker_position) catch
                    @panic("failed to allocate editor selection delete plan");
            },
            .tile => |position| {
                // Marker tiles survive (the '!' / '=' need their ground),
                // and so do stale entries (the tile is already gone).
                if (position.x == level.player_start.x and position.y == level.player_start.y) continue;
                if (level.level_end) |level_end_position| {
                    if (position.x == level_end_position.x and position.y == level_end_position.y) continue;
                }
                if (!functions.tileListContains(level.level_tiles, position)) continue;
                // A move keeps the ground under an UNSELECTED occupant
                // (the occupant stays, the moved tile lands at its target
                // instead - nothing is swept).
                if (mode == .selection_move and selectionMoveOccupantPinsTile(level, editor.selection, position)) continue;
                tile_positions.append(allocator, position) catch
                    @panic("failed to allocate editor selection delete plan");
                // Delete-key mode sweeps the occupant (at most one - one
                // thing per placed tile; deduped against the selected
                // entries).
                if (mode == .delete_key) {
                    for (level.entity_placements, 0..) |placement, placement_index| {
                        if (placement.position.x == position.x and placement.position.y == position.y) {
                            appendIndexIfNew(&entity_indices, @intCast(placement_index), allocator);
                            break;
                        }
                    }
                    for (level.item_placements, 0..) |placement, placement_index| {
                        if (placement.position.x == position.x and placement.position.y == position.y) {
                            appendIndexIfNew(&item_indices, @intCast(placement_index), allocator);
                            break;
                        }
                    }
                }
            },
        }
    }

    // Processing order: entity deletes, item deletes, decoration deletes
    // (each descending), then the tile erases. The whole list is reversed
    // for the LIFO push below.
    var plan: std.ArrayList(Event) = .empty;
    appendPlacementDeletesDescending(&plan, level, level_index, &entity_indices, .entity_placement, allocator);
    appendPlacementDeletesDescending(&plan, level, level_index, &item_indices, .ground_item_placement, allocator);
    appendPlacementDeletesDescending(&plan, level, level_index, &decoration_indices, .decoration_placement, allocator);
    for (tile_positions.items) |position| {
        plan.append(allocator, .{ .editor_event = .{ .editor_set_tile = .{
            .level_index = level_index,
            .position = position,
            .is_floor = false,
        } } }) catch @panic("failed to allocate editor selection delete plan");
    }

    // LIFO: reverse so processing + log order = plan order.
    std.mem.reverse(Event, plan.items);
    return plan.items;
}

/// In a selection move, an UNSELECTED occupant standing on `position`
/// PINS its ground - the tile stays underneath it and the moved thing
/// lands at its target instead (only selected things are backed up +
/// moved). The tools never place anything on a marker tile, so the marker
/// arm's use is defensive for crafted states.
fn selectionMoveOccupantPinsTile(
    level: *const types.EditorLevel,
    selection: []const types.Selectable,
    position: Vector2,
) bool {
    for (level.entity_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and placement.position.y == position.y and
            !selectionContains(selection, .{ .entity_placement = @intCast(placement_index) })) return true;
    }
    for (level.item_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and placement.position.y == position.y and
            !selectionContains(selection, .{ .ground_item_placement = @intCast(placement_index) })) return true;
    }
    return false;
}

/// Append `index` unless already collected (a crafted log can carry
/// duplicate selection entries; a duplicate delete would panic in the
/// delete arm's bounds check after the first removal shifts the list).
fn appendIndexIfNew(
    indices: *std.ArrayList(u32),
    index: u32,
    allocator: std.mem.Allocator,
) void {
    for (indices.items) |existing| {
        if (existing == index) return;
    }
    indices.append(allocator, index) catch
        @panic("failed to allocate editor selection delete plan");
}

/// Emit one placement-kind's deletes in DESCENDING index order - the
/// processing order (the caller reverses the whole plan for the LIFO
/// push, which flips it back to ascending in the slice). Out-of-range
/// (stale) indices are skipped defensively.
fn appendPlacementDeletesDescending(
    plan: *std.ArrayList(Event),
    level: *const types.EditorLevel,
    level_index: u32,
    indices: *std.ArrayList(u32),
    kind: std.meta.Tag(types.Selectable),
    allocator: std.mem.Allocator,
) void {
    std.mem.sort(u32, indices.items, {}, std.sort.asc(u32));
    const placement_count: usize = switch (kind) {
        .entity_placement => level.entity_placements.len,
        .ground_item_placement => level.item_placements.len,
        .decoration_placement => level.decoration_placements.len,
        else => return,
    };
    var index = indices.items.len;
    while (index > 0) {
        index -= 1;
        const placement_index = indices.items[index];
        if (@as(usize, placement_index) >= placement_count) continue;
        const variant: events.EditorEvent = switch (kind) {
            .entity_placement => .{ .editor_delete_entity_placement = .{
                .level_index = level_index,
                .placement_index = placement_index,
            } },
            .ground_item_placement => .{ .editor_delete_item_placement = .{
                .level_index = level_index,
                .placement_index = placement_index,
            } },
            .decoration_placement => .{ .editor_delete_decoration_placement = .{
                .level_index = level_index,
                .placement_index = placement_index,
            } },
            else => unreachable,
        };
        plan.append(allocator, .{ .editor_event = variant }) catch
            @panic("failed to allocate editor selection delete plan");
    }
}

pub fn planEditorRegionSelectActions(
    editor: *const types.Editor,
    start_position: Vector2,
    end_position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    const min_x = @min(start_position.x, end_position.x);
    const max_x = @max(start_position.x, end_position.x);
    const min_y = @min(start_position.y, end_position.y);
    const max_y = @max(start_position.y, end_position.y);

    var plan: std.ArrayList(Event) = .empty;
    for (level.level_tiles) |tile| {
        if (tile.x >= min_x and tile.x <= max_x and tile.y >= min_y and tile.y <= max_y) {
            appendSelectEntryIfNew(&plan, editor.selection, .{ .tile = tile }, allocator);
        }
    }
    for (level.entity_placements, 0..) |placement, placement_index| {
        if (placement.position.x >= min_x and placement.position.x <= max_x and
            placement.position.y >= min_y and placement.position.y <= max_y)
        {
            appendSelectEntryIfNew(&plan, editor.selection, .{ .entity_placement = @intCast(placement_index) }, allocator);
        }
    }
    for (level.item_placements, 0..) |placement, placement_index| {
        if (placement.position.x >= min_x and placement.position.x <= max_x and
            placement.position.y >= min_y and placement.position.y <= max_y)
        {
            appendSelectEntryIfNew(&plan, editor.selection, .{ .ground_item_placement = @intCast(placement_index) }, allocator);
        }
    }
    for (level.decoration_placements, 0..) |placement, placement_index| {
        // Any footprint tile inside the region grabs the decoration.
        const world_tiles = loaders.decorationFootprintWorldTiles(
            editor.decoration_types[placement.type_id].footprint,
            placement.position,
            allocator,
        );
        for (world_tiles) |world_tile| {
            if (world_tile.x >= min_x and world_tile.x <= max_x and
                world_tile.y >= min_y and world_tile.y <= max_y)
            {
                appendSelectEntryIfNew(&plan, editor.selection, .{ .decoration_placement = @intCast(placement_index) }, allocator);
                break;
            }
        }
    }
    if (level.player_start.x >= min_x and level.player_start.x <= max_x and
        level.player_start.y >= min_y and level.player_start.y <= max_y)
    {
        appendSelectEntryIfNew(&plan, editor.selection, .player_start, allocator);
    }
    if (level.level_end) |level_end_position| {
        if (level_end_position.x >= min_x and level_end_position.x <= max_x and
            level_end_position.y >= min_y and level_end_position.y <= max_y)
        {
            appendSelectEntryIfNew(&plan, editor.selection, .level_end, allocator);
        }
    }

    // LIFO: reverse so processing + log order = plan order.
    std.mem.reverse(Event, plan.items);
    return plan.items;
}

/// Plan the ctrl+A select-all: one `editor_select` per selectable thing
/// in the ACTIVE level (every tile, entity / item / decoration placement,
/// the '!' / '='), skipping entries already in the selection - the
/// marquee's membership rule with no region bound. The adds share the
/// action's idle point, so one undo step reverts the whole batch.
pub fn planEditorSelectAllActions(
    editor: *const types.Editor,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    var plan: std.ArrayList(Event) = .empty;
    for (level.level_tiles) |tile| {
        appendSelectEntryIfNew(&plan, editor.selection, .{ .tile = tile }, allocator);
    }
    for (level.entity_placements, 0..) |_, placement_index| {
        appendSelectEntryIfNew(
            &plan,
            editor.selection,
            .{ .entity_placement = @intCast(placement_index) },
            allocator,
        );
    }
    for (level.item_placements, 0..) |_, placement_index| {
        appendSelectEntryIfNew(
            &plan,
            editor.selection,
            .{ .ground_item_placement = @intCast(placement_index) },
            allocator,
        );
    }
    for (level.decoration_placements, 0..) |_, placement_index| {
        appendSelectEntryIfNew(
            &plan,
            editor.selection,
            .{ .decoration_placement = @intCast(placement_index) },
            allocator,
        );
    }
    appendSelectEntryIfNew(&plan, editor.selection, .player_start, allocator);
    if (level.level_end != null) {
        appendSelectEntryIfNew(&plan, editor.selection, .level_end, allocator);
    }

    // LIFO: reverse so processing + log order = plan order.
    std.mem.reverse(Event, plan.items);
    return plan.items;
}

/// Append `entry`'s select event unless it is already in the selection
/// (shared by the marquee region and the ctrl+A select-all - an add,
/// never a remove, never a duplicate).
fn appendSelectEntryIfNew(
    plan: *std.ArrayList(Event),
    selection: []const types.Selectable,
    entry: types.Selectable,
    allocator: std.mem.Allocator,
) void {
    if (selectionContains(selection, entry)) return;
    plan.append(allocator, .{ .editor_event = .{ .editor_select = .{ .entry = entry } } }) catch
        @panic("failed to allocate editor selection plan");
}
