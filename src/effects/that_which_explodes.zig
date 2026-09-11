const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const functions = @import("../functions.zig");
const effect_mod = @import("../effect.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Effect = effect_mod.Effect;

/// That Which Explodes: while active, when the holder is dealt attack
/// damage, the holder attacks every hostile within its EFFECTIVE radius
/// (base 1, effects carry no per-skill config) for 1x effective SPELL
/// damage (utility-skill damage rule — see DESIGN → Architecture).
pub const effect = Effect{
    .name = "That Which Explodes",
    .description = "Attack each enemy within radius when dealt damage",
    .additive_effect_modifiers = .{},
    .effect_sprite = null,
    .on_incoming_damage_fn = &onIncomingDamage,
};

/// Explode: attack each hostile within the holder's effective radius
/// (base 1) of the holder. Fires from the attack handler's
/// on_incoming_damage stage (only when damage was actually applied and
/// effects trigger).
fn onIncomingDamage(
    entity_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Event {
    const level = game_state.level orelse return null;
    const holder = level.entities[entity_index];

    const radius: i32 = @intCast(holder.getEffectiveRadius(1));
    const damage = holder.getEffectiveSpellDamage();

    var effect_events: std.ArrayList(Event) = .empty;
    for (level.entities, 0..) |entity, other_index| {
        if (other_index == entity_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == holder.team) continue;
        if (functions.chebyshevDistance(holder.position, entity.position) > radius) continue;
        effect_events.append(allocator, .{ .sub_level_event = .{ .attack = .{
            .attacker_index = entity_index,
            .defender_index = @intCast(other_index),
            .outgoing_damage = damage,
        } } }) catch @panic("failed to append explosion attack");
    }

    if (effect_events.items.len == 0) return null;
    return effect_events.items;
}
