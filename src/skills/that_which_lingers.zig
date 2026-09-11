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

// Re-export effect definition from effects directory
pub const effect = @import("../effects/that_which_lingers.zig").effect;

// --- Skill interface ---

/// That Which Lingers: an enchantment that applies the matching effect
/// (all outgoing skill durations +1). No targeting.
pub const skill = Skill{
    .name = "That Which Lingers",
    .skill_type = .enchantment,
    .deals_damage = false,
    .description = "Increase all skill durations by 1",
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

/// Self-cast — no targeting needed.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: rated against the casts the +1 outgoing-duration modifier
/// would enhance — the LIVE beneficiaries (casts that will actually fire
/// this turn and apply a duration): the planned ending cast if it carries
/// a `skill_duration`, plus any off-cooldown NON-ending skill with a
/// `skill_duration` offering a positive cast (all positive
/// cantrips/enchantments fire this turn; a future duration cantrip or
/// curse slots in automatically). Everything evaluates through the shared
/// frame (ai_select.optionsFor — lingers itself is cut by the
/// in-progress guard, mechanically excluded from its own scan). Rating =
/// best such cast + 1, so lingers fires BEFORE them in the chain (the +1
/// ordering rule — see DESIGN → Architecture, AI rating scale). No live
/// beneficiary → NO cast, no fallback: lingers extends nothing on its
/// own (its own recast is outside its 2-turn window, cd 5 > duration 2).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    frame: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.that_which_lingers) > 0) return &.{};

    var best_beneficiary: u32 = 0;

    // The planned turn-ending cast — the only ending skill that fires
    // this turn. Counted only if it applies a duration the +1 lengthens.
    const casts = ai_select.bestCasts(caster_index, game_state, weapon_type_definitions, allocator, frame);
    if (casts.ending) |plan| {
        if (lookups.getSkillDefinition(plan.skill_id)) |definition| {
            if (definition.skill_duration != null and plan.priority > best_beneficiary) {
                best_beneficiary = plan.priority;
            }
        }
    }

    // Non-ending beneficiaries (cantrips + enchantments): every
    // positive-rated one fires this turn, so each one's best option
    // counts. Ending skills are excluded — at most one fires, already
    // counted above via the plan.
    const slots = caster.collectSkillSlots(weapon_type_definitions);
    for (&slots) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) continue;
        const definition = lookups.getSkillDefinition(skill_id) orelse continue;
        if (definition.skill_type == .weapon_skill or definition.skill_type == .spell) continue;
        if (definition.skill_duration == null) continue;
        const options = ai_select.optionsFor(frame, skill_id, caster_index, game_state, weapon_type_definitions, allocator);
        for (options) |option| {
            if (option.priority > best_beneficiary) best_beneficiary = option.priority;
        }
    }

    if (best_beneficiary == 0) return &.{};
    return helpers.singleOption(allocator, .{ .target = caster.position, .priority = best_beneficiary + 1 });
}

/// Self-cast — target is the caster's own position.
/// Self-cast enchantment — no tile highlighting, just push the effect creation.
fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    _ = allocator;
    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];

    return .{ .sub_level_event = .{ .create_effect = .{
        .caster_index = caster_index,
        .receiver_index = caster_index,
        .effect_id = .that_which_lingers,
        .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
    } } };
}

/// Push the create_effect event on the caster.
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    _: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    return &.{.{ .sub_level_event = .{ .create_effect = .{
        .caster_index = caster_index,
        .receiver_index = caster_index,
        .effect_id = .that_which_lingers,
        .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
    } } }};
}
