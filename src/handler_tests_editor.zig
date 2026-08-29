//! Editor handler tests. Covers the editor input path — level-tab clicks
//! (`player_set_editor_level` → `editor_set_active_level`), which ride the
//! undo timeline like every GameState mutation. The framing-event round
//! trip (open → playtest → end → close against the real beginnings
//! mission) lives in main.zig. See DESIGN → Architecture → Level Editor.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const event_handlers = @import("event_handlers.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;

/// A minimal editor-screen starting state with `level_count` empty levels.
fn editorStartingState(levels: []const types.EditorLevel) state.GameState {
    return .{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = levels },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
}

test "player_set_editor_level: switches the active level, undo reverts" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{ .{}, .{}, .{} };
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.active_level_index);

    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .player_input_event = .{ .player_set_editor_level = .{ .level_index = 2 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(@as(usize, 2), history.current_state.editor.?.active_level_index);

    // The switch rides the undo timeline (the Editor is part of GameState,
    // captured by snapshots) — undo walks back to level 0.
    try testing.expect(history.undo(event_handlers.processEvent));
    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.active_level_index);
}

test "player_set_editor_level: out-of-range index is a no-op (handler guard)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{ .{} };
    var history = harness.newHistory(editorStartingState(&levels));
    runToIdle(&history);

    // The inline editor_set_active_level handler guards the range (an
    // out-of-range index leaves active_level_index unchanged).
    event_handlers.pushEvents(
        &history.current_state,
        &.{.{ .editor_event = .{ .editor_set_active_level = .{ .level_index = 9 } } }},
        history.current_arena.allocator(),
    );
    runToIdle(&history);

    try testing.expectEqual(@as(usize, 0), history.current_state.editor.?.active_level_index);
}
