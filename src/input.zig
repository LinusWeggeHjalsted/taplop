//! Input pipeline. Translates raw platform input (keyboard, mouse, touch)
//! into `PlayerInput` (anytime actions, idle game actions, pointer/drag
//! state) against the keybindings in `data/default_settings.txt`. Owns the camera
//! transforms: `screenToTile` (reference-space inverse) and `floatWorldPoint`
//! (float inverse, for camera pan). `tile_size_pixels` (256) is the
//! shared gameplay↔screen scale. The pointer lives in `PointerPosition`
//! (f32, reference space); the UI layout grid is `types.ScreenPosition`
//! (i32) — cross via `PointerPosition.toScreenPosition`.

const std = @import("std");
const types = @import("types.zig");
const ui = @import("ui.zig");

const Vector2 = types.Vector2;
const SkillId = types.SkillId;
pub const Modifiers = types.Modifiers;
const InputBinding = types.InputBinding;
const RawInput = types.RawInput;
const Settings = types.Settings;
const Camera = types.Camera;

// ============================================================
// Platform layer types — raw input from JS/native
// ============================================================

/// Pointer position in reference space (window pixels mapped through the
/// render letterbox inverse). Floats because the letterbox scale maps window
/// pixels to reference space non-1:1, so the pointer legitimately lands
/// between reference pixels — `screenToTile` needs that sub-pixel precision
/// at tile boundaries. Distinct from `types.ScreenPosition` (the integer
/// layout grid UI/drawables live on); cross the seam via `toScreenPosition`.
pub const PointerPosition = struct {
    x: f32,
    y: f32,

    /// Truncate to the integer reference-pixel grid (`types.ScreenPosition`).
    /// Used by hover passes that feed UI hit-testing (the layout grid is i32).
    pub fn toScreenPosition(self: PointerPosition) types.ScreenPosition {
        return .{ .x = @intFromFloat(self.x), .y = @intFromFloat(self.y) };
    }
};

/// Viewport dimensions in logical pixels.
pub const ViewportSize = struct {
    width: f32,
    height: f32,
};

/// Identifies a single finger/pointer across touch events.
pub const TouchId = u32;

/// A raw input event as produced by the platform layer (browser/native).
/// The platform just buffers these each tick and hands them over.
/// Key/button identifiers are human-readable strings (W3C KeyboardEvent.code
/// for keys, e.g. "KeyA", "Space", "ControlLeft").
pub const PlatformInputEvent = union(enum) {
    key_down: []const u8,
    key_up: []const u8,
    mouse_button_down: []const u8,
    mouse_button_up: []const u8,
    mouse_move: PointerPosition,
    mouse_scroll: f32, // positive = scroll up, negative = scroll down
    gamepad_button_down: []const u8,
    gamepad_button_up: []const u8,
    touch_start: TouchEvent,
    touch_move: TouchEvent,
    touch_end: TouchEvent,
};

pub const TouchEvent = struct {
    id: TouchId,
    position: PointerPosition,
};

/// Everything the platform layer hands to the game each update tick.
pub const PlatformInput = struct {
    events: []const PlatformInputEvent,
    viewport: ViewportSize,
    /// UTF-8 text characters typed this frame (the platform text/IME
    /// queue — distinct from key edges; a held key's repeat arrives as a
    /// key edge, IME-composed text arrives here). Only consumed while a
    /// text field is focused; the backend drains the queue unconditionally
    /// so it can't back up. See DESIGN → UI Framework → Text input widget.
    text_characters: []const u8 = &.{},
};

// ============================================================
// Input state — persistent across ticks, updated by translateInput
// ============================================================

/// Tracks which keys/buttons are currently held and pointer positions.
/// Lives on GameState so it persists across ticks.
pub const InputState = struct {
    keys_held: [max_held_keys]?[]const u8 = .{null} ** max_held_keys,
    mouse_buttons_held: [max_held_mouse]?[]const u8 = .{null} ** max_held_mouse,
    gamepad_buttons_held: [max_held_gamepad]?[]const u8 = .{null} ** max_held_gamepad,
    mouse_screen_position: PointerPosition = .{ .x = 0, .y = 0 },
    active_touches: [max_touch_points]?ActiveTouch = .{null} ** max_touch_points,
    /// Per-key hold timer for synthetic key repeat (see DESIGN → Input).
    /// Parallel to `keys_held`: an entry is created on a key_down edge and
    /// removed on key_up. Advanced by `advanceKeyRepeats` each tick; when a
    /// held key crosses its next-repeat threshold it fires a synthetic edge
    /// into `keys_repeated` for `checkAction` to consult. Only actions in the
    /// repeat whitelist (movement cursors, undo/redo, skip, error-scroll)
    /// pass `keys_repeated` to `checkAction`, so non-whitelisted bindings
    /// (skill slots, toggles, confirm/cancel) never repeat.
    key_repeat_state: [max_held_keys]?KeyRepeatEntry = .{null} ** max_held_keys,

    pub const max_held_keys = 16;
    pub const max_held_mouse = 5;
    pub const max_held_gamepad = 16;
    pub const max_touch_points = 10;

    /// Per-key synthetic-repeat timer. `held_microseconds` accumulates since
    /// the press edge; `next_repeat_at` is the held-time threshold at which
    /// the next synthetic edge fires (initialized to the initial delay, then
    /// bumped by the repeat interval after each fire).
    pub const KeyRepeatEntry = struct {
        key_id: []const u8,
        held_microseconds: u64 = 0,
        next_repeat_at: u64 = key_repeat_initial_delay_microseconds,
    };

    pub const ActiveTouch = struct {
        id: TouchId,
        position: PointerPosition,
    };

    /// Check if a string-identified input is in a held-inputs array.
    fn isHeld(held: []const ?[]const u8, id: []const u8) bool {
        for (held) |slot| {
            if (slot) |held_id| {
                if (std.mem.eql(u8, held_id, id)) return true;
            }
        }
        return false;
    }

    /// Add an input to a held-inputs array. No-op if already present or full.
    fn addHeld(held: []?[]const u8, id: []const u8) void {
        // Already held?
        if (isHeld(held, id)) return;
        // Find empty slot
        for (held) |*slot| {
            if (slot.* == null) {
                slot.* = id;
                return;
            }
        }
    }

    /// Remove an input from a held-inputs array.
    fn removeHeld(held: []?[]const u8, id: []const u8) void {
        for (held) |*slot| {
            if (slot.*) |held_id| {
                if (std.mem.eql(u8, held_id, id)) {
                    slot.* = null;
                    return;
                }
            }
        }
    }

    /// Start (or reset) synthetic-repeat tracking for a key. Called on a
    /// key_down edge alongside `addHeld(&keys_held, ...)`.
    fn addRepeat(self: *InputState, id: []const u8) void {
        // If an entry already exists for this key, reset its timer (a fresh
        // press edge restarts the initial-delay countdown).
        for (&self.key_repeat_state) |*slot| {
            if (slot.*) |*entry| {
                if (std.mem.eql(u8, entry.key_id, id)) {
                    entry.held_microseconds = 0;
                    entry.next_repeat_at = key_repeat_initial_delay_microseconds;
                    return;
                }
            }
        }
        for (&self.key_repeat_state) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .key_id = id };
                return;
            }
        }
    }

    /// Stop synthetic-repeat tracking for a key. Called on key_up.
    fn removeRepeat(self: *InputState, id: []const u8) void {
        for (&self.key_repeat_state) |*slot| {
            if (slot.*) |entry| {
                if (std.mem.eql(u8, entry.key_id, id)) {
                    slot.* = null;
                    return;
                }
            }
        }
    }

    /// Advance all held-key repeat timers by `delta_microseconds` and, for
    /// each key that has crossed its next-repeat threshold, append a
    /// synthetic edge to `repeated`. Fires at most once per key per tick
    /// (a stall that jumps past several intervals catches up by one repeat,
    /// not a burst — real-time input does not accumulate).
    fn advanceKeyRepeats(
        self: *InputState,
        delta_microseconds: u64,
        repeated: []?[]const u8,
    ) void {
        for (&self.key_repeat_state) |*slot| {
            if (slot.*) |*entry| {
                entry.held_microseconds +%= delta_microseconds;
                if (entry.held_microseconds >= entry.next_repeat_at) {
                    addHeld(repeated, entry.key_id);
                    // Skip any backlog from a large delta: schedule the next
                    // fire one interval from now, not from the missed target.
                    entry.next_repeat_at = entry.held_microseconds +
                        key_repeat_interval_microseconds;
                }
            }
        }
    }
};

// ============================================================
// Player input — semantic actions for the game logic
// ============================================================

pub const PlayerInput = struct {
    anytime: AnytimeInput = .{},
    idle: IdleInput = .{},
    pointer: PointerInput = .{},
    /// Current modifier-key state at input translation time. Read by the
    /// idle-input path for per-action overrides (e.g. ctrl held at click-time
    /// forces the attack step even with auto_skip enabled). Not a binding —
    /// bindings filter on modifiers in checkAction; this is the raw held state.
    modifiers: Modifiers = .{},
    /// Text-field keyboard resolution for this frame (Enter/Escape while a
    /// field is focused — see DESIGN → UI Framework → Text input widget).
    /// Resolved ONCE per frame by the caller (main), never per update()
    /// drain iteration. `.none` when no field is focused.
    text_edit_outcome: types.TextEditOutcome = .none,
};

/// Shared movement threshold for drag gestures (inventory drag once it
/// gains click-vs-drag disambiguation, camera pan). A pointer move of more
/// than this many reference pixels between press and release counts as a drag
/// rather than a click. 0 = any move is a drag. Centralized so it can be
/// tuned in one place if real-world use shows it needs a dead zone for jittery
/// clicks. Referenced by handleCameraPan.
pub const drag_threshold_pixels: i32 = 0;

/// Synthetic key-repeat cadence (see `InputState.KeyRepeatEntry`). A held
/// key fires its first repeat after this delay, then repeats at this
/// interval. Owns the cadence so players cannot gain a real-time advantage
/// by twiddling OS key-repeat settings. Tuned from in-game feel.
const key_repeat_initial_delay_microseconds: u64 = 300 * std.time.us_per_ms;
const key_repeat_interval_microseconds: u64 = 40 * std.time.us_per_ms;

/// Raw primary-pointer facts for the UI-resolution step (hit-testing, drag
/// lifecycle). Deliberately semantic-free: main.zig decides what a press/
/// release over a given position means. Position is in reference-resolution
/// space (types.ScreenPosition), matching where ui_elements are laid out.
pub const PointerInput = struct {
    pressed: bool = false, // primary button went down this tick
    released: bool = false, // primary button went up this tick
    held: bool = false, // primary button is held (for slider drag)
    position: types.ScreenPosition = .{ .x = 0, .y = 0 },
    /// Secondary (right) button edges + held state, for the camera-pan drag.
    /// Not a binding — like the tile cursor, this is raw pointer state
    /// consumed in the input path (see handleCameraPan).
    right_pressed: bool = false,
    right_released: bool = false,
    right_held: bool = false,
    /// Held keyboard modifiers at this tick. Surfaced here (off `InputState`)
    /// so slot-click handlers can resolve modifier-keyed intents (ctrl/alt/
    /// shift click) without reaching into input state.
    modifiers: types.Modifiers = .{},
};

/// Actions that can be handled regardless of event stack state.
pub const AnytimeInput = struct {
    undo: bool = false,
    redo: bool = false,
    /// Escape — drives the overlay-close chain in handleAnytimeInput (see
    /// Action.toggle_options_menu + DESIGN → Input → Escape overlay chain).
    toggle_options_menu: bool = false,
    dump_event_log: bool = false,
    /// Save the edited mission (ctrl+S / the editor options-menu button).
    /// Editor-only: consumed in handleAnytimeInput's editor gate; a no-op
    /// on every other screen (the delete_editor_selection discipline).
    save_editor_mission: bool = false,
    /// Export the edited mission as a .zip (the editor options-menu
    /// button). Same consumption + no-op discipline as
    /// `save_editor_mission`.
    export_editor_mission: bool = false,
    /// Dismiss a recoverable error popup (see SessionState.pending_error).
    /// Modal: when a pending error is shown, handleAnytimeInput lets only
    /// this through and swallows everything else.
    dismiss_error: bool = false,
    /// Scroll the error popup body by a step (arrows). Only consumed while a
    /// pending error is shown. See DESIGN → Error Handling.
    error_scroll_up: bool = false,
    error_scroll_down: bool = false,
    scroll_delta: f32 = 0,
    // Keyboard zoom shortcuts (PgUp / PgDn / ctrl+0). Press-only — the
    // mouse wheel (scroll_delta) is the continuous path. See Action.zoom_*.
    zoom_in: bool = false,
    zoom_out: bool = false,
    zoom_reset: bool = false,
    /// A button action from the options menu (context-specific: save, exit,
    /// etc.). Dispatched in handleAnytimeInput before the options-menu gate,
    /// so the action takes effect immediately even though the menu pauses
    /// the game. Null when no options button was clicked this tick.
    options_action: ?types.Action = null,
    /// Which settings control was clicked, set alongside
    /// `options_action == .change_setting` by the button-release dispatch
    /// in main.zig — Action can't carry a payload, so the SettingRef rides
    /// here. Valid only in the same frame as the click. See DESIGN → UI
    /// Framework → Settings screen.
    clicked_setting: ?types.SettingRef = null,
    /// Which editor palette group's header or "+" cell was clicked
    /// (expand/collapse / add-new-type), set alongside
    /// `options_action == .toggle_editor_palette_group` /
    /// `.add_editor_palette_type` by the button-release dispatch in
    /// main.zig — same payload-rides-along pattern as `clicked_setting`.
    /// Valid only in the same frame as the click.
    clicked_editor_group: ?usize = null,
    /// Which inspector section header was clicked (expand/collapse), set
    /// alongside `options_action == .toggle_editor_inspector_section` by
    /// the button-release dispatch — same payload-rides-along pattern.
    /// Valid only in the same frame as the click.
    clicked_editor_section: ?types.EditorInspectorSectionId = null,
    /// Which sprite picker cell was clicked (the sprite stem — for a
    /// mission-local pick, the namespaced `custom/<mission>/<stem>` id),
    /// set alongside `options_action == .select_editor_entity_sprite`.
    /// Valid only in the same frame as the click.
    clicked_editor_sprite: ?[]const u8 = null,
    /// Which sprite picker tab button was clicked (Mission / Official),
    /// set alongside `options_action == .select_editor_sprite_tab`.
    clicked_editor_sprite_tab: ?types.EditorSpritePickerTab = null,
    /// Which editor tool was clicked (make it active), set alongside
    /// `options_action == .select_editor_tool` (a tool cell) or
    /// `.delete_editor_palette_type` (a tool cell's delete button) by the
    /// button-release dispatch in main.zig — same payload-rides-along
    /// pattern as `clicked_setting`. Valid only in the same frame as the
    /// click.
    clicked_editor_tool: ?types.EditorToolId = null,
    /// Which editor level tab was clicked (make that level active) or which
    /// tab's × button was clicked (delete it), set alongside
    /// `options_action == .select_editor_level` / `.delete_editor_level` by
    /// the button-release dispatch in main.zig — same payload-rides-along
    /// pattern as `clicked_setting`. Valid only in the same frame as the
    /// click.
    clicked_editor_level: ?u32 = null,
    /// Editor entity color-swatch index, set alongside
    /// `options_action == .select_editor_entity_color` by the release
    /// dispatch (the inspector's swatch row).
    clicked_editor_color: ?u32 = null,
    /// Editor gear slot, set alongside `options_action ==
    /// .select_editor_weapon_type / .add_editor_item / .delete_editor_item`
    /// by the release dispatch (the inspector's slot controls).
    clicked_editor_gear_slot: ?types.GearSlot = null,
    /// Editor weapon type, set alongside
    /// `options_action == .select_editor_weapon_type` (a weapon-type cell)
    /// or `.select_editor_item_type` (an item-type pick cell).
    clicked_editor_weapon_type: ?types.WeaponType = null,
    /// Editor item KIND, set alongside
    /// `options_action == .select_editor_item_type` (the item content's
    /// type-pick rows; weapon cells pair it with
    /// `clicked_editor_weapon_type`).
    clicked_editor_item_kind: ?types.ItemKind = null,
    /// Editor utility-slot index, set alongside
    /// `options_action == .open_editor_skill_picker` (an inspector slot
    /// button).
    clicked_editor_utility_slot: ?u32 = null,
    /// Editor layer index, set alongside the Layers sections' actions
    /// (a layer's sprite/color/delete controls; null on the add-layer
    /// button = the picker's add mode).
    clicked_editor_layer: ?u32 = null,
    /// Footprint-editor grid cell (row-major), set alongside
    /// `options_action == .toggle_editor_footprint_tile`.
    clicked_editor_footprint_tile: ?u32 = null,
    /// Settings-sidebar gradient role (world / enemy / player), set
    /// alongside `options_action == .open_editor_level_gradient_picker` /
    /// `.toggle_editor_level_gradient_auto` by the release dispatch.
    clicked_editor_gradient_role: ?types.LevelGradientRole = null,
    /// Theme-picker gradient index, set alongside
    /// `options_action == .select_editor_level_gradient`.
    clicked_editor_gradient: ?u32 = null,
    /// Editor skill pick, set alongside
    /// `options_action == .select_editor_utility_skill` (a picker cell).
    /// No payload = the picker's None cell.
    clicked_editor_skill: ?types.SkillId = null,
    /// Mission-browser tab, set alongside
    /// `options_action == .select_editor_mission_tab` by the release
    /// dispatch (one of the browser's two tab buttons).
    clicked_editor_mission_tab: ?types.EditorMissionBrowserTab = null,
    /// Mission-browser row index (into the current tab's list), set
    /// alongside `options_action == .open_editor_mission_row` by the
    /// release dispatch (a mission row). Valid only in the same frame as
    /// the click — the row is resolved against the CURRENT tab's list
    /// before any rescan can replace it.
    clicked_editor_mission_row: ?u32 = null,
    /// Open/close the editor's mission browser (the options-menu Open
    /// Mission button, the browser's Back button, and the ctrl+O binding).
    /// Editor-screen-only at the consumption site (the
    /// save_editor_mission no-op discipline).
    toggle_editor_mission_browser: bool = false,

    /// Only handled when the player is in a hub or level.
    in_game: InGameInput = .{},
};

/// Anytime actions that are only valid in a hub or level context.
pub const InGameInput = struct {
    toggle_inventory: bool = false,
    toggle_gear: bool = false,
    toggle_skills: bool = false,
    toggle_entity_inspect: bool = false,
    toggle_world_map: bool = false,
    swap_weapons: bool = false,
    /// Raw, unvalidated tile under the mouse this frame (screenToTile of the
    /// mouse position; may not be a real level/hub tile). The cursor
    /// resolution step in update() validates it against the world tiles and
    /// applies UI occlusion before writing session.tile_cursor.
    mouse_tile: ?Vector2 = null,
    /// True if the mouse moved this tick. The cursor resolution uses this to
    /// decide whether the mouse or the arrow keys own the cursor this frame
    /// (mouse takes precedence when it moved; otherwise arrows nudge).
    mouse_moved_this_tick: bool = false,
    // Arrow-key cursor nudges (edge-triggered this tick). Consumed by the
    // cursor resolution as the TRIGGER ("should a nudge fire this frame?").
    move_cursor_up: bool = false,
    move_cursor_down: bool = false,
    move_cursor_left: bool = false,
    move_cursor_right: bool = false,
    /// Current cursor-direction vector derived from HELD cursor keys
    /// (independent of which fired this frame). (-1/0/+1 per axis; opposite
    /// keys cancel.) Lets a diagonal nudge fire when ANY one of the two held
    /// keys edges/repeats, instead of requiring both to fire in the same tick
    /// (two physical presses rarely land in one tick, and per-key repeat
    /// timers drift, so the old all-edges-this-frame model was inconsistent).
    cursor_direction: Vector2 = .{ .x = 0, .y = 0 },
};

/// Actions that are only handled when the event stack is empty
/// (i.e. the game is waiting for player input).
pub const IdleInput = struct {
    tile_clicked: ?Vector2 = null,
    skill_slot_selected: ?u8 = null, // 1-8, game logic resolves to SkillId
    confirm: bool = false,
    cancel: bool = false,
    skip: bool = false,
    // Dev tool: skip the current level. Press-only. Gated to dev builds +
    // level screen at the handler site; the binding ships in
    // default_settings.txt and no-ops elsewhere. See DESIGN → Input.
    skip_level: bool = false,
    // Editor select tool: delete the current selection (Delete key,
    // press-only). Consumed in handleIdleInput's editor arm — a no-op on
    // every other screen. See DESIGN → Architecture → Level Editor →
    // Selection model.
    delete_editor_selection: bool = false,
    // Editor select tool: clear the current selection (ctrl+D, press-only).
    // Same consumption + no-op discipline as `delete_editor_selection`.
    clear_editor_selection: bool = false,
    // Editor select tool: select everything in the active level (ctrl+A,
    // press-only). Same consumption + no-op discipline as
    // `delete_editor_selection` (plus a select-tool gate — every
    // selection op requires the select tool).
    select_editor_all: bool = false,
    /// A main-menu command (New Game / Load Save / ...), set only when a menu
    /// button is clicked (no keybind path). Handled by the main_menu branch of
    /// handleIdleInput.
    menu_action: ?types.Action = null,

    /// Which save row in the load-save browser was clicked (index into
    /// SessionState.save_files), set alongside `menu_action == .load_save_row`
    /// by the button-release dispatch in main.zig — Action can't carry the
    /// payload, so it rides in this sibling field. Valid only in the same
    /// frame as the click (not a keybind path).
    clicked_save_row: ?u32 = null,
};

/// Fold a UI Button's Action into `player_input` so a click drives the exact
/// same path as the equivalent keybind (buttons carry the same Action enum).
/// Actions with an existing input field set that field; main-menu commands
/// (which have no keybind) go to idle.menu_action. This is the one bridge from
/// "button was clicked" to the semantic input the handlers already consume.
pub fn applyAction(player_input: *PlayerInput, action: types.Action) void {
    switch (action) {
        .undo => player_input.anytime.undo = true,
        .redo => player_input.anytime.redo = true,
        .toggle_options_menu => player_input.anytime.toggle_options_menu = true,
        .dump_event_log => player_input.anytime.dump_event_log = true,
        .save_editor_mission => player_input.anytime.save_editor_mission = true,
        .export_editor_mission => player_input.anytime.export_editor_mission = true,
        .dismiss_error => player_input.anytime.dismiss_error = true,
        .error_scroll_up => player_input.anytime.error_scroll_up = true,
        .error_scroll_down => player_input.anytime.error_scroll_down = true,
        .zoom_in => player_input.anytime.zoom_in = true,
        .zoom_out => player_input.anytime.zoom_out = true,
        .zoom_reset => player_input.anytime.zoom_reset = true,
        .save_game => player_input.anytime.options_action = action,
        .restart_mission, .exit_mission, .exit_to_menu => player_input.anytime.options_action = action,
        .continue_after_mission, .replay_mission, .overwrite_clone => player_input.anytime.options_action = action,
        // Settings is reachable from both the main-menu button and the
        // options-menu button; routing through `options_action` lets one
        // handler (in `handleAnytimeInput`) serve both contexts — the
        // options_action switch runs regardless of screen. See DESIGN → UI
        // Framework → Settings screen.
        .open_settings => player_input.anytime.options_action = action,
        .change_setting => player_input.anytime.options_action = action,
        .toggle_editor_palette_group => player_input.anytime.options_action = action,
        .add_editor_palette_type => player_input.anytime.options_action = action,
        .delete_editor_palette_type => player_input.anytime.options_action = action,
        .add_editor_level => player_input.anytime.options_action = action,
        .delete_editor_level => player_input.anytime.options_action = action,
        .select_editor_tool => player_input.anytime.options_action = action,
        .select_editor_level => player_input.anytime.options_action = action,
        .toggle_editor_inspector => player_input.anytime.options_action = action,
        .toggle_editor_metadata_sidebar => player_input.anytime.options_action = action,
        .toggle_editor_inspector_section => player_input.anytime.options_action = action,
        .open_editor_sprite_picker => player_input.anytime.options_action = action,
        .select_editor_entity_sprite => player_input.anytime.options_action = action,
        .select_editor_decoration_sprite => player_input.anytime.options_action = action,
        .select_editor_sprite_tab => player_input.anytime.options_action = action,
        .import_editor_player => player_input.anytime.options_action = action,
        .select_editor_entity_color => player_input.anytime.options_action = action,
        .select_editor_decoration_color => player_input.anytime.options_action = action,
        .open_editor_entity_layer_picker => player_input.anytime.options_action = action,
        .open_editor_decoration_layer_picker => player_input.anytime.options_action = action,
        .select_editor_entity_layer => player_input.anytime.options_action = action,
        .select_editor_decoration_layer => player_input.anytime.options_action = action,
        .delete_editor_entity_layer => player_input.anytime.options_action = action,
        .delete_editor_decoration_layer => player_input.anytime.options_action = action,
        .select_editor_entity_layer_color => player_input.anytime.options_action = action,
        .select_editor_decoration_layer_color => player_input.anytime.options_action = action,
        .open_editor_footprint_picker => player_input.anytime.options_action = action,
        .toggle_editor_footprint_tile => player_input.anytime.options_action = action,
        .confirm_editor_footprint => player_input.anytime.options_action = action,
        .open_editor_level_gradient_picker => player_input.anytime.options_action = action,
        .select_editor_level_gradient => player_input.anytime.options_action = action,
        .toggle_editor_level_gradient_auto => player_input.anytime.options_action = action,
        .toggle_editor_entity_displays_weapons => player_input.anytime.options_action = action,
        .select_editor_weapon_type => player_input.anytime.options_action = action,
        .select_editor_item_type => player_input.anytime.options_action = action,
        .add_editor_item => player_input.anytime.options_action = action,
        .delete_editor_item => player_input.anytime.options_action = action,
        .open_editor_skill_picker => player_input.anytime.options_action = action,
        .select_editor_mission_tab,
        .open_editor_mission_row,
        => player_input.anytime.options_action = action,
        .close_editor_picker => player_input.anytime.options_action = action,
        .toggle_editor_mission_browser => player_input.anytime.toggle_editor_mission_browser = true,
        .select_editor_utility_skill => player_input.anytime.options_action = action,
        .toggle_inventory => player_input.anytime.in_game.toggle_inventory = true,
        .toggle_gear => player_input.anytime.in_game.toggle_gear = true,
        .toggle_skills => player_input.anytime.in_game.toggle_skills = true,
        .toggle_entity_inspect => player_input.anytime.in_game.toggle_entity_inspect = true,
        .toggle_world_map => player_input.anytime.in_game.toggle_world_map = true,
        .swap_weapons => player_input.anytime.in_game.swap_weapons = true,
        .move_cursor_up => player_input.anytime.in_game.move_cursor_up = true,
        .move_cursor_down => player_input.anytime.in_game.move_cursor_down = true,
        .move_cursor_left => player_input.anytime.in_game.move_cursor_left = true,
        .move_cursor_right => player_input.anytime.in_game.move_cursor_right = true,
        .confirm => player_input.idle.confirm = true,
        .cancel => player_input.idle.cancel = true,
        .skip => player_input.idle.skip = true,
        .skip_level => player_input.idle.skip_level = true,
        .delete_editor_selection => player_input.idle.delete_editor_selection = true,
        .clear_editor_selection => player_input.idle.clear_editor_selection = true,
        .select_editor_all => player_input.idle.select_editor_all = true,
        .skill_slot_1 => player_input.idle.skill_slot_selected = 1,
        .skill_slot_2 => player_input.idle.skill_slot_selected = 2,
        .skill_slot_3 => player_input.idle.skill_slot_selected = 3,
        .skill_slot_4 => player_input.idle.skill_slot_selected = 4,
        .skill_slot_5 => player_input.idle.skill_slot_selected = 5,
        .skill_slot_6 => player_input.idle.skill_slot_selected = 6,
        .skill_slot_7 => player_input.idle.skill_slot_selected = 7,
        .skill_slot_8 => player_input.idle.skill_slot_selected = 8,
        .continue_game,
        .new_game,
        .toggle_load_save_menu,
        .load_save_row,
        .import_save,
        .open_editor,
        .open_credits,
        => player_input.idle.menu_action = action,
    }
}

// ============================================================
// Input translation — raw platform events → semantic PlayerInput
// ============================================================

/// On-screen size of one tile in reference-space pixels at zoom 1.0. Sprites
/// are authored at this resolution (tile.png is 256x256 = one tile; entity
/// frames are 512x640 = 2 tiles wide). The renderer and screenToTile share
/// this so clicks map back to the tile that was drawn.
pub const tile_size_pixels: f32 = 256.0;

/// Convert a screen-space position to tile coordinates.
/// Takes into account camera position and zoom level.
pub fn screenToTile(
    screen_position: PointerPosition,
    camera: Camera,
    zoom: f32,
    viewport: ViewportSize,
) Vector2 {
    // Screen center is where the camera points.
    // Offset from center, then scale by zoom and tile size.
    const world_x = (@as(f32, @floatFromInt(camera.position.x)) +
        (screen_position.x - viewport.width / 2.0)) / (tile_size_pixels * zoom);
    const world_y = (@as(f32, @floatFromInt(camera.position.y)) +
        (screen_position.y - viewport.height / 2.0)) / (tile_size_pixels * zoom);

    return .{
        .x = @intFromFloat(@floor(world_x)),
        .y = @intFromFloat(@floor(world_y)),
    };
}

/// The float world position (tile units) under a screen position — the
/// inverse of the camera transform, before `@floor`. Used by the camera-pan
/// anchor so the grabbed point tracks the cursor. Kept beside screenToTile so
/// the two halves of the camera<->screen mapping stay in sync.
/// NOTE: takes `types.ScreenPosition` (i32), so the input is already
/// truncated at the `PointerInput.position` seam — sub-pixel precision is
/// lost before this fn sees it. See TODO → Tech Debt (`floatWorldPoint`
/// precision loss).
pub fn floatWorldPoint(
    screen_position: types.ScreenPosition,
    camera: Camera,
    zoom: f32,
    viewport: ViewportSize,
) struct { x: f32, y: f32 } {
    const tile_pixels = tile_size_pixels * zoom;
    return .{
        .x = (@as(f32, @floatFromInt(camera.position.x)) +
            (@as(f32, @floatFromInt(screen_position.x)) - viewport.width / 2.0)) / tile_pixels,
        .y = (@as(f32, @floatFromInt(camera.position.y)) +
            (@as(f32, @floatFromInt(screen_position.y)) - viewport.height / 2.0)) / tile_pixels,
    };
}

/// Get the current modifier state from held keys.
fn getModifiers(state: *const InputState) Modifiers {
    return .{
        .ctrl = InputState.isHeld(&state.keys_held, "ControlLeft") or
            InputState.isHeld(&state.keys_held, "ControlRight"),
        .shift = InputState.isHeld(&state.keys_held, "ShiftLeft") or
            InputState.isHeld(&state.keys_held, "ShiftRight"),
        .alt = InputState.isHeld(&state.keys_held, "AltLeft") or
            InputState.isHeld(&state.keys_held, "AltRight"),
    };
}

/// Count a binding's required modifiers — its specificity for precedence
/// (see DESIGN → Input). A plain binding has specificity 0; ctrl+shift has 2.
fn modifierSpecificity(modifiers: Modifiers) u8 {
    var count: u8 = 0;
    if (modifiers.ctrl) count += 1;
    if (modifiers.shift) count += 1;
    if (modifiers.alt) count += 1;
    return count;
}

/// True if two `RawInput` refer to the same physical input (same variant +
/// id string). Used to find competing bindings on the same key/button.
fn sameInput(a: types.RawInput, b: types.RawInput) bool {
    return switch (a) {
        .key => |ak| switch (b) {
            .key => |bk| std.mem.eql(u8, ak, bk),
            else => false,
        },
        .mouse_button => |am| switch (b) {
            .mouse_button => |bm| std.mem.eql(u8, am, bm),
            else => false,
        },
        .gamepad_button => |ag| switch (b) {
            .gamepad_button => |bg| std.mem.eql(u8, ag, bg),
            else => false,
        },
    };
}

/// Hybrid precedence: `binding` (already matching the held modifiers + a
/// pressed input) is suppressed if another binding on the SAME input matches
/// the held modifiers with strictly MORE required modifiers — a more-specific
/// chord wins, a plain binding gives way to it. Equal-specificity bindings
/// co-fire (disambiguated by handler context downstream, e.g. ArrowUp →
/// move_cursor_up + error_scroll_up). See DESIGN → Input.
fn isSuppressed(
    binding: InputBinding,
    bindings: []const InputBinding,
    modifiers: Modifiers,
) bool {
    const my_specificity = modifierSpecificity(binding.modifiers);
    for (bindings) |other| {
        if (!sameInput(other.input, binding.input)) continue;
        // The competitor must also match the held modifiers to win.
        if (other.modifiers.ctrl and !modifiers.ctrl) continue;
        if (other.modifiers.shift and !modifiers.shift) continue;
        if (other.modifiers.alt and !modifiers.alt) continue;
        if (modifierSpecificity(other.modifiers) > my_specificity) return true;
    }
    return false;
}

/// Check if an action is currently HELD (any bound input is down), ignoring
/// edges. Used to derive cursor direction from held cursor keys so a diagonal
/// nudge fires when ANY one of the two held keys edges/repeats (see
/// `InGameInput.cursor_direction`). Modifier matching is the same subset
/// semantics as `checkAction`, with the same hybrid precedence.
fn isActionHeld(
    action: types.Action,
    bindings: []const InputBinding,
    keys_held: []const ?[]const u8,
    mouse_buttons_held: []const ?[]const u8,
    gamepad_buttons_held: []const ?[]const u8,
    modifiers: Modifiers,
) bool {
    for (bindings) |binding| {
        if (binding.action != action) continue;
        if (binding.modifiers.ctrl and !modifiers.ctrl) continue;
        if (binding.modifiers.shift and !modifiers.shift) continue;
        if (binding.modifiers.alt and !modifiers.alt) continue;
        const held = switch (binding.input) {
            .key => |key| InputState.isHeld(keys_held, key),
            .mouse_button => |button| InputState.isHeld(mouse_buttons_held, button),
            .gamepad_button => |gamepad| InputState.isHeld(gamepad_buttons_held, gamepad),
        };
        if (held) {
            if (isSuppressed(binding, bindings, modifiers)) continue;
            return true;
        }
    }
    return false;
}

/// Check if an action was triggered by any just-pressed input this tick.
/// `keys_repeated` carries synthetic key-repeat edges for held keys (see
/// `InputState.advanceKeyRepeats`); callers pass a non-empty slice only for
/// actions in the repeat whitelist so non-whitelisted bindings never repeat.
fn checkAction(
    action: types.Action,
    bindings: []const InputBinding,
    keys_pressed: []const ?[]const u8,
    keys_repeated: []const ?[]const u8,
    mouse_pressed: []const ?[]const u8,
    gamepad_pressed: []const ?[]const u8,
    modifiers: Modifiers,
) bool {
    for (bindings) |binding| {
        if (binding.action != action) continue;

        // A binding's modifiers are REQUIREMENTS, not an exact match: a plain
        // binding fires regardless of held modifiers (so ctrl+key works for
        // any plain-bound action, e.g. ctrl+Space skip with force-attack);
        // a ctrl binding fires only when ctrl is held. Skip only when a
        // REQUIRED modifier is not held.
        if (binding.modifiers.ctrl and !modifiers.ctrl) continue;
        if (binding.modifiers.shift and !modifiers.shift) continue;
        if (binding.modifiers.alt and !modifiers.alt) continue;

        // Check if the bound input was just pressed (real edge) or repeated
        // (synthetic edge for held keys, whitelist-permitting).
        const pressed = switch (binding.input) {
            .key => |key| InputState.isHeld(keys_pressed, key) or
                InputState.isHeld(keys_repeated, key),
            .mouse_button => |button| InputState.isHeld(mouse_pressed, button),
            .gamepad_button => |gamepad| InputState.isHeld(gamepad_pressed, gamepad),
        };

        if (pressed) {
            // Hybrid precedence — see DESIGN → Input. A more-specific chord
            // on the same input suppresses this binding; equal-specificity
            // ties co-fire (gated by handler context downstream).
            if (isSuppressed(binding, bindings, modifiers)) continue;
            return true;
        }
    }
    return false;
}

/// Process raw platform input events, update InputState, and produce
/// a PlayerInput with semantic actions for the game logic.
pub fn translateInput(
    platform: PlatformInput,
    state: *InputState,
    settings: Settings,
    camera: Camera,
    delta_microseconds: u64,
    text_edit: ?*ui.TextEditState,
) PlayerInput {
    // Track which inputs were just pressed this tick (edge detection)
    var keys_pressed: [InputState.max_held_keys]?[]const u8 = .{null} ** InputState.max_held_keys;
    var keys_repeated: [InputState.max_held_keys]?[]const u8 = .{null} ** InputState.max_held_keys;
    var mouse_pressed: [InputState.max_held_mouse]?[]const u8 = .{null} ** InputState.max_held_mouse;
    var mouse_released: [InputState.max_held_mouse]?[]const u8 = .{null} ** InputState.max_held_mouse;
    var gamepad_pressed: [InputState.max_held_gamepad]?[]const u8 = .{null} ** InputState.max_held_gamepad;
    // Empty slice for non-whitelisted actions: checkAction never sees a
    // synthetic edge for them. (isHeld on a zero-length slice is always false.)
    const no_repeat: [0]?[]const u8 = .{};

    // Accumulate scroll delta across all events this tick
    var scroll_delta: f32 = 0;

    // Whether the mouse moved this tick (set in the mouse_move handler).
    var mouse_moved_this_tick: bool = false;

    // Process each raw event
    for (platform.events) |event| {
        switch (event) {
            .key_down => |key| {
                if (!InputState.isHeld(&state.keys_held, key)) {
                    InputState.addHeld(&keys_pressed, key);
                    // Start synthetic-repeat tracking on the press edge.
                    state.addRepeat(key);
                }
                InputState.addHeld(&state.keys_held, key);
            },
            .key_up => |key| {
                InputState.removeHeld(&state.keys_held, key);
                state.removeRepeat(key);
            },
            .mouse_button_down => |button| {
                if (!InputState.isHeld(&state.mouse_buttons_held, button)) {
                    InputState.addHeld(&mouse_pressed, button);
                }
                InputState.addHeld(&state.mouse_buttons_held, button);
            },
            .mouse_button_up => |button| {
                InputState.addHeld(&mouse_released, button);
                InputState.removeHeld(&state.mouse_buttons_held, button);
            },
            .mouse_move => |position| {
                // Only treat the mouse as having moved when the position
                // actually changed. The raylib backend emits a mouse_move
                // event every frame unconditionally (it always pushes the
                // current position), so without this check the arrow keys
                // could never take over the cursor.
                if (state.mouse_screen_position.x != position.x or
                    state.mouse_screen_position.y != position.y)
                {
                    mouse_moved_this_tick = true;
                }
                state.mouse_screen_position = position;
            },
            .mouse_scroll => |delta| {
                scroll_delta += delta;
            },
            .gamepad_button_down => |gamepad| {
                if (!InputState.isHeld(&state.gamepad_buttons_held, gamepad)) {
                    InputState.addHeld(&gamepad_pressed, gamepad);
                }
                InputState.addHeld(&state.gamepad_buttons_held, gamepad);
            },
            .gamepad_button_up => |gamepad| {
                InputState.removeHeld(&state.gamepad_buttons_held, gamepad);
            },
            .touch_start => |touch| {
                for (&state.active_touches) |*slot| {
                    if (slot.* == null) {
                        slot.* = .{ .id = touch.id, .position = touch.position };
                        break;
                    }
                }
            },
            .touch_move => |touch| {
                for (&state.active_touches) |*slot| {
                    if (slot.*) |*active| {
                        if (active.id == touch.id) {
                            active.position = touch.position;
                            break;
                        }
                    }
                }
            },
            .touch_end => |touch| {
                for (&state.active_touches) |*slot| {
                    if (slot.*) |active| {
                        if (active.id == touch.id) {
                            slot.* = null;
                            break;
                        }
                    }
                }
            },
        }
    }

    const modifiers = getModifiers(state);
    const bindings = settings.input_bindings;
    const zoom = @as(f32, @floatFromInt(settings.camera_zoom)) / 100.0;

    // Advance synthetic key-repeat timers now that all edges for this tick
    // have been processed (new presses start at delay, releases are gone).
    // Fires synthetic edges into `keys_repeated` for held keys that crossed
    // their next-repeat threshold.
    state.advanceKeyRepeats(delta_microseconds, &keys_repeated);

    // Build PlayerInput from triggered actions
    var result = PlayerInput{};

    // Text-field focus (see DESIGN → UI Framework → Text input widget):
    // while a field is focused, ALL binding translation is suppressed
    // (chords too — ctrl+Z included; Escape discards first) and the raw
    // keys + typed characters route into the field buffer instead. Pointer
    // facts, the wheel delta, and the cursor-resolution inputs still flow
    // (press arbitration is M2, at the press-dispatch site in update()).
    if (text_edit) |field| {
        result.text_edit_outcome = ui.routeTextInput(
            field,
            platform.text_characters,
            &keys_pressed,
            &keys_repeated,
            modifiers.shift,
        );
        result.anytime.scroll_delta = scroll_delta;
        result.anytime.in_game.mouse_tile = screenToTile(state.mouse_screen_position, camera, zoom, platform.viewport);
        result.anytime.in_game.mouse_moved_this_tick = mouse_moved_this_tick;
        result.pointer = pointerFacts(state, &mouse_pressed, &mouse_released, modifiers);
        result.modifiers = modifiers;
        return result;
    }

    // Anytime actions. Repeat whitelist: undo, redo, skip, error-scroll.
    // Toggles / dump_event_log / dismiss_error are press-only.
    result.anytime.undo = checkAction(.undo, bindings, &keys_pressed, &keys_repeated, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.redo = checkAction(.redo, bindings, &keys_pressed, &keys_repeated, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.toggle_options_menu = checkAction(.toggle_options_menu, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.dump_event_log = checkAction(.dump_event_log, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.dismiss_error = checkAction(.dismiss_error, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.toggle_editor_mission_browser = checkAction(.toggle_editor_mission_browser, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.error_scroll_up = checkAction(.error_scroll_up, bindings, &keys_pressed, &keys_repeated, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.error_scroll_down = checkAction(.error_scroll_down, bindings, &keys_pressed, &keys_repeated, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.scroll_delta = scroll_delta;
    result.anytime.zoom_in = checkAction(.zoom_in, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.zoom_out = checkAction(.zoom_out, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.zoom_reset = checkAction(.zoom_reset, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);

    // In-game anytime actions. Repeat whitelist: movement cursors only.
    // Toggles / swap_weapons are press-only.
    result.anytime.in_game.toggle_inventory = checkAction(.toggle_inventory, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.toggle_gear = checkAction(.toggle_gear, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.toggle_skills = checkAction(.toggle_skills, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.toggle_world_map = checkAction(.toggle_world_map, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.swap_weapons = checkAction(.swap_weapons, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.move_cursor_up = checkAction(.move_cursor_up, bindings, &keys_pressed, &keys_repeated, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.move_cursor_down = checkAction(.move_cursor_down, bindings, &keys_pressed, &keys_repeated, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.move_cursor_left = checkAction(.move_cursor_left, bindings, &keys_pressed, &keys_repeated, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.move_cursor_right = checkAction(.move_cursor_right, bindings, &keys_pressed, &keys_repeated, &mouse_pressed, &gamepad_pressed, modifiers);
    // Cursor direction from HELD cursor keys (not edges) so a diagonal nudge
    // fires when any one of the two held keys edges/repeats. Opposite keys on
    // one axis cancel.
    var dir_x: i32 = 0;
    var dir_y: i32 = 0;
    if (isActionHeld(.move_cursor_up, bindings, &state.keys_held, &state.mouse_buttons_held, &state.gamepad_buttons_held, modifiers)) dir_y -= 1;
    if (isActionHeld(.move_cursor_down, bindings, &state.keys_held, &state.mouse_buttons_held, &state.gamepad_buttons_held, modifiers)) dir_y += 1;
    if (isActionHeld(.move_cursor_left, bindings, &state.keys_held, &state.mouse_buttons_held, &state.gamepad_buttons_held, modifiers)) dir_x -= 1;
    if (isActionHeld(.move_cursor_right, bindings, &state.keys_held, &state.mouse_buttons_held, &state.gamepad_buttons_held, modifiers)) dir_x += 1;
    result.anytime.in_game.cursor_direction = .{ .x = dir_x, .y = dir_y };

    // Raw mouse-over-tile (unvalidated; the cursor resolution in update()
    // checks it against world tiles + UI occlusion). Plus whether the mouse
    // moved this tick (mouse owns the cursor when it moved; arrows otherwise).
    result.anytime.in_game.mouse_tile = screenToTile(state.mouse_screen_position, camera, zoom, platform.viewport);
    result.anytime.in_game.mouse_moved_this_tick = mouse_moved_this_tick;

    // Idle actions. Repeat whitelist: skip. confirm/cancel are press-only.
    result.idle.confirm = checkAction(.confirm, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.idle.cancel = checkAction(.cancel, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.idle.skip = checkAction(.skip, bindings, &keys_pressed, &keys_repeated, &mouse_pressed, &gamepad_pressed, modifiers);
    result.idle.skip_level = checkAction(.skip_level, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.idle.delete_editor_selection = checkAction(.delete_editor_selection, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.idle.clear_editor_selection = checkAction(.clear_editor_selection, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);
    result.idle.select_editor_all = checkAction(.select_editor_all, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers);

    // Skill slots 1-8 (press-only — repeating would queue uses by accident).
    const skill_slot_actions = [_]types.Action{
        .skill_slot_1, .skill_slot_2, .skill_slot_3, .skill_slot_4,
        .skill_slot_5, .skill_slot_6, .skill_slot_7, .skill_slot_8,
    };
    for (skill_slot_actions, 1..) |action, slot| {
        if (checkAction(action, bindings, &keys_pressed, &no_repeat, &mouse_pressed, &gamepad_pressed, modifiers)) {
            result.idle.skill_slot_selected = @intCast(slot);
            break;
        }
    }

    // Left mouse click → tile_clicked
    if (InputState.isHeld(&mouse_pressed, "left")) {
        result.idle.tile_clicked = screenToTile(state.mouse_screen_position, camera, zoom, platform.viewport);
    }

    // Primary-pointer facts for the UI-resolution step. The pointer is assumed
    // to already be in reference-resolution space (same assumption screenToTile
    // makes); update alongside it if the platform viewport mapping changes.
    result.pointer = pointerFacts(state, &mouse_pressed, &mouse_released, modifiers);

    result.modifiers = modifiers;
    return result;
}

/// Primary-pointer facts shared by the normal + text-field-focused paths
/// of `translateInput` (the focused path returns early, before the action
/// section, but must build the identical pointer state).
fn pointerFacts(
    state: *InputState,
    mouse_pressed: []const ?[]const u8,
    mouse_released: []const ?[]const u8,
    modifiers: Modifiers,
) PointerInput {
    return .{
        .pressed = InputState.isHeld(mouse_pressed, "left"),
        .released = InputState.isHeld(mouse_released, "left"),
        .held = InputState.isHeld(&state.mouse_buttons_held, "left"),
        .position = state.mouse_screen_position.toScreenPosition(),
        .right_pressed = InputState.isHeld(mouse_pressed, "right"),
        .right_released = InputState.isHeld(mouse_released, "right"),
        .right_held = InputState.isHeld(&state.mouse_buttons_held, "right"),
        .modifiers = modifiers,
    };
}

// ============================================================
// Tests — hybrid input precedence (see DESIGN → Input)
// ============================================================
//
// `checkAction` resolves a pressed input by SPECIFICITY: a more-specific
// chord (more required modifiers, all held) on the same key suppresses a
// less-specific binding; equal-specificity ties co-fire (disambiguated by
// handler context, e.g. ArrowUp → move_cursor_up + error_scroll_up).

const empty_mouse: [InputState.max_held_mouse]?[]const u8 = .{null} ** InputState.max_held_mouse;
const empty_gamepad: [InputState.max_held_gamepad]?[]const u8 = .{null} ** InputState.max_held_gamepad;
const no_repeat_keys: [0]?[]const u8 = .{};
const no_keys: [0]?[]const u8 = .{};

test "translateInput: focused text field suppresses bindings, routes keys + chars" {
    // Enter is bound to confirm, Escape to the options menu. While a field
    // is focused those keys must resolve the FIELD (commit / discard) and
    // no binding may fire — the M2 suppression rule (DESIGN → UI Framework
    // → Text input widget).
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Escape" }, .action = .toggle_options_menu },
    };
    const settings: Settings = .{ .input_bindings = &bindings };
    const camera: Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const platform = PlatformInput{
        .events = &.{.{ .key_down = "Enter" }},
        .viewport = .{ .width = 2560, .height = 2160 },
        .text_characters = " Pup",
    };

    // Control (unfocused): Enter fires its binding.
    {
        var input_state: InputState = .{};
        const result = translateInput(platform, &input_state, settings, camera, 0, null);
        try std.testing.expect(result.idle.confirm);
        try std.testing.expectEqual(types.TextEditOutcome.none, result.text_edit_outcome);
    }

    // Focused: the typed characters insert into the buffer, Enter resolves
    // to commit, and both bindings are suppressed.
    {
        var ui_state: ui.UiState = .{};
        ui.beginTextEdit(&ui_state, .{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } }, "Wolf");
        var input_state: InputState = .{};
        const result = translateInput(
            platform,
            &input_state,
            settings,
            camera,
            0,
            &ui_state.text_edit.?,
        );
        try std.testing.expectEqual(types.TextEditOutcome.commit, result.text_edit_outcome);
        try std.testing.expect(!result.idle.confirm);
        try std.testing.expect(!result.anytime.toggle_options_menu);
        try std.testing.expectEqualStrings("Wolf Pup", ui_state.text_edit.?.buffer.currentText());
    }
}

fn keysPressedOne(comptime id: []const u8) [InputState.max_held_keys]?[]const u8 {
    var arr: [InputState.max_held_keys]?[]const u8 = .{null} ** InputState.max_held_keys;
    arr[0] = id;
    return arr;
}

test "checkAction: more-specific chord suppresses plain binding on same key" {
    // Enter → confirm (plain); Enter+ctrl → dump_event_log (ctrl).
    // Pressing ctrl+Enter fires dump_event_log only.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Enter" }, .modifiers = .{ .ctrl = true }, .action = .dump_event_log },
    };
    const pressed = keysPressedOne("Enter");
    const mods = Modifiers{ .ctrl = true };
    try std.testing.expect(checkAction(.dump_event_log, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
    try std.testing.expect(!checkAction(.confirm, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
}

test "checkAction: plain press (no chord modifiers) fires plain binding only" {
    // Same bindings, but ctrl NOT held. The ctrl binding's requirement isn't
    // met, so only the plain confirm fires.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Enter" }, .modifiers = .{ .ctrl = true }, .action = .dump_event_log },
    };
    const pressed = keysPressedOne("Enter");
    const mods = Modifiers{};
    try std.testing.expect(checkAction(.confirm, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
    try std.testing.expect(!checkAction(.dump_event_log, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
}

test "checkAction: equal-specificity ties co-fire (no suppression)" {
    // ArrowUp → move_cursor_up + error_scroll_up (both plain). Both win —
    // disambiguation is by handler context, not here. This is the shipped
    // ArrowUp/ArrowDown pattern; the hybrid model must not collapse it.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "ArrowUp" }, .action = .move_cursor_up },
        .{ .input = .{ .key = "ArrowUp" }, .action = .error_scroll_up },
    };
    const pressed = keysPressedOne("ArrowUp");
    const mods = Modifiers{};
    try std.testing.expect(checkAction(.move_cursor_up, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
    try std.testing.expect(checkAction(.error_scroll_up, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
}

test "checkAction: a chord requiring an un-held modifier does not suppress" {
    // Enter → confirm (plain); Enter+shift → dump_event_log (shift). Pressing
    // Enter with ctrl held (not shift): the shift binding doesn't match the
    // held modifiers, so it is NOT a competitor — confirm still fires.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Enter" }, .modifiers = .{ .shift = true }, .action = .dump_event_log },
    };
    const pressed = keysPressedOne("Enter");
    const mods = Modifiers{ .ctrl = true };
    try std.testing.expect(checkAction(.confirm, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
    try std.testing.expect(!checkAction(.dump_event_log, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
}

test "checkAction: most specific among three wins" {
    // Enter → confirm (plain, spec0), Enter+ctrl → skip (ctrl, spec1),
    // Enter+ctrl+shift → dump_event_log (ctrl+shift, spec2).
    // ctrl+shift+Enter fires dump_event_log only.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Enter" }, .modifiers = .{ .ctrl = true }, .action = .skip },
        .{ .input = .{ .key = "Enter" }, .modifiers = .{ .ctrl = true, .shift = true }, .action = .dump_event_log },
    };
    const pressed = keysPressedOne("Enter");
    const mods = Modifiers{ .ctrl = true, .shift = true };
    try std.testing.expect(checkAction(.dump_event_log, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
    try std.testing.expect(!checkAction(.skip, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
    try std.testing.expect(!checkAction(.confirm, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods));
}
