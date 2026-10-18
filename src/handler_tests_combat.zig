//! Tier 2 handler tests - combat primitives + gear side effects. Each test
//! builds a level fixture (tiles + entities) via `test_harness.levelStateWith-
//! Entities`, pushes one event, runs to idle, and asserts on `current_state`.
//! See TODO → Tech debt (handler coverage).

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");
const event_handlers = @import("event_handlers.zig");
const event_push = @import("event_push.zig");
const functions = @import("functions.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;
const levelEntity = test_harness.levelEntity;
const Entity = types.Entity;
const Vector2 = types.Vector2;
const Event = events.Event;
const SubLevelEvent = events.SubLevelEvent;
const LevelEvent = events.LevelEvent;
const SkillId = types.SkillId;
const EffectId = types.EffectId;

/// A 3x3 tile grid (0,0)..(2,2) - enough room for combat without crowding.
const three_by_three = [_]Vector2{
    .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
    .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
    .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 },
};

/// Push a single sub-level event and run to idle.
fn pushAndRunSub(history: *state.GameStateHistory, event: SubLevelEvent) void {
    event_push.pushEvents(&history.current_state, &.{.{ .sub_level_event = event }}, history.current_arena.allocator());
    runToIdle(history);
}

/// Push a single level event and run to idle.
fn pushAndRunLevel(history: *state.GameStateHistory, event: LevelEvent) void {
    event_push.pushEvents(&history.current_state, &.{.{ .level_event = event }}, history.current_arena.allocator());
    runToIdle(history);
}

// ───────────────────────── scalar primitives ─────────────────────────

test "heal: clamps to max_health" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .max_health = 20, .current_health = 15 }},
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .heal = .{ .entity_index = 0, .amount = 10 } });
    try testing.expectEqual(@as(u32, 20), levelEntity(&history, 0).current_health);
}

test "heal: no-op on a dead entity (no revive)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .max_health = 20, .current_health = 0 }},
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .heal = .{ .entity_index = 0, .amount = 10 } });
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 0).current_health);
}

test "heal: partial heal up to capacity" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .max_health = 20, .current_health = 15 }},
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .heal = .{ .entity_index = 0, .amount = 3 } });
    try testing.expectEqual(@as(u32, 18), levelEntity(&history, 0).current_health);
}

test "change_momentum: adds and saturates at zero" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .momentum = 2 }},
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .change_momentum = .{ .entity_index = 0, .delta = 3 } });
    try testing.expectEqual(@as(u32, 5), levelEntity(&history, 0).momentum);
    pushAndRunSub(&history, .{ .change_momentum = .{ .entity_index = 0, .delta = -8 } });
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 0).momentum);
}

test "change_momentum: no-op on a dead entity" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .current_health = 0, .momentum = 5 }},
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .change_momentum = .{ .entity_index = 0, .delta = 2 } });
    try testing.expectEqual(@as(u32, 5), levelEntity(&history, 0).momentum);
}

test "change_cooldown: adds and saturates at zero" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0 }},
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .change_cooldown = .{ .entity_index = 0, .skill_id = .slice, .delta = 4 } });
    try testing.expectEqual(@as(u32, 4), levelEntity(&history, 0).skill_cooldowns.get(.slice));
    pushAndRunSub(&history, .{ .change_cooldown = .{ .entity_index = 0, .skill_id = .slice, .delta = -6 } });
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 0).skill_cooldowns.get(.slice));
}

test "change_cooldown: no-op on a dead entity" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .current_health = 0 }},
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .change_cooldown = .{ .entity_index = 0, .skill_id = .slice, .delta = 4 } });
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 0).skill_cooldowns.get(.slice));
}

// ───────────────────────── attack ─────────────────────────

test "attack: no-op if attacker is dead" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 0, .max_health = 20 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .attack = .{ .attacker_index = 0, .defender_index = 1, .outgoing_damage = 5 } });
    try testing.expectEqual(@as(u32, 10), levelEntity(&history, 1).current_health);
}

test "attack: no-op if defender is already dead" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 10, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 0, .max_health = 10 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .attack = .{ .attacker_index = 0, .defender_index = 1, .outgoing_damage = 5 } });
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 1).current_health);
}

test "attack: applies damage minus defense" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 10, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10, .defense = 2 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .attack = .{ .attacker_index = 0, .defender_index = 1, .outgoing_damage = 7 } });
    // 7 outgoing - 2 defense = 5 incoming.
    try testing.expectEqual(@as(u32, 5), levelEntity(&history, 1).current_health);
}

test "attack: killing the defender pushes death" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 10, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 3, .max_health = 10 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .attack = .{ .attacker_index = 0, .defender_index = 1, .outgoing_damage = 5 } });
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 1).current_health);
}

test "attack: heals_attacker lifesteals the damage dealt" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 8, .max_health = 20 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .attack = .{
        .attacker_index = 0,
        .defender_index = 1,
        .outgoing_damage = 5,
        .heals_attacker = true,
    } });
    // Defender takes 5 (10->5); attacker heals 5 (8->13).
    try testing.expectEqual(@as(u32, 5), levelEntity(&history, 1).current_health);
    try testing.expectEqual(@as(u32, 13), levelEntity(&history, 0).current_health);
}

test "attack: absorb converts incoming damage into healing (interceptor)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 20, .active_effects = &.{.{ .effect_id = .absorb, .duration = 1, .additive_effect_modifiers = .{} }} },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .attack = .{
        .attacker_index = 0,
        .defender_index = 1,
        .outgoing_damage = 5,
    } });
    // The interceptor zeroes the damage and heals the receiver for the
    // pre-defense amount: 10 + 5 = 15, no damage taken.
    try testing.expectEqual(@as(u32, 15), levelEntity(&history, 1).current_health);

    // A lethal hit cannot kill through absorb either - the heal clamps
    // to max instead.
    pushAndRunSub(&history, .{ .attack = .{
        .attacker_index = 0,
        .defender_index = 1,
        .outgoing_damage = 999,
    } });
    try testing.expectEqual(@as(u32, 20), levelEntity(&history, 1).current_health);
    try testing.expect(levelEntity(&history, 1).current_health > 0);
}

// ───────────────────────── death ─────────────────────────

test "death: non-player entity drops equipped gear + inventory + skill tomes" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .max_health = 10, .current_health = 0, .main_hand_weapon = .{ .weapon_damage = 4 }, .inventory = .{ .slots = blk: {
                var slots: [types.inventory_slot_count]?types.Item = .{null} ** types.inventory_slot_count;
                slots[0] = .{ .amulet = .{ .spell_damage = 2 } };
                break :blk slots;
            } }, .equipped_utility_skills = blk: {
                var skills: [types.utility_skill_count]?SkillId = .{null} ** types.utility_skill_count;
                skills[0] = .replenish;
                break :blk skills;
            } },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .death = .{ .entity_index = 1 } });
    // One ground stack at the enemy's position (1,0) with 3 items: weapon,
    // amulet, skill tome.
    const level = &history.current_state.level.?;
    try testing.expectEqual(@as(usize, 1), level.ground_items.len);
    try testing.expectEqual(@as(i32, 1), level.ground_items[0].position.x);
    try testing.expectEqual(@as(i32, 0), level.ground_items[0].position.y);
    try testing.expectEqual(@as(usize, 3), level.ground_items[0].items.len);
}

test "death: merges into an existing ground stack at the same position" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // Pre-place a ground stack at (1,0) with one item; the dying enemy is
    // also at (1,0) and drops one item → merged stack of 2.
    const pre_items = try backing.allocator().dupe(types.Item, &.{.{ .amulet = .{ .spell_damage = 1 } }});
    const pre_ground = try backing.allocator().dupe(types.GroundItems, &.{.{ .position = .{ .x = 1, .y = 0 }, .items = pre_items }});
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 0, .main_hand_weapon = .{ .weapon_damage = 4 } },
        },
        &three_by_three,
    ));
    history.current_state.level.?.ground_items = pre_ground;
    pushAndRunSub(&history, .{ .death = .{ .entity_index = 1 } });
    const level = &history.current_state.level.?;
    try testing.expectEqual(@as(usize, 1), level.ground_items.len);
    try testing.expectEqual(@as(usize, 2), level.ground_items[0].items.len);
}

test "death: player (entity 0) drops nothing" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 0, .main_hand_weapon = .{ .weapon_damage = 4 } }},
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .death = .{ .entity_index = 0 } });
    try testing.expectEqual(@as(usize, 0), history.current_state.level.?.ground_items.len);
}

// ───────────────────────── pickup_items ─────────────────────────

test "pickup_items: transfers a ground stack into inventory until full" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const items = try backing.allocator().dupe(types.Item, &.{
        .{ .amulet = .{ .spell_damage = 1 } },
        .{ .weapon = .{ .weapon_damage = 2 } },
    });
    const ground = try backing.allocator().dupe(types.GroundItems, &.{
        .{ .position = .{ .x = 0, .y = 0 }, .items = items },
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    history.current_state.level.?.ground_items = ground;
    pushAndRunSub(&history, .{ .pickup_items = .{ .entity_index = 0, .position = .{ .x = 0, .y = 0 } } });
    // Both items fit (empty inventory); stack removed from ground.
    try testing.expectEqual(@as(usize, 0), history.current_state.level.?.ground_items.len);
    try testing.expect(history.current_state.level.?.entities[0].inventory.slots[0] != null);
    try testing.expect(history.current_state.level.?.entities[0].inventory.slots[1] != null);
}

test "pickup_items: leftover items stay on the ground when inventory fills" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // Build a full inventory (every slot filled) so nothing fits.
    var full_slots: [types.inventory_slot_count]?types.Item = undefined;
    for (&full_slots) |*s| s.* = .{ .amulet = .{ .spell_damage = 99 } };
    const items = try backing.allocator().dupe(types.Item, &.{
        .{ .weapon = .{ .weapon_damage = 5 } },
    });
    const ground = try backing.allocator().dupe(types.GroundItems, &.{
        .{ .position = .{ .x = 0, .y = 0 }, .items = items },
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .inventory = .{ .slots = full_slots } }},
        &three_by_three,
    ));
    history.current_state.level.?.ground_items = ground;
    pushAndRunSub(&history, .{ .pickup_items = .{ .entity_index = 0, .position = .{ .x = 0, .y = 0 } } });
    // Nothing fit → the whole stack stays (as leftovers).
    try testing.expectEqual(@as(usize, 1), history.current_state.level.?.ground_items.len);
    try testing.expectEqual(@as(usize, 1), history.current_state.level.?.ground_items[0].items.len);
}

test "pickup_items: first-empty-slot placement" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // Slot 0 filled, slot 1 empty → pickup lands in slot 1.
    var slots: [types.inventory_slot_count]?types.Item = .{null} ** types.inventory_slot_count;
    slots[0] = .{ .amulet = .{ .spell_damage = 1 } };
    const items = try backing.allocator().dupe(types.Item, &.{.{ .weapon = .{ .weapon_damage = 5 } }});
    const ground = try backing.allocator().dupe(types.GroundItems, &.{
        .{ .position = .{ .x = 0, .y = 0 }, .items = items },
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .inventory = .{ .slots = slots } }},
        &three_by_three,
    ));
    history.current_state.level.?.ground_items = ground;
    pushAndRunSub(&history, .{ .pickup_items = .{ .entity_index = 0, .position = .{ .x = 0, .y = 0 } } });
    try testing.expectEqual(@as(usize, 0), history.current_state.level.?.ground_items.len);
    try testing.expect(history.current_state.level.?.entities[0].inventory.slots[1] != null);
    try testing.expect(history.current_state.level.?.entities[0].inventory.slots[2] == null);
}

// ───────────────────────── pickup_items: clone accumulator ─────────────────────────
// See DESIGN → Clones (clone system). Player pickups accumulate salvage value
// into mission.converted_materials_collected (the clone rate numerator).

test "pickup_items: player pickup adds salvage value to mission converted_materials_collected" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const item: types.Item = .{ .weapon = .{ .weapon_damage = 5, .weapon_type = .sword } };
    const items = try backing.allocator().dupe(types.Item, &.{item});
    const ground = try backing.allocator().dupe(types.GroundItems, &.{
        .{ .position = .{ .x = 0, .y = 0 }, .items = items },
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    history.current_state.level.?.ground_items = ground;
    history.current_state.mission = .{ .uuid = "test-uuid" };
    pushAndRunSub(&history, .{ .pickup_items = .{ .entity_index = 0, .position = .{ .x = 0, .y = 0 } } });
    const expected = functions.computeSalvageValue(item, harness.salvage_definitions);
    const got = history.current_state.mission.?.converted_materials_collected;
    try testing.expectEqual(expected.wood, got.wood);
    try testing.expectEqual(expected.metal, got.metal);
    try testing.expectEqual(expected.leather, got.leather);
    try testing.expectEqual(expected.cloth, got.cloth);
    try testing.expectEqual(expected.knowledge, got.knowledge);
}

test "pickup_items: non-player pickup does not accumulate" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const item: types.Item = .{ .weapon = .{ .weapon_damage = 5, .weapon_type = .sword } };
    const items = try backing.allocator().dupe(types.Item, &.{item});
    const ground = try backing.allocator().dupe(types.GroundItems, &.{
        .{ .position = .{ .x = 0, .y = 0 }, .items = items },
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 } },
        },
        &three_by_three,
    ));
    history.current_state.level.?.ground_items = ground;
    history.current_state.mission = .{ .uuid = "test-uuid" };
    // Entity 1 (enemy) picks up - no accumulation.
    pushAndRunSub(&history, .{ .pickup_items = .{ .entity_index = 1, .position = .{ .x = 0, .y = 0 } } });
    const got = history.current_state.mission.?.converted_materials_collected;
    try testing.expectEqual(@as(u32, 0), got.wood);
    try testing.expectEqual(@as(u32, 0), got.metal);
}

test "pickup_items: leftover items that don't fit don't accumulate" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // Full inventory → nothing fits, nothing accumulates.
    var full_slots: [types.inventory_slot_count]?types.Item = undefined;
    for (&full_slots) |*s| s.* = .{ .amulet = .{ .spell_damage = 99 } };
    const item: types.Item = .{ .weapon = .{ .weapon_damage = 5, .weapon_type = .sword } };
    const items = try backing.allocator().dupe(types.Item, &.{item});
    const ground = try backing.allocator().dupe(types.GroundItems, &.{
        .{ .position = .{ .x = 0, .y = 0 }, .items = items },
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .inventory = .{ .slots = full_slots } }},
        &three_by_three,
    ));
    history.current_state.level.?.ground_items = ground;
    history.current_state.mission = .{ .uuid = "test-uuid" };
    pushAndRunSub(&history, .{ .pickup_items = .{ .entity_index = 0, .position = .{ .x = 0, .y = 0 } } });
    const got = history.current_state.mission.?.converted_materials_collected;
    try testing.expectEqual(@as(u32, 0), got.wood);
    try testing.expectEqual(@as(u32, 0), got.metal);
}

// ───────────────────────── stun ─────────────────────────

test "stun: no-op if attacker or defender is dead" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 0, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .stun = .{ .attacker_index = 0, .defender_index = 1, .stun_duration = 2 } });
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 1).stun_duration);
}

test "stun: applies the duration to the defender" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 } },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .stun = .{ .attacker_index = 0, .defender_index = 1, .stun_duration = 3 } });
    try testing.expectEqual(@as(u32, 3), levelEntity(&history, 1).stun_duration);
}

test "stun: takes the max, not the sum (no mega-stunlock)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .stun_duration = 2 },
        },
        &three_by_three,
    ));
    // A shorter new stun must not extend the ongoing one...
    pushAndRunSub(&history, .{ .stun = .{ .attacker_index = 0, .defender_index = 1, .stun_duration = 1 } });
    try testing.expectEqual(@as(u32, 2), levelEntity(&history, 1).stun_duration);
    // ...but a longer one replaces it.
    pushAndRunSub(&history, .{ .stun = .{ .attacker_index = 0, .defender_index = 1, .stun_duration = 3 } });
    try testing.expectEqual(@as(u32, 3), levelEntity(&history, 1).stun_duration);
}

test "stun: zero effective duration adds nothing" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .active_effects = &.{.{ .effect_id = .stone_form, .duration = 2, .additive_effect_modifiers = .{ .incoming_stun_duration = -5 } }} },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .stun = .{ .attacker_index = 0, .defender_index = 1, .stun_duration = 2 } });
    // 2 base - 5 (StoneForm incoming_stun) clamps to 0 → no stun applied.
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 1).stun_duration);
}

// ───────────────────────── knockback + collision ─────────────────────────

test "knockback: moves the defender away from the attacker" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 } },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .knockback = .{
        .attacker_index = 0,
        .defender_index = 1,
        .distance = 2,
        .knockback_damage = 0,
    } });
    // Pushed from (1,0) to (3,0) - but (3,0) isn't a tile, so stops at (2,0).
    try testing.expectEqual(@as(i32, 2), levelEntity(&history, 1).position.x);
    try testing.expectEqual(@as(i32, 0), levelEntity(&history, 1).position.y);
}

test "knockback: stops at a tile edge (no collision damage when knockback_damage=0)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 10, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 2, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .knockback = .{
        .attacker_index = 0,
        .defender_index = 1,
        .distance = 5,
        .knockback_damage = 3,
    } });
    // Defender at (2,0) pushed +x → (3,0) not a tile → collision at the edge.
    // Collision applies knockback_damage (3, no defense) → 10-3 = 7.
    try testing.expectEqual(@as(i32, 2), levelEntity(&history, 1).position.x);
    try testing.expectEqual(@as(u32, 7), levelEntity(&history, 1).current_health);
}

test "knockback: no-op if either is dead" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 0, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 } },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .knockback = .{
        .attacker_index = 0,
        .defender_index = 1,
        .distance = 2,
        .knockback_damage = 0,
    } });
    try testing.expectEqual(@as(i32, 1), levelEntity(&history, 1).position.x);
}

test "collision: applies damage and can kill" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 3, .max_health = 10 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .collision = .{
        .attacker_index = 0,
        .defender_index = 1,
        .damage = 5,
    } });
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 1).current_health);
}

test "collision: no-op if defender is dead" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 0, .max_health = 10 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .collision = .{
        .attacker_index = 0,
        .defender_index = 1,
        .damage = 5,
    } });
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 1).current_health);
}

// ───────────────────────── mission stat accumulators ─────────────────────────
// See DESIGN → Clones (clone system). damage_dealt/taken accumulate in the
// attack + collision handlers, player-only, gated on incoming_damage > 0.

test "attack: player damage_dealt accumulates on the mission" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 10, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10, .defense = 2 },
        },
        &three_by_three,
    ));
    history.current_state.mission = .{ .uuid = "test-uuid" };
    pushAndRunSub(&history, .{ .attack = .{ .attacker_index = 0, .defender_index = 1, .outgoing_damage = 7 } });
    // 7 - 2 defense = 5 dealt.
    try testing.expectEqual(@as(u32, 5), history.current_state.mission.?.damage_dealt);
    try testing.expectEqual(@as(u32, 0), history.current_state.mission.?.damage_taken);
}

test "attack: player damage_taken accumulates on the mission" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 10, .max_health = 10, .defense = 1 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &three_by_three,
    ));
    history.current_state.mission = .{ .uuid = "test-uuid" };
    pushAndRunSub(&history, .{ .attack = .{ .attacker_index = 1, .defender_index = 0, .outgoing_damage = 6 } });
    // 6 - 1 defense = 5 taken.
    try testing.expectEqual(@as(u32, 5), history.current_state.mission.?.damage_taken);
    try testing.expectEqual(@as(u32, 0), history.current_state.mission.?.damage_dealt);
}

test "attack: zero-damage hit does not accumulate" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 10, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10, .defense = 10 },
        },
        &three_by_three,
    ));
    history.current_state.mission = .{ .uuid = "test-uuid" };
    pushAndRunSub(&history, .{ .attack = .{ .attacker_index = 0, .defender_index = 1, .outgoing_damage = 5 } });
    // 5 - 10 defense = 0 incoming → no accumulation.
    try testing.expectEqual(@as(u32, 0), history.current_state.mission.?.damage_dealt);
}

test "collision: player damage_dealt accumulates on the mission" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 10, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10, .defense = 2 },
        },
        &three_by_three,
    ));
    history.current_state.mission = .{ .uuid = "test-uuid" };
    pushAndRunSub(&history, .{ .collision = .{ .attacker_index = 0, .defender_index = 1, .damage = 8 } });
    // 8 - 2 defense = 6 dealt.
    try testing.expectEqual(@as(u32, 6), history.current_state.mission.?.damage_dealt);
}

// ───────────────────────── retreat ─────────────────────────

test "retreat: moves the entity away from the target" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 1, .y = 1 } },
            .{ .team = 1, .position = .{ .x = 2, .y = 1 } },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .retreat = .{
        .entity_index = 0,
        .target_position = .{ .x = 2, .y = 1 },
        .distance = 2,
    } });
    // Away from (2,1) in -x: (1,1) -> (0,1) -> (-1,1) not a tile → stops at (0,1).
    try testing.expectEqual(@as(i32, 0), levelEntity(&history, 0).position.x);
    try testing.expectEqual(@as(i32, 1), levelEntity(&history, 0).position.y);
}

test "retreat: no-op if entity is dead" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 1, .y = 1 }, .current_health = 0, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 2, .y = 1 } },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .retreat = .{
        .entity_index = 0,
        .target_position = .{ .x = 2, .y = 1 },
        .distance = 2,
    } });
    try testing.expectEqual(@as(i32, 1), levelEntity(&history, 0).position.x);
}

// ───────────────────────── create_effect / end_effect ─────────────────────────

test "create_effect: adds a new effect to the receiver" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 } },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .create_effect = .{
        .caster_index = 0,
        .receiver_index = 1,
        .effect_id = .stone_form,
        .duration = 3,
    } });
    const receiver = levelEntity(&history, 1);
    try testing.expectEqual(@as(usize, 1), receiver.active_effects.len);
    try testing.expectEqual(EffectId.stone_form, receiver.active_effects[0].effect_id);
    try testing.expectEqual(@as(u32, 3), receiver.active_effects[0].duration);
}

test "create_effect: extends an existing effect's duration instead of duplicating" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const pre_effects = try backing.allocator().dupe(types.Effect, &.{
        .{ .effect_id = .stone_form, .duration = 2, .additive_effect_modifiers = .{ .incoming_stun_duration = -1 } },
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .active_effects = pre_effects },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .create_effect = .{
        .caster_index = 0,
        .receiver_index = 1,
        .effect_id = .stone_form,
        .duration = 3,
    } });
    const receiver = levelEntity(&history, 1);
    try testing.expectEqual(@as(usize, 1), receiver.active_effects.len);
    try testing.expectEqual(@as(u32, 5), receiver.active_effects[0].duration);
}

test "create_effect: no-op on a dead receiver" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 0, .max_health = 10 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .create_effect = .{
        .caster_index = 0,
        .receiver_index = 1,
        .effect_id = .stone_form,
        .duration = 3,
    } });
    try testing.expectEqual(@as(usize, 0), levelEntity(&history, 1).active_effects.len);
}

test "end_effect: removes the effect from active_effects" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const pre_effects = try backing.allocator().dupe(types.Effect, &.{
        .{ .effect_id = .stone_form, .duration = 2, .additive_effect_modifiers = .{} },
        .{ .effect_id = .reflect, .duration = 1, .additive_effect_modifiers = .{} },
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .active_effects = pre_effects }},
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .end_effect = .{ .entity_index = 0, .effect_id = .stone_form } });
    const entity = levelEntity(&history, 0);
    try testing.expectEqual(@as(usize, 1), entity.active_effects.len);
    try testing.expectEqual(EffectId.reflect, entity.active_effects[0].effect_id);
}

// ───────────────────────── gear side effects (level context) ─────────────────────────

test "equip boots during player_move refreshes move highlights" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 1, .y = 1 }, .speed = 1 }},
        &three_by_three,
    ));
    history.current_state.level.?.turn_phase = .player_move;
    // Equip boots (speed_bonus 1) → effective speed 2 → reachable tiles grow.
    levelEntity(&history, 0).inventory.slots[0] = .{ .boots = .{ .speed_bonus = 1 } };
    event_push.pushEvents(&history.current_state, &.{.{ .player_event = .{ .equip_item = .{
        .inventory_slot_index = 0,
        .gear_slot = .boots,
    } } }}, history.current_arena.allocator());
    runToIdle(&history);
    // Speed 2 from the center of a 3x3 grid reaches all 8 tiles around (1,1).
    try testing.expectEqual(@as(usize, 8), history.current_state.level.?.highlighted_tiles.len);
}

test "equip weapon cancels a prepared skill" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 1, .y = 1 } }},
        &three_by_three,
    ));
    history.current_state.level.?.prepared_skill = .slice;
    levelEntity(&history, 0).inventory.slots[0] = .{ .weapon = .{ .weapon_type = .sword, .weapon_damage = 1 } };
    event_push.pushEvents(&history.current_state, &.{.{ .player_event = .{ .equip_item = .{
        .inventory_slot_index = 0,
        .gear_slot = .main_hand,
    } } }}, history.current_arena.allocator());
    runToIdle(&history);
    try testing.expectEqual(@as(?SkillId, null), history.current_state.level.?.prepared_skill);
}

test "adrenaline_surge: resets on-bar cooldowns then attacks once per reset" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            // Attacker: amulet-driven spell damage 4.
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .amulet = .{ .spell_damage = 4 } },
            // Defender: main-hand sword (slice / spinblade / flash_strike -
            // flash_strike is the SWAP-AVAILABLE third, not on the exposed
            // bar) + blink in utility slot 1.
            .{
                .team = 1,
                .position = .{ .x = 1, .y = 0 },
                .current_health = 20,
                .max_health = 20,
                .main_hand_weapon = .{ .weapon_type = .sword },
                .equipped_utility_skills = .{ .blink, null, null, null, null },
            },
        },
        &three_by_three,
    ));
    // slice + flash_strike (swap-available) + blink ticking; spinblade off.
    levelEntity(&history, 1).skill_cooldowns.set(.slice, 2);
    levelEntity(&history, 1).skill_cooldowns.set(.flash_strike, 3);
    levelEntity(&history, 1).skill_cooldowns.set(.blink, 1);
    // An OFF-BAR preserved cooldown (swap-inheritance ticking) - must NOT
    // count or reset.
    levelEntity(&history, 1).skill_cooldowns.set(.skewer, 4);

    pushAndRunSub(&history, .{ .adrenaline_surge = .{ .attacker_index = 0, .defender_index = 1 } });

    // 3 resets: slice, flash_strike, blink → zeroed. Skewer untouched.
    const defender = levelEntity(&history, 1);
    try testing.expectEqual(@as(u32, 0), defender.skill_cooldowns.get(.slice));
    try testing.expectEqual(@as(u32, 0), defender.skill_cooldowns.get(.flash_strike));
    try testing.expectEqual(@as(u32, 0), defender.skill_cooldowns.get(.blink));
    try testing.expectEqual(@as(u32, 4), defender.skill_cooldowns.get(.skewer));
    // 3 attacks of 4 spell damage: 20 - 12 = 8.
    try testing.expectEqual(@as(u32, 8), defender.current_health);
}

test "adrenaline_surge: resets land even when the attacks kill" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .amulet = .{ .spell_damage = 9 } },
            .{
                .team = 1,
                .position = .{ .x = 1, .y = 0 },
                .current_health = 10,
                .max_health = 20,
                .main_hand_weapon = .{ .weapon_type = .sword },
            },
        },
        &three_by_three,
    ));
    levelEntity(&history, 1).skill_cooldowns.set(.slice, 2);
    levelEntity(&history, 1).skill_cooldowns.set(.spinblade, 1);

    pushAndRunSub(&history, .{ .adrenaline_surge = .{ .attacker_index = 0, .defender_index = 1 } });

    // Two 9-damage attacks kill (10 -> 0) - but the resets drained FIRST,
    // so the cooldowns are zeroed regardless.
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 1).current_health);
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 1).skill_cooldowns.get(.slice));
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 1).skill_cooldowns.get(.spinblade));
}

test "adrenaline_surge: nothing ticking is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .amulet = .{ .spell_damage = 9 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &three_by_three,
    ));
    pushAndRunSub(&history, .{ .adrenaline_surge = .{ .attacker_index = 0, .defender_index = 1 } });
    try testing.expectEqual(@as(u32, 10), levelEntity(&history, 1).current_health);
}

test "accelerating waits: one shared counter per skill use, reset on use_skill" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 1, .y = 1 }, .main_hand_weapon = .{ .weapon_type = .sword, .weapon_damage = 1 } },
            .{ .team = 1, .position = .{ .x = 2, .y = 1 }, .current_health = 10, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 0, .y = 1 }, .current_health = 10, .max_health = 10 },
        },
        &three_by_three,
    ));

    // Spinblade hits both adjacent hostiles: attack → wait → damage → wait →
    // attack → wait → damage - ONE shared acceleration sequence (the
    // inter-event gaps and the hit-landing gaps are the same wait kind,
    // sharing the counter). 3 waits elapsed.
    pushAndRunLevel(&history, .{ .use_skill = .{
        .caster_index = 0,
        .skill_id = .spinblade,
        .target = null,
    } });
    try testing.expectEqual(@as(u32, 3), history.current_state.wait_acceleration);

    // A follow-up single-hit skill RESETS the chain: exactly one wait
    // (without the reset it would inherit the decayed position - 4).
    pushAndRunLevel(&history, .{ .use_skill = .{
        .caster_index = 0,
        .skill_id = .slice,
        .target = .{ .x = 2, .y = 1 },
    } });
    try testing.expectEqual(@as(u32, 1), history.current_state.wait_acceleration);
}
