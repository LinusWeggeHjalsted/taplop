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

/// That Which Reaches: an enchantment. Grants the That Which Reaches
/// effect on the caster — range and radius +1 for the duration.
/// Non-turn-ending (the enchantment pool's ratings only order the
/// non-ending skills).
pub const skill = Skill{
    .name = "That Which Reaches",
    .skill_type = .enchantment,
    .deals_damage = false,
    .description = "Increase range and radius by 1",
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

/// AI options: rated against the LIVE beneficiaries of the +1 range/radius
/// — the casts that will actually fire this turn and carry a range or
/// radius (the base-value rule: the planned ending cast when it has the
/// field, plus positive-rated non-ending skills with it — the +1 applies
/// to whatever they cast), MAX'd with the SIM DIFFERENTIAL: the bar
/// re-evaluated with the effect virtually applied
/// (helpers.bestCastsWithVirtualEffect) — any plan difference (an
/// enabled out-of-range cast, a better cast, a different target) is the
/// +1's doing, and the would-be cast's rating counts as a beneficiary.
/// Rating = best + 1 (fires first in the chain). No live beneficiary and
/// no differential → NO cast, no fallback (pure modifiers, nothing to
/// enhance). See DESIGN → Architecture, AI rating scale.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    frame: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.that_which_reaches) > 0) return &.{};

    var best_beneficiary: u32 = 0;

    // The real bar (this frame — reaches itself is cut by the in-progress
    // guard).
    const casts = ai_select.bestCasts(caster_index, game_state, weapon_type_definitions, allocator, frame);

    // Base-value rule: the planned ending cast if it carries a range or
    // radius (the +1 applies to it).
    if (casts.ending) |plan| {
        if (lookups.getSkillDefinition(plan.skill_id)) |definition| {
            if ((definition.range != null or definition.radius != null) and plan.priority > best_beneficiary) {
                best_beneficiary = plan.priority;
            }
        }
    }

    // ...plus every positive-rated non-ending skill with a range or radius
    // (all positive cantrips/enchantments fire this turn, so each one's
    // best option counts; ending skills fire at most one, already counted
    // via the plan).
    const slots = caster.collectSkillSlots(weapon_type_definitions);
    for (&slots) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) continue;
        const definition = lookups.getSkillDefinition(skill_id) orelse continue;
        if (definition.skill_type == .weapon_skill or definition.skill_type == .spell) continue;
        if (definition.range == null and definition.radius == null) continue;
        const options = ai_select.optionsFor(frame, skill_id, caster_index, game_state, weapon_type_definitions, allocator);
        for (options) |option| {
            if (option.priority > best_beneficiary) best_beneficiary = option.priority;
        }
    }

    // Sim differential: the bar WITH the effect virtually applied. Any
    // plan difference is the +1's doing — the would-be cast (enabled,
    // upgraded, or re-targeted) is a live beneficiary at its rating.
    const sim_gain = helpers.simDifferentialGain(
        frame,
        .that_which_reaches,
        .that_which_reaches,
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
            .effect_id = .that_which_reaches,
            .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
        } } },
    });
}
