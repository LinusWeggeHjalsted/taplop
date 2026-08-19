const std = @import("std");
const events = @import("events.zig");
const Event = events.Event;

/// How prominently an event appears in the combat log. The projection keeps
/// every event whose tier is not `.none`; the UI uses the tier to decide where
/// to show it (top-bar recent icons are `.coarse`; the detailed log shows
/// `.coarse` + `.fine` interleaved chronologically).
pub const CombatLogTier = enum {
    none,
    coarse,
    fine,
};

/// Classify a single event into a combat-log tier. Pure, O(1), no state.
///
/// Coarse (top bar, last N): the actions a player takes and the outcomes that
/// matter at a glance — a voluntary move, a skill use, a death.
/// Fine (detailed log, interleaved with coarse): the consequences of an action
/// — damage dealt, stun/knockback/retreat, healing, effects gained/lost,
/// collisions, pickups, and forced moves (knockback/retreat-induced).
/// None: everything else — mechanic noise (highlights, clear, turn-phase,
/// aggro checks), gear toggles (swap_hands is player-only and spammable), and
/// anything not relevant to a combat readout.
pub fn combatLogTier(event: Event) CombatLogTier {
    return switch (event) {
        // --- coarse ---
        .level_event => |level_event| switch (level_event) {
            .move_entity => |move| if (move.is_forced) .fine else .coarse,
            .use_skill => .coarse,
            else => .none,
        },
        .sub_level_event => |sub| switch (sub) {
            .death => .coarse,
            // --- fine ---
            .attack => .fine,
            .stun => .fine,
            .knockback => .fine,
            .retreat => .fine,
            .heal => .fine,
            .create_effect => .fine,
            .end_effect => .fine,
            .collision => .fine,
            .pickup_items => .fine,
            else => .none,
        },

        // --- none ---
        .meta_event,
        .super_event,
        .editor_event,
        .sub_editor_event,
        .player_event,
        .hub_event,
        .replay_viewer_event,
        => .none,
    };
}

/// Project the combat log for the current level: a chronologically ordered
/// slice of the events whose tier is not `.none`, drawn from the current
/// level's span of `event_history` up to `current_event_index`.
///
/// `level_start_index` is the event index where the current level began (the
/// most recent `start_level` meta event's position, found by a backward scan
/// in the caller). `current_event_index` truncates the future, so undo within
/// the level shortens the log and crossing back to the hub (no enclosing
/// start_level in the prefix) shows nothing. Pure, O(level events), no state.
/// The returned slice is allocated in `arena` (the per-frame arena in view()).
pub fn projectCombatLog(
    event_history: []const Event,
    level_start_index: u32,
    current_event_index: u32,
    arena: std.mem.Allocator,
) []const Event {
    var filtered: std.ArrayList(Event) = .empty;
    const start: usize = @intCast(level_start_index);
    const end: usize = @intCast(@min(current_event_index, @as(u32, @intCast(event_history.len))));
    var index: usize = start;
    while (index < end) : (index += 1) {
        const event = event_history[index];
        if (combatLogTier(event) != .none) {
            filtered.append(arena, event) catch @panic("failed to append combat log entry");
        }
    }
    return filtered.toOwnedSlice(arena) catch @panic("failed to allocate combat log");
}

test "combatLogTier classifies the whitelist" {
    // Coarse tier.
    try std.testing.expectEqual(CombatLogTier.coarse, combatLogTier(.{
        .level_event = .{ .move_entity = .{ .entity_index = 0, .destination = .{ .x = 1, .y = 0 } } },
    }));
    try std.testing.expectEqual(CombatLogTier.coarse, combatLogTier(.{
        .level_event = .{ .use_skill = .{ .caster_index = 0, .skill_id = .slice, .target = null } },
    }));
    try std.testing.expectEqual(CombatLogTier.coarse, combatLogTier(.{
        .sub_level_event = .{ .death = .{ .entity_index = 1 } },
    }));

    // Forced move is fine (not coarse) — the knockback/retreat entry covers it.
    try std.testing.expectEqual(CombatLogTier.fine, combatLogTier(.{
        .level_event = .{ .move_entity = .{ .entity_index = 1, .destination = .{ .x = 2, .y = 0 }, .is_forced = true } },
    }));

    // Fine tier consequences.
    try std.testing.expectEqual(CombatLogTier.fine, combatLogTier(.{
        .sub_level_event = .{ .attack = .{ .attacker_index = 0, .defender_index = 1, .outgoing_damage = 5 } },
    }));
    try std.testing.expectEqual(CombatLogTier.fine, combatLogTier(.{
        .sub_level_event = .{ .stun = .{ .attacker_index = 0, .defender_index = 1, .stun_duration = 1 } },
    }));
    try std.testing.expectEqual(CombatLogTier.fine, combatLogTier(.{
        .sub_level_event = .{ .knockback = .{ .attacker_index = 0, .defender_index = 1, .distance = 2, .knockback_damage = 1 } },
    }));
    try std.testing.expectEqual(CombatLogTier.fine, combatLogTier(.{
        .sub_level_event = .{ .retreat = .{ .entity_index = 1, .target_position = .{ .x = 0, .y = 0 }, .distance = 1 } },
    }));
    try std.testing.expectEqual(CombatLogTier.fine, combatLogTier(.{
        .sub_level_event = .{ .heal = .{ .entity_index = 0, .amount = 3 } },
    }));
    try std.testing.expectEqual(CombatLogTier.fine, combatLogTier(.{
        .sub_level_event = .{ .create_effect = .{ .caster_index = 0, .receiver_index = 1, .effect_id = .reflect, .duration = 1 } },
    }));
    try std.testing.expectEqual(CombatLogTier.fine, combatLogTier(.{
        .sub_level_event = .{ .end_effect = .{ .entity_index = 1, .effect_id = .reflect } },
    }));
    try std.testing.expectEqual(CombatLogTier.fine, combatLogTier(.{
        .sub_level_event = .{ .collision = .{ .attacker_index = 0, .defender_index = 1, .damage = 1 } },
    }));
    try std.testing.expectEqual(CombatLogTier.fine, combatLogTier(.{
        .sub_level_event = .{ .pickup_items = .{ .entity_index = 0, .position = .{ .x = 1, .y = 0 } } },
    }));

    // None tier — mechanic noise and out-of-scope events.
    try std.testing.expectEqual(CombatLogTier.none, combatLogTier(.{
        .level_event = .{ .clear_highlights = {} },
    }));
    try std.testing.expectEqual(CombatLogTier.none, combatLogTier(.{
        .level_event = .{ .turn_start = .{ .entity_index = 0 } },
    }));
    try std.testing.expectEqual(CombatLogTier.none, combatLogTier(.{
        .sub_level_event = .{ .aggro_around = .{ .entity_index = 0 } },
    }));
    try std.testing.expectEqual(CombatLogTier.none, combatLogTier(.{
        .sub_level_event = .{ .pickup_around = .{ .entity_index = 0 } },
    }));
    try std.testing.expectEqual(CombatLogTier.none, combatLogTier(.{
        .player_event = .swap_hands,
    }));
    try std.testing.expectEqual(CombatLogTier.none, combatLogTier(.{
        .meta_event = .open_main_menu,
    }));
}

test "projectCombatLog filters to the level span and whitelist" {
    const arena = std.testing.allocator;
    // A synthetic stream: pre-level noise, a start_level marker, then a mix of
    // whitelisted and ignored events within the level.
    const stream = [_]Event{
        .{ .meta_event = .open_main_menu }, // 0: before level, none
        .{ .meta_event = .{ .start_level = .{ .mission_path = "m", .level_index = 0 } } }, // 1: level start
        .{ .level_event = .{ .clear_highlights = {} } }, // 2: none
        .{ .level_event = .{ .move_entity = .{ .entity_index = 0, .destination = .{ .x = 1, .y = 0 } } } }, // 3: coarse
        .{ .sub_level_event = .{ .attack = .{ .attacker_index = 0, .defender_index = 1, .outgoing_damage = 5 } } }, // 4: fine
        .{ .sub_level_event = .{ .death = .{ .entity_index = 1 } } }, // 5: coarse
        .{ .level_event = .{ .clear_highlights = {} } }, // 6: none
    };

    // levelStartEventIndex returns the index AFTER start_level (the first
    // in-level event), so the span starts at 2. current position 6 (the count
    // of processed events, so 6 excludes index 6 itself).
    const log = projectCombatLog(&stream, 2, 6, arena);
    defer arena.free(log);

    // Should be the three whitelisted events in order: move, attack, death.
    try std.testing.expectEqual(@as(usize, 3), log.len);
    try std.testing.expectEqualDeep(stream[3], log[0]);
    try std.testing.expectEqualDeep(stream[4], log[1]);
    try std.testing.expectEqualDeep(stream[5], log[2]);
}

test "projectCombatLog clamps current_event_index to the stream length" {
    const arena = std.testing.allocator;
    const stream = [_]Event{
        .{ .meta_event = .{ .start_level = .{ .mission_path = "m", .level_index = 0 } } }, // 0
        .{ .sub_level_event = .{ .death = .{ .entity_index = 1 } } }, // 1: coarse
    };
    // current_event_index past the end should not overflow.
    const log = projectCombatLog(&stream, 0, 999, arena);
    defer arena.free(log);
    try std.testing.expectEqual(@as(usize, 1), log.len);
    try std.testing.expectEqualDeep(stream[1], log[0]);
}

test "projectCombatLog empty span yields empty log" {
    const arena = std.testing.allocator;
    const stream = [_]Event{
        .{ .meta_event = .{ .start_level = .{ .mission_path = "m", .level_index = 0 } } },
    };
    const log = projectCombatLog(&stream, 1, 1, arena);
    // Empty slice — still must be freed.
    defer arena.free(log);
    try std.testing.expectEqual(@as(usize, 0), log.len);
}
