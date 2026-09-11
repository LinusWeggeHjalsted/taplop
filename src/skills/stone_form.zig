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

/// Stone Form: an enchantment. Grants the Stone Form effect on the caster —
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

/// Self-cast — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: rated against the casts the outgoing-stun +1 would enhance
/// — the shared selection (ai_select): the planned ending cast if it
/// applies a stun, plus any positive-rated stun CANTRIP (none ship yet;
/// a future one slots in automatically). Rating = best such cast + 1, so
/// stone form fires BEFORE them in the chain (the +1 ordering rule — see
/// DESIGN → Architecture, AI rating scale). No live beneficiary → the
/// end-of-turn-heal fallback: one unit, gated below full health.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.stone_form) > 0) return &.{};

    var best_beneficiary: u32 = 0;

    // The planned turn-ending cast — counted only if it applies a stun
    // the outgoing-stun +1 would lengthen.
    if (ai_select.plannedEndingCast(caster_index, game_state, weapon_type_definitions, allocator)) |plan| {
        if (lookups.getSkillDefinition(plan.skill_id)) |definition| {
            if (definition.stun_duration != null and plan.priority > best_beneficiary) {
                best_beneficiary = plan.priority;
            }
        }
    }

    // Stun CANTRIP beneficiaries: every positive-rated cantrip fires
    // this turn, so each one's best option counts. Cantrips only (never
    // another enchantment — the one-way edge rule, ai_select.zig).
    const slots = caster.collectSkillSlots(weapon_type_definitions);
    for (&slots) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) continue;
        const definition = lookups.getSkillDefinition(skill_id) orelse continue;
        if (definition.skill_type != .cantrip) continue;
        if (definition.stun_duration == null) continue;
        const options = definition.aiOptions(caster_index, game_state, weapon_type_definitions, allocator);
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

/// Self-cast — no meaningful target.
/// Self-cast — fires immediately.
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
