const std = @import("std");
const state = @import("../state.zig");
const events = @import("../events.zig");
const effect_mod = @import("../effect.zig");

const GameState = state.GameState;
const Event = events.Event;
const Effect = effect_mod.Effect;
const DamageInterception = effect_mod.DamageInterception;

/// Reflect: while active, incoming damage is prevented and dealt back to the
/// attacker. Implemented as a damage interceptor (transform stage): it zeroes
/// the damage to the receiver and emits an attack back at the attacker.
pub const effect = Effect{
    .name = "Reflect",
    .description = "Incoming attack damage is prevented and dealt to the attacker",
    .additive_effect_modifiers = .{},
    .effect_sprite = "reflect",
    .intercept_incoming_damage_fn = &interceptIncomingDamage,
};

/// Prevent the damage (return 0) and reflect it back to the attacker. The
/// reflected attack has triggers_effects = false, so it skips the interception
/// fold and other effect callbacks - preventing reflect-vs-reflect loops
/// (mirrors Unity's isReflected flag).
fn interceptIncomingDamage(
    receiver_index: u32,
    attacker_index: u32,
    incoming_damage: u32,
    _: GameState,
    allocator: std.mem.Allocator,
) DamageInterception {
    if (incoming_damage == 0) return .{ .damage = 0 };

    const reflected = allocator.dupe(Event, &.{
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = receiver_index,
            .defender_index = attacker_index,
            .outgoing_damage = incoming_damage,
            .triggers_effects = false,
        } } },
    }) catch @panic("failed to allocate reflected attack");

    return .{ .damage = 0, .events = reflected };
}
