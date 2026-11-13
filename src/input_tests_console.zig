//! Console-input regression pins (DESIGN → Input → Console input): the
//! placement-class bugs the headless suite could not see before the console
//! channel existed, driven end-to-end at the handler level - a parsed
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
/// InputState's private isHeld - the assertion needs the fact, not the
/// helper).
fn keyHeld(input_state: *const input.InputState, id: []const u8) bool {
    for (input_state.keys_held) |slot| {
        if (slot) |held_id| {
            if (std.mem.eql(u8, held_id, id)) return true;
        }
    }
    return false;
}

/// One live-shaped console frame: reset the frame arena (main.frame's
/// per-frame cadence, retain capacity), build the dump-path root FRESH
/// (the live path passes the real FrameState; the test root is a shallow
/// copy that must be rebuilt per frame - a stale root silently reads dead
/// state, so the construction lives HERE and can't be forgotten), then
/// applyFrameCommand → translateInput → foldInjectedActions. Shared by
/// runConsoleScript's loop and the per-frame manual tests (the
/// static-lifetime pin, the rollover e2e). `hardware_pointer` simulates
/// the native backend's UNCONDITIONAL per-frame mouse_move event.
fn runConsoleFrame(
    queue: *console.ConsoleQueue,
    input_state: *input.InputState,
    history: *state.GameStateHistory,
    frame_arena: *std.heap.ArenaAllocator,
    hardware_pointer: ?input.PointerPosition,
) input.PlayerInput {
    _ = frame_arena.reset(.retain_capacity);
    const WalkerRoot = struct { history: state.GameStateHistory };
    var root = WalkerRoot{ .history = history.* };
    const hardware_events: [1]input.PlatformInputEvent = if (hardware_pointer) |position|
        .{.{ .mouse_move = position }}
    else
        .{.{ .mouse_move = .{ .x = 0, .y = 0 } }};
    const backend_input = input.PlatformInput{
        .events = &hardware_events,
        .viewport = .{ .width = types.reference_width, .height = types.reference_height },
    };
    const platform_input = console.applyFrameCommand(
        queue,
        backend_input,
        frame_arena.allocator(),
        history,
        &root,
        &.{},
        .{ .position = .{ .x = 0, .y = 0 } },
        1.0,
    );
    var player_input = input.translateInput(
        platform_input,
        input_state,
        history.settings,
        .{ .position = .{ .x = 0, .y = 0 } },
        0,
        null,
        null,
        game_contexts,
    );
    console.foldInjectedActions(&player_input, platform_input);
    return player_input;
}

/// One frame's console-driven input: parse a script of commands, run them
/// one per frame (the live drain's cadence) against `history`, returning the
/// LAST frame's PlayerInput. Mirrors frame()'s seam order: poll (backend
/// input) → applyFrameCommand → translateInput → fold injected actions -
/// INCLUDING the per-frame arena reset (runConsoleFrame's reset), so every
/// script exercises the live loop's reset cadence: an id (or any merged
/// byte) that dangles across frames fails HERE, not in a live session.
/// `arena` is the parent for the script's frame arena (reset per command,
/// freed at return - the returned PlayerInput is all values, nothing
/// borrowed from it).
/// `hardware_pointer` simulates the native backend's UNCONDITIONAL per-frame
/// mouse_move event (the hardware position it re-reports every frame - the
/// behavior that would overwrite a scripted position between commands).
fn runConsoleScript(
    history: *state.GameStateHistory,
    input_state: *input.InputState,
    arena: std.mem.Allocator,
    hardware_pointer: ?input.PointerPosition,
    script: []const []const u8,
) input.PlayerInput {
    var result: input.PlayerInput = .{};
    // One queue for the whole script (the live queue lives on FrameState -
    // the remembered pointer position persists across frames on it).
    var queue: console.ConsoleQueue = .{};
    var frame_arena = std.heap.ArenaAllocator.init(arena);
    defer frame_arena.deinit();
    for (script) |line| {
        queue.push(console.parseCommandLine(line).command);
        result = runConsoleFrame(&queue, input_state, history, &frame_arena, hardware_pointer);
    }
    return result;
}

test "runConsoleFrame resets the frame arena (the live loop's per-frame cadence)" {
    // The hardening's own guard: every console-driven frame must start
    // from a reset arena (main.frame's cadence), so bytes merged for one
    // command never survive into the next frame - the condition the
    // id-lifetime bug class hides behind when the reset is missing. The
    // static ids make today's tests insensitive to the reset's presence
    // (the deliberate-break check confirmed it), so the cadence is pinned
    // directly: two identical frames' allocations must land at the SAME
    // addresses (the reset between them rewound the arena), proven by a
    // probe allocated after each frame.
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    // One big node with plenty of slack, so the frames' allocations can
    // never spill into a second node (reset retains the LAST node - a
    // spilled frame would change which memory survives, making the
    // address assertion flaky).
    const warm = try frame_arena.allocator().alloc(u8, 8192);
    _ = warm;
    _ = frame_arena.reset(.retain_capacity);

    var queue: console.ConsoleQueue = .{};
    var input_state: input.InputState = .{};
    queue.push(console.parseCommandLine("press ArrowRight").command);
    _ = runConsoleFrame(&queue, &input_state, &history, &frame_arena, null);
    // Lands immediately after frame 1's merged-bytes allocations.
    const first_probe = try frame_arena.allocator().alloc(u8, 64);

    // Frame 2 (a release - the same allocation shape as the press). With
    // the per-frame reset, its allocations land where frame 1's did, so
    // the probe after it lands at the SAME address. Without the reset,
    // frame 2 stacks after first_probe and the addresses differ.
    queue.push(console.parseCommandLine("release ArrowRight").command);
    _ = runConsoleFrame(&queue, &input_state, &history, &frame_arena, null);
    const second_probe = try frame_arena.allocator().alloc(u8, 64);
    try testing.expect(second_probe.ptr == first_probe.ptr);
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

    history.current_state.ui_surfaces.openSurface(.options_menu);

    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(&history, &input_state, backing.allocator(), null, &.{"press Escape"});

    // The merged key edge rode the full pipeline: a held-state Escape press
    // whose binding translated to the escape action.
    try testing.expect(keyHeld(&input_state, "Escape"));
    try testing.expect(player_input.anytime.escape);

    // And the handler layer closed the menu - the dead-Escape class pinned.
    input_handlers.handleAnytimeInput(
        &history,
        player_input.anytime,
        player_input.clicked_payload,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
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
    history.current_state.ui_surfaces.openSurface(.options_menu);
    history.current_state.ui_surfaces.openSurface(.settings);
    history.session.ui_state.settings_tab = .keybinds;
    history.session.ui_state.keybind_scroll_offset = 4;

    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(&history, &input_state, backing.allocator(), null, &.{"scroll 1"});

    // One wheel notch up = one row earlier (the row-scroll convention).
    try testing.expectEqual(@as(f32, 1), player_input.anytime.scroll_delta);
    input_handlers.handleAnytimeInput(
        &history,
        player_input.anytime,
        player_input.clicked_payload,
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

    history.current_state.ui_surfaces.openSurface(.options_menu);

    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(&history, &input_state, backing.allocator(), null, &.{"action escape"});

    // applyAction folded the action directly (no binding consulted)...
    try testing.expect(player_input.anytime.escape);
    // ...and the handler layer consumed it.
    input_handlers.handleAnytimeInput(
        &history,
        player_input.anytime,
        player_input.clicked_payload,
        .{ .x = -4096, .y = -4096 },
        &.{},
    );
    try testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.options_menu));
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
    // pointer - frames later.
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
    // `press` id retained in InputState.keys_held - a held key stays held
    // until its `release` - must point at static memory, not arena bytes.
    // Regression pin for the crash class: arena-duped ids dangled into the
    // reset arena; the next held-state comparison read dead memory (a live
    // segfault in isHeld, and silently wrong held state - a "held" key
    // vanishing mid-chord). runConsoleScript resets per frame now too, so
    // every console test exercises the reset - but this pin goes further:
    // it SCRIBBLES over the reused bytes between frames, so a dangling id
    // reads garbage, not its own stale bytes (a reset alone can leave old
    // content readable).
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    var input_state: input.InputState = .{};
    var queue: console.ConsoleQueue = .{};
    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    // Frame 1: press ArrowRight (never released - it stays held).
    queue.push(console.parseCommandLine("press ArrowRight").command);
    {
        const player_input = runConsoleFrame(&queue, &input_state, &history, &frame_arena, null);
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
    // shape). Right must STILL register as held - the held-opposite cancel
    // keeps cursor_direction.x at 0.
    queue.push(console.parseCommandLine("press ArrowLeft").command);
    {
        const player_input = runConsoleFrame(&queue, &input_state, &history, &frame_arena, null);
        try testing.expect(player_input.anytime.in_game.move_cursor_left);
        try testing.expectEqual(@as(i32, 0), player_input.anytime.in_game.cursor_direction.x);
        try testing.expect(keyHeld(&input_state, "ArrowRight"));
        try testing.expect(keyHeld(&input_state, "ArrowLeft"));
    }
}

test "console end-to-end: fast right-then-left arrow rollover moves the cursor both times" {
    // The reported bug, pinned end-to-end through the console channel at
    // the live loop's cadence: press right, then press left BEFORE
    // releasing right (key rollover - what fast input actually does).
    // The nudge trigger is edge-based but the vector derived from HELD
    // keys (opposites cancel), so the left edge was consumed into a zero
    // vector and never re-fired - only the right press registered. The
    // press-direction fallback (cursor_press_direction) rescues the
    // rollover press at its own frame.
    //
    // Drives the full live seam per frame - applyFrameCommand (with a
    // per-frame arena RESET, like main.frame - runConsoleFrame) →
    // translateInput → resolveTileCursor - so the pin also re-exercises
    // the held-id static-lifetime property every frame.
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &three_by_three,
    ));
    test_harness.runToIdle(&history);

    var input_state: input.InputState = .{};
    var queue: console.ConsoleQueue = .{};
    var frame_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame_arena.deinit();

    // One live-shaped frame plus the cursor resolution (update()'s step
    // order): drain one console command, translate, resolve the tile
    // cursor. Returns the frame's PlayerInput.
    const frame = struct {
        fn run(
            queue_ptr: *console.ConsoleQueue,
            input_state_ptr: *input.InputState,
            history_ptr: *state.GameStateHistory,
            arena_ptr: *std.heap.ArenaAllocator,
        ) input.PlayerInput {
            const player_input = runConsoleFrame(queue_ptr, input_state_ptr, history_ptr, arena_ptr, null);
            input_handlers.resolveTileCursor(history_ptr, player_input, &.{});
            return player_input;
        }
    };

    // Rollover sequence: right press → left press (right still held) →
    // release right → release left. Every PRESS must register.
    queue.push(console.parseCommandLine("press ArrowRight").command);
    _ = frame.run(&queue, &input_state, &history, &frame_arena);
    try testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, history.session.tile_cursor.?);

    queue.push(console.parseCommandLine("press ArrowLeft").command);
    const rollover_frame = frame.run(&queue, &input_state, &history, &frame_arena);
    try testing.expect(rollover_frame.anytime.in_game.move_cursor_left);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, history.session.tile_cursor.?);

    queue.push(console.parseCommandLine("release ArrowRight").command);
    _ = frame.run(&queue, &input_state, &history, &frame_arena);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, history.session.tile_cursor.?);

    queue.push(console.parseCommandLine("release ArrowLeft").command);
    _ = frame.run(&queue, &input_state, &history, &frame_arena);
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, history.session.tile_cursor.?);

    // Control - sequential taps (right fully released before left presses)
    // registered at any speed before the fix and must stay identical.
    var tap_state: input.InputState = .{};
    var tap_queue: console.ConsoleQueue = .{};
    {
        tap_queue.push(console.parseCommandLine("press ArrowRight").command);
        _ = frame.run(&tap_queue, &tap_state, &history, &frame_arena);
        tap_queue.push(console.parseCommandLine("release ArrowRight").command);
        _ = frame.run(&tap_queue, &tap_state, &history, &frame_arena);
        tap_queue.push(console.parseCommandLine("press ArrowLeft").command);
        _ = frame.run(&tap_queue, &tap_state, &history, &frame_arena);
        tap_queue.push(console.parseCommandLine("release ArrowLeft").command);
        _ = frame.run(&tap_queue, &tap_state, &history, &frame_arena);
    }
    try testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, history.session.tile_cursor.?);
}

test "dump path: the observability stash is addressable (previous_player_input / previous_delta)" {
    // Pins the stash's dump paths against the real shape: a root with the
    // FrameState's stash fields set (the live write happens in main.frame;
    // here the walker proves the paths resolve + render the translation).
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    const StashRoot = struct {
        history: state.GameStateHistory,
        previous_player_input: ?input.PlayerInput,
        previous_delta_microseconds: u64,
    };
    var root = StashRoot{
        .history = history,
        .previous_player_input = .{ .anytime = .{ .in_game = .{
            .move_cursor_right = true,
            .cursor_direction = .{ .x = 1, .y = 0 },
        } } },
        .previous_delta_microseconds = 3200,
    };

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const const_root: *const StashRoot = &root;
    @import("dump_walker.zig").writeDump(&writer, const_root, "previous_player_input.anytime.in_game.cursor_direction");
    try testing.expectEqualStrings("{ x: 1, y: 0 }\n", buffer[0..writer.end]);

    var writer2 = std.Io.Writer.fixed(&buffer);
    @import("dump_walker.zig").writeDump(&writer2, const_root, "previous_delta_microseconds");
    try testing.expectEqualStrings("3200\n", buffer[0..writer2.end]);

    // The one string payload borrows session-owned scan bytes, so the
    // wholesale copy holds: a stashed editor_sprite payload reads back
    // verbatim (content - the pointer-identity pin lives in the picker
    // test).
    root.previous_player_input.?.clicked_payload = .{ .editor_sprite = "custom/artists_den/boss" };
    var writer3 = std.Io.Writer.fixed(&buffer);
    @import("dump_walker.zig").writeDump(&writer3, const_root, "previous_player_input.clicked_payload.editor_sprite");
    try testing.expectEqualStrings("custom/artists_den/boss\n", buffer[0..writer3.end]);
}

test "console action open_repo_link queues the clipboard copy (the native click path)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    // The fresh history sits on the main menu - the same consumption arm a
    // real button click fires (release seam -> applyAction -> idle
    // menu_action -> handleIdleInput). Tests run the native branch of
    // browser_url: the URL lands on the session's clipboard queue, which
    // frame() drains to the backend. Conditional on the build carrying a
    // repo URL (a tarball build without git emits no link and the action
    // no-ops).
    var input_state: input.InputState = .{};
    const player_input = runConsoleScript(&history, &input_state, backing.allocator(), null, &.{"action open_repo_link"});
    try testing.expect(player_input.idle.menu_action == .open_repo_link);
    input_handlers.handleIdleInput(&history, player_input.idle, .{});

    const build_info = @import("build_info");
    if (build_info.repo_url.len > 0) {
        try testing.expectEqualStrings(build_info.repo_url, history.session.pending_clipboard_text.items);
        // The drain hands the text to the frame and empties the queue.
        const drained = history.session.drainPendingClipboardText();
        try testing.expectEqualStrings(build_info.repo_url, drained);
        try testing.expectEqual(@as(usize, 0), history.session.pending_clipboard_text.items.len);
    } else {
        try testing.expectEqual(@as(usize, 0), history.session.pending_clipboard_text.items.len);
    }
}
