//! Console input - stdin as a scripted input channel (TAS-shaped). The
//! command vocabulary + parser, the reader-thread-facing queue, the
//! per-frame drain + PlatformInput merge, the action fold, and the dump
//! routing (path dumps → dump_walker.zig, pure reflection; the curated
//! ui/level projections stay here - derived facts that exist as no
//! stored state). Everything here is raylib-free; the reader thread + stdout
//! output writer are wired only by the native driver (native.zig) - with no
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
const dump_walker = @import("dump_walker.zig");
const ui = @import("ui.zig");
const view = @import("view.zig");

const GameStateHistory = state.GameStateHistory;
const PlatformInput = input.PlatformInput;
const PlatformInputEvent = input.PlatformInputEvent;

// ============================================================
// Bounded text - fixed-buffer strings, no allocation
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

/// Every input id the console accepts (the binding vocabulary - see
/// `types.producible_key_ids` / `producible_mouse_ids`).
const max_id_len = 32;
/// Longest `dump <path>` field path (see dump_walker.zig).
const max_path_len = 128;
/// Longest `type <text>` payload.
const max_type_text_len = 256;
/// Longest parse-error message.
const max_message_len = 256;

const IdText = BoundedText(max_id_len);
const TypeText = BoundedText(max_type_text_len);
const MessageText = BoundedText(max_message_len);
const PathText = BoundedText(max_path_len);

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
    /// Fire a semantic action - folded via `applyAction`, the same seam
    /// button clicks use (context-free; the consumption sites gate
    /// themselves). Payload-less actions only (the keybind vocabulary).
    action: types.Action,
    /// Hold commands until the game is idle (stack empty, no wait, no
    /// modal error - the same condition under which the game accepts
    /// player input). The pacing primitive for scripted turn flow: enemy
    /// turns drain over real-clock waits, and a frame count is a guess;
    /// `wait idle` releases the next command on the first frame the game
    /// would accept input again.
    wait_idle: void,
    /// Skip n frames before the next command (the pacing primitive).
    wait: u32,
    /// Write a field path's reflection to stdout (see dump_walker.zig).
    /// An empty path renders the root table of contents.
    dump: PathText,
    /// Write a CURATED report to stdout - derived facts that exist as no
    /// stored state (click centers, legal-target highlights), hand-
    /// maintained by design (the state mirrors went to `dump <path>`).
    report: ReportKind,
    /// Print the command list - the verb table, the console's single
    /// declaration of its own vocabulary (see `verb_table`). The
    /// discoverability entry point: everything printed is a
    /// tested-working line (the both-ways test parses every example).
    help: void,
    /// Print the full input-id vocabulary - the producible-id tables the
    /// parser validates `press`/`release` against (and the same ids the
    /// settings bindings name). Machine-walked: the print cannot lie, and
    /// new ids appear automatically.
    inputs: void,
    /// Request the session quit (the Exit Game path).
    quit: void,

    pub const CommandInputId = union(enum) {
        key: IdText,
        mouse: IdText,
    };

    pub const ReportKind = enum { ui, level };
};

/// The result of parsing one stdin line.
pub const ParseOutcome = union(enum) {
    /// Empty line or `#` comment - nothing to enqueue.
    skip: void,
    command: ConsoleCommand,
    /// The line's shape is wrong; the message names the problem (printed by
    /// the reader thread).
    err: MessageText,

    /// The err arm's message text (valid only when the outcome is `.err` -
    /// the reader thread's stderr report). Pointer self: the returned slice
    /// must point into the CALLER's outcome, not a by-value copy's dead
    /// frame.
    pub fn errorMessage(self: *const ParseOutcome) []const u8 {
        return self.err.view();
    }
};

// ============================================================
// Parser - one verb table owns the vocabulary
// ============================================================

/// One console verb - the single declaration of the console's command
/// vocabulary. The parser dispatches on `name`; `help` prints the entry
/// (columns aligned at comptime from the table's own widths); the both-ways
/// test parses every `example`, so everything `help` shows is a
/// tested-working command line, and a new `ConsoleCommand` variant is a test
/// failure until an example covers it. There is no second list to drift
/// against - the parser's accepted verbs ARE this table's names.
const VerbEntry = struct {
    name: []const u8,
    /// The argument shape, printed by `help` ("" = argument-less).
    args: []const u8,
    description: []const u8,
    /// Real, parsing command lines - test fixtures + the printed examples.
    /// The both-ways test walks them all (see the struct doc).
    examples: []const []const u8,
    /// Parse the verb's arguments into a command (or an error outcome).
    /// `rest` is the untrimmed rest-of-line (`type` consumes it verbatim);
    /// `argument` is the fully-trimmed remainder (every other verb).
    parse: *const fn (rest: []const u8, argument: []const u8) ParseOutcome,
};

const verb_table = [_]VerbEntry{
    .{
        .name = "press",
        .args = "<id>",
        .description = "press a key or mouse button (chords work across frames)",
        .examples = &.{"press Escape"},
        .parse = parsePress,
    },
    .{
        .name = "release",
        .args = "<id>",
        .description = "release a held key or button (completes the held model)",
        .examples = &.{"release KeyA"},
        .parse = parseRelease,
    },
    .{
        .name = "move",
        .args = "<x> <y>",
        .description = "move the pointer, reference-space pixels",
        .examples = &.{"move 640 360"},
        .parse = parseMove,
    },
    .{
        .name = "scroll",
        .args = "<delta>",
        .description = "scroll; positive = up",
        .examples = &.{"scroll 1"},
        .parse = parseScroll,
    },
    .{
        .name = "type",
        .args = "<text>",
        .description = "type text into the focused text field (the rest of the line)",
        .examples = &.{"type New Player"},
        .parse = parseType,
    },
    .{
        .name = "action",
        .args = "<name>",
        .description = "fire a semantic action (the keybind vocabulary)",
        .examples = &.{"action escape"},
        .parse = parseAction,
    },
    .{
        .name = "wait",
        .args = "<n> | idle",
        .description = "skip n frames, or hold until the game is idle (scripted turn-flow pacing)",
        .examples = &.{ "wait 60", "wait idle" },
        .parse = parseWait,
    },
    .{
        .name = "dump",
        .args = "<path>",
        .description = "field-path reflection over the live state (bare dump: the root contents)",
        .examples = &.{ "dump history.session.tile_cursor", "dump" },
        .parse = parseDump,
    },
    .{
        .name = "report",
        .args = "ui | level",
        .description = "curated projections: interactive surfaces / the active world",
        .examples = &.{"report ui"},
        .parse = parseReport,
    },
    .{
        .name = "help",
        .args = "",
        .description = "this command list",
        .examples = &.{"help"},
        .parse = parseHelp,
    },
    .{
        .name = "inputs",
        .args = "",
        .description = "every input id press/release accept (the bindings vocabulary)",
        .examples = &.{"inputs"},
        .parse = parseInputs,
    },
    .{
        .name = "quit",
        .args = "",
        .description = "request the session quit",
        .examples = &.{"quit"},
        .parse = parseQuit,
    },
};

/// Parse one console command line (no trailing newline). The line is
/// space-separated: a verb, then its arguments; `type`'s argument is the rest
/// of the line verbatim. Dispatch is the verb table above - one declaration
/// owns the vocabulary (see `VerbEntry`). Verbs, ids, action names, and dump
/// kinds are all exact-match (case-sensitive) - they name enum values the
/// engine consumes.
pub fn parseCommandLine(line: []const u8) ParseOutcome {
    const trimmed = std.mem.trim(u8, line, " \t\r");

    if (trimmed.len == 0 or trimmed[0] == '#') return .skip;

    const verb, const rest = splitFirstWord(trimmed);
    // Verbs other than `type` take single-token arguments - trim fully.
    // `type`'s payload is the rest of the line (its parse fn reads `rest`).
    const argument = std.mem.trim(u8, rest, " \t");

    inline for (verb_table) |entry| {
        if (std.mem.eql(u8, verb, entry.name)) return entry.parse(rest, argument);
    }
    return formattedMessage("unknown console command '{s}' - type 'help' for the command list", .{verb});
}

fn parseQuit(_: []const u8, argument: []const u8) ParseOutcome {
    if (argument.len > 0) return staticMessage("quit takes no arguments");
    return .{ .command = .quit };
}

fn parseHelp(_: []const u8, argument: []const u8) ParseOutcome {
    if (argument.len > 0) return staticMessage("help takes no arguments");
    return .{ .command = .help };
}

fn parseInputs(_: []const u8, argument: []const u8) ParseOutcome {
    if (argument.len > 0) return staticMessage("inputs takes no arguments");
    return .{ .command = .inputs };
}

fn parsePress(_: []const u8, argument: []const u8) ParseOutcome {
    if (argument.len == 0 or argument.len > max_id_len) {
        return staticMessage("press requires an input id (press Escape, press left)");
    }
    const command_id = classifyInputId(argument) orelse return unknownInputIdMessage(argument);
    return .{ .command = .{ .press = command_id } };
}

fn parseRelease(_: []const u8, argument: []const u8) ParseOutcome {
    if (argument.len == 0 or argument.len > max_id_len) {
        return staticMessage("release requires an input id (press Escape, press left)");
    }
    const command_id = classifyInputId(argument) orelse return unknownInputIdMessage(argument);
    return .{ .command = .{ .release = command_id } };
}

/// press/release share the unknown-id message (both validate against the
/// producible-id vocabulary; the full list is the `inputs` command).
fn unknownInputIdMessage(id: []const u8) ParseOutcome {
    return formattedMessage(
        "input id '{s}' names an input no platform mapping can produce; ids are W3C key codes (KeyA, Escape, ArrowLeft, ...) or mouse buttons (left, right, middle); the full list: inputs",
        .{id},
    );
}

fn parseMove(_: []const u8, argument: []const u8) ParseOutcome {
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

fn parseScroll(_: []const u8, argument: []const u8) ParseOutcome {
    if (argument.len == 0) return staticMessage("scroll requires a delta (scroll 1; positive = up)");
    const delta = std.fmt.parseFloat(f32, argument) catch
        return formattedMessage("scroll delta '{s}' is not a number", .{argument});
    return .{ .command = .{ .scroll = delta } };
}

fn parseType(rest: []const u8, _: []const u8) ParseOutcome {
    // `rest` is verbatim: splitFirstWord already consumed exactly one
    // separator after the verb, so a doubled space types a leading
    // space ("type  x" types " x"). The whole line was trimmed at
    // both ends by the dispatcher, so trailing whitespace is not typable.
    if (rest.len == 0) return staticMessage("type requires text (the rest of the line)");
    if (rest.len > max_type_text_len) {
        return staticMessage("type text exceeds 256 characters");
    }
    return .{ .command = .{ .type_text = storedText(TypeText, rest) } };
}

fn parseAction(_: []const u8, argument: []const u8) ParseOutcome {
    if (argument.len == 0) return staticMessage("action requires an action name (action escape)");
    const action = std.meta.stringToEnum(types.Action, argument) orelse
        return formattedMessage("unknown action '{s}'", .{argument});
    return .{ .command = .{ .action = action } };
}

fn parseWait(_: []const u8, argument: []const u8) ParseOutcome {
    if (argument.len == 0) return staticMessage("wait requires a frame count (wait 60) or 'idle'");
    if (std.mem.eql(u8, argument, "idle")) return .{ .command = .{ .wait_idle = {} } };
    const frames = std.fmt.parseInt(u32, argument, 10) catch
        return formattedMessage("wait count '{s}' is not a non-negative integer", .{argument});
    return .{ .command = .{ .wait = frames } };
}

fn parseDump(_: []const u8, argument: []const u8) ParseOutcome {
    // `dump` is PURELY the path mirror (the curated projections are
    // the `report` verb - two verbs, two semantics, no namespace
    // overlap). Bare `dump`: the root table of contents (empty
    // path). A path naming a nonexistent field errors at dump time,
    // truthfully, against the live state.
    if (argument.len > max_path_len) {
        return formattedMessage("dump path exceeds {d} characters", .{max_path_len});
    }
    for (argument) |char| switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '[', ']' => {},
        else => return staticMessage("dump path may contain only letters, digits, '_', '.', '[' and ']'"),
    };
    return .{ .command = .{ .dump = storedText(PathText, argument) } };
}

fn parseReport(_: []const u8, argument: []const u8) ParseOutcome {
    if (std.mem.eql(u8, argument, "ui")) return .{ .command = .{ .report = .ui } };
    if (std.mem.eql(u8, argument, "level")) return .{ .command = .{ .report = .level } };
    return formattedMessage("unknown report kind '{s}' (ui, level)", .{argument});
}

/// Split `text` at its first whitespace run: the word before, the remainder
/// after (untrimmed - callers trim).
fn splitFirstWord(text: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfAny(u8, text, " \t")) |separator_index| {
        return .{ text[0..separator_index], text[separator_index + 1 ..] };
    }
    return .{ text, "" };
}

/// Classify an input id as a key or mouse id by the binding vocabulary (the
/// producible-id lists; a gamepad id is unproducible - no gamepad table).
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
/// with atomic monotonic counters - no mutex (Zig 0.16's std locks need an Io
/// handle on BOTH threads, and the game thread has none to give inside
/// frame()). A full queue BLOCKS the reader (yield-spin backpressure), so a
/// piped script faster than the frame drain can never drop or reorder
/// commands - the reader paces the game until the backlog drains.
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
    /// Set by a popped `wait idle` (game thread only): hold commands until
    /// the game is idle, then release the next command on that same frame.
    wait_until_idle: bool = false,
    /// The console's remembered pointer position - set by `move`, persists
    /// across frames like held keys (the console's pointer is where the
    /// console left it). The native backend re-reports the hardware pointer
    /// position EVERY frame (unconditionally), which would otherwise
    /// overwrite a scripted position before the next command lands - so
    /// every INPUT-command frame re-applies this position ahead of the
    /// command's own events (last writer wins within the frame; see
    /// `applyFrameCommand`). Frames between commands stay on the hardware
    /// position - a human at the window never loses the pointer. Game
    /// thread only (set + read in applyFrameCommand).
    pointer_position: ?input.PointerPosition = null,
    /// The last command TAKEN by the frame drain (any kind - input, dump,
    /// quit, waits included), recorded for `dump console_queue.last_taken_command`
    /// (which command consumed a given frame - TAS pacing visibility).
    /// A by-value copy taken at pop, before the reader thread can reuse
    /// the slot. Game thread only.
    last_taken_command: ?ConsoleCommand = null,
    /// Dump output goes here (stdout), wired by the native driver. Without a
    /// writer there is no reader thread either (web), so a dump can never
    /// arrive. Stored as the concrete parent (the File.Writer owns its
    /// interface; the vtable resolves the parent via fieldParentPtr, so an
    /// interface copy would dangle).
    output: ?std.Io.File.Writer = null,
    output_buffer: [output_buffer_capacity]u8 = undefined,
    /// A human is typing at the other end - set once by the native driver
    /// at wiring from `isTty(stdin)`. Gates ONLY the console-ready prompt
    /// (see `promptDue`): the channel itself stays always-on by design - a
    /// piped script drives identically, just unprompted (a prompt over a
    /// pipe is a lie: it invites typing, but the reader is consuming the
    /// script), and an stdin-less launch (double-click, the mac bundle)
    /// prints nothing at all.
    interactive: bool = false,

    const queue_capacity = 64;
    const output_buffer_capacity = 4096;

    /// Enqueue one parsed command (reader thread). Blocks while the queue is
    /// full - yield-spin backpressure (the exit condition is the drain, not
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
    /// frames remain, each call decrements and yields null - so `wait n`
    /// spaces the surrounding commands n idle frames apart. A popped
    /// `wait idle` holds until `game_is_idle` (computed by the caller from
    /// the game state), then releases the next command on that same frame.
    fn takeFrameCommand(self: *ConsoleQueue, game_is_idle: bool) ?ConsoleCommand {
        if (self.wait_until_idle) {
            if (!game_is_idle) return null;
            self.wait_until_idle = false;
            // Fall through: the next command releases on the first idle
            // frame, not the one after.
        }
        if (self.wait_frames_remaining > 0) {
            self.wait_frames_remaining -= 1;
            return null;
        }
        const read = self.read_counter.load(.monotonic);
        // Empty: nothing pushed past what was popped.
        if (read == self.write_counter.load(.acquire)) return null;
        const command = self.commands[read % queue_capacity];
        // The observability record: which command this frame took (a
        // by-value copy - the slot is reader-thread memory, reusable once
        // the counter below publishes the pop).
        self.last_taken_command = command;
        // Release: the slot is consumed before the counter that frees it for
        // the producer's reuse.
        self.read_counter.store(read +% 1, .release);
        if (command == .wait) {
            self.wait_frames_remaining = command.wait;
            return null;
        }
        if (command == .wait_idle) {
            self.wait_until_idle = true;
            return null;
        }
        return command;
    }
};

// ============================================================
// The console-ready prompt
// ============================================================

/// Whether the console-ready prompt (`> `) is due after the frame drain
/// took `taken` - the game thread's marker that the channel can take the
/// next line. The GAME thread prints it (not the reader: stdout already
/// has exactly one writer - the game thread, via the queue's output -
/// and a reader-side prompt would race the next frame's dump output onto
/// a stale prompt line). Conditions: a HUMAN is typing (`interactive` - a
/// piped script is unprompted by design), the taken command wasn't `quit`
/// (the process is exiting), and the queue has DRAINED - pasted
/// multi-line input prompts once, after the last command, not once per
/// line. Mid-hold frames print nothing by construction: `wait` /
/// `wait idle` arm inside `takeFrameCommand` and never reach the caller's
/// switch, and the frame that ends a hold releases a real command whose
/// own drain check applies.
fn promptDue(queue: *const ConsoleQueue, taken: ConsoleCommand) bool {
    if (taken == .quit) return false;
    if (!queue.interactive) return false;
    const read = queue.read_counter.load(.monotonic);
    return read == queue.write_counter.load(.acquire);
}

/// Print the console-ready prompt: `> `, no newline, best-effort (a
/// failed write never surfaces - the console is a convenience channel,
/// not a game system). Called by `applyFrameCommand` via `promptDue` and
/// by the boot announcement below.
fn printPrompt(queue: *ConsoleQueue) void {
    if (queue.output) |*output| {
        output.interface.writeAll("> ") catch return;
        output.interface.flush() catch return;
    }
}

/// The boot half of the console's discoverability surface: when a human
/// is typing (`interactive`), one hint line pointing at `help` + the first
/// ready prompt. Called by the native driver at wiring; the per-command
/// prompts are `applyFrameCommand`'s.
pub fn announceConsoleInput(queue: *ConsoleQueue) void {
    if (!queue.interactive) return;
    if (queue.output) |*output| {
        output.interface.writeAll("console input on stdin - type help for the command list\n") catch return;
        output.interface.flush() catch return;
    }
    printPrompt(queue);
}

// ============================================================
// Per-frame drain + merge
// ============================================================

/// The per-frame console step (called from `frame()` right after the backend
/// poll): drain one command and apply it. Input commands return the
/// backend's PlatformInput with the command merged in (frame-arena-owned
/// bytes); `quit` requests the session quit; `dump` writes its projection to
/// the queue's output writer. With an empty queue (no reader - web, EOF, or
/// between commands) the backend input returns unchanged.
pub fn applyFrameCommand(
    queue: *ConsoleQueue,
    backend_input: PlatformInput,
    arena: std.mem.Allocator,
    history: *GameStateHistory,
    /// The driver's root object (the FrameState) - the dump-path root,
    /// passed as anytype so console.zig never imports session_setup (the
    /// walker is generic over it; a test passes any struct with the
    /// fields its paths address). Read-only: the walker const-asserts it.
    frame_root: anytype,
    ui_elements: []const ui.UiElement,
    camera: types.Camera,
    camera_zoom: f32,
) PlatformInput {
    // The game is idle - the condition under which it accepts player input
    // (empty stack, no wait, no modal error): the release condition for
    // `wait idle`.
    const game_is_idle = history.current_state.event_stack.len == 0 and
        history.current_state.waiting == null and
        history.session.pending_error == null;
    const command = queue.takeFrameCommand(game_is_idle) orelse return backend_input;
    const merged: PlatformInput = switch (command) {
        .quit => blk: {
            history.session.quit_requested = true;
            break :blk backend_input;
        },
        .dump => |*path_text| blk: {
            writeDump(path_text.view(), queue, frame_root);
            break :blk backend_input;
        },
        .report => |kind| blk: {
            writeReport(kind, queue, history, ui_elements, camera, camera_zoom);
            break :blk backend_input;
        },
        .help => blk: {
            writeHelp(queue);
            break :blk backend_input;
        },
        .inputs => blk: {
            writeInputs(queue);
            break :blk backend_input;
        },
        // Popped waits never leave takeFrameCommand (they arm their own
        // idle frames / idle hold there) - this arm only keeps the switch
        // exhaustive.
        .wait, .wait_idle => backend_input,
        // `move` both remembers the position and applies it this frame.
        .move => |position| blk: {
            queue.pointer_position = position;
            break :blk mergeIntoPlatformInput(command, backend_input, arena);
        },
        // Press/release/scroll/type/action: re-apply the remembered pointer
        // position ahead of the command's own events (a mouse_move event
        // after the backend's per-frame hardware position - last writer
        // wins), so the command acts where the console moved the pointer,
        // frames later. Without a remembered position (no `move` yet), the
        // command acts at the hardware position.
        else => blk: {
            var merged_input = backend_input;
            if (queue.pointer_position) |position| {
                merged_input = mergeIntoPlatformInput(.{ .move = position }, merged_input, arena);
            }
            break :blk mergeIntoPlatformInput(command, merged_input, arena);
        },
    };
    // The console-ready prompt, AFTER the command's effect (a `dump`'s
    // output lands above the prompt, same thread, no interleaving). See
    // `promptDue`.
    if (promptDue(queue, command)) printPrompt(queue);
    return merged;
}

/// Merge one input command into the frame's PlatformInput. Key/mouse ids
/// resolve to their canonical static slices (`internedInputId`); typed text
/// is duped into the frame arena (same-frame consumption - the text-input
/// router copies it into the field buffer before the frame ends, so the
/// arena lifetime is sufficient).
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
        // Not input commands - applyFrameCommand handles them (the waits
        // never reach here either).
        .wait, .wait_idle, .dump, .report, .help, .inputs, .quit => {},
    }
    return merged;
}

const EventDirection = enum { down, up };

/// Build the raw event for a press/release. Takes a POINTER into the
/// caller's command (the id's bounded bytes are read here, then discarded -
/// the event carries the INTERNED static slice, not a view into the
/// command). The payload slice must be static-lifetime: `InputState`
/// retains it past the frame (a held key stays in `keys_held` until its
/// `release`), and the frame arena resets every frame.
fn inputEventFor(
    id: *const ConsoleCommand.CommandInputId,
    direction: EventDirection,
) PlatformInputEvent {
    return switch (id.*) {
        .key => |*key| switch (direction) {
            .down => .{ .key_down = internedInputId(key.view()) },
            .up => .{ .key_up = internedInputId(key.view()) },
        },
        .mouse => |*mouse| switch (direction) {
            .down => .{ .mouse_button_down = internedInputId(mouse.view()) },
            .up => .{ .mouse_button_up = internedInputId(mouse.view()) },
        },
    };
}

/// Resolve a console input id to its canonical STATIC-lifetime slice - the
/// same string literal `types.producible_key_ids` / `producible_mouse_ids`
/// (and the backend's key mappings) use. Console-merged events must carry
/// static ids, not frame-arena bytes: `InputState.keys_held` and
/// `key_repeat_state` retain the id slice PAST the frame (a held key), and
/// the frame arena resets every frame - an arena-duped id dangles there and
/// the next held-state comparison reads dead memory (observed live as a
/// segfault in `isHeld`). The parser already validated the id against these
/// same tables (`classifyInputId`), so the lookup cannot miss; the panic
/// names the invariant if a future seam breaks it.
fn internedInputId(id: []const u8) []const u8 {
    for (types.producible_key_ids) |producible_id| {
        if (std.mem.eql(u8, id, producible_id)) return producible_id;
    }
    for (types.producible_mouse_ids) |producible_id| {
        if (std.mem.eql(u8, id, producible_id)) return producible_id;
    }
    @panic("console input id was not validated at parse time");
}

/// Append one event to the frame's event list. The ARRAY is frame-arena-
/// owned (same-frame consumption - `translateInput` drains it before the
/// frame ends); the event's string payload is an interned static slice
/// (`internedInputId`), so nothing in the array aliases frame-lifetime
/// bytes.
fn appendEvent(
    arena: std.mem.Allocator,
    existing: []const PlatformInputEvent,
    event: PlatformInputEvent,
) []const PlatformInputEvent {
    const merged = arena.alloc(PlatformInputEvent, existing.len + 1) catch
        @panic("failed to allocate merged input events");
    @memcpy(merged[0..existing.len], existing);
    merged[existing.len] = event;
    return merged;
}

/// Fold platform-injected actions (the console `action` command, merged into
/// `PlatformInput.actions`) into the frame's PlayerInput - the same seam
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
// Dumps + reports
// ============================================================

/// Write one `dump <path>` reflection to the console output (stdout,
/// wired by the native driver): streamed through the walker, then
/// flushed. Best-effort - a failed write reports on stderr and never
/// surfaces as a crash (the diagnostics-write convention).
fn writeDump(
    path: []const u8,
    queue: *ConsoleQueue,
    frame_root: anytype,
) void {
    if (queue.output) |*output| {
        dump_walker.writeDump(&output.interface, frame_root, path);
        output.interface.flush() catch |err| {
            std.debug.print("console dump write failed: {s}\n", .{@errorName(err)});
        };
    }
}

/// Write one `report <kind>` curated projection to the console output
/// (arena-built text, then flushed - same best-effort convention).
fn writeReport(
    kind: ConsoleCommand.ReportKind,
    queue: *ConsoleQueue,
    history: *GameStateHistory,
    ui_elements: []const ui.UiElement,
    camera: types.Camera,
    camera_zoom: f32,
) void {
    if (queue.output) |*output| {
        writeReportToWriter(kind, &output.interface, history, ui_elements, camera, camera_zoom);
    }
}

/// The help table's column width - the widest `name args` usage pair, at
/// comptime - added verbs realign the printed list automatically.
const help_column_width = blk: {
    var width: usize = 0;
    for (verb_table) |entry| {
        const usage_len = entry.name.len + entry.args.len +
            (if (entry.args.len > 0) @as(usize, 1) else 0);
        width = @max(width, usage_len);
    }
    break :blk width;
};

/// Write the command list (`help`) to the console output - one line per
/// verb-table entry: the usage (name + argument shape) padded to the
/// table's own comptime column width, the description, then the entry's
/// examples (the both-ways test parses them, so everything printed here
/// is a tested-working command line).
fn writeHelp(queue: *ConsoleQueue) void {
    if (queue.output) |*output| {
        writeHelpToWriter(&output.interface);
        output.interface.flush() catch return;
    }
}

/// The writer-level help step (writeHelp minus the queue plumbing) -
/// separate so tests drive it with a fixed writer over memory.
fn writeHelpToWriter(output: *std.Io.Writer) void {
    output.writeAll("console commands:\n") catch return;
    inline for (verb_table) |entry| {
        const usage = if (entry.args.len > 0)
            entry.name ++ " " ++ entry.args
        else
            entry.name;
        output.writeAll("  ") catch return;
        output.writeAll(usage) catch return;
        var pad: usize = usage.len;
        while (pad < help_column_width) : (pad += 1) {
            output.writeAll(" ") catch return;
        }
        output.writeAll("  ") catch return;
        output.writeAll(entry.description) catch return;
        for (entry.examples, 0..) |example, example_index| {
            output.writeAll(if (example_index == 0) " (" else "; ") catch return;
            output.writeAll(example) catch return;
        }
        output.writeAll(")\n") catch return;
    }
}

/// Write the full input-id vocabulary (`inputs`) to the console output -
/// straight from the producible-id tables the parser validates against
/// (the same ids the settings bindings name). Machine-walked: the print
/// cannot lie, and new ids appear automatically.
fn writeInputs(queue: *ConsoleQueue) void {
    if (queue.output) |*output| {
        writeInputsToWriter(&output.interface);
        output.interface.flush() catch return;
    }
}

/// The wrap column for the `inputs` id lists.
const input_id_list_wrap_column = 80;

/// The writer-level inputs step (writeInputs minus the queue plumbing) -
/// separate so tests drive it with a fixed writer over memory. Ids print
/// in table order wrapped at the wrap column - the tables' existing
/// category ordering (modifiers → letters → digits → punctuation →
/// navigation → F-keys → numpad → media) reads as grouping without any
/// hand-maintained grouping.
fn writeInputsToWriter(output: *std.Io.Writer) void {
    output.writeAll("keys (W3C physical-key codes):\n") catch return;
    writeIdList(output, &types.producible_key_ids);
    output.writeAll("mouse buttons:\n") catch return;
    writeIdList(output, &types.producible_mouse_ids);
}

/// One id list: space-separated, wrapped at the wrap column.
fn writeIdList(output: *std.Io.Writer, ids: []const []const u8) void {
    var line_len: usize = 0;
    for (ids) |id| {
        if (line_len > 0 and line_len + 1 + id.len > input_id_list_wrap_column) {
            output.writeAll("\n") catch return;
            line_len = 0;
        }
        if (line_len > 0) {
            output.writeAll(" ") catch return;
            line_len += 1;
        }
        output.writeAll(id) catch return;
        line_len += id.len;
    }
    output.writeAll("\n") catch return;
}

/// The writer-level report step (writeReport minus the queue plumbing) -
/// separate so tests drive it with a fixed writer over memory.
fn writeReportToWriter(
    kind: ConsoleCommand.ReportKind,
    output: *std.Io.Writer,
    history: *GameStateHistory,
    ui_elements: []const ui.UiElement,
    camera: types.Camera,
    camera_zoom: f32,
) void {
    var arena = std.heap.ArenaAllocator.init(history.backing_allocator);
    defer arena.deinit();
    const text = reportText(kind, history, ui_elements, camera, camera_zoom, arena.allocator());
    output.writeAll(text) catch |err| {
        std.debug.print("console report write failed: {s}\n", .{@errorName(err)});
        return;
    };
    output.writeAll("\n") catch |err| {
        std.debug.print("console report write failed: {s}\n", .{@errorName(err)});
        return;
    };
    output.flush() catch |err| {
        std.debug.print("console report write failed: {s}\n", .{@errorName(err)});
        return;
    };
}

/// Build a CURATED report projection as text (the `report ui`/`report
/// level` kinds - derived facts, hand-maintained by design; the state
/// mirrors went to the walker, `dump <path>`).
fn reportText(
    kind: ConsoleCommand.ReportKind,
    history: *GameStateHistory,
    ui_elements: []const ui.UiElement,
    camera: types.Camera,
    camera_zoom: f32,
    allocator: std.mem.Allocator,
) []const u8 {
    return switch (kind) {
        .ui => dumpUiText(history, ui_elements, allocator),
        .level => dumpLevelText(history, camera, camera_zoom, allocator),
    };
}

/// The active world (level or hub) for gameplay decisions: turn phase,
/// entities (team / health / aggro / tile + click center), the phase's
/// legal-target highlights (the game's own computed move/skill targeting -
/// a script never reasons about legality, it clicks a highlight), the
/// player's utility skill slots + cooldowns, and the level-end flag /
/// mission exits (click centers - the world clickables a script drives).
/// Click centers project through the frame's LIVE camera
/// (`view.tileClickCenter`), so the coordinates resolve back to their
/// tiles via `screenToTile` at whatever zoom/pan is current.
fn dumpLevelText(
    history: *GameStateHistory,
    camera: types.Camera,
    camera_zoom: f32,
    allocator: std.mem.Allocator,
) []const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    const current = &history.current_state;

    if (current.level) |level| {
        buffer.print(allocator, "world: level \"{s}\"\n", .{level.name}) catch
            @panic("failed to format level dump");
        buffer.print(allocator, "turn_phase: {s}\n", .{
            if (level.turn_phase) |phase| @tagName(phase) else "none",
        }) catch @panic("failed to format level dump");
        buffer.print(allocator, "tiles: {d}\n", .{level.level_tiles.len}) catch
            @panic("failed to format level dump");
        if (level.level_end) |flag| {
            appendTileLine(&buffer, allocator, "level_end", flag, camera, camera_zoom);
        } else {
            buffer.appendSlice(allocator, "level_end: none\n") catch @panic("failed to format level dump");
        }
        buffer.print(allocator, "prepared_skill: {s}\n", .{
            if (level.prepared_skill) |skill| @tagName(skill) else "none",
        }) catch @panic("failed to format level dump");

        buffer.print(allocator, "highlights: {d}\n", .{level.highlighted_tiles.len}) catch
            @panic("failed to format level dump");
        for (level.highlighted_tiles) |tile| {
            appendTileLine(&buffer, allocator, "highlight", tile, camera, camera_zoom);
        }

        buffer.print(allocator, "entities: {d}\n", .{level.entities.len}) catch
            @panic("failed to format level dump");
        for (level.entities, 0..) |entity, index| {
            appendEntityLine(&buffer, allocator, index, entity, camera, camera_zoom);
        }
        if (level.entities.len > 0) {
            appendSkillLines(
                &buffer,
                allocator,
                level.entities[0],
                history.weapon_type_definitions,
            );
        }

        // Ground stacks: walking onto the tile picks them up (the pickup
        // radius; a pants' pickup_radius_bonus widens it).
        buffer.print(allocator, "ground items: {d}\n", .{level.ground_items.len}) catch
            @panic("failed to format level dump");
        for (level.ground_items) |stack| {
            const center = view.tileClickCenter(stack.position, camera, camera_zoom);
            buffer.print(
                allocator,
                "ground ({d}, {d}) center {d} {d}: ",
                .{ stack.position.x, stack.position.y, center.x, center.y },
            ) catch @panic("failed to format level dump");
            for (stack.items, 0..) |item, item_index| {
                if (item_index > 0) {
                    buffer.appendSlice(allocator, ", ") catch @panic("failed to format level dump");
                }
                buffer.appendSlice(allocator, itemSummary(item, allocator)) catch
                    @panic("failed to format level dump");
            }
            buffer.appendSlice(allocator, "\n") catch @panic("failed to format level dump");
        }

        if (level.entities.len > 0) {
            appendInventoryLines(&buffer, allocator, level.entities[0]);
        }
    } else if (current.hub) |hub| {
        buffer.print(allocator, "world: hub \"{s}\"\n", .{hub.name}) catch
            @panic("failed to format level dump");
        buffer.print(allocator, "tiles: {d}\n", .{hub.hub_tiles.len}) catch
            @panic("failed to format level dump");

        buffer.appendSlice(allocator, "entities: 1 + npcs\n") catch @panic("failed to format level dump");
        appendEntityLine(&buffer, allocator, 0, hub.player, camera, camera_zoom);
        for (hub.npcs, 0..) |npc, index| {
            const center = view.tileClickCenter(npc.position, camera, camera_zoom);
            buffer.print(
                allocator,
                "entity {d} npc {s} tile ({d}, {d}) center {d} {d}\n",
                .{ index + 1, @tagName(npc.npc_type), npc.position.x, npc.position.y, center.x, center.y },
            ) catch @panic("failed to format level dump");
        }

        buffer.print(allocator, "mission_exits: {d}\n", .{hub.mission_exits.len}) catch
            @panic("failed to format level dump");
        for (hub.mission_exits) |mission_exit| {
            buffer.print(
                allocator,
                "mission_exit \"{s}\" ({d}, {d}) center {d} {d}\n",
                .{
                    mission_exit.mission_id,
                    mission_exit.position.x,
                    mission_exit.position.y,
                    view.tileClickCenter(mission_exit.position, camera, camera_zoom).x,
                    view.tileClickCenter(mission_exit.position, camera, camera_zoom).y,
                },
            ) catch @panic("failed to format level dump");
        }
    } else {
        buffer.appendSlice(allocator, "world: none (no level or hub)\n") catch
            @panic("failed to format level dump");
    }
    return buffer.items;
}

/// One tile line: `<kind> (x, y) center cx cy` - the center is a click
/// point that resolves back to the tile.
fn appendTileLine(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    kind: []const u8,
    tile: types.Vector2,
    camera: types.Camera,
    camera_zoom: f32,
) void {
    const center = view.tileClickCenter(tile, camera, camera_zoom);
    buffer.print(
        allocator,
        "{s} ({d}, {d}) center {d} {d}\n",
        .{ kind, tile.x, tile.y, center.x, center.y },
    ) catch @panic("failed to format level dump");
}

fn appendEntityLine(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    index: usize,
    entity: types.Entity,
    camera: types.Camera,
    camera_zoom: f32,
) void {
    const center = view.tileClickCenter(entity.position, camera, camera_zoom);
    buffer.print(
        allocator,
        "entity {d} \"{s}\" team {d} tile ({d}, {d}) health {d}/{d} aggro {s} center {d} {d}\n",
        .{
            index,
            entity.name,
            entity.team,
            entity.position.x,
            entity.position.y,
            entity.current_health,
            entity.max_health,
            if (entity.is_active) "yes" else "no",
            center.x,
            center.y,
        },
    ) catch @panic("failed to format level dump");
}

/// One item's summary: kind + name + the stats that matter to a decision.
fn itemSummary(item: types.Item, allocator: std.mem.Allocator) []const u8 {
    return switch (item) {
        .weapon => |weapon| std.fmt.allocPrint(
            allocator,
            "weapon \"{s}\" ({s}, damage {d})",
            .{ weapon.name, @tagName(weapon.weapon_type), weapon.weapon_damage },
        ) catch @panic("failed to format item summary"),
        .amulet => |amulet| std.fmt.allocPrint(
            allocator,
            "amulet \"{s}\" (spell damage {d})",
            .{ amulet.name, amulet.spell_damage },
        ) catch @panic("failed to format item summary"),
        .coat => |coat| std.fmt.allocPrint(
            allocator,
            "coat \"{s}\" (health {d}, defense {d})",
            .{ coat.name, coat.health_bonus, coat.defense_bonus },
        ) catch @panic("failed to format item summary"),
        .gloves => |gloves| std.fmt.allocPrint(
            allocator,
            "gloves \"{s}\" (health {d}, damage {d})",
            .{ gloves.name, gloves.health_bonus, gloves.damage_bonus },
        ) catch @panic("failed to format item summary"),
        .pants => |pants| std.fmt.allocPrint(
            allocator,
            "pants \"{s}\" (health {d}, pickup radius {d})",
            .{ pants.name, pants.health_bonus, pants.pickup_radius_bonus },
        ) catch @panic("failed to format item summary"),
        .boots => |boots| std.fmt.allocPrint(
            allocator,
            "boots \"{s}\" (health {d}, speed {d})",
            .{ boots.name, boots.health_bonus, boots.speed_bonus },
        ) catch @panic("failed to format item summary"),
        .skill_tome => |tome| std.fmt.allocPrint(
            allocator,
            "skill tome {s} (value {d})",
            .{ @tagName(tome.skill), tome.value },
        ) catch @panic("failed to format item summary"),
    };
}

/// The player's inventory (entity 0 in a level): picked-up items land here
/// (pickup is automatic on walking onto a ground stack's tile).
fn appendInventoryLines(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    player: types.Entity,
) void {
    var occupied: usize = 0;
    for (player.inventory.slots) |slot| {
        if (slot != null) occupied += 1;
    }
    buffer.print(
        allocator,
        "inventory: {d}/{d} slots\n",
        .{ occupied, types.inventory_slot_count },
    ) catch @panic("failed to format level dump");
    for (player.inventory.slots, 0..) |slot, index| {
        if (slot) |item| {
            buffer.print(
                allocator,
                "inventory {d}: {s}\n",
                .{ index, itemSummary(item, allocator) },
            ) catch @panic("failed to format level dump");
        }
    }
}

/// The player's full skill bar (entity 0 in a level): slots 1-2 = main-hand
/// weapon skills, 3 = off-hand, 4-8 = utility - the same numbering the
/// Digit1-8 bindings and the bottom bar use. Id + cooldown (ready when 0).
fn appendSkillLines(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    player: types.Entity,
    weapon_type_definitions: *const [types.weapon_type_count]types.WeaponTypeDefinition,
) void {
    buffer.appendSlice(allocator, "skill bar:\n") catch @panic("failed to format level dump");
    const slots = player.collectSkillSlots(weapon_type_definitions);
    for (slots, 0..) |slot, index| {
        const slot_number = index + 1;
        if (slot) |skill| {
            const cooldown = player.skill_cooldowns.get(skill);
            if (cooldown == 0) {
                buffer.print(
                    allocator,
                    "skill {d}: {s} ready\n",
                    .{ slot_number, @tagName(skill) },
                ) catch @panic("failed to format level dump");
            } else {
                buffer.print(
                    allocator,
                    "skill {d}: {s} cooldown {d}\n",
                    .{ slot_number, @tagName(skill), cooldown },
                ) catch @panic("failed to format level dump");
            }
        } else {
            buffer.print(allocator, "skill {d}: none\n", .{slot_number}) catch @panic("failed to format level dump");
        }
    }
}

fn dumpUiText(
    history: *GameStateHistory,
    ui_elements: []const ui.UiElement,
    allocator: std.mem.Allocator,
) []const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    const session = &history.session;
    const ui_state = &session.ui_state;
    // Class-1 surface state lives on GameState (see DESIGN → UI Framework
    // → UI state classification); the classes-2-4 view state below stays on
    // SessionState.
    const ui_surfaces = &history.current_state.ui_surfaces;
    buffer.print(allocator, "options_menu_open: {}\n", .{ui_surfaces.options_menu_open}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "settings_open: {}\n", .{ui_surfaces.settings_open}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "settings_tab: {s}\n", .{@tagName(ui_state.settings_tab)}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "credits_open: {}\n", .{ui_surfaces.credits_open}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "load_save_menu_open: {}\n", .{ui_surfaces.load_save_menu_open}) catch
        @panic("failed to format ui dump");
    buffer.print(allocator, "editor_browser_open: {}\n", .{ui_surfaces.editor_browser_open}) catch
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
    // press/release dispatch hit-tests against - `previous_view_state`),
    // each with its rect and its CENTER, a valid click point. Reference
    // space, so a coordinate from here clicks the same surface at any
    // window size / render resolution. Buttons carry their action name (the
    // semantic identity - the same enum `action <name>` accepts); sliders
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
            // targets); a bare slot is a decorative cell. The identity
            // carries the payload (gear/boots, inventory/0) - the tag alone
            // can't distinguish slots of the same kind.
            .slot => |slot| if (slot.ref) |slot_ref| {
                const identity: []const u8 = switch (slot_ref) {
                    .inventory => |index| std.fmt.allocPrint(
                        allocator,
                        "inventory/{d}",
                        .{index},
                    ) catch @panic("failed to format slot identity"),
                    .gear => |gear_slot| std.fmt.allocPrint(
                        allocator,
                        "gear/{s}",
                        .{@tagName(gear_slot)},
                    ) catch @panic("failed to format slot identity"),
                    .skill_bar => |index| std.fmt.allocPrint(
                        allocator,
                        "skill_bar/{d}",
                        .{index},
                    ) catch @panic("failed to format slot identity"),
                    .learned_skill => |skill| std.fmt.allocPrint(
                        allocator,
                        "learned_skill/{s}",
                        .{@tagName(skill)},
                    ) catch @panic("failed to format slot identity"),
                };
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
                        identity,
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

// ============================================================
// Tests
// ============================================================

/// A root for tests that never path-dump (the walker only walks it when a
/// `.path` command executes - these tests exercise other commands).
const no_dump_root: struct {} = .{};

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
        .{ .line = "wait idle", .expected = .{ .wait_idle = {} } },
        .{ .line = "dump", .expected = .{ .dump = storedText(PathText, "") } },
        .{ .line = "dump history.session.tile_cursor", .expected = .{ .dump = storedText(PathText, "history.session.tile_cursor") } },
        .{ .line = "dump history.event_history.items[12].meta_event", .expected = .{ .dump = storedText(PathText, "history.event_history.items[12].meta_event") } },
        .{ .line = "report ui", .expected = .{ .report = .ui } },
        .{ .line = "report level", .expected = .{ .report = .level } },
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

test "verb table: every example parses; every command variant is covered" {
    // Both ways, so the table can never drift from the vocabulary it owns:
    // (a) every example is a real, working command line (the printed help
    // shows only tested-working lines), and (b) every ConsoleCommand
    // variant is produced by at least one example - a new variant is a
    // test failure until the help table covers it.
    const CommandTag = std.meta.Tag(ConsoleCommand);
    var covered: [@typeInfo(CommandTag).@"enum".field_names.len]bool =
        @splat(false);
    for (verb_table) |entry| {
        for (entry.examples) |example| {
            const outcome = parseCommandLine(example);
            try std_testing.expect(outcome == .command);
            covered[@backingInt(std.meta.activeTag(outcome.command))] = true;
        }
    }
    for (std.meta.tags(CommandTag)) |variant_tag| {
        try std_testing.expect(covered[@backingInt(variant_tag)]);
    }
}

test "parseCommandLine: help and inputs parse; arguments error" {
    try std_testing.expectEqualDeep(ConsoleCommand.help, parseCommandLine("help").command);
    try std_testing.expectEqualDeep(ConsoleCommand.inputs, parseCommandLine("inputs").command);
    {
        const outcome = parseCommandLine("help me");
        try std_testing.expect(outcome == .err);
        try std_testing.expect(std.mem.indexOf(u8, outcome.err.view(), "help takes no arguments") != null);
    }
    {
        const outcome = parseCommandLine("inputs now");
        try std_testing.expect(outcome == .err);
        try std_testing.expect(std.mem.indexOf(u8, outcome.err.view(), "inputs takes no arguments") != null);
    }
}

test "writeHelpToWriter: every verb, description and example printed" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writeHelpToWriter(&writer);
    const text = buffer[0..writer.end];
    for (verb_table) |entry| {
        try std_testing.expect(std.mem.indexOf(u8, text, entry.name) != null);
        try std_testing.expect(std.mem.indexOf(u8, text, entry.description) != null);
        for (entry.examples) |example| {
            try std_testing.expect(std.mem.indexOf(u8, text, example) != null);
        }
    }
}

test "writeInputsToWriter: every producible id printed" {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writeInputsToWriter(&writer);
    const text = buffer[0..writer.end];
    for (types.producible_key_ids) |id| {
        try std_testing.expect(std.mem.indexOf(u8, text, id) != null);
    }
    for (types.producible_mouse_ids) |id| {
        try std_testing.expect(std.mem.indexOf(u8, text, id) != null);
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
        .{ .line = "dump history.$noop", .contains = "dump path may contain only letters" },
        .{ .line = "dump history session", .contains = "dump path may contain only letters" },
        .{ .line = "report everything", .contains = "unknown report kind 'everything'" },
        .{ .line = "report", .contains = "unknown report kind ''" },
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
    try std_testing.expect(queue.takeFrameCommand(true) == null);

    queue.push(parseCommandLine("press Escape").command);
    queue.push(parseCommandLine("move 10 20").command);
    queue.push(parseCommandLine("quit").command);

    const first = queue.takeFrameCommand(true).?;
    try std_testing.expect(first == .press);
    const second = queue.takeFrameCommand(true).?;
    try std_testing.expect(second == .move);
    const third = queue.takeFrameCommand(true).?;
    try std_testing.expect(third == .quit);
    try std_testing.expect(queue.takeFrameCommand(true) == null);
}

test "queue: wait n spaces surrounding commands n idle frames apart" {
    var queue: ConsoleQueue = .{};
    queue.push(parseCommandLine("press KeyA").command);
    queue.push(parseCommandLine("wait 2").command);
    queue.push(parseCommandLine("press KeyB").command);

    // Frame 1: the press before the wait.
    try std_testing.expect(queue.takeFrameCommand(true).? == .press);
    // Frame 2: the wait pops, arms 2 idle frames, yields nothing.
    try std_testing.expect(queue.takeFrameCommand(true) == null);
    // Frames 3 + 4: the armed idle frames.
    try std_testing.expect(queue.takeFrameCommand(true) == null);
    try std_testing.expect(queue.takeFrameCommand(true) == null);
    // Frame 5: the command after the wait - 3 frames after the wait itself.
    const after = queue.takeFrameCommand(true).?;
    try std_testing.expect(after == .press);
    try std_testing.expectEqualStrings("KeyB", after.press.key.view());
}

test "queue: wait idle holds until the game is idle, then releases on that frame" {
    var queue: ConsoleQueue = .{};
    queue.push(parseCommandLine("wait idle").command);
    queue.push(parseCommandLine("press KeyA").command);

    // Frame 1: the wait_idle pops + arms the hold (game not idle yet).
    try std_testing.expect(queue.takeFrameCommand(false) == null);
    // Busy frames: held.
    try std_testing.expect(queue.takeFrameCommand(false) == null);
    try std_testing.expect(queue.takeFrameCommand(false) == null);
    // The first idle frame releases the next command on that same frame.
    const command = queue.takeFrameCommand(true).?;
    try std_testing.expect(command == .press);
    // The hold is cleared: later frames flow normally (empty queue → null,
    // busy or not).
    try std_testing.expect(queue.takeFrameCommand(false) == null);
}

test "promptDue: the console-ready conditions" {
    var queue: ConsoleQueue = .{};
    queue.interactive = true;

    // `quit` never prompts - the process is exiting.
    try std_testing.expect(!promptDue(&queue, .quit));

    // A non-interactive channel (piped script, stdin-less launch) never
    // prompts, whatever it took.
    queue.interactive = false;
    try std_testing.expect(!promptDue(&queue, .{ .scroll = 1 }));
    queue.interactive = true;

    // A drained queue (the taken command was the last pending one) prompts:
    // the marker says the channel can take the next line.
    queue.push(.{ .scroll = 1 });
    try std_testing.expect(queue.takeFrameCommand(true) != null);
    try std_testing.expect(promptDue(&queue, .{ .scroll = 1 }));

    // An undrained queue (pasted multi-line input, mid-script backlog)
    // stays silent - one prompt after the LAST command, not per line.
    queue.push(.{ .scroll = 1 });
    queue.push(.{ .scroll = 2 });
    try std_testing.expect(queue.takeFrameCommand(true) != null);
    try std_testing.expect(!promptDue(&queue, .{ .scroll = 1 }));
    // Draining the remainder re-arms the prompt.
    try std_testing.expect(queue.takeFrameCommand(true) != null);
    try std_testing.expect(promptDue(&queue, .{ .scroll = 2 }));

    // Mid-hold frames prompt nothing BY CONSTRUCTION - `wait` / `wait idle`
    // arm inside takeFrameCommand and yield null, so no taken command ever
    // reaches the prompt check while a hold is armed (the wait-idle test
    // above pins that null). Nothing further to assert here.
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
        const command = queue.takeFrameCommand(true).?;
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
    // verb's one separator - a doubled space types a leading space).
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

    // Empty queue: the backend input returns unchanged (value-equal -
    // empty-slice pointers are not comparable).
    const passed_through = applyFrameCommand(&queue, backend_input, backing.allocator(), &history, &no_dump_root, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0);
    try std_testing.expectEqualDeep(backend_input, passed_through);
    try std_testing.expect(!history.session.quit_requested);

    queue.push(parseCommandLine("quit").command);
    _ = applyFrameCommand(&queue, backend_input, backing.allocator(), &history, &no_dump_root, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0);
    try std_testing.expect(history.session.quit_requested);
}

test "reportText: curated projections report the state they are handed" {
    const test_harness = @import("test_harness.zig");
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    // ui: reflects the surface state (GameState) + the view flags
    // (SessionState).
    history.current_state.ui_surfaces.options_menu_open = true;
    history.session.ui_state.keybind_scroll_offset = 4;
    const ui_text = reportText(.ui, &history, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0, arena);
    try std_testing.expect(std.mem.indexOf(u8, ui_text, "options_menu_open: true") != null);
    try std_testing.expect(std.mem.indexOf(u8, ui_text, "keybind_scroll_offset: 4") != null);

    // level: the gameplay-decision projection (here: no world → the
    // no-world line).
    const level_text = reportText(.level, &history, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0, arena);
    try std_testing.expect(std.mem.indexOf(u8, level_text, "world: none") != null);
}

test "reportText ui: interactive surfaces list rects + ready-to-use click centers" {
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

    const text = reportText(.ui, &history, &elements, .{ .position = .{ .x = 0, .y = 0 } }, 1.0, arena);

    // Each surface's line: rect + center (a valid click point - the exact
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
        "slot 100 200 128 128 center 164 264 ref skill_bar/0\n",
    ) != null);

    // An element list with no interactive surfaces reports none.
    const empty_text = reportText(.ui, &history, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0, arena);
    try std_testing.expect(std.mem.indexOf(u8, empty_text, "interactive surfaces") != null);
    try std_testing.expect(std.mem.indexOf(u8, empty_text, "none\n") != null);
}

test "reportText level: the active world with clickable highlights + entities" {
    const test_harness = @import("test_harness.zig");
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    var entities = [_]types.Entity{
        .{ .name = "Hero", .team = 0, .position = .{ .x = 1, .y = 1 }, .current_health = 20 },
        .{ .name = "Wolf", .team = 1, .position = .{ .x = 3, .y = 1 }, .current_health = 8, .max_health = 12, .is_active = true },
    };
    entities[0].equipped_utility_skills[0] = .bash;
    entities[0].skill_cooldowns.set(.bash, 2);
    entities[0].inventory.slots[0] = .{ .skill_tome = .{ .skill = .bash, .value = 3 } };
    const tiles = [_]types.Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
        .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
        .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 },
    };
    var history = harness.newHistory(test_harness.levelStateWithEntities(arena, &entities, &tiles));
    test_harness.runToIdle(&history);

    const level = &history.current_state.level.?;
    level.turn_phase = .player_move;
    level.level_end = .{ .x = 2, .y = 2 };
    const highlights = [_]types.Vector2{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 0 } };
    level.highlighted_tiles = &highlights;
    const ground_items = [_]types.GroundItems{
        .{ .position = .{ .x = 2, .y = 0 }, .items = &.{
            .{ .weapon = .{ .name = "Bamboo Spear", .weapon_type = .spear, .weapon_damage = 4 } },
            .{ .boots = .{ .name = "Comfortable Boots", .speed_bonus = 1 } },
        } },
    };
    level.ground_items = &ground_items;

    const camera: types.Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const zoom: f32 = 1.0;
    const text = reportText(.level, &history, &.{}, camera, zoom, arena);

    // World + phase + flag + highlights + entities + skills, one line each,
    // with click centers derived from the camera projection.
    try std_testing.expect(std.mem.indexOf(u8, text, "world: level") != null);
    try std_testing.expect(std.mem.indexOf(u8, text, "turn_phase: player_move\n") != null);
    try std_testing.expect(std.mem.indexOf(u8, text, "tiles: 9\n") != null);

    const flag_center = view.tileClickCenter(.{ .x = 2, .y = 2 }, camera, zoom);
    try std_testing.expect(std.mem.indexOf(
        u8,
        text,
        std.fmt.allocPrint(arena, "level_end (2, 2) center {d} {d}\n", .{ flag_center.x, flag_center.y }) catch unreachable,
    ) != null);

    const highlight_center = view.tileClickCenter(.{ .x = 0, .y = 1 }, camera, zoom);
    try std_testing.expect(std.mem.indexOf(
        u8,
        text,
        std.fmt.allocPrint(arena, "highlight (0, 1) center {d} {d}\n", .{ highlight_center.x, highlight_center.y }) catch unreachable,
    ) != null);

    try std_testing.expect(std.mem.indexOf(u8, text, "entity 0 \"Hero\" team 0 tile (1, 1) health 20/20 aggro no center") != null);
    try std_testing.expect(std.mem.indexOf(u8, text, "entity 1 \"Wolf\" team 1 tile (3, 1) health 8/12 aggro yes center") != null);
    // The skill bar: slots 1-3 = weapon skills (none here - no weapons),
    // 4-8 = utility (bash sits in the first utility slot → bar slot 4).
    try std_testing.expect(std.mem.indexOf(u8, text, "skill 1: none\n") != null);
    try std_testing.expect(std.mem.indexOf(u8, text, "skill 4: bash cooldown 2\n") != null);
    try std_testing.expect(std.mem.indexOf(u8, text, "skill 5: none\n") != null);

    // Ground stacks (walk onto the tile to pick up) + the inventory.
    const spear_center = view.tileClickCenter(.{ .x = 2, .y = 0 }, camera, zoom);
    try std_testing.expect(std.mem.indexOf(
        u8,
        text,
        std.fmt.allocPrint(
            arena,
            "ground (2, 0) center {d} {d}: weapon \"Bamboo Spear\" (spear, damage 4), boots \"Comfortable Boots\" (health 0, speed 1)\n",
            .{ spear_center.x, spear_center.y },
        ) catch unreachable,
    ) != null);
    try std_testing.expect(std.mem.indexOf(u8, text, "inventory: 1/96 slots\n") != null);
    try std_testing.expect(std.mem.indexOf(u8, text, "inventory 0: skill tome bash (value 3)\n") != null);

    // The click-center contract: a dumped center resolves back to its tile
    // through screenToTile - the exact resolution a console `move` + press
    // goes through - so a coordinate straight off the dump line lands on
    // the intended tile.
    const wolf_center = view.tileClickCenter(.{ .x = 3, .y = 1 }, camera, zoom);
    const resolved_tile = input.screenToTile(
        .{ .x = @floatFromInt(wolf_center.x), .y = @floatFromInt(wolf_center.y) },
        camera,
        zoom,
        .{ .width = types.reference_width, .height = types.reference_height },
    );
    try std_testing.expectEqual(types.Vector2{ .x = 3, .y = 1 }, resolved_tile);

    // No world (main menu): the dump says so.
    var menu_history = harness.newHistory(null);
    test_harness.runToIdle(&menu_history);
    const no_world_text = reportText(.level, &menu_history, &.{}, camera, zoom, arena);
    try std_testing.expect(std.mem.indexOf(u8, no_world_text, "world: none (no level or hub)\n") != null);
}

test "applyFrameCommand: wait idle holds while events are pending, releases when idle" {
    const test_harness = @import("test_harness.zig");
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    // A fresh history has the startup batch pending (not idle).
    var history = harness.newHistory(null);

    var queue: ConsoleQueue = .{};
    queue.push(parseCommandLine("wait idle").command);
    queue.push(parseCommandLine("quit").command);

    const backend_input = PlatformInput{ .events = &.{}, .viewport = .{ .width = 1280, .height = 1080 } };
    // While the stack is pending, the quit behind the hold never fires.
    _ = applyFrameCommand(&queue, backend_input, backing.allocator(), &history, &no_dump_root, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0);
    _ = applyFrameCommand(&queue, backend_input, backing.allocator(), &history, &no_dump_root, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0);
    try std_testing.expect(!history.session.quit_requested);

    // Drain to idle; the next frame releases the quit on the first idle
    // frame.
    test_harness.runToIdle(&history);
    _ = applyFrameCommand(&queue, backend_input, backing.allocator(), &history, &no_dump_root, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0);
    try std_testing.expect(history.session.quit_requested);
}

test "writeReportToWriter: writes the report to the output writer (parent-pointer shape)" {
    const test_harness = @import("test_harness.zig");
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    // The Allocating writer passed by its real parent pointer (the vtable
    // resolves the parent via fieldParentPtr - the same shape the native
    // wiring's File.Writer parent has).
    var allocating: std.Io.Writer.Allocating = .init(std_testing.allocator);
    defer allocating.deinit();
    writeReportToWriter(
        .level,
        &allocating.writer,
        &history,
        &.{},
        .{ .position = .{ .x = 0, .y = 0 } },
        1.0,
    );

    const written = allocating.written();
    try std_testing.expect(std.mem.indexOf(u8, written, "world: none (no level or hub)") != null);
    try std_testing.expect(written[written.len - 1] == '\n');
}

test "writeDump: path dumps route to the walker against the root" {
    const test_harness = @import("test_harness.zig");
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);
    history.session.tile_cursor = .{ .x = 2, .y = 3 };

    // The root mirrors the driver's: history by value (the walker reads
    // the same fields the FrameState would).
    const Root = struct { history: GameStateHistory };
    const root = Root{ .history = history };

    var buffer: [2048]u8 = undefined;

    // The parser produces path commands for ANY single-token argument -
    // including the pre-split spellings (`dump ui`), which now resolve as
    // paths and error truthfully (the redirect teaches `report ui`).
    {
        const outcome = parseCommandLine("dump ui");
        try std_testing.expect(outcome == .command);
        try std_testing.expectEqualStrings("ui", outcome.command.dump.view());
    }

    // A leaf path: the addressed value alone.
    {
        var writer = std.Io.Writer.fixed(&buffer);
        dump_walker.writeDump(&writer, &root, "history.session.tile_cursor");
        try std_testing.expectEqualStrings("{ x: 2, y: 3 }\n", buffer[0..writer.end]);
    }

    // A dead path: the truthful error names what IS there.
    {
        var writer = std.Io.Writer.fixed(&buffer);
        dump_walker.writeDump(&writer, &root, "history.nope");
        try std_testing.expect(std.mem.indexOf(u8, buffer[0..writer.end], "dump error: no field 'nope'") != null);
    }

    // The bare dump: the root table of contents.
    {
        var writer = std.Io.Writer.fixed(&buffer);
        dump_walker.writeDump(&writer, &root, "");
        try std_testing.expect(std.mem.indexOf(u8, buffer[0..writer.end], "history: ") != null);
    }
}

test "takeFrameCommand records the taken command (any kind, waits included)" {
    const test_harness = @import("test_harness.zig");
    var backing = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    test_harness.runToIdle(&history);

    var queue: ConsoleQueue = .{};
    try std_testing.expect(queue.last_taken_command == null);

    // An input command: recorded.
    const backend_input = PlatformInput{ .events = &.{}, .viewport = .{ .width = 1280, .height = 1080 } };
    const no_root: struct {} = .{};
    queue.push(parseCommandLine("press Escape").command);
    _ = applyFrameCommand(&queue, backend_input, backing.allocator(), &history, &no_root, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0);
    try std_testing.expect(queue.last_taken_command != null);
    try std_testing.expect(queue.last_taken_command.? == .press);

    // A wait arms its frames and returns nothing THIS frame - but it was
    // TAKEN (popped), so it records (which command consumed the frame is
    // the point of the field).
    queue.push(parseCommandLine("wait 5").command);
    _ = applyFrameCommand(&queue, backend_input, backing.allocator(), &history, &no_root, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0);
    try std_testing.expect(queue.last_taken_command != null);
    try std_testing.expect(queue.last_taken_command.? == .wait);

    // An empty drain (wait frames remaining) keeps the last record - the
    // last TAKEN command is still the truthful answer.
    _ = applyFrameCommand(&queue, backend_input, backing.allocator(), &history, &no_root, &.{}, .{ .position = .{ .x = 0, .y = 0 } }, 1.0);
    try std_testing.expect(queue.last_taken_command != null);
    try std_testing.expect(queue.last_taken_command.? == .wait);
}
