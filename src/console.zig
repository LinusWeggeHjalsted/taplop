//! Console input — stdin as a scripted input channel (TAS-shaped). The
//! command vocabulary + parser, the reader-thread-facing queue, the
//! per-frame drain + PlatformInput merge, the action fold, and the dump
//! projections. Everything here is raylib-free; the reader thread + stdout
//! output writer are wired only by the native driver (native.zig) — with no
//! reader the queue stays empty and the per-frame drain is a no-op (web, or
//! a native launch without stdin, which is immediate EOF). Injected events
//! ride the IDENTICAL pipeline as hardware input (translateInput, held-state
//! tracking, binding contexts, drains, recorded events), so a console-driven
//! session is indistinguishable from a played one and its log is a valid
//! --replay fixture. See DESIGN → Input → Console input.

const std = @import("std");
const types = @import("types.zig");
const input = @import("input.zig");
const state = @import("state.zig");
const writers = @import("writers.zig");
const session_log = @import("session_log.zig");
const ui = @import("ui.zig");

const GameStateHistory = state.GameStateHistory;
const PlatformInput = input.PlatformInput;
const PlatformInputEvent = input.PlatformInputEvent;

// ============================================================
// Bounded text — fixed-buffer strings, no allocation
// ============================================================

/// A fixed-capacity owned string, copied by value. Commands, error messages,
/// and queue entries carry these so the whole console path allocates nothing
/// between parse and merge (the merge's frame-arena dupes are the only
/// allocations, at drain time on the game's thread).
fn BoundedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: u16 = 0,

        const Self = @This();

        fn store(self: *Self, text: []const u8) bool {
            if (text.len > capacity) return false;
            @memcpy(self.bytes[0..text.len], text);
            // Defined tail bytes so value comparisons (expectEqualDeep) are
            // deterministic regardless of what the stack held before.
            @memset(self.bytes[text.len..], 0);
            self.len = @intCast(text.len);
            return true;
        }

        fn view(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// Every input id the console accepts (the binding vocabulary — see
/// `types.producible_key_ids` / `producible_mouse_ids`).
const max_id_len = 32;
/// Longest `type <text>` payload.
const max_type_text_len = 256;
/// Longest parse-error message.
const max_message_len = 256;

const IdText = BoundedText(max_id_len);
const TypeText = BoundedText(max_type_text_len);
const MessageText = BoundedText(max_message_len);

// ============================================================
// Commands
// ============================================================

/// One parsed console command. `wait` is a queue directive (pacing), `dump`
/// and `quit` apply directly in `applyFrameCommand`; every other kind is an
/// input command merged into the frame's PlatformInput.
pub const ConsoleCommand = union(enum) {
    /// Press a key or mouse button (held-state tracking makes it held, like
    /// a physical key; chords work across frames).
    press: CommandInputId,
    /// Release a held key or button (completes the held model).
    release: CommandInputId,
    /// Move the pointer (reference space, logical pixels).
    move: input.PointerPosition,
    /// Scroll; positive = up (the PlatformInputEvent convention).
    scroll: f32,
    /// Type text into the char queue (the text-input widget's machinery).
    type_text: TypeText,
    /// Fire a semantic action — folded via `applyAction`, the same seam
    /// button clicks use (context-free; the consumption sites gate
    /// themselves). Payload-less actions only (the keybind vocabulary).
    action: types.Action,
    /// Skip n frames before the next command (the pacing primitive).
    wait: u32,
    /// Write a projection to stdout.
    dump: DumpKind,
    /// Request the session quit (the Exit Game path).
    quit: void,

    pub const CommandInputId = union(enum) {
        key: IdText,
        mouse: IdText,
    };

    pub const DumpKind = enum { state, ui, settings, bindings, history };
};

/// The result of parsing one stdin line.
pub const ParseOutcome = union(enum) {
    /// Empty line or `#` comment — nothing to enqueue.
    skip: void,
    command: ConsoleCommand,
    /// The line's shape is wrong; the message names the problem (printed by
    /// the reader thread).
    err: MessageText,

    /// The err arm's message text (valid only when the outcome is `.err` —
    /// the reader thread's stderr report). Pointer self: the returned slice
    /// must point into the CALLER's outcome, not a by-value copy's dead
    /// frame.
    pub fn errorMessage(self: *const ParseOutcome) []const u8 {
        return self.err.view();
    }
};

// ============================================================
// Parser
// ============================================================

/// Parse one console command line (no trailing newline). The line is
/// space-separated: a verb, then its arguments; `type`'s argument is the rest
/// of the line verbatim. Verbs, ids, action names, and dump kinds are all
/// exact-match (case-sensitive) — they name enum values the engine consumes.
pub fn parseCommandLine(line: []const u8) ParseOutcome {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return .skip;

    const verb, const rest = splitFirstWord(trimmed);
    // Verbs other than `type` take single-token arguments — trim fully.
    // `type`'s payload is the rest of the line (handled in its own arm).
    const argument = std.mem.trim(u8, rest, " \t");

    if (std.mem.eql(u8, verb, "quit")) {
        if (argument.len > 0) return staticMessage("quit takes no arguments");
        return .{ .command = .quit };
    }

    if (std.mem.eql(u8, verb, "press") or std.mem.eql(u8, verb, "release")) {
        if (argument.len == 0 or argument.len > max_id_len) {
            return formattedMessage("{s} requires an input id (press Escape, press left)", .{verb});
        }
        const command_id = classifyInputId(argument) orelse
            return formattedMessage(
                "input id '{s}' names an input no platform mapping can produce; ids are W3C key codes (KeyA, Escape, ArrowLeft, ...) or mouse buttons (left, right, middle)",
                .{argument},
            );
        if (std.mem.eql(u8, verb, "press")) {
            return .{ .command = .{ .press = command_id } };
        } else {
            return .{ .command = .{ .release = command_id } };
        }
    }

    if (std.mem.eql(u8, verb, "move")) {
        const x_word, const after_x = splitFirstWord(argument);
        const y_word, const after_y = splitFirstWord(std.mem.trim(u8, after_x, " \t"));
        if (x_word.len == 0 or y_word.len == 0 or after_y.len > 0) {
            return staticMessage("move requires exactly two numbers (move 640 360, reference-space pixels)");
        }
        const x = std.fmt.parseFloat(f32, x_word) catch
            return formattedMessage("move x '{s}' is not a number", .{x_word});
        const y = std.fmt.parseFloat(f32, y_word) catch
            return formattedMessage("move y '{s}' is not a number", .{y_word});
        return .{ .command = .{ .move = .{ .x = x, .y = y } } };
    }

    if (std.mem.eql(u8, verb, "scroll")) {
        if (argument.len == 0) return staticMessage("scroll requires a delta (scroll 1; positive = up)");
        const delta = std.fmt.parseFloat(f32, argument) catch
            return formattedMessage("scroll delta '{s}' is not a number", .{argument});
        return .{ .command = .{ .scroll = delta } };
    }

    if (std.mem.eql(u8, verb, "type")) {
        // `rest` is verbatim: splitFirstWord already consumed exactly one
        // separator after the verb, so a doubled space types a leading
        // space ("type  x" types " x"). The whole line was trimmed at
        // both ends above, so trailing whitespace is not typable.
        if (rest.len == 0) return staticMessage("type requires text (the rest of the line)");
        if (rest.len > max_type_text_len) {
            return staticMessage("type text exceeds 256 characters");
        }
        return .{ .command = .{ .type_text = storedText(TypeText, rest) } };
    }

    if (std.mem.eql(u8, verb, "action")) {
        if (argument.len == 0) return staticMessage("action requires an action name (action escape)");
        const action = std.meta.stringToEnum(types.Action, argument) orelse
            return formattedMessage("unknown action '{s}'", .{argument});
        return .{ .command = .{ .action = action } };
    }

    if (std.mem.eql(u8, verb, "wait")) {
        if (argument.len == 0) return staticMessage("wait requires a frame count (wait 60)");
        const frames = std.fmt.parseInt(u32, argument, 10) catch
            return formattedMessage("wait count '{s}' is not a non-negative integer", .{argument});
        return .{ .command = .{ .wait = frames } };
    }

    if (std.mem.eql(u8, verb, "dump")) {
        if (std.mem.eql(u8, argument, "state")) return .{ .command = .{ .dump = .state } };
        if (std.mem.eql(u8, argument, "ui")) return .{ .command = .{ .dump = .ui } };
        if (std.mem.eql(u8, argument, "settings")) return .{ .command = .{ .dump = .settings } };
        if (std.mem.eql(u8, argument, "bindings")) return .{ .command = .{ .dump = .bindings } };
        if (std.mem.eql(u8, argument, "history")) return .{ .command = .{ .dump = .history } };
        return formattedMessage("unknown dump kind '{s}' (state, ui, settings, bindings, history)", .{argument});
    }

    return formattedMessage(
        "unknown console command '{s}' (press, release, move, scroll, type, action, wait, dump, quit)",
        .{verb},
    );
}

/// Split `text` at its first whitespace run: the word before, the remainder
/// after (untrimmed — callers trim).
fn splitFirstWord(text: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfAny(u8, text, " \t")) |separator_index| {
        return .{ text[0..separator_index], text[separator_index + 1 ..] };
    }
    return .{ text, "" };
}

/// Classify an input id as a key or mouse id by the binding vocabulary (the
/// producible-id lists; a gamepad id is unproducible — no gamepad table).
fn classifyInputId(id: []const u8) ?ConsoleCommand.CommandInputId {
    for (types.producible_key_ids) |producible_id| {
        if (std.mem.eql(u8, id, producible_id)) return .{ .key = storedText(IdText, id) };
    }
    for (types.producible_mouse_ids) |producible_id| {
        if (std.mem.eql(u8, id, producible_id)) return .{ .mouse = storedText(IdText, id) };
    }
    return null;
}

fn storedText(comptime Text: type, text: []const u8) Text {
    var stored: Text = .{};
    const fits = stored.store(text);
    std.debug.assert(fits); // capacity checked at every call site first
    return stored;
}

fn staticMessage(comptime message: []const u8) ParseOutcome {
    comptime if (message.len > max_message_len) @compileError("parse error message exceeds max_message_len");
    return .{ .err = storedText(MessageText, message) };
}

fn formattedMessage(comptime fmt: []const u8, args: anytype) ParseOutcome {
    var message: MessageText = .{};
    const written = std.fmt.bufPrint(&message.bytes, fmt, args) catch
        return staticMessage("console parse error message did not fit");
    message.len = @intCast(written.len);
    return .{ .err = message };
}

// ============================================================
// Queue (reader thread → game thread)
// ============================================================

/// The command queue shared between the reader thread (push) and the game's
/// frame drain (take, one per frame). A single-producer single-consumer ring
/// with atomic monotonic counters — no mutex (Zig 0.16's std locks need an Io
/// handle on BOTH threads, and the game thread has none to give inside
/// frame()). A full queue BLOCKS the reader (yield-spin backpressure), so a
/// piped script faster than the frame drain can never drop or reorder
/// commands — the reader paces the game until the backlog drains.
pub const ConsoleQueue = struct {
    commands: [queue_capacity]ConsoleCommand = undefined,
    /// Total commands ever pushed (reader thread). Monotonic; slot index is
    /// `write_counter % queue_capacity`. u32 (wasm32 rejects 64-bit
    /// atomics): the counter wraps, but the wrap-SAFE invariant is the
    /// occupied count (`write_counter -% read_counter`), which stays
    /// correct across wraparound because the capacity (64) is far below
    /// 2^32.
    write_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Total commands ever popped (game thread). Monotonic; slot index is
    /// `read_counter % queue_capacity` (see write_counter for the u32
    /// wrap-safety reasoning).
    read_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Idle frames remaining from a popped `wait` (game thread only).
    wait_frames_remaining: u32 = 0,
    /// The console's remembered pointer position — set by `move`, persists
    /// across frames like held keys (the console's pointer is where the
    /// console left it). The native backend re-reports the hardware pointer
    /// position EVERY frame (unconditionally), which would otherwise
    /// overwrite a scripted position before the next command lands — so
    /// every INPUT-command frame re-applies this position ahead of the
    /// command's own events (last writer wins within the frame; see
    /// `applyFrameCommand`). Frames between commands stay on the hardware
    /// position — a human at the window never loses the pointer. Game
    /// thread only (set + read in applyFrameCommand).
    pointer_position: ?input.PointerPosition = null,
    /// Dump output goes here (stdout), wired by the native driver. Without a
    /// writer there is no reader thread either (web), so a dump can never
    /// arrive. Stored as the concrete parent (the File.Writer owns its
    /// interface; the vtable resolves the parent via fieldParentPtr, so an
    /// interface copy would dangle).
    output: ?std.Io.File.Writer = null,
    output_buffer: [output_buffer_capacity]u8 = undefined,

    const queue_capacity = 64;
    const output_buffer_capacity = 4096;

    /// Enqueue one parsed command (reader thread). Blocks while the queue is
    /// full — yield-spin backpressure (the exit condition is the drain, not
    /// the yield; a failed yield just re-checks).
    pub fn push(self: *ConsoleQueue, command: ConsoleCommand) void {
        const write = self.write_counter.load(.monotonic);
        // Full: the slot at `write % capacity` is still pending consumption.
        // Wrapping subtraction: the occupied count, valid across wraparound.
        while (write -% self.read_counter.load(.acquire) >= queue_capacity) {
            std.Thread.yield() catch {};
        }
        self.commands[write % queue_capacity] = command;
        // Release: the slot write is visible to the consumer before the
        // counter that publishes it.
        self.write_counter.store(write +% 1, .release);
    }

    /// Pop this frame's command (at most one per frame, game thread). A
    /// popped `wait n` arms n idle frames and yields null this frame; while
    /// frames remain, each call decrements and yields null — so `wait n`
    /// spaces the surrounding commands n idle frames apart.
    fn takeFrameCommand(self: *ConsoleQueue) ?ConsoleCommand {
        if (self.wait_frames_remaining > 0) {
            self.wait_frames_remaining -= 1;
            return null;
        }
        const read = self.read_counter.load(.monotonic);
        // Empty: nothing pushed past what was popped.
        if (read == self.write_counter.load(.acquire)) return null;
        const command = self.commands[read % queue_capacity];
        // Release: the slot is consumed before the counter that frees it for
        // the producer's reuse.
        self.read_counter.store(read +% 1, .release);
        if (command == .wait) {
            self.wait_frames_remaining = command.wait;
            return null;
        }
        return command;
    }
};

// ============================================================
// Per-frame drain + merge
// ============================================================

/// The per-frame console step (called from `frame()` right after the backend
/// poll): drain one command and apply it. Input commands return the
/// backend's PlatformInput with the command merged in (frame-arena-owned
/// bytes); `quit` requests the session quit; `dump` writes its projection to
/// the queue's output writer. With an empty queue (no reader — web, EOF, or
/// between commands) the backend input returns unchanged.
pub fn applyFrameCommand(
    queue: *ConsoleQueue,
    backend_input: PlatformInput,
    arena: std.mem.Allocator,
    history: *GameStateHistory,
    ui_elements: []const ui.UiElement,
) PlatformInput {
    const command = queue.takeFrameCommand() orelse return backend_input;
    switch (command) {
        .quit => {
            history.session.quit_requested = true;
            return backend_input;
        },
        .dump => |kind| {
            writeDump(kind, queue, history, ui_elements);
            return backend_input;
        },
        // A popped wait never leaves takeFrameCommand (it arms its own idle
        // frames there) — this arm only keeps the switch exhaustive.
        .wait => return backend_input,
        // `move` both remembers the position and applies it this frame.
        .move => |position| {
            queue.pointer_position = position;
            return mergeIntoPlatformInput(command, backend_input, arena);
        },
        // Press/release/scroll/type/action: re-apply the remembered pointer
        // position ahead of the command's own events (a mouse_move event
        // after the backend's per-frame hardware position — last writer
        // wins), so the command acts where the console moved the pointer,
        // frames later. Without a remembered position (no `move` yet), the
        // command acts at the hardware position.
        else => {
            var merged = backend_input;
            if (queue.pointer_position) |position| {
                merged = mergeIntoPlatformInput(.{ .move = position }, merged, arena);
            }
            return mergeIntoPlatformInput(command, merged, arena);
        },
    }
}

/// Merge one input command into the frame's PlatformInput. String payloads
/// (key/mouse ids, typed text) are duped into the frame arena — the command's
/// bytes live in queue memory the reader thread may overwrite with a later
/// push, so merged events must not alias them.
fn mergeIntoPlatformInput(
    command: ConsoleCommand,
    backend_input: PlatformInput,
    arena: std.mem.Allocator,
) PlatformInput {
    var merged = backend_input;
    switch (command) {
        .press => |*id| {
            merged.events = appendEvent(arena, backend_input.events, inputEventFor(id, .down));
        },
        .release => |*id| {
            merged.events = appendEvent(arena, backend_input.events, inputEventFor(id, .up));
        },
        .move => |position| {
            merged.events = appendEvent(arena, backend_input.events, .{ .mouse_move = position });
        },
        .scroll => |delta| {
            merged.events = appendEvent(arena, backend_input.events, .{ .mouse_scroll = delta });
        },
        .type_text => |text| {
            const combined = arena.alloc(
                u8,
                backend_input.text_characters.len + text.len,
            ) catch @panic("failed to allocate merged text characters");
            @memcpy(combined[0..backend_input.text_characters.len], backend_input.text_characters);
            @memcpy(combined[backend_input.text_characters.len..], text.view());
            merged.text_characters = combined;
        },
        .action => |action| {
            const actions = arena.alloc(types.Action, 1) catch @panic("failed to allocate merged actions");
            actions[0] = action;
            merged.actions = actions;
        },
        // Not input commands — applyFrameCommand handles them (wait never
        // reaches here either).
        .wait, .dump, .quit => {},
    }
    return merged;
}

const EventDirection = enum { down, up };

/// Build the raw event for a press/release. Takes a POINTER into the
/// caller's command: the event's string payload is a view into the id's
/// bounded bytes, which must outlive this call until `appendEvent` dupes
/// them into the frame arena (a by-value id would leave the payload
/// pointing into this function's dead frame).
fn inputEventFor(
    id: *const ConsoleCommand.CommandInputId,
    direction: EventDirection,
) PlatformInputEvent {
    return switch (id.*) {
        .key => |*key| switch (direction) {
            .down => .{ .key_down = key.view() },
            .up => .{ .key_up = key.view() },
        },
        .mouse => |*mouse| switch (direction) {
            .down => .{ .mouse_button_down = mouse.view() },
            .up => .{ .mouse_button_up = mouse.view() },
        },
    };
}

fn appendEvent(
    arena: std.mem.Allocator,
    existing: []const PlatformInputEvent,
    event: PlatformInputEvent,
) []const PlatformInputEvent {
    const merged = arena.alloc(PlatformInputEvent, existing.len + 1) catch
        @panic("failed to allocate merged input events");
    @memcpy(merged[0..existing.len], existing);
    merged[existing.len] = dupeEventPayload(arena, event);
    return merged;
}

fn dupeEventPayload(arena: std.mem.Allocator, event: PlatformInputEvent) PlatformInputEvent {
    return switch (event) {
        .key_down => |key| .{ .key_down = arena.dupe(u8, key) catch @panic("failed to dupe console key id") },
        .key_up => |key| .{ .key_up = arena.dupe(u8, key) catch @panic("failed to dupe console key id") },
        .mouse_button_down => |id| .{ .mouse_button_down = arena.dupe(u8, id) catch @panic("failed to dupe console mouse id") },
        .mouse_button_up => |id| .{ .mouse_button_up = arena.dupe(u8, id) catch @panic("failed to dupe console mouse id") },
        else => event,
    };
}

/// Fold platform-injected actions (the console `action` command, merged into
/// `PlatformInput.actions`) into the frame's PlayerInput — the same seam
/// button clicks use, so console actions share the button path's semantics
/// (context-free; the consumption sites gate themselves). Called from
/// `frame()` right after `translateInput`.
pub fn foldInjectedActions(
    player_input: *input.PlayerInput,
    platform_input: PlatformInput,
) void {
    for (platform_input.actions) |action| {
        input.applyAction(player_input, action);
    }
}

// ============================================================
// Dumps
// ============================================================

/// Write one dump projection to the console output (stdout, wired by the
/// native driver). Best-effort — a failed write reports on stderr and never
/// surfaces as a crash (the diagnostics-write convention).
fn writeDump(
    kind: ConsoleCommand.DumpKind,
    queue: *ConsoleQueue,
    history: *GameStateHistory,
    ui_elements: []const ui.UiElement,
) void {
    if (queue.output) |*output| {
        writeDumpText(kind, &output.interface, history, ui_elements);
    }
}

fn writeDumpText(
    kind: ConsoleCommand.DumpKind,
    output: *std.Io.Writer,
    history: *GameStateHistory,
    ui_elements: []const ui.UiElement,
) void {
    var arena = std.heap.ArenaAllocator.init(history.backing_allocator);
    defer arena.deinit();
    const text = dumpText(kind, history, ui_elements, arena.allocator());
    output.writeAll(text) catch |err| {
        std.debug.print("console dump write failed: {s}\n", .{@errorName(err)});
        return;
    };
    output.writeAll("\n") catch |err| {
        std.debug.print("console dump write failed: {s}\n", .{@errorName(err)});
        return;
    };
    output.flush() catch |err| {
        std.debug.print("console dump write failed: {s}\n", .{@errorName(err)});
        return;
    };
}

/// Build a dump projection as text. `settings` is the full settings-file text
/// (the writer's own serialization); `history` is the session-log body (the
/// --replay artifact).
fn dumpText(
    kind: ConsoleCommand.DumpKind,
    history: *GameStateHistory,
    ui_elements: []const ui.UiElement,
    allocator: std.mem.Allocator,
) []const u8 {
    return switch (kind) {
        .state => dumpStateText(history, allocator),
        .ui => dumpUiText(history, ui_elements, allocator),
        .settings => writers.writeSettings(history.settings, allocator) catch
            @panic("failed to serialize settings dump"),
        .bindings => dumpBindingsText(history, allocator),
        .history => session_log.writeEventLog(
            history.event_history.items,
            "console_dump",
            allocator,
        ) catch @panic("failed to serialize history dump"),
    };
}

fn dumpStateText(history: *GameStateHistory, allocator: std.mem.Allocator) []const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    const current = &history.current_state;
    buffer.print(allocator, "screen: {s}\n", .{@tagName(current.screen)}) catch
        @panic("failed to format state dump");
    buffer.print(allocator, "world_generation: {d}\n", .{current.world_generation}) catch
        @panic("failed to format state dump");
    buffer.print(allocator, "event_stack: {d} pending\n", .{current.event_stack.len}) catch
        @panic("failed to format state dump");
    buffer.print(allocator, "event_history: {d} recorded (current index {d})\n", .{
        history.event_history.items.len,
        history.current_event_index,
    }) catch @panic("failed to format state dump");
    buffer.print(allocator, "idle_points: {d}\n", .{history.idle_points.items.len}) catch
        @panic("failed to format state dump");
    if (current.waiting) |wait| {
        buffer.print(allocator, "waiting: {d} microseconds remaining\n", .{wait.remaining_microseconds}) catch
            @panic("failed to format state dump");
    } else {
        buffer.appendSlice(allocator, "waiting: none\n") catch @panic("failed to format state dump");
    }
    buffer.appendSlice(
        allocator,
        if (history.session.pending_error != null) "pending_error: set\n" else "pending_error: none\n",
    ) catch @panic("failed to format state dump");
    if (current.level) |level| {
        var player_line: []const u8 = "player: none on field\n";
        for (level.entities) |entity| {
            if (entity.team == 0) {
                player_line = std.fmt.allocPrint(
                    allocator,
                    "player: at ({d}, {d})\n",
                    .{ entity.position.x, entity.position.y },
                ) catch @panic("failed to format state dump");
                break;
            }
        }
        buffer.print(allocator, "entities: {d}\n", .{level.entities.len}) catch
            @panic("failed to format state dump");
        buffer.appendSlice(allocator, player_line) catch @panic("failed to format state dump");
    } else if (current.hub != null) {
        buffer.appendSlice(allocator, "entities: hub (player present)\n") catch @panic("failed to format state dump");
    } else {
        buffer.appendSlice(allocator, "entities: none (no world)\n") catch @panic("failed to format state dump");
    }
    return buffer.items;
}

fn dumpUiText(
    history: *GameStateHistory,
    ui_elements: []const ui.UiElement,
    allocator: std.mem.Allocator,
) []const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    const session = &history.session;
    const ui_state = &session.ui_state;
    buffer.print(allocator, "options_menu_open: {}\n", .{ui_state.options_menu_open}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "settings_open: {}\n", .{ui_state.settings_open}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "settings_tab: {s}\n", .{@tagName(ui_state.settings_tab)}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "credits_open: {}\n", .{ui_state.credits_open}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "load_save_menu_open: {}\n", .{ui_state.load_save_menu_open}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "editor_browser_open: {}\n", .{ui_state.editor_browser_open}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "keybind_scroll_offset: {d}\n", .{ui_state.keybind_scroll_offset}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "error_scroll_offset: {d}\n", .{session.error_scroll_offset}) catch
        @panic("failed to format ui dump");
    if (session.tile_cursor) |cursor| {
        buffer.print(allocator, "tile_cursor: ({d}, {d})\n", .{ cursor.x, cursor.y }) catch
            @panic("failed to format ui dump");
    } else {
        buffer.appendSlice(allocator, "tile_cursor: none\n") catch @panic("failed to format ui dump");
    }
    buffer.appendSlice(
        allocator,
        if (session.camera_pan != null) "camera_pan: active\n" else "camera_pan: none\n",
    ) catch @panic("failed to format ui dump");

    // The last-rendered interactive surfaces (the same element list the
    // press/release dispatch hit-tests against — `previous_view_state`),
    // each with its rect and its CENTER, a valid click point. Reference
    // space, so a coordinate from here clicks the same surface at any
    // window size / render resolution. Buttons carry their action name (the
    // semantic identity — the same enum `action <name>` accepts); sliders
    // their setting + value; text fields their current text; ref-bearing
    // slots their drag identity.
    buffer.appendSlice(
        allocator,
        "interactive surfaces (reference space; center = a valid click point):\n",
    ) catch @panic("failed to format ui dump");
    var surfaces: usize = 0;
    for (ui_elements) |element| {
        switch (element) {
            .button => |button| {
                buffer.print(
                    allocator,
                    "button {d} {d} {d} {d} center {d} {d} action {s}\n",
                    .{
                        button.screen_position.x,
                        button.screen_position.y,
                        button.width,
                        button.height,
                        button.screen_position.x + @divTrunc(button.width, 2),
                        button.screen_position.y + @divTrunc(button.height, 2),
                        @tagName(button.action),
                    },
                ) catch @panic("failed to format ui dump");
                surfaces += 1;
            },
            .slider => |slider| {
                buffer.print(
                    allocator,
                    "slider {d} {d} {d} {d} center {d} {d} setting {s} value {d} min {d} max {d}\n",
                    .{
                        slider.screen_position.x,
                        slider.screen_position.y,
                        slider.width,
                        slider.height,
                        slider.screen_position.x + @divTrunc(slider.width, 2),
                        slider.screen_position.y + @divTrunc(slider.height, 2),
                        @tagName(slider.setting_id),
                        slider.value,
                        slider.min,
                        slider.max,
                    },
                ) catch @panic("failed to format ui dump");
                surfaces += 1;
            },
            .text_field => |field| {
                // The text is last + verbatim (it can contain spaces).
                buffer.print(
                    allocator,
                    "text_field {d} {d} {d} {d} center {d} {d} text {s}\n",
                    .{
                        field.screen_position.x,
                        field.screen_position.y,
                        field.width,
                        field.height,
                        field.screen_position.x + @divTrunc(field.width, 2),
                        field.screen_position.y + @divTrunc(field.height, 2),
                        field.text,
                    },
                ) catch @panic("failed to format ui dump");
                surfaces += 1;
            },
            // Only ref-bearing slots are interactive (drag sources/drop
            // targets); a bare slot is a decorative cell.
            .slot => |slot| if (slot.ref) |slot_ref| {
                buffer.print(
                    allocator,
                    "slot {d} {d} {d} {d} center {d} {d} ref {s}\n",
                    .{
                        slot.screen_position.x,
                        slot.screen_position.y,
                        slot.size,
                        slot.size,
                        slot.screen_position.x + @divTrunc(slot.size, 2),
                        slot.screen_position.y + @divTrunc(slot.size, 2),
                        @tagName(slot_ref),
                    },
                ) catch @panic("failed to format ui dump");
                surfaces += 1;
            },
            else => {},
        }
    }
    if (surfaces == 0) {
        buffer.appendSlice(allocator, "none\n") catch @panic("failed to format ui dump");
    }
    return buffer.items;
}

fn dumpBindingsText(history: *GameStateHistory, allocator: std.mem.Allocator) []const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    const bindings = history.settings.input_bindings;
    buffer.print(allocator, "{d} bindings\n", .{bindings.len}) catch
        @panic("failed to format bindings dump");
    for (bindings) |binding| {
        const id = switch (binding.input) {
            .key => |name| name,
            .mouse_button => |name| name,
            .gamepad_button => |name| name,
        };
        buffer.appendSlice(allocator, if (binding.modifiers.ctrl) "ctrl+" else "") catch
            @panic("failed to format bindings dump");
        buffer.appendSlice(allocator, if (binding.modifiers.shift) "shift+" else "") catch
            @panic("failed to format bindings dump");
        buffer.appendSlice(allocator, if (binding.modifiers.alt) "alt+" else "") catch
            @panic("failed to format bindings dump");
        buffer.print(allocator, "{s} -> {s} ({s})\n", .{
            id,
            @tagName(binding.action),
            contextListText(allocator, types.actionBindingContexts(binding.action)),
        }) catch @panic("failed to format bindings dump");
    }
    return buffer.items;
}

const all_binding_contexts = [_]types.BindingContext{ .anytime, .game, .editor, .menu, .error_popup };

/// The active contexts of a set as a comma list ("anytime,game").
fn contextListText(allocator: std.mem.Allocator, contexts: types.BindingContextSet) []const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    for (all_binding_contexts) |context| {
        if (!contexts.contains(context)) continue;
        if (buffer.items.len > 0) {
            buffer.append(allocator, ',') catch @panic("failed to format binding contexts");
        }
        buffer.appendSlice(allocator, @tagName(context)) catch @panic("failed to format binding contexts");
    }
    if (buffer.items.len == 0) return "none";
    return buffer.items;
}

// ============================================================
// Tests
// ============================================================

const std_testing = std.testing;

test "parseCommandLine: every command shape" {
    const cases = [_]struct { line: []const u8, expected: ConsoleCommand }{
        .{ .line = "press Escape", .expected = .{ .press = .{ .key = storedText(IdText, "Escape") } } },
        .{ .line = "press KeyA", .expected = .{ .press = .{ .key = storedText(IdText, "KeyA") } } },
        .{ .line = "press left", .expected = .{ .press = .{ .mouse = storedText(IdText, "left") } } },
        .{ .line = "release right", .expected = .{ .release = .{ .mouse = storedText(IdText, "right") } } },
        .{ .line = "release ArrowLeft", .expected = .{ .release = .{ .key = storedText(IdText, "ArrowLeft") } } },
        .{ .line = "move 640 360", .expected = .{ .move = .{ .x = 640, .y = 360 } } },
        .{ .line = "move -12.5 0", .expected = .{ .move = .{ .x = -12.5, .y = 0 } } },
        .{ .line = "scroll 1", .expected = .{ .scroll = 1 } },
        .{ .line = "scroll -3", .expected = .{ .scroll = -3 } },
        .{ .line = "type New Player", .expected = .{ .type_text = storedText(TypeText, "New Player") } },
        .{ .line = "action escape", .expected = .{ .action = .escape } },
        .{ .line = "action save_game", .expected = .{ .action = .save_game } },
        .{ .line = "wait 60", .expected = .{ .wait = 60 } },
        .{ .line = "wait 0", .expected = .{ .wait = 0 } },
        .{ .line = "dump state", .expected = .{ .dump = .state } },
        .{ .line = "dump ui", .expected = .{ .dump = .ui } },
        .{ .line = "dump settings", .expected = .{ .dump = .settings } },
        .{ .line = "dump bindings", .expected = .{ .dump = .bindings } },
        .{ .line = "dump history", .expected = .{ .dump = .history } },
        .{ .line = "quit", .expected = .quit },
        // Whitespace tolerance: leading/trailing spaces, split verbs.
        .{ .line = "  press   Escape  ", .expected = .{ .press = .{ .key = storedText(IdText, "Escape") } } },
    };
    for (cases) |case| {
        const outcome = parseCommandLine(case.line);
        try std_testing.expect(outcome == .command);
        try std_testing.expectEqualDeep(case.expected, outcome.command);
    }
}

test "parseCommandLine: empty lines and comments skip" {
    try std_testing.expect(parseCommandLine("") == .skip);
    try std_testing.expect(parseCommandLine("   ") == .skip);
    try std_testing.expect(parseCommandLine("# a comment") == .skip);
    try std_testing.expect(parseCommandLine("   # indented comment") == .skip);
}

test "parseCommandLine: errors name the problem" {
    const error_cases = [_]struct { line: []const u8, contains: []const u8 }{
        .{ .line = "juggle", .contains = "unknown console command 'juggle'" },
        .{ .line = "press", .contains = "press requires an input id" },
        .{ .line = "press nope", .contains = "input id 'nope' names an input no platform mapping can produce" },
        .{ .line = "press LEFT", .contains = "input id 'LEFT' names an input no platform mapping can produce" },
        .{ .line = "action wiggle", .contains = "unknown action 'wiggle'" },
        .{ .line = "action", .contains = "action requires an action name" },
        .{ .line = "move 640", .contains = "move requires exactly two numbers" },
        .{ .line = "move 640 360 12", .contains = "move requires exactly two numbers" },
        .{ .line = "move a b", .contains = "move x 'a' is not a number" },
        .{ .line = "move 0 b", .contains = "move y 'b' is not a number" },
        .{ .line = "scroll", .contains = "scroll requires a delta" },
        .{ .line = "scroll lots", .contains = "scroll delta 'lots' is not a number" },
        .{ .line = "wait", .contains = "wait requires a frame count" },
        .{ .line = "wait -1", .contains = "wait count '-1' is not a non-negative integer" },
        .{ .line = "dump", .contains = "unknown dump kind ''" },
        .{ .line = "dump everything", .contains = "unknown dump kind 'everything'" },
        .{ .line = "quit now", .contains = "quit takes no arguments" },
    };
    for (error_cases) |case| {
        const outcome = parseCommandLine(case.line);
        try std_testing.expect(outcome == .err);
        try std_testing.expect(std.mem.indexOf(u8, outcome.err.view(), case.contains) != null);
    }
}

test "parseCommandLine: a type payload over capacity errors instead of truncating" {
    var long_line: [max_type_text_len + 16]u8 = undefined;
    @memcpy(long_line[0..5], "type ");
    @memset(long_line[5..], 'x');
    const outcome = parseCommandLine(&long_line);
    try std_testing.expect(outcome == .err);
    try std_testing.expect(std.mem.indexOf(u8, outcome.err.view(), "exceeds 256 characters") != null);
}

test "queue: push/take roundtrip preserves order; empty yields null" {
    var queue: ConsoleQueue = .{};
    try std_testing.expect(queue.takeFrameCommand() == null);

    queue.push(parseCommandLine("press Escape").command);
    queue.push(parseCommandLine("move 10 20").command);
    queue.push(parseCommandLine("quit").command);

    const first = queue.takeFrameCommand().?;
    try std_testing.expect(first == .press);
    const second = queue.takeFrameCommand().?;
    try std_testing.expect(second == .move);
    const third = queue.takeFrameCommand().?;
    try std_testing.expect(third == .quit);
    try std_testing.expect(queue.takeFrameCommand() == null);
}

test "queue: wait n spaces surrounding commands n idle frames apart" {
    var queue: ConsoleQueue = .{};
    queue.push(parseCommandLine("press KeyA").command);
    queue.push(parseCommandLine("wait 2").command);
    queue.push(parseCommandLine("press KeyB").command);

    // Frame 1: the press before the wait.
    try std_testing.expect(queue.takeFrameCommand().? == .press);
    // Frame 2: the wait pops, arms 2 idle frames, yields nothing.
    try std_testing.expect(queue.takeFrameCommand() == null);
    // Frames 3 + 4: the armed idle frames.
    try std_testing.expect(queue.takeFrameCommand() == null);
    try std_testing.expect(queue.takeFrameCommand() == null);
    // Frame 5: the command after the wait — 3 frames after the wait itself.
    const after = queue.takeFrameCommand().?;
    try std_testing.expect(after == .press);
    try std_testing.expectEqualStrings("KeyB", after.press.key.view());
}

test "mergeIntoPlatformInput: input commands append to the backend's frame" {
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    const backend_events = [_]PlatformInputEvent{.{ .key_down = "KeyZ" }};
    const backend_input = PlatformInput{
        .events = &backend_events,
        .viewport = .{ .width = 2560, .height = 2160 },
        .text_characters = "hi",
    };

    // press appends a key_down with an arena-owned copy of the id.
    {
        var queue: ConsoleQueue = .{};
        queue.push(parseCommandLine("press Escape").command);
        const command = queue.takeFrameCommand().?;
        const merged = mergeIntoPlatformInput(command, backend_input, arena);
        try std_testing.expectEqual(@as(usize, 2), merged.events.len);
        try std_testing.expectEqualStrings("KeyZ", merged.events[0].key_down);
        try std_testing.expectEqualStrings("Escape", merged.events[1].key_down);
        // Arena-owned, not aliasing queue memory: a different address than
        // the command's own bytes (the queue slot).
        try std_testing.expect(merged.events[1].key_down.ptr != command.press.key.view().ptr);
        // Untouched fields pass through.
        try std_testing.expectEqualStrings("hi", merged.text_characters);
        try std_testing.expectEqual(@as(usize, 0), merged.actions.len);
    }

    // release + mouse ids.
    {
        const merged = mergeIntoPlatformInput(
            parseCommandLine("release left").command,
            backend_input,
            arena,
        );
        try std_testing.expectEqualStrings("left", merged.events[1].mouse_button_up);
    }

    // move + scroll.
    {
        const move_merged = mergeIntoPlatformInput(parseCommandLine("move 3 4").command, backend_input, arena);
        try std_testing.expectEqual(@as(f32, 3), move_merged.events[1].mouse_move.x);
        try std_testing.expectEqual(@as(f32, 4), move_merged.events[1].mouse_move.y);
        const scroll_merged = mergeIntoPlatformInput(parseCommandLine("scroll -2").command, backend_input, arena);
        try std_testing.expectEqual(@as(f32, -2), scroll_merged.events[1].mouse_scroll);
    }

    // type appends to the backend's text characters (verbatim after the
    // verb's one separator — a doubled space types a leading space).
    {
        const merged = mergeIntoPlatformInput(parseCommandLine("type  there").command, backend_input, arena);
        try std_testing.expectEqualStrings("hi there", merged.text_characters);
        try std_testing.expectEqual(@as(usize, 1), merged.events.len);
    }

    // action lands in the actions slice (not events).
    {
        const merged = mergeIntoPlatformInput(parseCommandLine("action escape").command, backend_input, arena);
        try std_testing.expectEqual(@as(usize, 1), merged.events.len);
        try std_testing.expectEqual(@as(usize, 1), merged.actions.len);
        try std_testing.expectEqual(types.Action.escape, merged.actions[0]);
    }

    // Non-input commands pass the backend input through unchanged.
    {
        const merged = mergeIntoPlatformInput(parseCommandLine("quit").command, backend_input, arena);
        try std_testing.expectEqual(@as(usize, 1), merged.events.len);
        try std_testing.expectEqualStrings("hi", merged.text_characters);
    }
}

test "foldInjectedActions: applies the merged action at the button seam" {
    var player_input: input.PlayerInput = .{};
    try std_testing.expect(!player_input.anytime.escape);

    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    const merged = mergeIntoPlatformInput(
        parseCommandLine("action escape").command,
        PlatformInput{ .events = &.{}, .viewport = .{ .width = 1280, .height = 1080 } },
        backing.allocator(),
    );
    foldInjectedActions(&player_input, merged);
    try std_testing.expect(player_input.anytime.escape);
}

test "applyFrameCommand: quit requests the session quit; empty queue passes through" {
    const test_harness = @import("test_harness.zig");
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    var queue: ConsoleQueue = .{};
    const backend_input = PlatformInput{ .events = &.{}, .viewport = .{ .width = 1280, .height = 1080 } };

    // Empty queue: the backend input returns unchanged (value-equal —
    // empty-slice pointers are not comparable).
    const passed_through = applyFrameCommand(&queue, backend_input, backing.allocator(), &history, &.{});
    try std_testing.expectEqualDeep(backend_input, passed_through);
    try std_testing.expect(!history.session.quit_requested);

    queue.push(parseCommandLine("quit").command);
    _ = applyFrameCommand(&queue, backend_input, backing.allocator(), &history, &.{});
    try std_testing.expect(history.session.quit_requested);
}

test "dumpText: projections report the state they are handed" {
    const test_harness = @import("test_harness.zig");
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    // state: a main-menu history — screen + no world.
    const state_text = dumpText(.state, &history, &.{}, arena);
    try std_testing.expect(std.mem.indexOf(u8, state_text, "screen: main_menu") != null);
    try std_testing.expect(std.mem.indexOf(u8, state_text, "entities: none (no world)") != null);

    // ui: reflects the session's UI flags.
    history.session.ui_state.options_menu_open = true;
    history.session.ui_state.keybind_scroll_offset = 4;
    const ui_text = dumpText(.ui, &history, &.{}, arena);
    try std_testing.expect(std.mem.indexOf(u8, ui_text, "options_menu_open: true") != null);
    try std_testing.expect(std.mem.indexOf(u8, ui_text, "keybind_scroll_offset: 4") != null);

    // settings: the writer's own full-file text.
    const settings_text = dumpText(.settings, &history, &.{}, arena);
    const written = writers.writeSettings(history.settings, arena) catch unreachable;
    try std_testing.expectEqualStrings(written, settings_text);

    // bindings: one line per binding, derived from the same list.
    const bindings_text = dumpText(.bindings, &history, &.{}, arena);
    const binding_lines = std.mem.count(u8, bindings_text, " -> ");
    try std_testing.expectEqual(history.settings.input_bindings.len, binding_lines);
    if (history.settings.input_bindings.len > 0) {
        const first = history.settings.input_bindings[0];
        try std_testing.expect(std.mem.indexOf(u8, bindings_text, @tagName(first.action)) != null);
    }

    // history: the session-log body.
    const history_text = dumpText(.history, &history, &.{}, arena);
    try std_testing.expect(std.mem.indexOf(u8, history_text, "EventLog") != null);
}

test "dumpText ui: interactive surfaces list rects + ready-to-use click centers" {
    const test_harness = @import("test_harness.zig");
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    const elements = [_]ui.UiElement{
        .{ .button = .{
            .screen_position = .{ .x = 1408, .y = 1176 },
            .width = 1024,
            .height = 160,
            .action = .toggle_load_save_menu,
        } },
        .{ .slider = .{
            .setting_id = .master_volume,
            .min = 0,
            .max = 100,
            .value = 50,
            .screen_position = .{ .x = 512, .y = 208 },
            .width = 320,
            .height = 48,
        } },
        .{ .text_field = .{
            .screen_position = .{ .x = 300, .y = 400 },
            .width = 512,
            .height = 64,
            .text_position = .{ .x = 312, .y = 412 },
            .text = "Wolf Pup",
            .font_size = 48,
            .frame_color = .{ .r = 255, .g = 255, .b = 255 },
            .ref = .{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } },
        } },
        .{ .slot = .{
            .screen_position = .{ .x = 100, .y = 200 },
            .size = 128,
            .ref = .{ .skill_bar = 0 },
        } },
    };

    const text = dumpText(.ui, &history, &elements, arena);

    // Each surface's line: rect + center (a valid click point — the exact
    // coordinate a `move` + `press left`/`release left` pair acts at) + the
    // semantic identity (action / setting / text / ref).
    try std_testing.expect(std.mem.indexOf(
        u8,
        text,
        "button 1408 1176 1024 160 center 1920 1256 action toggle_load_save_menu\n",
    ) != null);
    try std_testing.expect(std.mem.indexOf(
        u8,
        text,
        "slider 512 208 320 48 center 672 232 setting master_volume value 50 min 0 max 100\n",
    ) != null);
    try std_testing.expect(std.mem.indexOf(
        u8,
        text,
        "text_field 300 400 512 64 center 556 432 text Wolf Pup\n",
    ) != null);
    try std_testing.expect(std.mem.indexOf(
        u8,
        text,
        "slot 100 200 128 128 center 164 264 ref skill_bar\n",
    ) != null);

    // An element list with no interactive surfaces reports none.
    const empty_text = dumpText(.ui, &history, &.{}, arena);
    try std_testing.expect(std.mem.indexOf(u8, empty_text, "interactive surfaces") != null);
    try std_testing.expect(std.mem.indexOf(u8, empty_text, "none\n") != null);
}

test "writeDumpText: writes the projection to the output writer" {
    const test_harness = @import("test_harness.zig");
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    // The Allocating writer passed by its real parent pointer (the vtable
    // resolves the parent via fieldParentPtr — the same shape the native
    // wiring's File.Writer parent has).
    var allocating: std.Io.Writer.Allocating = .init(std_testing.allocator);
    defer allocating.deinit();
    writeDumpText(.state, &allocating.writer, &history, &.{});

    const written = allocating.written();
    try std_testing.expect(std.mem.indexOf(u8, written, "screen: main_menu") != null);
    try std_testing.expect(written[written.len - 1] == '\n');
}
