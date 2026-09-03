//! Tier 3 handler tests — AI + determinism. `enemy_turn_move` (nearest-target
//! tiebreak, min-range hold, reachable-tile fallback tiebreak), `enemy_turn_
//! attack` (non-turn-ending-first by priority, then turn-ending; cooldown
//! skip), `aggro_check` (self-centric radius activation), `pickup_around` (pure check → pushes pickup_items per in-range stack).
//! See TODO → Tech debt (handler coverage), DESIGN → Determinism & Tiebreaking.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");
const event_handlers = @import("event_handlers.zig");
const event_push = @import("event_push.zig");
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
    event_push.pushEvents(&history.current_state, &.{.{ .level_event = event }}, history.current_arena.allocator());
    runToIdle(history);
}

/// Push a single sub-level event and run to idle.
fn pushAndRunSub(history: *state.GameStateHistory, event: SubLevelEvent) void {
    event_push.pushEvents(&history.current_state, &.{.{ .sub_level_event = event }}, history.current_arena.allocator());
    runToIdle(history);
}

// ───────────────────────── aggro_check ─────────────────────────

test "aggro_check: activates inactive entities that see an opponent in their own aggro_range" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            // Player at center; aggro_range 3 → sees both enemies.
            .{ .team = 0, .position = .{ .x = 2, .y = 2 }, .aggro_range = 3 },
            // Enemy at distance 2 from player; aggro_range 6 → sees player.
            .{ .team = 1, .position = .{ .x = 4, .y = 2 }, .aggro_range = 6, .is_active = false },
            // Enemy at distance 2 from player; aggro_range 1 → does NOT see player.
            .{ .team = 1, .position = .{ .x = 0, .y = 2 }, .aggro_range = 1, .is_active = false },
        },
        &five_by_five,
    ));
    pushAndRunSub(&history, .{ .aggro_check = .{} });
    // Player (already active by convention) and enemy 1 (sees player) active.
    // Enemy 2 (aggro_range 1, player at distance 2) stays inactive.
    try testing.expect(levelEntity(&history, 1).is_active);
    try testing.expectEqual(false, levelEntity(&history, 2).is_active);
}

test "aggro_check: out-of-range opponents keep entities inactive" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .aggro_range = 1 },
            .{ .team = 1, .position = .{ .x = 4, .y = 4 }, .aggro_range = 1, .is_active = false },
        },
        &five_by_five,
    ));
    pushAndRunSub(&history, .{ .aggro_check = .{} });
    try testing.expectEqual(false, levelEntity(&history, 1).is_active);
}

test "aggro_check: same-team entities do not aggro each other" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 2, .y = 2 }, .aggro_range = 3 },
            .{ .team = 0, .position = .{ .x = 2, .y = 3 }, .aggro_range = 3, .is_active = false },
        },
        &five_by_five,
    ));
    pushAndRunSub(&history, .{ .aggro_check = .{} });
    try testing.expectEqual(false, levelEntity(&history, 1).is_active);
}

test "aggro_check: dead entities are not activated" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 2, .y = 2 }, .aggro_range = 3 },
            .{ .team = 1, .position = .{ .x = 2, .y = 3 }, .aggro_range = 3, .current_health = 0, .max_health = 10 },
        },
        &five_by_five,
    ));
    pushAndRunSub(&history, .{ .aggro_check = .{} });
    try testing.expectEqual(false, levelEntity(&history, 1).is_active);
}

test "aggro_check: already-active entities stay active (no deactivation)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 2, .y = 2 }, .aggro_range = 3 },
            .{ .team = 1, .position = .{ .x = 2, .y = 3 }, .aggro_range = 3, .is_active = true },
        },
        &five_by_five,
    ));
    pushAndRunSub(&history, .{ .aggro_check = .{} });
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

// ────────────── movement modes (skills/movement.zig) ──────────────

/// Corridor grid: only column x = 1 — forced one-axis movement so
/// stand-off distances are unambiguous.
const corridor = [_]Vector2{
    .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 },
    .{ .x = 1, .y = 3 }, .{ .x = 1, .y = 4 }, .{ .x = 1, .y = 5 },
    .{ .x = 1, .y = 6 }, .{ .x = 1, .y = 7 }, .{ .x = 1, .y = 8 },
};

test "enemy_turn_move: ready point-blank skill cluster-seeks" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // Dual staff: spark + meteor exposed, blitz (radius-1 point-blank) as the
    // off hand's third skill — blitz ready → cluster mode. Three targets
    // clustered around (0,2)-(0,4): tile (1,3) is within radius 1 of all
    // three, reachable in 3 steps from (4,3).
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{
                .team = 1,
                .position = .{ .x = 4, .y = 3 },
                .speed = 3,
                .main_hand_weapon = .{ .weapon_type = .staff },
                .off_hand_weapon = .{ .weapon_type = .staff },
            },
            .{ .team = 0, .position = .{ .x = 0, .y = 2 }, .current_health = 10, .max_health = 10 },
            .{ .team = 0, .position = .{ .x = 0, .y = 3 }, .current_health = 10, .max_health = 10 },
            .{ .team = 0, .position = .{ .x = 0, .y = 4 }, .current_health = 10, .max_health = 10 },
        },
        &five_by_five,
    ));
    pushAndRunLevel(&history, .{ .enemy_turn_move = .{ .entity_index = 0 } });
    try testing.expectEqual(@as(i32, 1), levelEntity(&history, 0).position.x);
    try testing.expectEqual(@as(i32, 3), levelEntity(&history, 0).position.y);
}

test "enemy_turn_move: point-blank skill on cooldown kites instead" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // Same dual staff, blitz on cooldown: no point-blank skill ready, the
    // kit's min range is 3 (spark) → keep_range. Corridor: the entity at
    // (1,4) with the hostile adjacent at (1,3) retreats to the standoff —
    // (1,6) is the farthest act-capable tile (distance 3).
    const game_state = test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{
                .team = 1,
                .position = .{ .x = 1, .y = 4 },
                .speed = 2,
                .main_hand_weapon = .{ .weapon_type = .staff },
                .off_hand_weapon = .{ .weapon_type = .staff },
            },
            .{ .team = 0, .position = .{ .x = 1, .y = 3 }, .current_health = 10, .max_health = 10 },
        },
        &corridor,
    );
    @constCast(game_state.level.?.entities)[0].skill_cooldowns.set(.blitz, 5);
    var history = harness.newHistory(game_state);
    pushAndRunLevel(&history, .{ .enemy_turn_move = .{ .entity_index = 0 } });
    try testing.expectEqual(@as(i32, 1), levelEntity(&history, 0).position.x);
    try testing.expectEqual(@as(i32, 6), levelEntity(&history, 0).position.y);
}

test "enemy_turn_move: ranged kit holds the standoff when closing in" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // Main-hand staff only (spark + meteor, min range 3): keep_range. The
    // entity starts at the standoff (distance 3) — no reachable tile is
    // farther while staying act-capable, so it stands and attacks.
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 1, .y = 6 }, .speed = 2, .main_hand_weapon = .{ .weapon_type = .staff } },
            .{ .team = 0, .position = .{ .x = 1, .y = 3 }, .current_health = 10, .max_health = 10 },
        },
        &corridor,
    ));
    pushAndRunLevel(&history, .{ .enemy_turn_move = .{ .entity_index = 0 } });
    try testing.expectEqual(@as(i32, 6), levelEntity(&history, 0).position.y);
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
    // Put stab AND vampiric_strike on cooldown (vampiric is now always
    // offered — rating 1 at full health, the lifesteal bonus only applies
    // below half) → no usable cast → turn_end, no damage.
    levelEntity(&history, 0).skill_cooldowns.set(.stab, 2);
    levelEntity(&history, 0).skill_cooldowns.set(.vampiric_strike, 2);
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
