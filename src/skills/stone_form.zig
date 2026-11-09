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

/// Stone Form: an enchantment. Grants the Stone Form effect on the caster -
/// reduced incoming stun, increased outgoing stun, and an end-of-turn heal.
/// Non-turn-ending.
pub const skill = Skill{
    .name = "Stone Form",
    .skill_type = .enchantment,
    .deals_damage = false,
    .description = "Reduce incoming stun durations by 1, increase outgoing stun durations by 1, and heal 20% of max health at end of turn",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = 5,
    .stun_duration = null,
    .cooldown = 10,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-cast - no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: rated against the casts the outgoing-stun +1 would enhance
/// - the LIVE beneficiaries (casts that will actually fire this turn):
/// the planned ending cast if it applies a stun, plus any off-cooldown
/// NON-ENDING skill with a stun duration offering a positive cast (all
/// positive cantrips/enchantments fire this turn; a future stun cantrip
/// or stun enchantment slots in automatically). Everything evaluates
/// through the shared frame (ai_select.optionsFor - self cut, memoized).
/// Rating = best such cast + 1, so stone form fires BEFORE them in the
/// chain (the +1 ordering rule - see DESIGN → Architecture, AI rating
/// scale). No live beneficiary → the end-of-turn-heal fallback: one unit,
/// gated below full health.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    frame: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.stone_form) > 0) return &.{};

    var best_beneficiary: u32 = 0;

    // The planned turn-ending cast - the ONLY ending skill that fires this
    // turn, so the only one a stun enhancement can ride. Counted only if
    // it applies a stun the outgoing-stun +1 would lengthen.
    const casts = ai_select.bestCasts(caster_index, game_state, weapon_type_definitions, allocator, frame);
    if (casts.ending) |plan| {
        if (lookups.getSkillDefinition(plan.skill_id)) |definition| {
            if (definition.stun_duration != null and plan.priority > best_beneficiary) {
                best_beneficiary = plan.priority;
            }
        }
    }

    // Non-ending beneficiaries (cantrips + enchantments): every
    // positive-rated one fires this turn, so each one's best option
    // counts. Ending skills are excluded here - they fire at most one,
    // already counted above via the plan.
    const slots = caster.collectSkillSlots(weapon_type_definitions);
    for (&slots) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) continue;
        const definition = lookups.getSkillDefinition(skill_id) orelse continue;
        if (definition.skill_type == .weapon_skill or definition.skill_type == .spell) continue;
        if (definition.stun_duration == null) continue;
        const options = ai_select.optionsFor(frame, skill_id, caster_index, game_state, weapon_type_definitions, allocator);
        for (options) |option| {
            if (option.priority > best_beneficiary) best_beneficiary = option.priority;
        }
    }

    if (best_beneficiary > 0) {
        return helpers.singleOption(allocator, .{ .target = null, .priority = best_beneficiary + 1 });
    }

    // Fallback: the 20%-max end-of-turn heal over the effect's duration.
    if (caster.current_health >= caster.getEffectiveMaxHealth()) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = 1 });
}

/// Self-cast - fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: apply the Stone Form effect to the caster for skill_duration turns.
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
            .effect_id = .stone_form,
            .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
        } } },
    });
}
