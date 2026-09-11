const effect_mod = @import("../effect.zig");

const Effect = effect_mod.Effect;

/// Bull Form: while active, increases knockback/retreat distance by 10
/// (additive modifier). No intercept/reactor hooks.
pub const effect = Effect{
    .name = "Bull Form",
    .description = "Increase distance by 10",
    .additive_effect_modifiers = .{
        .distance = 10,
    },
};
