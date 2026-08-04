const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const functions = @import("functions.zig");
const input = @import("input.zig");
const parser = @import("parser.zig");
const lookups = @import("generated_lookups.zig");

const computeFrameLength = functions.computeFrameLength;

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;
const MetaEvent = events.MetaEvent;
const PlayerInput = input.PlayerInput;
const Vector2 = types.Vector2;
const Entity = types.Entity;
const SkillId = types.SkillId;
const Editor = types.Editor;
const ReplayViewer = types.ReplayViewer;
const Level = types.Level;
const WeaponType = types.WeaponType;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const ColorThemeDefinitions = types.ColorThemeDefinitions;
const Settings = types.Settings;
const Skill = @import("skills/skill.zig").Skill;
const SkillType = types.SkillType;
const utility_skill_count = types.utility_skill_count;

// ============================================================
// Core functions
// ============================================================

// `export` makes these visible to JS when compiled to WASM.
// The build.zig `export_symbol_names` list must include them too.

/// Handle inputs that can interrupt regardless of queue state.
fn handleAnytimeInput(
    history: *GameStateHistory,
    anytime: input.AnytimeInput,
    allocator: std.mem.Allocator,
) void {
    if (anytime.undo) {
        _ = history.undo(allocator, &processEvent);
    }

    if (anytime.redo) {
        _ = history.redo(allocator, &processEvent);
    }

    if (anytime.toggle_options_menu) {
        history.current_state.ui_state.options_menu_open = !history.current_state.ui_state.options_menu_open;
    }

    // When options menu is open, block all other input
    if (history.current_state.ui_state.options_menu_open) return;

    if (anytime.scroll_delta != 0) {
        const zoom_speed: f32 = 0.1;
        history.settings.camera_zoom = @max(0.1, history.settings.camera_zoom + anytime.scroll_delta * zoom_speed);
    }

    // In-game inputs only apply when in a hub or level
    const current = &history.current_state;
    if (current.screen == .hub or current.screen == .level) {
        const in_game = anytime.in_game;

        if (in_game.toggle_inventory) {
            current.ui_state.toggleMiddlePanel(.inventory);
        }

        if (in_game.toggle_gear) {
            current.ui_state.toggleMiddlePanel(.gear);
        }

        if (in_game.toggle_skills) {
            current.ui_state.toggleMiddlePanel(.skills);
        }

        if (in_game.toggle_entity_inspect) |entity_index| {
            if (current.ui_state.inspected_entity_index) |current_inspected| {
                if (current_inspected == entity_index) {
                    // Same entity — close the panel
                    current.ui_state.toggleMiddlePanel(.enemy_inspect);
                    current.ui_state.inspected_entity_index = null;
                } else {
                    // Different entity — switch target
                    current.ui_state.inspected_entity_index = entity_index;
                }
            } else {
                // Not inspecting — open panel
                current.ui_state.inspected_entity_index = entity_index;
                current.ui_state.toggleMiddlePanel(.enemy_inspect);
            }
        }

        if (in_game.toggle_world_map) {
            current.ui_state.toggleFullScreenOverlay(.world_map);
        }
        if (in_game.move_tile_cursor_to) |_| {
            // TODO: move tile cursor
        }

        if (in_game.swap_weapons) {
            queueEvents(current, &.{
                .{ .player_event = .swap_hands },
            }, allocator);
        }
    }
}

/// Handle inputs that are only accepted when the event queue is empty.
fn handleIdleInput(
    history: *GameStateHistory,
    idle: input.IdleInput,
    allocator: std.mem.Allocator,
) void {
    const current = &history.current_state;

    // Level turn phase input handling
    if (current.level) |*level| {
        if (level.turn_phase) |turn_phase| {
            switch (turn_phase) {
                .player_move => {
                    if (idle.tile_clicked) |clicked_position| {
                        // Check if the clicked tile is in the highlighted (reachable) set
                        var is_reachable = false;
                        for (level.highlighted_tiles) |tile| {
                            if (tile.x == clicked_position.x and tile.y == clicked_position.y) {
                                is_reachable = true;
                                break;
                            }
                        }
                        if (is_reachable) {
                            level.highlighted_tiles = &.{};
                            level.turn_phase = null;
                            queueEvents(current, &.{
                                .{ .level_event = .player_turn_attack },
                                .{ .level_event = .{ .move_entity = .{
                                    .entity_index = 0,
                                    .destination = clicked_position,
                                } } },
                            }, allocator);
                        }
                    }

                    if (idle.skip) {
                        // Skip movement, go straight to attack phase
                        level.highlighted_tiles = &.{};
                        level.turn_phase = null;
                        queueEvents(current, &.{
                            .{ .level_event = .player_turn_attack },
                        }, allocator);
                    }
                },
                .player_attack => {
                    if (idle.skill_slot_selected) |slot| {
                        const player = level.entities[0];
                        if (resolveSkillSlot(slot, player, history.weapon_type_definitions)) |skill_id| {
                            // Check cooldown
                            if (player.skill_cooldowns.get(skill_id) > 0) return;

                            if (lookups.getSkillDefinition(skill_id)) |skill_definition| {
                                if (skill_definition.uses_targeting) {
                                    // Check auto_target_at_cursor: if cursor is on a valid target, use immediately
                                    if (history.settings.auto_target_at_cursor) {
                                        if (level.tile_cursor) |cursor_position| {
                                            const valid_targets = skill_definition.getValidTargets(0, current.*, allocator);
                                            if (valid_targets) |targets| {
                                                for (targets) |target| {
                                                    if (target.x == cursor_position.x and target.y == cursor_position.y) {
                                                        queuePlayerSkillUse(current, level, skill_id, skill_definition, cursor_position, allocator);
                                                        return;
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Begin targeting — queue player_prepare_skill
                                    level.prepared_skill = skill_id;
                                    queueEvents(current, &.{
                                        .{ .level_event = .{ .player_prepare_skill = .{
                                            .caster_index = 0,
                                            .skill_id = skill_id,
                                        } } },
                                    }, allocator);
                                } else {
                                    // No targeting — use immediately
                                    queuePlayerSkillUse(current, level, skill_id, skill_definition, null, allocator);
                                }
                            }
                        }
                    }

                    if (idle.confirm) {
                        // Confirm = simulated tile click at cursor position
                        if (level.tile_cursor) |cursor_position| {
                            if (level.prepared_skill) |skill_id| {
                                // Check if cursor is on a highlighted (valid) tile
                                var is_valid = false;
                                for (level.highlighted_tiles) |tile| {
                                    if (tile.x == cursor_position.x and tile.y == cursor_position.y) {
                                        is_valid = true;
                                        break;
                                    }
                                }
                                if (is_valid) {
                                    if (lookups.getSkillDefinition(skill_id)) |skill_definition| {
                                        queuePlayerSkillUse(current, level, skill_id, skill_definition, cursor_position, allocator);
                                    }
                                }
                            }
                        }
                    }

                    if (idle.cancel) {
                        // Cancel skill targeting
                        if (level.prepared_skill != null) {
                            level.prepared_skill = null;
                            level.highlighted_tiles = &.{};
                            // Stay in player_attack phase
                        }
                    }

                    if (idle.skip) {
                        // Skip attack, end turn
                        level.turn_phase = null;
                        level.prepared_skill = null;
                        level.highlighted_tiles = &.{};
                        queueEvents(current, &.{
                            .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
                        }, allocator);
                    }
                },
            }
            return;
        }
    }

    if (idle.tile_clicked) |clicked_position| {
        if (current.hub) |hub| {
            // Check if an NPC is on the clicked tile
            var clicked_npc: ?u32 = null;
            for (hub.npcs, 0..) |npc, npc_index| {
                if (npc.entity.position.x == clicked_position.x and
                    npc.entity.position.y == clicked_position.y)
                {
                    clicked_npc = @intCast(npc_index);
                    break;
                }
            }

            if (clicked_npc) |npc_index| {
                queueEvents(current, &.{
                    .{ .hub_event = .{ .interact_with_npc = .{
                        .npc_index = npc_index,
                    } } },
                }, allocator);
            } else {
                // Move to clicked tile if walkable
                var is_walkable = false;
                for (hub.hub_tiles) |tile| {
                    if (tile.x == clicked_position.x and tile.y == clicked_position.y) {
                        is_walkable = true;
                        break;
                    }
                }
                if (is_walkable) {
                    queueEvents(current, &.{
                        .{ .hub_event = .{ .move_player = .{
                            .destination = clicked_position,
                        } } },
                    }, allocator);
                }
            }
        }
    }

    if (idle.skill_slot_selected) |_| {
        // TODO: resolve slot to SkillId, begin skill targeting or queue skill use
        // if Settings.auto_target_at_cursor, check tile cursor position and use skill immediately if valid target
    }

    if (idle.confirm) {
        // TODO: confirm current action (e.g. skill target selection)
    }

    if (idle.cancel) {
        // TODO: cancel current action (e.g. deselect skill)
    }
}

/// Resolve a skill bar slot (1-8) to a SkillId for the given entity.
/// Slots 1-2: main hand weapon skills (skill_1, skill_2 from weapon type definition)
/// Slot 3: off hand weapon skill (skill_3 from off hand weapon type definition)
/// Slots 4-8: equipped utility skills (indices 0-4)
fn resolveSkillSlot(
    slot: u8,
    entity: Entity,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
) ?SkillId {
    return switch (slot) {
        1 => if (entity.main_hand_weapon) |weapon| weapon_type_definitions[@intFromEnum(weapon.weapon_type)].skill_1 else null,
        2 => if (entity.main_hand_weapon) |weapon| weapon_type_definitions[@intFromEnum(weapon.weapon_type)].skill_2 else null,
        3 => if (entity.off_hand_weapon) |weapon| weapon_type_definitions[@intFromEnum(weapon.weapon_type)].skill_3 else null,
        4 => entity.equipped_utility_skills[0],
        5 => entity.equipped_utility_skills[1],
        6 => entity.equipped_utility_skills[2],
        7 => entity.equipped_utility_skills[3],
        8 => entity.equipped_utility_skills[4],
        else => null,
    };
}

/// Queue a skill use for the player, followed by either turn_end (for
/// weapon_skill/spell) or player_turn_attack (for cantrip/enchantment/curse).
/// Collect all SkillIds available to an entity (weapon skills + utility skills).
/// Main hand contributes skill_1 and skill_2, off hand contributes skill_3.
fn collectEntitySkillIds(
    entity: Entity,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
) [utility_skill_count + 3]?SkillId {
    const main_hand_skills: [2]?SkillId = if (entity.main_hand_weapon) |weapon| blk: {
        const definition = weapon_type_definitions[@intFromEnum(weapon.weapon_type)];
        break :blk .{ definition.skill_1, definition.skill_2 };
    } else .{ null, null };

    const off_hand_skill: ?SkillId = if (entity.off_hand_weapon) |weapon|
        weapon_type_definitions[@intFromEnum(weapon.weapon_type)].skill_3
    else
        null;

    var result: [utility_skill_count + 3]?SkillId = undefined;
    result[0] = main_hand_skills[0];
    result[1] = main_hand_skills[1];
    result[2] = off_hand_skill;
    for (entity.equipped_utility_skills, 0..) |skill, index| {
        result[3 + index] = skill;
    }
    return result;
}

/// Compute the minimum effective range across all off-cooldown skills an entity has.
/// This is the closest distance the entity needs to be to use at least one skill.
/// Uses range if the skill has it, radius if not.
/// Returns null if no skills are off cooldown (shouldn't normally happen).
fn computeMinRange(
    entity: Entity,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
) ?u32 {
    const skill_ids = collectEntitySkillIds(entity, weapon_type_definitions);
    var min_range: ?u32 = null;

    for (&skill_ids) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (entity.skill_cooldowns.get(skill_id) > 0) continue;

        const skill_definition = lookups.getSkillDefinition(skill_id) orelse continue;

        const effective_range: u32 = if (skill_definition.range) |range|
            entity.getEffectiveRange(range)
        else if (skill_definition.radius) |radius|
            entity.getEffectiveRadius(radius)
        else
            0;

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

/// Queue a skill use for the player, followed by turn_end if the skill
/// type ends the turn (weapon_skill/spell). For non-turn-ending skills
/// (cantrip/enchantment/curse), turn_phase stays as player_attack so
/// idle input picks up again after use_skill processes.
fn queuePlayerSkillUse(
    current: *GameState,
    level: *types.Level,
    skill_id: SkillId,
    skill_definition: Skill,
    target: ?Vector2,
    allocator: std.mem.Allocator,
) void {
    level.prepared_skill = null;
    level.highlighted_tiles = &.{};

    const ends_turn = skill_definition.skill_type == .weapon_skill or
        skill_definition.skill_type == .spell;

    if (ends_turn) {
        level.turn_phase = null;
        queueEvents(current, &.{
            .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
            .{ .level_event = .{ .use_skill = .{
                .caster_index = 0,
                .skill_id = skill_id,
                .target = target,
            } } },
        }, allocator);
    } else {
        // Don't clear turn_phase — stays as player_attack.
        // Stack empties after use_skill, idle input resumes.
        queueEvents(current, &.{
            .{ .level_event = .{ .use_skill = .{
                .caster_index = 0,
                .skill_id = skill_id,
                .target = target,
            } } },
        }, allocator);
    }
}

/// Push events onto the event queue (stack). Events are processed from
/// the back, so the last event pushed is processed first.
fn queueEvents(
    current: *GameState,
    new_events: []const Event,
    allocator: std.mem.Allocator,
) void {
    if (new_events.len == 0) return;

    if (current.event_stack.len == 0) {
        current.event_stack = allocator.dupe(
            Event,
            new_events,
        ) catch @panic("failed to allocate event queue");
        return;
    }

    const combined = allocator.alloc(
        Event,
        current.event_stack.len + new_events.len,
    ) catch @panic("failed to allocate event queue");

    @memcpy(combined[0..current.event_stack.len], current.event_stack);
    @memcpy(combined[current.event_stack.len..], new_events);
    current.event_stack = combined;
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

/// Load the campaign from player_data.current_campaign and queue a start_hub
/// event for player_data.current_hub.
fn loadCampaignAndQueueHub(
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

    const campaign_parsed = parser.parseConfigFileFromPath(
        history.directory,
        history.io,
        campaign_path,
        allocator,
    ) catch @panic("failed to read campaign file");

    current.campaign = parser.loadCampaign(
        campaign_parsed.sections,
        allocator,
    ) catch @panic("failed to parse campaign file");

    // Queue start_hub with the player's current hub
    const hub_id = current.player_data.current_hub;
    queueEvents(current, &.{.{ .meta_event = .{ .start_hub = .{
        .hub_id = hub_id,
    } } }}, allocator);
}

/// Process a single event from the queue. Applies the event to the current
/// state and records it in event history. Also used by undo/redo replay.
fn processEvent(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
) void {
    const current = &history.current_state;

    if (current.event_stack.len == 0) return;

    // Pop the last event from the queue
    const next_event = current.event_stack[current.event_stack.len - 1];
    current.event_stack = current.event_stack[0 .. current.event_stack.len - 1];

    // Record in event history
    history.event_history.append(allocator, next_event) catch @panic("failed to append event");
    history.current_event_index += 1;

    switch (next_event) {
        .meta_event => |meta| {
            const should_checkpoint = switch (meta) {
                .start_level => |level| level.sets_checkpoint,
                .start_hub => |hub| hub.sets_checkpoint,
                else => false,
            };
            if (should_checkpoint) {
                history.setCheckpoint(allocator);
            }

            switch (meta) {
                .open_main_menu => {
                    current.transitionScreen(.main_menu);
                },
                .start_new_game => {
                    const parsed = parser.parseConfigFileFromPath(
                        history.directory,
                        history.io,
                        "data/new_player.txt",
                        allocator,
                    ) catch @panic("failed to read new_player.txt");

                    current.player_data = parser.loadPlayerSave(
                        parsed.sections,
                        allocator,
                    ) catch @panic("failed to parse new_player.txt");

                    loadCampaignAndQueueHub(current, history, allocator);
                },
                .load_save => |load| {
                    const parsed = parser.parseConfigFileFromPath(
                        history.directory,
                        history.io,
                        load.save_path,
                        allocator,
                    ) catch @panic("failed to read save file");

                    current.player_data = parser.loadPlayerSave(
                        parsed.sections,
                        allocator,
                    ) catch @panic("failed to parse save file");

                    loadCampaignAndQueueHub(current, history, allocator);
                },
                .save_game => |save| {
                    parser.writePlayerSaveToFile(
                        history.directory,
                        history.io,
                        save.save_path,
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

                    const hub_parsed = parser.parseConfigFileFromPath(
                        history.directory,
                        history.io,
                        hub_path,
                        allocator,
                    ) catch @panic("failed to read hub file");

                    current.hub = parser.loadHub(
                        hub_parsed.sections,
                        allocator,
                    ) catch @panic("failed to parse hub file");

                    current.player_data.current_hub = start.hub_id;
                    current.transitionScreen(.hub);

                    // Sync player entity from PlayerData
                    queueEvents(current, &.{.{ .super_event = .{ .build_player_from_data = .{
                        .entity_index = 0,
                    } } }}, allocator);
                },
                .end_hub => {},
                .start_mission => |start| {
                    const mission_file_path = std.fmt.allocPrint(
                        allocator,
                        "{s}/mission.txt",
                        .{start.mission_path},
                    ) catch @panic("failed to allocate mission path");

                    const mission_parsed = parser.parseConfigFileFromPath(
                        history.directory,
                        history.io,
                        mission_file_path,
                        allocator,
                    ) catch @panic("failed to read mission file");

                    current.mission = parser.loadMission(
                        mission_parsed.sections,
                        allocator,
                    ) catch @panic("failed to parse mission file");

                    current.mission.?.path = start.mission_path;
                    current.mission.?.current_level_index = 1;

                    // Queue the first level
                    queueEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                        .mission_path = start.mission_path,
                        .level_index = 1,
                    } } }}, allocator);
                },
                .end_mission => |end| {
                    // Return to the destination hub
                    if (end.hub_id) |hub_id| {
                        queueEvents(current, &.{.{ .meta_event = .{ .start_hub = .{
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

                    const level_parsed = parser.parseConfigFileFromPath(
                        history.directory,
                        history.io,
                        level_path,
                        allocator,
                    ) catch @panic("failed to read level file");

                    current.level = parser.loadLevel(
                        level_parsed.sections,
                        allocator,
                    ) catch @panic("failed to parse level file");

                    if (current.mission) |*mission| {
                        mission.current_level_index = start.level_index;
                    }

                    current.transitionScreen(.level);

                    // Sync player entity from PlayerData, check initial aggro, then start player turn
                    var start_events: std.ArrayList(Event) = .empty;

                    // Player turn_start at bottom of LIFO (processed last, after sync and aggro)
                    start_events.append(allocator, .{ .level_event = .{ .turn_start = .{
                        .entity_index = 0,
                    } } }) catch @panic("failed to append turn_start");

                    // Aggro checks in the middle
                    for (0..current.level.?.entities.len) |entity_index| {
                        start_events.append(allocator, .{ .sub_level_event = .{ .aggro_around = .{
                            .entity_index = @intCast(entity_index),
                        } } }) catch @panic("failed to append aggro event");
                    }

                    // Player sync on top (processed first)
                    start_events.append(allocator, .{ .super_event = .{ .build_player_from_data = .{
                        .entity_index = 0,
                    } } }) catch @panic("failed to append build_player_from_data");

                    queueEvents(current, start_events.items, allocator);
                },
                .end_level => {
                    if (current.mission) |mission| {
                        if (mission.current_level_index < mission.level_count) {
                            // More levels — queue the next one
                            const next_index = mission.current_level_index + 1;
                            queueEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                                .mission_path = mission.path,
                                .level_index = next_index,
                            } } }}, allocator);
                        } else {
                            // Last level done — end the mission
                            queueEvents(current, &.{.{ .meta_event = .{ .end_mission = .{
                                .hub_id = mission.end_hub,
                            } } }}, allocator);
                        }
                    }
                },
                else => {},
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

                    // If in a level with a prepared skill, cancel targeting
                    if (current.level) |*level| {
                        if (level.prepared_skill != null) {
                            level.prepared_skill = null;
                            level.highlighted_tiles = &.{};
                        }
                    }
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

                    // Swap the inventory item with the appropriate gear slot
                    switch (item) {
                        .weapon => |weapon| {
                            if (equip.main_hand) {
                                slot.* = if (player.main_hand_weapon) |old| .{ .weapon = old } else null;
                                player.main_hand_weapon = weapon;
                            } else {
                                slot.* = if (player.off_hand_weapon) |old| .{ .weapon = old } else null;
                                player.off_hand_weapon = weapon;
                            }
                        },
                        .amulet => |amulet| {
                            slot.* = if (player.amulet) |old| .{ .amulet = old } else null;
                            player.amulet = amulet;
                        },
                        .coat => |coat| {
                            slot.* = if (player.coat) |old| .{ .coat = old } else null;
                            player.coat = coat;
                        },
                        .gloves => |gloves| {
                            slot.* = if (player.gloves) |old| .{ .gloves = old } else null;
                            player.gloves = gloves;
                        },
                        .pants => |pants| {
                            slot.* = if (player.pants) |old| .{ .pants = old } else null;
                            player.pants = pants;
                        },
                        .boots => |boots| {
                            slot.* = if (player.boots) |old| .{ .boots = old } else null;
                            player.boots = boots;
                        },
                        .skill_tome => return,
                    }
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

                                queueEvents(current, &.{.{ .meta_event = .{ .start_mission = .{
                                    .mission_path = mission_path,
                                    .start_hub_id = current.player_data.current_hub,
                                    .end_hub_id = null,
                                } } }}, allocator);
                                break;
                            }
                        }
                    }
                },
                .interact_with_npc => {},
            }
        },
        .editor_event => |editor_event| {
            _ = editor_event;
            _ = current.editor;
        },
        .sub_editor_event => |sub_editor_event| {
            _ = sub_editor_event;
            _ = current.editor;
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
                            queueEvents(current, effect_events, allocator);
                        }
                    }

                    // 3. Reduce all effect durations by 1, queue end_effect for expired effects
                    var remaining_effects: std.ArrayList(types.Effect) = .empty;
                    for (entity.active_effects) |active_effect| {
                        if (active_effect.duration <= 1) {
                            queueEvents(current, &.{.{ .sub_level_event = .{ .end_effect = .{
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
                        queueEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                            .entity_index = turn.entity_index,
                        } } }}, allocator);
                    } else if (turn.entity_index == 0) {
                        // Player turn
                        queueEvents(current, &.{.{ .level_event = .player_turn_move }}, allocator);
                    } else {
                        // Enemy turn
                        queueEvents(current, &.{.{ .level_event = .{ .enemy_turn_move = .{
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
                            queueEvents(current, effect_events, allocator);
                        }
                    }

                    // If this is the player's turn ending, queue the full next round:
                    // all active/alive enemy turn_starts sorted by distance (closest first),
                    // plus the next player turn_start at the bottom (processed last).
                    if (turn.entity_index == 0) {
                        const level = &current.level.?;
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

                        // Sort by distance ascending (closest first)
                        std.mem.sort(EntityDistance, enemy_distances.items, {}, struct {
                            fn lessThan(_: void, a: EntityDistance, b: EntityDistance) bool {
                                return a.distance < b.distance;
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

                        queueEvents(current, round_events.items, allocator);
                    }
                    // Non-player turn_end: no queuing needed, next turn_start is already on the stack
                },
                .player_turn_move => {
                    const level = &current.level.?;
                    const player = level.entities[0];
                    const reachable = functions.reachableTiles(
                        level.*,
                        player.position,
                        player.getEffectiveSpeed(),
                        allocator,
                    );

                    level.highlighted_tiles = reachable;
                    level.turn_phase = .player_move;

                    // Event stack is now empty — handleIdleInput will pick up
                    // tile clicks and skip actions based on turn_phase.
                },
                .player_turn_attack => {
                    const level = &current.level.?;

                    // Auto-skip attack step out of combat: if no active enemies exist,
                    // go straight to turn_end
                    if (history.settings.auto_skip_attack_step_out_of_combat) {
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
                            queueEvents(current, &.{
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
                            queueEvents(current, &.{.{ .level_event = .{ .enemy_turn_attack = .{
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
                                    const distance_from_target = functions.chebyshevDistance(step_position, target_position);
                                    if (distance_from_target < min_range) break;
                                    destination = step_position;
                                }

                                if (destination.x != entity.position.x or destination.y != entity.position.y) {
                                    queueEvents(current, &.{
                                        .{ .level_event = .{ .enemy_turn_attack = .{
                                            .entity_index = enemy_move.entity_index,
                                        } } },
                                        .{ .level_event = .{ .move_entity = .{
                                            .entity_index = enemy_move.entity_index,
                                            .destination = destination,
                                        } } },
                                    }, allocator);
                                } else {
                                    queueEvents(current, &.{.{ .level_event = .{ .enemy_turn_attack = .{
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

                                var best_tile: ?Vector2 = null;
                                var best_distance: i32 = nearest_distance; // must improve on current
                                for (reachable) |tile| {
                                    const distance = functions.chebyshevDistance(tile, target_position);
                                    if (distance >= min_range and distance < best_distance) {
                                        best_distance = distance;
                                        best_tile = tile;
                                    }
                                }

                                if (best_tile) |destination| {
                                    queueEvents(current, &.{
                                        .{ .level_event = .{ .enemy_turn_attack = .{
                                            .entity_index = enemy_move.entity_index,
                                        } } },
                                        .{ .level_event = .{ .move_entity = .{
                                            .entity_index = enemy_move.entity_index,
                                            .destination = destination,
                                        } } },
                                    }, allocator);
                                } else {
                                    // Can't improve position — just attack
                                    queueEvents(current, &.{.{ .level_event = .{ .enemy_turn_attack = .{
                                        .entity_index = enemy_move.entity_index,
                                    } } }}, allocator);
                                }
                            }
                        }
                    } else {
                        // No targets — skip to turn end
                        queueEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                            .entity_index = enemy_move.entity_index,
                        } } }}, allocator);
                    }
                },
                .enemy_turn_attack => |enemy_attack| {
                    const level = &current.level.?;
                    const entity = level.entities[enemy_attack.entity_index];
                    const skill_ids = collectEntitySkillIds(entity, history.weapon_type_definitions);

                    // Evaluate all off-cooldown skills, partitioned by turn-ending vs not
                    var best_non_ending_id: ?SkillId = null;
                    var best_non_ending_priority: f32 = 0;
                    var best_non_ending_definition: ?Skill = null;

                    var best_ending_id: ?SkillId = null;
                    var best_ending_priority: f32 = 0;
                    var best_ending_definition: ?Skill = null;

                    for (&skill_ids) |maybe_skill_id| {
                        const skill_id = maybe_skill_id orelse continue;
                        if (entity.skill_cooldowns.get(skill_id) > 0) continue;
                        const skill_definition = lookups.getSkillDefinition(skill_id) orelse continue;

                        const skill_priority = skill_definition.priority(enemy_attack.entity_index, current.*);
                        if (skill_priority <= 0) continue;

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

                        // Queue another enemy_turn_attack after use_skill to re-evaluate
                        queueEvents(current, &.{
                            .{ .level_event = .{ .enemy_turn_attack = .{
                                .entity_index = enemy_attack.entity_index,
                            } } },
                            .{ .level_event = .{ .use_skill = .{
                                .caster_index = enemy_attack.entity_index,
                                .skill_id = skill_id,
                                .target = target,
                            } } },
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

                        queueEvents(current, &.{
                            .{ .level_event = .{ .turn_end = .{
                                .entity_index = enemy_attack.entity_index,
                            } } },
                            .{ .level_event = .{ .use_skill = .{
                                .caster_index = enemy_attack.entity_index,
                                .skill_id = skill_id,
                                .target = target,
                            } } },
                        }, allocator);
                    } else {
                        // No usable skills — end turn
                        queueEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                            .entity_index = enemy_attack.entity_index,
                        } } }}, allocator);
                    }
                },
                .player_prepare_skill => |prepare| {
                    if (lookups.getSkillDefinition(prepare.skill_id)) |skill_definition| {
                        if (skill_definition.playerPrepareSkill(prepare.caster_index, current.*, allocator)) |event| {
                            queueEvents(current, &.{event}, allocator);
                        }
                    }
                },
                .use_skill => |use| {
                    const entity = getLevelEntity(current, use.caster_index);
                    entity.momentum += 1;

                    if (lookups.getSkillDefinition(use.skill_id)) |skill_definition| {
                        // Queue the skill's events
                        const skill_events = skill_definition.useSkill(
                            use.caster_index,
                            use.target,
                            current.*,
                            allocator,
                        );
                        queueEvents(current, skill_events, allocator);

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
                .move_entity => |move| {
                    const entity = getLevelEntity(current, move.entity_index);
                    entity.position = move.destination;
                    entity.momentum += 1;

                    // Queue pickup and aggro checks after movement
                    queueEvents(current, &.{
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
                                    queueEvents(current, &.{
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

                    // Iterate ground items, try to pick up from those in range
                    var remaining_ground_items: std.ArrayList(types.GroundItems) = .empty;
                    for (level.ground_items) |ground_item_stack| {
                        const distance = functions.chebyshevDistance(entity.position, ground_item_stack.position);
                        if (distance > pickup_radius) {
                            // Out of range — keep as is
                            remaining_ground_items.append(allocator, ground_item_stack) catch
                                @panic("failed to append ground items");
                            continue;
                        }

                        // Try to move items to entity inventory
                        var leftover_items: std.ArrayList(types.Item) = .empty;
                        for (ground_item_stack.items) |item| {
                            // Find first empty inventory slot
                            var placed = false;
                            for (&entity.inventory.slots) |*slot| {
                                if (slot.* == null) {
                                    slot.* = item;
                                    placed = true;
                                    break;
                                }
                            }
                            if (!placed) {
                                // Inventory full — leave on ground
                                leftover_items.append(allocator, item) catch
                                    @panic("failed to append leftover item");
                            }
                        }

                        // If items remain, keep the ground stack
                        if (leftover_items.items.len > 0) {
                            remaining_ground_items.append(allocator, .{
                                .position = ground_item_stack.position,
                                .items = leftover_items.toOwnedSlice(allocator) catch
                                    @panic("failed to allocate leftover items"),
                            }) catch @panic("failed to append remaining ground items");
                        }
                    }
                    level.ground_items = remaining_ground_items.toOwnedSlice(allocator) catch
                        @panic("failed to allocate remaining ground items");
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
                                queueEvents(current, effect_events, allocator);
                            }
                        }
                        for (defender.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onIncomingStun(stun.defender_index, current.*, allocator)) |effect_events| {
                                queueEvents(current, effect_events, allocator);
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
                            queueEvents(current, effect_events, allocator);
                        }
                    }
                    for (defender.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onIncomingKnockback(knockback.defender_index, current.*, allocator)) |effect_events| {
                            queueEvents(current, effect_events, allocator);
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
                        queueEvents(current, &.{
                            .{ .level_event = .{ .move_entity = .{
                                .entity_index = knockback.defender_index,
                                .destination = destination,
                            } } },
                        }, allocator);
                    }

                    // Collision: apply knockback_damage to defender, trigger collision effects
                    if (collided) {
                        // Trigger on_outgoing_collision / on_incoming_collision
                        for (attacker.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onOutgoingCollision(knockback.attacker_index, current.*, allocator)) |effect_events| {
                                queueEvents(current, effect_events, allocator);
                            }
                        }
                        for (defender.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onIncomingCollision(knockback.defender_index, current.*, allocator)) |effect_events| {
                                queueEvents(current, effect_events, allocator);
                            }
                        }

                        // Apply collision damage (only defender's incoming modifiers)
                        const incoming_damage = defender.getEffectiveIncomingDamage(knockback.knockback_damage);
                        if (incoming_damage > 0) {
                            if (incoming_damage >= defender.current_health) {
                                defender.current_health = 0;
                            } else {
                                defender.current_health -= incoming_damage;
                            }

                            // Trigger on_outgoing_damage / on_incoming_damage
                            for (attacker.active_effects) |active_effect| {
                                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                                if (definition.onOutgoingDamage(knockback.attacker_index, current.*, allocator)) |effect_events| {
                                    queueEvents(current, effect_events, allocator);
                                }
                            }
                            for (defender.active_effects) |active_effect| {
                                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                                if (definition.onIncomingDamage(knockback.defender_index, current.*, allocator)) |effect_events| {
                                    queueEvents(current, effect_events, allocator);
                                }
                            }

                            if (defender.current_health == 0) {
                                queueEvents(current, &.{
                                    .{ .sub_level_event = .{ .death = .{
                                        .entity_index = knockback.defender_index,
                                    } } },
                                }, allocator);
                            }
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
                                queueEvents(current, effect_events, allocator);
                            }
                        }
                    }

                    // Calculate effective incoming damage
                    const incoming_damage = defender.getEffectiveIncomingDamage(attack.outgoing_damage);

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
                                    queueEvents(current, effect_events, allocator);
                                }
                            }
                            for (defender.active_effects) |active_effect| {
                                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                                if (definition.onIncomingDamage(attack.defender_index, current.*, allocator)) |effect_events| {
                                    queueEvents(current, effect_events, allocator);
                                }
                            }
                        }

                        // Queue death if defender health reached 0
                        if (defender.current_health == 0) {
                            queueEvents(current, &.{
                                .{ .sub_level_event = .{ .death = .{
                                    .entity_index = attack.defender_index,
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
                            queueEvents(current, effect_events, allocator);
                        }
                    }

                    // Trigger on_incoming_effect on receiver's existing effects (before adding new one)
                    for (receiver.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onIncomingEffect(create.receiver_index, current.*, allocator)) |effect_events| {
                            queueEvents(current, effect_events, allocator);
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
                        queueEvents(current, creation_events, allocator);
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
                                queueEvents(current, effect_events, allocator);
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
                        for (&entity.equipped_utility_skills) |skill_id| {
                            dropped_items.append(allocator, .{ .skill_tome = .{
                                .skill = skill_id,
                            } }) catch @panic("failed to append dropped skill tome");
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
                        queueEvents(current, effect_events, allocator);
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
                            queueEvents(current, effect_events, allocator);
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
                        queueEvents(current, &.{
                            .{ .level_event = .{ .move_entity = .{
                                .entity_index = retreat.entity_index,
                                .destination = destination,
                            } } },
                        }, allocator);
                    }
                },
            }
        },
    }
}

/// Process the next event in the queue, with player input handling.
fn update(
    history: *GameStateHistory,
    player_input: PlayerInput,
    allocator: std.mem.Allocator,
) void {
    // Always handle anytime input first (toggle_options_menu always works,
    // but other inputs are blocked when the options menu is open)
    handleAnytimeInput(history, player_input.anytime, allocator);

    // Options menu pauses the game
    if (history.current_state.ui_state.options_menu_open) return;

    if (history.current_state.event_stack.len > 0) {
        // Process next queued event
        processEvent(history, allocator);
    } else {
        // Queue empty — accept gameplay input
        handleIdleInput(history, player_input.idle, allocator);
    }
}

/// Build a ViewState describing what to render for the current game state.
fn view(
    current_state: *const GameState,
    color_theme_definitions: types.ColorThemeDefinitions,
) types.ViewState {
    _ = current_state;
    _ = color_theme_definitions;
    return .{
        .background_color = .{ .r = 0, .g = 0, .b = 0 },
        .active_color_theme = .{
            .lightest = .{ .r = 255, .g = 255, .b = 240 },
            .darkest = .{ .r = 20, .g = 15, .b = 25 },
            .world_gradient = .{ .colors = .{types.Color{ .r = 128, .g = 128, .b = 128 }} ** types.gradient_color_count },
            .enemy_gradient = .{ .colors = .{types.Color{ .r = 128, .g = 128, .b = 128 }} ** types.gradient_color_count },
            .player_gradient = .{ .colors = .{types.Color{ .r = 128, .g = 128, .b = 128 }} ** types.gradient_color_count },
        },
        .tiles = &.{},
        .tile_overlays = &.{},
        .ground_drawables = &.{},
        .ui_elements = &.{},
    };
}

fn gameLoop(
    allocator: std.mem.Allocator,
    starting_game_state: GameState,
    settings: Settings,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    color_theme_definitions: ColorThemeDefinitions,
    salvage_definitions: types.SalvageDefinitions,
    directory: std.Io.Dir,
    io: std.Io,
) void {
    var history = GameStateHistory.init(
        allocator,
        starting_game_state,
        settings,
        weapon_type_definitions,
        color_theme_definitions,
        salvage_definitions,
        directory,
        io,
    );
    var time_since_last_view: u32 = 0;
    var previous_view_state: ?types.ViewState = null;

    var needs_snapshot = false;

    while (true) {
        // TODO: read actual platform events from JS/native each tick
        const platform_input = input.PlatformInput{
            .events = &.{},
            .viewport = .{ .width = 0, .height = 0 },
        };
        const player_input = input.translateInput(
            platform_input,
            &history.current_state.input_state,
            history.settings,
            history.current_state.camera orelse .{ .position = .{ .x = 0, .y = 0 } },
        );

        const had_events = history.current_state.event_stack.len > 0;
        update(&history, player_input, allocator);
        const has_events = history.current_state.event_stack.len > 0;

        if (had_events and !has_events) {
            // Queue just emptied — save a snapshot
            history.takeSnapshot(allocator);
            needs_snapshot = false;
        } else if (had_events) {
            needs_snapshot = true;
        }

        const frame_length = computeFrameLength(history.settings);

        // Check if it's time to render
        if (time_since_last_view >= frame_length) {
            previous_view_state = view(&history.current_state, history.color_theme_definitions);
            // TODO: pass previous_view_state to renderer
            time_since_last_view -= frame_length;
        }
    }

    // Suppress unused local warning until input resolution uses previous_view_state
    _ = &previous_view_state;
}

const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;

/// Load settings from data/settings.txt. Returns default settings on failure.
fn loadSettingsFromDisk(
    directory: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) Settings {
    const parsed = parser.parseConfigFileFromPath(
        directory,
        io,
        "data/settings.txt",
        allocator,
    ) catch return .{ .input_bindings = &.{} };

    return parser.loadSettings(parsed.sections, allocator) catch .{ .input_bindings = &.{} };
}

/// Load color theme definitions from data/color_themes.txt.
/// Returns a default with no gradients on failure.
fn loadColorThemeDefinitionsFromDisk(
    directory: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) ColorThemeDefinitions {
    const parsed = parser.parseConfigFileFromPath(
        directory,
        io,
        "data/color_themes.txt",
        allocator,
    ) catch return .{
        .lightest = .{ .r = 255, .g = 255, .b = 240 },
        .darkest = .{ .r = 20, .g = 15, .b = 25 },
        .gradients = &.{},
    };

    return parser.loadColorThemeDefinitions(
        parsed.sections,
        allocator,
    ) catch .{
        .lightest = .{ .r = 255, .g = 255, .b = 240 },
        .darkest = .{ .r = 20, .g = 15, .b = 25 },
        .gradients = &.{},
    };
}

/// Load all weapon type definitions from data/weapon_types/.
/// Each file is named after its WeaponType enum value (e.g. sword.txt).
fn loadWeaponTypeDefinitions(
    directory: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) [weapon_type_count]WeaponTypeDefinition {
    var definitions: [weapon_type_count]WeaponTypeDefinition = undefined;
    const fields = @typeInfo(WeaponType).@"enum".fields;

    inline for (fields, 0..) |field, index| {
        const file_path = "data/weapon_types/" ++ field.name ++ ".txt";
        const parsed = parser.parseConfigFileFromPath(
            directory,
            io,
            file_path,
            allocator,
        ) catch @panic("failed to read weapon type file: " ++ file_path);

        definitions[index] = parser.loadWeaponTypeDefinition(
            parsed.sections,
        ) catch @panic("failed to parse weapon type file: " ++ file_path);
    }

    return definitions;
}

/// Load salvage definitions from data/salvage.txt.
/// Panics on failure since salvage data is required.
fn loadSalvageDefinitionsFromDisk(
    directory: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) types.SalvageDefinitions {
    const parsed = parser.parseConfigFileFromPath(
        directory,
        io,
        "data/salvage.txt",
        allocator,
    ) catch @panic("failed to read salvage.txt");

    return parser.loadSalvageDefinitions(
        parsed.sections,
        allocator,
    ) catch @panic("failed to parse salvage.txt");
}

/// Called once to start the game loop.
pub fn main() void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const directory = std.Io.Dir.cwd();

    const settings = loadSettingsFromDisk(directory, io, allocator);
    const weapon_type_definitions = loadWeaponTypeDefinitions(directory, io, allocator);
    const color_theme_definitions = loadColorThemeDefinitionsFromDisk(directory, io, allocator);
    const salvage_definitions = loadSalvageDefinitionsFromDisk(directory, io, allocator);

    const starting_game_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .input_state = .{},
        .ui_state = .{},
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    gameLoop(
        allocator,
        starting_game_state,
        settings,
        &weapon_type_definitions,
        color_theme_definitions,
        salvage_definitions,
        directory,
        io,
    );
}

test {
    _ = @import("parser.zig");
    _ = @import("functions.zig");
}

