//! Contract tests for skill implementations — the pure `Skill` interface
//! functions (selectTarget / priority / getValidTargets / useSkill) tested
//! directly against harness-built level states, independent of the handler
//! drain. New skills add their tests here. Target-selection conventions
//! live in skills/helpers.zig + DESIGN → Determinism & Tiebreaking.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const helpers = @import("skills/helpers.zig");
const test_harness = @import("test_harness.zig");
const shoot_skill = @import("skills/shoot.zig");
const powerful_shot_skill = @import("skills/powerful_shot.zig");
const bash_skill = @import("skills/bash.zig");

const Vector2 = types.Vector2;

/// Set one entity's cooldown entry on a const GameState's level (handlers
/// mutate through @constCast the same way — see test_harness.levelEntity).
fn setCooldown(
    game_state: anytype,
    entity_index: usize,
    skill_id: types.SkillId,
    cooldown: u32,
) void {
    @constCast(game_state.level.?.entities)[entity_index].skill_cooldowns.set(skill_id, cooldown);
}

test "weakestTarget: picks the lowest-health hostile over the nearest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Caster (team 1) at the origin; two hostiles — the wounded one is
    // FARTHER, the healthy one adjacent. Focus-fire prefers the wounded.
    const caster = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 0 } };
    const wounded = types.Entity{ .team = 0, .position = .{ .x = 3, .y = 0 }, .current_health = 5 };
    const healthy = types.Entity{ .team = 0, .position = .{ .x = 1, .y = 0 }, .current_health = 15 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, wounded, healthy },
        &.{},
    );

    const targets: []const Vector2 = &.{ wounded.position, healthy.position };
    const picked = helpers.weakestTarget(0, targets, game_state);
    try testing.expectEqual(wounded.position, picked.?);
}

test "weakestTarget: health tie breaks by distance to the caster" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 0 } };
    const far = types.Entity{ .team = 0, .position = .{ .x = 3, .y = 0 }, .current_health = 10 };
    const near = types.Entity{ .team = 0, .position = .{ .x = 1, .y = 0 }, .current_health = 10 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, far, near },
        &.{},
    );

    // List order reversed so "first in list" can't masquerade as the answer.
    const targets: []const Vector2 = &.{ far.position, near.position };
    const picked = helpers.weakestTarget(0, targets, game_state);
    try testing.expectEqual(near.position, picked.?);
}

test "weakestTarget: health + distance tie breaks by entity index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Both hostiles at Chebyshev distance 1 with equal health; index 1
    // (the first entity in the list) is listed LAST to prove list order
    // does not decide.
    const caster = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 0 } };
    const first = types.Entity{ .team = 0, .position = .{ .x = 1, .y = 0 }, .current_health = 10 };
    const second = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 1 }, .current_health = 10 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, first, second },
        &.{},
    );

    const targets: []const Vector2 = &.{ second.position, first.position };
    const picked = helpers.weakestTarget(0, targets, game_state);
    try testing.expectEqual(first.position, picked.?);
}

test "weakestTarget: null on null or empty targets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{caster},
        &.{},
    );

    try testing.expectEqual(@as(?Vector2, null), helpers.weakestTarget(0, null, game_state));
    try testing.expectEqual(@as(?Vector2, null), helpers.weakestTarget(0, &.{}, game_state));
}

test "nearestTarget: still picks the nearest regardless of health (Swap's read)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 0 } };
    const wounded_far = types.Entity{ .team = 0, .position = .{ .x = 3, .y = 0 }, .current_health = 5 };
    const healthy_near = types.Entity{ .team = 0, .position = .{ .x = 1, .y = 0 }, .current_health = 15 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, wounded_far, healthy_near },
        &.{},
    );

    const targets: []const Vector2 = &.{ wounded_far.position, healthy_near.position };
    const picked = helpers.nearestTarget(0, targets, game_state);
    try testing.expectEqual(healthy_near.position, picked.?);
}

test "shoot: useSkill emits attack + retreat with main-hand damage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .main_hand_weapon = .{ .weapon_damage = 7 },
    };
    const defender = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, defender },
        &.{},
    );

    const result = shoot_skill.skill.useSkill(0, defender.position, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 2), result.len);

    // ownedEvents returns LIFO order — the attack (listed first in
    // execution order) sits LAST in the slice, retreat first.
    const retreat = result[0].sub_level_event.retreat;
    try testing.expectEqual(@as(u32, 0), retreat.entity_index);
    try testing.expectEqual(defender.position, retreat.target_position);
    try testing.expectEqual(@as(u32, 1), retreat.distance);

    const attack = result[1].sub_level_event.attack;
    try testing.expectEqual(@as(u32, 0), attack.attacker_index);
    try testing.expectEqual(@as(u32, 1), attack.defender_index);
    try testing.expectEqual(@as(u32, 7), attack.outgoing_damage);
}

test "shoot: useSkill no-ops when no hostile stands on the target tile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .main_hand_weapon = .{ .weapon_damage = 7 },
    };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{caster},
        &.{},
    );

    const result = shoot_skill.skill.useSkill(0, .{ .x = 2, .y = 0 }, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "shoot: priority is 2 with a hostile in range, 0 otherwise or on cooldown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const in_range = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const out_of_range = types.Entity{ .team = 1, .position = .{ .x = 4, .y = 0 } };

    // No hostile at all.
    {
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});
        try testing.expectEqual(@as(u32, 0), shoot_skill.skill.priority(0, game_state));
    }
    // Hostile beyond effective range 3.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, out_of_range },
            &.{},
        );
        try testing.expectEqual(@as(u32, 0), shoot_skill.skill.priority(0, game_state));
    }
    // Hostile exactly at range 3.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, in_range },
            &.{},
        );
        try testing.expectEqual(@as(u32, 2), shoot_skill.skill.priority(0, game_state));
    }
    // On cooldown (a swap can leave one on a no-cooldown skill).
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, in_range },
            &.{},
        );
        setCooldown(game_state, 0, .shoot, 1);
        try testing.expectEqual(@as(u32, 0), shoot_skill.skill.priority(0, game_state));
    }
}

test "shoot: getValidTargets returns only living hostiles within range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const in_range = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const out_of_range = types.Entity{ .team = 1, .position = .{ .x = 4, .y = 0 } };
    const same_team = types.Entity{ .team = 0, .position = .{ .x = 1, .y = 0 } };
    const dead = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 1 }, .current_health = 0 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, in_range, out_of_range, same_team, dead },
        &.{},
    );

    const targets = shoot_skill.skill.getValidTargets(0, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 1), targets.?.len);
    try testing.expectEqual(in_range.position, targets.?[0]);
}

test "knockbackWouldCollide: edge, occupant, clear path, dead occupant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const defender = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };

    // Push runs off the tile set (level edge).
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, defender },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } },
        );
        try testing.expect(helpers.knockbackWouldCollide(0, 1, 1, game_state));
    }
    // A living entity on the push path.
    {
        const obstacle = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, defender, obstacle },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } },
        );
        try testing.expect(helpers.knockbackWouldCollide(0, 1, 1, game_state));
    }
    // Clear path over existing empty tiles.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, defender },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        );
        try testing.expect(!helpers.knockbackWouldCollide(0, 1, 2, game_state));
    }
    // A dead occupant is not an obstacle.
    {
        const corpse = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 }, .current_health = 0 };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, defender, corpse },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } },
        );
        try testing.expect(!helpers.knockbackWouldCollide(0, 1, 1, game_state));
    }
}

test "knockbackTarget: a colliding target beats a weaker open-field target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Caster (0,0). The wounded target at (1,0) has a clear push path; the
    // healthy target at (3,0) would be pushed off the tile set. Collision
    // outranks focus-fire.
    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const wounded_open = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 5 };
    const healthy_walled = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 }, .current_health = 15 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, wounded_open, healthy_walled },
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
    );

    const targets: []const Vector2 = &.{ wounded_open.position, healthy_walled.position };
    const picked = helpers.knockbackTarget(0, targets, 1, game_state);
    try testing.expectEqual(healthy_walled.position, picked.?);
}

test "knockbackTarget: with no collisions, falls back to the weakest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const wounded = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 5 };
    const healthy = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 }, .current_health = 15 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, wounded, healthy },
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 }, .{ .x = 4, .y = 0 } },
    );

    const targets: []const Vector2 = &.{ wounded.position, healthy.position };
    const picked = helpers.knockbackTarget(0, targets, 1, game_state);
    try testing.expectEqual(wounded.position, picked.?);
}

test "bash: priority is 3 when any in-range push collides, 2 otherwise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const adjacent = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };

    // Open field: adjacent target, clear push path.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, adjacent },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } },
        );
        try testing.expectEqual(@as(u32, 2), bash_skill.skill.priority(0, game_state));
    }
    // Two adjacent targets — the FIRST in scan order is open, the second is
    // walled. Any-collide (not nearest-only) bumps to 3.
    {
        const walled = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, adjacent, walled },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 1 } },
        );
        try testing.expectEqual(@as(u32, 3), bash_skill.skill.priority(0, game_state));
    }
    // On cooldown.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, adjacent },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } },
        );
        setCooldown(game_state, 0, .bash, 1);
        try testing.expectEqual(@as(u32, 0), bash_skill.skill.priority(0, game_state));
    }
}

test "powerful shot: useSkill emits attack + knockback with half collision damage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .main_hand_weapon = .{ .weapon_damage = 7 },
    };
    const defender = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, defender },
        &.{},
    );

    const result = powerful_shot_skill.skill.useSkill(0, defender.position, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 2), result.len);

    // ownedEvents returns LIFO order — attack (first in execution order)
    // sits LAST in the slice.
    const knockback = result[0].sub_level_event.knockback;
    try testing.expectEqual(@as(u32, 0), knockback.attacker_index);
    try testing.expectEqual(@as(u32, 1), knockback.defender_index);
    try testing.expectEqual(@as(u32, 2), knockback.distance);
    try testing.expectEqual(@as(u32, 3), knockback.knockback_damage); // 7 / 2

    const attack = result[1].sub_level_event.attack;
    try testing.expectEqual(@as(u32, 7), attack.outgoing_damage);
    try testing.expectEqual(@as(u32, 1), attack.defender_index);
}

test "powerful shot: priority is 3 when any in-range push collides, 2 otherwise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const near_open = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const far_walled = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };

    // Only the near target, open path (tiles extend past its push).
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, near_open },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        );
        try testing.expectEqual(@as(u32, 2), powerful_shot_skill.skill.priority(0, game_state));
    }
    // Near target open, far target walled (its 2-step push runs off the
    // tile set) — both in range 3, any-collide bumps to 3.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, near_open, far_walled },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        );
        try testing.expectEqual(@as(u32, 3), powerful_shot_skill.skill.priority(0, game_state));
    }
    // On cooldown.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, near_open },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        );
        setCooldown(game_state, 0, .powerful_shot, 1);
        try testing.expectEqual(@as(u32, 0), powerful_shot_skill.skill.priority(0, game_state));
    }
}
