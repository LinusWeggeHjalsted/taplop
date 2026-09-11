//! AI cast selection — the ONE selection algorithm shared by
//! `enemy_turn_attack` (which cast fires next) and the enhancement
//! enchantments' ratings (which anchor themselves to the cast they would
//! enhance — see DESIGN → Architecture, AI rating scale). Extracted from
//! the handler so a prediction can never drift from the real selection.
//! One-way edge rule: an enhancer may read the plan; the skills the plan
//! evaluates must never consult an enhancer's rating (the option graph
//! stays acyclic by construction).

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const lookups = @import("generated_lookups.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;

/// One planned cast: the skill, its chosen target, and the rating it was
/// picked at.
pub const CastPlan = struct {
    skill_id: types.SkillId,
    target: ?Vector2,
    priority: u32,
};

/// The best cast in each pool for one caster this re-evaluation.
pub const BestCasts = struct {
    /// The planned TURN-ENDING cast (weapon skills + spells) — the cast
    /// that ends the caster's attack phase once the non-ending chain
    /// empties. Null when no ending skill offers a positive cast.
    ending: ?CastPlan,
    /// The best NON-ENDING cast (cantrips + enchantments). The attack
    /// phase fires every positive non-ending option in descending rating
    /// before `ending`, so this is the next cast in the chain. Null when
    /// the pool is empty.
    non_ending: ?CastPlan,
};

/// Evaluate all the caster's off-cooldown skill slots' AI options and pick
/// the best cast per pool: partition by skill_type (weapon skill + spell =
/// turn-ending), skip 0-rated options, keep the strictly-best rating with
/// SLOT ORDER as the tiebreak (the first — leftmost — slot wins ties).
/// This is the exact selection `enemy_turn_attack` applies; enhancement
/// enchantments read the same result to rate themselves (best beneficiary
/// rating + 1).
pub fn bestCasts(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) BestCasts {
    const level = game_state.level orelse return .{ .ending = null, .non_ending = null };
    const caster = level.entities[caster_index];
    const skill_ids = caster.collectSkillSlots(weapon_type_definitions);

    var best_non_ending: ?CastPlan = null;
    var best_ending: ?CastPlan = null;

    for (&skill_ids) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) continue;
        const skill_definition = lookups.getSkillDefinition(skill_id) orelse continue;

        const ends_turn = skill_definition.skill_type == .weapon_skill or
            skill_definition.skill_type == .spell;

        const options = skill_definition.aiOptions(
            caster_index,
            game_state,
            weapon_type_definitions,
            allocator,
        );
        for (options) |option| {
            if (option.priority == 0) continue;

            if (ends_turn) {
                if (best_ending == null or option.priority > best_ending.?.priority) {
                    best_ending = .{
                        .skill_id = skill_id,
                        .target = option.target,
                        .priority = option.priority,
                    };
                }
            } else {
                if (best_non_ending == null or option.priority > best_non_ending.?.priority) {
                    best_non_ending = .{
                        .skill_id = skill_id,
                        .target = option.target,
                        .priority = option.priority,
                    };
                }
            }
        }
    }

    return .{ .ending = best_ending, .non_ending = best_non_ending };
}
