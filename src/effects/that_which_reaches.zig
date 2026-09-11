const effect_mod = @import("../effect.zig");

const Effect = effect_mod.Effect;

/// That Which Reaches: while active, increases range and radius by 1
/// (additive modifiers). No intercept/reactor hooks.
pub const effect = Effect{
    .name = "That Which Reaches",
    .description = "Increase range and radius by 1",
    .additive_effect_modifiers = .{
        .range = 1,
        .radius = 1,
    },
};
