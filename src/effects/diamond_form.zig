const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const effect_mod = @import("effect.zig");

const GameState = state.GameState;
const Event = events.Event;
const Effect = effect_mod.Effect;
const DamageInterception = effect_mod.DamageInterception;

/// Diamond Form: while active, the holder is invulnerable — all incoming
/// ATTACK damage is prevented (interceptor; collision damage still lands,
/// the deliberate attack-only interceptor rule — see DESIGN →
/// Architecture) — and the holder heals 10% of max health at the end of
/// each turn. The skill stunned the holder for the same duration, so the
/// turns pass without actions while the heal climbs.
pub const effect = Effect{
    .name = "Diamond Form",
    .description = "Become invulnerable and heal 10% of max health at end of turn",
    .additive_effect_modifiers = .{},
    .effect_sprite = null,
    .intercept_incoming_damage_fn = &interceptIncomingDamage,
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

/// Invulnerable: all incoming attack damage is prevented.
fn interceptIncomingDamage(
    _: u32,
    _: u32,
    _: u32,
    _: GameState,
    _: std.mem.Allocator,
) DamageInterception {
    return .{ .damage = 0 };
}

/// Heal 10% of max health at end of turn (heal handler clamps to max).
/// Fires even while the holder is stunned — a stunned entity's turn still
/// cycles turn_start/turn_end, only the actions are skipped.
fn onEndTurn(
    entity_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Event {
    const level = game_state.level orelse return null;
    const entity = level.entities[entity_index];
    const heal_amount = entity.getEffectiveMaxHealth() / 10;
    if (heal_amount == 0) return null;

    return allocator.dupe(Event, &.{
        .{ .sub_level_event = .{ .heal = .{
            .entity_index = entity_index,
            .amount = heal_amount,
        } } },
    }) catch @panic("failed to allocate diamond form heal");
}
