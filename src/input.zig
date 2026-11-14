//! Input pipeline. Translates raw platform input (keyboard, mouse, touch)
//! into `PlayerInput` (anytime actions, idle game actions, pointer/drag
//! state) against the keybindings in `data/default_settings.txt`. Owns the camera
//! transforms: `screenToTile` (reference-space inverse) and `floatWorldPoint`
//! (float inverse, for camera pan). `tile_size_pixels` (256) is the
//! shared gameplay↔screen scale. The pointer lives in `PointerPosition`
//! (f32, reference space); the UI layout grid is `types.ScreenPosition`
//! (i32) - cross via `PointerPosition.toScreenPosition`.

const std = @import("std");
const types = @import("types.zig");
const ui = @import("ui.zig");

const Vector2 = types.Vector2;
const ScreenPosition = types.ScreenPosition;
const SkillId = types.SkillId;
pub const Modifiers = types.Modifiers;
const InputBinding = types.InputBinding;
const RawInput = types.RawInput;
const Settings = types.Settings;
const Camera = types.Camera;

// ============================================================
// Platform layer types - raw input from JS/native
// ============================================================

/// Pointer position in reference space (window pixels mapped through the
/// render letterbox inverse). Floats because the letterbox scale maps window
/// pixels to reference space non-1:1, so the pointer legitimately lands
/// between reference pixels - `screenToTile` needs that sub-pixel precision
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
    /// queue - distinct from key edges; a held key's repeat arrives as a
    /// key edge, IME-composed text arrives here). Only consumed while a
    /// text field is focused; the backend drains the queue unconditionally
    /// so it can't back up. See DESIGN → UI Framework → Text input widget.
    text_characters: []const u8 = &.{},
    /// Semantic actions injected by the platform layer itself (the console
    /// input channel's `action` command - see DESIGN → Input → Console
    /// input): folded into the frame's PlayerInput via `applyAction` right
    /// after `translateInput`, the same seam button clicks use. Empty for
    /// every hardware frame; only the console merge fills it.
    actions: []const types.Action = &.{},
};

// ============================================================
// Input state - persistent across ticks, updated by translateInput
// ============================================================

/// Tracks which keys/buttons are currently held and pointer positions.
/// Lives on SessionState - never snapshotted, never reconstructed by
/// replay (held-key state must stay off the undo timeline; see DESIGN →
/// Replay & Side Effects).
pub const InputState = struct {
    keys_held: [max_held_keys]?[]const u8 = @splat(null),
    mouse_buttons_held: [max_held_mouse]?[]const u8 = @splat(null),
    gamepad_buttons_held: [max_held_gamepad]?[]const u8 = @splat(null),
    mouse_screen_position: PointerPosition = .{ .x = 0, .y = 0 },
    active_touches: [max_touch_points]?ActiveTouch = @splat(null),
    /// Per-key hold timer for synthetic key repeat (see DESIGN → Input).
    /// Parallel to `keys_held`: an entry is created on a key_down edge and
    /// removed on key_up. Advanced by `advanceKeyRepeats` each tick; when a
    /// held key crosses its next-repeat threshold it fires a synthetic edge
    /// into `keys_repeated` for `checkAction` to consult. Only actions in the
    /// repeat whitelist (movement cursors, undo/redo, skip, error-scroll)
    /// pass `keys_repeated` to `checkAction`, so non-whitelisted bindings
    /// (skill slots, toggles, confirm/cancel) never repeat.
    key_repeat_state: [max_held_keys]?KeyRepeatEntry = @splat(null),

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
    /// not a burst - real-time input does not accumulate).
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
// Player input - semantic actions for the game logic
// ============================================================

pub const PlayerInput = struct {
    anytime: AnytimeInput = .{},
    idle: IdleInput = .{},
    pointer: PointerInput = .{},
    /// Current modifier-key state at input translation time. Read by the
    /// idle-input path for per-action overrides (e.g. ctrl held at click-time
    /// forces the attack step even with auto_skip enabled). Not a binding -
    /// bindings filter on modifiers in checkAction; this is the raw held state.
    modifiers: Modifiers = .{},
    /// The clicked button's identity beyond its action (which row, which
    /// tab, which cell), set by the button-release dispatch in main.zig
    /// (and by `applyAction`'s keyboard bridges - the payload is the
    /// keyboard action's own identity there). Valid only in the same frame
    /// as the click. Inert data - it never fires anything by itself, which
    /// is why it rides `PlayerInput` directly rather than the anytime/idle
    /// sub-structs: those classify actions by when they may consume, and
    /// data doesn't consume. Read by the handler arm that fired the
    /// action. See `types.ButtonPayload` + DESIGN → Input → Button
    /// payloads.
    clicked_payload: ?types.ButtonPayload = null,
    /// Text-field keyboard resolution for this frame (Enter/Escape while a
    /// field is focused - see DESIGN → UI Framework → Text input widget).
    /// Resolved ONCE per frame by the caller (main), never per update()
    /// drain iteration. `.none` when no field is focused.
    text_edit_outcome: types.TextEditOutcome = .none,
    /// One frame's keybind-listening outcome (the capture seam - the
    /// text-edit-outcome model). Set only while a keybind edit is active;
    /// resolved once per frame in `main.frame`.
    keybind_capture_outcome: types.KeybindCaptureOutcome = .none,
    /// Every action that FIRED this frame (a set - a same-frame keybind +
    /// button + console command on one action dedupes to one entry).
    /// Recorded by `applyAction` itself, so all three input seams report
    /// uniformly. The per-action dispatch choke point: the action-layer
    /// sound (input_handlers.dispatchFiredActionSounds) and future
    /// per-action policy/analytics read THIS, not the per-flag consumption
    /// sites. See DESIGN → Input → Dispatch convergence.
    fired_actions: std.EnumSet(types.Action) = .empty,
};

/// Synthetic key-repeat cadence (see `InputState.KeyRepeatEntry`). A held
/// key fires its first repeat after this delay, then repeats at this
/// interval. Owns the cadence so players cannot gain a real-time advantage
/// by twiddling OS key-repeat settings. Tuned from in-game feel.
const key_repeat_initial_delay_microseconds: u64 = 300 * std.time.us_per_ms;
const key_repeat_interval_microseconds: u64 = 40 * std.time.us_per_ms;

/// Raw primary-pointer facts for the UI-resolution step (hit-testing, drag
/// lifecycle). Deliberately semantic-free: main.zig decides what a press/
/// release over a given position means. Position is the full-precision
/// reference-space `PointerPosition` (f32): UI hit-testing truncates via
/// `toScreenPosition()` at the seam (the layout grid is i32); world/tile
/// resolution (camera pan, screenToTile) uses the float directly.
pub const PointerInput = struct {
    pressed: bool = false, // primary button went down this tick
    released: bool = false, // primary button went up this tick
    held: bool = false, // primary button is held (for slider drag)
    position: PointerPosition = .{ .x = 0, .y = 0 },
    /// Secondary (right) button edges + held state, for the camera-pan drag.
    /// Not a binding - like the tile cursor, this is raw pointer state
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
    /// Escape - drives the overlay-close chain in handleAnytimeInput (see
    /// Action.escape + DESIGN → Input → Escape overlay chain).
    escape: bool = false,
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
    // Keyboard zoom shortcuts (PgUp / PgDn / ctrl+0). Press-only - the
    // mouse wheel (scroll_delta) is the continuous path. See Action.zoom_*.
    zoom_in: bool = false,
    zoom_out: bool = false,
    zoom_reset: bool = false,
    /// A button action from an overlay surface (the options menu's own
    /// buttons, plus every fullscreen overlay's interactions: the editor
    /// browser rows, the campaign browser, the world map's travel/mission
    /// buttons, the load-save browser's rows/Back/Import, settings, tips).
    /// Dispatched in handleAnytimeInput before the overlay pause gate, so
    /// the action takes effect immediately even though an open overlay
    /// pauses the game. Null when no overlay button was clicked this tick.
    options_action: ?types.Action = null,
    /// Open/close the editor browser (the main-menu Editor button, the
    /// options-menu Open Mission button, the browser's Back button, and
    /// the ctrl+O binding). The consumption site accepts the editor +
    /// main-menu screens; the keybind ships editor-context, so on the
    /// main menu only the button path can set this.
    toggle_editor_browser: bool = false,
    /// Import a mission .zip (the mission browser's Import button + the
    /// ctrl+I binding). Web-only effect at the consumption site (the
    /// upload trigger is comptime-dead on native - the skip_level
    /// discipline); consumed only while the browser is open.
    import_editor_mission: bool = false,
    /// The fresh-mission open (the editor browser's New Mission button,
    /// the options-menu New Mission button, and the ctrl+N binding):
    /// pushes `open_editor` with a null path. The consumption site accepts
    /// the editor + main-menu screens (the toggle_editor_browser
    /// discipline).
    new_editor_mission: bool = false,
    /// The fresh-campaign open (the editor browser's Campaign tab's New
    /// Campaign button): pushes `open_campaign_editor` with a null dir.
    /// Same reachable-screen discipline as the mission New.
    new_editor_campaign: bool = false,
    /// The campaign save (ctrl+S + the menu's Save Campaign). The
    /// campaign editor screen only (the consumption site gates; the
    /// mission's ctrl+S no-ops there and vice versa).
    save_campaign: bool = false,

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
    /// Direction of THIS tick's REAL press edges only (synthetic repeats
    /// excluded; -1/0/+1 per axis, summed like cursor_direction). The
    /// cursor resolution uses it as the fallback when the held vector
    /// cancels to zero - a press landing while its opposite is still held
    /// (key rollover at fast input speeds) is fresh intent and must nudge
    /// in its own direction, while repeats during a deliberately-held
    /// opposite pair keep the frozen cancel.
    cursor_press_direction: Vector2 = .{ .x = 0, .y = 0 },
};

/// Actions that are only handled when the event stack is empty
/// (i.e. the game is waiting for player input).
pub const IdleInput = struct {
    tile_clicked: ?Vector2 = null,
    /// The raw reference-screen position of an unconsumed left click - the
    /// campaign editor's map surface (the hub tool's placement): resolved
    /// against the framing + pan at the consumption site. Nulled by the
    /// press-resolution sites exactly like `tile_clicked` (a click that
    /// hit UI never reaches the map). Other screens never read it.
    map_clicked: ?ScreenPosition = null,
    skill_slot_selected: ?u8 = null, // 1-8, game logic resolves to SkillId
    confirm: bool = false,
    cancel: bool = false,
    skip: bool = false,
    // Dev tool: skip the current level. Press-only. Gated to dev builds +
    // level screen at the handler site; the binding ships in
    // default_settings.txt and no-ops elsewhere. See DESIGN → Input.
    skip_level: bool = false,
    // Editor select tool: delete the current selection (Delete key,
    // press-only). Consumed in handleIdleInput's editor arm - a no-op on
    // every other screen. See DESIGN → Architecture → Level Editor →
    // Selection model.
    delete_editor_selection: bool = false,
    // Editor select tool: clear the current selection (ctrl+D, press-only).
    // Same consumption + no-op discipline as `delete_editor_selection`.
    clear_editor_selection: bool = false,
    // Editor select tool: select everything in the active level (ctrl+A,
    // press-only). Same consumption + no-op discipline as
    // `delete_editor_selection` (plus a select-tool gate - every
    // selection op requires the select tool).
    select_editor_all: bool = false,
    /// A main-menu command (New Game / Continue / Import Game / the repo
    /// link - the buttons that live on the main menu itself, never under an
    /// overlay). Set when a menu button is clicked (no default keybind).
    /// Handled by the main_menu branch of handleIdleInput. The load-save
    /// browser's own interactions ride `anytime.options_action` instead -
    /// they must dispatch while the browser (an overlay) pauses the game.
    menu_action: ?types.Action = null,
};

/// THE action→PlayerInput mapping - the one dispatch seam. All three input
/// paths fold through it: UI button releases (main.zig), fired keybinds
/// (translateInput's one dispatch pass), and console `action` commands. A
/// binding and its button land on the exact same fields, and every action is
/// uniformly keybindable (the keybinds tab's action picker lists the whole
/// enum; the derived binding-context gate keeps each action to its screens).
/// Main-menu commands (no default keybind) go to idle.menu_action; the
/// load-save browser's interactions go to anytime.options_action (they must
/// dispatch while the browser overlay pauses the game).
pub fn applyAction(player_input: *PlayerInput, action: types.Action) void {
    // The fired-actions record: the one choke point for per-action behavior
    // (the action-layer sound now; analytics/policy later). A set - a
    // same-frame keybind + button + console command on one action records
    // once.
    player_input.fired_actions.insert(action);
    switch (action) {
        .undo => player_input.anytime.undo = true,
        .redo => player_input.anytime.redo = true,
        .escape => player_input.anytime.escape = true,
        .dump_event_log => player_input.anytime.dump_event_log = true,
        .save_editor_mission => player_input.anytime.save_editor_mission = true,
        .export_editor_mission => player_input.anytime.export_editor_mission = true,
        .dismiss_error => player_input.anytime.dismiss_error = true,
        .error_scroll_up => player_input.anytime.error_scroll_up = true,
        .error_scroll_down => player_input.anytime.error_scroll_down = true,
        .zoom_in => player_input.anytime.zoom_in = true,
        .zoom_out => player_input.anytime.zoom_out = true,
        .zoom_reset => player_input.anytime.zoom_reset = true,
        .save_game, .export_game => player_input.anytime.options_action = action,
        .restart_mission, .exit_mission, .exit_to_menu => player_input.anytime.options_action = action,
        .continue_after_mission, .replay_mission, .overwrite_clone, .overwrite_validation_replay => player_input.anytime.options_action = action,
        // Settings is reachable from both the main-menu button and the
        // options-menu button; routing through `options_action` lets one
        // handler (in `handleAnytimeInput`) serve both contexts - the
        // options_action switch runs regardless of screen. See DESIGN → UI
        // Framework → Settings screen.
        .open_settings => player_input.anytime.options_action = action,
        // Credits + Exit Game live in the MAIN-MENU options menu variant;
        // they must route through the anytime path too (idle input is
        // gated while the options menu is open).
        .open_credits,
        .exit_game,
        => player_input.anytime.options_action = action,
        // The tips button lives in the global top bar (always drawn, so
        // clickable even while the options menu is open); cycling fires
        // from the tips panel, which overlays any screen. Both route
        // through the anytime path's one options_action handler.
        .open_tips,
        .cycle_tips,
        => player_input.anytime.options_action = action,
        // The campaign browser fires from the world map (its top-left
        // campaign button) - an overlay context, so the anytime path's
        // one options_action handler serves it (the open_tips routing).
        .toggle_campaign_browser,
        .select_campaign_browser_tab,
        .view_campaign_row,
        .travel_to_map_hub,
        .start_mission_from_map_edge,
        => player_input.anytime.options_action = action,
        .change_setting => player_input.anytime.options_action = action,
        .select_settings_tab => player_input.anytime.options_action = action,
        .edit_keybind => player_input.anytime.options_action = action,
        .toggle_editor_palette_group => player_input.anytime.options_action = action,
        .add_editor_palette_type => player_input.anytime.options_action = action,
        .delete_editor_palette_type => player_input.anytime.options_action = action,
        .add_editor_level => player_input.anytime.options_action = action,
        .delete_editor_level => player_input.anytime.options_action = action,
        .select_editor_tool => player_input.anytime.options_action = action,
        .select_editor_campaign_tool,
        .select_editor_campaign_hub,
        .set_editor_campaign_start_hub,
        .open_campaign_background_picker,
        .select_editor_campaign_background,
        .close_campaign_picker,
        .toggle_campaign_inspector,
        .toggle_campaign_metadata_sidebar,
        .select_editor_campaign_mission,
        .reattach_campaign_mission_start,
        .reattach_campaign_mission_destination,
        .open_campaign_import_picker,
        .select_editor_campaign_import,
        => player_input.anytime.options_action = action,
        .select_editor_level => player_input.anytime.options_action = action,
        .toggle_editor_inspector => player_input.anytime.options_action = action,
        .toggle_editor_metadata_sidebar => player_input.anytime.options_action = action,
        .test_editor_level => player_input.anytime.options_action = action,
        .validate_editor_mission => player_input.anytime.options_action = action,
        .revalidate_editor_mission => player_input.anytime.options_action = action,
        .toggle_editor_inspector_section => player_input.anytime.options_action = action,
        .open_editor_sprite_picker => player_input.anytime.options_action = action,
        .select_editor_entity_sprite => player_input.anytime.options_action = action,
        .select_editor_decoration_sprite => player_input.anytime.options_action = action,
        .select_editor_sprite_tab => player_input.anytime.options_action = action,
        .import_editor_player => player_input.anytime.options_action = action,
        .import_editor_max_player => player_input.anytime.options_action = action,
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
        .toggle_editor_entity_keep_original_colors => player_input.anytime.options_action = action,
        .toggle_editor_decoration_keep_original_colors => player_input.anytime.options_action = action,
        .toggle_editor_decoration_layer_behind => player_input.anytime.options_action = action,
        .select_editor_weapon_type => player_input.anytime.options_action = action,
        .select_editor_item_type => player_input.anytime.options_action = action,
        .select_editor_inventory_slot => player_input.anytime.options_action = action,
        .add_editor_inventory_item => player_input.anytime.options_action = action,
        .delete_editor_inventory_item => player_input.anytime.options_action = action,
        .select_editor_inventory_item_type => player_input.anytime.options_action = action,
        .add_editor_item => player_input.anytime.options_action = action,
        .delete_editor_item => player_input.anytime.options_action = action,
        .open_editor_skill_picker => player_input.anytime.options_action = action,
        .select_editor_kind_tab,
        .select_editor_mission_tab,
        .open_editor_mission_row,
        .select_editor_campaign_tab,
        .open_editor_campaign_row,
        => player_input.anytime.options_action = action,
        .close_editor_picker => player_input.anytime.options_action = action,
        .toggle_editor_browser => player_input.anytime.toggle_editor_browser = true,
        .import_editor_mission => player_input.anytime.import_editor_mission = true,
        .new_editor_mission => player_input.anytime.new_editor_mission = true,
        .new_editor_campaign => player_input.anytime.new_editor_campaign = true,
        .save_campaign => player_input.anytime.save_campaign = true,
        // Keyboard-only editor shortcuts - no button carries these (the
        // palette cells use the payload-carrying click actions). The
        // keybind→click-action BRIDGE lives here: the keyboard action folds
        // onto the click paths' options_action + payload pair so keybind and
        // click share the consumption sites exactly, and the console `action`
        // commands get the same bridge (the console mirrors the keybind
        // path). The payload is the keyboard action's own identity - no
        // runtime payload to ride along. A same-frame keypress + button
        // release on the same action is degenerate (the button's payload
        // lands last, at main.zig's release dispatch, and wins).
        .campaign_select_tool => {
            player_input.anytime.options_action = .select_editor_campaign_tool;
            player_input.clicked_payload = .{ .editor_campaign_tool = .select };
        },
        .campaign_hub_tool => {
            player_input.anytime.options_action = .select_editor_campaign_tool;
            player_input.clicked_payload = .{ .editor_campaign_tool = .hub };
        },
        .campaign_mission_tool => {
            player_input.anytime.options_action = .select_editor_campaign_tool;
            player_input.clicked_payload = .{ .editor_campaign_tool = .mission };
        },
        .editor_select_tool => {
            player_input.anytime.options_action = .select_editor_tool;
            player_input.clicked_payload = .{ .editor_tool = .select };
        },
        .editor_tile_tool => {
            player_input.anytime.options_action = .select_editor_tool;
            player_input.clicked_payload = .{ .editor_tool = .tile };
        },
        .toggle_editor_entity_group => {
            player_input.anytime.options_action = .toggle_editor_palette_group;
            player_input.clicked_payload = .{ .editor_group = 0 };
        },
        .toggle_editor_decoration_group => {
            player_input.anytime.options_action = .toggle_editor_palette_group;
            player_input.clicked_payload = .{ .editor_group = 1 };
        },
        .toggle_editor_item_group => {
            player_input.anytime.options_action = .toggle_editor_palette_group;
            player_input.clicked_payload = .{ .editor_group = 2 };
        },
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
        // The load-save browser's interactions (rows / Back / Import) ride
        // the anytime options_action umbrella: the browser is a fullscreen
        // overlay that pauses update(), so its dispatch must run pre-gate
        // (the editor-browser discipline).
        .toggle_load_save_menu,
        .load_save_row,
        .import_save,
        => player_input.anytime.options_action = action,
        .continue_game,
        .new_game,
        // Import Game (web only, the main-menu button - a pure input-path
        // side effect consumed in the main-menu idle arm).
        .import_game,
        // The upstream-repo link (main-menu button - same class: consumed
        // in the main-menu idle arm, browser_url.openRepoLink).
        .open_repo_link,
        => player_input.idle.menu_action = action,
    }
}

// ============================================================
// Input translation - raw platform events → semantic PlayerInput
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

/// The float world position (tile units) under a screen position - the
/// inverse of the camera transform, before `@floor`. Used by the camera-pan
/// anchor so the grabbed point tracks the cursor with the pointer's full
/// sub-pixel precision. Kept beside screenToTile so the two halves of the
/// camera<->screen mapping stay in sync.
pub fn floatWorldPoint(
    screen_position: PointerPosition,
    camera: Camera,
    zoom: f32,
    viewport: ViewportSize,
) struct { x: f32, y: f32 } {
    const tile_pixels = tile_size_pixels * zoom;
    return .{
        .x = (@as(f32, @floatFromInt(camera.position.x)) +
            (screen_position.x - viewport.width / 2.0)) / tile_pixels,
        .y = (@as(f32, @floatFromInt(camera.position.y)) +
            (screen_position.y - viewport.height / 2.0)) / tile_pixels,
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

/// Count a binding's required modifiers - its specificity for precedence
/// (see DESIGN → Input). A plain binding has specificity 0; ctrl+shift has 2.
fn modifierSpecificity(modifiers: Modifiers) u8 {
    var count: u8 = 0;
    if (modifiers.ctrl) count += 1;
    if (modifiers.shift) count += 1;
    if (modifiers.alt) count += 1;
    return count;
}

/// Hybrid precedence: `binding` (already matching the held modifiers + a
/// pressed input) is suppressed if another binding on the SAME input -
/// with derived contexts (`actionBindingContexts(other.action)`)
/// intersecting the frame's ACTIVE set - EITHER matches the held modifiers
/// with strictly MORE required modifiers (a more-specific chord wins, a
/// plain binding gives way to it), OR matches with EQUAL specificity but
/// is a DIFFERENT action appearing EARLIER in the binding list (one combo
/// fires one action per context; first-listed wins - the deterministic
/// fallback, reachable only via a hand-edited file since `loadSettings`
/// warns + drops conflicts and the keybind UI prevents them). The same
/// action earlier never suppresses (both entries fire the same flag).
/// Only active bindings compete: a binding whose derived contexts are
/// inactive this frame never suppresses or is suppressed. See DESIGN →
/// Input → Hybrid precedence + binding conflicts.
fn isSuppressed(
    binding: InputBinding,
    binding_index: usize,
    bindings: []const InputBinding,
    modifiers: Modifiers,
    active_contexts: types.BindingContextSet,
) bool {
    const my_specificity = modifierSpecificity(binding.modifiers);
    for (bindings, 0..) |other, other_index| {
        if (!actionContextsActive(other.action, active_contexts)) continue;
        if (!types.rawInputsEqual(other.input, binding.input)) continue;
        // The competitor must also match the held modifiers to win.
        if (other.modifiers.ctrl and !modifiers.ctrl) continue;
        if (other.modifiers.shift and !modifiers.shift) continue;
        if (other.modifiers.alt and !modifiers.alt) continue;
        if (modifierSpecificity(other.modifiers) > my_specificity) return true;
        if (other_index < binding_index and
            modifierSpecificity(other.modifiers) == my_specificity and
            other.action != binding.action) return true;
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
    active_contexts: types.BindingContextSet,
) bool {
    for (bindings, 0..) |binding, binding_index| {
        if (binding.action != action) continue;
        if (!actionContextsActive(action, active_contexts)) continue;
        if (binding.modifiers.ctrl and !modifiers.ctrl) continue;
        if (binding.modifiers.shift and !modifiers.shift) continue;
        if (binding.modifiers.alt and !modifiers.alt) continue;
        const held = switch (binding.input) {
            .key => |key| InputState.isHeld(keys_held, key),
            .mouse_button => |button| InputState.isHeld(mouse_buttons_held, button),
            .gamepad_button => |gamepad| InputState.isHeld(gamepad_buttons_held, gamepad),
        };
        if (held) {
            if (isSuppressed(binding, binding_index, bindings, modifiers, active_contexts)) continue;
            return true;
        }
    }
    return false;
}

/// Whether `action` fired on a REAL press edge this tick (synthetic repeats
/// excluded) - the press-intent companion to `isActionHeld` (see
/// `InGameInput.cursor_press_direction`). Implemented as `bindingFires`
/// with an empty repeat set, so every gate (derived contexts, required
/// modifiers, hybrid precedence) is identical to the dispatch pass's.
fn actionPressedOnRealEdge(
    action: types.Action,
    bindings: []const InputBinding,
    keys_pressed: []const ?[]const u8,
    mouse_pressed: []const ?[]const u8,
    gamepad_pressed: []const ?[]const u8,
    modifiers: Modifiers,
    active_contexts: types.BindingContextSet,
) bool {
    for (bindings, 0..) |binding, binding_index| {
        if (binding.action != action) continue;
        if (bindingFires(
            binding,
            binding_index,
            bindings,
            keys_pressed,
            &no_repeat_keys,
            mouse_pressed,
            gamepad_pressed,
            modifiers,
            active_contexts,
        )) return true;
    }
    return false;
}

/// Whether `action`'s bindings may fire on synthetic key-repeat edges (see
/// `InputState.advanceKeyRepeats`): the repeated-firing whitelist -
/// undo/redo, skip, error-scroll, and the movement cursors. Everything else
/// is press-only (a toggle firing every repeat interval of a held key would
/// flip panels on repeat).
fn actionRepeats(action: types.Action) bool {
    return switch (action) {
        .undo,
        .redo,
        .skip,
        .error_scroll_up,
        .error_scroll_down,
        .move_cursor_up,
        .move_cursor_down,
        .move_cursor_left,
        .move_cursor_right,
        => true,
        else => false,
    };
}

/// Whether `binding` fires this tick - the per-binding gate of
/// translateInput's ONE dispatch pass (the loop inverted from the old
/// per-action queries: the fired set is defined by the bindings, so iterate
/// bindings, not actions - actions with no binding are never touched).
/// Gates in order: the action's derived binding contexts must intersect the
/// frame's active set; the binding's required modifiers must be held; the
/// bound input must have a real press edge (or a synthetic repeat edge,
/// whitelist-permitting via `actionRepeats`); and no more-specific or earlier
/// same-combo binding suppresses it (hybrid precedence - see DESIGN →
/// Input).
fn bindingFires(
    binding: InputBinding,
    binding_index: usize,
    bindings: []const InputBinding,
    keys_pressed: []const ?[]const u8,
    keys_repeated: []const ?[]const u8,
    mouse_pressed: []const ?[]const u8,
    gamepad_pressed: []const ?[]const u8,
    modifiers: Modifiers,
    active_contexts: types.BindingContextSet,
) bool {
    // Derived binding-context gate (see DESIGN → Input → Binding
    // contexts): a binding is active iff its action's contexts
    // (`actionBindingContexts`) intersect the frame's active set -
    // same-combo cross-context pairs (Digit1 = skill 1 in game /
    // select tool in editor) never co-fire; the active set + the
    // derived contexts are the single disambiguator.
    if (!actionContextsActive(binding.action, active_contexts)) return false;

    // A binding's modifiers are REQUIREMENTS, not an exact match: a plain
    // binding fires regardless of held modifiers (so ctrl+key works for
    // any plain-bound action, e.g. ctrl+Space skip with force-attack);
    // a ctrl binding fires only when ctrl is held. Fail only when a
    // REQUIRED modifier is not held.
    if (binding.modifiers.ctrl and !modifiers.ctrl) return false;
    if (binding.modifiers.shift and !modifiers.shift) return false;
    if (binding.modifiers.alt and !modifiers.alt) return false;

    // The bound input was just pressed (real edge) or repeated (synthetic
    // edge for held keys, whitelist-permitting).
    const pressed = switch (binding.input) {
        .key => |key| InputState.isHeld(keys_pressed, key) or
            (actionRepeats(binding.action) and InputState.isHeld(keys_repeated, key)),
        .mouse_button => |button| InputState.isHeld(mouse_pressed, button),
        .gamepad_button => |gamepad| InputState.isHeld(gamepad_pressed, gamepad),
    };
    if (!pressed) return false;

    // Hybrid precedence - see DESIGN → Input. A more-specific chord
    // on the same input suppresses this binding; an equal-
    // specificity different-action conflict is won by the earlier
    // list entry (first-match-wins - see isSuppressed).
    if (isSuppressed(binding, binding_index, bindings, modifiers, active_contexts)) return false;
    return true;
}

/// Derived binding-context gate: `action`'s binding is active this frame
/// iff `actionBindingContexts(action)` intersects the frame's active
/// contexts (see DESIGN → Input → Binding contexts).
fn actionContextsActive(action: types.Action, active_contexts: types.BindingContextSet) bool {
    return types.actionBindingContexts(action).intersects(active_contexts);
}

/// Process raw platform input events, update InputState, and produce
/// a PlayerInput with semantic actions for the game logic.
/// `active_contexts` is which BindingContexts are live this frame (the
/// caller computes it from the screen + pending_error - see main.zig's
/// frame); bindings in inactive contexts never fire. Button clicks bypass
/// this gate entirely (`applyAction`), since buttons only render in their
/// context.
pub fn translateInput(
    platform: PlatformInput,
    state: *InputState,
    settings: Settings,
    camera: Camera,
    delta_microseconds: u64,
    text_edit: ?*ui.TextEditState,
    /// The active keybind edit, if any (the Keybinds tab's listening /
    /// picker / pending state). While set, ALL binding translation is
    /// suppressed (the text-edit model) and the raw key/mouse presses
    /// route into the edit instead (`ui.routeKeybindCapture`). Escape
    /// cancels at every phase.
    keybind_edit: ?*ui.KeybindEditState,
    active_contexts: types.BindingContextSet,
) PlayerInput {
    // Track which inputs were just pressed this tick (edge detection)
    var keys_pressed: [InputState.max_held_keys]?[]const u8 = @splat(null);
    var keys_repeated: [InputState.max_held_keys]?[]const u8 = @splat(null);
    var mouse_pressed: [InputState.max_held_mouse]?[]const u8 = @splat(null);
    var mouse_released: [InputState.max_held_mouse]?[]const u8 = @splat(null);
    var gamepad_pressed: [InputState.max_held_gamepad]?[]const u8 = @splat(null);

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
    // (chords too - ctrl+Z included; Escape discards first) and the raw
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

    // Keybind edit active (the Keybinds tab's listening / picker / pending
    // state - the same suppression model as the text-field focus above):
    // ALL binding translation is suppressed and the raw presses route into
    // the edit (capture during listening; Escape cancels at every phase).
    // Pointer facts + the wheel flow (Confirm/Cancel/tab buttons are
    // clicks - the `applyAction` path, not bindings).
    if (keybind_edit) |edit_state| {
        result.keybind_capture_outcome = ui.routeKeybindCapture(
            edit_state,
            &keys_pressed,
            &mouse_pressed,
            modifiers,
        );
        result.anytime.scroll_delta = scroll_delta;
        result.pointer = pointerFacts(state, &mouse_pressed, &mouse_released, modifiers);
        result.modifiers = modifiers;
        return result;
    }

    // The ONE dispatch pass: every binding that passes its gates fires its
    // action through `applyAction` - the same seam UI button releases
    // (main.zig) and console `action` commands fold through, so a binding
    // and its button land on the exact same fields, and every action is
    // uniformly keybindable (the keybinds tab's action picker lists the
    // whole enum - a binding on ANY action, main-menu commands and click
    // actions included, is live; the derived binding-context gate keeps
    // each to its screens). Same-frame degeneracies resolve
    // first-listed-wins (the conflict rule's tiebreak): equal-specificity
    // same-combo competitors are suppressed inside the pass, and the
    // skill-slot guard below keeps one slot selection. Non-action input
    // facts (scroll delta, held-cursor direction, raw pointer/tile) are
    // assigned below the pass.
    for (bindings, 0..) |binding, binding_index| {
        if (!bindingFires(
            binding,
            binding_index,
            bindings,
            &keys_pressed,
            &keys_repeated,
            &mouse_pressed,
            &gamepad_pressed,
            modifiers,
            active_contexts,
        )) continue;
        // Skill slots assign by overwrite, and skill-slot bindings are
        // press-only (the repeat whitelist - repeating would queue uses
        // by accident): a same-frame double-slot press keeps the
        // FIRST-listed binding's slot.
        switch (binding.action) {
            .skill_slot_1,
            .skill_slot_2,
            .skill_slot_3,
            .skill_slot_4,
            .skill_slot_5,
            .skill_slot_6,
            .skill_slot_7,
            .skill_slot_8,
            => if (result.idle.skill_slot_selected != null) continue,
            else => {},
        }
        applyAction(&result, binding.action);
    }

    result.anytime.scroll_delta = scroll_delta;
    // Cursor direction from HELD cursor keys (not edges) so a diagonal nudge
    // fires when any one of the two held keys edges/repeats. Opposite keys on
    // one axis cancel.
    var dir_x: i32 = 0;
    var dir_y: i32 = 0;
    if (isActionHeld(.move_cursor_up, bindings, &state.keys_held, &state.mouse_buttons_held, &state.gamepad_buttons_held, modifiers, active_contexts)) dir_y -= 1;
    if (isActionHeld(.move_cursor_down, bindings, &state.keys_held, &state.mouse_buttons_held, &state.gamepad_buttons_held, modifiers, active_contexts)) dir_y += 1;
    if (isActionHeld(.move_cursor_left, bindings, &state.keys_held, &state.mouse_buttons_held, &state.gamepad_buttons_held, modifiers, active_contexts)) dir_x -= 1;
    if (isActionHeld(.move_cursor_right, bindings, &state.keys_held, &state.mouse_buttons_held, &state.gamepad_buttons_held, modifiers, active_contexts)) dir_x += 1;
    result.anytime.in_game.cursor_direction = .{ .x = dir_x, .y = dir_y };

    // Press-edge direction from the same-frame press arrays (repeats
    // excluded) - the rollover fallback vector (see
    // InGameInput.cursor_press_direction).
    var press_dir_x: i32 = 0;
    var press_dir_y: i32 = 0;
    if (actionPressedOnRealEdge(.move_cursor_up, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers, active_contexts)) press_dir_y -= 1;
    if (actionPressedOnRealEdge(.move_cursor_down, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers, active_contexts)) press_dir_y += 1;
    if (actionPressedOnRealEdge(.move_cursor_left, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers, active_contexts)) press_dir_x -= 1;
    if (actionPressedOnRealEdge(.move_cursor_right, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers, active_contexts)) press_dir_x += 1;
    result.anytime.in_game.cursor_press_direction = .{ .x = press_dir_x, .y = press_dir_y };

    // Raw mouse-over-tile (unvalidated; the cursor resolution in update()
    // checks it against world tiles + UI occlusion). Plus whether the mouse
    // moved this tick (mouse owns the cursor when it moved; arrows otherwise).
    result.anytime.in_game.mouse_tile = screenToTile(state.mouse_screen_position, camera, zoom, platform.viewport);
    result.anytime.in_game.mouse_moved_this_tick = mouse_moved_this_tick;

    // Left mouse click → tile_clicked (levels/hubs/editor) + the raw
    // screen position (the campaign editor's map surface).
    if (InputState.isHeld(&mouse_pressed, "left")) {
        result.idle.tile_clicked = screenToTile(state.mouse_screen_position, camera, zoom, platform.viewport);
        result.idle.map_clicked = state.mouse_screen_position.toScreenPosition();
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
        .position = state.mouse_screen_position,
        .right_pressed = InputState.isHeld(mouse_pressed, "right"),
        .right_released = InputState.isHeld(mouse_released, "right"),
        .right_held = InputState.isHeld(&state.mouse_buttons_held, "right"),
        .modifiers = modifiers,
    };
}

// ============================================================
// Tests - binding contexts + hybrid input precedence (DESIGN → Input)
// ============================================================
//
// `checkAction` gates on the active binding-context set first (same-combo
// cross-context pairs never co-fire), then resolves a pressed input by
// SPECIFICITY within the active set: a more-specific chord (more required
// modifiers, all held) on the same key suppresses a less-specific
// binding; equal-specificity ties co-fire.

const empty_mouse: [InputState.max_held_mouse]?[]const u8 = @splat(null);
const empty_gamepad: [InputState.max_held_gamepad]?[]const u8 = @splat(null);
const no_repeat_keys: [0]?[]const u8 = .{};
const no_keys: [0]?[]const u8 = .{};

// The level-screen active set (anytime + game) - the context the chord-
// precedence tests run under.
const test_contexts: types.BindingContextSet = .{ .anytime = true, .game = true };

test "translateInput: focused text field suppresses bindings, routes keys + chars" {
    // Enter is bound to confirm, Escape to the options menu. While a field
    // is focused those keys must resolve the FIELD (commit / discard) and
    // no binding may fire - the M2 suppression rule (DESIGN → UI Framework
    // → Text input widget).
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Escape" }, .action = .escape },
    };
    const settings: Settings = .{ .input_bindings = &bindings };
    const camera: Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const platform = PlatformInput{
        .events = &.{.{ .key_down = "Enter" }},
        .viewport = .{ .width = 2560, .height = 2160 },
        .text_characters = " Pup",
    };
    const active_contexts: types.BindingContextSet = .{ .anytime = true, .game = true };

    // Control (unfocused): Enter fires its binding.
    {
        var input_state: InputState = .{};
        const result = translateInput(platform, &input_state, settings, camera, 0, null, null, active_contexts);
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
            null,
            active_contexts,
        );
        try std.testing.expectEqual(types.TextEditOutcome.commit, result.text_edit_outcome);
        try std.testing.expect(!result.idle.confirm);
        try std.testing.expect(!result.anytime.escape);
        try std.testing.expectEqualStrings("Wolf Pup", ui_state.text_edit.?.buffer.currentText());
    }
}

fn keysPressedOne(comptime id: []const u8) [InputState.max_held_keys]?[]const u8 {
    var arr: [InputState.max_held_keys]?[]const u8 = @splat(null);
    arr[0] = id;
    return arr;
}

test "bindingFires: more-specific chord suppresses plain binding on same key" {
    // Enter → confirm (plain); Enter+ctrl → dump_event_log (ctrl).
    // Pressing ctrl+Enter fires dump_event_log only.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Enter" }, .modifiers = .{ .ctrl = true }, .action = .dump_event_log },
    };
    const pressed = keysPressedOne("Enter");
    const mods = Modifiers{ .ctrl = true };
    try std.testing.expect(bindingFires(bindings[1], 1, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, test_contexts));
    try std.testing.expect(!bindingFires(bindings[0], 0, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, test_contexts));
}

test "bindingFires: plain press (no chord modifiers) fires plain binding only" {
    // Same bindings, but ctrl NOT held. The ctrl binding's requirement isn't
    // met, so only the plain confirm fires.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Enter" }, .modifiers = .{ .ctrl = true }, .action = .dump_event_log },
    };
    const pressed = keysPressedOne("Enter");
    const mods = Modifiers{};
    try std.testing.expect(bindingFires(bindings[0], 0, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, test_contexts));
    try std.testing.expect(!bindingFires(bindings[1], 1, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, test_contexts));
}

test "bindingFires: same key, different contexts - exactly one fires" {
    // The shipped ArrowUp pattern under binding contexts: move_cursor_up
    // (game) + error_scroll_up (error_popup) share ArrowUp. The active
    // context set is the single disambiguator - with the game set active
    // only the cursor binding fires, with the error-popup set active only
    // the scroll binding fires. They never co-fire, and neither suppresses
    // the other (an inactive-context binding is not a precedence
    // competitor). See DESIGN → Input → Binding contexts.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "ArrowUp" }, .action = .move_cursor_up },
        .{ .input = .{ .key = "ArrowUp" }, .action = .error_scroll_up },
    };
    const pressed = keysPressedOne("ArrowUp");
    const mods = Modifiers{};
    const game_contexts: types.BindingContextSet = .{ .anytime = true, .game = true };
    try std.testing.expect(bindingFires(bindings[0], 0, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, game_contexts));
    try std.testing.expect(!bindingFires(bindings[1], 1, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, game_contexts));
    const error_contexts: types.BindingContextSet = .{ .error_popup = true };
    try std.testing.expect(!bindingFires(bindings[0], 0, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, error_contexts));
    try std.testing.expect(bindingFires(bindings[1], 1, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, error_contexts));
}

test "bindingFires: editor bindings inactive on the level screen" {
    // Digit1 bound twice - skill_slot_1 (game) + the editor select tool
    // (editor). On the level screen only the skill slot fires; on the
    // editor screen only the tool shortcut fires.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Digit1" }, .action = .skill_slot_1 },
        .{ .input = .{ .key = "Digit1" }, .action = .select_editor_tool },
    };
    const pressed = keysPressedOne("Digit1");
    const mods = Modifiers{};
    const game_contexts: types.BindingContextSet = .{ .anytime = true, .game = true };
    try std.testing.expect(bindingFires(bindings[0], 0, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, game_contexts));
    try std.testing.expect(!bindingFires(bindings[1], 1, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, game_contexts));
    const editor_contexts: types.BindingContextSet = .{ .anytime = true, .editor = true };
    try std.testing.expect(!bindingFires(bindings[0], 0, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, editor_contexts));
    try std.testing.expect(bindingFires(bindings[1], 1, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, editor_contexts));
}

test "bindingFires: equal-specificity conflict - earlier binding wins, one action fires" {
    // The conflict-rule fallback: one combo fires ONE action per context.
    // Two same-combo equal-specificity bindings on different actions
    // (both game-context) would co-fire - the EARLIER list entry wins and
    // the later is suppressed. Reachable only via a hand-edited file
    // (`loadSettings` warns + drops conflicts; the keybind UI prevents
    // them) - the deterministic fallback keeps replay safe. See DESIGN →
    // Input → Hybrid precedence + binding conflicts.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Enter" }, .action = .skip },
    };
    const pressed = keysPressedOne("Enter");
    const mods = Modifiers{};
    const game_contexts: types.BindingContextSet = .{ .anytime = true, .game = true };
    try std.testing.expect(bindingFires(bindings[0], 0, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, game_contexts));
    try std.testing.expect(!bindingFires(bindings[1], 1, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, game_contexts));
}

test "bindingFires: same action twice on one combo - both entries fire it" {
    // Duplicate entries on the SAME action are redundant, not conflicting:
    // neither suppresses the other (both set the same flag - `applyAction`
    // is idempotent - the loader warns + drops the duplicate; the engine
    // stays permissive).
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
    };
    const pressed = keysPressedOne("Enter");
    const mods = Modifiers{};
    const game_contexts: types.BindingContextSet = .{ .anytime = true, .game = true };
    try std.testing.expect(bindingFires(bindings[0], 0, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, game_contexts));
    try std.testing.expect(bindingFires(bindings[1], 1, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, game_contexts));
}

test "bindingFires: a chord requiring an un-held modifier does not suppress" {
    // Enter → confirm (plain); Enter+shift → dump_event_log (shift). Pressing
    // Enter with ctrl held (not shift): the shift binding doesn't match the
    // held modifiers, so it is NOT a competitor - confirm still fires.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .confirm },
        .{ .input = .{ .key = "Enter" }, .modifiers = .{ .shift = true }, .action = .dump_event_log },
    };
    const pressed = keysPressedOne("Enter");
    const mods = Modifiers{ .ctrl = true };
    try std.testing.expect(bindingFires(bindings[0], 0, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, test_contexts));
    try std.testing.expect(!bindingFires(bindings[1], 1, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, test_contexts));
}

test "bindingFires: most specific among three wins" {
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
    try std.testing.expect(bindingFires(bindings[2], 2, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, test_contexts));
    try std.testing.expect(!bindingFires(bindings[1], 1, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, test_contexts));
    try std.testing.expect(!bindingFires(bindings[0], 0, &bindings, &pressed, &no_repeat_keys, &empty_mouse, &empty_gamepad, mods, test_contexts));
}

test "bindingFires: synthetic repeat edges fire only repeat-whitelisted actions" {
    // The repeat whitelist (`actionRepeats`) gates synthetic key-repeat
    // edges inside the per-binding gate (the old shape passed a per-action
    // repeat slice at each call site). Held keys crossing their repeat
    // threshold fire undo/redo, skip, error-scroll, and the movement
    // cursors; everything else is press-only - escape held must NOT fire
    // on repeat.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "KeyZ" }, .action = .undo },
        .{ .input = .{ .key = "Escape" }, .action = .escape },
    };
    const no_keys_pressed: [InputState.max_held_keys]?[]const u8 = @splat(null);
    const repeated_undo = keysPressedOne("KeyZ");
    const repeated_escape = keysPressedOne("Escape");
    const mods = Modifiers{};
    // A repeat edge on the undo binding: fires (whitelisted).
    try std.testing.expect(bindingFires(bindings[0], 0, &bindings, &no_keys_pressed, &repeated_undo, &empty_mouse, &empty_gamepad, mods, test_contexts));
    // A repeat edge on the escape binding: does not fire (press-only).
    try std.testing.expect(!bindingFires(bindings[1], 1, &bindings, &no_keys_pressed, &repeated_escape, &empty_mouse, &empty_gamepad, mods, test_contexts));
}

test "translateInput: a menu-action binding fires on the main-menu set only" {
    // The convergence fix: the keybinds tab's action picker lists the whole
    // Action enum, but the old per-action dispatch lines never checked the
    // menu commands - a binding on `new_game` was silently dead (the picker
    // let you make it; translateInput never fired it). With the one
    // dispatch pass every action is live; the derived binding-context
    // gate (menu context, active only on the main-menu screen) keeps it
    // to its screens - dormant on the level screen like any editor/menu
    // action.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .new_game },
    };
    const settings: Settings = .{ .input_bindings = &bindings };
    const camera: Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const platform = PlatformInput{
        .events = &.{.{ .key_down = "Enter" }},
        .viewport = .{ .width = 2560, .height = 2160 },
    };
    // Main menu: fires, folding to menu_action (the button path's field).
    {
        var input_state: InputState = .{};
        const result = translateInput(platform, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .menu = true });
        try std.testing.expectEqual(types.Action.new_game, result.idle.menu_action);
    }
    // Level screen: the menu context is dormant - no fire.
    {
        var input_state: InputState = .{};
        const result = translateInput(platform, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .game = true });
        try std.testing.expectEqual(@as(?types.Action, null), result.idle.menu_action);
    }
}

test "translateInput: editor tool/palette keybinds bridge onto the click actions" {
    // Digit1-5 on the editor screen (the first shipped same-combo
    // cross-context pair - Digit1-8 are the in-game skill slots): the
    // tool shortcuts must land on options_action=.select_editor_tool with
    // the right editor_tool payload, and the group toggles on
    // options_action=.toggle_editor_palette_group with the right group
    // index - the exact pairs the button-release dispatch produces, so
    // the click consumption sites serve both. On the game set the same
    // keys fire the skill slots and nothing editor-side.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Digit1" }, .action = .skill_slot_1 },
        .{ .input = .{ .key = "Digit2" }, .action = .skill_slot_2 },
        .{ .input = .{ .key = "Digit1" }, .action = .editor_select_tool },
        .{ .input = .{ .key = "Digit2" }, .action = .editor_tile_tool },
        .{ .input = .{ .key = "Digit3" }, .action = .toggle_editor_entity_group },
    };
    const settings: Settings = .{ .input_bindings = &bindings };
    const camera: Camera = .{ .position = .{ .x = 0, .y = 0 } };

    const press_one = PlatformInput{
        .events = &.{.{ .key_down = "Digit1" }},
        .viewport = .{ .width = 2560, .height = 2160 },
    };
    const press_two = PlatformInput{
        .events = &.{.{ .key_down = "Digit2" }},
        .viewport = .{ .width = 2560, .height = 2160 },
    };
    const press_three = PlatformInput{
        .events = &.{.{ .key_down = "Digit3" }},
        .viewport = .{ .width = 2560, .height = 2160 },
    };

    // Editor screen: Digit1 → select tool (bridged), no skill slot.
    {
        var input_state: InputState = .{};
        const result = translateInput(press_one, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .editor = true });
        try std.testing.expectEqual(types.Action.select_editor_tool, result.anytime.options_action);
        try std.testing.expectEqual(types.EditorToolId.select, result.clicked_payload.?.editor_tool);
        try std.testing.expect(result.idle.skill_slot_selected == null);
    }
    // Editor screen: Digit2 → tile tool.
    {
        var input_state: InputState = .{};
        const result = translateInput(press_two, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .editor = true });
        try std.testing.expectEqual(types.Action.select_editor_tool, result.anytime.options_action);
        try std.testing.expectEqual(types.EditorToolId.tile, result.clicked_payload.?.editor_tool);
    }
    // Editor screen: Digit3 → entity group toggle (group index 0).
    {
        var input_state: InputState = .{};
        const result = translateInput(press_three, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .editor = true });
        try std.testing.expectEqual(types.Action.toggle_editor_palette_group, result.anytime.options_action);
        try std.testing.expectEqual(@as(usize, 0), result.clicked_payload.?.editor_group);
    }
    // Level screen: the same keys are the skill slots - no editor bridge.
    {
        var input_state: InputState = .{};
        const result = translateInput(press_one, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .game = true });
        try std.testing.expectEqual(@as(u8, 1), result.idle.skill_slot_selected);
        try std.testing.expect(result.anytime.options_action == null);
        try std.testing.expect(result.clicked_payload == null);
    }
    {
        var input_state: InputState = .{};
        const result = translateInput(press_two, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .game = true });
        try std.testing.expectEqual(@as(u8, 2), result.idle.skill_slot_selected);
    }
}

test "translateInput: editor save/export chords reach the anytime flags" {
    // Regression: ctrl+S shipped bound in data/default_settings.txt with
    // every plumbing site wired, but translateInput never dispatched
    // checkAction for save_editor_mission - the keybind was dead while the
    // options-menu button (applyAction) worked. This test pins the dispatch
    // itself, not just checkAction, so a missing line fails here. Runs on
    // the editor-screen context set; the same key's plain binding
    // (toggle_skills, game context) is inactive there - the chord-vs-plain
    // precedence itself is pinned by the checkAction tests above.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "KeyS" }, .action = .toggle_skills },
        .{ .input = .{ .key = "KeyS" }, .modifiers = .{ .ctrl = true }, .action = .save_editor_mission },
        .{ .input = .{ .key = "KeyE" }, .modifiers = .{ .ctrl = true }, .action = .export_editor_mission },
    };
    const settings: Settings = .{ .input_bindings = &bindings };
    const camera: Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const platform = PlatformInput{
        .events = &.{
            .{ .key_down = "ControlLeft" },
            .{ .key_down = "KeyS" },
            .{ .key_down = "KeyE" },
        },
        .viewport = .{ .width = 2560, .height = 2160 },
    };
    var input_state: InputState = .{};
    const active_contexts: types.BindingContextSet = .{ .anytime = true, .editor = true };
    const result = translateInput(platform, &input_state, settings, camera, 0, null, null, active_contexts);
    try std.testing.expect(result.anytime.save_editor_mission);
    try std.testing.expect(result.anytime.export_editor_mission);
    try std.testing.expect(!result.anytime.in_game.toggle_skills);
}

test "translateInput: ctrl+N fires new_editor_mission on the editor set only" {
    // The New Mission keybind's dispatch pin (the ctrl+S lesson: a binding
    // with every other site wired but no checkAction line is dead).
    // new_editor_mission is in the editor-browser family - EDITOR-ONLY
    // by classification (the browser still opens from the main menu via
    // its buttons; the keyboard shortcuts are editor-only). Dormant on
    // level/hub (a playtest/validation run) + the main menu.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "KeyN" }, .modifiers = .{ .ctrl = true }, .action = .new_editor_mission },
    };
    const settings: Settings = .{ .input_bindings = &bindings };
    const camera: Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const platform = PlatformInput{
        .events = &.{
            .{ .key_down = "ControlLeft" },
            .{ .key_down = "KeyN" },
        },
        .viewport = .{ .width = 2560, .height = 2160 },
    };
    // Editor screen: fires.
    {
        var input_state: InputState = .{};
        const result = translateInput(platform, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .editor = true });
        try std.testing.expect(result.anytime.new_editor_mission);
    }
    // Main menu: no fire (the browser opens there via its BUTTONS; the
    // keyboard shortcut is editor-only).
    {
        var input_state: InputState = .{};
        const result = translateInput(platform, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .menu = true });
        try std.testing.expect(!result.anytime.new_editor_mission);
    }
    // Level/hub (a playtest/validation run - the binding must go dormant
    // there): no fire.
    {
        var input_state: InputState = .{};
        const result = translateInput(platform, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .game = true });
        try std.testing.expect(!result.anytime.new_editor_mission);
    }
}

test "translateInput: an active keybind edit suppresses bindings + captures the press" {
    // The capture seam (the text-edit suppression model): while an edit is
    // active, NO binding fires and the raw presses route into the edit.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "KeyQ" }, .action = .dump_event_log },
    };
    const settings: Settings = .{ .input_bindings = &bindings };
    const camera: Camera = .{ .position = .{ .x = 0, .y = 0 } };
    var ui_state: ui.UiState = .{};
    ui_state.keybind_edit = .{ .edit = .{ .listening = .{ .binding = 0 } } };
    const platform = PlatformInput{
        .events = &.{
            .{ .key_down = "ControlLeft" },
            .{ .key_down = "KeyQ" },
        },
        .viewport = .{ .width = 2560, .height = 2160 },
    };
    var input_state: InputState = .{};
    const result = translateInput(platform, &input_state, settings, camera, 0, null, if (ui_state.keybind_edit != null) &ui_state.keybind_edit.? else null, .{ .anytime = true, .game = true });
    // Suppressed: the KeyQ binding never fired.
    try std.testing.expect(!result.anytime.dump_event_log);
    // Captured instead - with the held ctrl as the combo requirement.
    try std.testing.expectEqual(types.KeybindCaptureOutcome.captured, result.keybind_capture_outcome);
    try std.testing.expectEqualStrings("KeyQ", ui_state.keybind_edit.?.capture.capturedId().?);
    try std.testing.expect(ui_state.keybind_edit.?.capture.modifiers.ctrl);
}

test "translateInput: cursor_press_direction - real press edges only (the rollover fallback vector)" {
    // The nudge vector derives from HELD keys (opposites cancel), so a
    // press landing while its opposite is still held - key rollover at
    // fast input speeds - produced a zero vector and its edge was
    // consumed with no movement (the arrow-key swallow; see
    // resolveTileCursor's fallback). cursor_press_direction carries the
    // real-press intent for that fallback: this tick's press edges,
    // synthetic repeats excluded.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "ArrowLeft" }, .action = .move_cursor_left },
        .{ .input = .{ .key = "ArrowRight" }, .action = .move_cursor_right },
    };
    const settings: Settings = .{ .input_bindings = &bindings };
    const camera: Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const game_set: types.BindingContextSet = .{ .anytime = true, .game = true };
    const viewport = ViewportSize{ .width = 2560, .height = 2160 };

    // Rollover: right pressed on an earlier frame (still held - no
    // release), left presses now. The held vector cancels to zero; the
    // press direction keeps the left intent.
    {
        var input_state: InputState = .{};
        _ = translateInput(
            PlatformInput{ .events = &.{.{ .key_down = "ArrowRight" }}, .viewport = viewport },
            &input_state,
            settings,
            camera,
            0,
            null,
            null,
            game_set,
        );
        const rollover = translateInput(
            PlatformInput{ .events = &.{.{ .key_down = "ArrowLeft" }}, .viewport = viewport },
            &input_state,
            settings,
            camera,
            0,
            null,
            null,
            game_set,
        );
        const in_game = rollover.anytime.in_game;
        try std.testing.expect(in_game.move_cursor_left);
        try std.testing.expectEqual(@as(i32, 0), in_game.cursor_direction.x);
        try std.testing.expectEqual(@as(i32, -1), in_game.cursor_press_direction.x);
    }

    // Synthetic repeat edges do NOT count as presses: right held past the
    // repeat threshold fires the move_cursor_right edge again, but the
    // press direction stays zero - a deliberately-held opposite pair
    // keeps the frozen cancel, and the fallback cannot oscillate on
    // per-key repeat-timer drift.
    {
        var input_state: InputState = .{};
        _ = translateInput(
            PlatformInput{ .events = &.{.{ .key_down = "ArrowRight" }}, .viewport = viewport },
            &input_state,
            settings,
            camera,
            0,
            null,
            null,
            game_set,
        );
        const repeat_frame = translateInput(
            PlatformInput{ .events = &.{}, .viewport = viewport },
            &input_state,
            settings,
            camera,
            400 * std.time.us_per_ms,
            null,
            null,
            game_set,
        );
        const in_game = repeat_frame.anytime.in_game;
        try std.testing.expect(in_game.move_cursor_right);
        try std.testing.expectEqual(@as(i32, 1), in_game.cursor_direction.x);
        try std.testing.expectEqual(@as(i32, 0), in_game.cursor_press_direction.x);
    }
}

test "translateInput: ctrl+S is save_campaign on the campaign editor set, save_editor_mission on the editor set" {
    // The two editors' save chords share ONE combo across SEPARATE
    // contexts (the derived-context rule: a combo may be bound once per
    // context, and the campaign editor screen activates campaign_editor -
    // not editor - so neither binding shadows the other). The 3e wiring
    // shipped both bindings in the editor context, where first-listed
    // wins made save_campaign dead on the campaign editor screen (the
    // options-menu button worked; the chord didn't).
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "KeyS" }, .modifiers = .{ .ctrl = true }, .action = .save_editor_mission },
        .{ .input = .{ .key = "KeyS" }, .modifiers = .{ .ctrl = true }, .action = .save_campaign },
        .{ .input = .{ .key = "KeyN" }, .modifiers = .{ .ctrl = true }, .action = .new_editor_mission },
    };
    const settings: Settings = .{ .input_bindings = &bindings };
    const camera: Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const chord = PlatformInput{
        .events = &.{
            .{ .key_down = "ControlLeft" },
            .{ .key_down = "KeyS" },
        },
        .viewport = .{ .width = 2560, .height = 2160 },
    };
    const new_chord = PlatformInput{
        .events = &.{
            .{ .key_down = "ControlLeft" },
            .{ .key_down = "KeyN" },
        },
        .viewport = .{ .width = 2560, .height = 2160 },
    };

    // The mission editor screen: its own save fires, the campaign's is
    // dormant (the campaign_editor context is inactive).
    {
        var input_state: InputState = .{};
        const result = translateInput(chord, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .editor = true });
        try std.testing.expect(result.anytime.save_editor_mission);
        try std.testing.expect(!result.anytime.save_campaign);
    }
    // The campaign editor screen: the campaign save fires, the mission's
    // is dormant (the editor context is inactive).
    {
        var input_state: InputState = .{};
        const result = translateInput(chord, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .campaign_editor = true });
        try std.testing.expect(result.anytime.save_campaign);
        try std.testing.expect(!result.anytime.save_editor_mission);
    }
    // The browser family fires on BOTH editor screens (the browser opens
    // over either).
    {
        var input_state: InputState = .{};
        const editor_result = translateInput(new_chord, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .editor = true });
        try std.testing.expect(editor_result.anytime.new_editor_mission);
    }
    {
        var input_state: InputState = .{};
        const campaign_result = translateInput(new_chord, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .campaign_editor = true });
        try std.testing.expect(campaign_result.anytime.new_editor_mission);
    }
    // The cross-editor same-combo pair is legal (never co-fires - the
    // load-time conflict predicate).
    try std.testing.expect(!types.bindingContextsCoFire(.{ .editor = true }, .{ .campaign_editor = true }));
}

test "translateInput: campaign tool keybinds bridge onto the campaign cell's click action" {
    // Digit1-3 across BOTH editors (the campaign_editor context - the
    // same combos as the mission palette's tools, never co-firing): on
    // the campaign editor set the keys land on
    // options_action=.select_editor_campaign_tool with the right
    // campaign tool payloads (the exact pairs the palette cell's click
    // dispatch produces, so the click consumption site serves both); on
    // the editor set the mission palette's own Digit1-3 fire and nothing
    // campaign-side does.
    const bindings = [_]InputBinding{
        .{ .input = .{ .key = "Digit1" }, .action = .editor_select_tool },
        .{ .input = .{ .key = "Digit2" }, .action = .editor_tile_tool },
        .{ .input = .{ .key = "Digit1" }, .action = .campaign_select_tool },
        .{ .input = .{ .key = "Digit2" }, .action = .campaign_hub_tool },
        .{ .input = .{ .key = "Digit3" }, .action = .campaign_mission_tool },
    };
    const settings: Settings = .{ .input_bindings = &bindings };
    const camera: Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const press_one = PlatformInput{
        .events = &.{.{ .key_down = "Digit1" }},
        .viewport = .{ .width = 2560, .height = 2160 },
    };
    const press_two = PlatformInput{
        .events = &.{.{ .key_down = "Digit2" }},
        .viewport = .{ .width = 2560, .height = 2160 },
    };
    const press_three = PlatformInput{
        .events = &.{.{ .key_down = "Digit3" }},
        .viewport = .{ .width = 2560, .height = 2160 },
    };

    // Campaign editor screen: Digit1 -> select, Digit2 -> hub, Digit3 ->
    // mission (all bridged onto the cell's click action + payload).
    {
        var input_state: InputState = .{};
        const result = translateInput(press_one, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .campaign_editor = true });
        try std.testing.expectEqual(types.Action.select_editor_campaign_tool, result.anytime.options_action);
        try std.testing.expectEqual(types.CampaignEditorToolId.select, result.clicked_payload.?.editor_campaign_tool);
    }
    {
        var input_state: InputState = .{};
        const result = translateInput(press_two, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .campaign_editor = true });
        try std.testing.expectEqual(types.Action.select_editor_campaign_tool, result.anytime.options_action);
        try std.testing.expectEqual(types.CampaignEditorToolId.hub, result.clicked_payload.?.editor_campaign_tool);
    }
    {
        var input_state: InputState = .{};
        const result = translateInput(press_three, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .campaign_editor = true });
        try std.testing.expectEqual(types.Action.select_editor_campaign_tool, result.anytime.options_action);
        try std.testing.expectEqual(types.CampaignEditorToolId.mission, result.clicked_payload.?.editor_campaign_tool);
    }
    // Mission editor screen: the same keys are the MISSION palette's
    // tools - no campaign bridge.
    {
        var input_state: InputState = .{};
        const result = translateInput(press_one, &input_state, settings, camera, 0, null, null, .{ .anytime = true, .editor = true });
        try std.testing.expectEqual(types.Action.select_editor_tool, result.anytime.options_action);
        try std.testing.expectEqual(types.EditorToolId.select, result.clicked_payload.?.editor_tool);
    }
}
