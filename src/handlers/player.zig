//! Player-data mechanics: the `player_event` + `super_event` arms
//! (`handlePlayerEvent` - learn/equip/salvage/swap verbs;
//! `handleSuperEvent` - the entity↔PlayerData sync pair), the gear-slot
//! mutators + salvage helpers, and the clone-harvest math. The input
//! orchestrators live in player_input.zig; the cross-category helpers in
//! shared.zig.

const std = @import("std");
const types = @import("../types.zig");
const events = @import("../events.zig");
const state = @import("../state.zig");
const utility_skills = @import("../utility_skills.zig");
const functions = @import("../functions.zig");
const upgrade_mod = @import("../upgrade.zig");
const event_push = @import("../event_push.zig");
const shared = @import("shared.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Entity = types.Entity;

const SkillId = types.SkillId;
const utility_skill_count = types.utility_skill_count;
const weapon_type_count = @typeInfo(types.WeaponType).@"enum".field_names.len;

const pushEvents = event_push.pushEvents;
const cancelPreparedSkill = shared.cancelPreparedSkill;
const refreshMoveHighlights = shared.refreshMoveHighlights;
const getPlayerEntity = shared.getPlayerEntity;

/// Return the piece currently in a gear slot as an Item, or null if empty.
/// The occupied inventory slot indices inside a salvage region (two
/// opposite-corner slot indices, order-independent). Shared by the
/// `player_salvage_inventory_region` handler (one salvage_item per slot)
/// and the input-side no-op gate (an all-empty region never fires) - one
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

/// Whether `item` can go into `gear_slot`. Shared by the equip/unequip
/// machinery here and the input-side drag no-op gate (input_gestures.zig)
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
/// hand holds the weapon - the hidden skill's cd surfaces later if the player
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
    const new_def = &weapon_type_definitions[@backingInt(new_w.weapon_type)];
    const new_skills = [_]types.SkillId{ new_def.skill_1, new_def.skill_2, new_def.skill_3 };

    const old_skills: [3]?types.SkillId = if (old_weapon) |old_w| blk: {
        const old_def = &weapon_type_definitions[@backingInt(old_w.weapon_type)];
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

/// Pure harvest payout: per material, `(materials_collected * turns_spent)
/// / turns_to_complete` summed over all clones. The multiply happens BEFORE
/// the divide so a clone whose per-turn rate is fractional (materials <
/// turns_to_complete) still pays out - dividing first truncates the rate to
/// 0 and yields nothing. u64 accumulators: both the per-clone quotient
/// (u32-max materials x u32 turns) and the cross-clone sum can exceed u32,
/// so the payout clamps at u32 max per material rather than wrapping
/// (DESIGN → Post-game Rewards & Cosmetics → Overflow guard). Skips clones with `turns_to_complete == 0`. Shared by the
/// `harvest_clones` handler and the `end_level` completion branch (which
/// snapshots the payout onto `MissionCompleteInfo` for the overlay). See
/// DESIGN → Clones (clone system).
pub fn computeHarvest(clones: []const types.Clone, turns_spent: u32) types.Materials {
    if (turns_spent == 0) return .{};
    var wood: u64 = 0;
    var metal: u64 = 0;
    var leather: u64 = 0;
    var cloth: u64 = 0;
    var knowledge: u64 = 0;
    const t: u64 = turns_spent;
    for (clones) |clone| {
        if (clone.turns_to_complete == 0) continue;
        const d: u64 = clone.turns_to_complete;
        wood += (@as(u64, clone.materials_collected.wood) * t) / d;
        metal += (@as(u64, clone.materials_collected.metal) * t) / d;
        leather += (@as(u64, clone.materials_collected.leather) * t) / d;
        cloth += (@as(u64, clone.materials_collected.cloth) * t) / d;
        knowledge += (@as(u64, clone.materials_collected.knowledge) * t) / d;
    }
    return .{
        .wood = @intCast(@min(wood, std.math.maxInt(u32))),
        .metal = @intCast(@min(metal, std.math.maxInt(u32))),
        .leather = @intCast(@min(leather, std.math.maxInt(u32))),
        .cloth = @intCast(@min(cloth, std.math.maxInt(u32))),
        .knowledge = @intCast(@min(knowledge, std.math.maxInt(u32))),
    };
}

/// Whether `skill_id` is in the player's `learned_skills` list. Pure -
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

/// Handle a `SuperEvent` - the entity↔PlayerData sync pair
/// (build_player_from_data / build_data_from_player; see DESIGN →
/// Architecture → PlayerData/Entity sync).
pub fn handleSuperEvent(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    super: events.SuperEvent,
) void {
    const current = &history.current_state;
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
            // (multiply before divide - see computeHarvest).
            // Gated on turns_spent > 0 at the push site, but guard
            // here too in case a hand-crafted replay seeds it at 0.
            // See DESIGN → Clones (clone system).
            const payout = computeHarvest(current.player_data.clones, harvest.turns_spent);
            current.player_data.materials.add(payout);
        },
    }
}

/// Handle a `PlayerEvent` - the direct player verbs (learn/equip/salvage/
/// swap), pushed as machinery children by the input orchestrators.
pub fn handlePlayerEvent(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    player_event: events.PlayerEvent,
) void {
    const current = &history.current_state;
    switch (player_event) {
        .learn_skill => |learn| {
            // Item-action cue: the shared item base + the action's layer
            // (`sfx/items/<stem>_layer`; the pre-layering one-shot plays as
            // the interim layer until the file ships). See DESIGN → Audio
            // (layered cues).
            if (!history.replaying) history.session.queueCue(history.backing_allocator, .{
                .base = .item_base,
                .layer = .{ .item = .learn_skill },
            });
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
            // slots) must not click. Item-action cue - see the
            // learn_skill arm.
            if (!history.replaying) history.session.queueCue(history.backing_allocator, .{
                .base = .item_base,
                .layer = .{ .item = .salvage },
            });

            // Compute salvage value and add to player materials
            const materials = functions.computeSalvageValue(item, history.salvage_definitions);
            current.player_data.materials.add(materials);

            // Remove the item from inventory
            slot.* = null;
        },
        .upgrade_item => |upgrade| {
            const player = getPlayerEntity(current, 0);
            const item: types.Item = switch (upgrade.item) {
                .gear => |gear_slot| player.gearSlotItem(gear_slot) orelse return,
                .inventory => |slot_index| blk: {
                    if (slot_index >= types.inventory_slot_count) return;
                    break :blk player.inventory.slots[slot_index] orelse return;
                },
            };
            const current_value = types.itemStatValue(item, upgrade.stat) orelse return;
            if (current_value >= types.itemStatMax(upgrade.stat)) return;

            // The cost from the same price fns the legality + panel read
            // (one price definition - the live/replay asymmetry guard).
            // The affordability guard is the crafted-log belt: a recorded
            // purchase was validated affordable at record time.
            const definition = functions.getSalvageDefinition(item, history.salvage_definitions);
            const cost = upgrade_mod.rungCostSplit(
                history.upgrade_model,
                upgrade.stat,
                definition,
                current_value,
            );
            if (!upgrade_mod.canAffordMaterials(current.player_data.materials, cost)) return;

            // Sound after the guards: a no-op purchase (crafted logs; the
            // live buttons only emit for purchasable rungs) must not click.
            // Item-action cue - see the salvage_item arm.
            if (!history.replaying) history.session.queueCue(history.backing_allocator, .{
                .base = .item_base,
                .layer = .{ .item = .upgrade },
            });

            // Spend, then mutate the item on the entity (PlayerData's gear
            // copy syncs on save/screen transition - never here).
            current.player_data.materials.subtract(cost);
            const upgraded = types.itemWithStat(item, upgrade.stat, current_value + 1);
            switch (upgrade.item) {
                .gear => |gear_slot| {
                    setGearSlot(player, gear_slot, upgraded);
                    applyGearChangeSideEffects(current, gear_slot, allocator);
                },
                .inventory => |slot_index| player.inventory.slots[slot_index] = upgraded,
            }
        },
        .equip_item => |equip| {
            const player = getPlayerEntity(current, 0);
            const slot = &player.inventory.slots[equip.inventory_slot_index];

            const item = slot.* orelse return;
            if (!itemFitsGearSlot(item, equip.gear_slot)) return;
            // Sound after the guards: a no-op equip (empty slot /
            // unfitting item - crafted logs; live drags are gated at
            // the drop site) must not click. Item-action cue - see the
            // learn_skill arm.
            if (!history.replaying) history.session.queueCue(history.backing_allocator, .{
                .base = .item_base,
                .layer = .{ .item = .equip },
            });

            // Capture the displaced weapon before the gear-slot swap
            // overwrites the slot, so its skill cooldowns can be
            // inherited by the incoming weapon. See DESIGN → Architecture.
            const old_weapon: ?types.Weapon = switch (equip.gear_slot) {
                .main_hand, .off_hand => if (player.gearSlotItem(equip.gear_slot)) |old_item| old_item.weapon else null,
                else => null,
            };

            // Old gear (if any) drops back into the inventory slot.
            slot.* = player.gearSlotItem(equip.gear_slot);
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
            const piece = player.gearSlotItem(unequip.gear_slot) orelse return;
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
            // Only UTILITY skills may sit on the bar - the learned
            // list can contain weapon-skill tomes, so the drag path
            // gates here too (see src/utility_skills.zig).
            if (!utility_skills.isUtilitySkill(equip.skill_id)) return;
            const player = getPlayerEntity(current, 0);

            // Cooldown inheritance: the incoming skill's cd becomes
            // @max(old slot skill cd, incoming cd) so a fresh swap
            // can't bypass a cooldown that was ticking on the
            // displaced skill. The outgoing skill's cd is PRESERVED
            // (not cleared) in skill_cooldowns - see DESIGN → Architecture.
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
}
