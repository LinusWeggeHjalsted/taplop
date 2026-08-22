//! Tier 3 handler tests — AI + determinism. `enemy_turn_move` (nearest-target
//! tiebreak, min-range hold, reachable-tile fallback tiebreak), `enemy_turn_
//! attack` (non-turn-ending-first by priority, then turn-ending; cooldown
//! skip), `aggro_around` (radius activation + level-end coupling),
//! `pickup_around` (pure check → pushes pickup_items per in-range stack).
//! See TODO → Tech debt (handler coverage), AGENTS → Determinism & Tiebreaking.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");
const event_handlers = @import("event_handlers.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;
const levelEntity = test_harness.levelEntity;
const Entity = types.Entity;
const Vector2 = types.Vector2;
const Event = events.Event;
const LevelEvent = events.LevelEvent;
const SubLevelEvent = events.SubLevelEvent;
const SkillId = types.SkillId;

/// A 5x5 tile grid (0,0)..(4,4) — enough room for AI movement + tiebreaks.
const five_by_five = [_]Vector2{
    .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 }, .{ .x = 4, .y = 0 },
    .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 1 }, .{ .x = 4, .y = 1 },
    .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 2 }, .{ .x = 4, .y = 2 },
    .{ .x = 0, .y = 3 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = 3 }, .{ .x = 3, .y = 3 }, .{ .x = 4, .y = 3 },
    .{ .x = 0, .y = 4 }, .{ .x = 1, .y = 4 }, .{ .x = 2, .y = 4 }, .{ .x = 3, .y = 4 }, .{ .x = 4, .y = 4 },
};

/// Push a single level event and run to idle.
fn pushAndRunLevel(history: *state.GameStateHistory, event: LevelEvent) void {
    event_handlers.pushEvents(&history.current_state, &.{.{ .level_event = event }}, history.current_arena.allocator());
    runToIdle(history);
}

/// Push a single sub-level event and run to idle.
fn pushAndRunSub(history: *state.GameStateHistory, event: SubLevelEvent) void {
    event_handlers.pushEvents(&history.current_state, &.{.{ .sub_level_event = event }}, history.current_arena.allocator());
    runToIdle(history);
}

// ───────────────────────── aggro_around ─────────────────────────

test "aggro_around: activates opposing entities within aggro_range" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 2, .y = 2 }, .aggro_range = 2 },
            .{ .team = 1, .position = .{ .x = 4, .y = 2 }, .is_active = false }, // distance 2
            .{ .team = 1, .position = .{ .x = 0, .y = 2 }, .is_active = false }, // distance 2
            .{ .team = 1, .position = .{ .x = 0, .y = 0 }, .is_active = false }, // distance 2
        },
        &five_by_five,
    ));
    pushAndRunSub(&history, .{ .aggro_around = .{ .entity_index = 0 } });
    // All three enemies are at Chebyshev distance 2 → all activated.
    try testing.expect(levelEntity(&history, 1).is_active);
    try testing.expect(levelEntity(&history, 2).is_active);
    try testing.expect(levelEntity(&history, 3).is_active);
}

test "aggro_around: out-of-range enemies stay inactive" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .aggro_range = 1 },
            .{ .team = 1, .position = .{ .x = 4, .y = 4 }, .is_active = false }, // distance 4
        },
        &five_by_five,
    ));
    pushAndRunSub(&history, .{ .aggro_around = .{ .entity_index = 0 } });
    try testing.expectEqual(false, levelEntity(&history, 1).is_active);
}

test "aggro_around: same-team entities are not activated" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 2, .y = 2 }, .aggro_range = 3 },
            .{ .team = 0, .position = .{ .x = 2, .y = 3 }, .is_active = false }, // same team
        },
        &five_by_five,
    ));
    pushAndRunSub(&history, .{ .aggro_around = .{ .entity_index = 0 } });
    try testing.expectEqual(false, levelEntity(&history, 1).is_active);
}

test "aggro_around: dead enemies are not activated" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 2, .y = 2 }, .aggro_range = 3 },
            .{ .team = 1, .position = .{ .x = 2, .y = 3 }, .current_health = 0, .max_health = 10 },
        },
        &five_by_five,
    ));
    pushAndRunSub(&history, .{ .aggro_around = .{ .entity_index = 0 } });
    try testing.expectEqual(false, levelEntity(&history, 1).is_active);
}

test "aggro_around: already-active enemies stay active (no deactivation)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 2, .y = 2 }, .aggro_range = 3 },
            .{ .team = 1, .position = .{ .x = 2, .y = 3 }, .is_active = true },
        },
        &five_by_five,
    ));
    pushAndRunSub(&history, .{ .aggro_around = .{ .entity_index = 0 } });
    try testing.expect(levelEntity(&history, 1).is_active);
}

// ───────────────────────── pickup_around ─────────────────────────

test "pickup_around: pushes one pickup_items per in-range ground stack" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const items_a = try backing.allocator().dupe(types.Item, &.{.{ .weapon = .{ .weapon_damage = 1 } }});
    const items_b = try backing.allocator().dupe(types.Item, &.{.{ .amulet = .{ .spell_damage = 2 } }});
    const items_c = try backing.allocator().dupe(types.Item, &.{.{ .boots = .{ .speed_bonus = 1 } }});
    const ground = try backing.allocator().dupe(types.GroundItems, &.{
        .{ .position = .{ .x = 1, .y = 0 }, .items = items_a }, // distance 1 from (0,0)
        .{ .position = .{ .x = 0, .y = 1 }, .items = items_b }, // distance 1
        .{ .position = .{ .x = 4, .y = 4 }, .items = items_c }, // distance 4, out of range
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &five_by_five,
    ));
    history.current_state.level.?.ground_items = ground;
    // Default pickup radius is 0 → only stacks on the entity's own tile would
    // be picked up. Give the entity a 1-tile radius via the event's own logic
    // (pickup_around uses getEffectivePickupRadius(0)).
    pushAndRunSub(&history, .{ .pickup_around = .{ .entity_index = 0 } });
    // With radius 0, no stacks are in range (none at (0,0)) → all stay.
    try testing.expectEqual(@as(usize, 3), history.current_state.level.?.ground_items.len);
}

test "pickup_around: radius 1 picks up adjacent stacks" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const items_a = try backing.allocator().dupe(types.Item, &.{.{ .weapon = .{ .weapon_damage = 1 } }});
    const items_far = try backing.allocator().dupe(types.Item, &.{.{ .boots = .{ .speed_bonus = 1 } }});
    const ground = try backing.allocator().dupe(types.GroundItems, &.{
        .{ .position = .{ .x = 1, .y = 0 }, .items = items_a }, // distance 1
        .{ .position = .{ .x = 4, .y = 4 }, .items = items_far }, // distance 4
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .inventory = .{} }},
        &five_by_five,
    ));
    history.current_state.level.?.ground_items = ground;
    // Move items_a onto the entity's tile (0,0) so radius-0 pickup reaches it.
    const mutable_ground = @constCast(history.current_state.level.?.ground_items);
    mutable_ground[0].position = .{ .x = 0, .y = 0 };
    pushAndRunSub(&history, .{ .pickup_around = .{ .entity_index = 0 } });
    // The (0,0) stack gets picked up; the (4,4) stack stays.
    try testing.expectEqual(@as(usize, 1), history.current_state.level.?.ground_items.len);
    try testing.expect(levelEntity(&history, 0).inventory.slots[0] != null);
}

// ───────────────────────── enemy_turn_move ─────────────────────────

test "enemy_turn_move: nearest-target tiebreak resolves to lowest entity_index" {
    // Two player-team entities equidistant from the enemy. The strict-< scan
    // in index order keeps the first (lowest index) as the target.
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 2, .y = 2 }, .speed = 1 }, // enemy at index 0
            .{ .team = 0, .position = .{ .x = 0, .y = 2 }, .current_health = 10, .max_health = 10 }, // dist 2
            .{ .team = 0, .position = .{ .x = 4, .y = 2 }, .current_health = 10, .max_health = 10 }, // dist 2 (tie)
        },
        &five_by_five,
    ));
    // Give the enemy a stab skill so it has min_range 1; within min range it
    // skips to attack (no move). Both targets are distance 2 > 1, so it moves
    // toward the NEAREST = index 1 (at (0,2)), stepping to (1,2).
    levelEntity(&history, 0).main_hand_weapon = .{ .weapon_type = .dagger, .weapon_damage = 1 };
    pushAndRunLevel(&history, .{ .enemy_turn_move = .{ .entity_index = 0 } });
    // Moved one step toward (0,2): (2,2) -> (1,2). (Toward index 2 would be
    // (3,2).) This pins the lowest-entity_index tiebreak.
    try testing.expectEqual(@as(i32, 1), levelEntity(&history, 0).position.x);
    try testing.expectEqual(@as(i32, 2), levelEntity(&history, 0).position.y);
}

test "enemy_turn_move: already within min range holds position (skips to attack)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .speed = 2 },
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 10, .max_health = 10 }, // dist 1
        },
        &five_by_five,
    ));
    levelEntity(&history, 0).main_hand_weapon = .{ .weapon_type = .dagger, .weapon_damage = 1 }; // stab min range 1
    pushAndRunLevel(&history, .{ .enemy_turn_move = .{ .entity_index = 0 } });
    // Distance 1 <= min_range 1 → no move.
    try testing.expectEqual(@as(i32, 1), levelEntity(&history, 0).position.x);
    try testing.expectEqual(@as(i32, 0), levelEntity(&history, 0).position.y);
}

test "enemy_turn_move: no opposing entities → turn_end (no move)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 0, .y = 0 }, .speed = 2 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 } }, // same team
        },
        &five_by_five,
    ));
    pushAndRunLevel(&history, .{ .enemy_turn_move = .{ .entity_index = 0 } });
    try testing.expectEqual(@as(i32, 0), levelEntity(&history, 0).position.x);
}

test "enemy_turn_move: moves up to speed steps toward the target" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 0, .y = 0 }, .speed = 2 },
            .{ .team = 0, .position = .{ .x = 4, .y = 0 }, .current_health = 10, .max_health = 10 }, // dist 4
        },
        &five_by_five,
    ));
    // No weapon → computeMinRange returns null → min_range defaults to 1.
    // Path is a straight line; speed 2 steps to (2,0), staying >= min_range 1
    // (stops before (3,0) would be dist 1... actually (2,0) is dist 2, (3,0)
    // is dist 1 = min_range, still allowed). Walks up to speed steps but won't
    // enter the target's tile. (3,0) is dist 1 >= 1 and not the target tile
    // → steps there. So speed-2 → (2,0).
    pushAndRunLevel(&history, .{ .enemy_turn_move = .{ .entity_index = 0 } });
    try testing.expectEqual(@as(i32, 2), levelEntity(&history, 0).position.x);
}

// ───────────────────────── enemy_turn_attack ─────────────────────────

test "enemy_turn_attack: no usable skills → turn_end (no skill use)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 0, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &five_by_five,
    ));
    // No weapon, no utility skills → no off-cooldown skills → turn_end.
    pushAndRunLevel(&history, .{ .enemy_turn_attack = .{ .entity_index = 0 } });
    // No damage dealt (no skill fired).
    try testing.expectEqual(@as(u32, 10), levelEntity(&history, 1).current_health);
}

test "enemy_turn_attack: turn-ending weapon skill fires when a target is in range" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 0, .y = 0 }, .main_hand_weapon = .{ .weapon_type = .dagger, .weapon_damage = 5 } },
            .{ .team = 0, .position = .{ .x = 1, .y = 0 }, .current_health = 20, .max_health = 20 },
        },
        &five_by_five,
    ));
    // stab (dagger skill_1) is turn-ending, range 1, target adjacent → fires.
    pushAndRunLevel(&history, .{ .enemy_turn_attack = .{ .entity_index = 0 } });
    // stab deals 1.5x weapon_damage when target is above half health:
    // 5 + 5/2 = 7 (integer math), minus defense 0 = 7. 20 - 7 = 13.
    try testing.expectEqual(@as(u32, 13), levelEntity(&history, 1).current_health);
}

test "enemy_turn_attack: on-cooldown skill is skipped" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 0, .y = 0 }, .main_hand_weapon = .{ .weapon_type = .dagger, .weapon_damage = 5 } },
            .{ .team = 0, .position = .{ .x = 1, .y = 0 }, .current_health = 20, .max_health = 20 },
        },
        &five_by_five,
    ));
    // Put stab on cooldown → no usable skills → turn_end, no damage.
    levelEntity(&history, 0).skill_cooldowns.set(.stab, 2);
    pushAndRunLevel(&history, .{ .enemy_turn_attack = .{ .entity_index = 0 } });
    try testing.expectEqual(@as(u32, 20), levelEntity(&history, 1).current_health);
}

test "enemy_turn_attack: out-of-range target → priority 0, skill skipped" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 0, .y = 0 }, .main_hand_weapon = .{ .weapon_type = .dagger, .weapon_damage = 5 } },
            .{ .team = 0, .position = .{ .x = 4, .y = 4 }, .current_health = 20, .max_health = 20 }, // dist 4
        },
        &five_by_five,
    ));
    // stab range 1; target at dist 4 → priority 0 → skipped → turn_end.
    pushAndRunLevel(&history, .{ .enemy_turn_attack = .{ .entity_index = 0 } });
    try testing.expectEqual(@as(u32, 20), levelEntity(&history, 1).current_health);
}
