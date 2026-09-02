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
