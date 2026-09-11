//! AI cast selection — the ONE selection algorithm shared by
//! `enemy_turn_attack` (which cast fires next) and the enhancement
//! enchantments' ratings (which anchor themselves to the cast they would
//! enhance — see DESIGN → Architecture, AI rating scale). Extracted from
//! the handler so a prediction can never drift from the real selection.
//!
//! One-way edge rule (recursion safety): an enhancer's rating consults
//! (a) `plannedEndingCast` — which evaluates ONLY weapon/spell slots, none
//! of which are enhancers — and (b) the options of `.cantrip`-type
//! beneficiaries only (never another `.enchantment`). Enhancers never
//! consult other enhancers, and ending skills never consult the plan, so
//! the option-evaluation graph is acyclic by construction.

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
    ending: ?CastPlan,
    non_ending: ?CastPlan,
};

/// The selection pools: weapon skills + spells end the attack phase;
/// cantrips + enchantments don't (the attack phase fires every positive
/// non-ending option in descending rating before the ending cast).
const Pool = enum {
    ending,
    non_ending,
};

/// Evaluate all the caster's off-cooldown skill slots' AI options and pick
/// the best cast per pool: skip 0-rated options, keep the strictly-best
/// rating with SLOT ORDER as the tiebreak (the first — leftmost — slot
/// wins ties). This is the exact selection `enemy_turn_attack` applies.
pub fn bestCasts(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) BestCasts {
    return .{
        .ending = bestCast(caster_index, game_state, weapon_type_definitions, allocator, .ending),
        .non_ending = bestCast(caster_index, game_state, weapon_type_definitions, allocator, .non_ending),
    };
}

/// The planned TURN-ENDING cast — the cast that ends the caster's attack
/// phase once the non-ending chain empties. Enhancement enchantments read
/// this to rate themselves against the cast they would enhance (best
/// beneficiary rating + 1). Evaluates ONLY weapon/spell slots — see the
/// one-way edge rule in the file header.
pub fn plannedEndingCast(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) ?CastPlan {
    return bestCast(caster_index, game_state, weapon_type_definitions, allocator, .ending);
}

fn bestCast(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    pool: Pool,
) ?CastPlan {
    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];
    const skill_ids = caster.collectSkillSlots(weapon_type_definitions);

    var best: ?CastPlan = null;

    for (&skill_ids) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) continue;
        const skill_definition = lookups.getSkillDefinition(skill_id) orelse continue;

        const ends_turn = skill_definition.skill_type == .weapon_skill or
            skill_definition.skill_type == .spell;
        if ((pool == .ending) != ends_turn) continue;

        const options = skill_definition.aiOptions(
            caster_index,
            game_state,
            weapon_type_definitions,
            allocator,
        );
        for (options) |option| {
            if (option.priority == 0) continue;
            if (best == null or option.priority > best.?.priority) {
                best = .{
                    .skill_id = skill_id,
                    .target = option.target,
                    .priority = option.priority,
                };
            }
        }
    }

    return best;
}
