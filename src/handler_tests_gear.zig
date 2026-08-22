//! Tier 1 handler tests — gear & skill mechanics. Each test is a scripted
//! mini-session against a hub-context player (no level needed: the gear
//! handlers' side effects — `refreshMoveHighlights`/`cancelPreparedSkill` —
//! early-return without a level, so the mechanics are tested in isolation
//! here; the side-effect branches land with the Tier 2 combat tests). See
//! TODO → Tech debt (handler coverage) and AGENTS → Architecture (gear
//! operations use GearSlot; equip no-ops on type mismatch).

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");
const event_handlers = @import("event_handlers.zig");
const functions = @import("functions.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;
const GameState = state.GameState;
const Entity = types.Entity;
const Item = types.Item;
const GearSlot = types.GearSlot;
const Weapon = types.Weapon;
const Amulet = types.Amulet;
const Boots = types.Boots;
const SkillTome = types.SkillTome;
const SkillId = types.SkillId;
const Event = events.Event;
const PlayerEvent = events.PlayerEvent;

// ───────────────────────── fixtures ─────────────────────────

/// A hub-context GameState with `player` as the controllable entity. Gear
/// handlers resolve the player via `getPlayerEntity(current, 0)` which returns
/// `&hub.player` in a hub, so this is all the context they need.
fn hubStateWithPlayer(player_entity: Entity) GameState {
    return .{
        .screen = .hub,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = .{ .player = player_entity },
    };
}

/// Push a single player event and run the history to idle.
fn pushAndRun(history: *state.GameStateHistory, event: PlayerEvent) void {
    event_handlers.pushEvents(&history.current_state, &.{.{ .player_event = event }}, history.current_arena.allocator());
    runToIdle(history);
}

/// Mutable pointer to the hub player (entity 0).
fn player(history: *state.GameStateHistory) *Entity {
    return &history.current_state.hub.?.player;
}

// Deep-copy-safe field checks: `runToIdle` compacts the current arena
// (deep-copying current_state), so slice POINTERS change but scalar fields
// and slice CONTENTS survive. Each test identifies items by a unique scalar
// (weapon_damage, speed_bonus, spell_damage) rather than by struct equality.
fn expectWeapon(actual: ?Weapon, expected_damage: u32) !void {
    try testing.expect(actual != null);
    try testing.expectEqual(expected_damage, actual.?.weapon_damage);
}
fn expectBoots(actual: ?Boots, expected_speed: u32) !void {
    try testing.expect(actual != null);
    try testing.expectEqual(expected_speed, actual.?.speed_bonus);
}
fn inventoryWeaponDamage(slot: ?Item) ?u32 {
    const item = slot orelse return null;
    return switch (item) { .weapon => |w| w.weapon_damage, else => null };
}
fn inventoryBootsSpeed(slot: ?Item) ?u32 {
    const item = slot orelse return null;
    return switch (item) { .boots => |b| b.speed_bonus, else => null };
}

// ───────────────────────── equip_item ─────────────────────────

test "equip_item: empty inventory slot is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    // Slot 5 is empty by default; main_hand is empty.
    pushAndRun(&history, .{ .equip_item = .{ .inventory_slot_index = 5, .gear_slot = .main_hand } });
    try testing.expectEqual(@as(?Weapon, null), player(&history).main_hand_weapon);
    try testing.expectEqual(@as(?Item, null), player(&history).inventory.slots[5]);
}

test "equip_item: type mismatch is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).inventory.slots[2] = .{ .amulet = .{ .name = "amp", .spell_damage = 3 } };
    pushAndRun(&history, .{ .equip_item = .{ .inventory_slot_index = 2, .gear_slot = .main_hand } });
    // Amulet stays in the inventory slot; main_hand still empty (type mismatch
    // → no-op, nothing equipped).
    try testing.expectEqual(@as(?Weapon, null), player(&history).main_hand_weapon);
    try testing.expect(player(&history).inventory.slots[2] != null);
    try testing.expectEqual(@as(?Amulet, null), player(&history).amulet);
}

test "equip_item: into an empty gear slot moves the item" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const sword: Weapon = .{ .name = "sword", .weapon_type = .sword, .weapon_damage = 5 };
    player(&history).inventory.slots[3] = .{ .weapon = sword };
    pushAndRun(&history, .{ .equip_item = .{ .inventory_slot_index = 3, .gear_slot = .main_hand } });
    try expectWeapon(player(&history).main_hand_weapon, 5);
    try testing.expectEqual(@as(?Item, null), player(&history).inventory.slots[3]);
}

test "equip_item: into a filled gear slot swaps the old piece back" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const old_sword: Weapon = .{ .name = "old", .weapon_type = .sword, .weapon_damage = 2 };
    const new_sword: Weapon = .{ .name = "new", .weapon_type = .sword, .weapon_damage = 7 };
    player(&history).main_hand_weapon = old_sword;
    player(&history).inventory.slots[4] = .{ .weapon = new_sword };
    pushAndRun(&history, .{ .equip_item = .{ .inventory_slot_index = 4, .gear_slot = .main_hand } });
    try expectWeapon(player(&history).main_hand_weapon, 7);
    // The old piece (damage 2) drops back into the SAME inventory slot (4).
    try testing.expectEqual(@as(?u32, 2), inventoryWeaponDamage(player(&history).inventory.slots[4]));
}

// ───────────────────────── unequip_item ─────────────────────────

test "unequip_item: empty gear slot is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).inventory.slots[6] = .{ .weapon = .{ .name = "x", .weapon_damage = 1 } };
    pushAndRun(&history, .{ .unequip_item = .{ .gear_slot = .boots, .inventory_slot_index = 6 } });
    // boots was empty → no-op; inventory slot untouched.
    try testing.expectEqual(@as(?Boots, null), player(&history).boots);
    try testing.expect(player(&history).inventory.slots[6] != null);
}

test "unequip_item: into an empty inventory slot moves the piece out" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const boots: Boots = .{ .name = "boot", .speed_bonus = 1 };
    player(&history).boots = boots;
    pushAndRun(&history, .{ .unequip_item = .{ .gear_slot = .boots, .inventory_slot_index = 10 } });
    try testing.expectEqual(@as(?Boots, null), player(&history).boots);
    try testing.expectEqual(@as(?u32, 1), inventoryBootsSpeed(player(&history).inventory.slots[10]));
}

test "unequip_item: into a filled slot that fits swaps" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const worn: Boots = .{ .name = "worn", .speed_bonus = 1 };
    const spare: Boots = .{ .name = "spare", .speed_bonus = 2 };
    player(&history).boots = worn;
    player(&history).inventory.slots[11] = .{ .boots = spare };
    pushAndRun(&history, .{ .unequip_item = .{ .gear_slot = .boots, .inventory_slot_index = 11 } });
    // The inventory's spare boots (speed 2) go into the gear slot; worn (speed
    // 1) drops into slot 11.
    try expectBoots(player(&history).boots, 2);
    try testing.expectEqual(@as(?u32, 1), inventoryBootsSpeed(player(&history).inventory.slots[11]));
}

test "unequip_item: into a filled slot that does not fit is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const worn: Boots = .{ .name = "worn", .speed_bonus = 1 };
    player(&history).boots = worn;
    player(&history).inventory.slots[12] = .{ .amulet = .{ .name = "amp", .spell_damage = 1 } };
    pushAndRun(&history, .{ .unequip_item = .{ .gear_slot = .boots, .inventory_slot_index = 12 } });
    // Amulet doesn't fit boots → no-op. boots still worn (speed 1).
    try expectBoots(player(&history).boots, 1);
    try testing.expect(player(&history).inventory.slots[12] != null);
}

// ───────────────────────── learn_skill ─────────────────────────

test "learn_skill: empty inventory slot is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    pushAndRun(&history, .{ .learn_skill = .{ .inventory_slot_index = 7 } });
    // No tome consumed, no skill added (learned_skills stays empty by default).
    try testing.expectEqual(@as(usize, 0), history.current_state.player_data.learned_skills.len);
    try testing.expectEqual(@as(?Item, null), player(&history).inventory.slots[7]);
}

test "learn_skill: non-tome item is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).inventory.slots[8] = .{ .weapon = .{ .name = "w", .weapon_damage = 1 } };
    pushAndRun(&history, .{ .learn_skill = .{ .inventory_slot_index = 8 } });
    try testing.expectEqual(@as(usize, 0), history.current_state.player_data.learned_skills.len);
    // Weapon stays in the slot.
    try testing.expect(player(&history).inventory.slots[8] != null);
}

test "learn_skill: already-learned skill is a no-op (tome stays)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    // Pre-seed learned_skills with .slice via a direct player_data write.
    history.current_state.player_data.learned_skills = blk: {
        const skills = history.current_arena.allocator().alloc(SkillId, 1) catch @panic("alloc");
        skills[0] = .slice;
        break :blk skills;
    };
    player(&history).inventory.slots[9] = .{ .skill_tome = .{ .skill = .slice, .value = 5 } };
    pushAndRun(&history, .{ .learn_skill = .{ .inventory_slot_index = 9 } });
    // Already learned → tome NOT consumed, list unchanged.
    try testing.expectEqual(@as(usize, 1), history.current_state.player_data.learned_skills.len);
    try testing.expectEqual(SkillId.slice, history.current_state.player_data.learned_skills[0]);
    try testing.expect(player(&history).inventory.slots[9] != null);
}

test "learn_skill: valid tome is consumed and the skill is added" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).inventory.slots[9] = .{ .skill_tome = .{ .skill = .replenish, .value = 5 } };
    pushAndRun(&history, .{ .learn_skill = .{ .inventory_slot_index = 9 } });
    try testing.expectEqual(@as(?Item, null), player(&history).inventory.slots[9]);
    try testing.expectEqual(@as(usize, 1), history.current_state.player_data.learned_skills.len);
    try testing.expectEqual(SkillId.replenish, history.current_state.player_data.learned_skills[0]);
}

// ───────────────────────── salvage_item ─────────────────────────

test "salvage_item: empty inventory slot is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const materials_before = history.current_state.player_data.materials;
    pushAndRun(&history, .{ .salvage_item = .{ .inventory_slot_index = 13 } });
    try testing.expectEqual(materials_before, history.current_state.player_data.materials);
}

test "salvage_item: valid item is removed and materials increase by its salvage value" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const weapon: Weapon = .{ .name = "salvage_me", .weapon_type = .sword, .weapon_damage = 4 };
    player(&history).inventory.slots[14] = .{ .weapon = weapon };
    const expected = functions.computeSalvageValue(.{ .weapon = weapon }, history.salvage_definitions);
    const before = history.current_state.player_data.materials;
    pushAndRun(&history, .{ .salvage_item = .{ .inventory_slot_index = 14 } });
    try testing.expectEqual(@as(?Item, null), player(&history).inventory.slots[14]);
    var after = before;
    after.add(expected);
    try testing.expectEqual(after, history.current_state.player_data.materials);
}

// ───────────────────────── utility skills ─────────────────────────

test "equip_utility_skill: out-of-range slot is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    pushAndRun(&history, .{ .equip_utility_skill = .{ .skill_id = .replenish, .slot_index = 99 } });
    for (player(&history).equipped_utility_skills) |slot| {
        try testing.expectEqual(@as(?SkillId, null), slot);
    }
}

test "equip_utility_skill: valid slot sets the skill" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    pushAndRun(&history, .{ .equip_utility_skill = .{ .skill_id = .replenish, .slot_index = 2 } });
    try testing.expectEqual(@as(?SkillId, .replenish), player(&history).equipped_utility_skills[2]);
    // Other slots untouched.
    try testing.expectEqual(@as(?SkillId, null), player(&history).equipped_utility_skills[0]);
}

test "equip_utility_skill: overwrites a filled slot" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[1] = .howl;
    pushAndRun(&history, .{ .equip_utility_skill = .{ .skill_id = .replenish, .slot_index = 1 } });
    try testing.expectEqual(@as(?SkillId, .replenish), player(&history).equipped_utility_skills[1]);
}

test "swap_utility_skills: either index out of range is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[0] = .howl;
    pushAndRun(&history, .{ .swap_utility_skills = .{ .slot_a_index = 0, .slot_b_index = 99 } });
    try testing.expectEqual(@as(?SkillId, .howl), player(&history).equipped_utility_skills[0]);
}

test "swap_utility_skills: valid indices swap contents" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[0] = .howl;
    player(&history).equipped_utility_skills[3] = .replenish;
    pushAndRun(&history, .{ .swap_utility_skills = .{ .slot_a_index = 0, .slot_b_index = 3 } });
    try testing.expectEqual(@as(?SkillId, .replenish), player(&history).equipped_utility_skills[0]);
    try testing.expectEqual(@as(?SkillId, .howl), player(&history).equipped_utility_skills[3]);
}

test "swap_utility_skills: two null slots swap to null (no crash)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    pushAndRun(&history, .{ .swap_utility_skills = .{ .slot_a_index = 0, .slot_b_index = 4 } });
    try testing.expectEqual(@as(?SkillId, null), player(&history).equipped_utility_skills[0]);
    try testing.expectEqual(@as(?SkillId, null), player(&history).equipped_utility_skills[4]);
}

test "unequip_utility_skill: out-of-range slot is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[0] = .howl;
    pushAndRun(&history, .{ .unequip_utility_skill = .{ .slot_index = 99 } });
    try testing.expectEqual(@as(?SkillId, .howl), player(&history).equipped_utility_skills[0]);
}

test "unequip_utility_skill: valid slot clears to null" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[2] = .howl;
    pushAndRun(&history, .{ .unequip_utility_skill = .{ .slot_index = 2 } });
    try testing.expectEqual(@as(?SkillId, null), player(&history).equipped_utility_skills[2]);
}
