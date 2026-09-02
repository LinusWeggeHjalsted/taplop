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

const Vector2 = types.Vector2;

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
