const effect_mod = @import("../effect.zig");

const Effect = effect_mod.Effect;

/// That Which Rushes: while active, reduces cooldowns of used skills by 1
/// (the cooldown modifier applies where cooldowns are set, in use_skill)
/// and increases speed by 1 (both additive modifiers).
pub const effect = Effect{
    .name = "That Which Rushes",
    .description = "Reduce cooldowns of used skills by 1 and increase speed by 1",
    .additive_effect_modifiers = .{
        .cooldown = -1,
        .speed = 1,
    },
};
