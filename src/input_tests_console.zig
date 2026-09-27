//! Console-input regression pins (DESIGN → Input → Console input): the
//! placement-class bugs the headless suite could not see before the console
//! channel existed, driven end-to-end at the handler level — a parsed
//! console command merged into a frame's PlatformInput, through
//! `translateInput`, into the consumption layer (`handleAnytimeInput`).
//! These pin the classes the design calls out: the dead-Escape class
//! (`press Escape` must close the options menu) and the
//! wheel-after-the-gate class (`scroll 1` with the options menu open must
//! move the keybind tab's scroll offset).

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const console = @import("console.zig");
const input_handlers = @import("input_handlers.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;

const three_by_three = [_]types.Vector2{
    .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
    .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
    .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 },
};

const game_contexts: types.BindingContextSet = .{ .anytime = true, .game = true };

/// Whether `id` is in the input state's held-keys array (a local mirror of
/// InputState's private isHeld — the assertion needs the fact, not the
/// helper).
fn keyHeld(input_state: *const input.InputState, id: []const u8) bool {
    for (input_state.keys_held) |slot| {
        if (slot) |held_id| {
            if (std.mem.eql(u8, held_id, id)) return true;
        }
    }
    return false;
}

/// One frame's console-driven input: parse a script of commands, run them
/// one per frame (the live drain's cadence) against `history`, returning the
/// LAST frame's PlayerInput. Mirrors frame()'s seam order: poll (empty
/// backend input) → applyFrameCommand → translateInput → fold injected
/// actions. `arena` backs the merged bytes (the live seam's frame arena —
/// not testing.allocator, whose leak check would fire on the merges).
fn runConsoleScript(
    history: *state.GameStateHistory,
    input_state: *input.InputState,
    arena: std.mem.Allocator,
    script: []const []const u8,
) input.PlayerInput {
    var result: input.PlayerInput = .{};
    for (script) |line| {
        var queue: console.ConsoleQueue = .{};
        queue.push(console.parseCommandLine(line).command);
        const backend_input = input.PlatformInput{
            .events = &.{},
            .viewport = .{ .width = types.reference_width, .height = types.reference_height },
        };
        const platform_input = console.applyFrameCommand(
            &queue,
            backend_input,
            arena,
            history,
        );
        result = input.translateInput(
            platform_input,
            input_state,
            history.settings,
            .{ .position = .{ .x = 0, .y = 0 } },
            0,
            null,
            null,
            game_contexts,
        );
        console.foldInjectedActions(&result, platform_input);
    }
    return result;
}

test "console press Escape closes the options menu (merge → translate → handler)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    history.session.ui_state.options_menu_open = true;

    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(&history, &input_state, backing.allocator(), &.{"press Escape"});

    // The merged key edge rode the full pipeline: a held-state Escape press
    // whose binding translated to the escape action.
    try testing.expect(keyHeld(&input_state, "Escape"));
    try testing.expect(player_input.anytime.escape);

    // And the handler layer closed the menu — the dead-Escape class pinned.
    input_handlers.handleAnytimeInput(
        &history,
        player_input.anytime,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expect(!history.session.ui_state.options_menu_open);
}

test "console scroll with the options menu open moves the keybind scroll offset" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    // The in-game settings stack: the settings overlay over the options
    // menu, keybinds tab scrolled down a few rows.
    history.session.ui_state.options_menu_open = true;
    history.session.ui_state.settings_open = true;
    history.session.ui_state.settings_tab = .keybinds;
    history.session.ui_state.keybind_scroll_offset = 4;

    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(&history, &input_state, backing.allocator(), &.{"scroll 1"});

    // One wheel notch up = one row earlier (the row-scroll convention).
    try testing.expectEqual(@as(f32, 1), player_input.anytime.scroll_delta);
    input_handlers.handleAnytimeInput(
        &history,
        player_input.anytime,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expectEqual(@as(i32, 3), history.session.ui_state.keybind_scroll_offset);
}

test "console action escape closes the options menu (the button seam)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    history.session.ui_state.options_menu_open = true;

    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(&history, &input_state, backing.allocator(), &.{"action escape"});

    // applyAction folded the action directly (no binding consulted)...
    try testing.expect(player_input.anytime.escape);
    // ...and the handler layer consumed it.
    input_handlers.handleAnytimeInput(
        &history,
        player_input.anytime,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expect(!history.session.ui_state.options_menu_open);
}

test "console chords work across frames (held-state supplies the modifier)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    // press ControlLeft on one frame, press KeyQ on the next: the held
    // modifier persists across frames, exactly like a human pressing across
    // a frame boundary.
    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(
        &history,
        &input_state,
        backing.allocator(),
        &.{ "press ControlLeft", "press KeyQ" },
    );

    try testing.expect(keyHeld(&input_state, "ControlLeft"));
    try testing.expect(keyHeld(&input_state, "KeyQ"));
    try testing.expect(player_input.modifiers.ctrl);
}

test "console release completes the held model" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    var input_state: input.InputState = .{};
    _ = runConsoleScript(
        &history,
        &input_state,
        backing.allocator(),
        &.{ "press Escape", "release Escape" },
    );
    try testing.expect(!keyHeld(&input_state, "Escape"));
}

test "console quit requests the session quit" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    try testing.expect(!history.session.quit_requested);
    var input_state: input.InputState = .{};
    _ = runConsoleScript(&history, &input_state, backing.allocator(), &.{"quit"});
    try testing.expect(history.session.quit_requested);
}
