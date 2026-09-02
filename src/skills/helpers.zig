//! Shared building blocks for skill implementations. Skills compose generic
//! events (see DESIGN → Architecture); these helpers factor the targeting/lookup/return
//! boilerplate that is identical across most skills, so each skill file is
//! mostly its distinctive `useSkill` recipe.
//!
//! Excluded from the SkillId scan in build.zig (like skill.zig) — this is a
//! support file, not a skill.

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const functions = @import("../functions.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;

/// Positions of all living hostile entities within `range` (Chebyshev) of the
/// caster. Returns null if there are none — matching `Skill.getValidTargets`.
/// `range` is the caster's already-effective range.
pub fn hostilesInRange(
    caster_index: u32,
    game_state: GameState,
    range: i32,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];

    var positions: std.ArrayList(Vector2) = .empty;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(caster.position, entity.position) <= range) {
            positions.append(allocator, entity.position) catch @panic("failed to append target");
        }
    }

    if (positions.items.len == 0) return null;
    return positions.items;
}

/// AI target selection: the position nearest the caster from `valid_targets`.
/// Null if the list is null or empty — matching `Skill.selectTarget`.
pub fn nearestTarget(
    caster_index: u32,
    valid_targets: ?[]const Vector2,
    game_state: GameState,
) ?Vector2 {
    const targets = valid_targets orelse return null;
    if (targets.len == 0) return null;

    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];

    // Strict < keeps the first target at the minimum distance, so ties resolve
    // by the order of `targets` (its builder's scan order) — deterministic (see
    // DESIGN → Determinism & Tiebreaking).
    var best: ?Vector2 = null;
    var best_distance: i32 = std.math.maxInt(i32);
    for (targets) |position| {
        const distance = functions.chebyshevDistance(caster.position, position);
        if (distance < best_distance) {
            best_distance = distance;
            best = position;
        }
    }
    return best;
}

/// A `highlight_tiles` event covering `targets`, or null if there are none.
/// The standard `playerPrepareSkill` body for a targeted skill.
pub fn highlightTargets(targets: ?[]const Vector2) ?Event {
    const positions = targets orelse return null;
    return .{ .level_event = .{ .highlight_tiles = .{ .tile_positions = positions } } };
}

/// Index of a living hostile entity at `position`, or null. Used by `useSkill`
/// to resolve the entity standing on the chosen target tile.
pub fn hostileEntityAt(
    caster_index: u32,
    position: Vector2,
    game_state: GameState,
) ?u32 {
    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (entity.position.x == position.x and entity.position.y == position.y) {
            return @intCast(entity_index);
        }
    }
    return null;
}

/// Indices of living hostile entities within `radius` (Chebyshev) of `center`.
/// For radius/AoE skills that hit every hostile around a point. Empty slice if
/// none.
pub fn hostileIndicesInRadius(
    caster_index: u32,
    game_state: GameState,
    center: Vector2,
    radius: i32,
    allocator: std.mem.Allocator,
) []const u32 {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    var indices: std.ArrayList(u32) = .empty;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(center, entity.position) <= radius) {
            indices.append(allocator, @intCast(entity_index)) catch @panic("failed to append target index");
        }
    }
    return indices.items;
}

/// A resolved valid-target for the selection scans. `preferred` is the
/// leading key of the keyed selections (knockback: the push collides;
/// stun: the target is not already stunned).
const TargetCandidate = struct {
    position: Vector2,
    preferred: bool,
    health: u32,
    distance: i32,
    entity_index: u32,
};

/// The focus-fire tail order shared by EVERY selection helper: lowest
/// current health, then Chebyshev distance to the caster, then entity
/// index (unique — total order). Convention: DESIGN → Determinism &
/// Tiebreaking.
fn focusFireTailLessThan(a: TargetCandidate, b: TargetCandidate) bool {
    if (a.health != b.health) return a.health < b.health;
    if (a.distance != b.distance) return a.distance < b.distance;
    return a.entity_index < b.entity_index;
}

/// Preferred candidates first, then the focus-fire tail — the ordering for
/// the keyed selection helpers (knockbackTarget, stunTarget).
fn preferredThenTailLessThan(a: TargetCandidate, b: TargetCandidate) bool {
    if (a.preferred != b.preferred) return a.preferred;
    return focusFireTailLessThan(a, b);
}

/// AI target selection for attack skills: the hostile with the LOWEST
/// current health from `valid_targets` — focus-fire concentrates damage
/// on nearly-dead enemies so they die sooner (more effective than nearest-
/// first when several enemies are engaged). Ties break by Chebyshev distance
/// to the caster, then by entity index (unique, so the order is total).
/// Convention: see DESIGN → Determinism & Tiebreaking. `nearestTarget`
/// remains for the non-attack exceptions (Swap).
pub fn weakestTarget(
    caster_index: u32,
    valid_targets: ?[]const Vector2,
    game_state: GameState,
) ?Vector2 {
    const targets = valid_targets orelse return null;
    if (targets.len == 0) return null;

    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];

    var best: ?TargetCandidate = null;
    for (targets) |position| {
        // Valid targets come from getValidTargets, so the lookup should
        // never miss; skip defensively rather than panic on a stale list.
        const entity_index = hostileEntityAt(caster_index, position, game_state) orelse continue;
        const entity = level.entities[entity_index];
        const candidate = TargetCandidate{
            .position = position,
            .preferred = false,
            .health = entity.current_health,
            .distance = functions.chebyshevDistance(caster.position, position),
            .entity_index = entity_index,
        };
        if (best == null or focusFireTailLessThan(candidate, best.?)) best = candidate;
    }
    return if (best) |candidate| candidate.position else null;
}

/// Per-axis sign of an i32 delta: −1 / 0 / +1 (the knockback direction
/// normalization).
fn sign(value: i32) i32 {
    return if (value > 0) 1 else if (value < 0) @as(i32, -1) else 0;
}

/// Whether knocking `defender_index` back from `caster_index` by `distance`
/// steps would COLLIDE — a missing tile (level edge) or a living occupant
/// along the push path. Mirrors the knockback handler exactly: direction =
/// each axis of defender − caster normalized to −1/0/+1; the defender itself
/// is not an obstacle (it moves with the push); dead entities are not
/// obstacles. `distance` is the caster's EFFECTIVE push distance (the caller
/// applies getEffectiveDistance). Shared by the knockback skills' AI priority
/// and target selection so the prediction cannot drift from the handler.
pub fn knockbackWouldCollide(
    caster_index: u32,
    defender_index: u32,
    distance: u32,
    game_state: GameState,
) bool {
    const level = game_state.level orelse return false;
    const caster = level.entities[caster_index];
    const defender = level.entities[defender_index];

    const direction = Vector2{
        .x = sign(defender.position.x - caster.position.x),
        .y = sign(defender.position.y - caster.position.y),
    };
    var position = defender.position;
    var step: u32 = 0;
    while (step < distance) : (step += 1) {
        position = .{ .x = position.x + direction.x, .y = position.y + direction.y };
        if (!tileExists(game_state, position) or
            isOccupied(game_state, position, defender_index))
        {
            return true;
        }
    }
    return false;
}

/// AI target selection for knockback skills: prefer a target the push will
/// COLLIDE (the collision adds damage), then the focus-fire tail — lowest
/// current health, then Chebyshev distance to the caster, then entity index
/// (total order). `distance` is the caster's EFFECTIVE push distance. The
/// tail keys match `weakestTarget`; this adds the collide key in front.
pub fn knockbackTarget(
    caster_index: u32,
    valid_targets: ?[]const Vector2,
    distance: u32,
    game_state: GameState,
) ?Vector2 {
    const targets = valid_targets orelse return null;
    if (targets.len == 0) return null;

    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];

    var best: ?TargetCandidate = null;
    for (targets) |position| {
        // Valid targets come from getValidTargets, so the lookup should
        // never miss; skip defensively rather than panic on a stale list.
        const entity_index = hostileEntityAt(caster_index, position, game_state) orelse continue;
        const candidate = TargetCandidate{
            .position = position,
            .preferred = knockbackWouldCollide(caster_index, entity_index, distance, game_state),
            .health = level.entities[entity_index].current_health,
            .distance = functions.chebyshevDistance(caster.position, position),
            .entity_index = entity_index,
        };
        if (best == null or preferredThenTailLessThan(candidate, best.?)) best = candidate;
    }
    return if (best) |candidate| candidate.position else null;
}

/// AI target selection for stun skills: prefer a target that is NOT already
/// stunned (stuns take the max of current vs incoming, never stack — a stun
/// on a stunned target only pays if the new duration is longer), then the
/// focus-fire tail (lowest health, distance, entity index). See DESIGN →
/// Architecture (the stun rule).
pub fn stunTarget(
    caster_index: u32,
    valid_targets: ?[]const Vector2,
    game_state: GameState,
) ?Vector2 {
    const targets = valid_targets orelse return null;
    if (targets.len == 0) return null;

    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];

    var best: ?TargetCandidate = null;
    for (targets) |position| {
        // Valid targets come from getValidTargets, so the lookup should
        // never miss; skip defensively rather than panic on a stale list.
        const entity_index = hostileEntityAt(caster_index, position, game_state) orelse continue;
        const entity = level.entities[entity_index];
        const candidate = TargetCandidate{
            .position = position,
            .preferred = entity.stun_duration == 0,
            .health = entity.current_health,
            .distance = functions.chebyshevDistance(caster.position, position),
            .entity_index = entity_index,
        };
        if (best == null or preferredThenTailLessThan(candidate, best.?)) best = candidate;
    }
    return if (best) |candidate| candidate.position else null;
}

/// Empty walkable tiles within `range` (Chebyshev) of the caster — valid
/// teleport destinations (Blink, FlashStrike). Null if there are none.
pub fn emptyTilesInRange(
    caster_index: u32,
    game_state: GameState,
    range: i32,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];

    var positions: std.ArrayList(Vector2) = .empty;
    var delta_y: i32 = -range;
    while (delta_y <= range) : (delta_y += 1) {
        var delta_x: i32 = -range;
        while (delta_x <= range) : (delta_x += 1) {
            if (delta_x == 0 and delta_y == 0) continue;
            const position = Vector2{ .x = caster.position.x + delta_x, .y = caster.position.y + delta_y };
            if (tileExists(game_state, position) and !isOccupied(game_state, position, null)) {
                positions.append(allocator, position) catch @panic("failed to append empty tile");
            }
        }
    }
    if (positions.items.len == 0) return null;
    return positions.items;
}

/// Whether a walkable tile exists at `position`.
pub fn tileExists(game_state: GameState, position: Vector2) bool {
    const level = game_state.level orelse return false;
    for (level.level_tiles) |tile| {
        if (tile.x == position.x and tile.y == position.y) return true;
    }
    return false;
}

/// Whether a living entity (other than `exclude_index`, if given) occupies
/// `position`. Used for knockback/retreat collision checks.
pub fn isOccupied(game_state: GameState, position: Vector2, exclude_index: ?u32) bool {
    const level = game_state.level orelse return false;
    for (level.entities, 0..) |entity, entity_index| {
        if (exclude_index) |excluded| {
            if (entity_index == excluded) continue;
        }
        if (entity.current_health == 0) continue;
        if (entity.position.x == position.x and entity.position.y == position.y) return true;
    }
    return false;
}

/// Build the event slice a `useSkill` returns. Takes events in natural
/// EXECUTION order and returns them REVERSED, because the event stack is LIFO:
/// pushEvents appends and processEvent pops from the end, so the last element
/// runs first. Reversing here lets skill authors list events in the order they
/// should happen (e.g. attack, then stun).
///
/// The result lives in `allocator` (not a caller-frame temporary): pushEvents
/// consumes it synchronously but it must be valid at that point.
pub fn ownedEvents(
    allocator: std.mem.Allocator,
    events_in_execution_order: []const Event,
) []const Event {
    const owned = allocator.dupe(Event, events_in_execution_order) catch @panic("failed to allocate skill events");
    std.mem.reverse(Event, owned);
    return owned;
}
