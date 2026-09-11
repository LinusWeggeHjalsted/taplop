//! Input polling for the raylib backend: the key/mouse mapping tables and
//! the once-per-frame edge/position/char-queue read. The poll ORDER
//! invariant (read edges first, pump the OS queue last) lives here — see
//! DESIGN → Platform Seam (raylib). The letterbox transform is passed in by
//! the backend (window math stays with the window owner in backend.zig);
//! the scratch buffers are backend fields so their lifetime stays visible
//! next to the rest of the per-frame state.

const std = @import("std");
const rl = @import("raylib");
const input = @import("../input.zig");
const types = @import("../types.zig");
const backend = @import("backend.zig");

/// A raylib key mapped to the game's binding id (Web KeyboardEvent.code style,
/// e.g. "KeyZ", "Escape", "Digit1"). Only the keys the game actually binds are
/// listed; unmapped keys are ignored. Modifiers are included so getModifiers()
/// can detect ctrl/shift/alt for chorded bindings (undo/redo).
const KeyMapping = struct {
    key: rl.KeyboardKey,
    id: []const u8,
};

const shared_key_mappings = [_]KeyMapping{
    // Modifiers (tracked as held keys so getModifiers can read them).
    .{ .key = .left_control, .id = "ControlLeft" },
    .{ .key = .right_control, .id = "ControlRight" },
    .{ .key = .left_shift, .id = "ShiftLeft" },
    .{ .key = .right_shift, .id = "ShiftRight" },
    .{ .key = .left_alt, .id = "AltLeft" },
    .{ .key = .right_alt, .id = "AltRight" },
    // Action keys bound in data/default_settings.txt.
    .{ .key = .z, .id = "KeyZ" },
    .{ .key = .y, .id = "KeyY" },
    .{ .key = .i, .id = "KeyI" },
    .{ .key = .o, .id = "KeyO" },
    .{ .key = .n, .id = "KeyN" },
    .{ .key = .page_up, .id = "PageUp" },
    .{ .key = .page_down, .id = "PageDown" },
    .{ .key = .g, .id = "KeyG" },
    .{ .key = .s, .id = "KeyS" },
    .{ .key = .a, .id = "KeyA" },
    .{ .key = .d, .id = "KeyD" },
    .{ .key = .e, .id = "KeyE" },
    .{ .key = .m, .id = "KeyM" },
    .{ .key = .l, .id = "KeyL" },
    .{ .key = .escape, .id = "Escape" },
    .{ .key = .enter, .id = "Enter" },
    .{ .key = .backspace, .id = "Backspace" },
    .{ .key = .delete, .id = "Delete" },
    .{ .key = .space, .id = "Space" },
    .{ .key = .one, .id = "Digit1" },
    .{ .key = .zero, .id = "Digit0" },
    .{ .key = .two, .id = "Digit2" },
    .{ .key = .three, .id = "Digit3" },
    .{ .key = .four, .id = "Digit4" },
    .{ .key = .five, .id = "Digit5" },
    .{ .key = .six, .id = "Digit6" },
    .{ .key = .seven, .id = "Digit7" },
    .{ .key = .eight, .id = "Digit8" },
    .{ .key = .up, .id = "ArrowUp" },
    .{ .key = .down, .id = "ArrowDown" },
    .{ .key = .left, .id = "ArrowLeft" },
    .{ .key = .right, .id = "ArrowRight" },
};

/// raylib keys mapped to the game's binding ids on macOS only. Mac
/// convention is Command for app shortcuts, so the super keys report as the
/// Control ids — every `ControlLeft` binding (undo, save, select-all, …)
/// fires on Cmd, and the physical ctrl keys keep working too. The ids
/// flowing into translateInput stay platform-agnostic (settings files ship
/// one binding set for all platforms); the convention lives HERE, at the
/// backend key table. Held-key tracking is per-id, so holding Cmd + left
/// ctrl and releasing one drops the modifier early — an irrelevant corner.
const mac_key_mappings = [_]KeyMapping{
    .{ .key = .left_super, .id = "ControlLeft" },
    .{ .key = .right_super, .id = "ControlRight" },
};

/// The full key table for this target: the shared mappings plus, on macOS,
/// the Command-as-Control entries. `max_events_per_frame` sizes the event
/// buffer off this length.
const key_mappings = shared_key_mappings ++
    if (@import("builtin").os.tag == .macos) mac_key_mappings else &[_]KeyMapping{};

const MouseMapping = struct {
    button: rl.MouseButton,
    id: []const u8,
};

const mouse_mappings = [_]MouseMapping{
    .{ .button = .left, .id = "left" },
    .{ .button = .right, .id = "right" },
    .{ .button = .middle, .id = "middle" },
};

/// Upper bound on events emitted in a single frame. Each mapped key/button
/// contributes at most ONE event per frame (down or up — never both, the
/// poll loop uses `else if`), so `key_mappings.len + mouse_mappings.len`
/// bounds the edge events. The non-edge events (always-one mouse-move, the
/// mouse-scroll wheel delta) add `non_edge_events_per_frame`. Adding a new
/// mapping array (gamepad, touch) only needs to be added to the sum below;
/// adding a new non-edge event source bumps `non_edge_events_per_frame`.
/// No manual bumping on per-source changes — the formula tracks the counts.
const non_edge_events_per_frame: usize = 2; // mouse-move + mouse-scroll
pub const max_events_per_frame = key_mappings.len + mouse_mappings.len + non_edge_events_per_frame;

/// Size of the UTF-8 scratch buffer the platform char queue drains into each
/// poll (the backend owns the buffer so its lifetime is visible with the
/// rest of the per-frame state).
pub const char_buffer_size: usize = 64;

/// Read this frame's input edges, pointer position, scroll delta, and text
/// characters into the caller's scratch buffers and pump the OS event queue.
/// The transform is the window→reference letterbox (the pointer is mapped
/// back into reference space through its inverse). Valid until the next
/// call; translateInput consumes the result synchronously.
pub fn poll(
    transform: backend.ViewTransform,
    event_buffer: *[max_events_per_frame]input.PlatformInputEvent,
    char_buffer: *[char_buffer_size]u8,
) input.PlatformInput {
    // Read input edges and position FIRST, before pumping.
    //
    // Why this order: raylib's PollInputEvents() copies previous = current
    // (advancing the "previous" snapshot). IsMouseButtonPressed /
    // IsKeyPressed check current vs previous. On native, PollInputEvents
    // copies THEN calls glfwPollEvents() (which fires callbacks that update
    // current) — so pumping-then-reading works (the copy sees the old
    // state, game code sees the new state). But on web, events arrive
    // asynchronously via JS callbacks BETWEEN frames (current is already
    // set when we arrive). Pumping first would copy previous = current,
    // erasing the edge (current == previous → no press detected). Reading
    // first, then pumping, works on BOTH platforms: web sees current (from
    // JS callbacks) vs previous (from last frame's copy); native sees
    // current (from last iteration's glfwPollEvents) vs previous (from
    // last iteration's copy), with ~1 iteration of latency at the uncapped
    // loop speed (negligible).
    var count: usize = 0;

    // Mouse position, mapped from window pixels back into reference space
    // through the inverse of the letterbox transform.
    const mouse = rl.getMousePosition();
    event_buffer[count] = .{ .mouse_move = .{
        .x = if (transform.scale > 0) (mouse.x - transform.offset_x) / transform.scale else 0,
        .y = if (transform.scale > 0) (mouse.y - transform.offset_y) / transform.scale else 0,
    } };
    count += 1;

    // Keyboard edges.
    for (key_mappings) |mapping| {
        if (rl.isKeyPressed(mapping.key)) {
            event_buffer[count] = .{ .key_down = mapping.id };
            count += 1;
        } else if (rl.isKeyReleased(mapping.key)) {
            event_buffer[count] = .{ .key_up = mapping.id };
            count += 1;
        }
    }

    // Mouse button edges.
    for (mouse_mappings) |mapping| {
        if (rl.isMouseButtonPressed(mapping.button)) {
            event_buffer[count] = .{ .mouse_button_down = mapping.id };
            count += 1;
        } else if (rl.isMouseButtonReleased(mapping.button)) {
            event_buffer[count] = .{ .mouse_button_up = mapping.id };
            count += 1;
        }
    }

    // Mouse wheel: accumulated scroll delta since last frame (positive =
    // scroll up = zoom in). Not an edge — raylib accumulates it internally
    // and resets on pollInputEvents — so reading before the pump is fine
    // (same as the mouse position read above).
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0) {
        event_buffer[count] = .{ .mouse_scroll = wheel };
        count += 1;
    }

    // Text characters: drain the platform char queue (the text-input /
    // IME path — distinct from key edges) into UTF-8. Drained
    // unconditionally so the queue can't back up between frames;
    // consumers only read it while a text field is focused. Read before
    // the pump like the wheel (the queue accumulates between polls).
    var char_count: usize = 0;
    while (char_count < char_buffer.len) {
        const codepoint = rl.getCharPressed();
        if (codepoint <= 0) break;
        // Out-of-range values (control junk from the platform) are
        // skipped, not fatal — `@intCast` to u21 would panic otherwise.
        if (codepoint > 0x10FFFF) continue;
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch continue;
        if (char_count + length > char_buffer.len) break;
        @memcpy(char_buffer[char_count .. char_count + length], encoded[0..length]);
        char_count += length;
    }

    // Pump the OS event queue AFTER reading edges. On native this calls
    // glfwPollEvents() (fires callbacks that update current for the next
    // iteration) + copies previous = current. On web it just copies
    // previous = current (events are async). Without this call on native,
    // the window would hang between renders (OS events not processed).
    rl.pollInputEvents();

    return .{
        .events = event_buffer[0..count],
        // The game works entirely in reference space (the pointer above is
        // mapped there), so report the reference resolution as the viewport.
        .viewport = .{ .width = reference_width, .height = reference_height },
        .text_characters = char_buffer[0..char_count],
    };
}

const reference_width: f32 = @floatFromInt(types.reference_width);
const reference_height: f32 = @floatFromInt(types.reference_height);
