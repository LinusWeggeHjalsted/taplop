const std = @import("std");
const state = @import("../state.zig");
const events = @import("../events.zig");
const effect_mod = @import("../effect.zig");

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
    .on_end_turn_fn = &onEndTurn,
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
