//! Pure editor click/selection planning, in two layers (the slice-4
//! extraction):
//!
//! - The NEUTRAL GRID CORE (`GridStep` / `SelectionOp` + the `planGrid*`
//! / `grid*` fns): pure decision logic over a level-shaped grid +
//! placements + `Selectable` - what a click would mutate, in a
//! surface-independent vocabulary ordered for LIFO draining. No Editor,
//! no events. File-private today; the hub editor's tool facades (slice
//! 4-3) import it and flip it pub - the mission editor and the hub
//! editor then share every ordering rule (LIFO draining, index-stable
//! descending deletes, footprint-replace) by construction, once.
//!
//! - The MISSION-EDITOR FACADES (`planEditor*Actions`, `editorClickGroup`,
//! `editorSelection*`): resolve the active level, run the neutral core,
//! and map steps/ops onto `editor_event` 1:1 in order. These keep the
//! historical signatures - every call site (the input-side click
//! orchestrators + the gesture arms) and test is unchanged.
//!
//! Also here: the selection algebra (value equality, contains,
//! with-entry / without-entry / without-tile), `activeEditorLevel`, and
//! the two editors' tool-cycle steps. A planner computes the sub-event
//! list its click would push; the editor event handlers push the plan,
//! and the input layer fires the player action only when the plan is
//! nonempty, so a click that would change nothing never reaches the
//! event log (no undo/replay step). See DESIGN → Level Editor →
//! Active-tool model + Selection model.

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
        .npc_placement => |index| b == .npc_placement and b.npc_placement == index,
        .exit_placement => |index| b == .exit_placement and b.exit_placement == index,
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

/// One step of a NEUTRAL grid plan - the surface-independent mutation
/// vocabulary shared by the mission editor's level grids and the hub
/// editor's hub grids (the slice-4 extraction: the planners decide WHAT
/// to mutate over a level-shaped grid; each surface maps steps to its
/// own event family at the push site, 1:1 in order). Steps that address
/// placements by INDEX assume the processing convention the planners
/// encode: the plan is ordered for LIFO draining (the event stack pops
/// from the end - the REVERSE of processing order), and each delete
/// list ascends in the slice so it processes DESCENDING (index-stable
/// removal). A surface that maps steps in order inherits both rules by
/// construction.
pub const GridStep = union(enum) {
    set_tile: struct { position: Vector2, is_floor: bool },
    place_entity: struct { type_id: u32, position: Vector2 },
    set_entity_type: struct { placement_index: u32, type_id: u32 },
    delete_entity: u32,
    place_item: struct { type_id: u32, position: Vector2 },
    set_item_type: struct { placement_index: u32, type_id: u32 },
    delete_item: u32,
    place_decoration: struct { type_id: u32, position: Vector2 },
    delete_decoration: u32,
    /// Hub-grid kinds: an NPC placement (the type is the whole identity -
    /// the sprite derives from it; retype = delete + place in one plan)
    /// and the exit marker's UPSERT (keyed by mission handle - placing
    /// moves the mission's existing marker, wherever it was).
    place_npc: struct { npc_type: types.NpcType, position: Vector2 },
    delete_npc: u32,
    set_exit_marker: struct { mission: u32, position: Vector2 },
    delete_exit_marker: u32,
};

/// One step of a neutral SELECTION plan: the select / deselect / clear
/// vocabulary. The toggle, replace, region, and select-all planners
/// decide the ops over `Selectable`; each surface maps them to its own
/// selection events, 1:1 in order. Same LIFO order contract as
/// `GridStep`.
pub const SelectionOp = union(enum) {
    select: types.Selectable,
    deselect: types.Selectable,
    clear,
};

/// Which selection-deletion policy a plan runs - see
/// `planGridSelectionDelete`.
pub const SelectionDeleteMode = enum {
    /// The Delete key: a selected tile's OCCUPANT is swept with it (an
    /// occupant can't stand on nothing).
    delete_key,
    /// A selection move's clear phase: an UNSELECTED occupant PINS its
    /// tile - the tile stays underneath it and the moved tile lands at
    /// the target instead.
    selection_move,
};

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
/// Placement invariant). The plan is ordered for LIFO draining (set_tile
/// first, deletes in ascending placement order → processing DESCENDING -
/// index-stable removal; the tile lands last). All steps share one idle
/// point, so one undo reverts the whole click.
///
/// NEUTRAL CORE (the slice-4 extraction): pure over a level-shaped grid +
/// the decoration palette; the mission editor's `planEditorTilePaintActions`
/// and the hub editor's tile tool both map its steps to their own events.
fn planGridTilePaint(
    level: *const types.EditorLevel,
    decoration_types: []const types.DecorationTypeDef,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const GridStep {
    for (level.level_tiles) |tile| {
        if (tile.x == position.x and tile.y == position.y) return &.{};
    }
    var steps: std.ArrayList(GridStep) = .empty;
    steps.append(allocator, .{ .set_tile = .{
        .position = position,
        .is_floor = true,
    } }) catch @panic("failed to allocate editor paint plan");
    for (level.decoration_placements, 0..) |placement, placement_index| {
        const type_definition = decoration_types[placement.type_id];
        if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
            steps.append(allocator, .{ .delete_decoration = @intCast(placement_index) }) catch
                @panic("failed to allocate editor paint plan");
        }
    }
    return steps.items;
}

/// The mission editor's tile-paint façade: resolve the active level, run
/// the neutral planner, map the steps onto `editor_event` (1:1 in order).
pub fn planEditorTilePaintActions(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    return gridStepsToEditorEvents(
        @intCast(editor.active_level_index),
        planGridTilePaint(level, editor.decoration_types, position, allocator),
        allocator,
    );
}

/// Map a neutral grid plan onto the mission editor's `editor_event` family,
/// 1:1 in order (the plan's LIFO order is the contract - see `GridStep`).
fn gridStepsToEditorEvents(
    level_index: u32,
    steps: []const GridStep,
    allocator: std.mem.Allocator,
) []const Event {
    if (steps.len == 0) return &.{};
    var events_out: std.ArrayList(Event) = .empty;
    for (steps) |step| {
        const variant: events.EditorEvent = switch (step) {
            .set_tile => |tile| .{ .editor_set_tile = .{
                .level_index = level_index,
                .position = tile.position,
                .is_floor = tile.is_floor,
            } },
            .place_entity => |place| .{ .editor_place_entity = .{
                .level_index = level_index,
                .type_id = place.type_id,
                .position = place.position,
            } },
            .set_entity_type => |retype| .{ .editor_set_entity_placement_type = .{
                .level_index = level_index,
                .placement_index = retype.placement_index,
                .type_id = retype.type_id,
            } },
            .delete_entity => |placement_index| .{ .editor_delete_entity_placement = .{
                .level_index = level_index,
                .placement_index = placement_index,
            } },
            .place_item => |place| .{ .editor_place_item = .{
                .level_index = level_index,
                .type_id = place.type_id,
                .position = place.position,
            } },
            .set_item_type => |retype| .{ .editor_set_item_placement_type = .{
                .level_index = level_index,
                .placement_index = retype.placement_index,
                .type_id = retype.type_id,
            } },
            .delete_item => |placement_index| .{ .editor_delete_item_placement = .{
                .level_index = level_index,
                .placement_index = placement_index,
            } },
            .place_decoration => |place| .{ .editor_place_decoration = .{
                .level_index = level_index,
                .type_id = place.type_id,
                .position = place.position,
            } },
            .delete_decoration => |placement_index| .{ .editor_delete_decoration_placement = .{
                .level_index = level_index,
                .placement_index = placement_index,
            } },
            // Hub-grid kinds: a mission level never produces these steps
            // (its npc/exit lists are empty by invariant).
            .place_npc, .delete_npc, .set_exit_marker, .delete_exit_marker => unreachable,
        };
        events_out.append(allocator, .{ .editor_event = variant }) catch
            @panic("failed to allocate editor plan");
    }
    return events_out.items;
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
/// Enemy-tool click: place the palette entity type at the clicked tile,
/// replacing whatever occupies it. Occupant semantics (see DESIGN →
/// Level Editor → Active-tool model, placement tools): player start / level end →
/// no-op (never overwritten); covering decorations → deleted; missing tile
/// → placed; co-located ground item → deleted; existing enemy → RETYPED in
/// place (set_entity_type, not delete + re-place - stable identity); same
/// type already there → nothing to do (the plan is empty only when the tile
/// is also present and nothing needs clearing). The plan is ordered for LIFO
/// draining (the REVERSE of processing order; the per-kind delete lists
/// ascend so they process descending - index-stable removal). All steps
/// share one idle point - one undo reverts the whole click. The
/// one-thing-per-tile invariant is enforced at the place handler (panic on
/// an occupied tile) - the deletes above run first, so the place lands on a
/// cleared tile.
///
/// NEUTRAL CORE (the slice-4 extraction): the mission editor maps it via
/// `planEditorEntityPlacementActions`; the hub editor has no entity tools
/// and never calls it.
fn planGridEntityPlacement(
    level: *const types.EditorLevel,
    entity_types: []const types.EntityTypeDef,
    decoration_types: []const types.DecorationTypeDef,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const GridStep {
    if (type_id >= entity_types.len) return &.{};

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

    var steps: std.ArrayList(GridStep) = .empty;
    if (occupant_index == null) {
        steps.append(allocator, .{ .place_entity = .{
            .type_id = type_id,
            .position = position,
        } }) catch @panic("failed to allocate editor place plan");
    } else if (level.entity_placements[occupant_index.?].type_id != type_id) {
        // Same type already there - no branch taken (nothing to do).
        steps.append(allocator, .{ .set_entity_type = .{
            .placement_index = @intCast(occupant_index.?),
            .type_id = type_id,
        } }) catch @panic("failed to allocate editor place plan");
    }
    if (!tile_present) {
        steps.append(allocator, .{ .set_tile = .{
            .position = position,
            .is_floor = true,
        } }) catch @panic("failed to allocate editor place plan");
    }
    for (level.item_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            steps.append(allocator, .{ .delete_item = @intCast(placement_index) }) catch
                @panic("failed to allocate editor place plan");
        }
    }
    for (level.decoration_placements, 0..) |placement, placement_index| {
        const type_definition = decoration_types[placement.type_id];
        if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
            steps.append(allocator, .{ .delete_decoration = @intCast(placement_index) }) catch
                @panic("failed to allocate editor place plan");
        }
    }
    return steps.items;
}

/// The mission editor's enemy-tool façade over the neutral planner.
pub fn planEditorEntityPlacementActions(
    editor: *const types.Editor,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    return gridStepsToEditorEvents(
        @intCast(editor.active_level_index),
        planGridEntityPlacement(level, editor.entity_types, editor.decoration_types, type_id, position, allocator),
        allocator,
    );
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
/// ANY footprint tile → deleted; then the placement lands (the place handler
/// enforces footprint-tile exclusivity). The plan is ordered for LIFO
/// draining (the REVERSE of processing order; each delete list ascends so it
/// processes descending - index-stable). All steps share one idle point -
/// one undo reverts the whole click.
///
/// NEUTRAL CORE (the slice-4 extraction): shared by the mission editor's
/// `planEditorDecorationPlacementActions` and the hub editor's decoration
/// tool (the campaign-SHARED decoration palette).
fn planGridDecorationPlacement(
    level: *const types.EditorLevel,
    decoration_types: []const types.DecorationTypeDef,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const GridStep {
    if (type_id >= decoration_types.len) return &.{};
    const type_definition = decoration_types[type_id];
    const footprint_tiles = loaders.decorationFootprintWorldTiles(
        type_definition.footprint,
        position,
        allocator,
    );
    if (footprint_tiles.len == 0) return &.{};

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

    var steps: std.ArrayList(GridStep) = .empty;
    if (!duplicate_present) {
        steps.append(allocator, .{ .place_decoration = .{
            .type_id = type_id,
            .position = position,
        } }) catch @panic("failed to allocate editor place plan");
    }
    // Erase every covered tile that has one.
    for (footprint_tiles) |tile| {
        if (functions.tileListContains(level.level_tiles, tile)) {
            steps.append(allocator, .{ .set_tile = .{
                .position = tile,
                .is_floor = false,
            } }) catch @panic("failed to allocate editor place plan");
        }
    }
    // Entities + items standing on covered tiles (they sit ON tiles, so
    // this fires for covered tiles that had one - looping all footprint
    // tiles is robust either way).
    for (level.entity_placements, 0..) |placement, placement_index| {
        if (functions.tileListContains(footprint_tiles, placement.position)) {
            steps.append(allocator, .{ .delete_entity = @intCast(placement_index) }) catch
                @panic("failed to allocate editor place plan");
        }
    }
    for (level.item_placements, 0..) |placement, placement_index| {
        if (functions.tileListContains(footprint_tiles, placement.position)) {
            steps.append(allocator, .{ .delete_item = @intCast(placement_index) }) catch
                @panic("failed to allocate editor place plan");
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
        const other_definition = decoration_types[placement.type_id];
        var overlaps = false;
        for (footprint_tiles) |tile| {
            if (loaders.decorationFootprintCovers(other_definition.footprint, placement.position, tile, allocator)) {
                overlaps = true;
                break;
            }
        }
        if (overlaps) {
            steps.append(allocator, .{ .delete_decoration = @intCast(placement_index) }) catch
                @panic("failed to allocate editor place plan");
        }
    }
    return steps.items;
}

/// The mission editor's decoration-tool façade over the neutral planner.
pub fn planEditorDecorationPlacementActions(
    editor: *const types.Editor,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    return gridStepsToEditorEvents(
        @intCast(editor.active_level_index),
        planGridDecorationPlacement(level, editor.decoration_types, type_id, position, allocator),
        allocator,
    );
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
/// Ground-item-tool click: place the palette item type at the clicked tile
/// - the same occupant replacement as the entity tool, with the roles swapped
/// for the two placement kinds: an existing ground item is RETYPED in place
/// (set_item_type) and an enemy on the tile is DELETED (the item can't
/// coexist with it). The '!' / '=' → no-op; covering decorations → deleted; a
/// missing tile → placed (the item sits ON a tile). The plan is ordered for
/// LIFO draining (the REVERSE of processing order; each delete list ascends
/// so it processes descending - index-stable). All steps share one idle
/// point - one undo reverts the whole click.
///
/// NEUTRAL CORE (the slice-4 extraction): the mission editor maps it via
/// `planEditorItemPlacementActions`; the hub editor has no item tools and
/// never calls it.
fn planGridItemPlacement(
    level: *const types.EditorLevel,
    item_types: []const types.ItemTypeDef,
    decoration_types: []const types.DecorationTypeDef,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const GridStep {
    if (type_id >= item_types.len) return &.{};

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

    var steps: std.ArrayList(GridStep) = .empty;
    if (occupant_index == null) {
        steps.append(allocator, .{ .place_item = .{
            .type_id = type_id,
            .position = position,
        } }) catch @panic("failed to allocate editor place plan");
    } else if (level.item_placements[occupant_index.?].type_id != type_id) {
        // Same type already there - no branch taken (nothing to do).
        steps.append(allocator, .{ .set_item_type = .{
            .placement_index = @intCast(occupant_index.?),
            .type_id = type_id,
        } }) catch @panic("failed to allocate editor place plan");
    }
    if (!tile_present) {
        steps.append(allocator, .{ .set_tile = .{
            .position = position,
            .is_floor = true,
        } }) catch @panic("failed to allocate editor place plan");
    }
    // An enemy on the tile is deleted (an item can't coexist with it - one
    // thing per placed tile).
    for (level.entity_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            steps.append(allocator, .{ .delete_entity = @intCast(placement_index) }) catch
                @panic("failed to allocate editor place plan");
        }
    }
    for (level.decoration_placements, 0..) |placement, placement_index| {
        const type_definition = decoration_types[placement.type_id];
        if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
            steps.append(allocator, .{ .delete_decoration = @intCast(placement_index) }) catch
                @panic("failed to allocate editor place plan");
        }
    }
    return steps.items;
}

/// The mission editor's item-tool façade over the neutral planner.
pub fn planEditorItemPlacementActions(
    editor: *const types.Editor,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    return gridStepsToEditorEvents(
        @intCast(editor.active_level_index),
        planGridItemPlacement(level, editor.item_types, editor.decoration_types, type_id, position, allocator),
        allocator,
    );
}

/// NPC-tool click over a hub grid: place the NPC type at the clicked
/// tile - the entity tool's occupant semantics over the hub kinds. The
/// '!' / '=' -> no-op (never overwritten); a tile with an EXIT MARKER ->
/// no-op (markers are graph wiring - content never overwrites them; move
/// the marker first); an existing NPC -> RETYPED in place (delete +
/// place in one plan - the type is the whole identity); a missing tile
/// -> placed (an NPC's tile is walkable at load); covering decorations
/// -> deleted (replace). The plan is ordered for LIFO draining (the
/// place steps first, the deletes ascending -> processing descending -
/// index-stable). A mission level never calls this (no NPC tools).
pub fn planGridNpcPlacement(
    level: *const types.EditorLevel,
    decoration_types: []const types.DecorationTypeDef,
    npc_type: types.NpcType,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const GridStep {
    // The '!' / '=' are singletons, movable never deletable.
    if (level.player_start.x == position.x and level.player_start.y == position.y) return &.{};
    if (level.level_end) |level_end_position| {
        if (level_end_position.x == position.x and level_end_position.y == position.y) return &.{};
    }
    // An exit marker pins its cell (one layout char per cell - the save
    // format cannot represent an NPC under a marker).
    for (level.exit_placements) |placement| {
        if (placement.position.x == position.x and placement.position.y == position.y) return &.{};
    }

    var tile_present = false;
    for (level.level_tiles) |tile| {
        if (tile.x == position.x and tile.y == position.y) {
            tile_present = true;
            break;
        }
    }

    // Co-located NPC placement, if any.
    var occupant_index: ?usize = null;
    for (level.npc_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            occupant_index = placement_index;
            break;
        }
    }

    var steps: std.ArrayList(GridStep) = .empty;
    if (occupant_index == null) {
        steps.append(allocator, .{ .place_npc = .{
            .npc_type = npc_type,
            .position = position,
        } }) catch @panic("failed to allocate editor place plan");
    } else if (level.npc_placements[occupant_index.?].npc_type != npc_type) {
        // Same type already there - no branch taken (nothing to do).
        // Retype = delete the old + place the new (one plan, one idle
        // point - the type is the whole identity, no stable index to
        // preserve).
        steps.append(allocator, .{ .place_npc = .{
            .npc_type = npc_type,
            .position = position,
        } }) catch @panic("failed to allocate editor place plan");
        steps.append(allocator, .{ .delete_npc = @intCast(occupant_index.?) }) catch
            @panic("failed to allocate editor place plan");
    }
    if (!tile_present) {
        steps.append(allocator, .{ .set_tile = .{
            .position = position,
            .is_floor = true,
        } }) catch @panic("failed to allocate editor place plan");
    }
    for (level.decoration_placements, 0..) |placement, placement_index| {
        const type_definition = decoration_types[placement.type_id];
        if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
            steps.append(allocator, .{ .delete_decoration = @intCast(placement_index) }) catch
                @panic("failed to allocate editor place plan");
        }
    }
    return steps.items;
}

/// Exit-marker-tool click over a hub grid: put/move THE mission's marker
/// (the tool's payload) at the clicked tile - the UPSERT rule (one
/// marker per mission; placing at a new position moves it wherever it
/// was). The '!' / '=' -> no-op; ANOTHER mission's marker on the cell ->
/// no-op (one marker per cell - the layout format's one char; move that
/// marker first); a co-located NPC -> deleted (content yields to
/// markers); covering decorations -> deleted; a missing tile -> placed
/// (an exit's tile is walkable at load). The plan is ordered for LIFO
/// draining (the upsert first, then the place/delete steps). A mission
/// level never calls this (no mission tools).
pub fn planGridExitPlacement(
    level: *const types.EditorLevel,
    decoration_types: []const types.DecorationTypeDef,
    mission: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const GridStep {
    // The '!' / '=' are singletons, movable never deletable.
    if (level.player_start.x == position.x and level.player_start.y == position.y) return &.{};
    if (level.level_end) |level_end_position| {
        if (level_end_position.x == position.x and level_end_position.y == position.y) return &.{};
    }
    // Another mission's marker pins its cell; THIS mission's own marker
    // elsewhere simply moves (the upsert).
    for (level.exit_placements) |placement| {
        if (placement.position.x == position.x and placement.position.y == position.y and
            placement.mission != mission) return &.{};
    }

    var tile_present = false;
    for (level.level_tiles) |tile| {
        if (tile.x == position.x and tile.y == position.y) {
            tile_present = true;
            break;
        }
    }

    var steps: std.ArrayList(GridStep) = .empty;
    steps.append(allocator, .{ .set_exit_marker = .{
        .mission = mission,
        .position = position,
    } }) catch @panic("failed to allocate editor place plan");
    if (!tile_present) {
        steps.append(allocator, .{ .set_tile = .{
            .position = position,
            .is_floor = true,
        } }) catch @panic("failed to allocate editor place plan");
    }
    // A co-located NPC yields (content vs markers - the save format's
    // one char per cell).
    for (level.npc_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            steps.append(allocator, .{ .delete_npc = @intCast(placement_index) }) catch
                @panic("failed to allocate editor place plan");
        }
    }
    for (level.decoration_placements, 0..) |placement, placement_index| {
        const type_definition = decoration_types[placement.type_id];
        if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
            steps.append(allocator, .{ .delete_decoration = @intCast(placement_index) }) catch
                @panic("failed to allocate editor place plan");
        }
    }
    return steps.items;
}

/// One-step plan for the delete cascade's early-return arms.
fn singleGridStepPlan(
    step: GridStep,
    allocator: std.mem.Allocator,
) []const GridStep {
    const steps = allocator.alloc(GridStep, 1) catch
        @panic("failed to allocate editor delete plan");
    steps[0] = step;
    return steps;
}

/// Right-click delete (tool-independent): ONE thing per click, priority:
/// enemy / ground-item occupant (at most one by the one-thing-per-tile
/// invariant; an entity wins if both are somehow present), then covering
/// decoration(s) (all of them - consistent with every other editor flow;
/// overlapping footprints are a degenerate hand-authored case), then the
/// bare tile. The '!' / '=' are never deleted (checked first - they sit ON
/// tiles, so the bare-tile erase must not fire under them), and empty ground
/// is a no-op (empty plan). One delete = one undo step by construction.
///
/// NEUTRAL CORE (the slice-4 extraction): shared by the mission editor's
/// `planEditorDeleteActions` and the hub editor's right-click delete (the
/// hub grid has no entities/items - those arms simply never fire there).
fn planGridDelete(
    level: *const types.EditorLevel,
    decoration_types: []const types.DecorationTypeDef,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const GridStep {
    // The '!' / '=' are singletons, movable never deletable - and their
    // tiles survive too.
    if (level.player_start.x == position.x and level.player_start.y == position.y) return &.{};
    if (level.level_end) |level_end_position| {
        if (level_end_position.x == position.x and level_end_position.y == position.y) return &.{};
    }

    // The exit marker first (progressive delete: the marker goes alone -
    // the ground and any wiring elsewhere survive; removing a marker
    // makes its mission unstartable, a deliberate act).
    for (level.exit_placements) |placement| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            return singleGridStepPlan(.{ .delete_exit_marker = placement.mission }, allocator);
        }
    }
    // Occupant first (progressive delete: the item/enemy goes, the tile
    // survives for the next click).
    for (level.entity_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            return singleGridStepPlan(.{ .delete_entity = @intCast(placement_index) }, allocator);
        }
    }
    for (level.item_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            return singleGridStepPlan(.{ .delete_item = @intCast(placement_index) }, allocator);
        }
    }
    for (level.npc_placements, 0..) |placement, placement_index| {
        if (placement.position.x == position.x and
            placement.position.y == position.y)
        {
            return singleGridStepPlan(.{ .delete_npc = @intCast(placement_index) }, allocator);
        }
    }
    // Covering decoration(s): ascending list → descending processing
    // (index-stable).
    var covering: std.ArrayList(GridStep) = .empty;
    for (level.decoration_placements, 0..) |placement, placement_index| {
        const type_definition = decoration_types[placement.type_id];
        if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
            covering.append(allocator, .{ .delete_decoration = @intCast(placement_index) }) catch
                @panic("failed to allocate editor delete plan");
        }
    }
    if (covering.items.len > 0) return covering.items;
    // Bare tile.
    if (functions.tileListContains(level.level_tiles, position)) {
        return singleGridStepPlan(.{ .set_tile = .{
            .position = position,
            .is_floor = false,
        } }, allocator);
    }
    // Nothing there - no-op.
    return &.{};
}

/// The mission editor's right-click-delete façade over the neutral planner.
pub fn planEditorDeleteActions(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    return gridStepsToEditorEvents(
        @intCast(editor.active_level_index),
        planGridDelete(level, editor.decoration_types, position, allocator),
        allocator,
    );
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
/// The select tool's click GROUP at `position` over a level-shaped grid:
/// everything that acts as one unit - the '!' / '=' singletons; a covering
/// decoration (the FIRST - exactly what the hover preview outlines); or the
/// tile INCLUDING anything standing on it (entity / ground-item
/// placements). Empty ground → an empty group. Shared by the toggle
/// (shift+click) and replace (plain click) planners; the group order is
/// tile, entity, item. Also the would-be POST-REPLACE selection the
/// move-drag gate evaluates an unselected-claim drag against (see
/// `editorSelectionMoveVetoed`).
///
/// NEUTRAL CORE (the slice-4 extraction): shared by the mission editor and
/// the hub editor's select tool.
fn gridClickGroup(
    level: *const types.EditorLevel,
    decoration_types: []const types.DecorationTypeDef,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    var group: [4]types.Selectable = undefined;
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
    // An exit marker is its OWN singleton group (graph wiring, like the
    // '!' - clicking it addresses the marker, not the ground under it).
    if (group_length == 0) {
        for (level.exit_placements, 0..) |placement, placement_index| {
            if (placement.position.x == position.x and placement.position.y == position.y) {
                group[0] = .{ .exit_placement = @intCast(placement_index) };
                group_length = 1;
                break;
            }
        }
    }
    if (group_length == 0) {
        // A covering decoration (the first - matching the hover preview).
        for (level.decoration_placements, 0..) |placement, placement_index| {
            const type_definition = decoration_types[placement.type_id];
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
        for (level.npc_placements, 0..) |placement, placement_index| {
            if (placement.position.x == position.x and placement.position.y == position.y) {
                group[group_length] = .{ .npc_placement = @intCast(placement_index) };
                group_length += 1;
            }
        }
    }

    const entries = allocator.alloc(types.Selectable, group_length) catch
        @panic("failed to allocate editor click group");
    @memcpy(entries, group[0..group_length]);
    return entries;
}

/// The mission editor's click-group façade over the neutral core (pub for
/// the move-drag gesture's import).
pub fn editorClickGroup(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    const level = activeEditorLevel(editor) orelse return &.{};
    return gridClickGroup(level, editor.decoration_types, position, allocator);
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

/// Map a neutral selection plan onto the mission editor's selection events,
/// 1:1 in order (the plan's LIFO order is the contract - see
/// `SelectionOp`).
fn selectionOpsToEditorEvents(
    ops: []const SelectionOp,
    allocator: std.mem.Allocator,
) []const Event {
    if (ops.len == 0) return &.{};
    var events_out: std.ArrayList(Event) = .empty;
    for (ops) |op| {
        const variant: events.EditorEvent = switch (op) {
            .select => |entry| .{ .editor_select = .{ .entry = entry } },
            .deselect => |entry| .{ .editor_deselect = .{ .entry = entry } },
            .clear => .editor_clear_selection,
        };
        events_out.append(allocator, .{ .editor_event = variant }) catch
            @panic("failed to allocate editor selection plan");
    }
    return events_out.items;
}

/// Toggle-plan core (shift+click): the clicked group's entries toggle as
/// one unit. Anything from the group already selected -> deselect every
/// PRESENT entry (clicking a selected tile deselects the tile AND its
/// occupant); nothing selected -> select the whole group. One op per entry
/// (granular by design - see DESIGN -> Architecture -> Level Editor ->
/// Selection model); they share the click's idle point, so one undo step
/// reverts the whole click. The ops are ordered for LIFO draining - the
/// group REVERSED - so the entries process (and land in the recorded log)
/// in group order: tile, then entity, then item.
///
/// NEUTRAL CORE (the slice-4 extraction): shared by both editors' select
/// tools.
fn planGridSelectionToggle(
    selection: []const types.Selectable,
    group: []const types.Selectable,
    allocator: std.mem.Allocator,
) []const SelectionOp {
    if (group.len == 0) return &.{};

    // Toggle direction: anything present -> deselect every present entry;
    // nothing present -> select the whole group.
    var any_present = false;
    for (group) |entry| {
        if (selectionContains(selection, entry)) {
            any_present = true;
            break;
        }
    }
    var ops: std.ArrayList(SelectionOp) = .empty;
    var group_index = group.len;
    while (group_index > 0) {
        group_index -= 1;
        const entry = group[group_index];
        const op: SelectionOp = if (any_present)
            .{ .deselect = entry }
        else
            .{ .select = entry };
        ops.append(allocator, op) catch @panic("failed to allocate editor selection plan");
    }
    return ops.items;
}

/// The mission editor's shift+click toggle facade over the neutral core.
pub fn planEditorSelectionActions(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const group = editorClickGroup(editor, position, allocator);
    return selectionOpsToEditorEvents(
        planGridSelectionToggle(editor.selection, group, allocator),
        allocator,
    );
}

/// Plain-click (no Shift) planner: REPLACE the selection with the clicked
/// group - the whole selection is cleared, then the group is selected.
/// Empty ground → the clear alone (the clicky deselect-all). A click that
/// would change nothing (the selection IS exactly the group, or empty
/// ground with an already-empty selection) plans empty - no player action
/// fires. Built forward in processing order (clear first, then the
/// group's selects in group order) and reversed for the LIFO push, so the
/// clear processes first and the final selection reads in group order.
/// Replace-plan core (plain click): REPLACE the selection with the clicked
/// group - the whole selection is cleared, then the group is selected.
/// Empty ground -> the clear alone (the clicky deselect-all). A click that
/// would change nothing (the selection IS exactly the group, or empty
/// ground with an already-empty selection) plans empty - no player action
/// fires. Built forward in processing order (clear first, then the group's
/// selects in group order) and reversed for the LIFO push, so the clear
/// processes first and the final selection reads in group order.
///
/// NEUTRAL CORE (the slice-4 extraction): shared by both editors' select
/// tools.
fn planGridSelectionReplace(
    selection: []const types.Selectable,
    group: []const types.Selectable,
    allocator: std.mem.Allocator,
) []const SelectionOp {
    // The selection is already exactly the group (also covers empty
    // ground + empty selection) -> nothing to do.
    if (group.len == selection.len) {
        var all_present = true;
        for (group) |entry| {
            if (!selectionContains(selection, entry)) {
                all_present = false;
                break;
            }
        }
        if (all_present) return &.{};
    }

    var ops: std.ArrayList(SelectionOp) = .empty;
    if (selection.len > 0) {
        ops.append(allocator, .clear) catch
            @panic("failed to allocate editor selection plan");
    }
    for (group) |entry| {
        ops.append(allocator, .{ .select = entry }) catch
            @panic("failed to allocate editor selection plan");
    }
    std.mem.reverse(SelectionOp, ops.items);
    return ops.items;
}

/// The mission editor's plain-click replace facade over the neutral core.
pub fn planEditorReplaceSelectionActions(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const group = editorClickGroup(editor, position, allocator);
    return selectionOpsToEditorEvents(
        planGridSelectionReplace(editor.selection, group, allocator),
        allocator,
    );
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
pub fn planEditorSelectionDeleteActions(
    editor: *const types.Editor,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    return gridStepsToEditorEvents(
        @intCast(editor.active_level_index),
        planGridSelectionDelete(level, editor.selection, allocator, .delete_key),
        allocator,
    );
}

/// Does the select tool's selection cover `position` over a level-shaped
/// grid - i.e. would a plain press there start a MOVE drag? Mirrors the
/// click group resolution: a selected tile / entity / item at the
/// position, a selected decoration whose footprint covers it, or a
/// selected '!' / '=' at it.
///
/// NEUTRAL CORE (the slice-4 extraction): shared by both editors'
/// move-drag gestures.
fn gridSelectionContainsPosition(
    level: *const types.EditorLevel,
    decoration_types: []const types.DecorationTypeDef,
    selection: []const types.Selectable,
    position: Vector2,
    allocator: std.mem.Allocator,
) bool {
    for (selection) |selected| {
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
            .npc_placement => |index| {
                if (index < level.npc_placements.len) {
                    const placement = level.npc_placements[index];
                    if (placement.position.x == position.x and placement.position.y == position.y) return true;
                }
            },
            .exit_placement => |index| {
                if (index < level.exit_placements.len) {
                    const placement = level.exit_placements[index];
                    if (placement.position.x == position.x and placement.position.y == position.y) return true;
                }
            },
            .decoration_placement => |index| {
                if (index < level.decoration_placements.len) {
                    const placement = level.decoration_placements[index];
                    if (loaders.decorationFootprintCovers(
                        decoration_types[placement.type_id].footprint,
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

/// The mission editor's move-drag-claim facade over the neutral core
/// (used by `handleEditorMoveDrag`).
pub fn editorSelectionContainsPosition(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) bool {
    const level = activeEditorLevel(editor) orelse return false;
    return gridSelectionContainsPosition(level, editor.decoration_types, editor.selection, position, allocator);
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
fn gridSelectionMoveVetoed(
    level: *const types.EditorLevel,
    selection: []const types.Selectable,
    delta: Vector2,
) bool {
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

/// The mission editor's move-veto facade over the neutral core.
pub fn editorSelectionMoveVetoed(
    editor: *const types.Editor,
    selection: []const types.Selectable,
    delta: Vector2,
) bool {
    const level = activeEditorLevel(editor) orelse return false;
    return gridSelectionMoveVetoed(level, selection, delta);
}

/// The translated selection as a selection-move worklist over a
/// level-shaped grid: each selected thing's move entry (type_id + TARGET
/// position - the concrete backup the delete phase needs because it
/// destroys the placements the selection addressed). Ordered like the
/// selection itself; the commit chain places them sequentially against
/// the live post-delete state.
///
/// NEUTRAL CORE (the slice-4 extraction): the hub editor's move lands as
/// its own commit event over the same entry shape (hub arms join at 4-3).
fn gridSelectionMoveEntries(
    level: *const types.EditorLevel,
    selection: []const types.Selectable,
    delta: Vector2,
    allocator: std.mem.Allocator,
) []const types.EditorSelectionMoveEntry {
    var entries: std.ArrayList(types.EditorSelectionMoveEntry) = .empty;
    for (selection) |selected| {
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
            .npc_placement => |index| {
                if (index < level.npc_placements.len) {
                    const placement = level.npc_placements[index];
                    entries.append(allocator, .{ .npc = .{
                        .npc_type = placement.npc_type,
                        .position = translatedPosition(placement.position, delta),
                    } }) catch @panic("failed to allocate editor selection move entries");
                }
            },
            .exit_placement => |index| {
                if (index < level.exit_placements.len) {
                    const placement = level.exit_placements[index];
                    entries.append(allocator, .{ .exit_marker = .{
                        .mission = placement.mission,
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
    return entries.items;
}

/// The mission editor's selection-move facade over the neutral cores: the
/// translated selection as the commit-chain worklist
/// (`editor_commit_selection_move`), then the clear phase mapped onto
/// `editor_event`. Shared by the `player_move_editor_selection` handler
/// (the entries build lives in the neutral core - the other tools' shape)
/// and the input-side no-op gate (via `editorSelectionMoveVetoed`). EMPTY
/// when the move is vetoed - the drag never fires (no dead undo step),
/// not a partial move (the flag silently staying behind while the rest
/// moves would be easy to miss).
pub fn planEditorSelectionMoveActions(
    editor: *const types.Editor,
    delta: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};

    if (editorSelectionMoveVetoed(editor, editor.selection, delta)) return &.{};

    const entries = gridSelectionMoveEntries(level, editor.selection, delta, allocator);

    var plan: std.ArrayList(Event) = .empty;
    plan.append(allocator, .{ .editor_event = .{ .editor_commit_selection_move = .{
        .entries = entries,
        .next_index = 0,
    } } }) catch @panic("failed to allocate editor selection move plan");
    plan.appendSlice(allocator, gridStepsToEditorEvents(
        @intCast(editor.active_level_index),
        planGridSelectionDelete(level, editor.selection, allocator, .selection_move),
        allocator,
    )) catch @panic("failed to allocate editor selection move plan");
    return plan.items;
}

/// Selection-deletion core: fan a selection out into the per-entry grid
/// steps (the same machinery the right-click delete composes). The
/// '!' / '=' entries are NEVER deletable (skipped) and the tiles under
/// them survive too (a marker needs its ground). A selected tile takes
/// its OCCUPANT with it under `delete_key` - an entity/item placement
/// standing on it is deleted even when unselected (unreachable via
/// today's UI - clicks and marquees always grab tile + occupants
/// together - but craftable in a log and reachable once deselect
/// features land; an occupant can't stand on nothing).
///
/// Index stability: the delete set is computed from the ORIGINAL state
/// (selected placements + swept occupants, deduped per kind), and the
/// processing order - the reversed LIFO plan - runs each placement kind
/// HIGH-BEFORE-LOW, so a removal never shifts an index a later step still
/// addresses. Tile erases are position-keyed (safe any time) and process
/// last. Stale entries (out-of-range indices, absent tiles) are skipped
/// defensively. The selection reconcile runs inside each delete arm of
/// the surface event handlers, keeping the selection consistent
/// mid-batch.
///
/// NEUTRAL CORE (the slice-4 extraction): the Delete key
/// (`planEditorSelectionDeleteActions`) and the selection move's clear
/// phase (inside `planEditorSelectionMoveActions`) both map it; the hub
/// editor maps it for its delete + move at 4-3.
fn planGridSelectionDelete(
    level: *const types.EditorLevel,
    selection: []const types.Selectable,
    allocator: std.mem.Allocator,
    mode: SelectionDeleteMode,
) []const GridStep {
    // The delete set per placement kind (selected entries + swept
    // occupants, deduped) + the erasable tile positions.
    var entity_indices: std.ArrayList(u32) = .empty;
    var item_indices: std.ArrayList(u32) = .empty;
    var decoration_indices: std.ArrayList(u32) = .empty;
    var npc_indices: std.ArrayList(u32) = .empty;
    var exit_missions: std.ArrayList(u32) = .empty;
    var tile_positions: std.ArrayList(Vector2) = .empty;

    for (selection) |selected| {
        switch (selected) {
            .entity_placement => |index| appendIndexIfNew(&entity_indices, index, allocator),
            .ground_item_placement => |index| appendIndexIfNew(&item_indices, index, allocator),
            .decoration_placement => |index| appendIndexIfNew(&decoration_indices, index, allocator),
            .npc_placement => |index| appendIndexIfNew(&npc_indices, index, allocator),
            .exit_placement => |index| {
                // The exit delete is keyed by MISSION HANDLE (the upsert
                // rule - index-stability does not apply), deduped.
                if (index < level.exit_placements.len) {
                    appendMissionIfNew(&exit_missions, level.exit_placements[index].mission, allocator);
                }
            },
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
                // its ground (both markers selected -> both moving ->
                // neither remains; the marker's own tile arm protection
                // already skipped this erase, so no duplicate).
                if (selected == .player_start) {
                    if (level.level_end) |level_end_position| {
                        if (level_end_position.x == marker_position.x and level_end_position.y == marker_position.y and
                            !selectionContains(selection, .level_end)) continue;
                    }
                } else {
                    if (level.player_start.x == marker_position.x and level.player_start.y == marker_position.y and
                        !selectionContains(selection, .player_start)) continue;
                }
                // An unselected occupant pins its ground (defensive - the
                // placement rules never put anything on a marker tile).
                if (selectionMoveOccupantPinsTile(level, selection, marker_position)) continue;
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
                if (mode == .selection_move and selectionMoveOccupantPinsTile(level, selection, position)) continue;
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
                    for (level.npc_placements, 0..) |placement, placement_index| {
                        if (placement.position.x == position.x and placement.position.y == position.y) {
                            appendIndexIfNew(&npc_indices, @intCast(placement_index), allocator);
                            break;
                        }
                    }
                }
            },
        }
    }

    // Processing order: entity deletes, item deletes, decoration deletes
    // (each descending), then the tile erases. The whole list is reversed
    // for the LIFO plan below.
    var plan: std.ArrayList(GridStep) = .empty;
    appendPlacementDeletesDescending(&plan, level, &entity_indices, .entity, allocator);
    appendPlacementDeletesDescending(&plan, level, &item_indices, .item, allocator);
    appendPlacementDeletesDescending(&plan, level, &decoration_indices, .decoration, allocator);
    appendPlacementDeletesDescending(&plan, level, &npc_indices, .npc, allocator);
    for (exit_missions.items) |mission| {
        plan.append(allocator, .{ .delete_exit_marker = mission }) catch
            @panic("failed to allocate editor selection delete plan");
    }
    for (tile_positions.items) |position| {
        plan.append(allocator, .{ .set_tile = .{
            .position = position,
            .is_floor = false,
        } }) catch @panic("failed to allocate editor selection delete plan");
    }

    // LIFO: reverse so processing + log order = plan order.
    std.mem.reverse(GridStep, plan.items);
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

/// Append `mission` unless already collected (the exit-delete set's
/// dedup - a crafted log can carry duplicate exit entries; the keyed
/// delete would otherwise fire twice).
fn appendMissionIfNew(
    missions: *std.ArrayList(u32),
    mission: u32,
    allocator: std.mem.Allocator,
) void {
    for (missions.items) |existing| {
        if (existing == mission) return;
    }
    missions.append(allocator, mission) catch
        @panic("failed to allocate editor selection delete plan");
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

/// The placement-kind a `GridStep` delete addresses - the delete core's
/// per-kind axis (mirrors the Selectable placement arms).
const GridPlacementKind = enum {
    entity,
    item,
    decoration,
    npc,
};

/// Emit one placement-kind's deletes in DESCENDING index order - the
/// processing order (the caller reverses the whole plan for the LIFO
/// contract, which flips it back to ascending in the slice). Out-of-range
/// (stale) indices are skipped defensively.
fn appendPlacementDeletesDescending(
    plan: *std.ArrayList(GridStep),
    level: *const types.EditorLevel,
    indices: *std.ArrayList(u32),
    kind: GridPlacementKind,
    allocator: std.mem.Allocator,
) void {
    std.mem.sort(u32, indices.items, {}, std.sort.asc(u32));
    const placement_count: usize = switch (kind) {
        .entity => level.entity_placements.len,
        .item => level.item_placements.len,
        .decoration => level.decoration_placements.len,
        .npc => level.npc_placements.len,
    };
    var index = indices.items.len;
    while (index > 0) {
        index -= 1;
        const placement_index = indices.items[index];
        if (@as(usize, placement_index) >= placement_count) continue;
        const step: GridStep = switch (kind) {
            .entity => .{ .delete_entity = placement_index },
            .item => .{ .delete_item = placement_index },
            .decoration => .{ .delete_decoration = placement_index },
            .npc => .{ .delete_npc = placement_index },
        };
        plan.append(allocator, step) catch
            @panic("failed to allocate editor selection delete plan");
    }
}

/// Marquee core: every selectable thing inside the inclusive rectangle
/// spanned by the two corner tiles over a level-shaped grid (order-
/// independent), skipping entries already in the selection (an add,
/// never a remove - the plain click toggles). Region membership: level
/// tiles / entity / item placements by position; a decoration when ANY
/// of its footprint tiles is inside (matching the click hit-testing - if
/// you can click it, you can marquee it); the '!' / '=' singletons by
/// their tile. Deterministic order - tiles, entities, items, decorations,
/// singletons, each in stored order - and the list is REVERSED before
/// returning (the LIFO order contract) so the entries process + land in
/// the log in plan order. An empty result (nothing in the region, or
/// everything already selected) means no player action fires.
///
/// NEUTRAL CORE (the slice-4 extraction): shared by both editors'
/// marquee gestures.
fn planGridRegionSelect(
    level: *const types.EditorLevel,
    decoration_types: []const types.DecorationTypeDef,
    selection: []const types.Selectable,
    start_position: Vector2,
    end_position: Vector2,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    const min_x = @min(start_position.x, end_position.x);
    const max_x = @max(start_position.x, end_position.x);
    const min_y = @min(start_position.y, end_position.y);
    const max_y = @max(start_position.y, end_position.y);

    var entries: std.ArrayList(types.Selectable) = .empty;
    for (level.level_tiles) |tile| {
        if (tile.x >= min_x and tile.x <= max_x and tile.y >= min_y and tile.y <= max_y) {
            appendSelectEntryIfNew(&entries, selection, .{ .tile = tile }, allocator);
        }
    }
    for (level.entity_placements, 0..) |placement, placement_index| {
        if (placement.position.x >= min_x and placement.position.x <= max_x and
            placement.position.y >= min_y and placement.position.y <= max_y)
        {
            appendSelectEntryIfNew(&entries, selection, .{ .entity_placement = @intCast(placement_index) }, allocator);
        }
    }
    for (level.item_placements, 0..) |placement, placement_index| {
        if (placement.position.x >= min_x and placement.position.x <= max_x and
            placement.position.y >= min_y and placement.position.y <= max_y)
        {
            appendSelectEntryIfNew(&entries, selection, .{ .ground_item_placement = @intCast(placement_index) }, allocator);
        }
    }
    for (level.decoration_placements, 0..) |placement, placement_index| {
        // Any footprint tile inside the region grabs the decoration.
        const world_tiles = loaders.decorationFootprintWorldTiles(
            decoration_types[placement.type_id].footprint,
            placement.position,
            allocator,
        );
        for (world_tiles) |world_tile| {
            if (world_tile.x >= min_x and world_tile.x <= max_x and
                world_tile.y >= min_y and world_tile.y <= max_y)
            {
                appendSelectEntryIfNew(&entries, selection, .{ .decoration_placement = @intCast(placement_index) }, allocator);
                break;
            }
        }
    }
    if (level.player_start.x >= min_x and level.player_start.x <= max_x and
        level.player_start.y >= min_y and level.player_start.y <= max_y)
    {
        appendSelectEntryIfNew(&entries, selection, .player_start, allocator);
    }
    if (level.level_end) |level_end_position| {
        if (level_end_position.x >= min_x and level_end_position.x <= max_x and
            level_end_position.y >= min_y and level_end_position.y <= max_y)
        {
            appendSelectEntryIfNew(&entries, selection, .level_end, allocator);
        }
    }

    // LIFO: reverse so processing + log order = plan order.
    std.mem.reverse(types.Selectable, entries.items);
    return entries.items;
}

/// The mission editor's marquee facade over the neutral core.
pub fn planEditorRegionSelectActions(
    editor: *const types.Editor,
    start_position: Vector2,
    end_position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    return selectEntriesToEditorEvents(
        planGridRegionSelect(level, editor.decoration_types, editor.selection, start_position, end_position, allocator),
        allocator,
    );
}

/// Map a neutral list of new selection entries onto the mission editor's
/// select events, 1:1 in order (the list's LIFO order is the contract).
fn selectEntriesToEditorEvents(
    entries: []const types.Selectable,
    allocator: std.mem.Allocator,
) []const Event {
    if (entries.len == 0) return &.{};
    var events_out: std.ArrayList(Event) = .empty;
    for (entries) |entry| {
        events_out.append(allocator, .{ .editor_event = .{ .editor_select = .{ .entry = entry } } }) catch
            @panic("failed to allocate editor selection plan");
    }
    return events_out.items;
}

/// Plan the ctrl+A select-all: one `editor_select` per selectable thing
/// in the ACTIVE level (every tile, entity / item / decoration placement,
/// the '!' / '='), skipping entries already in the selection - the
/// marquee's membership rule with no region bound. The adds share the
/// action's idle point, so one undo step reverts the whole batch.
fn planGridSelectAll(
    level: *const types.EditorLevel,
    selection: []const types.Selectable,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    var entries: std.ArrayList(types.Selectable) = .empty;
    for (level.level_tiles) |tile| {
        appendSelectEntryIfNew(&entries, selection, .{ .tile = tile }, allocator);
    }
    for (level.entity_placements, 0..) |_, placement_index| {
        appendSelectEntryIfNew(
            &entries,
            selection,
            .{ .entity_placement = @intCast(placement_index) },
            allocator,
        );
    }
    for (level.item_placements, 0..) |_, placement_index| {
        appendSelectEntryIfNew(
            &entries,
            selection,
            .{ .ground_item_placement = @intCast(placement_index) },
            allocator,
        );
    }
    for (level.decoration_placements, 0..) |_, placement_index| {
        appendSelectEntryIfNew(
            &entries,
            selection,
            .{ .decoration_placement = @intCast(placement_index) },
            allocator,
        );
    }
    appendSelectEntryIfNew(&entries, selection, .player_start, allocator);
    if (level.level_end != null) {
        appendSelectEntryIfNew(&entries, selection, .level_end, allocator);
    }

    // LIFO: reverse so processing + log order = plan order.
    std.mem.reverse(types.Selectable, entries.items);
    return entries.items;
}

/// The mission editor's ctrl+A facade over the neutral core.
pub fn planEditorSelectAllActions(
    editor: *const types.Editor,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};
    return selectEntriesToEditorEvents(
        planGridSelectAll(level, editor.selection, allocator),
        allocator,
    );
}

/// Append `entry` unless it is already in the selection (shared by the
/// marquee region and the ctrl+A select-all - an add, never a remove,
/// never a duplicate).
fn appendSelectEntryIfNew(
    entries: *std.ArrayList(types.Selectable),
    selection: []const types.Selectable,
    entry: types.Selectable,
    allocator: std.mem.Allocator,
) void {
    if (selectionContains(selection, entry)) return;
    entries.append(allocator, entry) catch
        @panic("failed to allocate editor selection plan");
}

// ============================================================
// The hub editor facades (slice 4-3) - the mission facades' mirror
// over the same neutral core: resolve nothing (the CALLER passes the
// drilled-in hub + the campaign decoration palette), run the core,
// map onto HubEditorEvent 1:1 in order. The target hub's handle is
// never carried per event (the drill-in IS the address).
// ============================================================

/// Map a neutral grid plan onto the hub editor's event family, 1:1 in
/// order. No level_index - the events address the drilled-in hub. Pub for
/// the hub commit-chain handler (the move worklist plans directly against
/// the neutral core).
pub fn gridStepsToHubEvents(
    steps: []const GridStep,
    allocator: std.mem.Allocator,
) []const Event {
    if (steps.len == 0) return &.{};
    var events_out: std.ArrayList(Event) = .empty;
    for (steps) |step| {
        const variant: events.HubEditorEvent = switch (step) {
            .set_tile => |tile| .{ .hub_set_tile = .{
                .position = tile.position,
                .is_floor = tile.is_floor,
            } },
            .place_decoration => |place| .{ .hub_place_decoration = .{
                .type_id = place.type_id,
                .position = place.position,
            } },
            .delete_decoration => |placement_index| .{ .hub_delete_decoration_placement = .{
                .placement_index = placement_index,
            } },
            .place_npc => |place| .{ .hub_place_npc = .{
                .npc_type = place.npc_type,
                .position = place.position,
            } },
            .delete_npc => |placement_index| .{ .hub_delete_npc_placement = .{
                .placement_index = placement_index,
            } },
            .set_exit_marker => |set| .{ .hub_set_exit_marker = .{
                .mission = set.mission,
                .position = set.position,
            } },
            .delete_exit_marker => |mission| .{ .hub_delete_exit_marker = .{
                .mission = mission,
            } },
            // The hub grid has no entities or items - those core arms are
            // mission-only vocabulary a hub plan never contains.
            .place_entity, .set_entity_type, .delete_entity, .place_item, .set_item_type, .delete_item => unreachable,
        };
        events_out.append(allocator, .{ .hub_editor_event = variant }) catch
            @panic("failed to allocate hub editor plan");
    }
    return events_out.items;
}

/// Map a neutral selection plan onto the hub editor's selection events,
/// 1:1 in order.
fn selectionOpsToHubEvents(
    ops: []const SelectionOp,
    allocator: std.mem.Allocator,
) []const Event {
    if (ops.len == 0) return &.{};
    var events_out: std.ArrayList(Event) = .empty;
    for (ops) |op| {
        const variant: events.HubEditorEvent = switch (op) {
            .select => |entry| .{ .hub_select = .{ .entry = entry } },
            .deselect => |entry| .{ .hub_deselect = .{ .entry = entry } },
            .clear => .hub_clear_selection,
        };
        events_out.append(allocator, .{ .hub_editor_event = variant }) catch
            @panic("failed to allocate hub editor selection plan");
    }
    return events_out.items;
}

/// Map a neutral list of new selection entries onto the hub editor's
/// select events, 1:1 in order.
fn selectEntriesToHubEvents(
    entries: []const types.Selectable,
    allocator: std.mem.Allocator,
) []const Event {
    if (entries.len == 0) return &.{};
    var events_out: std.ArrayList(Event) = .empty;
    for (entries) |entry| {
        events_out.append(allocator, .{ .hub_editor_event = .{ .hub_select = .{ .entry = entry } } }) catch
            @panic("failed to allocate hub editor selection plan");
    }
    return events_out.items;
}

/// The hub grid of the drilled-in hub (the caller resolves the hub; this
/// is the shared dereference so every facade reads the same shape).
fn hubGrid(hub: *const types.CampaignHubEdit) *const types.EditorLevel {
    return &hub.grid;
}

/// Tile-paint click over the drilled-in hub (the tile tool). The plan is
/// the neutral core's, mapped onto the hub events.
pub fn planHubTilePaintActions(
    hub: *const types.CampaignHubEdit,
    decoration_types: []const types.DecorationTypeDef,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    return gridStepsToHubEvents(
        planGridTilePaint(hubGrid(hub), decoration_types, position, allocator),
        allocator,
    );
}

/// Decoration placement over the drilled-in hub (the move chain's
/// decoration re-placement; the decoration TOOL palette lands at 4-5 and
/// calls the same facade).
pub fn planHubDecorationPlacementActions(
    hub: *const types.CampaignHubEdit,
    decoration_types: []const types.DecorationTypeDef,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    return gridStepsToHubEvents(
        planGridDecorationPlacement(hubGrid(hub), decoration_types, type_id, position, allocator),
        allocator,
    );
}

/// The tool-independent right-click delete over the drilled-in hub.
pub fn planHubDeleteActions(
    hub: *const types.CampaignHubEdit,
    decoration_types: []const types.DecorationTypeDef,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    return gridStepsToHubEvents(
        planGridDelete(hubGrid(hub), decoration_types, position, allocator),
        allocator,
    );
}

/// The hub editor's click group at `position` (pub for the gesture arms).
pub fn hubClickGroup(
    hub: *const types.CampaignHubEdit,
    decoration_types: []const types.DecorationTypeDef,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    return gridClickGroup(hubGrid(hub), decoration_types, position, allocator);
}

/// Select-tool shift+click over the drilled-in hub: toggle the clicked
/// group.
pub fn planHubToggleSelectionActions(
    hub: *const types.CampaignHubEdit,
    decoration_types: []const types.DecorationTypeDef,
    selection: []const types.Selectable,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    return selectionOpsToHubEvents(
        planGridSelectionToggle(selection, hubClickGroup(hub, decoration_types, position, allocator), allocator),
        allocator,
    );
}

/// Select-tool plain click over the drilled-in hub: replace the selection
/// with the clicked group.
pub fn planHubReplaceSelectionActions(
    hub: *const types.CampaignHubEdit,
    decoration_types: []const types.DecorationTypeDef,
    selection: []const types.Selectable,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    return selectionOpsToHubEvents(
        planGridSelectionReplace(selection, hubClickGroup(hub, decoration_types, position, allocator), allocator),
        allocator,
    );
}

/// Select-tool marquee over the drilled-in hub.
pub fn planHubRegionSelectActions(
    hub: *const types.CampaignHubEdit,
    decoration_types: []const types.DecorationTypeDef,
    selection: []const types.Selectable,
    start_position: Vector2,
    end_position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    return selectEntriesToHubEvents(
        planGridRegionSelect(hubGrid(hub), decoration_types, selection, start_position, end_position, allocator),
        allocator,
    );
}

/// ctrl+A over the drilled-in hub.
pub fn planHubSelectAllActions(
    hub: *const types.CampaignHubEdit,
    selection: []const types.Selectable,
    allocator: std.mem.Allocator,
) []const Event {
    return selectEntriesToHubEvents(
        planGridSelectAll(hubGrid(hub), selection, allocator),
        allocator,
    );
}

/// Select-tool Delete key over the drilled-in hub.
pub fn planHubSelectionDeleteActions(
    hub: *const types.CampaignHubEdit,
    selection: []const types.Selectable,
    allocator: std.mem.Allocator,
) []const Event {
    return gridStepsToHubEvents(
        planGridSelectionDelete(hubGrid(hub), selection, allocator, .delete_key),
        allocator,
    );
}

/// Does the hub selection cover `position` (the move-drag claim)?
pub fn hubSelectionContainsPosition(
    hub: *const types.CampaignHubEdit,
    decoration_types: []const types.DecorationTypeDef,
    selection: []const types.Selectable,
    position: Vector2,
    allocator: std.mem.Allocator,
) bool {
    return gridSelectionContainsPosition(hubGrid(hub), decoration_types, selection, position, allocator);
}

/// The hub selection-move plan: the translated selection as the chained
/// worklist (hub_commit_selection_move), then the clear phase mapped onto
/// hub events. A hub grid has no level_end, so the marker veto never
/// fires. EMPTY only on a dead hub (the mission version's veto path is
/// structurally unreachable here).
pub fn planHubSelectionMoveActions(
    hub: *const types.CampaignHubEdit,
    selection: []const types.Selectable,
    delta: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const entries = gridSelectionMoveEntries(hubGrid(hub), selection, delta, allocator);

    var plan: std.ArrayList(Event) = .empty;
    plan.append(allocator, .{ .hub_editor_event = .{ .hub_commit_selection_move = .{
        .entries = entries,
        .next_index = 0,
    } } }) catch @panic("failed to allocate hub editor selection move plan");
    plan.appendSlice(allocator, gridStepsToHubEvents(
        planGridSelectionDelete(hubGrid(hub), selection, allocator, .selection_move),
        allocator,
    )) catch @panic("failed to allocate hub editor selection move plan");
    return plan.items;
}

/// One entry of the mission editor's Tab cycle: a tool + the palette
/// REGION it occupies (the layout-order ordinal: the fixed tools, then
/// the groups) - the spatial cycle model's position key.
const CycleEntry = struct {
    tool: types.EditorToolId,
    region: u8,
};

/// The palette region a tool occupies: the layout order is
/// [Select][Tile][Entities][Decorations][Items] - collapsed regions are
/// skipped by the cycle, but an orphaned active tool keeps its region's
/// position (see `nextMissionEditorTool`).
fn editorToolRegion(tool: types.EditorToolId) u8 {
    return switch (tool) {
        .select => 0,
        .tile => 1,
        .entity_type => 2,
        .decoration_type => 3,
        .item_type => 4,
    };
}

/// The mission editor's Tab-cycle list: the always-active fixed tools
/// (Select, Tile), then each EXPANDED palette group's type tools in
/// palette order (Entities, Decorations, Items). A group's cells are in
/// the cycle only while the group is expanded - collapsing a group
/// removes its tools. Pure; allocates the (small) list into `allocator`.
fn missionEditorToolCycle(
    allocator: std.mem.Allocator,
    editor: types.Editor,
    palette_collapsed: [3]bool,
) []const CycleEntry {
    var cycle: std.ArrayList(CycleEntry) = .empty;
    cycle.append(allocator, .{ .tool = .select, .region = 0 }) catch @panic("failed to append the select tool");
    cycle.append(allocator, .{ .tool = .tile, .region = 1 }) catch @panic("failed to append the tile tool");
    if (!palette_collapsed[0]) {
        for (editor.entity_types, 0..) |_, index| {
            cycle.append(allocator, .{ .tool = .{ .entity_type = @intCast(index) }, .region = 2 }) catch
                @panic("failed to append an entity tool");
        }
    }
    if (!palette_collapsed[1]) {
        for (editor.decoration_types, 0..) |_, index| {
            cycle.append(allocator, .{ .tool = .{ .decoration_type = @intCast(index) }, .region = 3 }) catch
                @panic("failed to append a decoration tool");
        }
    }
    if (!palette_collapsed[2]) {
        for (editor.item_types, 0..) |_, index| {
            cycle.append(allocator, .{ .tool = .{ .item_type = @intCast(index) }, .region = 4 }) catch
                @panic("failed to append an item tool");
        }
    }
    return cycle.toOwnedSlice(allocator) catch @panic("failed to own the tool cycle");
}

/// The next mission-editor tool in the Tab cycle - a SPATIAL model over
/// the palette's fixed region layout ([Select][Tile][Entities]
/// [Decorations][Items]): Tab cycles right, shift+Tab left, to the
/// nearest PRESENT tool (collapsed regions are skipped), wrapping at the
/// ends. An active tool whose group is COLLAPSED keeps its region's
/// position: the cycle steps to the nearest present tool beyond that
/// region in the direction (forward from an orphaned entity tool with
/// Decorations expanded lands on its first cell - not a wrap to Select;
/// with everything else collapsed it wraps to Select, and backward lands
/// on Tile). Pure.
pub fn nextMissionEditorTool(
    allocator: std.mem.Allocator,
    editor: types.Editor,
    palette_collapsed: [3]bool,
    forward: bool,
) types.EditorToolId {
    const cycle = missionEditorToolCycle(allocator, editor, palette_collapsed);
    defer allocator.free(cycle);
    // The active tool present in the cycle: step within it, wrapping at
    // the ends.
    for (cycle, 0..) |entry, index| {
        if (std.meta.eql(entry.tool, editor.active_tool)) {
            const next_index = if (forward)
                (index + 1) % cycle.len
            else
                (index + cycle.len - 1) % cycle.len;
            return cycle[next_index].tool;
        }
    }
    // The active tool's group is collapsed (the tool is not in the
    // cycle): step past its REGION to the nearest present tool in the
    // direction, wrapping to the cycle's far end when none lies beyond.
    const active_region = editorToolRegion(editor.active_tool);
    if (forward) {
        for (cycle) |entry| {
            if (entry.region > active_region) return entry.tool;
        }
        return cycle[0].tool;
    }
    var index = cycle.len;
    while (index > 0) {
        index -= 1;
        if (cycle[index].region < active_region) return cycle[index].tool;
    }
    return cycle[cycle.len - 1].tool;
}

/// The campaign editor's Tab cycle: the three map tools left-to-right
/// (select -> hub -> mission), wrapping. Pure.
pub fn nextCampaignEditorTool(
    active: types.CampaignEditorToolId,
    forward: bool,
) types.CampaignEditorToolId {
    const order = [_]types.CampaignEditorToolId{ .select, .hub, .mission };
    var active_index: usize = 0;
    for (order, 0..) |tool, index| {
        if (tool == active) active_index = index;
    }
    const next_index = if (forward)
        (active_index + 1) % order.len
    else
        (active_index + order.len - 1) % order.len;
    return order[next_index];
}

test "nextMissionEditorTool: the fixed tools cycle when every group is collapsed" {
    const allocator = std.testing.allocator;
    const editor = types.Editor{};
    const all_collapsed = [3]bool{ true, true, true };

    // The cycle is [select, tile]: forward wraps tile -> select, backward
    // wraps select -> tile.
    try std.testing.expectEqual(
        types.EditorToolId.tile,
        nextMissionEditorTool(allocator, editor, all_collapsed, true),
    );
    try std.testing.expectEqual(
        types.EditorToolId.select,
        nextMissionEditorTool(allocator, .{ .active_tool = .tile }, all_collapsed, true),
    );
    try std.testing.expectEqual(
        types.EditorToolId.tile,
        nextMissionEditorTool(allocator, .{ .active_tool = .select }, all_collapsed, false),
    );
    try std.testing.expectEqual(
        types.EditorToolId.select,
        nextMissionEditorTool(allocator, .{ .active_tool = .tile }, all_collapsed, false),
    );
}

test "nextMissionEditorTool: expanded groups' tools ride the cycle in palette order" {
    const allocator = std.testing.allocator;
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .team = 1 } },
        .{ .id = "Brute", .template = .{ .name = "Brute", .team = 1 } },
    };
    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
    };
    // Entities + decorations expanded, items collapsed: the cycle is
    // [select, tile, entity 0, entity 1, decoration 0].
    const groups = [3]bool{ false, false, true };

    // Forward steps through the expanded entities, then the decoration,
    // then wraps to select.
    try std.testing.expectEqual(
        types.EditorToolId{ .entity_type = 0 },
        nextMissionEditorTool(allocator, .{ .active_tool = .tile, .entity_types = &entity_types, .decoration_types = &decoration_types }, groups, true),
    );
    try std.testing.expectEqual(
        types.EditorToolId{ .entity_type = 1 },
        nextMissionEditorTool(allocator, .{ .active_tool = .{ .entity_type = 0 }, .entity_types = &entity_types, .decoration_types = &decoration_types }, groups, true),
    );
    try std.testing.expectEqual(
        types.EditorToolId{ .decoration_type = 0 },
        nextMissionEditorTool(allocator, .{ .active_tool = .{ .entity_type = 1 }, .entity_types = &entity_types, .decoration_types = &decoration_types }, groups, true),
    );
    try std.testing.expectEqual(
        types.EditorToolId.select,
        nextMissionEditorTool(allocator, .{ .active_tool = .{ .decoration_type = 0 }, .entity_types = &entity_types, .decoration_types = &decoration_types }, groups, true),
    );
    // Backward wraps select -> the last entry (the decoration).
    try std.testing.expectEqual(
        types.EditorToolId{ .decoration_type = 0 },
        nextMissionEditorTool(allocator, .{ .active_tool = .select, .entity_types = &entity_types, .decoration_types = &decoration_types }, groups, false),
    );
}

test "nextMissionEditorTool: an orphaned tool keeps its region's position - the spatial cycle" {
    const allocator = std.testing.allocator;
    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
        .{ .id = "rock", .sprite = "rock_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
    };
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .team = 1 } },
    };

    // THE PLAYTEST SCENARIO: an entity tool active, Entities collapsed,
    // Decorations expanded - forward lands on the FIRST decoration cell
    // (Decorations sits right of Entities in the layout), backward on
    // Tile (the nearest present tool to the left).
    const editor = types.Editor{
        .active_tool = .{ .entity_type = 0 },
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
    };
    const entities_collapsed = [3]bool{ true, false, true };
    try std.testing.expectEqual(
        types.EditorToolId{ .decoration_type = 0 },
        nextMissionEditorTool(allocator, editor, entities_collapsed, true),
    );
    try std.testing.expectEqual(
        types.EditorToolId.tile,
        nextMissionEditorTool(allocator, editor, entities_collapsed, false),
    );

    // Everything else collapsed: forward wraps past the orphan's region
    // to the cycle's start (Select), backward lands on Tile.
    const all_collapsed = [3]bool{ true, true, true };
    try std.testing.expectEqual(
        types.EditorToolId.select,
        nextMissionEditorTool(allocator, editor, all_collapsed, true),
    );
    try std.testing.expectEqual(
        types.EditorToolId.tile,
        nextMissionEditorTool(allocator, editor, all_collapsed, false),
    );

    // An orphaned ITEM tool (Items collapsed) with Entities +
    // Decorations expanded: forward wraps to Select (nothing present
    // right of Items), backward lands on the LAST decoration cell.
    const item_editor = types.Editor{
        .active_tool = .{ .item_type = 0 },
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
    };
    const items_collapsed = [3]bool{ false, false, true };
    try std.testing.expectEqual(
        types.EditorToolId.select,
        nextMissionEditorTool(allocator, item_editor, items_collapsed, true),
    );
    try std.testing.expectEqual(
        types.EditorToolId{ .decoration_type = 1 },
        nextMissionEditorTool(allocator, item_editor, items_collapsed, false),
    );

    // An orphaned DECORATION tool (Decorations collapsed) with Entities
    // expanded: backward lands on the last entity cell, forward on
    // Select (Items collapsed too - the wrap).
    const decoration_editor = types.Editor{
        .active_tool = .{ .decoration_type = 1 },
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
    };
    const decorations_collapsed = [3]bool{ false, true, true };
    try std.testing.expectEqual(
        types.EditorToolId{ .entity_type = 0 },
        nextMissionEditorTool(allocator, decoration_editor, decorations_collapsed, false),
    );
    try std.testing.expectEqual(
        types.EditorToolId.select,
        nextMissionEditorTool(allocator, decoration_editor, decorations_collapsed, true),
    );
}

test "nextCampaignEditorTool: the three tools wrap both ways" {
    try std.testing.expectEqual(types.CampaignEditorToolId.hub, nextCampaignEditorTool(.select, true));
    try std.testing.expectEqual(types.CampaignEditorToolId.mission, nextCampaignEditorTool(.hub, true));
    try std.testing.expectEqual(types.CampaignEditorToolId.select, nextCampaignEditorTool(.mission, true));
    try std.testing.expectEqual(types.CampaignEditorToolId.mission, nextCampaignEditorTool(.select, false));
    try std.testing.expectEqual(types.CampaignEditorToolId.hub, nextCampaignEditorTool(.mission, false));
}

test "grid core: the hub-readiness contract - tile paint, decoration, delete over a hub-shaped grid" {
    // The hub editor's grids are EditorLevels with NO entities, NO items,
    // NO level_end - the neutral core must plan over exactly that shape
    // (the entity/item arms simply never fire). This is the 4-3 preview:
    // the hub facades will map these steps onto the hub event family.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
    };
    // The invariant-respecting hub shape: the decoration's footprint tile
    // (1,0) is TILE-FREE (footprint tiles erase their ground).
    const hub_grid = types.EditorLevel{
        .level_tiles = &.{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 } },
        .player_start = .{ .x = 0, .y = 0 },
        .decoration_placements = &.{.{ .type_id = 0, .position = .{ .x = 1, .y = 0 } }},
    };

    // Tile paint on empty ground: one step.
    const paint = planGridTilePaint(&hub_grid, &decoration_types, .{ .x = 5, .y = 5 }, allocator);
    try std.testing.expectEqual(@as(usize, 1), paint.len);
    try std.testing.expectEqual(GridStep{ .set_tile = .{ .position = .{ .x = 5, .y = 5 }, .is_floor = true } }, paint[0]);

    // Tile paint under the covering decoration: the paint + the covering
    // delete (replace, not block).
    const replace = planGridTilePaint(&hub_grid, &decoration_types, .{ .x = 1, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 2), replace.len);
    try std.testing.expectEqual(GridStep{ .set_tile = .{ .position = .{ .x = 1, .y = 0 }, .is_floor = true } }, replace[0]);
    try std.testing.expectEqual(GridStep{ .delete_decoration = 0 }, replace[1]);

    // The player spawn is never overwritten and never deleted.
    try std.testing.expectEqual(@as(usize, 0), planGridDelete(&hub_grid, &decoration_types, .{ .x = 0, .y = 0 }, allocator).len);
    const spawn_cover = planGridDecorationPlacement(&hub_grid, &decoration_types, 0, .{ .x = 0, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 0), spawn_cover.len);

    // Delete priority over the hub shape: the covering decoration, then
    // the bare tile.
    const decoration_delete = planGridDelete(&hub_grid, &decoration_types, .{ .x = 1, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 1), decoration_delete.len);
    try std.testing.expectEqual(GridStep{ .delete_decoration = 0 }, decoration_delete[0]);
    const tile_delete = planGridDelete(&hub_grid, &decoration_types, .{ .x = 0, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 0), tile_delete.len); // the spawn's ground survives
    const empty = planGridDelete(&hub_grid, &decoration_types, .{ .x = 9, .y = 9 }, allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // The click group over the hub shape: the spawn singleton, the
    // covering decoration, the bare tile - no entity/item arms.
    const spawn_group = gridClickGroup(&hub_grid, &decoration_types, .{ .x = 0, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 1), spawn_group.len);
    try std.testing.expectEqual(types.Selectable.player_start, spawn_group[0]);
    const decoration_group = gridClickGroup(&hub_grid, &decoration_types, .{ .x = 1, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 1), decoration_group.len);
    try std.testing.expectEqual(types.Selectable{ .decoration_placement = 0 }, decoration_group[0]);
    try std.testing.expectEqual(@as(usize, 0), gridClickGroup(&hub_grid, &decoration_types, .{ .x = 9, .y = 9 }, allocator).len);

    // The move veto never fires on a hub grid (no level_end).
    try std.testing.expect(!gridSelectionMoveVetoed(&hub_grid, &.{.player_start}, .{ .x = 1, .y = 0 }));
}

test "grid core: the NPC placement planner - occupant retype, marker protection, tile placement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
    };
    const hub_grid = types.EditorLevel{
        .level_tiles = &.{.{ .x = 0, .y = 0 }},
        .player_start = .{ .x = 0, .y = 0 },
        .npc_placements = &.{.{ .npc_type = .dream_guide, .position = .{ .x = 1, .y = 0 } }},
        .exit_placements = &.{.{ .mission = 5, .position = .{ .x = 2, .y = 0 } }},
    };

    // The spawn is never overwritten.
    try std.testing.expectEqual(@as(usize, 0), planGridNpcPlacement(&hub_grid, &decoration_types, .gear_upgrader, .{ .x = 0, .y = 0 }, allocator).len);

    // An exit marker pins its cell (content never overwrites markers).
    try std.testing.expectEqual(@as(usize, 0), planGridNpcPlacement(&hub_grid, &decoration_types, .gear_upgrader, .{ .x = 2, .y = 0 }, allocator).len);

    // Same type on the occupant: no place/retype - but the missing tile
    // under the position is still ensured (an NPC's tile is walkable at
    // load; the ground completes regardless).
    {
        const same_type = planGridNpcPlacement(&hub_grid, &decoration_types, .dream_guide, .{ .x = 1, .y = 0 }, allocator);
        try std.testing.expectEqual(@as(usize, 1), same_type.len);
        try std.testing.expectEqual(GridStep{ .set_tile = .{ .position = .{ .x = 1, .y = 0 }, .is_floor = true } }, same_type[0]);
    }

    // A different type: retype = place + delete (the LIFO order processes
    // the delete first), plus the missing tile under the position.
    const retype = planGridNpcPlacement(&hub_grid, &decoration_types, .gear_upgrader, .{ .x = 1, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 3), retype.len);
    try std.testing.expectEqual(GridStep{ .place_npc = .{ .npc_type = .gear_upgrader, .position = .{ .x = 1, .y = 0 } } }, retype[0]);
    try std.testing.expectEqual(GridStep{ .delete_npc = 0 }, retype[1]);
    try std.testing.expectEqual(GridStep{ .set_tile = .{ .position = .{ .x = 1, .y = 0 }, .is_floor = true } }, retype[2]);

    // Empty ground: place + tile.
    const place = planGridNpcPlacement(&hub_grid, &decoration_types, .gear_upgrader, .{ .x = 5, .y = 5 }, allocator);
    try std.testing.expectEqual(@as(usize, 2), place.len);
    try std.testing.expectEqual(GridStep{ .place_npc = .{ .npc_type = .gear_upgrader, .position = .{ .x = 5, .y = 5 } } }, place[0]);
    try std.testing.expectEqual(GridStep{ .set_tile = .{ .position = .{ .x = 5, .y = 5 }, .is_floor = true } }, place[1]);
}

test "grid core: the exit placement planner - the upsert, cell conflicts, content yielding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
    };
    const hub_grid = types.EditorLevel{
        .level_tiles = &.{.{ .x = 0, .y = 0 }},
        .player_start = .{ .x = 0, .y = 0 },
        .npc_placements = &.{.{ .npc_type = .dream_guide, .position = .{ .x = 1, .y = 0 } }},
        .exit_placements = &.{.{ .mission = 5, .position = .{ .x = 2, .y = 0 } }},
    };

    // The spawn is never overwritten.
    try std.testing.expectEqual(@as(usize, 0), planGridExitPlacement(&hub_grid, &decoration_types, 7, .{ .x = 0, .y = 0 }, allocator).len);

    // ANOTHER mission's marker pins the cell; this mission's own marker
    // elsewhere moves (the upsert - the marker's old cell is irrelevant).
    try std.testing.expectEqual(@as(usize, 0), planGridExitPlacement(&hub_grid, &decoration_types, 7, .{ .x = 2, .y = 0 }, allocator).len);
    const move_own = planGridExitPlacement(&hub_grid, &decoration_types, 5, .{ .x = 3, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 2), move_own.len);
    try std.testing.expectEqual(GridStep{ .set_exit_marker = .{ .mission = 5, .position = .{ .x = 3, .y = 0 } } }, move_own[0]);
    try std.testing.expectEqual(GridStep{ .set_tile = .{ .position = .{ .x = 3, .y = 0 }, .is_floor = true } }, move_own[1]);

    // A co-located NPC yields (content vs markers) + the tile.
    const over_npc = planGridExitPlacement(&hub_grid, &decoration_types, 7, .{ .x = 1, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 3), over_npc.len);
    try std.testing.expectEqual(GridStep{ .set_exit_marker = .{ .mission = 7, .position = .{ .x = 1, .y = 0 } } }, over_npc[0]);
    try std.testing.expectEqual(GridStep{ .set_tile = .{ .position = .{ .x = 1, .y = 0 }, .is_floor = true } }, over_npc[1]);
    try std.testing.expectEqual(GridStep{ .delete_npc = 0 }, over_npc[2]);
}

test "grid core: the delete chain over the hub kinds - marker first, then the NPC, then decoration, then tile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
    };
    const hub_grid = types.EditorLevel{
        .level_tiles = &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } },
        .player_start = .{ .x = 0, .y = 0 },
        .npc_placements = &.{.{ .npc_type = .dream_guide, .position = .{ .x = 1, .y = 0 } }},
        .exit_placements = &.{.{ .mission = 5, .position = .{ .x = 2, .y = 0 } }},
    };

    // The marker tier: one click removes exactly the marker.
    const marker = planGridDelete(&hub_grid, &decoration_types, .{ .x = 2, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 1), marker.len);
    try std.testing.expectEqual(GridStep{ .delete_exit_marker = 5 }, marker[0]);

    // The NPC occupant tier.
    const npc = planGridDelete(&hub_grid, &decoration_types, .{ .x = 1, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 1), npc.len);
    try std.testing.expectEqual(GridStep{ .delete_npc = 0 }, npc[0]);

    // The click group over the hub kinds: the marker singleton group; the
    // tile + its NPC together.
    const marker_group = gridClickGroup(&hub_grid, &decoration_types, .{ .x = 2, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 1), marker_group.len);
    try std.testing.expectEqual(types.Selectable{ .exit_placement = 0 }, marker_group[0]);
    const tile_group = gridClickGroup(&hub_grid, &decoration_types, .{ .x = 1, .y = 0 }, allocator);
    try std.testing.expectEqual(@as(usize, 2), tile_group.len);
    try std.testing.expectEqual(types.Selectable{ .tile = .{ .x = 1, .y = 0 } }, tile_group[0]);
    try std.testing.expectEqual(types.Selectable{ .npc_placement = 0 }, tile_group[1]);
}
