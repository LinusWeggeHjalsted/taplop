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
/// LAST frame's PlayerInput. Mirrors frame()'s seam order: poll (backend
/// input) → applyFrameCommand → translateInput → fold injected actions.
/// `arena` backs the merged bytes (the live seam's frame arena — not
/// testing.allocator, whose leak check would fire on the merges).
/// `hardware_pointer` simulates the native backend's UNCONDITIONAL per-frame
/// mouse_move event (the hardware position it re-reports every frame — the
/// behavior that would overwrite a scripted position between commands).
fn runConsoleScript(
    history: *state.GameStateHistory,
    input_state: *input.InputState,
    arena: std.mem.Allocator,
    hardware_pointer: ?input.PointerPosition,
    script: []const []const u8,
) input.PlayerInput {
    var result: input.PlayerInput = .{};
    // One queue for the whole script (the live queue lives on FrameState —
    // the remembered pointer position persists across frames on it).
    var queue: console.ConsoleQueue = .{};
    for (script) |line| {
        queue.push(console.parseCommandLine(line).command);
        const hardware_events: [1]input.PlatformInputEvent = if (hardware_pointer) |position|
            .{.{ .mouse_move = position }}
        else
            .{.{ .mouse_move = .{ .x = 0, .y = 0 } }};
        const backend_input = input.PlatformInput{
            .events = &hardware_events,
            .viewport = .{ .width = types.reference_width, .height = types.reference_height },
        };
        const platform_input = console.applyFrameCommand(
            &queue,
            backend_input,
            arena,
            history,
            &.{},
            .{ .position = .{ .x = 0, .y = 0 } },
            1.0,
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

    history.current_state.ui_surfaces.options_menu_open = true;

    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(&history, &input_state, backing.allocator(), null, &.{"press Escape"});

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
    try testing.expect(!history.current_state.ui_surfaces.options_menu_open);
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
    history.current_state.ui_surfaces.options_menu_open = true;
    history.current_state.ui_surfaces.settings_open = true;
    history.session.ui_state.settings_tab = .keybinds;
    history.session.ui_state.keybind_scroll_offset = 4;

    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(&history, &input_state, backing.allocator(), null, &.{"scroll 1"});

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

    history.current_state.ui_surfaces.options_menu_open = true;

    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(&history, &input_state, backing.allocator(), null, &.{"action escape"});

    // applyAction folded the action directly (no binding consulted)...
    try testing.expect(player_input.anytime.escape);
    // ...and the handler layer consumed it.
    input_handlers.handleAnytimeInput(
        &history,
        player_input.anytime,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expect(!history.current_state.ui_surfaces.options_menu_open);
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
        null,
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
        null,
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
    _ = runConsoleScript(&history, &input_state, backing.allocator(), null, &.{"quit"});
    try testing.expect(history.session.quit_requested);
}

test "console move persists to the command frame over the backend's per-frame hardware position" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    // The native backend re-reports the hardware pointer position EVERY
    // frame (unconditionally); without persistence a scripted `move` would
    // be overwritten before the next command lands. The remembered
    // position re-applies ahead of the command's events (last writer wins
    // within the frame), so the press acts where the console moved the
    // pointer — frames later.
    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(
        &history,
        &input_state,
        backing.allocator(),
        .{ .x = 2291, .y = 981 }, // hardware resting elsewhere
        &.{ "move 1920 1256", "press left" },
    );

    try testing.expect(player_input.pointer.pressed);
    try testing.expectEqual(@as(f32, 1920), player_input.pointer.position.x);
    try testing.expectEqual(@as(f32, 1256), player_input.pointer.position.y);

    // And the hardware position owns the frame when no command re-applies
    // the remembered one (the human never loses the pointer):
    const hardware_frame = input.translateInput(
        input.PlatformInput{
            .events = &.{.{ .mouse_move = .{ .x = 2291, .y = 981 } }},
            .viewport = .{ .width = types.reference_width, .height = types.reference_height },
        },
        &input_state,
        history.settings,
        .{ .position = .{ .x = 0, .y = 0 } },
        0,
        null,
        null,
        game_contexts,
    );
    try testing.expectEqual(@as(f32, 2291), hardware_frame.pointer.position.x);
}

test "console press: held-key id survives the frame-arena reset (static-lifetime ids)" {
    // The live frame loop RESETS the frame arena every frame
    // (main.frame's `frame_arena.reset(.retain_capacity)`), so a console
    // `press` id retained in InputState.keys_held — a held key stays held
    // until its `release` — must point at static memory, not arena bytes.
    // Regression pin for the crash class: arena-duped ids dangled into the
    // reset arena; the next held-state comparison read dead memory (a live
    // segfault in isHeld, and silently wrong held state — a "held" key
    // vanishing mid-chord). The other console tests share one arena for
    // the whole script, which is why they could not see this class.
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    var input_state: input.InputState = .{};
    var queue: console.ConsoleQueue = .{};
    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    // Frame 1: press ArrowRight (never released — it stays held).
    queue.push(console.parseCommandLine("press ArrowRight").command);
    const hardware_events = [1]input.PlatformInputEvent{.{ .mouse_move = .{ .x = 0, .y = 0 } }};
    const backend_input = input.PlatformInput{
        .events = &hardware_events,
        .viewport = .{ .width = types.reference_width, .height = types.reference_height },
    };
    {
        const platform_input = console.applyFrameCommand(
            &queue,
            backend_input,
            frame_arena.allocator(),
            &history,
            &.{},
            .{ .position = .{ .x = 0, .y = 0 } },
            1.0,
        );
        const player_input = input.translateInput(
            platform_input,
            &input_state,
            history.settings,
            .{ .position = .{ .x = 0, .y = 0 } },
            0,
            null,
            null,
            game_contexts,
        );
        try testing.expect(player_input.anytime.in_game.move_cursor_right);
        try testing.expectEqual(@as(i32, 1), player_input.anytime.in_game.cursor_direction.x);
        try testing.expect(keyHeld(&input_state, "ArrowRight"));
    }

    // The frame ends: the live loop resets the arena here. Scribble junk
    // over the reused memory in small chunks so a dangling id slice would
    // read garbage (not its old bytes).
    _ = frame_arena.reset(.retain_capacity);
    for (0..256) |_| {
        const churn = frame_arena.allocator().alloc(u8, 16) catch unreachable;
        @memset(churn, 'X');
    }

    // Frame 2: press ArrowLeft while ArrowRight is still held (the rollover
    // shape). Right must STILL register as held — the held-opposite cancel
    // keeps cursor_direction.x at 0.
    queue.push(console.parseCommandLine("press ArrowLeft").command);
    {
        const platform_input = console.applyFrameCommand(
            &queue,
            backend_input,
            frame_arena.allocator(),
            &history,
            &.{},
            .{ .position = .{ .x = 0, .y = 0 } },
            1.0,
        );
        const player_input = input.translateInput(
            platform_input,
            &input_state,
            history.settings,
            .{ .position = .{ .x = 0, .y = 0 } },
            0,
            null,
            null,
            game_contexts,
        );
        try testing.expect(player_input.anytime.in_game.move_cursor_left);
        try testing.expectEqual(@as(i32, 0), player_input.anytime.in_game.cursor_direction.x);
        try testing.expect(keyHeld(&input_state, "ArrowRight"));
        try testing.expect(keyHeld(&input_state, "ArrowLeft"));
    }
}
