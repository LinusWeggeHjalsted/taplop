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
};
