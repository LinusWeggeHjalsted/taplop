//! UI framework: the flat `UiElement` tagged union (nine_slice_panel, slot,
//! button, text_label, fill_sprite, image, solid_rect), layout helpers (Rect
//! algebra, `Row`/`Grid`, screen-space `i32` dims), and the panel/overlay
//! builders (top bar, bottom bar, main menu, tooltips, skill tooltips, gear,
//! inventory, skills, entity inspect, mission complete/fail, options, load-save
//! browser). `UiState` (open panels/overlays/drag/scroll) lives on
//! `SessionState`, off the undo timeline. Buttons carry an `Action` so clicks
//! feed the one input path. See DESIGN → UI Framework.

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const lookups = @import("generated_lookups.zig");
const utility_skills = @import("utility_skills.zig");
const sprite_metadata = @import("generated_sprite_metadata");
const Skill = @import("skills/skill.zig").Skill;
const Effect = @import("effects/effect.zig").Effect;

const Action = types.Action;
const ScreenPosition = types.ScreenPosition;
const Rectangle = types.Rectangle;
const Color = types.Color;
const Entity = types.Entity;
const SkillId = types.SkillId;
const GearSlot = types.GearSlot;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const GameState = state.GameState;

const weapon_type_count = @typeInfo(types.WeaponType).@"enum".fields.len;

// ============================================================
// UI state — lives on GameState, tracks what's open
// ============================================================

pub const MiddlePanelId = enum {
    inventory,
    gear,
    skills,
    entity_inspect,
};

pub const FullScreenOverlayId = enum {
    world_map,
    full_combat_log,
};

pub const max_middle_panels = 4;
pub const max_full_screen_overlays = 2;

/// Which field the editor's centered picker is assigning (see
/// DESIGN → Architecture → Level Editor → Editor UI layout — the
/// centered sprite picker section; the skill picker is the first
/// consumer).
pub const EditorPickerTarget = union(enum) {
    utility_skill_slot: u32,
    /// The edited entity type's base sprite (the inspector's Sprite row).
    entity_sprite: void,
    /// The edited decoration type's base sprite (the decoration
    /// inspector's Sprite row — official tab adopts a registry prefab,
    /// mission tab picks a custom stem).
    decoration_sprite: void,
    /// An ENTITY layer sprite (the enemy content's Layers section): the
    /// layer index being edited, null = add-new (the skill picker's slot
    /// pattern).
    entity_layer: ?u32,
    /// A DECORATION layer sprite — same shape; the official tab filters
    /// to the base type's dims (the load-time layer invariant).
    decoration_layer: ?u32,
    /// The decoration type's FOOTPRINT editor (the Footprint row): the
    /// full-size sprite with toggleable 256×256 grid cells; the draft
    /// rides `UiState.editor_footprint_draft`. Carries the TYPE ID it was
    /// opened on — the editor stays self-contained while tools switch
    /// mid-edit (the dropdown convention), and toggles/confirm can never
    /// silently apply to a different type.
    decoration_footprint: u32,
};

/// The footprint editor's draft-grid capacity: 8×8 sprite-grid tiles
/// (2048px sprites). Shipped decoration art is 3×3 at most; a custom
/// sprite beyond the limit doesn't open the editor (custom dims
/// verification is a TODO). Public: the input layer's open gate reads it.
pub const editor_footprint_grid_cell_limit: usize = 64;

/// The OFFICIAL enemy sprites (shipped `assets/entities/*.png`) as bare
/// stems — the sprite picker's Official tab. The player body is EXCLUDED
/// (the player sprite isn't an enemy base-sprite option). Comptime from
/// the sprite-metadata table; sorted for a stable picker order.
const official_entity_sprite_stems: []const []const u8 = build: {
    var stems: []const []const u8 = &.{};
    for (sprite_metadata.map.kvs.keys[0..sprite_metadata.map.kvs.len]) |key| {
        if (!std.mem.startsWith(u8, key, "entities/")) continue;
        if (std.mem.eql(u8, key, "entities/player")) continue;
        const stem = key["entities/".len..];
        // Insert in sorted position (comptime slices have const elements —
        // no in-place sort).
        var insert_index: usize = 0;
        while (insert_index < stems.len and std.mem.lessThan(u8, stems[insert_index], stem)) : (insert_index += 1) {}
        stems = stems[0..insert_index] ++ [_][]const u8{stem} ++ stems[insert_index..];
    }
    break :build stems;
};

/// One shipped decoration sprite (stem + pixel dims) for the picker's
/// layer-mode Official tab.
const OfficialDecorationSprite = struct {
    stem: []const u8,
    width: i32,
    height: i32,
};

/// The OFFICIAL decoration sprites (shipped `assets/decorations/*.png`) as
/// stems + pixel dims — the sprite picker's LAYER-mode Official tab (the
/// base-sprite mode lists the registry prefabs instead). Comptime from
/// the sprite-metadata table; a malformed dims string is a build bug.
const official_decoration_sprites: []const OfficialDecorationSprite = build: {
    @setEvalBranchQuota(20000);
    var list: []const OfficialDecorationSprite = &.{};
    for (sprite_metadata.map.kvs.keys[0..sprite_metadata.map.kvs.len]) |key| {
        if (!std.mem.startsWith(u8, key, "decorations/")) continue;
        const stem = key["decorations/".len..];
        const dims = sprite_metadata.map.get(key).?;
        const space = std.mem.indexOfScalar(u8, dims, ' ').?;
        const width = std.fmt.parseInt(i32, dims[0..space], 10) catch
            @compileError("malformed sprite dims string");
        const height = std.fmt.parseInt(i32, dims[space + 1 ..], 10) catch
            @compileError("malformed sprite dims string");
        var insert_index: usize = 0;
        while (insert_index < list.len and std.mem.lessThan(u8, list[insert_index].stem, stem)) : (insert_index += 1) {}
        list = list[0..insert_index] ++
            [_]OfficialDecorationSprite{.{ .stem = stem, .width = width, .height = height }} ++
            list[insert_index..];
    }
    break :build list;
};

const editor_inspector_section_count: usize =
    @typeInfo(types.EditorInspectorSectionId).@"enum".fields.len;

pub const UiState = struct {
    /// Middle section panels, ordered by open time (first opened = leftmost).
    open_middle_panels: [max_middle_panels]?MiddlePanelId = .{null} ** max_middle_panels,

    /// Full-screen overlays that can stack (world map, full combat log).
    open_full_screen_overlays: [max_full_screen_overlays]?FullScreenOverlayId = .{null} ** max_full_screen_overlays,

    /// Options menu is separate — always on top, locks input.
    options_menu_open: bool = false,

    /// Load-save browser (main menu, full screen). Like the options menu
    /// it's a modal overlay; the panel itself blocks input to the main-menu
    /// buttons behind it. Auto-cleared by the screen-transition UI reset
    /// when a load succeeds (screen leaves main_menu).
    load_save_menu_open: bool = false,

    /// Credits screen (main menu, full screen). Modal overlay like the
    /// load-save browser; the panel blocks input to the main-menu buttons
    /// behind it. Toggled by the `.open_credits` action (the Credits button
    /// opens, the Back button closes — same action, toggle semantics).
    /// Auto-cleared by the screen-transition UI reset.
    credits_open: bool = false,

    /// Settings screen (full screen). Modal overlay; opens ON TOP OF the
    /// options menu (in-game, via the options-menu "Settings" button) or
    /// directly over the main menu (via the main-menu "Settings" button).
    /// Back button closes it. The options menu stays open underneath when
    /// opened in-game, so its top-of-`update()` gate keeps the world paused
    /// — no separate gating for this overlay. Toggled by `Action.open_settings`.
    /// Auto-cleared by the screen-transition UI reset. See DESIGN → UI
    /// Framework → Settings screen.
    settings_open: bool = false,

    /// Which slider is being dragged (left-press on a slider → held →
    /// release). Null when no slider drag is in progress. Off the undo
    /// timeline (UI interaction state, like `drag`). Cleared by the
    /// screen-transition UI reset.
    active_slider: ?types.SettingId = null,

    /// The focused text-input field, if any (see DESIGN → UI Framework →
    /// Text input widget). While set, `translateInput` suppresses ALL
    /// binding translation and routes keys/chars into the field's buffer;
    /// Enter/OK commit (the field-kind switch lives in input_handlers),
    /// Escape discards, and a left press outside the field commits + is
    /// arbitrated per the M2 rule. Off the undo timeline — the COMMIT is
    /// the event; the buffer never needs replay. Cleared by the
    /// screen-transition UI reset.
    text_edit: ?TextEditState = null,

    /// Load-save browser vertical scroll offset, in ROWS (not pixels) — one
    /// scroll tick = one full row pitch, so text placement is identical at
    /// every scroll position. Clamped to `[0, max_scroll_row]` in
    /// `buildLoadSavePanel` (the view is the only place that knows the max,
    /// which depends on the save count). Off the undo timeline like the
    /// other scrolls.
    load_save_scroll_offset: i32 = 0,

    /// Which entity is being inspected (for entity inspect panel).
    inspected_entity_index: ?u32 = null,

    /// Middle section horizontal scroll offset (for when panels exceed width).
    middle_section_scroll_offset: i32 = 0,

    /// Skills browser vertical scroll offset, in grid ROWS (not pixels).
    /// Clamped to `[0, max_scroll_row]` in `buildSkillsPanel` (the view is
    /// the only place that knows `max_scroll_row`, which depends on the
    /// learned-skill count). Off the undo timeline like the other scrolls.
    skills_scroll_offset: i32 = 0,

    /// Editor palette group scroll offsets, in TOOL CELLS — one wheel notch
    /// = one cell. Index 0 = Enemies, 1 = Decorations, 2 = Ground Items.
    /// A group shows at most `editor_palette_max_tools` type cells; scrolling
    /// shifts the visible window left/right. Clamped in place by
    /// `buildEditorBottomBar` (authoritative — it knows the group size) and
    /// on write in the wheel handler. View-side transient state, off the
    /// undo timeline (same as `skills_scroll_offset`).
    editor_palette_scroll: [3]i32 = .{ 0, 0, 0 },

    /// Editor inspector content scroll offset, in ROW UNITS (the 128px
    /// pitch — a section header is one unit, a field entry two) — one wheel
    /// notch = one unit (the whole-row convention keeps every line on the
    /// grid at any offset). Clamped in place by the inspector content
    /// builder (authoritative — it knows the content height) and on write
    /// in the wheel handler. Off the undo timeline like the other scrolls.
    editor_inspector_scroll: i32 = 0,

    /// The editor's centered picker, if open — which field is being
    /// picked (first consumer: the utility-skill picker; the sprite picker
    /// joins later). A MODAL overlay: while set, the input layer runs only
    /// the picker's own actions (see handleAnytimeInput). Off the undo
    /// timeline — picking is what records, opening is an affordance.
    editor_picker: ?EditorPickerTarget = null,

    /// The footprint editor's DRAFT grid (the `.decoration_footprint`
    /// picker): one bool per sprite-grid tile, row-major. Seeded from the
    /// type's current footprint at open, flipped per tile-cell click,
    /// committed (or discarded) by Confirm/Close. A FIXED-size grid —
    /// sprites larger than the cell limit don't open the editor (custom
    /// dims verification is a TODO). Off the undo timeline — the confirm
    /// is the event; the draft is transient view state like a text
    /// buffer.
    editor_footprint_draft: [editor_footprint_grid_cell_limit]bool =
        .{false} ** editor_footprint_grid_cell_limit,

    /// Editor palette group collapse state: false = expanded, true =
    /// collapsed (header + "+" only, no type cells). Collapsed by DEFAULT
    /// (all groups) — the bar starts minimal. Toggled by clicking the group
    /// header button (accordion: expanding one collapses the others). Off
    /// the undo timeline (view-side display state, like
    /// `editor_palette_scroll`).
    editor_palette_collapsed: [3]bool = .{ true, true, true },

    /// Editor inspector section expansion: true = expanded (children
    /// emitted), false = collapsed (header only). ALL COLLAPSED by default —
    /// the panel starts minimal. Independent toggles (no accordion — the
    /// palette groups are one-at-a-time; inspector sections are per-topic
    /// and often wanted together, e.g. Weapons + Gear). Off the undo
    /// timeline (view-side display state, same class as
    /// `editor_palette_collapsed`). Keyed by `EditorInspectorSectionId` —
    /// shared across the enemy + player contents.
    editor_inspector_section_expanded: [editor_inspector_section_count]bool =
        .{false} ** editor_inspector_section_count,

    /// Which tab the sprite picker is showing (Mission / Official). View
    /// affordance — a direct UiState write, off the undo timeline. Reset
    /// to `.mission_local` on every open (custom assets take priority over
    /// shipped ones).
    editor_picker_sprite_tab: types.EditorSpritePickerTab = .mission_local,

    /// Combat log scroll offset (for full combat log view).
    combat_log_scroll_offset: i32 = 0,

    /// In-progress pointer drag of an inventory item / gear piece / skill.
    drag: ?DragState = null,

    /// A pointer press on a content slot awaiting promotion-to-drag or
    /// click-on-release (movement-threshold lifecycle). One per pointer at
    /// a time.
    pending_slot_press: ?PendingSlotPress = null,

    /// A right-press on a world entity tile awaiting click-vs-drag
    /// disambiguation (levels only). Cancels if the pointer moves beyond
    /// the drag threshold (became a camera pan); on a clean release toggles
    /// the entity inspect panel on `inspected_entity_index`. See
    /// `handleRightClickInspect` in input_handlers.
    pending_right_click: ?PendingRightClick = null,

    /// Most recent plain single click on a content inventory slot, for
    /// double-click detection. Cleared on modifier-clicks and on a fired
    /// double. See `LastItemClick`.
    last_item_click: ?LastItemClick = null,

    /// In-progress shift-drag region selection in the inventory panel.
    /// `start_slot` / `end_slot` are inventory indices for opposite corners
    /// (order-independent); `end_slot` updates live as the pointer moves and
    /// tracks the last slot the pointer was over (so a release off-grid still
    /// salves the last valid region). Set only while a shift+left-drag is in
    /// progress; cleared on release. The region is rendered as a lightest
    /// outline around the bounding box. See DESIGN → Input.
    salvage_region: ?SalvageRegion = null,

    /// In-progress shift-drag region selection in the editor viewport (the
    /// select tool's marquee). Set on a shift+left press over the viewport
    /// (select tool active); `end_position` updates live once the drag
    /// threshold promotes the press; cleared on release (fires the region
    /// add via `player_select_editor_region` if Shift is still held — an
    /// unpromoted release acts as a plain click instead) or cancel. The
    /// rectangle renders as a lightest region outline once promoted. See
    /// DESIGN → Architecture → Level Editor → Selection model.
    editor_marquee: ?EditorMarquee = null,

    /// In-progress selection MOVE drag (see `EditorMoveDrag`). Mutually
    /// exclusive with `editor_marquee` by construction: a Shift press
    /// claims the marquee, a plain press on a selected thing claims the
    /// move — each gesture's press clears the other's stale state.
    editor_move_drag: ?EditorMoveDrag = null,

    pub fn toggleMiddlePanel(self: *UiState, panel_id: MiddlePanelId) void {
        // If already open, close it
        for (&self.open_middle_panels) |*slot| {
            if (slot.*) |open| {
                if (open == panel_id) {
                    slot.* = null;
                    return;
                }
            }
        }
        // Not open — find first empty slot
        for (&self.open_middle_panels) |*slot| {
            if (slot.* == null) {
                slot.* = panel_id;
                return;
            }
        }
    }

    /// Whether `panel_id` is currently open. The read-side companion of
    /// `toggleMiddlePanel` (view-side producers, e.g. the inspected-entity
    /// aggro outline, need to know a panel is showing without walking the
    /// slot array themselves).
    pub fn isMiddlePanelOpen(self: *const UiState, panel_id: MiddlePanelId) bool {
        for (self.open_middle_panels) |maybe_panel| {
            if (maybe_panel) |open| {
                if (open == panel_id) return true;
            }
        }
        return false;
    }

    pub fn toggleFullScreenOverlay(self: *UiState, overlay_id: FullScreenOverlayId) void {
        for (&self.open_full_screen_overlays) |*slot| {
            if (slot.*) |open| {
                if (open == overlay_id) {
                    slot.* = null;
                    return;
                }
            }
        }
        for (&self.open_full_screen_overlays) |*slot| {
            if (slot.* == null) {
                slot.* = overlay_id;
                return;
            }
        }
    }
};

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
    save_file: u32, // a row in the load-save browser (index into SessionState.save_files)

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
            .save_file => |ai| switch (b) {
                .save_file => |bi| ai == bi,
                else => false,
            },
        };
    }
};

/// An in-progress drag. Lives on UiState so it is auto-cancelled on screen
/// transition (the live loop resets SessionState.ui_state there). The ghost
/// follows the pointer using InputState.mouse_screen_position — no pointer
/// position is stored here.
pub const DragState = struct {
    source: SlotRef,
    icon_sprite_id: []const u8,
    /// Render size of the ghost, by domain (see `slotContentSize`). Captured
    /// at press time so the view needs no state lookup to draw the ghost.
    size: i32,
};

/// Which mouse button a slot press used. Right-click is a distinct intent
/// (equip-to-off-hand / alt-swapped equip) and never starts a drag (drags
/// are left-button only; right-drag is camera pan on the world).
pub const ClickButton = enum { left, right };

/// A pointer press on a content slot that has not yet been promoted to a
/// drag (movement below `drag_threshold_pixels`) or resolved as a click
/// (release). The movement-threshold drag lifecycle: press records a
/// pending press; move beyond threshold promotes it to `DragState`; release
/// within threshold over the same slot is a click. Lives on UiState so it
/// survives across frames until release and is cleared on screen transition.
pub const PendingSlotPress = struct {
    source: SlotRef,
    icon_sprite_id: []const u8,
    press_position: ScreenPosition,
    button: ClickButton,
    /// Whether Shift was held at press time. A shift+left press on an
    /// inventory slot promotes to a salvage-region selection (not an item
    /// drag) once the pointer crosses the drag threshold. See handleDrag.
    shift_held: bool = false,
};

/// A right-press on the world awaiting click-vs-drag disambiguation
/// (movement-threshold lifecycle): if the pointer stays within
/// `drag_threshold_pixels` until release, the press was a CLICK and the
/// kind's action fires; if it moves beyond the threshold first, this is
/// cancelled — the press became a camera pan. One gesture state, two
/// owners by kind: `inspect` (levels — right-click an entity to toggle
/// the inspect panel, `handleRightClickInspect`) and `editor_delete`
/// (editor screen — the tool-independent delete,
/// `handleRightClickEditorDelete`). Each handler only touches its own
/// kind (the other screen's pending survives its handler's clear).
pub const PendingRightClick = union(enum) {
    /// The pressed entity (levels).
    inspect: struct {
        entity_index: u32,
        press_position: ScreenPosition,
    },
    /// The pressed world tile (editor). Recorded at PRESS — a clean
    /// click acts on what was under the pointer when the button went
    /// down, not where sub-threshold drift left it at release.
    editor_delete: struct {
        position: types.Vector2,
        press_position: ScreenPosition,
    },
};

/// The most recent plain (no-modifier) single click on a content inventory
/// slot, for double-click detection. Only plain single clicks that did NOT
/// fire an intent seed a pending double (modifier-clicks fire immediately
/// and clear this). Lives on UiState (off the undo timeline → replay-safe).
pub const LastItemClick = struct {
    slot_index: u32,
    button: ClickButton,
    time: u64,
};

/// In-progress shift-drag region selection in the inventory panel. The two
/// slot indices are opposite corners (order-independent); `end_slot` is
/// updated live as the pointer moves (tracking the last valid slot the
/// pointer was over). See `UiState.salvage_region`.
pub const SalvageRegion = struct {
    start_slot: u32,
    end_slot: u32,
};

/// In-progress shift-drag region selection in the editor viewport. The two
/// tile positions are opposite corners (order-independent); `end_position`
/// updates live as the pointer moves (tracking the last valid tile — a
/// release over blocking UI still fires the last valid region).
/// `press_position` (screen px) drives the drag-threshold promotion;
/// `promoted` gates the rectangle rendering (an unpromoted release is a
/// plain click, not a region). See `UiState.editor_marquee`.
pub const EditorMarquee = struct {
    start_position: types.Vector2,
    end_position: types.Vector2,
    press_position: ScreenPosition,
    promoted: bool,
};

/// In-progress selection MOVE drag (select tool, plain left press on a
/// selected thing). `press_position_tile` anchors the delta;
/// `current_position_tile` tracks the pointer live once the drag
/// threshold promotes the press (keeping the last valid tile over
/// blocking UI); the promoted delta drives the view's translated
/// selection outlines. Cleared on release (fires
/// `player_move_editor_selection` when the delta is nonzero — an
/// unpromoted release acts as a plain click instead) or cancel. See
/// `UiState.editor_move_drag`.
pub const EditorMoveDrag = struct {
    press_position_tile: types.Vector2,
    current_position_tile: types.Vector2,
    press_position: ScreenPosition,
    promoted: bool,
};

// ============================================================
// Tooltip content model
// ============================================================
// A tooltip is a stack of rows plus an optional header row. A row is a
// sequence of inline-styled spans; wrapping happens per row and preserves
// each span's styling. Stat lines like "Range 3" are just ordinary rows
// (value is text after a space) — no special alignment or wrapping rules.
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
/// One source of truth — keep the two in sync.
pub const glyph_spacing_font_divisor: i32 = 20;

/// Per-glyph advance widths for the loaded font, in source pixels at
/// `base_size`. Indexed by ASCII codepoint (32..126); a codepoint outside
/// that range falls back to a rough 0.5em advance. The backend fills this
/// from the loaded `rl.Font` (`RaylibBackend.fontMetrics`); layout code
/// receives it via `RenderContext.font_metrics` so `view()` and its builders
/// measure text with the same advances the renderer draws with.
pub const FontMetrics = struct {
    /// The font size the `advances` were rasterized at (raylib `Font.baseSize`).
    base_size: i32,
    /// Advance width at `base_size` for ASCII codepoint `(index + 32)`.
    advances: [95]i32,

    /// Advance width of a span at `font_size`, in reference pixels. Mirrors
    /// raylib's `DrawTextEx` cursor advance per glyph — `advanceX *
    /// (font_size / base_size) + spacing` — so the measure matches where the
    /// renderer's cursor actually lands (and multi-span emit flows like one
    /// continuous string). Float-accumulated per glyph, truncated to i32 at
    /// the end. UTF-8-aware: ASCII bytes index `advances`; a multibyte
    /// sequence skips its full byte length (clamped to the slice end) and
    /// uses the 0.5em fallback + spacing.
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
                // Multibyte lead byte: skip the whole sequence (clamped to
                // the slice end so a truncated tail can't overrun) and use the
                // non-ASCII fallback. The decoded value is > 126 regardless, so
                // it never indexes `advances` — no need to decode it.
                const len: usize = switch (byte & 0xF0) {
                    0xC0, 0xD0 => 2,
                    0xE0 => 3,
                    0xF0 => 4,
                    else => 1, // invalid lead byte — skip one, stay in bounds
                };
                i += @min(len, span.text.len - i);
                total += @as(f32, @floatFromInt(font_size)) * 0.5 + spacing;
            }
        }
        return @intFromFloat(total);
    }

    /// Per-glyph advance for one ASCII byte at `font_size`. Matches raylib's
    /// `DrawTextEx`: `advanceX * scaleFactor + spacing` when the glyph has a
    /// nonzero advance, else a 0.5em fallback (raylib falls back to
    /// `recs.width`; we approximate with 0.5em — close enough for the rare
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
        // Control character or DEL — 0.5em fallback.
        return @as(f32, @floatFromInt(font_size)) * 0.5 + spacing;
    }

    /// Total width of a row's spans laid out on one line, in reference pixels.
    pub fn measureRowWidth(self: FontMetrics, row: TooltipRow, font_size: i32) i32 {
        var total: i32 = 0;
        for (row) |span| total += self.measureSpanWidth(span, font_size);
        return total;
    }
};

/// Text-buffer capacity for one editable field. Level-format strings
/// (names, sprite ids) are short; 128 covers them with headroom.
const text_field_capacity: usize = 128;

/// The pure core of the text input widget (see DESIGN → UI Framework →
/// Text input widget): a fixed-capacity UTF-8 buffer with a byte-index
/// caret and a selection anchor. All editing is pure methods over the
/// struct, unit-tested without raylib; the input-routing layer (which
/// knows the field kind, e.g. digits-only filtering) calls these, and
/// `view()` renders the caret/selection from the indices. Caret and
/// anchor always sit on CODEPOINT boundaries — never mid-multibyte.
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
    fn selectionRange(self: *const TextField) ?struct { start: usize, end: usize } {
        const anchor = self.selection_anchor orelse return null;
        if (anchor == self.caret) return null;
        return .{ .start = @min(anchor, self.caret), .end = @max(anchor, self.caret) };
    }

    /// Seed the buffer with a starting value (focus loads the field's
    /// current value so editing starts from it). Truncates to capacity.
    /// Caret at the end, no selection — the common edit-from-value start.
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
        // regions overlap — a forward copy would read already-overwritten
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
    /// Pure — the routing layer calls it with the field's measured text
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
/// write — the commit (not the focus) is what touches GameState.
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
/// input_handlers — the framework stays field-agnostic). Digits-only
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
    // field is gone by the next frame's synthetic edge) — their outcomes are
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
/// (Enter commits, Escape discards). Any other key is ignored here — its
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

/// Whether a field id takes digits only (the stat fields — parsing and
/// clamping happen at commit; this filter keeps garbage out of the buffer
/// as it's typed). Numeric ids join here with their slices.
fn textFieldIsNumeric(field_id: types.TextFieldId) bool {
    return switch (field_id) {
        .entity_name, .item_name, .mission_name, .level_name => false,
        .entity_stat, .item_stat => true,
    };
}

/// Click inside the FOCUSED field: map the click x to a caret index
/// (measured via the metrics) and move the caret there — a plain move,
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

/// Baseline-to-baseline height for one line at `font_size`, in reference
/// pixels. A layout factor (1.2em leading), not font data — raylib doesn't
/// expose hhea/OS·2 line metrics, so this stays a free function independent
/// of `FontMetrics`.
pub fn lineHeight(font_size: i32) i32 {
    return @divTrunc(font_size * 120, 100);
}

test "measurement seam: row width sums spans, bold equals plain" {
    // Synthetic metrics: base_size 100, uniform 50px advance per ASCII glyph.
    // With the shared per-glyph spacing (font_size/20 = 5px), each glyph
    // measures 50 + 5 = 55px — reproduces raylib's DrawTextEx cursor advance
    // so the wrapping/layout tests below stay deterministic and font-agnostic.
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const font_size: i32 = 100;
    // Plain: 4 glyphs * (50 advance + 5 spacing) = 220.
    try std.testing.expectEqual(@as(i32, 220), metrics.measureSpanWidth(text("abcd"), font_size));
    // Only the regular face is loaded, so bold renders identical to plain —
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

    // Select backward (anchor at 15, caret at 8) — same replaced range.
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

    // Multibyte: the fallback width (0.5em + spacing = 55 at size 100 —
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
    // outcome — if the key were a resolver — is discarded.
    _ = routeTextInput(&ui_state.text_edit.?, "", &no_keys, &backspace_repeated, false);
    try std.testing.expectEqualStrings("Skeleton Warri", ui_state.text_edit.?.buffer.currentText());

    // Shift+ArrowLeft selects (the anchor plants at the old caret —
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

test "emitInspectorTextField via the content builder: current value unfocused, buffer + caret + selection while focused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, .{ .r = 30, .g = 30, .b = 30 }, black, black, black, .{ .r = 40, .g = 40, .b = 40 } } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton Warrior", .sprite = "skeleton_1", .team = 1 },
    }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // Unfocused: both fields show the current values; no caret/selection.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        const name_field = findTextField(&elements, .entity_name).?;
        try std.testing.expectEqualStrings("Skeleton Warrior", name_field.text);
        try std.testing.expect(name_field.caret == null);
        try std.testing.expect(name_field.selection == null);
        // The paper-strip treatment: lightest frame, PURE-black text
        // (literal 0,0,0 — the caret/selection follow the text color).
        try std.testing.expectEqual(theme.lightest, name_field.frame_color);
        try std.testing.expectEqual(types.Color{ .r = 0, .g = 0, .b = 0 }, name_field.text_color);
        try std.testing.expectEqual(
            types.TextFieldRef{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } },
            name_field.ref,
        );
        // The control line: full content width, flush with the content
        // region's left edge (the label sits on its own line above).
        try std.testing.expectEqual(
            editorInspectorPanelRect().x + ui_gap,
            name_field.screen_position.x,
        );
    }

    // Focused (name), with a selection + mid-string caret: the field shows
    // the BUFFER, the selection rect spans the selected glyphs, and the
    // caret sits at the measured prefix width.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        beginTextEdit(&ui_state, .{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } }, "Skeleton");
        // Type " W" (caret at 10), then select back two codepoints
        // (" W" selected: anchor 10, caret 8).
        const no_keys: [0]?[]const u8 = .{};
        _ = routeTextInput(&ui_state.text_edit.?, " W", &no_keys, &no_keys, false);
        const arrow_left: [2]?[]const u8 = .{ "ArrowLeft", "ArrowLeft" };
        _ = routeTextInput(&ui_state.text_edit.?, "", &arrow_left, &no_keys, true);
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        const name_field = findTextField(&elements, .entity_name).?;
        try std.testing.expectEqualStrings("Skeleton W", name_field.text);
        // Selection spans buffer glyphs 8..10, caret sits at index 8 — the
        // geometry is the metrics' own measurement of those slices (the
        // accumulation truncates once at the end, so per-glyph arithmetic
        // would drift; measure the same way the builder does).
        const buffer_text = ui_state.text_edit.?.buffer.currentText();
        const expected_selection_x = metrics.measureSpanWidth(text(buffer_text[0..8]), 64);
        const expected_selection_width = metrics.measureSpanWidth(text(buffer_text[8..10]), 64);
        try std.testing.expectEqual(expected_selection_x, name_field.selection.?.x);
        try std.testing.expectEqual(expected_selection_width, name_field.selection.?.width);
        try std.testing.expectEqual(expected_selection_x, name_field.caret.?.x);
    }
}

/// The first text field in `elements` whose ref id matches, for inspector
/// builder tests.
fn findTextField(elements: *const UiElementList, field_id: types.TextFieldId) ?TextFieldUi {
    for (elements.items) |element| switch (element) {
        .text_field => |field| if (std.meta.eql(field.ref.id, field_id)) return field,
        else => {},
    };
    return null;
}

test "inspector scalar controls: stat fields formatted, swatch row, toggle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const enemy_two: types.Color = .{ .r = 20, .g = 20, .b = 20 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{ black, black, enemy_two, black, black, black } },
        .player_gradient = .{ .colors = .{ black, .{ .r = 30, .g = 30, .b = 30 }, black, black, black, .{ .r = 40, .g = 40, .b = 40 } } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // Defaults: max_health 20, defense 0, speed 1, aggro_range 3,
    // displays_weapons true; color_index SET TO 2 (the highlighted swatch).
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1, .color_index = 2 },
    }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // Scroll 10 — the Stats section's four numeric fields are the window
    // (the section-break spacer fills the tail): decimal-formatted values.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 10, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "- Stats", "Max health", "Defense", "Speed", "Aggro range" });
        try std.testing.expectEqualStrings("20", findTextField(&elements, .{ .entity_stat = .max_health }).?.text);
        try std.testing.expectEqualStrings("0", findTextField(&elements, .{ .entity_stat = .defense }).?.text);
        try std.testing.expectEqualStrings("1", findTextField(&elements, .{ .entity_stat = .speed }).?.text);
        try std.testing.expectEqualStrings("3", findTextField(&elements, .{ .entity_stat = .aggro_range }).?.text);
    }

    // The Color control (scroll 0 window): six swatch fills in the ENEMY
    // gradient + six payload buttons, the current index (2) highlighted.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        var swatch_count: usize = 0;
        var highlighted_count: usize = 0;
        var swatch_fill_seen = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_color) {
                swatch_count += 1;
                if (button.highlighted) {
                    highlighted_count += 1;
                    try std.testing.expectEqual(@as(u32, 2), button.editor_color.?);
                }
            },
            .solid_rect => |rect| {
                // The enemy gradient's index-2 color is the swatch fill for
                // index 2 (the others are black — assert the distinctive one).
                if (std.meta.eql(rect.color, enemy_two)) swatch_fill_seen = true;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 6), swatch_count);
        try std.testing.expectEqual(@as(usize, 1), highlighted_count);
        try std.testing.expect(swatch_fill_seen);
    }

    // The Displays-weapons control: a full-width toggle showing the FORMAT
    // vocabulary ("true"), highlighted while true.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        var toggle_button: ?Button = null;
        var saw_true_label = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .toggle_editor_entity_displays_weapons) {
                toggle_button = button;
            },
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "true")) saw_true_label = true;
            },
            else => {},
        };
        try std.testing.expect(toggle_button != null);
        // Half the control width (full-width reads as a section header),
        // and never highlighted (the true/false label carries the state).
        try std.testing.expectEqual(
            @divFloor(editorInspectorPanelRect().width - 2 * ui_gap, 2),
            toggle_button.?.width,
        );
        try std.testing.expect(!toggle_button.?.highlighted);
        try std.testing.expect(saw_true_label);
    }
}

test "decoration inspector content: identity + footprint rows, world-gradient swatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const world_three: types.Color = .{ .r = 20, .g = 20, .b = 20 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{ black, black, black, world_three, black, black } },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
        .color_index = 3,
    }};
    const editor: types.Editor = .{
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
    };

    var elements: UiElementList = .empty;
    var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
    try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);

    // Identity (Sprite + Color — a decoration's name IS its sprite path, no
    // name row) + Footprint (the read-only tile-count placeholder).
    try expectInspectorLabels(
        &elements,
        &.{ "- Identity", "Sprite", "stone_2", "Color", "- Footprint", "Footprint", "2 tiles" },
    );

    // The sprite button opens the shared picker (the input site routes the
    // kind by the inspector target).
    var saw_sprite_button = false;
    var swatch_count: usize = 0;
    var highlighted_count: usize = 0;
    var world_fill_seen = false;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.action == .open_editor_sprite_picker) saw_sprite_button = true;
            if (button.action == .select_editor_decoration_color) {
                swatch_count += 1;
                if (button.highlighted) {
                    highlighted_count += 1;
                    try std.testing.expectEqual(@as(u32, 3), button.editor_color.?);
                }
            }
        },
        .solid_rect => |rect| {
            // The WORLD gradient's index-3 color is the swatch fill for
            // index 3 (the others are black — assert the distinctive one).
            if (std.meta.eql(rect.color, world_three)) world_fill_seen = true;
        },
        else => {},
    };
    try std.testing.expect(saw_sprite_button);
    try std.testing.expectEqual(@as(usize, 6), swatch_count);
    try std.testing.expectEqual(@as(usize, 1), highlighted_count);
    try std.testing.expect(world_fill_seen);
}

test "inspector weapons + gear sections: type rows, add/delete, item fields when equipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, .{ .r = 30, .g = 30, .b = 30 }, black, black, black, .{ .r = 40, .g = 40, .b = 40 } } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // Main hand: an equipped sword. Coat: equipped. Everything else empty.
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{
            .name = "Skeleton",
            .team = 1,
            .main_hand_weapon = .{ .name = "Skeleton Sword", .weapon_type = .sword, .weapon_damage = 5 },
            .coat = .{ .name = "Skeleton Coat", .health_bonus = 2, .defense_bonus = 1 },
        },
    }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // Units: Identity 9 + spacer, Stats 9 + spacer → Weapons header at 20.
    // Scroll 20 shows: the Weapons header, Main hand (equipped: type row +
    // Delete + its fields), Off hand (empty: type row, no Delete).
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 20, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "- Weapons", "Main hand", "Delete", "Main hand name", "Main hand damage", "Off hand" });

        // The equipped weapon's fields carry its values.
        try std.testing.expectEqualStrings(
            "Skeleton Sword",
            findTextField(&elements, .{ .item_name = .main_hand }).?.text,
        );
        try std.testing.expectEqualStrings(
            "5",
            findTextField(&elements, .{ .item_stat = .{ .slot = .main_hand, .stat = .weapon_damage } }).?.text,
        );
        // No off-hand fields (the slot is empty).
        try std.testing.expect(findTextField(&elements, .{ .item_name = .off_hand }) == null);

        // Type cells: 12 total (two hands × 6), exactly one highlighted —
        // the main hand's sword. The main hand's row also carries a
        // Delete; the off hand's doesn't.
        var type_cells: usize = 0;
        var highlighted: ?types.GearSlot = null;
        var deletes: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .select_editor_weapon_type) {
                    type_cells += 1;
                    if (button.highlighted) highlighted = button.editor_gear_slot.?;
                    try std.testing.expect(button.editor_weapon_type != null);
                }
                if (button.action == .delete_editor_item and button.editor_gear_slot.? == .main_hand) {
                    deletes += 1;
                }
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 12), type_cells);
        try std.testing.expectEqual(types.GearSlot.main_hand, highlighted.?);
        try std.testing.expectEqual(@as(usize, 1), deletes);
    }

    // The Gear section's items (scroll 30 — the window opens at the Gear
    // header): coat equipped → Delete + its fields; amulet empty → Add.
    // The coat's defense field doesn't fully fit the window.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 30, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "- Gear", "Amulet", "Add", "Coat", "Delete", "Coat name", "Coat health bonus" });

        var adds: usize = 0;
        var coat_deletes: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .add_editor_item and button.editor_gear_slot.? == .amulet) adds += 1;
                if (button.action == .delete_editor_item and button.editor_gear_slot.? == .coat) coat_deletes += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), adds);
        try std.testing.expectEqual(@as(usize, 1), coat_deletes);
        try std.testing.expectEqualStrings(
            "Skeleton Coat",
            findTextField(&elements, .{ .item_name = .coat }).?.text,
        );
        try std.testing.expectEqualStrings(
            "2",
            findTextField(&elements, .{ .item_stat = .{ .slot = .coat, .stat = .health_bonus } }).?.text,
        );
    }
}

test "editorInspectorTarget: active enemy/decoration tools pass through; tile/item fall back to the player" {
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 },
    }};
    const decoration_types = [_]types.DecorationTypeDef{.{ .id = "Tree" }};
    const item_types = [_]types.ItemTypeDef{.{ .id = "Gold" }};
    const levels = [_]types.EditorLevel{.{}};
    const base: types.Editor = .{
        .levels = &levels,
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
        .item_types = &item_types,
        .active_tool = .{ .entity_type = 0 },
    };
    try std.testing.expectEqual(EditorInspectorTarget{ .entity_type = 0 }, editorInspectorTarget(base));

    var tile_tool = base;
    tile_tool.active_tool = .tile;
    try std.testing.expectEqual(EditorInspectorTarget.player, editorInspectorTarget(tile_tool));

    var decoration_tool = base;
    decoration_tool.active_tool = .{ .decoration_type = 0 };
    try std.testing.expectEqual(
        EditorInspectorTarget{ .decoration_type = 0 },
        editorInspectorTarget(decoration_tool),
    );

    var item_tool = base;
    item_tool.active_tool = .{ .item_type = 0 };
    try std.testing.expectEqual(EditorInspectorTarget.player, editorInspectorTarget(item_tool));

    // A stale active tool id (defensive) can't show anything.
    var stale_tool = base;
    stale_tool.active_tool = .{ .entity_type = 7 };
    try std.testing.expectEqual(EditorInspectorTarget.player, editorInspectorTarget(stale_tool));
    var stale_decoration_tool = base;
    stale_decoration_tool.active_tool = .{ .decoration_type = 7 };
    try std.testing.expectEqual(EditorInspectorTarget.player, editorInspectorTarget(stale_decoration_tool));

    // An empty selection under the select tool → the player fallback.
    var select_tool = base;
    select_tool.active_tool = .select;
    try std.testing.expectEqual(EditorInspectorTarget.player, editorInspectorTarget(select_tool));
}

test "editorInspectorTarget: one shared enemy type wins; tiles and the '=' are ignored" {
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .team = 1 } },
        .{ .id = "Bat", .template = .{ .name = "Bat", .team = 1 } },
    };
    const levels = [_]types.EditorLevel{.{ .entity_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
        .{ .type_id = 0, .position = .{ .x = 3, .y = 1 } },
        .{ .type_id = 1, .position = .{ .x = 5, .y = 2 } },
    } }};
    const resolve = struct {
        fn check(
            selection: []const types.Selectable,
        ) EditorInspectorTarget {
            return editorInspectorTarget(.{
                .levels = &levels,
                .entity_types = &entity_types,
                .active_tool = .select,
                .selection = selection,
            });
        }
    }.check;

    // One enemy → its type.
    try std.testing.expectEqual(
        EditorInspectorTarget{ .entity_type = 0 },
        resolve(&.{.{ .entity_placement = 0 }}),
    );

    // Several enemies of the SAME type, mixed with tiles and the '='
    // (legitimately uninspectable — they contribute nothing) → still that
    // one type.
    try std.testing.expectEqual(
        EditorInspectorTarget{ .entity_type = 0 },
        resolve(&.{
            .{ .tile = .{ .x = 1, .y = 1 } },
            .{ .entity_placement = 1 },
            .{ .level_end = {} },
            .{ .entity_placement = 0 },
        }),
    );

    // Two different enemy types → the player fallback.
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .entity_placement = 0 }, .{ .entity_placement = 2 } }),
    );

    // Tiles / the '=' only → nothing referenced → the player fallback.
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .tile = .{ .x = 0, .y = 0 } }, .{ .level_end = {} } }),
    );
}

test "editorInspectorTarget: selected decorations resolve to their type" {
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .team = 1 },
    }};
    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "tree_1" },
        .{ .id = "ruin_1" },
    };
    const levels = [_]types.EditorLevel{.{ .decoration_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 2, .y = 2 } },
        .{ .type_id = 0, .position = .{ .x = 5, .y = 1 } },
        .{ .type_id = 1, .position = .{ .x = 8, .y = 0 } },
    }, .entity_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
    } }};
    const resolve = struct {
        fn check(
            selection: []const types.Selectable,
        ) EditorInspectorTarget {
            return editorInspectorTarget(.{
                .levels = &levels,
                .entity_types = &entity_types,
                .decoration_types = &decoration_types,
                .active_tool = .select,
                .selection = selection,
            });
        }
    }.check;

    // One decoration → its type.
    try std.testing.expectEqual(
        EditorInspectorTarget{ .decoration_type = 0 },
        resolve(&.{.{ .decoration_placement = 0 }}),
    );

    // Several decorations of the SAME type → still that one type.
    try std.testing.expectEqual(
        EditorInspectorTarget{ .decoration_type = 0 },
        resolve(&.{ .{ .decoration_placement = 0 }, .{ .decoration_placement = 1 } }),
    );

    // A decoration + an enemy → two distinct kinds → the player fallback.
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .decoration_placement = 0 }, .{ .entity_placement = 0 } }),
    );

    // An out-of-range placement index or a stale palette type id is an
    // unresolvable bug-state reference — fallback, not a crash (the
    // delete arms keep the selection consistent, so this is defensive).
    try std.testing.expectEqual(EditorInspectorTarget.player, resolve(&.{.{ .decoration_placement = 99 }}));

    const stale_levels = [_]types.EditorLevel{.{ .decoration_placements = &.{
        .{ .type_id = 7, .position = .{ .x = 0, .y = 0 } },
    } }};
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        editorInspectorTarget(.{
            .levels = &stale_levels,
            .decoration_types = &decoration_types,
            .active_tool = .select,
            .selection = &.{.{ .decoration_placement = 0 }},
        }),
    );
}

test "editorInspectorTarget: the '!' contributes a player reference" {
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .team = 1 } },
    };
    const levels = [_]types.EditorLevel{.{ .entity_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 0, .y = 0 } },
    } }};
    const resolve = struct {
        fn check(
            selection: []const types.Selectable,
        ) EditorInspectorTarget {
            return editorInspectorTarget(.{
                .levels = &levels,
                .entity_types = &entity_types,
                .active_tool = .select,
                .selection = selection,
            });
        }
    }.check;

    // The '!' alone → the player.
    try std.testing.expectEqual(EditorInspectorTarget.player, resolve(&.{.{ .player_start = {} }}));

    // The '!' + an enemy → two distinct references → the player (the
    // enemy does NOT win over the spawn).
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .entity_placement = 0 }, .{ .player_start = {} } }),
    );

    // The '!' mixed with tiles / the '=' → still the player.
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .tile = .{ .x = 2, .y = 2 } }, .{ .player_start = {} } }),
    );
}

test "editorInspectorTarget: unresolvable references force the player fallback" {
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .team = 1 },
    }};
    const item_types = [_]types.ItemTypeDef{.{ .id = "Gold" }};
    const levels = [_]types.EditorLevel{.{ .entity_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 1, .y = 0 } },
    }, .item_placements = &.{
        .{ .type_id = 0, .position = .{ .x = 2, .y = 2 } },
    } }};
    const resolve = struct {
        fn check(
            selection: []const types.Selectable,
        ) EditorInspectorTarget {
            return editorInspectorTarget(.{
                .levels = &levels,
                .entity_types = &entity_types,
                .item_types = &item_types,
                .active_tool = .select,
                .selection = selection,
            });
        }
    }.check;

    // A selected ground item has no inspector content — fallback (alone
    // or mixed with a valid enemy).
    try std.testing.expectEqual(EditorInspectorTarget.player, resolve(&.{.{ .ground_item_placement = 0 }}));
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        resolve(&.{ .{ .entity_placement = 0 }, .{ .ground_item_placement = 0 } }),
    );

    // An out-of-range placement index or a stale palette type id is an
    // unresolvable bug-state reference — fallback, not a crash (the
    // delete arms keep the selection consistent, so this is defensive).
    try std.testing.expectEqual(EditorInspectorTarget.player, resolve(&.{.{ .entity_placement = 99 }}));

    const stale_levels = [_]types.EditorLevel{.{ .entity_placements = &.{
        .{ .type_id = 7, .position = .{ .x = 0, .y = 0 } },
    } }};
    try std.testing.expectEqual(
        EditorInspectorTarget.player,
        editorInspectorTarget(.{
            .levels = &stale_levels,
            .entity_types = &entity_types,
            .active_tool = .select,
            .selection = &.{.{ .entity_placement = 0 }},
        }),
    );

    // The entity arm the content builder consumes: a valid inference
    // resolves, everything else nulls.
    try std.testing.expectEqual(
        @as(?u32, 0),
        editorInspectorEntityTarget(.{
            .levels = &levels,
            .entity_types = &entity_types,
            .active_tool = .select,
            .selection = &.{.{ .entity_placement = 0 }},
        }),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        editorInspectorEntityTarget(.{
            .levels = &levels,
            .entity_types = &entity_types,
            .active_tool = .select,
            .selection = &.{.{ .player_start = {} }},
        }),
    );
}

test "textEditPressProceeds: M2 region is the open inspector panel + its toggle" {
    const rect = editorInspectorPanelRect();
    try std.testing.expectEqual(@as(i32, 0), rect.x);
    try std.testing.expectEqual(
        top_bar_height + ui_gap + editor_header_strip_height + ui_gap,
        rect.y,
    );
    try std.testing.expectEqual(editor_inspector_width, rect.width);

    const inside_panel: ScreenPosition = .{ .x = 512, .y = rect.y + 100 };
    const outside_panel: ScreenPosition = .{ .x = 1500, .y = rect.y + 100 };
    const over_viewport: ScreenPosition = .{ .x = 1500, .y = 1000 };

    // Inside the open panel → a sibling control; the press proceeds.
    try std.testing.expect(textEditPressProceeds(true, false, inside_panel, null));
    // Panel closed → only the toggle button itself proceeds.
    try std.testing.expect(!textEditPressProceeds(false, false, inside_panel, null));
    try std.testing.expect(textEditPressProceeds(false, false, inside_panel, .toggle_editor_inspector));
    // Outside the panel → pure dismissal, even over other UI (Undo).
    try std.testing.expect(!textEditPressProceeds(true, false, outside_panel, .undo));
    try std.testing.expect(!textEditPressProceeds(true, false, over_viewport, null));
    // Picker surfaces float OUTSIDE the panel rect but are the active
    // interaction — the press proceeds (commit + pick in one click).
    try std.testing.expect(textEditPressProceeds(true, false, outside_panel, .select_editor_utility_skill));
    try std.testing.expect(textEditPressProceeds(true, false, outside_panel, .close_editor_picker));
    // The settings sidebar's rect + toggle behave the same (a sibling
    // control of a sidebar field).
    const sidebar_rect = editorSettingsSidebarPanelRect();
    const inside_sidebar: ScreenPosition = .{ .x = sidebar_rect.x + 100, .y = sidebar_rect.y + 100 };
    try std.testing.expect(textEditPressProceeds(false, true, inside_sidebar, null));
    try std.testing.expect(!textEditPressProceeds(false, false, inside_sidebar, null));
    try std.testing.expect(textEditPressProceeds(false, false, inside_sidebar, .toggle_editor_settings_sidebar));
}



// ============================================================
// Layout constants — fixed sizes in reference resolution
// ============================================================

pub const top_bar_height: i32 = 256;
pub const bottom_bar_height: i32 = 256;
/// Standard gameplay button/slot size (128×128 at 1080p → 256×256 at the
/// 2160p reference resolution).
pub const slot_size: i32 = 256;
/// Weapon-swap button — half a normal button, centered vertically.
pub const swap_button_size: i32 = 128;
/// Main-menu button — wide stacked buttons on the title screen.
pub const menu_button_width: i32 = 1024;
pub const menu_button_font_size: i32 = 96;
/// Main-menu title ("taplop") — centered at the top of the screen, above
/// the button stack. Larger than every other UI font size (atlas glyphs
/// upscale 1.5× from the 128px base — accepted softness for a title).
pub const main_menu_title_font_size: i32 = 256;
/// Gap between the main-menu title band and the first button.
pub const main_menu_title_gap: i32 = 96;
/// Shared height for every `emitPanelButton` panel-backed button (main
/// menu, mission end screens, error-popup dismiss, load-save browser,
/// credits, settings). One tuning knob for the panel-button height class —
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
/// Movement threshold (reference-space pixels) separating a click from a
/// drag: a press that moves less than this before release is a click; at or
/// beyond it the press promotes to a drag (ghost appears). Standard UI
/// disambiguation — see DESIGN → UI Framework.
pub const drag_threshold_pixels: i32 = 8;
/// Double-click window (microseconds, session-clock). Two plain single
/// clicks on the same inventory slot + same button within this window fire
/// the double-click intent. Modifier-clicks (ctrl/alt/shift) fire
/// immediately and don't seed a pending double.
pub const double_click_threshold_us: u64 = 400_000;
/// One inventory grid cell (half `slot_size` — ported from the Unity
/// 256×256 ItemSlot.png at 0.5x). See DESIGN → UI Framework.
pub const inventory_slot_size: i32 = 128;
/// Inventory panel content area (below the header): `ui_gap` clearance +
/// 8×12 flush grid (1024×1536) + `ui_gap` + 128-wide material sidebar +
/// `ui_gap` clearance. Width  = 16 + 1024 + 16 + 128 + 16 = 1200.
/// Content height = 16 + 1536 + 16 = 1568 = middle_panel_height − header_height.
pub const inventory_panel_width: i32 = 1200;
/// Middle panels fill the full middle section height (reference_height −
/// top_bar_height − bottom_bar_height = 1648). The header strip
/// (`header_height`) sits at the top of each panel; the content area below
/// is `middle_panel_height − header_height` = 1568, which fits the
/// inventory grid (16 + 12×128 + 16) exactly. See `emitPanelHeader`.
pub const middle_panel_height: i32 = 1648;
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
/// Scrollbar lives in the panel's right `ui_gap` margin (16px), so the
/// track is 12px centered within it. See `buildSkillsPanel`.
pub const skills_scrollbar_width: i32 = 12;
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

/// The full reference-resolution canvas — the root region everything
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

    pub fn totalWidth(self: Grid) i32 {
        return rowWidth(self.columns, self.cell_width, self.gap);
    }

    pub fn totalHeight(self: Grid, rows: i32) i32 {
        return rowWidth(rows, self.cell_height, self.gap);
    }
};

// ============================================================
// UI elements — building blocks for the view function
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
/// destination region (reference pixels). Pure geometry — the renderer only
/// forwards each pair to the GPU.
pub const NineSlicePiece = struct {
    source: Rectangle,
    destination: Rectangle,
};

/// Compute the nine source/destination rect pairs that draw a 9-slice panel
/// sprite over `destination`. All corners are drawn SQUARE (aspect-true 1:1):
/// the corner size is `min(slice_width, slice_height, destination.width/2,
/// destination.height/2)`, and both the source and destination rects are
/// cropped to that size — a panel shorter than two slices gets proportionally
/// smaller corners instead of squashed ones. Edges stretch along their run
/// axis and keep the corner thickness across it; the center stretches in
/// both axes. Pieces are row-major (top-left, top, top-right, left, center,
/// right, bottom-left, bottom, bottom-right); degenerate pieces (zero size,
/// only possible on a panel smaller than 2× the corner size) are returned
/// with zero extents for the caller to skip.
pub fn nineSlicePieces(
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
    // Corner = min(128, 128, 50, 50) = 50 — everything shrinks uniformly.
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
    /// Settings control identity, if this button is a settings toggle or
    /// choice. The `.change_setting` action + `AnytimeInput.clicked_setting`
    /// fold this into the handler. Null for non-settings buttons. See
    /// `SettingRef`.
    /// DESIGN → UI Framework → Settings screen.
    setting_ref: ?types.SettingRef = null,
    /// Editor palette group index, if this button is a group header
    /// (expand/collapse). The `.toggle_editor_palette_group` action +
    /// `AnytimeInput.clicked_editor_group` fold this into the handler —
    /// same pattern as `setting_ref`.
    editor_group: ?usize = null,
    /// Inspector section identity, if this button is a section header
    /// (expand/collapse). The `.toggle_editor_inspector_section` action +
    /// `AnytimeInput.clicked_editor_section` fold this into the handler.
    editor_section: ?types.EditorInspectorSectionId = null,
    /// Sprite picker cell identity, if this button is a sprite option (the
    /// stem — for mission-local picks the namespaced
    /// `custom/<mission>/<stem>` id). The `.select_editor_entity_sprite`
    /// action + `AnytimeInput.clicked_editor_sprite` fold this into the
    /// handler.
    editor_sprite: ?[]const u8 = null,
    /// Sprite picker tab identity, if this button is a tab (Mission /
    /// Official). The `.select_editor_sprite_tab` action +
    /// `AnytimeInput.clicked_editor_sprite_tab` fold this into the handler.
    editor_sprite_tab: ?types.EditorSpritePickerTab = null,
    /// Editor tool identity, if this button is a tool cell (make it the
    /// active tool). The `.select_editor_tool` action +
    /// `AnytimeInput.clicked_editor_tool` fold this into the handler.
    editor_tool: ?types.EditorToolId = null,
    /// Editor level-tab index, if this button is a level tab (make that
    /// level active). The `.select_editor_level` action +
    /// `AnytimeInput.clicked_editor_level` fold this into the handler.
    editor_level: ?u32 = null,
    /// Editor entity color-swatch index, if this button is one of the
    /// inspector's color swatches. The `.select_editor_entity_color`
    /// action + `AnytimeInput.clicked_editor_color` fold this into the
    /// handler.
    editor_color: ?u32 = null,
    /// Editor gear slot, if this button is an inspector slot control (a
    /// weapon-type cell, Add, or Delete). Rides in
    /// `AnytimeInput.clicked_editor_gear_slot` alongside its action.
    editor_gear_slot: ?types.GearSlot = null,
    /// Editor weapon type, if this button is a weapon-type cell (set
    /// alongside `editor_gear_slot`). Rides in
    /// `AnytimeInput.clicked_editor_weapon_type`.
    editor_weapon_type: ?types.WeaponType = null,
    /// Editor utility-slot index, if this button is an inspector
    /// utility-slot button (opens the skill picker). Rides in
    /// `AnytimeInput.clicked_editor_utility_slot`.
    editor_utility_slot: ?u32 = null,
    /// Editor LAYER index, if this button is a Layers-section control (a
    /// layer's sprite button, its color swatches, its Delete, or the
    /// add-layer button — null there = the picker's add mode). Rides in
    /// `AnytimeInput.clicked_editor_layer` alongside its action.
    editor_layer: ?u32 = null,
    /// Footprint-editor grid cell (row-major), if this button is one of
    /// the editor's sprite-grid tile cells. Rides in
    /// `AnytimeInput.clicked_editor_footprint_tile`.
    editor_footprint_tile: ?u32 = null,
    /// Editor skill pick, if this button is a skill-picker cell. Rides in
    /// `AnytimeInput.clicked_editor_skill`; null on the None cell (clears).
    editor_skill: ?types.SkillId = null,
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

/// A sprite image (icon, decoration, etc.).
pub const Image = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    width: i32,
    height: i32,
    color: Color = default_tint,
    /// Tint alpha (0–255). Default fully opaque; overlays like the skill
    /// cooldown wash use 128 for 50% transparency.
    alpha: u8 = 255,
    /// Region of the sprite to draw. Null means the full sprite. Used for
    /// spritesheet frames (e.g. the editor Select tool's
    /// `world/tile_highlight` frame 0).
    source_rectangle: ?Rectangle = null,
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

/// An editable text field (the text-input widget's UI surface — see
/// DESIGN → UI Framework → Text input widget). The builder computes ALL
/// render data (it owns the metrics + the focused field's buffer): the
/// frame rect, the text to show (the field's current value, or the live
/// buffer while THIS field is focused), and the caret/selection geometry
/// — the backend just draws. `ref` is the field's identity for
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
    /// The text's color — also the caret + selection color (a field's
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
/// (stroked — same `drawRectangleLinesEx` primitive as the world
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
/// (single source of truth — no bounds stored alongside the element).
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

/// Whether an element occludes the pointer — i.e. hit-testing stops here
/// instead of falling through to elements drawn behind it. Solid surfaces
/// (panels, buttons, slots) block; decorative overlays (cooldown numbers,
/// the drag ghost, the tooltip itself) opt out with `blocks_input = false`.
pub fn blocksInputOf(element: UiElement) bool {
    return switch (element) {
        inline else => |e| e.blocks_input,
    };
}

/// The one hit-testing primitive shared by every pointer query (tooltips,
/// clicks, drags, …). Walks elements top-to-bottom (reverse of draw order).
/// Non-blocking elements are transparent and skipped; the walk halts at the
/// first blocking element. Returns the topmost element under `position` that
/// satisfies `matches`, provided it is reached before any blocker — so an
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
/// check — used during an active drag to find the slider matching the
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
pub fn slotAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?Slot {
    return if (hitTest(ui_elements, position, isRefSlot)) |i| ui_elements[i].slot else null;
}

/// The SlotRef of the topmost ref-bearing slot under `position`, or null.
pub fn slotRefAt(
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?SlotRef {
    return if (slotAt(ui_elements, position)) |slot| slot.ref else null;
}

/// The SlotRef of the topmost ref-bearing element under `position`, or null.
/// Covers both `.slot` and `.button` elements (skill-bar slots are buttons
/// that also carry a ref — click = activate, drag = reorder/clear). Used by
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
        // A non-blocking overlay on top (e.g. cooldown number) — pass through.
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
// Tooltip placement (side-based)
// ============================================================

/// One side of the source element a tooltip can sit flush against.
pub const Side = enum { right, below, left, above };

/// Place the tooltip flush against one side of the source element so they
/// share an edge (not just a corner). Tries sides in a fixed preference
/// order — above, below, right, left — and uses the first that fits on
/// screen without clamping, so tooltips prefer going above an element
/// (the natural direction, especially for the bottom bar) and only fall
/// sideways when there's no vertical room. If no side fits fully, falls back
/// to the top preference (above) and clamps. Aligns the tooltip to the near
/// corner along the chosen side — e.g. above with the source in the left
/// half left-aligns the tooltip, so the shared edge runs from the source's
/// top-left corner rightward. Clamping shifts the tooltip along the
/// cross-axis, shrinking the shared edge but keeping the sides flush
/// (degenerates to a point only if the tooltip is larger than the available
/// cross-axis space).
pub fn placeTooltip(
    source_position: ScreenPosition,
    source_width: i32,
    source_height: i32,
    tooltip_width: i32,
    tooltip_height: i32,
) struct { x: i32, y: i32 } {
    const source_right = source_position.x + source_width;
    const source_bottom = source_position.y + source_height;
    const screen_w = types.reference_width;
    const screen_h = types.reference_height;
    const source_center_x = source_position.x + @divTrunc(source_width, 2);
    const source_center_y = source_position.y + @divTrunc(source_height, 2);
    const left_half = source_center_x < @divTrunc(screen_w, 2);
    const top_half = source_center_y < @divTrunc(screen_h, 2);

    // Candidate position for each side, in preference order (above, below,
    // right, left). Each is flush on its side and aligned to the near corner
    // along that side.
    const positions = [_]struct { x: i32, y: i32 }{
        // above: flush over the source, horizontally near-corner-aligned.
        .{ .x = if (left_half) source_position.x else source_right - tooltip_width, .y = source_position.y - tooltip_height },
        // below: flush under the source, horizontally near-corner-aligned.
        .{ .x = if (left_half) source_position.x else source_right - tooltip_width, .y = source_bottom },
        // right: flush to the right, vertically near-corner-aligned.
        .{ .x = source_right, .y = if (top_half) source_position.y else source_bottom - tooltip_height },
        // left: flush to the left, vertically near-corner-aligned.
        .{ .x = source_position.x - tooltip_width, .y = if (top_half) source_position.y else source_bottom - tooltip_height },
    };

    // First side that fits on screen without clamping wins.
    for (positions) |pos| {
        if (pos.x >= 0 and pos.x + tooltip_width <= screen_w and pos.y >= 0 and pos.y + tooltip_height <= screen_h)
            return .{ .x = pos.x, .y = pos.y };
    }

    // None fit fully — fall back to the top preference (above), clamped.
    // `@max(0, …)` guards an oversized tooltip (taller/wider than the
    // reference screen): screen - tooltip goes negative, and clamp requires
    // lo <= hi. Clamping to 0 pins the top-left corner — the best placement
    // when the panel can't fit anywhere.
    const fallback = positions[0];
    return .{
        .x = std.math.clamp(fallback.x, 0, @max(0, screen_w - tooltip_width)),
        .y = std.math.clamp(fallback.y, 0, @max(0, screen_h - tooltip_height)),
    };
}

// ============================================================
// Tooltip layout
// ============================================================
// Measures and wraps a Tooltip's rows against the padded content area, then
// positions a background panel plus one TextLabel per span. Written entirely
// against the measurement seam (measureSpanWidth / lineHeight), so it is
// deterministic and testable regardless of the eventual font.

pub const tooltip_max_width: i32 = 1024;
pub const tooltip_padding: i32 = 24; // inner padding around content
pub const tooltip_row_gap: i32 = 8; // vertical gap between rows
pub const tooltip_header_gap: i32 = 16; // extra gap below the header
pub const tooltip_header_font_size: i32 = 64;
pub const tooltip_body_font_size: i32 = 56;
pub const tooltip_panel_sprite = "ui/panel";

// Error popup sizing — a modal centered panel for recoverable load
// failures (see SessionState.pending_error). Reuses the tooltip wrap
// machinery (wrapRow / measureRowWidth / lineHeight) for the message body.
// The body scrolls when the wrapped text exceeds the max body height.
pub const error_popup_max_width: i32 = 1280;
pub const error_popup_padding: i32 = 32;
pub const error_header_font_size: i32 = 72;
pub const error_body_font_size: i32 = 56;
pub const error_header_gap: i32 = 24; // gap below the "Error" header
pub const error_button_gap: i32 = 32; // gap above the Dismiss button
pub const error_dismiss_button_width: i32 = 512;
pub const error_dismiss_button_font_size: i32 = 64;
/// One body text line's height — also the scroll-step unit (arrow keys scroll
/// 3 lines at a time; see handleAnytimeInput). Kept in sync with
/// `lineHeight(error_body_font_size)`.
pub const error_scroll_line_height: i32 = 56;
/// Max body region height before scrolling kicks in. Leaves room for the
/// header + Dismiss button + padding within the 2160px reference height.
pub const error_popup_max_body_height: i32 = 1600;
/// Scrollbar geometry (reference-space pixels). Drawn only when the body
/// content overflows the visible region.
pub const error_scrollbar_width: i32 = 12;
pub const error_scrollbar_gap: i32 = 16; // gap between body text and scrollbar

/// Build a modal, centered, scrollable error popup showing `message` with
/// a Dismiss button. Appended last in view() so it draws on top of
/// everything; the panel's `blocks_input = true` halts hit-testing within
/// its bounds. handleAnytimeInput gates all input except `dismiss_error` +
/// the scroll actions while a pending error is set (see
/// SessionState.pending_error).
///
/// When the wrapped body exceeds `error_popup_max_body_height`, the body
/// scrolls: only lines within the visible window are emitted, and a
/// scrollbar is drawn. `session.error_scroll_offset` is clamped to
/// `[0, max_scroll]` here (the view is the only place that knows
/// `max_scroll`, which depends on the wrapped line count). Pure over the
/// message + frame arena, aside from that scroll-offset clamp.
pub fn buildErrorPopup(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    session: *state.SessionState,
    message: []const u8,
    button_color: Color,
) !void {
    const content_width_limit = error_popup_max_width - 2 * error_popup_padding;

    const header_lines = try wrapRow(
        allocator,
        font_metrics,
        try spanRow(allocator, text("Error")),
        error_header_font_size,
        content_width_limit,
    );
    const body_lines = try wrapRow(
        allocator,
        font_metrics,
        try spanRow(allocator, text(message)),
        error_body_font_size,
        content_width_limit,
    );

    const body_line_height = lineHeight(error_body_font_size);
    const body_content_height: i32 = @intCast(body_lines.len * @as(usize, @intCast(body_line_height)));
    const visible_body_height = @min(body_content_height, error_popup_max_body_height);
    const max_scroll = @max(@as(i32, 0), body_content_height - visible_body_height);
    // Clamp the scroll offset (authoritative — the input handler can't know
    // max_scroll without wrapping the text itself).
    if (session.error_scroll_offset < 0) session.error_scroll_offset = 0;
    if (session.error_scroll_offset > max_scroll) session.error_scroll_offset = max_scroll;
    const scroll_offset = session.error_scroll_offset;
    const scrolls = body_content_height > visible_body_height;

    // Content width = widest visual line, capped to the limit. The Dismiss
    // button + scrollbar also constrain width so they fit inside the panel.
    var content_width: i32 = error_dismiss_button_width;
    if (scrolls) content_width += error_scrollbar_width + error_scrollbar_gap;
    for (header_lines) |line| {
        const line_width = @min(font_metrics.measureRowWidth(line, error_header_font_size), content_width_limit);
        if (line_width > content_width) content_width = line_width;
    }
    for (body_lines) |line| {
        const line_width = @min(font_metrics.measureRowWidth(line, error_body_font_size), content_width_limit);
        if (line_width > content_width) content_width = line_width;
    }

    // Content height: header lines + header gap + visible body + button gap + button.
    const header_height: i32 = @intCast(header_lines.len * @as(usize, @intCast(lineHeight(error_header_font_size))));
    const content_height = header_height +
        error_header_gap +
        visible_body_height +
        error_button_gap +
        panel_button_height;

    const panel_width = content_width + 2 * error_popup_padding;
    const panel_height = content_height + 2 * error_popup_padding;

    // Center on screen, clamped to the reference resolution.
    const panel_rect = screenRect().placeCenter(panel_width, panel_height);
    const panel_pos = panel_rect.position();

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = tooltip_panel_sprite,
        .screen_position = panel_pos,
        .width = panel_width,
        .height = panel_height,
        // Modal: halts hit-testing within the panel bounds so clicks on the
        // popup (not on the button) are swallowed rather than passing through.
        .blocks_input = true,
    } });

    const content_x = panel_pos.x + error_popup_padding;
    var y = panel_pos.y + error_popup_padding;

    // Header lines.
    for (header_lines) |line| {
        var x = content_x;
        for (line) |span| {
            try elements.append(allocator, .{ .text_label = .{
                .text = span.text,
                .screen_position = .{ .x = x, .y = y },
                .color = span.color,
                .font_size = error_header_font_size,
                .bold = true,
                .blocks_input = false,
            } });
            x += font_metrics.measureSpanWidth(span, error_header_font_size);
        }
        y += lineHeight(error_header_font_size);
    }
    y += error_header_gap;

    // Body: emit only the lines within the scroll window. Lines above
    // scroll_offset are above the visible region; lines below
    // (scroll_offset + visible_body_height) are below it. The renderer
    // would clip them anyway, but skipping them keeps the element list small
    // and the hit-test set clean.
    const body_top = y;
    const first_visible_line: usize = @intCast(@divTrunc(scroll_offset, body_line_height));
    const visible_line_count: usize = @intCast(@divTrunc(visible_body_height, body_line_height));
    const last_visible_line = @min(body_lines.len, first_visible_line + visible_line_count);
    // Skip the height of the lines above the scroll window.
    y += @intCast(first_visible_line * @as(usize, @intCast(body_line_height)));
    for (body_lines[first_visible_line..last_visible_line]) |line| {
        var x = content_x;
        for (line) |span| {
            try elements.append(allocator, .{ .text_label = .{
                .text = span.text,
                .screen_position = .{ .x = x, .y = y },
                .color = span.color,
                .font_size = error_body_font_size,
                .blocks_input = false,
            } });
            x += font_metrics.measureSpanWidth(span, error_body_font_size);
        }
        y += body_line_height;
    }

    // Scrollbar (only when the body overflows). Track + thumb on the right
    // edge of the body region. The thumb is proportional to the visible /
    // total ratio and positioned by the scroll offset.
    if (scrolls) {
        const scrollbar_x = content_x + content_width - error_scrollbar_width;
        const track_color: types.Color = .{ .r = 80, .g = 80, .b = 80 };
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = scrollbar_x, .y = body_top },
            .width = error_scrollbar_width,
            .height = visible_body_height,
            .color = track_color,
        } });
        const thumb_height = @max(
            @as(i32, 40),
            @divTrunc(visible_body_height * visible_body_height, body_content_height),
        );
        const thumb_y = body_top + @divTrunc(scroll_offset * (visible_body_height - thumb_height), max_scroll);
        const thumb_color: types.Color = .{ .r = 180, .g = 180, .b = 180 };
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = scrollbar_x, .y = thumb_y },
            .width = error_scrollbar_width,
            .height = thumb_height,
            .color = thumb_color,
        } });
    }

    // Dismiss button, centered horizontally in the panel. Positioned after
    // the (possibly scrolled) body region — always at the bottom, reachable.
    y = body_top + visible_body_height + error_button_gap;
    const button_rect = Rectangle{
        .x = panel_pos.x + @divTrunc(panel_width - error_dismiss_button_width, 2),
        .y = y,
        .width = error_dismiss_button_width,
        .height = panel_button_height,
    };
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        button_rect,
        "Dismiss",
        error_dismiss_button_font_size,
        .dismiss_error,
        button_color,
        null,
    );
}


/// Wrap one logical row into visual lines that each fit `content_width`.
/// Text is split on spaces (the only break opportunities); each word keeps
/// its span's style, so styling survives wrapping. Spaces at a wrap point
/// (and at the start of a line) are dropped; a single word wider than
/// `content_width` sits alone on its line and is allowed to overflow.
fn wrapRow(
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
                // Run of non-space, non-slash characters.
                while (index < span.text.len and span.text[index] != ' ' and span.text[index] != '/') index += 1;
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
const WrappedRow = struct {
    font_size: i32,
    lines: []const TooltipRow,
    is_header: bool,
};

/// Append a tooltip (background panel + positioned text) for `tooltip`,
/// anchored to the element at the given source bounds. No-op for empty
/// tooltips.
pub fn buildTooltip(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    source_position: ScreenPosition,
    source_width: i32,
    source_height: i32,
    tooltip: Tooltip,
) !void {
    const content_width_limit = tooltip_max_width - 2 * tooltip_padding;

    // Wrap every row up front so the panel can be sized before placement.
    var wrapped: std.ArrayList(WrappedRow) = .empty;
    if (tooltip.header) |header| {
        try wrapped.append(allocator, .{
            .font_size = tooltip_header_font_size,
            .lines = try wrapRow(allocator, font_metrics, header, tooltip_header_font_size, content_width_limit),
            .is_header = true,
        });
    }
    for (tooltip.body) |body_row| {
        try wrapped.append(allocator, .{
            .font_size = tooltip_body_font_size,
            .lines = try wrapRow(allocator, font_metrics, body_row, tooltip_body_font_size, content_width_limit),
            .is_header = false,
        });
    }
    if (wrapped.items.len == 0) return;

    // Size: widest visual line (capped) for width; stacked line heights plus
    // inter-row and header gaps for height. This loop mirrors the emit loop.
    var content_width: i32 = 0;
    var content_height: i32 = 0;
    for (wrapped.items, 0..) |wrapped_row, row_index| {
        if (row_index > 0) content_height += tooltip_row_gap;
        for (wrapped_row.lines) |line| {
            const line_width = @min(font_metrics.measureRowWidth(line, wrapped_row.font_size), content_width_limit);
            if (line_width > content_width) content_width = line_width;
            content_height += lineHeight(wrapped_row.font_size);
        }
        if (wrapped_row.is_header) content_height += tooltip_header_gap;
    }

    const panel_width = content_width + 2 * tooltip_padding;
    const panel_height = content_height + 2 * tooltip_padding;

    // Place flush against one side of the source (shared edge), clamped on screen.
    const placement = placeTooltip(source_position, source_width, source_height, panel_width, panel_height);
    const panel_x = placement.x;
    const panel_y = placement.y;

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = tooltip_panel_sprite,
        .screen_position = .{ .x = panel_x, .y = panel_y },
        .width = panel_width,
        .height = panel_height,
        // The tooltip is a passive overlay; it never captures the pointer.
        .blocks_input = false,
    } });

    const content_x = panel_x + tooltip_padding;
    var y = panel_y + tooltip_padding;
    for (wrapped.items, 0..) |wrapped_row, row_index| {
        if (row_index > 0) y += tooltip_row_gap;
        for (wrapped_row.lines) |line| {
            var x = content_x;
            for (line) |span| {
                try elements.append(allocator, .{ .text_label = .{
                    .text = span.text,
                    .screen_position = .{ .x = x, .y = y },
                    .color = span.color,
                    .font_size = wrapped_row.font_size,
                    .bold = span.bold,
                    .italic = span.italic,
                    .blocks_input = false,
                } });
                x += font_metrics.measureSpanWidth(span, wrapped_row.font_size);
            }
            y += lineHeight(wrapped_row.font_size);
        }
        if (wrapped_row.is_header) y += tooltip_header_gap;
    }
}

/// A one-span row, arena-allocated so it outlives the builder.
fn spanRow(allocator: std.mem.Allocator, span: Span) !TooltipRow {
    return allocator.dupe(Span, &.{span});
}

/// Display name for a skill type (e.g. .weapon_skill -> "Weapon Skill").
fn skillTypeName(skill_type: types.SkillType) []const u8 {
    return switch (skill_type) {
        .weapon_skill => "Weapon Skill",
        .spell => "Spell",
        .cantrip => "Cantrip",
        .enchantment => "Enchantment",
        .curse => "Curse",
    };
}

/// Display name for a weapon type (e.g. .sword -> "Sword").
fn weaponTypeName(weapon_type: types.WeaponType) []const u8 {
    return switch (weapon_type) {
        .sword => "Sword",
        .shield => "Shield",
        .spear => "Spear",
        .dagger => "Dagger",
        .axe => "Axe",
        .staff => "Staff",
    };
}

/// Display name for an item type (e.g. .amulet -> "Amulet"). Weapons are
/// handled by `weaponTypeName` (they carry a sub-type).
fn itemTypeName(item: types.Item) []const u8 {
    return switch (item) {
        .weapon => |w| weaponTypeName(w.weapon_type),
        .amulet => "Amulet",
        .coat => "Coat",
        .gloves => "Gloves",
        .pants => "Pants",
        .boots => "Boots",
        .skill_tome => "Skill Tome",
    };
}

/// The player's equipped gear, used as the baseline for tooltip stat
/// comparisons. Mirrors the gear fields on Entity (entity 0 in a level,
/// the hub player outside one). Null fields = empty slot (baseline 0).
pub const EquippedGear = struct {
    main_hand_weapon: ?types.Weapon = null,
    off_hand_weapon: ?types.Weapon = null,
    amulet: ?types.Amulet = null,
    coat: ?types.Coat = null,
    gloves: ?types.Gloves = null,
    pants: ?types.Pants = null,
    boots: ?types.Boots = null,
};

/// Snapshot of an entity's equipped gear for tooltip comparisons.
pub fn equippedGearFromEntity(entity: Entity) EquippedGear {
    return .{
        .main_hand_weapon = entity.main_hand_weapon,
        .off_hand_weapon = entity.off_hand_weapon,
        .amulet = entity.amulet,
        .coat = entity.coat,
        .gloves = entity.gloves,
        .pants = entity.pants,
        .boots = entity.boots,
    };
}

/// Green/red for stat feedback: gear-tooltip comparisons and combat
/// damage/heal numbers (damage red, heals green — including 0 values).
pub const positive_color: Color = .{ .r = 0, .g = 255, .b = 0 };
pub const negative_color: Color = .{ .r = 255, .g = 0, .b = 0 };

/// One comparison number: "+d" green when the hovered item's stat is
/// higher, "-d" red when lower, uncolored "0" when equal.
fn comparisonSpan(
    allocator: std.mem.Allocator,
    item_value: u32,
    equipped_value: u32,
) !Span {
    const difference: i32 = @as(i32, @intCast(item_value)) - @as(i32, @intCast(equipped_value));
    if (difference > 0) {
        return colored(try std.fmt.allocPrint(allocator, "+{d}", .{difference}), positive_color);
    }
    if (difference < 0) {
        return colored(try std.fmt.allocPrint(allocator, "{d}", .{difference}), negative_color);
    }
    return text("0");
}

/// A stat row: plain "Label value" when both baselines are null
/// (comparison suppressed — gear panel, player inspect), "Label value (d)"
/// with one baseline, "Label value (d1, d2)" with both (weapons compare
/// against each equipped hand). A non-null baseline of 0 means the slot is
/// empty (compare against nothing equipped).
fn statRow(
    allocator: std.mem.Allocator,
    label: []const u8,
    value: u32,
    first_baseline: ?u32,
    second_baseline: ?u32,
) !TooltipRow {
    if (first_baseline == null and second_baseline == null) {
        const line = try std.fmt.allocPrint(allocator, "{s} {d}", .{ label, value });
        return spanRow(allocator, text(line));
    }
    var spans: std.ArrayList(Span) = .empty;
    try spans.append(allocator, text(try std.fmt.allocPrint(allocator, "{s} {d} (", .{ label, value })));
    try spans.append(allocator, try comparisonSpan(allocator, value, first_baseline orelse 0));
    if (second_baseline) |baseline| {
        try spans.append(allocator, text(", "));
        try spans.append(allocator, try comparisonSpan(allocator, value, baseline));
    }
    try spans.append(allocator, text(")"));
    return spans.toOwnedSlice(allocator);
}

/// Build an inventory item tooltip. Weapons show name + weapon type +
/// damage (compared against BOTH equipped hands); other gear shows name +
/// item type + each stat (compared against the same slot's equipped item);
/// skill tomes show the skill name + learned/learn-prompt. `learned_skills`
/// is the player's current learned-skill set (for the tome line).
/// `equipped` is the comparison baseline; null suppresses comparisons.
pub fn buildItemTooltip(
    allocator: std.mem.Allocator,
    item: types.Item,
    learned_skills: []const types.SkillId,
    equipped: ?EquippedGear,
) !Tooltip {
    switch (item) {
        .weapon => |weapon| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text(weaponTypeName(weapon.weapon_type))));
            const main_baseline: ?u32 = if (equipped) |e|
                (if (e.main_hand_weapon) |w| w.weapon_damage else 0)
            else
                null;
            const off_baseline: ?u32 = if (equipped) |e|
                (if (e.off_hand_weapon) |w| w.weapon_damage else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Damage", weapon.weapon_damage, main_baseline, off_baseline));
            return .{
                .header = try spanRow(allocator, text(weapon.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .amulet => |amulet| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text("Amulet")));
            const spell_baseline: ?u32 = if (equipped) |e|
                (if (e.amulet) |a| a.spell_damage else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Spell Damage", amulet.spell_damage, spell_baseline, null));
            return .{
                .header = try spanRow(allocator, text(amulet.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .coat => |coat| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text("Coat")));
            const health_baseline: ?u32 = if (equipped) |e|
                (if (e.coat) |c| c.health_bonus else 0)
            else
                null;
            const defense_baseline: ?u32 = if (equipped) |e|
                (if (e.coat) |c| c.defense_bonus else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Health", coat.health_bonus, health_baseline, null));
            try body.append(allocator, try statRow(allocator, "Defense", coat.defense_bonus, defense_baseline, null));
            return .{
                .header = try spanRow(allocator, text(coat.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .gloves => |gloves| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text("Gloves")));
            const health_baseline: ?u32 = if (equipped) |e|
                (if (e.gloves) |g| g.health_bonus else 0)
            else
                null;
            const damage_baseline: ?u32 = if (equipped) |e|
                (if (e.gloves) |g| g.damage_bonus else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Health", gloves.health_bonus, health_baseline, null));
            try body.append(allocator, try statRow(allocator, "Damage", gloves.damage_bonus, damage_baseline, null));
            return .{
                .header = try spanRow(allocator, text(gloves.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .pants => |pants| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text("Pants")));
            const health_baseline: ?u32 = if (equipped) |e|
                (if (e.pants) |p| p.health_bonus else 0)
            else
                null;
            const pickup_baseline: ?u32 = if (equipped) |e|
                (if (e.pants) |p| p.pickup_radius_bonus else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Health", pants.health_bonus, health_baseline, null));
            try body.append(allocator, try statRow(allocator, "Pickup Radius", pants.pickup_radius_bonus, pickup_baseline, null));
            return .{
                .header = try spanRow(allocator, text(pants.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .boots => |boots| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text("Boots")));
            const health_baseline: ?u32 = if (equipped) |e|
                (if (e.boots) |b| b.health_bonus else 0)
            else
                null;
            const speed_baseline: ?u32 = if (equipped) |e|
                (if (e.boots) |b| b.speed_bonus else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Health", boots.health_bonus, health_baseline, null));
            try body.append(allocator, try statRow(allocator, "Speed", boots.speed_bonus, speed_baseline, null));
            return .{
                .header = try spanRow(allocator, text(boots.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .skill_tome => |tome| {
            const definition = lookups.getSkillDefinition(tome.skill) orelse {
                // Unknown skill id (shouldn't happen for shipped content);
                // show a minimal fallback so the slot isn't tooltip-less.
                return .{
                    .header = try spanRow(allocator, text("Skill Tome")),
                    .body = &.{},
                };
            };
            const header_text = try std.fmt.allocPrint(allocator, "{s} Tome", .{definition.name});
            const already_learned = isSkillLearnedIn(learned_skills, tome.skill);
            const body_text = if (already_learned)
                "Already learned"
            else
                try std.fmt.allocPrint(allocator, "Activate to learn {s}", .{definition.name});
            return .{
                .header = try spanRow(allocator, text(header_text)),
                .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(body_text))}),
            };
        },
    }
}

/// Whether `skill_id` is in `learned_skills`. The event_handlers version
/// (`isSkillLearned`) takes the same args; this local copy keeps the tooltip
/// builder self-contained (ui.zig doesn't import event_handlers).
fn isSkillLearnedIn(learned_skills: []const types.SkillId, skill_id: types.SkillId) bool {
    for (learned_skills) |learned| {
        if (learned == skill_id) return true;
    }
    return false;
}

/// Build the standard skill tooltip:
///   name (header)
///   description
///   skill type
///   one "Label N" row per non-null skill variable, in interface order
/// No span styling yet — every row is a single plain span.
pub fn buildSkillTooltip(allocator: std.mem.Allocator, skill: Skill) !Tooltip {
    var body: std.ArrayList(TooltipRow) = .empty;
    try body.append(allocator, try spanRow(allocator, text(skill.description)));
    try body.append(allocator, try spanRow(allocator, text(skillTypeName(skill.skill_type))));

    const variables = [_]struct { label: []const u8, value: ?u32 }{
        .{ .label = "Range", .value = skill.range },
        .{ .label = "Radius", .value = skill.radius },
        .{ .label = "Distance", .value = skill.distance },
        .{ .label = "Duration", .value = skill.skill_duration },
        .{ .label = "Stun Duration", .value = skill.stun_duration },
        .{ .label = "Cooldown", .value = skill.cooldown },
    };
    for (variables) |variable| {
        if (variable.value) |value| {
            const line = try std.fmt.allocPrint(allocator, "{s} {d}", .{ variable.label, value });
            try body.append(allocator, try spanRow(allocator, text(line)));
        }
    }

    return .{
        .header = try spanRow(allocator, text(skill.name)),
        .body = try body.toOwnedSlice(allocator),
    };
}

test "buildSkillTooltip lays out name, description, type, then non-null vars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const slice = @import("skills/slice.zig").skill;
    const tooltip = try buildSkillTooltip(arena.allocator(), slice);
    try std.testing.expectEqualStrings("Slice", tooltip.header.?[0].text);
    // description, Weapon Skill, Range 1 (other vars are null)
    try std.testing.expectEqual(@as(usize, 3), tooltip.body.len);
    try std.testing.expectEqualStrings("Attack target, dealing 1.5x damage if they have less than half health", tooltip.body[0][0].text);
    try std.testing.expectEqualStrings("Weapon Skill", tooltip.body[1][0].text);
    try std.testing.expectEqualStrings("Range 1", tooltip.body[2][0].text);
}

test "buildItemTooltip: weapon shows name, type, damage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const weapon = types.Item{ .weapon = .{ .name = "Iron Sword", .weapon_type = .sword, .weapon_damage = 5 } };
    const tooltip = try buildItemTooltip(arena.allocator(), weapon, &.{}, null);
    try std.testing.expectEqualStrings("Iron Sword", tooltip.header.?[0].text);
    try std.testing.expectEqual(@as(usize, 2), tooltip.body.len);
    try std.testing.expectEqualStrings("Sword", tooltip.body[0][0].text);
    try std.testing.expectEqualStrings("Damage 5", tooltip.body[1][0].text);
}

test "buildItemTooltip: coat shows name, type, health, defense" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const coat = types.Item{ .coat = .{ .name = "Leather Coat", .health_bonus = 3, .defense_bonus = 2 } };
    const tooltip = try buildItemTooltip(arena.allocator(), coat, &.{}, null);
    try std.testing.expectEqualStrings("Leather Coat", tooltip.header.?[0].text);
    try std.testing.expectEqual(@as(usize, 3), tooltip.body.len);
    try std.testing.expectEqualStrings("Coat", tooltip.body[0][0].text);
    try std.testing.expectEqualStrings("Health 3", tooltip.body[1][0].text);
    try std.testing.expectEqualStrings("Defense 2", tooltip.body[2][0].text);
}

test "buildItemTooltip: skill tome not learned shows learn prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tome = types.Item{ .skill_tome = .{ .skill = .slice, .value = 5 } };
    const learned = [_]types.SkillId{};
    const tooltip = try buildItemTooltip(arena.allocator(), tome, &learned, null);
    try std.testing.expectEqualStrings("Slice Tome", tooltip.header.?[0].text);
    try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
    try std.testing.expectEqualStrings("Activate to learn Slice", tooltip.body[0][0].text);
}

test "buildItemTooltip: skill tome already learned shows learned line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tome = types.Item{ .skill_tome = .{ .skill = .slice, .value = 5 } };
    const learned = [_]types.SkillId{.slice};
    const tooltip = try buildItemTooltip(arena.allocator(), tome, &learned, null);
    try std.testing.expectEqualStrings("Slice Tome", tooltip.header.?[0].text);
    try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
    try std.testing.expectEqualStrings("Already learned", tooltip.body[0][0].text);
}

test "buildItemTooltip: weapon compares damage against both equipped hands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const weapon = types.Item{ .weapon = .{ .name = "Iron Sword", .weapon_type = .sword, .weapon_damage = 5 } };
    const equipped = EquippedGear{
        .main_hand_weapon = .{ .name = "Old Sword", .weapon_type = .sword, .weapon_damage = 4 },
        .off_hand_weapon = .{ .name = "Old Dagger", .weapon_type = .dagger, .weapon_damage = 5 },
    };
    const tooltip = try buildItemTooltip(arena.allocator(), weapon, &.{}, equipped);
    // Row spans: "Damage 5 (" | "+1" green | ", " | "0" uncolored | ")"
    const row = tooltip.body[1];
    try std.testing.expectEqual(@as(usize, 5), row.len);
    try std.testing.expectEqualStrings("Damage 5 (", row[0].text);
    try std.testing.expectEqualStrings("+1", row[1].text);
    try std.testing.expectEqual(positive_color, row[1].color);
    try std.testing.expectEqualStrings(", ", row[2].text);
    try std.testing.expectEqualStrings("0", row[3].text);
    try std.testing.expectEqual(default_tint, row[3].color);
    try std.testing.expectEqualStrings(")", row[4].text);
}

test "buildItemTooltip: weapon negative comparison and empty off hand baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const weapon = types.Item{ .weapon = .{ .name = "Iron Sword", .weapon_type = .sword, .weapon_damage = 5 } };
    // Main hand does 7 (worse: -2), off hand empty (better than 0: +5).
    const equipped = EquippedGear{
        .main_hand_weapon = .{ .name = "Big Axe", .weapon_type = .axe, .weapon_damage = 7 },
    };
    const tooltip = try buildItemTooltip(arena.allocator(), weapon, &.{}, equipped);
    const row = tooltip.body[1];
    try std.testing.expectEqualStrings("-2", row[1].text);
    try std.testing.expectEqual(negative_color, row[1].color);
    try std.testing.expectEqualStrings("+5", row[3].text);
    try std.testing.expectEqual(positive_color, row[3].color);
}

test "buildItemTooltip: coat compares each stat against the equipped coat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const coat = types.Item{ .coat = .{ .name = "Leather Coat", .health_bonus = 3, .defense_bonus = 2 } };
    // Equipped coat: health 4 (worse: -1), defense 2 (equal: 0). Empty
    // slots elsewhere must not matter — only the same slot's item is read.
    const equipped = EquippedGear{
        .coat = .{ .name = "Old Coat", .health_bonus = 4, .defense_bonus = 2 },
    };
    const tooltip = try buildItemTooltip(arena.allocator(), coat, &.{}, equipped);
    const health_row = tooltip.body[1];
    try std.testing.expectEqual(@as(usize, 3), health_row.len);
    try std.testing.expectEqualStrings("Health 3 (", health_row[0].text);
    try std.testing.expectEqualStrings("-1", health_row[1].text);
    try std.testing.expectEqual(negative_color, health_row[1].color);
    try std.testing.expectEqualStrings(")", health_row[2].text);
    const defense_row = tooltip.body[2];
    try std.testing.expectEqualStrings("0", defense_row[1].text);
    try std.testing.expectEqual(default_tint, defense_row[1].color);
}

test "buildItemTooltip: empty equipped slot compares against zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const boots = types.Item{ .boots = .{ .name = "Boots", .health_bonus = 2, .speed_bonus = 1 } };
    const tooltip = try buildItemTooltip(arena.allocator(), boots, &.{}, EquippedGear{});
    const speed_row = tooltip.body[2];
    try std.testing.expectEqualStrings("+1", speed_row[1].text);
    try std.testing.expectEqual(positive_color, speed_row[1].color);
}


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

// ============================================================
// Panel content builders — called by the view function
// ============================================================

// Builders append UiElements into a shared list in back-to-front draw
// order. The view function calls each relevant builder based on game
// state; the flat list is what the renderer walks. pub: main.zig's
// focus-on-click integration test builds elements directly.
pub const UiElementList = std.ArrayList(UiElement);

/// The player entity is index 0 in a level, or the dedicated hub player.
pub fn playerEntity(game_state: *const GameState) ?Entity {
    if (game_state.level) |level| {
        if (level.entities.len > 0) return level.entities[0];
        return null;
    }
    if (game_state.hub) |hub| return hub.player;
    return null;
}

const cooldown_font_size: i32 = 96;
const overlay_font_size: i32 = 64;

/// Emit a centered integer label inside `cell` (cooldowns, momentum,
/// effect durations). Centered on the MEASURED text width via `font_metrics`
/// so multi-digit numbers sit truly centered; vertical centering uses the
/// `font_size` glyph cell (raylib draws from the top of that cell).
fn emitCenteredNumber(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    value: u32,
    font_size: i32,
) !void {
    const label = try std.fmt.allocPrint(allocator, "{d}", .{value});
    // Center on the MEASURED text width (not a font_size square) so multi-digit
    // numbers sit truly centered. Vertical centering uses the `font_size` glyph
    // cell (not `lineHeight`) — raylib draws a glyph from the top of a
    // font_size-tall cell, so centering that cell puts the visual mass on the
    // button's center; centering the taller lineHeight box would sit text high.
    const label_width = font_metrics.measureSpanWidth(text(label), font_size);
    const label_box = cell.placeCenter(label_width, font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = label_box.position(),
        .font_size = font_size,
        // Outlined for readability over varied icon art.
        .outlined = true,
        // Sits on top of its parent icon/button; let its tooltip win the hover.
        .blocks_input = false,
    } });
}

/// Emit a number label in the BOTTOM-RIGHT corner of `cell`, outlined for
/// readability. Mirrors the material-count placement (`material_count_font_size`
/// + `material_count_inset`) so effect-duration numbers read like the
/// inventory material counts. Used for active-effect duration overlays.
fn emitCornerNumber(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    value: u32,
) !void {
    const label = try std.fmt.allocPrint(allocator, "{d}", .{value});
    const label_width = font_metrics.measureSpanWidth(text(label), material_count_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = .{
            .x = cell.x + cell.width - label_width - material_count_inset,
            .y = cell.y + cell.height - material_count_font_size - material_count_inset,
        },
        .font_size = material_count_font_size,
        .outlined = true,
        .blocks_input = false,
    } });
}

/// Sprite id of the reusable button background — a rounded panel drawn
/// under an icon so the coloring framework can tint background and icon
/// independently.
pub const button_background_sprite_id: []const u8 = "ui/button_background";

/// Emit a middle-panel header: a title `text_label` on the left (vertically
/// centered in the `header_height` strip) + a close `button` flush in the
/// panel's top-right corner. Returns the content bounds — the area below the
/// header where the panel body lives. The close button carries the panel's
/// toggle action (firing it while open closes the panel); the view() hover
/// pass sets `highlighted` on the button under the pointer, so the renderer
/// rings it with the theme lightest. Callers emit the 9-slice panel
/// background first, then this, then position body elements within the
/// returned content bounds.
fn emitPanelHeader(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    bounds: Rectangle,
    title: []const u8,
    close_action: Action,
) !Rectangle {
    const origin = bounds.position();
    // raylib draws a glyph from the top of a font_size-tall cell, so offset
    // by (header_height − font_size)/2 to center the visual mass.
    const text_y = origin.y + @divFloor(middle_panel_header_height - middle_panel_header_font_size, 2);
    try elements.append(allocator, .{ .text_label = .{
        .text = title,
        .screen_position = .{ .x = origin.x + ui_gap, .y = text_y },
        .font_size = middle_panel_header_font_size,
        .blocks_input = false,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = close_button_sprite_id,
        .screen_position = .{
            .x = origin.x + bounds.width - close_button_size,
            .y = origin.y,
        },
        .width = close_button_size,
        .height = close_button_size,
        .action = close_action,
    } });
    return .{
        .x = bounds.x,
        .y = bounds.y + middle_panel_header_height,
        .width = bounds.width,
        .height = bounds.height - middle_panel_header_height,
    };
}

/// Emit a layered icon button: a background sprite (carries the action,
/// tooltip, and hit-test) with the icon drawn on top. The icon passes hover
/// through to the background so the whole button is one target. Callers pass
/// the background id so different button styles (bottom-bar frame, skill
/// frame) reuse the same layering.
fn emitIconButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    background_sprite_id: []const u8,
    icon_sprite_id: []const u8,
    action: Action,
    tooltip: ?Tooltip,
    background_color: Color,
    icon_color: Color,
    highlighted: bool,
    /// Drag ref, if this button is also a drag source/drop target.
    ref: ?SlotRef,
) !void {
    try elements.append(allocator, .{ .button = .{
        .sprite_id = background_sprite_id,
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = action,
        .color = background_color,
        .tooltip = tooltip,
        .highlighted = highlighted,
        .ref = ref,
    } });
    try elements.append(allocator, .{ .image = .{
        .sprite_id = icon_sprite_id,
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = icon_color,
        // Sits on top of the background; let the button win the hit-test.
        .blocks_input = false,
    } });
}

/// Emit a panel-backed button: a 9-slice panel background, a spriteless
/// Button over it (owns the action + hit-test + optional tooltip), and a
/// centered text label on top. Used for text buttons (main menu, settings,
/// dialog choices).
fn emitPanelButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    label: []const u8,
    font_size: i32,
    action: Action,
    button_color: Color,
    tooltip: ?Tooltip,
) !void {
    // Button panels take an explicit tint (player gradient index 5) so they
    // read as buttons against background panels, which stay theme `darkest`.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = action,
        .tooltip = tooltip,
    } });
    // Centered label. Horizontal centering uses the measurement seam;
    // vertical centering uses the `font_size` glyph cell (not `lineHeight`) —
    // raylib draws from the top of a font_size-tall cell, so centering that
    // cell (not the taller lineHeight box) puts the visual mass on the
    // button's center.
    const label_width = font_metrics.measureSpanWidth(text(label), font_size);
    const label_box = cell.placeCenter(label_width, font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = label_box.position(),
        .font_size = font_size,
        // Sits on top of the button; let the button win the hit-test.
        .blocks_input = false,
    } });
}

/// Map a skill bar slot (1-8) to its input Action, so clicking a skill
/// button triggers the same path as the keybind.
fn skillSlotAction(slot: u8) Action {
    return switch (slot) {
        1 => .skill_slot_1,
        2 => .skill_slot_2,
        3 => .skill_slot_3,
        4 => .skill_slot_4,
        5 => .skill_slot_5,
        6 => .skill_slot_6,
        7 => .skill_slot_7,
        8 => .skill_slot_8,
        else => unreachable,
    };
}

/// Inverse of `skillSlotAction`: map a skill-slot Action back to its slot
/// number (1-8), or null for any other action. Used by `view()` to detect
/// when the pointer hovers a skill button and resolve which skill it is.
pub fn actionSkillSlot(action: Action) ?u8 {
    return switch (action) {
        .skill_slot_1 => 1,
        .skill_slot_2 => 2,
        .skill_slot_3 => 3,
        .skill_slot_4 => 4,
        .skill_slot_5 => 5,
        .skill_slot_6 => 6,
        .skill_slot_7 => 7,
        .skill_slot_8 => 8,
        else => null,
    };
}

/// Emit one skill button into `cell`. If the slot resolves to a skill,
/// draws the icon button (with tooltip) plus a cooldown overlay and
/// remaining-turns number when on cooldown. Empty slots (e.g. a missing
/// off-hand weapon) draw an empty-slot placeholder so the row keeps its
/// width.
fn emitSkillButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    slot: u8,
    player: Entity,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    background_color: Color,
    icon_color: Color,
    prepared_skill: ?SkillId,
    /// Tint for the cooldown overlay (the skill-button sprite washed at 50%
    /// alpha). Caller passes the active theme's darkest color.
    cooldown_overlay_color: Color,
    /// Drag ref for this slot, if it's a reorderable utility slot. Null for
    /// weapon-skill slots (1-3, derived from the equipped weapon — not
    /// draggable). Set by the caller for utility slots 4-8.
    drag_ref: ?SlotRef,
    /// The slot currently being dragged from, if any. The source slot renders
    /// empty (diamond) so the skill reads as "in flight" (shown only as the
    /// ghost following the pointer).
    drag_source: ?SlotRef,
) !void {
    const skill_id = player.skillInSlot(slot, weapon_type_definitions);
    const definition = if (skill_id) |id| lookups.getSkillDefinition(id) else null;
    const is_drag_source = blk: {
        // A ref-less slot (weapon skill) can never be the drag source.
        const ref = drag_ref orelse break :blk false;
        const src = drag_source orelse break :blk false;
        break :blk src.eql(ref);
    };

    // Empty, or the drag source (skill is "in flight"): render the diamond
    // marker. For a reorderable utility slot this is a `.slot` carrying the
    // ref so it stays a DROP TARGET (an empty slot can receive a drop). For
    // a weapon slot or the drag source it's a plain `.image` (inert — no
    // ref, no action; a same-slot drop is already a no-op via the guard).
    if (skill_id == null or definition == null or is_drag_source) {
        if (drag_ref) |ref| {
            try elements.append(allocator, .{ .slot = .{
                .screen_position = cell.position(),
                .size = cell.width,
                .icon_sprite_id = "ui/skill_slot_empty",
                .icon_color = background_color,
                .ref = ref,
            } });
        } else {
            try elements.append(allocator, .{ .image = .{
                .sprite_id = "ui/skill_slot_empty",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = background_color,
            } });
        }
        return;
    }

    // Filled slot: skill frame background + the skill's icon on top. The icon
    // id mirrors the SkillId tag name (assets/skills/<tag>.png). Highlighted
    // when this slot holds the prepared skill awaiting target confirmation.
    const is_prepared = prepared_skill != null and prepared_skill.? == skill_id.?;
    const icon_sprite_id = skillIconSpriteId(skill_id.?);
    try emitIconButton(
        elements,
        allocator,
        cell,
        "ui/skill_button",
        icon_sprite_id,
        skillSlotAction(slot),
        try buildSkillTooltip(allocator, definition.?),
        background_color,
        icon_color,
        is_prepared,
        drag_ref,
    );

    const cooldown = player.skill_cooldowns.get(skill_id.?);
    if (cooldown > 0) {
        try elements.append(allocator, .{ .image = .{
            // Reuse the skill-button frame as a translucent wash so the icon
            // reads as dimmed/locked. Tinted darkest theme color at 50% alpha.
            .sprite_id = "ui/skill_button",
            .screen_position = cell.position(),
            .width = cell.width,
            .height = cell.height,
            .color = cooldown_overlay_color,
            .alpha = 128,
            // Overlay on the skill button — pass hover through to the button.
            .blocks_input = false,
        } });
        try emitCenteredNumber(elements, allocator, font_metrics, cell, cooldown, cooldown_font_size);
    }
}

/// The bottom bar: one horizontally-centered row anchored to the bottom
/// of `screen`, laid out left-to-right as
///   inventory, gear, skills, health, weapon-skills, swap, utility-skills, skip
/// with `ui_gap` between top-level items. The two skill sub-bars pack
/// their buttons flush (no gap). Skip appears only in levels. The bar has
/// no background of its own — it is purely a layout region.
pub fn buildBottomBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    game_state: *const GameState,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    active_theme: types.ActiveColorTheme,
    player_color_index: u32,
    /// The slot currently being dragged from, if any. Suppresses the source
    /// skill's render so it reads as "in flight". Passed to `emitSkillButton`.
    drag_source: ?SlotRef,
) !void {
    const player = playerEntity(game_state) orelse return;
    const in_level = game_state.screen == .level;
    // The skill awaiting target confirmation (player_prepare_skill set it;
    // confirm/cancel/clear_prepared_skill clears it). Null in a hub (no
    // level) or when no skill is prepared. Used to highlight its slot.
    const prepared_skill: ?SkillId = if (in_level) blk: {
        if (game_state.level) |level| break :blk level.prepared_skill;
        break :blk null;
    } else null;

    // Player-gradient colors for the bottom bar elements.
    const p = active_theme.player_gradient.colors;
    const c_btn = p[@min(@as(u32, 4), types.gradient_color_count - 1)]; // inventory/gear/skills: 4
    const c_globe_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)]; // health bg: 5
    const c_globe_fill = p[@min(@as(u32, 1), types.gradient_color_count - 1)]; // health fill: 1
    const c_border = p[@min(@as(u32, 3), types.gradient_color_count - 1)]; // border/skill bg/skip bg/turn/swap/momentum: 3
    const c_icon = p[@min(@as(u32, 1), types.gradient_color_count - 1)]; // skill/skip icon: 1
    const c_skip_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)]; // skip bg: 5
    _ = player_color_index; // UI uses fixed indices, not the player's chosen index

    const weapon_skills_width = 3 * slot_size;
    const utility_skills_width = 5 * slot_size;

    // Total content width, to size and center the row.
    var top_level_count: i32 = 7; // inventory,gear,skills,health,wpn,swap,util
    // The health globe cell is wider than slot_size to fit its border at
    // native size (297 vs 256) — the border is authored wider than a slot, so
    // the cell matches it rather than letting the border overhang into the
    // gaps (which crowded the neighbors — see health_globe_border_width).
    var content_width = slot_size * 3 // inventory, gear, skills
        + health_globe_border_width // health (wider than a slot)
        + weapon_skills_width + swap_button_size + utility_skills_width;
    if (in_level) {
        top_level_count += 1;
        content_width += slot_size;
    }
    content_width += ui_gap * (top_level_count - 1);

    const bar = screen.placeBottomCenter(content_width, bottom_bar_height, 0);
    var row = Row.init(bar.position(), bottom_bar_height, ui_gap);

    // Panel toggle buttons.
    const toggles = [_]struct { sprite: []const u8, action: Action, label: []const u8 }{
        .{ .sprite = "ui/icon_inventory", .action = .toggle_inventory, .label = "Inventory" },
        .{ .sprite = "ui/icon_gear", .action = .toggle_gear, .label = "Gear" },
        .{ .sprite = "ui/icon_skills", .action = .toggle_skills, .label = "Skills" },
    };
    for (toggles) |toggle| {
        try elements.append(allocator, .{ .button = .{
            .sprite_id = toggle.sprite,
            .screen_position = row.next(slot_size).position(),
            .action = toggle.action,
            .color = c_btn,
            .tooltip = .{ .header = try spanRow(allocator, text(toggle.label)) },
        } });
    }

    // Health globe (vertical fill).
    const health_cell = row.next(health_globe_border_width);
    // One flat white ball serves as both background and fill; tint reads
    // them as depleted vs current health. Rendered at the ball's native
    // (downscaled) size, centered in the cell so it sits inside the border.
    const ball = health_cell.placeCenter(health_globe_ball_size, health_globe_ball_size);
    try elements.append(allocator, .{ .fill_sprite = .{
        .background_sprite_id = "ui/health_globe",
        .fill_sprite_id = "ui/health_globe",
        .screen_position = ball.position(),
        .width = health_globe_ball_size,
        .height = health_globe_ball_size,
        .fill_fraction = if (player.getEffectiveMaxHealth() == 0)
            0
        else
            @as(f32, @floatFromInt(player.current_health)) /
                @as(f32, @floatFromInt(player.getEffectiveMaxHealth())),
        .fill_direction = .up,
        .background_color = c_globe_bg,
        .fill_color = c_globe_fill,
        .tooltip = .{ .header = try spanRow(allocator, text(
            try std.fmt.allocPrint(allocator, "{d} / {d}", .{ player.current_health, player.getEffectiveMaxHealth() }),
        )) },
    } });
    // Stylized border drawn over the globe at its native size, centered on the
    // cell (co-registered with the ball). Slightly wider than the cell, so it
    // overhangs horizontally. Hover passes through to the globe.
    const border = health_cell.placeCenter(health_globe_border_width, health_globe_border_height);
    try elements.append(allocator, .{ .image = .{
        .sprite_id = "ui/health_globe_border",
        .screen_position = border.position(),
        .width = health_globe_border_width,
        .height = health_globe_border_height,
        .color = c_border,
        .blocks_input = false,
    } });

    // Current-health number centered on the ball, outlined for readability
    // over the fill. Passes hover through to the globe (the tooltip shows
    // `current / max`). Drawn AFTER the border so it sits on top of both.
    {
        const health_text = try std.fmt.allocPrint(allocator, "{d}", .{player.current_health});
        const label_width = font_metrics.measureSpanWidth(text(health_text), overlay_font_size);
        const label_box = ball.placeCenter(label_width, overlay_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = health_text,
            .screen_position = label_box.position(),
            .font_size = overlay_font_size,
            .outlined = true,
            .blocks_input = false,
        } });
    }

    // Weapon skills sub-bar (slots 1-3, packed flush).
    const weapon_sub_bar = row.next(weapon_skills_width);
    {
        var inner = Row.init(weapon_sub_bar.position(), bottom_bar_height, 0);
        var slot: u8 = 1;
        while (slot <= 3) : (slot += 1) {
            // Weapon-skill slots are derived from the equipped weapon — not
            // reorderable, so no drag ref.
            try emitSkillButton(elements, allocator, font_metrics, inner.next(slot_size), slot, player, weapon_type_definitions, c_border, c_icon, prepared_skill, active_theme.darkest, null, drag_source);
        }
    }

    // Weapon swap button (128, centered vertically in its cell).
    {
        const cell = row.next(swap_button_size);
        try elements.append(allocator, .{ .button = .{
            .sprite_id = "ui/icon_swap",
            .screen_position = cell.placeCenter(swap_button_size, swap_button_size).position(),
            .width = swap_button_size,
            .height = swap_button_size,
            .action = .swap_weapons,
            .color = c_border,
            .tooltip = .{ .header = try spanRow(allocator, text("Swap weapons")) },
        } });
    }

    // Utility skills sub-bar (slots 4-8, packed flush).
    const utility_sub_bar = row.next(utility_skills_width);
    {
        var inner = Row.init(utility_sub_bar.position(), bottom_bar_height, 0);
        var slot: u8 = 4;
        while (slot <= 8) : (slot += 1) {
            // Utility-skill slots are reorderable by drag: ref = skill_bar
            // index 0-4 (slot 4 → index 0, ..., slot 8 → index 4).
            try emitSkillButton(elements, allocator, font_metrics, inner.next(slot_size), slot, player, weapon_type_definitions, c_border, c_icon, prepared_skill, active_theme.darkest, .{ .skill_bar = @as(u32, slot - 4) }, drag_source);
        }
    }

    // Skip button — levels only.
    var skip_cell: ?Rectangle = null;
    if (in_level) {
        const cell = row.next(slot_size);
        skip_cell = cell;
        try emitIconButton(
            elements,
            allocator,
            cell,
            button_background_sprite_id,
            "ui/icon_skip",
            .skip,
            .{ .header = try spanRow(allocator, text("Skip turn step")) },
            c_skip_bg,
            c_icon,
            false,
            null,
        );
    }

    // --- Indicators above the bar (16px gap, 128×128) ---

    // Momentum: centered above the health globe (levels only).
    if (in_level) {
        const momentum_cell = health_cell
            .placeTopCenter(small_icon_size, small_icon_size, 0)
            .translate(0, -(ui_gap + small_icon_size));
        try elements.append(allocator, .{ .image = .{
            .sprite_id = "ui/momentum",
            .screen_position = momentum_cell.position(),
            .width = small_icon_size,
            .height = small_icon_size,
            .color = c_border,
            .tooltip = .{
                .header = try spanRow(allocator, text(
                    try std.fmt.allocPrint(allocator, "{d} momentum", .{player.momentum}),
                )),
                .body = try allocator.dupe(TooltipRow, &.{
                    try spanRow(allocator, text(
                        try std.fmt.allocPrint(allocator, "+{d} damage", .{player.getConvertedMomentum()}),
                    )),
                }),
            },
        } });
        try emitCenteredNumber(elements, allocator, font_metrics, momentum_cell, player.momentum, overlay_font_size);
    }

    // Active effects: flush 128 grid spanning the skill bars, filling
    // right-to-left (oldest rightmost) then wrapping upward.
    if (player.active_effects.len > 0) {
        const span_right = utility_sub_bar.right();
        const span_width = utility_sub_bar.right() - weapon_sub_bar.x;
        const columns = @max(1, @divFloor(span_width, small_icon_size));
        const bottom_row_top = bar.y - ui_gap - small_icon_size;
        for (player.active_effects, 0..) |effect, index| {
            const ordinal: i32 = @intCast(index);
            const column = @mod(ordinal, columns);
            const grid_row = @divFloor(ordinal, columns);
            const cell: Rectangle = .{
                .x = span_right - (column + 1) * small_icon_size,
                .y = bottom_row_top - grid_row * small_icon_size,
                .width = small_icon_size,
                .height = small_icon_size,
            };
            const definition = lookups.getEffectDefinition(effect.effect_id);
            try elements.append(allocator, .{ .image = .{
                .sprite_id = effectIconSpriteId(effect.effect_id, definition),
                .screen_position = cell.position(),
                .width = small_icon_size,
                .height = small_icon_size,
                .color = c_icon,
                .tooltip = .{
                    .header = try spanRow(allocator, text(definition.name)),
                    .body = try allocator.dupe(TooltipRow, &.{
                        try spanRow(allocator, text(definition.description)),
                        try spanRow(allocator, text(
                            try std.fmt.allocPrint(allocator, "Current duration {d}", .{effect.duration}),
                        )),
                    }),
                },
            } });
            try emitCornerNumber(elements, allocator, font_metrics, cell, effect.duration);
        }
    }

    // Turn-step icons: move + attack above the skip button (levels only),
    // combined width equal to the skip button. The current phase is
    // highlighted; neither is highlighted during enemy turns.
    if (skip_cell) |skip| {
        const turn_phase = if (game_state.level) |level| level.turn_phase else null;
        const strip: Rectangle = .{
            .x = skip.x,
            .y = bar.y - ui_gap - small_icon_size,
            .width = skip.width,
            .height = small_icon_size,
        };
        var inner = Row.init(strip.position(), small_icon_size, 0);
        const move_cell = inner.next(small_icon_size);
        const attack_cell = inner.next(small_icon_size);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = "ui/turn_move",
            .screen_position = move_cell.position(),
            .width = small_icon_size,
            .height = small_icon_size,
            .color = c_border,
            .highlighted = turn_phase == .player_move,
            .tooltip = .{ .header = try spanRow(allocator, text("Move step")) },
        } });
        try elements.append(allocator, .{ .image = .{
            .sprite_id = "ui/turn_attack",
            .screen_position = attack_cell.position(),
            .width = small_icon_size,
            .height = small_icon_size,
            .color = c_border,
            .highlighted = turn_phase == .player_attack,
            .tooltip = .{ .header = try spanRow(allocator, text("Attack step")) },
        } });
    }
}

// ============================================================
// Editor bottom bar (tool palette)
// ============================================================

/// All entity sprites share one 512x640 frame (view.zig `entity_frame_*`).
/// Duplicated here because ui.zig can't import view.zig (view imports ui).
const editor_entity_frame_width: i32 = 512;
const editor_entity_frame_height: i32 = 640;

/// `world/tile_highlight.png` spritesheet: 4 frames of 256x256 in a
/// horizontal strip (frame N occupies x = N*256..N*256+256). The Select
/// tool graphic is frame 0.
const tile_highlight_frame_size: i32 = 256;

/// Font size for the editor palette group headers ("Enemies", …).
const editor_group_header_font_size: i32 = 64;

/// Height of the group header buttons and the editor "+" cells: 128.
/// Expanded groups' headers sit in a strip above the bar; collapsed
/// groups' headers + "+" sit flush against the bottom of the screen
/// (see `buildEditorBottomBar`).
const editor_header_strip_height: i32 = 128;

/// Side length of the square ui/panel "+" cells (palette group add-new,
/// level-tab add-level).
const editor_plus_size: i32 = 128;

/// Maximum type cells a palette group shows at once. Groups with more
/// types scroll horizontally (wheel over the group shifts the window;
/// see `UiState.editor_palette_scroll`).
pub const editor_palette_max_tools: usize = 8;

/// A palette group's type count: 0 = Enemies, 1 = Decorations, 2 = Ground
/// Items. Shared between the builder's window math and the wheel routing's
/// emission-order segmentation.
pub fn editorPaletteGroupSize(editor: types.Editor, group_index: usize) usize {
    return switch (group_index) {
        0 => editor.entity_types.len,
        1 => editor.decoration_types.len,
        else => editor.item_types.len,
    };
}

/// Which editor palette group's tool cells contain `position`, if any.
/// Tool cells are Buttons whose sprite is `ui/button_background` (the
/// header buttons are spriteless over panels and the "+" cells are
/// panels — neither matches), so detection matches those in the
/// bottom-bar band and
/// segments the emission order: 2 fixed tools, then per EXPANDED group
/// `min(size, max_tools)` type cells (collapsed groups contribute none).
/// Valid only on the editor screen; callers gate on it.
pub fn editorPaletteGroupAt(
    editor: types.Editor,
    collapsed: [3]bool,
    ui_elements: []const UiElement,
    position: ScreenPosition,
) ?usize {
    if (position.y < types.reference_height - bottom_bar_height) return null;
    var cell_index: usize = 0;
    for (ui_elements) |element| switch (element) {
        .button => |button| {
            const sprite_id = button.sprite_id orelse continue;
            if (!std.mem.eql(u8, sprite_id, button_background_sprite_id)) continue;
            if (button.screen_position.y < types.reference_height - bottom_bar_height) continue;
            defer cell_index += 1;
            const group = editorPaletteGroupOfCell(editor, collapsed, cell_index) orelse continue;
            const cell: Rectangle = .{
                .x = button.screen_position.x,
                .y = button.screen_position.y,
                .width = button.width,
                .height = button.height,
            };
            if (cell.contains(position)) return group;
        },
        else => {},
    };
    return null;
}

/// Map a flat tool-cell index (bottom-bar emission order) to its palette
/// group. The first 2 cells are the fixed tools (Select, Tile); each
/// EXPANDED group then contributes `min(size, max_tools)` type cells
/// (collapsed groups contribute none).
fn editorPaletteGroupOfCell(editor: types.Editor, collapsed: [3]bool, cell_index: usize) ?usize {
    var index = cell_index;
    if (index < 2) return null;
    index -= 2;
    for (0..3) |group_index| {
        if (collapsed[group_index]) continue;
        const segment = @min(
            editorPaletteGroupSize(editor, group_index),
            editor_palette_max_tools,
        );
        if (index < segment) return group_index;
        index -= segment;
    }
    return null;
}

/// Largest aspect-preserving rectangle that fits inside `cell`, centered.
/// Non-positive sprite dimensions (an unresolvable/missing sprite) fall
/// back to the full cell so the renderer's missing-art magenta still shows
/// at cell size.
fn scaleToFit(cell: Rectangle, sprite_width: i32, sprite_height: i32) Rectangle {
    if (sprite_width <= 0 or sprite_height <= 0) return cell;
    const scale = @min(
        @as(f32, @floatFromInt(cell.width)) / @as(f32, @floatFromInt(sprite_width)),
        @as(f32, @floatFromInt(cell.height)) / @as(f32, @floatFromInt(sprite_height)),
    );
    const fitted_width: i32 = @intFromFloat(@as(f32, @floatFromInt(sprite_width)) * scale);
    const fitted_height: i32 = @intFromFloat(@as(f32, @floatFromInt(sprite_height)) * scale);
    return cell.placeCenter(fitted_width, fitted_height);
}

/// Emit one editor tool cell: a `ui/button_background` Button tinted as a
/// button (player gradient index 5) carrying the tool's action + payload +
/// tooltip + input, with the tool's graphic scaled to fit (aspect-preserved,
/// centered, then multiplied by `graphic_scale`) on top — the icon passes
/// hover through to the button. Selecting the tool makes it active; the
/// ACTIVE tool's button is highlighted (lightest edge outline), as is the
/// hovered one via the generic hover pass in `view()`.
fn emitEditorToolCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    tool: types.EditorToolId,
    graphic_sprite_id: []const u8,
    graphic_source_rectangle: ?Rectangle,
    graphic_width: i32,
    graphic_height: i32,
    graphic_scale: f32,
    graphic_color: Color,
    button_color: Color,
    tooltip_header: []const u8,
    active_tool: types.EditorToolId,
) !void {
    try elements.append(allocator, .{ .button = .{
        .sprite_id = button_background_sprite_id,
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = .select_editor_tool,
        .editor_tool = tool,
        .color = button_color,
        .highlighted = std.meta.eql(tool, active_tool),
        .tooltip = .{ .header = try spanRow(allocator, text(tooltip_header)) },
    } });
    // Fit the graphic at native dims, then shrink the fitted rect by
    // `graphic_scale`. (Scaling the INPUT dims is a no-op — scaleToFit
    // grows or shrinks to fill the cell, so the aspect ratio erases any
    // uniform pre-scale.)
    const fitted_full = scaleToFit(cell, graphic_width, graphic_height);
    const fitted_width: i32 = @intFromFloat(@as(f32, @floatFromInt(fitted_full.width)) * graphic_scale);
    const fitted_height: i32 = @intFromFloat(@as(f32, @floatFromInt(fitted_full.height)) * graphic_scale);
    const fitted = cell.placeCenter(fitted_width, fitted_height);
    try elements.append(allocator, .{ .image = .{
        .sprite_id = graphic_sprite_id,
        .screen_position = fitted.position(),
        .width = fitted.width,
        .height = fitted.height,
        .color = graphic_color,
        .source_rectangle = graphic_source_rectangle,
        .blocks_input = false,
    } });
}

/// Editor top row: level tabs, emitted to the RIGHT of the top bar's
/// options + undo buttons (those come from `buildTopBar` — same locations
/// as levels/hubs). One 128-high panel-backed button per level (the
/// palette group-header visual class), labeled with the level's name or
/// "Level N" if unnamed. The ACTIVE tab is highlighted (lightest edge
/// outline — the same path as tool cells); clicking switches the active
/// level (payload = level index → `.select_editor_level` →
/// `player_set_editor_level`, which rides the undo timeline). To the right
/// of the last tab sits a square panel "+" (add level — inert until
/// `editor_add_level`'s handler + click routing land). See DESIGN →
/// Architecture → Level Editor → Editor UI layout (tabs).
pub fn buildEditorLevelTabs(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];

    // Tabs start right of the top bar's two cells (options + undo joined
    // by ui_gap in buildTopBar's Row; one more gap separates the tabs) and
    // sit flush against the top of the screen.
    var x = 2 * (slot_size + ui_gap);
    const y: i32 = 0;

    for (editor.levels, 0..) |level, index| {
        const label = if (level.name.len > 0)
            level.name
        else
            try std.fmt.allocPrint(allocator, "Level {d}", .{index + 1});
        const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
        // Width = label + side padding, never narrower than the tab height
        // (a square floor so short labels don't squish the panel).
        const width = @max(label_width + 2 * ui_gap, editor_header_strip_height);
        const cell: Rectangle = .{
            .x = x,
            .y = y,
            .width = width,
            .height = editor_header_strip_height,
        };

        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = cell.position(),
            .width = width,
            .height = editor_header_strip_height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .sprite_id = null,
            .screen_position = cell.position(),
            .width = width,
            .height = editor_header_strip_height,
            .action = .select_editor_level,
            .editor_level = @intCast(index),
            .highlighted = index == editor.active_level_index,
            .tooltip = .{ .header = try spanRow(allocator, text(label)) },
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = cell.placeCenter(label_width, editor_group_header_font_size).position(),
            .font_size = editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });

        x += width + ui_gap;
    }

    // Add-level "+": square panel cell flush right of the last tab.
    try emitEditorPlusCell(
        elements,
        allocator,
        font_metrics,
        .{ .x = x, .y = y, .width = editor_header_strip_height, .height = editor_header_strip_height },
        button_color,
        active_theme.lightest,
        "Add level",
    );
}

/// Width of the editor inspector sidebar's background panel. Placeholder
/// value — revisit once the field layout lands and the real width is
/// visible.
pub const editor_inspector_width: i32 = 1024;

/// The inspector background panel's rect — the single source for the
/// builder's layout AND the M2 press arbitration (DESIGN → UI Framework →
/// Text input widget), so the two can't drift.
pub fn editorInspectorPanelRect() Rectangle {
    const top = top_bar_height + ui_gap + editor_header_strip_height + ui_gap;
    const bottom = types.reference_height -
        bottom_bar_height - 2 * ui_gap - editor_header_strip_height;
    return .{ .x = 0, .y = top, .width = editor_inspector_width, .height = bottom - top };
}

/// Editor inspector sidebar (the left bar): a top-left "Inspector" toggle
/// button flush below the options button (the level-tab / group-header
/// visual class: panel-backed, `editor_header_strip_height` tall, label +
/// side padding wide), and — when open — a background panel underneath it
/// that will host the active tool's field editors (later slices; empty for
/// now). The panel spans from below the button down to one `ui_gap` above
/// the expanded palette groups' header strip (those headers sit `ui_gap` +
/// one strip above the bottom bar; the extra gap keeps the panel from
/// sitting flush against them — their x range overlaps the panel since the
/// bottom bar is flush left). The open flag lives on the Editor (GameState)
/// — the toggle rides the undo timeline via `editor_toggle_inspector`.
/// See DESIGN → Architecture → Level Editor → Editor UI layout (inspector).
pub fn buildEditorInspectorPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    inspector_open: bool,
    ui_state: *UiState,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];

    // Toggle button: flush left, below the top bar's options button.
    const label = "Inspector";
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    const width = @max(label_width + 2 * ui_gap, editor_header_strip_height);
    const button_cell: Rectangle = .{
        .x = 0,
        .y = top_bar_height + ui_gap,
        .width = width,
        .height = editor_header_strip_height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_header_strip_height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = null,
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_header_strip_height,
        .action = .toggle_editor_inspector,
        .tooltip = .{ .header = try spanRow(allocator, text(label)) },
    } });
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = button_cell.placeCenter(label_width, editor_group_header_font_size).position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });

    // Background panel (when open): from below the button to one ui_gap
    // above the expanded palette groups' header strip. Theme darkest —
    // the background-panel class (button panels tint gradient[5] to read
    // as buttons against it).
    if (inspector_open) {
        const panel_rect = editorInspectorPanelRect();
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = panel_rect.position(),
            .width = panel_rect.width,
            .height = panel_rect.height,
            .color = active_theme.darkest,
        } });
        try buildEditorInspectorContent(
            elements,
            allocator,
            font_metrics,
            editor,
            active_theme,
            ui_state,
        );
    }
}

/// Width of the editor settings sidebar's background panel (mirrors the
/// inspector's placeholder width).
pub const editor_settings_sidebar_width: i32 = 1024;

/// The settings sidebar's panel rect — the inspector rect mirrored to the
/// right edge. Single source for the builder's layout AND the M2 press
/// arbitration, so the two can't drift.
pub fn editorSettingsSidebarPanelRect() Rectangle {
    const top = top_bar_height + ui_gap + editor_header_strip_height + ui_gap;
    const bottom = types.reference_height -
        bottom_bar_height - 2 * ui_gap - editor_header_strip_height;
    return .{
        .x = types.reference_width - editor_settings_sidebar_width,
        .y = top,
        .width = editor_settings_sidebar_width,
        .height = bottom - top,
    };
}

/// Editor settings sidebar (the right bar): a top-right "Settings" toggle
/// button at the inspector toggle's height, flush to the right screen edge
/// (the same visual class), and — when open — a background panel hosting
/// the mission + active-level metadata: the Mission section (name field)
/// and the Level section (name field; the gradient rows land with the
/// theme slice). The open flag lives on the Editor (GameState) — the
/// toggle rides the undo timeline via `editor_toggle_settings_sidebar`.
/// See DESIGN → Architecture → Level Editor → Editor UI layout (Settings
/// sidebar).
pub fn buildEditorSettingsSidebar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    sidebar_open: bool,
    ui_state: *UiState,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];

    // Toggle button: flush right, at the inspector toggle's height.
    const label = "Settings";
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    const width = @max(label_width + 2 * ui_gap, editor_header_strip_height);
    const button_cell: Rectangle = .{
        .x = types.reference_width - width,
        .y = top_bar_height + ui_gap,
        .width = width,
        .height = editor_header_strip_height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_header_strip_height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = null,
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_header_strip_height,
        .action = .toggle_editor_settings_sidebar,
        .tooltip = .{ .header = try spanRow(allocator, text(label)) },
    } });
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = button_cell.placeCenter(label_width, editor_group_header_font_size).position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });

    if (!sidebar_open) return;

    const panel_rect = editorSettingsSidebarPanelRect();
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = panel_rect.position(),
        .width = panel_rect.width,
        .height = panel_rect.height,
        .color = active_theme.darkest,
    } });

    // Content: the Mission section (name) then the Level section (name).
    // The inspector's row geometry (two-unit field entries: label line
    // above, control below) + section strips; the strips here are PLAIN
    // labels (no collapse — the sidebar is two fixed sections).
    const content: Rectangle = .{
        .x = panel_rect.x + ui_gap,
        .y = panel_rect.y + ui_gap,
        .width = panel_rect.width - 2 * ui_gap,
        .height = panel_rect.height - 2 * ui_gap,
    };
    const text_edit: ?*const TextEditState =
        if (ui_state.text_edit != null) &ui_state.text_edit.? else null;

    // Mission section: strip + the name field entry (two units — the
    // inspector's field-entry geometry).
    var cursor_y = content.y;
    try emitSidebarSectionStrip(
        elements,
        allocator,
        .{ .x = content.x, .y = cursor_y, .width = content.width, .height = editor_header_strip_height },
        "Mission",
        button_color,
        active_theme,
    );
    cursor_y += editor_header_strip_height + ui_gap;
    try emitSidebarNameField(
        elements,
        allocator,
        font_metrics,
        text_edit,
        .{ .id = .mission_name, .target = .mission },
        editor.mission.name,
        .{ .x = content.x, .y = cursor_y, .width = content.width, .height = 2 * editor_inspector_row_height },
        active_theme,
    );

    // The section-break spacer belongs to the section above it (the
    // inspector's convention).
    cursor_y += 2 * editor_inspector_row_height + ui_gap;
    try emitSidebarSectionStrip(
        elements,
        allocator,
        .{ .x = content.x, .y = cursor_y, .width = content.width, .height = editor_header_strip_height },
        "Level",
        button_color,
        active_theme,
    );
    cursor_y += editor_header_strip_height + ui_gap;
    // The level index rides the ref target (the tab the field was focused
    // on — a mid-edit tab switch can't retarget the commit). A level-less
    // editor (defensive — open_editor guarantees ≥1) shows an empty field
    // whose commit gates on the index bound.
    const active_level: usize = @min(editor.active_level_index, editor.levels.len);
    const level_name = if (active_level < editor.levels.len)
        editor.levels[active_level].name
    else
        "";
    try emitSidebarNameField(
        elements,
        allocator,
        font_metrics,
        text_edit,
        .{ .id = .level_name, .target = .{ .level = @intCast(active_level) } },
        level_name,
        .{ .x = content.x, .y = cursor_y, .width = content.width, .height = 2 * editor_inspector_row_height },
        active_theme,
    );
}

/// A sidebar section strip: the group-header visual class (panel-backed,
/// label left-padded + vertically centered) — plain, not collapsible (the
/// sidebar's two sections are fixed).
fn emitSidebarSectionStrip(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    label: []const u8,
    strip_color: types.Color,
    active_theme: types.ActiveColorTheme,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = strip_color,
    } });
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = .{
            .x = cell.x + ui_gap,
            .y = cell.y + @divFloor(cell.height - editor_group_header_font_size, 2),
        },
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

/// A sidebar name field: the inspector field-entry geometry (label line
/// above, paper-strip control below) over the shared `emitTextFieldUi`.
/// `entry` is the two-unit cell (label unit + control unit).
fn emitSidebarNameField(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    text_edit: ?*const TextEditState,
    ref: types.TextFieldRef,
    current_value: []const u8,
    entry: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    try elements.append(allocator, .{ .text_label = .{
        .text = "Name",
        .screen_position = .{ .x = entry.x, .y = inspectorLabelY(entry) },
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
    try emitTextFieldUi(
        elements,
        allocator,
        font_metrics,
        text_edit,
        ref,
        current_value,
        inspectorControlRect(entry),
        active_theme,
    );
}

/// Inspector content row pitch — the 128px UNIT: a section header is one
/// unit; a field entry is TWO (the label line above, the editable value
/// below — one thing per line, full width).
pub const editor_inspector_row_height: i32 = editor_header_strip_height;

/// Inspector scrollbar track width, centered in the panel's right `ui_gap`
/// margin (the skills-panel precedent).
pub const editor_inspector_scrollbar_width: i32 = 12;

/// Inset of a control line within its row unit. Halved from `ui_gap` so
/// the label line sits CLOSE to its editable value (the header reads as
/// belonging to the field, not floating).
const editor_inspector_control_gap: i32 = @divFloor(ui_gap, 2);

/// The control line's rect inside a two-unit entry cell: the lower row
/// unit, inset by `editor_inspector_control_gap` (the label sits flush
/// above it at the unit's bottom).
fn inspectorControlRect(cell: Rectangle) Rectangle {
    return .{
        .x = cell.x,
        .y = cell.y + editor_inspector_row_height + editor_inspector_control_gap,
        .width = cell.width,
        .height = editor_inspector_row_height - 2 * editor_inspector_control_gap,
    };
}

/// The label line's y inside a two-unit entry cell: flush to the BOTTOM of
/// the upper unit, directly above the control line.
fn inspectorLabelY(cell: Rectangle) i32 {
    return cell.y + editor_inspector_row_height - editor_group_header_font_size;
}

/// What the editor inspector is currently showing. The player is the
/// FALLBACK: any state that doesn't resolve to exactly one enemy or
/// decoration type shows the player (the '!' spawn's loadout). The item
/// arm joins when its inspector slice lands.
pub const EditorInspectorTarget = union(enum) {
    entity_type: u32,
    decoration_type: u32,
    player: void,
};

/// The inspector's target: the ACTIVE placement tool (enemy or
/// decoration), or — while the select tool is active — the tool INFERRED
/// from the selection. The player is the fallback for everything else:
/// the tile tool, the item tool (no inspector content yet), an empty or
/// ambiguous selection, an unresolvable reference. Inference rules:
/// tiles and the '=' contribute NOTHING (legitimately uninspectable —
/// mixing them with enemies still shows the enemy); the '!' contributes a
/// `.player` REFERENCE (so player-start + anything — or alone — resolves
/// to the player); entity and decoration placements contribute their
/// type, resolved against the ACTIVE level — an out-of-range placement
/// index or a stale palette type id is an unresolvable bug-state reference
/// and forces the fallback (the delete arms keep the selection
/// consistent, so this is defensive only — see `Selectable`); ground-item
/// placements can't resolve to a showable target yet — they force the
/// fallback too. Exactly one distinct reference wins; two or more (e.g.
/// two enemy types, or an enemy plus a decoration) fall back to the
/// player. See DESIGN → Architecture → Level Editor → Selection model
/// (Inspector tool-type inference).
pub fn editorInspectorTarget(editor: types.Editor) EditorInspectorTarget {
    switch (editor.active_tool) {
        // The select tool infers from the selection below.
        .select => {},
        .entity_type => |type_id| return if (type_id < editor.entity_types.len)
            .{ .entity_type = type_id }
        else
            .player,
        .decoration_type => |type_id| return if (type_id < editor.decoration_types.len)
            .{ .decoration_type = type_id }
        else
            .player,
        // The tile tool has no fields; the item inspector is a later
        // slice — the player is the fallback.
        .tile, .item_type => return .player,
    }
    if (editor.active_level_index >= editor.levels.len) return .player;
    const level = editor.levels[editor.active_level_index];
    var inferred: ?EditorInspectorTarget = null;
    for (editor.selection) |selected| {
        const referenced: ?EditorInspectorTarget = switch (selected) {
            // Legitimately uninspectable — contributes nothing (mixing
            // tiles / the '=' with enemies still shows the enemy).
            .tile, .level_end => null,
            .player_start => .player,
            .entity_placement => |index| blk: {
                // An out-of-range placement index or a stale palette type
                // id is an unresolvable bug-state reference — it can't
                // show anything, so it forces the fallback (defensive
                // only; the placement arms keep both valid). A VALID
                // reference contributes below (break) so later entries
                // still get compared against it.
                if (index >= level.entity_placements.len) return .player;
                const type_id = level.entity_placements[index].type_id;
                if (type_id >= editor.entity_types.len) return .player;
                break :blk .{ .entity_type = type_id };
            },
            .decoration_placement => |index| blk: {
                // Same defensive posture as the entity arm.
                if (index >= level.decoration_placements.len) return .player;
                const type_id = level.decoration_placements[index].type_id;
                if (type_id >= editor.decoration_types.len) return .player;
                break :blk .{ .decoration_type = type_id };
            },
            // No item inspector content yet — a selected ground item
            // can't resolve to a showable target, so it forces the
            // fallback (the arm becomes a real reference when the union
            // widens with its slice).
            .ground_item_placement => return .player,
        };
        const target = referenced orelse continue;
        if (inferred) |existing| {
            if (!editorInspectorTargetsEqual(existing, target)) return .player;
        } else {
            inferred = target;
        }
    }
    return inferred orelse .player;
}

fn editorInspectorTargetsEqual(
    first: EditorInspectorTarget,
    second: EditorInspectorTarget,
) bool {
    if (std.meta.activeTag(first) != std.meta.activeTag(second)) return false;
    return switch (first) {
        .player => true,
        .entity_type => |type_id| type_id == second.entity_type,
        .decoration_type => |type_id| type_id == second.decoration_type,
    };
}

/// The entity (enemy) type the inspector currently edits, or null when
/// the resolved target (see `editorInspectorTarget`) is the player or a
/// decoration type. File-private: the inspector content builder is the
/// only consumer — the input-side commit sites map the full target
/// instead (the player arm edits `player_def`, the decoration arm edits
/// the decoration palette).
fn editorInspectorEntityTarget(editor: types.Editor) ?u32 {
    return switch (editorInspectorTarget(editor)) {
        .entity_type => |type_id| if (type_id < editor.entity_types.len) type_id else null,
        .decoration_type, .player => null,
    };
}

/// The control a field entry hosts (the editable value line, below the
/// label). Controls land per slice; `none` entries render label-only until
/// theirs.
const EditorInspectorControl = union(enum) {
    none,
    text: types.TextFieldId,
    /// The base-sprite row (enemy identity): a button showing the current
    /// stem that opens the centered sprite picker (mission-local +
    /// official tabs — see DESIGN → Level Editor → Editor UI layout, the
    /// centered sprite picker).
    sprite_button: void,
    /// The color_index swatch row (the enemy gradient, one swatch per
    /// index — the settings screen's player-color row is the precedent).
    swatches,
    /// The displays_weapons true/false toggle.
    toggle,
    /// The decoration content's sprite row — same button look as the
    /// entity `sprite_button`, reading the decoration context instead.
    decoration_sprite_button: void,
    /// The decoration content's color swatch row (the WORLD gradient —
    /// decorations index into it, matching the in-game tinting).
    decoration_swatches: void,
    /// The decoration content's footprint row: a button showing the tile
    /// count that opens the centered footprint editor (the tile-grid
    /// picker).
    footprint_button: void,
};

/// One line of inspector content — per the coupling contract in DESIGN →
/// Architecture → Level Editor → Editor UI layout → Inspector fields. The
/// list is built PER FRAME from the editor state (a present item adds its
/// sub-field rows after its slot row). Sections carry their identity (not
/// a label string): the id keys the expansion state + the label lookup.
const EditorInspectorEntry = union(enum) {
    section: types.EditorInspectorSectionId,
    /// One blank unit before every section header except the first — the
    /// section break reads as a break, not just a different strip.
    spacer: void,
    field: struct {
        label: []const u8,
        control: EditorInspectorControl,
    },
    /// A weapon slot: the label line + the weapon-type row (a pick creates
    /// while empty / retypes in place) + Delete while a weapon is equipped.
    weapon_slot: types.GearSlot,
    /// A non-weapon gear slot: the label line + Add (while empty) / Delete
    /// (while equipped); a present item's name/stat field entries follow.
    gear_slot: types.GearSlot,
    /// The utility-skill bar: the label line + ONE row of five 128×128
    /// skill slots (occupied = skill button + icon, empty = the diamond
    /// marker), each opening the centered picker.
    utility_skill_row: void,
    /// The player loadout's name — a READ-ONLY value line (the name comes
    /// with the imported player data, it isn't hand-edited).
    player_name_line: void,
    /// The player inspector's Import button: copy the session's player
    /// data (or the new-game default, with none) into the loadout.
    import_player: void,
    /// The player loadout's inventory — a read-only item count (the
    /// editable inventory UI is its own slice).
    inventory_summary: void,
    /// One ENEMY layer's slot row (label "Layer N"): the sprite-stem
    /// button (re-pick via the layer picker) + Delete. The Layers section
    /// is enemy content only — the player loadout has no layers.
    entity_layer: u32,
    /// One enemy layer's color swatch row (the enemy gradient).
    entity_layer_color: u32,
    /// The enemy content's add-layer row (opens the picker in add mode).
    add_entity_layer: void,
    /// One DECORATION layer's slot row — the entity_layer shape over the
    /// decoration context.
    decoration_layer: u32,
    /// One decoration layer's color swatch row (the world gradient).
    decoration_layer_color: u32,
    /// The decoration content's add-layer row.
    add_decoration_layer: void,
};

/// A section's display label.
fn editorInspectorSectionLabel(section: types.EditorInspectorSectionId) []const u8 {
    return switch (section) {
        .identity => "Identity",
        .stats => "Stats",
        .weapons => "Weapons",
        .gear => "Gear",
        .utility_skills => "Utility skills",
        .inventory => "Inventory",
        .player => "Player",
        .footprint => "Footprint",
        .layers => "Layers",
    };
}

/// Row units an entry occupies: a section header is one; everything else
/// is two (the label line above the control line).
fn editorInspectorEntryUnits(entry: EditorInspectorEntry) i32 {
    return switch (entry) {
        .section, .spacer => 1,
        .field,
        .weapon_slot,
        .gear_slot,
        .utility_skill_row,
        .player_name_line,
        .import_player,
        .inventory_summary,
        .entity_layer,
        .entity_layer_color,
        .add_entity_layer,
        .decoration_layer,
        .decoration_layer_color,
        .add_decoration_layer,
        => 2,
    };
}

/// The stat fields an item kind carries, in display order (the inspector
/// only offers these — a stat the item doesn't have commits nothing by
/// construction).
fn gearSlotStatSet(slot: types.GearSlot) []const types.ItemStatField {
    return switch (slot) {
        .main_hand, .off_hand => &.{.weapon_damage},
        .amulet => &.{.spell_damage},
        .coat => &.{ .health_bonus, .defense_bonus },
        .gloves => &.{ .damage_bonus, .health_bonus },
        .pants => &.{ .pickup_radius_bonus, .health_bonus },
        .boots => &.{ .speed_bonus, .health_bonus },
    };
}

fn itemStatLabel(stat: types.ItemStatField) []const u8 {
    // Lowercase-first: the label always follows its slot's name ("Coat
    // health bonus"), never standalone.
    return switch (stat) {
        .weapon_damage => "damage",
        .spell_damage => "spell damage",
        .health_bonus => "health bonus",
        .defense_bonus => "defense bonus",
        .damage_bonus => "damage bonus",
        .pickup_radius_bonus => "pickup radius",
        .speed_bonus => "speed bonus",
    };
}

/// One gear slot's entries: the slot row + the equipped item's Name +
/// stat field rows (nothing extra while the slot is empty).
fn appendInspectorSlotEntries(
    allocator: std.mem.Allocator,
    template: types.Entity,
    entries: *std.ArrayList(EditorInspectorEntry),
    slot_row: EditorInspectorEntry,
    slot: types.GearSlot,
) !void {
    try entries.append(allocator, slot_row);
    if (template.gearSlotItem(slot) == null) return;
    const slot_label = types.gearSlotLabel(slot);
    try entries.append(allocator, .{ .field = .{
        .label = try std.fmt.allocPrint(allocator, "{s} name", .{slot_label}),
        .control = .{ .text = .{ .item_name = slot } },
    } });
    for (gearSlotStatSet(slot)) |stat| {
        try entries.append(allocator, .{ .field = .{
            .label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ slot_label, itemStatLabel(stat) }),
            .control = .{ .text = .{ .item_stat = .{ .slot = slot, .stat = stat } } },
        } });
    }
}

/// The Weapons + Gear sections (shared by the enemy + player content):
/// each section header, then (while expanded) each slot's row followed by
/// the equipped item's fields. The spacer BEFORE Weapons is the caller's —
/// it belongs to the caller's preceding section (Stats for the enemy
/// content, Player for the player content) and is emitted only while THAT
/// section is expanded.
fn appendInspectorGearSections(
    allocator: std.mem.Allocator,
    template: types.Entity,
    entries: *std.ArrayList(EditorInspectorEntry),
    expanded: *const [editor_inspector_section_count]bool,
) !void {
    try entries.append(allocator, .{ .section = .weapons });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.weapons)]) {
        for ([_]types.GearSlot{ .main_hand, .off_hand }) |hand| {
            try appendInspectorSlotEntries(allocator, template, entries, .{ .weapon_slot = hand }, hand);
        }
    }
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.weapons)]) {
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .gear });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.gear)]) {
        for ([_]types.GearSlot{ .amulet, .coat, .gloves, .pants, .boots }) |slot| {
            try appendInspectorSlotEntries(allocator, template, entries, .{ .gear_slot = slot }, slot);
        }
    }
}

/// The enemy-type inspector's content plan: five sections over every
/// field `parseEntityDefinition` reads (the coupling contract — anything
/// editable by text-editing the level file is a row here). Each section
/// header is followed by its children WHILE EXPANDED (collapsed sections
/// carry the header only — see `UiState.editor_inspector_section_expanded`).
/// The Weapons + Gear sections are state-dependent: each slot row is
/// followed by the equipped item's Name + stat rows (nothing when the slot
/// is empty).
fn editorInspectorEntityEntries(
    allocator: std.mem.Allocator,
    template: types.Entity,
    expanded: *const [editor_inspector_section_count]bool,
) ![]const EditorInspectorEntry {
    var entries: std.ArrayList(EditorInspectorEntry) = .empty;

    // Identity + Stats: fixed.
    try entries.append(allocator, .{ .section = .identity });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.identity)]) {
        try entries.appendSlice(allocator, &.{
            .{ .field = .{ .label = "Name", .control = .{ .text = .entity_name } } },
            .{ .field = .{ .label = "Sprite", .control = .sprite_button } },
            .{ .field = .{ .label = "Color", .control = .swatches } },
            .{ .field = .{ .label = "Displays weapons", .control = .toggle } },
        });
        // The section-break spacer belongs to the section ABOVE it — a
        // collapsed section takes no gap after it (headers stack flush).
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .stats });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.stats)]) {
        try entries.appendSlice(allocator, &.{
            .{ .field = .{ .label = "Max health", .control = .{ .text = .{ .entity_stat = .max_health } } } },
            .{ .field = .{ .label = "Defense", .control = .{ .text = .{ .entity_stat = .defense } } } },
            .{ .field = .{ .label = "Speed", .control = .{ .text = .{ .entity_stat = .speed } } } },
            .{ .field = .{ .label = "Aggro range", .control = .{ .text = .{ .entity_stat = .aggro_range } } } },
        });
        try entries.append(allocator, .spacer);
    }

    try appendInspectorGearSections(allocator, template, &entries, expanded);

    // Utility skills: ONE row of five skill slots (the entity-inspect
    // look), each slot opening the centered picker.
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.gear)]) {
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .utility_skills });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.utility_skills)]) {
        try entries.append(allocator, .{ .utility_skill_row = {} });
    }

    // Layers: per layer a slot row (sprite re-pick + delete) + a color
    // row, then the add button. The LAST section — the spacer above it
    // belongs to utility_skills.
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.utility_skills)]) {
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .layers });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.layers)]) {
        for (0..template.layers.len) |layer_index| {
            try entries.appendSlice(allocator, &.{
                .{ .entity_layer = @intCast(layer_index) },
                .{ .entity_layer_color = @intCast(layer_index) },
            });
        }
        try entries.append(allocator, .{ .add_entity_layer = {} });
    }

    return entries.items;
}

/// The PLAYER content's entries (the fallback target — the '!' spawn's
/// loadout): the loadout header + (while expanded) the read-only name line
/// + import button, the shared Weapons / Gear / Utility sections, and the
/// inventory summary. No Identity / Stats sections — base stats are
/// enemy-authorable only; the player template keeps its defaults.
fn editorInspectorPlayerEntries(
    allocator: std.mem.Allocator,
    template: types.Entity,
    expanded: *const [editor_inspector_section_count]bool,
) ![]const EditorInspectorEntry {
    var entries: std.ArrayList(EditorInspectorEntry) = .empty;

    try entries.append(allocator, .{ .section = .player });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.player)]) {
        try entries.appendSlice(allocator, &.{
            .{ .player_name_line = {} },
            .{ .import_player = {} },
        });
        // The section-break spacer belongs to the section ABOVE it — a
        // collapsed section takes no gap after it (headers stack flush).
        try entries.append(allocator, .spacer);
    }
    try appendInspectorGearSections(allocator, template, &entries, expanded);

    if (expanded[@intFromEnum(types.EditorInspectorSectionId.gear)]) {
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .utility_skills });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.utility_skills)]) {
        try entries.append(allocator, .{ .utility_skill_row = {} });
    }

    if (expanded[@intFromEnum(types.EditorInspectorSectionId.utility_skills)]) {
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .inventory });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.inventory)]) {
        try entries.append(allocator, .{ .inventory_summary = {} });
    }

    return entries.items;
}

/// The DECORATION content's entries: Identity (sprite + color — a
/// decoration's name IS its sprite path, so there is no name row) +
/// Footprint (a read-only tile count; the footprint editor is a later
/// slice). Decoration layers are deferred with the layer editor (they
/// arrive whole via a registry prefab pick in the meantime).
fn editorInspectorDecorationEntries(
    allocator: std.mem.Allocator,
    definition: types.DecorationTypeDef,
    expanded: *const [editor_inspector_section_count]bool,
) ![]const EditorInspectorEntry {
    var entries: std.ArrayList(EditorInspectorEntry) = .empty;

    try entries.append(allocator, .{ .section = .identity });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.identity)]) {
        try entries.appendSlice(allocator, &.{
            .{ .field = .{ .label = "Sprite", .control = .decoration_sprite_button } },
            .{ .field = .{ .label = "Color", .control = .decoration_swatches } },
        });
        try entries.append(allocator, .spacer);
    }
    try entries.append(allocator, .{ .section = .footprint });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.footprint)]) {
        try entries.appendSlice(allocator, &.{
            .{ .field = .{ .label = "Footprint", .control = .footprint_button } },
        });
        try entries.append(allocator, .spacer);
    }

    // Layers: per layer a slot row (sprite re-pick + delete) + a color
    // row, then the add button. The LAST section — the spacer above it
    // belongs to footprint.
    try entries.append(allocator, .{ .section = .layers });
    if (expanded[@intFromEnum(types.EditorInspectorSectionId.layers)]) {
        for (0..definition.layers.len) |layer_index| {
            try entries.appendSlice(allocator, &.{
                .{ .decoration_layer = @intCast(layer_index) },
                .{ .decoration_layer_color = @intCast(layer_index) },
            });
        }
        try entries.append(allocator, .{ .add_decoration_layer = {} });
    }

    return entries.items;
}

/// Build the inspector's content inside the open panel (called by
/// `buildEditorInspectorPanel`): the resolved target's entries — the
/// active enemy tool's field rows, or the player loadout (the fallback
/// target). View-relative windowed emission
/// (the skills-panel model): only FULLY visible rows are emitted at the top
/// of the content region, so nothing half-draws or overflows the panel; the
/// scrollbar thumb conveys the position. `scroll_offset` (rows) is clamped
/// here — authoritative, this fn knows the content height. The wheel
/// routes here from handleAnytimeInput when the pointer is inside the panel
/// rect; while a text field is focused the wheel still flows (only key
/// bindings are suppressed).
/// A section-header strip: panel-backed, the label left-padded and
/// vertically centered (the group-header visual class) — and the section's
/// EXPAND/COLLAPSE button: the whole strip is clickable, the +/- marker
/// prefix carries the state.
fn emitInspectorSectionStrip(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    section: types.EditorInspectorSectionId,
    expanded: bool,
    strip_color: types.Color,
    active_theme: types.ActiveColorTheme,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = strip_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = .toggle_editor_inspector_section,
        .editor_section = section,
        .tooltip = .{ .header = try spanRow(allocator, text(
            if (expanded) "Collapse" else "Expand",
        )) },
    } });
    const label = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ if (expanded) "- " else "+ ", editorInspectorSectionLabel(section) },
    );
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = .{
            .x = cell.x + ui_gap,
            .y = cell.y + @divFloor(cell.height - editor_group_header_font_size, 2),
        },
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

/// The entity template an inspector content path edits, resolved from
/// the inspector target (enemy type vs player loadout): the template its
/// controls read, the `EntityEditTarget` its commits carry (text-field
/// refs), and the team gradient its controls tint with (enemy content =
/// enemy gradient, player content = player gradient — matching the
/// entity-inspect panel's team-gradient coloring).
const InspectorEntityContext = struct {
    template: types.Entity,
    edit_target: types.EntityEditTarget,
    gradient_colors: [types.gradient_color_count]types.Color,
};

/// The decoration type an inspector content path edits, resolved from
/// the inspector target: the definition its controls read. Coloring is
/// the WORLD gradient (decorations index into it, matching the in-game
/// tinting) — carried by the active theme, not this struct.
const InspectorDecorationContext = struct {
    type_definition: types.DecorationTypeDef,
};

fn buildEditorInspectorContent(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    ui_state: *UiState,
) !void {
    const panel = editorInspectorPanelRect();
    const content: Rectangle = .{
        .x = panel.x + ui_gap,
        .y = panel.y + ui_gap,
        .width = panel.width - 2 * ui_gap,
        .height = panel.height - 2 * ui_gap,
    };
    const visible_rows = @divFloor(content.height, editor_inspector_row_height);
    const scroll_offset = &ui_state.editor_inspector_scroll;

    // Target resolution: the active enemy/decoration tool, a selection of
    // placements that all reference one type, or the PLAYER fallback (the
    // '!' spawn's loadout) — see editorInspectorTarget. All paths share
    // the windowing machinery below; they differ in entries + context.
    // Exactly one context is populated (the one its entries read).
    const target = editorInspectorTarget(editor);
    const entity_context: ?InspectorEntityContext = switch (target) {
        .entity_type => |index| .{
            .template = editor.entity_types[index].template,
            .edit_target = .{ .entity_type = index },
            .gradient_colors = active_theme.enemy_gradient.colors,
        },
        .player => .{
            .template = editor.player_def.template,
            .edit_target = .player_def,
            .gradient_colors = active_theme.player_gradient.colors,
        },
        .decoration_type => null,
    };
    const decoration_context: ?InspectorDecorationContext = switch (target) {
        .decoration_type => |index| .{
            .type_definition = editor.decoration_types[index],
        },
        .entity_type, .player => null,
    };
    const entries: []const EditorInspectorEntry = switch (target) {
        .entity_type => |index| try editorInspectorEntityEntries(
            allocator,
            editor.entity_types[index].template,
            &ui_state.editor_inspector_section_expanded,
        ),
        .player => try editorInspectorPlayerEntries(
            allocator,
            editor.player_def.template,
            &ui_state.editor_inspector_section_expanded,
        ),
        .decoration_type => |index| try editorInspectorDecorationEntries(
            allocator,
            editor.decoration_types[index],
            &ui_state.editor_inspector_section_expanded,
        ),
    };
    // Unit math: a section header is 1 row unit, a field entry 2 (label
    // line + control line). Scroll + windowing are in units, so every line
    // stays on the 128px grid at any offset.
    var total_units: i32 = 0;
    for (entries) |entry| total_units += editorInspectorEntryUnits(entry);
    const max_scroll_row = @max(@as(i32, 0), total_units - visible_rows);
    if (scroll_offset.* < 0) scroll_offset.* = 0;
    if (scroll_offset.* > max_scroll_row) scroll_offset.* = max_scroll_row;

    // Team gradient throughout — the context's gradient (enemy content
    // enemy, player content player; matching the entity-inspect panel's
    // team-gradient coloring). Decoration content tints with the WORLD
    // gradient instead (the in-game decoration tinting) — one button
    // color, resolved per target (the section strips read it too).
    const button_color: Color = if (entity_context) |context|
        context.gradient_colors[@min(@as(u32, 5), types.gradient_color_count - 1)]
    else
        active_theme.world_gradient.colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const text_edit: ?*const TextEditState =
        if (ui_state.text_edit != null) &ui_state.text_edit.? else null;

    // Windowed emission (the skills-panel model, variable-height entries):
    // an entry is emitted only when it FULLY fits the visible window —
    // partially-visible entries are skipped (nothing half-draws or
    // overflows the panel; the scrollbar thumb conveys the position).
    var start_unit: i32 = 0;
    var index: usize = 0;
    while (index < entries.len and start_unit < scroll_offset.* + visible_rows) : (index += 1) {
        const entry = entries[index];
        const units = editorInspectorEntryUnits(entry);
        defer start_unit += units;
        if (start_unit < scroll_offset.* or
            start_unit + units > scroll_offset.* + visible_rows) continue;
        const cell: Rectangle = .{
            .x = content.x,
            .y = content.y + (start_unit - scroll_offset.*) * editor_inspector_row_height,
            .width = content.width,
            .height = units * editor_inspector_row_height,
        };
        switch (entry) {
            // A blank unit — the section-break gap.
            .spacer => {},
            // Section header: a panel-backed strip (the group-header visual
            // class), label left-padded + vertically centered.
            .section => |section_id| try emitInspectorSectionStrip(
                elements,
                allocator,
                cell,
                section_id,
                ui_state.editor_inspector_section_expanded[@intFromEnum(section_id)],
                button_color,
                active_theme,
            ),
            // Field entry (two lines): the label line on top, the editable
            // value below it — full content width, one thing per line.
            .field => |row| {
                try elements.append(allocator, .{ .text_label = .{
                    .text = row.label,
                    .screen_position = .{ .x = cell.x, .y = inspectorLabelY(cell) },
                    .font_size = editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
                const control_rect = inspectorControlRect(cell);
                switch (row.control) {
                    .none => {},
                    .sprite_button => try emitInspectorSpriteButton(
                        elements,
                        allocator,
                        font_metrics,
                        entity_context.?.template.sprite,
                        button_color,
                        control_rect,
                        active_theme,
                    ),
                    // The decoration content's sprite row — same emitter,
                    // decoration context (a decoration's sprite id is its
                    // bare stem or `custom/<mission>/<stem>`).
                    .decoration_sprite_button => try emitInspectorSpriteButton(
                        elements,
                        allocator,
                        font_metrics,
                        decoration_context.?.type_definition.sprite,
                        button_color,
                        control_rect,
                        active_theme,
                    ),
                    .text => |field_id| try emitInspectorTextField(
                        elements,
                        allocator,
                        font_metrics,
                        text_edit,
                        entity_context.?,
                        control_rect,
                        field_id,
                        active_theme,
                    ),
                    .swatches => try emitInspectorColorSwatches(
                        elements,
                        allocator,
                        entity_context.?.gradient_colors,
                        entity_context.?.template.color_index,
                        .select_editor_entity_color,
                        null,
                        control_rect,
                    ),
                    // The decoration content's swatch row — the WORLD
                    // gradient + the decoration commit action.
                    .decoration_swatches => try emitInspectorColorSwatches(
                        elements,
                        allocator,
                        active_theme.world_gradient.colors,
                        decoration_context.?.type_definition.color_index,
                        .select_editor_decoration_color,
                        null,
                        control_rect,
                    ),
                    // The decoration content's footprint row: a button
                    // showing the tile count that opens the footprint
                    // editor.
                    .footprint_button => {
                        const tile_count = try std.fmt.allocPrint(
                            allocator,
                            "{d} tiles",
                            .{decoration_context.?.type_definition.footprint.len},
                        );
                        try emitInspectorFootprintButton(
                            elements,
                            allocator,
                            font_metrics,
                            tile_count,
                            button_color,
                            control_rect,
                            active_theme,
                        );
                    },
                    .toggle => try emitInspectorToggle(
                        elements,
                        allocator,
                        font_metrics,
                        entity_context.?,
                        control_rect,
                        active_theme,
                    ),
                }
            },
            // A weapon slot: the slot's label + the weapon-type row (create
            // on pick while empty / retype in place) + Delete while equipped.
            .weapon_slot => |hand| {
                try emitInspectorSlotLabel(elements, allocator, cell, types.gearSlotLabel(hand), active_theme);
                const control_rect = inspectorControlRect(cell);
                try emitInspectorWeaponSlot(
                    elements,
                    allocator,
                    font_metrics,
                    entity_context.?,
                    hand,
                    control_rect,
                    active_theme,
                );
            },
            // The utility-skill bar: the label line + one row of five
            // 128×128 skill slots — the entity-inspect look (skill-button
            // frame + icon, the empty diamond), each opening the picker.
            .utility_skill_row => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Skill bar", active_theme);
                const slot_row: Rectangle = .{
                    .x = cell.x,
                    .y = cell.y + editor_inspector_row_height,
                    .width = cell.width,
                    .height = editor_inspector_row_height,
                };
                try emitInspectorUtilitySkillRow(
                    elements,
                    allocator,
                    entity_context.?,
                    slot_row,
                );
            },
            // A gear slot: the slot's label + Add (while empty) / Delete
            // (while equipped); the item's field entries follow as their
            // own rows.
            .gear_slot => |slot| {
                try emitInspectorSlotLabel(elements, allocator, cell, types.gearSlotLabel(slot), active_theme);
                const control_rect = inspectorControlRect(cell);
                try emitInspectorGearSlot(
                    elements,
                    allocator,
                    font_metrics,
                    entity_context.?,
                    slot,
                    control_rect,
                    active_theme,
                );
            },
            // The player loadout's name — a read-only value line (the
            // name arrives with the imported player data).
            .player_name_line => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Name", active_theme);
                try elements.append(allocator, .{ .text_label = .{
                    .text = entity_context.?.template.name,
                    .screen_position = .{
                        .x = cell.x,
                        .y = cell.y + editor_inspector_row_height,
                    },
                    .font_size = editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
            },
            // The Import button: copy the session's player data (or the
            // new-game default, with none) into the loadout.
            .import_player => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Import", active_theme);
                const control_rect = inspectorControlRect(cell);
                const rect: Rectangle = .{
                    .x = control_rect.x,
                    .y = control_rect.y,
                    .width = @divFloor(control_rect.width, 2),
                    .height = control_rect.height,
                };
                const import_button_color = entity_context.?.gradient_colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
                try elements.append(allocator, .{ .nine_slice_panel = .{
                    .sprite_id = "ui/panel",
                    .screen_position = rect.position(),
                    .width = rect.width,
                    .height = rect.height,
                    .color = import_button_color,
                } });
                try elements.append(allocator, .{ .button = .{
                    .screen_position = rect.position(),
                    .width = rect.width,
                    .height = rect.height,
                    .action = .import_editor_player,
                } });
                const label = "Player data";
                const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
                try elements.append(allocator, .{ .text_label = .{
                    .text = label,
                    .screen_position = rect
                        .placeCenter(label_width, editor_group_header_font_size)
                        .position(),
                    .font_size = editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
            },
            // The player loadout's inventory — a read-only item count.
            .inventory_summary => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Items", active_theme);
                var item_count: u32 = 0;
                for (entity_context.?.template.inventory.slots) |maybe_item| {
                    if (maybe_item != null) item_count += 1;
                }
                const value = try std.fmt.allocPrint(allocator, "{d}", .{item_count});
                try elements.append(allocator, .{ .text_label = .{
                    .text = value,
                    .screen_position = .{
                        .x = cell.x,
                        .y = cell.y + editor_inspector_row_height,
                    },
                    .font_size = editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
            },
            // One ENEMY layer: the slot row — the sprite-stem button (a
            // re-pick opens the layer picker for this index) + Delete.
            .entity_layer => |layer_index| {
                try emitInspectorSlotLabel(
                    elements,
                    allocator,
                    cell,
                    try inspectorLayerLabel(allocator, layer_index, false),
                    active_theme,
                );
                const control_rect = inspectorControlRect(cell);
                try emitInspectorLayerRow(
                    elements,
                    allocator,
                    font_metrics,
                    entity_context.?.template.layers[layer_index].sprite,
                    layer_index,
                    .open_editor_entity_layer_picker,
                    .delete_editor_entity_layer,
                    button_color,
                    control_rect,
                    active_theme,
                );
            },
            // One enemy layer's color swatch row (the enemy gradient).
            .entity_layer_color => |layer_index| {
                try emitInspectorSlotLabel(
                    elements,
                    allocator,
                    cell,
                    try inspectorLayerLabel(allocator, layer_index, true),
                    active_theme,
                );
                const control_rect = inspectorControlRect(cell);
                try emitInspectorColorSwatches(
                    elements,
                    allocator,
                    entity_context.?.gradient_colors,
                    entity_context.?.template.layers[layer_index].color_index,
                    .select_editor_entity_layer_color,
                    layer_index,
                    control_rect,
                );
            },
            // The enemy content's add-layer row: a Pick-sprite button that
            // opens the layer picker in ADD mode (no layer payload).
            .add_entity_layer => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Add layer", active_theme);
                const control_rect = inspectorControlRect(cell);
                const rect: Rectangle = .{
                    .x = control_rect.x,
                    .y = control_rect.y,
                    .width = @divFloor(control_rect.width, 2),
                    .height = control_rect.height,
                };
                try emitInspectorLayerButton(
                    elements,
                    allocator,
                    font_metrics,
                    rect,
                    "Pick sprite",
                    .open_editor_entity_layer_picker,
                    null,
                    button_color,
                    active_theme.lightest,
                );
            },
            // One DECORATION layer — the entity arms' shape over the
            // decoration context (world gradient, decoration actions).
            .decoration_layer => |layer_index| {
                try emitInspectorSlotLabel(
                    elements,
                    allocator,
                    cell,
                    try inspectorLayerLabel(allocator, layer_index, false),
                    active_theme,
                );
                const control_rect = inspectorControlRect(cell);
                try emitInspectorLayerRow(
                    elements,
                    allocator,
                    font_metrics,
                    decoration_context.?.type_definition.layers[layer_index].sprite,
                    layer_index,
                    .open_editor_decoration_layer_picker,
                    .delete_editor_decoration_layer,
                    button_color,
                    control_rect,
                    active_theme,
                );
            },
            .decoration_layer_color => |layer_index| {
                try emitInspectorSlotLabel(
                    elements,
                    allocator,
                    cell,
                    try inspectorLayerLabel(allocator, layer_index, true),
                    active_theme,
                );
                const control_rect = inspectorControlRect(cell);
                try emitInspectorColorSwatches(
                    elements,
                    allocator,
                    active_theme.world_gradient.colors,
                    decoration_context.?.type_definition.layers[layer_index].color_index,
                    .select_editor_decoration_layer_color,
                    layer_index,
                    control_rect,
                );
            },
            .add_decoration_layer => {
                try emitInspectorSlotLabel(elements, allocator, cell, "Add layer", active_theme);
                const control_rect = inspectorControlRect(cell);
                const rect: Rectangle = .{
                    .x = control_rect.x,
                    .y = control_rect.y,
                    .width = @divFloor(control_rect.width, 2),
                    .height = control_rect.height,
                };
                try emitInspectorLayerButton(
                    elements,
                    allocator,
                    font_metrics,
                    rect,
                    "Pick sprite",
                    .open_editor_decoration_layer_picker,
                    null,
                    button_color,
                    active_theme.lightest,
                );
            },
        }
    }

    // Scrollbar (only when the content overflows): track + proportional
    // thumb in the right `ui_gap` margin — the skills-panel geometry,
    // measured in row units.
    if (total_units > visible_rows) {
        const track_x = panel.x + panel.width - ui_gap +
            @divFloor(ui_gap - editor_inspector_scrollbar_width, 2);
        const track_y = content.y;
        const track_height = visible_rows * editor_inspector_row_height;
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = track_y },
            .width = editor_inspector_scrollbar_width,
            .height = track_height,
            .color = .{ .r = 80, .g = 80, .b = 80 },
        } });
        const thumb_height = @max(
            @as(i32, 40),
            @divTrunc(track_height * visible_rows, total_units),
        );
        const thumb_y = track_y +
            @divTrunc(scroll_offset.* * (track_height - thumb_height), max_scroll_row);
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = thumb_y },
            .width = editor_inspector_scrollbar_width,
            .height = thumb_height,
            .color = .{ .r = 180, .g = 180, .b = 180 },
        } });
    }
}


/// Emit one inspector text field in the row's control column. The builder
/// computes ALL render data (it owns the metrics + the focused buffer):
/// the display text is the live buffer while THIS field is focused, else
/// the field's current value; the caret/selection geometry is measured
/// from the buffer. Display text is duped into the frame allocator — an
/// element slice must never point into UiState (it mutates between
/// frames, and the previous frame's elements are hit-tested a frame
/// later).
/// The base-sprite row's control (entity + decoration content): a
/// half-width panel-backed button showing the current stem — clicking
/// opens the centered sprite picker (the input site routes entity vs
/// decoration by the inspector target).
fn emitInspectorSpriteButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    sprite: []const u8,
    button_color: Color,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = .open_editor_sprite_picker,
        .tooltip = .{ .header = try spanRow(allocator, text("Pick sprite")) },
    } });
    const label = if (sprite.len > 0) sprite else "(none)";
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

fn emitInspectorTextField(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    text_edit: ?*const TextEditState,
    context: InspectorEntityContext,
    control_rect: Rectangle,
    field_id: types.TextFieldId,
    active_theme: types.ActiveColorTheme,
) !void {
    const value = context.template.textFieldValue(allocator, field_id) catch
        @panic("failed to format entity field value");
    try emitTextFieldUi(
        elements,
        allocator,
        font_metrics,
        text_edit,
        .{ .id = field_id, .target = .{ .entity = context.edit_target } },
        value,
        control_rect,
        active_theme,
    );
}

/// The text-field ELEMENT (shared by the inspector's entity fields and
/// the settings sidebar's name fields): the paper-strip visual (lightest
/// frame, pure-black text — the contrast is the point; the caret +
/// selection draw in the same color, see the backend arm) + the focused
/// field's live buffer/caret/selection overlay.
fn emitTextFieldUi(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    text_edit: ?*const TextEditState,
    ref: types.TextFieldRef,
    current_value: []const u8,
    field_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const font_size = editor_group_header_font_size;
    var field: TextFieldUi = .{
        .screen_position = field_rect.position(),
        .width = field_rect.width,
        .height = field_rect.height,
        .text_position = .{
            .x = field_rect.x + ui_gap,
            .y = field_rect.y + @divFloor(field_rect.height - font_size, 2),
        },
        .text = try allocator.dupe(u8, current_value),
        .font_size = font_size,
        .frame_color = active_theme.lightest,
        .text_color = .{ .r = 0, .g = 0, .b = 0 },
        .ref = ref,
    };

    if (text_edit) |edit| {
        if (std.meta.eql(edit.field, ref)) {
            const buffer_text = edit.buffer.currentText();
            field.text = try allocator.dupe(u8, buffer_text);
            if (edit.buffer.selectionRange()) |selection| {
                const before = font_metrics.measureSpanWidth(text(buffer_text[0..selection.start]), font_size);
                const within = font_metrics.measureSpanWidth(text(buffer_text[selection.start..selection.end]), font_size);
                field.selection = .{ .x = before, .width = within };
            }
            const caret_x = font_metrics.measureSpanWidth(text(buffer_text[0..edit.buffer.caret]), font_size);
            field.caret = .{ .x = caret_x, .height = font_size };
        }
    }

    try elements.append(allocator, .{ .text_field = field });
}

/// The color_index control (base + layer rows, entity + decoration
/// content): one swatch per gradient index (the settings screen's
/// player-color row is the precedent — colored fill + invisible payload
/// button + highlighted selection). The gradient source + commit action
/// differ per content kind (enemy / player team gradient via
/// `.select_editor_entity_color`, world gradient via
/// `.select_editor_decoration_color`; the `_layer_color` actions for layer
/// rows, with `layer_index` riding the payload). A swatch click commits
/// the index (same-value picks never fire).
fn emitInspectorColorSwatches(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    gradient: [types.gradient_color_count]types.Color,
    current_index: u32,
    action: types.Action,
    layer_index: ?u32,
    control_rect: Rectangle,
) !void {
    for (0..types.gradient_color_count) |index| {
        const swatch_rect: Rectangle = .{
            .x = control_rect.x + @as(i32, @intCast(index)) * (control_rect.height + ui_gap),
            .y = control_rect.y,
            .width = control_rect.height,
            .height = control_rect.height,
        };
        // The swatch fill.
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = swatch_rect.position(),
            .width = swatch_rect.width,
            .height = swatch_rect.height,
            .color = gradient[@min(@as(u32, @intCast(index)), types.gradient_color_count - 1)],
        } });
        // Invisible hit-test button over it, carrying the index (+ the
        // layer index on a layer row).
        try elements.append(allocator, .{ .button = .{
            .screen_position = swatch_rect.position(),
            .width = swatch_rect.width,
            .height = swatch_rect.height,
            .action = action,
            .editor_color = @intCast(index),
            .editor_layer = layer_index,
            .highlighted = current_index == index,
        } });
    }
}

/// The displays_weapons control: a panel-backed strip showing the current
/// value in the FORMAT's vocabulary ("true"/"false" — the exact tokens
/// `asBool` parses), highlighted while true; clicking flips it via
/// `.toggle_editor_entity_displays_weapons`.
fn emitInspectorToggle(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    context: InspectorEntityContext,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const current = context.template.displays_weapons;
    const button_color = context.gradient_colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const label: []const u8 = if (current) "true" else "false";
    // Half the panel width — full-width reads as a section header; the
    // value vocabulary ("true"/"false") carries the state, no highlight.
    const rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = .toggle_editor_entity_displays_weapons,
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

/// A slot entry's label line (the top row unit of a weapon/gear slot).
fn emitInspectorSlotLabel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    label: []const u8,
    active_theme: types.ActiveColorTheme,
) !void {
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = .{ .x = cell.x, .y = inspectorLabelY(cell) },
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

/// A weapon slot's control line: the six weapon types as cells (the
/// enemy_<type> silhouette the entity will actually wield, on the shared
/// button background — the palette tool-cell visual class). Picking a type
/// CREATES a default weapon while the slot is empty, or RETYPES in place
/// (name/damage kept); the current type is highlighted. A Delete button
/// follows while a weapon is equipped (clears the slot to null).
fn emitInspectorWeaponSlot(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    context: InspectorEntityContext,
    hand: types.GearSlot,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const button_color = context.gradient_colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const item_icon_color = context.gradient_colors[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const equipped_weapon: ?types.Weapon = switch (hand) {
        .main_hand => context.template.main_hand_weapon,
        .off_hand => context.template.off_hand_weapon,
        else => null,
    };

    const cell_size = control_rect.height;
    const cell_pitch = cell_size + ui_gap;
    inline for (std.meta.fields(types.WeaponType), 0..) |field, loop_index| {
        const weapon_type: types.WeaponType = @enumFromInt(field.value);
        const index: i32 = @intCast(loop_index);
        const cell: Rectangle = .{
            .x = control_rect.x + index * cell_pitch,
            .y = control_rect.y,
            .width = cell_size,
            .height = cell_size,
        };
        const highlighted = if (equipped_weapon) |weapon| weapon.weapon_type == weapon_type else false;
        try elements.append(allocator, .{ .button = .{
            .sprite_id = "ui/item_slot",
            .screen_position = cell.position(),
            .width = cell.width,
            .height = cell.height,
            .action = .select_editor_weapon_type,
            .editor_gear_slot = hand,
            .editor_weapon_type = weapon_type,
            .color = button_color,
            .highlighted = highlighted,
            .tooltip = .{ .header = try spanRow(allocator, text(types.weaponTypeLabel(weapon_type))) },
        } });
        // The item icon (the inventory's `items/<type>` art — the author
        // picks an ITEM, not an entity overlay), palette item-icon tint.
        const sprite_id = try std.fmt.allocPrint(
            allocator,
            "items/{s}",
            .{field.name},
        );
        const fitted = scaleToFit(cell, inventory_slot_size, inventory_slot_size);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = sprite_id,
            .screen_position = fitted.position(),
            .width = fitted.width,
            .height = fitted.height,
            .color = item_icon_color,
            .blocks_input = false,
        } });
    }

    // Delete (while equipped): the row's remaining width after the cells.
    if (equipped_weapon != null) {
        const type_row_width = @as(i32, @intCast(std.meta.fields(types.WeaponType).len)) * cell_pitch - ui_gap;
        const delete_rect: Rectangle = .{
            .x = control_rect.x + type_row_width + ui_gap,
            .y = control_rect.y,
            .width = control_rect.width - type_row_width - 2 * ui_gap,
            .height = cell_size,
        };
        try emitInspectorSlotButton(
            elements,
            allocator,
            font_metrics,
            delete_rect,
            "Delete",
            .delete_editor_item,
            hand,
            button_color,
            active_theme.lightest,
        );
    }
}

/// A gear slot's control line: Add while the slot is empty (creates a
/// default item), Delete while an item is equipped (clears to null). The
/// item's own name/stat fields follow as separate entries.
fn emitInspectorGearSlot(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    context: InspectorEntityContext,
    slot: types.GearSlot,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const button_color = context.gradient_colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const occupied = context.template.gearSlotItem(slot) != null;
    const label: []const u8 = if (occupied) "Delete" else "Add";
    const action: types.Action = if (occupied) .delete_editor_item else .add_editor_item;
    // Half the panel width — full-width reads as a section header.
    const rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };
    try emitInspectorSlotButton(
        elements,
        allocator,
        font_metrics,
        rect,
        label,
        action,
        slot,
        button_color,
        active_theme.lightest,
    );
}

/// A full-rect panel-backed slot button (Add / Delete): panel + spriteless
/// button + centered label — the toggle's visual class.
fn emitInspectorSlotButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    rect: Rectangle,
    label: []const u8,
    action: types.Action,
    slot: types.GearSlot,
    button_color: Color,
    label_color: Color,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = action,
        .editor_gear_slot = slot,
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = label_color,
        .blocks_input = false,
    } });
}

/// The decoration content's Footprint row's control: a half-width
/// panel-backed button showing the tile count — clicking opens the
/// centered footprint editor (the sprite button's look, its own action).
fn emitInspectorFootprintButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    label: []const u8,
    button_color: Color,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = .open_editor_footprint_picker,
        .tooltip = .{ .header = try spanRow(allocator, text("Edit footprint")) },
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

/// A layer row's label (1-based for display): "Layer N" / "Layer N color".
fn inspectorLayerLabel(
    allocator: std.mem.Allocator,
    layer_index: u32,
    with_color_suffix: bool,
) ![]const u8 {
    const number = layer_index + 1;
    return if (with_color_suffix)
        std.fmt.allocPrint(allocator, "Layer {d} color", .{number})
    else
        std.fmt.allocPrint(allocator, "Layer {d}", .{number});
}

/// One layer's slot row (the Layers section): the control line holds the
/// sprite-stem button (a re-pick opens the layer picker for this index) +
/// a Delete button — the weapon-slot row's layout, entity + decoration
/// content alike (the actions + button color differ per kind).
fn emitInspectorLayerRow(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    sprite: []const u8,
    layer_index: u32,
    open_action: types.Action,
    delete_action: types.Action,
    button_color: Color,
    control_rect: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    // The sprite-stem button (half width, the base sprite button's look).
    const sprite_rect: Rectangle = .{
        .x = control_rect.x,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 2),
        .height = control_rect.height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = sprite_rect.position(),
        .width = sprite_rect.width,
        .height = sprite_rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = sprite_rect.position(),
        .width = sprite_rect.width,
        .height = sprite_rect.height,
        .action = open_action,
        .editor_layer = layer_index,
        .tooltip = .{ .header = try spanRow(allocator, text("Pick sprite")) },
    } });
    const label = if (sprite.len > 0) sprite else "(none)";
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = sprite_rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });

    // The Delete button (quarter width, flush right of the stem button).
    const delete_rect: Rectangle = .{
        .x = sprite_rect.x + sprite_rect.width + ui_gap,
        .y = control_rect.y,
        .width = @divFloor(control_rect.width, 4),
        .height = control_rect.height,
    };
    try emitInspectorLayerButton(
        elements,
        allocator,
        font_metrics,
        delete_rect,
        "Delete",
        delete_action,
        layer_index,
        button_color,
        active_theme.lightest,
    );
}

/// A panel-backed layer button with a centered label (Delete / Pick
/// sprite) carrying the layer-index payload — `emitInspectorSlotButton`'s
/// visual class (null layer index = the add-layer button).
fn emitInspectorLayerButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    rect: Rectangle,
    label: []const u8,
    action: types.Action,
    layer_index: ?u32,
    button_color: Color,
    label_color: Color,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = rect.position(),
        .width = rect.width,
        .height = rect.height,
        .action = action,
        .editor_layer = layer_index,
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = rect
            .placeCenter(label_width, editor_group_header_font_size)
            .position(),
        .font_size = editor_group_header_font_size,
        .color = label_color,
        .blocks_input = false,
    } });
}
/// A utility-skill slot's control line: a half-width button showing the
/// slot's current skill (or "None") — clicking opens the centered skill
/// picker for that slot.
/// The utility-skill bar as ONE row of five 128×128 skill slots — the
/// entity-inspect skill look: occupied = skill-button frame + full-size
/// icon + skill tooltip; empty = the `ui/skill_slot_empty` diamond. Every
/// slot opens the centered picker (the slot index rides the button). The
/// context carries the team gradient, so the enemy + player inspectors
/// share the row.
fn emitInspectorUtilitySkillRow(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    context: InspectorEntityContext,
    row_rect: Rectangle,
) !void {
    const skill_frame_color = context.gradient_colors[3];
    const skill_icon_color = context.gradient_colors[1];
    const cell_size = editor_inspector_row_height;
    const cell_pitch = cell_size + ui_gap;
    for (0..types.utility_skill_count) |loop_index| {
        const slot_index: u32 = @intCast(loop_index);
        const cell: Rectangle = .{
            .x = row_rect.x + @as(i32, @intCast(loop_index)) * cell_pitch,
            .y = row_rect.y,
            .width = cell_size,
            .height = cell_size,
        };
        const current: ?types.SkillId = context.template.equipped_utility_skills[loop_index];
        if (current) |skill_id| {
            const tooltip: ?Tooltip = if (lookups.getSkillDefinition(skill_id)) |definition|
                try buildSkillTooltip(allocator, definition)
            else
                null;
            try elements.append(allocator, .{ .button = .{
                .sprite_id = "ui/skill_button",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .open_editor_skill_picker,
                .editor_utility_slot = slot_index,
                .color = skill_frame_color,
                .tooltip = tooltip,
            } });
            try elements.append(allocator, .{ .image = .{
                .sprite_id = skillIconSpriteId(skill_id),
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = skill_icon_color,
                .blocks_input = false,
            } });
        } else {
            // Empty slot — the diamond marker (the skill-bar look); the
            // tooltip names the pick target.
            try elements.append(allocator, .{ .button = .{
                .sprite_id = "ui/skill_slot_empty",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .open_editor_skill_picker,
                .editor_utility_slot = slot_index,
                .color = skill_frame_color,
                .tooltip = .{ .header = try spanRow(allocator, text("None")) },
            } });
        }
    }
}

/// The centered utility-skill picker (the picker framework's first
/// consumer — see DESIGN → Architecture → Level Editor → Editor UI
/// layout). A modal panel: the None option + one cell per
/// utility-eligible skill (the flat list from src/utility_skills.zig —
/// weapon skills are never offered), 4-wide skill-button cells with the
/// icon + name; the currently-assigned skill is highlighted; a close
/// button top-right (the middle-panel convention). `target` names the
/// slot being assigned.
pub fn buildEditorSkillPicker(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    target: EditorPickerTarget,
    active_theme: types.ActiveColorTheme,
) !void {
    const slot_index = switch (target) {
        .utility_skill_slot => |index| index,
        // The sprite/footprint targets aren't this picker's (the view
        // dispatches on the target); defensive for crafted calls.
        .entity_sprite, .decoration_sprite, .entity_layer, .decoration_layer, .decoration_footprint => return,
    };
    var current: ?types.SkillId = null;
    if (slot_index < types.utility_skill_count) {
        current = switch (editorInspectorTarget(editor)) {
            .entity_type => |type_index| if (type_index < editor.entity_types.len)
                editor.entity_types[type_index].template.equipped_utility_skills[slot_index]
            else
                null,
            .player => editor.player_def.template.equipped_utility_skills[slot_index],
            // No utility-skill row in the decoration content — nothing to
            // show as current (defensive; the picker never opens on it).
            .decoration_type => null,
        };
    }

    const options: i32 = @intCast(1 + utility_skills.utility_skill_ids.len); // None + skills
    const columns: i32 = 4;
    const rows: i32 = @divTrunc(options + columns - 1, columns);
    const cell = slot_size;
    const width = columns * cell + (columns - 1) * ui_gap + 2 * ui_gap;
    const height = middle_panel_header_height + rows * cell + (rows - 1) * ui_gap + 2 * ui_gap;
    const bounds = screenRect().placeCenter(width, height);

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = width,
        .height = height,
        .color = active_theme.darkest,
    } });
    const title = try std.fmt.allocPrint(allocator, "Assign Slot {d}", .{slot_index + 4});
    const content = try emitPanelHeader(elements, allocator, bounds, title, .close_editor_picker);

    // The entity-inspect panel's skill coloring convention: frame at the
    // team gradient's index 3, icon at index 1 — the enemy gradient here
    // (the picker edits an enemy type).
    const enemy = active_theme.enemy_gradient.colors;
    const skill_frame_color = enemy[@min(@as(u32, 3), types.gradient_color_count - 1)];
    const skill_icon_color = enemy[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const grid_origin: ScreenPosition = .{
        .x = content.x + ui_gap,
        .y = content.y + ui_gap,
    };

    // Cell 0: the None option (clears the slot) — no editor_skill payload;
    // the one cell that carries a text label.
    try emitPickerSkillCell(
        elements,
        allocator,
        font_metrics,
        .{ .x = grid_origin.x, .y = grid_origin.y, .width = cell, .height = cell },
        null,
        "None",
        "ui/skill_slot_empty",
        current == null,
        skill_frame_color,
        skill_icon_color,
        active_theme.lightest,
    );
    // One cell per utility skill, in enum order (index + 1: cell 0 is
    // None). Icon-only — the icon is the identity at full cell size; the
    // tooltip carries the name.
    for (utility_skills.utility_skill_ids, 0..) |skill_id, index| {
        const definition = lookups.getSkillDefinition(skill_id) orelse continue;
        const column: i32 = @intCast((index + 1) % @as(usize, @intCast(columns)));
        const row: i32 = @intCast((index + 1) / @as(usize, @intCast(columns)));
        const cell_rect: Rectangle = .{
            .x = grid_origin.x + column * (cell + ui_gap),
            .y = grid_origin.y + row * (cell + ui_gap),
            .width = cell,
            .height = cell,
        };
        try emitPickerSkillCell(
            elements,
            allocator,
            font_metrics,
            cell_rect,
            skill_id,
            definition.name,
            "ui/skill_button",
            current == skill_id,
            skill_frame_color,
            skill_icon_color,
            active_theme.lightest,
        );
    }
}

/// The centered SPRITE picker (the picker framework's second consumer):
/// pick the edited entity type's base sprite. Two tabs top-left — Mission
/// (the .pngs scanned from the mission directory, stored as namespaced
/// `custom/<mission-dir>/<stem>` ids) and Official (the shipped entity
/// sprites, minus the player body); close top-right. One 256×256 cell per
/// option (the palette tool-cell look). Dropdown semantics like the skill
/// picker: blocks only where it sits, stays open until a pick or close.
/// No scrolling — 4 columns, all rows (overflow is a follow-up if real
/// content needs it).
pub fn buildEditorSpritePicker(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    mission_sprites: []const []const u8,
    decoration_registry: []const types.DecorationTypeDef,
    picker_target: EditorPickerTarget,
    tab: types.EditorSpritePickerTab,
) !void {
    // What the picker is picking: a BASE sprite (entity / decoration) or
    // a LAYER sprite (entity / decoration — the layer index rides the
    // picker target, null = add-new; the skill picker's slot pattern).
    // The base modes resolve through the inspector target; a skill-slot
    // target is the skill picker's own builder (the view dispatches).
    const PickerKind = enum { entity_base, decoration_base, entity_layer, decoration_layer };
    const picker_kind: PickerKind = switch (picker_target) {
        .utility_skill_slot, .decoration_footprint => return,
        .entity_sprite => .entity_base,
        .decoration_sprite => .decoration_base,
        .entity_layer => .entity_layer,
        .decoration_layer => .decoration_layer,
    };
    const layer_mode = picker_kind == .entity_layer or picker_kind == .decoration_layer;
    const layer_index: ?u32 = switch (picker_target) {
        .entity_layer => |index| index,
        .decoration_layer => |index| index,
        else => null,
    };

    // The edited definition (highlight target + tint source) — the target
    // resolution's single seam, same as the skill picker. Entity content
    // tints with the enemy gradient; decoration content with the WORLD
    // gradient (the in-game decoration tinting). The player target keeps
    // the entity shape (the player has no sprite/layer rows, so the
    // picker only opens on it via a stale open — picks commit nothing).
    const target = editorInspectorTarget(editor);
    const entity_context: ?InspectorEntityContext = switch (target) {
        .entity_type => |index| .{
            .template = editor.entity_types[index].template,
            .edit_target = .{ .entity_type = index },
            .gradient_colors = active_theme.enemy_gradient.colors,
        },
        .player => .{
            .template = editor.player_def.template,
            .edit_target = .player_def,
            .gradient_colors = active_theme.player_gradient.colors,
        },
        .decoration_type => null,
    };
    const decoration_context: ?InspectorDecorationContext = switch (target) {
        .decoration_type => |index| .{
            .type_definition = editor.decoration_types[index],
        },
        .entity_type, .player => null,
    };
    const base_sprite: []const u8 = if (decoration_context) |context|
        context.type_definition.sprite
    else
        entity_context.?.template.sprite;
    const base_color_index: u32 = if (decoration_context) |context|
        context.type_definition.color_index
    else
        entity_context.?.template.color_index;
    // In layer-EDIT mode the edited layer is the highlight target + tint
    // source; ADD mode highlights nothing and tints with the base. A
    // stale state — the layer index out of range, or the picker kind
    // mismatched with the target (the tool switched mid-open; the
    // dropdown stays open by design) — also falls back to the base
    // values, and every pick no-ops at the commit gate.
    const edited_layer_sprite: ?[]const u8 = blk: {
        const index = layer_index orelse break :blk null;
        if (picker_kind == .entity_layer) {
            const context = entity_context orelse break :blk null;
            if (index >= context.template.layers.len) break :blk null;
            break :blk context.template.layers[index].sprite;
        }
        const context = decoration_context orelse break :blk null;
        if (index >= context.type_definition.layers.len) break :blk null;
        break :blk context.type_definition.layers[index].sprite;
    };
    const edited_layer_color_index: ?u32 = blk: {
        const index = layer_index orelse break :blk null;
        if (picker_kind == .entity_layer) {
            const context = entity_context orelse break :blk null;
            if (index >= context.template.layers.len) break :blk null;
            break :blk context.template.layers[index].color_index;
        }
        const context = decoration_context orelse break :blk null;
        if (index >= context.type_definition.layers.len) break :blk null;
        break :blk context.type_definition.layers[index].color_index;
    };
    const gradient = if (picker_kind == .decoration_base or picker_kind == .decoration_layer)
        active_theme.world_gradient.colors
    else
        active_theme.enemy_gradient.colors;
    const current_sprite: ?[]const u8 = if (layer_mode) edited_layer_sprite else base_sprite;
    const current_color_index: u32 = edited_layer_color_index orelse base_color_index;
    const graphic_color = gradient[@min(current_color_index, types.gradient_color_count - 1)];
    const button_color = gradient[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const pick_action: types.Action = switch (picker_kind) {
        .entity_base => .select_editor_entity_sprite,
        .decoration_base => .select_editor_decoration_sprite,
        .entity_layer => .select_editor_entity_layer,
        .decoration_layer => .select_editor_decoration_layer,
    };

    // One cell per offered sprite, built per frame into the frame arena:
    // the stored id (a bare stem or a namespaced `custom/<mission>/<stem>`),
    // the cell label, the renderable graphic (null = a text-only cell —
    // custom art isn't renderable yet), and the graphic's aspect-fit
    // frame. The Official tab's list differs per kind: the shipped entity
    // sprites (base + layer — a layer may be any entity art, the fixed
    // 512×640 frame), the registry prefabs (decoration base — each pick
    // adopts the whole prefab), or the shipped decoration sprites
    // FILTERED to the base type's dims (decoration layers must match
    // their base — the load-time invariant; mismatched art is never
    // offered). Mission-local art is the same list for every kind (dims
    // are checked at the pick commit).
    const PickerCell = struct {
        stored_id: []const u8,
        label: []const u8,
        graphic_id: ?[]const u8,
        frame_width: i32,
        frame_height: i32,
    };
    var cells: std.ArrayList(PickerCell) = .empty;
    const mission_directory = missionDirectoryName(editor.mission.path);
    switch (tab) {
        .mission_local => {
            for (mission_sprites) |file_name| {
                const stem = file_name[0 .. std.mem.lastIndexOfScalar(u8, file_name, '.') orelse file_name.len];
                try cells.append(allocator, .{
                    .stored_id = try std.fmt.allocPrint(
                        allocator,
                        "custom/{s}/{s}",
                        .{ mission_directory, stem },
                    ),
                    .label = stem,
                    .graphic_id = null,
                    .frame_width = editor_entity_frame_width,
                    .frame_height = editor_entity_frame_height,
                });
            }
        },
        .official => switch (picker_kind) {
            .entity_base, .entity_layer => {
                for (official_entity_sprite_stems) |stem| {
                    try cells.append(allocator, .{
                        .stored_id = stem,
                        .label = stem,
                        .graphic_id = try std.fmt.allocPrint(allocator, "entities/{s}", .{stem}),
                        .frame_width = editor_entity_frame_width,
                        .frame_height = editor_entity_frame_height,
                    });
                }
            },
            .decoration_base => {
                for (decoration_registry) |definition| {
                    try cells.append(allocator, .{
                        .stored_id = definition.sprite,
                        .label = definition.sprite,
                        .graphic_id = try std.fmt.allocPrint(
                            allocator,
                            "decorations/{s}",
                            .{definition.sprite},
                        ),
                        .frame_width = definition.pixel_dims.x,
                        .frame_height = definition.pixel_dims.y,
                    });
                }
            },
            .decoration_layer => {
                // A stale open on a non-decoration target: no base dims to
                // match against — no cells ("No sprites"), picks no-op.
                if (decoration_context) |context| {
                    const base_dims = context.type_definition.pixel_dims;
                    for (official_decoration_sprites) |sprite| {
                        if (sprite.width != base_dims.x or sprite.height != base_dims.y) continue;
                        try cells.append(allocator, .{
                            .stored_id = sprite.stem,
                            .label = sprite.stem,
                            .graphic_id = try std.fmt.allocPrint(
                                allocator,
                                "decorations/{s}",
                                .{sprite.stem},
                            ),
                            .frame_width = sprite.width,
                            .frame_height = sprite.height,
                        });
                    }
                }
            },
        },
    }
    const columns: i32 = 4;
    const rows: i32 = @max(@divTrunc(@as(i32, @intCast(cells.items.len)) + columns - 1, columns), 1);
    const cell = slot_size;
    const width = columns * cell + (columns - 1) * ui_gap + 2 * ui_gap;
    const height = middle_panel_header_height + rows * cell + (rows - 1) * ui_gap + 2 * ui_gap;
    const bounds = screenRect().placeCenter(width, height);

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = width,
        .height = height,
        .color = active_theme.darkest,
    } });

    // The header: tab buttons top-left, close top-right (no title — the
    // tabs ARE the header). Tab state is UiState (a view affordance).
    const origin = bounds.position();
    const tab_specs = [_]struct { tab: types.EditorSpritePickerTab, label: []const u8 }{
        .{ .tab = .mission_local, .label = "Mission" },
        .{ .tab = .official, .label = "Official" },
    };
    var tab_x = origin.x + ui_gap;
    for (tab_specs) |spec| {
        const label_width = font_metrics.measureSpanWidth(text(spec.label), middle_panel_header_font_size);
        const tab_width = label_width + 2 * ui_gap;
        const active = spec.tab == tab;
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = .{ .x = tab_x, .y = origin.y },
            .width = tab_width,
            .height = middle_panel_header_height,
            // Darkest always (the background-panel class) — the active
            // tab's highlight outline is the indication, no tint change.
            .color = active_theme.darkest,
        } });
        try elements.append(allocator, .{ .button = .{
            .screen_position = .{ .x = tab_x, .y = origin.y },
            .width = tab_width,
            .height = middle_panel_header_height,
            .action = .select_editor_sprite_tab,
            .editor_sprite_tab = spec.tab,
            .highlighted = active,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = spec.label,
            .screen_position = .{
                .x = tab_x + ui_gap,
                .y = origin.y + @divFloor(middle_panel_header_height - middle_panel_header_font_size, 2),
            },
            .font_size = middle_panel_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        tab_x += tab_width + ui_gap;
    }
    try elements.append(allocator, .{ .button = .{
        .sprite_id = close_button_sprite_id,
        .screen_position = .{
            .x = origin.x + bounds.width - close_button_size,
            .y = origin.y,
        },
        .width = close_button_size,
        .height = close_button_size,
        .action = .close_editor_picker,
    } });
    const content: Rectangle = .{
        .x = bounds.x,
        .y = bounds.y + middle_panel_header_height,
        .width = bounds.width,
        .height = bounds.height - middle_panel_header_height,
    };

    // The edited template's colors were resolved above (the target's
    // single seam) — nothing further to derive here.
    const grid_origin: ScreenPosition = .{
        .x = content.x + ui_gap,
        .y = content.y + ui_gap,
    };

    if (cells.items.len == 0) {
        try elements.append(allocator, .{ .text_label = .{
            .text = "No sprites",
            .screen_position = grid_origin,
            .font_size = editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        return;
    }

    for (cells.items, 0..) |picker_cell, index| {
        const column: i32 = @intCast(index % @as(usize, @intCast(columns)));
        const row: i32 = @intCast(index / @as(usize, @intCast(columns)));
        const cell_rect: Rectangle = .{
            .x = grid_origin.x + column * (cell + ui_gap),
            .y = grid_origin.y + row * (cell + ui_gap),
            .width = cell,
            .height = cell,
        };
        // Nothing highlighted in layer-ADD mode (no current layer); a
        // stale layer index likewise highlights nothing.
        const highlighted = if (current_sprite) |sprite|
            std.mem.eql(u8, sprite, picker_cell.stored_id)
        else
            false;
        try emitPickerSpriteCell(
            elements,
            allocator,
            font_metrics,
            cell_rect,
            picker_cell.stored_id,
            picker_cell.label,
            picker_cell.graphic_id,
            graphic_color,
            button_color,
            highlighted,
            active_theme.lightest,
            pick_action,
            picker_cell.frame_width,
            picker_cell.frame_height,
        );
    }
}

/// The decoration FOOTPRINT editor (the `.decoration_footprint` picker):
/// a centered panel showing the type's sprite FULL-SIZE (1:1 — 256 screen
/// px per sprite-grid tile) with one toggleable cell per tile, a
/// continuous WHITE outline around the draft-selected region (the
/// placement preview's region-edge style — 8px bars centered on the
/// boundary, seamless at corners), a close button top-right (discard),
/// and a Confirm button bottom-center. The draft rides
/// `UiState.editor_footprint_draft`; the type id rides the picker target
/// (see the union). Custom-stem art isn't renderable yet — its cells get
/// a dark fill so the grid stays visible.
pub fn buildEditorFootprintEditor(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    type_id: u32,
    ui_state: *const UiState,
) !void {
    // The type deleted mid-edit (or a stale open): nothing to edit —
    // the panel vanishes; the close button is unreachable, so the input
    // arms' own guards are the real defense (the toggle no-ops on an
    // out-of-range type).
    if (type_id >= editor.decoration_types.len) return;
    const definition = editor.decoration_types[type_id];
    const grid_width: i32 = @divTrunc(definition.pixel_dims.x + 255, 256);
    const grid_height: i32 = @divTrunc(definition.pixel_dims.y + 255, 256);
    if (grid_width <= 0 or grid_height <= 0) return;
    const cell_count: usize = @intCast(grid_width * grid_height);
    if (cell_count > editor_footprint_grid_cell_limit) return;

    const tile: i32 = 256;
    const grid_width_pixels = grid_width * tile;
    const grid_height_pixels = grid_height * tile;
    const header_height = middle_panel_header_height;
    const confirm_height = editor_inspector_row_height;
    const width = grid_width_pixels + 2 * ui_gap;
    const height = header_height + grid_height_pixels + confirm_height + 3 * ui_gap;
    const bounds = screenRect().placeCenter(width, height);

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = width,
        .height = height,
        .color = active_theme.darkest,
    } });

    // The header: title left, close right (the sprite picker's idiom).
    const origin = bounds.position();
    try elements.append(allocator, .{ .text_label = .{
        .text = "Footprint",
        .screen_position = .{
            .x = origin.x + ui_gap,
            .y = origin.y + @divFloor(header_height - middle_panel_header_font_size, 2),
        },
        .font_size = middle_panel_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = close_button_sprite_id,
        .screen_position = .{
            .x = origin.x + bounds.width - close_button_size,
            .y = origin.y,
        },
        .width = close_button_size,
        .height = close_button_size,
        .action = .close_editor_picker,
    } });

    // The sprite grid: the art at its TRUE pixel dims anchored top-left
    // of the (ceil-rounded) grid area; custom stems get a dark fill per
    // cell so the grid stays visible without art.
    const grid_origin: ScreenPosition = .{
        .x = origin.x + ui_gap,
        .y = origin.y + header_height + ui_gap,
    };
    if (std.mem.startsWith(u8, definition.sprite, "custom/")) {
        for (0..cell_count) |cell_index| {
            const column: i32 = @intCast(cell_index % @as(usize, @intCast(grid_width)));
            const row: i32 = @intCast(cell_index / @as(usize, @intCast(grid_width)));
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{
                    .x = grid_origin.x + column * tile,
                    .y = grid_origin.y + row * tile,
                },
                .width = tile,
                .height = tile,
                .color = .{ .r = 40, .g = 40, .b = 40 },
            } });
        }
    } else {
        const graphic_id = try std.fmt.allocPrint(allocator, "decorations/{s}", .{definition.sprite});
        try elements.append(allocator, .{ .image = .{
            .sprite_id = graphic_id,
            .screen_position = grid_origin,
            .width = definition.pixel_dims.x,
            .height = definition.pixel_dims.y,
            .color = default_tint,
            .blocks_input = false,
        } });
    }

    // One invisible toggle button per grid cell (the draft flips at the
    // input site — a direct UiState write, off the undo timeline).
    for (0..cell_count) |cell_index| {
        const column: i32 = @intCast(cell_index % @as(usize, @intCast(grid_width)));
        const row: i32 = @intCast(cell_index / @as(usize, @intCast(grid_width)));
        try elements.append(allocator, .{ .button = .{
            .screen_position = .{
                .x = grid_origin.x + column * tile,
                .y = grid_origin.y + row * tile,
            },
            .width = tile,
            .height = tile,
            .action = .toggle_editor_footprint_tile,
            .editor_footprint_tile = @intCast(cell_index),
        } });
    }

    // The draft-selected region's outline: one 8px bar per boundary side
    // (the neighbor across it unselected or off-grid), centered on the
    // boundary — the editor's region-edge outline, in white, so corners
    // join seamlessly for any shape.
    const outline_thickness: i32 = 8;
    const half_thickness: i32 = @divFloor(outline_thickness, 2);
    const draftSelected = struct {
        fn check(
            draft: *const [editor_footprint_grid_cell_limit]bool,
            grid_width_: i32,
            grid_height_: i32,
            x: i32,
            y: i32,
        ) bool {
            if (x < 0 or y < 0 or x >= grid_width_ or y >= grid_height_) return false;
            return draft[@intCast(y * grid_width_ + x)];
        }
    }.check;
    for (0..cell_count) |cell_index| {
        if (!ui_state.editor_footprint_draft[cell_index]) continue;
        const column: i32 = @intCast(cell_index % @as(usize, @intCast(grid_width)));
        const row: i32 = @intCast(cell_index / @as(usize, @intCast(grid_width)));
        const cell_x = grid_origin.x + column * tile;
        const cell_y = grid_origin.y + row * tile;
        const draft = &ui_state.editor_footprint_draft;
        if (!draftSelected(draft, grid_width, grid_height, column, row - 1)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x, .y = cell_y - half_thickness },
                .width = tile,
                .height = outline_thickness,
                .color = default_tint,
            } });
        }
        if (!draftSelected(draft, grid_width, grid_height, column, row + 1)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x, .y = cell_y + tile - half_thickness },
                .width = tile,
                .height = outline_thickness,
                .color = default_tint,
            } });
        }
        if (!draftSelected(draft, grid_width, grid_height, column - 1, row)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x - half_thickness, .y = cell_y },
                .width = outline_thickness,
                .height = tile,
                .color = default_tint,
            } });
        }
        if (!draftSelected(draft, grid_width, grid_height, column + 1, row)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x + tile - half_thickness, .y = cell_y },
                .width = outline_thickness,
                .height = tile,
                .color = default_tint,
            } });
        }
    }

    // The Confirm button (bottom-center, the layer-button visual class).
    const confirm_rect: Rectangle = .{
        .x = origin.x + @divFloor(bounds.width - @divFloor(bounds.width, 2), 2),
        .y = origin.y + header_height + grid_height_pixels + 2 * ui_gap,
        .width = @divFloor(bounds.width, 2),
        .height = confirm_height,
    };
    try emitInspectorLayerButton(
        elements,
        allocator,
        font_metrics,
        confirm_rect,
        "Confirm",
        .confirm_editor_footprint,
        null,
        active_theme.world_gradient.colors[@min(@as(u32, 5), types.gradient_color_count - 1)],
        active_theme.lightest,
    );
}

/// The mission directory's NAME (the last path segment) — the namespace
/// for mission-local sprite ids.
fn missionDirectoryName(mission_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, mission_path, '/')) |slash| {
        return mission_path[slash + 1 ..];
    }
    return mission_path;
}

/// One sprite-picker cell: the button background (carrying the pick + the
/// stored-id payload) + the option's graphic. Official options draw the
/// sprite; mission-local options carry a text label (their art isn't
/// renderable until custom-asset rendering lands).
fn emitPickerSpriteCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell_rect: Rectangle,
    sprite_id: []const u8,
    label: []const u8,
    graphic_sprite_id: ?[]const u8,
    graphic_color: Color,
    button_color: Color,
    highlighted: bool,
    label_color: Color,
    pick_action: types.Action,
    frame_width: i32,
    frame_height: i32,
) !void {
    try elements.append(allocator, .{ .button = .{
        .sprite_id = button_background_sprite_id,
        .screen_position = cell_rect.position(),
        .width = cell_rect.width,
        .height = cell_rect.height,
        .action = pick_action,
        .editor_sprite = sprite_id,
        .color = button_color,
        .highlighted = highlighted,
        .tooltip = .{ .header = try spanRow(allocator, text(label)) },
    } });
    if (graphic_sprite_id) |graphic_id| {
        const fitted = scaleToFit(cell_rect, frame_width, frame_height);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = graphic_id,
            .screen_position = fitted.position(),
            .width = fitted.width,
            .height = fitted.height,
            .color = graphic_color,
            .blocks_input = false,
        } });
    } else {
        const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = cell_rect
                .placeCenter(label_width, editor_group_header_font_size)
                .position(),
            .font_size = editor_group_header_font_size,
            .color = label_color,
            .blocks_input = false,
        } });
    }
}

/// One picker cell: the frame button (carrying the pick; null skill_id =
/// the None cell) + the skill icon at FULL cell size. Real skills are
/// icon-only (the tooltip carries the name); the None cell keeps its text
/// label.
fn emitPickerSkillCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell_rect: Rectangle,
    skill_id: ?types.SkillId,
    label: []const u8,
    frame_sprite_id: []const u8,
    highlighted: bool,
    frame_color: Color,
    icon_color: Color,
    label_color: Color,
) !void {
    const tooltip: ?Tooltip = if (skill_id) |some_id|
        if (lookups.getSkillDefinition(some_id)) |definition|
            try buildSkillTooltip(allocator, definition)
        else
            null
    else
        .{ .header = try spanRow(allocator, text("None")) };
    try elements.append(allocator, .{ .button = .{
        .sprite_id = frame_sprite_id,
        .screen_position = cell_rect.position(),
        .width = cell_rect.width,
        .height = cell_rect.height,
        .action = .select_editor_utility_skill,
        .editor_skill = skill_id,
        .color = frame_color,
        .highlighted = highlighted,
        .tooltip = tooltip,
    } });
    if (skill_id) |some_id| {
        // Full cell size — the icon is the identity.
        try elements.append(allocator, .{ .image = .{
            .sprite_id = skillIconSpriteId(some_id),
            .screen_position = cell_rect.position(),
            .width = cell_rect.width,
            .height = cell_rect.height,
            .color = icon_color,
            .blocks_input = false,
        } });
    } else {
        const font_size: i32 = 48;
        const label_width = font_metrics.measureSpanWidth(text(label), font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = cell_rect
                .placeBottomCenter(label_width, font_size, ui_gap)
                .position(),
            .font_size = font_size,
            .color = label_color,
            .blocks_input = false,
        } });
    }
}

/// M2 press arbitration for a focused text field (see DESIGN → UI
/// Framework → Text input widget): true when a left press may PROCEED
/// after committing the field — the press is on a sibling control of the
/// field's own panel (anything inside the open inspector panel or the
/// open settings sidebar, or either toggle button); false when it must be
/// consumed as pure dismissal. Callers gate on a focused field before
/// calling; `pressed_button` is the button under the press position, if
/// any (the toggle buttons sit outside their panel rects, so they are
/// matched by action).
pub fn textEditPressProceeds(
    inspector_open: bool,
    sidebar_open: bool,
    position: ScreenPosition,
    pressed_button: ?Action,
) bool {
    if (pressed_button) |action| {
        if (action == .toggle_editor_inspector) return true;
        if (action == .toggle_editor_settings_sidebar) return true;
        // A picker surface (a skill cell, a sprite cell, a picker tab, or
        // the close button): the picker is the ACTIVE interaction — commit
        // the field and let the pick fire in the same click (it floats
        // outside the panel rects, so the region checks below wouldn't
        // cover it).
        if (action == .select_editor_utility_skill or
            action == .select_editor_entity_sprite or
            action == .select_editor_sprite_tab or
            action == .close_editor_picker) return true;
    }
    if (inspector_open and editorInspectorPanelRect().contains(position)) return true;
    if (sidebar_open and editorSettingsSidebarPanelRect().contains(position)) return true;
    return false;
}

/// Editor bottom bar: the tool palette. Fixed tools first
/// (Select, Tile), then three groups — Enemies, Decorations, Ground Items —
/// each a header toggle + a square panel "+" (add-new) cell + one slot per
/// palette type. Expanded groups put their header + "+" in the strip above
/// the bar; collapsed (or empty) groups put them flush against the bottom
/// of the screen. Every tool renders the shared button background plus a
/// distinguishing graphic: Select = `world/tile_highlight` frame 0, Tile =
/// `world/tile`, enemies = entity base sprite (enemy gradient at the
/// template's color_index), decorations = base sprite (world gradient at
/// the type's color_index), ground items = the item icon (ground items
/// always render as the shared ground bag in-world, so the palette shows
/// the ITEM's icon for authoring distinction). Interaction (active-tool
/// selection, group collapse, click handling) is a later slice. Horizontal
/// scrolling: a group shows at most `editor_palette_max_tools` type cells;
/// `scroll_offsets[group]` (clamped in place here to `[0, size - max]`) is
/// the first visible cell, and the wheel scrolls the window while the
/// pointer is over the group (see `editorPaletteGroupAt`). See DESIGN →
/// Architecture → Level Editor → Editor UI layout (tool palette).
pub fn buildEditorBottomBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    scroll_offsets: *[3]i32,
    collapsed: *[3]bool,
    active_tool: types.EditorToolId,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const item_icon_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const world = active_theme.world_gradient.colors;
    const enemy = active_theme.enemy_gradient.colors;

    const group_labels = [_][]const u8{ "Enemies", "Decorations", "Ground Items" };
    const group_sizes = [3]usize{
        editor.entity_types.len,
        editor.decoration_types.len,
        editor.item_types.len,
    };

    // Per-group header button widths (label + side padding).
    var header_widths: [group_labels.len]i32 = undefined;
    for (group_labels, 0..) |label, group_index| {
        header_widths[group_index] =
            font_metrics.measureSpanWidth(text(label), editor_group_header_font_size) + 2 * ui_gap;
    }

    // Row footprint per group: expanded = its visible type cells; collapsed
    // (or empty) = the header + "+" extent, so headers never overlap in the
    // strip above. Total content width joins the footprints by ui_gap.
    var footprints: [group_labels.len]i32 = undefined;
    var content_width: i32 = 2 * slot_size; // Select + Tile
    for (group_sizes, 0..) |size, group_index| {
        if (collapsed[group_index] or size == 0) {
            footprints[group_index] = header_widths[group_index] + editor_plus_size;
        } else {
            const visible: i32 = @intCast(@min(size, editor_palette_max_tools));
            footprints[group_index] = visible * slot_size + (visible - 1) * ui_gap;
        }
        content_width += footprints[group_index];
    }
    content_width += (2 + group_labels.len - 1) * ui_gap;

    // The bar is flush against the screen's LEFT edge (not centered): the
    // content width changes as groups expand/collapse, and centering would
    // move the fixed tools — left-anchoring keeps Select/Tile stable.
    const bar = screen.placeBottomLeft(content_width, bottom_bar_height, 0);
    var row = Row.init(bar.position(), bottom_bar_height, ui_gap);

    // Fixed tools. The tile graphic draws at half size (the tile art is
    // busy at full cell scale).
    try emitEditorToolCell(
        elements,
        allocator,
        row.next(slot_size),
        .select,
        "world/tile_highlight",
        .{ .x = 0, .y = 0, .width = tile_highlight_frame_size, .height = tile_highlight_frame_size },
        tile_highlight_frame_size,
        tile_highlight_frame_size,
        1.0,
        active_theme.lightest,
        button_color,
        "Select",
        active_tool,
    );
    try emitEditorToolCell(
        elements,
        allocator,
        row.next(slot_size),
        .tile,
        "world/tile",
        null,
        tile_highlight_frame_size,
        tile_highlight_frame_size,
        0.5,
        world[@min(@as(u32, 1), types.gradient_color_count - 1)],
        button_color,
        "Tile paint",
        active_tool,
    );

    // Palette groups. Each group emits: a header toggle button + a "+"
    // button (square ui/panel cells, same visual class as the level tabs)
    // and its visible window of type cells in the row (none when
    // collapsed). An EXPANDED group's header + "+" sit in the strip above
    // the bar (labeling the cells below); a COLLAPSED (or empty) group has
    // no cells to label, so they drop flush against the bottom of the
    // screen instead of hovering above the bar — same condition the
    // footprint math uses.
    for (group_labels, 0..) |label, group_index| {
        const size = group_sizes[group_index];
        const group_left = bar.x + row.cursor_x;
        const footprint = footprints[group_index];
        const header_y: i32 = if (collapsed[group_index] or size == 0)
            screen.bottom() - editor_header_strip_height
        else
            bar.y - ui_gap - editor_header_strip_height;

        // Header: panel-backed button (128 high), left-aligned with the
        // group. Clicking toggles collapse (payload = group index).
        const header_width = header_widths[group_index];
        const header_cell: Rectangle = .{
            .x = group_left,
            .y = header_y,
            .width = header_width,
            .height = editor_header_strip_height,
        };
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = header_cell.position(),
            .width = header_width,
            .height = editor_header_strip_height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .sprite_id = null,
            .screen_position = header_cell.position(),
            .width = header_width,
            .height = editor_header_strip_height,
            .action = .toggle_editor_palette_group,
            .editor_group = group_index,
            .tooltip = .{ .header = try spanRow(allocator, text(
                try std.fmt.allocPrint(allocator, "{s} {s}", .{ label, if (collapsed[group_index]) "(collapsed)" else "" }),
            )) },
        } });
        const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = header_cell.placeCenter(label_width, editor_group_header_font_size).position(),
            .font_size = editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });

        // "+" (add-new): square ui/panel cell flush against the header's
        // right edge (adjacent — reads as tied to the group). Inert until
        // the edit-verb handlers land — tooltip-carrying panel, like the
        // level tabs.
        const plus_cell: Rectangle = .{
            .x = group_left + header_width,
            .y = header_y,
            .width = editor_plus_size,
            .height = editor_plus_size,
        };
        try emitEditorPlusCell(
            elements,
            allocator,
            font_metrics,
            plus_cell,
            button_color,
            active_theme.lightest,
            try std.fmt.allocPrint(allocator, "Add new {s} type", .{label}),
        );

        // Type cells: the visible window (skipped entirely when collapsed).
        if (!collapsed[group_index] and size > 0) {
            // Clamp the window offset in place (authoritative — the wheel
            // handler also bounds-checks, but the builder owns the truth).
            const max_offset: i32 = @intCast(size -| editor_palette_max_tools);
            scroll_offsets[group_index] = @min(@max(scroll_offsets[group_index], 0), max_offset);
            const first_visible: usize = @intCast(scroll_offsets[group_index]);
            const visible = @min(size, editor_palette_max_tools);

            switch (group_index) {
                0 => for (editor.entity_types[first_visible .. first_visible + visible], 0..) |type_definition, ordinal| {
                    const sprite_id = try std.fmt.allocPrint(
                        allocator,
                        "entities/{s}",
                        .{type_definition.template.sprite},
                    );
                    const color_index = @min(type_definition.template.color_index, types.gradient_color_count - 1);
                    try emitEditorToolCell(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .entity_type = @intCast(first_visible + ordinal) },
                        sprite_id,
                        null,
                        editor_entity_frame_width,
                        editor_entity_frame_height,
                        1.0,
                        enemy[color_index],
                        button_color,
                        type_definition.id,
                        active_tool,
                    );
                },
                1 => for (editor.decoration_types[first_visible .. first_visible + visible], 0..) |type_definition, ordinal| {
                    const sprite_id = try std.fmt.allocPrint(
                        allocator,
                        "decorations/{s}",
                        .{type_definition.sprite},
                    );
                    const color_index = @min(type_definition.color_index, types.gradient_color_count - 1);
                    try emitEditorToolCell(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .decoration_type = @intCast(first_visible + ordinal) },
                        sprite_id,
                        null,
                        type_definition.pixel_dims.x,
                        type_definition.pixel_dims.y,
                        1.0,
                        world[color_index],
                        button_color,
                        type_definition.id,
                        active_tool,
                    );
                },
                else => for (editor.item_types[first_visible .. first_visible + visible], 0..) |type_definition, ordinal| {
                    try emitEditorToolCell(
                        elements,
                        allocator,
                        cellAt(bar.y, group_left, ordinal),
                        .{ .item_type = @intCast(first_visible + ordinal) },
                        itemIconSpriteId(type_definition.item),
                        null,
                        inventory_slot_size,
                        inventory_slot_size,
                        1.0,
                        item_icon_color,
                        button_color,
                        type_definition.id,
                        active_tool,
                    );
                },
            }
        }

        // Advance the row cursor past the group's footprint + inter-group
        // gap (explicit — groups don't use `Row.next`, whose per-cell
        // trailing gap would double the inter-group spacing).
        row.cursor_x += footprint + ui_gap;
    }
}

/// The nth tool cell of a palette group starting at `group_left`.
fn cellAt(bar_y: i32, group_left: i32, ordinal: usize) Rectangle {
    const offset: i32 = @intCast(ordinal);
    return .{
        .x = group_left + offset * (slot_size + ui_gap),
        .y = bar_y,
        .width = slot_size,
        .height = bottom_bar_height,
    };
}

/// A square ui/panel "+" cell (the editor's add-new affordance — palette
/// group pluses and the level-tab add-level plus). Inert until its edit
/// verb lands: a tooltip-carrying panel + a non-blocking centered "+"
/// glyph, same visual class as the level tabs. `cell` should be square.
fn emitEditorPlusCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    panel_color: Color,
    text_color: Color,
    tooltip_header: []const u8,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = panel_color,
        .tooltip = .{ .header = try spanRow(allocator, text(tooltip_header)) },
    } });
    const plus_width = font_metrics.measureSpanWidth(text("+"), editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = "+",
        .screen_position = cell.placeCenter(plus_width, editor_group_header_font_size).position(),
        .font_size = editor_group_header_font_size,
        .color = text_color,
        .blocks_input = false,
    } });
}

/// Build the inventory panel into `bounds`: a 9-slice background, an 8×12
/// flush grid of `ui/item_slot` cells tinted with player-gradient index 5,
/// and a 128-wide material-count sidebar on the right. `bounds` is the
/// panel's outer rectangle (sized to `inventory_panel_width` ×
/// `middle_panel_height`); the grid sits `ui_gap` inside the top-left, the
/// sidebar sits `ui_gap` right of the grid. Each occupied slot emits an item
/// `Image` + a `SlotRef` (drag source / click target). Font size for the
/// material-count labels in the inventory sidebar (fits
/// in the bottom-right corner of a 128px material icon).
pub const material_count_font_size: i32 = 48;
/// Inset from a material icon's bottom-right corner to its count label.
pub const material_count_inset: i32 = 8;

/// One entry in the inventory sidebar's material stack.
/// Static display info for one material kind (the parts that don't vary by
/// context). The single source of truth for the five-material icon set —
/// every material-icon site in the UI reads from `material_kinds` so the
/// sprite / color / name mapping can't drift between them. Counts are
/// context-specific (inventory totals vs mission-complete harvest vs new-
/// clone summary) and supplied per site via a `types.Materials` value.
const MaterialKind = struct {
    sprite_id: []const u8,
    color_index: u32,
    /// Display name for the tooltip (e.g. "Wood").
    name: []const u8,
};

/// The five material kinds in display order (top-to-bottom for vertical
/// stacks, left-to-right for horizontal rows).
const material_kinds = [_]MaterialKind{
    .{ .sprite_id = "ui/material_wood", .color_index = 5, .name = "Wood" },
    .{ .sprite_id = "ui/material_metal", .color_index = 2, .name = "Metal" },
    .{ .sprite_id = "ui/material_leather", .color_index = 5, .name = "Leather" },
    .{ .sprite_id = "ui/material_cloth", .color_index = 2, .name = "Cloth" },
    .{ .sprite_id = "ui/material_knowledge", .color_index = 0, .name = "Knowledge" },
};

/// Read the count for `kind_index` out of `materials`. Kept as a switch so
/// adding a material kind is a compile error until every index is handled.
fn materialCount(materials: types.Materials, kind_index: usize) u32 {
    return switch (kind_index) {
        0 => materials.wood,
        1 => materials.metal,
        2 => materials.leather,
        3 => materials.cloth,
        4 => materials.knowledge,
        else => unreachable,
    };
}

/// Layout direction for `emitMaterialIcons`: `.vertical` stacks icons flush
/// (no gap, step = icon_size downward); `.horizontal` spaces them with
/// `ui_gap` (step = icon_size + ui_gap rightward). Matches the two layouts
/// the material-icon sites use (sidebar / harvest column = vertical;
/// new-clone summary row = horizontal).
const MaterialIconDirection = enum { vertical, horizontal };

/// Emit the five material icons (each a blocking `Image` with a
/// `{count} {name}` tooltip) plus a non-blocking outlined count label in
/// each icon's bottom-right corner. Walks `material_kinds` in display order
/// starting at `origin` (top-left of the first icon), stepping by
/// `direction`. `materials` supplies the per-kind counts. The shared body
/// for the inventory sidebar, the mission-complete harvest column, and the
/// new-clone summary row — so the icon set + tooltip format can't drift.
fn emitMaterialIcons(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    origin: ScreenPosition,
    icon_size: i32,
    direction: MaterialIconDirection,
    materials: types.Materials,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    var pos = origin;
    for (material_kinds, 0..) |kind, index| {
        const count = materialCount(materials, index);
        const icon_color = p[@min(kind.color_index, types.gradient_color_count - 1)];
        const tooltip_text = try std.fmt.allocPrint(allocator, "{d} {s}", .{ count, kind.name });
        try elements.append(allocator, .{ .image = .{
            .sprite_id = kind.sprite_id,
            .screen_position = pos,
            .width = icon_size,
            .height = icon_size,
            .color = icon_color,
            .tooltip = .{ .header = try spanRow(allocator, text(tooltip_text)) },
        } });
        // Count label: bottom-right corner of the icon, outlined for
        // readability over the icon art. Passes hover through to the icon
        // so the icon's tooltip is the single target.
        const count_text = try std.fmt.allocPrint(allocator, "{d}", .{count});
        const label_width = font_metrics.measureSpanWidth(text(count_text), material_count_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = count_text,
            .screen_position = .{
                .x = pos.x + icon_size - label_width - material_count_inset,
                .y = pos.y + icon_size - material_count_font_size - material_count_inset,
            },
            .font_size = material_count_font_size,
            .outlined = true,
            .blocks_input = false,
        } });
        switch (direction) {
            .vertical => pos.y += icon_size,
            .horizontal => pos.x += icon_size + ui_gap,
        }
    }
}

/// Build the inventory panel into `bounds`: a 9-slice background, an 8×12
/// flush grid of `ui/item_slot` cells (each carrying an inventory `SlotRef`
/// so press/click/drag handlers can resolve which slot was acted on), and a
/// 128-wide sidebar on the right. The sidebar stacks the five material
/// icons bottom-aligned (each with an outlined count label + a `{count}
/// {type}` tooltip) and tops them with the salvage-tool indicator (display-
/// only, outlined while Shift is held). A shift+left-drag over the grid
/// renders a lightest stroked outline around the bounding box of the
/// selected region (see `UiState.salvage_region`). `bounds` is the panel's
/// outer rectangle (sized to `inventory_panel_width` ×
/// `middle_panel_height`); the grid sits `ui_gap` inside the top-left,
/// the sidebar sits `ui_gap` right of the grid.
/// Sprite id for an item's inventory/gear icon. Weapons resolve per
/// `WeaponType` (Unity's `WandItem` maps to our `staff`); gear types have
/// one icon each; `skill_tome` uses a single generic tome icon (the taught
/// skill is separate info; a per-skill tome icon is not wired — see TODO →
/// UI Framework). All item icons live under `assets/items/` at 128×128
/// (ported from the Unity `Resources/Items/` sprites at native size). See
/// DESIGN → UI Framework.
pub fn itemIconSpriteId(item: types.Item) []const u8 {
    return switch (item) {
        .weapon => |weapon| switch (weapon.weapon_type) {
            .sword => "items/sword",
            .shield => "items/shield",
            .spear => "items/spear",
            .dagger => "items/dagger",
            .axe => "items/axe",
            .staff => "items/staff",
        },
        .amulet => "items/amulet",
        .coat => "items/coat",
        .gloves => "items/gloves",
        .pants => "items/pants",
        .boots => "items/boots",
        .skill_tome => "items/skill_tome",
    };
}

/// The sprite id for a skill icon: `skills/<tag>` mirroring the SkillId tag
/// name (assets/skills/<tag>.png). Comptime-built per-variant table so the
/// returned slice is stable for the process lifetime (no allocation) —
/// drag ghosts borrow it across frames.
fn skillIconSpriteId(skill_id: SkillId) []const u8 {
    const table = comptime blk: {
        const fields = @typeInfo(SkillId).@"enum".fields;
        var t: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| {
            t[i] = "skills/" ++ field.name;
        }
        break :blk t;
    };
    return table[@intFromEnum(skill_id)];
}

/// The sprite id for an active-effect icon in the UI (bottom-bar effects
/// grid + entity-inspect panel). Effects created by a skill share the skill's
/// tag name (EffectId and SkillId overlap: `reflect`, `stone_form`,
/// `that_which_lingers`), so the skill's icon (`skills/<tag>`) is used —
/// the effect's own `effect_sprite` is a WORLD overlay (under
/// `assets/effects/`), not a UI icon. Non-skill effects without a
/// matching SkillId fall back to the effect-sprite path
/// (`effects/<effect_sprite>`) or the effect name (magenta placeholder).
fn effectIconSpriteId(effect_id: types.EffectId, definition: Effect) []const u8 {
    const tag = @tagName(effect_id);
    if (std.meta.stringToEnum(SkillId, tag)) |skill_id| {
        return skillIconSpriteId(skill_id);
    }
    if (definition.effect_sprite) |sprite| return sprite;
    return definition.name;
}

/// Render size for a slot's content, by domain. Inventory + gear slots are
/// 128×128 (`inventory_slot_size`); skill-bar + learned-skill slots are
/// 256×256 (`slot_size`). Pure function of the ref's domain.
pub fn slotContentSize(ref: SlotRef) i32 {
    return switch (ref) {
        .inventory, .gear => inventory_slot_size,
        .skill_bar, .learned_skill => slot_size,
        // Unreachable: save rows never start drags (slotContentIcon is
        // null for them). Size value is arbitrary.
        .save_file => slot_size,
    };
}

/// The content icon for a slot ref, resolved against the live player entity
/// (inventory/gear/skill-bar contents) or the skill-id tag (learned-skill
/// pool). Returns null for an empty slot — the caller must not start a drag
/// from an empty slot. This is the "what is actually being dragged" lookup,
/// distinct from a slot element's `icon_sprite_id` (which is the frame
/// background, always present).
pub fn slotContentIcon(game_state: *const GameState, ref: SlotRef) ?[]const u8 {
    const player = playerEntity(game_state) orelse return null;
    return switch (ref) {
        .inventory => |i| blk: {
            if (i >= player.inventory.slots.len) break :blk null;
            if (player.inventory.slots[i]) |item| break :blk itemIconSpriteId(item);
            break :blk null;
        },
        .gear => |g| switch (g) {
            .main_hand => if (player.main_hand_weapon) |w| itemIconSpriteId(.{ .weapon = w }) else null,
            .off_hand => if (player.off_hand_weapon) |w| itemIconSpriteId(.{ .weapon = w }) else null,
            .amulet => if (player.amulet) |a| itemIconSpriteId(.{ .amulet = a }) else null,
            .coat => if (player.coat) |c| itemIconSpriteId(.{ .coat = c }) else null,
            .gloves => if (player.gloves) |gv| itemIconSpriteId(.{ .gloves = gv }) else null,
            .pants => if (player.pants) |p| itemIconSpriteId(.{ .pants = p }) else null,
            .boots => if (player.boots) |b| itemIconSpriteId(.{ .boots = b }) else null,
        },
        .skill_bar => |i| blk: {
            if (i >= player.equipped_utility_skills.len) break :blk null;
            if (player.equipped_utility_skills[i]) |skill_id| break :blk skillIconSpriteId(skill_id);
            break :blk null;
        },
        .learned_skill => |skill_id| skillIconSpriteId(skill_id),
        // Save rows have no drag content — null here is what keeps the drag
        // machinery from ever starting on them (a press can't promote).
        .save_file => null,
    };
}

/// The Item in a gear slot, or null if empty. Used by panel builders for
/// item icons + tooltips. Mirrors the handler-side `gearSlotItem`.
pub fn gearSlotItem(player: Entity, gear_slot: GearSlot) ?types.Item {
    return player.gearSlotItem(gear_slot);
}

pub fn buildInventoryPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    inventory: types.Inventory,
    materials: types.Materials,
    learned_skills: []const types.SkillId,
    /// The player's equipped gear — baseline for item-tooltip stat
    /// comparisons. Null suppresses them.
    equipped: ?EquippedGear,
    active_theme: types.ActiveColorTheme,
    /// The slot currently being dragged from, if any. The item `Image` is
    /// suppressed on the source slot so the item reads as "in flight"
    /// (shown only as the drag ghost following the pointer). The frame +
    /// tooltip still emit (the tooltip is globally suppressed while a drag
    /// is active — see view.zig — so it's moot here, but the frame keeps
    /// the slot's hit-test identity intact).
    drag_source: ?SlotRef,
    /// Held keyboard modifiers this frame. Drives the salvage-tool indicator
    /// highlight (outlined while Shift is held).
    held_modifiers: types.Modifiers,
    /// In-progress shift-drag region selection, if any. Rendered as a lightest
    /// outline around the bounding box of the two corner slots.
    salvage_region: ?SalvageRegion,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, "Inventory", .toggle_inventory);

    const p = active_theme.player_gradient.colors;
    const slot_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    // Item icons render at player-gradient index 1.
    const item_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const origin = content.position();
    const grid = Grid{
        .origin = .{ .x = origin.x + ui_gap, .y = origin.y + ui_gap },
        .cell_width = inventory_slot_size,
        .cell_height = inventory_slot_size,
        .gap = 0,
        .columns = types.inventory_columns,
    };
    var index: i32 = 0;
    while (index < types.inventory_slot_count) : (index += 1) {
        const cell = grid.cell(index);
        // Slot frame. Carries the slot identity so press/click handlers
        // can resolve which slot was acted on (drag/drop + click intents).
        // When the slot holds an item, the tooltip rides on the frame: the
        // item Image on top is non-blocking, so `tooltipAt` falls through to
        // the Slot beneath (the blocking surface) — one tooltip target per
        // slot.
        const occupied_slot = inventory.slots[@intCast(index)];
        const slot_tooltip: ?Tooltip = if (occupied_slot) |item|
            try buildItemTooltip(allocator, item, learned_skills, equipped)
        else
            null;
        try elements.append(allocator, .{ .slot = .{
            .screen_position = cell.position(),
            .size = inventory_slot_size,
            .icon_sprite_id = "ui/item_slot",
            .icon_color = slot_color,
            .ref = .{ .inventory = @intCast(index) },
            .tooltip = slot_tooltip,
        } });
        // Item icon on top of the frame. Passes hover/click through to the
        // slot beneath so the slot stays the single interaction target.
        // Suppressed on the drag source: the item reads as "in flight"
        // (the drag ghost follows the pointer instead).
        const is_drag_source = if (drag_source) |src| switch (src) {
            .inventory => |si| si == @as(u32, @intCast(index)),
            else => false,
        } else false;
        if (!is_drag_source) {
            if (inventory.slots[@intCast(index)]) |item| {
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = itemIconSpriteId(item),
                    .screen_position = cell.position(),
                    .width = inventory_slot_size,
                    .height = inventory_slot_size,
                    .color = item_color,
                    .blocks_input = false,
                } });
            }
        }
    }

    // Material sidebar: a 128-wide column to the right of the grid
    // (`ui_gap` between them). The five material icons stack bottom-aligned
    // — the stack's bottom edge aligns with the grid's bottom edge. Order
    // top-to-bottom: wood, metal, leather, cloth, knowledge, each tinted
    // with its fixed player-gradient index. Each icon carries an outlined
    // count label in its bottom-right corner.
    const sidebar_x = origin.x + ui_gap + types.inventory_columns * inventory_slot_size + ui_gap;
    const grid_top = origin.y + ui_gap;
    const grid_bottom = grid_top + types.inventory_rows * inventory_slot_size;
    const stack_height = @as(i32, material_kinds.len) * inventory_slot_size;
    const icon_top = grid_bottom - stack_height;
    try emitMaterialIcons(
        elements,
        allocator,
        font_metrics,
        .{ .x = sidebar_x, .y = icon_top },
        inventory_slot_size,
        .vertical,
        materials,
        active_theme,
    );

    // Salvage-tool indicator: top of the material sidebar column (the
    // materials are bottom-aligned, so the top of that column is empty).
    // Display-only (no action) — it signals that Shift+drag multi-salvages.
    // Outlined via the programmatic sprite-silhouette highlight while Shift
    // is held so the player sees the mode is active.
    const lightest = active_theme.lightest;
    const salvage_tool_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];
    try elements.append(allocator, .{ .image = .{
        .sprite_id = "ui/salvage_tool",
        .screen_position = .{ .x = sidebar_x, .y = grid_top },
        .width = inventory_slot_size,
        .height = inventory_slot_size,
        .color = salvage_tool_color,
        .highlighted = held_modifiers.shift,
        .tooltip = .{ .header = try spanRow(allocator, text(
            "Hold Shift to salvage items into materials - hold and drag to multi-salvage",
        )) },
        .blocks_input = false,
    } });

    // Shift-drag region outline: a lightest stroked rectangle around the
    // bounding box of the two corner slots. Drawn over the grid (non-blocking)
    // so hover/click still reach the slots beneath.
    if (salvage_region) |region| {
        const start_row = @divTrunc(@as(i32, @intCast(region.start_slot)), types.inventory_columns);
        const start_col = @rem(@as(i32, @intCast(region.start_slot)), types.inventory_columns);
        const end_row = @divTrunc(@as(i32, @intCast(region.end_slot)), types.inventory_columns);
        const end_col = @rem(@as(i32, @intCast(region.end_slot)), types.inventory_columns);
        const min_row = @min(start_row, end_row);
        const min_col = @min(start_col, end_col);
        const max_row = @max(start_row, end_row);
        const max_col = @max(start_col, end_col);
        const region_origin = ScreenPosition{
            .x = grid.origin.x + min_col * inventory_slot_size,
            .y = grid.origin.y + min_row * inventory_slot_size,
        };
        const region_width = (max_col - min_col + 1) * inventory_slot_size;
        const region_height = (max_row - min_row + 1) * inventory_slot_size;
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = region_origin,
            .width = region_width,
            .height = region_height,
            .color = lightest,
            .filled = false,
            .blocks_input = false,
        } });
    }
}

/// Font size for the gear-panel combat-stat lines.
pub const gear_stat_font_size: i32 = 56;

/// The combat-stat labels shown in the gear panel, in display order. Shared
/// between `gearPanelWidth` (measures the longest line for the panel width)
/// and `buildGearPanel` (renders them). Values are runtime, so width is
/// measured against a max-digit template, not the live value.
const gear_stat_labels = [_][]const u8{
    "Main Hand Damage",
    "Off Hand Damage",
    "Spell Damage",
    "Max Health",
    "Defense",
    "Pickup Radius",
    "Speed",
};

/// Gear panel width, derived from the longest stat line so the stats
/// column (flush against the gear stack) fits without truncation.
/// Mirrors the tooltip/error-popup approach (`measureSpanWidth` → content
/// width + padding). Layout: weapon row (2 slots + gap) on top; gear stack
/// (1 slot) under main-hand; stats flush against the gear stack's right
/// edge, starting under the off-hand. Width = margin + slot + stats +
/// margin.
pub fn gearPanelWidth(font_metrics: FontMetrics) i32 {
    // Value gutter: space + up to 2 digits (stats are bounded; see balance
    // bounds in loaders.zig). Keeps the width stable as values change.
    const value_gutter = font_metrics.measureSpanWidth(text(" 99"), gear_stat_font_size);
    var stats_width: i32 = 0;
    for (gear_stat_labels) |label| {
        const line_width = font_metrics.measureSpanWidth(text(label), gear_stat_font_size) + value_gutter;
        if (line_width > stats_width) stats_width = line_width;
    }
    // Non-weapon row content: panel margin (ui_gap) + 1 slot.
    const non_weapon_row_width = ui_gap + inventory_slot_size;
    // Stats content: stats text + panel margin (ui_gap).
    const stats_column_width = stats_width + ui_gap;
    return non_weapon_row_width + stats_column_width;
}

/// Gear panel: equipped weapons (main/off hand) top-left, then amulet →
/// coat → gloves → pants → boots stacked below the main-hand, and combat
/// stats flush against the gear stack's right edge (starting under the
/// off-hand). All slots + item icons 128×128 (`inventory_slot_size`).
/// Panel width is derived from the longest stat line (`gearPanelWidth`);
/// height shares `middle_panel_height` with the other middle panels.
/// Slots carry `ref = .{ .gear = ... }` so drag to/from inventory works
/// (equip/unequip via the existing orchestrator mapping). The item icon is
/// suppressed on the drag source (shown only as the ghost).
pub fn buildGearPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    player: Entity,
    learned_skills: []const types.SkillId,
    active_theme: types.ActiveColorTheme,
    drag_source: ?SlotRef,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, "Gear", .toggle_gear);

    const p = active_theme.player_gradient.colors;
    const slot_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const item_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const origin = content.position();
    const cell_size = inventory_slot_size;

    // Emit one gear slot: frame + item icon (suppressed on drag source) +
    // tooltip. The frame carries the ref (drag source + drop target).
    const emitGearSlot = struct {
        fn run(
            elems: *UiElementList,
            alloc: std.mem.Allocator,
            cell_pos: ScreenPosition,
            gear_slot: GearSlot,
            pl: Entity,
            skills: []const types.SkillId,
            s_color: Color,
            i_color: Color,
            src: ?SlotRef,
        ) !void {
            const ref: SlotRef = .{ .gear = gear_slot };
            const is_drag_source = if (src) |s| s.eql(ref) else false;
            const item = gearSlotItem(pl, gear_slot);
            // Equipped-item tooltips show no comparisons (an item
            // compared to itself is all zeros).
            const slot_tooltip: ?Tooltip = if (item) |it|
                try buildItemTooltip(alloc, it, skills, null)
            else
                null;
            try elems.append(alloc, .{ .slot = .{
                .screen_position = cell_pos,
                .size = cell_size,
                .icon_sprite_id = "ui/item_slot",
                .icon_color = s_color,
                .ref = ref,
                .tooltip = slot_tooltip,
            } });
            // Item icon on top, suppressed on the drag source ("in flight").
            if (!is_drag_source) {
                if (item) |it| {
                    try elems.append(alloc, .{ .image = .{
                        .sprite_id = itemIconSpriteId(it),
                        .screen_position = cell_pos,
                        .width = cell_size,
                        .height = cell_size,
                        .color = i_color,
                        .blocks_input = false,
                    } });
                }
            }
        }
    }.run;

    // Weapons: main_hand + off_hand side by side on the top row.
    const top_y = origin.y + ui_gap;
    const col0_x = origin.x + ui_gap;
    const col1_x = col0_x + cell_size + ui_gap;
    try emitGearSlot(elements, allocator, .{ .x = col0_x, .y = top_y }, .main_hand, player, learned_skills, slot_color, item_color, drag_source);
    try emitGearSlot(elements, allocator, .{ .x = col1_x, .y = top_y }, .off_hand, player, learned_skills, slot_color, item_color, drag_source);

    // Gear stack: amulet → coat → gloves → pants → boots, each one row below
    // the weapons, under the main-hand column.
    const gear_slots = [_]GearSlot{ .amulet, .coat, .gloves, .pants, .boots };
    var row_y = top_y + cell_size + ui_gap;
    for (gear_slots) |gs| {
        try emitGearSlot(elements, allocator, .{ .x = col0_x, .y = row_y }, gs, player, learned_skills, slot_color, item_color, drag_source);
        row_y += cell_size + ui_gap;
    }

    // Combat stats flush against the gear stack's right edge (no gap),
    // flowing down under the off-hand. Effective values (gear + effect
    // modifiers + momentum where applicable). See `getEffective*` on Entity.
    const stats_x = col0_x + cell_size;
    const stats_top = top_y + cell_size + ui_gap;
    const stat_line_height: i32 = gear_stat_font_size + 16;

    const main_damage = if (player.main_hand_weapon) |w| player.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const off_damage = if (player.off_hand_weapon) |w| player.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const stat_values = [_]u32{
        main_damage,
        off_damage,
        player.getEffectiveSpellDamage(),
        player.getEffectiveMaxHealth(),
        player.getEffectiveDefense(),
        player.getEffectivePickupRadius(0),
        player.getEffectiveSpeed(),
    };

    var stat_y = stats_top;
    for (gear_stat_labels, stat_values) |label, value| {
        const line = try std.fmt.allocPrint(allocator, "{s} {d}", .{ label, value });
        try elements.append(allocator, .{ .text_label = .{
            .text = line,
            .screen_position = .{ .x = stats_x, .y = stat_y },
            .font_size = gear_stat_font_size,
            .blocks_input = false,
        } });
        stat_y += stat_line_height;
    }
    _ = font_metrics;
}

/// Entity-inspect panel (right-click an entity in a level). Read-only
/// mirror of the player's skill bar + active effects + gear panel, tinted
/// with the inspected entity's TEAM gradient (player gradient for team 0,
/// enemy gradient otherwise). No slots carry a `SlotRef` and no buttons
/// carry an `Action` — nothing is draggable or clickable; tooltips still
/// work on hover. Opened by right-clicking a tile with an entity (see
/// `handleRightClickInspect` in input_handlers). See DESIGN → UI Framework
/// → Entity inspect.
///
/// Layout (top to bottom inside the panel):
///   1. Skill bar — 4×2 grid of `slot_size` (256) slots, slots 1-4 top row,
///      5-8 bottom. Empty slots show the diamond marker; cooldowns show
///      the translucent wash + remaining-turns number.
///   2. Active effects — `small_icon_size` (128) icons flowing left→right
///      then wrapping down, max 8 columns. Omitted entirely when the entity
///      has no active effects.
///   3. Gear mirror — weapons (main/off hand) top-left, amulet→coat→gloves→
///      pants→boots stacked below the main-hand, combat-stat column flush
///      against the gear stack's right edge (under the off-hand). All 128×128 (`inventory_slot_size`).
pub fn buildEntityInspectPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    entity: Entity,
    learned_skills: []const types.SkillId,
    /// The PLAYER's equipped gear — baseline for the inspected entity's
    /// gear-tooltip comparisons (dropped enemy gear is directly usable,
    /// so the comparison is actionable). Null (inspecting the player
    /// itself, or no player) suppresses comparisons.
    equipped: ?EquippedGear,
    active_theme: types.ActiveColorTheme,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, entity.name, .toggle_entity_inspect);

    // Team gradient: player (team 0) vs enemy (team ≠ 0). Same fixed
    // indices the bottom bar + gear panel use, resolved against the team's
    // own gradient instead of always the player's.
    const g = if (entity.team == 0) active_theme.player_gradient.colors else active_theme.enemy_gradient.colors;
    const c_skill_frame = g[@min(@as(u32, 3), types.gradient_color_count - 1)];
    const c_skill_icon = g[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const c_gear_slot = g[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const c_gear_item = g[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const cooldown_overlay_color = active_theme.darkest;

    const origin = content.position();

    // --- Skill bar: 4×2 grid of slot_size slots ---
    const skill_grid_origin: ScreenPosition = .{
        .x = origin.x + ui_gap,
        .y = origin.y + ui_gap,
    };
    const skill_grid = Grid{
        .origin = skill_grid_origin,
        .cell_width = slot_size,
        .cell_height = slot_size,
        .gap = 0,
        .columns = 4,
    };
    const skill_slots = entity.collectSkillSlots(weapon_type_definitions);
    for (skill_slots, 0..) |maybe_skill, index| {
        const cell = skill_grid.cell(@intCast(index));
        if (maybe_skill) |skill_id| {
            const definition = lookups.getSkillDefinition(skill_id) orelse {
                // Unknown skill id — render the empty marker rather than crash.
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = "ui/skill_slot_empty",
                    .screen_position = cell.position(),
                    .width = cell.width,
                    .height = cell.height,
                    .color = c_skill_frame,
                } });
                continue;
            };
            try elements.append(allocator, .{ .image = .{
                .sprite_id = "ui/skill_button",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = c_skill_frame,
                .tooltip = try buildSkillTooltip(allocator, definition),
            } });
            try elements.append(allocator, .{ .image = .{
                .sprite_id = skillIconSpriteId(skill_id),
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = c_skill_icon,
                .blocks_input = false,
            } });
            const cooldown = entity.skill_cooldowns.get(skill_id);
            if (cooldown > 0) {
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = "ui/skill_button",
                    .screen_position = cell.position(),
                    .width = cell.width,
                    .height = cell.height,
                    .color = cooldown_overlay_color,
                    .alpha = 128,
                    .blocks_input = false,
                } });
                try emitCenteredNumber(elements, allocator, font_metrics, cell, cooldown, cooldown_font_size);
            }
        } else {
            // Empty slot — diamond marker, same as the skill bar.
            try elements.append(allocator, .{ .image = .{
                .sprite_id = "ui/skill_slot_empty",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = c_skill_frame,
            } });
        }
    }

    // --- Active effects: 128px icons, max 8 columns, left→right then down ---
    var cursor_y = skill_grid_origin.y + 2 * slot_size + ui_gap;
    if (entity.active_effects.len > 0) {
        const effects_origin: ScreenPosition = .{
            .x = origin.x + ui_gap,
            .y = cursor_y,
        };
        const effect_columns: i32 = 8;
        for (entity.active_effects, 0..) |effect, index| {
            const ordinal: i32 = @intCast(index);
            const column = @mod(ordinal, effect_columns);
            const grid_row = @divFloor(ordinal, effect_columns);
            const cell: Rectangle = .{
                .x = effects_origin.x + column * small_icon_size,
                .y = effects_origin.y + grid_row * small_icon_size,
                .width = small_icon_size,
                .height = small_icon_size,
            };
            const definition = lookups.getEffectDefinition(effect.effect_id);
            try elements.append(allocator, .{ .image = .{
                .sprite_id = effectIconSpriteId(effect.effect_id, definition),
                .screen_position = cell.position(),
                .width = small_icon_size,
                .height = small_icon_size,
                .color = c_skill_icon,
                .tooltip = .{
                    .header = try spanRow(allocator, text(definition.name)),
                    .body = try allocator.dupe(TooltipRow, &.{
                        try spanRow(allocator, text(definition.description)),
                        try spanRow(allocator, text(
                            try std.fmt.allocPrint(allocator, "Current duration {d}", .{effect.duration}),
                        )),
                    }),
                },
            } });
            try emitCornerNumber(elements, allocator, font_metrics, cell, effect.duration);
        }
        const effect_rows = @divTrunc(@as(i32, @intCast(entity.active_effects.len)) + effect_columns - 1, effect_columns);
        cursor_y += effect_rows * small_icon_size + ui_gap;
    }

    // --- Gear mirror: weapons row + gear stack + stat column ---
    const gear_top_y = cursor_y;
    const gear_cell_size = inventory_slot_size;
    const col0_x = origin.x + ui_gap;
    const col1_x = col0_x + gear_cell_size + ui_gap;

    const emitGearSlot = struct {
        fn run(
            elems: *UiElementList,
            alloc: std.mem.Allocator,
            cell_pos: ScreenPosition,
            gear_slot: GearSlot,
            ent: Entity,
            skills: []const types.SkillId,
            item_equipped: ?EquippedGear,
            s_color: Color,
            i_color: Color,
        ) !void {
            const item = gearSlotItem(ent, gear_slot);
            const slot_tooltip: ?Tooltip = if (item) |it|
                try buildItemTooltip(alloc, it, skills, item_equipped)
            else
                null;
            try elems.append(alloc, .{ .image = .{
                .sprite_id = "ui/item_slot",
                .screen_position = cell_pos,
                .width = gear_cell_size,
                .height = gear_cell_size,
                .color = s_color,
                .tooltip = slot_tooltip,
            } });
            if (item) |it| {
                try elems.append(alloc, .{ .image = .{
                    .sprite_id = itemIconSpriteId(it),
                    .screen_position = cell_pos,
                    .width = gear_cell_size,
                    .height = gear_cell_size,
                    .color = i_color,
                    .blocks_input = false,
                } });
            }
        }
    }.run;

    try emitGearSlot(elements, allocator, .{ .x = col0_x, .y = gear_top_y }, .main_hand, entity, learned_skills, equipped, c_gear_slot, c_gear_item);
    try emitGearSlot(elements, allocator, .{ .x = col1_x, .y = gear_top_y }, .off_hand, entity, learned_skills, equipped, c_gear_slot, c_gear_item);

    const gear_slots = [_]GearSlot{ .amulet, .coat, .gloves, .pants, .boots };
    var row_y = gear_top_y + gear_cell_size + ui_gap;
    for (gear_slots) |gs| {
        try emitGearSlot(elements, allocator, .{ .x = col0_x, .y = row_y }, gs, entity, learned_skills, equipped, c_gear_slot, c_gear_item);
        row_y += gear_cell_size + ui_gap;
    }

    // Combat-stat column (flush against the gear stack, same as
    // buildGearPanel).
    const stats_x = col0_x + gear_cell_size;
    const stats_top = gear_top_y + gear_cell_size + ui_gap;
    const stat_line_height: i32 = gear_stat_font_size + 16;
    // The inspect stat column leads with the entity's live combat state
    // (current health, aggro range) before the effective gear stats — the
    // player gear panel shares only the gear-stat tail.
    const entity_stat_labels = [_][]const u8{ "Current Health", "Aggro Range" } ++ gear_stat_labels;
    const main_damage = if (entity.main_hand_weapon) |w| entity.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const off_damage = if (entity.off_hand_weapon) |w| entity.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const stat_values = [_]u32{
        entity.current_health,
        entity.aggro_range,
        main_damage,
        off_damage,
        entity.getEffectiveSpellDamage(),
        entity.getEffectiveMaxHealth(),
        entity.getEffectiveDefense(),
        entity.getEffectivePickupRadius(0),
        entity.getEffectiveSpeed(),
    };
    var stat_y = stats_top;
    for (entity_stat_labels, stat_values) |label, value| {
        const line = try std.fmt.allocPrint(allocator, "{s} {d}", .{ label, value });
        try elements.append(allocator, .{ .text_label = .{
            .text = line,
            .screen_position = .{ .x = stats_x, .y = stat_y },
            .font_size = gear_stat_font_size,
            .blocks_input = false,
        } });
        stat_y += stat_line_height;
    }
}

/// Skills browser panel: a 9-slice background, then a 4-wide grid of
/// `slot_size` (256) skill slots filling downward from the top-left, one
/// per learned skill in `learned_skills` order (parsed order — no
/// sorting/grouping/search yet). Each slot is a `ui/skill_button` frame
/// tinted with player-gradient index 3 carrying `ref = .{ .learned_skill =
/// ... }` (drag source/drop target) + a non-blocking `skills/<tag>` icon
/// overlay tinted with index 1, mirroring the skill bar. No `action` —
/// clicking a browser entry doesn't fire a skill (it's not on the bar);
/// drag-to-bar is not wired (see TODO → UI Framework). The drag source's
/// icon is suppressed ("in flight"), matching inventory/gear.
///
/// Vertical overflow is cut at a full skill's bottom (no half-skills): only
/// whole rows within the visible height are emitted. A scrollbar (track +
/// proportional thumb) sits in the right `ui_gap` margin when the skill
/// count exceeds the visible rows. `scroll_offset` (in rows) is clamped to
/// `[0, max_scroll_row]` here — the authoritative clamp, since only the
/// view knows `max_scroll_row`.
pub fn buildSkillsPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    learned_skills: []const SkillId,
    active_theme: types.ActiveColorTheme,
    /// In/out: current scroll offset in rows; clamped here to `[0, max_scroll_row]`.
    scroll_offset: *i32,
    /// The slot currently being dragged from, if any. The skill icon is
    /// suppressed on the source slot so it reads as "in flight" (shown only
    /// as the drag ghost). The frame + ref still emit so the slot stays a
    /// drop target.
    drag_source: ?SlotRef,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, "Skills", .toggle_skills);

    const p = active_theme.player_gradient.colors;
    const frame_color = p[@min(@as(u32, 3), types.gradient_color_count - 1)];
    const icon_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const origin = content.position();
    const grid_origin: ScreenPosition = .{
        .x = origin.x + ui_gap,
        .y = origin.y + ui_gap,
    };
    const grid_height = content.height - 2 * ui_gap;
    const visible_rows = @divFloor(grid_height, slot_size);
    const total_rows = @divTrunc(@as(i32, @intCast(learned_skills.len)) + skills_panel_columns - 1, skills_panel_columns);
    const max_scroll_row = @max(@as(i32, 0), total_rows - visible_rows);
    // Authoritative clamp (the input handler can't know max_scroll_row).
    if (scroll_offset.* < 0) scroll_offset.* = 0;
    if (scroll_offset.* > max_scroll_row) scroll_offset.* = max_scroll_row;
    const first_row = scroll_offset.*;

    const grid = Grid{
        .origin = grid_origin,
        .cell_width = slot_size,
        .cell_height = slot_size,
        .gap = 0,
        .columns = skills_panel_columns,
    };

    // Emit only the fully-visible rows, drawn at the TOP of the grid region
    // (view-relative positions — the scrollbar thumb conveys the scroll
    // position, same pattern as `buildErrorPopup`'s body window). A row that
    // wouldn't fully fit is not emitted (no half-skills).
    const visible_row_count = @min(visible_rows, @max(@as(i32, 0), total_rows - first_row));
    var view_row: i32 = 0;
    while (view_row < visible_row_count) : (view_row += 1) {
        var column: i32 = 0;
        while (column < skills_panel_columns) : (column += 1) {
            const index: usize = @intCast((first_row + view_row) * skills_panel_columns + column);
            if (index >= learned_skills.len) break;
            const skill_id = learned_skills[index];
            const cell = grid.cell(view_row * skills_panel_columns + column);
            const ref: SlotRef = .{ .learned_skill = skill_id };
            const is_drag_source = if (drag_source) |src| src.eql(ref) else false;
            // Drag source: render the empty-slot diamond so the skill reads
            // as "in flight" (shown only as the drag ghost following the
            // pointer). The frame keeps its ref so the slot stays a drop
            // target for a same-slot drop (a no-op). Mirrors `emitSkillButton`'s
            // drag-source / empty handling. No tooltip — globally suppressed
            // while a drag is active anyway (see view.zig).
            if (is_drag_source) {
                try elements.append(allocator, .{ .slot = .{
                    .screen_position = cell.position(),
                    .size = slot_size,
                    .icon_sprite_id = "ui/skill_slot_empty",
                    .icon_color = frame_color,
                    .ref = ref,
                } });
                continue;
            }
            const definition = lookups.getSkillDefinition(skill_id);
            const slot_tooltip: ?Tooltip = if (definition) |def|
                try buildSkillTooltip(allocator, def)
            else
                null;
            // Frame carries the slot identity (drag source + drop target).
            try elements.append(allocator, .{ .slot = .{
                .screen_position = cell.position(),
                .size = slot_size,
                .icon_sprite_id = "ui/skill_button",
                .icon_color = frame_color,
                .ref = ref,
                .tooltip = slot_tooltip,
            } });
            // Skill icon on top.
            {
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = skillIconSpriteId(skill_id),
                    .screen_position = cell.position(),
                    .width = slot_size,
                    .height = slot_size,
                    .color = icon_color,
                    .blocks_input = false,
                } });
            }
        }
    }

    // Scrollbar (only when the skill count overflows the visible rows). Track
    // + proportional thumb in the right `ui_gap` margin, spanning the grid's
    // height. Mirrors `buildErrorPopup`'s scrollbar geometry.
    if (total_rows > visible_rows) {
        const track_x = origin.x + bounds.width - ui_gap +
            @divFloor(ui_gap - skills_scrollbar_width, 2);
        const track_y = grid_origin.y;
        const track_height = visible_rows * slot_size;
        const track_color: types.Color = .{ .r = 80, .g = 80, .b = 80 };
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = track_y },
            .width = skills_scrollbar_width,
            .height = track_height,
            .color = track_color,
        } });
        const thumb_height = @max(
            @as(i32, 40),
            @divTrunc(track_height * visible_rows, total_rows),
        );
        const thumb_y = track_y +
            @divTrunc(scroll_offset.* * (track_height - thumb_height), max_scroll_row);
        const thumb_color: types.Color = .{ .r = 180, .g = 180, .b = 180 };
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = thumb_y },
            .width = skills_scrollbar_width,
            .height = thumb_height,
            .color = thumb_color,
        } });
    }

    _ = font_metrics;
}

test "buildSkillsPanel: few skills — one row, slots + icons, no scrollbar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const learned = [_]SkillId{ .slice, .stab, .chop };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    var scroll_offset: i32 = 5; // clamped to 0 (no overflow)

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = skills_panel_width,
        .height = middle_panel_height,
    };
    try buildSkillsPanel(&elements, arena.allocator(), metrics, bounds, &learned, theme, &scroll_offset, null);

    // 1 panel + 2 header (title + close button) + 3 slots + 3 icons, no scrollbar.
    try std.testing.expectEqual(@as(usize, 9), elements.items.len);
    try std.testing.expectEqual(@as(i32, 0), scroll_offset); // clamped
    for (elements.items) |element| switch (element) {
        .solid_rect => @panic("unexpected scrollbar for few skills"),
        else => {},
    };
}

test "buildSkillsPanel: overflow — scrollbar present, only visible rows emitted, no half-skills" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 25 skills → 7 rows (ceil(25/4)); visible_rows = 6 (1536/256). Overflow
    // by 1 row → max_scroll_row = 1.
    const learned = [_]SkillId{
        .slice, .stab, .chop, .cleave,
        .slam, .skewer, .impale, .bash,
        .blink, .blitz, .daze, .focus,
        .howl, .reflect, .replenish, .retreating_swipe,
        .spark, .spinblade, .stone_form, .swap,
        .that_which_lingers, .throw, .toss, .vampiric_strike,
        .flash_strike,
    };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    var scroll_offset: i32 = 100; // clamped to max_scroll_row = 1

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = skills_panel_width,
        .height = middle_panel_height,
    };
    try buildSkillsPanel(&elements, arena.allocator(), metrics, bounds, &learned, theme, &scroll_offset, null);

    // scroll clamped to the last row.
    try std.testing.expectEqual(@as(i32, 1), scroll_offset);

    // Count slots: only the fully-visible rows emit. At scroll_offset = 1,
    // visible rows are [1, 7) = 6 rows = 24 cells, but row 6 has only 1 skill
    // (25 - 24 = 1), so 24 - 3 = 21 slots. Each slot has an icon → 21 icons.
    var slot_count: usize = 0;
    var icon_count: usize = 0;
    var solid_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .slot => slot_count += 1,
        .image => icon_count += 1,
        .solid_rect => solid_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 21), slot_count);
    try std.testing.expectEqual(@as(usize, 21), icon_count);
    // Scrollbar: track + thumb.
    try std.testing.expectEqual(@as(usize, 2), solid_count);

    // No slot's bottom edge exceeds the visible grid bottom (no half-skills).
    const grid_top = middle_panel_header_height + ui_gap;
    const grid_bottom = grid_top + 6 * slot_size; // visible_rows * slot_size
    for (elements.items) |element| switch (element) {
        .slot => |slot| {
            const bottom = slot.screen_position.y + slot.size;
            try std.testing.expect(bottom <= grid_bottom);
        },
        else => {},
    };
}

test "buildSkillsPanel: drag source suppresses the icon, keeps the slot ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const learned = [_]SkillId{ .slice, .stab };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    var scroll_offset: i32 = 0;
    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = skills_panel_width,
        .height = middle_panel_height,
    };
    try buildSkillsPanel(
        &elements,
        arena.allocator(),
        metrics,
        bounds,
        &learned,
        theme,
        &scroll_offset,
        SlotRef{ .learned_skill = .slice }, // dragging the first skill
    );

    // The first slot keeps its ref (drop target) and renders the empty-slot
    // diamond ("in flight"); the second emits the skill_button frame + icon.
    var found_source_slot = false;
    var found_source_diamond = false;
    var image_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .slot => |slot| if (slot.ref != null and slot.ref.?.eql(.{ .learned_skill = .slice })) {
            found_source_slot = true;
            found_source_diamond = std.mem.eql(u8, slot.icon_sprite_id orelse "", "ui/skill_slot_empty");
        },
        .image => image_count += 1,
        else => {},
    };
    try std.testing.expect(found_source_slot);
    try std.testing.expect(found_source_diamond);
    // Only the second skill's icon emits; the drag source's is suppressed.
    try std.testing.expectEqual(@as(usize, 1), image_count);
}

test "scaleToFit: aspect-preserved, centered, degenerate dims fall back to cell" {
    const cell = Rectangle{ .x = 100, .y = 200, .width = 256, .height = 256 };

    // Tall sprite (the 512x640 entity frame): height-limited → 204x256,
    // centered horizontally.
    const tall = scaleToFit(cell, 512, 640);
    try std.testing.expectEqual(@as(i32, 204), tall.width);
    try std.testing.expectEqual(@as(i32, 256), tall.height);
    try std.testing.expectEqual(@as(i32, 100 + 26), tall.x);
    try std.testing.expectEqual(@as(i32, 200), tall.y);

    // Wide sprite (e.g. a 768x512 decoration): width-limited → 256x170.
    const wide = scaleToFit(cell, 768, 512);
    try std.testing.expectEqual(@as(i32, 256), wide.width);
    try std.testing.expectEqual(@as(i32, 170), wide.height);

    // Unresolvable dims (a fresh type with no sprite yet) → the full cell.
    const degenerate = scaleToFit(cell, 0, 0);
    try std.testing.expectEqual(cell, degenerate);
}

test "buildEditorLevelTabs: one panel button per level, active highlighted, unnamed fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const player_one: types.Color = .{ .r = 30, .g = 30, .b = 30 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, player_one, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const levels = [_]types.EditorLevel{
        .{ .name = "The Crossing" },
        .{}, // unnamed -> "Level 2"
        .{}, // unnamed -> "Level 3"
    };
    const editor: types.Editor = .{
        .levels = &levels,
        .active_level_index = 1,
    };

    var elements: UiElementList = .empty;
    try buildEditorLevelTabs(&elements, arena.allocator(), metrics, editor, theme);

    // 3 tabs x (panel + spriteless button + label) + the add-level "+"
    // (panel + glyph) = 11 elements.
    try std.testing.expectEqual(@as(usize, 11), elements.items.len);

    // Tabs sit right of the top bar's options + undo cells, 128 high,
    // flush against the top of the screen.
    const start_x = 2 * (slot_size + ui_gap);
    try std.testing.expectEqual(@as(i32, start_x), elements.items[0].nine_slice_panel.screen_position.x);
    try std.testing.expectEqual(@as(i32, 0), elements.items[0].nine_slice_panel.screen_position.y);
    try std.testing.expectEqual(@as(i32, 128), elements.items[0].nine_slice_panel.height);

    // Per tab: the button carries the payload + action; only the ACTIVE
    // tab (index 1) is highlighted. Labels: the level's name, else
    // "Level N".
    const expected_labels = [_][]const u8{ "The Crossing", "Level 2", "Level 3" };
    var previous_x: i32 = start_x;
    for (0..3) |tab| {
        const button = elements.items[3 * tab + 1].button;
        try std.testing.expectEqual(Action.select_editor_level, button.action);
        try std.testing.expectEqual(@as(u32, @intCast(tab)), button.editor_level.?);
        try std.testing.expectEqual(tab == 1, button.highlighted);
        try std.testing.expect(button.sprite_id == null); // spriteless over the panel

        const label = elements.items[3 * tab + 2].text_label;
        try std.testing.expectEqualStrings(expected_labels[tab], label.text);
        try std.testing.expect(!label.blocks_input);

        // Tabs lay out left-to-right, advancing past each panel.
        const panel_x = elements.items[3 * tab].nine_slice_panel.screen_position.x;
        try std.testing.expect(panel_x >= previous_x);
        previous_x = panel_x;
    }

    // Add-level "+": square ui/panel cell to the right of the last tab,
    // top-aligned with the tabs, carrying the tooltip. Inert (a panel, not
    // a button — no action until `editor_add_level`'s handler lands).
    const plus_panel = elements.items[9].nine_slice_panel;
    try std.testing.expectEqualStrings("ui/panel", plus_panel.sprite_id);
    try std.testing.expectEqual(@as(i32, 128), plus_panel.width);
    try std.testing.expectEqual(@as(i32, 128), plus_panel.height);
    try std.testing.expectEqual(@as(i32, 0), plus_panel.screen_position.y);
    try std.testing.expect(plus_panel.screen_position.x > previous_x);
    try std.testing.expect(plus_panel.tooltip != null);
    try std.testing.expectEqualStrings("+", elements.items[10].text_label.text);
    try std.testing.expect(!elements.items[10].text_label.blocks_input);
}

test "buildEditorInspectorPanel: toggle button always, background panel only when open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const player_one: types.Color = .{ .r = 30, .g = 30, .b = 30 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, player_one, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    // Select tool, empty selection: the open panel carries the PLAYER
    // content (the fallback target) — ALL SECTIONS COLLAPSED by default:
    // five headers (+ markers) + spacers, everything fits, no scrollbar.
    const editor: types.Editor = .{};

    // Open (the default): toggle 3 + background panel + 5 section
    // headers × (panel + button + label) = 19 elements.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(usize, 19), elements.items.len);
        try expectInspectorToggleShape(&elements);
        try expectInspectorLabels(&elements, &.{ "+ Player", "+ Weapons", "+ Gear", "+ Utility skills", "+ Inventory" });
        // The player content tints with the PLAYER gradient (the strip at
        // element 4 uses gradient[5]).
        try std.testing.expectEqual(player_five, elements.items[4].nine_slice_panel.color);

        // The background panel: flush left, below the button, down to one
        // ui_gap above the expanded palette groups' header strip, tinted
        // darkest (the background-panel class — button panels tint
        // gradient[5]).
        const panel = elements.items[3].nine_slice_panel;
        try std.testing.expectEqualStrings("ui/panel", panel.sprite_id);
        try std.testing.expectEqual(@as(i32, 0), panel.screen_position.x);
        try std.testing.expectEqual(top_bar_height + ui_gap + editor_header_strip_height + ui_gap, panel.screen_position.y);
        try std.testing.expectEqual(editor_inspector_width, panel.width);
        // The expanded header strip's top (buildEditorBottomBar's
        // `bar.y - ui_gap - editor_header_strip_height`) sits one ui_gap
        // below the panel's bottom.
        const expanded_header_top = types.reference_height - bottom_bar_height - ui_gap - editor_header_strip_height;
        try std.testing.expectEqual(expanded_header_top - ui_gap, panel.screen_position.y + panel.height);
        try std.testing.expectEqual(theme.darkest, panel.color);
        try std.testing.expect(panel.blocks_input);
        // The builder draws exactly the shared rect fn — the M2 press
        // arbitration (`textEditPressProceeds`) reads the same geometry,
        // so the two cannot drift.
        try std.testing.expectEqual(
            editorInspectorPanelRect(),
            Rectangle{
                .x = panel.screen_position.x,
                .y = panel.screen_position.y,
                .width = panel.width,
                .height = panel.height,
            },
        );
    }

    // Closed: just the toggle (3 elements), no longer highlighted.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, false, &ui_state);
        try std.testing.expectEqual(@as(usize, 3), elements.items.len);
        try expectInspectorToggleShape(&elements);
    }
}

test "buildEditorInspectorPanel content: enemy tool rows windowed + clamped, scrollbar on overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, black, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton", .team = 1 } },
    };
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // 45 row units (6 sections × 1 + 17 two-unit entries — 4 identity
    // fields, 4 stats, 2 weapon slots, 5 gear slots, the utility-skill
    // row, the add-layer row — + 5 spacers); the panel fits 10 units, so
    // 35 units scroll + the scrollbar shows.
    const visible_rows = @divFloor(
        editorInspectorPanelRect().height - 2 * ui_gap,
        editor_inspector_row_height,
    );
    try std.testing.expectEqual(@as(i32, 10), visible_rows);

    // Scroll 0: units 0..10 — Identity, Name, Sprite, Color, Displays
    // weapons, then the section-break spacer (the Stats header starts at
    // 10 and needs the spacer's unit too → next window).
    // Elements: toggle 3 + bg 1 + Identity 3 (panel + button + label) +
    // Name 1 (text field) + Sprite 3 (panel + picker button + label) +
    // Color
    // (label + 6 swatch fills + 6 swatch buttons = 13) + Displays weapons
    // (label + panel + button + value label = 4) + scrollbar 2 = 29.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(usize, 32), elements.items.len);
        try expectInspectorLabels(&elements, &.{ "- Identity", "Name", "Sprite", "(none)", "Color", "Displays weapons", "true" });
        // 6 swatch fills + the 2 scrollbar rects.
        try std.testing.expectEqual(@as(usize, 8), countSolidRects(&elements));
    }

    // Scroll 3: the window opens at Sprite and runs through the spacer +
    // the Stats header + Max health (Defense doesn't fully fit).
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 3, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "Sprite", "(none)", "Color", "Displays weapons", "true", "- Stats", "Max health" });
    }

    // Out-of-range scroll clamps to max (45 − 10 = 35, the five spacers
    // included): the window is the last gear slot + the utility section +
    // the skill row + the Layers tail.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 999, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(i32, 35), ui_state.editor_inspector_scroll);
        try expectInspectorLabels(&elements, &.{
            "Boots", "Add", "- Utility skills", "Skill bar", "- Layers", "Add layer", "Pick sprite",
        });
        // The skill row: five 128×128 picker buttons — three empty (the
        // diamond sprite) and this template has no skills equipped, so
        // all five are empty diamonds.
        var picker_slot_buttons: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .open_editor_skill_picker) {
                picker_slot_buttons += 1;
                try std.testing.expectEqualStrings("ui/skill_slot_empty", button.sprite_id.?);
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 5), picker_slot_buttons);
    }

    // Negative scroll clamps to 0.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = -4 };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(i32, 0), ui_state.editor_inspector_scroll);
    }

    // A stale tool id (the type deleted mid-edit) falls back to the PLAYER
    // content — its scroll CLAMPS (31 units − 10 visible = 21), no reset;
    // the bottom window lands on the last gear slot + utility + inventory.
    {
        const stale_editor: types.Editor = .{
            .entity_types = &entity_types,
            .active_tool = .{ .entity_type = 7 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 999, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, stale_editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(i32, 21), ui_state.editor_inspector_scroll);
        try expectInspectorLabels(&elements, &.{ "Boots", "Add", "- Utility skills", "Skill bar", "- Inventory", "Items", "0" });
        // No swatches in the window — only the scrollbar rects are solid.
        try std.testing.expectEqual(@as(usize, 2), countSolidRects(&elements));
    }
}

test "inspector utility-skill row: occupied slots show the skill, empty the diamond" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // Slot 1 carries blink, the rest are empty.
    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton", .template = .{
        .equipped_utility_skills = .{ null, .blink, null, null, null },
    } }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    // Scroll to the bottom — the window lands on the skill row.
    var elements: UiElementList = .empty;
    var ui_state: UiState = .{ .editor_inspector_scroll = 999, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
    try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);

    // Five picker buttons: blink's slot is the skill button, the rest
    // the empty diamond. Every slot rides its index.
    var slot_buttons: usize = 0;
    var blink_slot: ?u32 = null;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .open_editor_skill_picker) {
            slot_buttons += 1;
            if (button.editor_utility_slot == 1) {
                try std.testing.expectEqualStrings("ui/skill_button", button.sprite_id.?);
                blink_slot = button.editor_utility_slot;
            } else {
                try std.testing.expectEqualStrings("ui/skill_slot_empty", button.sprite_id.?);
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 5), slot_buttons);
    try std.testing.expectEqual(@as(?u32, 1), blink_slot);

    // The occupied slot carries the full-size skill icon (the entity-
    // inspect look) with the icon tint from the gradient's index 1 — and
    // the row's geometry: 128×128 cells pitched 128 + ui_gap.
    var saw_blink_icon = false;
    for (elements.items) |element| switch (element) {
        .image => |image| if (std.mem.eql(u8, image.sprite_id, skillIconSpriteId(.blink))) {
            saw_blink_icon = true;
            try std.testing.expectEqual(@as(i32, 128), image.width);
            try std.testing.expectEqual(@as(i32, 128), image.height);
        },
        else => {},
    };
    try std.testing.expect(saw_blink_icon);

    // Slot pitch: consecutive picker buttons advance by 128 + ui_gap.
    var previous_x: ?i32 = null;
    var pitches: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .open_editor_skill_picker) {
            if (previous_x) |x| {
                try std.testing.expectEqual(editor_inspector_row_height + ui_gap, button.screen_position.x - x);
                pitches += 1;
            }
            previous_x = button.screen_position.x;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), pitches);
}

test "inspector player content: gear + skills + inventory over player_def, commits target player_def" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, black, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // An equipped loadout: a main-hand weapon, an amulet, blink in slot 0,
    // two inventory items.
    var inventory: types.Inventory = .{};
    inventory.slots[3] = .{ .weapon = .{ .name = "Spare Sword", .weapon_type = .sword, .weapon_damage = 2 } };
    inventory.slots[4] = .{ .weapon = .{ .name = "Spare Axe", .weapon_type = .axe, .weapon_damage = 2 } };
    const editor: types.Editor = .{
        .player_def = .{ .id = "Player", .template = .{
            .name = "New Player",
            .main_hand_weapon = .{ .name = "Starter Sword", .weapon_type = .sword, .weapon_damage = 3 },
            .amulet = .{ .name = "Starter Amulet", .spell_damage = 3 },
            .equipped_utility_skills = .{ .blink, null, null, null, null },
            .inventory = inventory,
        } },
        .active_tool = .select,
        .selection = &.{.{ .player_start = {} }},
    };

    // Window [7,17): the main hand's slot row + its item fields + the
    // off-hand row + the Gear header. The weapon's text fields carry
    // `.player_def` — the player content's commits route there.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 7, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "Main hand", "Delete", "Main hand name", "Main hand damage", "Off hand", "- Gear" });
        const name_field = findTextField(&elements, .{ .item_name = .main_hand }).?;
        try std.testing.expectEqualStrings("Starter Sword", name_field.text);
        try std.testing.expectEqual(types.TextEditTarget{ .entity = .player_def }, name_field.ref.target);
        const damage_field = findTextField(&elements, .{ .item_stat = .{ .slot = .main_hand, .stat = .weapon_damage } }).?;
        try std.testing.expectEqualStrings("3", damage_field.text);
        // The equipped hand shows its Delete (not Add).
        var main_hand_delete = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .delete_editor_item and
                button.editor_gear_slot.? == .main_hand)
            {
                main_hand_delete = true;
            },
            else => {},
        };
        try std.testing.expect(main_hand_delete);
    }

    // Bottom window: the skill row (blink occupied in slot 0, the rest
    // diamonds) + the inventory summary counting the two items.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_scroll = 999, .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{ "Boots", "Add", "- Utility skills", "Skill bar", "- Inventory", "Items", "2" });
        var occupied_slots: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .open_editor_skill_picker) {
                if (button.editor_utility_slot == 0) {
                    try std.testing.expectEqualStrings("ui/skill_button", button.sprite_id.?);
                    occupied_slots += 1;
                } else {
                    try std.testing.expectEqualStrings("ui/skill_slot_empty", button.sprite_id.?);
                }
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), occupied_slots);
    }
}

/// All inspector sections expanded — the content tests' standard state
/// (the shipped default is ALL COLLAPSED; see
/// `UiState.editor_inspector_section_expanded`). Pub for the main.zig
/// focus-on-click test, which builds the inspector through the real view.
pub fn allInspectorSectionsExpanded() [editor_inspector_section_count]bool {
    return .{true} ** editor_inspector_section_count;
}

/// Assert the inspector's content labels, in order, skipping the toggle
/// button's own "Inspector" label (elements 0-2 are the toggle group, 3
/// the background panel).
fn expectInspectorLabels(elements: *const UiElementList, expected: []const []const u8) !void {
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(std.testing.allocator);
    for (elements.items[4..]) |element| switch (element) {
        .text_label => |label| try labels.append(std.testing.allocator, label.text),
        else => {},
    };
    try std.testing.expectEqual(expected.len, labels.items.len);
    for (expected, labels.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

fn countSolidRects(elements: *const UiElementList) usize {
    var count: usize = 0;
    for (elements.items) |element| switch (element) {
        .solid_rect => count += 1,
        else => {},
    };
    return count;
}

/// Shared shape checks for the inspector toggle button (the level-tab
/// visual class): panel-backed cell flush left below the options button,
/// 128 high, label + side padding wide, spriteless button carrying the
/// action + tooltip. Never highlighted (the label carries the state).
fn expectInspectorToggleShape(elements: *const UiElementList) !void {
    const panel = elements.items[0].nine_slice_panel;
    try std.testing.expectEqualStrings("ui/panel", panel.sprite_id);
    try std.testing.expectEqual(@as(i32, 0), panel.screen_position.x);
    try std.testing.expectEqual(top_bar_height + ui_gap, panel.screen_position.y);
    try std.testing.expectEqual(editor_header_strip_height, panel.height);
    try std.testing.expect(panel.width >= editor_header_strip_height);

    const button = elements.items[1].button;
    try std.testing.expectEqual(Action.toggle_editor_inspector, button.action);
    try std.testing.expect(!button.highlighted);
    try std.testing.expect(button.sprite_id == null);
    try std.testing.expect(button.tooltip != null);

    const label = elements.items[2].text_label;
    try std.testing.expectEqualStrings("Inspector", label.text);
    try std.testing.expect(!label.blocks_input);
}

test "buildEditorBottomBar: fixed tools + palette groups + plus cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const world_one: types.Color = .{ .r = 10, .g = 10, .b = 10 };
    const enemy_two: types.Color = .{ .r = 20, .g = 20, .b = 20 };
    const player_one: types.Color = .{ .r = 30, .g = 30, .b = 30 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = .{ black, world_one, black, black, black, black } },
        .enemy_gradient = .{ .colors = .{ black, black, enemy_two, black, black, black } },
        .player_gradient = .{ .colors = .{ black, player_one, black, black, black, player_five } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    var entity_template: types.Entity = .{};
    entity_template.sprite = "skeleton";
    entity_template.color_index = 2;
    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton Warrior", .template = entity_template },
    };
    const decoration_types = [_]types.DecorationTypeDef{
        .{ .id = "Ruin", .sprite = "ruin_1", .pixel_dims = .{ .x = 512, .y = 512 } },
    };
    const item_types = [_]types.ItemTypeDef{
        .{ .id = "Iron Sword", .item = .{ .weapon = .{} } },
    };
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
        .item_types = &item_types,
    };

    var elements: UiElementList = .empty;
    var scroll_offsets: [3]i32 = .{ 0, 0, 0 };
    var collapsed: [3]bool = .{ false, false, false };
    try buildEditorBottomBar(
        &elements,
        arena.allocator(),
        metrics,
        screenRect(),
        editor,
        theme,
        &scroll_offsets,
        &collapsed,
        .select,
    );

    // 2 fixed tools x (bg + graphic) + 3 groups x (header panel + button
    // + label + plus (panel + glyph) + type (bg + graphic)) = 4 + 21.
    try std.testing.expectEqual(@as(usize, 25), elements.items.len);

    // Every tool graphic sits on a button_background cell at the bottom of the
    // screen: 5 tool cells (2 fixed + 3 palette types) — the "+" cells are
    // square ui/panel cells in the header strip, out of the bar band.
    var background_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.sprite_id != null and
                std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id) and
                button.screen_position.y >= types.reference_height - bottom_bar_height)
            {
                background_count += 1;
                try std.testing.expectEqual(bottom_bar_height, button.height);
                try std.testing.expectEqual(
                    types.reference_height - bottom_bar_height,
                    button.screen_position.y,
                );
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 5), background_count);

    // Fixed tools: Select uses tile_highlight frame 0 (a source rectangle,
    // not the whole 1024-wide sheet); Tile uses world/tile tinted with the
    // world gradient index 1.
    var found_select_frame = false;
    var found_tile = false;
    var found_enemy = false;
    var found_decoration = false;
    var found_item = false;
    for (elements.items) |element| switch (element) {
        .image => |image| {
            if (std.mem.eql(u8, image.sprite_id, "world/tile_highlight")) {
                found_select_frame = image.source_rectangle != null;
            } else if (std.mem.eql(u8, image.sprite_id, "world/tile")) {
                found_tile = std.meta.eql(image.color, world_one);
            } else if (std.mem.eql(u8, image.sprite_id, "entities/skeleton")) {
                found_enemy = std.meta.eql(image.color, enemy_two) and
                    image.width == 204 and image.height == 256;
            } else if (std.mem.eql(u8, image.sprite_id, "decorations/ruin_1")) {
                found_decoration = image.width == 256 and image.height == 256;
            } else if (std.mem.eql(u8, image.sprite_id, "items/sword")) {
                found_item = std.meta.eql(image.color, player_one) and
                    image.width == 256 and image.height == 256;
            }
        },
        else => {},
    };
    try std.testing.expect(found_select_frame);
    try std.testing.expect(found_tile);
    try std.testing.expect(found_enemy);
    try std.testing.expect(found_decoration);
    try std.testing.expect(found_item);

    // Three group headers + three "+" glyphs, all non-blocking overlays.
    // Headers sit ABOVE the bar (the strip the in-game indicators use),
    // left-aligned with their group's first cell; the "+" glyphs center on
    // their square panel cells beside the headers.
    var header_count: usize = 0;
    var enemies_header: ?types.ScreenPosition = null;
    var enemies_header_button: ?types.ScreenPosition = null;
    var first_enemy_cell: ?types.ScreenPosition = null;
    const header_top: i32 = types.reference_height - bottom_bar_height - ui_gap - editor_header_strip_height;
    var enemy_cell_index: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.editor_group == 0) enemies_header_button = button.screen_position;
            if (button.sprite_id != null and
                std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id) and
                button.screen_position.y >= types.reference_height - bottom_bar_height)
            {
                // Cells emit in order: Select, Tile, enemy, …
                if (enemy_cell_index == 2) first_enemy_cell = button.screen_position;
                enemy_cell_index += 1;
            }
        },
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "Enemies")) {
                enemies_header = label.screen_position;
                try std.testing.expect(!label.blocks_input);
            } else if (std.mem.eql(u8, label.text, "+") or
                std.mem.eql(u8, label.text, "Decorations") or
                std.mem.eql(u8, label.text, "Ground Items"))
            {
                header_count += 1;
                try std.testing.expect(!label.blocks_input);
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 5), header_count);
    try std.testing.expect(enemies_header != null);
    try std.testing.expect(enemies_header_button != null);
    try std.testing.expect(first_enemy_cell != null);
    // Label is centered in the 128-high header button.
    try std.testing.expectEqual(
        header_top + @divTrunc(editor_header_strip_height - editor_group_header_font_size, 2),
        enemies_header.?.y,
    );
    // The header BUTTON is left-aligned with the group's first cell.
    try std.testing.expectEqual(first_enemy_cell.?.x, enemies_header_button.?.x);
}

test "buildEditorBottomBar: collapsed groups sit flush bottom; expanded hover above" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton" }};
    const editor: types.Editor = .{ .entity_types = &entity_types };

    var elements: UiElementList = .empty;
    var scroll_offsets: [3]i32 = .{ 0, 0, 0 };
    // Enemies (group 0) expanded; Decorations + Ground Items collapsed.
    var collapsed: [3]bool = .{ false, true, true };
    try buildEditorBottomBar(
        &elements,
        arena.allocator(),
        metrics,
        screenRect(),
        editor,
        theme,
        &scroll_offsets,
        &collapsed,
        .select,
    );

    const flush_bottom_y = types.reference_height - editor_header_strip_height;
    const hovering_y = types.reference_height - bottom_bar_height - ui_gap - editor_header_strip_height;

    // Expanded group 0: header + "+" hover in the strip above the bar,
    // and its type cell is in the bar band.
    // Collapsed groups 1 + 2: header + "+" sit flush against the bottom
    // of the screen, and emit no type cells.
    var group_header_y: [3]?i32 = .{ null, null, null };
    var plus_panels: usize = 0;
    var bar_band_tool_cells: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.editor_group) |group_index| {
                group_header_y[group_index] = button.screen_position.y;
            }
            if (button.sprite_id != null and
                std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id) and
                button.screen_position.y >= types.reference_height - bottom_bar_height)
            {
                bar_band_tool_cells += 1;
            }
        },
        .nine_slice_panel => |panel| {
            // The three "+" cells: square ui/panel cells (their y is asserted
            // via the paired "+" glyphs below).
            if (panel.width == editor_plus_size and panel.height == editor_plus_size) {
                plus_panels += 1;
            }
        },
        else => {},
    };

    // Tool cells: 2 fixed + the 1 expanded enemy type (collapsed groups
    // contribute none).
    try std.testing.expectEqual(@as(usize, 3), bar_band_tool_cells);

    try std.testing.expectEqual(hovering_y, group_header_y[0].?);
    try std.testing.expectEqual(flush_bottom_y, group_header_y[1].?);
    try std.testing.expectEqual(flush_bottom_y, group_header_y[2].?);

    // The "+" panels pair with their group headers by adjacency: group 0's
    // plus hovers, groups 1 + 2's sit flush bottom. Assert via the glyph
    // labels' y instead of x bookkeeping (each "+" glyph centers on its
    // panel).
    var plus_glyph_ys: [3]i32 = undefined;
    var plus_ys_found: usize = 0;
    var decoration_header_x: ?i32 = null;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.editor_group == 1) decoration_header_x = button.screen_position.x;
        },
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "+")) {
                plus_glyph_ys[plus_ys_found] = label.screen_position.y;
                plus_ys_found += 1;
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), plus_panels);
    try std.testing.expectEqual(@as(usize, 3), plus_ys_found);
    // Emission order is group order, so glyph 0 hovers, 1 + 2 flush bottom.
    try std.testing.expectEqual(
        hovering_y + @divTrunc(editor_header_strip_height - editor_group_header_font_size, 2),
        plus_glyph_ys[0],
    );
    try std.testing.expectEqual(
        flush_bottom_y + @divTrunc(editor_header_strip_height - editor_group_header_font_size, 2),
        plus_glyph_ys[1],
    );
    try std.testing.expectEqual(
        flush_bottom_y + @divTrunc(editor_header_strip_height - editor_group_header_font_size, 2),
        plus_glyph_ys[2],
    );
    try std.testing.expect(decoration_header_x != null);
}

test "buildEditorBottomBar: group window clamps to max 8 tools + scrolls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // 12 decorations → window of 8, max offset 4. All others sized 1.
    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton" }};
    var decoration_types: [12]types.DecorationTypeDef = undefined;
    for (&decoration_types, 0..) |*type_definition, index| {
        type_definition.* = .{
            .id = try std.fmt.allocPrint(arena.allocator(), "Ruin {d}", .{index}),
            .sprite = "ruin_1",
            .pixel_dims = .{ .x = 512, .y = 512 },
        };
    }
    const item_types = [_]types.ItemTypeDef{.{ .id = "Iron Sword" }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
        .item_types = &item_types,
    };

    var elements: UiElementList = .empty;
    var scroll_offsets: [3]i32 = .{ 0, 99, 0 }; // over-scrolled → clamps to 4
    var collapsed: [3]bool = .{ false, false, false };
    try buildEditorBottomBar(
        &elements,
        arena.allocator(),
        metrics,
        screenRect(),
        editor,
        theme,
        &scroll_offsets,
        &collapsed,
        .select,
    );

    // The over-scrolled offset clamps to size - max = 12 - 8 = 4; negative
    // would clamp to 0.
    try std.testing.expectEqual(@as(i32, 4), scroll_offsets[1]);

    // Count decoration tool cells: exactly 8 (the window). Tooltips live
    // on the button_background image, which is emitted immediately BEFORE
    // its graphic — pair them by position. The window starting at 4 shows
    // types 4..11 — the FIRST type ("Ruin 0") is NOT among them, the LAST
    // ("Ruin 11") is.
    var decoration_cells: usize = 0;
    var found_first = false;
    var found_last = false;
    var previous_tooltip: ?Tooltip = null;
    for (elements.items) |element| switch (element) {
        .button => |button| previous_tooltip = button.tooltip,
        .image => |image| {
            if (std.mem.eql(u8, image.sprite_id, "decorations/ruin_1")) {
                decoration_cells += 1;
                const tooltip = previous_tooltip.?; // button precedes its graphic
                const header = tooltip.header.?[0].text;
                if (std.mem.eql(u8, header, "Ruin 0")) found_first = true;
                if (std.mem.eql(u8, header, "Ruin 11")) found_last = true;
            }
        },
        else => {
            previous_tooltip = null;
        },
    };
    try std.testing.expectEqual(@as(usize, 8), decoration_cells);
    try std.testing.expect(!found_first);
    try std.testing.expect(found_last);

    // Group detection: pointer over a decoration cell maps to group 1
    // (Decorations); over a fixed tool or above the bar maps to null.
    const tool_backgrounds: usize = blk: {
        var count: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.sprite_id != null and std.mem.eql(
                u8,
                button.sprite_id.?,
                button_background_sprite_id,
            ) and button.screen_position.y >= types.reference_height - bottom_bar_height)
            {
                count += 1;
            },
            else => {},
        };
        break :blk count;
    };
    // 2 fixed + 1 enemy + 8 decorations + 1 item (pluses are in the
    // header strip, out of the bar band).
    try std.testing.expectEqual(@as(usize, 12), tool_backgrounds);

    // The 5th background cell (index 4) is the first decoration window
    // cell — cells are emitted in order: Select, Tile, enemy, enemy-plus,
    // decorations (8), decoration-plus, item, item-plus.
    var cell_index: usize = 0;
    var decoration_cell_center: ?types.ScreenPosition = null;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            if (button.sprite_id == null) continue;
            if (!std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id)) continue;
            if (button.screen_position.y < types.reference_height - bottom_bar_height) continue;
            defer cell_index += 1;
            if (cell_index == 4) {
                decoration_cell_center = .{
                    .x = button.screen_position.x + @divTrunc(button.width, 2),
                    .y = button.screen_position.y + @divTrunc(button.height, 2),
                };
            }
        },
        else => {},
    };
    try std.testing.expect(decoration_cell_center != null);
    try std.testing.expectEqual(
        @as(?usize, 1),
        editorPaletteGroupAt(editor, collapsed, elements.items, decoration_cell_center.?),
    );
    // Above the bar: null regardless of x.
    try std.testing.expectEqual(
        @as(?usize, null),
        editorPaletteGroupAt(editor, collapsed, elements.items, .{ .x = decoration_cell_center.?.x, .y = 0 }),
    );
    // Fixed tool (first cell): null — not a palette group.
    var first_cell_center: ?types.ScreenPosition = null;
    {
        var index: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.sprite_id != null and
                    std.mem.eql(u8, button.sprite_id.?, button_background_sprite_id) and
                    button.screen_position.y >= types.reference_height - bottom_bar_height)
                {
                    if (index == 0) {
                        first_cell_center = .{
                            .x = button.screen_position.x + @divTrunc(button.width, 2),
                            .y = button.screen_position.y + @divTrunc(button.height, 2),
                        };
                    }
                    index += 1;
                }
            },
            else => {},
        };
    }
    try std.testing.expect(first_cell_center != null);
    try std.testing.expectEqual(
        @as(?usize, null),
        editorPaletteGroupAt(editor, collapsed, elements.items, first_cell_center.?),
    );
}

/// Top bar: options button flush in the top-left corner, then `ui_gap`,
/// then the undo button, then the remaining width reserved for the combat
/// log (not rendered — see TODO → Combat Log). Left-anchored row mirroring
/// the bottom bar's conventions (`Row`, `ui_gap`, `slot_size`). No
/// background of its own — purely a layout region, like the bottom bar.
/// Undo is never disabled: the
/// only state with nothing to undo is a fresh main menu, where this bar is
/// not shown; `history.undo` no-ops at the earliest idle point regardless.
pub fn buildTopBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    screen: Rectangle,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    // Match the bottom-bar skip button: background = gradient[5], icon = gradient[1].
    const c_btn_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const c_btn_icon = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    var row = Row.init(screen.position(), top_bar_height, ui_gap);

    // Options button — flush in the top-left corner (no margin). Layered
    // background + icon, same as the skip button.
    const options_cell = row.next(slot_size);
    try emitIconButton(
        elements,
        allocator,
        options_cell,
        button_background_sprite_id,
        "ui/icon_options",
        .toggle_options_menu,
        .{ .header = try spanRow(allocator, text("Options")) },
        c_btn_bg,
        c_btn_icon,
        false,
        null,
    );

    // Undo button — same size, one `ui_gap` to the right of options. Same
    // layered background + icon treatment as the options button.
    const undo_cell = row.next(slot_size);
    try emitIconButton(
        elements,
        allocator,
        undo_cell,
        button_background_sprite_id,
        "ui/icon_undo",
        .undo,
        .{ .header = try spanRow(allocator, text("Undo")) },
        c_btn_bg,
        c_btn_icon,
        false,
        null,
    );
}

/// Build the mission-complete overlay: a full-screen 9-slice panel with a
/// "{mission_name} completed" header centered at the top, a centered "New
/// clone: [icons]" summary line below it, a two-column area (left stats,
/// right clone-harvest rewards with its own sub-header) extending downward,
/// and Continue + Replay Mission (+ Overwrite Clone if offered) buttons side
/// by side at the bottom. Rendered when `GameState.last_completed_mission`
/// is set (the player completed the last level of a mission; the cascade has
/// already transitioned to the hub). See DESIGN → Architecture + DESIGN →
/// Clones (clone system).
pub fn buildMissionComplete(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    info: types.MissionCompleteInfo,
    active_theme: types.ActiveColorTheme,
) !void {
    // Button panels tint with player gradient index 5 to read as buttons
    // against the theme-`darkest` background panel.
    const button_color = active_theme.player_gradient.colors[@min(@as(u32, 5), types.gradient_color_count - 1)];
    // Full-screen panel background.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
    } });

    // ── Header: "{name} completed", centered at the top. ──
    const header_font_size: i32 = 128;
    const header_text = try std.fmt.allocPrint(allocator, "{s} completed", .{info.name});
    const header_width = font_metrics.measureSpanWidth(text(header_text), header_font_size);
    const header_box = screen.placeTopCenter(header_width, header_font_size, ui_gap * 4);
    try elements.append(allocator, .{ .text_label = .{
        .text = header_text,
        .screen_position = header_box.position(),
        .font_size = header_font_size,
        .blocks_input = false,
    } });

    // ── "New clone: [horizontal icons]" — centered below the header. ──
    // Shows the just-completed run's converted_materials (the clone's
    // rate numerator). The icon row is horizontal + compact (96px icons)
    // so the whole line reads as one summary.
    const new_clone_icon_size: i32 = 96;
    const new_clone_label_text = "New clone:";
    const new_clone_label_font_size: i32 = 64;
    const new_clone_label_width = font_metrics.measureSpanWidth(text(new_clone_label_text), new_clone_label_font_size);
    const new_clone_icon_row_width = rowWidth(5, new_clone_icon_size, ui_gap);
    const new_clone_total_width = new_clone_label_width + ui_gap + new_clone_icon_row_width;
    const new_clone_y = header_box.y + header_font_size + ui_gap * 3;
    const new_clone_start_x = screen.x + @divTrunc(screen.width - new_clone_total_width, 2);
    try elements.append(allocator, .{ .text_label = .{
        .text = new_clone_label_text,
        .screen_position = .{ .x = new_clone_start_x, .y = new_clone_y + (new_clone_icon_size - new_clone_label_font_size) / 2 },
        .font_size = new_clone_label_font_size,
        .blocks_input = false,
    } });
    try emitMaterialIcons(
        elements,
        allocator,
        font_metrics,
        .{ .x = new_clone_start_x + new_clone_label_width + ui_gap, .y = new_clone_y },
        new_clone_icon_size,
        .horizontal,
        info.converted_materials,
        active_theme,
    );

    // ── Two columns extending down from below the new-clone line. ──
    const content_y = new_clone_y + new_clone_icon_size + ui_gap * 4;

    // Left column: stats (flush left, top-aligned at content_y).
    const stat_font_size: i32 = 64;
    const stat_line_height: i32 = stat_font_size + ui_gap;
    const stat_entries = [_]struct { label: []const u8, value: u32 }{
        .{ .label = "Turns Spent", .value = info.turns_spent },
        .{ .label = "Tiles Moved", .value = info.tiles_moved },
        .{ .label = "Skills Used", .value = info.skills_used },
        .{ .label = "Damage Dealt", .value = info.damage_dealt },
        .{ .label = "Damage Taken", .value = info.damage_taken },
    };
    const stats_left = screen.x + ui_gap * 4;
    var stat_y = content_y;
    for (stat_entries) |entry| {
        const value_text = try std.fmt.allocPrint(allocator, "{d}", .{entry.value});
        const line_text = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ entry.label, value_text });
        try elements.append(allocator, .{ .text_label = .{
            .text = line_text,
            .screen_position = .{ .x = stats_left, .y = stat_y },
            .font_size = stat_font_size,
            .blocks_input = false,
        } });
        stat_y += stat_line_height;
    }

    // Right column: "Clone material harvest" sub-header + vertical material
    // icon stack (flush right, top-aligned at content_y).
    const harvest_header_font_size: i32 = 64;
    const harvest_header_text = "Clone material harvest";
    const harvest_header_width = font_metrics.measureSpanWidth(text(harvest_header_text), harvest_header_font_size);
    const material_right = screen.x + screen.width - ui_gap * 4;
    try elements.append(allocator, .{ .text_label = .{
        .text = harvest_header_text,
        .screen_position = .{ .x = material_right - harvest_header_width, .y = content_y },
        .font_size = harvest_header_font_size,
        .blocks_input = false,
    } });
    const icon_top = content_y + harvest_header_font_size + ui_gap * 2;
    try emitMaterialIcons(
        elements,
        allocator,
        font_metrics,
        .{ .x = material_right - inventory_slot_size, .y = icon_top },
        inventory_slot_size,
        .vertical,
        info.harvested_materials,
        active_theme,
    );

    // ── Bottom buttons: Replay Mission in the bottom-left corner, Continue
    //    in the bottom-right corner. Overwrite Clone (when offered) sits
    //    centered between them. ──
    const buttons_row = screen.placeBottomCenter(menu_button_width, panel_button_height, ui_gap * 4);
    const button_y = buttons_row.y;
    const margin = ui_gap * 4;
    // Replay Mission — bottom-left.
    try emitPanelButton(elements, allocator, font_metrics, .{
        .x = screen.x + margin,
        .y = button_y,
        .width = menu_button_width,
        .height = panel_button_height,
    }, "Replay Mission", menu_button_font_size, .replay_mission, button_color, null);
    // Continue — bottom-right.
    try emitPanelButton(elements, allocator, font_metrics, .{
        .x = screen.x + screen.width - margin - menu_button_width,
        .y = button_y,
        .width = menu_button_width,
        .height = panel_button_height,
    }, "Continue", menu_button_font_size, .continue_after_mission, button_color, null);
    // Overwrite Clone — centered (only when offered).
    if (info.overwrite_offered) {
        const centered = screen.placeBottomCenter(menu_button_width, panel_button_height, ui_gap * 4);
        try emitPanelButton(elements, allocator, font_metrics, centered, "Overwrite Clone", menu_button_font_size, .overwrite_clone, button_color, null);
    }
}

/// Build the mission-fail overlay: a full-screen 9-slice panel with a
/// large "Defeat" label centered above a two-button stack (Restart Mission,
/// Exit Mission). Rendered when the player is dead (derived from
/// `level.entities[0].current_health == 0` in view()). The buttons reuse the
/// existing `.restart_mission` / `.exit_mission` actions — same dispatch path
/// as the options menu. See DESIGN → Architecture.
pub fn buildMissionFail(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    button_color: Color,
) !void {
    // Full-screen panel background.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
    } });

    const defeat_font_size: i32 = 256;
    const defeat_label_width = font_metrics.measureSpanWidth(text("Defeat"), defeat_font_size);
    const defeat_label = screen.placeCenter(defeat_label_width, defeat_font_size);
    // Place the label above the button stack, leaving room for the buttons
    // and a gap between the label and the stack.
    const buttons_above: i32 = 2 * panel_button_height + ui_gap;
    try elements.append(allocator, .{ .text_label = .{
        .text = "Defeat",
        .screen_position = .{
            .x = defeat_label.x,
            .y = defeat_label.y - buttons_above - ui_gap - defeat_font_size,
        },
        .font_size = defeat_font_size,
        .blocks_input = false,
    } });

    const MenuButton = struct { label: []const u8, action: Action };
    const buttons = [_]MenuButton{
        .{ .label = "Restart Mission", .action = .restart_mission },
        .{ .label = "Exit Mission", .action = .exit_mission },
    };

    const total_height = rowWidth(@intCast(buttons.len), panel_button_height, ui_gap);
    const origin = screen
        .placeCenter(menu_button_width, total_height)
        .position();

    for (buttons, 0..) |menu_button, index| {
        const cell: Rectangle = .{
            .x = origin.x,
            .y = origin.y + @as(i32, @intCast(index)) * (panel_button_height + ui_gap),
            .width = menu_button_width,
            .height = panel_button_height,
        };
        try emitPanelButton(
            elements,
            allocator,
            font_metrics,
            cell,
            menu_button.label,
            menu_button_font_size,
            menu_button.action,
            button_color,
            null,
        );
    }
}

/// Build the options menu: a full-screen 9-slice panel background with a
/// centered stack of `menu_button_width` buttons (same design as the main
/// menu). Context-specific: the button list depends on the current screen.
/// Continue carries `.toggle_options_menu` (the toggle closes the menu);
/// Save carries `.save_game`. Rendered on top of the bottom bar when
/// `options_menu_open` is set, like the error popup. See DESIGN → UI
/// Framework.
pub fn buildOptionsMenu(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    current_screen: state.Screen,
    button_color: Color,
    /// Where the exported save lands, for the Export Save tooltip. Native:
    /// the resolved persistent dir (tooltip: "Saves to <dir>/saves/"). Web:
    /// null — the export IS a browser download (tooltip: "Triggers a file
    /// download"). Threaded from `SessionState.persistent_dir_path` (set
    /// once by the entry file; see its doc).
    persistent_dir_path: ?[]const u8,
) !void {
    // Full-screen panel background.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
    } });

    const MenuButton = struct { label: []const u8, action: Action, tooltip: ?Tooltip = null };
    var buttons: [8]MenuButton = undefined;
    var button_count: usize = 0;

    buttons[button_count] = .{ .label = "Continue", .action = .toggle_options_menu };
    button_count += 1;

    // Level-only exit paths (restart / exit mission). Hub has no mission in
    // progress to restart or abandon.
    if (current_screen == .level) {
        buttons[button_count] = .{ .label = "Restart Mission", .action = .restart_mission };
        button_count += 1;
        buttons[button_count] = .{ .label = "Exit Mission", .action = .exit_mission };
        button_count += 1;
    }

    // Where the exported save goes: on native, the timestamped save lands
    // in <persistent dir>/saves/ (the autosave update is a side effect); on
    // web it's offered as a browser download (no user-visible path).
    // Hidden in the editor — the save the player expects there is the
    // MISSION being edited (a separate future slice), not the campaign
    // save. `save_game` is button-only (no keybind), so hiding the button
    // removes the path entirely.
    if (current_screen != .editor) {
        const export_save_body = if (persistent_dir_path) |dir|
            try std.fmt.allocPrint(allocator, "Saves to {s}/saves/", .{dir})
        else
            "Triggers a file download";
        buttons[button_count] = .{
            .label = "Export Save",
            .action = .save_game,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(export_save_body))}) },
        };
        button_count += 1;
    }

    // Settings: opens the settings overlay on top of this one (drill-in).
    // Present in every context the options menu appears in (level + hub).
    buttons[button_count] = .{ .label = "Settings", .action = .open_settings };
    button_count += 1;

    buttons[button_count] = .{ .label = "Exit to Main Menu", .action = .exit_to_menu };
    button_count += 1;

    const total_height = rowWidth(@intCast(button_count), panel_button_height, ui_gap);
    const origin = screen
        .placeCenter(menu_button_width, total_height)
        .position();

    for (buttons[0..button_count], 0..) |menu_button, index| {
        const cell: Rectangle = .{
            .x = origin.x,
            .y = origin.y + @as(i32, @intCast(index)) * (panel_button_height + ui_gap),
            .width = menu_button_width,
            .height = panel_button_height,
        };
        try emitPanelButton(
            elements,
            allocator,
            font_metrics,
            cell,
            menu_button.label,
            menu_button_font_size,
            menu_button.action,
            button_color,
            menu_button.tooltip,
        );
    }
}

/// Build the main-menu button stack: fixed-size buttons centered as a group
/// on `screen`, spaced by `ui_gap`, each with a centered text label. The
/// Continue button is emitted only when `continue_available` (there is a game
/// to resume — populated PlayerData).
pub fn buildMainMenu(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    continue_available: bool,
    button_color: Color,
) !void {
    const MenuButton = struct { label: []const u8, action: Action };
    var buttons: [6]MenuButton = undefined;
    var button_count: usize = 0;
    if (continue_available) {
        buttons[button_count] = .{ .label = "Continue", .action = .continue_game };
        button_count += 1;
    }
    buttons[button_count] = .{ .label = "New Game", .action = .new_game };
    button_count += 1;
    buttons[button_count] = .{ .label = "Load Save", .action = .toggle_load_save_menu };
    button_count += 1;
    // Dev entry point (hardcoded beginnings mission).
    buttons[button_count] = .{ .label = "Editor", .action = .open_editor };
    button_count += 1;
    buttons[button_count] = .{ .label = "Settings", .action = .open_settings };
    button_count += 1;
    buttons[button_count] = .{ .label = "Credits", .action = .open_credits };
    button_count += 1;

    const total_height = rowWidth(@intCast(button_count), panel_button_height, ui_gap);
    // The title + button stack center together as one block: title band on
    // top of the stack, both centered by one `placeCenter` over the combined
    // height. Gap between title and first button = `main_menu_title_gap`.
    const title = "taplop";
    const title_width = font_metrics.measureSpanWidth(text(title), main_menu_title_font_size);
    const block_height = main_menu_title_gap + main_menu_title_font_size + total_height;
    const origin = screen
        .placeCenter(menu_button_width, block_height)
        .position();

    try elements.append(allocator, .{ .text_label = .{
        .text = title,
        .screen_position = .{
            .x = origin.x + @divTrunc(menu_button_width - title_width, 2),
            .y = origin.y,
        },
        .font_size = main_menu_title_font_size,
        .blocks_input = false,
    } });
    const buttons_origin_y = origin.y + main_menu_title_gap + main_menu_title_font_size;

    for (buttons[0..button_count], 0..) |menu_button, index| {
        const cell: Rectangle = .{
            .x = origin.x,
            .y = buttons_origin_y + @as(i32, @intCast(index)) * (panel_button_height + ui_gap),
            .width = menu_button_width,
            .height = panel_button_height,
        };
        try emitPanelButton(
            elements,
            allocator,
            font_metrics,
            cell,
            menu_button.label,
            menu_button_font_size,
            menu_button.action,
            button_color,
            null,
        );
    }
}

// --- Load-save browser (main menu, full screen) ---

pub const load_save_header_font_size: i32 = 72;
pub const load_save_header_gap: i32 = 32;
pub const load_save_row_font_size: i32 = 56;
/// One save row's height. The scroll unit is the full row PITCH (height +
/// gap) so scrolled text sits at identical y positions at every offset.
pub const load_save_row_height: i32 = 112;
pub const load_save_row_gap: i32 = 8;
pub const load_save_padding: i32 = 48;
pub const load_save_button_gap: i32 = 48; // gap between rows region and bottom buttons
pub const load_save_scrollbar_width: i32 = 12;
pub const load_save_scrollbar_gap: i32 = 16;
/// Import/Back button size (bottom corners). Import label is long, so the
/// buttons are wider than tall menu buttons but reuse the menu font.
pub const load_save_button_width: i32 = 768;

/// Build the load-save browser: a full-screen modal panel listing
/// `save_files` (newest first — the slice arrives pre-sorted from
/// `FileSource.listSaveFiles`), one clickable row per save, a Back button
/// bottom-left and (web only) an Import button bottom-right.
/// Overflowing lists scroll: only the visible row window is emitted and a
/// scrollbar is drawn. `scroll_offset` is in rows and clamped here to
/// `[0, max_scroll_row]` (the view is the only place that knows the max,
/// which depends on the row count). Barebones by design (see TODO →
/// Platform Layer for the future polish slice).
pub fn buildLoadSavePanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    save_files: []const @import("file_source.zig").SaveFileEntry,
    scroll_offset: *i32,
    button_color: Color,
) !void {
    // Full-screen modal background — blocks input to the main-menu buttons
    // behind it.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .blocks_input = true,
    } });

    const content_x = screen.x + load_save_padding;
    const content_width = screen.width - 2 * load_save_padding;

    // Header.
    const header_y = screen.y + load_save_padding;
    try elements.append(allocator, .{ .text_label = .{
        .text = "Load Save",
        .screen_position = .{ .x = content_x, .y = header_y },
        .font_size = load_save_header_font_size,
        .blocks_input = false,
    } });

    // Rows region: from below the header to above the bottom buttons.
    const rows_y = header_y + lineHeight(load_save_header_font_size) + load_save_header_gap;
    const rows_bottom = screen.y + screen.height - load_save_padding -
        panel_button_height - load_save_button_gap;
    const rows_height = rows_bottom - rows_y;
    const row_pitch = load_save_row_height + load_save_row_gap;
    const visible_rows: usize = @intCast(@max(0, @divTrunc(rows_height, row_pitch)));

    // Clamp the scroll offset (authoritative — the input handler can't know
    // max_scroll_row without the row count).
    const total_rows: usize = save_files.len;
    const max_scroll_row: i32 = @intCast(total_rows - @min(total_rows, visible_rows));
    if (scroll_offset.* < 0) scroll_offset.* = 0;
    if (scroll_offset.* > max_scroll_row) scroll_offset.* = max_scroll_row;
    const scrolls = total_rows > visible_rows;

    if (total_rows == 0) {
        try elements.append(allocator, .{ .text_label = .{
            .text = "No save files",
            .screen_position = .{ .x = content_x, .y = rows_y },
            .font_size = load_save_row_font_size,
            .blocks_input = false,
        } });
    } else {
        // Rows widen right up to the scrollbar gutter when one is drawn.
        const rows_width = if (scrolls)
            content_width - load_save_scrollbar_width - load_save_scrollbar_gap
        else
            content_width;

        const first: usize = @intCast(scroll_offset.*);
        const last_exclusive = @min(total_rows, first + visible_rows);
        for (first..last_exclusive) |index| {
            const cell: Rectangle = .{
                .x = content_x,
                .y = rows_y + @as(i32, @intCast(index - first)) * row_pitch,
                .width = rows_width,
                .height = load_save_row_height,
            };
            try elements.append(allocator, .{ .nine_slice_panel = .{
                .sprite_id = "ui/panel",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
            } });
            try elements.append(allocator, .{ .button = .{
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .load_save_row,
                .ref = .{ .save_file = @intCast(index) },
            } });
            // Label: filename minus extension, centered like a panel button
            // label (horizontal via measurement, vertical via the glyph cell).
            const file = save_files[index];
            const label = file.name[0 .. file.name.len - ".txt".len];
            const label_width = font_metrics.measureSpanWidth(text(label), load_save_row_font_size);
            const label_box = cell.placeCenter(label_width, load_save_row_font_size);
            try elements.append(allocator, .{ .text_label = .{
                .text = label,
                .screen_position = label_box.position(),
                .font_size = load_save_row_font_size,
                .blocks_input = false,
            } });
        }

        // Scrollbar: track + proportional thumb along the rows region, same
        // fixed grays as the error popup's scrollbar.
        if (scrolls) {
            const scrollbar_x = content_x + content_width - load_save_scrollbar_width;
            const track_color: types.Color = .{ .r = 80, .g = 80, .b = 80 };
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = scrollbar_x, .y = rows_y },
                .width = load_save_scrollbar_width,
                .height = rows_height,
                .color = track_color,
            } });
            const visible_span_rows: i32 = @intCast(@min(total_rows, visible_rows));
            const track_travel = rows_height - visible_span_rows * row_pitch;
            const thumb_height = @max(@as(i32, 40), visible_span_rows * row_pitch);
            const thumb_y = rows_y + if (max_scroll_row == 0)
                0
            else
                @divTrunc(scroll_offset.* * track_travel, max_scroll_row);
            const thumb_color: types.Color = .{ .r = 180, .g = 180, .b = 180 };
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = scrollbar_x, .y = thumb_y },
                .width = load_save_scrollbar_width,
                .height = thumb_height,
                .color = thumb_color,
            } });
        }
    }

    // Bottom corners: Back (always) + Import (web only).
    const button_y = screen.y + screen.height - load_save_padding - panel_button_height;
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = content_x,
            .y = button_y,
            .width = load_save_button_width,
            .height = panel_button_height,
        },
        "Back",
        menu_button_font_size,
        .toggle_load_save_menu,
        button_color,
        null,
    );
    if (@import("builtin").os.tag == .emscripten) {
        try emitPanelButton(
            elements,
            allocator,
            font_metrics,
            .{
                .x = screen.x + screen.width - load_save_padding - load_save_button_width,
                .y = button_y,
                .width = load_save_button_width,
                .height = panel_button_height,
            },
            "Import",
            menu_button_font_size,
            .import_save,
            button_color,
            null,
        );
    }
}

// --- Credits screen (main menu, full screen) ---

pub const credits_header_font_size: i32 = 96;
pub const credits_header_gap: i32 = 80;
/// Name line font size — larger than the roles line so each person reads
/// as a heading above their credits.
pub const credits_name_font_size: i32 = 72;
/// Roles line font size — the credit detail under each name.
pub const credits_role_font_size: i32 = 48;
/// Gap between a person's name and their roles line.
pub const credits_name_to_role_gap: i32 = 16;
/// Gap between each person block (name + roles).
pub const credits_person_gap: i32 = 64;
pub const credits_padding: i32 = 48;
pub const credits_button_gap: i32 = 48;
/// Back button size (bottom-left). Matches the load-save Back button so the
/// two main-menu overlays feel consistent.
pub const credits_button_width: i32 = 768;

/// Build the credits screen: a full-screen modal panel with a centered
/// "Credits" header, three person blocks (name in a larger font above their
/// roles in a smaller font, gaps between each person), and a Back button in
/// the bottom-left. The panel blocks input to the main-menu buttons behind
/// it. The Back button reuses the `.open_credits` action (toggle semantics —
/// same pattern as the load-save browser's Back button).
pub fn buildCreditsPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    button_color: Color,
) !void {
    // Full-screen modal background — blocks input to the main-menu buttons
    // behind it.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .blocks_input = true,
    } });

    const content_x = screen.x + credits_padding;
    const content_width = screen.width - 2 * credits_padding;

    // Header, centered horizontally near the top.
    const header_text = "Credits";
    const header_width = font_metrics.measureSpanWidth(text(header_text), credits_header_font_size);
    const header_x = content_x + @divTrunc(content_width - header_width, 2);
    const header_y = screen.y + credits_padding;
    try elements.append(allocator, .{ .text_label = .{
        .text = header_text,
        .screen_position = .{ .x = header_x, .y = header_y },
        .font_size = credits_header_font_size,
        .blocks_input = false,
    } });

    // Each person is a block: name (larger font) on its own line, roles
    // (smaller font) on the next line. A gap separates each person block.
    const Credit = struct { name: []const u8, roles: []const u8 };
    const credits = [_]Credit{
        .{ .name = "Linus W. Hjalsted", .roles = "game director, game design, program design, UI/UX design, level design" },
        .{ .name = "Cille R. K. Abildhauge", .roles = "art director, graphics, world building" },
        .{ .name = "Victor H. B. Willaredt", .roles = "sound director, sound design, music" },
    };
    const name_height = lineHeight(credits_name_font_size);
    const role_height = lineHeight(credits_role_font_size);
    const person_height = name_height + credits_name_to_role_gap + role_height;
    const block_height = rowWidth(credits.len, person_height, credits_person_gap);
    // Vertically center the credit block in the space between the header
    // and the bottom buttons.
    const buttons_top = screen.y + screen.height - credits_padding -
        panel_button_height - credits_button_gap;
    const block_y = header_y + lineHeight(credits_header_font_size) +
        @divTrunc(buttons_top - (header_y + lineHeight(credits_header_font_size)) - block_height, 2);
    for (credits, 0..) |credit, index| {
        const person_y = block_y + @as(i32, @intCast(index)) * (person_height + credits_person_gap);

        const name_width = font_metrics.measureSpanWidth(text(credit.name), credits_name_font_size);
        const name_x = content_x + @divTrunc(content_width - name_width, 2);
        try elements.append(allocator, .{ .text_label = .{
            .text = credit.name,
            .screen_position = .{ .x = name_x, .y = person_y },
            .font_size = credits_name_font_size,
            .blocks_input = false,
        } });

        const role_width = font_metrics.measureSpanWidth(text(credit.roles), credits_role_font_size);
        const role_x = content_x + @divTrunc(content_width - role_width, 2);
        const role_y = person_y + name_height + credits_name_to_role_gap;
        try elements.append(allocator, .{ .text_label = .{
            .text = credit.roles,
            .screen_position = .{ .x = role_x, .y = role_y },
            .font_size = credits_role_font_size,
            .blocks_input = false,
        } });
    }

    // Back button, bottom-left.
    const button_y = screen.y + screen.height - credits_padding - panel_button_height;
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = content_x,
            .y = button_y,
            .width = credits_button_width,
            .height = panel_button_height,
        },
        "Back",
        menu_button_font_size,
        .open_credits,
        button_color,
        null,
    );
}

// --- Settings screen (full screen, overlay) ---

pub const settings_padding: i32 = 48;
pub const settings_header_font_size: i32 = 96;
pub const settings_header_gap: i32 = 64;
pub const settings_row_font_size: i32 = 56;
pub const settings_row_height: i32 = 120;
pub const settings_row_gap: i32 = 32;
pub const settings_label_to_control_gap: i32 = 48;
pub const settings_button_gap: i32 = 48;
/// Back button size (bottom-left). Matches the load-save / credits Back
/// buttons so the main-menu overlays feel consistent.
pub const settings_button_width: i32 = 768;
/// Toggle button (On/Off) width — sits in the control area of a row.
pub const settings_toggle_width: i32 = 400;
/// Camera-zoom choice button width (one of 4).
pub const settings_choice_button_width: i32 = 240;
/// Player-color swatch size (one of 6).
pub const settings_swatch_size: i32 = 120;
pub const settings_swatch_gap: i32 = 16;
/// Slider track width.
pub const settings_slider_width: i32 = 800;
pub const settings_slider_value_gap: i32 = 32;

/// Emit a settings control button: a tinted 9-slice panel + a button
/// carrying `setting_ref` (the field identity) + a centered text label.
/// Like `emitPanelButton` but for the settings binding (setting_ref on the
/// button, not a SlotRef) with a `highlighted` flag for the active choice.
fn emitSettingButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    label: []const u8,
    font_size: i32,
    sref: types.SettingRef,
    highlighted: bool,
    button_color: Color,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = .change_setting,
        .setting_ref = sref,
        .highlighted = highlighted,
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), font_size);
    const label_box = cell.placeCenter(label_width, font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = label_box.position(),
        .font_size = font_size,
        .blocks_input = false,
    } });
}

/// Build the settings screen: a full-screen modal panel with a centered
/// "Settings" header, a column of control rows (toggle/choice — sliders
/// land in slice 3b), and a Back button in the bottom-left. The panel
/// blocks input to the surface behind it (main menu or the options menu).
/// See DESIGN → UI Framework → Settings screen.
pub fn buildSettingsPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    settings: types.Settings,
    player_gradient: types.ColorGradient,
    button_color: Color,
) !void {
    // Full-screen modal background — blocks input to the surface behind it.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .blocks_input = true,
    } });

    const content_x = screen.x + settings_padding;
    const content_width = screen.width - 2 * settings_padding;

    // Header, centered horizontally near the top.
    const header_text = "Settings";
    const header_width = font_metrics.measureSpanWidth(text(header_text), settings_header_font_size);
    const header_x = content_x + @divTrunc(content_width - header_width, 2);
    const header_y = screen.y + settings_padding;
    try elements.append(allocator, .{ .text_label = .{
        .text = header_text,
        .screen_position = .{ .x = header_x, .y = header_y },
        .font_size = settings_header_font_size,
        .blocks_input = false,
    } });

    // Control rows. Each row: label (left) + control (right, flush
    // against the label — measured per-row so the control sits right after
    // the label text, not at a fixed column). Vertically stacked below the
    // header, centered as a group between header and Back button.

    // 11 rows (5 toggle/choice + 5 slider + 1 fps toggle):
    //   0. Master Volume (slider 0–100)
    //   1. Music Volume (slider 0–100)
    //   2. Sound Effects Volume (slider 0–100)
    //   3. Render FPS Cap (slider 0–256, 0 = Uncapped)
    //   4. Animation FPS (slider 1–16)
    //   5. VSync (toggle)
    //   6. Camera Zoom (4-button choice)
    //   7. Player Color (6-swatch choice)
    //   8. Auto-skip attack step (toggle)
    //   9. Auto-target at cursor (toggle)
    //  10. Show FPS (toggle)
    const row_count: i32 = 11;
    const rows_total_height = rowWidth(row_count, settings_row_height, settings_row_gap);
    const buttons_top = screen.y + screen.height - settings_padding -
        panel_button_height - settings_button_gap;
    const rows_y_start = header_y + lineHeight(settings_header_font_size) + settings_header_gap +
        @divTrunc(buttons_top - (header_y + lineHeight(settings_header_font_size) + settings_header_gap) - rows_total_height, 2);

    // Helper: emit a row label at content_x, vertically centered in the row,
    // and return the x position flush after the label (label_width + gap).
    const emitLabel = struct {
        fn run(
            elems: *UiElementList,
            alloc: std.mem.Allocator,
            fm: FontMetrics,
            label_text: []const u8,
            x: i32,
            y: i32,
        ) i32 {
            const label_width = fm.measureSpanWidth(text(label_text), settings_row_font_size);
            elems.append(alloc, .{ .text_label = .{
                .text = label_text,
                .screen_position = .{ .x = x, .y = y + @divTrunc(settings_row_height - settings_row_font_size, 2) },
                .font_size = settings_row_font_size,
                .blocks_input = false,
            }}) catch @panic("failed to append settings label");
            return x + label_width + settings_label_to_control_gap;
        }
    }.run;

    // Helper: emit a slider row — label (flush left) + slider control +
    // value text (right of the slider). Returns nothing. The slider value
    // is read from `settings` via the setting id, so it tracks the drag live
    // (the panel is rebuilt each frame).
    const emitSliderRow = struct {
        fn run(
            elems: *UiElementList,
            alloc: std.mem.Allocator,
            fm: FontMetrics,
            label_text: []const u8,
            id: types.SettingId,
            min: u32,
            max: u32,
            value: u32,
            value_label: []const u8,
            x: i32,
            y: i32,
        ) void {
            const ctrl_x = emitLabel(elems, alloc, fm, label_text, x, y);
            elems.append(alloc, .{ .slider = .{
                .setting_id = id,
                .min = min,
                .max = max,
                .value = value,
                .screen_position = .{ .x = ctrl_x, .y = y },
                .width = settings_slider_width,
                .height = settings_row_height,
            }}) catch @panic("failed to append slider");
            // Value text right of the slider.
            const value_x = ctrl_x + settings_slider_width + settings_slider_value_gap;
            elems.append(alloc, .{ .text_label = .{
                .text = value_label,
                .screen_position = .{ .x = value_x, .y = y + @divTrunc(settings_row_height - settings_row_font_size, 2) },
                .font_size = settings_row_font_size,
                .blocks_input = false,
            }}) catch @panic("failed to append slider value");
        }
    }.run;

    var row_index: i32 = 0;

    // ── Slider rows (0–4) ──

    // Row 0: Master Volume (0–100).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.master_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Master Volume", .master_volume, 0, 100, settings.master_volume, value_label, content_x, r_y);
    }
    row_index += 1;

    // Row 1: Music Volume (0–100).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.music_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Music Volume", .music_volume, 0, 100, settings.music_volume, value_label, content_x, r_y);
    }
    row_index += 1;

    // Row 2: Sound Effects Volume (0–100).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.sound_effects_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Sound Effects Volume", .sound_effects_volume, 0, 100, settings.sound_effects_volume, value_label, content_x, r_y);
    }
    row_index += 1;

    // Row 3: Render FPS Cap (0–256, 0 = Uncapped).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const value_label: []const u8 = if (settings.render_fps_cap == 0)
            "Uncapped"
        else
            std.fmt.allocPrint(allocator, "{d}", .{settings.render_fps_cap}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Render FPS Cap", .render_fps_cap, 0, 256, settings.render_fps_cap, value_label, content_x, r_y);
    }
    row_index += 1;

    // Row 4: Animation FPS (1–16).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const value_label = std.fmt.allocPrint(allocator, "{d}", .{settings.animation_fps}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Animation FPS", .animation_fps, 1, 16, settings.animation_fps, value_label, content_x, r_y);
    }
    row_index += 1;

    // ── Toggle / choice rows (5–9) ──

    // Row 5: VSync toggle. Label is platform-specific: on web the setting
    // is a no-op — the browser's requestAnimationFrame paces rendering to
    // the display refresh regardless (rAF IS vsync on web; no page code can
    // out-run it). On native it's a real GLFW swap-interval toggle that only
    // applies at window creation, hence the restart note.
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const vsync_label = if (@import("builtin").os.tag == .emscripten)
            "VSync (always on in browser)"
        else
            "VSync (change requires restart)";
        const ctrl_x = emitLabel(elements, allocator, font_metrics, vsync_label, content_x, r_y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = r_y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.vsync) "On" else "Off",
            settings_row_font_size,
            .{ .id = .vsync },
            false,
            button_color,
        );
    }
    row_index += 1;

    // Row 6: Camera Zoom — 4 buttons (25/50/75/100 hundredths → display as %).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Camera Zoom", content_x, r_y);
        const zoom_values = [_]u32{ 25, 50, 75, 100 };
        const zoom_labels = [_][]const u8{ "25%", "50%", "75%", "100%" };
        for (zoom_values, zoom_labels, 0..) |value, label, i| {
            try emitSettingButton(
                elements,
                allocator,
                font_metrics,
                .{
                    .x = ctrl_x + @as(i32, @intCast(i)) * (settings_choice_button_width + settings_swatch_gap),
                    .y = r_y,
                    .width = settings_choice_button_width,
                    .height = settings_row_height,
                },
                label,
                settings_row_font_size,
                .{ .id = .camera_zoom, .choice_value = value },
                settings.camera_zoom == value,
                button_color,
            );
        }
    }
    row_index += 1;

    // Row 7: Player Color — 6 swatches (player gradient indices 0–5).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Player Color", content_x, r_y);
        const swatch_y = r_y + @divTrunc(settings_row_height - settings_swatch_size, 2);
        for (0..types.gradient_color_count) |i| {
            const sx = ctrl_x + @as(i32, @intCast(i)) * (settings_swatch_size + settings_swatch_gap);
            const swatch_rect: Rectangle = .{ .x = sx, .y = swatch_y, .width = settings_swatch_size, .height = settings_swatch_size };
            // Colored fill (the swatch itself).
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = swatch_rect.position(),
                .width = swatch_rect.width,
                .height = swatch_rect.height,
                .color = player_gradient.colors[i],
            } });
            // Invisible hit-test button over the swatch.
            try elements.append(allocator, .{ .button = .{
                .screen_position = swatch_rect.position(),
                .width = swatch_rect.width,
                .height = swatch_rect.height,
                .action = .change_setting,
                .setting_ref = .{ .id = .player_color_index, .choice_value = @intCast(i) },
                .highlighted = settings.player_color_index == i,
            } });
        }
    }
    row_index += 1;

    // Row 8: Auto-skip attack step toggle.
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Auto-skip Attack Step", content_x, r_y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = r_y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.auto_skip_attack_step_out_of_combat) "On" else "Off",
            settings_row_font_size,
            .{ .id = .auto_skip_attack_step_out_of_combat },
            false,
            button_color,
        );
    }
    row_index += 1;

    // Row 9: Auto-target at cursor toggle.
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Auto-target at Cursor", content_x, r_y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = r_y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.auto_target_at_cursor) "On" else "Off",
            settings_row_font_size,
            .{ .id = .auto_target_at_cursor },
            false,
            button_color,
        );
    }
    row_index += 1;

    // Row 10: Show FPS toggle.
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Show FPS", content_x, r_y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = r_y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.show_fps) "On" else "Off",
            settings_row_font_size,
            .{ .id = .show_fps },
            false,
            button_color,
        );
    }

    // Back button, bottom-left.
    const button_y = screen.y + screen.height - settings_padding - panel_button_height;
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = content_x,
            .y = button_y,
            .width = settings_button_width,
            .height = panel_button_height,
        },
        "Back",
        menu_button_font_size,
        .open_settings,
        button_color,
        null,
    );
}

test "buildErrorPopup emits a modal panel, header, body, and a Dismiss button" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, "failed to parse data/campaigns/act_one.txt: missing Campaign section", .{ .r = 50, .g = 50, .b = 50 });

    // Panel + header label(s) + body label(s) + (panel + button + label) from emitPanelButton.
    // At minimum: 1 nine_slice (popup) + 1 header text + N body texts + 1 nine_slice (button) + 1 button + 1 label.
    try std.testing.expect(elements.items.len >= 6);

    // The first element is the popup panel and it is modal (blocks_input).
    try std.testing.expectEqual(std.meta.activeTag(elements.items[0]), .nine_slice_panel);
    try std.testing.expect(elements.items[0].nine_slice_panel.blocks_input);

    // The Dismiss button carries Action.dismiss_error.
    var found_dismiss = false;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .dismiss_error) {
            found_dismiss = true;
        },
        else => {},
    };
    try std.testing.expect(found_dismiss);
}

test "buildErrorPopup: short message — no scrollbar, scroll offset clamped to 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};
    session.error_scroll_offset = 500; // should be clamped to 0 (content fits)

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, "short error", .{ .r = 50, .g = 50, .b = 50 });

    // No scrollbar (no solid_rect) since content fits in the visible region.
    for (elements.items) |element| switch (element) {
        .solid_rect => @panic("unexpected scrollbar for short message"),
        else => {},
    };
    try std.testing.expectEqual(@as(i32, 0), session.error_scroll_offset);
}

test "buildErrorPopup: long message — scrollbar present, only visible lines emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};

    // Build a message long enough to overflow error_popup_max_body_height.
    // Each line is ~56px; 1600px / 56 ≈ 28 lines fit. Generate 60 lines.
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(std.testing.allocator);
    for (0..60) |i| {
        if (i > 0) msg.appendSlice(std.testing.allocator, "\n") catch @panic("msg");
        msg.appendSlice(std.testing.allocator, "This is warning line number X with some text.") catch @panic("msg");
    }

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, msg.items, .{ .r = 50, .g = 50, .b = 50 });

    // Scrollbar present (at least 2 solid_rects: track + thumb).
    var solid_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .solid_rect => solid_count += 1,
        else => {},
    };
    try std.testing.expect(solid_count >= 2);

    // Scroll offset is 0 (top of content) since we didn't scroll.
    try std.testing.expectEqual(@as(i32, 0), session.error_scroll_offset);
}

test "buildErrorPopup: scroll offset clamped to max_scroll on long message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session: state.SessionState = .{};
    session.error_scroll_offset = 100_000; // way past max_scroll

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(std.testing.allocator);
    for (0..60) |i| {
        if (i > 0) msg.appendSlice(std.testing.allocator, "\n") catch @panic("msg");
        msg.appendSlice(std.testing.allocator, "This is warning line number X with some text.") catch @panic("msg");
    }

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    try buildErrorPopup(&elements, arena.allocator(), metrics, &session, msg.items, .{ .r = 50, .g = 50, .b = 50 });

    // Clamped to max_scroll (which is body_content_height - visible_body_height,
    // both positive since content overflows). Exact value depends on wrapping,
    // but it must be > 0 and < the original 100_000.
    try std.testing.expect(session.error_scroll_offset > 0);
    try std.testing.expect(session.error_scroll_offset < 100_000);
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
// Tooltip placement (placeTooltip) — pure geometry over (source, screen, size)
// ============================================================

test "placeTooltip: source in bottom bar prefers above" {
    // A bottom-bar element: source near the bottom edge, centered horizontally.
    // `above` has ~1900px clearance (fits a 600px tooltip) and is the top
    // preference, so the tooltip sits flush over the source.
    const placement = placeTooltip(.{ .x = 1600, .y = 1900 }, 256, 256, 400, 600);
    // Flush above: panel bottom edge meets source top edge (y = 1900 - 600).
    try std.testing.expectEqual(@as(i32, 1900 - 600), placement.y);
    try std.testing.expectEqual(@as(i32, 1600), placement.x); // left-aligned (left half)
}

test "placeTooltip: source in top-left quadrant goes below" {
    // Source in the top half → `above` doesn't fit (clearance = source.y = 100
    // < tooltip height 600), so the preference order falls to `below`.
    const placement = placeTooltip(.{ .x = 200, .y = 100 }, 256, 256, 400, 600);
    // Flush below: panel top edge meets source bottom edge (y = 100 + 256).
    try std.testing.expectEqual(@as(i32, 100 + 256), placement.y);
    try std.testing.expectEqual(@as(i32, 200), placement.x); // left-aligned (left half)
}

test "placeTooltip: above doesn't fit and below doesn't fit → falls sideways" {
    // A tall source spanning most of the screen leaves no vertical room on
    // either side (above clearance = source.y = 200, below = 360, both < tooltip
    // height 400), so the preference order falls past above/below to `right`.
    // The tooltip is short enough that its vertical alignment (top-align) stays
    // on screen, so `right` fits.
    const placement = placeTooltip(.{ .x = 1000, .y = 200 }, 256, 1600, 500, 400);
    // Flush right: panel left edge meets source right edge (x = 1000 + 256).
    try std.testing.expectEqual(@as(i32, 1000 + 256), placement.x);
    // top-aligned (source center y = 200+800 = 1000 < screen center 1080).
    try std.testing.expectEqual(@as(i32, 200), placement.y);
}

test "placeTooltip: near-corner alignment follows the near corner" {
    // Source in the bottom-right quadrant, `above` fits (clearance = y = 1700 >
    // tooltip height 400). Right-align: shared edge runs from the source's
    // top-right corner leftward.
    const source_x: i32 = 3400;
    const source_w: i32 = 256;
    const placement = placeTooltip(.{ .x = source_x, .y = 1700 }, source_w, 256, 400, 400);
    try std.testing.expectEqual(@as(i32, 1700 - 400), placement.y); // flush above
    // right-aligned: panel right edge == source right edge
    try std.testing.expectEqual(source_x + source_w, placement.x + 400);
}

test "placeTooltip: nothing fits → falls back to top preference (above), clamped" {
    // Tooltip taller than the screen on every side's cross axis and larger
    // than the vertical clearance. Falls back to `above` and clamps on screen.
    const placement = placeTooltip(.{ .x = 1000, .y = 1000 }, 256, 256, 5000, 5000);
    // Clamped to [0, screen - tooltip] on both axes (tooltip > screen →
    // screen - tooltip is negative, clamp yields 0).
    try std.testing.expectEqual(@as(i32, 0), placement.x);
    try std.testing.expectEqual(@as(i32, 0), placement.y);
}

test "placeTooltip: shared edge — panel sits flush on the chosen side" {
    // Top preference `above` fits: the panel's bottom edge must equal the
    // source's top edge (shared edge, not just a corner touch).
    const source_y: i32 = 1500;
    const tooltip_h: i32 = 500;
    const placement = placeTooltip(.{ .x = 1500, .y = source_y }, 256, 256, 400, tooltip_h);
    try std.testing.expectEqual(source_y, placement.y + tooltip_h);
}

// ───────────────────────── entity inspect panel ─────────────────────────
// See `buildEntityInspectPanel`. Read-only mirror of the player's skill bar +
// active effects + gear, tinted with the inspected entity's team gradient.

/// A minimal weapon-type table for inspect-panel tests: every weapon type
/// maps skill_1 → stab, skill_2 → chop, skill_3 → throw so equipped weapons
/// populate slots 1-3 deterministically.
fn testWeaponTypeDefinitions() [weapon_type_count]WeaponTypeDefinition {
    var defs: [weapon_type_count]WeaponTypeDefinition = undefined;
    for (&defs) |*d| d.* = .{ .skill_1 = .stab, .skill_2 = .chop, .skill_3 = .throw };
    return defs;
}

test "buildEntityInspectPanel: player entity emits skill + gear slots, read-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const player_color: types.Color = .{ .r = 10, .g = 20, .b = 30 };
    const enemy_color: types.Color = .{ .r = 90, .g = 80, .b = 70 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{enemy_color} ** 6 },
        .player_gradient = .{ .colors = .{player_color} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 0;
    entity.main_hand_weapon = .{ .weapon_type = .sword };
    entity.off_hand_weapon = .{ .weapon_type = .shield };
    entity.equipped_utility_skills = .{ .slice, .stab, null, null, null };

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // No .slot elements and no gameplay-clickable .button — everything is
    // read-only .image, except the panel-header close button (a .button
    // carrying the toggle_entity_inspect action).
    for (elements.items) |element| switch (element) {
        .slot => @panic("inspect panel emitted a draggable .slot"),
        .button => |btn| if (btn.action != .toggle_entity_inspect) {
            @panic("inspect panel emitted a clickable .button other than close");
        },
        else => {},
    };

    // The skill-bar frame images are tinted with the PLAYER gradient (team 0).
    const expected_frame = player_color; // index 3 → player_color (all 6 are same)
    var found_skill_frame = false;
    for (elements.items) |element| switch (element) {
        .image => |img| if (std.mem.eql(u8, img.sprite_id, "ui/skill_button")) {
            try std.testing.expectEqual(expected_frame, img.color);
            found_skill_frame = true;
        },
        else => {},
    };
    try std.testing.expect(found_skill_frame);
}

test "buildEntityInspectPanel: enemy entity uses enemy gradient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const player_color: types.Color = .{ .r = 10, .g = 20, .b = 30 };
    const enemy_color: types.Color = .{ .r = 90, .g = 80, .b = 70 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{enemy_color} ** 6 },
        .player_gradient = .{ .colors = .{player_color} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 1; // enemy
    entity.main_hand_weapon = .{ .weapon_type = .sword };
    entity.current_health = 7;
    entity.aggro_range = 5;

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // Skill-bar frame tinted with the ENEMY gradient (team ≠ 0).
    var found_enemy_frame = false;
    // The stat column LEADS with the entity's live combat state.
    var found_current_health = false;
    var found_aggro_range = false;
    var stat_lines: usize = 0;
    var first_stat_lines: [2][]const u8 = undefined;
    for (elements.items) |element| switch (element) {
        .image => |img| if (std.mem.eql(u8, img.sprite_id, "ui/skill_button")) {
            try std.testing.expectEqual(enemy_color, img.color);
            found_enemy_frame = true;
        },
        .text_label => |label| {
            // Stat lines live in the column flush against the gear stack
            // (x = 16 + 128); the panel title shares the font size, so gate
            // on position, not just text.
            if (label.screen_position.x == ui_gap + inventory_slot_size and label.font_size == gear_stat_font_size) {
                if (stat_lines < 2) first_stat_lines[stat_lines] = label.text;
                stat_lines += 1;
                if (std.mem.eql(u8, label.text, "Current Health 7")) found_current_health = true;
                if (std.mem.eql(u8, label.text, "Aggro Range 5")) found_aggro_range = true;
            }
        },
        else => {},
    };
    try std.testing.expect(found_enemy_frame);
    try std.testing.expect(found_current_health);
    try std.testing.expect(found_aggro_range);
    // The two live-state rows lead the column (before the gear stats).
    try std.testing.expect(stat_lines == 9);
    try std.testing.expectEqualStrings("Current Health 7", first_stat_lines[0]);
    try std.testing.expectEqualStrings("Aggro Range 5", first_stat_lines[1]);
}

test "buildEntityInspectPanel: cooldown overlay + number when skill on cooldown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 0;
    entity.main_hand_weapon = .{ .weapon_type = .sword };
    // Slot 1 = stab (sword skill_1); put it on cooldown.
    entity.skill_cooldowns.set(.stab, 3);

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // A cooldown overlay is a translucent (alpha 128) skill_button image on
    // top of the filled slot. Count them — exactly one skill is on cooldown.
    var overlay_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .image => |img| if (std.mem.eql(u8, img.sprite_id, "ui/skill_button") and img.alpha == 128) {
            overlay_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), overlay_count);
}

test "buildEntityInspectPanel: active effects emit 128px icons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 1;
    // Allocate active_effects in the arena (Entity.active_effects is a slice).
    const effects = try arena.allocator().alloc(types.Effect, 2);
    effects[0] = .{ .effect_id = .reflect, .duration = 2 };
    effects[1] = .{ .effect_id = .stone_form, .duration = 4 };
    entity.active_effects = effects;

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // Two effect icons at 128px, carrying tooltips.
    var effect_icon_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .image => |img| if (img.width == small_icon_size and img.height == small_icon_size and img.tooltip != null) {
            // Effect icons use the effect definition name as the sprite id.
            // Effect icons use the SKILL icon (`skills/<tag>`) when the
            // effect shares a tag with a skill (reflect/stone_form do).
            if (std.mem.eql(u8, img.sprite_id, "skills/reflect") or std.mem.eql(u8, img.sprite_id, "skills/stone_form")) {
                effect_icon_count += 1;
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), effect_icon_count);
}

test "buildLoadSavePanel: rows carry refs + actions, scroll window + clamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    // Enough rows to overflow the visible window (rows region is roughly
    // 2160 - 2*48 - header(~86) - 32 - 160 - 48 ≈ 1700px → ~14 visible rows).
    var files: [20]@import("file_source.zig").SaveFileEntry = undefined;
    for (&files, 0..) |*file, i| {
        file.* = .{
            .name = try std.fmt.allocPrint(allocator, "save_{d}.txt", .{i}),
            .path = try std.fmt.allocPrint(allocator, "saves/save_{d}.txt", .{i}),
            .mtime_ns = @intCast(1000 - i),
        };
    }

    var scroll: i32 = 0;
    var elements: UiElementList = .empty;
    try buildLoadSavePanel(&elements, allocator, metrics, screen, &files, &scroll, .{ .r = 50, .g = 50, .b = 50 });

    // The scroll offset was clamped... 20 rows vs ~14 visible → max > 0, but
    // offset 0 stays 0. Rows emitted: only the visible window.
    var row_buttons: usize = 0;
    var first_ref_index: ?u32 = null;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .load_save_row) {
            row_buttons += 1;
            const ref = button.ref.?;
            if (first_ref_index == null) first_ref_index = ref.save_file;
        },
        else => {},
    };
    try std.testing.expect(row_buttons > 0);
    try std.testing.expect(row_buttons < files.len); // window, not all rows
    try std.testing.expectEqual(@as(u32, 0), first_ref_index.?); // starts at scroll 0

    // Scroll to the end: clamp to max_scroll_row, last row visible.
    scroll = 999;
    var elements_end: UiElementList = .empty;
    try buildLoadSavePanel(&elements_end, allocator, metrics, screen, &files, &scroll, .{ .r = 50, .g = 50, .b = 50 });
    var last_ref_index: u32 = 0;
    for (elements_end.items) |element| switch (element) {
        .button => |button| if (button.action == .load_save_row) {
            last_ref_index = button.ref.?.save_file;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(u32, files.len - 1), last_ref_index);
    // Clamped to exactly the last window start.
    const max_scroll_row: i32 = @intCast(files.len - row_buttons);
    try std.testing.expectEqual(max_scroll_row, scroll);

    // Negative scroll clamps to 0.
    scroll = -5;
    var elements_neg: UiElementList = .empty;
    try buildLoadSavePanel(&elements_neg, allocator, metrics, screen, &files, &scroll, .{ .r = 50, .g = 50, .b = 50 });
    try std.testing.expectEqual(@as(i32, 0), scroll);
}

test "buildLoadSavePanel: empty list shows placeholder, Back always emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    var scroll: i32 = 0;
    var elements: UiElementList = .empty;
    try buildLoadSavePanel(&elements, allocator, metrics, screen, &.{}, &scroll, .{ .r = 50, .g = 50, .b = 50 });

    var found_placeholder = false;
    var found_back = false;
    for (elements.items) |element| switch (element) {
        .text_label => |label| if (std.mem.eql(u8, label.text, "No save files")) {
            found_placeholder = true;
        },
        .button => |button| if (button.action == .toggle_load_save_menu) {
            found_back = true;
        },
        else => {},
    };
    try std.testing.expect(found_placeholder);
    try std.testing.expect(found_back);
}

test "buildOptionsMenu: Export Save tooltip reflects the save destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // Native (a persistent dir path is known): "Saves to <dir>/saves/".
    {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, .level, button_color, "/home/tester/.ziglop");
        const button = (for (elements.items) |element| switch (element) {
            .button => |b| if (b.action == .save_game) break b,
            else => {},
        } else @panic("no Export Save button"));
        const tooltip = button.tooltip orelse @panic("Export Save button has no tooltip");
        try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
        try std.testing.expectEqual(@as(usize, 1), tooltip.body[0].len);
        try std.testing.expectEqualStrings("Saves to /home/tester/.ziglop/saves/", tooltip.body[0][0].text);
    }

    // Web (null path): the export is a browser download.
    {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, .level, button_color, null);
        const button = (for (elements.items) |element| switch (element) {
            .button => |b| if (b.action == .save_game) break b,
            else => {},
        } else @panic("no Export Save button"));
        const tooltip = button.tooltip orelse @panic("Export Save button has no tooltip");
        try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
        try std.testing.expectEqualStrings("Triggers a file download", tooltip.body[0][0].text);
    }

    // Other buttons stay tooltip-free.
    {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, .level, button_color, "/x");
        for (elements.items) |element| switch (element) {
            .button => |b| if (b.action != .save_game) {
                try std.testing.expect(b.tooltip == null);
            },
            else => {},
        };
    }

    // Editor context: no Export Save button (the editor's save target is
    // the mission being edited — a future slice). Continue + Settings +
    // Exit to Main Menu remain.
    {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, .editor, button_color, "/home/tester/.ziglop");
        for (elements.items) |element| switch (element) {
            .button => |b| try std.testing.expect(b.action != .save_game),
            else => {},
        };
    }
}



test "buildEditorSkillPicker: header + close + None + one cell per utility skill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, .{ .r = 30, .g = 30, .b = 30 }, black, black, black, .{ .r = 40, .g = 40, .b = 40 } } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // Slot 1 (Slot 5) already carries blink — its cell is highlighted,
    // the None cell is not.
    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton", .template = .{
        .equipped_utility_skills = .{ null, .blink, null, null, null },
    } }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    var elements: UiElementList = .empty;
    try buildEditorSkillPicker(&elements, arena.allocator(), metrics, editor, .{ .utility_skill_slot = 1 }, theme);

    // Panel + header label + close + None (button + label) + 7 ×
    // (button + full-size icon) = 19 — real skills are icon-only.
    try std.testing.expectEqual(@as(usize, 19), elements.items.len);

    var picker_buttons: usize = 0;
    var highlighted_skill: ?types.SkillId = null;
    var none_highlighted = false;
    var saw_blink_cell = false;
    var saw_header = false;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_editor_utility_skill) {
            picker_buttons += 1;
            if (button.editor_skill == null) {
                none_highlighted = button.highlighted;
            } else if (button.highlighted) {
                highlighted_skill = button.editor_skill;
            }
            if (button.editor_skill == .blink) saw_blink_cell = true;
        },
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "Assign Slot 5")) saw_header = true;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 8), picker_buttons); // None + 7 skills
    try std.testing.expectEqual(types.SkillId.blink, highlighted_skill.?);
    try std.testing.expect(!none_highlighted);
    try std.testing.expect(saw_blink_cell);
    try std.testing.expect(saw_header);
    // No weapon-skill payload anywhere.
    for (elements.items) |element| switch (element) {
        .button => |button| try std.testing.expect(
            button.editor_skill == null or utility_skills.isUtilitySkill(button.editor_skill.?),
        ),
        else => {},
    };

    // The PLAYER fallback target: the picker reads the player loadout's
    // slots (the '!' selected under the select tool resolves to the
    // player).
    {
        const player_editor: types.Editor = .{
            .player_def = .{ .id = "Player", .template = .{
                .equipped_utility_skills = .{ null, .stone_form, null, null, null },
            } },
            .active_tool = .select,
            .selection = &.{.{ .player_start = {} }},
        };
        var player_elements: UiElementList = .empty;
        try buildEditorSkillPicker(
            &player_elements,
            arena.allocator(),
            metrics,
            player_editor,
            .{ .utility_skill_slot = 1 },
            theme,
        );
        var player_highlighted: ?types.SkillId = null;
        for (player_elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_utility_skill and
                button.highlighted and button.editor_skill != null)
            {
                player_highlighted = button.editor_skill;
            },
            else => {},
        };
        try std.testing.expectEqual(types.SkillId.stone_form, player_highlighted.?);
    }
}

test "buildEditorSpritePicker: tabs, official cells (player excluded), mission-local namespaced cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Bear",
        .template = .{ .name = "Bear", .sprite = "bear", .team = 1 },
    }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
        .mission = .{ .path = "missions/artists_den" },
    };

    // Official tab: one cell per shipped enemy sprite, the player body
    // excluded; the current sprite (bear) highlighted; every cell carries
    // its stem payload + the shipped sprite graphic.
    {
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(&elements, arena.allocator(), metrics, editor, theme, &.{}, &.{}, .entity_sprite, .official);
        var pick_buttons: usize = 0;
        var highlighted: ?[]const u8 = null;
        var saw_player = false;
        var saw_bear_graphic = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_sprite) {
                pick_buttons += 1;
                if (std.mem.eql(u8, button.editor_sprite.?, "player")) saw_player = true;
                if (button.highlighted) highlighted = button.editor_sprite;
            } else if (button.action == .select_editor_sprite_tab) {
                // Tabs: Mission + Official, the active one highlighted.
                if (button.editor_sprite_tab.? == .official) {
                    try std.testing.expect(button.highlighted);
                } else {
                    try std.testing.expect(!button.highlighted);
                }
            },
            .image => |image| if (std.mem.eql(u8, image.sprite_id, "entities/bear")) {
                saw_bear_graphic = true;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 9), pick_buttons); // 10 shipped minus player
        try std.testing.expect(!saw_player);
        try std.testing.expectEqualStrings("bear", highlighted.?);
        try std.testing.expect(saw_bear_graphic);
    }

    // Mission tab: the scanned file names become namespaced
    // `custom/<mission-dir>/<stem>` payloads, shown as TEXT cells (the art
    // isn't renderable until custom-asset rendering lands).
    {
        const mission_sprites = [_][]const u8{ "boss.png", "minion.png" };
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &mission_sprites,
            &.{},
            .entity_sprite,
            .mission_local,
        );
        var payloads: [2][]const u8 = .{ "", "" };
        var pick_buttons: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_sprite) {
                payloads[pick_buttons] = button.editor_sprite.?;
                pick_buttons += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), pick_buttons);
        try std.testing.expectEqualStrings("custom/artists_den/boss", payloads[0]);
        try std.testing.expectEqualStrings("custom/artists_den/minion", payloads[1]);
        // The mission tab's cells carry text labels, no sprite graphics.
        try std.testing.expectEqualStrings("boss", findLabel(&elements, "boss").text);
    }
}

/// Find the first text label with exactly `label_text` (test helper).
fn findLabel(elements: *const UiElementList, label_text: []const u8) TextLabel {
    for (elements.items) |element| switch (element) {
        .text_label => |label| if (std.mem.eql(u8, label.text, label_text)) return label,
        else => {},
    };
    @panic("label not found");
}

test "buildEditorSpritePicker: decoration target — registry official cells, namespaced mission cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const world_four: types.Color = .{ .r = 20, .g = 20, .b = 20 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{ black, black, black, black, world_four, black } },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const tree_footprint = [_]types.Vector2{.{ .x = 1, .y = 2 }};
    const tree_layers = [_]types.DecorationLayer{.{
        .sprite = "tree_1_canopy",
        .color_index = 2,
        .pixel_dims = .{ .x = 512, .y = 768 },
    }};
    const registry = [_]types.DecorationTypeDef{
        .{
            .id = "tree_1",
            .sprite = "tree_1",
            .footprint = &tree_footprint,
            .pixel_dims = .{ .x = 512, .y = 768 },
            .color_index = 4,
            .layers = &tree_layers,
        },
        .{ .id = "stone_2", .sprite = "stone_2", .pixel_dims = .{ .x = 512, .y = 256 } },
    };
    const stone_footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &stone_footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
        .color_index = 4,
    }};
    const editor: types.Editor = .{
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
        .mission = .{ .path = "custom_missions/artists_den" },
    };

    // Official tab: one cell per registry prefab — the decoration pick
    // action, the shipped `decorations/<stem>` graphic, the current sprite
    // (stone_2) highlighted, world-gradient tint at the type's color.
    {
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &.{},
            &registry,
            .decoration_sprite,
            .official,
        );
        var pick_buttons: usize = 0;
        var highlighted: ?[]const u8 = null;
        var saw_tree_graphic = false;
        var saw_world_tint = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_sprite) {
                pick_buttons += 1;
                if (button.highlighted) highlighted = button.editor_sprite;
            },
            .image => |image| {
                if (std.mem.eql(u8, image.sprite_id, "decorations/tree_1")) saw_tree_graphic = true;
                if (std.meta.eql(image.color, world_four)) saw_world_tint = true;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), pick_buttons);
        try std.testing.expectEqualStrings("stone_2", highlighted.?);
        try std.testing.expect(saw_tree_graphic);
        try std.testing.expect(saw_world_tint);
    }

    // Mission tab: same namespacing as the entity picker; text cells (the
    // art isn't renderable until custom-asset rendering lands).
    {
        const mission_sprites = [_][]const u8{"banner.png"};
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &mission_sprites,
            &registry,
            .decoration_sprite,
            .mission_local,
        );
        var pick_buttons: usize = 0;
        var payload: ?[]const u8 = null;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_sprite) {
                pick_buttons += 1;
                payload = button.editor_sprite;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), pick_buttons);
        try std.testing.expectEqualStrings("custom/artists_den/banner", payload.?);
    }
}

test "inspector Layers sections: per-layer rows + add button (enemy + decoration)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // ENEMY content with one layer: the clamped window lands on the
    // utility row + the whole Layers section.
    {
        const entity_layers = [_]types.EntityLayer{.{ .sprite = "hood", .color_index = 2 }};
        const entity_types = [_]types.EntityTypeDef{.{
            .id = "Skeleton",
            .template = .{
                .name = "Skeleton",
                .sprite = "skeleton_1",
                .team = 1,
                .layers = &entity_layers,
            },
        }};
        const editor: types.Editor = .{
            .entity_types = &entity_types,
            .active_tool = .{ .entity_type = 0 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{
            .editor_inspector_scroll = 999,
            .editor_inspector_section_expanded = allInspectorSectionsExpanded(),
        };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{
            "Skill bar", "- Layers", "Layer 1", "hood", "Delete", "Layer 1 color", "Add layer", "Pick sprite",
        });

        // The layer slot row: the stem button opens the ENTITY layer
        // picker for index 0; Delete carries the same payload. The color
        // swatches carry the layer index + the layer-color action, the
        // current index (2) highlighted.
        var saw_stem_button = false;
        var saw_delete = false;
        var swatch_count: usize = 0;
        var highlighted_count: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .open_editor_entity_layer_picker and
                    button.editor_layer != null and button.editor_layer.? == 0)
                {
                    saw_stem_button = true;
                }
                if (button.action == .delete_editor_entity_layer and
                    button.editor_layer != null and button.editor_layer.? == 0)
                {
                    saw_delete = true;
                }
                if (button.action == .select_editor_entity_layer_color) {
                    try std.testing.expectEqual(@as(u32, 0), button.editor_layer.?);
                    swatch_count += 1;
                    if (button.highlighted) highlighted_count += 1;
                }
            },
            else => {},
        };
        try std.testing.expect(saw_stem_button);
        try std.testing.expect(saw_delete);
        try std.testing.expectEqual(@as(usize, 6), swatch_count);
        try std.testing.expectEqual(@as(usize, 1), highlighted_count);
    }

    // DECORATION content with one layer: the clamped window lands on the
    // footprint row + the whole Layers section (world-gradient swatches).
    {
        const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
        const decoration_layers = [_]types.DecorationLayer{.{
            .sprite = "tree_1_canopy",
            .color_index = 2,
            .pixel_dims = .{ .x = 512, .y = 256 },
        }};
        const decoration_types = [_]types.DecorationTypeDef{.{
            .id = "stone_2",
            .sprite = "stone_2",
            .footprint = &footprint,
            .pixel_dims = .{ .x = 512, .y = 256 },
            .layers = &decoration_layers,
        }};
        const editor: types.Editor = .{
            .decoration_types = &decoration_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{
            .editor_inspector_scroll = 999,
            .editor_inspector_section_expanded = allInspectorSectionsExpanded(),
        };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try expectInspectorLabels(&elements, &.{
            "Footprint", "2 tiles", "- Layers", "Layer 1", "tree_1_canopy", "Delete", "Layer 1 color", "Add layer", "Pick sprite",
        });

        var swatch_count: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_layer_color) {
                try std.testing.expectEqual(@as(u32, 0), button.editor_layer.?);
                swatch_count += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 6), swatch_count);
    }
}

test "buildEditorSpritePicker: layer modes — entity stems, dims-filtered decoration stems" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // ENTITY layer mode (editing layer 0, sprite "bear"): the Official
    // tab lists the shipped entity sprites (player excluded) with the
    // entity-layer pick action; the edited layer's sprite highlights.
    {
        const entity_layers = [_]types.EntityLayer{.{ .sprite = "bear", .color_index = 2 }};
        const entity_types = [_]types.EntityTypeDef{.{
            .id = "Skeleton",
            .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1, .layers = &entity_layers },
        }};
        const editor: types.Editor = .{
            .entity_types = &entity_types,
            .active_tool = .{ .entity_type = 0 },
        };
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &.{},
            &.{},
            .{ .entity_layer = 0 },
            .official,
        );
        var pick_buttons: usize = 0;
        var highlighted: ?[]const u8 = null;
        var saw_player = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_layer) {
                pick_buttons += 1;
                if (std.mem.eql(u8, button.editor_sprite.?, "player")) saw_player = true;
                if (button.highlighted) highlighted = button.editor_sprite;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 9), pick_buttons);
        try std.testing.expect(!saw_player);
        try std.testing.expectEqualStrings("bear", highlighted.?);
    }

    // DECORATION layer mode (add — null index): the Official tab lists
    // ONLY the shipped decoration sprites whose dims match the base
    // type's (512x256 here) — the load-time layer invariant — with the
    // decoration-layer pick action; nothing highlights in add mode.
    {
        const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
        const decoration_types = [_]types.DecorationTypeDef{.{
            .id = "stone_2",
            .sprite = "stone_2",
            .footprint = &footprint,
            .pixel_dims = .{ .x = 512, .y = 256 },
        }};
        const editor: types.Editor = .{
            .decoration_types = &decoration_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &.{},
            &.{},
            .{ .decoration_layer = null },
            .official,
        );
        var pick_buttons: usize = 0;
        var highlighted_count: usize = 0;
        var saw_mismatched_dims = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_layer) {
                pick_buttons += 1;
                if (button.highlighted) highlighted_count += 1;
            },
            .image => |image| {
                // The cells' graphics all aspect-fit at 512x256 (the
                // entity-frame convention is 512x640 — a mismatched
                // filter leak would show up as a taller fit).
                if (image.height > @divFloor(slot_size * 256, 512)) saw_mismatched_dims = true;
            },
            else => {},
        };
        try std.testing.expect(pick_buttons > 0);
        try std.testing.expectEqual(@as(usize, 0), highlighted_count);
        try std.testing.expect(!saw_mismatched_dims);
    }
}

test "buildEditorFootprintEditor: tile cells, white region outline, confirm; inspector row opens it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
    }};
    const editor: types.Editor = .{
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
    };

    // The editor panel with the draft selecting ONLY cell (0,0): two
    // toggle cells, the shipped-sprite graphic, a 4-bar white outline
    // around the lone selected cell (every side is a boundary — the
    // neighbor (1,0) is unselected, the others off-grid), and the
    // Confirm button.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        ui_state.editor_footprint_draft[0] = true;
        try buildEditorFootprintEditor(&elements, arena.allocator(), metrics, editor, theme, 0, &ui_state);

        var toggle_buttons: usize = 0;
        var saw_graphic = false;
        var saw_confirm = false;
        var saw_close = false;
        var white_bars: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .toggle_editor_footprint_tile) {
                    toggle_buttons += 1;
                    try std.testing.expect(button.editor_footprint_tile != null);
                }
                if (button.action == .confirm_editor_footprint) saw_confirm = true;
                if (button.action == .close_editor_picker) saw_close = true;
            },
            .image => |image| {
                if (std.mem.eql(u8, image.sprite_id, "decorations/stone_2")) saw_graphic = true;
            },
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, default_tint)) white_bars += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), toggle_buttons);
        try std.testing.expect(saw_graphic);
        try std.testing.expect(saw_confirm);
        try std.testing.expect(saw_close);
        try std.testing.expectEqual(@as(usize, 4), white_bars);
    }

    // A custom-stem type: no renderable art — the cells get dark fills so
    // the grid stays visible (2 fills, no image).
    {
        const custom_types = [_]types.DecorationTypeDef{.{
            .id = "custom/x/banner",
            .sprite = "custom/x/banner",
            .footprint = &footprint,
            .pixel_dims = .{ .x = 512, .y = 256 },
        }};
        const custom_editor: types.Editor = .{
            .decoration_types = &custom_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        ui_state.editor_footprint_draft[0] = true;
        ui_state.editor_footprint_draft[1] = true;
        try buildEditorFootprintEditor(&elements, arena.allocator(), metrics, custom_editor, theme, 0, &ui_state);

        var saw_image = false;
        var dark_fills: usize = 0;
        var white_bars: usize = 0;
        for (elements.items) |element| switch (element) {
            .image => saw_image = true,
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, .{ .r = 40, .g = 40, .b = 40 })) dark_fills += 1;
                if (std.meta.eql(rect.color, default_tint)) white_bars += 1;
            },
            else => {},
        };
        try std.testing.expect(!saw_image);
        try std.testing.expectEqual(@as(usize, 2), dark_fills);
        // Both cells selected: the region's boundary is the 2x1 block's
        // outer rectangle — 6 bars (2 top + 2 bottom + 1 left + 1 right).
        try std.testing.expectEqual(@as(usize, 6), white_bars);
    }

    // The inspector's Footprint row: a "<N> tiles" button that opens the
    // editor.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        var saw_footprint_button = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .open_editor_footprint_picker) {
                saw_footprint_button = true;
            },
            else => {},
        };
        try std.testing.expect(saw_footprint_button);
    }
}

test "buildEditorSettingsSidebar: toggle always, panel + name fields when open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const player_five: types.Color = .{ .r = 40, .g = 40, .b = 40 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 5 ++ .{player_five} },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const levels = [_]types.EditorLevel{ .{ .name = "First" }, .{ .name = "Second" } };
    const editor: types.Editor = .{
        .levels = &levels,
        .mission = .{ .name = "My Mission" },
        .active_level_index = 1,
    };

    // Open (the default): toggle (panel + button + label) + background
    // panel + two section strips (panel + label each) + two name entries
    // (label + text field each) = 12 elements.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorSettingsSidebar(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        try std.testing.expectEqual(@as(usize, 12), elements.items.len);

        // The toggle button: flush RIGHT at the inspector toggle's height.
        const toggle_panel = elements.items[0].nine_slice_panel;
        try std.testing.expectEqualStrings("ui/panel", toggle_panel.sprite_id);
        try std.testing.expectEqual(top_bar_height + ui_gap, toggle_panel.screen_position.y);
        try std.testing.expectEqual(types.reference_width, toggle_panel.screen_position.x + toggle_panel.width);
        const toggle_button = elements.items[1].button;
        try std.testing.expectEqual(Action.toggle_editor_settings_sidebar, toggle_button.action);

        // The background panel: the shared rect fn (the M2 press
        // arbitration reads the same geometry), right-aligned.
        const panel = elements.items[3].nine_slice_panel;
        try std.testing.expectEqual(
            editorSettingsSidebarPanelRect(),
            Rectangle{
                .x = panel.screen_position.x,
                .y = panel.screen_position.y,
                .width = panel.width,
                .height = panel.height,
            },
        );
        try std.testing.expectEqual(types.reference_width, panel.screen_position.x + panel.width);
        try std.testing.expectEqual(theme.darkest, panel.color);

        // The two text fields: mission ref + the ACTIVE TAB's level ref,
        // seeded with the current names.
        var mission_field: ?TextFieldUi = null;
        var level_field: ?TextFieldUi = null;
        for (elements.items) |element| switch (element) {
            .text_field => |field| switch (field.ref.id) {
                .mission_name => mission_field = field,
                .level_name => level_field = field,
                else => {},
            },
            else => {},
        };
        try std.testing.expect(mission_field != null);
        try std.testing.expectEqualStrings("My Mission", mission_field.?.text);
        try std.testing.expectEqual(types.TextEditTarget.mission, mission_field.?.ref.target);
        try std.testing.expect(level_field != null);
        try std.testing.expectEqualStrings("Second", level_field.?.text);
        try std.testing.expectEqual(types.TextEditTarget{ .level = 1 }, level_field.?.ref.target);
    }

    // Closed: just the toggle (3 elements).
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        try buildEditorSettingsSidebar(&elements, arena.allocator(), metrics, editor, theme, false, &ui_state);
        try std.testing.expectEqual(@as(usize, 3), elements.items.len);
        try std.testing.expectEqual(Action.toggle_editor_settings_sidebar, elements.items[1].button.action);
    }
}
