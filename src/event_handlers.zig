//! Event processing — the `processEvent` dispatch and its handler helpers.
//!
//! `processEvent` pops one event from `GameState.event_stack` and applies it
//! (a pure state transform), recording it into the session log when not
//! replaying. It is the single funnel through which all undoable gameplay
//! state mutates; the input handlers (input_handlers.zig) and the live game
//! loop (main.zig) call it, and state.zig's undo/redo/reconstruct machinery
//! receives it as an `apply_event` function pointer.
//!
//! Handler-internal helpers (entity accessors, gear mutators, move-highlight
//! refresh, prepared-skill cancel, AI min-range, tile tiebreak) live here too,
//! alongside the event-pushing utilities (`pushEvents`/`pushPlayerSkillUse`)
//! shared with the input handlers, and the pure editor click planners
//! (`planEditor*Actions`) shared by the editor handlers and the input-side
//! no-op gate (see DESIGN → Level Editor → Active-tool model).

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const functions = @import("functions.zig");
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");
const writers = @import("writers.zig");
const file_source_mod = @import("file_source.zig");
const lookups = @import("generated_lookups.zig");
const deep_copy = @import("deep_copy.zig");
const Skill = @import("skills/skill.zig").Skill;

const deepCopy = deep_copy.deepCopy;

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;
const Vector2 = types.Vector2;
const Entity = types.Entity;
const SkillId = types.SkillId;
const Level = types.Level;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const utility_skill_count = types.utility_skill_count;
const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;
const WeaponType = types.WeaponType;

// Real-time pause inserted between enemy turn actions (before moving, before
// each skill) so enemy turns don't resolve instantly. Not skippable — see the
// wait handling in update() (main.zig).
const turn_flow_wait_milliseconds: u32 = 500;

/// Sign of an i32: -1, 0, or 1. Used to normalize a position delta into a
/// unit direction (one of 8) for the damage-number anim's travel vector.
fn sign(value: i32) i32 {
    return if (value > 0) 1 else if (value < 0) @as(i32, -1) else 0;
}

/// Damage-number travel direction: the normalized attacker→defender delta
/// (one of 8), or top-right `{1, -1}` (same as heals) when the delta is
/// `{0,0}` — i.e. self-damage (attacker == defender, no direction away from
/// an attacker exists). The fallback avoids a divide-by-zero NaN in
/// `view.numberAnimPosition`'s unit-vector math. See AGENTS Animation.
fn damageNumberDirection(attacker_position: Vector2, defender_position: Vector2) Vector2 {
    const dx = sign(defender_position.x - attacker_position.x);
    const dy = sign(defender_position.y - attacker_position.y);
    if (dx == 0 and dy == 0) return .{ .x = 1, .y = -1 };
    return .{ .x = dx, .y = dy };
}

/// Duration of the damage/heal number one-shot anim (matches
/// `view.number_anim_duration_microseconds`). 500ms.
const number_anim_duration_microseconds: u32 = 500_000;

/// Duration of the aggro indicator one-shot anim. 500ms.
const aggro_indicator_duration_microseconds: u32 = 500_000;

/// Activate an entity (flip `is_active = true`) and queue the one-shot
/// aggro indicator above its head. Shared by `aggro_check` and
/// `aggro_in_radius` (Howl) so both paths show the graphic. Gated
/// `!replaying` (same as all anim/sound side effects). See DESIGN → Animation.
fn activateEntity(
    history: *GameStateHistory,
    entity: *types.Entity,
    entity_index: u32,
) void {
    entity.is_active = true;
    if (history.replaying) return;
    history.session.queueAnim(history.backing_allocator, .{
        .event_index = history.current_event_index - 1,
        .kind = .{ .aggro_indicator = .{ .entity_index = entity_index } },
        .duration_us = aggro_indicator_duration_microseconds,
    });
}

/// Compute the minimum effective range across all off-cooldown skills an entity
/// has — the closest distance it needs to be to use at least one skill. Uses
/// range if the skill has it, radius if not. Returns null if no skills are off
/// cooldown (shouldn't normally happen).
fn computeMinRange(
    entity: Entity,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
) ?u32 {
    const skill_ids = entity.collectSkillSlots(weapon_type_definitions);
    var min_range: ?u32 = null;

    for (&skill_ids) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (entity.skill_cooldowns.get(skill_id) > 0) continue;

        const skill_definition = lookups.getSkillDefinition(skill_id) orelse continue;

        // Self/no-target skills (no range and no radius) don't require closing
        // on the target, so they must not drag min_range down to 0 (which would
        // let the enemy path onto the target's own tile).
        const effective_range: u32 = blk: {
            if (skill_definition.range) |range| break :blk entity.getEffectiveRange(range);
            if (skill_definition.radius) |radius| break :blk entity.getEffectiveRadius(radius);
            continue;
        };

        if (min_range) |current_min| {
            if (effective_range < current_min) {
                min_range = effective_range;
            }
        } else {
            min_range = effective_range;
        }
    }

    return min_range;
}

/// Push the single orchestrator event for a player skill use. The handler
/// resolves whether the skill ends the turn (weapon_skill/spell) and composes
/// use_skill + clear_highlights + clear_prepared_skill (+ turn_end). Keeping
/// one event per action is what lets reconstruction derive idle points from
/// virtual stack depth (see reconstructFromEventLog in state.zig).
pub fn pushPlayerSkillUse(
    current: *GameState,
    skill_id: SkillId,
    target: ?Vector2,
    allocator: std.mem.Allocator,
) void {
    pushPlayerAction(current, .{ .player_use_skill = .{
        .skill_id = skill_id,
        .target = target,
    } }, allocator);
}

/// Push events onto the event stack. Events are processed from the back
/// (top of stack), so the last event pushed is processed first.
pub fn pushEvents(
    current: *GameState,
    new_events: []const Event,
    allocator: std.mem.Allocator,
) void {
    if (new_events.len == 0) return;

    if (current.event_stack.len == 0) {
        current.event_stack = allocator.dupe(
            Event,
            new_events,
        ) catch @panic("failed to allocate event stack");
        return;
    }

    const combined = allocator.alloc(
        Event,
        current.event_stack.len + new_events.len,
    ) catch @panic("failed to allocate event stack");

    @memcpy(combined[0..current.event_stack.len], current.event_stack);
    @memcpy(combined[current.event_stack.len..], new_events);
    current.event_stack = combined;
}

/// Push a player-input event (the ONLY kind input handlers may push — see
/// `PlayerInputEvent` in events.zig). This wrapper is the compile-time gate:
/// input handlers call this instead of `pushEvents`, so they can't push
/// machinery events. The handler for a `PlayerInputEvent` may push machinery
/// events as children via `pushEvents` (that's the orchestrator convention).
pub fn pushPlayerAction(
    current: *GameState,
    action: events.PlayerInputEvent,
    allocator: std.mem.Allocator,
) void {
    pushEvents(current, &.{.{ .player_input_event = action }}, allocator);
}

/// Push the gameplay start batch for a freshly-loaded level: player sync
/// (build_player_from_data, runs first) + per-entity aggro checks + the
/// player's turn_start (runs last). Shared by start_level (normal gameplay,
/// Set by a reconstruction-read handler when its config read or parse
/// fails during LIVE play. Sets the user-facing pending_error (the
/// descriptive `message`, duped into history_arena so it survives the
/// revert) + the `load_error` flag (the drain loop checks it and reverts).
/// During replay, panics instead (fail-fast — a reconstruction-read
/// failure during replay is unexpected; in-session replay has cached bytes,
/// cross-session replay of changed content is the known accepted fail-fast).
/// See DESIGN → Error Handling → three contexts.
fn failReconstructionRead(history: *GameStateHistory, message: []const u8) void {
    if (history.replaying) @panic("replay: reconstruction read failed (content changed?)");
    history.session.setPendingError(history.history_arena.allocator(), message);
    history.load_error = true;
}

/// Run key validation on `sections` and, if any unknown keys are found,
/// surface them as a pending_error popup. Advisory — the load continues
/// regardless (unknown keys are dropped, not fatal). Gated on !replaying
/// so undo/redo doesn't re-surface warnings from the recording. See AGENTS
/// → Error Handling → key validation.
fn validateConfigKeys(
    history: *GameStateHistory,
    sections: []const parser.Section,
    key_map: std.StaticStringMap([]const []const u8),
    file_path: []const u8,
    allocator: std.mem.Allocator,
) void {
    if (history.replaying) return;
    var key_warnings: std.ArrayList([]const u8) = .empty;
    parser.validateKeys(sections, key_map, file_path, allocator, &key_warnings);
    surfaceWarnings(history, &key_warnings, allocator);
}

/// Surface collected warnings (key-validation or balance-bound) as a single
/// `pending_error` popup. No-op when the list is empty or during replay.
fn surfaceWarnings(
    history: *GameStateHistory,
    warnings: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) void {
    if (history.replaying) return;
    if (warnings.items.len == 0) return;
    var message: std.ArrayList(u8) = .empty;
    for (warnings.items, 0..) |warning, index| {
        if (index > 0) message.appendSlice(allocator, "\n") catch
            @panic("failed to assemble warning message");
        message.appendSlice(allocator, warning) catch
            @panic("failed to assemble warning message");
    }
    history.session.setPendingError(history.history_arena.allocator(), message.items);
}

/// sync_player=true — the level's bare player entity gets its loadout from
/// PlayerData) and start_playtest / start_validation (editor, sync_player=
/// false — the player is already fully instantiated from editor.player_def,
/// so build_player_from_data would clobber it with the campaign's PlayerData).
fn pushGameplayStartEvents(current: *GameState, allocator: std.mem.Allocator, sync_player: bool) void {
    var start_events: std.ArrayList(Event) = .empty;
    // Player turn_start at bottom of LIFO (processed last, after sync + aggro).
    start_events.append(allocator, .{ .level_event = .{ .turn_start = .{
        .entity_index = 0,
    } } }) catch @panic("failed to append turn_start");
    // Aggro check: one event scans every inactive entity against its own
    // aggro_range. No `check_level_end` at level start — the player spawn
    // (`!`) and the level end (`=`) are always different tiles.
    start_events.append(allocator, .{ .sub_level_event = .{ .aggro_check = .{} } }) catch
        @panic("failed to append aggro_check event");
    // Player sync on top (processed first) — only for normal gameplay.
    if (sync_player) {
        start_events.append(allocator, .{ .super_event = .{ .build_player_from_data = .{
            .entity_index = 0,
        } } }) catch @panic("failed to append build_player_from_data");
    }
    pushEvents(current, start_events.items, allocator);
}

/// Handle an EditorEvent (the non-`editor_set_active_level` variants). Pure
/// state transform on `current.editor.?.levels[]` or the palette. Called from
/// the `.editor_event` arm of `processEvent`; the switch there dispatches the
/// one inline case and routes the rest here. Arms land incrementally with
/// the editor UI slices; unimplemented variants still panic so an unhooked
/// editor event fails fast rather than silently no-op'ing (which would let
/// the UI believe it edited something). The select tool's selection set
/// lives on the Editor (`Editor.selection`, on the undo timeline); the
/// placement-removal arms keep it consistent (prune the deleted entry,
/// remap the indices above it) in the same event, so undo/redo restores
/// the edit and its selection bookkeeping together.
fn handleEditorEvent(
    current: *GameState,
    event: events.EditorEvent,
    allocator: std.mem.Allocator,
) void {
    const editor = &(current.editor orelse @panic("editor event with no editor"));
    switch (event) {
        .editor_set_tool => |set| {
            // Defensive against crafted logs: a tool index outside its
            // palette is ignored (same posture as editor_set_active_level's
            // range check — validatePlayerAction rejects it at the replay
            // seam, the live path can't produce it).
            const tool_valid = switch (set.tool) {
                .select, .tile => true,
                .entity_type => |type_id| type_id < editor.entity_types.len,
                .decoration_type => |type_id| type_id < editor.decoration_types.len,
                .item_type => |type_id| type_id < editor.item_types.len,
            };
            if (!tool_valid) return;
            editor.active_tool = set.tool;
            // Invariant: selection nonempty ⇔ active tool is select — a
            // switch away from the select tool takes the selection with it
            // (same event, so one undo step reverts both).
            if (set.tool != .select) editor.selection = &.{};
        },
        .editor_toggle_inspector => {
            editor.inspector_open = !editor.inspector_open;
        },
        .editor_select => |select| {
            // Defensive against crafted logs: the select workflow only, and
            // placement entries must address the active level's lists (a
            // live plan can't violate either — validatePlayerAction rejects
            // the tool case at the replay seam).
            if (editor.active_tool != .select) return;
            const level = activeEditorLevel(editor) orelse return;
            const entry_valid = switch (select.entry) {
                .entity_placement => |index| index < level.entity_placements.len,
                .decoration_placement => |index| index < level.decoration_placements.len,
                .ground_item_placement => |index| index < level.item_placements.len,
                .tile, .player_start, .level_end => true,
            };
            if (!entry_valid) return;
            if (selectionContains(editor.selection, select.entry)) return;
            editor.selection = selectionWithEntry(editor.selection, select.entry, allocator);
        },
        .editor_deselect => |deselect| {
            if (editor.active_tool != .select) return;
            editor.selection = selectionWithoutEntry(editor.selection, deselect.entry, allocator);
        },
        .editor_clear_selection => {
            editor.selection = &.{};
        },
        .editor_set_tile => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_tile: level index out of range");
            }
            const level = &@constCast(editor.levels)[set.level_index];
            // A selected tile leaves the selection when the tile is
            // actually erased (an erase of an absent tile is an idempotent
            // no-op — nothing to prune). Gated on the erase targeting the
            // active level (selection entries are active-level-relative).
            if (!set.is_floor and
                set.level_index == editor.active_level_index and
                functions.tileListContains(level.level_tiles, set.position))
            {
                editor.selection = selectionWithoutTile(editor.selection, set.position, allocator);
            }
            level.level_tiles = setLevelTile(level.level_tiles, set.position, set.is_floor, allocator);
        },
        .editor_delete_decoration_placement => |delete| {
            if (delete.level_index >= editor.levels.len) {
                @panic("editor_delete_decoration_placement: level index out of range");
            }
            const level = &@constCast(editor.levels)[delete.level_index];
            if (delete.placement_index >= level.decoration_placements.len) {
                @panic("editor_delete_decoration_placement: placement index out of range");
            }
            var placements = allocator.alloc(
                types.DecorationPlacement,
                level.decoration_placements.len - 1,
            ) catch @panic("failed to allocate decoration placements");
            // Order-preserving removal — placement indices are the identity
            // the move/delete events address, so reordering would corrupt
            // them (the orchestrator deletes high-before-low for exactly
            // this reason).
            @memcpy(
                placements[0..delete.placement_index],
                level.decoration_placements[0..delete.placement_index],
            );
            @memcpy(
                placements[delete.placement_index..],
                level.decoration_placements[delete.placement_index + 1 ..],
            );
            level.decoration_placements = placements;
            if (delete.level_index == editor.active_level_index) {
                editor.selection = reconcileSelectionAfterPlacementDelete(
                    editor.selection,
                    .decoration_placement,
                    delete.placement_index,
                    allocator,
                );
            }
        },
        .editor_place_entity => |place| {
            if (place.level_index >= editor.levels.len) {
                @panic("editor_place_entity: level index out of range");
            }
            const level = &@constCast(editor.levels)[place.level_index];
            // One thing per placed tile (see the placement-tools bullet in
            // DESIGN → Level Editor → Active-tool model): a placement never
            // lands on a tile that already carries an entity or item. The
            // click orchestrator clears occupants first, so reaching here
            // occupied is a logic bug — fail fast.
            for (level.entity_placements) |placement| {
                if (placement.position.x == place.position.x and
                    placement.position.y == place.position.y)
                {
                    @panic("editor_place_entity onto a tile that already has an entity");
                }
            }
            for (level.item_placements) |placement| {
                if (placement.position.x == place.position.x and
                    placement.position.y == place.position.y)
                {
                    @panic("editor_place_entity onto a tile that already has a ground item");
                }
            }
            var placements = allocator.alloc(
                types.EntityPlacement,
                level.entity_placements.len + 1,
            ) catch @panic("failed to allocate entity placements");
            @memcpy(placements[0..level.entity_placements.len], level.entity_placements);
            placements[level.entity_placements.len] = .{
                .type_id = place.type_id,
                .position = place.position,
            };
            level.entity_placements = placements;
        },
        .editor_set_entity_placement_type => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_entity_placement_type: level index out of range");
            }
            const level = &@constCast(editor.levels)[set.level_index];
            if (set.placement_index >= level.entity_placements.len) {
                @panic("editor_set_entity_placement_type: placement index out of range");
            }
            // In-place retype: identity (index) + position stay stable, so
            // nothing referencing the placement shifts.
            @constCast(level.entity_placements)[set.placement_index].type_id = set.type_id;
        },
        .editor_delete_item_placement => |delete| {
            if (delete.level_index >= editor.levels.len) {
                @panic("editor_delete_item_placement: level index out of range");
            }
            const level = &@constCast(editor.levels)[delete.level_index];
            if (delete.placement_index >= level.item_placements.len) {
                @panic("editor_delete_item_placement: placement index out of range");
            }
            var placements = allocator.alloc(
                types.ItemPlacement,
                level.item_placements.len - 1,
            ) catch @panic("failed to allocate item placements");
            // Order-preserving removal (same reasoning as the decoration
            // delete — indices are the identity the move/delete events
            // address).
            @memcpy(
                placements[0..delete.placement_index],
                level.item_placements[0..delete.placement_index],
            );
            @memcpy(
                placements[delete.placement_index..],
                level.item_placements[delete.placement_index + 1 ..],
            );
            level.item_placements = placements;
            if (delete.level_index == editor.active_level_index) {
                editor.selection = reconcileSelectionAfterPlacementDelete(
                    editor.selection,
                    .ground_item_placement,
                    delete.placement_index,
                    allocator,
                );
            }
        },
        .editor_delete_entity_placement => |delete| {
            if (delete.level_index >= editor.levels.len) {
                @panic("editor_delete_entity_placement: level index out of range");
            }
            const level = &@constCast(editor.levels)[delete.level_index];
            if (delete.placement_index >= level.entity_placements.len) {
                @panic("editor_delete_entity_placement: placement index out of range");
            }
            var placements = allocator.alloc(
                types.EntityPlacement,
                level.entity_placements.len - 1,
            ) catch @panic("failed to allocate entity placements");
            // Order-preserving removal (indices are the identity the
            // move/delete/retype events address).
            @memcpy(
                placements[0..delete.placement_index],
                level.entity_placements[0..delete.placement_index],
            );
            @memcpy(
                placements[delete.placement_index..],
                level.entity_placements[delete.placement_index + 1 ..],
            );
            level.entity_placements = placements;
            if (delete.level_index == editor.active_level_index) {
                editor.selection = reconcileSelectionAfterPlacementDelete(
                    editor.selection,
                    .entity_placement,
                    delete.placement_index,
                    allocator,
                );
            }
        },
        .editor_place_decoration => |place| {
            if (place.level_index >= editor.levels.len) {
                @panic("editor_place_decoration: level index out of range");
            }
            if (place.type_id >= editor.decoration_types.len) {
                @panic("editor_place_decoration: type id out of range");
            }
            const level = &@constCast(editor.levels)[place.level_index];
            const footprint_tiles = loaders.decorationFootprintWorldTiles(
                editor.decoration_types[place.type_id].footprint,
                place.position,
                allocator,
            );
            // A decoration's footprint tiles are EXCLUSIVE — no level tile,
            // no entity / item placement, no other decoration's footprint
            // under any of them (the parse-time placement invariant, now
            // enforced at the placement event; the click orchestrator
            // clears occupants first, so reaching here occupied is a logic
            // bug — fail fast). See DESIGN → Decorations & Footprint →
            // Placement invariant.
            for (footprint_tiles) |tile| {
                if (functions.tileListContains(level.level_tiles, tile)) {
                    @panic("editor_place_decoration onto a tile");
                }
                for (level.entity_placements) |placement| {
                    if (placement.position.x == tile.x and placement.position.y == tile.y) {
                        @panic("editor_place_decoration onto an entity placement");
                    }
                }
                for (level.item_placements) |placement| {
                    if (placement.position.x == tile.x and placement.position.y == tile.y) {
                        @panic("editor_place_decoration onto an item placement");
                    }
                }
            }
            for (level.decoration_placements) |placement| {
                const other_definition = editor.decoration_types[placement.type_id];
                for (footprint_tiles) |tile| {
                    if (loaders.decorationFootprintCovers(other_definition.footprint, placement.position, tile, allocator)) {
                        @panic("editor_place_decoration onto another decoration's footprint");
                    }
                }
            }
            var placements = allocator.alloc(
                types.DecorationPlacement,
                level.decoration_placements.len + 1,
            ) catch @panic("failed to allocate decoration placements");
            @memcpy(placements[0..level.decoration_placements.len], level.decoration_placements);
            placements[level.decoration_placements.len] = .{
                .type_id = place.type_id,
                .position = place.position,
            };
            level.decoration_placements = placements;
        },
        .editor_place_item => |place| {
            if (place.level_index >= editor.levels.len) {
                @panic("editor_place_item: level index out of range");
            }
            const level = &@constCast(editor.levels)[place.level_index];
            // One thing per placed tile (see `editor_place_entity`): an
            // item never lands on a tile that already carries an entity or
            // item placement. The click orchestrator clears occupants
            // first, so reaching here occupied is a logic bug — fail fast.
            for (level.entity_placements) |placement| {
                if (placement.position.x == place.position.x and
                    placement.position.y == place.position.y)
                {
                    @panic("editor_place_item onto a tile that already has an entity");
                }
            }
            for (level.item_placements) |placement| {
                if (placement.position.x == place.position.x and
                    placement.position.y == place.position.y)
                {
                    @panic("editor_place_item onto a tile that already has a ground item");
                }
            }
            var placements = allocator.alloc(
                types.ItemPlacement,
                level.item_placements.len + 1,
            ) catch @panic("failed to allocate item placements");
            @memcpy(placements[0..level.item_placements.len], level.item_placements);
            placements[level.item_placements.len] = .{
                .type_id = place.type_id,
                .position = place.position,
            };
            level.item_placements = placements;
        },
        .editor_set_item_placement_type => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_item_placement_type: level index out of range");
            }
            const level = &@constCast(editor.levels)[set.level_index];
            if (set.placement_index >= level.item_placements.len) {
                @panic("editor_set_item_placement_type: placement index out of range");
            }
            // In-place retype: identity (index) + position stay stable, so
            // nothing referencing the placement shifts.
            @constCast(level.item_placements)[set.placement_index].type_id = set.type_id;
        },
        .editor_set_player_start => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_player_start: level index out of range");
            }
            @constCast(editor.levels)[set.level_index].player_start = set.position;
        },
        .editor_set_level_end => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_level_end: level index out of range");
            }
            @constCast(editor.levels)[set.level_index].level_end = set.position;
        },
        .editor_commit_selection_move => |commit| {
            // Final link: the worklist is exhausted — a move deselects
            // (nothing is reselected; the clear phase's reconcile already
            // pruned the deleted entries, this drops the rest).
            if (commit.next_index >= commit.entries.len) {
                editor.selection = &.{};
                return;
            }
            const entry = commit.entries[commit.next_index];

            // Plan THIS entry against the live post-clear state — the
            // placement planners are the current placement rules (a
            // marker target plans empty, so that thing was deleted fully
            // in the clear phase and simply doesn't place). Type ids from
            // a crafted worklist are skipped defensively (the live path
            // derives them from real placements, and the clear phase
            // never deletes palette types).
            var plan: std.ArrayList(Event) = .empty;
            switch (entry) {
                .entity => |move_entry| {
                    if (move_entry.type_id < editor.entity_types.len) {
                        plan.appendSlice(
                            allocator,
                            planEditorEntityPlacementActions(editor, move_entry.type_id, move_entry.position, allocator),
                        ) catch @panic("failed to allocate editor selection move plan");
                    }
                },
                .decoration => |move_entry| {
                    if (move_entry.type_id < editor.decoration_types.len) {
                        plan.appendSlice(
                            allocator,
                            planEditorDecorationPlacementActions(editor, move_entry.type_id, move_entry.position, allocator),
                        ) catch @panic("failed to allocate editor selection move plan");
                    }
                },
                .item => |move_entry| {
                    if (move_entry.type_id < editor.item_types.len) {
                        plan.appendSlice(
                            allocator,
                            planEditorItemPlacementActions(editor, move_entry.type_id, move_entry.position, allocator),
                        ) catch @panic("failed to allocate editor selection move plan");
                    }
                },
                .tile => |position| {
                    plan.appendSlice(
                        allocator,
                        planEditorTilePaintActions(editor, position, allocator),
                    ) catch @panic("failed to allocate editor selection move plan");
                },
                .player_start, .level_end => |position| {
                    // A tile is ensured under the moved marker (paint = the
                    // current replacement rules), then the marker moves.
                    plan.appendSlice(
                        allocator,
                        planEditorTilePaintActions(editor, position, allocator),
                    ) catch @panic("failed to allocate editor selection move plan");
                    const marker_variant: events.EditorEvent = if (entry == .player_start)
                        .{ .editor_set_player_start = .{
                            .level_index = @intCast(editor.active_level_index),
                            .position = position,
                        } }
                    else
                        .{ .editor_set_level_end = .{
                            .level_index = @intCast(editor.active_level_index),
                            .position = position,
                        } };
                    plan.append(allocator, .{ .editor_event = marker_variant }) catch
                        @panic("failed to allocate editor selection move plan");
                },
            }

            // Push [next link, …plan] — LIFO runs this entry's plan first,
            // then the next link plans the following entry against the
            // result (the chain exists precisely so each entry sees the
            // fully-processed state; see the event's doc in events.zig).
            var push: std.ArrayList(Event) = .empty;
            push.append(allocator, .{ .editor_event = .{ .editor_commit_selection_move = .{
                .entries = commit.entries,
                .next_index = commit.next_index + 1,
            } } }) catch @panic("failed to allocate editor selection move plan");
            push.appendSlice(allocator, plan.items) catch
                @panic("failed to allocate editor selection move plan");
            pushEvents(current, push.items, allocator);
        },
        else => @panic("editor event handler not implemented"),
    }
}

/// Set or erase one tile in a level's tile list, returning the new list.
/// Idempotent: painting an existing tile / erasing an absent one returns
/// the input unchanged. Inserts keep `tileBefore` (row-major) order so the
/// list stays canonical with the parser's layout-scan order.
fn setLevelTile(
    tiles: []const Vector2,
    position: Vector2,
    is_floor: bool,
    allocator: std.mem.Allocator,
) []const Vector2 {
    if (is_floor) {
        for (tiles) |tile| {
            if (tile.x == position.x and tile.y == position.y) return tiles;
        }
        var new_tiles = allocator.alloc(Vector2, tiles.len + 1) catch
            @panic("failed to allocate level tiles");
        var insert_index: usize = tiles.len;
        for (tiles, 0..) |tile, index| {
            if (!tileBefore(tile, position)) {
                insert_index = index;
                break;
            }
        }
        @memcpy(new_tiles[0..insert_index], tiles[0..insert_index]);
        new_tiles[insert_index] = position;
        @memcpy(new_tiles[insert_index + 1 ..], tiles[insert_index..]);
        return new_tiles;
    }
    for (tiles, 0..) |tile, index| {
        if (tile.x == position.x and tile.y == position.y) {
            var new_tiles = allocator.alloc(Vector2, tiles.len - 1) catch
                @panic("failed to allocate level tiles");
            @memcpy(new_tiles[0..index], tiles[0..index]);
            @memcpy(new_tiles[index..], tiles[index + 1 ..]);
            return new_tiles;
        }
    }
    return tiles;
}

fn tileBefore(a: Vector2, b: Vector2) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.y < b.y;
}

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

fn selectionContains(items: []const types.Selectable, entry: types.Selectable) bool {
    for (items) |existing| {
        if (selectableEqual(existing, entry)) return true;
    }
    return false;
}

/// The selection with `entry` appended (a fresh slice — `Editor.selection`
/// is replaced wholesale, never mutated in place, so deepCopy snapshots
/// stay sound).
fn selectionWithEntry(
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
/// slice when absent — a deselect of a non-selected entry is an
/// idempotent no-op).
fn selectionWithoutEntry(
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

/// Keep the select tool's selection consistent after a placement removal:
/// drop the deleted entry and DECREMENT the selected indices above it — a
/// removal shifts later placements down, so without the remap the
/// surviving entries would point at the WRONG placements (skipping only
/// out-of-range entries isn't enough). `kind` selects which placement
/// list the indices refer to; entries of other kinds are untouched.
/// Callers gate on the removal targeting the ACTIVE level (selection
/// entries are active-level-relative). Returns the original slice when no
/// entry of `kind` is present.
fn reconcileSelectionAfterPlacementDelete(
    selection: []const types.Selectable,
    kind: std.meta.Tag(types.Selectable),
    removed_index: u32,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    var has_relevant = false;
    for (selection) |selected| {
        if (std.meta.activeTag(selected) == kind) {
            has_relevant = true;
            break;
        }
    }
    if (!has_relevant) return selection;

    const rebuilt = allocator.alloc(types.Selectable, selection.len) catch
        @panic("failed to allocate editor selection");
    var length: usize = 0;
    for (selection) |selected| {
        const relevant: ?u32 = switch (selected) {
            .entity_placement => |value| if (kind == .entity_placement) value else null,
            .decoration_placement => |value| if (kind == .decoration_placement) value else null,
            .ground_item_placement => |value| if (kind == .ground_item_placement) value else null,
            else => null,
        };
        if (relevant) |value| {
            if (value == removed_index) continue;
            if (value > removed_index) {
                switch (selected) {
                    .entity_placement => |shifted| rebuilt[length] = .{ .entity_placement = shifted - 1 },
                    .decoration_placement => |shifted| rebuilt[length] = .{ .decoration_placement = shifted - 1 },
                    .ground_item_placement => |shifted| rebuilt[length] = .{ .ground_item_placement = shifted - 1 },
                    else => unreachable,
                }
                length += 1;
                continue;
            }
        }
        rebuilt[length] = selected;
        length += 1;
    }
    return rebuilt[0..length];
}

/// The selection without its tile entry at `position` (a tile entry is
/// position-keyed, not index-keyed — nothing to remap; other kinds pass
/// through). Returns the original slice when no such entry exists.
fn selectionWithoutTile(
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

/// Get a mutable pointer to the player entity, whether in a level or hub.
fn getPlayerEntity(
    current: *GameState,
    entity_index: u32,
) *Entity {
    if (current.level) |*level| {
        return &@constCast(level.entities)[entity_index];
    } else if (current.hub) |*hub| {
        return &hub.player;
    }
    @panic("getPlayerEntity called with no level or hub");
}

/// Recompute the reachable tiles shown during the player's move step.
/// No-op unless we're in a level and currently in the .player_move phase
/// (e.g. changing boots in the hub or during the attack step should not
/// touch highlighted_tiles).
fn refreshMoveHighlights(
    current: *GameState,
    allocator: std.mem.Allocator,
) void {
    const level = if (current.level) |*level| level else return;
    if (level.turn_phase != .player_move) return;

    const player = level.entities[0];
    level.highlighted_tiles = functions.reachableTiles(
        level.*,
        player.position,
        player.getEffectiveSpeed(),
        allocator,
    );
}

/// Cancel any in-progress skill targeting during the player's attack step.
/// No-op unless we're in a level with a prepared skill. Call this whenever
/// the player's available skills change mid-attack-step (swapping or equipping
/// weapons rewrites the first three skill slots), so a skill prepared from the
/// old weapon does not linger with stale targeting highlights.
fn cancelPreparedSkill(current: *GameState) void {
    const level = if (current.level) |*level| level else return;
    if (level.prepared_skill == null) return;

    level.prepared_skill = null;
    level.highlighted_tiles = &.{};
}

/// Return the piece currently in a gear slot as an Item, or null if empty.
/// The occupied inventory slot indices inside a salvage region (two
/// opposite-corner slot indices, order-independent). Shared by the
/// `player_salvage_inventory_region` handler (one salvage_item per slot)
/// and the input-side no-op gate (an all-empty region never fires) — one
/// definition of the region's slots so the two can't drift.
pub fn salvageRegionOccupiedSlots(
    player: types.Entity,
    start_slot: u32,
    end_slot: u32,
    allocator: std.mem.Allocator,
) []const u32 {
    const start_row = @divTrunc(start_slot, types.inventory_columns);
    const start_col = @rem(start_slot, types.inventory_columns);
    const end_row = @divTrunc(end_slot, types.inventory_columns);
    const end_col = @rem(end_slot, types.inventory_columns);
    const min_row = @min(start_row, end_row);
    const max_row = @max(start_row, end_row);
    const min_col = @min(start_col, end_col);
    const max_col = @max(start_col, end_col);
    var occupied: std.ArrayList(u32) = .empty;
    var row: u32 = min_row;
    while (row <= max_row) : (row += 1) {
        var col: u32 = min_col;
        while (col <= max_col) : (col += 1) {
            const slot_index = row * types.inventory_columns + col;
            if (player.inventory.slots[slot_index] != null) {
                occupied.append(allocator, slot_index) catch
                    @panic("failed to allocate salvage region slots");
            }
        }
    }
    return occupied.items;
}

fn gearSlotItem(player: *Entity, gear_slot: types.GearSlot) ?types.Item {
    return switch (gear_slot) {
        .main_hand => if (player.main_hand_weapon) |weapon| .{ .weapon = weapon } else null,
        .off_hand => if (player.off_hand_weapon) |weapon| .{ .weapon = weapon } else null,
        .amulet => if (player.amulet) |amulet| .{ .amulet = amulet } else null,
        .coat => if (player.coat) |coat| .{ .coat = coat } else null,
        .gloves => if (player.gloves) |gloves| .{ .gloves = gloves } else null,
        .pants => if (player.pants) |pants| .{ .pants = pants } else null,
        .boots => if (player.boots) |boots| .{ .boots = boots } else null,
    };
}

/// Whether an inventory item can be equipped into the given gear slot.
/// Whether `item` can go into `gear_slot`. Shared by the equip/unequip
/// machinery here and the input-side drag no-op gate (input_handlers)
/// so "fits" has one definition and the two can't drift.
pub fn itemFitsGearSlot(item: types.Item, gear_slot: types.GearSlot) bool {
    return switch (gear_slot) {
        .main_hand, .off_hand => item == .weapon,
        .amulet => item == .amulet,
        .coat => item == .coat,
        .gloves => item == .gloves,
        .pants => item == .pants,
        .boots => item == .boots,
    };
}

/// Write an item into a gear slot. The caller must ensure the item fits the
/// slot (see itemFitsGearSlot); the union access panics otherwise.
fn setGearSlot(player: *Entity, gear_slot: types.GearSlot, item: types.Item) void {
    switch (gear_slot) {
        .main_hand => player.main_hand_weapon = item.weapon,
        .off_hand => player.off_hand_weapon = item.weapon,
        .amulet => player.amulet = item.amulet,
        .coat => player.coat = item.coat,
        .gloves => player.gloves = item.gloves,
        .pants => player.pants = item.pants,
        .boots => player.boots = item.boots,
    }
}

/// Empty a gear slot.
fn clearGearSlot(player: *Entity, gear_slot: types.GearSlot) void {
    switch (gear_slot) {
        .main_hand => player.main_hand_weapon = null,
        .off_hand => player.off_hand_weapon = null,
        .amulet => player.amulet = null,
        .coat => player.coat = null,
        .gloves => player.gloves = null,
        .pants => player.pants = null,
        .boots => player.boots = null,
    }
}

/// Re-apply the mid-turn side effects of a gear change: weapons rewrite the
/// first three skills (cancel targeting), boots change speed (refresh range).
fn applyGearChangeSideEffects(
    current: *GameState,
    gear_slot: types.GearSlot,
    allocator: std.mem.Allocator,
) void {
    const player = getPlayerEntity(current, 0);
    // Gear may change effective max health (coat/gloves/pants/boots carry
    // health_bonus). Clamp current_health to the new cap so the invariant
    // current_health ≤ getEffectiveMaxHealth() holds. Equipping a +health
    // piece raises the cap without healing (current stays, more headroom);
    // unequipping drops current to the new cap if it was above.
    player.current_health = @min(player.current_health, player.getEffectiveMaxHealth());
    switch (gear_slot) {
        .main_hand, .off_hand => cancelPreparedSkill(current),
        .boots => refreshMoveHighlights(current, allocator),
        else => {},
    }
}

/// Set the incoming weapon's three skill cooldowns to `@max(old, new)` so
/// equipping a fresh weapon can't bypass a cooldown that was ticking on the
/// displaced weapon's skills. Runs for all three skills regardless of which
/// hand holds the weapon — the hidden skill's cd surfaces later if the player
/// `swap_hands`. Both old+new cds are snapshotted before any `set` so a
/// degenerate SkillId overlap between weapon types can't double-decrement.
/// See DESIGN → Architecture (Cooldown inheritance on skill/weapon swap).
fn transferWeaponCooldowns(
    player: *Entity,
    old_weapon: ?types.Weapon,
    new_weapon: ?types.Weapon,
    weapon_type_definitions: *const [weapon_type_count]types.WeaponTypeDefinition,
) void {
    const new_w = new_weapon orelse return;
    const new_def = &weapon_type_definitions[@intFromEnum(new_w.weapon_type)];
    const new_skills = [_]types.SkillId{ new_def.skill_1, new_def.skill_2, new_def.skill_3 };

    const old_skills: [3]?types.SkillId = if (old_weapon) |old_w| blk: {
        const old_def = &weapon_type_definitions[@intFromEnum(old_w.weapon_type)];
        break :blk .{ old_def.skill_1, old_def.skill_2, old_def.skill_3 };
    } else .{ null, null, null };

    // Snapshot every cooldown before any mutation so a degenerate SkillId
    // overlap between old and new weapon types can't double-decrement.
    var new_cds: [3]u32 = undefined;
    var old_cds: [3]u32 = undefined;
    for (&new_cds, &old_cds, new_skills, old_skills) |*new_cd, *old_cd, new_skill, old_skill| {
        new_cd.* = player.skill_cooldowns.get(new_skill);
        old_cd.* = if (old_skill) |s| player.skill_cooldowns.get(s) else 0;
    }
    // Pair positionally: new skill_i inherits the max of old skill_i and
    // new skill_i. No old weapon → old cd is 0 → new cd is preserved as-is.
    for (new_cds, old_cds, new_skills) |new_cd, old_cd, new_skill| {
        player.skill_cooldowns.set(new_skill, @max(old_cd, new_cd));
    }
}

/// Get a mutable pointer to an entity in the current level.
fn getLevelEntity(
    current: *GameState,
    entity_index: u32,
) *Entity {
    if (current.level) |*level| {
        return &@constCast(level.entities)[entity_index];
    }
    @panic("getLevelEntity called with no level");
}

/// Compare a just-completed run against an existing clone, per-material, on
/// the per-turn rate (materials / turns). Pareto-strict: the new run is
/// "strictly better" when its rate is `>=` the old rate for ALL materials
/// AND `>` for at least one nonzero material. Tied-zero materials (a
/// mission that gives no cloth in either run) don't block the comparison.
/// Both turns values must be > 0 (the caller gates on that — see end_level).
/// See DESIGN → Clones (clone system).
pub fn cloneIsStrictlyBetter(
    new_turns: u32,
    new_materials: types.Materials,
    old_turns: u32,
    old_materials: types.Materials,
) bool {
    const fields = .{
        .{ new_materials.wood, old_materials.wood },
        .{ new_materials.metal, old_materials.metal },
        .{ new_materials.leather, old_materials.leather },
        .{ new_materials.cloth, old_materials.cloth },
        .{ new_materials.knowledge, old_materials.knowledge },
    };
    var has_strict_gain = false;
    inline for (fields) |pair| {
        const new_rate = pair[0] / new_turns;
        const old_rate = pair[1] / old_turns;
        if (new_rate < old_rate) return false;
        if (new_rate > old_rate) has_strict_gain = true;
    }
    return has_strict_gain;
}

/// Pointer to the current mission, or null if the acting entity isn't the
/// player (entity_index 0) or no mission is active. Shared by the per-event
/// accumulators (tiles_moved, skills_used, damage_dealt/taken, converted
/// materials) so they're one-liners at each call site. See DESIGN → Clones
/// (clone system).
fn playerMissionPtr(current: *GameState) ?*types.Mission {
    if (current.mission) |*mission| return mission;
    return null;
}

/// Pure harvest payout: per material, `(materials_collected * turns_spent)
/// / turns_to_complete` summed over all clones. The multiply happens BEFORE
/// the divide so a clone whose per-turn rate is fractional (materials <
/// turns_to_complete) still pays out — dividing first truncates the rate to
/// 0 and yields nothing. u64 intermediate guards the multiply against u32
/// overflow. Skips clones with `turns_to_complete == 0`. Shared by the
/// `harvest_clones` handler and the `end_level` completion branch (which
/// snapshots the payout onto `MissionCompleteInfo` for the overlay). See
/// DESIGN → Clones (clone system).
pub fn computeHarvest(clones: []const types.Clone, turns_spent: u32) types.Materials {
    if (turns_spent == 0) return .{};
    var payout: types.Materials = .{};
    const t: u64 = turns_spent;
    for (clones) |clone| {
        if (clone.turns_to_complete == 0) continue;
        const d: u64 = clone.turns_to_complete;
        payout.wood += @intCast((@as(u64, clone.materials_collected.wood) * t) / d);
        payout.metal += @intCast((@as(u64, clone.materials_collected.metal) * t) / d);
        payout.leather += @intCast((@as(u64, clone.materials_collected.leather) * t) / d);
        payout.cloth += @intCast((@as(u64, clone.materials_collected.cloth) * t) / d);
        payout.knowledge += @intCast((@as(u64, clone.materials_collected.knowledge) * t) / d);
    }
    return payout;
}

/// event for player_data.current_hub.
fn loadCampaignAndPushHub(
    current: *GameState,
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
) void {
    // Build campaign file path: data/campaigns/{campaign_id}/campaign.txt
    const campaign_path = std.fmt.allocPrint(
        allocator,
        "data/campaigns/{s}/campaign.txt",
        .{current.player_data.current_campaign},
    ) catch @panic("failed to allocate campaign path");

    const campaign_sections = blk: {
        const bytes = history.readReconstructionFile(campaign_path) catch {
            failReconstructionRead(history, "failed to read campaign file");
            return;
        };
        break :blk parser.parseConfigFile(bytes, allocator) catch {
            failReconstructionRead(history, "failed to parse campaign file");
            return;
        };
    };
    validateConfigKeys(history, campaign_sections, parser.campaign_key_map, campaign_path, allocator);
    current.campaign = loaders.loadCampaign(
        campaign_sections,
        allocator,
    ) catch {
        failReconstructionRead(history, "failed to parse campaign file");
        return;
    };

    // Push start_hub with the player's current hub
    const hub_id = current.player_data.current_hub;
    pushEvents(current, &.{.{ .meta_event = .{ .start_hub = .{
        .hub_id = hub_id,
    } } }}, allocator);
}

/// Process a single event from the stack. Applies the event to the current

/// Handle a `PlayerInputEvent` — the handler for the `.player_input_event`
/// arm in `processEvent`. Each variant is a player-initiated action (keybind
/// or click). Simple variants do inline work; orchestrator variants push
/// machinery events as children via `pushEvents`. See `PlayerInputEvent` in
/// events.zig + DESIGN → Determinism & Tiebreaking → Replay PLAYER-ACTION
/// LEGALITY.
fn handlePlayerInputEvent(
    history: *GameStateHistory,
    current: *GameState,
    pi: events.PlayerInputEvent,
    allocator: std.mem.Allocator,
) void {
    switch (pi) {
        // --- Meta: overlay dismiss ---
        .dismiss_mission_complete => {
            current.last_completed_mission = null;
        },

        // --- Meta: continue (main-menu Continue button) ---
        // Two branches by PlayerData state. Populated (the mid-session
        // exit-to-menu case) → resume directly from in-memory data, no file
        // read. Empty (the fresh-launch case) → load the autosave first, then
        // loadCampaignAndPushHub resumes at player_data.current_hub. See
        // DESIGN → File System & IO (autosave).
        .player_continue => {
            if (current.player_data.current_campaign.len > 0) {
                loadCampaignAndPushHub(current, history, allocator);
                if (history.load_error) return;
            } else {
                pushEvents(current, &.{.{ .meta_event = .{ .load_save = .{
                    .save_path = writers.autosave_path,
                } } }}, allocator);
            }
        },

        // --- Meta: load a save from the load-save browser ---
        // Thin orchestrator: the browser's acquisition (scan/pick) happened
        // in idle input; here we just feed the resident path to the normal
        // load path (read → parse → load → resume at the save's hub). A
        // corrupt/missing file fails inside `load_save` recoverably (popup +
        // revert) — the browser stays open for another pick.
        .player_load_save => |load| {
            pushEvents(current, &.{.{ .meta_event = .{ .load_save = .{
                .save_path = load.save_path,
            } } }}, allocator);
        },

        // --- Meta: new game ---
        .start_new_game => {
            var balance_warnings: std.ArrayList([]const u8) = .empty;
            const parsed_sections = blk: {
                const bytes = history.readReconstructionFile("data/new_player.txt") catch {
                    failReconstructionRead(history, "failed to read new_player.txt");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator) catch {
                    failReconstructionRead(history, "failed to parse new_player.txt");
                    return;
                };
            };
            validateConfigKeys(history, parsed_sections, parser.player_save_key_map, "data/new_player.txt", allocator);
            current.player_data = loaders.loadPlayerSave(
                parsed_sections,
                allocator,
                "data/new_player.txt",
                &balance_warnings,
            ) catch {
                failReconstructionRead(history, "failed to parse new_player.txt");
                return;
            };
            surfaceWarnings(history, &balance_warnings, allocator);
            loadCampaignAndPushHub(current, history, allocator);
            if (history.load_error) return;
            // Push backup_autosave AFTER loadCampaignAndPushHub so it lands
            // ON TOP of start_hub (LIFO → runs first). If it were pushed
            // before, start_hub would run first and its transitionScreen(.hub)
            // would clear the event stack, wiping backup_autosave before it
            // runs. The backup reads the autosave file (independent of
            // GameState), so running before start_hub is correct. See DESIGN
            // → File System & IO (Autosave).
            pushEvents(current, &.{.{ .meta_event = .backup_autosave }}, allocator);
        },

        // --- Meta: save ---
        // Writes a timestamped save AND updates the autosave. Both write_save
        // events read the synced PlayerData (build_data_from_player runs first
        // via LIFO). The autosave is the recovery path for a player who saves
        // mid-mission then quits: without it, Continue would resume at the
        // last hub transition and lose any loot picked up since. See DESIGN →
        // File System & IO (autosave).
        .save_game => |save| {
            if (current.level != null or current.hub != null) {
                pushEvents(current, &.{
                    .{ .meta_event = .{ .write_save = .{ .save_path = writers.autosave_path } } },
                    .{ .meta_event = .{ .write_save = .{ .save_path = save.save_path } } },
                    .{ .super_event = .{ .build_data_from_player = .{ .entity_index = 0 } } },
                }, allocator);
            } else {
                pushEvents(current, &.{
                    .{ .meta_event = .{ .write_save = .{ .save_path = writers.autosave_path } } },
                    .{ .meta_event = .{ .write_save = .{ .save_path = save.save_path } } },
                }, allocator);
            }
        },

        // --- Meta: open editor ---
        .open_editor => |start| {
            var balance_warnings: std.ArrayList([]const u8) = .empty;
            const mission_file_path = std.fmt.allocPrint(
                allocator,
                "{s}/mission.txt",
                .{start.mission_path},
            ) catch @panic("failed to allocate mission path");
            const mission_sections = blk: {
                const bytes = history.readReconstructionFile(mission_file_path) catch {
                    failReconstructionRead(history, "failed to read mission file");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator) catch {
                    failReconstructionRead(history, "failed to parse mission file");
                    return;
                };
            };
            validateConfigKeys(history, mission_sections, parser.mission_key_map, mission_file_path, allocator);
            const mission = loaders.loadMission(
                mission_sections,
                allocator,
            ) catch {
                failReconstructionRead(history, "failed to parse mission file");
                return;
            };
            const player_file_path = std.fmt.allocPrint(
                allocator,
                "{s}/player.txt",
                .{start.mission_path},
            ) catch @panic("failed to allocate player path");
            const player_sections = blk: {
                const bytes = history.readReconstructionFile(player_file_path) catch {
                    failReconstructionRead(history, "failed to read player.txt");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator) catch {
                    failReconstructionRead(history, "failed to parse player.txt");
                    return;
                };
            };
            validateConfigKeys(history, player_sections, parser.player_loadout_key_map, player_file_path, allocator);
            const player_entity = loaders.loadPlayerLoadout(player_sections, allocator, player_file_path, &balance_warnings) catch {
                failReconstructionRead(history, "failed to parse player.txt");
                return;
            };
            var level_sections: std.ArrayList([]const parser.Section) = .empty;
            var level_index: u32 = 1;
            while (level_index <= mission.level_count) : (level_index += 1) {
                const level_path = std.fmt.allocPrint(
                    allocator,
                    "{s}/level_{d}.txt",
                    .{ start.mission_path, level_index },
                ) catch @panic("failed to allocate level path");
                const sections = blk: {
                    const bytes = history.readReconstructionFile(level_path) catch {
                        failReconstructionRead(history, "failed to read level file");
                        return;
                    };
                    break :blk parser.parseConfigFile(bytes, allocator) catch {
                        failReconstructionRead(history, "failed to parse level file");
                        return;
                    };
                };
                validateConfigKeys(history, sections, parser.level_key_map, level_path, allocator);
                level_sections.append(allocator, sections) catch @panic("failed to append level sections");
            }
            current.editor = loaders.buildEditorMission(
                mission,
                player_entity,
                level_sections.items,
                history.file_source,
                allocator,
                start.mission_path,
                &balance_warnings,
            ) catch {
                failReconstructionRead(history, "failed to build editor mission");
                return;
            };
            surfaceWarnings(history, &balance_warnings, allocator);
            current.transitionScreen(.editor);
        },

        // --- Meta: exit/skip orchestrators ---
        .player_skip_level => {
            pushEvents(current, &.{.{ .meta_event = .{ .end_level = .{} } }}, allocator);
        },
        .player_restart_mission => {
            pushEvents(current, &.{.{ .meta_event = .{ .end_level = .{
                .continuation = .restart_mission,
            } } }}, allocator);
        },
        .player_exit_mission => {
            pushEvents(current, &.{.{ .meta_event = .{ .end_level = .{
                .continuation = .exit_mission,
            } } }}, allocator);
        },
        .player_exit_to_menu => {
            if (current.screen == .level) {
                pushEvents(current, &.{.{ .meta_event = .{ .end_level = .{
                    .continuation = .exit_to_menu,
                } } }}, allocator);
            } else if (current.screen == .hub) {
                pushEvents(current, &.{
                    .{ .meta_event = .open_main_menu },
                    .{ .meta_event = .end_hub },
                }, allocator);
            } else if (current.screen == .editor) {
                // close_editor owns the teardown AND the transition (its
                // handler calls transitionScreen(.main_menu), which clears
                // the editor via the screen-scope swap) — no sibling
                // open_main_menu needed.
                pushEvents(current, &.{.{ .meta_event = .close_editor }}, allocator);
            }
        },
        .player_replay_mission => {
            const info = current.last_completed_mission orelse return;
            const mission_path = allocator.dupe(u8, info.path) catch
                @panic("failed to allocate replay mission path");
            pushEvents(current, &.{
                .{ .meta_event = .{ .start_mission = .{
                    .mission_path = mission_path,
                    .start_hub_id = current.player_data.current_hub,
                    .end_hub_id = null,
                } } },
                .{ .meta_event = .end_hub },
            }, allocator);
        },
        // Level-tab click: switch the editor's active level. Thin orchestrator
        // — the EditorEvent owns the mutation (undo rides the timeline).
        .player_set_editor_level => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_active_level = .{
                .level_index = set.level_index,
            } } }}, allocator);
        },
        // Tool-cell click: push the machinery event (the tool pointer + the
        // selection clear live on the undo timeline together).
        .player_set_editor_tool => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_tool = .{
                .tool = set.tool,
            } } }}, allocator);
        },
        // Inspector toggle-button click: push the machinery event (the
        // panel's open state rides the undo timeline with the edits).
        .player_toggle_editor_inspector => {
            pushEvents(current, &.{.{ .editor_event = .editor_toggle_inspector }}, allocator);
        },
        // Select-tool click: thin over the shared planner (the input layer
        // fires only nonempty plans — see planEditorSelectionActions).
        .player_toggle_editor_selection => |toggle| {
            if (current.editor) |*editor| {
                pushEvents(current, planEditorSelectionActions(editor, toggle.position, allocator), allocator);
            }
        },
        // Select-tool plain click: thin over the shared planner (the input
        // layer fires only nonempty plans — see
        // planEditorReplaceSelectionActions).
        .player_replace_editor_selection => |replace| {
            if (current.editor) |*editor| {
                pushEvents(current, planEditorReplaceSelectionActions(editor, replace.position, allocator), allocator);
            }
        },
        // Select-tool marquee release: thin over the shared planner (the
        // gesture handler fires only nonempty plans — see
        // planEditorRegionSelectActions).
        .player_select_editor_region => |select| {
            if (current.editor) |*editor| {
                pushEvents(
                    current,
                    planEditorRegionSelectActions(editor, select.start_position, select.end_position, allocator),
                    allocator,
                );
            }
        },
        // Select-tool ctrl+A: thin over the shared planner (the input layer
        // fires only nonempty plans — see planEditorSelectAllActions).
        .player_select_editor_all => {
            if (current.editor) |*editor| {
                pushEvents(
                    current,
                    planEditorSelectAllActions(editor, allocator),
                    allocator,
                );
            }
        },
        // Select-tool Delete key: thin over the shared planner (the input
        // layer fires only nonempty plans — see
        // planEditorSelectionDeleteActions).
        .player_delete_editor_selection => {
            if (current.editor) |*editor| {
                pushEvents(current, planEditorSelectionDeleteActions(editor, allocator), allocator);
            }
        },
        // Select-tool ctrl+D: push the single clear event.
        .player_clear_editor_selection => {
            pushEvents(current, &.{.{ .editor_event = .editor_clear_selection }}, allocator);
        },
        // Select-tool move-drag release: back the selection up as concrete
        // things at their translated positions, then push [commit link 0,
        // …clear plan] — LIFO runs the clear phase first, then the commit
        // chain places the worklist one entry at a time against the live
        // post-clear state (see editor_commit_selection_move).
        .player_move_editor_selection => |move| {
            if (current.editor) |*editor| {
                const level = activeEditorLevel(editor) orelse return;
                var entries: std.ArrayList(types.EditorSelectionMoveEntry) = .empty;
                for (editor.selection) |selected| {
                    switch (selected) {
                        .entity_placement => |index| {
                            if (index < level.entity_placements.len) {
                                const placement = level.entity_placements[index];
                                entries.append(allocator, .{ .entity = .{
                                    .type_id = placement.type_id,
                                    .position = translatedPosition(placement.position, move.delta),
                                } }) catch @panic("failed to allocate editor selection move entries");
                            }
                        },
                        .decoration_placement => |index| {
                            if (index < level.decoration_placements.len) {
                                const placement = level.decoration_placements[index];
                                entries.append(allocator, .{ .decoration = .{
                                    .type_id = placement.type_id,
                                    .position = translatedPosition(placement.position, move.delta),
                                } }) catch @panic("failed to allocate editor selection move entries");
                            }
                        },
                        .ground_item_placement => |index| {
                            if (index < level.item_placements.len) {
                                const placement = level.item_placements[index];
                                entries.append(allocator, .{ .item = .{
                                    .type_id = placement.type_id,
                                    .position = translatedPosition(placement.position, move.delta),
                                } }) catch @panic("failed to allocate editor selection move entries");
                            }
                        },
                        .tile => |position| {
                            entries.append(allocator, .{ .tile = translatedPosition(position, move.delta) }) catch
                                @panic("failed to allocate editor selection move entries");
                        },
                        .player_start => {
                            entries.append(allocator, .{ .player_start = translatedPosition(level.player_start, move.delta) }) catch
                                @panic("failed to allocate editor selection move entries");
                        },
                        .level_end => {
                            if (level.level_end) |level_end_position| {
                                entries.append(allocator, .{ .level_end = translatedPosition(level_end_position, move.delta) }) catch
                                    @panic("failed to allocate editor selection move entries");
                            }
                        },
                    }
                }
                var push: std.ArrayList(Event) = .empty;
                push.append(allocator, .{ .editor_event = .{ .editor_commit_selection_move = .{
                    .entries = entries.items,
                    .next_index = 0,
                } } }) catch @panic("failed to allocate editor selection move plan");
                push.appendSlice(allocator, planEditorSelectionMoveDeleteActions(editor, allocator)) catch
                    @panic("failed to allocate editor selection move plan");
                pushEvents(current, push.items, allocator);
            }
        },
        // Tile-paint click: thin over the shared planner (the input layer
        // fires only nonempty plans — see planEditorTilePaintActions).
        .player_paint_editor_tile => |paint| {
            if (current.editor) |*editor| {
                pushEvents(current, planEditorTilePaintActions(editor, paint.position, allocator), allocator);
            }
        },
        // Enemy-tool click: thin over the shared planner (the input layer
        // fires only nonempty plans — see planEditorEntityPlacementActions).
        .player_place_editor_entity => |place| {
            if (current.editor) |*editor| {
                pushEvents(current, planEditorEntityPlacementActions(editor, place.type_id, place.position, allocator), allocator);
            }
        },
        // Decoration-tool click: thin over the shared planner (the input
        // layer fires only nonempty plans — see
        // planEditorDecorationPlacementActions).
        .player_place_editor_decoration => |place| {
            if (current.editor) |*editor| {
                pushEvents(current, planEditorDecorationPlacementActions(editor, place.type_id, place.position, allocator), allocator);
            }
        },
        // Ground-item-tool click: thin over the shared planner (the input
        // layer fires only nonempty plans — see
        // planEditorItemPlacementActions).
        .player_place_editor_item => |place| {
            if (current.editor) |*editor| {
                pushEvents(current, planEditorItemPlacementActions(editor, place.type_id, place.position, allocator), allocator);
            }
        },
        // Editor right-click delete: thin over the shared planner (the
        // input layer fires only nonempty plans — see
        // planEditorDeleteActions).
        .player_delete_editor_at => |delete| {
            if (current.editor) |*editor| {
                pushEvents(current, planEditorDeleteActions(editor, delete.position, allocator), allocator);
            }
        },
        .player_overwrite_clone => {
            // Replace the existing clone for this mission with the just-
            // completed run's data. Only offered when overwrite_offered is
            // set (a clone exists + the run was not strictly better). See
            // DESIGN → Clones (clone system).
            const info = current.last_completed_mission orelse return;
            pushEvents(current, &.{.{ .super_event = .{ .save_clone_info = .{
                .mission_uuid = info.uuid,
                .mission_name = info.name,
                .total_turns = info.turns_spent,
                .total_materials = info.converted_materials,
            } } }}, allocator);
        },

        // --- Player: swap weapons ---
        .swap_hands => {
            const player = getPlayerEntity(current, 0);
            const held_weapon = player.main_hand_weapon;
            player.main_hand_weapon = player.off_hand_weapon;
            player.off_hand_weapon = held_weapon;
            cancelPreparedSkill(current);
        },

        // --- Hub: movement + NPC interaction ---
        .move_player => |move| {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .move);
            if (current.hub) |*hub| {
                hub.player.position = move.destination;
                for (hub.mission_exits) |exit| {
                    if (exit.position.x == move.destination.x and
                        exit.position.y == move.destination.y)
                    {
                        const mission_path = std.fmt.allocPrint(
                            allocator,
                            "data/campaigns/{s}/missions/{s}",
                            .{ current.player_data.current_campaign, exit.mission_id },
                        ) catch @panic("failed to allocate mission path");
                        pushEvents(current, &.{
                            .{ .meta_event = .{ .start_mission = .{
                                .mission_path = mission_path,
                                .start_hub_id = current.player_data.current_hub,
                                .end_hub_id = null,
                            } } },
                            .{ .meta_event = .end_hub },
                        }, allocator);
                        break;
                    }
                }
            }
        },
        .interact_with_npc => {},

        // --- Level: player-action orchestrators ---
        .player_move_action => |action| {
            pushEvents(current, &.{
                .{ .level_event = .{ .player_turn_attack = .{
                    .force_attack_step = action.force_attack_step,
                } } },
                .{ .level_event = .clear_highlights },
                .{ .level_event = .{ .move_entity = .{
                    .entity_index = 0,
                    .destination = action.destination,
                } } },
            }, allocator);
        },
        .player_skip_move => |skip| {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .skip);
            pushEvents(current, &.{
                .{ .level_event = .{ .player_turn_attack = .{
                    .force_attack_step = skip.force_attack_step,
                } } },
                .{ .level_event = .clear_highlights },
            }, allocator);
        },
        .player_skip_move_to_skill => |skip| {
            if (skip.prepare) {
                pushEvents(current, &.{
                    .{ .player_input_event = .{ .player_prepare_skill = .{
                        .caster_index = 0,
                        .skill_id = skip.skill_id,
                    } } },
                    .{ .level_event = .{ .player_turn_attack = .{
                        .force_attack_step = true,
                    } } },
                    .{ .level_event = .clear_highlights },
                }, allocator);
            } else {
                pushEvents(current, &.{
                    .{ .player_input_event = .{ .player_use_skill = .{
                        .skill_id = skip.skill_id,
                        .target = skip.target,
                    } } },
                    .{ .level_event = .{ .player_turn_attack = .{
                        .force_attack_step = true,
                    } } },
                    .{ .level_event = .clear_highlights },
                }, allocator);
            }
        },
        .player_cancel_skill => {
            pushEvents(current, &.{
                .{ .level_event = .clear_highlights },
                .{ .level_event = .clear_prepared_skill },
            }, allocator);
        },
        .player_skip_attack => {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .skip);
            pushEvents(current, &.{
                .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
                .{ .level_event = .clear_highlights },
                .{ .level_event = .clear_prepared_skill },
            }, allocator);
        },
        .player_use_skill => |use| {
            const ends_turn = if (lookups.getSkillDefinition(use.skill_id)) |def|
                (def.skill_type == .weapon_skill or def.skill_type == .spell)
            else
                false;
            if (ends_turn) {
                pushEvents(current, &.{
                    .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
                    .{ .level_event = .{ .use_skill = .{
                        .caster_index = 0,
                        .skill_id = use.skill_id,
                        .target = use.target,
                    } } },
                    .{ .level_event = .clear_highlights },
                    .{ .level_event = .clear_prepared_skill },
                }, allocator);
            } else {
                pushEvents(current, &.{
                    .{ .level_event = .{ .use_skill = .{
                        .caster_index = 0,
                        .skill_id = use.skill_id,
                        .target = use.target,
                    } } },
                    .{ .level_event = .clear_highlights },
                    .{ .level_event = .clear_prepared_skill },
                }, allocator);
            }
        },
        .player_prepare_skill => |prepare| {
            const level = &current.level.?;
            level.prepared_skill = prepare.skill_id;
            if (lookups.getSkillDefinition(prepare.skill_id)) |skill_definition| {
                if (skill_definition.playerPrepareSkill(prepare.caster_index, current.*, allocator)) |event| {
                    pushEvents(current, &.{event}, allocator);
                }
            }
        },

        // --- Inventory/gear/skill: click + drag orchestrators ---
        // Each pushes the machinery event(s) as a child. The orchestrator
        // carries only the player's intent; all mutation is in the verbs.
        // See DESIGN → Architecture (orchestrator convention) + DESIGN →
        // Determinism & Tiebreaking (replay whitelist).
        .player_use_inventory_item => |use| {
            const player = getPlayerEntity(current, 0);
            const slot = &player.inventory.slots[use.inventory_slot_index];
            const item = slot.* orelse return;
            switch (item) {
                .weapon => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = if (use.off_hand) .off_hand else .main_hand,
                } } }}, allocator),
                .amulet => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = .amulet,
                } } }}, allocator),
                .coat => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = .coat,
                } } }}, allocator),
                .gloves => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = .gloves,
                } } }}, allocator),
                .pants => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = .pants,
                } } }}, allocator),
                .boots => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = .boots,
                } } }}, allocator),
                .skill_tome => |tome| {
                    if (isSkillLearned(current.player_data.learned_skills, tome.skill)) {
                        pushEvents(current, &.{.{ .player_event = .{ .salvage_item = .{
                            .inventory_slot_index = use.inventory_slot_index,
                        } } }}, allocator);
                    } else {
                        pushEvents(current, &.{.{ .player_event = .{ .learn_skill = .{
                            .inventory_slot_index = use.inventory_slot_index,
                        } } }}, allocator);
                    }
                },
            }
        },
        .player_salvage_inventory_item => |salvage| {
            pushEvents(current, &.{.{ .player_event = .{ .salvage_item = .{
                .inventory_slot_index = salvage.inventory_slot_index,
            } } }}, allocator);
        },
        .player_salvage_inventory_region => |region| {
            // One salvage_item per occupied slot in the region's bounding
            // box — the slot list comes from the shared region helper (the
            // input-side no-op gate reads the same definition).
            const player = getPlayerEntity(current, 0);
            const occupied_slots = salvageRegionOccupiedSlots(
                player.*,
                region.start_slot,
                region.end_slot,
                allocator,
            );
            var salvage_events: std.ArrayList(Event) = .empty;
            for (occupied_slots) |slot_index| {
                salvage_events.append(allocator, .{ .player_event = .{ .salvage_item = .{
                    .inventory_slot_index = slot_index,
                } } }) catch @panic("failed to allocate salvage events");
            }
            pushEvents(current, salvage_events.items, allocator);
        },
        .player_equip_to_gear => |equip| {
            pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                .inventory_slot_index = equip.inventory_slot_index,
                .gear_slot = equip.gear_slot,
            } } }}, allocator);
        },
        .player_unequip_from_gear => |unequip| {
            pushEvents(current, &.{.{ .player_event = .{ .unequip_item = .{
                .gear_slot = unequip.gear_slot,
                .inventory_slot_index = unequip.inventory_slot_index,
            } } }}, allocator);
        },
        .player_swap_inventory_items => |swap| {
            pushEvents(current, &.{.{ .player_event = .{ .swap_inventory_items = .{
                .slot_a_index = swap.slot_a_index,
                .slot_b_index = swap.slot_b_index,
            } } }}, allocator);
        },
        .player_assign_utility_skill => |assign| {
            // Enforce no duplicate utility skills on the bar: if the dragged
            // skill already occupies a utility slot, swap the target slot with
            // that slot (the skill moves, the displaced target contents land
            // where the skill was) instead of assigning a second copy. A drop
            // onto the slot that already holds this skill is a no-op. The bar's
            // weapon skills (slots 1-3, derived from the equipped weapon) are
            // a separate, non-overlapping set in shipped content, so the
            // search is over the utility slots only. See DESIGN → Architecture.
            if (assign.slot_index >= utility_skill_count) return;
            const player = getPlayerEntity(current, 0);
            var existing_slot: ?u32 = null;
            for (player.equipped_utility_skills, 0..) |slot_skill, index| {
                if (slot_skill) |skill| if (skill == assign.skill_id) {
                    existing_slot = @intCast(index);
                    break;
                };
            }
            if (existing_slot) |source_index| {
                if (source_index == assign.slot_index) return; // already there
                pushEvents(current, &.{.{ .player_event = .{ .swap_utility_skills = .{
                    .slot_a_index = assign.slot_index,
                    .slot_b_index = source_index,
                } } }}, allocator);
                return;
            }
            pushEvents(current, &.{.{ .player_event = .{ .equip_utility_skill = .{
                .skill_id = assign.skill_id,
                .slot_index = assign.slot_index,
            } } }}, allocator);
        },
        .player_swap_utility_skills => |swap| {
            pushEvents(current, &.{.{ .player_event = .{ .swap_utility_skills = .{
                .slot_a_index = swap.slot_a_index,
                .slot_b_index = swap.slot_b_index,
            } } }}, allocator);
        },
        .player_clear_utility_skill => |clear| {
            pushEvents(current, &.{.{ .player_event = .{ .unequip_utility_skill = .{
                .slot_index = clear.slot_index,
            } } }}, allocator);
        },
    }
}

/// Whether `skill_id` is in the player's `learned_skills` list. Pure —
/// extracted from the `player_use_inventory_item` handler so the
/// learn-vs-salvage decision for a skill tome is testable without the
/// orchestrator wrapper (no `expectPanics` in Zig 0.16; see AGENTS →
/// Testing discipline).
pub fn isSkillLearned(learned_skills: []const types.SkillId, skill_id: types.SkillId) bool {
    for (learned_skills) |learned| {
        if (learned == skill_id) return true;
    }
    return false;
}

/// The active level, or null when the editor has no levels or the active
/// index is out of range — the click planners no-op on null (defensive:
/// live input can't produce it, crafted session logs can).
fn activeEditorLevel(editor: *const types.Editor) ?*const types.EditorLevel {
    if (editor.levels.len == 0) return null;
    if (editor.active_level_index >= editor.levels.len) return null;
    return &editor.levels[editor.active_level_index];
}

/// Pure planners for the editor click orchestrators (tile paint, the three
/// placement tools, the right-click delete). Each computes the sub-event list
/// its click would push from the live editor state: the handler pushes the
/// plan, and the input layer fires the player action only when the plan is
/// nonempty — a click that would change nothing never reaches the event log,
/// so it can't create an undo or replay step (see DESIGN → Level Editor →
/// Active-tool model). One planner per tool is the single source of truth for
/// both sides (no duplicated no-op conditions to drift); the handlers keep
/// the empty-plan return as the defensive path for crafted or pre-change
/// session logs. Directly unit-testable (the AGENTS → Testing discipline
/// bool-helper convention).
///
/// Tile-paint click (tile tool active): one click = one tile. The effect is
/// computed from state — no-op (empty plan) when a tile is already there
/// (entities / items / the '!' / '=' sit ON tiles, so they never block a
/// paint); every decoration whose footprint covers the position is deleted
/// first (replace, not block — see DESIGN → Decorations & Footprint →
/// Placement invariant). The array is ordered for LIFO draining (set_tile
/// first, deletes in ascending placement order → the deletes process in
/// DESCENDING order — required for index-stable removal, since deleting a
/// lower index first would shift the pending higher ones — and the tile
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
/// place (`editor_set_entity_placement_type`, not delete + re-place — stable
/// identity); same type already there → nothing to do (the plan is empty
/// only when the tile is also present and nothing needs clearing). The
/// array is ordered for LIFO draining (the REVERSE of processing order; the
/// per-kind delete lists ascend so they process descending — index-stable
/// removal). All sub-events share one idle point — one undo reverts the
/// whole click. The one-thing-per-tile invariant is enforced at
/// `editor_place_entity` (panic on an occupied tile) — the deletes above run
/// first, so the place lands on a cleared tile.
pub fn planEditorEntityPlacementActions(
    editor: *const types.Editor,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    if (type_id >= editor.entity_types.len) return &.{};
    const level = activeEditorLevel(editor) orelse return &.{};

    // The '!' and '=' are singletons, movable never deletable — an enemy
    // never overwrites them.
    if (level.player_start.x == position.x and level.player_start.y == position.y) return &.{};
    if (level.level_end) |level_end_position| {
        if (level_end_position.x == position.x and level_end_position.y == position.y) return &.{};
    }

    // Is a tile already there (the enemy stands ON a tile — a missing one
    // is placed as part of the click)?
    var tile_present = false;
    for (level.level_tiles) |tile| {
        if (tile.x == position.x and tile.y == position.y) {
            tile_present = true;
            break;
        }
    }

    // Co-located entity placement, if any (invariant: at most one — the
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
        // Same type already there — no branch taken (nothing to do).
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
/// the tile/enemy placements — a decoration's footprint tiles are TILE-FREE,
/// so covered tiles are ERASED rather than placed: the '!' / '=' under ANY
/// footprint tile → no-op (never overwritten); an EXACT DUPLICATE (same type
/// at the same anchor → identical footprint) already satisfies the
/// placement — the plan skips the place and the duplicate's own delete, so
/// no duplicate ever stacks (other overlapping decorations still get
/// deleted); tiles under footprint tiles → erased, along with the entities /
/// ground items standing on them; other decorations whose footprints overlap
/// ANY footprint tile → deleted; then the placement lands
/// (`editor_place_decoration` enforces footprint-tile exclusivity). The
/// array is ordered for LIFO draining (the REVERSE of processing order; each
/// delete list ascends so it processes descending — index-stable). All
/// sub-events share one idle point — one undo reverts the whole click.
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
    // the placement — skip the place and the duplicate's own delete; the
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
    // this fires for covered tiles that had one — looping all footprint
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
    // the new footprint's world tiles (set intersection — checking this
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
/// — the same occupant replacement as the enemy tool, with the roles swapped
/// for the two placement kinds: an existing ground item is RETYPED in place
/// (`editor_set_item_placement_type`) and an enemy on the tile is DELETED
/// (the item can't coexist with it). The '!' / '=' → no-op; covering
/// decorations → deleted; a missing tile → placed (the item sits ON a
/// tile). The array is ordered for LIFO draining (the REVERSE of processing
/// order; each delete list ascends so it processes descending — index-
/// stable). All sub-events share one idle point — one undo reverts the
/// whole click.
pub fn planEditorItemPlacementActions(
    editor: *const types.Editor,
    type_id: u32,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    if (type_id >= editor.item_types.len) return &.{};
    const level = activeEditorLevel(editor) orelse return &.{};

    // The '!' and '=' are singletons, movable never deletable — a ground
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

    // Co-located item placement, if any (invariant: at most one — the loop
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
        // Same type already there — no branch taken (nothing to do).
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
    // An enemy on the tile is deleted (an item can't coexist with it — one
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

/// Editor right-click: the tool-independent delete — ONE thing per click,
/// priority: enemy / ground-item occupant (at most one by the one-thing-per-
/// tile invariant; an entity wins if both are somehow present), then
/// covering decoration(s) (all of them — consistent with every other editor
/// flow; overlapping footprints are a degenerate hand-authored case), then
/// the bare tile. The '!' / '=' are never deleted (checked first — they sit
/// ON tiles, so the bare-tile erase must not fire under them), and empty
/// ground is a no-op (empty plan). One delete = one undo step by
/// construction.
pub fn planEditorDeleteActions(
    editor: *const types.Editor,
    position: Vector2,
    allocator: std.mem.Allocator,
) []const Event {
    const level = activeEditorLevel(editor) orelse return &.{};

    // The '!' / '=' are singletons, movable never deletable — and their
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
    // Nothing there — no-op.
    return &.{};
}

/// Select-tool click planner: toggle the clicked thing's GROUP in the
/// selection. A click's group is everything that toggles together: the
/// '!' / '=' singletons; a covering decoration (the FIRST — exactly what
/// the hover preview outlines); or the tile INCLUDING anything standing
/// on it (entity / ground-item placements). Anything from the group
/// already selected → the plan deselects every PRESENT entry (clicking a
/// selected tile deselects the tile AND its occupant); nothing selected →
/// the plan selects the whole group. Empty ground selects nothing (empty
/// plan — no player action fires). One event per entry (granular by
/// design — see DESIGN → Architecture → Level Editor → Selection model);
/// they share the click's idle point, so one undo step reverts the whole
/// click.
/// The select tool's click GROUP at `position`: everything that acts as
/// one unit — the '!' / '=' singletons; a covering decoration (the FIRST —
/// exactly what the hover preview outlines); or the tile INCLUDING
/// anything standing on it (entity / ground-item placements). Empty ground
/// → an empty group. Shared by the toggle (shift+click) and replace (plain
/// click) planners; the group order is tile, entity, item.
fn editorClickGroup(
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
        // A covering decoration (the first — matching the hover preview).
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
    // The event stack is LIFO — push the group REVERSED so the entries
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
/// group — the whole selection is cleared, then the group is selected.
/// Empty ground → the clear alone (the clicky deselect-all). A click that
/// would change nothing (the selection IS exactly the group, or empty
/// ground with an already-empty selection) plans empty — no player action
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
/// never a remove — the plain click toggles). Region membership: level
/// tiles / entity / item placements by position; a decoration when ANY
/// of its footprint tiles is inside (matching the click hit-testing — if
/// you can click it, you can marquee it); the '!' / '=' singletons by
/// their tile. Deterministic order — tiles, entities, items, decorations,
/// singletons, each in stored order — and the list is REVERSED before
/// returning (the event stack is LIFO) so the entries process + land in
/// the log in plan order. An empty plan (nothing in the region, or
/// everything already selected) means no player action fires.
/// Select-tool Delete-key planner: fan the selection out into the per-entry
/// delete events (the same machinery the right-click delete composes). The
/// '!' / '=' entries are NEVER deletable (skipped) and the tiles under them
/// survive too (a marker needs its ground). A selected tile takes its
/// OCCUPANT with it — an entity/item placement standing on it is deleted
/// even when unselected (unreachable via today's UI — clicks and marquees
/// always grab tile + occupants together — but craftable in a log and
/// reachable once deselect features land; an occupant can't stand on
/// nothing).
///
/// Index stability: the delete set is computed from the ORIGINAL state
/// (selected placements + swept occupants, deduped per kind), and the
/// processing order — the reversed LIFO push — runs each placement kind
/// HIGH-BEFORE-LOW, so a removal never shifts an index a later event still
/// addresses (same reasoning as the covering-decoration deletes in
/// `planEditorDeleteActions`). Tile erases are position-keyed (safe any
/// time) and process last. The selection reconcile runs inside each delete
/// arm, keeping the selection consistent mid-batch; stale entries (out-of-
/// range indices, absent tiles) are skipped defensively. Everything shares
/// the player action's idle point — one undo step reverts the whole
/// deletion.
/// Which selection-deletion policy a plan runs — see
/// `planEditorSelectionDeleteActions` / `planEditorSelectionMoveDeleteActions`.
const SelectionDeleteMode = enum {
    /// The Delete key: a selected tile's OCCUPANT is swept with it (an
    /// occupant can't stand on nothing).
    delete_key,
    /// A selection move's clear phase: an UNSELECTED occupant PINS its
    /// tile — the tile stays underneath it and the moved tile lands at
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
/// Does the select tool's selection cover `position` — i.e. would a plain
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

pub fn planEditorSelectionMoveDeleteActions(
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
                // The Delete key never touches markers — and their tiles
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
                // An unselected occupant pins its ground (defensive — the
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
                // instead — nothing is swept).
                if (mode == .selection_move and selectionMoveOccupantPinsTile(level, editor.selection, position)) continue;
                tile_positions.append(allocator, position) catch
                    @panic("failed to allocate editor selection delete plan");
                // Delete-key mode sweeps the occupant (at most one — one
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
/// PINS its ground — the tile stays underneath it and the moved thing
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

/// Emit one placement-kind's deletes in DESCENDING index order — the
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
/// the '!' / '='), skipping entries already in the selection — the
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
/// (shared by the marquee region and the ctrl+A select-all — an add,
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

/// Process a single event from the stack. Applies the event to the current
/// state and records it in event history. Also used by undo/redo replay.
pub fn processEvent(
    history: *GameStateHistory,
) void {
    const current = &history.current_state;
    // All live state mutations allocate into current_arena (reclaimed by
    // compaction at idle points and by reconstruction on undo/redo). Durable
    // event recording goes through history.recordEvent into history_arena.
    const allocator = history.current_arena.allocator();

    if (current.event_stack.len == 0) return;

    // Pop the last event from the stack
    const next_event = current.event_stack[current.event_stack.len - 1];
    current.event_stack = current.event_stack[0 .. current.event_stack.len - 1];

    // Record in event history. Skip during replay: replay walks events that
    // are already recorded, applying them to rebuild a past state — it must
    // not create new events. The index still advances so replayTo's loop
    // progresses. (See recordEvent for the undo-branch handling.)
    if (!history.replaying) {
        history.recordEvent(next_event);
    }
    history.current_event_index += 1;

    switch (next_event) {
        .meta_event => |meta| {
            // Checkpoint AFTER the handler runs so the saved state reflects
            // the post-transition scope (level/hub loaded, screen set). A
            // checkpoint taken before the handler would capture the PRE-
            // transition state (e.g. hub with level=null) labeled with the
            // post-event index — replaying from it would hit in-level sub-
            // events (aggro_check) with no level loaded and crash.
            const should_checkpoint = switch (meta) {
                .start_level => |level| level.sets_checkpoint,
                .start_hub => |hub| hub.sets_checkpoint,
                else => false,
            };

            switch (meta) {
                .open_main_menu => {
                    current.transitionScreen(.main_menu);
                },
                .load_save => |load| {
                    var balance_warnings: std.ArrayList([]const u8) = .empty;
                    const parsed_sections = blk: {
                        const bytes = history.readReconstructionFile(load.save_path) catch {
                            // Missing/unreadable save (e.g. a deleted
                            // autosave after the menu offered Continue) is
                            // recoverable per DESIGN → Error Handling →
                            // context 2 — popup + revert, not a crash. If it
                            // was the autosave, hide Continue so the user
                            // doesn't retry into the same error.
                            if (std.mem.eql(u8, load.save_path, writers.autosave_path)) {
                                history.session.autosave_available = false;
                            }
                            failReconstructionRead(history, "failed to read save file");
                            return;
                        };
                        break :blk parser.parseConfigFile(bytes, allocator) catch {
                            failReconstructionRead(history, "failed to parse save file");
                            return;
                        };
                    };
                    validateConfigKeys(history, parsed_sections, parser.player_save_key_map, load.save_path, allocator);

                    current.player_data = loaders.loadPlayerSave(
                        parsed_sections,
                        allocator,
                        load.save_path,
                        &balance_warnings,
                    ) catch {
                        failReconstructionRead(history, "failed to parse save file");
                        return;
                    };
                    surfaceWarnings(history, &balance_warnings, allocator);

                    loadCampaignAndPushHub(current, history, allocator);
                    if (history.load_error) return;
                },
                .write_save => |write| {
                    // Side effect: skip during replay so undo/redo scrubbing
                    // doesn't rewrite the save (or spam download prompts on web).
                    if (history.replaying) return;
                    // A write failure is recoverable: the state is fine, just
                    // the file didn't write. Surface a popup + abort the write;
                    // don't crash. See DESIGN → Error Handling → three contexts.
                    writers.writePlayerSaveToFile(
                        history.file_source,
                        write.save_path,
                        current.player_data,
                        allocator,
                    ) catch {
                        history.session.setPendingError(
                            history.history_arena.allocator(),
                            "failed to write save file",
                        );
                        return;
                    };
                    // On web, the timestamped save (not the autosave — that's
                    // the smooth-resume path in IDBFS) is also offered to the
                    // player as a browser download, so a save file on disk
                    // doesn't require digging through browser storage. No-op
                    // on native. See DESIGN → File System & IO.
                    if (!std.mem.eql(u8, write.save_path, writers.autosave_path)) {
                        file_source_mod.triggerBrowserDownload(allocator, write.save_path);
                    }
                },
                .backup_autosave => {
                    // Side effect: skip during replay (undo/redo scrubbing
                    // must not re-copy files). See DESIGN → File System & IO.
                    if (history.replaying) return;
                    // No autosave present → nothing to back up.
                    if (!history.file_source.fileExists(writers.autosave_path)) return;
                    // Pure file copy: read the autosave bytes, write them at
                    // a timestamped backup path. Best-effort — a failure
                    // surfaces the popup but does NOT abort the new game
                    // (the backup is preservation, not a prerequisite).
                    const autosave_bytes = history.file_source.readFile(
                        allocator,
                        writers.autosave_path,
                    ) catch {
                        history.session.setPendingError(
                            history.history_arena.allocator(),
                            "failed to back up autosave",
                        );
                        return;
                    };
                    defer allocator.free(autosave_bytes);
                    // Timestamp format "YYYYMMDD_HHMMSS" — mirrors
                    // `input_handlers.formatSessionTimestamp` /
                    // `crash_dump.formatTimestamp` (inlined here to avoid a
                    // circular import; event_handlers is imported by
                    // input_handlers). See TODO → Logging & Replay.
                    const seconds: u64 = @intCast(std.Io.Clock.now(.real, history.io).toSeconds());
                    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
                    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
                    const month_day = year_day.calculateMonthDay();
                    const day_seconds = epoch_seconds.getDaySeconds();
                    const backup_path = std.fmt.allocPrint(
                        allocator,
                        "saves/autosave-{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.txt",
                        .{
                            year_day.year,
                            month_day.month.numeric(),
                            @as(u32, month_day.day_index) + 1,
                            day_seconds.getHoursIntoDay(),
                            day_seconds.getMinutesIntoHour(),
                            day_seconds.getSecondsIntoMinute(),
                        },
                    ) catch @panic("failed to allocate backup path");
                    defer allocator.free(backup_path);
                    history.file_source.writeFile(backup_path, autosave_bytes) catch {
                        history.session.setPendingError(
                            history.history_arena.allocator(),
                            "failed to back up autosave",
                        );
                        return;
                    };
                },
                .start_hub => |start| {
                    // Build hub file path: data/campaigns/{campaign}/hubs/{hub_id}/hub.txt
                    const hub_path = std.fmt.allocPrint(
                        allocator,
                        "data/campaigns/{s}/hubs/{s}/hub.txt",
                        .{ current.player_data.current_campaign, start.hub_id },
                    ) catch @panic("failed to allocate hub path");

                    const hub_sections = blk: {
                        const bytes = history.readReconstructionFile(hub_path) catch {
                            failReconstructionRead(history, "failed to read hub file");
                            return;
                        };
                        break :blk parser.parseConfigFile(bytes, allocator) catch {
                            failReconstructionRead(history, "failed to parse hub file");
                            return;
                        };
                    };
                    validateConfigKeys(history, hub_sections, parser.hub_key_map, hub_path, allocator);

                    current.hub = loaders.loadHub(
                        hub_sections,
                        history.file_source,
                        allocator,
                    ) catch {
                        failReconstructionRead(history, "failed to parse hub file");
                        return;
                    };

                    current.player_data.current_hub = start.hub_id;
                    current.world_generation +%= 1;
                    current.transitionScreen(.hub);

                    // Set/clear the mission-complete overlay info. Non-null
                    // when this hub entry follows a mission completion (the
                    // overlay renders); null on a normal entry (clears any
                    // stale value). On the undo timeline via GameState. See
                    // DESIGN → Architecture.
                    current.last_completed_mission = start.completed_mission;

                    // Sync player entity from PlayerData
                    pushEvents(current, &.{.{ .super_event = .{ .build_player_from_data = .{
                        .entity_index = 0,
                    } } }}, allocator);
                },
                .end_hub => {
                    // Preserve the player entity's changes back into PlayerData
                    // before the hub is discarded/replaced, then autosave the
                    // synced data. Pushed on top so both run before whatever
                    // continuation the exit path stacked below (LIFO): sync
                    // first, then the write reads the synced PlayerData. All
                    // hub-exit paths must route through here. See DESIGN →
                    // File System & IO (autosave).
                    pushEvents(current, &.{
                        .{ .meta_event = .{ .write_save = .{ .save_path = writers.autosave_path } } },
                        .{ .super_event = .{ .build_data_from_player = .{
                            .entity_index = 0,
                        } } },
                    }, allocator);
                },
                .close_editor => {
                    // Tear down the editor session and return to the main menu.
                    // transitionScreen clears editor (old scope .editor, new
                    // scope .main_menu has no editor).
                    current.transitionScreen(.main_menu);
                },
                .start_playtest => |start| {
                    // Instantiate the chosen level from the editor's palette +
                    // player_def into a concrete gameplay Level. Discard
                    // semantics: the editor's levels/palette are untouched.
                    const editor = &current.editor.?;
                    current.level = loaders.instantiateEditorLevel(editor.*, start.level_index, allocator);
                    current.mission = deepCopy(types.Mission, editor.mission, allocator);
                    current.mission.?.current_level_index = start.level_index + 1; // 1-based for gameplay handlers
                    if (editor.mode == .edit) editor.mode = .playtest;
                    current.world_generation +%= 1;
                    current.transitionScreen(.level);
                    pushGameplayStartEvents(current, allocator, false);
                },
                .end_playtest => {
                    // Discard the playtest level + mission, restore the editor.
                    // transitionScreen(.editor) clears level + mission (out of
                    // scope) but keeps editor (.level scope includes editor).
                    current.editor.?.mode = .edit;
                    current.transitionScreen(.editor);
                },
                .start_validation => {
                    // Forced full-mission playthrough from level 1. Same as
                    // playtest but mode=.validate and always level 0. end_level's
                    // guard pushes the next level or end_validation.
                    const editor = &current.editor.?;
                    current.level = loaders.instantiateEditorLevel(editor.*, 0, allocator);
                    current.mission = deepCopy(types.Mission, editor.mission, allocator);
                    current.mission.?.current_level_index = 1;
                    editor.mode = .validate;
                    current.world_generation +%= 1;
                    current.transitionScreen(.level);
                    pushGameplayStartEvents(current, allocator, false);
                },
                .end_validation => {
                    // Restore the editor after a validation run. Returns to
                    // edit mode; validation result + replay attachment are
                    // not wired.
                    current.editor.?.mode = .edit;
                    current.transitionScreen(.editor);
                },
                .start_mission => |start| {
                    const mission_file_path = std.fmt.allocPrint(
                        allocator,
                        "{s}/mission.txt",
                        .{start.mission_path},
                    ) catch @panic("failed to allocate mission path");

                    const mission_sections = blk: {
                        const bytes = history.readReconstructionFile(mission_file_path) catch {
                            failReconstructionRead(history, "failed to read mission file");
                            return;
                        };
                        break :blk parser.parseConfigFile(bytes, allocator) catch {
                            failReconstructionRead(history, "failed to parse mission file");
                            return;
                        };
                    };
                    validateConfigKeys(history, mission_sections, parser.mission_key_map, mission_file_path, allocator);

                    current.mission = loaders.loadMission(
                        mission_sections,
                        allocator,
                    ) catch {
                        failReconstructionRead(history, "failed to parse mission file");
                        return;
                    };

                    current.mission.?.path = start.mission_path;
                    current.mission.?.current_level_index = 1;

                    // Clear the mission-complete overlay info — entering a
                    // mission (new game or replay) retires any prior
                    // completion. On the undo timeline via GameState. See
                    // DESIGN → Architecture.
                    current.last_completed_mission = null;

                    // Return-hub override: when the caller passes a non-null
                    // end_hub_id, the mission returns THERE on end_mission
                    // instead of its authored end_hub. Used by dreams
                    // (custom missions): the authored end_hub may name a hub
                    // that doesn't exist in the player's campaign, so the
                    // caller overrides the return to the hub the player was
                    // at. Official missions pass null and keep the authored
                    // end_hub (existing behavior). The override lives on the
                    // live mission working copy (current_arena), so it is
                    // captured by deepCopy and reproduced on replay
                    // (start_mission re-applies it from the recorded event).
                    // See DESIGN → Custom Missions & Online Services → Dreams.
                    if (start.end_hub_id) |hub_id| {
                        current.mission.?.end_hub = hub_id;
                    }

                    // Push the first level
                    pushEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                        .mission_path = start.mission_path,
                        .level_index = 1,
                    } } }}, allocator);
                },
                .end_mission => |end| {
                    // Editor exit guard: in an editor session, end_mission
                    // should never be reached (end_level's guard redirects to
                    // end_validation / end_playtest), but suppress the
                    // start_hub continuation defensively if it ever is.
                    if (current.editor != null) return;
                    // Return to the destination hub. Pass completed_mission
                    // through so start_hub sets last_completed_mission (the
                    // mission-complete overlay). Null for abandon/exits.
                    if (end.hub_id) |hub_id| {
                        pushEvents(current, &.{.{ .meta_event = .{ .start_hub = .{
                            .hub_id = hub_id,
                            .completed_mission = end.completed_mission,
                        } } }}, allocator);
                    }
                },
                .start_level => |start| {
                    var balance_warnings: std.ArrayList([]const u8) = .empty;
                    const level_path = std.fmt.allocPrint(
                        allocator,
                        "{s}/level_{d}.txt",
                        .{ start.mission_path, start.level_index },
                    ) catch @panic("failed to allocate level path");

                    const level_sections = blk: {
                        const bytes = history.readReconstructionFile(level_path) catch {
                            failReconstructionRead(history, "failed to read level file");
                            return;
                        };
                        break :blk parser.parseConfigFile(bytes, allocator) catch {
                            failReconstructionRead(history, "failed to parse level file");
                            return;
                        };
                    };

                    // Key validation: warn on unknown keys (advisory — the
                    // file still loads). Catches typo'd keys that the
                    // permissive parser would silently drop. See DESIGN →
                    // Error Handling.
                    validateConfigKeys(history, level_sections, parser.level_key_map, level_path, allocator);

                    current.level = loaders.loadLevel(
                        level_sections,
                        history.file_source,
                        allocator,
                        level_path,
                        &balance_warnings,
                    ) catch {
                        failReconstructionRead(history, "failed to parse level file");
                        return;
                    };
                    surfaceWarnings(history, &balance_warnings, allocator);

                    if (current.mission) |*mission| {
                        mission.current_level_index = start.level_index;
                    }

                    current.world_generation +%= 1;
                    current.transitionScreen(.level);
                    pushGameplayStartEvents(current, allocator, true);
                },
                .end_level => |end| {
                    // Editor exit guard: when an editor session is active, it
                    // owns the exit continuation — the gameplay default
                    // (next start_level / end_mission → start_hub) is
                    // suppressed/redirected. build_data_from_player is also
                    // skipped (playtest/validate are discard-semantics; the
                    // player's real PlayerData is unchanged). See DESIGN →
                    // Architecture → Level Editor.
                    if (current.editor) |editor| {
                        switch (editor.mode) {
                            .playtest => {
                                pushEvents(current, &.{.{ .meta_event = .end_playtest }}, allocator);
                            },
                            .validate => {
                                const current_level_index = current.mission.?.current_level_index;
                                if (current_level_index < editor.levels.len) {
                                    const next_index = current_level_index; // 0-based: current is 1-based, next is current
                                    pushEvents(current, &.{.{ .meta_event = .{ .start_playtest = .{
                                        .level_index = next_index,
                                    } } }}, allocator);
                                } else {
                                    pushEvents(current, &.{.{ .meta_event = .{ .end_validation = .{
                                        .success = true,
                                    } } }}, allocator);
                                }
                            },
                            .edit => {}, // shouldn't happen (no level loaded in edit mode)
                        }
                        return;
                    }
                    // Clone-system scratch locals, populated by the .default
                    // last-level branch below and consumed by the trailing
                    // push block (LIFO: harvest → save → write_save run before
                    // the end_mission/start_mission already pushed). See DESIGN
                    // → Clones (clone system).
                    var clone_harvest_turns: ?u32 = null;
                    var clone_save_info: ?struct {
                        mission_uuid: []const u8,
                        mission_name: []const u8,
                        total_turns: u32,
                        total_materials: types.Materials,
                    } = null;
                    switch (end.continuation) {
                        .default => {
                            if (current.mission) |mission| {
                                if (mission.current_level_index < mission.level_count) {
                                    // More levels — push the next one
                                    const next_index = mission.current_level_index + 1;
                                    pushEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                                        .mission_path = mission.path,
                                        .level_index = next_index,
                                    } } }}, allocator);
                                } else {
                                    // Last level done — end the mission.
                                    // Play the completion sound (live play
                                    // only) + carry the mission info through
                                    // the cascade for the mission-complete
                                    // overlay (end_mission → start_hub sets
                                    // GameState.last_completed_mission).
                                    if (!history.replaying) {
                                        history.session.queueSound(history.backing_allocator, .mission_completion);
                                    }
                                    // Clone decision: harvest from all old
                                    // clones, then auto-save a clone for this
                                    // mission on first completion or a
                                    // strictly-better run (Pareto per-material
                                    // rate). Otherwise flag the overlay to
                                    // offer a manual overwrite button. See
                                    // DESIGN → Clones (clone system).
                                    const turns = mission.turns_spent;
                                    const converted = mission.converted_materials_collected;
                                    var existing_clone: ?types.Clone = null;
                                    for (current.player_data.clones) |clone| {
                                        if (std.mem.eql(u8, clone.mission_uuid, mission.uuid)) {
                                            existing_clone = clone;
                                            break;
                                        }
                                    }
                                    var overwrite_offered = false;
                                    var harvested: types.Materials = .{};
                                    if (turns > 0) {
                                        clone_harvest_turns = turns;
                                        harvested = computeHarvest(current.player_data.clones, turns);
                                        if (existing_clone) |old| {
                                            if (cloneIsStrictlyBetter(turns, converted, old.turns_to_complete, old.materials_collected)) {
                                                clone_save_info = .{
                                                    .mission_uuid = mission.uuid,
                                                    .mission_name = mission.name,
                                                    .total_turns = turns,
                                                    .total_materials = converted,
                                                };
                                            } else {
                                                overwrite_offered = true;
                                            }
                                        } else {
                                            clone_save_info = .{
                                                .mission_uuid = mission.uuid,
                                                .mission_name = mission.name,
                                                .total_turns = turns,
                                                .total_materials = converted,
                                            };
                                        }
                                    }
                                    pushEvents(current, &.{.{ .meta_event = .{ .end_mission = .{
                                        .hub_id = mission.end_hub,
                                        .completed_mission = .{
                                            .uuid = mission.uuid,
                                            .name = mission.name,
                                            .path = mission.path,
                                            .turns_spent = turns,
                                            .converted_materials = converted,
                                            .harvested_materials = harvested,
                                            .tiles_moved = mission.tiles_moved,
                                            .damage_dealt = mission.damage_dealt,
                                            .damage_taken = mission.damage_taken,
                                            .skills_used = mission.skills_used,
                                            .overwrite_offered = overwrite_offered,
                                        },
                                    } } }}, allocator);
                                }
                            }
                        },
                        // Restart: replay the mission from level 1 with the
                        // current PlayerData (synced below before start_mission
                        // runs). The player keeps their gear; only level
                        // progress resets.
                        .restart_mission => {
                            if (current.mission) |mission| {
                                pushEvents(current, &.{.{ .meta_event = .{ .start_mission = .{
                                    .mission_path = mission.path,
                                    .start_hub_id = null,
                                    .end_hub_id = null,
                                } } }}, allocator);
                            }
                        },
                        // Abandon the mission: return to the hub the player
                        // was at before entering it (the mission's start_hub).
                        // end_mission's handler pushes start_hub with the
                        // given hub_id.
                        .exit_mission => {
                            if (current.mission) |mission| {
                                const hub_id = mission.start_hub orelse current.player_data.current_hub;
                                pushEvents(current, &.{.{ .meta_event = .{ .end_mission = .{
                                    .hub_id = hub_id,
                                } } }}, allocator);
                            }
                        },
                        // Quit to main menu: PlayerData is synced below
                        // before open_main_menu clears the level scope.
                        .exit_to_menu => {
                            pushEvents(current, &.{.{ .meta_event = .open_main_menu }}, allocator);
                        },
                    }
                    // Preserve the player entity's changes back into PlayerData
                    // before the level is discarded/replaced, then autosave the
                    // synced data. Pushed last so both run on top of the
                    // continuation above (LIFO): sync first, then the write
                    // reads the synced PlayerData. All level-exit paths must
                    // route through here. The editor early-returns above before
                    // this push, so playtest/validate never autosave (discard
                    // semantics — the real PlayerData is unchanged). See DESIGN
                    // → File System & IO (autosave).
                    //
                    // On a last-level completion (.default branch above), the
                    // clone system also injects `harvest_clones` (payout from
                    // all old clones) and `save_clone_info` (auto-save /
                    // auto-overwrite the clone for this mission) between the
                    // sync and the write — LIFO array order is [write_save,
                    // save_clone_info?, harvest_clones?, build_data_from_player]
                    // so execution is sync → harvest → save → write. See
                    // DESIGN → Clones (clone system).
                    var exit_events: std.ArrayList(Event) = .empty;
                    exit_events.append(allocator, .{ .meta_event = .{ .write_save = .{
                        .save_path = writers.autosave_path,
                    } } }) catch @panic("failed to append exit event");
                    if (clone_save_info) |info| {
                        exit_events.append(allocator, .{ .super_event = .{ .save_clone_info = .{
                            .mission_uuid = info.mission_uuid,
                            .mission_name = info.mission_name,
                            .total_turns = info.total_turns,
                            .total_materials = info.total_materials,
                        } } }) catch @panic("failed to append save_clone_info");
                    }
                    if (clone_harvest_turns) |turns| {
                        exit_events.append(allocator, .{ .super_event = .{ .harvest_clones = .{
                            .turns_spent = turns,
                        } } }) catch @panic("failed to append harvest_clones");
                    }
                    exit_events.append(allocator, .{ .super_event = .{ .build_data_from_player = .{
                        .entity_index = 0,
                    } } }) catch @panic("failed to append build_data_from_player");
                    pushEvents(current, exit_events.items, allocator);
                },
                .wait => |wait_event| {
                    // Begin a real-time pause; update() drains it as frames
                    // elapse before the next event is processed. Record the
                    // stack depth so anytime interjections (swap_weapons)
                    // pushed during the wait are processed immediately down
                    // to this baseline instead of delaying until the wait
                    // elapses. The wait event is already popped, so this is
                    // the depth of the remaining enemy-turn events.
                    current.waiting = .{
                        .remaining_microseconds = @as(u64, wait_event.duration_milliseconds) * 1000,
                        .baseline_stack_depth = current.event_stack.len,
                    };
                },
                else => {},
            }

            // Now that the handler has loaded the new scope, checkpoint it.
            if (should_checkpoint) {
                history.setCheckpoint();
            }
        },
        .super_event => |super| {
            switch (super) {
                .build_player_from_data => |sync| {
                    const player_data = &current.player_data;
                    const player_entity = getPlayerEntity(current, sync.entity_index);

                    player_entity.name = player_data.player_name;
                    player_entity.main_hand_weapon = player_data.main_hand_weapon;
                    player_entity.off_hand_weapon = player_data.off_hand_weapon;
                    player_entity.amulet = player_data.amulet;
                    player_entity.coat = player_data.coat;
                    player_entity.gloves = player_data.gloves;
                    player_entity.pants = player_data.pants;
                    player_entity.boots = player_data.boots;
                    player_entity.equipped_utility_skills = player_data.equipped_utility_skills;
                    player_entity.inventory = player_data.inventory;
                    // Enter at full effective health (base + gear health_bonus).
                    player_entity.current_health = player_entity.getEffectiveMaxHealth();
                },
                .build_data_from_player => |sync| {
                    const player_data = &current.player_data;
                    const player_entity = getPlayerEntity(current, sync.entity_index);

                    player_data.player_name = player_entity.name;
                    player_data.main_hand_weapon = player_entity.main_hand_weapon;
                    player_data.off_hand_weapon = player_entity.off_hand_weapon;
                    player_data.amulet = player_entity.amulet;
                    player_data.coat = player_entity.coat;
                    player_data.gloves = player_entity.gloves;
                    player_data.pants = player_entity.pants;
                    player_data.boots = player_entity.boots;
                    player_data.equipped_utility_skills = player_entity.equipped_utility_skills;
                    player_data.inventory = player_entity.inventory;
                },
                .save_clone_info => |info| {
                    // Replace the existing clone for this mission (matched by
                    // uuid), else append. The clone records the run's
                    // per-turn material conversion rate (materials_collected
                    // / turns_to_complete) so future completions can harvest
                    // from it. See DESIGN → Clones (clone system).
                    var rebuilt: std.ArrayList(types.Clone) = .empty;
                    var replaced = false;
                    for (current.player_data.clones) |clone| {
                        if (std.mem.eql(u8, clone.mission_uuid, info.mission_uuid)) {
                            rebuilt.append(allocator, .{
                                .mission_uuid = info.mission_uuid,
                                .name = info.mission_name,
                                .turns_to_complete = info.total_turns,
                                .materials_collected = info.total_materials,
                            }) catch @panic("failed to append clone");
                            replaced = true;
                        } else {
                            rebuilt.append(allocator, clone) catch @panic("failed to copy clone");
                        }
                    }
                    if (!replaced) {
                        rebuilt.append(allocator, .{
                            .mission_uuid = info.mission_uuid,
                            .name = info.mission_name,
                            .turns_to_complete = info.total_turns,
                            .materials_collected = info.total_materials,
                        }) catch @panic("failed to append clone");
                    }
                    current.player_data.clones =
                        rebuilt.toOwnedSlice(allocator) catch @panic("failed to allocate clones");
                },
                .harvest_clones => |harvest| {
                    // Payout from all saved clones: per material,
                    // `(materials * turns_spent) / turns_to_complete`
                    // (multiply before divide — see computeHarvest).
                    // Gated on turns_spent > 0 at the push site, but guard
                    // here too in case a hand-crafted replay seeds it at 0.
                    // See DESIGN → Clones (clone system).
                    const payout = computeHarvest(current.player_data.clones, harvest.turns_spent);
                    current.player_data.materials.add(payout);
                },
            }
        },
        .player_event => |player_event| {
            switch (player_event) {
                .learn_skill => |learn| {
                    if (!history.replaying) history.session.queueSound(history.backing_allocator, .learn_skill);
                    const player = getPlayerEntity(current, 0);
                    const slot = &player.inventory.slots[learn.inventory_slot_index];

                    // Validate the slot contains a skill tome
                    const item = slot.* orelse return;
                    const skill_id = switch (item) {
                        .skill_tome => |tome| tome.skill,
                        else => return,
                    };

                    // Check if already learned
                    for (current.player_data.learned_skills) |learned| {
                        if (learned == skill_id) return;
                    }

                    // Remove the tome from inventory
                    slot.* = null;

                    // Add to learned skills
                    var updated_skills: std.ArrayList(SkillId) = .empty;
                    updated_skills.appendSlice(allocator, current.player_data.learned_skills) catch
                        @panic("failed to copy learned skills");
                    updated_skills.append(allocator, skill_id) catch
                        @panic("failed to append learned skill");
                    current.player_data.learned_skills = updated_skills.toOwnedSlice(allocator) catch
                        @panic("failed to allocate learned skills");
                },
                .salvage_item => |salvage| {
                    const player = getPlayerEntity(current, 0);
                    const slot = &player.inventory.slots[salvage.inventory_slot_index];

                    const item = slot.* orelse return;
                    // Sound after the guard: a salvage of an empty slot
                    // (crafted logs; live clicks are gated to occupied
                    // slots) must not click.
                    if (!history.replaying) history.session.queueSound(history.backing_allocator, .salvage);

                    // Compute salvage value and add to player materials
                    const materials = functions.computeSalvageValue(item, history.salvage_definitions);
                    current.player_data.materials.add(materials);

                    // Remove the item from inventory
                    slot.* = null;
                },
                .equip_item => |equip| {
                    const player = getPlayerEntity(current, 0);
                    const slot = &player.inventory.slots[equip.inventory_slot_index];

                    const item = slot.* orelse return;
                    if (!itemFitsGearSlot(item, equip.gear_slot)) return;
                    // Sound after the guards: a no-op equip (empty slot /
                    // unfitting item — crafted logs; live drags are gated at
                    // the drop site) must not click.
                    if (!history.replaying) history.session.queueSound(history.backing_allocator, .equip);

                    // Capture the displaced weapon before the gear-slot swap
                    // overwrites the slot, so its skill cooldowns can be
                    // inherited by the incoming weapon. See DESIGN → Architecture.
                    const old_weapon: ?types.Weapon = switch (equip.gear_slot) {
                        .main_hand, .off_hand => if (gearSlotItem(player, equip.gear_slot)) |old_item| old_item.weapon else null,
                        else => null,
                    };

                    // Old gear (if any) drops back into the inventory slot.
                    slot.* = gearSlotItem(player, equip.gear_slot);
                    setGearSlot(player, equip.gear_slot, item);

                    applyGearChangeSideEffects(current, equip.gear_slot, allocator);

                    if (equip.gear_slot == .main_hand or equip.gear_slot == .off_hand) {
                        transferWeaponCooldowns(
                            player,
                            old_weapon,
                            item.weapon,
                            history.weapon_type_definitions,
                        );
                    }
                },
                .unequip_item => |unequip| {
                    const player = getPlayerEntity(current, 0);
                    const piece = gearSlotItem(player, unequip.gear_slot) orelse return;
                    const slot = &player.inventory.slots[unequip.inventory_slot_index];

                    if (slot.*) |existing| {
                        // Filled target: swap only if the item fits this slot.
                        if (!itemFitsGearSlot(existing, unequip.gear_slot)) return;
                        setGearSlot(player, unequip.gear_slot, existing);
                        slot.* = piece;
                    } else {
                        // Empty target: move the piece out and clear the slot.
                        slot.* = piece;
                        clearGearSlot(player, unequip.gear_slot);
                    }

                    applyGearChangeSideEffects(current, unequip.gear_slot, allocator);
                },
                .equip_utility_skill => |equip| {
                    if (equip.slot_index >= utility_skill_count) return;
                    const player = getPlayerEntity(current, 0);

                    // Cooldown inheritance: the incoming skill's cd becomes
                    // @max(old slot skill cd, incoming cd) so a fresh swap
                    // can't bypass a cooldown that was ticking on the
                    // displaced skill. The outgoing skill's cd is PRESERVED
                    // (not cleared) in skill_cooldowns — see DESIGN → Architecture.
                    const old_skill = player.equipped_utility_skills[equip.slot_index];
                    const incoming_cd = player.skill_cooldowns.get(equip.skill_id);
                    const old_cd = if (old_skill) |s| player.skill_cooldowns.get(s) else 0;

                    player.equipped_utility_skills[equip.slot_index] = equip.skill_id;
                    player.skill_cooldowns.set(equip.skill_id, @max(old_cd, incoming_cd));

                    // Changing utility skills can invalidate a prepared skill.
                    cancelPreparedSkill(current);
                },
                .swap_utility_skills => |swap| {
                    if (swap.slot_a_index >= utility_skill_count) return;
                    if (swap.slot_b_index >= utility_skill_count) return;
                    const player = getPlayerEntity(current, 0);
                    const held = player.equipped_utility_skills[swap.slot_a_index];
                    player.equipped_utility_skills[swap.slot_a_index] =
                        player.equipped_utility_skills[swap.slot_b_index];
                    player.equipped_utility_skills[swap.slot_b_index] = held;

                    cancelPreparedSkill(current);
                    if (!history.replaying) history.session.queueSound(history.backing_allocator, .swap_skill);
                },
                .unequip_utility_skill => |unequip| {
                    if (unequip.slot_index >= utility_skill_count) return;
                    const player = getPlayerEntity(current, 0);
                    player.equipped_utility_skills[unequip.slot_index] = null;

                    cancelPreparedSkill(current);
                },
                .swap_inventory_items => |swap| {
                    if (swap.slot_a_index >= types.inventory_slot_count) return;
                    if (swap.slot_b_index >= types.inventory_slot_count) return;
                    const player = getPlayerEntity(current, 0);
                    const held = player.inventory.slots[swap.slot_a_index];
                    player.inventory.slots[swap.slot_a_index] =
                        player.inventory.slots[swap.slot_b_index];
                    player.inventory.slots[swap.slot_b_index] = held;
                },
            }
        },
        .player_input_event => |pi| {
            handlePlayerInputEvent(history, current, pi, allocator);
        },
        .editor_event => |editor_event| {
            switch (editor_event) {
                .editor_set_active_level => |set| {
                    if (current.editor) |*editor| {
                        if (set.level_index < editor.levels.len) {
                            editor.active_level_index = set.level_index;
                            // The selection is active-level-relative — a
                            // tab switch takes it with it (same event, so
                            // undo restores the tab AND its selection).
                            editor.selection = &.{};
                        }
                    }
                },
                // The remaining editor events are handled in the dedicated
                // editor handler block below (handleEditorEvent). They are
                // pure state transforms on current.editor.?.levels[] or the
                // palette; undo/redo works by construction via deepCopy.
                else => |ev| handleEditorEvent(
                    current,
                    ev,
                    allocator,
                ),
            }
        },
        .replay_viewer_event => |replay_event| {
            _ = replay_event;
            _ = current.replay_viewer;
        },
        .level_event => |level_event| {
            switch (level_event) {
                .turn_start => |turn| {
                    const entity = getLevelEntity(current, turn.entity_index);

                    // Skip dead entities
                    if (entity.current_health == 0) return;

                    // 1. Reduce all skill cooldowns by 1
                    inline for (@typeInfo(SkillId).@"enum".fields) |field| {
                        const skill_id: SkillId = @as(SkillId, @enumFromInt(field.value));
                        const current_cooldown = entity.skill_cooldowns.get(skill_id);
                        if (current_cooldown > 0) {
                            entity.skill_cooldowns.set(skill_id, current_cooldown - 1);
                        }
                    }

                    // 2. Trigger on_start_turn for all active effects, collecting events
                    for (entity.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onStartTurn(turn.entity_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }

                    // 3. Reduce all effect durations by 1, push end_effect for expired effects
                    var remaining_effects: std.ArrayList(types.Effect) = .empty;
                    for (entity.active_effects) |active_effect| {
                        if (active_effect.duration <= 1) {
                            pushEvents(current, &.{.{ .sub_level_event = .{ .end_effect = .{
                                .entity_index = turn.entity_index,
                                .effect_id = active_effect.effect_id,
                            } } }}, allocator);
                        } else {
                            var updated_effect = active_effect;
                            updated_effect.duration -= 1;
                            remaining_effects.append(allocator, updated_effect) catch
                                @panic("failed to append remaining effect");
                        }
                    }
                    entity.active_effects = remaining_effects.toOwnedSlice(allocator) catch
                        @panic("failed to allocate remaining effects");

                    // 4. If stunned, reduce stun and skip turn
                    if (entity.stun_duration > 0) {
                        entity.stun_duration -= 1;
                        pushEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                            .entity_index = turn.entity_index,
                        } } }}, allocator);
                    } else if (turn.entity_index == 0) {
                        // Player turn
                        pushEvents(current, &.{.{ .level_event = .player_turn_move }}, allocator);
                    } else {
                        // Enemy turn
                        pushEvents(current, &.{.{ .level_event = .{ .enemy_turn_move = .{
                            .entity_index = turn.entity_index,
                        } } }}, allocator);
                    }
                },
                .turn_end => |turn| {
                    const entity = getLevelEntity(current, turn.entity_index);

                    // If this is the player's turn ending, push the full next round:
                    // all active/alive enemy turn_starts sorted by distance (closest first),
                    // plus the next player turn_start at the bottom (processed last).
                    //
                    // The round events are pushed BEFORE on_end_turn effect hooks
                    // so the heals (and any other on_end_turn events) land on TOP
                    // of the LIFO stack and run before any turn_starts — i.e. at
                    // the END of this turn, not the start of the next. (Swapping
                    // the two blocks was the fix for Stone Form healing at the
                    // start of the player's next turn instead of the end of the
                    // current one; enemy turn_end doesn't build a round so the
                    // order is moot there.)
                    if (turn.entity_index == 0) {
                        // Turn counters. The per-mission counter (turns_spent)
                        // lives on the live mission working copy and is
                        // discarded with it on exit — it scopes a single
                        // playthrough for the mission-complete screen and the
                        // validation replay's author medal target. The
                        // cumulative lifetime counter (player_data.turns)
                        // persists across the campaign for historical stats;
                        // it is SKIPPED in editor playtest/validate
                        // (discard-semantics — the editor session must not
                        // inflate the player's real turn count). Both are
                        // direct GameState writes inside an event handler, so
                        // they are reproduced on replay. See DESIGN → Custom
                        // Missions & Online Services → Author time + medals.
                        if (current.mission) |*mission| {
                            mission.turns_spent += 1;
                        }
                        if (current.editor == null) {
                            current.player_data.turns += 1;
                        }

                        const level = &current.level.?;
                        level.turn_phase = null;
                        const player_position = level.entities[0].position;

                        // Collect active, alive non-player entity indices with their distances
                        const EntityDistance = struct {
                            entity_index: u32,
                            distance: i32,
                        };
                        var enemy_distances: std.ArrayList(EntityDistance) = .empty;
                        for (level.entities, 0..) |other_entity, entity_index| {
                            if (entity_index == 0) continue;
                            if (other_entity.current_health == 0) continue;
                            if (!other_entity.is_active) continue;
                            enemy_distances.append(allocator, .{
                                .entity_index = @intCast(entity_index),
                                .distance = functions.chebyshevDistance(player_position, other_entity.position),
                            }) catch @panic("failed to append enemy distance");
                        }

                        // Sort by distance ascending (closest first). std.mem.sort
                        // is unstable, so break ties explicitly by entity_index —
                        // otherwise equal-distance enemies would take turns in an
                        // arbitrary order (see DESIGN → Determinism & Tiebreaking).
                        std.mem.sort(EntityDistance, enemy_distances.items, {}, struct {
                            fn lessThan(_: void, a: EntityDistance, b: EntityDistance) bool {
                                if (a.distance != b.distance) return a.distance < b.distance;
                                return a.entity_index < b.entity_index;
                            }
                        }.lessThan);

                        // Build event batch: player turn_start first (bottom of LIFO),
                        // then enemy turn_starts in reverse distance order (farthest first
                        // on stack = closest processed first).
                        var round_events: std.ArrayList(Event) = .empty;

                        // Player's next turn_start goes first in the array (bottom of LIFO stack)
                        round_events.append(allocator, .{ .level_event = .{ .turn_start = .{
                            .entity_index = 0,
                        } } }) catch @panic("failed to append player turn_start");

                        // Enemy turn_starts in reverse order (farthest first in array)
                        var reverse_index: usize = enemy_distances.items.len;
                        while (reverse_index > 0) {
                            reverse_index -= 1;
                            const enemy = enemy_distances.items[reverse_index];
                            round_events.append(allocator, .{ .level_event = .{ .turn_start = .{
                                .entity_index = enemy.entity_index,
                            } } }) catch @panic("failed to append enemy turn_start");
                        }

                        pushEvents(current, round_events.items, allocator);
                    }
                    // Non-player turn_end: no round to build, next turn_start is
                    // already on the stack.

                    // Trigger on_end_turn for all active effects. Pushed AFTER the
                    // round events (above) so on_end_turn events (e.g. Stone Form
                    // heal) sit on top of the LIFO stack and run before any
                    // turn_starts — at the END of this turn, not the start of the
                    // next.
                    for (entity.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onEndTurn(turn.entity_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }
                },
                .player_turn_move => {
                    const level = &current.level.?;
                    level.turn_phase = .player_move;
                    refreshMoveHighlights(current, allocator);

                    // Event stack is now empty — handleIdleInput will pick up
                    // tile clicks and skip actions based on turn_phase.
                },
                .player_turn_attack => |attack| {
                    const level = &current.level.?;

                    // Auto-skip attack step out of combat: if no active enemies
                    // exist, go straight to turn_end. The player can override
                    // by holding ctrl at click-time (force_attack_step), which
                    // is carried through the orchestrator so the override is
                    // replay-safe (recorded in the event).
                    if (history.settings.auto_skip_attack_step_out_of_combat and !attack.force_attack_step) {
                        var has_active_enemies = false;
                        for (level.entities, 0..) |entity, entity_index| {
                            if (entity_index == 0) continue;
                            if (entity.current_health == 0) continue;
                            if (!entity.is_active) continue;
                            if (entity.team != level.entities[0].team) {
                                has_active_enemies = true;
                                break;
                            }
                        }
                        if (!has_active_enemies) {
                            pushEvents(current, &.{
                                .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
                            }, allocator);
                            return;
                        }
                    }

                    level.turn_phase = .player_attack;

                    // Event stack is now empty — handleIdleInput will pick up
                    // skill slot selection, skip, and swap weapons based on turn_phase.
                },
                .enemy_turn_move => |enemy_move| {
                    const level = &current.level.?;
                    const entity = level.entities[enemy_move.entity_index];

                    // A dead entity can't take its turn — skip to turn_end to
                    // advance the cycle. (Reactive effects like Reflect can
                    // kill an entity mid-turn, leaving its turn events already
                    // on the stack.)
                    if (entity.current_health == 0) {
                        pushEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                            .entity_index = enemy_move.entity_index,
                        } } }}, allocator);
                        return;
                    }

                    // Find nearest alive entity from a different team
                    var nearest_target: ?Vector2 = null;
                    var nearest_distance: i32 = std.math.maxInt(i32);
                    for (level.entities, 0..) |other_entity, other_index| {
                        if (other_index == enemy_move.entity_index) continue;
                        if (other_entity.current_health == 0) continue;
                        if (other_entity.team == entity.team) continue;
                        const distance = functions.chebyshevDistance(entity.position, other_entity.position);
                        // Strict < keeps the first at the minimum distance; since
                        // we iterate entities in index order, ties resolve to the
                        // lowest entity_index (the tiebreaking convention).
                        if (distance < nearest_distance) {
                            nearest_distance = distance;
                            nearest_target = other_entity.position;
                        }
                    }

                    if (nearest_target) |target_position| {
                        // Compute min range from off-cooldown skills
                        const min_range: i32 = @intCast(computeMinRange(entity, history.weapon_type_definitions) orelse 1);

                        // If already within min range, don't move
                        if (nearest_distance <= min_range) {
                            // Skip to attack
                            pushEvents(current, &.{.{ .level_event = .{ .enemy_turn_attack = .{
                                .entity_index = enemy_move.entity_index,
                            } } }}, allocator);
                        } else {
                            // Try pathfinding to target
                            const path = functions.shortestPath(
                                level.*,
                                entity.position,
                                target_position,
                                allocator,
                            );

                            if (path) |path_tiles| {
                                const effective_speed = entity.getEffectiveSpeed();

                                // Walk along path up to speed steps, but don't get closer than min_range
                                var destination = entity.position;
                                const max_steps = @min(effective_speed, @as(u32, @intCast(path_tiles.len)));
                                for (0..max_steps) |step_index| {
                                    const step_position = path_tiles[step_index];
                                    // Never step onto the target's own tile: shortestPath
                                    // includes the (occupied) destination as its final
                                    // tile, so stop before it regardless of min_range.
                                    if (step_position.x == target_position.x and step_position.y == target_position.y) break;
                                    const distance_from_target = functions.chebyshevDistance(step_position, target_position);
                                    if (distance_from_target < min_range) break;
                                    destination = step_position;
                                }

                                if (destination.x != entity.position.x or destination.y != entity.position.y) {
                                    // Order (LIFO, last runs first): wait, then move, then attack.
                                    pushEvents(current, &.{
                                        .{ .level_event = .{ .enemy_turn_attack = .{
                                            .entity_index = enemy_move.entity_index,
                                        } } },
                                        .{ .level_event = .{ .move_entity = .{
                                            .entity_index = enemy_move.entity_index,
                                            .destination = destination,
                                        } } },
                                        .{ .meta_event = .{ .wait = .{ .duration_milliseconds = turn_flow_wait_milliseconds } } },
                                    }, allocator);
                                } else {
                                    pushEvents(current, &.{.{ .level_event = .{ .enemy_turn_attack = .{
                                        .entity_index = enemy_move.entity_index,
                                    } } }}, allocator);
                                }
                            } else {
                                // No direct path — use reachable tiles, pick closest to target
                                const reachable = functions.reachableTiles(
                                    level.*,
                                    entity.position,
                                    entity.getEffectiveSpeed(),
                                    allocator,
                                );

                                // Pick the reachable tile closest to the target
                                // (but no nearer than min_range, and only if it
                                // improves on the current position). Ties in
                                // distance break by the (x, y) tile convention so
                                // the choice is defined, not scan-order-dependent.
                                var best_tile: ?Vector2 = null;
                                var best_distance: i32 = nearest_distance;
                                for (reachable) |tile| {
                                    const distance = functions.chebyshevDistance(tile, target_position);
                                    if (distance < min_range) continue;
                                    if (distance >= nearest_distance) continue; // must improve on current
                                    const is_better = best_tile == null or
                                        distance < best_distance or
                                        (distance == best_distance and tileBefore(tile, best_tile.?));
                                    if (is_better) {
                                        best_distance = distance;
                                        best_tile = tile;
                                    }
                                }

                                if (best_tile) |destination| {
                                    // Order (LIFO, last runs first): wait, then move, then attack.
                                    pushEvents(current, &.{
                                        .{ .level_event = .{ .enemy_turn_attack = .{
                                            .entity_index = enemy_move.entity_index,
                                        } } },
                                        .{ .level_event = .{ .move_entity = .{
                                            .entity_index = enemy_move.entity_index,
                                            .destination = destination,
                                        } } },
                                        .{ .meta_event = .{ .wait = .{ .duration_milliseconds = turn_flow_wait_milliseconds } } },
                                    }, allocator);
                                } else {
                                    // Can't improve position — just attack
                                    pushEvents(current, &.{.{ .level_event = .{ .enemy_turn_attack = .{
                                        .entity_index = enemy_move.entity_index,
                                    } } }}, allocator);
                                }
                            }
                        }
                    } else {
                        // No targets — skip to turn end
                        pushEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                            .entity_index = enemy_move.entity_index,
                        } } }}, allocator);
                    }
                },
                .enemy_turn_attack => |enemy_attack| {
                    const level = &current.level.?;
                    const entity = level.entities[enemy_attack.entity_index];

                    // A dead entity can't take its turn — skip to turn_end to
                    // advance the cycle. (Reactive effects like Reflect can
                    // kill an entity mid-turn, leaving its turn events already
                    // on the stack.)
                    if (entity.current_health == 0) {
                        pushEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                            .entity_index = enemy_attack.entity_index,
                        } } }}, allocator);
                        return;
                    }

                    const skill_ids = entity.collectSkillSlots(history.weapon_type_definitions);

                    // Evaluate all off-cooldown skills, partitioned by turn-ending vs not
                    var best_non_ending_id: ?SkillId = null;
                    var best_non_ending_priority: u32 = 0;
                    var best_non_ending_definition: ?Skill = null;

                    var best_ending_id: ?SkillId = null;
                    var best_ending_priority: u32 = 0;
                    var best_ending_definition: ?Skill = null;

                    // collectSkillSlots yields skills in slot order (1..8), and
                    // strict > below keeps the first at the best priority — so
                    // priority ties resolve to the lowest slot (the tiebreaking
                    // convention), per turn-ending / non-ending bucket.
                    for (&skill_ids) |maybe_skill_id| {
                        const skill_id = maybe_skill_id orelse continue;
                        if (entity.skill_cooldowns.get(skill_id) > 0) continue;
                        const skill_definition = lookups.getSkillDefinition(skill_id) orelse continue;

                        const skill_priority = skill_definition.priority(enemy_attack.entity_index, current.*);
                        if (skill_priority == 0) continue;

                        const ends_turn = skill_definition.skill_type == .weapon_skill or
                            skill_definition.skill_type == .spell;

                        if (ends_turn) {
                            if (skill_priority > best_ending_priority) {
                                best_ending_priority = skill_priority;
                                best_ending_id = skill_id;
                                best_ending_definition = skill_definition;
                            }
                        } else {
                            if (skill_priority > best_non_ending_priority) {
                                best_non_ending_priority = skill_priority;
                                best_non_ending_id = skill_id;
                                best_non_ending_definition = skill_definition;
                            }
                        }
                    }

                    // Use non-turn-ending skills first, then turn-ending
                    if (best_non_ending_id) |skill_id| {
                        const skill_definition = best_non_ending_definition.?;
                        const valid_targets = skill_definition.getValidTargets(
                            enemy_attack.entity_index,
                            current.*,
                            allocator,
                        );
                        const target = skill_definition.selectTarget(
                            enemy_attack.entity_index,
                            valid_targets,
                            current.*,
                        );

                        // Push another enemy_turn_attack after use_skill to re-evaluate.
                        // Order (LIFO, last runs first): wait, then skill, then re-evaluate.
                        pushEvents(current, &.{
                            .{ .level_event = .{ .enemy_turn_attack = .{
                                .entity_index = enemy_attack.entity_index,
                            } } },
                            .{ .level_event = .{ .use_skill = .{
                                .caster_index = enemy_attack.entity_index,
                                .skill_id = skill_id,
                                .target = target,
                            } } },
                            .{ .meta_event = .{ .wait = .{ .duration_milliseconds = turn_flow_wait_milliseconds } } },
                        }, allocator);
                    } else if (best_ending_id) |skill_id| {
                        const skill_definition = best_ending_definition.?;
                        const valid_targets = skill_definition.getValidTargets(
                            enemy_attack.entity_index,
                            current.*,
                            allocator,
                        );
                        const target = skill_definition.selectTarget(
                            enemy_attack.entity_index,
                            valid_targets,
                            current.*,
                        );

                        // Order (LIFO, last runs first): wait, then skill, then turn_end.
                        pushEvents(current, &.{
                            .{ .level_event = .{ .turn_end = .{
                                .entity_index = enemy_attack.entity_index,
                            } } },
                            .{ .level_event = .{ .use_skill = .{
                                .caster_index = enemy_attack.entity_index,
                                .skill_id = skill_id,
                                .target = target,
                            } } },
                            .{ .meta_event = .{ .wait = .{ .duration_milliseconds = turn_flow_wait_milliseconds } } },
                        }, allocator);
                    } else {
                        // No usable skills — end turn
                        pushEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                            .entity_index = enemy_attack.entity_index,
                        } } }}, allocator);
                    }
                },
                .use_skill => |use| {
                    const entity = getLevelEntity(current, use.caster_index);
                    entity.momentum += 1;

                    // Mission stat: skills used by the player. See DESIGN
                    // → Clones (clone system).
                    if (use.caster_index == 0) {
                        if (playerMissionPtr(current)) |mission| {
                            mission.skills_used += 1;
                        }
                    }

                    if (lookups.getSkillDefinition(use.skill_id)) |skill_definition| {
                        // Sound for the cast/swing, by skill type: weapon skills
                        // play the swing; spells/cantrips/enchantments/curses play
                        // the spell cast (cantrip/enchantment reuse `spell` — see
                        // TODO → Audio). See DESIGN → Audio.
                        if (!history.replaying) {
                            const cast_sound: types.SoundId = switch (skill_definition.skill_type) {
                                .weapon_skill => .weapon_swing,
                                .spell, .cantrip, .enchantment, .curse => .spell,
                            };
                            history.session.queueSound(history.backing_allocator, cast_sound);
                            // One-shot anim: show the skill's icon above the
                            // caster for 500ms. `current_event_index - 1` is
                            // this `use_skill` event's index (processEvent
                            // increments before dispatch). See DESIGN →
                            // Animation.
                            history.session.queueAnim(history.backing_allocator, .{
                                .event_index = history.current_event_index - 1,
                                .kind = .{ .skill_icon = .{
                                    .entity_index = use.caster_index,
                                    .skill_id = use.skill_id,
                                } },
                                .duration_us = 500_000,
                            });
                        }
                        // Push the skill's events
                        const skill_events = skill_definition.useSkill(
                            use.caster_index,
                            use.target,
                            current.*,
                            allocator,
                        );
                        pushEvents(current, skill_events, allocator);

                        // Set cooldown
                        if (skill_definition.cooldown) |base_cooldown| {
                            entity.skill_cooldowns.set(
                                use.skill_id,
                                entity.getEffectiveCooldown(base_cooldown),
                            );
                        }
                    }
                },
                .highlight_tiles => |highlight| {
                    const level = &current.level.?;
                    level.highlighted_tiles = highlight.tile_positions;
                },
                .clear_highlights => {
                    const level = &current.level.?;
                    level.highlighted_tiles = &.{};
                },
                .clear_prepared_skill => {
                    const level = &current.level.?;
                    level.prepared_skill = null;
                },
                .move_entity => |move| {
                    if (!history.replaying) history.session.queueSound(history.backing_allocator, .move);
                    const entity = getLevelEntity(current, move.entity_index);
                    entity.position = move.destination;
                    entity.momentum += 1;

                    // Mission stat: tiles moved by the player. See DESIGN
                    // → Clones (clone system).
                    if (move.entity_index == 0) {
                        if (playerMissionPtr(current)) |mission| {
                            mission.tiles_moved += 1;
                        }
                    }

                    // Push pickup, aggro check, and level-end check after
                    // movement. LIFO (last in array runs first), so the
                    // array order is: check_level_end, aggro_check,
                    // pickup_around → execution: pickup → aggro → level-end.
                    // check_level_end runs after aggro_check so newly-aggroed
                    // enemies are counted before the win check.
                    pushEvents(current, &.{
                        .{ .sub_level_event = .{ .check_level_end = .{} } },
                        .{ .sub_level_event = .{ .aggro_check = .{} } },
                        .{ .sub_level_event = .{ .pickup_around = .{
                            .entity_index = move.entity_index,
                        } } },
                    }, allocator);
                },
            }
        },
        .sub_level_event => |sub_level_event| {
            switch (sub_level_event) {
                .aggro_check => {
                    // Scan every inactive entity; for each, if any opposing
                    // entity is within ITS OWN aggro_range, activate it.
                    // Self-centric — one event covers the whole level. See
                    // DESIGN → Architecture.
                    const level = &current.level.?;
                    for (level.entities, 0..) |*entity, entity_index| {
                        if (entity.current_health == 0) continue;
                        if (entity.is_active) continue; // already aggroed

                        const aggro_range: i32 = @intCast(entity.aggro_range);
                        var sees_opponent = false;
                        for (level.entities, 0..) |other_entity, other_index| {
                            if (other_index == entity_index) continue;
                            if (other_entity.current_health == 0) continue;
                            if (other_entity.team == entity.team) continue;
                            if (functions.chebyshevDistance(entity.position, other_entity.position) <= aggro_range) {
                                sees_opponent = true;
                                break;
                            }
                        }
                        if (sees_opponent) {
                            activateEntity(history, @constCast(entity), @intCast(entity_index));
                        }
                    }
                },
                .check_level_end => {
                    // Lose condition: if the player is dead, the mission is
                    // failed — don't check the win condition (a dead player
                    // on the exit with no enemies would falsely trigger
                    // level completion). The mission_fail overlay is derived
                    // from player health in view(); see DESIGN → Architecture.
                    const level = &current.level.?;
                    if (level.entities[0].current_health == 0) return;

                    // Win condition: if the player is on level_end and no
                    // active enemies remain, end the level. Decoupled from
                    // aggro_check so it can also fire after `death` (killing
                    // the last enemy while standing on the exit ends the
                    // level without an extra move). Pushed AFTER aggro_check
                    // on the stack (LIFO → runs after) so newly-aggroed
                    // enemies are counted. See DESIGN → Architecture.
                    const player = level.entities[0];
                    if (level.level_end) |level_end| {
                        if (player.position.x == level_end.x and player.position.y == level_end.y) {
                            var has_active_enemies = false;
                            for (level.entities, 0..) |entity, entity_index| {
                                if (entity_index == 0) continue;
                                if (entity.current_health == 0) continue;
                                if (!entity.is_active) continue;
                                if (entity.team != player.team) {
                                    has_active_enemies = true;
                                    break;
                                }
                            }
                            if (!has_active_enemies) {
                                pushEvents(current, &.{
                                    .{ .meta_event = .{ .end_level = .{ .continuation = .default } } },
                                }, allocator);
                            }
                        }
                    }
                },
                .pickup_around => |pickup| {
                    const level = &current.level.?;
                    const entity = getLevelEntity(current, pickup.entity_index);
                    const pickup_radius: i32 = @intCast(entity.getEffectivePickupRadius(0));

                    // Pure CHECK: no mutation here. For each ground stack in
                    // range, push a pickup_items event keyed by position; the
                    // handler does the transfer. An empty move pushes nothing,
                    // so the combat log only sees actual pickups.
                    for (level.ground_items) |ground_item_stack| {
                        const distance = functions.chebyshevDistance(entity.position, ground_item_stack.position);
                        if (distance <= pickup_radius) {
                            pushEvents(current, &.{
                                .{ .sub_level_event = .{ .pickup_items = .{
                                    .entity_index = pickup.entity_index,
                                    .position = ground_item_stack.position,
                                } } },
                            }, allocator);
                        }
                    }
                },
                .pickup_items => |pickup| {
                    if (!history.replaying) history.session.queueSound(history.backing_allocator, .pickup);
                    const level = &current.level.?;
                    const entity = getLevelEntity(current, pickup.entity_index);

                    // Find the ground stack at the recorded position (one stack
                    // per position by invariant; pickup_around pushed exactly
                    // one event per in-range stack, so it is present).
                    var stack_index: ?usize = null;
                    for (level.ground_items, 0..) |ground_item_stack, index| {
                        if (ground_item_stack.position.x == pickup.position.x and
                            ground_item_stack.position.y == pickup.position.y)
                        {
                            stack_index = index;
                            break;
                        }
                    }
                    if (stack_index == null) @panic("pickup_items: ground stack not found at position");

                    // Transfer items into the entity's inventory (first-empty-
                    // slot); collect the ones that don't fit as leftovers.
                    // Items the PLAYER actually picks up also count toward the
                    // mission's converted-materials accumulator (the clone's
                    // rate numerator) — valued at salvage value regardless of
                    // what the player later does with the item. Leftover items
                    // that don't fit stay on the ground and don't count. See
                    // DESIGN → Clones (clone system).
                    const stack = level.ground_items[stack_index.?];
                    var leftover_items: std.ArrayList(types.Item) = .empty;
                    const is_player = pickup.entity_index == 0;
                    const mission_ptr: ?*types.Mission =
                        if (is_player) (if (current.mission) |*m| m else null) else null;
                    for (stack.items) |item| {
                        var placed = false;
                        for (&entity.inventory.slots) |*slot| {
                            if (slot.* == null) {
                                slot.* = item;
                                placed = true;
                                break;
                            }
                        }
                        if (placed) {
                            if (mission_ptr) |mission| {
                                const value = functions.computeSalvageValue(item, history.salvage_definitions);
                                mission.converted_materials_collected.add(value);
                            }
                        } else {
                            leftover_items.append(allocator, item) catch
                                @panic("failed to append leftover item");
                        }
                    }

                    // Rebuild ground_items: drop this stack if fully picked up,
                    // or replace it with the leftovers in place.
                    var rebuilt: std.ArrayList(types.GroundItems) = .empty;
                    for (level.ground_items, 0..) |ground_item_stack, index| {
                        if (index == stack_index.?) {
                            if (leftover_items.items.len > 0) {
                                rebuilt.append(allocator, .{
                                    .position = ground_item_stack.position,
                                    .items = leftover_items.toOwnedSlice(allocator) catch
                                        @panic("failed to allocate leftover items"),
                                }) catch @panic("failed to append leftover stack");
                            }
                        } else {
                            rebuilt.append(allocator, ground_item_stack) catch
                                @panic("failed to copy ground stack");
                        }
                    }
                    level.ground_items = rebuilt.toOwnedSlice(allocator) catch
                        @panic("failed to allocate ground items");
                },
                .stun => |stun| {
                    const attacker = getLevelEntity(current, stun.attacker_index);
                    const defender = getLevelEntity(current, stun.defender_index);

                    if (attacker.current_health == 0) return;
                    if (defender.current_health == 0) return;

                    const effective_duration = defender.getEffectiveIncomingStunDuration(stun.stun_duration);

                    if (effective_duration > 0) {
                        defender.stun_duration += effective_duration;

                        for (attacker.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onOutgoingStun(stun.attacker_index, current.*, allocator)) |effect_events| {
                                pushEvents(current, effect_events, allocator);
                            }
                        }
                        for (defender.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onIncomingStun(stun.defender_index, current.*, allocator)) |effect_events| {
                                pushEvents(current, effect_events, allocator);
                            }
                        }
                    }
                },
                .knockback => |knockback| {
                    const level = &current.level.?;
                    const attacker = getLevelEntity(current, knockback.attacker_index);
                    const defender = getLevelEntity(current, knockback.defender_index);

                    if (attacker.current_health == 0) return;
                    if (defender.current_health == 0) return;

                    // Trigger on_outgoing_knockback / on_incoming_knockback
                    for (attacker.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onOutgoingKnockback(knockback.attacker_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }
                    for (defender.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onIncomingKnockback(knockback.defender_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }

                    // Normalize direction: attacker -> defender, each axis to -1/0/+1
                    const raw_delta_x = defender.position.x - attacker.position.x;
                    const raw_delta_y = defender.position.y - attacker.position.y;
                    const direction_x: i32 = if (raw_delta_x > 0) 1 else if (raw_delta_x < 0) @as(i32, -1) else 0;
                    const direction_y: i32 = if (raw_delta_y > 0) 1 else if (raw_delta_y < 0) @as(i32, -1) else 0;

                    // Build tile and occupied sets for collision checking
                    var tile_set = std.AutoHashMap(Vector2, void).init(allocator);
                    for (level.level_tiles) |tile| {
                        tile_set.put(tile, {}) catch @panic("failed to build tile set");
                    }

                    var occupied = std.AutoHashMap(Vector2, void).init(allocator);
                    for (level.entities, 0..) |entity, entity_index| {
                        if (entity_index == knockback.defender_index) continue;
                        if (entity.current_health == 0) continue;
                        occupied.put(entity.position, {}) catch @panic("failed to build occupied set");
                    }

                    // Step incrementally in the knockback direction
                    var destination = defender.position;
                    var collided = false;
                    for (0..knockback.distance) |_| {
                        const next_position = Vector2{
                            .x = destination.x + direction_x,
                            .y = destination.y + direction_y,
                        };

                        if (!tile_set.contains(next_position) or occupied.contains(next_position)) {
                            collided = true;
                            break;
                        }

                        destination = next_position;
                    }

                    // Move entity if position changed
                    if (destination.x != defender.position.x or destination.y != defender.position.y) {
                        pushEvents(current, &.{
                            .{ .level_event = .{ .move_entity = .{
                                .entity_index = knockback.defender_index,
                                .destination = destination,
                                .is_forced = true,
                            } } },
                        }, allocator);
                    }

                    // Collision: push a collision event that applies the
                    // knockback_damage (with defender incoming modifiers) and
                    // fires the collision/damage callbacks. Kept as an event
                    // so the combat-log projection can see it.
                    if (collided) {
                        pushEvents(current, &.{
                            .{ .sub_level_event = .{ .collision = .{
                                .attacker_index = knockback.attacker_index,
                                .defender_index = knockback.defender_index,
                                .damage = knockback.knockback_damage,
                            } } },
                        }, allocator);
                    }
                },
                .collision => |collision| {
                    if (!history.replaying) history.session.queueSound(history.backing_allocator, .damage);
                    const attacker = getLevelEntity(current, collision.attacker_index);
                    const defender = getLevelEntity(current, collision.defender_index);

                    if (defender.current_health == 0) return;

                    // Trigger on_outgoing_collision / on_incoming_collision
                    for (attacker.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onOutgoingCollision(collision.attacker_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }
                    for (defender.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onIncomingCollision(collision.defender_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }

                    // Apply collision damage. The skill site already
                    // applied the attacker's outgoing modifiers (same as
                    // `attack`); the handler applies only the defender's
                    // incoming modifiers. Collision does NOT go through
                    // damage intercepts — deliberate counterplay around
                    // Reflect. See DESIGN → Architecture.
                    const incoming_damage = defender.getEffectiveIncomingDamage(collision.damage);

                    // Damage number always shows (even 0) so a connecting
                    // collision is observable — a fully-absorbed hit no longer
                    // looks like a whiff. The hit flash stays gated on > 0
                    // (a flash reads as "damage was dealt"). See DESIGN →
                    // Animation.
                    if (!history.replaying) {
                        history.session.queueAnim(history.backing_allocator, .{
                            .event_index = history.current_event_index - 1,
                            .kind = .{ .damage_number = .{
                                .entity_index = collision.defender_index,
                                .value = incoming_damage,
                                .direction = damageNumberDirection(attacker.position, defender.position),
                            } },
                            .duration_us = number_anim_duration_microseconds,
                        });
                    }

                    if (incoming_damage > 0) {
                        if (incoming_damage >= defender.current_health) {
                            defender.current_health = 0;
                        } else {
                            defender.current_health -= incoming_damage;
                        }

                        // Mission stats: damage dealt (player is attacker)
                        // / taken (player is defender). See DESIGN → Clones
                        // (clone system).
                        if (playerMissionPtr(current)) |mission| {
                            if (collision.attacker_index == 0) mission.damage_dealt += incoming_damage;
                            if (collision.defender_index == 0) mission.damage_taken += incoming_damage;
                        }

                        // One-shot hit flash on the defender (gated
                        // `!replaying`, same shape as the skill-icon anim).
                        // Only when damage is actually dealt. See DESIGN →
                        // Animation.
                        if (!history.replaying) {
                            history.session.queueAnim(history.backing_allocator, .{
                                .event_index = history.current_event_index - 1,
                                .kind = .{ .hit_flash = .{
                                    .entity_index = collision.defender_index,
                                } },
                                .duration_us = 250_000,
                            });
                        }

                        // Trigger on_outgoing_damage / on_incoming_damage
                        for (attacker.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onOutgoingDamage(collision.attacker_index, current.*, allocator)) |effect_events| {
                                pushEvents(current, effect_events, allocator);
                            }
                        }
                        for (defender.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onIncomingDamage(collision.defender_index, current.*, allocator)) |effect_events| {
                                pushEvents(current, effect_events, allocator);
                            }
                        }

                        if (defender.current_health == 0) {
                            pushEvents(current, &.{
                                .{ .sub_level_event = .{ .death = .{
                                    .entity_index = collision.defender_index,
                                } } },
                            }, allocator);
                        }
                    }
                },
                .attack => |attack| {
                    if (!history.replaying) history.session.queueSound(history.backing_allocator, .damage);
                    const attacker = getLevelEntity(current, attack.attacker_index);
                    const defender = getLevelEntity(current, attack.defender_index);

                    if (attacker.current_health == 0) return;
                    if (defender.current_health == 0) return;

                    // Trigger on_attack effect callbacks for attacker
                    if (attack.triggers_effects) {
                        for (attacker.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onAttack(attack.attacker_index, current.*, allocator)) |effect_events| {
                                pushEvents(current, effect_events, allocator);
                            }
                        }
                    }

                    // Damage pipeline: transform stage. The defender's effects
                    // can change the outgoing damage before defense (Reflect
                    // zeroes it and reflects it back). Gated on triggers_effects
                    // so a reflected attack (triggers_effects=false) is not
                    // re-intercepted — no reflect-vs-reflect loops.
                    var effective_outgoing = attack.outgoing_damage;
                    if (attack.triggers_effects) {
                        for (defender.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            const interception = definition.interceptIncomingDamage(
                                attack.defender_index,
                                attack.attacker_index,
                                effective_outgoing,
                                current.*,
                                allocator,
                            );
                            effective_outgoing = interception.damage;
                            pushEvents(current, interception.events, allocator);
                        }
                    }

                    // Calculate effective incoming damage
                    const incoming_damage = defender.getEffectiveIncomingDamage(effective_outgoing);

                    // Damage number always shows (even 0) so a connecting
                    // hit is observable — a fully-absorbed attack no longer
                    // looks like a whiff. The hit flash stays gated on > 0
                    // (a flash reads as "damage was dealt"). See DESIGN →
                    // Animation.
                    if (!history.replaying) {
                        history.session.queueAnim(history.backing_allocator, .{
                            .event_index = history.current_event_index - 1,
                            .kind = .{ .damage_number = .{
                                .entity_index = attack.defender_index,
                                .value = incoming_damage,
                                .direction = damageNumberDirection(attacker.position, defender.position),
                            } },
                            .duration_us = number_anim_duration_microseconds,
                        });
                    }

                    if (incoming_damage > 0) {
                        // Apply damage
                        if (incoming_damage >= defender.current_health) {
                            defender.current_health = 0;
                        } else {
                            defender.current_health -= incoming_damage;
                        }

                        // Mission stats: damage dealt (player is attacker)
                        // / taken (player is defender). See DESIGN → Clones
                        // (clone system).
                        if (playerMissionPtr(current)) |mission| {
                            if (attack.attacker_index == 0) mission.damage_dealt += incoming_damage;
                            if (attack.defender_index == 0) mission.damage_taken += incoming_damage;
                        }

                        // One-shot hit flash on the defender (gated
                        // `!replaying`, same shape as the skill-icon anim).
                        // Only when damage is actually dealt. See DESIGN →
                        // Animation.
                        if (!history.replaying) {
                            history.session.queueAnim(history.backing_allocator, .{
                                .event_index = history.current_event_index - 1,
                                .kind = .{ .hit_flash = .{
                                    .entity_index = attack.defender_index,
                                } },
                                .duration_us = 250_000,
                            });
                        }

                        // Trigger on_outgoing_damage / on_incoming_damage effect callbacks
                        if (attack.triggers_effects) {
                            for (attacker.active_effects) |active_effect| {
                                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                                if (definition.onOutgoingDamage(attack.attacker_index, current.*, allocator)) |effect_events| {
                                    pushEvents(current, effect_events, allocator);
                                }
                            }
                            for (defender.active_effects) |active_effect| {
                                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                                if (definition.onIncomingDamage(attack.defender_index, current.*, allocator)) |effect_events| {
                                    pushEvents(current, effect_events, allocator);
                                }
                            }
                        }

                        // Push death if defender health reached 0
                        if (defender.current_health == 0) {
                            pushEvents(current, &.{
                                .{ .sub_level_event = .{ .death = .{
                                    .entity_index = attack.defender_index,
                                } } },
                            }, allocator);
                        }

                        // Lifesteal: heal the attacker for the damage dealt
                        // (composes the generic heal primitive).
                        if (attack.heals_attacker) {
                            pushEvents(current, &.{
                                .{ .sub_level_event = .{ .heal = .{
                                    .entity_index = attack.attacker_index,
                                    .amount = incoming_damage,
                                } } },
                            }, allocator);
                        }
                    }
                },
                .create_effect => |create| {
                    const caster = getLevelEntity(current, create.caster_index);
                    const receiver = getLevelEntity(current, create.receiver_index);

                    if (receiver.current_health == 0) return;

                    // Calculate effective duration from receiver's incoming modifier
                    const effective_duration = receiver.getEffectiveIncomingSkillDuration(create.duration);
                    if (effective_duration == 0) return;

                    // Trigger on_outgoing_effect on caster's existing effects
                    for (caster.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onOutgoingEffect(create.caster_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }

                    // Trigger on_incoming_effect on receiver's existing effects (before adding new one)
                    for (receiver.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onIncomingEffect(create.receiver_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }

                    // Check if receiver already has this effect — extend duration if so
                    const effect_definition = lookups.getEffectDefinition(create.effect_id);
                    var found_existing = false;
                    for (@constCast(receiver.active_effects)) |*active_effect| {
                        if (active_effect.effect_id == create.effect_id) {
                            active_effect.duration += effective_duration;
                            found_existing = true;
                            break;
                        }
                    }

                    if (!found_existing) {
                        // Add as a new effect
                        var updated_effects: std.ArrayList(types.Effect) = .empty;
                        updated_effects.appendSlice(allocator, receiver.active_effects) catch
                            @panic("failed to copy active effects");
                        updated_effects.append(allocator, .{
                            .effect_id = create.effect_id,
                            .duration = effective_duration,
                            .additive_effect_modifiers = effect_definition.additive_effect_modifiers,
                        }) catch @panic("failed to append new effect");
                        receiver.active_effects = updated_effects.toOwnedSlice(allocator) catch
                            @panic("failed to allocate updated effects");
                    }

                    // Trigger on_effect_creation for the effect
                    if (effect_definition.onEffectCreation(create.receiver_index, current.*, allocator)) |creation_events| {
                        pushEvents(current, creation_events, allocator);
                    }
                },
                .death => |death| {
                    const level = &current.level.?;
                    const entity = level.entities[death.entity_index];

                    // Player death: play the defeat sound (side effect,
                    // gated !replaying) and freeze-frame — clear the
                    // remaining event stack so the rest of the enemy turn
                    // doesn't play out. The mission_fail overlay is derived
                    // from player health in view(), so no flag or event is
                    // needed. Undo reconstructs to the pre-enemy-turn idle
                    // point; the death state is derivable from health == 0.
                    // See DESIGN → Architecture.
                    if (death.entity_index == 0) {
                        if (!history.replaying) history.session.queueSound(history.backing_allocator, .defeat);
                        current.event_stack = &.{};
                        return;
                    }

                    // Trigger on_opponent_death on all alive, active entities from opposing teams
                    for (level.entities, 0..) |other_entity, other_index| {
                        if (other_index == death.entity_index) continue;
                        if (other_entity.current_health == 0) continue;
                        if (!other_entity.is_active) continue;
                        if (other_entity.team == entity.team) continue;
                        for (other_entity.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onOpponentDeath(@intCast(other_index), current.*, allocator)) |effect_events| {
                                pushEvents(current, effect_events, allocator);
                            }
                        }
                    }

                    // Drop items for non-player entities
                    if (death.entity_index != 0) {
                        var dropped_items: std.ArrayList(types.Item) = .empty;

                        // Drop equipped gear
                        if (entity.main_hand_weapon) |weapon|
                            dropped_items.append(allocator, .{ .weapon = weapon }) catch @panic("failed to append dropped item");
                        if (entity.off_hand_weapon) |weapon|
                            dropped_items.append(allocator, .{ .weapon = weapon }) catch @panic("failed to append dropped item");
                        if (entity.amulet) |amulet|
                            dropped_items.append(allocator, .{ .amulet = amulet }) catch @panic("failed to append dropped item");
                        if (entity.coat) |coat|
                            dropped_items.append(allocator, .{ .coat = coat }) catch @panic("failed to append dropped item");
                        if (entity.gloves) |gloves|
                            dropped_items.append(allocator, .{ .gloves = gloves }) catch @panic("failed to append dropped item");
                        if (entity.pants) |pants|
                            dropped_items.append(allocator, .{ .pants = pants }) catch @panic("failed to append dropped item");
                        if (entity.boots) |boots|
                            dropped_items.append(allocator, .{ .boots = boots }) catch @panic("failed to append dropped item");

                        // Drop inventory contents
                        for (&entity.inventory.slots) |slot| {
                            if (slot) |item| {
                                dropped_items.append(allocator, item) catch @panic("failed to append dropped item");
                            }
                        }

                        // Drop skill tomes for each equipped utility skill
                        for (&entity.equipped_utility_skills) |slot| {
                            if (slot) |skill_id| {
                                dropped_items.append(allocator, .{ .skill_tome = .{
                                    .skill = skill_id,
                                } }) catch @panic("failed to append dropped skill tome");
                            }
                        }

                        if (dropped_items.items.len > 0) {
                            const items_slice = dropped_items.toOwnedSlice(allocator) catch
                                @panic("failed to allocate dropped items");

                            // Find existing GroundItems at this position, or create new
                            var found_ground_items = false;
                            var updated_ground_items: std.ArrayList(types.GroundItems) = .empty;
                            for (level.ground_items) |ground_item_stack| {
                                if (ground_item_stack.position.x == entity.position.x and
                                    ground_item_stack.position.y == entity.position.y)
                                {
                                    // Merge into existing stack
                                    var merged: std.ArrayList(types.Item) = .empty;
                                    merged.appendSlice(allocator, ground_item_stack.items) catch
                                        @panic("failed to merge ground items");
                                    merged.appendSlice(allocator, items_slice) catch
                                        @panic("failed to merge ground items");
                                    updated_ground_items.append(allocator, .{
                                        .position = entity.position,
                                        .items = merged.toOwnedSlice(allocator) catch
                                            @panic("failed to allocate merged items"),
                                    }) catch @panic("failed to append ground items");
                                    found_ground_items = true;
                                } else {
                                    updated_ground_items.append(allocator, ground_item_stack) catch
                                        @panic("failed to append ground items");
                                }
                            }

                            if (!found_ground_items) {
                                updated_ground_items.append(allocator, .{
                                    .position = entity.position,
                                    .items = items_slice,
                                }) catch @panic("failed to append new ground items");
                            }

                            level.ground_items = updated_ground_items.toOwnedSlice(allocator) catch
                                @panic("failed to allocate ground items");
                        }
                    }

                    // A death changes the alive-enemy count; if the player
                    // is standing on the exit, re-check the win condition so
                    // killing the last enemy ends the level without an extra
                    // move. See DESIGN → Architecture.
                    pushEvents(current, &.{
                        .{ .sub_level_event = .{ .check_level_end = .{} } },
                    }, allocator);
                },
                .end_effect => |end| {
                    const entity = getLevelEntity(current, end.entity_index);

                    // Trigger on_effect_end callback
                    const definition = lookups.getEffectDefinition(end.effect_id);
                    if (definition.onEffectEnd(end.entity_index, current.*, allocator)) |effect_events| {
                        pushEvents(current, effect_events, allocator);
                    }

                    // Remove the effect from active_effects
                    var remaining: std.ArrayList(types.Effect) = .empty;
                    for (entity.active_effects) |active_effect| {
                        if (active_effect.effect_id != end.effect_id) {
                            remaining.append(allocator, active_effect) catch
                                @panic("failed to append remaining effect");
                        }
                    }
                    entity.active_effects = remaining.toOwnedSlice(allocator) catch
                        @panic("failed to allocate remaining effects");
                },
                .retreat => |retreat| {
                    const level = &current.level.?;
                    const entity = getLevelEntity(current, retreat.entity_index);

                    if (entity.current_health == 0) return;

                    // Trigger on_retreat effect callbacks
                    for (entity.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onRetreat(retreat.entity_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }

                    // Direction: away from target_position (opposite of knockback direction)
                    const raw_delta_x = entity.position.x - retreat.target_position.x;
                    const raw_delta_y = entity.position.y - retreat.target_position.y;
                    const direction_x: i32 = if (raw_delta_x > 0) 1 else if (raw_delta_x < 0) @as(i32, -1) else 0;
                    const direction_y: i32 = if (raw_delta_y > 0) 1 else if (raw_delta_y < 0) @as(i32, -1) else 0;

                    // Build tile and occupied sets for collision checking
                    var tile_set = std.AutoHashMap(Vector2, void).init(allocator);
                    for (level.level_tiles) |tile| {
                        tile_set.put(tile, {}) catch @panic("failed to build tile set");
                    }

                    var occupied = std.AutoHashMap(Vector2, void).init(allocator);
                    for (level.entities, 0..) |other_entity, entity_index| {
                        if (entity_index == retreat.entity_index) continue;
                        if (other_entity.current_health == 0) continue;
                        occupied.put(other_entity.position, {}) catch @panic("failed to build occupied set");
                    }

                    // Step incrementally away from target
                    var destination = entity.position;
                    for (0..retreat.distance) |_| {
                        const next_position = Vector2{
                            .x = destination.x + direction_x,
                            .y = destination.y + direction_y,
                        };

                        if (!tile_set.contains(next_position) or occupied.contains(next_position)) {
                            break;
                        }

                        destination = next_position;
                    }

                    // Move entity if position changed
                    if (destination.x != entity.position.x or destination.y != entity.position.y) {
                        pushEvents(current, &.{
                            .{ .level_event = .{ .move_entity = .{
                                .entity_index = retreat.entity_index,
                                .destination = destination,
                                .is_forced = true,
                            } } },
                        }, allocator);
                    }
                },
                .heal => |heal_event| {
                    const entity = getLevelEntity(current, heal_event.entity_index);
                    if (entity.current_health == 0) return; // no reviving via heal
                    const capacity = entity.getEffectiveMaxHealth() - entity.current_health;
                    const applied = @min(heal_event.amount, capacity);
                    entity.current_health += applied;
                    // Heal number (`+value`) floating up-right from the
                    // entity's top-left bbox corner. Gated `!replaying`.
                    // Only when heal is actually applied (a full-health heal
                    // shows nothing). See AGENTS Animation.
                    if (!history.replaying and applied > 0) {
                        history.session.queueAnim(history.backing_allocator, .{
                            .event_index = history.current_event_index - 1,
                            .kind = .{ .heal_number = .{
                                .entity_index = heal_event.entity_index,
                                .value = applied,
                            } },
                            .duration_us = number_anim_duration_microseconds,
                        });
                    }
                },
                .change_momentum => |change| {
                    const entity = getLevelEntity(current, change.entity_index);
                    if (entity.current_health == 0) return;
                    entity.momentum = functions.applySignedDelta(entity.momentum, change.delta);
                },
                .change_cooldown => |change| {
                    const entity = getLevelEntity(current, change.entity_index);
                    if (entity.current_health == 0) return;
                    const current_cooldown = entity.skill_cooldowns.get(change.skill_id);
                    entity.skill_cooldowns.set(change.skill_id, functions.applySignedDelta(current_cooldown, change.delta));
                },
                .swap_positions => |swap| {
                    const entity_a = getLevelEntity(current, swap.entity_a_index);
                    const entity_b = getLevelEntity(current, swap.entity_b_index);
                    if (entity_a.current_health == 0 or entity_b.current_health == 0) return;
                    // Capture both positions before either move, then reuse
                    // `move_entity` for both legs so all post-move events
                    // (sound, momentum, pickup, aggro, level-end) fire
                    // uniformly. `is_forced`: a swap is a magical teleport,
                    // not a voluntary walk. LIFO: entity_b moves first (to
                    // pos_a), then entity_a (to pos_b). See DESIGN →
                    // Architecture.
                    const pos_a = entity_a.position;
                    const pos_b = entity_b.position;
                    pushEvents(current, &.{
                        .{ .level_event = .{ .move_entity = .{
                            .entity_index = swap.entity_a_index,
                            .destination = pos_b,
                            .is_forced = true,
                        } } },
                        .{ .level_event = .{ .move_entity = .{
                            .entity_index = swap.entity_b_index,
                            .destination = pos_a,
                            .is_forced = true,
                        } } },
                    }, allocator);
                },
                .aggro_in_radius => |aggro| {
                    const level = &current.level.?;
                    const entity = level.entities[aggro.entity_index];
                    const radius: i32 = @intCast(aggro.radius);
                    for (level.entities, 0..) |*other_entity, other_index| {
                        if (other_index == aggro.entity_index) continue;
                        if (other_entity.current_health == 0) continue;
                        // No team filter: Howl rallies same-team entities
                        // (a wolf howling to aggro its pack), and aggroing
                        // opposing entities (including the player) is
                        // harmless — `is_active` on the player is ignored by
                        // the loops that skip entity 0.
                        if (functions.chebyshevDistance(entity.position, other_entity.position) <= radius) {
                            activateEntity(history, @constCast(other_entity), @intCast(other_index));
                        }
                    }
                },
                .reset_weapon_cooldowns => |reset| {
                    // Resolve the entity's weapon skills (slots 1-3) — needs
                    // weapon_type_definitions from history, hence a handler and
                    // not the skill's useSkill. Emit a change_cooldown per
                    // skill on cooldown (composes the cooldown primitive).
                    const entity = getLevelEntity(current, reset.entity_index);
                    if (entity.current_health == 0) return;
                    var slot: u8 = 1;
                    while (slot <= 3) : (slot += 1) {
                        const skill_id = entity.skillInSlot(slot, history.weapon_type_definitions) orelse continue;
                        const current_cooldown = entity.skill_cooldowns.get(skill_id);
                        if (current_cooldown == 0) continue;
                        pushEvents(current, &.{
                            .{ .sub_level_event = .{ .change_cooldown = .{
                                .entity_index = reset.entity_index,
                                .skill_id = skill_id,
                                .delta = -@as(i32, @intCast(current_cooldown)),
                            } } },
                        }, allocator);
                    }
                },
            }
        },
    }
}

