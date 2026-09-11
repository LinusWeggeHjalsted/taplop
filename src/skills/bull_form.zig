const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const skill_mod = @import("../skill.zig");
const helpers = @import("../skill_helpers.zig");
const ai_select = @import("../ai_select.zig");
const lookups = @import("../generated_lookups.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Bull Form: an enchantment. Grants the Bull Form
/// effect on the caster — knockback/retreat distance +10 for the duration.
/// Non-turn-ending (the enchantment pool's ratings only order the
/// non-ending skills).
pub const skill = Skill{
    .name = "Bull Form",
    .skill_type = .enchantment,
    .deals_damage = false,
    .description = "Increase distance by 10",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = 2,
    .stun_duration = null,
    .cooldown = 5,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-cast — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: rated against the LIVE beneficiaries of the +10 push
/// distance — the casts that will actually fire this turn and carry a
/// `distance` (knockback/retreat pushes travel farther, and the extra
/// distance can flip a collision: the base-value rule counts the planned
/// ending cast when it has the field, plus positive-rated non-ending
/// skills with it), MAX'd with the SIM DIFFERENTIAL (the bar re-evaluated
/// with the effect virtually applied — a push that would now collide
/// rates one higher; see helpers.simDifferentialGain). Rating = best + 1
/// (fires first in the chain). No live beneficiary and no differential →
/// NO cast, no fallback (pure modifiers). See DESIGN → Architecture, AI
/// rating scale.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    frame: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.bull_form) > 0) return &.{};

    var best_beneficiary: u32 = 0;

    // The real bar (this frame — bull form itself is cut by the in-progress
    // guard).
    const casts = ai_select.bestCasts(caster_index, game_state, weapon_type_definitions, allocator, frame);

    // Base-value rule: the planned ending cast if it carries a distance
    // (the +10 applies to its push).
    if (casts.ending) |plan| {
        if (lookups.getSkillDefinition(plan.skill_id)) |definition| {
            if (definition.distance != null and plan.priority > best_beneficiary) {
                best_beneficiary = plan.priority;
            }
        }
    }

    // ...plus every positive-rated non-ending skill with a distance (all
    // positive cantrips/enchantments fire this turn; ending skills fire
    // at most one, already counted via the plan).
    const slots = caster.collectSkillSlots(weapon_type_definitions);
    for (&slots) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) continue;
        const definition = lookups.getSkillDefinition(skill_id) orelse continue;
        if (definition.skill_type == .weapon_skill or definition.skill_type == .spell) continue;
        if (definition.distance == null) continue;
        const options = ai_select.optionsFor(frame, skill_id, caster_index, game_state, weapon_type_definitions, allocator);
        for (options) |option| {
            if (option.priority > best_beneficiary) best_beneficiary = option.priority;
        }
    }

    // Sim differential: with +10 distance a push that stops short of a
    // blocker would now collide (bash/slam's collision bonus flips).
    const sim_gain = helpers.simDifferentialGain(
        frame,
        .bull_form,
        .bull_form,
        caster_index,
        casts,
        game_state,
        weapon_type_definitions,
        allocator,
    );
    if (sim_gain > best_beneficiary) best_beneficiary = sim_gain;

    if (best_beneficiary == 0) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = best_beneficiary + 1 });
}

/// Self-cast — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: apply the effect to the caster for skill_duration turns.
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .create_effect = .{
            .caster_index = caster_index,
            .receiver_index = caster_index,
            .effect_id = .bull_form,
            .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
        } } },
    });
}
