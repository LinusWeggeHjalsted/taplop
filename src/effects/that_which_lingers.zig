const effect_mod = @import("../effect.zig");

const Effect = effect_mod.Effect;

/// That Which Lingers: while active, increases all outgoing skill durations
/// by 1 (additive modifier). No intercept/reactor hooks.
pub const effect = Effect{
    .name = "That Which Lingers",
    .description = "Increase all skill durations by 1",
    .additive_effect_modifiers = .{
        .outgoing_skill_duration = 1,
    },
    .intercept_incoming_damage_fn = effect_mod.pass_incoming_damage,
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
