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
//! shared with the input handlers.

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const functions = @import("functions.zig");
const parser = @import("parser.zig");
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
    pushEvents(current, &.{
        .{ .level_event = .{ .player_use_skill = .{
            .skill_id = skill_id,
            .target = target,
        } } },
    }, allocator);
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

/// Push the gameplay start batch for a freshly-loaded level: player sync
/// (build_player_from_data, runs first) + per-entity aggro checks + the
/// player's turn_start (runs last). Shared by start_level (normal gameplay,
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
    // Aggro checks in the middle.
    for (0..current.level.?.entities.len) |entity_index| {
        start_events.append(allocator, .{ .sub_level_event = .{ .aggro_around = .{
            .entity_index = @intCast(entity_index),
        } } }) catch @panic("failed to append aggro event");
    }
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
/// one inline case and routes the rest here. Implementation lands in the next
/// slice (the handlers are mechanical — each sets a field). Until then this
/// panics so an unimplemented editor event fails fast rather than silently
/// no-op'ing (which would let the UI believe it edited something).
fn handleEditorEvent(
    current: *GameState,
    event: events.EditorEvent,
    allocator: std.mem.Allocator,
) void {
    _ = current;
    _ = event;
    _ = allocator;
    @panic("editor event handler not yet implemented");
}

fn tileBefore(a: Vector2, b: Vector2) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.y < b.y;
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
fn itemFitsGearSlot(item: types.Item, gear_slot: types.GearSlot) bool {
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
    switch (gear_slot) {
        .main_hand, .off_hand => cancelPreparedSkill(current),
        .boots => refreshMoveHighlights(current, allocator),
        else => {},
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

    const campaign_sections = parser.parseConfigFile(
        history.readReconstructionFile(campaign_path),
        allocator,
    ) catch @panic("failed to parse campaign file");

    current.campaign = parser.loadCampaign(
        campaign_sections,
        allocator,
    ) catch @panic("failed to parse campaign file");

    // Push start_hub with the player's current hub
    const hub_id = current.player_data.current_hub;
    pushEvents(current, &.{.{ .meta_event = .{ .start_hub = .{
        .hub_id = hub_id,
    } } }}, allocator);
}

/// Process a single event from the stack. Applies the event to the current

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
            // events (aggro_around) with no level loaded and crash.
            const should_checkpoint = switch (meta) {
                .start_level => |level| level.sets_checkpoint,
                .start_hub => |hub| hub.sets_checkpoint,
                else => false,
            };

            switch (meta) {
                .open_main_menu => {
                    current.transitionScreen(.main_menu);
                },
                .start_new_game => {
                    const parsed_sections = parser.parseConfigFile(
                        history.readReconstructionFile("data/new_player.txt"),
                        allocator,
                    ) catch @panic("failed to parse new_player.txt");

                    current.player_data = parser.loadPlayerSave(
                        parsed_sections,
                        allocator,
                    ) catch @panic("failed to parse new_player.txt");

                    loadCampaignAndPushHub(current, history, allocator);
                },
                .load_save => |load| {
                    const parsed_sections = parser.parseConfigFile(
                        history.readReconstructionFile(load.save_path),
                        allocator,
                    ) catch @panic("failed to parse save file");

                    current.player_data = parser.loadPlayerSave(
                        parsed_sections,
                        allocator,
                    ) catch @panic("failed to parse save file");

                    loadCampaignAndPushHub(current, history, allocator);
                },
                .save_game => |save| {
                    // Orchestrate: make PlayerData current, then write. LIFO means
                    // the last-pushed event runs first, so build_data_from_player
                    // (on top) syncs before write_save persists. Only sync when a
                    // working entity exists (hub/level); outside those, player 0
                    // isn't present and we write PlayerData as-is.
                    if (current.level != null or current.hub != null) {
                        pushEvents(current, &.{
                            .{ .meta_event = .{ .write_save = .{ .save_path = save.save_path } } },
                            .{ .super_event = .{ .build_data_from_player = .{ .entity_index = 0 } } },
                        }, allocator);
                    } else {
                        pushEvents(current, &.{
                            .{ .meta_event = .{ .write_save = .{ .save_path = save.save_path } } },
                        }, allocator);
                    }
                },
                .write_save => |write| {
                    // Side effect: skip during replay so undo/redo scrubbing
                    // doesn't rewrite the save (or spam download prompts on web).
                    if (history.replaying) return;
                    parser.writePlayerSaveToFile(
                        history.file_source,
                        write.save_path,
                        current.player_data,
                        allocator,
                    ) catch @panic("failed to write save file");
                },
                .start_hub => |start| {
                    // Build hub file path: data/campaigns/{campaign}/hubs/{hub_id}/hub.txt
                    const hub_path = std.fmt.allocPrint(
                        allocator,
                        "data/campaigns/{s}/hubs/{s}/hub.txt",
                        .{ current.player_data.current_campaign, start.hub_id },
                    ) catch @panic("failed to allocate hub path");

                    const hub_sections = parser.parseConfigFile(
                        history.readReconstructionFile(hub_path),
                        allocator,
                    ) catch @panic("failed to parse hub file");

                    current.hub = parser.loadHub(
                        hub_sections,
                        history.file_source,
                        allocator,
                    ) catch @panic("failed to parse hub file");

                    current.player_data.current_hub = start.hub_id;
                    current.transitionScreen(.hub);

                    // Sync player entity from PlayerData
                    pushEvents(current, &.{.{ .super_event = .{ .build_player_from_data = .{
                        .entity_index = 0,
                    } } }}, allocator);
                },
                .end_hub => {
                    // Preserve the player entity's changes back into PlayerData
                    // before the hub is discarded/replaced. Pushed on top so it
                    // runs before whatever continuation the exit path stacked
                    // below (LIFO). All hub-exit paths must route through here.
                    pushEvents(current, &.{.{ .super_event = .{ .build_data_from_player = .{
                        .entity_index = 0,
                    } } }}, allocator);
                },
                .open_editor => |start| {
                    // Load a mission into an Editor session. All reads go through
                    // history.readReconstructionFile so the reconstruction cache
                    // makes undo replay deterministic (see AGENTS → File System
                    // & IO → Reconstruction cache). buildEditorMission dedups
                    // the levels' inline definitions into a shared palette.
                    const mission_file_path = std.fmt.allocPrint(
                        allocator,
                        "{s}/mission.txt",
                        .{start.mission_path},
                    ) catch @panic("failed to allocate mission path");
                    const mission_sections = parser.parseConfigFile(
                        history.readReconstructionFile(mission_file_path),
                        allocator,
                    ) catch @panic("failed to parse mission file");
                    const mission = parser.loadMission(
                        mission_sections,
                        allocator,
                    ) catch @panic("failed to parse mission file");

                    // Player loadout (player.txt) — required for editor
                    // playtest/validation. Official missions ship one too.
                    const player_file_path = std.fmt.allocPrint(
                        allocator,
                        "{s}/player.txt",
                        .{start.mission_path},
                    ) catch @panic("failed to allocate player path");
                    const player_sections = parser.parseConfigFile(
                        history.readReconstructionFile(player_file_path),
                        allocator,
                    ) catch @panic("failed to parse player.txt");
                    const player_entity = parser.loadPlayerLoadout(player_sections, allocator) catch
                        @panic("failed to parse player.txt");

                    // Read + parse every level, then build the reference-based editor.
                    var level_sections: std.ArrayList([]const parser.Section) = .empty;
                    var level_index: u32 = 1;
                    while (level_index <= mission.level_count) : (level_index += 1) {
                        const level_path = std.fmt.allocPrint(
                            allocator,
                            "{s}/level_{d}.txt",
                            .{ start.mission_path, level_index },
                        ) catch @panic("failed to allocate level path");
                        const sections = parser.parseConfigFile(
                            history.readReconstructionFile(level_path),
                            allocator,
                        ) catch @panic("failed to parse level file");
                        level_sections.append(allocator, sections) catch @panic("failed to append level sections");
                    }
                    current.editor = parser.buildEditorMission(
                        mission,
                        player_entity,
                        level_sections.items,
                        history.file_source,
                        allocator,
                    ) catch @panic("failed to build editor mission");
                    current.transitionScreen(.editor);
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
                    current.level = parser.instantiateEditorLevel(editor.*, start.level_index, allocator);
                    current.mission = deepCopy(types.Mission, editor.mission, allocator);
                    current.mission.?.current_level_index = start.level_index + 1; // 1-based for gameplay handlers
                    if (editor.mode == .edit) editor.mode = .playtest;
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
                    current.level = parser.instantiateEditorLevel(editor.*, 0, allocator);
                    current.mission = deepCopy(types.Mission, editor.mission, allocator);
                    current.mission.?.current_level_index = 1;
                    editor.mode = .validate;
                    current.transitionScreen(.level);
                    pushGameplayStartEvents(current, allocator, false);
                },
                .end_validation => {
                    // Restore the editor after a validation run. Success
                    // semantics + replay attachment are deferred (online
                    // services); for now just return to edit mode.
                    current.editor.?.mode = .edit;
                    current.transitionScreen(.editor);
                },
                .start_mission => |start| {
                    const mission_file_path = std.fmt.allocPrint(
                        allocator,
                        "{s}/mission.txt",
                        .{start.mission_path},
                    ) catch @panic("failed to allocate mission path");

                    const mission_sections = parser.parseConfigFile(
                        history.readReconstructionFile(mission_file_path),
                        allocator,
                    ) catch @panic("failed to parse mission file");

                    current.mission = parser.loadMission(
                        mission_sections,
                        allocator,
                    ) catch @panic("failed to parse mission file");

                    current.mission.?.path = start.mission_path;
                    current.mission.?.current_level_index = 1;

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
                    // See AGENTS → Custom Missions & Online Services → Dreams.
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
                    // Return to the destination hub
                    if (end.hub_id) |hub_id| {
                        pushEvents(current, &.{.{ .meta_event = .{ .start_hub = .{
                            .hub_id = hub_id,
                        } } }}, allocator);
                    }
                },
                .start_level => |start| {
                    const level_path = std.fmt.allocPrint(
                        allocator,
                        "{s}/level_{d}.txt",
                        .{ start.mission_path, start.level_index },
                    ) catch @panic("failed to allocate level path");

                    const level_sections = parser.parseConfigFile(
                        history.readReconstructionFile(level_path),
                        allocator,
                    ) catch @panic("failed to parse level file");

                    current.level = parser.loadLevel(
                        level_sections,
                        history.file_source,
                        allocator,
                    ) catch @panic("failed to parse level file");

                    if (current.mission) |*mission| {
                        mission.current_level_index = start.level_index;
                    }

                    current.transitionScreen(.level);
                    pushGameplayStartEvents(current, allocator, true);
                },
                .end_level => {
                    // Editor exit guard: when an editor session is active, it
                    // owns the exit continuation — the gameplay default
                    // (next start_level / end_mission → start_hub) is
                    // suppressed/redirected. build_data_from_player is also
                    // skipped (playtest/validate are discard-semantics; the
                    // player's real PlayerData is unchanged). See AGENTS →
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
                    if (current.mission) |mission| {
                        if (mission.current_level_index < mission.level_count) {
                            // More levels — push the next one
                            const next_index = mission.current_level_index + 1;
                            pushEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                                .mission_path = mission.path,
                                .level_index = next_index,
                            } } }}, allocator);
                        } else {
                            // Last level done — end the mission
                            pushEvents(current, &.{.{ .meta_event = .{ .end_mission = .{
                                .hub_id = mission.end_hub,
                            } } }}, allocator);
                        }
                    }
                    // Preserve the player entity's changes back into PlayerData
                    // before the level is discarded/replaced. Pushed last so it
                    // runs on top of the continuation above (LIFO). All
                    // level-exit paths must route through here.
                    pushEvents(current, &.{.{ .super_event = .{ .build_data_from_player = .{
                        .entity_index = 0,
                    } } }}, allocator);
                },
                .wait => |wait_event| {
                    // Begin a real-time pause; update() drains it as frames
                    // elapse before the next event is processed.
                    current.waiting = .{
                        .remaining_microseconds = @as(u64, wait_event.duration_milliseconds) * 1000,
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
                .save_clone_info => {},
            }
        },
        .player_event => |player_event| {
            switch (player_event) {
                .swap_hands => {
                    const player = getPlayerEntity(current, 0);
                    const held_weapon = player.main_hand_weapon;
                    player.main_hand_weapon = player.off_hand_weapon;
                    player.off_hand_weapon = held_weapon;

                    // Swapping hands changes the first three skills, so cancel
                    // any skill prepared from the previous configuration.
                    cancelPreparedSkill(current);
                },
                .learn_skill => |learn| {
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

                    // Old gear (if any) drops back into the inventory slot.
                    slot.* = gearSlotItem(player, equip.gear_slot);
                    setGearSlot(player, equip.gear_slot, item);

                    applyGearChangeSideEffects(current, equip.gear_slot, allocator);
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
                    player.equipped_utility_skills[equip.slot_index] = equip.skill_id;

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
                },
                .unequip_utility_skill => |unequip| {
                    if (unequip.slot_index >= utility_skill_count) return;
                    const player = getPlayerEntity(current, 0);
                    player.equipped_utility_skills[unequip.slot_index] = null;

                    cancelPreparedSkill(current);
                },
            }
        },
        .hub_event => |hub_event| {
            switch (hub_event) {
                .move_player => |move| {
                    if (current.hub) |*hub| {
                        hub.player.position = move.destination;

                        // Check if the player landed on a mission exit
                        for (hub.mission_exits) |exit| {
                            if (exit.position.x == move.destination.x and
                                exit.position.y == move.destination.y)
                            {
                                const mission_path = std.fmt.allocPrint(
                                    allocator,
                                    "data/campaigns/{s}/missions/{s}",
                                    .{ current.player_data.current_campaign, exit.mission_id },
                                ) catch @panic("failed to allocate mission path");

                                // end_hub on top runs first (syncs the hub
                                // player entity into PlayerData), then the
                                // mission starts.
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
            }
        },
        .editor_event => |editor_event| {
            switch (editor_event) {
                .editor_set_active_level => |set| {
                    if (current.editor) |*editor| {
                        if (set.level_index < editor.levels.len) {
                            editor.active_level_index = set.level_index;
                        }
                    }
                },
                // The remaining editor events are handled in the dedicated
                // editor handler block below (handleEditorEvent). They are
                // pure state transforms on current.editor.?.levels[] or the
                // palette; undo/redo works by construction via deepCopy.
                else => |ev| handleEditorEvent(current, ev, allocator),
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

                    // Trigger on_end_turn for all active effects
                    for (entity.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onEndTurn(turn.entity_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }

                    // If this is the player's turn ending, push the full next round:
                    // all active/alive enemy turn_starts sorted by distance (closest first),
                    // plus the next player turn_start at the bottom (processed last).
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
                        // they are reproduced on replay. See AGENTS → Custom
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
                        // arbitrary order (see AGENTS.md tiebreaking convention).
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
                    // Non-player turn_end: no pushing needed, next turn_start is already on the stack
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
                // --- player-action orchestrators ---
                // Each pushes the same batch the input path used to push
                // directly, so behavior is unchanged; the only difference is
                // that one recorded event represents the whole action.
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
                    pushEvents(current, &.{
                        .{ .level_event = .{ .player_turn_attack = .{
                            .force_attack_step = skip.force_attack_step,
                        } } },
                        .{ .level_event = .clear_highlights },
                    }, allocator);
                },
                .player_cancel_skill => {
                    pushEvents(current, &.{
                        .{ .level_event = .clear_highlights },
                        .{ .level_event = .clear_prepared_skill },
                    }, allocator);
                },
                .player_skip_attack => {
                    pushEvents(current, &.{
                        .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
                        .{ .level_event = .clear_highlights },
                        .{ .level_event = .clear_prepared_skill },
                    }, allocator);
                },
                .player_use_skill => |use| {
                    // Whether the skill ends the turn is a property of the skill
                    // type; resolve it here so the recorded orchestrator stays
                    // a single event and the turn_end verb is replayed in order
                    // alongside the rest.
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
                .use_skill => |use| {
                    const entity = getLevelEntity(current, use.caster_index);
                    entity.momentum += 1;

                    if (lookups.getSkillDefinition(use.skill_id)) |skill_definition| {
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
                    const entity = getLevelEntity(current, move.entity_index);
                    entity.position = move.destination;
                    entity.momentum += 1;

                    // Push pickup and aggro checks after movement
                    pushEvents(current, &.{
                        .{ .sub_level_event = .{ .aggro_around = .{
                            .entity_index = move.entity_index,
                        } } },
                        .{ .sub_level_event = .{ .pickup_around = .{
                            .entity_index = move.entity_index,
                        } } },
                    }, allocator);
                },
            }
        },
        .sub_level_event => |sub_level_event| {
            switch (sub_level_event) {
                .aggro_around => |aggro| {
                    const level = &current.level.?;
                    const entity = level.entities[aggro.entity_index];
                    const aggro_range: i32 = @intCast(entity.aggro_range);

                    for (level.entities, 0..) |*other_entity, other_index| {
                        if (other_index == aggro.entity_index) continue;
                        if (other_entity.current_health == 0) continue;
                        if (other_entity.team == entity.team) continue;
                        if (other_entity.is_active) continue;
                        const distance = functions.chebyshevDistance(entity.position, other_entity.position);
                        if (distance <= aggro_range) {
                            @constCast(other_entity).is_active = true;
                        }
                    }

                    // After player aggro check: if player is on level_end,
                    // no active enemies alive, and stack is empty, end the level
                    if (aggro.entity_index == 0) {
                        if (level.level_end) |level_end| {
                            if (entity.position.x == level_end.x and entity.position.y == level_end.y) {
                                var has_active_enemies = false;
                                for (level.entities, 0..) |other_entity, other_index| {
                                    if (other_index == 0) continue;
                                    if (other_entity.current_health == 0) continue;
                                    if (!other_entity.is_active) continue;
                                    if (other_entity.team != entity.team) {
                                        has_active_enemies = true;
                                        break;
                                    }
                                }
                                if (!has_active_enemies) {
                                    pushEvents(current, &.{
                                        .{ .meta_event = .end_level },
                                    }, allocator);
                                }
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
                    const stack = level.ground_items[stack_index.?];
                    var leftover_items: std.ArrayList(types.Item) = .empty;
                    for (stack.items) |item| {
                        var placed = false;
                        for (&entity.inventory.slots) |*slot| {
                            if (slot.* == null) {
                                slot.* = item;
                                placed = true;
                                break;
                            }
                        }
                        if (!placed) {
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

                    // Apply collision damage (only the defender's incoming
                    // modifiers — collision isn't a weapon hit, so no attacker
                    // outgoing damage modifiers apply).
                    const incoming_damage = defender.getEffectiveIncomingDamage(collision.damage);
                    if (incoming_damage > 0) {
                        if (incoming_damage >= defender.current_health) {
                            defender.current_health = 0;
                        } else {
                            defender.current_health -= incoming_damage;
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

                    if (incoming_damage > 0) {
                        // Apply damage
                        if (incoming_damage >= defender.current_health) {
                            defender.current_health = 0;
                        } else {
                            defender.current_health -= incoming_damage;
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
                    const capacity = entity.max_health - entity.current_health;
                    entity.current_health += @min(heal_event.amount, capacity);
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
                    const temp = entity_a.position;
                    entity_a.position = entity_b.position;
                    entity_b.position = temp;
                },
                .aggro_in_radius => |aggro| {
                    const level = &current.level.?;
                    const entity = level.entities[aggro.entity_index];
                    const radius: i32 = @intCast(aggro.radius);
                    for (level.entities, 0..) |*other_entity, other_index| {
                        if (other_index == aggro.entity_index) continue;
                        if (other_entity.current_health == 0) continue;
                        if (other_entity.team == entity.team) continue;
                        if (functions.chebyshevDistance(entity.position, other_entity.position) <= radius) {
                            @constCast(other_entity).is_active = true;
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

