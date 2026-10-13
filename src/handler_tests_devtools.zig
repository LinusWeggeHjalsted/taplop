//! Dev-tools handler tests. Currently covers `skip_level` (ctrl+Enter): the
//! idle input handler pushes `end_level` with the default continuation when
//! in a level + a dev build. The dev-mode gate is a comptime build option
//! (`@import("build_info").dev_mode`, defaulted to `optimize == .Debug`), so
//! the test build (Debug) has the gate open and exercises the live path; the
//! no-op-in-release path is the same branch with the comptime condition
//! inverted, not separately tested. See AGENTS → Dev Tools + DESIGN → Input.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const events = @import("events.zig");
const input = @import("input.zig");
const input_handlers = @import("input_handlers.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;
const Vector2 = types.Vector2;

const three_by_three = [_]Vector2{
    .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
    .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
    .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 },
};

test "skip_level idle input pushes end_level in a level (dev build)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    runToIdle(&history);

    // Stack starts empty (handleIdleInput only runs when idle).
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    input_handlers.handleIdleInput(&history, .{ .skip_level = true }, null, .{});

    // player_skip_level (the orchestrator) is on top of the event stack.
    // Its handler will push end_level as a child when processed.
    try testing.expect(history.current_state.event_stack.len > 0);
    const top = history.current_state.event_stack[history.current_state.event_stack.len - 1];
    try testing.expectEqual(@as(std.meta.Tag(events.Event), .player_input_event), std.meta.activeTag(top));
    try testing.expectEqual(@as(std.meta.Tag(events.PlayerInputEvent), .player_skip_level), std.meta.activeTag(top.player_input_event));
}

test "skip_level does not fire on the main menu (level-only gate)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null); // default main-menu start state
    runToIdle(&history);

    input_handlers.handleIdleInput(&history, .{ .skip_level = true }, null, .{});

    // No end_level pushed — skip_level is gated to the level screen.
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}
