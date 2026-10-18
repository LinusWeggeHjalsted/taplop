//! Input polling for the raylib backend: the key/mouse mapping tables and
//! the once-per-frame edge/position/char-queue read. The poll ORDER
//! invariant (read edges first, pump the OS queue last) lives here - see
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
    // The FULL W3C KeyboardEvent.code id set raylib can report - the whole
    // raylib KeyboardKey enum except the super keys (mac-only, mapped to
    // the Control ids in mac_key_mappings - see its comment). The ids match
    // the W3C code names (KeyZ, Digit1, BracketLeft, NumpadEnter, ...) so a
    // binding in data/default_settings.txt or a captured rebind can name
    // ANY physical key without a backend edit. Unbound-but-mapped keys
    // reach translateInput and match nothing (checkAction only matches
    // bound inputs) - they're inert. Poll cost: one isKeyPressed per table
    // entry per frame (~110 entries).
    //
    // Modifiers first (tracked as held keys so getModifiers can read them).
    .{ .key = .left_control, .id = "ControlLeft" },
    .{ .key = .right_control, .id = "ControlRight" },
    .{ .key = .left_shift, .id = "ShiftLeft" },
    .{ .key = .right_shift, .id = "ShiftRight" },
    .{ .key = .left_alt, .id = "AltLeft" },
    .{ .key = .right_alt, .id = "AltRight" },
    // Letters.
    .{ .key = .a, .id = "KeyA" },
    .{ .key = .b, .id = "KeyB" },
    .{ .key = .c, .id = "KeyC" },
    .{ .key = .d, .id = "KeyD" },
    .{ .key = .e, .id = "KeyE" },
    .{ .key = .f, .id = "KeyF" },
    .{ .key = .g, .id = "KeyG" },
    .{ .key = .h, .id = "KeyH" },
    .{ .key = .i, .id = "KeyI" },
    .{ .key = .j, .id = "KeyJ" },
    .{ .key = .k, .id = "KeyK" },
    .{ .key = .l, .id = "KeyL" },
    .{ .key = .m, .id = "KeyM" },
    .{ .key = .n, .id = "KeyN" },
    .{ .key = .o, .id = "KeyO" },
    .{ .key = .p, .id = "KeyP" },
    .{ .key = .q, .id = "KeyQ" },
    .{ .key = .r, .id = "KeyR" },
    .{ .key = .s, .id = "KeyS" },
    .{ .key = .t, .id = "KeyT" },
    .{ .key = .u, .id = "KeyU" },
    .{ .key = .v, .id = "KeyV" },
    .{ .key = .w, .id = "KeyW" },
    .{ .key = .x, .id = "KeyX" },
    .{ .key = .y, .id = "KeyY" },
    .{ .key = .z, .id = "KeyZ" },
    // Digits (top row).
    .{ .key = .zero, .id = "Digit0" },
    .{ .key = .one, .id = "Digit1" },
    .{ .key = .two, .id = "Digit2" },
    .{ .key = .three, .id = "Digit3" },
    .{ .key = .four, .id = "Digit4" },
    .{ .key = .five, .id = "Digit5" },
    .{ .key = .six, .id = "Digit6" },
    .{ .key = .seven, .id = "Digit7" },
    .{ .key = .eight, .id = "Digit8" },
    .{ .key = .nine, .id = "Digit9" },
    // Punctuation.
    .{ .key = .apostrophe, .id = "Quote" },
    .{ .key = .comma, .id = "Comma" },
    .{ .key = .minus, .id = "Minus" },
    .{ .key = .period, .id = "Period" },
    .{ .key = .slash, .id = "Slash" },
    .{ .key = .semicolon, .id = "Semicolon" },
    .{ .key = .equal, .id = "Equal" },
    .{ .key = .left_bracket, .id = "BracketLeft" },
    .{ .key = .backslash, .id = "Backslash" },
    .{ .key = .right_bracket, .id = "BracketRight" },
    .{ .key = .grave, .id = "Backquote" },
    // Whitespace + editing.
    .{ .key = .space, .id = "Space" },
    .{ .key = .escape, .id = "Escape" },
    .{ .key = .enter, .id = "Enter" },
    .{ .key = .tab, .id = "Tab" },
    .{ .key = .backspace, .id = "Backspace" },
    .{ .key = .insert, .id = "Insert" },
    .{ .key = .delete, .id = "Delete" },
    // Navigation.
    .{ .key = .up, .id = "ArrowUp" },
    .{ .key = .down, .id = "ArrowDown" },
    .{ .key = .left, .id = "ArrowLeft" },
    .{ .key = .right, .id = "ArrowRight" },
    .{ .key = .page_up, .id = "PageUp" },
    .{ .key = .page_down, .id = "PageDown" },
    .{ .key = .home, .id = "Home" },
    .{ .key = .end, .id = "End" },
    // Lock + print keys.
    .{ .key = .caps_lock, .id = "CapsLock" },
    .{ .key = .scroll_lock, .id = "ScrollLock" },
    .{ .key = .num_lock, .id = "NumLock" },
    .{ .key = .print_screen, .id = "PrintScreen" },
    .{ .key = .pause, .id = "Pause" },
    // Function row.
    .{ .key = .f1, .id = "F1" },
    .{ .key = .f2, .id = "F2" },
    .{ .key = .f3, .id = "F3" },
    .{ .key = .f4, .id = "F4" },
    .{ .key = .f5, .id = "F5" },
    .{ .key = .f6, .id = "F6" },
    .{ .key = .f7, .id = "F7" },
    .{ .key = .f8, .id = "F8" },
    .{ .key = .f9, .id = "F9" },
    .{ .key = .f10, .id = "F10" },
    .{ .key = .f11, .id = "F11" },
    .{ .key = .f12, .id = "F12" },
    // Numpad.
    .{ .key = .kp_0, .id = "Numpad0" },
    .{ .key = .kp_1, .id = "Numpad1" },
    .{ .key = .kp_2, .id = "Numpad2" },
    .{ .key = .kp_3, .id = "Numpad3" },
    .{ .key = .kp_4, .id = "Numpad4" },
    .{ .key = .kp_5, .id = "Numpad5" },
    .{ .key = .kp_6, .id = "Numpad6" },
    .{ .key = .kp_7, .id = "Numpad7" },
    .{ .key = .kp_8, .id = "Numpad8" },
    .{ .key = .kp_9, .id = "Numpad9" },
    .{ .key = .kp_decimal, .id = "NumpadDecimal" },
    .{ .key = .kp_divide, .id = "NumpadDivide" },
    .{ .key = .kp_multiply, .id = "NumpadMultiply" },
    .{ .key = .kp_subtract, .id = "NumpadSubtract" },
    .{ .key = .kp_add, .id = "NumpadAdd" },
    .{ .key = .kp_enter, .id = "NumpadEnter" },
    .{ .key = .kp_equal, .id = "NumpadEqual" },
    // Context + media keys (raylib-exposed extras on the W3C code model).
    .{ .key = .kb_menu, .id = "ContextMenu" },
    .{ .key = .back, .id = "BrowserBack" },
    .{ .key = .volume_up, .id = "AudioVolumeUp" },
    .{ .key = .volume_down, .id = "AudioVolumeDown" },
};

// Uniqueness guard: a duplicated key or id in the table would silently
// shadow one binding id with another's events (each entry is polled
// independently). Comptime - the whole table is checked at compile time;
// the mac overlay is excluded (it intentionally reuses Control ids).
comptime {
    @setEvalBranchQuota(20_000);
    for (shared_key_mappings, 0..) |mapping, index| {
        for (shared_key_mappings[index + 1 ..]) |other| {
            if (mapping.key == other.key)
                @compileError("duplicate key in shared_key_mappings: " ++ @tagName(mapping.key));
            if (std.mem.eql(u8, mapping.id, other.id))
                @compileError("duplicate id in shared_key_mappings: " ++ mapping.id);
        }
    }
}

// Lockstep guard: the backend tables and `types.producible_key_ids` /
// `producible_mouse_ids` must name EXACTLY the same ids (both directions).
// A table id missing from the list = `loadSettings` would warn a REAL
// binding as dead (the missing-Escape regression's failure mode); a list
// entry with no table row = a binding the loader accepts but nothing can
// ever produce (the silent dead-binding class). Comptime - checked in
// every native build.
comptime {
    @setEvalBranchQuota(200_000);
    for (shared_key_mappings) |mapping| {
        var found = false;
        for (types.producible_key_ids) |producible_id| {
            if (std.mem.eql(u8, mapping.id, producible_id)) found = true;
        }
        if (!found)
            @compileError("key table id missing from types.producible_key_ids: " ++ mapping.id);
    }
    for (types.producible_key_ids) |producible_id| {
        var found = false;
        for (shared_key_mappings) |mapping| {
            if (std.mem.eql(u8, mapping.id, producible_id)) found = true;
        }
        if (!found)
            @compileError("types.producible_key_ids entry has no key table row: " ++ producible_id);
    }
    for (mouse_mappings) |mapping| {
        var found = false;
        for (types.producible_mouse_ids) |producible_id| {
            if (std.mem.eql(u8, mapping.id, producible_id)) found = true;
        }
        if (!found)
            @compileError("mouse table id missing from types.producible_mouse_ids: " ++ mapping.id);
    }
    for (types.producible_mouse_ids) |producible_id| {
        var found = false;
        for (mouse_mappings) |mapping| {
            if (std.mem.eql(u8, mapping.id, producible_id)) found = true;
        }
        if (!found)
            @compileError("types.producible_mouse_ids entry has no mouse table row: " ++ producible_id);
    }
}

/// raylib keys mapped to the game's binding ids on macOS only. Mac
/// convention is Command for app shortcuts, so the super keys report as the
/// Control ids - every `ControlLeft` binding (undo, save, select-all, ...)
/// fires on Cmd, and the physical ctrl keys keep working too. The ids
/// flowing into translateInput stay platform-agnostic (settings files ship
/// one binding set for all platforms); the convention lives HERE, at the
/// backend key table. Held-key tracking is per-id, so holding Cmd + left
/// ctrl and releasing one drops the modifier early - an irrelevant corner.
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
/// contributes at most ONE event per frame (down or up - never both, the
/// poll loop uses `else if`), so `key_mappings.len + mouse_mappings.len`
/// bounds the edge events. The non-edge events (always-one mouse-move, the
/// mouse-scroll wheel delta) add `non_edge_events_per_frame`. Adding a new
/// mapping array (gamepad, touch) only needs to be added to the sum below;
/// adding a new non-edge event source bumps `non_edge_events_per_frame`.
/// No manual bumping on per-source changes - the formula tracks the counts.
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
    // current) - so pumping-then-reading works (the copy sees the old
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
    // scroll up = zoom in). Not an edge - raylib accumulates it internally
    // and resets on pollInputEvents - so reading before the pump is fine
    // (same as the mouse position read above).
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0) {
        event_buffer[count] = .{ .mouse_scroll = wheel };
        count += 1;
    }

    // Text characters: drain the platform char queue (the text-input /
    // IME path - distinct from key edges) into UTF-8. Drained
    // unconditionally so the queue can't back up between frames;
    // consumers only read it while a text field is focused. Read before
    // the pump like the wheel (the queue accumulates between polls).
    var char_count: usize = 0;
    while (char_count < char_buffer.len) {
        const codepoint = rl.getCharPressed();
        if (codepoint <= 0) break;
        // Out-of-range values (control junk from the platform) are
        // skipped, not fatal - `@intCast` to u21 would panic otherwise.
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
