//! Event-stack push utilities. `pushEvents` appends machinery events to
//! `GameState.event_stack` (LIFO - the last pushed processes first);
//! `pushPlayerAction` is the compile-time gate input handlers go through
//! (they may only push `PlayerInputEvent`s - the orchestrator convention,
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

/// Whether a batch contains a player_input orchestrator - the bool core
/// of the machinery-only funnel gate below (the no-expectPanics
/// convention: the panic layer is thin, this is what tests pin).
pub fn batchContainsPlayerAction(new_events: []const Event) bool {
    for (new_events) |event| {
        if (event == .player_input_event) return true;
    }
    return false;
}

/// Push events onto the event stack. Events are processed from the back
/// (top of stack), so the last event pushed is processed first.
///
/// THE MACHINERY-ONLY FUNNEL: a handler pushing a player_input
/// orchestrator as a cascade child strands it on the replay stack -
/// replay seeds every recorded player_input event as input-origin
/// (drained seed or mid-drain LIFO), so a handler-pushed copy never
/// pops and every state past it reconstructs as mid-cascade (the
/// undo-mangle crash's root cause - see DONE.md). Fail fast here
/// instead: player actions enter the stack only through
/// `pushPlayerAction` (the input channel; its ONE sanctioned
/// handler-side use is meta.zig's restart_mission re-entry - the
/// validation-replay slice rule). See DESIGN → Architecture
/// (orchestrator convention).
pub fn pushEvents(
    current: *GameState,
    new_events: []const Event,
    allocator: std.mem.Allocator,
) void {
    if (new_events.len == 0) return;

    if (batchContainsPlayerAction(new_events)) {
        @panic("pushEvents: a player_input orchestrator pushed through the machinery funnel - player actions enter the stack only via pushPlayerAction (see DESIGN -> Architecture, orchestrator convention)");
    }

    appendToStack(current, new_events, allocator);
}

/// The shared stack-append core both funnels ride (LIFO - the last
/// pushed is processed first).
fn appendToStack(
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

/// Push a player-input event (the ONLY kind input handlers may push - see
/// `PlayerInputEvent` in events.zig). This wrapper is the input channel:
/// input handlers call this instead of `pushEvents`, so they can't push
/// machinery events, and the handler for a `PlayerInputEvent` may push
/// machinery events as children via `pushEvents` (that's the orchestrator
/// convention). The ONE sanctioned handler-side use is meta.zig's
/// restart_mission re-entry (the validation-replay slice rule - the recorded
/// stream must begin each attempt at a seedable top-level player action).
pub fn pushPlayerAction(
    current: *GameState,
    action: events.PlayerInputEvent,
    allocator: std.mem.Allocator,
) void {
    appendToStack(current, &.{.{ .player_input_event = action }}, allocator);
}

test "batchContainsPlayerAction: the machinery-funnel gate core" {
    // The undo-mangle class in miniature: a machinery batch is clean, a
    // batch carrying a player_input orchestrator trips the gate.
    const machinery_only = [_]Event{
        .{ .level_event = .clear_highlights },
        .{ .level_event = .{ .use_skill = .{
            .caster_index = 0,
            .skill_id = .stab,
            .target = null,
        } } },
    };
    try std.testing.expect(!batchContainsPlayerAction(&machinery_only));

    const with_orchestrator = [_]Event{
        .{ .level_event = .clear_highlights },
        .{ .player_input_event = .{ .player_use_skill = .{
            .skill_id = .stab,
            .target = null,
        } } },
    };
    try std.testing.expect(batchContainsPlayerAction(&with_orchestrator));
}
