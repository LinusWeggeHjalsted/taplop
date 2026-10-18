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

/// That Which Rushes: an enchantment. Grants the That Which Rushes
/// effect on the caster - cooldown -1 and speed +1 for the duration.
/// Non-turn-ending (the enchantment pool's ratings only order the
/// non-ending skills).
pub const skill = Skill{
    .name = "That Which Rushes",
    .skill_type = .enchantment,
    .deals_damage = false,
    .description = "Reduce cooldowns of used skills by 1 and increase speed by 1",
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

/// Self-cast - no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: rated against the LIVE beneficiaries of the cooldown −1 -
/// the casts that will actually fire this turn AND have a cooldown > 0
/// (the modifier applies where cooldowns are set, in use_skill: each such
/// cast's newly-set cooldown comes out one less): the planned ending
/// cast when it carries a cooldown, plus every positive-rated off-cd
/// non-ending skill with one (all positive cantrips/enchantments fire
/// this turn). The speed +1 is a future-turn rider (the movement phase
/// already ran) and never a standalone reason to cast - NO fallback: the
/// speed bonus is not worth a full turn's duration on its own. Rating =
/// best such cast + 1 (fires first in the chain). See DESIGN →
/// Architecture, AI rating scale.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    frame: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.that_which_rushes) > 0) return &.{};

    var best_beneficiary: u32 = 0;

    // The planned turn-ending cast - the only ending skill that fires
    // this turn. Counted only if its cooldown will actually tick down.
    const casts = ai_select.bestCasts(caster_index, game_state, weapon_type_definitions, allocator, frame);
    if (casts.ending) |plan| {
        if (lookups.getSkillDefinition(plan.skill_id)) |definition| {
            if (definition.cooldown != null and definition.cooldown.? > 0 and plan.priority > best_beneficiary) {
                best_beneficiary = plan.priority;
            }
        }
    }

    // Non-ending beneficiaries: every positive-rated one fires this
    // turn, so each one's best option counts; ending skills fire at most
    // one, already counted via the plan. A cooldown of 0 (or none) gains
    // nothing from the −1.
    const slots = caster.collectSkillSlots(weapon_type_definitions);
    for (&slots) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) continue;
        const definition = lookups.getSkillDefinition(skill_id) orelse continue;
        if (definition.skill_type == .weapon_skill or definition.skill_type == .spell) continue;
        if (definition.cooldown == null or definition.cooldown.? == 0) continue;
        const options = ai_select.optionsFor(frame, skill_id, caster_index, game_state, weapon_type_definitions, allocator);
        for (options) |option| {
            if (option.priority > best_beneficiary) best_beneficiary = option.priority;
        }
    }

    if (best_beneficiary == 0) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = best_beneficiary + 1 });
}

/// Self-cast - fires immediately.
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
            .effect_id = .that_which_rushes,
            .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
        } } },
    });
}
