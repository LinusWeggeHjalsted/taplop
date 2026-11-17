//! Tier 1 handler tests - gear & skill mechanics. Each test is a scripted
//! mini-session against a hub-context player (no level needed: the gear
//! handlers' side effects - `refreshMoveHighlights`/`cancelPreparedSkill` -
//! early-return without a level, so the mechanics are tested in isolation
//! here; the side-effect branches land with the Tier 2 combat tests). See
//! TODO → Tech debt (handler coverage) and DESIGN → Architecture (gear
//! operations use GearSlot; equip no-ops on type mismatch).

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");
const event_handlers = @import("event_handlers.zig");
const event_push = @import("event_push.zig");
const functions = @import("functions.zig");
const test_harness = @import("test_harness.zig");
const input_handlers = @import("input_handlers.zig");
const input_gestures = @import("input_gestures.zig");
const input = @import("input.zig");
const ui = @import("ui.zig");

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
    event_push.pushEvents(&history.current_state, &.{.{ .player_event = event }}, history.current_arena.allocator());
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
    return switch (item) {
        .weapon => |w| w.weapon_damage,
        else => null,
    };
}
fn inventoryBootsSpeed(slot: ?Item) ?u32 {
    const item = slot orelse return null;
    return switch (item) {
        .boots => |b| b.speed_bonus,
        else => null,
    };
}

// ───────────────────────── swap_hands ─────────────────────────

test "swap_hands: the hands trade weapons and a prepared skill is cancelled" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // Level context (not the file's hub default): the swap's
    // cancelPreparedSkill side effect needs a level to act on, and the
    // prepared skill rides level state.
    const three_by_three = [_]types.Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
        .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 },
    };
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    const player_entity = test_harness.levelEntity(&history, 0);
    player_entity.main_hand_weapon = .{ .name = "sword", .weapon_type = .sword, .weapon_damage = 5 };
    player_entity.off_hand_weapon = .{ .name = "spear", .weapon_type = .spear, .weapon_damage = 7 };
    history.current_state.level.?.prepared_skill = .slice;

    event_push.pushPlayerAction(
        &history.current_state,
        .swap_hands,
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    // The weapons trade places (identified by damage, not struct equality -
    // runToIdle's arena compaction re-addresses everything).
    try expectWeapon(test_harness.levelEntity(&history, 0).main_hand_weapon, 7);
    try expectWeapon(test_harness.levelEntity(&history, 0).off_hand_weapon, 5);
    // The prepared skill does not linger into the new main hand's slots
    // (the equip-weapon precedent).
    try testing.expectEqual(@as(?SkillId, null), history.current_state.level.?.prepared_skill);
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

// ───────────────────────── player_salvage_inventory_region ─────────────────────────

// The region orchestrator fans out one salvage_item per OCCUPIED slot in
// the bounding box of the two corner indices (order-independent). Empty
// slots in the box are skipped. Mirrors the live shift-drag gesture.
test "player_salvage_inventory_region: salves occupied slots in the box, skips empty" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    // Place items at slot 0 (row 0 col 0), slot 9 (row 1 col 1), and slot 17
    // (row 2 col 1). Leave the rest empty.
    const weapon_a: Weapon = .{ .name = "a", .weapon_type = .sword, .weapon_damage = 4 };
    const weapon_b: Weapon = .{ .name = "b", .weapon_type = .sword, .weapon_damage = 4 };
    const weapon_c: Weapon = .{ .name = "c", .weapon_type = .sword, .weapon_damage = 4 };
    player(&history).inventory.slots[0] = .{ .weapon = weapon_a };
    player(&history).inventory.slots[9] = .{ .weapon = weapon_b };
    player(&history).inventory.slots[17] = .{ .weapon = weapon_c };
    const before = history.current_state.player_data.materials;
    // Box from slot 0 to slot 17 covers rows 0-2, cols 0-1 (6 slots), 3
    // occupied. Corners given in reverse order to confirm order-independence.
    pushInputAndRun(&history, .{ .player_salvage_inventory_region = .{
        .start_slot = 17,
        .end_slot = 0,
    } });
    try testing.expectEqual(@as(?Item, null), player(&history).inventory.slots[0]);
    try testing.expectEqual(@as(?Item, null), player(&history).inventory.slots[9]);
    try testing.expectEqual(@as(?Item, null), player(&history).inventory.slots[17]);
    var after = before;
    after.add(functions.computeSalvageValue(.{ .weapon = weapon_a }, history.salvage_definitions));
    after.add(functions.computeSalvageValue(.{ .weapon = weapon_b }, history.salvage_definitions));
    after.add(functions.computeSalvageValue(.{ .weapon = weapon_c }, history.salvage_definitions));
    try testing.expectEqual(after, history.current_state.player_data.materials);
}

test "player_salvage_inventory_region: box with no occupied slots is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const before = history.current_state.player_data.materials;
    pushInputAndRun(&history, .{
        .player_salvage_inventory_region = .{
            .start_slot = 0,
            .end_slot = 7, // entire first row, all empty
        },
    });
    try testing.expectEqual(before, history.current_state.player_data.materials);
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

// ───────────── equip_utility_skill: cooldown inheritance ─────────────
// See DESIGN → Architecture (Cooldown inheritance on skill/weapon swap).
// Equipping a skill onto a bar slot sets the incoming cd to @max(old slot
// cd, incoming cd); the outgoing skill's cd is PRESERVED (not cleared).

test "equip_utility_skill: incoming inherits @max(old slot cd, incoming cd)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[1] = .howl;
    player(&history).skill_cooldowns.set(.howl, 3);
    player(&history).skill_cooldowns.set(.replenish, 1);
    pushAndRun(&history, .{ .equip_utility_skill = .{ .skill_id = .replenish, .slot_index = 1 } });
    try testing.expectEqual(@as(u32, 3), player(&history).skill_cooldowns.get(.replenish));
}

test "equip_utility_skill: into empty slot preserves incoming cd" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).skill_cooldowns.set(.replenish, 4);
    pushAndRun(&history, .{ .equip_utility_skill = .{ .skill_id = .replenish, .slot_index = 2 } });
    try testing.expectEqual(@as(u32, 4), player(&history).skill_cooldowns.get(.replenish));
}

test "equip_utility_skill: outgoing skill cd is preserved (not cleared)" {
    // Rotating a used skill off the bar must not reset it - otherwise the
    // player could cycle use→swap-out→swap-back-in to bypass cooldowns.
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[1] = .howl;
    player(&history).skill_cooldowns.set(.howl, 3);
    player(&history).skill_cooldowns.set(.replenish, 0);
    pushAndRun(&history, .{ .equip_utility_skill = .{ .skill_id = .replenish, .slot_index = 1 } });
    try testing.expectEqual(@as(u32, 3), player(&history).skill_cooldowns.get(.howl));
}

// ───────────── equip_item: weapon cooldown inheritance ─────────────
// See DESIGN → Architecture (Cooldown inheritance on skill/weapon swap).
// Equipping a weapon sets ALL THREE of its skill cds to @max(old weapon's
// corresponding cd, new weapon's corresponding cd), even the hidden one.

test "equip_item: main_hand weapon inherits @max for all 3 skills" {
    // sword (old, main_hand): slice=3, spinblade=0, flash_strike=5
    // spear (new, inventory): toss=1, impale=0, skewer=2
    // expect: toss=max(3,1)=3, impale=max(0,0)=0, skewer=max(5,2)=5
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const sword: Weapon = .{ .name = "sword", .weapon_type = .sword, .weapon_damage = 2 };
    const spear: Weapon = .{ .name = "spear", .weapon_type = .spear, .weapon_damage = 7 };
    player(&history).main_hand_weapon = sword;
    player(&history).inventory.slots[4] = .{ .weapon = spear };
    player(&history).skill_cooldowns.set(.slice, 3);
    player(&history).skill_cooldowns.set(.flash_strike, 5);
    player(&history).skill_cooldowns.set(.toss, 1);
    player(&history).skill_cooldowns.set(.skewer, 2);
    pushAndRun(&history, .{ .equip_item = .{ .inventory_slot_index = 4, .gear_slot = .main_hand } });
    try testing.expectEqual(@as(u32, 3), player(&history).skill_cooldowns.get(.toss));
    try testing.expectEqual(@as(u32, 0), player(&history).skill_cooldowns.get(.impale));
    // skill_3 (skewer) is hidden while spear is in main_hand, but its cd is
    // set anyway and surfaces if the player swap_hands.
    try testing.expectEqual(@as(u32, 5), player(&history).skill_cooldowns.get(.skewer));
}

test "equip_item: off_hand weapon inherits @max for all 3 skills" {
    // Only skill_3 is exposed for the off hand, but all 3 are inherited.
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const sword: Weapon = .{ .name = "sword", .weapon_type = .sword, .weapon_damage = 2 };
    const spear: Weapon = .{ .name = "spear", .weapon_type = .spear, .weapon_damage = 7 };
    player(&history).off_hand_weapon = sword;
    player(&history).inventory.slots[4] = .{ .weapon = spear };
    player(&history).skill_cooldowns.set(.slice, 3);
    player(&history).skill_cooldowns.set(.flash_strike, 5);
    player(&history).skill_cooldowns.set(.toss, 1);
    player(&history).skill_cooldowns.set(.skewer, 2);
    pushAndRun(&history, .{ .equip_item = .{ .inventory_slot_index = 4, .gear_slot = .off_hand } });
    try testing.expectEqual(@as(u32, 3), player(&history).skill_cooldowns.get(.toss));
    try testing.expectEqual(@as(u32, 0), player(&history).skill_cooldowns.get(.impale));
    try testing.expectEqual(@as(u32, 5), player(&history).skill_cooldowns.get(.skewer));
}

test "equip_item: weapon into empty hand preserves own cds" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    const spear: Weapon = .{ .name = "spear", .weapon_type = .spear, .weapon_damage = 7 };
    player(&history).inventory.slots[3] = .{ .weapon = spear };
    player(&history).skill_cooldowns.set(.toss, 2);
    player(&history).skill_cooldowns.set(.skewer, 4);
    pushAndRun(&history, .{ .equip_item = .{ .inventory_slot_index = 3, .gear_slot = .main_hand } });
    try testing.expectEqual(@as(u32, 2), player(&history).skill_cooldowns.get(.toss));
    try testing.expectEqual(@as(u32, 0), player(&history).skill_cooldowns.get(.impale));
    try testing.expectEqual(@as(u32, 4), player(&history).skill_cooldowns.get(.skewer));
}

// ───────────────── player_assign_utility_skill (no-duplicate rule) ─────────────────

/// Push a single player-input orchestrator event and run to idle.
fn pushInputAndRun(history: *state.GameStateHistory, event: events.PlayerInputEvent) void {
    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = event }}, history.current_arena.allocator());
    runToIdle(history);
}

test "player_assign_utility_skill: fresh skill assigns to the slot" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    pushInputAndRun(&history, .{ .player_assign_utility_skill = .{
        .skill_id = .replenish,
        .slot_index = 2,
    } });
    try testing.expectEqual(@as(?SkillId, .replenish), player(&history).equipped_utility_skills[2]);
}

test "player_assign_utility_skill: skill already in another slot swaps instead of duplicating" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[0] = .replenish; // existing copy
    player(&history).equipped_utility_skills[3] = .howl; // target occupied
    // Drag the learned replenish onto slot index 3.
    pushInputAndRun(&history, .{ .player_assign_utility_skill = .{
        .skill_id = .replenish,
        .slot_index = 3,
    } });
    // The skill moved to the target slot; no duplicate. The displaced howl
    // lands where replenish was (swap, not overwrite).
    try testing.expectEqual(@as(?SkillId, .replenish), player(&history).equipped_utility_skills[3]);
    try testing.expectEqual(@as(?SkillId, .howl), player(&history).equipped_utility_skills[0]);
    // No slot holds a second copy.
    var replenish_count: usize = 0;
    for (player(&history).equipped_utility_skills) |slot| {
        if (slot == .replenish) replenish_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), replenish_count);
}

test "player_assign_utility_skill: drop onto the slot that already holds the skill is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[2] = .replenish;
    player(&history).equipped_utility_skills[0] = .howl;
    pushInputAndRun(&history, .{ .player_assign_utility_skill = .{
        .skill_id = .replenish,
        .slot_index = 2,
    } });
    // Unchanged - no self-swap, no duplicate.
    try testing.expectEqual(@as(?SkillId, .replenish), player(&history).equipped_utility_skills[2]);
    try testing.expectEqual(@as(?SkillId, .howl), player(&history).equipped_utility_skills[0]);
}

test "player_assign_utility_skill: swap moves the skill to an empty target slot" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[1] = .replenish; // existing copy
    // slot 4 empty
    pushInputAndRun(&history, .{ .player_assign_utility_skill = .{
        .skill_id = .replenish,
        .slot_index = 4,
    } });
    try testing.expectEqual(@as(?SkillId, .replenish), player(&history).equipped_utility_skills[4]);
    try testing.expectEqual(@as(?SkillId, null), player(&history).equipped_utility_skills[1]);
}

test "player_assign_utility_skill: out-of-range slot is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    pushInputAndRun(&history, .{ .player_assign_utility_skill = .{
        .skill_id = .replenish,
        .slot_index = 99,
    } });
    for (player(&history).equipped_utility_skills) |slot| {
        try testing.expectEqual(@as(?SkillId, null), slot);
    }
}

// ───────────────── handleDrag: drag a skill off the bar (clear on drop-off) ─────────────────

/// A minimal skill-bar button element at `pos` size 256 carrying
/// `ref = .{ .skill_bar = slot }`, mirroring `emitSkillButton`'s filled-slot
/// emit (background button + ref). Enough for `handleDrag`'s `refAt` +
/// `slotContentIcon` to resolve the slot.
fn skillBarElement(slot: u32, pos: types.ScreenPosition) ui.UiElement {
    return .{ .button = .{
        .sprite_id = "ui/skill_button",
        .screen_position = pos,
        .width = 256,
        .height = 256,
        .action = .skill_slot_4,
        .ref = .{ .skill_bar = slot },
    } };
}

test "handleDrag: drag a bar skill to empty space clears the slot" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[0] = .replenish;

    const elements = [_]ui.UiElement{skillBarElement(0, .{ .x = 0, .y = 0 })};

    // Press on the slot → records a pending press.
    input_gestures.handleDrag(&history, .{ .pressed = true, .position = .{ .x = 10, .y = 10 } }, &elements);
    // Move past the drag threshold → promotes to a drag.
    input_gestures.handleDrag(&history, .{ .position = .{ .x = 500, .y = 500 } }, &elements);
    // Release over empty space (no ref under the pointer) → off-bar → clear.
    input_gestures.handleDrag(&history, .{ .released = true, .position = .{ .x = 500, .y = 500 } }, &elements);

    runToIdle(&history);
    try testing.expectEqual(@as(?SkillId, null), player(&history).equipped_utility_skills[0]);
}

test "handleDrag: drag a bar skill onto an inventory ref (cross-domain) clears the slot" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[0] = .replenish;

    // A skill-bar slot at (0,0) and an inventory slot at (400,0).
    const elements = [_]ui.UiElement{
        skillBarElement(0, .{ .x = 0, .y = 0 }),
        .{ .slot = .{
            .screen_position = .{ .x = 400, .y = 0 },
            .size = 128,
            .icon_sprite_id = "ui/item_slot",
            .ref = .{ .inventory = 0 },
        } },
    };

    input_gestures.handleDrag(&history, .{ .pressed = true, .position = .{ .x = 10, .y = 10 } }, &elements);
    input_gestures.handleDrag(&history, .{ .position = .{ .x = 450, .y = 10 } }, &elements);
    // Release over the inventory slot - cross-domain, dragToOrchestrator
    // returns null, not a self-drop → off-bar → clear.
    input_gestures.handleDrag(&history, .{ .released = true, .position = .{ .x = 450, .y = 10 } }, &elements);

    runToIdle(&history);
    try testing.expectEqual(@as(?SkillId, null), player(&history).equipped_utility_skills[0]);
}

test "handleDrag: release back on the source slot is a no-op (no clear)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[0] = .replenish;

    const elements = [_]ui.UiElement{skillBarElement(0, .{ .x = 0, .y = 0 })};

    input_gestures.handleDrag(&history, .{ .pressed = true, .position = .{ .x = 10, .y = 10 } }, &elements);
    input_gestures.handleDrag(&history, .{ .position = .{ .x = 500, .y = 500 } }, &elements);
    // Release back over the source slot → self-drop → no-op.
    input_gestures.handleDrag(&history, .{ .released = true, .position = .{ .x = 10, .y = 10 } }, &elements);

    runToIdle(&history);
    try testing.expectEqual(@as(?SkillId, .replenish), player(&history).equipped_utility_skills[0]);
}

test "handleDrag: drag a bar skill onto another bar slot swaps (not clear)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[0] = .replenish;
    player(&history).equipped_utility_skills[3] = .howl;

    const elements = [_]ui.UiElement{
        skillBarElement(0, .{ .x = 0, .y = 0 }),
        skillBarElement(3, .{ .x = 400, .y = 0 }),
    };

    input_gestures.handleDrag(&history, .{ .pressed = true, .position = .{ .x = 10, .y = 10 } }, &elements);
    input_gestures.handleDrag(&history, .{ .position = .{ .x = 450, .y = 10 } }, &elements);
    // Release over slot 3 → swap (not clear).
    input_gestures.handleDrag(&history, .{ .released = true, .position = .{ .x = 450, .y = 10 } }, &elements);

    runToIdle(&history);
    try testing.expectEqual(@as(?SkillId, .howl), player(&history).equipped_utility_skills[0]);
    try testing.expectEqual(@as(?SkillId, .replenish), player(&history).equipped_utility_skills[3]);
}

// ───────────────────────── drag no-op gate ─────────────────────────
// A drop that would change nothing (unfitting item→gear or gear→occupied
// pair, re-assigning the skill already in the slot) never fires - no dead
// undo step. The pure predicate is covered in input_gestures.zig; these
// pin the wiring through handleDrag.

fn inventorySlotElement(slot: u32, pos: types.ScreenPosition) ui.UiElement {
    return .{ .slot = .{
        .screen_position = pos,
        .size = 128,
        .icon_sprite_id = "ui/item_slot",
        .ref = .{ .inventory = slot },
    } };
}

fn gearSlotElement(gear_slot: types.GearSlot, pos: types.ScreenPosition) ui.UiElement {
    return .{ .slot = .{
        .screen_position = pos,
        .size = 128,
        .icon_sprite_id = "ui/item_slot",
        .ref = .{ .gear = gear_slot },
    } };
}

test "handleDrag: unfitting equip drop never fires" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).inventory.slots[0] = .{ .weapon = .{
        .name = "sword",
        .weapon_type = .sword,
        .weapon_damage = 4,
    } };

    // An inventory slot at (0,0) holding the sword; the boots gear slot at
    // (400,0).
    const elements = [_]ui.UiElement{
        inventorySlotElement(0, .{ .x = 0, .y = 0 }),
        gearSlotElement(.boots, .{ .x = 400, .y = 0 }),
    };
    input_gestures.handleDrag(&history, .{ .pressed = true, .position = .{ .x = 10, .y = 10 } }, &elements);
    input_gestures.handleDrag(&history, .{ .position = .{ .x = 450, .y = 10 } }, &elements);
    input_gestures.handleDrag(&history, .{ .released = true, .position = .{ .x = 450, .y = 10 } }, &elements);

    // A weapon doesn't fit the boots slot - nothing fired, nothing moved.
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expect(inventoryWeaponDamage(player(&history).inventory.slots[0]) != null);
    try testing.expect(player(&history).boots == null);
}

test "handleDrag: unequip onto a filled unfitting slot never fires" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).boots = .{ .name = "worn boots", .speed_bonus = 2 };
    player(&history).inventory.slots[0] = .{ .weapon = .{
        .name = "sword",
        .weapon_type = .sword,
        .weapon_damage = 4,
    } };

    // The boots gear slot at (0,0); an inventory slot at (400,0) holding a
    // weapon (which doesn't fit the boots slot the piece would vacate).
    const elements = [_]ui.UiElement{
        gearSlotElement(.boots, .{ .x = 0, .y = 0 }),
        inventorySlotElement(0, .{ .x = 400, .y = 0 }),
    };
    input_gestures.handleDrag(&history, .{ .pressed = true, .position = .{ .x = 10, .y = 10 } }, &elements);
    input_gestures.handleDrag(&history, .{ .position = .{ .x = 450, .y = 10 } }, &elements);
    input_gestures.handleDrag(&history, .{ .released = true, .position = .{ .x = 450, .y = 10 } }, &elements);

    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expect(player(&history).boots != null);
    try testing.expect(inventoryWeaponDamage(player(&history).inventory.slots[0]) != null);
}

test "handleDrag: re-assigning the skill already in the bar slot never fires" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(hubStateWithPlayer(.{}));
    player(&history).equipped_utility_skills[0] = .replenish;

    // A learned-skill entry at (0,0); bar slot 0 (already holding that
    // skill) at (400,0).
    const elements = [_]ui.UiElement{
        .{ .slot = .{
            .screen_position = .{ .x = 0, .y = 0 },
            .size = 128,
            .icon_sprite_id = "ui/item_slot",
            .ref = .{ .learned_skill = .replenish },
        } },
        skillBarElement(0, .{ .x = 400, .y = 0 }),
    };
    input_gestures.handleDrag(&history, .{ .pressed = true, .position = .{ .x = 10, .y = 10 } }, &elements);
    input_gestures.handleDrag(&history, .{ .position = .{ .x = 450, .y = 10 } }, &elements);
    input_gestures.handleDrag(&history, .{ .released = true, .position = .{ .x = 450, .y = 10 } }, &elements);

    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try testing.expectEqual(@as(?SkillId, .replenish), player(&history).equipped_utility_skills[0]);
}
