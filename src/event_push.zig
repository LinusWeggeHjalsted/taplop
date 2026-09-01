//! Event-stack push utilities. `pushEvents` appends machinery events to
//! `GameState.event_stack` (LIFO — the last pushed processes first);
//! `pushPlayerAction` is the compile-time gate input handlers go through
//! (they may only push `PlayerInputEvent`s — the orchestrator convention,
//! see events.zig); `pushPlayerSkillUse` pushes the one player_use_skill
//! orchestrator. Kept apart from the handlers so input_handlers, main.zig,
//! the skill helpers, and the handler tests can push without importing the
//! whole dispatch.

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");

const Event = events.Event;
const Vector2 = types.Vector2;
const GameState = state.GameState;
const SkillId = types.SkillId;

/// Push the single orchestrator event for a player skill use. The handler
/// resolves whether the skill ends the turn (weapon_skill/spell) and composes
/// use_skill + clear_highlights + clear_prepared_skill (+ turn_end). Keeping
/// one event per action is what lets reconstruction derive idle points from
/// virtual stack depth (see reconstructFromEventLog in state.zig).
pub fn pushPlayerSkillUse(
    current: *GameState,
    skill_id: SkillId,
    target: ?Vector2,
    allocator: std.mem.Allocator,
) void {
    pushPlayerAction(current, .{ .player_use_skill = .{
        .skill_id = skill_id,
        .target = target,
    } }, allocator);
}

/// Push events onto the event stack. Events are processed from the back
/// (top of stack), so the last event pushed is processed first.
pub fn pushEvents(
    current: *GameState,
    new_events: []const Event,
    allocator: std.mem.Allocator,
) void {
    if (new_events.len == 0) return;

    if (current.event_stack.len == 0) {
        current.event_stack = allocator.dupe(
            Event,
            new_events,
        ) catch @panic("failed to allocate event stack");
        return;
    }

    const combined = allocator.alloc(
        Event,
        current.event_stack.len + new_events.len,
    ) catch @panic("failed to allocate event stack");

    @memcpy(combined[0..current.event_stack.len], current.event_stack);
    @memcpy(combined[current.event_stack.len..], new_events);
    current.event_stack = combined;
}

/// Push a player-input event (the ONLY kind input handlers may push — see
/// `PlayerInputEvent` in events.zig). This wrapper is the compile-time gate:
/// input handlers call this instead of `pushEvents`, so they can't push
/// machinery events. The handler for a `PlayerInputEvent` may push machinery
/// events as children via `pushEvents` (that's the orchestrator convention).
pub fn pushPlayerAction(
    current: *GameState,
    action: events.PlayerInputEvent,
    allocator: std.mem.Allocator,
) void {
    pushEvents(current, &.{.{ .player_input_event = action }}, allocator);
}
