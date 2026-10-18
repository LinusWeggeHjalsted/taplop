//! The text input widget's core + routing: `TextField` (the pure
//! fixed-capacity UTF-8 buffer with caret/selection), `TextEditState`
//! (the focused field's identity + buffer, owned by `UiState.text_edit`),
//! `beginTextEdit`/`routeTextInput` (the translateInput seam), and
//! `placeCaretFromClick` (click-to-caret via the metrics). See DESIGN →
//! UI Framework → Text input widget.

const std = @import("std");
const types = @import("../types.zig");
const element = @import("element.zig");
const ui_state_mod = @import("state.zig");

const FontMetrics = element.FontMetrics;
const text = element.text;
const default_tint = element.default_tint;
const TextFieldUi = element.TextFieldUi;
const UiState = ui_state_mod.UiState;

/// Text-buffer capacity for one editable field. Level-format strings
/// (names, sprite ids) are short; 128 covers them with headroom.
const text_field_capacity: usize = 128;

/// The pure core of the text input widget (see DESIGN → UI Framework →
/// Text input widget): a fixed-capacity UTF-8 buffer with a byte-index
/// caret and a selection anchor. All editing is pure methods over the
/// struct, unit-tested without raylib; the input-routing layer (which
/// knows the field kind, e.g. digits-only filtering) calls these, and
/// `view()` renders the caret/selection from the indices. Caret and
/// anchor always sit on CODEPOINT boundaries - never mid-multibyte.
const TextField = struct {
    buffer: [text_field_capacity]u8 = @splat(0),
    length: usize = 0,
    /// Caret byte index, 0..length, on a codepoint boundary.
    caret: usize = 0,
    /// Selection anchor byte index (the other end is the caret); null =
    /// no selection. The rendered/edited selection is min/max of the two.
    selection_anchor: ?usize = null,

    /// The buffer's current contents (pub: the input-side commit path in
    /// input_handlers reads the value to push).
    pub fn currentText(self: *const TextField) []const u8 {
        return self.buffer[0..self.length];
    }

    /// The selection as an ordered byte range, or null when empty. An
    /// anchor equal to the caret is NO selection (a collapsed anchor is
    /// cleared by moveCaretTo's non-select path anyway; this guards the
    /// degenerate case).
    pub fn selectionRange(self: *const TextField) ?struct { start: usize, end: usize } {
        const anchor = self.selection_anchor orelse return null;
        if (anchor == self.caret) return null;
        return .{ .start = @min(anchor, self.caret), .end = @max(anchor, self.caret) };
    }

    /// Seed the buffer with a starting value (focus loads the field's
    /// current value so editing starts from it). Truncates to capacity.
    /// Caret at the end, no selection - the common edit-from-value start.
    fn loadValue(self: *TextField, value: []const u8) void {
        const accepted = @min(value.len, text_field_capacity);
        @memcpy(self.buffer[0..accepted], value[0..accepted]);
        self.length = accepted;
        self.caret = accepted;
        self.selection_anchor = null;
    }

    /// Replace the selection (or insert at the caret when none) with
    /// `new_text`, truncated to what the capacity allows. Always collapses
    /// the selection and leaves the caret after the accepted text.
    fn insertText(self: *TextField, new_text: []const u8) void {
        const range = self.selectionRange();
        const start: usize = if (range) |selection| selection.start else self.caret;
        const removed: usize = if (range) |selection| selection.end - selection.start else 0;
        const available = text_field_capacity - self.length + removed;
        const accepted = @min(new_text.len, available);
        // Shift the tail to its post-insert position, then fill the gap.
        // copyBackwards: the tail moves RIGHT when accepted > removed (the
        // regions overlap - a forward copy would read already-overwritten
        // bytes); backwards is safe in both directions.
        const tail_start = start + removed;
        const tail_length = self.length - tail_start;
        std.mem.copyBackwards(
            u8,
            self.buffer[start + accepted .. start + accepted + tail_length],
            self.buffer[tail_start .. tail_start + tail_length],
        );
        @memcpy(self.buffer[start .. start + accepted], new_text[0..accepted]);
        self.length = self.length - removed + accepted;
        self.caret = start + accepted;
        self.selection_anchor = null;
    }

    /// Delete the selection, or the codepoint before the caret
    /// (backspace). No-op at the start of the buffer with no selection.
    fn deleteBackward(self: *TextField) void {
        if (self.selectionRange()) |selection| {
            self.deleteRange(selection.start, selection.end);
            return;
        }
        if (self.caret == 0) return;
        const start = codepointStartBefore(self.currentText(), self.caret);
        self.deleteRange(start, self.caret);
    }

    /// Delete the selection, or the codepoint after the caret (delete
    /// key). No-op at the end of the buffer with no selection.
    fn deleteForward(self: *TextField) void {
        if (self.selectionRange()) |selection| {
            self.deleteRange(selection.start, selection.end);
            return;
        }
        if (self.caret >= self.length) return;
        const end = codepointEndAfter(self.currentText(), self.caret);
        self.deleteRange(self.caret, end);
    }

    /// Move the caret to `index` (clamped into the buffer; mid-codepoint
    /// indices round FORWARD to the next boundary). `select` is the one
    /// primitive for every movement: false = a plain move that clears the
    /// selection (a click repositions the caret); true = a selection move
    /// that plants the anchor at the OLD caret first if none is set
    /// (shift+arrow, drag-select).
    fn moveCaretTo(self: *TextField, index: usize, select: bool) void {
        var target = @min(index, self.length);
        while (target < self.length and isContinuationByte(self.buffer[target])) target += 1;
        if (select) {
            if (self.selection_anchor == null) self.selection_anchor = self.caret;
        } else {
            self.selection_anchor = null;
        }
        self.caret = target;
    }

    /// Caret one codepoint left (shift = extend the selection).
    fn moveCaretLeft(self: *TextField, select: bool) void {
        self.moveCaretTo(codepointStartBefore(self.currentText(), self.caret), select);
    }

    /// Caret one codepoint right (shift = extend the selection).
    fn moveCaretRight(self: *TextField, select: bool) void {
        self.moveCaretTo(codepointEndAfter(self.currentText(), self.caret), select);
    }

    fn deleteRange(self: *TextField, start: usize, end: usize) void {
        std.debug.assert(start <= end and end <= self.length);
        const removed = end - start;
        const tail_length = self.length - end;
        std.mem.copyForwards(
            u8,
            self.buffer[start .. start + tail_length],
            self.buffer[end .. end + tail_length],
        );
        self.length -= removed;
        self.caret = start;
        self.selection_anchor = null;
    }

    /// Byte index of the codepoint boundary the click x lands on: the
    /// first codepoint whose measured END exceeds `x` (clicking inside a
    /// glyph positions before it), or `length` when x is past the end.
    /// Pure - the routing layer calls it with the field's measured text
    /// x-origin subtracted.
    fn caretIndexAtX(
        field_text: []const u8,
        metrics: FontMetrics,
        font_size: i32,
        x: i32,
    ) usize {
        var index: usize = 0;
        var width_so_far: i32 = 0;
        while (index < field_text.len) {
            const end = codepointEndAfter(field_text, index);
            width_so_far += metrics.measureSpanWidth(text(field_text[index..end]), font_size);
            if (width_so_far > x) return index;
            index = end;
        }
        return field_text.len;
    }
};

fn isContinuationByte(byte: u8) bool {
    return byte & 0b11000000 == 0b10000000;
}

/// Byte index of the start of the codepoint BEFORE `index` (the lead
/// byte of the char the caret sits after). `index` is a boundary; at the
/// buffer start there is no preceding codepoint, so 0 returns 0 (a
/// move-left at the start becomes a no-op).
fn codepointStartBefore(field_text: []const u8, index: usize) usize {
    var start = index;
    while (start > 0 and isContinuationByte(field_text[start - 1])) start -= 1;
    if (start == 0) return 0;
    return start - 1;
}

/// Byte index just past the codepoint AT `index`. `index` is a boundary.
fn codepointEndAfter(field_text: []const u8, index: usize) usize {
    var end = index + 1;
    while (end < field_text.len and isContinuationByte(field_text[end])) end += 1;
    return end;
}

/// One focused text field: its identity (which GameState field + which
/// entity target) plus the edit buffer. Owned by `UiState.text_edit`.
pub const TextEditState = struct {
    field: types.TextFieldRef,
    buffer: TextField = .{},
};

/// Begin editing a field (its UI element was clicked): seed the buffer
/// with the field's current value so editing starts from it. Pure UiState
/// write - the commit (not the focus) is what touches GameState.
pub fn beginTextEdit(
    ui_state: *UiState,
    field: types.TextFieldRef,
    current_value: []const u8,
) void {
    var edit: TextEditState = .{ .field = field };
    edit.buffer.loadValue(current_value);
    ui_state.text_edit = edit;
}

/// Route one frame of raw input into the focused field's buffer. Called
/// from `translateInput` (the seam that owns raw key edges + synthetic
/// repeats) while a field is focused; returns the keyboard outcome for the
/// caller to resolve once per frame (the field-kind commit switch lives in
/// input_handlers - the framework stays field-agnostic). Digits-only
/// filtering for numeric fields happens HERE (the routing layer knows the
/// field kind; the core buffer stays generic). See DESIGN → UI Framework →
/// Text input widget.
pub fn routeTextInput(
    text_edit: *TextEditState,
    characters: []const u8,
    pressed_keys: []const ?[]const u8,
    repeated_keys: []const ?[]const u8,
    shift_held: bool,
) types.TextEditOutcome {
    if (textFieldIsNumeric(text_edit.field.id)) {
        // Numeric fields accept digits only, filtered codepoint-by-
        // codepoint as they're typed.
        var index: usize = 0;
        while (index < characters.len) {
            const end = codepointEndAfter(characters, index);
            if (std.ascii.isDigit(characters[index])) {
                text_edit.buffer.insertText(characters[index..end]);
            }
            index = end;
        }
    } else {
        text_edit.buffer.insertText(characters);
    }

    // Edit keys: real edges first, then synthetic repeats (hold-backspace).
    // Repeats never resolve (a held Enter committed on the real edge; the
    // field is gone by the next frame's synthetic edge) - their outcomes are
    // discarded, only the buffer edits apply.
    var outcome: types.TextEditOutcome = .none;
    for (pressed_keys) |slot| {
        const resolved = textEditKey(text_edit, slot orelse continue, shift_held) orelse continue;
        outcome = resolved;
    }
    for (repeated_keys) |slot| {
        const key = slot orelse continue;
        _ = textEditKey(text_edit, key, shift_held);
    }
    return outcome;
}

/// Apply one edit key to the buffer; a non-null return is a resolution key
/// (Enter commits, Escape discards). Any other key is ignored here - its
/// binding was suppressed at the translateInput level.
fn textEditKey(text_edit: *TextEditState, key: []const u8, shift_held: bool) ?types.TextEditOutcome {
    const buffer = &text_edit.buffer;
    if (std.mem.eql(u8, key, "Backspace")) {
        buffer.deleteBackward();
    } else if (std.mem.eql(u8, key, "Delete")) {
        buffer.deleteForward();
    } else if (std.mem.eql(u8, key, "ArrowLeft")) {
        buffer.moveCaretLeft(shift_held);
    } else if (std.mem.eql(u8, key, "ArrowRight")) {
        buffer.moveCaretRight(shift_held);
    } else if (std.mem.eql(u8, key, "Enter")) {
        return .commit;
    } else if (std.mem.eql(u8, key, "Escape")) {
        return .cancel;
    }
    return null;
}

/// Whether a field id takes digits only (the stat fields - parsing and
/// clamping happen at commit; this filter keeps garbage out of the buffer
/// as it's typed). Numeric ids join here with their slices.
fn textFieldIsNumeric(field_id: types.TextFieldId) bool {
    return switch (field_id) {
        .entity_name, .item_name, .item_def_name, .mission_name, .level_name => false,
        .inventory_item_name => false,
        .entity_stat, .item_stat, .item_def_stat => true,
        .inventory_item_stat => true,
    };
}

/// Click inside the FOCUSED field: map the click x to a caret index
/// (measured via the metrics) and move the caret there - a plain move,
/// clearing the selection. Callers gate on the clicked element being the
/// focused field. Drag-select within a field is a later refinement.
pub fn placeCaretFromClick(
    text_edit: *TextEditState,
    field: TextFieldUi,
    click_x: i32,
    metrics: FontMetrics,
) void {
    const index = TextField.caretIndexAtX(
        text_edit.buffer.currentText(),
        metrics,
        field.font_size,
        click_x - field.text_position.x,
    );
    text_edit.buffer.moveCaretTo(index, false);
}

test "TextField: insert at a mid-string caret shifts the tail intact" {
    // The case the original insertText got wrong (copyForwards on a
    // right-shifting overlap corrupted the tail): inserting at the START
    // or the MIDDLE with no selection.
    var field: TextField = .{};
    field.loadValue("25");
    field.moveCaretTo(0, false);
    field.insertText("0");
    try std.testing.expectEqualStrings("025", field.currentText());
    try std.testing.expectEqual(@as(usize, 1), field.caret);

    field.loadValue("skeleton");
    field.moveCaretTo(4, false);
    field.insertText("-");
    try std.testing.expectEqualStrings("skel-eton", field.currentText());
    try std.testing.expectEqual(@as(usize, 5), field.caret);

    // Selection-replace where the replacement is LONGER than the removed
    // selection (the tail also shifts right).
    field.loadValue("Skeleton Warrior");
    field.moveCaretTo(9, false); // caret at 'W'
    field.moveCaretTo(16, true); // select "Warrior"
    field.insertText("Champion");
    try std.testing.expectEqualStrings("Skeleton Champion", field.currentText());
}

test "TextField: loadValue seeds caret-at-end, insert appends, capacity truncates" {
    var field: TextField = .{};
    field.loadValue("Skeleton");
    try std.testing.expectEqualStrings("Skeleton", field.currentText());
    try std.testing.expectEqual(@as(usize, 8), field.caret);
    try std.testing.expect(field.selection_anchor == null);

    // Insert with no selection appends at the caret.
    field.insertText(" Warrior");
    try std.testing.expectEqualStrings("Skeleton Warrior", field.currentText());
    try std.testing.expectEqual(@as(usize, 16), field.caret);

    // loadValue truncates to capacity.
    var long: TextField = .{};
    long.loadValue("x" ** 200);
    try std.testing.expectEqual(@as(usize, text_field_capacity), long.length);
    try std.testing.expectEqualStrings("x" ** text_field_capacity, long.currentText());

    // Insert past capacity truncates the INSERTED text (keeps the buffer
    // full rather than dropping the tail).
    long.insertText("abc");
    try std.testing.expectEqual(@as(usize, text_field_capacity), long.length);
    try std.testing.expectEqualStrings("x" ** text_field_capacity, long.currentText());
}

test "TextField: deleteBackward and deleteForward, with and without selection" {
    var field: TextField = .{};
    field.loadValue("Wolf");

    // Backspace at the end removes one char; caret follows.
    field.deleteBackward();
    try std.testing.expectEqualStrings("Wol", field.currentText());
    try std.testing.expectEqual(@as(usize, 3), field.caret);

    // Backspace at the start is a no-op.
    field.moveCaretTo(0, false);
    field.deleteBackward();
    try std.testing.expectEqualStrings("Wol", field.currentText());

    // Delete forward removes the char after the caret; at the end a no-op.
    field.deleteForward();
    try std.testing.expectEqualStrings("ol", field.currentText());
    field.moveCaretTo(field.length, false);
    field.deleteForward();
    try std.testing.expectEqualStrings("ol", field.currentText());

    // Deleting WITH a selection removes exactly the selection, whichever
    // direction the delete key came from.
    field.loadValue("Skeleton Warrior");
    field.moveCaretTo(9, false); // caret at 'W'
    field.moveCaretLeft(true); // shift+left: select the space before 'W'
    field.deleteForward();
    try std.testing.expectEqualStrings("SkeletonWarrior", field.currentText());
}

test "TextField: moveCaretTo select/clear primitive drives every movement" {
    var field: TextField = .{};
    field.loadValue("abcd");

    // Plain move clears any selection; the click case.
    field.moveCaretTo(2, false);
    try std.testing.expectEqual(@as(usize, 2), field.caret);
    try std.testing.expect(field.selection_anchor == null);

    // Select-move plants the anchor at the OLD caret (shift+arrow,
    // drag-select share this).
    field.moveCaretLeft(true);
    try std.testing.expectEqual(@as(usize, 1), field.caret);
    try std.testing.expectEqual(@as(usize, 2), field.selection_anchor.?);
    const selection = field.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 1), selection.start);
    try std.testing.expectEqual(@as(usize, 2), selection.end);

    // Extending past the anchor flips the range's direction, not its ends.
    field.moveCaretLeft(true);
    const extended = field.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 0), extended.start);
    try std.testing.expectEqual(@as(usize, 2), extended.end);

    // A non-select move collapses the selection.
    field.moveCaretTo(3, false);
    try std.testing.expect(field.selectionRange() == null);

    // Bounds clamp; mid-codepoint rounds forward (covered with multibyte
    // below); out-of-range indexes clamp to the buffer ends.
    field.moveCaretTo(99, false);
    try std.testing.expectEqual(field.length, field.caret);
    field.moveCaretTo(0, false);
    // Anchor == caret is no selection (the degenerate guard).
    field.selection_anchor = field.caret;
    try std.testing.expect(field.selectionRange() == null);
}

test "TextField: insert replaces the selection (both anchor directions)" {
    var field: TextField = .{};
    field.loadValue("Skeleton Warrior");

    // Select forward from 8 to 16 (" Warrior"), then type over it.
    field.moveCaretTo(8, false);
    field.moveCaretTo(16, true);
    field.insertText(" Knight");
    try std.testing.expectEqualStrings("Skeleton Knight", field.currentText());
    try std.testing.expectEqual(@as(usize, 15), field.caret);

    // Select backward (anchor at 15, caret at 8) - same replaced range.
    field.moveCaretTo(15, false);
    field.moveCaretTo(8, true);
    try std.testing.expectEqual(@as(usize, 8), field.selectionRange().?.start);
    field.insertText("Goblin");
    try std.testing.expectEqualStrings("SkeletonGoblin", field.currentText());
    try std.testing.expectEqual(@as(usize, 14), field.caret);
    try std.testing.expect(field.selection_anchor == null);
}

test "TextField: caret navigation is codepoint-aware (UTF-8)" {
    // "é" = 0xC3 0xA9 (2 bytes), "z" = 1 byte: a 5-byte buffer holding
    // 3 codepoints.
    var field: TextField = .{};
    field.loadValue("\u{00E9}z\u{00E9}");
    try std.testing.expectEqual(@as(usize, 5), field.length);

    // Left from the end steps one CODEPOINT at a time: 5 -> 3 (start of
    // the trailing é) -> 2 (the single-byte 'z').
    field.moveCaretLeft(false);
    try std.testing.expectEqual(@as(usize, 3), field.caret);
    field.moveCaretLeft(false);
    try std.testing.expectEqual(@as(usize, 2), field.caret);

    // Right steps over the full sequence again.
    field.moveCaretRight(false);
    try std.testing.expectEqual(@as(usize, 3), field.caret);

    // Backspace removes the whole codepoint before the caret (the 'z').
    field.deleteBackward();
    try std.testing.expectEqualStrings("\u{00E9}\u{00E9}", field.currentText());
    try std.testing.expectEqual(@as(usize, 2), field.caret);

    // Delete-forward removes the whole codepoint after the caret (the
    // trailing é).
    field.deleteForward();
    try std.testing.expectEqualStrings("\u{00E9}", field.currentText());

    // A mid-codepoint index rounds FORWARD to the next boundary (so a
    // stray 1 inside the first sequence is boundary 3, not 1).
    field.loadValue("\u{00E9}\u{00E9}");
    field.moveCaretTo(1, false);
    try std.testing.expectEqual(@as(usize, 2), field.caret);
}

test "TextField: caretIndexAtX maps a click x to a boundary" {
    // Synthetic metrics (the measurement-seam convention above): each
    // ASCII glyph measures 55px at font_size 100.
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const field_text = "abcd";

    // Clicking inside the first glyph (x < 55) positions before it; each
    // 55px step lands before the next glyph.
    try std.testing.expectEqual(@as(usize, 0), TextField.caretIndexAtX(field_text, metrics, 100, 0));
    try std.testing.expectEqual(@as(usize, 0), TextField.caretIndexAtX(field_text, metrics, 100, 54));
    try std.testing.expectEqual(@as(usize, 1), TextField.caretIndexAtX(field_text, metrics, 100, 55));
    try std.testing.expectEqual(@as(usize, 2), TextField.caretIndexAtX(field_text, metrics, 100, 110));
    try std.testing.expectEqual(@as(usize, 3), TextField.caretIndexAtX(field_text, metrics, 100, 165));
    // Past the end = the end.
    try std.testing.expectEqual(@as(usize, 4), TextField.caretIndexAtX(field_text, metrics, 100, 500));

    // Multibyte: the fallback width (0.5em + spacing = 55 at size 100 -
    // same as an ASCII glyph here) keeps boundaries whole.
    try std.testing.expectEqual(@as(usize, 0), TextField.caretIndexAtX("\u{00E9}z", metrics, 100, 50));
    try std.testing.expectEqual(@as(usize, 2), TextField.caretIndexAtX("\u{00E9}z", metrics, 100, 56));
}

test "routeTextInput: chars insert, edit keys apply, Enter/Escape resolve, repeats edit-only" {
    var ui_state: UiState = .{};
    beginTextEdit(
        &ui_state,
        .{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } },
        "Skeleton",
    );

    const no_keys: [0]?[]const u8 = .{};
    const enter_pressed: [1]?[]const u8 = .{"Enter"};
    const escape_pressed: [1]?[]const u8 = .{"Escape"};
    const backspace_pressed: [1]?[]const u8 = .{"Backspace"};
    const backspace_repeated: [1]?[]const u8 = .{"Backspace"};
    const arrow_pressed: [1]?[]const u8 = .{"ArrowLeft"};

    // Typed characters append at the caret.
    try std.testing.expectEqual(
        types.TextEditOutcome.none,
        routeTextInput(&ui_state.text_edit.?, " Warrior", &no_keys, &no_keys, false),
    );
    try std.testing.expectEqualStrings("Skeleton Warrior", ui_state.text_edit.?.buffer.currentText());

    // A real backspace edge deletes one codepoint.
    try std.testing.expectEqual(
        types.TextEditOutcome.none,
        routeTextInput(&ui_state.text_edit.?, "", &backspace_pressed, &no_keys, false),
    );
    try std.testing.expectEqualStrings("Skeleton Warrio", ui_state.text_edit.?.buffer.currentText());

    // A synthetic repeat edge (hold-backspace) deletes another; its
    // outcome - if the key were a resolver - is discarded.
    _ = routeTextInput(&ui_state.text_edit.?, "", &no_keys, &backspace_repeated, false);
    try std.testing.expectEqualStrings("Skeleton Warri", ui_state.text_edit.?.buffer.currentText());

    // Shift+ArrowLeft selects (the anchor plants at the old caret -
    // caret 14 on the 14-char buffer, one codepoint back to 13).
    _ = routeTextInput(&ui_state.text_edit.?, "", &arrow_pressed, &no_keys, true);
    const selection = ui_state.text_edit.?.buffer.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 13), selection.start);
    try std.testing.expectEqual(@as(usize, 14), selection.end);

    // Enter resolves to commit; Escape to discard.
    try std.testing.expectEqual(
        types.TextEditOutcome.commit,
        routeTextInput(&ui_state.text_edit.?, "", &enter_pressed, &no_keys, false),
    );
    try std.testing.expectEqual(
        types.TextEditOutcome.cancel,
        routeTextInput(&ui_state.text_edit.?, "", &escape_pressed, &no_keys, false),
    );
}

test "placeCaretFromClick: click x maps through the field's text origin" {
    var ui_state: UiState = .{};
    beginTextEdit(&ui_state, .{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } }, "abcd");
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const field: TextFieldUi = .{
        .screen_position = .{ .x = 0, .y = 0 },
        .width = 512,
        .height = 96,
        .text_position = .{ .x = 100, .y = 0 },
        .text = "abcd",
        .font_size = 100,
        .frame_color = default_tint,
        .ref = .{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } },
    };

    // Each glyph measures 55px at size 100 (the synthetic convention); a
    // click two glyphs into the text (field x 100 + 110) lands the caret
    // at index 2. Clicking far past the end lands at the end.
    placeCaretFromClick(&ui_state.text_edit.?, field, 100 + 110, metrics);
    try std.testing.expectEqual(@as(usize, 2), ui_state.text_edit.?.buffer.caret);
    placeCaretFromClick(&ui_state.text_edit.?, field, 999, metrics);
    try std.testing.expectEqual(@as(usize, 4), ui_state.text_edit.?.buffer.caret);
    // A plain move clears any selection.
    ui_state.text_edit.?.buffer.moveCaretTo(1, true);
    try std.testing.expect(ui_state.text_edit.?.buffer.selectionRange() != null);
    placeCaretFromClick(&ui_state.text_edit.?, field, 100, metrics);
    try std.testing.expect(ui_state.text_edit.?.buffer.selectionRange() == null);
}
