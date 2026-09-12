//! Shared building blocks for skill implementations. Skills compose generic
//! events (see DESIGN → Architecture); these helpers factor the targeting/lookup/return
//! boilerplate that is identical across most skills, so each skill file is
//! mostly its distinctive `useSkill` recipe.

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");
const functions = @import("functions.zig");
const skill_mod = @import("skill.zig");
const ai_select = @import("ai_select.zig");
const lookups = @import("generated_lookups.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const AiOption = skill_mod.AiOption;

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
///
/// EXECUTION ORDER — the AoE spiral (see DESIGN → Determinism & Tiebreaking):
/// targets enumerate by TILE, walking `spiralTilesInRadius` — the innermost
/// ring first from its top-left tile clockwise, then each next ring the same
/// way. The center tile is NOT included (meteor is the one exception — it
/// strikes the center first, then the spiral).
pub fn hostileIndicesInRadius(
    caster_index: u32,
    game_state: GameState,
    center: Vector2,
    radius: i32,
    allocator: std.mem.Allocator,
) []const u32 {
    var indices: std.ArrayList(u32) = .empty;
    const tiles = spiralTilesInRadius(allocator, center, radius);
    for (tiles) |tile| {
        // Same filter as always (living, hostile, not the caster) — the
        // per-tile lookup IS the filter, and one entity per tile makes the
        // mapping unique.
        if (hostileEntityAt(caster_index, tile, game_state)) |entity_index| {
            indices.append(allocator, entity_index) catch @panic("failed to append target index");
        }
    }
    return indices.items;
}

/// The tiles within `radius` (Chebyshev) of `center`, EXCLUDING the center
/// tile, in spiral order: ring 1 first, starting at the ring's top-left
/// `(center.x - 1, center.y - 1)` and walking CLOCKWISE (screen coords, +y
/// is down: top edge left→right, right edge top→bottom, bottom edge
/// right→left, left edge bottom→top), then ring 2 the same way, and so on
/// outward. Ring n has exactly 8n tiles. The shared AoE execution order —
/// see DESIGN → Determinism & Tiebreaking (AoE execution order).
pub fn spiralTilesInRadius(
    allocator: std.mem.Allocator,
    center: Vector2,
    radius: i32,
) []const Vector2 {
    var tiles: std.ArrayList(Vector2) = .empty;
    var ring: i32 = 1;
    while (ring <= radius) : (ring += 1) {
        const cx = center.x;
        const cy = center.y;
        // Top edge, left → right (includes both top corners).
        var i: i32 = 0;
        while (i <= 2 * ring) : (i += 1) {
            tiles.append(allocator, .{ .x = cx - ring + i, .y = cy - ring }) catch
                @panic("failed to append spiral tile");
        }
        // Right edge, top → bottom (excludes the top-right corner).
        i = 1;
        while (i <= 2 * ring) : (i += 1) {
            tiles.append(allocator, .{ .x = cx + ring, .y = cy - ring + i }) catch
                @panic("failed to append spiral tile");
        }
        // Bottom edge, right → left (excludes the bottom-right corner).
        i = 1;
        while (i <= 2 * ring) : (i += 1) {
            tiles.append(allocator, .{ .x = cx + ring - i, .y = cy + ring }) catch
                @panic("failed to append spiral tile");
        }
        // Left edge, bottom → top (excludes both left corners).
        i = 1;
        while (i <= 2 * ring - 1) : (i += 1) {
            tiles.append(allocator, .{ .x = cx - ring, .y = cy + ring - i }) catch
                @panic("failed to append spiral tile");
        }
    }
    return tiles.items;
}

/// A resolved valid-target for the selection scans. `preferred` is the

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

/// Number of living hostile entities within `radius` (Chebyshev) of
/// `center` — the AoE hit-count around an arbitrary point (the caster's
/// own position for self-centered skills, a candidate landing tile for
/// Flash Strike). Allocation-free so priority fns can call it.
pub fn hostileCountWithinRadius(
    caster_index: u32,
    game_state: GameState,
    center: Vector2,
    radius: i32,
) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];

    var count: u32 = 0;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(center, entity.position) <= radius) count += 1;
    }
    return count;
}

/// The AoE rating in VALUE UNITS (see DESIGN → Architecture, AI rating
/// scale): `base` is what ONE target's plain hit is worth (1 for a plain
/// AoE; 2 when the cast carries a global rider worth a hit, e.g. Flash
/// Strike's teleport), +1 per additional target. 0 when nothing would be
/// hit.
pub fn aoePriority(target_count: u32, base_priority: u32) u32 {
    if (target_count == 0) return 0;
    return base_priority + target_count - 1;
}

/// Build a one-option AI list — the common case where a skill has a single
/// best cast (the focus-fire pick, a self-cast buff, the best strike
/// center). Skills with genuinely competing casts build their own slice.
pub fn singleOption(allocator: std.mem.Allocator, option: AiOption) []const AiOption {
    return allocator.dupe(AiOption, &.{option}) catch @panic("failed to allocate AI option");
}

/// Number of hostiles within `radius` (Chebyshev) of `center` whose knockback
/// push from the caster (by `push_distance`) would COLLIDE — the
/// AoE-knockback collision count. Allocation-free; reuses
/// knockbackWouldCollide so the prediction cannot drift from the handler.
pub fn collidingTargetCount(
    caster_index: u32,
    game_state: GameState,
    center: Vector2,
    radius: i32,
    push_distance: u32,
) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];

    var count: u32 = 0;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(center, entity.position) > radius) continue;
        if (knockbackWouldCollide(caster_index, @intCast(entity_index), push_distance, game_state)) count += 1;
    }
    return count;
}

/// The value-unit rating for AoE knockback skills: one hit's worth per
/// target (`base` for the first — 1 for a plain per-target hit), +1 per
/// target whose push would collide (the collision adds ~a hit of damage
/// to that target). "Per colliding target" is honest for an AoE — the
/// cast has no target choice (contrast the single-target skills, whose
/// collision bump rides their pick). 0 when nothing would be hit.
/// 1.5x damage, integer math (base + base/2). Damage multipliers apply
/// LAST — to the fully-modified damage (gear + effects + momentum + any
/// skill-specific additive bonus), never to the raw weapon/spell number.
/// See DESIGN → Architecture → Damage multiplier ordering.
pub fn damageTimesOneAndAHalf(base_damage: u32) u32 {
    return base_damage + base_damage / 2;
}

pub fn aoeKnockbackPriority(target_count: u32, colliding_count: u32, base_priority: u32) u32 {
    if (target_count == 0) return 0;
    return base_priority + target_count - 1 + colliding_count;
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

/// Intra-effect pacing gap between the individual effects of one skill
/// (and between a hit's resolution and its damage — the attack/collision
/// arms push it too). Distinct from turn-flow pacing (500ms between turn
/// steps). Shared here because both skills and the handlers construct it.
/// See DESIGN → Architecture → Damage apply split + TODO → Effect pacing.
pub const effect_step_wait_milliseconds: u32 = 125;

/// A `wait` event carrying `effect_step_wait_milliseconds` — the constructor
/// skill recipes interleave into their `ownedEvents` lists (natural
/// execution order) to pace their individual effects.
pub fn effectStepWait() Event {
    return .{ .meta_event = .{ .wait = .{
        .duration_milliseconds = effect_step_wait_milliseconds,
    } } };
}

/// The caster's would-be best casts with one extra active effect virtually
/// applied — an enhancement enchantment's DIFFERENTIAL evaluation: what
/// would the bar cast if I were already active? (That Which Reaches: +1
/// range can enable an out-of-range attack or upgrade the target choice;
/// Bull Form: +10 distance can flip a knockback's collision rating. See
/// DESIGN → Architecture, AI rating scale.)
///
/// Shallow-clones the entities slice (only the caster's effects array is
/// replaced — the denormalized `additive_effect_modifiers` the modifier
/// pipeline reads are copied from the effect definition, mirroring
/// create_effect), then runs `ai_select.bestCasts` against the simulated
/// state with a FRESH frame: the caller frame's option memos are for the
/// real state and must not be poisoned with virtual-modifier results. The
/// sim frame INHERITS the caller's in-progress set plus `skill_id` — the
/// whole "currently being decided" stack is excluded from the
/// hypothetical (without the inheritance, two sim-based enhancers
/// equipped together would alternate through each other's sims forever).
/// Transient arena memory, pass-scoped.
pub fn bestCastsWithVirtualEffect(
    frame: *skill_mod.EvalFrame,
    skill_id: types.SkillId,
    effect_id: types.EffectId,
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) ai_select.BestCasts {
    const level = game_state.level orelse return .{ .ending = null, .non_ending = null };

    var sim_state = game_state;
    const entities = allocator.dupe(types.Entity, level.entities) catch
        @panic("failed to clone entities for virtual-effect simulation");
    const effect_definition = lookups.getEffectDefinition(effect_id);
    var updated_effects: std.ArrayList(types.Effect) = .empty;
    updated_effects.appendSlice(allocator, entities[caster_index].active_effects) catch
        @panic("failed to copy active effects for simulation");
    updated_effects.append(allocator, .{
        .effect_id = effect_id,
        .duration = 1,
        .additive_effect_modifiers = effect_definition.additive_effect_modifiers,
    }) catch @panic("failed to append simulated effect");
    entities[caster_index].active_effects = updated_effects.toOwnedSlice(allocator) catch
        @panic("failed to allocate simulated effects");
    sim_state.level.?.entities = entities;

    var sim_frame = skill_mod.EvalFrame.empty();
    sim_frame.in_progress = frame.in_progress;
    sim_frame.in_progress.insert(skill_id);
    return ai_select.bestCasts(caster_index, sim_state, weapon_type_definitions, allocator, &sim_frame);
}

/// The virtual-effect sim differential's GAIN for an enhancement
/// enchantment: the whole bar re-evaluated with the effect virtually
/// applied (bestCastsWithVirtualEffect), and the best plan rating that
/// DIFFERS from the real bar's plans (any difference — an enabled cast, a
/// better cast, a different target — counts; see ai_select.plansDiffer).
/// Both pools. 0 when the modifier changes nothing the bar would cast.
/// `real` is the caller's own bestCasts result (already computed for the
/// base-value rule) — the comparison needs it, so pass it rather than
/// re-deriving. See DESIGN → Architecture, AI rating scale.
pub fn simDifferentialGain(
    frame: *skill_mod.EvalFrame,
    skill_id: types.SkillId,
    effect_id: types.EffectId,
    caster_index: u32,
    real: ai_select.BestCasts,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) u32 {
    const sim = bestCastsWithVirtualEffect(frame, skill_id, effect_id, caster_index, game_state, weapon_type_definitions, allocator);
    var gain: u32 = 0;
    // The gain is the SIM's plan when it differs — unwrap the sim side
    // only (plansDiffer is also true when the real plan exists and the
    // sim's doesn't; there is no would-be cast to gain from there).
    if (sim.ending) |sim_plan| {
        if (ai_select.plansDiffer(real.ending, sim_plan)) gain = sim_plan.priority;
    }
    if (sim.non_ending) |sim_plan| {
        if (ai_select.plansDiffer(real.non_ending, sim_plan) and sim_plan.priority > gain) {
            gain = sim_plan.priority;
        }
    }
    return gain;
}

test "spiralTilesInRadius: ring 1 from the top-left, clockwise, center excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tiles = spiralTilesInRadius(arena.allocator(), .{ .x = 2, .y = 2 }, 1);
    try std.testing.expectEqual(@as(usize, 8), tiles.len);
    const expected = [_]types.Vector2{
        .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 1 },
        .{ .x = 3, .y = 2 }, .{ .x = 3, .y = 3 }, .{ .x = 2, .y = 3 },
        .{ .x = 1, .y = 3 }, .{ .x = 1, .y = 2 },
    };
    for (tiles, expected) |tile, want| try std.testing.expectEqual(want, tile);
}

test "spiralTilesInRadius: ring 2 follows ring 1, 8n tiles per ring" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tiles = spiralTilesInRadius(arena.allocator(), .{ .x = 2, .y = 2 }, 2);
    try std.testing.expectEqual(@as(usize, 24), tiles.len); // 8 + 16

    // Ring 2 starts at ITS top-left (0, 0), directly after ring 1.
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, tiles[8]);
    // Ring 2's top edge runs left → right ...
    try std.testing.expectEqual(types.Vector2{ .x = 4, .y = 0 }, tiles[12]);
    // ... then the right edge top → bottom ...
    try std.testing.expectEqual(types.Vector2{ .x = 4, .y = 1 }, tiles[13]);
    // ... and the walk ends on the left edge, second tile from the top.
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 1 }, tiles[23]);
}

test "hostileIndicesInRadius: spiral execution order + the living/hostile filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Caster at the center; a hostile on ring 1 (bottom edge), one on
    // ring 2 (top-left), a DEAD hostile on ring 1, and an ally on ring 1.
    var entities = [_]types.Entity{
        .{ .team = 0, .position = .{ .x = 2, .y = 2 }, .current_health = 10 }, // caster
        .{ .team = 1, .position = .{ .x = 2, .y = 3 }, .current_health = 10 }, // ring 1
        .{ .team = 1, .position = .{ .x = 0, .y = 0 }, .current_health = 10 }, // ring 2
        .{ .team = 1, .position = .{ .x = 1, .y = 1 }, .current_health = 0 }, // dead, ring 1
        .{ .team = 0, .position = .{ .x = 3, .y = 3 }, .current_health = 10 }, // ally, ring 1
    };
    var level: types.Level = .{};
    level.entities = &entities;
    const game_state = state.GameState{
        .screen = .level,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = level,
        .hub = null,
    };

    const indices = hostileIndicesInRadius(0, game_state, .{ .x = 2, .y = 2 }, 2, arena.allocator());
    // Ring 1 before ring 2; dead + same-team filtered out.
    try std.testing.expectEqual(@as(usize, 2), indices.len);
    try std.testing.expectEqual(@as(u32, 1), indices[0]);
    try std.testing.expectEqual(@as(u32, 2), indices[1]);
}
