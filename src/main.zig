//! Platform-agnostic composition root. Owns the uncapped game loop
//! (`gameLoop`/`run`), the per-iteration `update` step that ties input
//! polling, event processing, and view construction together, and the
//! round-trip reconstruction test. Startup config loading lives in
//! `session_setup.zig`; the entry files build the `SessionSetup` there and
//! hand it to `run`. Never imports raylib — the platform driver
//! (`native.zig`/`web.zig`) calls `run` with a duck-typed backend and drives
//! `frame` per platform. See DESIGN → Platform Seam for the frame/driver
//! split and the budget-driven drain.

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const combat_log = @import("combat_log.zig");
const state = @import("state.zig");
const functions = @import("functions.zig");
const input = @import("input.zig");
const parser = @import("parser.zig");
const session_log = @import("session_log.zig");
const session_log_bundle = @import("session_log_bundle.zig");
const lookups = @import("generated_lookups.zig");
const ui = @import("ui.zig");
const event_handlers = @import("event_handlers.zig");
const event_push = @import("event_push.zig");
const input_handlers = @import("input_handlers.zig");
const input_gestures = @import("input_gestures.zig");
const view_mod = @import("view.zig");
const build_info = @import("build_info");
const file_source_mod = @import("file_source.zig");
const crash_dump = @import("crash_dump.zig");
const console = @import("console.zig");

const FileSource = file_source_mod.FileSource;

const test_harness = @import("test_harness.zig");

const GameState = state.GameState;

/// Per-entity stagger gap for number anims (damage/heal): a same-entity
/// multi-hit in one drain spaces its numbers this far apart so they don't
/// overlap (e.g. Bash's attack+collision). 0.125s. See DESIGN → Animation.
const number_stagger_gap_microseconds: u64 = 125_000;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;
const MetaEvent = events.MetaEvent;
const PlayerInput = input.PlayerInput;
const Vector2 = types.Vector2;
const Entity = types.Entity;
const SkillId = types.SkillId;
const Editor = types.Editor;
const ReplayViewer = types.ReplayViewer;
const Level = types.Level;
const session_setup = @import("session_setup.zig");
const FrameState = session_setup.FrameState;
const Skill = @import("skill.zig").Skill;
const SkillType = types.SkillType;
const utility_skill_count = types.utility_skill_count;

// ============================================================
// Core functions
// ============================================================

// `export` makes these visible to JS when compiled to WASM.
// The build.zig `export_symbol_names` list must include them too.

/// Handle inputs that can interrupt regardless of event stack state.
/// Map a completed drag (source slot → target slot) to the player event it
/// produces, or null for an invalid / no-op drop. The switch on the source
/// enforces the item/skill domain split: item sources (inventory/gear) only
/// yield events for item targets, skill sources (skill_bar/learned_skill) only
/// for skill targets — everything cross-domain or nonsensical falls to null.
/// Process the next event on the stack, with player input handling.
fn update(
    history: *GameStateHistory,
    input_this_tick: PlayerInput,
    previous_view_state: ?types.ViewState,
    delta_microseconds: u64,
    camera: types.Camera,
    camera_zoom: f32,
    viewport: input.ViewportSize,
) void {
    var player_input = input_this_tick;

    // The UI drawn last frame is what the pointer is over this frame. Used to
    // resolve clicks into actions and to arbitrate world vs UI clicks.
    const ui_elements: []const ui.UiElement =
        if (previous_view_state) |view_state| view_state.ui_elements else &.{};

    // Track held modifiers per-frame so `view()` can render modifier-keyed
    // feedback (salvage-tool highlight while Shift is held). Transient view
    // state — see SessionState.held_modifiers.
    history.session.held_modifiers = player_input.modifiers;

    // Button click resolution: press records the button + queues the
    // down-sound + consumes the world click; release fires the action +
    // queues the up-sound ONLY if the release is over the same button that
    // was pressed (drag-off cancels — no sound, no action). This is the
    // standard UI press/release model. A press on any blocking UI surface
    // (button or not) consumes the world click so it doesn't also act on the
    // level/hub behind it (world/UI arbitration). See DESIGN → Input.
    if (player_input.pointer.pressed) {
        const pointer_position = player_input.pointer.position.toScreenPosition();
        // Text-field focus arbitration (M2 — DESIGN → UI Framework → Text
        // input widget): a left press while a field is focused COMMITS it,
        // then either proceeds (the press is on a sibling inspector
        // control — one-click field switching) or is consumed as pure
        // dismissal (no tool/world action as a side effect of ending an
        // edit; e.g. Undo-while-focused eats the click so the NEXT click
        // undoes the just-committed value). Idempotent across the drain's
        // repeated update() calls: the commit clears focus, so later calls
        // take the normal path below.
        var consumed_by_text_edit = false;
        if (history.session.ui_state.text_edit != null) {
            // Pressing the FOCUSED field itself does not commit — the press
            // tracks for caret positioning at release. Any other press
            // commits first, then the M2 proceed/consume split.
            const pressed_field = ui.textFieldAt(ui_elements, pointer_position);
            const pressing_focused_field = pressed_field != null and
                std.meta.eql(pressed_field.?.ref, history.session.ui_state.text_edit.?.field);
            if (!pressing_focused_field) {
                input_handlers.commitFocusedTextEdit(history);
                const inspector_open = if (history.current_state.editor) |editor|
                    editor.inspector_open
                else
                    false;
                const metadata_sidebar_open = if (history.current_state.editor) |editor|
                    editor.metadata_sidebar_open
                else
                    false;
                const pressed_button = if (ui.buttonAt(ui_elements, pointer_position)) |button|
                    button.action
                else
                    null;
                consumed_by_text_edit = !ui.textEditPressProceeds(
                    inspector_open,
                    metadata_sidebar_open,
                    pointer_position,
                    pressed_button,
                );
            }
        }
        if (consumed_by_text_edit) {
            history.session.pressed_button = null;
            history.session.pressed_text_field = null;
            player_input.idle.tile_clicked = null;
            player_input.idle.confirm = false;
        } else if (ui.textFieldAt(ui_elements, pointer_position)) |field| {
            // A text-field press: tracks like a button press (release over
            // the SAME field focuses it / positions the caret; drag-off
            // cancels). A field is not a button — pressed_button stays null.
            history.session.pressed_text_field = field.ref;
            history.session.pressed_button = null;
            player_input.idle.tile_clicked = null;
            player_input.idle.confirm = false;
        } else if (ui.buttonAt(ui_elements, pointer_position)) |button| {
            history.session.pressed_button = button.action;
            history.session.queueSound(history.backing_allocator, .button_base_down);
            player_input.idle.tile_clicked = null;
            player_input.idle.confirm = false;
        } else if (ui.blockingElementAt(ui_elements, pointer_position) != null) {
            history.session.pressed_button = null;
            player_input.idle.tile_clicked = null;
            player_input.idle.confirm = false;
        } else {
            history.session.pressed_button = null;
        }
    }
    if (player_input.pointer.released) {
        const pointer_position = player_input.pointer.position.toScreenPosition();
        // An in-flight drag owns the release: the button-click model yields so
        // `handleDrag` can resolve the drop (or no-op for a drag-back-to-
        // source). `drag` still reflects the promoted state from the prior
        // move frame — `handleDrag` hasn't run yet this frame.
        if (history.session.ui_state.drag == null) {
            if (history.session.pressed_text_field) |pressed_ref| {
                // Release over the SAME field that was pressed: focus it —
                // or, when it is already the focused field, position the
                // caret at the click x (measured with the metrics the field
                // was laid out with, read off the previous view state).
                // Drag-off cancels, same as buttons.
                if (ui.textFieldAt(ui_elements, pointer_position)) |field| {
                    if (std.meta.eql(field.ref, pressed_ref)) {
                        const already_focused = history.session.ui_state.text_edit != null and
                            std.meta.eql(history.session.ui_state.text_edit.?.field, pressed_ref);
                        if (already_focused) {
                            if (previous_view_state) |view_state| {
                                ui.placeCaretFromClick(
                                    &history.session.ui_state.text_edit.?,
                                    field,
                                    pointer_position.x,
                                    view_state.font_metrics,
                                );
                            }
                        } else {
                            input_handlers.beginFocusedTextEdit(history, pressed_ref);
                        }
                    }
                }
            } else if (history.session.pressed_button) |pressed_action| {
                // Fire only if the release is over the same button that was pressed.
                if (ui.buttonAt(ui_elements, pointer_position)) |button| {
                    if (button.action == pressed_action) {
                        input.applyAction(&player_input, button.action);
                        // Payloadful buttons: the load-save rows carry their
                        // row index in the SlotRef (Action can't). Ride it
                        // alongside the folded action — same-frame only.
                        if (button.ref) |ref| switch (ref) {
                            .save_file => |row| player_input.idle.clicked_save_row = row,
                            else => {},
                        };
                        // Settings controls: the SettingRef (which field +
                        // which value) rides in `anytime.clicked_setting`
                        // alongside the `.change_setting` action.
                        if (button.setting_ref) |sref| {
                            player_input.anytime.clicked_setting = sref;
                        }
                        // Editor palette group headers: the group index
                        // rides in `anytime.clicked_editor_group` alongside
                        // the `.toggle_editor_palette_group` action.
                        if (button.editor_group) |group_index| {
                            player_input.anytime.clicked_editor_group = group_index;
                        }
                        // Inspector section headers: the section id rides
                        // in `anytime.clicked_editor_section` alongside the
                        // `.toggle_editor_inspector_section` action.
                        if (button.editor_section) |section| {
                            player_input.anytime.clicked_editor_section = section;
                        }
                        // Sprite picker cells + tabs: the stem / tab ride
                        // alongside their actions.
                        if (button.editor_sprite) |sprite| {
                            player_input.anytime.clicked_editor_sprite = sprite;
                        }
                        if (button.editor_sprite_tab) |tab| {
                            player_input.anytime.clicked_editor_sprite_tab = tab;
                        }
                        // Editor tool cells: the tool identity rides in
                        // `anytime.clicked_editor_tool` alongside the
                        // `.select_editor_tool` action.
                        if (button.editor_tool) |tool| {
                            player_input.anytime.clicked_editor_tool = tool;
                        }
                        // Editor level tabs: the level index rides in
                        // `anytime.clicked_editor_level` alongside the
                        // `.select_editor_level` action.
                        if (button.editor_level) |level_index| {
                            player_input.anytime.clicked_editor_level = level_index;
                        }
                        // Inspector color swatches: the gradient index rides
                        // in `anytime.clicked_editor_color` alongside the
                        // `.select_editor_entity_color` action.
                        if (button.editor_color) |color_index| {
                            player_input.anytime.clicked_editor_color = color_index;
                        }
                        // Inspector slot controls (weapon-type cells, Add,
                        // Delete): the slot + (for type cells) the weapon
                        // type ride alongside the action.
                        if (button.editor_gear_slot) |gear_slot| {
                            player_input.anytime.clicked_editor_gear_slot = gear_slot;
                        }
                        if (button.editor_weapon_type) |weapon_type| {
                            player_input.anytime.clicked_editor_weapon_type = weapon_type;
                        }
                        // Item-type pick cells: the kind rides alongside
                        // the action (weapon cells also carry the type via
                        // `clicked_editor_weapon_type`).
                        if (button.editor_item_kind) |item_kind| {
                            player_input.anytime.clicked_editor_item_kind = item_kind;
                        }
                        // Inventory-slot controls (the player inspector's
                        // Inventory section): the slot index rides
                        // alongside the action.
                        if (button.editor_inventory_slot) |slot_index| {
                            player_input.anytime.clicked_editor_inventory_slot = slot_index;
                        }
                        // Inspector utility-slot buttons + skill-picker
                        // cells: the slot / skill ride alongside the action
                        // (a missing skill payload = the picker's None cell).
                        if (button.editor_utility_slot) |utility_slot| {
                            player_input.anytime.clicked_editor_utility_slot = utility_slot;
                        }
                        // Layers-section controls: the layer index rides
                        // alongside the action (null on the add-layer
                        // button = the picker's add mode).
                        if (button.editor_layer) |layer_index| {
                            player_input.anytime.clicked_editor_layer = layer_index;
                        }
                        // Footprint-editor tile cells: the grid cell index
                        // rides alongside the toggle action.
                        if (button.editor_footprint_tile) |cell_index| {
                            player_input.anytime.clicked_editor_footprint_tile = cell_index;
                        }
                        // Settings-sidebar gradient rows + theme-picker
                        // rows: the role (swatch / Auto buttons) or the
                        // gradient index (picker rows) rides alongside the
                        // action.
                        if (button.editor_gradient_role) |role| {
                            player_input.anytime.clicked_editor_gradient_role = role;
                        }
                        if (button.editor_gradient) |gradient_index| {
                            player_input.anytime.clicked_editor_gradient = gradient_index;
                        }
                        if (button.editor_skill) |skill_id| {
                            player_input.anytime.clicked_editor_skill = skill_id;
                        }
                        // Editor-browser tabs + rows: the kind / tab /
                        // row index ride alongside their actions.
                        if (button.editor_kind) |kind| {
                            player_input.anytime.clicked_editor_kind = kind;
                        }
                        // Settings screen content tab (Settings /
                        // Keybinds) rides alongside its action.
                        if (button.settings_tab) |settings_tab| {
                            player_input.anytime.clicked_settings_tab = settings_tab;
                        }
                        // Keybinds-tab edit command (rekey / reassign /
                        // add / remove / pick / confirm / cancel / reset)
                        // rides alongside its action.
                        if (button.keybind_command) |keybind_command| {
                            player_input.anytime.clicked_keybind_command = keybind_command;
                        }
                        if (button.editor_mission_tab) |mission_tab| {
                            player_input.anytime.clicked_editor_mission_tab = mission_tab;
                        }
                        if (button.editor_mission_row) |mission_row| {
                            player_input.anytime.clicked_editor_mission_row = mission_row;
                        }
                        // Release sound: the base up for every button except
                        // skill slots (auto-fire's use_skill cue subsumes it;
                        // the prepare path plays its own up base at the
                        // consumption site). The action's TEXTURE is queued at
                        // the consumption/effect site, so keyboard triggers
                        // share it (keys stay click-sound-free). See DESIGN →
                        // Audio (layered cues).
                        if (!types.actionIsSkillSlot(button.action)) {
                            history.session.queueSound(history.backing_allocator, .button_base_up);
                        }
                        player_input.idle.tile_clicked = null;
                        player_input.idle.confirm = false;
                    }
                }
            }
        }
        history.session.pressed_button = null;
        history.session.pressed_text_field = null;
    }

    // Tile-cursor resolution: decide what tile (if any) the logical cursor is
    // on this frame. Mouse takes precedence when it moved (cursor follows it,
    // cleared over blocking UI or a non-tile); otherwise arrow keys nudge the
    // cursor one tile (snapping to the player's tile if null). Runs before
    // input_handlers.handleAnytimeInput/input_handlers.handleIdleInput so the
    // idle path sees the fresh cursor (auto_target_at_cursor reads it).
    input_handlers.resolveTileCursor(history, player_input, ui_elements);

    // Always handle anytime input first (escape always works,
    // but other inputs are blocked when the options menu is open)
    input_handlers.handleAnytimeInput(history, player_input.anytime, player_input.pointer.position.toScreenPosition(), ui_elements);

    // Settings slider drag runs before the options-menu gate so sliders work
    // while the settings overlay is open on top of the options menu. See
    // DESIGN → UI Framework → Settings screen.
    input_gestures.handleSliderDrag(history, player_input.pointer, ui_elements);

    // Options menu pauses the game. The editor browser (a modal on
    // top of it or standalone over the editor / main menu) gets the same
    // pause: drag / camera pan / viewport gestures + idle input are blocked
    // while it's open. Its own interactions were consumed in
    // handleAnytimeInput above.
    if (history.current_state.ui_surfaces.options_menu_open or
        history.current_state.ui_surfaces.editor_browser_open) return;

    // Recoverable error popup pauses the game (modal — same as options).
    // handleAnytimeInput already cleared it if `dismiss_error` fired this
    // frame, so a dismiss releases the modal within the same frame.
    if (history.session.pending_error != null) return;

    // Drag lifecycle runs anytime (not gated on the event stack) so the player
    // can rearrange inventory / gear / skills even while turns resolve. Hit-
    // tested against the previous frame's UI.
    input_gestures.handleDrag(history, player_input.pointer, ui_elements);

    // Camera pan (right-drag) runs anytime alongside the inventory drag. Needs
    // the camera (with current pan) for the drag-start anchor; subsequent pan
    // updates use the stored anchor, so the camera passed here is the frame's
    // input camera. See handleCameraPan.
    input_gestures.handleCameraPan(history, player_input.pointer, ui_elements, camera, camera_zoom, viewport);

    // Right-click entity inspection (levels only). Runs alongside the camera
    // pan + drag; the two right-click consumers coexist via the movement-
    // threshold disambiguation (a clean right-click inspects, a right-drag
    // pans). See handleRightClickInspect.
    input_gestures.handleRightClickInspect(history, player_input.pointer, ui_elements, camera, camera_zoom, viewport);

    // Editor right-click: the tool-independent delete (clean click) vs the
    // camera pan (right-drag) — same disambiguation, owning the
    // `.editor_delete` pending kind on the editor screen. Runs after the
    // inspect handler (which clears only its own kind elsewhere).
    input_gestures.handleRightClickEditorDelete(history, player_input.pointer, ui_elements, camera, camera_zoom, viewport);

    // Editor select-tool marquee (shift+left-drag region add). Runs after
    // the right-click handlers, same anytime block; a shift press is
    // claimed here so `handleIdleInput`'s select arm skips it (the arm
    // gates on Shift itself).
    input_gestures.handleEditorMarquee(history, player_input.pointer, ui_elements, camera, camera_zoom, viewport);

    // Editor select-tool selection move (plain left press on a selected
    // thing OR on an unselected-but-selectable thing, drag, release).
    // Runs after the marquee (a Shift press is the marquee's; a plain
    // press on a claimable thing is the move's — the two gestures are
    // exclusive by press modifier + claimability).
    input_gestures.handleEditorMoveDrag(history, player_input.pointer, ui_elements, camera, camera_zoom, viewport);

    // Editor tile-tool paint drag (plain left press paints the press tile;
    // held + move paints each newly-visited tile). Runs after the move
    // drag — the gestures are exclusive by tool (tile vs select), and a
    // tile-tool press never reaches the select gestures.
    input_gestures.handleEditorTileDrag(history, player_input.pointer, ui_elements, camera, camera_zoom, viewport);

    // Turn-flow pause: while waiting, drain the timer and stall event
    // processing until it elapses. Anytime input and drag above still run, so
    // undo/redo/options remain responsive mid-wait (undo rebuilds state and
    // clears the wait via replay). Not skippable: no input can shorten it.
    if (history.current_state.waiting) |*wait_state| {
        if (wait_state.remaining_microseconds > delta_microseconds) {
            wait_state.remaining_microseconds -= delta_microseconds;
            // Drain anytime-interjected events (e.g. swap_weapons pushed by
            // handleAnytimeInput above) down to the depth the wait started
            // at, so they're handled immediately instead of sitting on the
            // stack until the wait elapses. No idle point: the wait hasn't
            // ended and the surrounding enemy-turn drain owns the next one.
            // Assumption: interjection events don't push nested waits or
            // reconstruction reads (true for swap_hands, the only anytime
            // event-pusher today); break on load_error for safety regardless.
            const baseline = wait_state.baseline_stack_depth;
            while (history.current_state.event_stack.len > baseline) {
                if (history.load_error) break;
                event_handlers.processEvent(history);
            }
            return;
        }
        history.current_state.waiting = null;
        // Wait elapsed this tick; fall through to process the next event.
        // An interjection pushed during the wait is on top of the stack and
        // runs first in the normal path below.
    }

    if (history.current_state.event_stack.len > 0) {
        // Process next pushed event
        event_handlers.processEvent(history);
    } else {
        // Stack empty — accept gameplay input
        input_handlers.handleIdleInput(history, player_input.idle, player_input.modifiers);
    }
}

/// Build a ViewState describing what to render for the current game state.
/// The frame_allocator is a per-frame arena — everything the ViewState
/// points at is allocated from it and lives until the next frame.

/// Live-apply the `render_resolution` setting (called from `frame()` each
/// iteration): compare against the last-applied snapshot and swap the
/// backend's render target on a diff. Same diff-and-apply shape as the audio
/// volumes block above. On apply failure the backend kept its old target, so
/// the setting REVERTS to the currently-running preset — dirty-marked so the
/// revert persists, and surfaced via the pending-error popup. The revert also
/// stops a retry loop: the setting now matches the snapshot, so the user's
/// next click on the failed preset (a fresh diff) is the only re-attempt.
/// See DESIGN → Platform Seam → Render target resolution.
fn applyRenderResolutionSetting(backend: anytype, history: *GameStateHistory) void {
    if (history.settings.render_resolution == history.session.last_applied_render_resolution) return;
    if (backend.applyRenderResolution(history.settings.render_resolution)) {
        history.session.last_applied_render_resolution = history.settings.render_resolution;
        return;
    }
    const requested = history.settings.render_resolution;
    const kept = history.session.last_applied_render_resolution;
    history.settings.render_resolution = kept;
    state.markSettingsDirty(history);
    const message = std.fmt.allocPrint(
        history.history_arena.allocator(),
        "{s} rendering is not supported on this system — kept {s}.",
        .{ requested.label(), kept.label() },
    ) catch @panic("failed to format render resolution error message");
    history.session.setPendingError(history.history_arena.allocator(), message);
}

/// Drain budget: process events for at most this long per frame before
/// returning control to the driver. Long enough that a typical small-level
/// drain completes in one frame on both platforms; short enough that the
/// window/tab stays responsive during a big drain (the driver regains control
/// each frame to poll input + render). Native was previously uncapped (a big
/// drain blocked the main thread); web would have frozen one rAF per event.
/// 10ms is a starting value.
const drain_budget_microseconds: u64 = 10 * std.time.ms_per_s;

/// One frame's worth of work — the platform-agnostic core, shared by both the
/// The number of ALIVE, AGGRO'D, enemy-team entities — the music
/// intensity projection (one ambient layer per active enemy; see DESIGN →
/// Audio — layered music). Pure integer gameplay logic; a state projection
/// computed per frame (never an event), so replay/undo are safe by
/// construction. Hubs have no `level` → 0 layers there.
fn countActiveEnemies(game_state: *const state.GameState) u32 {
    const level = game_state.level orelse return 0;
    var count: u32 = 0;
    for (level.entities) |entity| {
        if (entity.team == 0) continue; // the player + same-team helpers
        if (entity.current_health == 0) continue;
        if (!entity.is_active) continue; // not yet aggroed — no intensity
        count += 1;
    }
    return count;
}

/// The platform-agnostic per-frame update step, shared by the native and
/// web drivers. Gameplay outcome depends on event order + real-clock wait
/// deltas, both identical across platforms; only wall-clock drain
/// duration differs (native drains as fast as the CPU allows within the
/// budget, web drains within the budget per requestAnimationFrame). This
/// function NEVER yields/sleeps — scheduling is the driver's job (native
/// sleeps via backend.waitTime; web lets the browser schedule rAFs).
pub fn frame(backend: anytype, frame_state: *FrameState) void {
    const history = &frame_state.history;

    // Real-clock delta since the last frame (NOT frame-rate based), so the
    // wait timer drains in real time regardless of how often frame() is called.
    // Computed ONCE at the top of the frame and shared by every consumer
    // (music lerp, wait timer, session/animation clocks) — deltaMicroseconds()
    // is stateful (each call returns time since the previous call), so a
    // second call would hand the gameplay clocks a near-zero delta. Also
    // computed before translateInput so synthetic key-repeat cadence (see
    // DESIGN → Input) is framerate-independent too.
    const delta_microseconds = backend.deltaMicroseconds();

    // Music streams require a per-frame update call (raylib decodes in
    // chunks) + the intensity projection drives the layer volumes. No-op
    // when audio isn't initialized. The music/master volume scaling is
    // applied per frame here (sfx volume is per-play in `playSounds`), so
    // volume-setting changes apply live with no diff machinery. See
    // DESIGN → Audio.
    backend.updateMusic(
        countActiveEnemies(&history.current_state),
        delta_microseconds,
        history.settings,
    );

    applyRenderResolutionSetting(backend, history);

    const backend_input = backend.pollInput();
    // Camera is derived (centered on the player + clamped to the view
    // region — see DESIGN → Platform Seam → Camera clamping), computed
    // each frame so input (screenToTile) and rendering stay in sync.
    // Computed BEFORE the console drain below so the level dump projects
    // tiles through the frame's live camera.
    const camera_zoom = @as(f32, @floatFromInt(history.settings.camera_zoom)) / 100.0;
    const view_region = view_mod.cameraViewRegion(
        &history.current_state,
        backend.fontMetrics(),
        camera_zoom,
    );
    // Input camera: computed BEFORE the drain, reflecting the previously-
    // rendered view (the player clicks against what's on screen). Includes
    // the current camera pan so screenToTile maps clicks against the panned
    // view. The render camera is recomputed post-update below so it tracks
    // the state being drawn (see the render gate).
    const camera = view_mod.computeCamera(&history.current_state, camera_zoom, history.session.camera_pan, view_region);
    // Console input (stdin — a scripted/TAS channel): drain one command per
    // frame and merge it into this frame's PlatformInput, so injected input
    // rides the identical pipeline as hardware input from here down (see
    // DESIGN → Input → Console input). No reader thread (web, or a
    // stdin-less native launch) → empty queue → the backend input passes
    // through unchanged.
    const platform_input = console.applyFrameCommand(
        &frame_state.console_queue,
        backend_input,
        frame_state.frame_arena.allocator(),
        history,
        // The last-rendered UI — the same element list the press/release
        // dispatch hit-tests against; the ui dump lists it. Empty before the
        // first render.
        if (frame_state.previous_view_state) |*previous_view_state|
            previous_view_state.ui_elements
        else
            &.{},
        camera,
        camera_zoom,
    );
    // Which binding contexts are live this frame (see DESIGN → Input →
    // Binding contexts). The error popup is modal: while up, ONLY the
    // error_popup context is active (everything else — including `anytime`
    // — is swallowed until dismissal, mirroring the pending_error gate in
    // handleAnytimeInput). Otherwise the current screen picks its context
    // (an editor playtest/validation run is a `.level` screen, so the game
    // set activates and the editor set goes dormant — the run plays like
    // gameplay for free); `anytime` rides along everywhere. The replay
    // viewer has no context-specific bindings yet (`anytime` only).
    const active_contexts: types.BindingContextSet = if (history.session.pending_error != null)
        .{ .error_popup = true }
    else switch (history.current_state.screen) {
        .level, .hub => .{ .anytime = true, .game = true },
        .editor => .{ .anytime = true, .editor = true },
        .main_menu => .{ .anytime = true, .menu = true },
        .replay_viewer => .{ .anytime = true },
    };
    var player_input = input.translateInput(
        platform_input,
        &history.session.input_state,
        history.settings,
        camera,
        delta_microseconds,
        // The focused text field, if any (binding translation is suppressed
        // while set — see DESIGN → UI Framework → Text input widget).
        if (history.session.ui_state.text_edit != null)
            &history.session.ui_state.text_edit.?
        else
            null,
        // The active keybind edit, if any (the Keybinds tab's listening /
        // picker / pending state — binding translation is suppressed while
        // set; see DESIGN → UI Framework → Settings screen).
        if (history.session.ui_state.keybind_edit != null)
            &history.session.ui_state.keybind_edit.?
        else
            null,
        active_contexts,
    );
    // Console `action <name>` commands (merged into PlatformInput.actions
    // above): fold via applyAction — the same seam button clicks use.
    // Keybind-path firing cadence (the flag rides the frame's PlayerInput
    // through the drain), NOT the button path's pressed_button guard. See
    // DESIGN → Input → Console input.
    console.foldInjectedActions(&player_input, platform_input);

    // Text-field keyboard resolution (Enter commits, Escape discards). Once
    // per frame HERE, before the drain — update() re-runs per drain
    // iteration and must not re-resolve. A commit pushes + drains its own
    // event, so the drain below sees the resulting stack state.
    if (player_input.text_edit_outcome != .none) {
        input_handlers.resolveTextEditOutcome(history, player_input.text_edit_outcome);
    }

    // Keybind-capture resolution (a key was captured → pending; Escape →
    // cancel). Same once-per-frame-here rule as the text-field resolution
    // above — the drain re-runs update() per iteration.
    if (player_input.keybind_capture_outcome != .none) {
        input_handlers.resolveKeybindCaptureOutcome(history, player_input.keybind_capture_outcome);
    }

    // Recenter key before the drain, for the pan-clear check: if the
    // player moved this frame (a move event in the drain, or a click-to-move
    // in the idle update) OR the editor switched level tabs, clear the camera
    // pan so the camera recenters on the (newly) clamped framing. Grabbing
    // the pre-drain key lets us detect the change without inspecting events.
    const recenter_key_before = view_mod.cameraRecenterKey(&history.current_state);

    // Advance the non-pause-gated session clock (used for debounced write
    // deadlines). Unlike animation_clock, this advances every frame regardless
    // of pause so writes fire even while the options menu is open. Done before
    // the drain so markWriteDirty (called during the drain via
    // handleAnytimeInput) sees an up-to-date clock. See DESIGN → Input.
    history.session.session_clock +%= delta_microseconds;

    // Drain: call update() repeatedly until the stack empties, a wait
    // activates, or the drain budget elapses — whichever comes first. update()
    // handles one event OR one idle input per call (plus anytime input, drag,
    // and the wait-timer drain); when the stack is empty, the final update()
    // processes one idle input and the drain then exits via the empty-stack
    // check. This is the one behavior change from the old single-update-per-
    // iteration loop: a multi-event drain now completes within a single frame
    // (within the budget) instead of one event per iteration. The old round-
    // trip test's runToIdle helper already drains to empty the same way, so
    // reconstruction semantics are unchanged.
    const drain_start = backend.realClockMicroseconds();
    while (history.current_state.waiting == null and
        history.session.pending_error == null and
        history.current_state.event_stack.len > 0 and
        backend.realClockMicroseconds() - drain_start < drain_budget_microseconds)
    {
        const screen_before_update = history.current_state.screen;
        const world_generation_before_update = history.current_state.world_generation;
        const had_events = history.current_state.event_stack.len > 0;
        update(history, player_input, frame_state.previous_view_state, delta_microseconds, camera, camera_zoom, platform_input.viewport);

        // A reconstruction-read handler failed during the event just
        // processed. Revert to the last idle-point snapshot (guaranteed
        // exact — it was just taken, no snapshots since — and stack-empty by
        // construction), trim the failed transaction's recorded events, and
        // exit the drain. The handler already set session.pending_error with
        // a descriptive message (it survives the revert — SessionState is
        // off GameState). See DESIGN → Error Handling → three contexts.
        if (history.load_error) {
            history.load_error = false;
            const last_idle_event_index = history.idle_points.items[history.current_idle_index];
            history.restoreTo(last_idle_event_index, &event_handlers.processEvent);
            history.event_history.shrinkRetainingCapacity(history.current_event_index);
            break;
        }

        const has_events = history.current_state.event_stack.len > 0;

        // Classes-2–4 UI state (view affordances, scrolls, gesture
        // lifecycles), the tile cursor, and the camera/pressed-button
        // transients are view/input state off the undoable GameState. Reset
        // them whenever the screen changes OR a new world is installed
        // (start_hub / start_level / start_playtest all bump
        // world_generation even when the Screen enum stays the same — e.g.
        // level-to-level keeps screen == .level, so the screen check alone
        // would leave a stale tile cursor positioned in the old level's
        // grid; start_validation chains start_level, so its world installs
        // bump the same way). undo/redo across a screen boundary runs
        // through update() too, so both signals fire there as well. The
        // class-1 SURFACE state is NOT reset here — it lives on GameState
        // and is closed by the handlers (transitionScreen / start_level /
        // start_hub), so replay reproduces it. Input state is deliberately
        // left alone — it is live hardware state.
        if (history.current_state.screen != screen_before_update or
            history.current_state.world_generation != world_generation_before_update)
        {
            history.session.ui_state = .{};
            history.session.tile_cursor = null;
            history.session.camera_pan = null;
            history.session.camera_pan_anchor = null;
            history.session.camera_pan_press = null;
            history.session.pressed_button = null;
            history.session.clearAnims();
        }

        if (had_events and !has_events) {
            // Stack just emptied — record the idle point (snapshot + compact
            // current_arena so per-turn churn and any exited level/hub are
            // reclaimed instead of accumulating across the session). Shared
            // with reconstruction via recordIdlePoint. Condition delegated to
            // maybeRecordIdlePoint (one place for the idle-point detection
            // logic, shared with the idle branch).
            history.maybeRecordIdlePoint(had_events);
        }
    }

    // Idle/wait frame: the stack is empty or a wait is active, so there are no
    // events to drain. Run one update() to handle idle input (and anytime
    // input / drag / wait-timer drain, which update() does every call).
    // Mirrors the old loop's single update() on idle iterations.
    if (history.current_state.waiting != null or
        history.session.pending_error != null or
        history.current_state.event_stack.len == 0)
    {
        const event_index_before_update = history.current_event_index;
        const screen_before_update = history.current_state.screen;
        const world_generation_before_update = history.current_state.world_generation;
        update(history, player_input, frame_state.previous_view_state, delta_microseconds, camera, camera_zoom, platform_input.viewport);
        if (history.current_state.screen != screen_before_update or
            history.current_state.world_generation != world_generation_before_update)
        {
            history.session.ui_state = .{};
            history.session.tile_cursor = null;
            history.session.camera_pan = null;
            history.session.camera_pan_anchor = null;
            history.session.camera_pan_press = null;
            history.session.pressed_button = null;
            history.session.clearAnims();
        }
        // An anytime action (e.g. swap_weapons) can push events onto the
        // empty stack and process them within this one update() call. If
        // events were processed and the stack is empty again with no active
        // wait, it's an idle boundary — record the undo stop via
        // maybeRecordIdlePoint (shared with the drain loop). The helper's
        // "not already an idle point" check excludes undo/redo, which are
        // also anytime actions handled inside update() and land on an
        // existing idle point (recording a duplicate there would make
        // undo/redo cycle). A mid-wait anytime interjection is drained to
        // baseline inside update() and leaves the stack at baseline
        // (non-empty during an enemy turn), so it does not record an idle
        // point here — it stays absorbed into the surrounding drain's idle
        // point, as intended.
        const events_processed = history.current_event_index != event_index_before_update;
        history.maybeRecordIdlePoint(events_processed);
    }

    // Drain queued one-shot sounds after the update drain. Event handlers
    // and input handlers push onto `session.pending_sounds` (gated
    // `!replaying`); play them here via the backend. The slice is valid
    // until the next drain (clearRetainingCapacity keeps the backing). See
    // DESIGN → Audio.
    const pending_sounds = history.session.drainPendingSounds();
    if (pending_sounds.len > 0) {
        backend.playSounds(pending_sounds, history.settings);
    }

    // Drain queued one-shot anims: stamp `end_clock` from the live animation
    // clock and move them into `active_anims`, where `view()` gates them by
    // event index + time. Handlers push gated `!replaying` (same as sounds);
    // the clock is read HERE, not in handlers, so the replay-purity invariant
    // holds (handlers never touch wall-clock). See DESIGN → Animation.
    const pending_anims = history.session.drainPendingAnims();
    for (pending_anims) |anim| {
        // Number anims are per-entity staggered (0.125s gap) so same-entity
        // multi-hits in one drain don't overlap; other anims start immediately.
        // `start_clock` is when the anim begins visibly advancing; `end_clock`
        // is `start_clock + duration_us`. The clock is read HERE, not in
        // handlers, so the replay-purity invariant holds. See DESIGN →
        // Animation.
        const start_clock: u64 = switch (anim.kind) {
            .damage_number => |info| blk: {
                const stagger_gap: u64 = number_stagger_gap_microseconds;
                const earliest = history.session.animation_clock;
                const last = history.session.last_number_start_by_entity.get(info.entity_index) orelse 0;
                const s = if (last == 0) earliest else @max(earliest, last + stagger_gap);
                history.session.last_number_start_by_entity.put(history.backing_allocator, info.entity_index, s) catch
                    @panic("failed to update number stagger map");
                break :blk s;
            },
            .heal_number => |info| blk: {
                const stagger_gap: u64 = number_stagger_gap_microseconds;
                const earliest = history.session.animation_clock;
                const last = history.session.last_number_start_by_entity.get(info.entity_index) orelse 0;
                const s = if (last == 0) earliest else @max(earliest, last + stagger_gap);
                history.session.last_number_start_by_entity.put(history.backing_allocator, info.entity_index, s) catch
                    @panic("failed to update number stagger map");
                break :blk s;
            },
            else => history.session.animation_clock,
        };
        history.session.active_anims.append(history.backing_allocator, .{
            .event_index = anim.event_index,
            .kind = anim.kind,
            .start_clock = start_clock,
            .end_clock = start_clock + anim.duration_us,
        }) catch @panic("failed to activate anim");
    }

    // Player-move recenter: if the player's tile changed this frame (a move
    // event in the drain or a click-to-move in the idle update), clear the
    // camera pan so the camera recenters on the player — pan drifts off the
    // player while looking around, and a move is the natural "look, then go"
    // hand-off back to player-centered framing. The editor's active level
    // index rides the key too: a level-tab switch recenters even when two
    // levels share a player_start (fresh levels all come from one template).
    const recenter_key_after = view_mod.cameraRecenterKey(&history.current_state);
    if (!std.meta.eql(recenter_key_after, recenter_key_before))
    {
        history.session.camera_pan = null;
        history.session.camera_pan_anchor = null;
        history.session.camera_pan_press = null;
    }

    // Advance the animation clock by this frame's real-time delta, but only
    // when the world isn't paused (options menu / pending error open — same
    // gates as `update()`). The clock is session-relative (starts at 0) and
    // off the undoable GameState, so looping anims wave continuously across
    // undo/redo without phase jumps, and pausing freezes anims in place. Read
    // by view() for sprite-animation frame selection. See DESIGN → Animation.
    if (!history.current_state.ui_surfaces.options_menu_open and history.session.pending_error == null) {
        history.session.animation_clock +%= delta_microseconds;
    }

    // Fire any debounced writes whose deadline has elapsed (currently
    // settings persistence). Runs after all updates so dirty
    // marks from this frame's input are registered before the check.
    // `frame()` is the live path — replay goes through restoreTo/replayTo,
    // not here — so the !replaying gate is automatic. See DESIGN → Input.
    history.session.fireElapsedWrites(history, history.session.session_clock);

    // Render gate: only build+render a frame when enough real time has elapsed
    // since the last render AND we're not mid-drain. During an active event
    // drain (stack non-empty, no wait) we skip rendering — intermediate states
    // flash by in <1ms and aren't worth a frame, and vsync (swapScreenBuffer)
    // blocks the thread for a full refresh, frame-locking the drain to the
    // render rate. We render when the drain completes (stack empties) or
    // pauses (a wait is active). render_interval is 0 when uncapped.
    const render_interval = backend.renderIntervalMicroseconds(history.settings);
    const now = backend.realClockMicroseconds();
    const since_last_render = now - frame_state.last_render_time;
    // A pending error pauses the drain (the modal popup blocks event
    // processing) — treat it like a wait for render-gate purposes so the
    // popup is visible. See DESIGN → Error Handling.
    const drain_in_progress = history.current_state.event_stack.len > 0 and
        history.current_state.waiting == null and
        history.session.pending_error == null;
    if (!drain_in_progress and since_last_render >= render_interval) {
        // Smoothed FPS: an EMA over the actual rendered frame interval
        // (`since_last_render` IS the time between this render and the last).
        // Advanced here, in `frame()` only — never in handlers, so the
        // replay-purity invariant holds (handlers never touch wall-clock).
        // Read by `view()` for the optional `show_fps` overlay. See DESIGN
        // → Animation for the clock-in-`frame()`-only rule this mirrors.
        if (since_last_render > 0) {
            const instant: f32 = @as(f32, std.time.us_per_s) /
                @as(f32, @floatFromInt(since_last_render));
            if (history.session.fps_smoothed == 0) {
                history.session.fps_smoothed = instant; // cold-start seed
            } else {
                const alpha: f32 = 0.1;
                history.session.fps_smoothed += alpha * (instant - history.session.fps_smoothed);
            }
        }
        // Render camera is computed from the POST-update current_state, NOT the
        // pre-update camera used for input above. The input camera must reflect
        // the previously-rendered view (clicks are made against what's on
        // screen); the render camera must track the state being drawn. Without
        // this recompute, a move completed this frame draws the player at the
        // new position under a camera still centered on the old one — a
        // one-frame glitch where the player appears jumped/shifted before the
        // camera catches up next frame. computeCamera is cheap; recompute it
        // here so render never lags the state by a frame. The view region is
        // recomputed too — panels can open/close mid-drain (UiState writes
        // are immediate), and the clamp must match the state being drawn.
        const render_view_region = view_mod.cameraViewRegion(
            &history.current_state,
            backend.fontMetrics(),
            camera_zoom,
        );
        const render_camera = view_mod.computeCamera(&history.current_state, camera_zoom, history.session.camera_pan, render_view_region);
        _ = frame_state.frame_arena.reset(.retain_capacity);
        // Per-frame lookup of entity-sprite top-y (topmost non-transparent
        // pixel), so `view()` can place floating indicators above the actual
        // art top. Built here (not in `view()`) because `view()` is pure /
        // raylib-free — the backend owns the decode + cache (same shape as
        // the outline-mask cache). Keyed by bare sprite stem; `view()` looks
        // up `entity.sprite`. Frame-arena-backed (no deinit). See DESIGN →
        // Animation.
        var sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds) = .{};
        const frame_alloc = frame_state.frame_arena.allocator();
        if (history.current_state.level) |*level| {
            for (level.entities) |*entity| {
                if (sprite_bounds.contains(entity.sprite)) continue;
                const bounds = backend.entitySpriteBounds(frame_alloc, entity.sprite);
                sprite_bounds.put(frame_alloc, entity.sprite, bounds) catch
                    @panic("failed to populate sprite_bounds");
            }
        } else if (history.current_state.hub) |*hub| {
            const hub_entity_count = 1 + hub.npcs.len;
            const hub_entity_ptrs = frame_alloc.alloc(*const types.Entity, hub_entity_count) catch
                @panic("failed to alloc hub entity pointer slice");
            hub_entity_ptrs[0] = &hub.player;
            for (hub.npcs, 0..) |*npc, index| hub_entity_ptrs[index + 1] = &npc.entity;
            for (hub_entity_ptrs) |entity| {
                if (sprite_bounds.contains(entity.sprite)) continue;
                const bounds = backend.entitySpriteBounds(frame_alloc, entity.sprite);
                sprite_bounds.put(frame_alloc, entity.sprite, bounds) catch
                    @panic("failed to populate sprite_bounds");
            }
        } else if (history.current_state.editor) |*editor| {
            // Edit mode: the player template + the entity palette types (the
            // editor scene projects those sprites). Mission-wide palette
            // sizes are small, so no per-active-level filtering.
            if (editor.levels.len > 0) {
                var templates: std.ArrayList(*const types.Entity) = .empty;
                templates.append(frame_alloc, &editor.player_def.template) catch
                    @panic("failed to collect editor entity templates");
                for (editor.entity_types) |*type_definition| {
                    templates.append(frame_alloc, &type_definition.template) catch
                        @panic("failed to collect editor entity templates");
                }
                for (templates.items) |entity| {
                    if (sprite_bounds.contains(entity.sprite)) continue;
                    const bounds = backend.entitySpriteBounds(frame_alloc, entity.sprite);
                    sprite_bounds.put(frame_alloc, entity.sprite, bounds) catch
                        @panic("failed to populate sprite_bounds");
                }
            }
        }
        frame_state.previous_view_state = view_mod.view(
            &history.current_state,
            &history.session,
            history.settings,
            history.color_theme_definitions,
            history.weapon_type_definitions,
            .{
                .camera = render_camera,
                .camera_zoom = camera_zoom,
                .event_history = history.event_history.items,
                .level_start_index = history.levelStartEventIndex(),
                .current_event_index = history.current_event_index,
                .frame_allocator = frame_alloc,
                .font_metrics = backend.fontMetrics(),
                .sprite_bounds = sprite_bounds,
                .can_undo = history.canUndo(),
                .can_redo = history.canRedo(),
            },
        );
        backend.render(frame_state.previous_view_state.?, platform_input.viewport);

        // Advance last_render to the most recent ideal frame boundary so the
        // schedule never drifts — a slightly-late frame self-corrects on the
        // next, and a long hitch skips missed frames (no burst-rendering)
        // while staying phase-aligned. `elapsed % interval` is how far past
        // the last ideal boundary we are; subtract it from `now`.
        const elapsed = now - frame_state.last_render_time;
        frame_state.last_render_time = if (render_interval == 0)
            now
        else
            now - (elapsed % render_interval);
    }
}

/// Native driver: a blocking while-loop that calls frame() each iteration and
/// yields (sleeps ~0.1ms) when idle so the loop doesn't busy-spin at 100% CPU.
/// The web driver (web.zig) replaces this with
/// emscripten_set_main_loop(frame_callback, -1, true) — the browser schedules
/// frames and handles yielding, so no sleep is needed there. Both drivers call
/// the SAME frame() function, so gameplay outcome is identical across platforms.
fn gameLoop(backend: anytype, frame_state: *FrameState) void {
    // Idle/wait yield: when the stack is empty OR a wait is active, there's no
    // event-drain work to do — only the wait timer (drained by real-clock
    // deltas on wake) and anytime input (undo/redo/options, handled every
    // frame()) need attention. Sleep briefly so the loop doesn't busy-spin at
    // 100% CPU. 0.1ms keeps input latency ~0.1ms (well under a 60Hz frame) at
    // ~10% CPU on one core. During active event drains the loop spins freely
    // (useful work, no yield). Web doesn't sleep at all — the browser's rAF
    // scheduling IS the yield.
    const idle_yield_seconds: f64 = 0.0001; // 0.1ms — see DESIGN → Platform Seam (idle yield)
    // Exit conditions: the window's close button OR a requested quit (the
    // main-menu options menu's Exit Game — native only; web never sets it).
    // The run() defers flush pending writes + diagnostics on the way out.
    while (!backend.shouldClose() and !frame_state.history.session.quit_requested) {
        frame(backend, frame_state);
        if (frame_state.history.current_state.event_stack.len == 0 or
            frame_state.history.current_state.waiting != null)
        {
            backend.waitTime(idle_yield_seconds);
        }
    }
}

/// Load a session-log BUNDLE from `path` (cwd-relative or absolute; a
/// directory containing `session_log.txt` + `content/` — see
/// session_log_bundle.zig) and reconstruct the session from its event
/// history, resuming at the end of the log. Used by the native `--replay
/// <path>` CLI flag. Raylib-free so it's unit-testable.
///
/// The bundle's embedded content pre-populates the reconstruction cache, so
/// the replay is AUTHORITATIVE: the exact bytes the original session read
/// (the autosave it loaded, the mission files as they were then) are what
/// the reconstruction applies, regardless of what the files on disk say
/// now.
///
/// Recoverable: on any load failure (bundle missing, session_log.txt
/// corrupt, unsupported `file_format_version`, missing/tampered content
/// copy), sets a dismissible `pending_error` popup and returns WITHOUT
/// reconstructing — the game falls back to the seeded main-menu state the
/// caller already set up. Reconstruction divergence still panics per the
/// replay-verification policy; with the content embedded, a divergence is a
/// real bug, not a changed file. See DESIGN → Logging & Replay.
pub fn loadAndReconstructSession(
    history: *state.GameStateHistory,
    path: []const u8,
    io: std.Io,
) void {
    const allocator = history.history_arena.allocator();
    const bundle = session_log_bundle.loadSessionLogBundle(std.Io.Dir.cwd(), path, io, allocator) catch |err| {
        const msg = std.fmt.allocPrint(
            allocator,
            "Could not load replay bundle '{s}': {s}",
            .{ path, @errorName(err) },
        ) catch "failed to format replay load error";
        history.session.setPendingError(allocator, msg);
        return;
    };
    input_handlers.warnIfSessionLogFromDifferentBuild(bundle.log.game_version);
    // Populate the cache from the bundle's embedded copies (manifest order
    // preserved), then replay authoritatively — every reconstruction read
    // serves the bundle's bytes.
    history.loadReconstructionCache(bundle.cache_entries);
    history.reconstructFromEventLog(
        bundle.log.events,
        @intCast(bundle.log.events.len),
        &event_handlers.processEvent,
        .authoritative,
    );
}

/// Entry point shared by every platform: drive the backend-driven game loop
/// against a session the caller has already set up. The caller (native.zig /
/// web.zig) builds the `SessionSetup` via `session_setup.createSessionSetup`,
/// places it in a stable location, and calls `fixupPointers()` before handing
/// it here. The `backend` provides window/clock/input/rendering (see
/// gameLoop). Never called from wasm/test builds, so this stays out of the
/// raylib-free compiles even though it is `pub`.
pub fn run(
    backend: anytype,
    setup: *session_setup.SessionSetup,
) void {
    defer setup.frame_state.frame_arena.deinit();
    crash_dump.install(&setup.frame_state.history);
    defer crash_dump.uninstall();
    // Shutdown safety net: flush any pending debounced writes (e.g. settings
    // changed moments before quit) so a quick change-then-exit isn't lost.
    // Runs before the arena deinit. See DESIGN → Input.
    defer setup.frame_state.history.session.flushPendingWrites(&setup.frame_state.history);
    defer setup.frame_state.history.session.pending_sounds.deinit(setup.frame_state.history.backing_allocator);
    defer setup.frame_state.history.session.pending_anims.deinit(setup.frame_state.history.backing_allocator);
    defer setup.frame_state.history.session.active_anims.deinit(setup.frame_state.history.backing_allocator);
    defer setup.frame_state.history.session.last_number_start_by_entity.deinit(setup.frame_state.history.backing_allocator);
    gameLoop(backend, &setup.frame_state);
}


/// Drive event processing until the stack empties (test harness: no update()
/// loop, so waits are cleared rather than timed). Mirrors the live gameLoop's
/// idle bookkeeping: on stack-empty, recordIdlePoint (snapshot + compact), so
/// a forward-played session accumulates the same idle points the live loop
/// would — which reconstruction then derives from virtual depth.
fn runToIdle(history: *GameStateHistory) void {
    while (history.current_state.event_stack.len > 0) {
        event_handlers.processEvent(history);
        if (history.load_error) @panic("runToIdle: handler set load_error (test content should be valid)");
        history.current_state.waiting = null;
    }
    history.recordIdlePoint();
}

/// Minimal duck-typed backend for the `applyRenderResolutionSetting` tests:
/// records the apply + whether it succeeded (the helper only needs
/// `applyRenderResolution`).
const FakeRenderBackend = struct {
    fail: bool = false,
    applied: ?types.RenderResolution = null,
    apply_count: usize = 0,

    fn applyRenderResolution(self: *FakeRenderBackend, resolution: types.RenderResolution) bool {
        self.applied = resolution;
        self.apply_count += 1;
        return !self.fail;
    }
};

test "countActiveEnemies: alive + aggro'd + enemy-team only, null level is 0" {
    // The music intensity projection (see DESIGN → Audio — layered music).
    var entities = [_]types.Entity{
        .{ .team = 0, .current_health = 10, .is_active = true }, // player
        .{ .team = 1, .current_health = 10, .is_active = true }, // active enemy
        .{ .team = 1, .current_health = 10, .is_active = false }, // not aggroed
        .{ .team = 1, .current_health = 0, .is_active = true }, // dead
        .{ .team = 2, .current_health = 10, .is_active = true }, // second enemy team counts
        .{ .team = 0, .current_health = 10, .is_active = true }, // helper, player team
    };
    var level: types.Level = .{};
    level.entities = &entities;
    var game_state = state.GameState{
        .screen = .level,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = level,
        .hub = null,
    };
    game_state.level = level;
    try std.testing.expectEqual(@as(u32, 2), countActiveEnemies(&game_state));

    // No level (hub, main menu) — nothing to project.
    game_state.level = null;
    try std.testing.expectEqual(@as(u32, 0), countActiveEnemies(&game_state));
}

test "applyRenderResolutionSetting: applies on diff, snapshot follows, no-op without one" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var harness = test_harness.Harness.init(arena);
    var history = harness.newHistory(null);

    // The snapshot starts in sync with the backend's init-time target (both
    // default) — the harness settings load the same default.
    try std.testing.expectEqual(types.default_render_resolution, history.session.last_applied_render_resolution);

    // No diff → no backend call.
    var backend = FakeRenderBackend{};
    applyRenderResolutionSetting(&backend, &history);
    try std.testing.expectEqual(@as(?types.RenderResolution, null), backend.applied);

    // Diff → backend called, snapshot updated, no error popup.
    history.settings.render_resolution = .p2160;
    applyRenderResolutionSetting(&backend, &history);
    try std.testing.expectEqual(@as(?types.RenderResolution, .p2160), backend.applied);
    try std.testing.expectEqual(types.RenderResolution.p2160, history.session.last_applied_render_resolution);
    try std.testing.expect(history.session.pendingError() == null);
}

test "applyRenderResolutionSetting: failed apply reverts the setting + popup, no retry loop" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var harness = test_harness.Harness.init(arena);
    var history = harness.newHistory(null);

    var backend = FakeRenderBackend{ .fail = true };
    history.settings.render_resolution = .p2160;
    applyRenderResolutionSetting(&backend, &history);

    // The setting reverts to the currently-running preset; the snapshot
    // (and the backend's actual target) never moved.
    try std.testing.expectEqual(types.default_render_resolution, history.settings.render_resolution);
    try std.testing.expectEqual(types.default_render_resolution, history.session.last_applied_render_resolution);

    // The popup names both the requested and the kept preset.
    const message = history.session.pendingError() orelse return error.ExpectedPendingError;
    try std.testing.expect(std.mem.indexOf(u8, message, "2160p") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "1080p") != null);

    // Setting now matches the snapshot → a second frame does not retry.
    applyRenderResolutionSetting(&backend, &history);
    try std.testing.expectEqual(@as(usize, 1), backend.apply_count);
}

test "session log round-trips through reconstruction (forward play == replay)" {
    const allocator = std.testing.allocator;

    // One arena backs the whole test: every sub-arena the histories spin up is
    // freed at once, so no GameStateHistory deinit is needed.
    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    // Forward-play a short scripted session (main menu -> new game -> hub ->
    // one hub move) into history1, recording events as it goes.
    var history1 = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history1);
    event_push.pushEvents(&history1.current_state, &.{.{ .player_input_event = .start_new_game }}, history1.current_arena.allocator());
    runToIdle(&history1);
    event_push.pushEvents(&history1.current_state, &.{.{ .player_input_event = .{ .move_player = .{ .destination = .{ .x = 1, .y = 0 } } } }}, history1.current_arena.allocator());
    runToIdle(&history1);
    try std.testing.expectEqual(state.Screen.hub, history1.current_state.screen);

    // Serialize -> parse -> load the recorded history.
    const body = try session_log.writeEventLog(history1.event_history.items, "20260101_000000", arena);
    const sections = try parser.parseConfigFile(body, arena);
    const log = try session_log.loadEventLog(sections, arena);
    input_handlers.warnIfSessionLogFromDifferentBuild(log.game_version); // same build -> silent

    // Reconstruct into a fresh history2 from the loaded log and compare the
    // final states: faithful reconstruction means replay == forward play.
    var history2 = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    history2.reconstructFromEventLog(log.events, @intCast(log.events.len), &event_handlers.processEvent, .lazy_disk);

    try std.testing.expectEqualDeep(history1.current_state, history2.current_state);

    // Virtual-depth reconstruction must derive the SAME idle points the live
    // loop recorded (not serialized — derived from the event stream). This is
    // what makes a loaded session undo/redo "as if played live".
    try std.testing.expectEqualSlices(
        u32,
        history1.idle_points.items,
        history2.idle_points.items,
    );

    // Undo on the reconstructed session should walk back through the derived
    // idle points to the start, mirroring live play. Reconstruct to the end
    // lands at the last idle point; undoing reaches index 0.
    try std.testing.expectEqual(
        history2.idle_points.items.len - 1,
        history2.current_idle_index,
    );
    while (history2.undo(&event_handlers.processEvent)) {}
    try std.testing.expectEqual(@as(u32, 0), history2.current_idle_index);
}

test "loadAndReconstructSession: resumes at the end of a loaded bundle" {
    // The --replay CLI path reads a session-log BUNDLE from disk and
    // reconstructs the session from its event history, landing at the end
    // of the log. This mirrors the round-trip test above but exercises the
    // real artifact path (`writeSessionLogBundle` → `loadAndReconstructSession`)
    // instead of calling `reconstructFromEventLog` directly: forward-play a
    // session, write its bundle, load + reconstruct into a fresh history,
    // assert the final state matches forward play — including the embedded
    // reconstruction cache (the authoritative-replay input). See DESIGN →
    // Logging & Replay.
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir: history1's reconstruction reads fall through
    // to the embedded map, and the bundle lands under zig-cache (not the
    // project cwd).
    const scratch = "zig-cache/test-recon-load";
    const scratch_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, scratch_dir);

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    // Forward-play a short session (main menu -> new game -> hub -> one hub
    // move) into history1.
    var history1 = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history1);
    event_push.pushEvents(&history1.current_state, &.{.{ .player_input_event = .start_new_game }}, history1.current_arena.allocator());
    runToIdle(&history1);
    event_push.pushEvents(&history1.current_state, &.{.{ .player_input_event = .{ .move_player = .{ .destination = .{ .x = 1, .y = 0 } } } }}, history1.current_arena.allocator());
    runToIdle(&history1);
    try std.testing.expectEqual(state.Screen.hub, history1.current_state.screen);

    // Serialize the session as a bundle (the artifact the CLI consumes):
    // session_log.txt + the content copies of everything it read.
    try session_log_bundle.writeSessionLogBundle(
        &file_source,
        history1.event_history.items,
        history1.reconstruction_cache.items,
        "logs/test_bundle",
        "20260101_000000",
        arena,
    );

    // The motivating regression: the file the session read CHANGES between
    // record and replay. Here the mutation rides the mod-shadowing seam —
    // a persistent-dir copy of data/new_player.txt that overrides the
    // embedded map (the in-game case is the autosave: overwritten by every
    // later session). Under the old lazy-disk fallback the replay would
    // read the shadow and diverge (verifyReplayMatch panic); the bundle's
    // embedded copy keeps the replay exact. The shadow must stay parseable,
    // so it's derived from the real bytes (the name field differs).
    const real_new_player = file_source.readFile(arena, "data/new_player.txt") catch
        @panic("read new_player for shadow");
    const shadow_new_player = try std.mem.replaceOwned(
        u8,
        arena,
        real_new_player,
        "player_name New Player",
        "player_name Shadow Player",
    );
    try std.testing.expect(shadow_new_player.len != real_new_player.len);
    try scratch_dir.createDirPath(io, "data");
    try scratch_dir.writeFile(io, .{
        .sub_path = "data/new_player.txt",
        .data = shadow_new_player,
    });

    // Load + reconstruct into a fresh history2 via the CLI glue (the
    // cwd-relative path to the bundle dir under the scratch tree).
    var history2 = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    loadAndReconstructSession(&history2, "zig-cache/test-recon-load/logs/test_bundle", io);

    // No pending error (a clean load surfaces no popup).
    try std.testing.expect(history2.session.pendingError() == null);
    // The reconstructed final state matches forward play.
    try std.testing.expectEqualDeep(history1.current_state, history2.current_state);
    // The reconstructed idle points match (undo/redo works as if played live).
    try std.testing.expectEqualSlices(u32, history1.idle_points.items, history2.idle_points.items);
    // The embedded reconstruction cache came through whole: the
    // authoritative replay ran on exactly the recorded reads.
    try std.testing.expectEqual(
        history1.reconstruction_cache.items.len,
        history2.reconstruction_cache.items.len,
    );
}

test "loadAndReconstructSession: missing file sets pending_error, stays at main menu" {
    // A bad --replay path is recoverable: the game surfaces a dismissible
    // popup and falls back to the seeded main-menu state instead of
    // crashing. The history is left untouched (still at the initial seed).
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);

    loadAndReconstructSession(&history, "zig-cache/nonexistent-replay-bundle", io);

    // A pending error popup is set (the dismissible warning).
    try std.testing.expect(history.session.pendingError() != null);
    // The state is unchanged from the seed — still at the main menu.
    try std.testing.expectEqual(state.Screen.main_menu, history.current_state.screen);
    try std.testing.expectEqual(@as(u32, 0), history.current_event_index);
}

test "reconstruction with wait events: undo/redo reversible, no stale waiting" {
    // Regression: `replayToWithIdleTracking` used to leave `waiting` set
    // during its replay loop (the wait MetaEvent sets it, but replay is
    // instant with no timer drain to clear it). Snapshots taken at
    // stack-empty moments after a wait event captured `waiting = true`,
    // breaking the live-loop invariant (idle-point snapshots never carry
    // `waiting`). On undo, `restoreTo`'s fast path restored that buggy
    // snapshot, and `undo`'s mid-drain special case (`waiting != null`)
    // spun on the same idle point — undo appeared "swallowed" and redo
    // history was eaten by `discardFutureTimeline` on each spin.
    //
    // This test forward-plays a session that includes enemy turns (which
    // push wait MetaEvents), serializes, reconstructs, and asserts:
    //   1. `waiting == null` after reconstruction (the final clear works).
    //   2. Undo advances `current_idle_index` each step (not stuck).
    //   3. Undo + redo returns to the same state (reversible).
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    // Forward-play the real game flow: main menu → start_new_game (player
    // action) → hub → move_player onto a mission exit tile (player action
    // that pushes start_mission + end_hub as handler children) → level.
    // Then move the player adjacent to an enemy and skip the turn to trigger
    // enemy turns with wait events. Every top-level event is a player action,
    // so reconstruction's isPlayerAction gate accepts them.
    var history1 = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history1);
    event_push.pushEvents(&history1.current_state, &.{.{ .player_input_event = .start_new_game }}, history1.current_arena.allocator());
    runToIdle(&history1);
    try std.testing.expectEqual(state.Screen.hub, history1.current_state.screen);

    // Find the beginnings mission exit tile in the hub and move the player
    // onto it (move_player is a player action; landing on the exit pushes
    // start_mission + end_hub as handler children).
    const hub = &history1.current_state.hub.?;
    var beginnings_exit: ?types.Vector2 = null;
    for (hub.mission_exits) |exit| {
        if (std.mem.eql(u8, exit.mission_id, "beginnings")) {
            beginnings_exit = exit.position;
            break;
        }
    }
    try std.testing.expect(beginnings_exit != null);
    event_push.pushEvents(&history1.current_state, &.{.{ .player_input_event = .{ .move_player = .{
        .destination = beginnings_exit.?,
    } } }}, history1.current_arena.allocator());
    runToIdle(&history1);
    try std.testing.expectEqual(state.Screen.level, history1.current_state.screen);

    // The player starts out of aggro range of every enemy, so skipping the
    // turn alone won't trigger enemy turns (enemies are inactive until
    // aggro_check activates them). Walk the player toward the nearest enemy
    // one step at a time (player_move_action pathfinds one step per turn)
    // until the enemy aggros. Then skip the turn to trigger enemy turns with
    // wait events. Each player_move_action is a player action that
    // reconstruction accepts.
    const enemy_pos = history1.current_state.level.?.entities[1].position;
    var aggroed = false;
    var walk_steps: u32 = 0;
    while (!aggroed and walk_steps < 10) : (walk_steps += 1) {
        const player_pos = history1.current_state.level.?.entities[0].position;
        // Step one tile toward the enemy (Chebyshev neighbor): sign(dx), sign(dy).
        const sign = struct {
            fn of(v: i32) i32 {
                if (v > 0) return 1;
                if (v < 0) return -1;
                return 0;
            }
        }.of;
        const step: types.Vector2 = .{
            .x = player_pos.x + sign(enemy_pos.x - player_pos.x),
            .y = player_pos.y + sign(enemy_pos.y - player_pos.y),
        };
        event_push.pushEvents(&history1.current_state, &.{.{ .player_input_event = .{ .player_move_action = .{
            .destination = step,
        } } }}, history1.current_arena.allocator());
        runToIdle(&history1);
        aggroed = history1.current_state.level.?.entities[1].is_active;
    }
    try std.testing.expect(aggroed);

    // Skip the player's move + attack to end the turn → enemy turns drain
    // (pushing wait events) → turn_start for the next player turn.
    event_push.pushEvents(&history1.current_state, &.{.{ .player_input_event = .{ .player_skip_move = .{} } }}, history1.current_arena.allocator());
    runToIdle(&history1);
    if (history1.current_state.level.?.turn_phase == .player_attack) {
        event_push.pushEvents(&history1.current_state, &.{.{ .player_input_event = .player_skip_attack }}, history1.current_arena.allocator());
        runToIdle(&history1);
    }

    // Confirm the session actually included wait events (enemy turns fired).
    var has_wait = false;
    for (history1.event_history.items) |event| {
        if (event == .meta_event and event.meta_event == .wait) {
            has_wait = true;
            break;
        }
    }
    try std.testing.expect(has_wait);

    // Serialize → reconstruct into a fresh history.
    const body = try session_log.writeEventLog(history1.event_history.items, "20260101_000000", arena);
    const sections = try parser.parseConfigFile(body, arena);
    const log = try session_log.loadEventLog(sections, arena);

    var history2 = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    history2.reconstructFromEventLog(log.events, @intCast(log.events.len), &event_handlers.processEvent, .lazy_disk);

    // (1) No stale `waiting` after reconstruction.
    try std.testing.expect(history2.current_state.waiting == null);
    // Final state matches forward play.
    try std.testing.expectEqualDeep(history1.current_state, history2.current_state);

    // (2) Undo advances the idle index each step (not stuck). Undo a few
    // steps and confirm the index strictly decreases each time.
    const start_idle_idx = history2.current_idle_index;
    const start_event_idx = history2.current_event_index;
    var prev_idle_idx = start_idle_idx;
    var undo_steps: u32 = 0;
    while (undo_steps < 4 and history2.undo(&event_handlers.processEvent)) {
        undo_steps += 1;
        try std.testing.expect(history2.current_idle_index < prev_idle_idx);
        try std.testing.expect(history2.current_state.waiting == null);
        prev_idle_idx = history2.current_idle_index;
    }
    try std.testing.expect(undo_steps > 0); // at least one undo worked

    // (3) Redo back to the start — reversible. Each redo strictly increases
    // the idle index, and the final state matches the pre-undo state.
    var redo_steps: u32 = 0;
    while (redo_steps < undo_steps and history2.redo(&event_handlers.processEvent)) {
        redo_steps += 1;
        try std.testing.expect(history2.current_state.waiting == null);
    }
    try std.testing.expectEqual(redo_steps, undo_steps);
    try std.testing.expectEqual(start_idle_idx, history2.current_idle_index);
    try std.testing.expectEqual(start_event_idx, history2.current_event_index);
}

test "replay verification: clean replay through the slow path passes" {
    // The natural-stack replay loops (state.zig) verify before each dispatch
    // that the event about to run (stack top) matches the recorded stream.
    // On undo/redo the slow path (restoreTo -> replayTo) only fires when no
    // exact snapshot exists, so here we force it: forward-play a session, then
    // NULL every snapshot + checkpoint so any undo/redo replays the whole
    // history from initial_state. A clean replay must verify every event
    // without tripping the panic — this is the positive integration proof
    // that the check is wired and sound. (A tampered event_history would trip
    // the panic; deepEqual/firstDiffField unit tests in deep_copy.zig prove
    // the comparison detects that.)
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);
    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .start_new_game }}, history.current_arena.allocator());
    runToIdle(&history);
    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .{ .move_player = .{ .destination = .{ .x = 1, .y = 0 } } } }}, history.current_arena.allocator());
    runToIdle(&history);
    try std.testing.expectEqual(state.Screen.hub, history.current_state.screen);

    // Evict every restore point so undo/redo take the replay slow path.
    for (&history.snapshots) |*slot| slot.* = null;
    for (&history.checkpoints) |*slot| slot.* = null;

    // Undo back to the start: each step replays from initial_state through
    // every event up to the target idle point, running verifyReplayMatch on
    // each. A clean replay must not panic.
    while (history.undo(&event_handlers.processEvent)) {}
    try std.testing.expectEqual(@as(u32, 0), history.current_idle_index);

    // Redo forward to the end: same slow-path replay + verification.
    while (history.redo(&event_handlers.processEvent)) {}
    try std.testing.expectEqual(
        history.idle_points.items.len - 1,
        history.current_idle_index,
    );
    try std.testing.expectEqual(state.Screen.hub, history.current_state.screen);
}

test "ported campaign missions load through the event path" {
    // The 4 designed missions ported from the Unity project (beginnings,
    // forest, wetlands, seatown) plus the Camp at the Crossroads hub must
    // load end-to-end through the event path — not just the parser. Each
    // start_mission reads mission.txt + level_1.txt via the reconstruction
    // cache, transitions to .level, and instantiates entities. This catches
    // mission/hub wiring + level loading issues that parser-only tests miss.
    const allocator = std.testing.allocator;
    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    const missions = [_]struct { path: []const u8, min_entities: usize }{
        .{ .path = "data/campaigns/main_campaign/missions/beginnings", .min_entities = 2 },
        .{ .path = "data/campaigns/main_campaign/missions/forest", .min_entities = 2 },
        .{ .path = "data/campaigns/main_campaign/missions/wetlands", .min_entities = 2 },
        .{ .path = "data/campaigns/main_campaign/missions/seatown", .min_entities = 2 },
    };
    for (missions) |mission| {
        // Fresh history per mission so each load is independent.
        var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
        runToIdle(&history);
        event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .start_mission = .{
            .mission_path = mission.path,
            .start_hub_id = null,
            .end_hub_id = null,
        } } }}, history.current_arena.allocator());
        runToIdle(&history);
        try std.testing.expectEqual(state.Screen.level, history.current_state.screen);
        const level = history.current_state.level orelse return error.expectedLevel;
        // Player (entity 0) + at least one enemy.
        try std.testing.expect(level.entities.len >= mission.min_entities);
        try std.testing.expect(history.current_state.mission != null);
    }
}

test "reconstruction cache: undo replay reads original bytes after the file is overwritten" {
    // The reconstruction cache makes replay deterministic regardless of later
    // file changes (the editor-saves-overwrite-mid-session case). A live
    // reconstruction read caches its bytes; a replay of that event returns the
    // cached bytes, not whatever is on disk now. This is the within-session
    // guarantee; cross-session replay pre-populates the cache from a
    // session-log bundle (see session_log_bundle.zig).
    const allocator = std.testing.allocator;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir under the project's zig-cache so it's writable
    // and easy to clean up. FileSource reads hit this dir first (no embedded
    // override for a non-data/non-assets path).
    const scratch_path = "zig-cache/test-recon-cache";
    const persistent_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch_path) catch {};
    const file_source = FileSource.init(io, persistent_dir);

    // Write version 1 of a custom file (not under data//assets/ so writeFile accepts it).
    file_source.writeFile("custom_mission.txt", "version1") catch @panic("failed to write v1");

    // Minimal history: readReconstructionFile touches current_event_index,
    // replaying, reconstruction_disk_fallback, reconstruction_cache, history_arena,
    // and file_source — the rest is left undefined (the method never reads it).
    var history: GameStateHistory = undefined;
    history.backing_allocator = allocator;
    history.history_arena = std.heap.ArenaAllocator.init(allocator);
    defer history.history_arena.deinit();
    history.reconstruction_cache = .empty;
    history.file_source = &file_source;
    history.replaying = false;
    history.reconstruction_disk_fallback = false;

    // Simulate a live reconstruction read at event index 0: processEvent
    // increments current_event_index to 1 before dispatching the handler, so
    // the event under handling is at index 0 = current_event_index - 1.
    history.current_event_index = 1;
    const live_bytes = history.readReconstructionFile("custom_mission.txt") catch
        @panic("failed to read reconstruction file in test");
    try std.testing.expectEqualStrings("version1", live_bytes);

    // Overwrite the file on disk (e.g. an editor save) with different bytes.
    file_source.writeFile("custom_mission.txt", "version2") catch @panic("failed to write v2");

    // Replay the same event: replaying=true, same event index. Must return the
    // CACHED version1 bytes, not the new version2 on disk.
    history.replaying = true;
    history.current_event_index = 1;
    const replayed_bytes = history.readReconstructionFile("custom_mission.txt") catch
        @panic("failed to read reconstruction file in test");
    try std.testing.expectEqualStrings("version1", replayed_bytes);
}

test "editor building blocks: open -> playtest -> end -> close round-trips" {
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);

    // Open the editor on the shipped beginnings mission.
    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .{ .open_editor = .{
        .mission_path = "data/campaigns/main_campaign/missions/beginnings",
    } } }}, history.current_arena.allocator());
    runToIdle(&history);

    // Editor is populated: screen is .editor, mission loaded, levels array
    // has the mission's level_count entries, mode is .edit. The palette is
    // reference-based: beginnings' level_1 has one enemy type (Skeleton
    // Warrior at char '1') placed three times, so entity_types has one entry
    // and level 0 has three placements referencing it. player_def carries
    // the player loadout from player.txt.
    try std.testing.expectEqual(state.Screen.editor, history.current_state.screen);
    try std.testing.expect(history.current_state.editor != null);
    const editor = &history.current_state.editor.?;
    try std.testing.expectEqual(@as(usize, 3), editor.levels.len); // beginnings has 3 levels
    try std.testing.expectEqual(types.EditorMode.edit, editor.mode);
    try std.testing.expectEqual(@as(usize, 2), editor.entity_types.len); // two enemy types (Skeleton Warrior + Javelineer, mission-wide palette)
    try std.testing.expectEqual(@as(usize, 3), editor.levels[0].entity_placements.len);
    try std.testing.expectEqual(@as(u32, 0), editor.levels[0].entity_placements[0].type_id);
    // Ground items: mission-wide item palette. beginnings level_1 authors one
    // ground item (Comfortable Boots at 'a' — raw (3,6), (0,2) spawn-relative),
    // level_2 another (Bamboo Spear) — two distinct types; level 0 has one
    // placement. Level files author one item per stack (one layout char per
    // item), so one placement per stack here.
    try std.testing.expectEqual(@as(usize, 2), editor.item_types.len);
    try std.testing.expectEqualStrings("Comfortable Boots", editor.item_types[0].id);
    try std.testing.expectEqualStrings("Bamboo Spear", editor.item_types[1].id);
    try std.testing.expectEqual(@as(usize, 1), editor.levels[0].item_placements.len);
    try std.testing.expectEqual(@as(u32, 0), editor.levels[0].item_placements[0].type_id);
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 2 }, editor.levels[0].item_placements[0].position);
    try std.testing.expect(std.mem.eql(u8, "Player", editor.player_def.template.name));
    try std.testing.expect(std.mem.eql(u8, "player", editor.player_def.template.sprite));

    // Start a playtest on level 0.
    event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .start_playtest = .{
        .level_index = 0,
    } } }}, history.current_arena.allocator());
    runToIdle(&history);

    // Gameplay is live: screen is .level, current.level populated (entity 0
    // = player from player_def at the '!', entities 1-3 = the three skeleton
    // placements of the palette type), editor dormant with mode .playtest.
    try std.testing.expectEqual(state.Screen.level, history.current_state.screen);
    try std.testing.expect(history.current_state.level != null);
    try std.testing.expectEqual(@as(usize, 4), history.current_state.level.?.entities.len); // player + 3 enemies
    try std.testing.expect(std.mem.eql(u8, "Player", history.current_state.level.?.entities[0].name));
    try std.testing.expect(std.mem.eql(u8, "skeleton_1", history.current_state.level.?.entities[1].sprite));
    try std.testing.expectEqual(types.EditorMode.playtest, history.current_state.editor.?.mode);
    try std.testing.expect(history.current_state.editor != null); // dormant, not cleared
    // The instantiated level carries the ground-item placements as stacks:
    // one boots stack at the 'a' position.
    try std.testing.expectEqual(@as(usize, 1), history.current_state.level.?.ground_items.len);
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 2 }, history.current_state.level.?.ground_items[0].position);
    try std.testing.expectEqual(@as(usize, 1), history.current_state.level.?.ground_items[0].items.len);
    try std.testing.expectEqualStrings("Comfortable Boots", history.current_state.level.?.ground_items[0].items[0].boots.name);

    // End the playtest (simulating the player completing the level — in live
    // play, end_level's guard pushes end_playtest; here we push it directly).
    event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .end_playtest }}, history.current_arena.allocator());
    runToIdle(&history);

    // Back in the editor: screen .editor, level + mission cleared (discard
    // semantics), mode .edit, editor's levels array untouched.
    try std.testing.expectEqual(state.Screen.editor, history.current_state.screen);
    try std.testing.expect(history.current_state.level == null);
    try std.testing.expect(history.current_state.mission == null);
    try std.testing.expectEqual(types.EditorMode.edit, history.current_state.editor.?.mode);
    try std.testing.expectEqual(@as(usize, 3), history.current_state.editor.?.levels.len);

    // Close the editor.
    event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .close_editor }}, history.current_arena.allocator());
    runToIdle(&history);
    try std.testing.expectEqual(state.Screen.main_menu, history.current_state.screen);
    try std.testing.expect(history.current_state.editor == null);
}

test "fresh editor open: empty New Mission, template level, playtest round-trip" {
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);

    // The main-menu Editor button's flow: null mission_path = a FRESH
    // empty mission (no uuid — identity is minted at save time, never
    // held in state; see DESIGN → Level Editor → Mission identity).
    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .{
        .open_editor = .{ .mission_path = null },
    } }}, history.current_arena.allocator());
    runToIdle(&history);

    try std.testing.expectEqual(state.Screen.editor, history.current_state.screen);
    const editor = &history.current_state.editor.?;
    try std.testing.expectEqual(types.EditorMode.edit, editor.mode);
    try std.testing.expectEqualStrings("New Mission", editor.mission.name);
    try std.testing.expectEqualStrings("missions/New Mission", editor.mission.path);
    try std.testing.expectEqual(@as(u32, 1), editor.mission.level_count);
    try std.testing.expectEqual(@as(usize, 0), editor.mission.uuid.len);

    // One default-template level: the minimal `!=` layout (the markers
    // carry their own ground — exactly two tiles), unnamed, no placements.
    try std.testing.expectEqual(@as(usize, 1), editor.levels.len);
    const template_level = editor.levels[0];
    try std.testing.expectEqual(@as(usize, 0), template_level.name.len);
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, template_level.player_start);
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, template_level.level_end.?);
    try std.testing.expectEqual(@as(usize, 2), template_level.level_tiles.len);
    try std.testing.expectEqual(@as(usize, 0), template_level.entity_placements.len);
    try std.testing.expectEqual(@as(usize, 0), template_level.decoration_placements.len);
    try std.testing.expectEqual(@as(usize, 0), template_level.item_placements.len);

    // Empty palettes — no tools in any group.
    try std.testing.expectEqual(@as(usize, 0), editor.entity_types.len);
    try std.testing.expectEqual(@as(usize, 0), editor.decoration_types.len);
    try std.testing.expectEqual(@as(usize, 0), editor.item_types.len);

    // player_def is the max-player seed (max_player.txt's player_name).
    try std.testing.expectEqualStrings("New Player", editor.player_def.template.name);
    try std.testing.expectEqualStrings("player", editor.player_def.template.sprite);

    // Playtest the template level: just the player at the '!', the '=' at
    // (1,0), nothing else.
    event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .start_playtest = .{
        .level_index = 0,
    } } }}, history.current_arena.allocator());
    runToIdle(&history);
    try std.testing.expectEqual(state.Screen.level, history.current_state.screen);
    try std.testing.expectEqual(@as(usize, 1), history.current_state.level.?.entities.len);
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, history.current_state.level.?.level_end.?);

    // End + close round-trip.
    event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .end_playtest }}, history.current_arena.allocator());
    runToIdle(&history);
    event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .close_editor }}, history.current_arena.allocator());
    runToIdle(&history);
    try std.testing.expectEqual(state.Screen.main_menu, history.current_state.screen);
    try std.testing.expect(history.current_state.editor == null);
}

test "turn counters: per-mission increments, cumulative skipped in editor mode" {
    // The player's turn_start (entity_index == 0) increments the per-mission
    // turns_spent (scoped to the current playthrough) and the cumulative
    // player_data.turns (lifetime). In editor playtest/validate the
    // cumulative counter is SKIPPED (discard-semantics — the editor session
    // must not inflate the player's real turn count); the per-mission
    // counter still increments (discarded with the mission on exit). This
    // uses the editor playtest path to enter a level and take one turn.
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);

    // Open editor + start playtest on beginnings level 0.
    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .{ .open_editor = .{
        .mission_path = "data/campaigns/main_campaign/missions/beginnings",
    } } }}, history.current_arena.allocator());
    runToIdle(&history);
    event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .start_playtest = .{
        .level_index = 0,
    } } }}, history.current_arena.allocator());
    runToIdle(&history);

    try std.testing.expectEqual(state.Screen.level, history.current_state.screen);
    // The first player turn has BEGUN (turn_start ran in the start drain).
    try std.testing.expectEqual(@as(u32, 1), history.current_state.mission.?.turns_spent);
    try std.testing.expectEqual(@as(u32, 0), history.current_state.player_data.turns);

    // Skip the player's move phase. If enemies are active, this enters the
    // attack phase; if not, auto_skip_attack_step_out_of_combat completes
    // the whole turn (turn_end fires during the drain, and the round
    // builder queues the NEXT turn_start — the second begun turn). The
    // per-mission counter increments again; the cumulative counter does
    // NOT (editor mode).
    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .{ .player_skip_move = .{} } }}, history.current_arena.allocator());
    runToIdle(&history);

    // If auto-skip didn't fire (we're in the attack phase), skip it to
    // complete the turn. If it did fire, we're back in player_move for the
    // next turn — don't push another skip (it would start a second turn).
    if (history.current_state.level.?.turn_phase == .player_attack) {
        event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .player_skip_attack }}, history.current_arena.allocator());
        runToIdle(&history);
    }

    try std.testing.expectEqual(@as(u32, 2), history.current_state.mission.?.turns_spent);
    try std.testing.expectEqual(@as(u32, 0), history.current_state.player_data.turns);

    // End the playtest (discard semantics — counters are discarded with the
    // mission; player_data.turns was never touched).
    event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .end_playtest }}, history.current_arena.allocator());
    runToIdle(&history);
    try std.testing.expectEqual(state.Screen.editor, history.current_state.screen);
}

test "open_editor with a path from inside the editor swaps missions + bumps world_generation" {
    // The mission browser opens an existing mission while ALREADY in the
    // editor: the screen stays .editor, so the driver's transition UI reset
    // only fires if open_editor bumps world_generation (the same signal
    // start_level/start_hub use). Without it, the browser itself (a UiState
    // flag) + stale view state would survive the mission swap.
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir (the shipped content reads come from the
    // embedded map regardless).
    const scratch = "zig-cache/test-open-editor-from-editor";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);

    // Enter the editor with a fresh mission, then swap to beginnings via a
    // path open (the mission browser's row click).
    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .{ .open_editor = .{
        .mission_path = null,
    } } }}, history.current_arena.allocator());
    runToIdle(&history);
    try std.testing.expectEqual(state.Screen.editor, history.current_state.screen);
    const generation_before = history.current_state.world_generation;

    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .{ .open_editor = .{
        .mission_path = "data/campaigns/main_campaign/missions/beginnings",
    } } }}, history.current_arena.allocator());
    runToIdle(&history);

    // The swap landed (Beginnings, three levels) and the screen stayed
    // .editor — but the generation bumped, so the driver's UI reset fires.
    try std.testing.expectEqual(state.Screen.editor, history.current_state.screen);
    try std.testing.expectEqualStrings("Beginnings", history.current_state.editor.?.mission.name);
    try std.testing.expectEqual(@as(u32, 3), history.current_state.editor.?.mission.level_count);
    try std.testing.expectEqual(generation_before + 1, history.current_state.world_generation);
}

test "reconstruction read failure: handler sets load_error, drain loop reverts state + trims history" {
    // A broken mission file (invalid content) causes start_mission's parse
    // to fail. The handler sets load_error + pending_error and returns. The
    // drain loop (simulated here) reverts to the last idle-point snapshot,
    // trims the failed transaction's recorded events, and the popup message
    // survives (it's on SessionState, off GameState). See DESIGN → Error
    // Handling → three contexts.
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir with a broken mission.txt shadow.
    const scratch = "zig-cache/test-recon-read-fail";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Write a broken mission.txt at the beginnings path (shadows the
    // embedded copy). Invalid content → parseConfigFile fails.
    dir.createDirPath(io, "data/campaigns/main_campaign/missions/beginnings") catch
        @panic("failed to create mission dir");
    dir.writeFile(io, .{
        .sub_path = "data/campaigns/main_campaign/missions/beginnings/mission.txt",
        .data = "this is not valid config",
    }) catch @panic("failed to write broken mission");

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);

    // We're at the main menu (idle). Record the pre-action state for later
    // comparison.
    const pre_event_index = history.current_event_index;
    const pre_idle_index = history.current_idle_index;
    try std.testing.expectEqual(@as(?[]const u8, null), history.session.pending_error);

    // Push start_mission pointing at the broken mission.
    event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .start_mission = .{
        .mission_path = "data/campaigns/main_campaign/missions/beginnings",
        .start_hub_id = null,
        .end_hub_id = null,
    } } }}, history.current_arena.allocator());

    // Process one event (start_mission). The parse fails → load_error is set,
    // pending_error is set, and processEvent returns without mutating state
    // further (mission stays null, screen stays main_menu).
    event_handlers.processEvent(&history);
    try std.testing.expect(history.load_error);
    try std.testing.expect(history.session.pending_error != null);
    try std.testing.expect(history.current_state.mission == null);
    try std.testing.expectEqual(state.Screen.main_menu, history.current_state.screen);

    // Simulate the drain loop's revert: restore to the last idle-point
    // snapshot, trim the failed transaction's recorded events, clear the flag.
    history.load_error = false;
    const last_idle_event_index = history.idle_points.items[history.current_idle_index];
    history.restoreTo(last_idle_event_index, &event_handlers.processEvent);
    history.event_history.shrinkRetainingCapacity(history.current_event_index);

    // State is fully reverted: back at the main menu, event index restored,
    // event_history trimmed (the failed start_mission event is gone).
    try std.testing.expectEqual(pre_event_index, history.current_event_index);
    try std.testing.expectEqual(pre_idle_index, history.current_idle_index);
    try std.testing.expectEqual(pre_event_index, history.event_history.items.len);
    try std.testing.expectEqual(state.Screen.main_menu, history.current_state.screen);
    try std.testing.expect(history.current_state.mission == null);

    // The popup message survived the revert (SessionState is off GameState).
    try std.testing.expect(history.session.pending_error != null);
}

test "write_save failure: sets pending_error, no crash, no state corruption" {
    // A write_save event whose target dir parent is a FILE (not a dir)
    // fails on ensureParentDirs (createDirPath can't make a dir where a
    // file exists). The handler surfaces pending_error and returns instead
    // of panicking. State is unchanged (the save just didn't happen — no
    // revert needed for a failed write). See DESIGN → Error Handling.
    const allocator = std.testing.allocator;

    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir with a file at "saves" (so writing to
    // "saves/test_save.txt" fails — ensureParentDirs can't create the
    // "saves" dir because a file with that name exists).
    const scratch = "zig-cache/test-write-save-fail";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    dir.writeFile(io, .{ .sub_path = "saves", .data = "i am a file not a dir" }) catch
        @panic("failed to create blocker file");
    const file_source = FileSource.init(io, dir);

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = session_setup.loadSettingsFromDisk(&file_source, arena, &warnings);
    const weapon_type_definitions = session_setup.loadWeaponTypeDefinitions(&file_source, arena, &warnings);
    const color_theme_definitions = session_setup.loadColorThemeDefinitionsFromDisk(&file_source, arena, &warnings);
    const salvage_definitions = session_setup.loadSalvageDefinitionsFromDisk(&file_source, arena, &warnings);

    const starting_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{ .current_campaign = "test_campaign", .player_name = "Test" },
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    var history = GameStateHistory.init(arena, starting_state, settings, &weapon_type_definitions, color_theme_definitions, salvage_definitions, &file_source, io);
    runToIdle(&history);

    try std.testing.expectEqual(@as(?[]const u8, null), history.session.pending_error);

    // Push write_save to "saves/test_save.txt" — ensureParentDirs tries to
    // create the "saves" dir, fails because "saves" is a file.
    event_push.pushEvents(&history.current_state, &.{.{ .meta_event = .{ .write_save = .{
        .save_path = "saves/test_save.txt",
    } } }}, history.current_arena.allocator());
    event_handlers.processEvent(&history);

    // The write failed → pending_error is set, load_error is NOT (writes
    // don't need a revert — state is fine, just the file didn't write).
    try std.testing.expect(history.session.pending_error != null);
    try std.testing.expect(!history.load_error);

    // State is unchanged — the save didn't happen, but player_data is intact.
    try std.testing.expectEqualStrings("Test", history.current_state.player_data.player_name);

    history.session.clearPendingError();
}

// ───────────────────────── anytime swap_weapons: idle point + wait interjection ─────────────────────────
//
// swap_weapons is an anytime action (handleAnytimeInput). Two bugs were fixed
// together: (1) swapping while idle processed the event but recorded no undo
// stop, so the swap wasn't undoable until the next action absorbed it; (2)
// swapping during an enemy-turn wait sat on the stack until the wait elapsed
// (~500ms delay). The fix: update()'s wait branch drains anytime-interjected
// events down to the wait's baseline_stack_depth (immediate, no delay, no idle
// point — absorbed into the surrounding drain), and frame()'s idle branch
// records an idle point when update() advanced the index and left the stack
// empty with no active wait. These tests exercise update() directly (both
// changes are inside it) and replicate the frame() idle-branch condition for
// the idle-stop assertion.

const three_by_three_tiles = [_]types.Vector2{
    .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
    .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
    .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 },
};

/// A player entity with distinguishable weapons: main = sword (damage 5),
/// off = bow (damage 3). After a swap, main = bow / off = sword.
fn playerWithWeapons() types.Entity {
    return .{
        .team = 0,
        .max_health = 20,
        .current_health = 20,
        .main_hand_weapon = .{ .name = "sword", .weapon_type = .sword, .weapon_damage = 5 },
        .off_hand_weapon = .{ .name = "staff", .weapon_type = .staff, .weapon_damage = 3 },
    };
}

test "anytime swap_weapons while idle: records an undoable idle point" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{playerWithWeapons()},
        &three_by_three_tiles,
    ));
    runToIdle(&history); // records the initial idle point (stack starts empty)

    const idle_count_before = history.idle_points.items.len;
    const event_index_before = history.current_event_index;
    try std.testing.expectEqual(@as(?types.WeaponType, .sword), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);

    // Drive one update() with swap_weapons set — mirrors what frame()'s idle
    // branch does: handleAnytimeInput pushes swap_hands, then update()'s tail
    // processes it (stack non-empty → processEvent), leaving stack empty.
    var player_input: input.PlayerInput = .{};
    player_input.anytime.in_game.swap_weapons = true;
    const camera_zoom = @as(f32, @floatFromInt(history.settings.camera_zoom)) / 100.0;
    const camera = view_mod.computeCamera(&history.current_state, camera_zoom, history.session.camera_pan, null);
    update(&history, player_input, null, 16_000, camera, camera_zoom, .{ .width = 3840, .height = 2160 });

    // The swap processed: weapons are now swapped.
    try std.testing.expectEqual(@as(?types.WeaponType, .staff), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(@as(?types.WeaponType, .sword), history.current_state.level.?.entities[0].off_hand_weapon.?.weapon_type);
    // The swap was recorded into event_history.
    try std.testing.expect(history.current_event_index == event_index_before + 1);
    // Stack is empty, no wait active — the frame() idle-branch condition.
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try std.testing.expect(history.current_state.waiting == null);
    // Replicate frame()'s idle-branch check: index advanced + stack empty +
    // not waiting → record the undo stop.
    if (history.current_event_index != event_index_before and
        history.current_state.event_stack.len == 0 and
        history.current_state.waiting == null)
    {
        history.recordIdlePoint();
    }
    try std.testing.expectEqual(idle_count_before + 1, history.idle_points.items.len);

    // Undo restores the pre-swap weapon arrangement.
    try std.testing.expect(history.undo(&event_handlers.processEvent));
    try std.testing.expectEqual(@as(?types.WeaponType, .sword), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(@as(?types.WeaponType, .staff), history.current_state.level.?.entities[0].off_hand_weapon.?.weapon_type);
}

test "anytime swap_weapons during a wait: handled immediately, no idle point, absorbed" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{playerWithWeapons()},
        &three_by_three_tiles,
    ));
    runToIdle(&history);
    const idle_count_before = history.idle_points.items.len;
    const event_index_before = history.current_event_index;

    // Simulate an enemy-turn wait in progress: one event remains on the stack
    // below the wait's baseline depth (e.g. a pending turn_end). The wait has
    // 500ms remaining; baseline_stack_depth = 1 (the stack depth when the wait
    // was pushed, after the wait event itself was popped).
    event_push.pushEvents(&history.current_state, &.{.{
        .level_event = .clear_highlights,
    }}, history.current_arena.allocator());
    history.current_state.waiting = .{
        .remaining_microseconds = 500_000,
        .baseline_stack_depth = 1,
    };
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);

    // Drive update() with swap_weapons set and a delta (100ms) smaller than
    // the wait remaining (500ms) — so the wait does NOT elapse this tick.
    var player_input: input.PlayerInput = .{};
    player_input.anytime.in_game.swap_weapons = true;
    const camera_zoom = @as(f32, @floatFromInt(history.settings.camera_zoom)) / 100.0;
    const camera = view_mod.computeCamera(&history.current_state, camera_zoom, history.session.camera_pan, null);
    update(&history, player_input, null, 100_000, camera, camera_zoom, .{ .width = 3840, .height = 2160 });

    // The interjection was handled IMMEDIATELY (not delayed until the wait
    // elapsed): weapons are swapped this tick.
    try std.testing.expectEqual(@as(?types.WeaponType, .staff), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(@as(?types.WeaponType, .sword), history.current_state.level.?.entities[0].off_hand_weapon.?.weapon_type);
    // The swap was recorded into event_history.
    try std.testing.expect(history.current_event_index == event_index_before + 1);
    // The wait is still active — remaining reduced by exactly the delta.
    try std.testing.expect(history.current_state.waiting != null);
    try std.testing.expectEqual(@as(u64, 400_000), history.current_state.waiting.?.remaining_microseconds);
    // The baseline event (clear_highlights) is still on the stack — the
    // interjection drained only down to baseline_stack_depth.
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    // No idle point was recorded for the interjection — it stays absorbed
    // into the surrounding enemy-turn drain's eventual idle point.
    try std.testing.expectEqual(idle_count_before, history.idle_points.items.len);
}

test "undo/redo via anytime input does not record duplicate idle points (no cycling)" {
    // Regression: the idle-branch idle-point recording fired for ANY index
    // change inside update(), including undo/redo (which are anytime actions).
    // undo/redo set current_idle_index + restoreTo(current_event_index), so
    // after update() the position is already indexed — recording a duplicate
    // grew idle_points with near-duplicate entries and made undo/redo cycle
    // between two states instead of walking the timeline. The fix gates the
    // recording on `idle_points[current_idle_index] != current_event_index`,
    // which is true only for genuine new forward progress (processEvent
    // advances the index without touching current_idle_index) and false for
    // navigation (undo/redo leave them equal).
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{playerWithWeapons()},
        &three_by_three_tiles,
    ));
    runToIdle(&history); // idle point 0 (index after open_main_menu... here just the initial)

    // Idle swap #1 → idle point 1 (sword→staff). Drive via update() and
    // replicate frame()'s idle-branch recording (the helper being tested).
    doIdleSwap(&history);
    try std.testing.expectEqual(@as(?types.WeaponType, .staff), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);
    const idle_count_after_swap1 = history.idle_points.items.len;

    // Idle swap #2 → idle point 2 (staff→sword).
    doIdleSwap(&history);
    try std.testing.expectEqual(@as(?types.WeaponType, .sword), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);
    const idle_count_after_swap2 = history.idle_points.items.len;
    try std.testing.expectEqual(idle_count_after_swap1 + 1, idle_count_after_swap2);

    // Undo via anytime input (the bug path). Should go back to idle point 1
    // (staff in main hand) WITHOUT recording a duplicate idle point.
    doAnytime(&history, .{ .undo = true });
    try std.testing.expectEqual(@as(?types.WeaponType, .staff), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(idle_count_after_swap2, history.idle_points.items.len); // no duplicate recorded

    // Undo again — must go further back to idle point 0, NOT cycle forward to
    // idle point 2 (the cycling symptom). Without the fix, this second undo
    // recorded a duplicate and subsequent undos bounced between swap1/swap2.
    doAnytime(&history, .{ .undo = true });
    try std.testing.expectEqual(idle_count_after_swap2, history.idle_points.items.len); // still no duplicate
    // At the earliest idle point — one more undo is a no-op.
    try std.testing.expect(!history.undo(&event_handlers.processEvent));

    // Redo walks forward without recording duplicates either.
    doAnytime(&history, .{ .redo = true });
    try std.testing.expectEqual(@as(?types.WeaponType, .staff), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(idle_count_after_swap2, history.idle_points.items.len);
    doAnytime(&history, .{ .redo = true });
    try std.testing.expectEqual(@as(?types.WeaponType, .sword), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(idle_count_after_swap2, history.idle_points.items.len);
}

/// Drive one update() in the idle frame and replicate frame()'s idle-branch
/// idle-point recording — the exact path the duplicate-idle-point bug lived
/// in. Shared by doIdleSwap (a new action) and doAnytime (undo/redo), so both
/// exercise the same condition the production idle branch uses.
fn runIdleUpdate(history: *GameStateHistory, player_input: input.PlayerInput) void {
    const event_index_before = history.current_event_index;
    const camera_zoom = @as(f32, @floatFromInt(history.settings.camera_zoom)) / 100.0;
    const camera = view_mod.computeCamera(&history.current_state, camera_zoom, history.session.camera_pan, null);
    update(history, player_input, null, 16_000, camera, camera_zoom, .{ .width = 3840, .height = 2160 });
    const events_processed = history.current_event_index != event_index_before;
    history.maybeRecordIdlePoint(events_processed);
}

/// Drive an idle swap_weapons through update() and replicate frame()'s
/// idle-branch idle-point recording — the exact path the bug lived in.
fn doIdleSwap(history: *GameStateHistory) void {
    var player_input: input.PlayerInput = .{};
    player_input.anytime.in_game.swap_weapons = true;
    runIdleUpdate(history, player_input);
}

/// Drive an anytime action (undo/redo/etc.) through update() and replicate
/// frame()'s idle-branch idle-point recording — the path that recorded
/// duplicate idle points on undo/redo before the fix.
fn doAnytime(history: *GameStateHistory, anytime: input.AnytimeInput) void {
    var player_input: input.PlayerInput = .{};
    player_input.anytime = anytime;
    runIdleUpdate(history, player_input);
}

test "undo during a mid-drain reverts to the current idle point, not one further back" {
    // Regression: undo mid-drain (an in-progress player action's subtree on
    // the stack, e.g. enemy turns draining after the player ended their turn)
    // decremented current_idle_index past the state the player was just at,
    // landing one idle point further back than expected. The fix reverts TO
    // the current idle point (cancelling the partial drain) instead of
    // decrementing, and discards the partial drain's recorded events. See
    // DESIGN → Replay & Side Effects.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{playerWithWeapons()},
        &three_by_three_tiles,
    ));
    runToIdle(&history); // idle point 0
    doIdleSwap(&history); // idle point 1 (sword → staff)
    doIdleSwap(&history); // idle point 2 (staff → sword)
    try std.testing.expectEqual(@as(usize, 3), history.idle_points.items.len);
    const idle_index_before = history.current_idle_index; // 2
    try std.testing.expectEqual(@as(?types.WeaponType, .sword), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);

    // Simulate a mid-drain: an in-progress player action's subtree is on the
    // stack with a wait active (e.g. enemy turns draining). current_idle_index
    // still points at idle point 2 — the state just before the drain started.
    event_push.pushEvents(&history.current_state, &.{.{
        .level_event = .clear_highlights,
    }}, history.current_arena.allocator());
    history.current_state.waiting = .{
        .remaining_microseconds = 500_000,
        .baseline_stack_depth = 1,
    };
    try std.testing.expect(history.current_state.event_stack.len > 0);

    // Undo mid-drain: reverts to idle point 2 (the current idle point), NOT
    // decrement to idle point 1.
    try std.testing.expect(history.undo(&event_handlers.processEvent));
    try std.testing.expectEqual(idle_index_before, history.current_idle_index); // didn't decrement
    try std.testing.expectEqual(history.idle_points.items[idle_index_before], history.current_event_index);
    // Stack cleared + wait cleared (restoreTo clears waiting).
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try std.testing.expect(history.current_state.waiting == null);
    // The partial drain's events were discarded — event_history trimmed to
    // the current event index, idle_points trimmed to current_idle_index + 1.
    try std.testing.expectEqual(@as(usize, history.current_event_index), history.event_history.items.len);
    try std.testing.expectEqual(@as(usize, idle_index_before + 1), history.idle_points.items.len);

    // Now idle: a second undo decrements normally to idle point 1 (staff).
    try std.testing.expect(history.undo(&event_handlers.processEvent));
    try std.testing.expectEqual(@as(?types.WeaponType, .staff), history.current_state.level.?.entities[0].main_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(idle_index_before - 1, history.current_idle_index);
}

test "maybeRecordIdlePoint: first idle point from empty idle_points (no out-of-bounds)" {
    // Regression: maybeRecordIdlePoint reads idle_points[current_idle_index]
    // to check "not already an idle point." At startup idle_points is empty
    // and current_idle_index is 0, so that read was out of bounds and crashed
    // the exe on the first frame (the open_main_menu drain). The tests missed
    // it because every test calls runToIdle first, which populates idle_points
    // via recordIdlePoint before any maybeRecordIdlePoint call. This test
    // drives the empty-list path directly.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{playerWithWeapons()},
        &three_by_three_tiles,
    ));
    // Fresh history: idle_points empty, current_idle_index 0, no events yet.
    try std.testing.expectEqual(@as(usize, 0), history.idle_points.items.len);
    try std.testing.expectEqual(@as(u32, 0), history.current_event_index);

    // Process one event (swap_hands) directly, then call maybeRecordIdlePoint
    // with empty idle_points — must record the first idle point, not crash.
    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = .swap_hands }}, history.current_arena.allocator());
    event_handlers.processEvent(&history);
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try std.testing.expect(history.current_event_index > 0);

    history.maybeRecordIdlePoint(true);
    try std.testing.expectEqual(@as(usize, 1), history.idle_points.items.len);
    try std.testing.expectEqual(history.current_event_index, history.idle_points.items[0]);
}

test "text field focus-on-click: press + release over a field focuses it; click inside repositions the caret" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const entity_types = [_]types.EntityTypeDef{
        .{ .id = "Skeleton", .template = .{ .name = "Skeleton Warrior", .sprite = "skeleton_1", .team = 1 } },
    };
    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(.{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{
            .levels = &levels,
            .entity_types = &entity_types,
            .active_tool = .{ .entity_type = 0 },
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    runToIdle(&history);

    // The inspector's sections start ALL COLLAPSED (the shipped default)
    // — expand them so the fields render.
    history.session.ui_state.editor_inspector_section_expanded = ui.allInspectorSectionsExpanded();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, .{ .r = 30, .g = 30, .b = 30 }, black, black, black, .{ .r = 40, .g = 40, .b = 40 } } },
    };
    const metrics = ui.FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // The previous frame's view: the inspector with its two text fields.
    var elements: ui.UiElementList = .empty;
    try ui.buildEditorInspectorPanel(
        &elements,
        arena,
        metrics,
        history.current_state.editor.?,
        theme,
        true,
        &history.session.ui_state,
    );
    const view_state = types.ViewState{
        .background_color = black,
        .active_color_theme = theme,
        .world_scale = 1.0,
        .tiles = &.{},
        .tile_overlays = &.{},
        .ground_drawables = &.{},
        .occlusion_insets = &.{},
        .world_overlays = &.{},
        .ui_elements = elements.items,
        .font_metrics = metrics,
        .combat_log = &.{},
    };

    var name_field: ?ui.TextFieldUi = null;
    var sprite_button: ?ui.Button = null;
    for (elements.items) |element| switch (element) {
        .text_field => |field| {
            if (field.ref.id == .entity_name) name_field = field;
        },
        .button => |button| {
            if (button.action == .open_editor_sprite_picker) sprite_button = button;
        },
        else => {},
    };
    const name_click = input.PointerPosition{
        .x = @as(f32, @floatFromInt(name_field.?.screen_position.x)) + 40,
        .y = @as(f32, @floatFromInt(name_field.?.screen_position.y)) + 40,
    };
    const sprite_click = input.PointerPosition{
        .x = @as(f32, @floatFromInt(sprite_button.?.screen_position.x)) + 40,
        .y = @as(f32, @floatFromInt(sprite_button.?.screen_position.y)) + 40,
    };

    const camera: types.Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const viewport = input.ViewportSize{ .width = 2560, .height = 2160 };

    // Press over the Name field: tracked, not a button.
    {
        var player_input = input.PlayerInput{};
        player_input.pointer.pressed = true;
        player_input.pointer.position = name_click;
        update(&history, player_input, view_state, 0, camera, 1.0, viewport);
        try std.testing.expectEqual(
            types.TextFieldRef{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } },
            history.session.pressed_text_field.?,
        );
        try std.testing.expect(history.session.pressed_button == null);
    }
    // Release over the same field: focused, seeded with the current value.
    {
        var player_input = input.PlayerInput{};
        player_input.pointer.released = true;
        player_input.pointer.position = name_click;
        update(&history, player_input, view_state, 0, camera, 1.0, viewport);
        try std.testing.expect(history.session.ui_state.text_edit != null);
        try std.testing.expectEqualStrings(
            "Skeleton Warrior",
            history.session.ui_state.text_edit.?.buffer.currentText(),
        );
        try std.testing.expect(history.session.pressed_text_field == null);
    }

    // Click INSIDE the focused field: the caret repositions (no commit, no
    // refocus). At font 64 each glyph measures ~35px; 40px into the text
    // lands inside the second glyph → caret at index 1.
    {
        var player_input = input.PlayerInput{};
        player_input.pointer.pressed = true;
        player_input.pointer.position = .{
            .x = @as(f32, @floatFromInt(name_field.?.text_position.x)) + 40,
            .y = name_click.y,
        };
        update(&history, player_input, view_state, 0, camera, 1.0, viewport);
        player_input = .{};
        player_input.pointer.released = true;
        player_input.pointer.position = .{
            .x = @as(f32, @floatFromInt(name_field.?.text_position.x)) + 40,
            .y = name_click.y,
        };
        update(&history, player_input, view_state, 0, camera, 1.0, viewport);
        try std.testing.expectEqual(@as(usize, 1), history.session.ui_state.text_edit.?.buffer.caret);
        // Still the same focused field (a caret move, not a refocus).
        try std.testing.expectEqual(
            types.TextFieldRef{ .id = .entity_name, .target = .{ .entity = .{ .entity_type = 0 } } },
            history.session.ui_state.text_edit.?.field,
        );
    }

    // Press on the SPRITE row's button while the name field is focused:
    // M2 commits the name (unchanged → records nothing) + the press
    // proceeds; release OPENS the centered sprite picker (the Sprite row's
    // action).
    {
        var player_input = input.PlayerInput{};
        player_input.pointer.pressed = true;
        player_input.pointer.position = sprite_click;
        update(&history, player_input, view_state, 0, camera, 1.0, viewport);
        player_input = .{};
        player_input.pointer.released = true;
        player_input.pointer.position = sprite_click;
        update(&history, player_input, view_state, 0, camera, 1.0, viewport);
        try std.testing.expect(history.session.ui_state.editor_picker != null);
        try std.testing.expectEqual(
            ui.EditorPickerTarget.entity_sprite,
            history.session.ui_state.editor_picker.?,
        );
        try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
        // Close it — the drag-off block below needs a clean slate.
        player_input = .{};
        player_input.pointer.pressed = true;
        player_input.pointer.position = .{ .x = 2400, .y = 2400 };
        update(&history, player_input, view_state, 0, camera, 1.0, viewport);
    }

    // Drag-off: press on the name field, release far away. The PRESS
    // already committed the sprite field (M2 — focus dropped); the missed
    // release cancels the name focus too, so no field is focused.
    {
        var player_input = input.PlayerInput{};
        player_input.pointer.pressed = true;
        player_input.pointer.position = name_click;
        update(&history, player_input, view_state, 0, camera, 1.0, viewport);
        player_input = .{};
        player_input.pointer.released = true;
        player_input.pointer.position = .{ .x = 2400, .y = 2400 };
        update(&history, player_input, view_state, 0, camera, 1.0, viewport);
        try std.testing.expect(history.session.ui_state.text_edit == null);
        try std.testing.expect(history.session.pressed_text_field == null);
    }
}
