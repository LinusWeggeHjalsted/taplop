const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const effect_mod = @import("../effect.zig");

const GameState = state.GameState;
const Event = events.Event;
const Effect = effect_mod.Effect;

/// Promise of Death: while active, when an opponent of the holder dies,
/// the holder resets EVERY ticking cooldown - the full sweep, including
/// off-bar preserved cooldowns (self-beneficial; the on-bar-only rule is
/// an Adrenaline Surge balance concern about enemy-side inherited
/// cooldowns driving damage, which cannot apply here) - and heals to full.
pub const effect = Effect{
    .name = "Promise of Death",
    .description = "Reset all cooldowns and gain full health if an enemy dies",
    .additive_effect_modifiers = .{},
    .effect_sprite = null,
    .on_opponent_death_fn = &onOpponentDeath,
};

/// The payday: reset every ticking cooldown (full sweep) + heal to full.
fn onOpponentDeath(
    entity_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Event {
    const level = game_state.level orelse return null;
    const holder = level.entities[entity_index];

    var effect_events: std.ArrayList(Event) = .empty;
    // Every int in 0..count is a valid SkillId tag (the generated enum is
    // hole-free), so a plain runtime loop covers the full map.
    const skill_id_count = std.meta.fields(types.SkillId).len;
    for (0..skill_id_count) |int_skill_id| {
        const skill_id: types.SkillId = @enumFromInt(int_skill_id);
        const current_cooldown = holder.skill_cooldowns.get(skill_id);
        if (current_cooldown == 0) continue;
        effect_events.append(allocator, .{ .sub_level_event = .{ .change_cooldown = .{
            .entity_index = entity_index,
            .skill_id = skill_id,
            .delta = -@as(i32, @intCast(current_cooldown)),
        } } }) catch @panic("failed to append promise reset");
    }

    if (holder.current_health < holder.getEffectiveMaxHealth()) {
        effect_events.append(allocator, .{ .sub_level_event = .{ .heal = .{
            .entity_index = entity_index,
            .amount = holder.getEffectiveMaxHealth(),
        } } }) catch @panic("failed to append promise heal");
    }

    if (effect_events.items.len == 0) return null;
    return effect_events.items;
}
