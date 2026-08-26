const std = @import("std");
const state = @import("../state.zig");
const events = @import("../events.zig");
const effect_mod = @import("effect.zig");

const GameState = state.GameState;
const Event = events.Event;
const Effect = effect_mod.Effect;

/// Stone Form: reduces incoming stun durations by 1, increases outgoing stun
/// durations by 1 (both via additive modifiers), and heals 20% of max health
/// at the end of each turn.
pub const effect = Effect{
    .name = "Stone Form",
    .description = "Reduce incoming stun durations by 1, increase outgoing stun durations by 1, and heal 20% of max health at end of turn",
    .additive_effect_modifiers = .{
        .outgoing_stun_duration = 1,
        .incoming_stun_duration = -1,
    },
    .intercept_incoming_damage_fn = effect_mod.pass_incoming_damage,
    .on_effect_creation_fn = effect_mod.no_op,
    .on_effect_end_fn = effect_mod.no_op,
    .on_start_turn_fn = effect_mod.no_op,
    .on_end_turn_fn = &onEndTurn,
    .on_attack_fn = effect_mod.no_op,
    .on_outgoing_damage_fn = effect_mod.no_op,
    .on_incoming_damage_fn = effect_mod.no_op,
    .on_outgoing_stun_fn = effect_mod.no_op,
    .on_incoming_stun_fn = effect_mod.no_op,
    .on_outgoing_effect_fn = effect_mod.no_op,
    .on_incoming_effect_fn = effect_mod.no_op,
    .on_outgoing_knockback_fn = effect_mod.no_op,
    .on_incoming_knockback_fn = effect_mod.no_op,
    .on_outgoing_collision_fn = effect_mod.no_op,
    .on_incoming_collision_fn = effect_mod.no_op,
    .on_retreat_fn = effect_mod.no_op,
    .on_opponent_death_fn = effect_mod.no_op,
};

/// Heal 20% of max health at end of turn (heal handler clamps to max).
fn onEndTurn(
    entity_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Event {
    const level = game_state.level orelse return null;
    const entity = level.entities[entity_index];
    const heal_amount = entity.getEffectiveMaxHealth() / 5;
    if (heal_amount == 0) return null;

    return allocator.dupe(Event, &.{
        .{ .sub_level_event = .{ .heal = .{
            .entity_index = entity_index,
            .amount = heal_amount,
        } } },
    }) catch @panic("failed to allocate stone form heal");
}
