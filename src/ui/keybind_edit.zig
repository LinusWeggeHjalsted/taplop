//! The keybinds tab's edit state machine (TODO → Keybind editor slice 4):
//! listening → pending (confirm/cancel) and the picker, plus the
//! `translateInput` capture seam (`routeKeybindCapture` — the text-input
//! model: while an edit is active, ALL binding translation is suppressed and
//! raw key/mouse presses route into the capture instead). Pure UiState —
//! the whole machine is view + input-layer state off the undo timeline; the
//! settings mutation happens only at CONFIRM (the camera_zoom discipline).
//! See DESIGN → UI Framework → Settings screen (the Keybinds tab).

const std = @import("std");
const types = @import("../types.zig");

/// The active keybind edit. While `UiState.keybind_edit` is set, binding
/// translation is suppressed (see the module doc) — Escape cancels at every
/// phase.
pub const KeybindEdit = union(enum) {
    /// Listening for a key press (a row's combo area or `+` was clicked).
    /// The first non-modifier key press (with the held modifiers becoming
    /// the combo's requirements) or mouse press captures → pending. A
    /// mouse press ANYWHERE captures (clicking is binding the clicked
    /// button) — Escape is the only non-capturing escape.
    listening: KeybindTarget,
    /// The right-column action picker is open (a row's action panel was
    /// clicked, or the standalone Add button): the full scrollable action
    /// list; picking one either moves the target row's combo to it
    /// (reassign → pending) or begins listening for a new binding's combo
    /// (standalone add → listening).
    picker: KeybindTarget,
    /// A complete proposal awaiting Confirm / Cancel: the row shows the
    /// captured combo + Confirm/Cancel buttons + the steal warning (if the
    /// combo currently fires another binding, confirming REMOVES it — see
    /// DESIGN → Input → Hybrid precedence + binding conflicts).
    pending: PendingKeybind,
};

/// What an edit targets: an existing binding (by index into
/// `settings.input_bindings`) or a new one.
pub const KeybindTarget = union(enum) {
    /// Rekey/reassign the binding at `settings.input_bindings[index]`.
    binding: usize,
    /// Add a combo for a known action (a row's `+`).
    add: types.Action,
    /// Standalone add: the action is picked in the picker first.
    add_new,
};

/// One awaiting-confirm proposal. The binding's input string points into
/// `KeybindEditState.capture` (UiState-owned, stable until the edit ends);
/// the CONFIRM applier dupes it into the settings allocation.
pub const PendingKeybind = struct {
    /// The proposed binding (captured combo + action).
    binding: types.InputBinding,
    /// null = a NEW entry (an add); else the entry being replaced (a rekey
    /// or reassign of that index).
    replace_index: ?usize,
    /// The entry confirming will REMOVE (the steal): same combo, contexts
    /// intersect, different index than `replace_index`. The first listed
    /// wins (the loader's rule) — the target row keeps its combo, the
    /// other one goes. Same action + same combo = a redundant duplicate
    /// (confirming dedupes). Null = no steal, clean apply.
    stolen_index: ?usize,
};

/// The captured combo during a LISTENING edit. Owned, fixed buffers — no
/// allocation, no lifetime (the pending state persists across frames; the
/// raw event ids it captures from only live one frame).
pub const KeybindCapture = struct {
    /// Longest input id the backend tables produce, plus headroom (a
    /// hand-file id clamps).
    pub const max_id_len: usize = 24;

    /// What kind of input the captured id names (the binding's
    /// `input_type`).
    pub const Kind = enum { key, mouse_button };

    id_buffer: [max_id_len]u8 = undefined,
    id_len: usize = 0,
    kind: Kind = .key,
    modifiers: types.Modifiers = .{},

    pub fn clear(self: *KeybindCapture) void {
        self.id_len = 0;
    }

    /// The captured input id, or null before a capture.
    pub fn capturedId(self: *const KeybindCapture) ?[]const u8 {
        if (self.id_len == 0) return null;
        return self.id_buffer[0..self.id_len];
    }

    pub fn store(
        self: *KeybindCapture,
        kind: Kind,
        id: []const u8,
        modifiers: types.Modifiers,
    ) void {
        const length = @min(id.len, max_id_len);
        @memcpy(self.id_buffer[0..length], id[0..length]);
        self.id_len = length;
        self.kind = kind;
        self.modifiers = modifiers;
    }

    /// The captured combo as a binding input (borrowing this capture's
    /// buffer — the pending state owns it; the confirm applier dupes).
    pub fn rawInput(self: *const KeybindCapture) types.RawInput {
        const id = self.capturedId() orelse "";
        return switch (self.kind) {
            .key => .{ .key = id },
            .mouse_button => .{ .mouse_button = id },
        };
    }
};

/// The UiState-resident edit: the phase machine + the capture. Pointed at
/// (as one pointer) by the `translateInput` seam.
pub const KeybindEditState = struct {
    edit: KeybindEdit,
    capture: KeybindCapture = .{},
};

/// True for the modifier ids (held-state tracking only — they never capture;
/// a combo needs a base key, and the held modifiers BECOME the combo's
/// requirements).
pub fn isModifierInputId(id: []const u8) bool {
    const modifier_ids = [_][]const u8{
        "ControlLeft", "ControlRight", "ShiftLeft", "ShiftRight", "AltLeft", "AltRight",
    };
    for (modifier_ids) |modifier_id| {
        if (std.mem.eql(u8, id, modifier_id)) return true;
    }
    return false;
}

/// Route one frame of raw input into the active keybind edit (the
/// `translateInput` seam, the text-input model): Escape cancels at every
/// phase; during LISTENING the first non-modifier key press or mouse press
/// captures; during PENDING Enter confirms (the modal-capture-state
/// convention — Escape cancels, Enter triggers the primary action; safe
/// despite Enter often being the captured key itself: capture happens
/// during LISTENING, so by pending an Enter press can only mean confirm).
/// Called only while an edit is active (binding translation is suppressed
/// upstream). Pure UiState writes — no settings touch until confirm.
pub fn routeKeybindCapture(
    edit_state: *KeybindEditState,
    pressed_keys: []const ?[]const u8,
    mouse_pressed: []const ?[]const u8,
    modifiers: types.Modifiers,
) types.KeybindCaptureOutcome {
    // Escape cancels at every phase (it is never capturable — rebinding the
    // escape key away mid-edit would be self-defeating; a binding for
    // `.escape` can still be created by rebinding another row's combo).
    for (pressed_keys) |slot| {
        const id = slot orelse continue;
        if (std.mem.eql(u8, id, "Escape")) return .canceled;
    }

    // Enter confirms during pending (the modal-capture-state convention —
    // see the fn doc for why the captured-Enter case is not ambiguous).
    if (edit_state.edit == .pending) {
        for (pressed_keys) |slot| {
            const id = slot orelse continue;
            if (std.mem.eql(u8, id, "Enter")) return .confirmed;
        }
    }

    if (edit_state.edit != .listening) return .none;

    // Keys first: the first non-modifier press captures, the held modifiers
    // becoming the combo's requirements.
    for (pressed_keys) |slot| {
        const id = slot orelse continue;
        if (isModifierInputId(id)) continue;
        edit_state.capture.store(.key, id, modifiers);
        return .captured;
    }
    // Mouse buttons capture too (a click while listening binds the clicked
    // button — standard capture behavior; the click that STARTED the
    // listening was consumed by its own button before the edit began).
    for (mouse_pressed) |slot| {
        const id = slot orelse continue;
        edit_state.capture.store(.mouse_button, id, modifiers);
        return .captured;
    }
    return .none;
}

test "routeKeybindCapture: keys capture with held modifiers; Escape cancels; modifiers never capture" {
    var edit_state: KeybindEditState = .{ .edit = .{ .listening = .{ .binding = 0 } } };
    const empty: [0]?[]const u8 = .{};

    // A non-modifier press captures, the held modifiers becoming the
    // combo's requirements.
    const pressed_keys = [_]?[]const u8{"KeyQ"};
    try std.testing.expectEqual(types.KeybindCaptureOutcome.captured, routeKeybindCapture(&edit_state, &pressed_keys, &empty, .{ .ctrl = true }));
    try std.testing.expectEqualStrings("KeyQ", edit_state.capture.capturedId().?);
    try std.testing.expect(edit_state.capture.modifiers.ctrl);
    try std.testing.expectEqual(std.meta.activeTag(edit_state.capture.rawInput()), .key);

    // A modifier-only press never captures (a combo needs a base key).
    edit_state = .{ .edit = .{ .listening = .{ .binding = 0 } } };
    const modifier_press = [_]?[]const u8{"ControlLeft"};
    try std.testing.expectEqual(types.KeybindCaptureOutcome.none, routeKeybindCapture(&edit_state, &modifier_press, &empty, .{}));
    try std.testing.expect(edit_state.capture.capturedId() == null);

    // Escape cancels (never captures) — at every phase.
    edit_state = .{ .edit = .{ .listening = .{ .binding = 0 } } };
    const escape_press = [_]?[]const u8{"Escape"};
    try std.testing.expectEqual(types.KeybindCaptureOutcome.canceled, routeKeybindCapture(&edit_state, &escape_press, &empty, .{}));

    // Outside listening (pending), a normal press does nothing; Escape
    // still cancels; Enter CONFIRMS (the modal-capture-state convention —
    // capture is over by pending, so an Enter press can only mean confirm).
    edit_state = .{ .edit = .{ .pending = .{
        .binding = .{ .input = .{ .key = "Enter" }, .action = .undo },
        .replace_index = 0,
        .stolen_index = null,
    } } };
    const normal_press = [_]?[]const u8{"KeyQ"};
    try std.testing.expectEqual(types.KeybindCaptureOutcome.none, routeKeybindCapture(&edit_state, &normal_press, &empty, .{}));
    try std.testing.expectEqual(types.KeybindCaptureOutcome.canceled, routeKeybindCapture(&edit_state, &escape_press, &empty, .{}));
    const enter_press = [_]?[]const u8{"Enter"};
    try std.testing.expectEqual(types.KeybindCaptureOutcome.confirmed, routeKeybindCapture(&edit_state, &enter_press, &empty, .{}));

    // During LISTENING Enter is an ordinary capturable key (the combo being
    // rebound TO Enter captures it; only pending Enter confirms).
    edit_state = .{ .edit = .{ .listening = .{ .binding = 0 } } };
    try std.testing.expectEqual(types.KeybindCaptureOutcome.captured, routeKeybindCapture(&edit_state, &enter_press, &empty, .{}));
    try std.testing.expectEqualStrings("Enter", edit_state.capture.capturedId().?);

    // A mouse press captures as a mouse binding.
    edit_state = .{ .edit = .{ .listening = .{ .binding = 0 } } };
    const mouse_press = [_]?[]const u8{"left"};
    try std.testing.expectEqual(types.KeybindCaptureOutcome.captured, routeKeybindCapture(&edit_state, &empty, &mouse_press, .{}));
    try std.testing.expectEqualStrings("left", edit_state.capture.capturedId().?);
    try std.testing.expectEqual(std.meta.activeTag(edit_state.capture.rawInput()), .mouse_button);
}
