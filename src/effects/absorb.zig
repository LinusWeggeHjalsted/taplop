const std = @import("std");
const state = @import("../state.zig");
const events = @import("../events.zig");
const effect_mod = @import("effect.zig");

const GameState = state.GameState;
const Event = events.Event;
const Effect = effect_mod.Effect;
const DamageInterception = effect_mod.DamageInterception;

/// Absorb: while active, incoming attack damage is converted to healing —
/// the interceptor zeroes the damage and heals the receiver for the
/// pre-defense amount (the same stage and amount Reflect reflects back; the
/// heal handler clamps to max). Like every interceptor, ATTACK-only —
/// collision damage bypasses it (the deliberate Reflect counterplay rule,
/// DESIGN → Architecture).
pub const effect = Effect{
    .name = "Absorb",
    .description = "Incoming attack damage is converted to healing",
    .additive_effect_modifiers = .{},
    .effect_sprite = null,
    .intercept_incoming_damage_fn = &interceptIncomingDamage,
    .on_effect_creation_fn = effect_mod.no_op,
    .on_effect_end_fn = effect_mod.no_op,
    .on_start_turn_fn = effect_mod.no_op,
    .on_end_turn_fn = effect_mod.no_op,
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

/// Zero the damage and heal the receiver for the intercepted amount. A
/// zero-damage hit converts to nothing (no heal event).
fn interceptIncomingDamage(
    receiver_index: u32,
    _: u32,
    incoming_damage: u32,
    _: GameState,
    allocator: std.mem.Allocator,
) DamageInterception {
    if (incoming_damage == 0) return .{ .damage = 0 };

    const heals = allocator.dupe(Event, &.{
        .{ .sub_level_event = .{ .heal = .{
            .entity_index = receiver_index,
            .amount = incoming_damage,
        } } },
    }) catch @panic("failed to allocate absorb heal");

    return .{ .damage = 0, .events = heals };
}
