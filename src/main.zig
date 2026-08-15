const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const functions = @import("functions.zig");
const input = @import("input.zig");
const parser = @import("parser.zig");
const lookups = @import("generated_lookups.zig");
const ui = @import("ui.zig");

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

// Real-time pause inserted between enemy turn actions (before moving, before
// each skill) so enemy turns don't resolve instantly. Not skippable — see the
// wait handling in update().
const turn_flow_wait_milliseconds: u32 = 500;

// ============================================================
// Core functions
// ============================================================

// `export` makes these visible to JS when compiled to WASM.
// The build.zig `export_symbol_names` list must include them too.

/// Handle inputs that can interrupt regardless of event stack state.
/// Map a completed drag (source slot → target slot) to the player event it
/// produces, or null for an invalid / no-op drop. The switch on the source
/// enforces the item/skill domain split: item sources (inventory/gear) only
/// yield events for item targets, skill sources (skill_bar/learned_skill) only
/// for skill targets — everything cross-domain or nonsensical falls to null.
fn dragToEvent(from: ui.SlotRef, to: ui.SlotRef) ?Event {
    return switch (from) {
        .inventory => |inventory_index| switch (to) {
            .gear => |gear_slot| .{ .player_event = .{ .equip_item = .{
                .inventory_slot_index = inventory_index,
                .gear_slot = gear_slot,
            } } },
            else => null, // inventory→inventory move (future) + skill targets
        },
        .gear => |gear_slot| switch (to) {
            .inventory => |inventory_index| .{ .player_event = .{ .unequip_item = .{
                .gear_slot = gear_slot,
                .inventory_slot_index = inventory_index,
            } } },
            else => null,
        },
        .learned_skill => |skill_id| switch (to) {
            .skill_bar => |slot_index| .{ .player_event = .{ .equip_utility_skill = .{
                .skill_id = skill_id,
                .slot_index = slot_index,
            } } },
            else => null,
        },
        .skill_bar => |from_index| switch (to) {
            .skill_bar => |to_index| .{ .player_event = .{ .swap_utility_skills = .{
                .slot_a_index = from_index,
                .slot_b_index = to_index,
            } } },
            // Dropping a bar skill back onto the skills menu clears the slot.
            .learned_skill => .{ .player_event = .{ .unequip_utility_skill = .{
                .slot_index = from_index,
            } } },
            else => null,
        },
    };
}

/// Pointer-driven drag lifecycle. Runs every tick (anytime): press over a
/// slot with content begins a drag; release hit-tests the target slot and
/// pushes the resolved event. Hit-tests against the previous frame's UI.
fn handleDrag(
    history: *GameStateHistory,
    pointer: input.PointerInput,
    ui_elements: []const ui.UiElement,
) void {
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();
    const ui_state = &history.session.ui_state;

    if (pointer.pressed) {
        // Begin a drag only when the pointer goes down on a slot that both has
        // an identity and holds something (icon present).
        if (ui.slotAt(ui_elements, pointer.position)) |slot| {
            if (slot.ref) |ref| {
                if (slot.icon_sprite_id) |icon| {
                    ui_state.drag = .{ .source = ref, .icon_sprite_id = icon };
                }
            }
        }
    }

    if (pointer.released) {
        if (ui_state.drag) |drag| {
            if (ui.slotRefAt(ui_elements, pointer.position)) |target| {
                if (dragToEvent(drag.source, target)) |event| {
                    pushEvents(current, &.{event}, allocator);
                }
            }
            ui_state.drag = null;
        }
    }
}

fn handleAnytimeInput(
    history: *GameStateHistory,
    anytime: input.AnytimeInput,
) void {
    if (anytime.undo) {
        _ = history.undo(&processEvent);
    }

    if (anytime.redo) {
        _ = history.redo(&processEvent);
    }

    if (anytime.toggle_options_menu) {
        history.session.ui_state.options_menu_open = !history.session.ui_state.options_menu_open;
    }

    // When options menu is open, block all other input
    if (history.session.ui_state.options_menu_open) return;

    if (anytime.scroll_delta != 0) {
        const zoom_speed: f32 = 0.1;
        history.settings.camera_zoom = @max(0.1, history.settings.camera_zoom + anytime.scroll_delta * zoom_speed);
    }

    // In-game inputs only apply when in a hub or level
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();
    const ui_state = &history.session.ui_state;
    if (current.screen == .hub or current.screen == .level) {
        const in_game = anytime.in_game;

        if (in_game.toggle_inventory) {
            ui_state.toggleMiddlePanel(.inventory);
        }

        if (in_game.toggle_gear) {
            ui_state.toggleMiddlePanel(.gear);
        }

        if (in_game.toggle_skills) {
            ui_state.toggleMiddlePanel(.skills);
        }

        if (in_game.toggle_entity_inspect) |entity_index| {
            if (ui_state.inspected_entity_index) |current_inspected| {
                if (current_inspected == entity_index) {
                    // Same entity — close the panel
                    ui_state.toggleMiddlePanel(.enemy_inspect);
                    ui_state.inspected_entity_index = null;
                } else {
                    // Different entity — switch target
                    ui_state.inspected_entity_index = entity_index;
                }
            } else {
                // Not inspecting — open panel
                ui_state.inspected_entity_index = entity_index;
                ui_state.toggleMiddlePanel(.enemy_inspect);
            }
        }

        if (in_game.toggle_world_map) {
            ui_state.toggleFullScreenOverlay(.world_map);
        }
        if (in_game.move_tile_cursor_to) |_| {
            // TODO: move tile cursor
        }

        if (in_game.swap_weapons) {
            pushEvents(current, &.{
                .{ .player_event = .swap_hands },
            }, allocator);
        }
    }
}

/// Handle inputs that are only accepted when the event stack is empty.
fn handleIdleInput(
    history: *GameStateHistory,
    idle: input.IdleInput,
) void {
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();

    // Main menu: menu buttons emit a menu_action (no keybind path).
    if (current.screen == .main_menu) {
        if (idle.menu_action) |action| {
            switch (action) {
                .new_game => pushEvents(current, &.{
                    .{ .meta_event = .start_new_game },
                }, allocator),
                // continue_game / load_save need an autosave path + file picker,
                // and open_settings / open_credits need their screens. Wired
                // when those land (Continue isn't even shown on a fresh start).
                .continue_game, .load_save, .open_settings, .open_credits => {},
                else => {},
            }
        }
        return;
    }

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
                            pushEvents(current, &.{
                                .{ .level_event = .player_turn_attack },
                                .{ .level_event = .clear_highlights },
                                .{ .level_event = .{ .move_entity = .{
                                    .entity_index = 0,
                                    .destination = clicked_position,
                                } } },
                            }, allocator);
                        }
                    }

                    if (idle.skip) {
                        // Skip movement, go straight to attack phase
                        pushEvents(current, &.{
                            .{ .level_event = .player_turn_attack },
                            .{ .level_event = .clear_highlights },
                        }, allocator);
                    }
                },
                .player_attack => {
                    if (idle.skill_slot_selected) |slot| {
                        const player = level.entities[0];
                        if (player.skillInSlot(slot, history.weapon_type_definitions)) |skill_id| {
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
                                                        pushPlayerSkillUse(current, skill_id, skill_definition, cursor_position, allocator);
                                                        return;
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Begin targeting — push player_prepare_skill
                                    pushEvents(current, &.{
                                        .{ .level_event = .{ .player_prepare_skill = .{
                                            .caster_index = 0,
                                            .skill_id = skill_id,
                                        } } },
                                    }, allocator);
                                } else {
                                    // No targeting — use immediately
                                    pushPlayerSkillUse(current, skill_id, skill_definition, null, allocator);
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
                                        pushPlayerSkillUse(current, skill_id, skill_definition, cursor_position, allocator);
                                    }
                                }
                            }
                        }
                    }

                    if (idle.cancel) {
                        // Cancel skill targeting
                        if (level.prepared_skill != null) {
                            // Stay in player_attack phase
                            pushEvents(current, &.{
                                .{ .level_event = .clear_highlights },
                                .{ .level_event = .clear_prepared_skill },
                            }, allocator);
                        }
                    }

                    if (idle.skip) {
                        // Skip attack, end turn
                        pushEvents(current, &.{
                            .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
                            .{ .level_event = .clear_highlights },
                            .{ .level_event = .clear_prepared_skill },
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
                pushEvents(current, &.{
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
                    pushEvents(current, &.{
                        .{ .hub_event = .{ .move_player = .{
                            .destination = clicked_position,
                        } } },
                    }, allocator);
                }
            }
        }
    }

    if (idle.skill_slot_selected) |_| {
        // TODO: resolve slot to SkillId, begin skill targeting or push skill use
        // if Settings.auto_target_at_cursor, check tile cursor position and use skill immediately if valid target
    }

    if (idle.confirm) {
        // TODO: confirm current action (e.g. skill target selection)
    }

    if (idle.cancel) {
        // TODO: cancel current action (e.g. deselect skill)
    }
}

/// Compute the minimum effective range across all off-cooldown skills an entity has.
/// This is the closest distance the entity needs to be to use at least one skill.
/// Uses range if the skill has it, radius if not.
/// Returns null if no skills are off cooldown (shouldn't normally happen).
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

/// Push a skill use for the player, followed by turn_end if the skill
/// type ends the turn (weapon_skill/spell). For non-turn-ending skills
/// (cantrip/enchantment/curse), turn_phase stays as player_attack so
/// idle input picks up again after use_skill processes.
fn pushPlayerSkillUse(
    current: *GameState,
    skill_id: SkillId,
    skill_definition: Skill,
    target: ?Vector2,
    allocator: std.mem.Allocator,
) void {
    const ends_turn = skill_definition.skill_type == .weapon_skill or
        skill_definition.skill_type == .spell;

    if (ends_turn) {
        pushEvents(current, &.{
            .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
            .{ .level_event = .{ .use_skill = .{
                .caster_index = 0,
                .skill_id = skill_id,
                .target = target,
            } } },
            .{ .level_event = .clear_highlights },
            .{ .level_event = .clear_prepared_skill },
        }, allocator);
    } else {
        // Don't clear turn_phase — stays as player_attack.
        // Stack empties after use_skill, idle input resumes.
        pushEvents(current, &.{
            .{ .level_event = .{ .use_skill = .{
                .caster_index = 0,
                .skill_id = skill_id,
                .target = target,
            } } },
            .{ .level_event = .clear_highlights },
            .{ .level_event = .clear_prepared_skill },
        }, allocator);
    }
}

/// Push events onto the event stack. Events are processed from the back
/// (top of stack), so the last event pushed is processed first.
fn pushEvents(
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

/// Load the campaign from player_data.current_campaign and push a start_hub
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

    // Push start_hub with the player's current hub
    const hub_id = current.player_data.current_hub;
    pushEvents(current, &.{.{ .meta_event = .{ .start_hub = .{
        .hub_id = hub_id,
    } } }}, allocator);
}

/// Process a single event from the stack. Applies the event to the current
/// state and records it in event history. Also used by undo/redo replay.
fn processEvent(
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
            const should_checkpoint = switch (meta) {
                .start_level => |level| level.sets_checkpoint,
                .start_hub => |hub| hub.sets_checkpoint,
                else => false,
            };
            if (should_checkpoint) {
                history.setCheckpoint();
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

                    loadCampaignAndPushHub(current, history, allocator);
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
                        history.directory,
                        history.io,
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

                    // Push the first level
                    pushEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                        .mission_path = start.mission_path,
                        .level_index = 1,
                    } } }}, allocator);
                },
                .end_mission => |end| {
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

                    pushEvents(current, start_events.items, allocator);
                },
                .end_level => {
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
                            } } },
                        }, allocator);
                    }

                    // Collision: apply knockback_damage to defender, trigger collision effects
                    if (collided) {
                        // Trigger on_outgoing_collision / on_incoming_collision
                        for (attacker.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onOutgoingCollision(knockback.attacker_index, current.*, allocator)) |effect_events| {
                                pushEvents(current, effect_events, allocator);
                            }
                        }
                        for (defender.active_effects) |active_effect| {
                            const definition = lookups.getEffectDefinition(active_effect.effect_id);
                            if (definition.onIncomingCollision(knockback.defender_index, current.*, allocator)) |effect_events| {
                                pushEvents(current, effect_events, allocator);
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
                                    pushEvents(current, effect_events, allocator);
                                }
                            }
                            for (defender.active_effects) |active_effect| {
                                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                                if (definition.onIncomingDamage(knockback.defender_index, current.*, allocator)) |effect_events| {
                                    pushEvents(current, effect_events, allocator);
                                }
                            }

                            if (defender.current_health == 0) {
                                pushEvents(current, &.{
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

/// Process the next event on the stack, with player input handling.
fn update(
    history: *GameStateHistory,
    input_this_tick: PlayerInput,
    previous_view_state: ?types.ViewState,
    delta_microseconds: u64,
) void {
    var player_input = input_this_tick;

    // The UI drawn last frame is what the pointer is over this frame. Used to
    // resolve clicks into actions and to arbitrate world vs UI clicks.
    const ui_elements: []const ui.UiElement =
        if (previous_view_state) |view_state| view_state.ui_elements else &.{};

    // Resolve a primary-button press over the UI. A press on a Button folds its
    // Action into the input (so a click drives the same path as the keybind); a
    // press on any blocking UI surface consumes the world click so it does not
    // also act on the level/hub behind it (world/UI arbitration).
    if (player_input.pointer.pressed) {
        const pointer_position = player_input.pointer.position;
        if (ui.buttonAt(ui_elements, pointer_position)) |button| {
            input.applyAction(&player_input, button.action);
            player_input.idle.tile_clicked = null;
            player_input.idle.confirm = false;
        } else if (ui.blockingElementAt(ui_elements, pointer_position) != null) {
            player_input.idle.tile_clicked = null;
            player_input.idle.confirm = false;
        }
    }

    // Always handle anytime input first (toggle_options_menu always works,
    // but other inputs are blocked when the options menu is open)
    handleAnytimeInput(history, player_input.anytime);

    // Options menu pauses the game
    if (history.session.ui_state.options_menu_open) return;

    // Drag lifecycle runs anytime (not gated on the event stack) so the player
    // can rearrange inventory / gear / skills even while turns resolve. Hit-
    // tested against the previous frame's UI.
    handleDrag(history, player_input.pointer, ui_elements);

    // Turn-flow pause: while waiting, drain the timer and stall event
    // processing until it elapses. Anytime input and drag above still run, so
    // undo/redo/options remain responsive mid-wait (undo rebuilds state and
    // clears the wait via replay). Not skippable: no input can shorten it.
    if (history.current_state.waiting) |*wait_state| {
        if (wait_state.remaining_microseconds > delta_microseconds) {
            wait_state.remaining_microseconds -= delta_microseconds;
            return;
        }
        history.current_state.waiting = null;
        // Wait elapsed this tick; fall through to process the next event.
    }

    if (history.current_state.event_stack.len > 0) {
        // Process next pushed event
        processEvent(history);
    } else {
        // Stack empty — accept gameplay input
        handleIdleInput(history, player_input.idle);
    }
}

/// Build a ViewState describing what to render for the current game state.
/// The frame_allocator is a per-frame arena — everything the ViewState
/// points at is allocated from it and lives until the next frame.
fn view(
    current_state: *const GameState,
    session: *const state.SessionState,
    color_theme_definitions: types.ColorThemeDefinitions,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    camera: types.Camera,
    camera_zoom: f32,
    frame_allocator: std.mem.Allocator,
) types.ViewState {
    const active_theme = activeThemeFor(current_state, color_theme_definitions);

    // World layer: checkerboard tiles + entity sprites for the hub/level.
    var tiles: std.ArrayList(types.TileDrawable) = .empty;
    var tile_overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
    var ground_drawables: std.ArrayList(types.GroundDrawable) = .empty;
    if (current_state.level) |*level| {
        buildTiles(&tiles, frame_allocator, level.level_tiles, active_theme, camera, camera_zoom);
        buildHighlightOverlays(&tile_overlays, frame_allocator, level.highlighted_tiles, active_theme, camera, camera_zoom);
        buildCursorOverlay(&tile_overlays, frame_allocator, level.level_tiles, session, active_theme, camera, camera_zoom);
        // Level-end marker drawn before entities so actors occlude it (a proper
        // mixed y-sort with entities is a later refinement).
        if (level.level_end) |end_position| {
            ground_drawables.append(frame_allocator, .{
                .level_end = levelEndDrawable(end_position, camera, camera_zoom),
            }) catch @panic("failed to append level-end drawable");
        }
        buildEntities(&ground_drawables, frame_allocator, level.entities, camera, camera_zoom);
    } else if (current_state.hub) |*hub| {
        buildTiles(&tiles, frame_allocator, hub.hub_tiles, active_theme, camera, camera_zoom);
        buildCursorOverlay(&tile_overlays, frame_allocator, hub.hub_tiles, session, active_theme, camera, camera_zoom);
        // Mission-start markers use the same flag sprite as level ends, drawn
        // before entities so actors occlude them.
        for (hub.mission_exits) |exit| {
            ground_drawables.append(frame_allocator, .{
                .level_end = levelEndDrawable(exit.position, camera, camera_zoom),
            }) catch @panic("failed to append mission-start drawable");
        }
        buildHubEntities(&ground_drawables, frame_allocator, hub, camera, camera_zoom);
    }

    var ui_elements: std.ArrayList(ui.UiElement) = .empty;

    if (current_state.screen == .level or current_state.screen == .hub) {
        ui.buildBottomBar(
            &ui_elements,
            frame_allocator,
            ui.screenRect(),
            current_state,
            weapon_type_definitions,
        ) catch @panic("failed to build bottom bar");
    } else if (current_state.screen == .main_menu) {
        // Continue is available when there is a game to resume. Today that is
        // populated PlayerData; a future standalone build also offers Continue
        // when an autosave file exists (detected once via the file layer, not
        // per frame here — see TODO.txt).
        const continue_available = current_state.player_data.current_campaign.len > 0;
        ui.buildMainMenu(
            &ui_elements,
            frame_allocator,
            ui.screenRect(),
            continue_available,
        ) catch @panic("failed to build main menu");
    }

    // Drag ghost: the dragged icon follows the pointer, drawn last (on top).
    // Pointer position is in reference-resolution space (see translateInput).
    if (session.ui_state.drag) |drag| {
        const pointer = session.input_state.mouse_screen_position;
        ui_elements.append(frame_allocator, .{ .image = .{
            .sprite_id = drag.icon_sprite_id,
            .screen_position = .{
                .x = @as(i32, @intFromFloat(pointer.x)) - @divTrunc(ui.slot_size, 2),
                .y = @as(i32, @intFromFloat(pointer.y)) - @divTrunc(ui.slot_size, 2),
            },
            .width = ui.slot_size,
            .height = ui.slot_size,
            // Follows the pointer; must not occlude drop-target hit-testing.
            .blocks_input = false,
        } }) catch @panic("failed to append drag ghost");
    }

    // Hover tooltip: the topmost element under the pointer that carries
    // tooltip content spawns a tooltip, appended last so it draws on top.
    // Suppressed while dragging.
    if (session.ui_state.drag == null) {
        const pointer = session.input_state.mouse_screen_position;
        const point = types.ScreenPosition{
            .x = @intFromFloat(pointer.x),
            .y = @intFromFloat(pointer.y),
        };
        if (ui.tooltipAt(ui_elements.items, point)) |hovered| {
            const bounds = ui.boundsOf(hovered);
            ui.buildTooltip(
                &ui_elements,
                frame_allocator,
                bounds.position(),
                bounds.width,
                bounds.height,
                ui.tooltipOf(hovered).?,
            ) catch @panic("failed to build tooltip");
        }
    }

    return .{
        .background_color = active_theme.darkest,
        .active_color_theme = active_theme,
        .world_scale = camera_zoom,
        .tiles = tiles.items,
        .tile_overlays = tile_overlays.items,
        .ground_drawables = ground_drawables.items,
        .ui_elements = ui_elements.items,
    };
}

/// The active color theme for the current screen, derived from its
/// color_wheel_index (level/hub); a neutral default elsewhere.
fn activeThemeFor(
    current_state: *const GameState,
    color_theme_definitions: types.ColorThemeDefinitions,
) types.ActiveColorTheme {
    const color_wheel_index = if (current_state.level) |level|
        level.color_wheel_index
    else if (current_state.hub) |hub|
        hub.color_wheel_index
    else
        0;
    return parser.deriveActiveColorTheme(color_theme_definitions, color_wheel_index);
}

/// The player's tile position for the current screen (entity 0 in a level,
/// the hub player), or the origin when neither is active.
fn playerPosition(current_state: *const GameState) types.Vector2 {
    if (current_state.level) |level| {
        if (level.entities.len > 0) return level.entities[0].position;
    }
    if (current_state.hub) |hub| return hub.player.position;
    return .{ .x = 0, .y = 0 };
}

/// Camera centered on the player: places the player tile's center at the
/// screen center. Position is in the same world-pixel space screenToTile
/// inverts (tile coord * tile_size_pixels * zoom).
fn computeCamera(current_state: *const GameState, zoom: f32) types.Camera {
    const player_tile = playerPosition(current_state);
    const tile_pixels = input.tile_size_pixels * zoom;
    return .{ .position = .{
        .x = @intFromFloat((@as(f32, @floatFromInt(player_tile.x)) + 0.5) * tile_pixels),
        .y = @intFromFloat((@as(f32, @floatFromInt(player_tile.y)) + 0.5) * tile_pixels),
    } };
}

/// Convert a tile coordinate to its top-left screen position (reference space).
/// Exact inverse of input.screenToTile so clicks land on the drawn tile.
fn tileToScreen(tile: types.Vector2, camera: types.Camera, zoom: f32) types.ScreenPosition {
    const tile_pixels = input.tile_size_pixels * zoom;
    const half_width: f32 = @floatFromInt(@divTrunc(types.reference_width, 2));
    const half_height: f32 = @floatFromInt(@divTrunc(types.reference_height, 2));
    const x = @as(f32, @floatFromInt(tile.x)) * tile_pixels - @as(f32, @floatFromInt(camera.position.x)) + half_width;
    const y = @as(f32, @floatFromInt(tile.y)) * tile_pixels - @as(f32, @floatFromInt(camera.position.y)) + half_height;
    return .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
}

/// Entity sprite frame: all entities/weapons share one 512x640 frame (2 tiles
/// wide x 2.5 tall) authored at tile_size_pixels, with one normalized pivot
/// (horizontal center, at the feet with 0.5 tile of foot/shadow overflow).
const entity_frame_width: f32 = 512.0;
const entity_frame_height: f32 = 640.0;
const entity_pivot_x: f32 = 0.5;
const entity_pivot_y: f32 = 0.8;

const world_white: types.Color = .{ .r = 255, .g = 255, .b = 255 };

/// Flag pole frame: 256x512 (1 tile wide x 2 tall). Pivot (0.5, 0.75) centers
/// the bottom tile-half of the frame on the marker's tile. Used for both level
/// ends and hub mission-start markers. The animated banner overlay is deferred
/// to the animation work.
const flag_pole_width: f32 = 256.0;
const flag_pole_height: f32 = 512.0;
const flag_pivot_x: f32 = 0.5;
const flag_pivot_y: f32 = 0.75;

fn levelEndDrawable(
    tile: types.Vector2,
    camera: types.Camera,
    zoom: f32,
) types.LevelEndDrawable {
    const tile_top_left = tileToScreen(tile, camera, zoom);
    const tile_pixels = input.tile_size_pixels * zoom;
    const center_x = @as(f32, @floatFromInt(tile_top_left.x)) + tile_pixels / 2;
    const center_y = @as(f32, @floatFromInt(tile_top_left.y)) + tile_pixels / 2;
    return .{
        .sprite_id = "world/flag_pole",
        .screen_position = .{
            .x = @intFromFloat(@round(center_x - flag_pivot_x * flag_pole_width * zoom)),
            .y = @intFromFloat(@round(center_y - flag_pivot_y * flag_pole_height * zoom)),
        },
        .color = world_white,
    };
}

/// Build an EntityDrawable for `entity`, aligning the shared sprite pivot to
/// the center of the entity's tile. Only the base sprite is populated for now
/// (weapons/gear/effects/health bar land later).
fn entityDrawable(
    entity: *const Entity,
    camera: types.Camera,
    zoom: f32,
    allocator: std.mem.Allocator,
) types.EntityDrawable {
    const tile_top_left = tileToScreen(entity.position, camera, zoom);
    const tile_pixels = input.tile_size_pixels * zoom;
    const center_x = @as(f32, @floatFromInt(tile_top_left.x)) + tile_pixels / 2;
    const center_y = @as(f32, @floatFromInt(tile_top_left.y)) + tile_pixels / 2;
    const draw_width = entity_frame_width * zoom;
    const draw_height = entity_frame_height * zoom;
    // Body and every weapon overlay share this pivot-aligned top-left, so they
    // register with no per-sprite offset (same 512x640 frame + pivot).
    const top_left = types.ScreenPosition{
        .x = @intFromFloat(@round(center_x - entity_pivot_x * draw_width)),
        .y = @intFromFloat(@round(center_y - entity_pivot_y * draw_height)),
    };
    const base_sprite_id = std.fmt.allocPrint(allocator, "entities/{s}", .{entity.sprite}) catch
        @panic("failed to build entity sprite id");

    // Weapons: main hand drawn as-authored (left), off hand mirrored (right).
    var weapon_sprites: [2]?types.SpriteDrawable = .{ null, null };
    if (entity.main_hand_weapon) |weapon| {
        weapon_sprites[0] = weaponSprite(entity, weapon.weapon_type, top_left, false, allocator);
    }
    if (entity.off_hand_weapon) |weapon| {
        weapon_sprites[1] = weaponSprite(entity, weapon.weapon_type, top_left, true, allocator);
    }

    return .{
        .back_effect_sprites = &.{},
        .base_sprite = .{
            .sprite_id = base_sprite_id,
            .screen_position = top_left,
            .draw_offset = .{ .x = 0, .y = 0 },
            .source_rectangle = null,
            .color = world_white,
        },
        .weapon_sprites = weapon_sprites,
        .gear_sprites = &.{},
        .front_effect_sprites = &.{},
        .health_bar = null,
    };
}

/// Build a weapon overlay sprite for an entity. The weapon art shares the
/// entity frame + pivot, so it uses the same top-left as the body. Player
/// bodies (team 0) use the plain art; enemy silhouettes use the enemy_ variant.
/// Off-hand weapons are mirrored to sit on the right.
fn weaponSprite(
    entity: *const Entity,
    weapon_type: types.WeaponType,
    top_left: types.ScreenPosition,
    flip_horizontal: bool,
    allocator: std.mem.Allocator,
) types.SpriteDrawable {
    const variant_prefix = if (entity.team == 0) "" else "enemy_";
    const sprite_id = std.fmt.allocPrint(allocator, "weapons/{s}{s}", .{ variant_prefix, @tagName(weapon_type) }) catch
        @panic("failed to build weapon sprite id");
    return .{
        .sprite_id = sprite_id,
        .screen_position = top_left,
        .draw_offset = .{ .x = 0, .y = 0 },
        .source_rectangle = null,
        .color = world_white,
        .flip_horizontal = flip_horizontal,
    };
}

/// Order entities back-to-front for painter's-algorithm occlusion. tileToScreen
/// maps higher tile.y to a LARGER screen y (lower on screen = nearer the
/// viewer), so lower tile.y is further back and drawn first (ascending y).
fn entityDrawsBefore(_: void, a: *const Entity, b: *const Entity) bool {
    if (a.position.y != b.position.y) return a.position.y < b.position.y;
    return a.position.x < b.position.x;
}

fn buildEntities(
    list: *std.ArrayList(types.GroundDrawable),
    allocator: std.mem.Allocator,
    entities: []const Entity,
    camera: types.Camera,
    zoom: f32,
) void {
    var order = allocator.alloc(*const Entity, entities.len) catch @panic("failed to alloc entity order");
    for (entities, 0..) |*entity, index| order[index] = entity;
    std.mem.sort(*const Entity, order, {}, entityDrawsBefore);
    for (order) |entity| {
        list.append(allocator, .{ .entity = entityDrawable(entity, camera, zoom, allocator) }) catch
            @panic("failed to append entity drawable");
    }
}

/// Hub actors: the player plus NPCs, sorted together back-to-front.
fn buildHubEntities(
    list: *std.ArrayList(types.GroundDrawable),
    allocator: std.mem.Allocator,
    hub: *const types.Hub,
    camera: types.Camera,
    zoom: f32,
) void {
    var order = allocator.alloc(*const Entity, hub.npcs.len + 1) catch @panic("failed to alloc hub order");
    order[0] = &hub.player;
    for (hub.npcs, 0..) |*npc, index| order[index + 1] = &npc.entity;
    std.mem.sort(*const Entity, order, {}, entityDrawsBefore);
    for (order) |entity| {
        list.append(allocator, .{ .entity = entityDrawable(entity, camera, zoom, allocator) }) catch
            @panic("failed to append hub entity drawable");
    }
}

/// Move-range highlights: a translucent fill over each reachable tile, tinted
/// with a player-gradient color.
fn buildHighlightOverlays(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    highlighted_tiles: []const types.Vector2,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    for (highlighted_tiles) |tile| {
        list.append(allocator, .{
            .screen_position = tileToScreen(tile, camera, zoom),
            .overlay_type = .highlight,
            .color = active_theme.player_gradient.colors[2],
        }) catch @panic("failed to append highlight overlay");
    }
}

/// Hover cursor: an outline on the tile under the pointer, when it is a real
/// tile. Derived purely from the session pointer (reference space) — no
/// GameState mutation, so it is replay-safe like the tooltip/drag-ghost.
fn buildCursorOverlay(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    world_tiles: []const types.Vector2,
    session: *const state.SessionState,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    const pointer = session.input_state.mouse_screen_position;
    const viewport = input.ViewportSize{
        .width = @floatFromInt(types.reference_width),
        .height = @floatFromInt(types.reference_height),
    };
    const hovered_tile = input.screenToTile(pointer, camera, zoom, viewport);
    for (world_tiles) |tile| {
        if (tile.x == hovered_tile.x and tile.y == hovered_tile.y) {
            list.append(allocator, .{
                .screen_position = tileToScreen(hovered_tile, camera, zoom),
                .overlay_type = .cursor,
                .color = active_theme.lightest,
            }) catch @panic("failed to append cursor overlay");
            return;
        }
    }
}

/// Append a checkerboard TileDrawable per tile. The two shades come from world
/// gradient indices 1 and 3, chosen by (x + y) parity.
fn buildTiles(
    list: *std.ArrayList(types.TileDrawable),
    allocator: std.mem.Allocator,
    tiles: []const types.Vector2,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    for (tiles) |tile| {
        const color = if (@mod(tile.x + tile.y, 2) == 0)
            active_theme.world_gradient.colors[1]
        else
            active_theme.world_gradient.colors[3];
        list.append(allocator, .{
            .screen_position = tileToScreen(tile, camera, zoom),
            .color = color,
        }) catch @panic("failed to append tile drawable");
    }
}

/// Platform-agnostic game loop, driven by a `backend` (comptime duck-typed).
/// The backend owns the window/clock/input/rendering and must provide:
///   shouldClose() bool
///   deltaMicroseconds() u64            — wall-clock time since the last frame
///   pollInput() input.PlatformInput    — events + current viewport this frame
///   render(view_state: types.ViewState, viewport: input.ViewportSize) void
/// This keeps main.zig raylib-free: the raylib calls live in the backend
/// (raylib_backend.zig), which only the native/web builds compile. See the
/// platform-seam note in build.zig.
fn gameLoop(
    backend: anytype,
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
    var previous_view_state: ?types.ViewState = null;

    // Per-frame arena: everything a ViewState points at is allocated here
    // and freed (reset) at the start of the next render.
    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    while (!backend.shouldClose()) {
        const platform_input = backend.pollInput();
        // Camera is derived (centered on the player), computed once per frame so
        // input (screenToTile) and rendering (tileToScreen) use the identical
        // transform. Future right-drag panning adds a session pan offset here.
        const camera_zoom = history.settings.camera_zoom;
        const camera = computeCamera(&history.current_state, camera_zoom);
        const player_input = input.translateInput(
            platform_input,
            &history.session.input_state,
            history.settings,
            camera,
        );

        // Real frame delta from the backend clock (GetFrameTime on raylib),
        // in microseconds. Drives the turn-flow wait timer in update().
        const delta_microseconds = backend.deltaMicroseconds();

        const had_events = history.current_state.event_stack.len > 0;
        const screen_before_update = history.current_state.screen;
        update(&history, player_input, previous_view_state, delta_microseconds);
        const has_events = history.current_state.event_stack.len > 0;

        // UI panels/drag are transient view state, not part of the undoable
        // GameState. Reset them whenever the screen changes (transitions and
        // undo/redo across a screen boundary both run inside update()). Input
        // state is deliberately left alone — it is live hardware state.
        if (history.current_state.screen != screen_before_update) {
            history.session.ui_state = .{};
        }

        if (had_events and !has_events) {
            // Stack just emptied — save a snapshot, then compact current_arena
            // so the per-turn allocation churn (and any exited level/hub) is
            // reclaimed instead of accumulating across the session.
            history.takeSnapshot();
            history.compactCurrentArena();
        }

        // Build the frame's view and hand it to the backend to draw. Rendering
        // is paced by the backend (vsync / target FPS); we build one ViewState
        // per rendered frame. NOTE: this runs update() exactly once per frame,
        // so a large event stack (e.g. level load) drains at frame rate — a
        // pacing refinement to revisit when it becomes visible (see TODO.txt).
        _ = frame_arena.reset(.retain_capacity);
        previous_view_state = view(
            &history.current_state,
            &history.session,
            history.color_theme_definitions,
            history.weapon_type_definitions,
            camera,
            camera_zoom,
            frame_arena.allocator(),
        );
        backend.render(previous_view_state.?, platform_input.viewport);
    }
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

/// Entry point shared by every platform: load config, build the initial
/// GameState, and run the backend-driven game loop. The `backend` provides
/// window/clock/input/rendering (see gameLoop). Called by the native entry in
/// native.zig (and, later, the web entry) — never from wasm/test builds, so
/// this stays out of the raylib-free compiles even though it is `pub`.
pub fn run(
    backend: anytype,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    io: std.Io,
) void {
    const settings = loadSettingsFromDisk(directory, io, allocator);
    const weapon_type_definitions = loadWeaponTypeDefinitions(directory, io, allocator);
    const color_theme_definitions = loadColorThemeDefinitionsFromDisk(directory, io, allocator);
    const salvage_definitions = loadSalvageDefinitionsFromDisk(directory, io, allocator);

    const starting_game_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    gameLoop(
        backend,
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

test "dragToEvent maps valid drags and blocks cross-domain drops" {
    // inventory → gear = equip
    {
        const event = dragToEvent(.{ .inventory = 2 }, .{ .gear = .boots }).?;
        try std.testing.expectEqual(@as(u32, 2), event.player_event.equip_item.inventory_slot_index);
        try std.testing.expectEqual(types.GearSlot.boots, event.player_event.equip_item.gear_slot);
    }
    // gear → inventory = unequip
    {
        const event = dragToEvent(.{ .gear = .amulet }, .{ .inventory = 5 }).?;
        try std.testing.expectEqual(types.GearSlot.amulet, event.player_event.unequip_item.gear_slot);
        try std.testing.expectEqual(@as(u32, 5), event.player_event.unequip_item.inventory_slot_index);
    }
    // learned skill → skill bar = equip utility skill
    {
        const event = dragToEvent(.{ .learned_skill = .replenish }, .{ .skill_bar = 1 }).?;
        try std.testing.expectEqual(types.SkillId.replenish, event.player_event.equip_utility_skill.skill_id);
        try std.testing.expectEqual(@as(u32, 1), event.player_event.equip_utility_skill.slot_index);
    }
    // skill bar → skill bar = swap
    {
        const event = dragToEvent(.{ .skill_bar = 0 }, .{ .skill_bar = 3 }).?;
        try std.testing.expectEqual(@as(u32, 0), event.player_event.swap_utility_skills.slot_a_index);
        try std.testing.expectEqual(@as(u32, 3), event.player_event.swap_utility_skills.slot_b_index);
    }
    // skill bar → learned skill (skills menu) = unequip utility skill
    {
        const event = dragToEvent(.{ .skill_bar = 2 }, .{ .learned_skill = .slice }).?;
        try std.testing.expectEqual(@as(u32, 2), event.player_event.unequip_utility_skill.slot_index);
    }
    // Cross-domain and nonsensical drops are no-ops.
    try std.testing.expectEqual(@as(?Event, null), dragToEvent(.{ .inventory = 0 }, .{ .skill_bar = 0 }));
    try std.testing.expectEqual(@as(?Event, null), dragToEvent(.{ .learned_skill = .slice }, .{ .gear = .coat }));
    try std.testing.expectEqual(@as(?Event, null), dragToEvent(.{ .gear = .coat }, .{ .gear = .boots }));
    // inventory → inventory move is not implemented yet.
    try std.testing.expectEqual(@as(?Event, null), dragToEvent(.{ .inventory = 0 }, .{ .inventory = 1 }));
}


