//! UI interaction state: `UiState` (open panels/overlays, drag + click
//! + marquee lifecycles, the editor picker target + footprint draft,
//! inspector/metadata scroll + expansion) and its satellite types. Lives
//! on `SessionState`, off the undo timeline. See DESIGN → UI Framework.

const std = @import("std");
const types = @import("../types.zig");
const element = @import("element.zig");
const text_input = @import("text_input.zig");

const ScreenPosition = types.ScreenPosition;
const SlotRef = element.SlotRef;
const TextEditState = text_input.TextEditState;

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
    /// The metadata sidebar's THEME PICKER (a gradient row's swatch):
    /// every gradient as a full-width strip, one pick per row. Carries
    /// the LEVEL INDEX it was opened on + the ROLE being picked (the
    /// world index, or an enemy/player override) — a mid-edit tab switch
    /// can't retarget the pick.
    level_gradient: struct { level_index: u32, role: types.LevelGradientRole },
};

/// The footprint editor's draft-grid capacity: 8×8 sprite-grid tiles
/// (2048px sprites). Shipped decoration art is 3×3 at most; a custom
/// sprite beyond the limit doesn't open the editor (custom dims
/// verification is a TODO). Public: the input layer's open gate reads it.
pub const editor_footprint_grid_cell_limit: usize = 64;

pub const editor_inspector_section_count: usize =
    @typeInfo(types.EditorInspectorSectionId).@"enum".fields.len;

pub const UiState = struct {
    /// Middle section panels, ordered by open time (first opened =
    /// leftmost). The open panels always occupy a contiguous prefix of the
    /// slots (closing compacts), so slot order IS display order and a
    /// reopened panel lands rightmost instead of recalling its pre-close
    /// slot.
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

    /// Which content tab the open settings screen shows (Settings /
    /// Keybinds). A view affordance — direct UiState write, off the undo
    /// timeline (the editor-browser tab convention). A tab switch resets
    /// `keybind_scroll_offset` (the other tab's list has its own extent).
    settings_tab: types.SettingsTab = .settings,

    /// The Keybinds tab's list scroll: the index of the first visible ROW
    /// (group headers + binding rows both count — the list is flat rows).
    /// One wheel notch = one row; lower clamp at the input site, upper
    /// clamp in the builder (authoritative — only it knows the content
    /// height). See DESIGN → UI Framework → Settings screen.
    keybind_scroll_offset: i32 = 0,

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
    /// = one cell. Index 0 = Entities, 1 = Decorations, 2 = Items.
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
    /// The metadata sidebar's scroll offset (row units) — same model as
    /// `editor_inspector_scroll`: clamped authoritative in the builder,
    /// lower-clamped in the wheel handler.
    editor_metadata_scroll: i32 = 0,
    /// The level-tab row's scroll window offset (the editor top bar): the
    /// index of the first visible tab. One wheel notch over the tab strip
    /// = one tab (the routing in input_handlers); `buildEditorLevelTabs`
    /// clamps the upper bound in place (authoritative — it knows the tab
    /// widths) and scrolls the minimum distance to bring the ACTIVE tab
    /// on-screen when (and only when) the active tab CHANGES (the
    /// `editor_level_tab_last_active` memo below) — a change-less frame
    /// never touches the offset, or it would fight every manual scroll.
    /// Off the undo timeline like the other scrolls.
    editor_level_tab_scroll: i32 = 0,
    /// The level index `buildEditorLevelTabs` last followed. The follow
    /// fires only on a CHANGE of the active tab (add-level's switch to the
    /// new tab, a delete shifting the active index, a tab click far from
    /// the window) — running it every frame would snap the window back to
    /// the active tab and make manual scrolling impossible.
    editor_level_tab_last_active: i32 = -1,

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

    /// Editor inspector: the player loadout inventory's selected slot (the
    /// Inventory section's detail rows insert below this slot's row).
    /// Direct UiState write at the slot-cell click site (the
    /// section-expansion discipline: selection is navigation, not
    /// authored content — off the undo timeline). Bounds-checked at every
    /// read; clicking the already-selected slot deselects (null).
    editor_inventory_selected_slot: ?u32 = null,

    /// Which tab the sprite picker is showing (Mission / Official). View
    /// affordance — a direct UiState write, off the undo timeline. Reset
    /// to `.mission_local` on every open (custom assets take priority over
    /// shipped ones).
    editor_picker_sprite_tab: types.EditorSpritePickerTab = .mission_local,

    /// Editor browser (the main-menu Editor button, the options-menu Open
    /// Mission button / ctrl+O): a full-screen modal over the editor OR
    /// the main menu, mirroring the load-save browser. Like the options
    /// menu it locks input (the input layer gates on it); the panel itself
    /// blocks input to the UI behind it. Auto-cleared by the
    /// screen-transition UI reset — open_editor bumps world_generation on
    /// every successful open, so the reset fires even editor-to-editor.
    /// See DESIGN → Architecture → Level Editor → The editor browser.
    editor_browser_open: bool = false,

    /// Which editor kind the browser is showing (the kind tab row —
    /// Mission today; Hub / Campaign append when those editors land).
    /// View affordance — a direct UiState write, off the undo timeline
    /// (the list-tab's convention); a kind switch resets the scroll.
    editor_browser_kind: types.EditorKind = .mission,

    /// Which tab the mission browser is showing (Your Missions / Official).
    /// View affordance — a direct UiState write, off the undo timeline.
    /// Reset to `.local` on every open (your collection is the primary
    /// target).
    editor_mission_browser_tab: types.EditorMissionBrowserTab = .local,

    /// Mission browser vertical scroll offset, in ROWS — the load-save
    /// browser's exact scroll model (one notch = one full row pitch, lower
    /// clamp at the input site, upper clamp authoritative in the builder).
    /// Cleared on every open. Off the undo timeline like the other scrolls.
    editor_mission_scroll_offset: i32 = 0,

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
    /// `handleRightClickInspect` in input_gestures.zig.
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

    /// In-progress tile-tool PAINT drag (see `handleEditorTileDrag` in
    /// input_gestures.zig). A plain left press over the viewport (tile tool
    /// active) sets it; the press tile paints immediately, then each tile
    /// the held pointer enters paints until release or context loss (tool
    /// switch away from tile / tab / screen change — the gesture's next
    /// call clears). A bool because the drag needs no press data (no
    /// threshold promotion — painting starts at press); the visited-tile
    /// set lives on SessionState (`editor_tile_drag_visited`). While set,
    /// the idle-input tile arm defers (the gesture owns the press).
    editor_tile_drag: bool = false,

    pub fn toggleMiddlePanel(self: *UiState, panel_id: MiddlePanelId) void {
        // If already open, close it and compact the remaining panels down
        // (the contiguous-prefix invariant above).
        for (&self.open_middle_panels) |*slot| {
            if (slot.*) |open| {
                if (open == panel_id) {
                    slot.* = null;
                    var write_index: usize = 0;
                    for (self.open_middle_panels) |maybe_panel| {
                        if (maybe_panel) |remaining| {
                            self.open_middle_panels[write_index] = remaining;
                            write_index += 1;
                        }
                    }
                    while (write_index < max_middle_panels) : (write_index += 1) {
                        self.open_middle_panels[write_index] = null;
                    }
                    return;
                }
            }
        }
        // Not open — append after the last open panel (rightmost in display
        // order). No-op when all slots are open.
        var target_index: usize = 0;
        for (self.open_middle_panels, 0..) |maybe_panel, index| {
            if (maybe_panel != null) target_index = index + 1;
        }
        if (target_index < max_middle_panels) {
            self.open_middle_panels[target_index] = panel_id;
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


test "toggleMiddlePanel: open order is display order; reopen lands rightmost" {
    const Panels = [max_middle_panels]?MiddlePanelId;
    var ui_state = UiState{};

    // Open order = slot order (leftmost first).
    ui_state.toggleMiddlePanel(.inventory);
    ui_state.toggleMiddlePanel(.skills);
    try std.testing.expectEqual(
        Panels{ .inventory, .skills, null, null },
        ui_state.open_middle_panels,
    );

    // Closing a middle panel compacts the rest (contiguous prefix).
    ui_state.toggleMiddlePanel(.inventory);
    try std.testing.expectEqual(
        Panels{ .skills, null, null, null },
        ui_state.open_middle_panels,
    );

    // Reopening appends rightmost — it does not recall its pre-close slot.
    ui_state.toggleMiddlePanel(.inventory);
    try std.testing.expectEqual(
        Panels{ .skills, .inventory, null, null },
        ui_state.open_middle_panels,
    );

    // Closing the rightmost panel leaves the prefix intact.
    ui_state.toggleMiddlePanel(.inventory);
    try std.testing.expectEqual(
        Panels{ .skills, null, null, null },
        ui_state.open_middle_panels,
    );
    ui_state.toggleMiddlePanel(.skills);
    try std.testing.expectEqual(
        Panels{ null, null, null, null },
        ui_state.open_middle_panels,
    );
}

test "toggleMiddlePanel: a full panel strip ignores a new open" {
    const Panels = [max_middle_panels]?MiddlePanelId;
    var ui_state = UiState{};
    for ([_]MiddlePanelId{ .inventory, .gear, .skills, .entity_inspect }) |panel_id| {
        ui_state.toggleMiddlePanel(panel_id);
    }
    // All four are open — a fifth panel id cannot be stored, so this
    // close-then-reopen pair must not clobber anything.
    ui_state.toggleMiddlePanel(.inventory);
    try std.testing.expectEqual(
        Panels{ .gear, .skills, .entity_inspect, null },
        ui_state.open_middle_panels,
    );
    ui_state.toggleMiddlePanel(.inventory);
    try std.testing.expectEqual(
        Panels{ .gear, .skills, .entity_inspect, .inventory },
        ui_state.open_middle_panels,
    );
    // The strip is full again; toggling a panel that is already open still
    // closes it, and the freed slot is usable.
    ui_state.toggleMiddlePanel(.entity_inspect);
    try std.testing.expectEqual(
        Panels{ .gear, .skills, .inventory, null },
        ui_state.open_middle_panels,
    );
}
