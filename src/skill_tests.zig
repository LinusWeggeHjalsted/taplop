//! Contract tests for skill implementations — the pure `Skill` interface
//! functions (selectTarget / priority / getValidTargets / useSkill) tested
//! directly against harness-built level states, independent of the handler
//! drain. New skills add their tests here. Target-selection conventions
//! live in skill_helpers.zig + DESIGN → Determinism & Tiebreaking.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const skill_mod = @import("skill.zig");
const state = @import("state.zig");
const helpers = @import("skill_helpers.zig");
const test_harness = @import("test_harness.zig");
const shoot_skill = @import("skills/shoot.zig");
const powerful_shot_skill = @import("skills/powerful_shot.zig");
const bash_skill = @import("skills/bash.zig");
const head_shot_skill = @import("skills/head_shot.zig");
const heal_skill = @import("skills/heal.zig");
const focus_skill = @import("skills/focus.zig");
const stone_form_skill = @import("skills/stone_form.zig");
const ai_select = @import("ai_select.zig");
const cleave_skill = @import("skills/cleave.zig");
const meteor_skill = @import("skills/meteor.zig");
const threat_mod = @import("ai_threat.zig");
const absorb_skill = @import("skills/absorb.zig");
const reflect_skill = @import("skills/reflect.zig");
const absorb_effect = @import("effects/absorb.zig");
const spinblade_skill = @import("skills/spinblade.zig");
const flash_strike_skill = @import("skills/flash_strike.zig");
const drain_skill = @import("skills/drain.zig");
const howl_skill = @import("skills/howl.zig");
const stab_skill = @import("skills/stab.zig");
const worldfire_skill = @import("skills/worldfire.zig");
const shockwave_skill = @import("skills/shockwave.zig");
const slam_skill = @import("skills/slam.zig");
const charged_bolt_skill = @import("skills/charged_bolt.zig");
const blitz_skill = @import("skills/blitz.zig");
const chain_lightning_skill = @import("skills/chain_lightning.zig");
const adrenaline_surge_skill = @import("skills/adrenaline_surge.zig");
const burst_skill = @import("skills/burst.zig");
const meditate_skill = @import("skills/meditate.zig");
const accelerate_skill = @import("skills/accelerate.zig");
const that_which_reaches_skill = @import("skills/that_which_reaches.zig");
const that_which_lingers_skill = @import("skills/that_which_lingers.zig");
const bull_form_skill = @import("skills/bull_form.zig");
const that_which_rushes_skill = @import("skills/that_which_rushes.zig");
const that_which_explodes_skill = @import("skills/that_which_explodes.zig");
const promise_of_death_skill = @import("skills/promise_of_death.zig");
const throw_skill = @import("skills/throw.zig");
const impale_skill = @import("skills/impale.zig");
const skewer_skill = @import("skills/skewer.zig");

const that_which_explodes_effect = @import("effects/that_which_explodes.zig");
const promise_of_death_effect = @import("effects/promise_of_death.zig");

const Vector2 = types.Vector2;

/// A skill's options with a FRESH evaluation frame per call (a test block
/// often mutates state between calls — a shared frame would serve stale
/// memoized options; within one real pass the state is frozen, but a test
/// block isn't).
fn freshOptions(
    skill_id: types.SkillId,
    caster_index: u32,
    game_state: state.GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    var frame = skill_mod.EvalFrame.empty();
    return ai_select.optionsFor(&frame, skill_id, caster_index, game_state, weapon_type_definitions, allocator);
}

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
    try testing.expectEqual(@as(usize, 3), result.len);

    // ownedEvents returns LIFO order — attack, wait, retreat in execution
    // order → retreat, wait, attack in the slice (the wait is the pacing
    // gap ownedEvents interleaves between the recipe's events).
    const retreat = result[0].sub_level_event.retreat;
    try testing.expectEqual(@as(u32, 0), retreat.entity_index);
    try testing.expectEqual(defender.position, retreat.target_position);
    try testing.expectEqual(@as(u32, 1), retreat.distance);

    try testing.expect(result[1].meta_event == .accelerating_wait);

    const attack = result[2].sub_level_event.attack;
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
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.shoot, 0, game_state, undefined, arena.allocator()).len);
    }
    // Hostile beyond effective range 3.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, out_of_range },
            &.{},
        );
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.shoot, 0, game_state, undefined, arena.allocator()).len);
    }
    // Hostile exactly at range 3.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, in_range },
            &.{},
        );
        const options = freshOptions(.shoot, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
    // On cooldown (a swap can leave one on a no-cooldown skill).
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, in_range },
            &.{},
        );
        setCooldown(game_state, 0, .shoot, 1);
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.shoot, 0, game_state, undefined, arena.allocator()).len);
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

test "bash: option is 3 with the colliding pick, 2 on an open path" {
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
        const options = freshOptions(.bash, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
    // Two adjacent targets — the FIRST in scan order is open, the second is
    // walled. The option carries BOTH the 3 rating and the walled target
    // (one decision — the old split could rate off one target while
    // selection attacked another).
    {
        const walled = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, adjacent, walled },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 1 } },
        );
        const options = freshOptions(.bash, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
        try testing.expectEqual(walled.position, options[0].target.?);
    }
    // On cooldown.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, adjacent },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } },
        );
        setCooldown(game_state, 0, .bash, 1);
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.bash, 0, game_state, undefined, arena.allocator()).len);
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
    try testing.expectEqual(@as(usize, 3), result.len);

    // ownedEvents returns LIFO order — attack, wait, knockback in execution
    // order → knockback, wait, attack in the slice.
    const knockback = result[0].sub_level_event.knockback;
    try testing.expectEqual(@as(u32, 0), knockback.attacker_index);
    try testing.expectEqual(@as(u32, 1), knockback.defender_index);
    try testing.expectEqual(@as(u32, 2), knockback.distance);
    try testing.expectEqual(@as(u32, 3), knockback.knockback_damage); // 7 / 2

    try testing.expect(result[1].meta_event == .accelerating_wait);

    const attack = result[2].sub_level_event.attack;
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
        const options = freshOptions(.powerful_shot, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
    // Near target open, far target walled (its 2-step push runs off the
    // tile set) — both in range 3, any-collide bumps to 3.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, near_open, far_walled },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        );
        const options = freshOptions(.powerful_shot, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
    // On cooldown.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, near_open },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        );
        setCooldown(game_state, 0, .powerful_shot, 1);
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.powerful_shot, 0, game_state, undefined, arena.allocator()).len);
    }
}

test "head shot: useSkill emits attack + stun with off-hand damage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .off_hand_weapon = .{ .weapon_damage = 9 },
    };
    const defender = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, defender },
        &.{},
    );

    const result = head_shot_skill.skill.useSkill(0, defender.position, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 3), result.len);

    // LIFO order — attack, wait, stun in execution order → stun, wait,
    // attack in the slice.
    const stun = result[0].sub_level_event.stun;
    try testing.expectEqual(@as(u32, 0), stun.attacker_index);
    try testing.expectEqual(@as(u32, 1), stun.defender_index);
    try testing.expectEqual(@as(u32, 1), stun.stun_duration);

    try testing.expect(result[1].meta_event == .accelerating_wait);

    const attack = result[2].sub_level_event.attack;
    try testing.expectEqual(@as(u32, 9), attack.outgoing_damage);
    try testing.expectEqual(@as(u32, 1), attack.defender_index);
}

test "head shot: priority is 3 with a hostile in range, 0 otherwise or on cooldown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const in_range = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const out_of_range = types.Entity{ .team = 1, .position = .{ .x = 4, .y = 0 } };

    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, out_of_range },
            &.{},
        );
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.head_shot, 0, game_state, undefined, arena.allocator()).len);
    }
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, in_range },
            &.{},
        );
        const options = freshOptions(.head_shot, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
        setCooldown(game_state, 0, .head_shot, 1);
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.head_shot, 0, game_state, undefined, arena.allocator()).len);
    }
}

test "idol heal: useSkill emits a self-heal for a fifth of max health" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Awkward value on purpose: 23 / 5 must truncate to 4 (integer math).
    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 }, .max_health = 23, .current_health = 9 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{caster},
        &.{},
    );

    try testing.expectEqual(@as(?[]const Vector2, null), heal_skill.skill.getValidTargets(0, game_state, arena.allocator()));

    const result = heal_skill.skill.useSkill(0, null, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 1), result.len);
    const heal = result[0].sub_level_event.heal;
    try testing.expectEqual(@as(u32, 0), heal.entity_index);
    try testing.expectEqual(@as(u32, 4), heal.amount);
}

test "idol heal: priority is 1 only below half health" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Full health → 0 (the no-op gate).
    {
        const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 }, .max_health = 20, .current_health = 20 };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.heal, 0, game_state, undefined, arena.allocator()).len);
    }
    // Exactly half → 0 (at/above half).
    {
        const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 }, .max_health = 20, .current_health = 10 };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.heal, 0, game_state, undefined, arena.allocator()).len);
    }
    // Below half → 1.
    {
        const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 }, .max_health = 20, .current_health = 9 };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});
        const options = freshOptions(.heal, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
        // Cooldown overrides (a swap can leave one on a no-cooldown skill).
        setCooldown(game_state, 0, .heal, 1);
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.heal, 0, game_state, undefined, arena.allocator()).len);
    }
}

test "focus: options rate by ticking weapon-skill count, cantrips excluded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // A sword-carrier (slots: slice, spinblade, flash_strike) with one
    // weapon skill + one cantrip ticking: rate = 1 — the cantrip doesn't
    // count (the reset handler resolves slots 1-3 only).
    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .main_hand_weapon = .{ .weapon_type = .sword },
        .equipped_utility_skills = .{ .blink, null, null, null, null },
    };
    const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});
    setCooldown(game_state, 0, .slice, 2);
    setCooldown(game_state, 0, .blink, 3);
    {
        const options = freshOptions(.focus, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
    // Two weapon skills ticking → rate = 2.
    setCooldown(game_state, 0, .spinblade, 2);
    {
        const options = freshOptions(.focus, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
    // Only the cantrip ticking → nothing to reset, no option.
    setCooldown(game_state, 0, .slice, 0);
    setCooldown(game_state, 0, .spinblade, 0);
    try testing.expectEqual(@as(usize, 0),
        freshOptions(.focus, 0, game_state, definitions, arena.allocator()).len);
}

test "stone form: rates above the planned stun cast; HoT fallback without one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // An axe-carrier BELOW half health with an unstunned hostile in
    // cleave range: chop rates 1 (its above-half bonus is gone) and
    // cleave rates 2, so the planned ending cast is cleave — stone form
    // rates one above it, firing first in the chain (the +1 rule). Note
    // at FULL health chop ties cleave at 2 and slot order plans the
    // chop — no stun planned, so stone form waits; that's the plan-
    // dependent rule working as settled.
    const axe_caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .max_health = 20,
        .current_health = 9,
        .main_hand_weapon = .{ .weapon_type = .axe },
        .equipped_utility_skills = .{ .stone_form, null, null, null, null },
    };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ axe_caster, types.Entity{
            .team = 1,
            .position = .{ .x = 1, .y = 0 },
            .max_health = 20,
            .current_health = 20,
        } },
        &.{},
    );

    // The shared selection plans cleave at 2 (unstunned target).
    var frame = skill_mod.EvalFrame.empty();
    const plan = ai_select.bestCasts(0, game_state, definitions, arena.allocator(), &frame).ending;
    try testing.expectEqual(types.SkillId.cleave, plan.?.skill_id);
    try testing.expectEqual(@as(u32, 2), plan.?.priority);

    {
        const options = freshOptions(.stone_form, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 3), options[0].priority);
    }

    // Hostile far out of range: no planned ending cast, no stun cantrip
    // ticking — the HoT fallback applies, and it offers 1 (below full).
    @constCast(game_state.level.?.entities)[1].position = .{ .x = 30, .y = 30 };
    frame = skill_mod.EvalFrame.empty();
    try testing.expect(
        ai_select.bestCasts(0, game_state, definitions, arena.allocator(), &frame).ending == null,
    );
    {
        const options = freshOptions(.stone_form, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }

    // Full health with no beneficiary: nothing at all.
    @constCast(game_state.level.?.entities)[0].current_health = 20;
    try testing.expectEqual(@as(usize, 0),
        freshOptions(.stone_form, 0, game_state, definitions, arena.allocator()).len);
    @constCast(game_state.level.?.entities)[0].current_health = 9;

    // A sword-carrier (chop plans, but chops don't stun) below full
    // health: no beneficiary, so the HoT fallback offers 1.
    @constCast(game_state.level.?.entities)[0].main_hand_weapon = .{ .weapon_type = .sword };
    @constCast(game_state.level.?.entities)[0].current_health = 9;
    {
        const options = freshOptions(.stone_form, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
}

test "that which lingers: rates above a live duration beneficiary, nothing alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // Lingers + reaches equipped (both off cooldown): reaches carries a
    // skill_duration and offers its cast, so lingers rates one above it —
    // firing FIRST in the chain so reaches' cast gains the +1 duration.
    // Lingers itself is cut from its own scan by the frame's in-progress
    // guard (it would otherwise count its own skill_duration).
    // Howl (radius 16) gives reaches a live range/radius beneficiary:
    // the fresh (inactive) hostile counts, so reaches rates howl's cast
    // + 1 = 2, and lingers rates reaches' cast + 1 = 3 — the chain order
    // is reaches -> howl... with lingers firing first of all so both
    // gain the +1 duration.
    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .max_health = 20,
        .current_health = 20,
        .equipped_utility_skills = .{ .that_which_lingers, .that_which_reaches, .howl, null, null },
    };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .max_health = 20, .current_health = 20 } },
        &.{},
    );
    {
        const options = freshOptions(.that_which_reaches, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
    {
        const options = freshOptions(
            .that_which_lingers,
            0,
            game_state,
            definitions,
            arena.allocator(),
        );
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 3), options[0].priority);
    }

    // Lingers alone: extends nothing on its own (its recast is outside its
    // 2-turn window) — no beneficiary, no cast (no fallback).
    const lone_caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .max_health = 20,
        .current_health = 20,
        .equipped_utility_skills = .{ .that_which_lingers, null, null, null, null },
    };
    const lone_state = test_harness.levelStateWithEntities(arena.allocator(), &.{lone_caster}, &.{});
    try testing.expectEqual(@as(usize, 0),
        freshOptions(.that_which_lingers, 0, lone_state, definitions, arena.allocator()).len);
}

test "that which reaches: the sim differential enables an out-of-range attack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // A sword-carrier (main hand: slice range 1, spinblade radius 1 —
    // slot 3 is the off-hand) with a hostile at distance 2: both attacks
    // are out of range — no plan at all. With the effect virtually
    // applied, slice (range 2) reaches the hostile: the sim's ending
    // plan differs, so reaches rates the would-be slice + 1 = 2 and
    // fires; the re-evaluation then really casts it.
    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .max_health = 20,
        .current_health = 20,
        .main_hand_weapon = .{ .weapon_type = .sword },
        .equipped_utility_skills = .{ .that_which_reaches, null, null, null, null },
    };
    const tiles = [_]types.Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
        .{ .x = 3, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 5, .y = 0 },
    };
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 }, .max_health = 20, .current_health = 20 } },
            &tiles,
        );
        const options = freshOptions(.that_which_reaches, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }

    // Distance 3: even with +1 nothing reaches the hostile — no plan in
    // either world, no differential, no cast.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 }, .max_health = 20, .current_health = 20 } },
            &tiles,
        );
        try testing.expectEqual(@as(usize, 0),
            freshOptions(.that_which_reaches, 0, game_state, definitions, arena.allocator()).len);
    }
}

test "that which reaches: the sim differential enables a cantrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // No weapon at all — burst (radius 1) is the whole bar, with a hostile
    // at distance 2: burst has nothing in radius. With +1 radius the
    // hostile counts — the sim's non-ending plan differs, so reaches
    // rates the would-be burst + 1 = 2.
    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .max_health = 20,
        .current_health = 20,
        .equipped_utility_skills = .{ .that_which_reaches, .burst, null, null, null },
    };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 }, .max_health = 20, .current_health = 20 } },
        &.{},
    );
    const options = freshOptions(.that_which_reaches, 0, game_state, definitions, arena.allocator());
    try testing.expectEqual(@as(usize, 1), options.len);
    try testing.expectEqual(@as(u32, 2), options[0].priority);
}

test "that which reaches: an in-range plan is the base-value beneficiary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // Hostile adjacent: the planned ending cast is slice (1, range 1) —
    // the base-value rule counts it, reaches rates 1 + 1 = 2 and fires
    // first (the +1 range applies to the slice). The sim finds no
    // improvement worth more (same target, same rating).
    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .max_health = 20,
        .current_health = 20,
        .main_hand_weapon = .{ .weapon_type = .sword },
        .equipped_utility_skills = .{ .that_which_reaches, null, null, null, null },
    };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .max_health = 20, .current_health = 20 } },
        &.{.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }},
    );
    const options = freshOptions(.that_which_reaches, 0, game_state, definitions, arena.allocator());
    try testing.expectEqual(@as(usize, 1), options.len);
    try testing.expectEqual(@as(u32, 2), options[0].priority);
}

test "that which rushes: rates above cooldown-bearing casts, never standalone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // A cantrip beneficiary: howl (cd 10) counts the fresh hostile, so
    // rushes rates howl's cast + 1 = 2 — firing first, so howl's newly-set
    // cooldown comes out one less.
    {
        const caster = types.Entity{
            .team = 0,
            .position = .{ .x = 0, .y = 0 },
            .max_health = 20,
            .current_health = 20,
            .equipped_utility_skills = .{ .that_which_rushes, .howl, null, null, null },
        };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .max_health = 20, .current_health = 20 } },
            &.{},
        );
        const options = freshOptions(.that_which_rushes, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }

    // A planned ending beneficiary: two adjacent hostiles make spinblade
    // (cd 2) the plan at 2, so rushes rates 2 + 1 = 3.
    {
        const caster = types.Entity{
            .team = 0,
            .position = .{ .x = 0, .y = 0 },
            .max_health = 20,
            .current_health = 20,
            .main_hand_weapon = .{ .weapon_type = .sword },
            .equipped_utility_skills = .{ .that_which_rushes, null, null, null, null },
        };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{
                caster,
                types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .max_health = 20, .current_health = 20 },
                types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 }, .max_health = 20, .current_health = 20 },
            },
            &.{.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }},
        );
        const options = freshOptions(.that_which_rushes, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 3), options[0].priority);
    }

    // Nothing cooldown-bearing fires (slice, the plan, has NO cooldown) —
    // the speed rider alone never justifies the cast: no fallback.
    {
        const caster = types.Entity{
            .team = 0,
            .position = .{ .x = 0, .y = 0 },
            .max_health = 20,
            .current_health = 20,
            .main_hand_weapon = .{ .weapon_type = .sword },
            .equipped_utility_skills = .{ .that_which_rushes, null, null, null, null },
        };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .max_health = 20, .current_health = 20 } },
            &.{.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }},
        );
        try testing.expectEqual(@as(usize, 0),
            freshOptions(.that_which_rushes, 0, game_state, definitions, arena.allocator()).len);
    }
}

test "that which bull form: the sim differential flips a short push into a collision" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // A shield-carrier (bash push 1, slam push 2) with the target at
    // distance 1 and a blocker at distance 4: nothing collides at base
    // distances (the plan is bash @ 1 — a distance skill, so the
    // base-value rule already rates bull form 2). With +10 distance
    // virtually applied, bash's push reaches the blocker — the sim's
    // plan rates 2 — so bull form rates 2 + 1 = 3 and fires first.
    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .max_health = 20,
        .current_health = 20,
        .main_hand_weapon = .{ .weapon_type = .shield },
        .equipped_utility_skills = .{ .bull_form, null, null, null, null },
    };
    const tiles = [_]types.Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
        .{ .x = 3, .y = 0 }, .{ .x = 4, .y = 0 },
    };
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{
                caster,
                types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .max_health = 20, .current_health = 20 },
                types.Entity{ .team = 1, .position = .{ .x = 4, .y = 0 }, .max_health = 20, .current_health = 20 },
            },
            &tiles,
        );
        const options = freshOptions(.bull_form, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 3), options[0].priority);
    }

    // A sword-carrier (no distance skills at all) with an adjacent
    // hostile: nothing on the bar pushes, no differential — pure
    // modifiers with nothing to enhance, no cast.
    {
        const sword_caster = types.Entity{
            .team = 0,
            .position = .{ .x = 0, .y = 0 },
            .max_health = 20,
            .current_health = 20,
            .main_hand_weapon = .{ .weapon_type = .sword },
            .equipped_utility_skills = .{ .bull_form, null, null, null, null },
        };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ sword_caster, types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .max_health = 20, .current_health = 20 } },
            &.{.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }},
        );
        try testing.expectEqual(@as(usize, 0),
            freshOptions(.bull_form, 0, game_state, definitions, arena.allocator()).len);
    }
}

test "stunTarget: an unstunned target beats a weaker stunned one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The wounded target is already stunned (a new 1-turn stun can't lower
    // or usefully extend its 2) — the healthy unstunned one is the better
    // stun victim despite focus-fire saying otherwise.
    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const wounded_stunned = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 5, .stun_duration = 2 };
    const healthy_unstunned = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 }, .current_health = 15 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, wounded_stunned, healthy_unstunned },
        &.{},
    );

    const targets: []const Vector2 = &.{ wounded_stunned.position, healthy_unstunned.position };
    const picked = helpers.stunTarget(0, targets, game_state);
    try testing.expectEqual(healthy_unstunned.position, picked.?);
}

test "stunTarget: all stunned falls back to the weakest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const wounded = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 }, .current_health = 5, .stun_duration = 1 };
    const healthy = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 15, .stun_duration = 1 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, wounded, healthy },
        &.{},
    );

    const targets: []const Vector2 = &.{ wounded.position, healthy.position };
    const picked = helpers.stunTarget(0, targets, game_state);
    try testing.expectEqual(wounded.position, picked.?);
}

test "cleave: priority is 2 with an unstunned target, 1 when all are stunned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const adjacent = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };

    {
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, adjacent }, &.{});
        const options = freshOptions(.cleave, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
    {
        const stunned = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .stun_duration = 2 };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, stunned }, &.{});
        const options = freshOptions(.cleave, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
}

test "head shot: priority drops to 2 when the only target is already stunned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const stunned = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 }, .stun_duration = 2 };
    const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, stunned }, &.{});
    const options = freshOptions(.head_shot, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
}

test "meteor: options pick the tile with the most hostiles within radius" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };

    // No hostiles reachable (range 3 + radius 1 can't reach the far
    // corner) → no option.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, types.Entity{ .team = 1, .position = .{ .x = 8, .y = 8 } } },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 8, .y = 8 } },
        );
        try testing.expectEqual(@as(usize, 0),
            freshOptions(.meteor, 0, game_state, undefined, arena.allocator()).len);
    }
    // A cluster straddling tile (3,0): the hostile ON the tile is a direct
    // hit (distance 0), its diagonal neighbor at (4,1) is at distance 1 →
    // the best center is the OCCUPIED tile itself — no off-tile center
    // reaches both (Chebyshev makes (2,0)→(4,1) distance 2), and Flash
    // Strike wouldn't even consider (3,0) because it only teleports to
    // empty tiles → count 2 → priority 2.
    {
        const on_tile = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
        const diagonal_neighbor = types.Entity{ .team = 1, .position = .{ .x = 4, .y = 1 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, on_tile, diagonal_neighbor },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 }, .{ .x = 4, .y = 1 } },
        );
        const options = freshOptions(.meteor, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
        try testing.expectEqual(Vector2{ .x = 3, .y = 0 }, options[0].target.?);
    }
    // The caster's own tile is a legal center: two adjacent hostiles make
    // (0,0) the max-count tile → a point-blank cast at the caster's feet.
    {
        const adjacent_a = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
        const adjacent_b = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, adjacent_a, adjacent_b },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 } },
        );
        const options = freshOptions(.meteor, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
        try testing.expectEqual(caster.position, options[0].target.?);
    }
    // A lone reachable hostile → a single-target cast rates 1 (a plain hit —
    // it ties the basic attack and loses to slot order, the cluster-saving
    // posture); on cooldown → no option.
    {
        const target = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, target },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        );
        const options = freshOptions(.meteor, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
        setCooldown(game_state, 0, .meteor, 1);
        try testing.expectEqual(@as(usize, 0),
            freshOptions(.meteor, 0, game_state, undefined, arena.allocator()).len);
    }
}

test "meteor: useSkill attacks each hostile within radius of the target tile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .main_hand_weapon = .{ .weapon_damage = 6 },
    };
    const on_tile = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const neighbor = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 1 } };
    const beyond = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 2 } };
    const same_team = types.Entity{ .team = 0, .position = .{ .x = 4, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, on_tile, neighbor, beyond, same_team },
        &.{},
    );

    const result = meteor_skill.skill.useSkill(0, .{ .x = 3, .y = 0 }, game_state, arena.allocator());
    // On-tile (distance 0) + neighbor (distance 1) hit at main-hand damage;
    // beyond (distance 2) + the ally not. With the pacing wait the slice is
    // attack, wait, attack.
    try testing.expectEqual(@as(usize, 3), result.len);
    for (result) |event| {
        if (event == .meta_event) continue;
        const attack = event.sub_level_event.attack;
        try testing.expectEqual(@as(u32, 0), attack.attacker_index);
        try testing.expectEqual(@as(u32, 6), attack.outgoing_damage);
        try testing.expect(attack.defender_index == 1 or attack.defender_index == 2);
    }
    // Meteor strikes the CENTER first, then the spiral — and useSkill
    // returns the REVERSED array (ownedEvents; the last element executes
    // first), so the center target (`on_tile`, index 1) is the LAST element.
    try testing.expectEqual(@as(u32, 1), result[2].sub_level_event.attack.defender_index);
}

test "computeMaxDamageRange: max reach over off-cooldown damaging skills" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // Main-hand sword: slice (range 1) + spinblade (radius 1) → 1.
    {
        const caster = types.Entity{
            .team = 0,
            .position = .{ .x = 0, .y = 0 },
            .main_hand_weapon = .{ .weapon_type = .sword },
        };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});
        try testing.expectEqual(
            @as(?u32, 1),
            threat_mod.computeMaxDamageRange(game_state.level.?.entities[0], definitions),
        );
    }
    // Off-hand sword joins: flash_strike (range 3) enters the bar → 3;
    // with flash_strike on cooldown the reach falls back to 1.
    {
        const caster = types.Entity{
            .team = 0,
            .position = .{ .x = 0, .y = 0 },
            .main_hand_weapon = .{ .weapon_type = .sword },
            .off_hand_weapon = .{ .weapon_type = .sword },
        };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});
        try testing.expectEqual(
            @as(?u32, 3),
            threat_mod.computeMaxDamageRange(game_state.level.?.entities[0], definitions),
        );
        setCooldown(game_state, 0, .flash_strike, 1);
        try testing.expectEqual(
            @as(?u32, 1),
            threat_mod.computeMaxDamageRange(game_state.level.?.entities[0], definitions),
        );
    }
    // No weapons, empty utility bar → null (cannot deal damage at all).
    {
        const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});
        try testing.expectEqual(
            @as(?u32, null),
            threat_mod.computeMaxDamageRange(game_state.level.?.entities[0], definitions),
        );
    }
}

test "hostileCanAttackNextTurn: reach, stun, aggro, and damaging filters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const sword_enemy_at = struct {
        fn make(position: Vector2) types.Entity {
            return .{
                .team = 1,
                .position = position,
                .is_active = true,
                .speed = 1,
                .main_hand_weapon = .{ .weapon_type = .sword },
            };
        }
    }.make;

    // Sword enemy (max damage reach 1, speed 1) at distance 2 → threat;
    // at distance 3 → out of reach.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, sword_enemy_at(.{ .x = 2, .y = 0 }) },
            &.{},
        );
        try testing.expect(threat_mod.hostileCanAttackNextTurn(0, game_state, definitions));
    }
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, sword_enemy_at(.{ .x = 3, .y = 0 }) },
            &.{},
        );
        try testing.expect(!threat_mod.hostileCanAttackNextTurn(0, game_state, definitions));
    }
    // Same distance-3 enemy with an off-hand sword too (flash_strike, reach
    // 3) → speed 1 + reach 3 = 4 ≥ 3 → threat.
    {
        const enemy = types.Entity{
            .team = 1,
            .position = .{ .x = 3, .y = 0 },
            .is_active = true,
            .speed = 1,
            .main_hand_weapon = .{ .weapon_type = .sword },
            .off_hand_weapon = .{ .weapon_type = .sword },
        };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, enemy }, &.{});
        try testing.expect(threat_mod.hostileCanAttackNextTurn(0, game_state, definitions));
    }
    // Stunned (skips its next turn) → not a threat.
    {
        const enemy = types.Entity{
            .team = 1,
            .position = .{ .x = 2, .y = 0 },
            .is_active = true,
            .speed = 1,
            .stun_duration = 1,
            .main_hand_weapon = .{ .weapon_type = .sword },
        };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, enemy }, &.{});
        try testing.expect(!threat_mod.hostileCanAttackNextTurn(0, game_state, definitions));
    }
    // Inactive (unaggroed) → not a threat.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, sword_enemy_at(.{ .x = 2, .y = 0 }) },
            &.{},
        );
        @constCast(game_state.level.?.entities)[1].is_active = false;
        try testing.expect(!threat_mod.hostileCanAttackNextTurn(0, game_state, definitions));
    }
    // No damaging skills at all → not a threat (distance 3 > speed 1).
    {
        const enemy = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 }, .is_active = true, .speed = 1 };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, enemy }, &.{});
        try testing.expect(!threat_mod.hostileCanAttackNextTurn(0, game_state, definitions));
    }
}

test "absorb: useSkill applies the absorb effect to the caster for one round" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});

    const result = absorb_skill.skill.useSkill(0, null, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 1), result.len);
    const create = result[0].sub_level_event.create_effect;
    try testing.expectEqual(@as(u32, 0), create.caster_index);
    try testing.expectEqual(@as(u32, 0), create.receiver_index);
    try testing.expectEqual(types.EffectId.absorb, create.effect_id);
    try testing.expectEqual(@as(u32, 1), create.duration);
}

test "absorb: priority tiers by threat and health" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    const caster_full = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 }, .max_health = 20, .current_health = 20 };
    const caster_wounded = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 }, .max_health = 20, .current_health = 9 };
    const sword_enemy_at = struct {
        fn make(position: Vector2) types.Entity {
            return .{
                .team = 1,
                .position = position,
                .is_active = true,
                .speed = 1,
                .main_hand_weapon = .{ .weapon_type = .sword },
            };
        }
    }.make;

    // Threatened (adjacent sword enemy) at full health → 2.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster_full, sword_enemy_at(.{ .x = 1, .y = 0 }) },
            &.{},
        );
        const options = freshOptions(.absorb, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
    // Threatened + below half → 4 (the panic tier).
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster_wounded, sword_enemy_at(.{ .x = 1, .y = 0 }) },
            &.{},
        );
        const options = freshOptions(.absorb, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 4), options[0].priority);
    }
    // Unthreatened (enemy far out of reach) → 0, even below half.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster_wounded, sword_enemy_at(.{ .x = 9, .y = 9 }) },
            &.{},
        );
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.absorb, 0, game_state, definitions, arena.allocator()).len);
    }
    // Threatened but on cooldown → 0.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster_wounded, sword_enemy_at(.{ .x = 1, .y = 0 }) },
            &.{},
        );
        setCooldown(game_state, 0, .absorb, 1);
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.absorb, 0, game_state, definitions, arena.allocator()).len);
    }
}

test "absorb effect: intercepts damage into a heal of the same amount" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});

    const intercepted = absorb_effect.effect.interceptIncomingDamage(0, 1, 7, game_state, arena.allocator());
    try testing.expectEqual(@as(u32, 0), intercepted.damage);
    try testing.expectEqual(@as(usize, 1), intercepted.events.len);
    const heal = intercepted.events[0].sub_level_event.heal;
    try testing.expectEqual(@as(u32, 0), heal.entity_index);
    try testing.expectEqual(@as(u32, 7), heal.amount);

    const zero = absorb_effect.effect.interceptIncomingDamage(0, 1, 0, game_state, arena.allocator());
    try testing.expectEqual(@as(u32, 0), zero.damage);
    try testing.expectEqual(@as(usize, 0), zero.events.len);
}

test "reflect: priority tiers by threat and health" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    const caster_full = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 }, .max_health = 20, .current_health = 20 };
    const caster_wounded = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 }, .max_health = 20, .current_health = 9 };
    const sword_enemy_at = struct {
        fn make(position: Vector2) types.Entity {
            return .{
                .team = 1,
                .position = position,
                .is_active = true,
                .speed = 1,
                .main_hand_weapon = .{ .weapon_type = .sword },
            };
        }
    }.make;

    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster_full, sword_enemy_at(.{ .x = 1, .y = 0 }) },
            &.{},
        );
        const options = freshOptions(.reflect, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster_wounded, sword_enemy_at(.{ .x = 1, .y = 0 }) },
            &.{},
        );
        const options = freshOptions(.reflect, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 4), options[0].priority);
    }
    // The old heuristic fired on ANY hostile within 2 tiles, aggro or not —
    // an idle unaggroed enemy at distance 2 must not bait the cooldown.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster_wounded, sword_enemy_at(.{ .x = 2, .y = 0 }) },
            &.{},
        );
        @constCast(game_state.level.?.entities)[1].is_active = false;
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.reflect, 0, game_state, definitions, arena.allocator()).len);
    }
}

test "aoePriority: value units (base + count - 1)" {
    try testing.expectEqual(@as(u32, 0), helpers.aoePriority(0, 1));
    try testing.expectEqual(@as(u32, 1), helpers.aoePriority(1, 1));
    try testing.expectEqual(@as(u32, 2), helpers.aoePriority(2, 1));
    try testing.expectEqual(@as(u32, 5), helpers.aoePriority(5, 1));
    try testing.expectEqual(@as(u32, 2), helpers.aoePriority(1, 2)); // global rider
    try testing.expectEqual(@as(u32, 4), helpers.aoePriority(3, 2));
}

test "hostileCountWithinRadius: counts living hostiles around a center" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const in_radius_a = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const in_radius_b = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
    const out_of_radius = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 2 } };
    const same_team = types.Entity{ .team = 0, .position = .{ .x = 1, .y = 1 } };
    const dead = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 1 }, .current_health = 0 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, in_radius_a, in_radius_b, out_of_radius, same_team, dead },
        &.{},
    );

    try testing.expectEqual(@as(u32, 2), helpers.hostileCountWithinRadius(0, game_state, .{ .x = 0, .y = 0 }, 1));
    // Centered at (1,1): all three hostiles sit within radius 1
    // ((2,2) included — Chebyshev diagonals count as 1).
    try testing.expectEqual(@as(u32, 3), helpers.hostileCountWithinRadius(0, game_state, .{ .x = 1, .y = 1 }, 1));
    try testing.expectEqual(@as(u32, 1), helpers.hostileCountWithinRadius(0, game_state, .{ .x = 2, .y = 2 }, 1));
}

test "spinblade: priority bumps to 4 with two hostiles in radius" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const adjacent = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };

    {
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, adjacent }, &.{});
        const options = freshOptions(.spinblade, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
    {
        const second = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, adjacent, second }, &.{});
        const options = freshOptions(.spinblade, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
}

test "flash strike: priority counts hits over the best landing tile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const pair_a = types.Entity{ .team = 1, .position = .{ .x = 4, .y = 0 } };
    const pair_b = types.Entity{ .team = 1, .position = .{ .x = 4, .y = 1 } };

    // No hostiles anywhere near → no reachable hit → 0 (the old flat-3
    // rating flashed into empty space).
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{caster},
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } },
        );
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.flash_strike, 0, game_state, undefined, arena.allocator()).len);
    }
    // A landing tile at (3,0) is within range 3 and radius 1 of BOTH
    // hostiles → the max count is 2 → 4, and the option's target IS that
    // tile — the cast lands where the rating was earned.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, pair_a, pair_b },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 0 } },
        );
        const options = freshOptions(.flash_strike, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 3), options[0].priority);
        try testing.expectEqual(Vector2{ .x = 3, .y = 0 }, options[0].target.?);
    }
}

test "drain: useSkill attacks each hostile in radius with lifesteal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .off_hand_weapon = .{ .weapon_damage = 6 },
    };
    const adjacent_a = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const adjacent_b = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
    const far = types.Entity{ .team = 1, .position = .{ .x = 5, .y = 5 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, adjacent_a, adjacent_b, far },
        &.{},
    );

    const result = drain_skill.skill.useSkill(0, null, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 3), result.len); // 2 attacks + the pacing wait
    // ownedEvents reverses execution order; both attacks carry the
    // off-hand damage and lifesteal on (the pacing wait skips the checks).
    for (result) |event| {
        if (event == .meta_event) continue;
        const attack = event.sub_level_event.attack;
        try testing.expectEqual(@as(u32, 0), attack.attacker_index);
        try testing.expectEqual(@as(u32, 6), attack.outgoing_damage);
        try testing.expect(attack.heals_attacker);
        try testing.expect(attack.defender_index == 1 or attack.defender_index == 2);
    }
}

test "drain: priority follows the AoE bump (3 single, 4 double)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const adjacent = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };

    {
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, adjacent }, &.{});
        const options = freshOptions(.drain, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
    {
        const second = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, adjacent, second }, &.{});
        const options = freshOptions(.drain, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
        setCooldown(game_state, 0, .drain, 1);
        try testing.expectEqual(@as(usize, 0),
    freshOptions(.drain, 0, game_state, undefined, arena.allocator()).len);
    }
}

test "howl: priority bumps with multiple inactive entities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 0 } };
    const inactive_a = types.Entity{ .team = 0, .position = .{ .x = 3, .y = 0 } };
    const inactive_b = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 3 } };

    {
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, inactive_a }, &.{});
        const options = freshOptions(.howl, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
    {
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, inactive_a, inactive_b }, &.{});
        const options = freshOptions(.howl, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
}

test "stab: rating follows the pick, not any-healthy (seam fix)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Weakest target is wounded (Stab's 1.5x bonus does NOT pay on it) while
    // a healthy target stands in range. The old priority summarized "any
    // healthy target" -> 3; the unified option rates the actual pick -> 2.
    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const wounded_weakest = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 4, .max_health = 20 };
    const healthy = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 }, .current_health = 20, .max_health = 20 };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, wounded_weakest, healthy },
        &.{},
    );

    const options = freshOptions(.stab, 0, game_state, undefined, arena.allocator());
    try testing.expectEqual(@as(usize, 1), options.len);
    try testing.expectEqual(wounded_weakest.position, options[0].target.?);
    try testing.expectEqual(@as(u32, 1), options[0].priority);
}

test "worldfire: useSkill attacks each hostile within radius 5 for spell damage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .amulet = .{ .spell_damage = 6 },
    };
    const at_edge = types.Entity{ .team = 1, .position = .{ .x = 5, .y = 0 } };
    const at_diagonal_edge = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 4 } };
    const beyond = types.Entity{ .team = 1, .position = .{ .x = 6, .y = 0 } };
    const same_team = types.Entity{ .team = 0, .position = .{ .x = 1, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, at_edge, at_diagonal_edge, beyond, same_team },
        &.{},
    );

    const result = worldfire_skill.skill.useSkill(0, null, game_state, arena.allocator());
    // Both radius-5 hostiles hit (Chebyshev diagonal = 5); beyond + ally not.
    // 2 attacks + the pacing wait between them.
    try testing.expectEqual(@as(usize, 3), result.len);
    for (result) |event| {
        if (event == .meta_event) continue;
        const attack = event.sub_level_event.attack;
        try testing.expectEqual(@as(u32, 0), attack.attacker_index);
        try testing.expectEqual(@as(u32, 6), attack.outgoing_damage);
        try testing.expect(attack.defender_index == 1 or attack.defender_index == 2);
    }
}

test "worldfire: options follow the AoE bump at radius 5" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const far_single = types.Entity{ .team = 1, .position = .{ .x = 5, .y = 0 } };

    // One target in the big radius → 1.
    {
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, far_single }, &.{});
        const options = freshOptions(.worldfire, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
    // THREE targets end up in radius (the far single counts too) → 3.
    {
        const cluster_a = types.Entity{ .team = 1, .position = .{ .x = 4, .y = 4 } };
        const cluster_b = types.Entity{ .team = 1, .position = .{ .x = 5, .y = 4 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, far_single, cluster_a, cluster_b },
            &.{},
        );
        const options = freshOptions(.worldfire, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 3), options[0].priority);
        setCooldown(game_state, 0, .worldfire, 1);
        try testing.expectEqual(@as(usize, 0), freshOptions(.worldfire, 0, game_state, undefined, arena.allocator()).len);
    }
}

test "aoeKnockbackPriority: value units (base + count - 1 + colliding)" {
    try testing.expectEqual(@as(u32, 0), helpers.aoeKnockbackPriority(0, 0, 1));
    try testing.expectEqual(@as(u32, 1), helpers.aoeKnockbackPriority(1, 0, 1));
    try testing.expectEqual(@as(u32, 2), helpers.aoeKnockbackPriority(1, 1, 1));
    try testing.expectEqual(@as(u32, 2), helpers.aoeKnockbackPriority(2, 0, 1));
    try testing.expectEqual(@as(u32, 3), helpers.aoeKnockbackPriority(2, 1, 1));
    try testing.expectEqual(@as(u32, 6), helpers.aoeKnockbackPriority(4, 2, 1));
}

test "collidingTargetCount: counts only in-radius hostiles whose push collides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const open = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const walled = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
    const out_of_radius = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 3 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, open, walled, out_of_radius },
        // open's 2-step push path ((2,0),(3,0)) exists; walled's ((0,2))
        // does not.
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 }, .{ .x = 0, .y = 1 } },
    );

    try testing.expectEqual(@as(u32, 1), helpers.collidingTargetCount(0, game_state, .{ .x = 0, .y = 0 }, 1, 2));
}

test "shockwave: useSkill attacks then knockbacks each hostile in radius" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .amulet = .{ .spell_damage = 7 },
    };
    const adjacent_a = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const adjacent_b = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
    const far = types.Entity{ .team = 1, .position = .{ .x = 5, .y = 5 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, adjacent_a, adjacent_b, far },
        &.{},
    );

    const result = shockwave_skill.skill.useSkill(0, null, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 7), result.len); // 2 attacks + 2 knockbacks + 3 pacing waits

    var attacks: usize = 0;
    var knockbacks: usize = 0;
    var waits: usize = 0;
    for (result) |event| switch (event) {
        .sub_level_event => |sub| switch (sub) {
            .attack => |attack| {
                attacks += 1;
                try testing.expectEqual(@as(u32, 0), attack.attacker_index);
                try testing.expectEqual(@as(u32, 7), attack.outgoing_damage);
                try testing.expect(attack.defender_index == 1 or attack.defender_index == 2);
            },
            .knockback => |knockback| {
                knockbacks += 1;
                try testing.expectEqual(@as(u32, 2), knockback.distance);
                try testing.expectEqual(@as(u32, 3), knockback.knockback_damage); // 7 / 2
                try testing.expect(knockback.defender_index == 1 or knockback.defender_index == 2);
            },
            else => try testing.expect(false),
        },
        .meta_event => |meta| switch (meta) {
            .accelerating_wait => waits += 1,
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    };
    try testing.expectEqual(@as(usize, 2), attacks);
    try testing.expectEqual(@as(usize, 2), knockbacks);
    try testing.expectEqual(@as(usize, 3), waits);
    // LIFO: the pair listed first (defender 1's attack) runs first — its
    // knockback sits at the BOTTOM of the reversed slice.
    try testing.expectEqual(@as(u32, 1), result[6].sub_level_event.attack.defender_index);
    try testing.expectEqual(@as(u32, 1), result[4].sub_level_event.knockback.defender_index);
}

test "shockwave: options follow the stacked-bump ladder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };

    // Single open-field target (push path clear through 2 steps) → 3.
    {
        const single = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, single },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        );
        const options = freshOptions(.shockwave, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
    // Single walled target (push runs off the tile set) → 4.
    {
        const single = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, single },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } },
        );
        const options = freshOptions(.shockwave, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
    // Two targets, one open one walled → 3 + 1 (cluster) + 1 (collision).
    {
        const open = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
        const walled = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, open, walled },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 }, .{ .x = 0, .y = 1 } },
        );
        const options = freshOptions(.shockwave, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(u32, 3), options[0].priority);
    }
}

test "slam: options on the stacked-bump ladder (retrofit)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };

    // Single open target → 3 (as before the retrofit).
    {
        const single = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, single },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        );
        const options = freshOptions(.slam, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(u32, 1), options[0].priority);
    }
    // Cluster with one walled → 5 (the old AoE-bump-only rating said 4 —
    // it under-sold Slam's full-damage collisions).
    {
        const open = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
        const walled = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, open, walled },
            &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 }, .{ .x = 0, .y = 1 } },
        );
        const options = freshOptions(.slam, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(u32, 3), options[0].priority);
    }
}

test "charged bolt: useSkill attacks with the tripled momentum bonus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Amulet spell damage 6, momentum 4 (log2 → converted bonus 2):
    // getEffectiveSpellDamage folds the conversion in once (6 + 2 = 8),
    // the tripled bonus adds it twice more → 12.
    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .amulet = .{ .spell_damage = 6 },
        .momentum = 4,
    };
    const defender = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, defender },
        &.{},
    );

    const result = charged_bolt_skill.skill.useSkill(0, defender.position, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 1), result.len);
    const attack = result[0].sub_level_event.attack;
    try testing.expectEqual(@as(u32, 0), attack.attacker_index);
    try testing.expectEqual(@as(u32, 1), attack.defender_index);
    try testing.expectEqual(@as(u32, 12), attack.outgoing_damage);
}

test "charged bolt: options offer the focus-fire pick at 2 (one significant bonus)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const in_range = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const out_of_range = types.Entity{ .team = 1, .position = .{ .x = 4, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, in_range, out_of_range },
        &.{},
    );

    const options = freshOptions(.charged_bolt, 0, game_state, undefined, arena.allocator());
    try testing.expectEqual(@as(usize, 1), options.len);
    try testing.expectEqual(in_range.position, options[0].target.?);
    try testing.expectEqual(@as(u32, 2), options[0].priority);
}

test "blitz: options count hits plus stuns-that-pay (value units)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const adjacent_a = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const adjacent_b = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };

    // Single unstunned target: attack 1 + stun 1 → 2.
    {
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, adjacent_a }, &.{});
        const options = freshOptions(.blitz, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(usize, 1), options.len);
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
    // Two targets, one already stunned: 2 hits + 1 paying stun → 3.
    {
        const stunned = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 }, .stun_duration = 2 };
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, adjacent_a, stunned }, &.{});
        const options = freshOptions(.blitz, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(u32, 3), options[0].priority);
    }
    // Two unstunned targets: 2 hits + 2 paying stuns → 4.
    {
        const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, adjacent_a, adjacent_b }, &.{});
        const options = freshOptions(.blitz, 0, game_state, undefined, arena.allocator());
        try testing.expectEqual(@as(u32, 4), options[0].priority);
    }
}

test "drain: lifesteal adds a hit's worth below half health" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const wounded_caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .max_health = 20,
        .current_health = 9,
    };
    const adjacent_a = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const adjacent_b = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ wounded_caster, adjacent_a, adjacent_b },
        &.{},
    );

    // 2 targets + 1 lifesteal bonus (caster below half) → 3.
    const options = freshOptions(.drain, 0, game_state, undefined, arena.allocator());
    try testing.expectEqual(@as(usize, 1), options.len);
    try testing.expectEqual(@as(u32, 3), options[0].priority);
}

test "chain lightning: useSkill arcs through the connected hostile component" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .amulet = .{ .spell_damage = 6 },
    };
    // A line of three hostiles, each within radius 1 of the next → all
    // chained. The ally is not a node; the far hostile is not adjacent to
    // any of them.
    const first = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const second = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 } };
    const third = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const ally = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 1 } };
    const far = types.Entity{ .team = 1, .position = .{ .x = 6, .y = 6 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, first, second, third, ally, far },
        &.{},
    );

    const result = chain_lightning_skill.skill.useSkill(0, first.position, game_state, arena.allocator());
    // 3 attacks + the pacing waits between them.
    try testing.expectEqual(@as(usize, 5), result.len);
    for (result) |event| {
        if (event == .meta_event) continue;
        const attack = event.sub_level_event.attack;
        try testing.expectEqual(@as(u32, 6), attack.outgoing_damage);
        try testing.expect(attack.defender_index == 1 or attack.defender_index == 2 or attack.defender_index == 3);
    }
}

test "chain lightning: an ally between hostiles breaks the chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 }, .amulet = .{ .spell_damage = 6 } };
    // Hostile — ally — hostile in a line: the two hostiles are Chebyshev 2
    // apart (the ally occupies the middle), beyond radius 1 → not
    // connected. Lightning arcs between enemies only.
    const near = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const ally = types.Entity{ .team = 0, .position = .{ .x = 2, .y = 0 } };
    const beyond = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, near, ally, beyond },
        &.{},
    );

    const result = chain_lightning_skill.skill.useSkill(0, near.position, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(u32, 1), result[0].sub_level_event.attack.defender_index);
}

test "chain lightning: options pick the target with the largest component" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    // Two in-range candidates, geometrically separate: the lone target at
    // (-1,0) (component 1) and the head of a pair at (1,1)-(2,2)
    // (component 2 — the pair head is NOT within radius of the lone one,
    // unlike my first attempt at this test where a diagonal made them one
    // component). The pair wins, rated 2 in value units.
    const lone = types.Entity{ .team = 1, .position = .{ .x = -1, .y = 0 }, .current_health = 5 };
    const pair_head = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 1 }, .current_health = 15 };
    const pair_tail = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 2 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, lone, pair_head, pair_tail },
        &.{},
    );

    const options = freshOptions(.chain_lightning, 0, game_state, undefined, arena.allocator());
    try testing.expectEqual(@as(usize, 1), options.len);
    try testing.expectEqual(pair_head.position, options[0].target.?);
    try testing.expectEqual(@as(u32, 2), options[0].priority);
}

test "adrenaline surge: options rate the target by its ticking on-bar count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    // Two in-range sword-carriers: the wounded one has MORE ticking
    // cooldowns (3 vs 1) — the count outranks focus-fire.
    const lightly_cooled = types.Entity{
        .team = 1,
        .position = .{ .x = 1, .y = 0 },
        .current_health = 5,
        .max_health = 20,
        .main_hand_weapon = .{ .weapon_type = .sword },
    };
    const heavily_cooled = types.Entity{
        .team = 1,
        .position = .{ .x = 0, .y = 1 },
        .current_health = 15,
        .max_health = 20,
        .main_hand_weapon = .{ .weapon_type = .sword },
        .equipped_utility_skills = .{ .blink, null, null, null, null },
    };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, lightly_cooled, heavily_cooled },
        &.{},
    );
    @constCast(game_state.level.?.entities)[1].skill_cooldowns.set(.slice, 2); // 1 ticking
    @constCast(game_state.level.?.entities)[2].skill_cooldowns.set(.slice, 2);
    @constCast(game_state.level.?.entities)[2].skill_cooldowns.set(.flash_strike, 3); // swap-available third
    @constCast(game_state.level.?.entities)[2].skill_cooldowns.set(.blink, 1); // utility
    @constCast(game_state.level.?.entities)[2].skill_cooldowns.set(.skewer, 9); // off-bar: not counted

    const options = freshOptions(.adrenaline_surge, 0, game_state, definitions, arena.allocator());
    try testing.expectEqual(@as(usize, 1), options.len);
    try testing.expectEqual(heavily_cooled.position, options[0].target.?);
    try testing.expectEqual(@as(u32, 3), options[0].priority);
}

test "adrenaline surge: nothing ticking on any target offers nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const target = types.Entity{
        .team = 1,
        .position = .{ .x = 1, .y = 0 },
        .main_hand_weapon = .{ .weapon_type = .sword },
    };
    const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, target }, &.{});

    try testing.expectEqual(@as(usize, 0), freshOptions(.adrenaline_surge, 0, game_state, definitions, arena.allocator()).len);
}

test "adrenaline surge: useSkill delegates to the machinery event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const defender = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{ caster, defender }, &.{});

    const result = adrenaline_surge_skill.skill.useSkill(0, defender.position, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 1), result.len);
    const surge = result[0].sub_level_event.adrenaline_surge;
    try testing.expectEqual(@as(u32, 0), surge.attacker_index);
    try testing.expectEqual(@as(u32, 1), surge.defender_index);
}

test "burst: useSkill attacks each hostile in radius with spell damage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .amulet = .{ .spell_damage = 5 },
    };
    const adjacent_a = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const adjacent_b = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
    const beyond = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, adjacent_a, adjacent_b, beyond },
        &.{},
    );

    const result = burst_skill.skill.useSkill(0, null, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 3), result.len); // 2 attacks + the pacing wait
    for (result) |event| {
        if (event == .meta_event) continue;
        const attack = event.sub_level_event.attack;
        try testing.expectEqual(@as(u32, 5), attack.outgoing_damage);
        try testing.expect(attack.defender_index == 1 or attack.defender_index == 2);
    }

    const options = freshOptions(.burst, 0, game_state, undefined, arena.allocator());
    try testing.expectEqual(@as(u32, 2), options[0].priority); // 1 per target hit
}

test "meditate: resets each OTHER equipped utility skill, itself excluded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .equipped_utility_skills = .{ .meditate, .blink, null, .howl, null },
    };
    const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});
    setCooldown(game_state, 0, .blink, 2);
    setCooldown(game_state, 0, .howl, 1);
    setCooldown(game_state, 0, .meditate, 0); // casting it now
    setCooldown(game_state, 0, .skewer, 4); // off-bar preserved: untouched

    const result = meditate_skill.skill.useSkill(0, null, game_state, arena.allocator());
    // Blink + howl reset (2 events + the pacing wait); meditate itself and
    // the off-bar skewer excluded.
    try testing.expectEqual(@as(usize, 3), result.len);
    for (result) |event| {
        if (event == .meta_event) continue;
        const change = event.sub_level_event.change_cooldown;
        try testing.expect(change.skill_id == .blink or change.skill_id == .howl);
        try testing.expect(change.entity_index == 0);
    }

    const options = freshOptions(.meditate, 0, game_state, undefined, arena.allocator());
    try testing.expectEqual(@as(u32, 2), options[0].priority); // the reset count
}

test "accelerate: gains 2 momentum per enemy within radius" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const near_a = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 } };
    const near_b = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 3 } };
    const far = types.Entity{ .team = 1, .position = .{ .x = 4, .y = 0 } };
    const ally = types.Entity{ .team = 0, .position = .{ .x = 1, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, near_a, near_b, far, ally },
        &.{},
    );

    const result = accelerate_skill.skill.useSkill(0, null, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 1), result.len);
    const change = result[0].sub_level_event.change_momentum;
    try testing.expectEqual(@as(u32, 0), change.entity_index);
    try testing.expectEqual(@as(i32, 4), change.delta); // two enemies within 3, 2 momentum each

    const options = freshOptions(.accelerate, 0, game_state, undefined, arena.allocator());
    try testing.expectEqual(@as(u32, 2), options[0].priority); // direct enemy count
}

test "modifier enchantments: reaching, bull, rushing apply their effects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lookups = @import("generated_lookups.zig");

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{caster}, &.{});

    // That Which Reaches: range +1 and radius +1 modifiers on the effect
    // definition, applied to the caster for 2 turns.
    {
        const result = that_which_reaches_skill.skill.useSkill(0, null, game_state, arena.allocator());
        const create = result[0].sub_level_event.create_effect;
        try testing.expectEqual(types.EffectId.that_which_reaches, create.effect_id);
        try testing.expectEqual(@as(u32, 2), create.duration);
        const modifiers = lookups.getEffectDefinition(.that_which_reaches).additive_effect_modifiers;
        try testing.expectEqual(@as(i32, 1), modifiers.range);
        try testing.expectEqual(@as(i32, 1), modifiers.radius);
        // No hostiles, nothing range-bearing on the bar: no live
        // beneficiary and no sim differential — nothing to cast (the old
        // unconditional rating 1 is gone).
        try testing.expectEqual(@as(usize, 0),
            freshOptions(.that_which_reaches, 0, game_state, undefined, arena.allocator()).len);
    }
    // Bull Form: distance +10.
    {
        const result = bull_form_skill.skill.useSkill(0, null, game_state, arena.allocator());
        try testing.expectEqual(types.EffectId.bull_form, result[0].sub_level_event.create_effect.effect_id);
        try testing.expectEqual(@as(i32, 10), lookups.getEffectDefinition(.bull_form).additive_effect_modifiers.distance);
    }
    // That Which Rushes: cooldown -1 and speed +1.
    {
        const result = that_which_rushes_skill.skill.useSkill(0, null, game_state, arena.allocator());
        try testing.expectEqual(types.EffectId.that_which_rushes, result[0].sub_level_event.create_effect.effect_id);
        const modifiers = lookups.getEffectDefinition(.that_which_rushes).additive_effect_modifiers;
        try testing.expectEqual(@as(i32, -1), modifiers.cooldown);
        try testing.expectEqual(@as(i32, 1), modifiers.speed);
    }
}

test "that which explodes: the effect attacks hostiles in radius for spell damage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const holder = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .amulet = .{ .spell_damage = 6 },
    };
    const adjacent_a = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const adjacent_b = types.Entity{ .team = 1, .position = .{ .x = 0, .y = 1 } };
    const far = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const ally = types.Entity{ .team = 0, .position = .{ .x = 1, .y = 1 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ holder, adjacent_a, adjacent_b, far, ally },
        &.{},
    );

    const events = that_which_explodes_effect.effect.onIncomingDamage(0, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 2), events.?.len);
    for (events.?) |event| {
        const attack = event.sub_level_event.attack;
        try testing.expectEqual(@as(u32, 0), attack.attacker_index);
        try testing.expectEqual(@as(u32, 6), attack.outgoing_damage); // spell damage rule
        try testing.expect(attack.defender_index == 1 or attack.defender_index == 2);
    }
}

test "that which explodes: the radius goes through the holder's effective radius" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Holder carries a +1 radius modifier (the That Which Reaches stack):
    // base radius 1 → effective 2, so the enemy at Chebyshev 2 is hit too.
    // Regression guard for the effective-value audit — the radius used to
    // be hardcoded 1, so radius modifiers did nothing for the explosion.
    const holder = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .amulet = .{ .spell_damage = 6 },
        .active_effects = &.{.{ .effect_id = .that_which_reaches, .duration = 2, .additive_effect_modifiers = .{ .radius = 1 } }},
    };
    const within_base = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const within_effective = types.Entity{ .team = 1, .position = .{ .x = 2, .y = 0 } };
    const beyond = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ holder, within_base, within_effective, beyond },
        &.{},
    );

    const events = that_which_explodes_effect.effect.onIncomingDamage(0, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 2), events.?.len);
    for (events.?) |event| {
        const attack = event.sub_level_event.attack;
        try testing.expect(attack.defender_index == 1 or attack.defender_index == 2);
    }
}

test "that which explodes: options gate on the threat model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    const caster = types.Entity{ .team = 0, .position = .{ .x = 0, .y = 0 } };
    const sword_enemy_at = struct {
        fn make(position: Vector2) types.Entity {
            return .{
                .team = 1,
                .position = position,
                .is_active = true,
                .speed = 1,
                .main_hand_weapon = .{ .weapon_type = .sword },
            };
        }
    }.make;

    // Threatened (adjacent active sword enemy) → 2.
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, sword_enemy_at(.{ .x = 1, .y = 0 }) },
            &.{},
        );
        const options = freshOptions(.that_which_explodes, 0, game_state, definitions, arena.allocator());
        try testing.expectEqual(@as(u32, 2), options[0].priority);
    }
    // Unthreatened (far away) → no option (exploding into the void).
    {
        const game_state = test_harness.levelStateWithEntities(
            arena.allocator(),
            &.{ caster, sword_enemy_at(.{ .x = 9, .y = 9 }) },
            &.{},
        );
        try testing.expectEqual(@as(usize, 0), freshOptions(.that_which_explodes, 0, game_state, definitions, arena.allocator()).len);
    }
}

test "promise of death: full-sweep reset + full heal on opponent death" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const holder = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .max_health = 20,
        .current_health = 7,
        .main_hand_weapon = .{ .weapon_type = .sword },
        .equipped_utility_skills = .{ .blink, null, null, null, null },
    };
    const game_state = test_harness.levelStateWithEntities(arena.allocator(), &.{holder}, &.{});
    setCooldown(game_state, 0, .slice, 2); // on-bar
    setCooldown(game_state, 0, .flash_strike, 3); // swap-available third
    setCooldown(game_state, 0, .blink, 1); // utility
    setCooldown(game_state, 0, .skewer, 4); // OFF-BAR preserved — still swept

    const events = promise_of_death_effect.effect.onOpponentDeath(0, game_state, arena.allocator());
    // Four resets (the full sweep incl. skewer) + the heal.
    try testing.expectEqual(@as(usize, 5), events.?.len);
    var resets: usize = 0;
    var saw_heal = false;
    for (events.?) |event| switch (event.sub_level_event) {
        .change_cooldown => resets += 1,
        .heal => |heal| {
            saw_heal = true;
            try testing.expectEqual(@as(u32, 20), heal.amount); // heal to full
        },
        else => try testing.expect(false),
    };
    try testing.expectEqual(@as(usize, 4), resets);
    try testing.expect(saw_heal);
}

test "damage multiplier ordering: Throw's 1.5x applies to the modified total" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Off-hand 4 + gloves bonus 3 → effective 7; 1.5x of the MODIFIED
    // total = 10. (The old order — 1.5x of the raw 4, then the gloves
    // bonus — would give 9.) Regression guard for DESIGN → Architecture →
    // Damage multiplier ordering.
    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .off_hand_weapon = .{ .weapon_damage = 4 },
        .gloves = .{ .damage_bonus = 3 },
    };
    const defender = types.Entity{ .team = 1, .position = .{ .x = 3, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, defender },
        &.{},
    );

    const result = throw_skill.skill.useSkill(0, defender.position, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(u32, 10), result[0].sub_level_event.attack.outgoing_damage);
}

test "damage multiplier ordering: Impale's doubled momentum rides inside the multiplier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Main 4, momentum 4 (converted bonus 2): pipeline = 4 + 2 = 6, the
    // doubled-momentum rider → 8, then 1.5x LAST = 12. (The old order gave
    // 10: 1.5x of the raw 4, +2 momentum, +2 more.)
    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .main_hand_weapon = .{ .weapon_damage = 4 },
        .momentum = 4,
    };
    const defender = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, defender },
        &.{},
    );

    const result = impale_skill.skill.useSkill(0, defender.position, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(u32, 12), result[0].sub_level_event.attack.outgoing_damage);
}

test "damage multiplier ordering: Skewer's doubled momentum rides inside the multiplier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Off-hand 4, momentum 4 (converted bonus 2): pipeline = 6, doubled
    // momentum → 8, then 2x LAST = 16.
    const caster = types.Entity{
        .team = 0,
        .position = .{ .x = 0, .y = 0 },
        .off_hand_weapon = .{ .weapon_damage = 4 },
        .momentum = 4,
    };
    const defender = types.Entity{ .team = 1, .position = .{ .x = 1, .y = 0 } };
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{ caster, defender },
        &.{},
    );

    const result = skewer_skill.skill.useSkill(0, defender.position, game_state, arena.allocator());
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(u32, 16), result[0].sub_level_event.attack.outgoing_damage);
}
