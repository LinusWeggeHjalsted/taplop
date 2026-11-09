//! AI cast selection - the ONE selection algorithm shared by
//! `enemy_turn_attack` (which cast fires next) and the enhancement
//! enchantments' ratings (which anchor themselves to the cast they would
//! enhance - see DESIGN → Architecture, AI rating scale). Extracted from
//! the handler so a prediction can never drift from the real selection.
//!
//! All option evaluations go THROUGH the pass-scoped EvalFrame
//! (`optionsFor`): memoized once per pass (state is frozen within a pass),
//! recursion cut by the in-progress guard (a skill under evaluation
//! answers nothing to nested questions about it). Any skill may consult
//! any set of skills - a cycle terminates at the guard, so no structural
//! restrictions (pool separation, beneficiary-type filters) are needed.

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const skill_mod = @import("skill.zig");
const lookups = @import("generated_lookups.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const EvalFrame = skill_mod.EvalFrame;
const AiOption = skill_mod.AiOption;

/// One planned cast: the skill, its chosen target, and the rating it was
/// picked at.
pub const CastPlan = struct {
    skill_id: types.SkillId,
    target: ?Vector2,
    priority: u32,
};

/// The best cast in each pool for one caster this re-evaluation.
pub const BestCasts = struct {
    /// The planned TURN-ENDING cast (weapon skills + spells) - the cast
    /// that ends the caster's attack phase once the non-ending chain
    /// empties. Null when no ending skill offers a positive cast.
    ending: ?CastPlan,
    /// The best NON-ENDING cast (cantrips + enchantments). The attack
    /// phase fires every positive non-ending option in descending rating
    /// before `ending`, so this is the next cast in the chain. Null when
    /// the pool is empty.
    non_ending: ?CastPlan,
};

/// A skill's current option set, computed through the frame: memoized
/// once per pass, cycle-cut by the in-progress guard (a skill whose
/// aiOptions is transitively being computed returns empty options - the
/// correct semantics for a consultation, e.g. an enhancer scanning
/// beneficiaries must not count itself). THE entry point for every
/// option evaluation - never call a skill's aiOptions directly.
pub fn optionsFor(
    frame: *EvalFrame,
    skill_id: types.SkillId,
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const AiOption {
    if (frame.in_progress.contains(skill_id)) return &.{};
    if (frame.results[@backingInt(skill_id)]) |options| return options;
    const skill = lookups.getSkillDefinition(skill_id) orelse return &.{};

    frame.in_progress.insert(skill_id);
    const options = skill.aiOptions(
        caster_index,
        game_state,
        weapon_type_definitions,
        allocator,
        frame,
    );
    frame.in_progress.remove(skill_id);
    frame.results[@backingInt(skill_id)] = options;
    return options;
}

/// True when the two best-cast plans differ in any way - different skill,
/// different target, different rating, or one exists and the other
/// doesn't. The virtual-effect differential's improvement signal (see
/// helpers.bestCastsWithVirtualEffect): a difference means the simulated
/// modifier changed what the bar would cast.
pub fn plansDiffer(a: ?CastPlan, b: ?CastPlan) bool {
    if (a == null and b == null) return false;
    if (a == null or b == null) return true;
    const a_target = a.?.target;
    const b_target = b.?.target;
    if ((a_target == null) != (b_target == null)) return true;
    if (a_target != null and !std.meta.eql(a_target.?, b_target.?)) return true;
    return a.?.skill_id != b.?.skill_id or
        a.?.priority != b.?.priority;
}

/// Evaluate all the caster's off-cooldown skill slots and pick the best
/// cast per pool: partition by skill_type (weapon skill + spell =
/// turn-ending), skip 0-rated options, keep the strictly-best rating with
/// SLOT ORDER as the tiebreak (the first - leftmost - slot wins ties).
/// This is the exact selection `enemy_turn_attack` applies; enhancement
/// enchantments read the same result to rate themselves (best live
/// beneficiary + 1). Pass the frame the caller is being evaluated in -
/// consultations from inside an aiOptions share the frame, so the
/// caller's own options are cycle-cut and everything else is memoized.
pub fn bestCasts(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    frame: *EvalFrame,
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

        const options = optionsFor(frame, skill_id, caster_index, game_state, weapon_type_definitions, allocator);
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
