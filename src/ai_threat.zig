//! AI range + threat math, shared by the enemy AI (handlers/level.zig) and
//! the defensive skills' priority fns (Absorb, Reflect). Lives in its own
//! file — not skill_helpers.zig — because it needs generated_lookups, which
//! imports every skill file; this file imports none, so there is no import
//! cycle. See DESIGN → Architecture (AI threat model).

const types = @import("types.zig");
const state = @import("state.zig");
const functions = @import("functions.zig");
const lookups = @import("generated_lookups.zig");

const GameState = state.GameState;
const Entity = types.Entity;
const SkillId = types.SkillId;
const WeaponTypeDefinitions = types.WeaponTypeDefinitions;

/// Effective reach of one skill for approach/threat math: a targeted skill
/// reaches `range`, a self-centered AoE skill reaches `radius` (it hits
/// everything within that of the caster), and a self-cast skill (neither)
/// has no reach. Cooldown and damage filters belong to the callers.
fn effectiveSkillReach(entity: Entity, skill_id: SkillId) ?u32 {
    const skill_definition = lookups.getSkillDefinition(skill_id) orelse return null;
    if (skill_definition.range) |range| return entity.getEffectiveRange(range);
    if (skill_definition.radius) |radius| return entity.getEffectiveRadius(radius);
    return null;
}

/// The MINIMUM effective reach across the entity's off-cooldown skills —
/// the "close enough to act at all" threshold for enemy approach (an enemy
/// stops moving once within min range of its target). Counts every usable
/// skill, not just damaging ones: a control-only enemy should stop and
/// cast from its range, not walk adjacent first. Min answers
/// "when can I act"; computeMaxDamageRange answers "how far can I hurt" —
/// different questions, different filters. Null when nothing is usable.
pub fn computeMinRange(
    entity: Entity,
    weapon_type_definitions: WeaponTypeDefinitions,
) ?u32 {
    const skill_ids = entity.collectSkillSlots(weapon_type_definitions);
    var min_range: ?u32 = null;

    for (&skill_ids) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (entity.skill_cooldowns.get(skill_id) > 0) continue;
        const effective_range = effectiveSkillReach(entity, skill_id) orelse continue;

        if (min_range) |current_min| {
            if (effective_range < current_min) {
                min_range = effective_range;
            }
        } else {
            min_range = effective_range;
        }
    }

    return min_range;
}

/// The MAXIMUM effective reach across the entity's off-cooldown DAMAGING
/// skills — how far away it can hurt something after closing. Non-damaging
/// skills (movement, control, buffs) don't threaten. Null when no damaging
/// skill is ready (such an entity cannot deal damage next turn).
pub fn computeMaxDamageRange(
    entity: Entity,
    weapon_type_definitions: WeaponTypeDefinitions,
) ?u32 {
    const skill_ids = entity.collectSkillSlots(weapon_type_definitions);
    var max_range: ?u32 = null;

    for (&skill_ids) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (entity.skill_cooldowns.get(skill_id) > 0) continue;
        const skill_definition = lookups.getSkillDefinition(skill_id) orelse continue;
        if (!skill_definition.deals_damage) continue;
        const effective_range = effectiveSkillReach(entity, skill_id) orelse continue;

        if (max_range == null or effective_range > max_range.?) {
            max_range = effective_range;
        }
    }

    return max_range;
}

/// Whether any hostile could reach and attack `caster_index` on its next
/// turn: alive, active (unaggroed enemies don't act), unstunned (a stunned
/// entity skips its next turn), and within `effective speed + max damaging
/// reach` by Chebyshev. Obstacle-blind — a wall between can overestimate,
/// which is the safe direction for a defensive cooldown; a pathfinding
/// refinement is a later polish pass. Used by the defensive skills' AI
/// priority (Absorb, Reflect). See DESIGN → Architecture (AI threat model).
pub fn hostileCanAttackNextTurn(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: WeaponTypeDefinitions,
) bool {
    const level = game_state.level orelse return false;
    const caster = level.entities[caster_index];

    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (!entity.is_active) continue;
        if (entity.stun_duration > 0) continue;

        const reach: i32 = @as(i32, @intCast(entity.getEffectiveSpeed())) +
            @as(i32, @intCast(computeMaxDamageRange(entity, weapon_type_definitions) orelse 0));
        if (functions.chebyshevDistance(caster.position, entity.position) <= reach) return true;
    }
    return false;
}
