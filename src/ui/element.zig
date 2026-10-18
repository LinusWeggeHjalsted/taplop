//! UI framework core: the flat `UiElement` tagged union + its variants,
//! layout (Rect algebra - `Row`/`Grid`, reference-space layout constants),
//! the tooltip span content model, the `FontMetrics` measurement seam, and
//! the hit-testing primitives (boundsOf/buttonAt/slotAt/tooltipAt - one
//! occlusion walk over the flat list). Self-contained over types.zig;
//! builders append into a shared `UiElementList` (see DESIGN → UI
//! Framework).

const std = @import("std");
const types = @import("../types.zig");

const Action = types.Action;
const ScreenPosition = types.ScreenPosition;
const Rectangle = types.Rectangle;
const Color = types.Color;
const GearSlot = types.GearSlot;
const SkillId = types.SkillId;

/// Identity of a slot the pointer can start a drag from or drop onto. The
/// two item variants (inventory/gear) and two skill variants (skill_bar/
/// learned_skill) form the item and skill "domains"; drag resolution routes
/// on the source domain and rejects cross-domain drops, so skills and items
/// never interact.
pub const SlotRef = union(enum) {
    inventory: u32, // inventory slot index
    gear: GearSlot, // equipped gear slot
    skill_bar: u32, // utility bar slot index (0-4)
    learned_skill: SkillId, // an entry in the skills-menu pool

    /// Whether two refs identify the same slot (same variant + same index/
    /// gear slot / skill id). Tagged-union equality with a same-variant
    /// short-circuit.
    pub fn eql(a: SlotRef, b: SlotRef) bool {
        return switch (a) {
            .inventory => |ai| switch (b) {
                .inventory => |bi| ai == bi,
                else => false,
            },
            .gear => |ag| switch (b) {
                .gear => |bg| ag == bg,
                else => false,
            },
            .skill_bar => |ai| switch (b) {
                .skill_bar => |bi| ai == bi,
                else => false,
            },
            .learned_skill => |as| switch (b) {
                .learned_skill => |bs| as == bs,
                else => false,
            },
        };
    }
};

// Tooltip content model
// ============================================================
// A tooltip is a stack of rows plus an optional header row. A row is a
// sequence of inline-styled spans; wrapping happens per row and preserves
// each span's styling. Stat lines like "Range 3" are just ordinary rows
// (value is text after a space) - no special alignment or wrapping rules.
// All of this is built per-frame in the view arena.

/// A run of text sharing one style within a row.
pub const Span = struct {
    text: []const u8,
    color: Color = default_tint,
    bold: bool = false,
    italic: bool = false,
};

/// One logical line of a tooltip; wraps into visual lines during layout.
pub const TooltipRow = []const Span;

/// Unlaid-out tooltip content carried by a UI element. `header` is a
/// distinct row only so layout can give it separator/extra spacing; its
/// styling still comes from its spans.
pub const Tooltip = struct {
    header: ?TooltipRow = null,
    body: []const TooltipRow = &.{},
};

// -- span constructors (readable authoring at call sites) --

/// A plain span in the default color.
pub fn text(value: []const u8) Span {
    return .{ .text = value };
}

/// A span in a specific color.
pub fn colored(value: []const u8, color: Color) Span {
    return .{ .text = value, .color = color };
}

/// A bold span in the default color.
pub fn bold(value: []const u8) Span {
    return .{ .text = value, .bold = true };
}

/// An italic span in the default color.
pub fn italic(value: []const u8) Span {
    return .{ .text = value, .italic = true };
}

// ============================================================
// Text measurement
// ============================================================
// The ONLY font-dependent code in text layout. Everything else (wrapping,
// panel sizing, corner selection, label centering) is written against the
// `FontMetrics` methods below and `lineHeight`; their innards read the font's
// per-glyph advance table (extracted from the loaded raylib `Font` by the
// backend) instead of assuming a fixed advance. `FontMetrics` is a plain
// value type (no raylib import) so the measurement seam stays testable in
// the headless build.

/// Per-glyph extra spacing the renderer adds between glyphs, expressed as
/// `font_size / glyph_spacing_font_divisor`. Shared by `FontMetrics`
/// measurement and `RaylibBackend.drawTextLabel` so layout measure matches
/// render advance (raylib's `DrawTextEx` adds this per glyph to the cursor).
/// One source of truth - keep the two in sync.
pub const glyph_spacing_font_divisor: i32 = 20;

/// One non-ASCII glyph's advance, extracted from the active font by the
/// backend. A `FontMetrics`'s `non_ascii` slice is sorted ascending by
/// codepoint so lookups binary-search.
pub const NonAsciiAdvance = struct {
    codepoint: u21,
    /// Advance width at `base_size`; 0 treated as "no advance recorded"
    /// (the 0.5em fallback applies, mirroring the ASCII zero-advance rule).
    advance: i32,
};

/// Per-glyph advance widths for the loaded font, in source pixels at
/// `base_size`. ASCII codepoints (32..126) index `advances`; non-ASCII
/// codepoints binary-search `non_ascii` (filled from the font's full cmap
/// coverage); a codepoint the font lacks falls back to a rough 0.5em
/// advance. The backend fills this from the loaded `rl.Font`
/// (`RaylibBackend.fontMetrics`); layout code receives it via
/// `RenderContext.font_metrics` so `view()` and its builders measure text
/// with the same advances the renderer draws with. `non_ascii` borrows
/// backend-owned storage (session lifetime) - a FontMetrics value is only
/// valid within the frame it was fetched in.
pub const FontMetrics = struct {
    /// The font size the `advances` were rasterized at (raylib `Font.baseSize`).
    base_size: i32,
    /// Advance width at `base_size` for ASCII codepoint `(index + 32)`.
    advances: [95]i32,
    /// Advances at `base_size` for the font's non-ASCII glyphs, sorted by
    /// codepoint. Empty when the active font was baked without them (the
    /// default-font fallback) - every multibyte sequence then measures via the
    /// 0.5em fallback.
    non_ascii: []const NonAsciiAdvance = &.{},

    /// Advance width of a span at `font_size`, in reference pixels. Mirrors
    /// raylib's `DrawTextEx` cursor advance per glyph - `advanceX *
    /// (font_size / base_size) + spacing` - so the measure matches where the
    /// renderer's cursor actually lands (and multi-span emit flows like one
    /// continuous string). Float-accumulated per glyph, truncated to i32 at
    /// the end. UTF-8-aware: ASCII bytes index `advances`; a multibyte
    /// sequence decodes to a codepoint and binary-searches `non_ascii`,
    /// falling back to a rough 0.5em advance when the sequence is invalid,
    /// truncated, or the codepoint has no recorded advance.
    pub fn measureSpanWidth(self: FontMetrics, span: Span, font_size: i32) i32 {
        const scale_factor: f32 = @as(f32, @floatFromInt(font_size)) / @as(f32, @floatFromInt(self.base_size));
        const spacing: f32 = @as(f32, @floatFromInt(font_size)) / @as(f32, @floatFromInt(glyph_spacing_font_divisor));
        var total: f32 = 0;
        var i: usize = 0;
        while (i < span.text.len) {
            const byte = span.text[i];
            if (byte < 0x80) {
                total += self.asciiAdvance(byte, font_size, scale_factor, spacing);
                i += 1;
            } else {
                // Multibyte lead byte: decode the codepoint to look up its
                // advance in `non_ascii` (the font's full-coverage glyph
                // set). An invalid sequence, a truncated tail (clamped to
                // the slice end so it can't overrun), or a codepoint the
                // font lacks falls back to the 0.5em approximation.
                const len: usize = switch (byte & 0xF0) {
                    0xC0, 0xD0 => 2,
                    0xE0 => 3,
                    0xF0 => 4,
                    else => 1, // invalid lead byte - skip one, stay in bounds
                };
                const sequence_end = @min(i + len, span.text.len);
                const codepoint: ?u21 = if (sequence_end - i == len)
                    std.unicode.utf8Decode(span.text[i..sequence_end]) catch null
                else
                    null;
                i = sequence_end;
                if (codepoint) |value| {
                    if (self.nonAsciiAdvance(value)) |advance| {
                        total += @as(f32, @floatFromInt(advance)) * scale_factor + spacing;
                        continue;
                    }
                }
                total += @as(f32, @floatFromInt(font_size)) * 0.5 + spacing;
            }
        }
        return @intFromFloat(total);
    }

    /// Binary-search `non_ascii` for one codepoint's advance; null when the
    /// font has no recorded advance for it (absent from the baked set, or a
    /// zero advance).
    fn nonAsciiAdvance(self: FontMetrics, codepoint: u21) ?i32 {
        var low: usize = 0;
        var high: usize = self.non_ascii.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = self.non_ascii[mid];
            if (entry.codepoint == codepoint) {
                return if (entry.advance > 0) entry.advance else null;
            }
            if (entry.codepoint < codepoint) low = mid + 1 else high = mid;
        }
        return null;
    }

    /// Per-glyph advance for one ASCII byte at `font_size`. Matches raylib's
    /// `DrawTextEx`: `advanceX * scaleFactor + spacing` when the glyph has a
    /// nonzero advance, else a 0.5em fallback (raylib falls back to
    /// `recs.width`; we approximate with 0.5em - close enough for the rare
    /// zero-advance glyph).
    fn asciiAdvance(self: FontMetrics, byte: u8, font_size: i32, scale_factor: f32, spacing: f32) f32 {
        if (byte >= 32 and byte <= 126) {
            const advance = self.advances[byte - 32];
            if (advance > 0) {
                return @as(f32, @floatFromInt(advance)) * scale_factor + spacing;
            }
            // Zero-advance glyph (not in the font / blank). Use 0.5em.
            return @as(f32, @floatFromInt(font_size)) * 0.5 + spacing;
        }
        // Control character or DEL - 0.5em fallback.
        return @as(f32, @floatFromInt(font_size)) * 0.5 + spacing;
    }

    /// Total width of a row's spans laid out on one line, in reference pixels.
    pub fn measureRowWidth(self: FontMetrics, row: TooltipRow, font_size: i32) i32 {
        var total: i32 = 0;
        for (row) |span| total += self.measureSpanWidth(span, font_size);
        return total;
    }
};

/// Baseline-to-baseline height for one line at `font_size`, in reference
/// pixels. A layout factor (1.2em leading), not font data - raylib doesn't
/// expose hhea/OS·2 line metrics, so this stays a free function independent
/// of `FontMetrics`.
pub fn lineHeight(font_size: i32) i32 {
    return @divTrunc(font_size * 120, 100);
}

test "measurement seam: non-ASCII glyphs measure via their real advances" {
    // Synthetic metrics: base_size 100, uniform 50px ASCII advance; the
    // font's full-coverage set records em-dash (U+2014) at 90 and ellipsis
    // (U+2026) at 130. At font_size 100 each glyph adds its advance + 5px
    // spacing: ASCII 55, em-dash 95, ellipsis 135.
    const non_ascii = [_]NonAsciiAdvance{
        .{ .codepoint = 0x2014, .advance = 90 },
        .{ .codepoint = 0x2026, .advance = 130 },
    };
    const metrics = FontMetrics{
        .base_size = 100,
        .advances = [_]i32{50} ** 95,
        .non_ascii = &non_ascii,
    };
    const font_size: i32 = 100;
    // "a - b": 55 + 95 + 55 = 205 (the em-dash advance, not 0.5em).
    try std.testing.expectEqual(
        @as(i32, 205),
        metrics.measureSpanWidth(text("a\u{2014}b"), font_size),
    );
    // "a...b" with a real ellipsis: 55 + 135 + 55 = 245.
    try std.testing.expectEqual(
        @as(i32, 245),
        metrics.measureSpanWidth(text("a\u{2026}b"), font_size),
    );

    // A codepoint the font lacks (en-dash) falls back to 0.5em: 50 + 5.
    try std.testing.expectEqual(
        @as(i32, 55),
        metrics.measureSpanWidth(text("\u{2013}"), font_size),
    );
    // Empty non_ascii (the default-font fallback) keeps the 0.5em behavior.
    const ascii_only = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    try std.testing.expectEqual(
        @as(i32, 55),
        ascii_only.measureSpanWidth(text("\u{2014}"), font_size),
    );

    // Invalid UTF-8 and truncated multibyte tails measure via the fallback
    // without reading out of bounds.
    try std.testing.expectEqual(
        @as(i32, 55),
        metrics.measureSpanWidth(text("\xFF"), font_size),
    );
    // "\xE2\x80" is a 3-byte em-dash sequence missing its last byte.
    try std.testing.expectEqual(
        @as(i32, 55),
        metrics.measureSpanWidth(text("\xE2\x80"), font_size),
    );
}

test "measurement seam: row width sums spans, bold equals plain" {
    // Synthetic metrics: base_size 100, uniform 50px advance per ASCII glyph.
    // With the shared per-glyph spacing (font_size/20 = 5px), each glyph
    // measures 50 + 5 = 55px - reproduces raylib's DrawTextEx cursor advance
    // so the wrapping/layout tests below stay deterministic and font-agnostic.
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const font_size: i32 = 100;
    // Plain: 4 glyphs * (50 advance + 5 spacing) = 220.
    try std.testing.expectEqual(@as(i32, 220), metrics.measureSpanWidth(text("abcd"), font_size));
    // Only the regular face is loaded, so bold renders identical to plain -
    // the metrics reflect that honestly (no bold inflation).
    try std.testing.expectEqual(
        metrics.measureSpanWidth(text("abcd"), font_size),
        metrics.measureSpanWidth(bold("abcd"), font_size),
    );
    // A row's width is the sum of its spans.
    const row: TooltipRow = &.{ text("ab"), colored("cd", default_tint) };
    try std.testing.expectEqual(metrics.measureSpanWidth(text("abcd"), font_size), metrics.measureRowWidth(row, font_size));
    // Line height exceeds the font size (leading).
    try std.testing.expect(lineHeight(font_size) > font_size);
}

// Layout constants - fixed sizes in reference resolution
// ============================================================

/// The global top bar's height - matches its buttons (`top_bar_slot_size`;
/// the bar is a plain layout region, no background). Smaller than the
/// bottom bar on purpose: the top bar carries secondary controls
/// (options / undo / redo) and shouldn't compete with the bottom bar's
/// gameplay slots for screen space.
pub const top_bar_height: i32 = 128;
pub const bottom_bar_height: i32 = 256;
/// Global-top-bar button cell size (options / undo / redo). Distinct from
/// `slot_size` (the bottom bar's 256×256 gameplay slots stay that size).
pub const top_bar_slot_size: i32 = 128;
/// Standard gameplay button/slot size (128×128 at 1080p → 256×256 at the
/// 2160p reference resolution).
pub const slot_size: i32 = 256;
/// Weapon-swap button - half a normal button, centered vertically.
pub const swap_button_size: i32 = 128;
/// Scrollbar geometry + colors (reference-space pixels), shared by every
/// scrollbar surface (error popup, editor theme picker, load-save browser,
/// editor browser, skills grid, editor inspector, settings keybinds
/// columns): a 12px track with a 16px gap from the scrolled content, fixed
/// grays, a 40px minimum thumb, drawn only when content overflows. One
/// tuning knob per surface class - the scrollbar-polish pass retunes here.
pub const scrollbar_width: i32 = 12;
pub const scrollbar_gap: i32 = 16;
pub const scrollbar_track_color: Color = .{ .r = 80, .g = 80, .b = 80 };
pub const scrollbar_thumb_color: Color = .{ .r = 180, .g = 180, .b = 180 };
pub const scrollbar_thumb_min_height: i32 = 40;
/// Main-menu button - wide stacked buttons on the title screen.
pub const menu_button_width: i32 = 1024;
pub const menu_button_font_size: i32 = 96;
/// Main-menu title ("taplop") - centered at the top of the screen, above
/// the button stack. Larger than every other UI font size (atlas glyphs
/// upscale 1.5× from the 128px base - accepted softness for a title).
pub const main_menu_title_font_size: i32 = 256;
/// Gap between the main-menu title band and the first button.
pub const main_menu_title_gap: i32 = 96;
/// Shared height for every `emitPanelButton` panel-backed button (main
/// menu, mission end screens, error-popup dismiss, load-save browser,
/// credits, settings). One tuning knob for the panel-button height class -
/// per-screen heights proved to be five copies of the same number.
pub const panel_button_height: i32 = 160;
/// Secondary indicator icons above the bar (momentum, effects, turn steps).
pub const small_icon_size: i32 = 128;
/// Health globe sizes match the downscaled Unity art. The ball sits inside
/// the ornamented border, which is a touch wider than the 256 cell and
/// overhangs horizontally.
pub const health_globe_ball_size: i32 = 212;
pub const health_globe_border_width: i32 = 297;
pub const health_globe_border_height: i32 = slot_size; // 256 tall by design
/// Gap between top-level UI items (e.g. bottom-bar segments).
pub const ui_gap: i32 = 16;
pub const slot_padding: i32 = 8;
/// Shared movement threshold (reference-space pixels) separating a click
/// from a drag, used by EVERY drag gesture (slot drags, camera pan,
/// marquee, selection move, right-click cancel). A press that moves no more
/// than this before release is a click; strictly beyond it the press promotes
/// to a drag (strict `>` so a zero value still tolerates a no-movement
/// press). Standard UI disambiguation - see DESIGN → UI Framework.
pub const drag_threshold_pixels: i32 = 2;
/// Double-click window (microseconds, session-clock). Two plain single
/// clicks on the same inventory slot + same button within this window fire
/// the double-click intent. Modifier-clicks (ctrl/alt/shift) fire
/// immediately and don't seed a pending double.
pub const double_click_threshold_us: u64 = 400_000;
/// One inventory grid cell (half `slot_size` - ported from the Unity
/// 256×256 ItemSlot.png at 0.5x). See DESIGN → UI Framework.
pub const inventory_slot_size: i32 = 128;
/// Inventory panel content area (below the header): `ui_gap` clearance +
/// 8×12 flush grid (1024×1536) + `ui_gap` + 128-wide material sidebar +
/// `ui_gap` clearance. Width  = 16 + 1024 + 16 + 128 + 16 = 1200.
/// Content height = 16 + 1536 + 16 = 1568 = middle_panel_height − header_height.
pub const inventory_panel_width: i32 = 1200;
/// Middle panels (inventory / gear / skills / entity inspect) occupy the
/// TOP of the middle section: height is the inventory grid's EXACT FIT
/// (header + gap + grid + gap), NOT the section - the freed strip below
/// them, down to the bottom bar, is the bottom-bar indicator row's
/// dedicated space (momentum / effects / turn steps sit flush against the
/// bar; see bottom_bar.zig). Derived from the same constants the inventory
/// builder lays out with, so the grid can never outgrow the panel.
pub const middle_panel_height: i32 = middle_panel_header_height + 2 * ui_gap + types.inventory_rows * inventory_slot_size;
/// Height of the title + close-button strip at the top of every middle
/// panel. Sized so the inventory grid fits exactly below it (1648 − 80 −
/// 1568 = 0 slack). The close button matches this height.
pub const middle_panel_header_height: i32 = 80;
/// Close-button edge length (matches `middle_panel_header_height`). Flush
/// in the panel's top-right corner. Sprite `ui/close_button` is a placeholder
/// (magenta fallback) until real art lands; the hover outline still renders
/// via the `highlighted` rect-outline fallback in the renderer.
pub const close_button_size: i32 = middle_panel_header_height;
/// Title text font size for middle-panel headers. Vertically centered in
/// `middle_panel_header_height` (raylib draws from the top of a font_size-
/// tall cell).
pub const middle_panel_header_font_size: i32 = 56;
pub const close_button_sprite_id: []const u8 = "ui/close_button";
/// Skills panel: `ui_gap` clearance + a 4-wide grid of `slot_size` (256)
/// cells (1024 wide) + `ui_gap` clearance. Width = 16 + 1024 + 16 = 1056.
/// Height shares `middle_panel_height` with the other middle panels.
pub const skills_panel_width: i32 = 1056;
pub const skills_panel_columns: i32 = 4;
/// Enemy-inspect panel width: the 4-wide skill grid (4 × `slot_size` +
/// 2 × `ui_gap` side margins = 1056). The gear mirror + active-effects
/// strip fit within this width. See `buildEntityInspectPanel`.
pub const entity_inspect_panel_width: i32 = 4 * slot_size + 2 * ui_gap;

/// Default tint for UI elements. For sprites (Button/Slot/Image) this means
/// "no tint" (pure white, show original art). For text it is the "unset"
/// sentinel: the renderer's `drawTextLabel` substitutes the active theme's
/// `lightest` (the artist's offwhite) so uncolored text inherits the theme
/// without builders needing a runtime color. Explicitly colored text (via
/// `colored(...)`) passes a non-`default_tint` color and is unaffected.
pub const default_tint: Color = .{ .r = 255, .g = 255, .b = 255 };

// ============================================================
// Layout helpers
// ============================================================

/// The full reference-resolution canvas - the root region everything
/// else is placed within.
pub fn screenRect() Rectangle {
    return .{ .x = 0, .y = 0, .width = types.reference_width, .height = types.reference_height };
}

/// Total width of `count` items of `item_width` separated by `gap`.
/// Handy for sizing a group before centering or right-aligning it.
pub fn rowWidth(count: i32, item_width: i32, gap: i32) i32 {
    if (count <= 0) return 0;
    return count * item_width + (count - 1) * gap;
}

/// Lays out fixed-height cells left-to-right from an origin, advancing a
/// cursor after each. Call `next(width)` for each cell in order.
pub const Row = struct {
    origin: ScreenPosition,
    height: i32,
    gap: i32,
    cursor_x: i32 = 0,

    pub fn init(origin: ScreenPosition, height: i32, gap: i32) Row {
        return .{ .origin = origin, .height = height, .gap = gap };
    }

    pub fn next(self: *Row, width: i32) Rectangle {
        const rect: Rectangle = .{
            .x = self.origin.x + self.cursor_x,
            .y = self.origin.y,
            .width = width,
            .height = self.height,
        };
        self.cursor_x += width + self.gap;
        return rect;
    }
};

/// A uniform grid of cells (e.g. the inventory). `cell(index)` returns
/// the rectangle for the nth cell, filling row by row.
pub const Grid = struct {
    origin: ScreenPosition,
    cell_width: i32,
    cell_height: i32,
    gap: i32,
    columns: i32,

    pub fn cell(self: Grid, index: i32) Rectangle {
        const column = @mod(index, self.columns);
        const row = @divFloor(index, self.columns);
        return .{
            .x = self.origin.x + column * (self.cell_width + self.gap),
            .y = self.origin.y + row * (self.cell_height + self.gap),
            .width = self.cell_width,
            .height = self.cell_height,
        };
    }
};

// ============================================================
// UI elements - building blocks for the view function
// ============================================================

/// A 9-slice panel background. The source sprite is a 3x3 grid of equal
/// slices (slice size = sprite dimension / 3); the renderer draws the four
/// corners 1:1 and stretches the four edges + center to fill. The slice
/// thickness comes from the sprite itself, so there is no border field here.
pub const NineSlicePanel = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    width: i32,
    height: i32,
    color: Color = default_tint,
    tooltip: ?Tooltip = null,
    blocks_input: bool = true,
};

/// One draw of a 9-slice: a source region (texture pixels) blitted into a
/// destination region (reference pixels). Pure geometry - the renderer only
/// forwards each pair to the GPU.
pub const NineSlicePiece = struct {
    source: Rectangle,
    destination: Rectangle,
};

/// Compute the nine source/destination rect pairs that draw a 9-slice panel
/// sprite over `destination`. All corners are drawn SQUARE (aspect-true 1:1):
/// the corner size is `min(slice_width, slice_height, destination.width/2,
/// destination.height/2)`, and both the source and destination rects are
/// cropped to that size - a panel shorter than two slices gets proportionally
/// smaller corners instead of squashed ones. Edges stretch along their run
/// axis and keep the corner thickness across it; the center stretches in
/// both axes. Pieces are row-major (top-left, top, top-right, left, center,
/// right, bottom-left, bottom, bottom-right); degenerate pieces (zero size,
/// only possible on a panel smaller than 2× the corner size) are returned
/// with zero extents for the caller to skip.
fn nineSlicePieces(
    texture_width: i32,
    texture_height: i32,
    destination: Rectangle,
) [9]NineSlicePiece {
    const slice_width = @divTrunc(texture_width, 3);
    const slice_height = @divTrunc(texture_height, 3);
    const corner = @min(
        @min(slice_width, slice_height),
        @min(@divTrunc(destination.width, 2), @divTrunc(destination.height, 2)),
    );

    // The 3×3 grid of source/destination columns and rows. Corners occupy
    // `corner` in both spaces; edge/center sources span between the corner
    // regions of the texture, destinations between the corner regions of the
    // panel.
    const source_columns = [3]i32{ 0, corner, texture_width - corner };
    const source_rows = [3]i32{ 0, corner, texture_height - corner };
    const source_widths = [3]i32{ corner, texture_width - corner * 2, corner };
    const source_heights = [3]i32{ corner, texture_height - corner * 2, corner };

    const destination_columns = [3]i32{ destination.x, destination.x + corner, destination.x + destination.width - corner };
    const destination_rows = [3]i32{ destination.y, destination.y + corner, destination.y + destination.height - corner };
    const destination_widths = [3]i32{ corner, destination.width - corner * 2, corner };
    const destination_heights = [3]i32{ corner, destination.height - corner * 2, corner };

    var pieces: [9]NineSlicePiece = undefined;
    var index: usize = 0;
    for (0..3) |row| {
        for (0..3) |column| {
            pieces[index] = .{
                .source = .{
                    .x = source_columns[column],
                    .y = source_rows[row],
                    .width = source_widths[column],
                    .height = source_heights[row],
                },
                .destination = .{
                    .x = destination_columns[column],
                    .y = destination_rows[row],
                    .width = destination_widths[column],
                    .height = destination_heights[row],
                },
            };
            index += 1;
        }
    }
    return pieces;
}

/// Nine-slice pieces for drawing under render-target minification: the
/// `nineSlicePieces` math plus the RUN-axis source crop. `render_scale` is
/// the render target's zoom (target px per reference px - the UI-pass
/// camera zoom, `RaylibBackend.renderScale`).
///
/// WHY the crop: a NARROW panel's top/bottom edge pieces span the whole
/// source width (texture_width - 2*corner texels) but land in a destination
/// only a fraction as wide - the piece minifies 3-6x along its run axis,
/// dragging the texture LOD 2+ mip levels down where the border stroke is
/// box-averaged to a fraction of its true thickness; trilinear ghost-blends
/// those thin levels into the sample and the border renders as a
/// gray-gradient smear (the small-tooltip 9-slice bug; probe history in
/// DONE.md). Cropping the source span to the destination's span in TARGET
/// pixels keeps the run-axis LOD term at 0 (<= 1:1 texel:pixel), so the
/// border samples at its true thickness - small panels render as crisp as
/// large ones, at every render_resolution preset.
///
/// Piece roles: corners are never cropped (square 1:1 in both spaces by
/// construction); top/bottom edges crop their width, left/right edges
/// their height, the center both. The CROSS axis is never cropped (already
/// 1:1 in reference space - cropping it would cut into the border). The
/// crop window is centered along the run axis: the shipped edge art is
/// uniform there, so the window choice is invisible; when patterned edge
/// art ships, the tiling refinement supersedes it.
pub fn nineSlicePiecesAtScale(
    texture_width: i32,
    texture_height: i32,
    destination: Rectangle,
    render_scale: f32,
) [9]NineSlicePiece {
    var pieces = nineSlicePieces(texture_width, texture_height, destination);
    for (&pieces, 0..) |*piece, index| {
        const is_corner = index == 0 or index == 2 or index == 6 or index == 8;
        if (is_corner) continue;
        const is_center = index == 4;
        const crop_width = is_center or index == 1 or index == 7;
        const crop_height = is_center or index == 3 or index == 5;
        if (crop_width) {
            const span = cropRunAxis(piece.source.x, piece.source.width, piece.destination.width, render_scale);
            piece.source.x = span.offset;
            piece.source.width = span.span;
        }
        if (crop_height) {
            const span = cropRunAxis(piece.source.y, piece.source.height, piece.destination.height, render_scale);
            piece.source.y = span.offset;
            piece.source.height = span.span;
        }
    }
    return pieces;
}

const CroppedSpan = struct { offset: i32, span: i32 };

/// Clamp a run-axis source span to the destination's span in TARGET pixels
/// (destination ref px * render_scale), window centered. No-op when the
/// source span already fits (the destination magnifies or matches along the
/// run axis) or the destination span degenerates to zero.
fn cropRunAxis(source_offset: i32, source_span: i32, destination_span: i32, render_scale: f32) CroppedSpan {
    const destination_target_span = @as(f32, @floatFromInt(destination_span)) * render_scale;
    const target_span: i32 = @intFromFloat(@round(destination_target_span));
    if (target_span <= 0 or source_span <= target_span)
        return .{ .offset = source_offset, .span = source_span };
    return .{
        .offset = source_offset + @divTrunc(source_span - target_span, 2),
        .span = target_span,
    };
}

test "nineSlicePieces: large panel keeps full square slices" {
    // ui/panel.png is 384×384 → 128px slices. A panel taller than two slices
    // keeps all nine pieces at full size.
    const pieces = nineSlicePieces(384, 384, .{ .x = 100, .y = 200, .width = 1024, .height = 512 });
    // Top-left corner: 1:1, source at the texture origin.
    try std.testing.expectEqual(Rectangle{ .x = 0, .y = 0, .width = 128, .height = 128 }, pieces[0].source);
    try std.testing.expectEqual(Rectangle{ .x = 100, .y = 200, .width = 128, .height = 128 }, pieces[0].destination);
    // Top-right corner: source hugs the texture's right edge, destination the
    // panel's right edge.
    try std.testing.expectEqual(Rectangle{ .x = 256, .y = 0, .width = 128, .height = 128 }, pieces[2].source);
    try std.testing.expectEqual(Rectangle{ .x = 996, .y = 200, .width = 128, .height = 128 }, pieces[2].destination);
    // Center: inner source region, stretched to the inner destination.
    try std.testing.expectEqual(Rectangle{ .x = 128, .y = 128, .width = 128, .height = 128 }, pieces[4].source);
    try std.testing.expectEqual(Rectangle{ .x = 228, .y = 328, .width = 768, .height = 256 }, pieces[4].destination);
    // Top edge: 128-thick in both spaces, stretched along the run axis.
    try std.testing.expectEqual(Rectangle{ .x = 128, .y = 0, .width = 128, .height = 128 }, pieces[1].source);
    try std.testing.expectEqual(Rectangle{ .x = 228, .y = 200, .width = 768, .height = 128 }, pieces[1].destination);
}

test "nineSlicePieces: short panel shrinks corners square instead of squashing" {
    // A 160px-tall panel is shorter than two 128px slices. The corners must
    // come out SQUARE at 80×80 (the old renderer clamped only the height,
    // drawing 128×80 squashed corners), with the source cropped to match.
    const pieces = nineSlicePieces(384, 384, .{ .x = 0, .y = 0, .width = 512, .height = 160 });
    try std.testing.expectEqual(Rectangle{ .x = 0, .y = 0, .width = 80, .height = 80 }, pieces[0].source);
    try std.testing.expectEqual(Rectangle{ .x = 0, .y = 0, .width = 80, .height = 80 }, pieces[0].destination);
    try std.testing.expectEqual(Rectangle{ .x = 432, .y = 0, .width = 80, .height = 80 }, pieces[2].destination);
    // Top edge: 80-thick strip cropped from the 128px slice, stretched along
    // the run axis only.
    try std.testing.expectEqual(Rectangle{ .x = 80, .y = 0, .width = 224, .height = 80 }, pieces[1].source);
    try std.testing.expectEqual(Rectangle{ .x = 80, .y = 0, .width = 352, .height = 80 }, pieces[1].destination);
    // Center collapses to zero height (skipped by the renderer).
    try std.testing.expectEqual(@as(i32, 0), pieces[4].destination.height);
}

test "nineSlicePieces: tiny panel clamps corners to half size" {
    const pieces = nineSlicePieces(384, 384, .{ .x = 40, .y = 60, .width = 100, .height = 100 });
    // Corner = min(128, 128, 50, 50) = 50 - everything shrinks uniformly.
    try std.testing.expectEqual(Rectangle{ .x = 0, .y = 0, .width = 50, .height = 50 }, pieces[0].source);
    try std.testing.expectEqual(Rectangle{ .x = 40, .y = 60, .width = 50, .height = 50 }, pieces[0].destination);
    // Degenerate center: corners meet, nothing left to fill.
    try std.testing.expectEqual(Rectangle{ .x = 90, .y = 110, .width = 0, .height = 0 }, pieces[4].destination);
}

test "nineSlicePieces: pieces tile the destination exactly" {
    const destination = Rectangle{ .x = 37, .y = 53, .width = 777, .height = 333 };
    const pieces = nineSlicePieces(384, 384, destination);
    // Each row of destinations tiles the panel: shared y + height, widths
    // summing to the panel width. Same check transposed for columns.
    var covered_width: i32 = 0;
    for (0..3) |column| {
        const first_in_column = pieces[column];
        var covered_height: i32 = 0;
        for (0..3) |row| {
            const piece = pieces[row * 3 + column];
            try std.testing.expectEqual(first_in_column.destination.x, piece.destination.x);
            try std.testing.expectEqual(first_in_column.destination.width, piece.destination.width);
            covered_height += piece.destination.height;
            // Sources stay inside the texture.
            try std.testing.expect(piece.source.x >= 0);
            try std.testing.expect(piece.source.y >= 0);
            try std.testing.expect(piece.source.x + piece.source.width <= 384);
            try std.testing.expect(piece.source.y + piece.source.height <= 384);
        }
        covered_width += first_in_column.destination.width;
        try std.testing.expectEqual(destination.height, covered_height);
    }
    try std.testing.expectEqual(destination.width, covered_width);
}

test "nineSlicePiecesAtScale: narrow tooltip edge pieces crop to the destination's target span" {
    // The undo tooltip's geometry (a header-only tooltip: 212x124 - text
    // width + padding, lineHeight(64) + padding) at the 1080p render scale
    // (0.5): corner 62, the top/bottom edge sources span 260 texels but the
    // destination run spans only 88 reference px (44 target px) - without
    // the crop the piece minifies 260:44 along the run axis and the border
    // smears through deep mips.
    const pieces = nineSlicePiecesAtScale(384, 384, .{ .x = 200, .y = 200, .width = 212, .height = 124 }, 0.5);
    // Top edge: source cropped to 44 texels, centered in the 260-texel
    // middle column (x 62 + (260-44)/2 = 170), cross axis untouched.
    try std.testing.expectEqual(Rectangle{ .x = 170, .y = 0, .width = 44, .height = 62 }, pieces[1].source);
    try std.testing.expectEqual(Rectangle{ .x = 262, .y = 200, .width = 88, .height = 62 }, pieces[1].destination);
    // Bottom edge: the same crop in the bottom slice.
    try std.testing.expectEqual(Rectangle{ .x = 170, .y = 322, .width = 44, .height = 62 }, pieces[7].source);
    // Corners never cropped (square 1:1 by construction).
    try std.testing.expectEqual(Rectangle{ .x = 0, .y = 0, .width = 62, .height = 62 }, pieces[0].source);
    try std.testing.expectEqual(Rectangle{ .x = 322, .y = 0, .width = 62, .height = 62 }, pieces[2].source);
    // Left/right edges are degenerate on a 124-tall panel (corner = h/2) -
    // zero-span destinations stay zero.
    try std.testing.expectEqual(@as(i32, 0), pieces[3].destination.height);
    try std.testing.expectEqual(@as(i32, 0), pieces[5].destination.height);
}

test "nineSlicePiecesAtScale: tall narrow panel crops the left/right edges" {
    // 212x300: corner 106, the left/right edge sources span 172 texels but
    // the destination run spans only 88 reference px (44 target); the
    // top/bottom edges are degenerate (corner = w/2).
    const pieces = nineSlicePiecesAtScale(384, 384, .{ .x = 0, .y = 0, .width = 212, .height = 300 }, 0.5);
    // Left edge: height cropped 172 -> 44, centered (y 106 + (172-44)/2).
    try std.testing.expectEqual(Rectangle{ .x = 0, .y = 170, .width = 106, .height = 44 }, pieces[3].source);
    try std.testing.expectEqual(Rectangle{ .x = 0, .y = 106, .width = 106, .height = 88 }, pieces[3].destination);
    try std.testing.expectEqual(@as(i32, 0), pieces[1].destination.width);
}

test "nineSlicePiecesAtScale: large panel pieces are unchanged" {
    // A wide panel's edge pieces MAGNIFY along the run axis (the source
    // span is the smaller side) - the crop is a no-op for every piece.
    const destination = Rectangle{ .x = 100, .y = 200, .width = 1024, .height = 512 };
    const uncropped = nineSlicePieces(384, 384, destination);
    const scaled = nineSlicePiecesAtScale(384, 384, destination, 0.5);
    for (uncropped, scaled) |before, after| try std.testing.expectEqual(before, after);
}

/// A clickable slot (inventory cell, gear slot, skill bar slot).
pub const Slot = struct {
    screen_position: ScreenPosition,
    size: i32 = slot_size,
    /// The icon inside the slot, if any.
    icon_sprite_id: ?[]const u8 = null,
    icon_color: Color = default_tint,
    /// Semantic identity, if this slot can be dragged from / dropped onto.
    ref: ?SlotRef = null,
    /// Tooltip shown on hover.
    tooltip: ?Tooltip = null,
    blocks_input: bool = true,
};

/// A clickable button with a sprite. Clicking triggers the same
/// action as the corresponding keybind.
pub const Button = struct {
    /// The button's own sprite, if any. `null` = a spriteless button used
    /// purely as an action/hit-test target over a separate background (e.g.
    /// a 9-slice panel behind it); the renderer draws nothing for it.
    sprite_id: ?[]const u8 = null,
    screen_position: ScreenPosition,
    width: i32 = slot_size,
    height: i32 = slot_size,
    color: Color = default_tint,
    action: Action,
    /// Renderer draws a programmatic edge highlight around the sprite's
    /// opaque pixels when set (e.g. selected panel button).
    highlighted: bool = false,
    tooltip: ?Tooltip = null,
    /// Semantic identity, if this button is also a drag source/drop target
    /// (e.g. a skill-bar slot: click = activate the skill, drag = reorder/
    /// clear). Null for action-only buttons. See `refAt`.
    ref: ?SlotRef = null,
    /// The button's identity BEYOND its action, if it has one - what was
    /// clicked (which row, which tab, which cell), riding the frame's
    /// input alongside the action (see `types.ButtonPayload` + DESIGN →
    /// Input → Button payloads). Null for action-only buttons; the
    /// variant must be the one `actionButtonPayload(action)` names.
    payload: ?types.ButtonPayload = null,
    blocks_input: bool = true,
};

/// An integer slider control (step 1). The backend draws a track + fill
/// + thumb; the input handler (`handleSliderDrag`) manages click/drag.
/// The value label is emitted as a separate `text_label` by the builder
/// (rebuilt each frame from the live settings value, so it tracks the drag
/// in real time). See DESIGN → UI Framework → Settings screen.
pub const Slider = struct {
    setting_id: types.SettingId,
    min: u32,
    max: u32,
    value: u32,
    screen_position: ScreenPosition,
    width: i32,
    height: i32,
    tooltip: ?Tooltip = null,
    blocks_input: bool = true,
};

/// A text label.
pub const TextLabel = struct {
    text: []const u8,
    screen_position: ScreenPosition,
    color: Color = default_tint,
    font_size: i32,
    bold: bool = false,
    italic: bool = false,
    /// Draw a pure-black edge-outline (the 8-direction drop-shadow ring,
    /// same machinery as floating damage numbers) under the fill for
    /// readability over varied backgrounds. See DESIGN → Animation.
    outlined: bool = false,
    tooltip: ?Tooltip = null,
    blocks_input: bool = true,
};

/// A partially-filled sprite, e.g. the circular health globe. Draws
/// `background_sprite_id` in full, then `fill_sprite_id` cropped to
/// `fill_fraction` from the given direction (e.g. `.up` keeps the
/// bottom portion). Generalizes to mana, radial cooldowns, etc.
pub const FillSprite = struct {
    background_sprite_id: []const u8,
    fill_sprite_id: []const u8,
    screen_position: ScreenPosition,
    width: i32,
    height: i32,
    /// 0 = empty, 1 = full.
    fill_fraction: f32,
    fill_direction: enum { up, down, left, right } = .up,
    /// The two sprites can share one flat asset (e.g. the white health ball)
    /// and read as empty vs filled purely through these tints (depleted color
    /// under the fill color).
    background_color: Color = default_tint,
    fill_color: Color = default_tint,
    tooltip: ?Tooltip = null,
    blocks_input: bool = true,
};

/// How far the clickable-tile highlight (and the editor Select tool's
/// icon of it) is inset from the tile edge: the square's side divided by
/// this. 16 = the retired `world/tile_highlight` marching-ants sheet's band
/// position (16 source px of a 256 tile) - the inset the prototype sheet
/// established, kept for the outline-class replacement.
pub const tile_highlight_inset_divisor: i32 = 16;

/// A sprite image (icon, decoration, etc.).
pub const Image = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    width: i32,
    height: i32,
    color: Color = default_tint,
    /// Tint alpha (0-255). Default fully opaque; overlays like the skill
    /// cooldown wash use 128 for 50% transparency.
    alpha: u8 = 255,
    /// Mirror horizontally (negative source width at the render seam, the
    /// world sprite path's flip trick). Used for off-hand weapon previews
    /// in editor cells - they must mirror like the scene does.
    flip_horizontal: bool = false,
    /// Renderer draws a programmatic edge highlight around the sprite's
    /// opaque pixels when set (e.g. the active turn-step indicator).
    highlighted: bool = false,
    tooltip: ?Tooltip = null,
    blocks_input: bool = true,
};

/// Any UI element that can appear in a panel.
pub const UiElement = union(enum) {
    nine_slice_panel: NineSlicePanel,
    slot: Slot,
    button: Button,
    text_label: TextLabel,
    fill_sprite: FillSprite,
    image: Image,
    solid_rect: SolidRect,
    slider: Slider,
    text_field: TextFieldUi,
};

/// An editable text field (the text-input widget's UI surface - see
/// DESIGN → UI Framework → Text input widget). The builder computes ALL
/// render data (it owns the metrics + the focused field's buffer): the
/// frame rect, the text to show (the field's current value, or the live
/// buffer while THIS field is focused), and the caret/selection geometry
/// - the backend just draws. `ref` is the field's identity for
/// focus-on-click + the commit path. blocks_input: clicks on the field
/// are field presses (caret positioning / focus), not world clicks.
pub const TextFieldUi = struct {
    /// The frame rect (hit-test bounds).
    screen_position: ScreenPosition,
    width: i32,
    height: i32,
    /// Where the text draws (top-left, the TextLabel convention: raylib
    /// draws from the top of a font_size-sized box).
    text_position: ScreenPosition,
    text: []const u8,
    font_size: i32,
    frame_color: Color,
    /// The text's color - also the caret + selection color (a field's
    /// accents match its text). default_tint renders as the theme
    /// lightest; the inspector sets pure black on the lightest frame.
    text_color: Color = default_tint,
    ref: types.TextFieldRef,
    /// Caret bar while focused: x offset from `text_position.x`, height.
    caret: ?struct { x: i32, height: i32 } = null,
    /// Selection highlight while a selection exists: x offset + width
    /// from `text_position.x` (drawn under the text).
    selection: ?struct { x: i32, width: i32 } = null,
    tooltip: ?Tooltip = null,
    blocks_input: bool = true,
};

/// A plain rectangle (filled by default, or stroked when `filled` is
/// false). Used for UI primitives like the error popup's scrollbar
/// track + thumb (filled) and the inventory salvage-region outline
/// (stroked - the outline class by construction: same `drawRectangleLinesEx`
/// primitive AND the same marching stripe treatment as the world
/// range/radius outlines). `blocks_input` defaults to false (decorative);
/// set true if used as a solid surface.
pub const SolidRect = struct {
    screen_position: ScreenPosition,
    width: i32,
    height: i32,
    color: Color = default_tint,
    /// When false, draw a stroked outline (`line_width` per side) instead of
    /// a filled rectangle.
    filled: bool = true,
    /// Stroke width in reference pixels when `filled` is false. Defaults to
    /// the shared outline thickness used by world range/radius outlines.
    line_width: i32 = 8,
    tooltip: ?Tooltip = null,
    blocks_input: bool = false,
};

// ============================================================
// Pointer hit-testing
// ============================================================

/// The screen rectangle an element occupies, derived from its own geometry
/// (single source of truth - no bounds stored alongside the element).
/// A `text_label` reports a `font_size`-square extent: no text label today
/// needs measured hit-bounds (they are all `blocks_input = false`, so the
/// button behind wins the hit-test), and none carries a tooltip. Wire
/// `measureSpanWidth` into this arm if a text label ever needs a real extent.
pub fn boundsOf(element: UiElement) Rectangle {
    return switch (element) {
        .nine_slice_panel => |e| .{ .x = e.screen_position.x, .y = e.screen_position.y, .width = e.width, .height = e.height },
        .slot => |e| .{ .x = e.screen_position.x, .y = e.screen_position.y, .width = e.size, .height = e.size },
        .button => |e| .{ .x = e.screen_position.x, .y = e.screen_position.y, .width = e.width, .height = e.height },
        .text_label => |e| .{ .x = e.screen_position.x, .y = e.screen_position.y, .width = e.font_size, .height = e.font_size },
        .fill_sprite => |e| .{ .x = e.screen_position.x, .y = e.screen_position.y, .width = e.width, .height = e.height },
        .image => |e| .{ .x = e.screen_position.x, .y = e.screen_position.y, .width = e.width, .height = e.height },
        .solid_rect => |e| .{ .x = e.screen_position.x, .y = e.screen_position.y, .width = e.width, .height = e.height },
        .slider => |e| .{ .x = e.screen_position.x, .y = e.screen_position.y, .width = e.width, .height = e.height },
        .text_field => |e| .{ .x = e.screen_position.x, .y = e.screen_position.y, .width = e.width, .height = e.height },
    };
}

/// The tooltip an element carries, if any. All variants share a `tooltip`
/// field, so one `inline else` reads them uniformly.
pub fn tooltipOf(element: UiElement) ?Tooltip {
    return switch (element) {
        inline else => |e| e.tooltip,
    };
}

/// Whether an element occludes the pointer - i.e. hit-testing stops here
/// instead of falling through to elements drawn behind it. Solid surfaces
/// (panels, buttons, slots) block; decorative overlays (cooldown numbers,
/// the drag ghost, the tooltip itself) opt out with `blocks_input = false`.
fn blocksInputOf(element: UiElement) bool {
    return switch (element) {
        inline else => |e| e.blocks_input,
    };
}

/// The one hit-testing primitive shared by every pointer query (tooltips,
/// clicks, drags, ...). Walks elements top-to-bottom (reverse of draw order).
/// Non-blocking elements are transparent and skipped; the walk halts at the
/// first blocking element. Returns the topmost element under `position` that
/// satisfies `matches`, provided it is reached before any blocker - so an
/// opaque element on top both captures its own input and shields whatever it
/// covers.
fn hitTest(
    ui_elements: []const UiElement,
    position: ScreenPosition,
    comptime matches: fn (UiElement) bool,
) ?usize {
    var index = ui_elements.len;
    while (index > 0) {
        index -= 1;
        const element = ui_elements[index];
        if (!boundsOf(element).contains(position)) continue;
        if (matches(element)) return index;
        if (blocksInputOf(element)) return null;
    }
    return null;
}

fn hasTooltip(element: UiElement) bool {
    return tooltipOf(element) != null;
}

fn isRefSlot(element: UiElement) bool {
    return switch (element) {
        .slot => |slot| slot.ref != null,
        else => false,
    };
}

fn isButton(element: UiElement) bool {
    return switch (element) {
        .button => true,
        else => false,
    };
}

fn isSlider(element: UiElement) bool {
    return switch (element) {
        .slider => true,
        else => false,
    };
}

/// The topmost tooltip-bearing element under `position` (respecting
/// occlusion), or null. Used by the hover pass in view().
pub fn tooltipAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?UiElement {
    return if (hitTest(ui_elements, position, hasTooltip)) |i| ui_elements[i] else null;
}

/// The topmost Button under `position` (respecting occlusion), or null. Used
/// to resolve a click into the button's Action.
pub fn buttonAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?Button {
    return if (hitTest(ui_elements, position, isButton)) |i| ui_elements[i].button else null;
}

/// The topmost text field under `position` (respecting occlusion), or
/// null. The press/release dispatch uses it for focus-on-click and
/// caret positioning (see DESIGN → UI Framework → Text input widget).
pub fn textFieldAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?TextFieldUi {
    return if (hitTest(ui_elements, position, isTextField)) |i| ui_elements[i].text_field else null;
}

fn isTextField(element: UiElement) bool {
    return switch (element) {
        .text_field => true,
        else => false,
    };
}

/// The index in `ui_elements` of the topmost button under `position`
/// (respecting occlusion), or null. Used by the view() hover pass to mark the
/// hovered button's `highlighted` flag in place (the ArrayList owns the
/// element; `buttonAt` returns a copy, which can't be written back).
pub fn buttonIndexAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?usize {
    return hitTest(ui_elements, position, isButton);
}

/// The topmost slider under `position` (respecting occlusion), or null.
/// Used by `handleSliderDrag` to begin a drag on left-press.
pub fn sliderAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?Slider {
    return if (hitTest(ui_elements, position, isSlider)) |i| ui_elements[i].slider else null;
}

/// Find the slider for `id` in `ui_elements` (first match, no occlusion
/// check - used during an active drag to find the slider matching the
/// `active_slider` setting id). Returns null if not found (e.g. the panel
/// was rebuilt and the slider isn't present this frame).
pub fn findSlider(
    ui_elements: []const UiElement,
    id: types.SettingId,
) ?Slider {
    for (ui_elements) |element| switch (element) {
        .slider => |slider| if (slider.setting_id == id) return slider,
        else => {},
    };
    return null;
}

/// The topmost input-blocking element under `position`, or null. Used for
/// world/UI click arbitration: if a blocking UI element is under the pointer,
/// the world should not also receive the click.
pub fn blockingElementAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?UiElement {
    return if (hitTest(ui_elements, position, blocksInputOf)) |i| ui_elements[i] else null;
}

/// The topmost ref-bearing slot under `position` (respecting occlusion),
/// or null. Used by drag.
fn slotAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?Slot {
    return if (hitTest(ui_elements, position, isRefSlot)) |i| ui_elements[i].slot else null;
}

/// The SlotRef of the topmost ref-bearing slot under `position`, or null.
fn slotRefAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?SlotRef {
    return if (slotAt(ui_elements, position)) |slot| slot.ref else null;
}

/// The SlotRef of the topmost ref-bearing element under `position`, or null.
/// Covers both `.slot` and `.button` elements (skill-bar slots are buttons
/// that also carry a ref - click = activate, drag = reorder/clear). Used by
/// the drag lifecycle for press + drop-target resolution. Respects occlusion
/// via the shared `hitTest` primitive.
pub fn refAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?SlotRef {
    return if (hitTest(ui_elements, position, isRefElement)) |i| refOf(ui_elements[i]) else null;
}

fn isRefElement(element: UiElement) bool {
    return refOf(element) != null;
}

fn refOf(element: UiElement) ?SlotRef {
    return switch (element) {
        .slot => |slot| slot.ref,
        .button => |button| button.ref,
        else => null,
    };
}

test "slotRefAt returns the topmost slot under the point" {
    const elements = [_]UiElement{
        // A non-slot element is ignored.
        .{ .image = .{ .sprite_id = "x", .screen_position = .{ .x = 0, .y = 0 }, .width = 100, .height = 100 } },
        // Bottom slot: inventory 3 at (0,0) size 100.
        .{ .slot = .{ .screen_position = .{ .x = 0, .y = 0 }, .size = 100, .ref = .{ .inventory = 3 } } },
        // Top slot overlapping it: gear boots at (50,50) size 100.
        .{ .slot = .{ .screen_position = .{ .x = 50, .y = 50 }, .size = 100, .ref = .{ .gear = .boots } } },
        // A slot with no ref is skipped.
        .{ .slot = .{ .screen_position = .{ .x = 200, .y = 200 }, .size = 100 } },
    };

    // Inside only the bottom slot.
    try std.testing.expectEqual(SlotRef{ .inventory = 3 }, slotRefAt(&elements, .{ .x = 10, .y = 10 }).?);
    // Overlap region resolves to the topmost (gear).
    try std.testing.expectEqual(SlotRef{ .gear = .boots }, slotRefAt(&elements, .{ .x = 60, .y = 60 }).?);
    // Over the ref-less slot: no hit.
    try std.testing.expectEqual(@as(?SlotRef, null), slotRefAt(&elements, .{ .x = 250, .y = 250 }));
    // Right edge is exclusive.
    try std.testing.expectEqual(@as(?SlotRef, null), slotRefAt(&elements, .{ .x = 150, .y = 60 }));
    // Empty space.
    try std.testing.expectEqual(@as(?SlotRef, null), slotRefAt(&elements, .{ .x = 500, .y = 500 }));
}

test "tooltipAt: overlays pass through, blockers shield what is behind" {
    const tip = Tooltip{ .header = &.{text("hi")} };
    const elements = [_]UiElement{
        // Bottom: a button with a tooltip.
        .{ .button = .{ .sprite_id = "b", .screen_position = .{ .x = 0, .y = 0 }, .action = .skip, .tooltip = tip } },
        // A non-blocking overlay on top (e.g. cooldown number) - pass through.
        .{ .text_label = .{ .text = "3", .screen_position = .{ .x = 0, .y = 0 }, .font_size = 100, .blocks_input = false } },
    };
    // The overlay is transparent, so the button's tooltip is found beneath it.
    try std.testing.expect(tooltipAt(&elements, .{ .x = 10, .y = 10 }) != null);

    // Now cover the button with a blocking, tooltip-less panel (e.g. an open
    // full-screen overlay): hovering it must not reveal the button's tooltip.
    const blocked = [_]UiElement{
        .{ .button = .{ .sprite_id = "b", .screen_position = .{ .x = 0, .y = 0 }, .action = .skip, .tooltip = tip } },
        .{ .nine_slice_panel = .{ .sprite_id = "p", .screen_position = .{ .x = 0, .y = 0 }, .width = slot_size, .height = slot_size } },
    };
    try std.testing.expect(tooltipAt(&blocked, .{ .x = 10, .y = 10 }) == null);
}

// ============================================================

// Builders append UiElements into a shared list in back-to-front draw
// order. The view function calls each relevant builder based on game
// state; the flat list is what the renderer walks. pub: main.zig's
// focus-on-click integration test builds elements directly.
pub const UiElementList = std.ArrayList(UiElement);

/// Wrap one logical row into visual lines that each fit `content_width`.
/// Text is split on spaces and '/' (the width-based break opportunities);
/// each word keeps its span's style, so styling survives wrapping. Spaces
/// at a wrap point (and at the start of a line) are dropped; a single word
/// wider than `content_width` is character-wrapped into fitting chunks.
/// A '\n' in the text is a HARD line break: the current line is flushed
/// (dropping the pending space) and the character itself is dropped - no
/// emitted span may contain a raw newline, because raylib's DrawTextEx
/// ALSO breaks on '\n' but with its own line advance + x reset, which the
/// layout never reserved space for (the measurement/rendering disagreement
/// that made overlapping lines in the error popup - the startup warnings
/// are joined with '\n'). Consecutive breaks collapse (no blank lines -
/// the warning-list shape wants one entry per line, no gap noise, and a
/// trailing break must not add a trailing blank row). '\r' is treated the
/// same way (tolerating Windows-style line endings).
pub fn wrapRow(
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    row: TooltipRow,
    font_size: i32,
    content_width: i32,
) ![]const TooltipRow {
    var lines: std.ArrayList(TooltipRow) = .empty;
    var current: std.ArrayList(Span) = .empty;
    var current_width: i32 = 0;
    var pending_space: ?Span = null;

    for (row) |span| {
        var index: usize = 0;
        while (index < span.text.len) {
            const ch = span.text[index];
            if (ch == '\n' or ch == '\r') {
                // Hard line break - flush the current line, drop the pending
                // space + the break character itself (see the fn doc).
                index += 1;
                pending_space = null;
                if (current.items.len > 0) {
                    try lines.append(allocator, try current.toOwnedSlice(allocator));
                    current = .empty;
                    current_width = 0;
                }
                continue;
            }
            const is_space = ch == ' ';
            const is_slash = ch == '/';
            const start = index;
            if (is_space) {
                // Run of spaces.
                while (index < span.text.len and span.text[index] == ' ') index += 1;
            } else if (is_slash) {
                // A '/' is a break opportunity. Keep it with the preceding
                // text as one token (so "data/campaigns/" is one piece), then
                // the next segment starts after the '/'. This keeps paths
                // readable while allowing them to wrap at separators.
                index += 1; // include the '/'
            } else {
                // Run of non-space, non-slash, non-newline characters -
                // a newline must END the token so the hard-break check at
                // the loop top sees it (otherwise it rides inside the word).
                while (index < span.text.len and span.text[index] != ' ' and
                    span.text[index] != '/' and
                    span.text[index] != '\n' and span.text[index] != '\r') index += 1;
            }
            const piece = Span{
                .text = span.text[start..index],
                .color = span.color,
                .bold = span.bold,
                .italic = span.italic,
            };
            if (is_space) {
                pending_space = piece;
                continue;
            }
            const word_width = font_metrics.measureSpanWidth(piece, font_size);
            const space_width = if (pending_space) |s| font_metrics.measureSpanWidth(s, font_size) else 0;
            // If the word itself is wider than the content width, character-
            // wrap it: emit chunks that fit, each on its own line. This is
            // the fallback for any token (path segment, long key, etc.) that
            // still overflows after splitting on spaces and '/'.
            if (word_width > content_width) {
                // First, flush any pending line content before the long word.
                if (current.items.len > 0) {
                    // Drop the pending space (the break before the long word
                    // consumes it) and flush.
                    pending_space = null;
                    try lines.append(allocator, try current.toOwnedSlice(allocator));
                    current = .empty;
                    current_width = 0;
                }
                // Split the long piece into char-chunks that each fit.
                const char_width = font_metrics.measureSpanWidth(.{ .text = "x", .color = piece.color, .bold = piece.bold }, font_size);
                if (char_width == 0) {
                    // Degenerate (zero-width font); emit the whole piece to
                    // avoid an infinite loop.
                    try current.append(allocator, piece);
                    current_width = word_width;
                } else {
                    const max_chars = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(content_width, char_width))));
                    var ci: usize = 0;
                    while (ci < piece.text.len) {
                        const chunk_len = @min(max_chars, piece.text.len - ci);
                        try lines.append(allocator, try allocator.dupe(Span, &.{.{
                            .text = piece.text[ci .. ci + chunk_len],
                            .color = piece.color,
                            .bold = piece.bold,
                            .italic = piece.italic,
                        }}));
                        ci += chunk_len;
                    }
                    // The long word is fully emitted; reset line state.
                    current = .empty;
                    current_width = 0;
                    pending_space = null;
                }
                continue;
            }
            if (current.items.len > 0 and current_width + space_width + word_width > content_width) {
                // Break before this word: flush the line, drop the pending space.
                try lines.append(allocator, try current.toOwnedSlice(allocator));
                current = .empty;
                current_width = 0;
                pending_space = null;
                try current.append(allocator, piece);
                current_width = word_width;
            } else {
                // Keep any pending space only mid-line (drop leading spaces).
                if (pending_space) |s| {
                    if (current.items.len > 0) {
                        try current.append(allocator, s);
                        current_width += space_width;
                    }
                    pending_space = null;
                }
                try current.append(allocator, piece);
                current_width += word_width;
            }
        }
    }
    if (current.items.len > 0) try lines.append(allocator, try current.toOwnedSlice(allocator));
    return lines.toOwnedSlice(allocator);
}

/// One wrapped row ready to size and draw: its font size, its visual lines,
/// and whether it is the header (which gets extra spacing below).
pub const WrappedRow = struct {
    font_size: i32,
    lines: []const TooltipRow,
    is_header: bool,
};

test "wrapRow breaks at spaces and drops the break space" {
    const font_size: i32 = 100; // 1 char = 55px (50 advance + 5 spacing)
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const row: TooltipRow = &.{text("aa bb cc")};

    // content_width 310 fits "aa bb" (110+55+110=275) but not a third word.
    const lines = try wrapRow(std.testing.allocator, metrics, row, font_size, 310);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    // First visual line keeps the interior space span: ["aa", " ", "bb"].
    try std.testing.expectEqual(@as(usize, 3), lines[0].len);
    try std.testing.expectEqualStrings("aa", lines[0][0].text);
    try std.testing.expectEqualStrings(" ", lines[0][1].text);
    try std.testing.expectEqualStrings("bb", lines[0][2].text);
    // Second line starts at "cc" with no leading space.
    try std.testing.expectEqualStrings("cc", lines[1][0].text);
}

test "wrapRow: newline is a hard line break, the character dropped" {
    // raylib's DrawTextEx ALSO breaks on '\n' (its own line advance + x
    // reset) - so a span containing one renders more lines than the layout
    // measured, overlapping the next visual row (the error-popup bug: the
    // startup warnings are joined with '\n'). wrapRow must treat '\n' as a
    // hard break and never emit it inside a span; '\r' (Windows line
    // endings) is handled the same way.
    const font_size: i32 = 100; // 1 char = 55px (50 advance + 5 spacing)
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const row: TooltipRow = &.{text("aa bb\ncc dd\r\n\nee")};

    // content_width wide enough that no WIDTH-based break ever fires -
    // every line break below comes from the newline handling.
    const lines = try wrapRow(std.testing.allocator, metrics, row, font_size, 10_000);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    // Each hard-broken line keeps its interior space span, starts with no
    // leading/trailing space, and contains no newline character. The \r\n +
    // \n run collapses - consecutive breaks emit no blank lines (the
    // warning-list shape: one warning per line, no gap noise).
    const expected = [_][]const u8{ "aa bb", "cc dd", "ee" };
    for (lines, expected) |line, want| {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(std.testing.allocator);
        for (line) |span| try joined.appendSlice(std.testing.allocator, span.text);
        try std.testing.expectEqualStrings(want, joined.items);
        for (line) |span| {
            try std.testing.expect(std.mem.indexOfScalar(u8, span.text, '\n') == null);
            try std.testing.expect(std.mem.indexOfScalar(u8, span.text, '\r') == null);
        }
    }
}

test "wrapRow breaks on '/' for paths" {
    // font_size 100 → 1 char = 55px (50 advance + 5 spacing). content_width
    // 380 fits "aa/bb/" (6 glyphs = 330) but not a third segment, so it
    // wraps at a '/' and the first line keeps the trailing slash.
    const font_size: i32 = 100;
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const row: TooltipRow = &.{text("aa/bb/cc")};

    const lines = try wrapRow(std.testing.allocator, metrics, row, font_size, 380);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }
    // "aa/bb/" (6 chars = 300px) fits, then "cc" on the next line.
    // The '/' stays with the preceding segment.
    try std.testing.expect(lines.len >= 2);
    // First line starts with "aa/bb/" (includes the trailing slash).
    var first_line_text: []const u8 = "";
    for (lines[0]) |span| first_line_text = span.text;
    try std.testing.expect(std.mem.endsWith(u8, first_line_text, "/"));
}

test "wrapRow character-wraps a token wider than the content width" {
    // font_size 100 → 1 char = 55px. content_width 240 fits 4 chars.
    // "abcdefgh" is 8 chars = 440px > 240, no spaces or slashes → char-wrap.
    const font_size: i32 = 100;
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const row: TooltipRow = &.{text("abcdefgh")};

    const lines = try wrapRow(std.testing.allocator, metrics, row, font_size, 240);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }
    // 8 chars / 4 per line = 2 lines.
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    // Each line has 4 chars.
    var first_line_text: []const u8 = "";
    for (lines[0]) |span| first_line_text = span.text;
    try std.testing.expectEqualStrings("abcd", first_line_text);
    var second_line_text: []const u8 = "";
    for (lines[1]) |span| second_line_text = span.text;
    try std.testing.expectEqualStrings("efgh", second_line_text);
}

test "wrapRow: normal space wrapping still works" {
    // Regression: the existing space-based wrapping behavior is unchanged.
    const font_size: i32 = 100;
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const row: TooltipRow = &.{text("aa bb cc")};

    const lines = try wrapRow(std.testing.allocator, metrics, row, font_size, 310);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqual(@as(usize, 3), lines[0].len);
    try std.testing.expectEqualStrings("aa", lines[0][0].text);
    try std.testing.expectEqualStrings(" ", lines[0][1].text);
    try std.testing.expectEqualStrings("bb", lines[0][2].text);
    try std.testing.expectEqualStrings("cc", lines[1][0].text);
}

// ============================================================
// Tooltip placement (placeTooltip) - pure geometry over (source, screen, size)
// ============================================================
