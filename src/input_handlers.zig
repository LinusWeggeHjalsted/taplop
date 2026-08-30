//! Input consumption — the semantic layer that turns a `PlayerInput` into
//! gameplay actions (event pushes) and transient state changes.
//!
//! `input.zig` is the *translation* layer (raw platform events → semantic
//! `PlayerInput`); this file is the *consumption* layer: `handleAnytimeInput`,
//! `handleIdleInput`, `resolveTileCursor`, and the drag lifecycle resolve a
//! player input into event pushes (via `event_handlers.pushEvents`) or direct
//! `SessionState` writes (transient view/input state — never undoable
//! `GameState`). Session-log dev tooling (`dumpEventLog`, the build-version
//! advisory warn, the timestamp formatter) lives here too, called from the
//! anytime path.

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const parser = @import("parser.zig");
const writers = @import("writers.zig");
const session_log = @import("session_log.zig");
const lookups = @import("generated_lookups.zig");
const ui = @import("ui.zig");
const file_source_mod = @import("file_source.zig");
const event_handlers = @import("event_handlers.zig");
const view_mod = @import("view.zig");
const build_info = @import("build_info");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;

/// Mouse-wheel zoom cadence + bounds. Additive in fixed steps (one zoom-in
/// then one zoom-out returns to the exact same value — no float drift).
/// Default 0.5; scroll up zooms in, scroll down zooms out. The minimum is
/// always one step (so the floor divides evenly into the range). Tune from
/// feel; if linear spacing feels uneven across the range, swap the additive
/// step for a generated level table (a localized change here).
const camera_zoom_step: u32 = 25;
const min_camera_zoom: u32 = 25;
const max_camera_zoom: u32 = 100;
const default_camera_zoom: u32 = 50;

/// True when the pointer is over a skills-browser slot (a ref-bearing
/// element whose ref is `.learned_skill`). Used to route the mouse wheel to
/// skills-browser scroll instead of camera zoom. The skills panel's slots
/// are only emitted when the panel is open, so a hit here implies the panel
/// is open — no separate open-state check needed. See `handleAnytimeInput`.
fn skillsSlotUnderPointer(
    ui_elements: []const ui.UiElement,
    position: types.ScreenPosition,
) bool {
    const ref = ui.refAt(ui_elements, position) orelse return false;
    return switch (ref) {
        .learned_skill => true,
        else => false,
    };
}

/// Write the current settings to `~/.ziglop/settings.txt` (best-effort —
/// errors are swallowed since a failed preferences write is not critical;
/// the preference just doesn't persist). Called as a `PendingWrite` writer
/// when the settings debounce fires. See DESIGN → Input.
pub fn writeSettingsToFile(history: *GameStateHistory) void {
    const allocator = history.backing_allocator;
    const bytes = writers.writeSettings(history.settings, allocator) catch return;
    defer allocator.free(bytes);
    history.file_source.writeFile("settings.txt", bytes) catch return;
}

/// Mark settings as dirty for debounced persistence. Called after a tunable
/// setting changes (currently `camera_zoom`). See DESIGN → Input.
fn markSettingsDirty(history: *GameStateHistory) void {
    history.session.markWriteDirty(.settings, writeSettingsToFile, history.session.session_clock);
}
const PlayerInput = input.PlayerInput;
const Vector2 = types.Vector2;
const Entity = types.Entity;
const SkillId = types.SkillId;
const Level = types.Level;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const Settings = types.Settings;
const utility_skill_count = types.utility_skill_count;
const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;
const WeaponType = types.WeaponType;

/// Map a drag (source slot ref → target slot ref) to the orchestrator
/// `PlayerInputEvent` that the handler will resolve, or null for a
/// nonsensical / unsupported drop. Replaces the old `dragToEvent` which
/// returned machinery events directly — input now only pushes
/// PlayerInputEvents (orchestrator convention; see DESIGN → Determinism &
/// Tiebreaking → Replay PLAYER-ACTION LEGALITY). The handler pushes the
/// machinery event as a child.
pub fn dragToOrchestrator(from: ui.SlotRef, to: ui.SlotRef) ?events.PlayerInputEvent {
    // A drop back on the source slot is a no-op for every domain — don't
    // push a no-op swap/equip into the event log.
    if (ui.SlotRef.eql(from, to)) return null;
    return switch (from) {
        // Save rows are never drag sources (see slotContentIcon).
        .save_file => null,
        .inventory => |inventory_index| switch (to) {
            .gear => |gear_slot| .{ .player_equip_to_gear = .{
                .inventory_slot_index = inventory_index,
                .gear_slot = gear_slot,
            } },
            .inventory => |target_index| .{ .player_swap_inventory_items = .{
                .slot_a_index = inventory_index,
                .slot_b_index = target_index,
            } },
            else => null, // inventory → skill targets: no handler
        },
        .gear => |gear_slot| switch (to) {
            .inventory => |inventory_index| .{ .player_unequip_from_gear = .{
                .gear_slot = gear_slot,
                .inventory_slot_index = inventory_index,
            } },
            else => null,
        },
        .learned_skill => |skill_id| switch (to) {
            .skill_bar => |slot_index| .{ .player_assign_utility_skill = .{
                .skill_id = skill_id,
                .slot_index = slot_index,
            } },
            else => null,
        },
        .skill_bar => |from_index| switch (to) {
            .skill_bar => |to_index| .{ .player_swap_utility_skills = .{
                .slot_a_index = from_index,
                .slot_b_index = to_index,
            } },
            // Dropping a bar skill back onto the skills menu clears the slot.
            .learned_skill => .{ .player_clear_utility_skill = .{
                .slot_index = from_index,
            } },
            else => null,
        },
    };
}

/// Pointer-driven slot-press lifecycle. Runs every tick (anytime): a press
/// on a content slot records a pending press (no ghost yet); movement beyond
/// `drag_threshold_pixels` promotes it to a drag (ghost appears, drop on
/// release); a release within threshold over the same slot is a click
/// resolved into an inventory-item intent (equip / salvage, with modifier +
/// double-click disambiguation). Right-button presses never drag (right-drag
/// is camera pan on the world; panels block it, so a right-press on a slot is
/// a click). Hit-tests against the previous frame's UI.
///
/// Item clicks are ANYTIME (not gated on the event stack) — salvaging /
/// equipping / learning during enemy turns is allowed. The pushed
/// orchestrator is processed mid-drain like `swap_hands` (see the wait/drain
/// loop in `update`). See DESIGN → UI Framework.
pub fn handleDrag(
    history: *GameStateHistory,
    pointer: input.PointerInput,
    ui_elements: []const ui.UiElement,
) void {
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();
    const ui_state = &history.session.ui_state;

    // --- Left button: press → pending or drag ---
    if (pointer.pressed) {
        if (ui.refAt(ui_elements, pointer.position)) |ref| {
            // Two press paths share `pending_slot_press`:
            //   • Shift+left on an INVENTORY slot (occupied or empty) tracks
            //     a salvage-region selection — empty slots are valid region
            //     corners so the player can drag across mixed occupancy.
            //   • Otherwise, only OCCUPIED slots track an item drag/click —
            //     `slotContentIcon` is null for an empty slot, gating drags
            //     to slots that actually hold something.
            if (pointer.modifiers.shift and ref == .inventory) {
                ui_state.pending_slot_press = .{
                    .source = ref,
                    // No ghost is rendered for a region selection; the icon
                    // is unused on this path (empty-slot shift+click is a
                    // harmless no-op salvage).
                    .icon_sprite_id = "ui/item_slot",
                    .press_position = pointer.position,
                    .button = .left,
                    .shift_held = true,
                };
            } else if (ui.slotContentIcon(current, ref)) |icon| {
                ui_state.pending_slot_press = .{
                    .source = ref,
                    .icon_sprite_id = icon,
                    .press_position = pointer.position,
                    .button = .left,
                    .shift_held = pointer.modifiers.shift,
                };
            }
        }
    }

    // Promote a pending left-press once the pointer moves beyond the
    // threshold. Uses `>` (strict) so a zero-threshold config still tolerates
    // a no-movement press+release as a CLICK (0 > 0 is false → pending
    // survives → release reaches the click branch). `>=` would promote on
    // the press frame itself (0 >= 0 is true), making click-to-equip dead.
    // See `handleRightClickInspect` for the same `>` convention.
    if (ui_state.pending_slot_press) |press| {
        if (press.button == .left) {
            const dx = pointer.position.x - press.press_position.x;
            const dy = pointer.position.y - press.press_position.y;
            if (dx * dx + dy * dy > ui.drag_threshold_pixels * ui.drag_threshold_pixels) {
                if (press.shift_held and press.source == .inventory) {
                    ui_state.salvage_region = .{
                        .start_slot = press.source.inventory,
                        .end_slot = press.source.inventory,
                    };
                } else {
                    ui_state.drag = .{
                        .source = press.source,
                        .icon_sprite_id = press.icon_sprite_id,
                        .size = ui.slotContentSize(press.source),
                    };
                }
                ui_state.pending_slot_press = null;
            }
        }
    }

    // While a salvage-region selection is in progress, update the end slot to
    // the inventory slot currently under the pointer. Runs every call (not
    // just on events) so the outline tracks the cursor live. When the pointer
    // is off-grid (null / non-inventory ref) the previous end slot is kept —
    // the release then salves the last valid region.
    if (ui_state.salvage_region) |region| {
        if (ui.refAt(ui_elements, pointer.position)) |ref| switch (ref) {
            .inventory => |slot_index| ui_state.salvage_region = .{
                .start_slot = region.start_slot,
                .end_slot = slot_index,
            },
            else => {},
        };
    }

    // --- Left button: release → drop, region-salvage, or click ---
    if (pointer.released) {
        if (ui_state.salvage_region) |region| {
            // Shift-drag release: salvage the bounding box if Shift is still
            // held, else cancel. Either way the selection clears.
            if (pointer.modifiers.shift) {
                event_handlers.pushPlayerAction(current, .{ .player_salvage_inventory_region = .{
                    .start_slot = region.start_slot,
                    .end_slot = region.end_slot,
                } }, allocator);
            }
            ui_state.salvage_region = null;
            ui_state.pending_slot_press = null;
        } else if (ui_state.drag) |drag| {
            // Resolve the drop. `target` is null when the release is over empty
            // space (or non-ref UI like a panel background). A resolved
            // orchestrator (swap / assign / equip / clear) is pushed as-is.
            const target: ?ui.SlotRef = ui.refAt(ui_elements, pointer.position);
            var resolved: ?events.PlayerInputEvent = null;
            if (target) |target_ref| {
                if (dragToOrchestrator(drag.source, target_ref)) |orchestrator| {
                    resolved = orchestrator;
                }
            }
            // Drag a skill off the bar: if nothing resolved and the release
            // isn't back on the source slot, the drag went "off the bar" (empty
            // space, a non-ref surface, or a cross-domain ref like an inventory
            // slot) → clear the source utility slot. A self-drop (release back
            // on the source slot) stays a no-op. Item/gear drags off to empty
            // space just cancel (no destroy-on-missdrop). See DESIGN →
            // Architecture (no-duplicate utility-skill rule + off-bar clear).
            if (resolved == null) {
                const is_self_drop = if (target) |target_ref| ui.SlotRef.eql(drag.source, target_ref) else false;
                if (!is_self_drop) switch (drag.source) {
                    .skill_bar => |from_index| resolved = .{ .player_clear_utility_skill = .{
                        .slot_index = from_index,
                    } },
                    else => {},
                };
            }
            if (resolved) |orchestrator| {
                event_handlers.pushPlayerAction(current, orchestrator, allocator);
            }
            ui_state.drag = null;
            ui_state.pending_slot_press = null;
        } else if (ui_state.pending_slot_press) |press| {
            if (press.button == .left) {
                // Release over the same slot = click; elsewhere = cancel.
                if (ui.refAt(ui_elements, pointer.position)) |target| {
                    if (slotRefsEqual(target, press.source)) {
                        resolveInventoryClick(history, press.source, .left, pointer.modifiers);
                    }
                }
                ui_state.pending_slot_press = null;
            }
        }
    }

    // --- Right button: press → pending (click only, no drag) ---
    if (pointer.right_pressed) {
        if (ui.refAt(ui_elements, pointer.position)) |ref| {
            // Same content gate as left-press: only occupied slots are
            // clickable (an empty slot has nothing to equip/salvage).
            if (ui.slotContentIcon(current, ref)) |icon| {
                ui_state.pending_slot_press = .{
                    .source = ref,
                    .icon_sprite_id = icon,
                    .press_position = pointer.position,
                    .button = .right,
                };
            }
        }
    }

    // --- Right button: release → click ---
    if (pointer.right_released) {
        if (ui_state.pending_slot_press) |press| {
            if (press.button == .right and ui_state.drag == null) {
                if (ui.refAt(ui_elements, pointer.position)) |target| {
                    if (slotRefsEqual(target, press.source)) {
                        resolveInventoryClick(history, press.source, .right, pointer.modifiers);
                    }
                }
                ui_state.pending_slot_press = null;
            }
        }
    }
}

/// Whether two SlotRefs refer to the same slot. Thin wrapper over
/// `SlotRef.eql` (kept for the call sites that read better with a free fn).
fn slotRefsEqual(a: ui.SlotRef, b: ui.SlotRef) bool {
    return ui.SlotRef.eql(a, b);
}

/// The click intents an inventory-slot click can resolve to. `none` carries
/// no action (plain single click awaiting a double, or a no-op combo).
const ItemIntent = enum { equip_main, equip_off, salvage, none };

/// Resolve a click (button + modifiers + double-click state) to an intent.
/// Precedence: shift > ctrl > alt > plain-double; combos (2+ modifiers) are
/// a no-op. Pure — testable without input/state.
///   shift+left → salvage; shift+right → none
///   ctrl+left → equip_main; ctrl+right → equip_off
///   alt+left → equip_off; alt+right → equip_main
///   plain double-left → equip_main; plain double-right → equip_off
///   plain single → none (seeds a pending double)
fn resolveItemClick(button: ui.ClickButton, modifiers: types.Modifiers, is_double: bool) ItemIntent {
    const combo: u8 = @as(u8, @intFromBool(modifiers.shift)) + @as(u8, @intFromBool(modifiers.ctrl)) + @as(u8, @intFromBool(modifiers.alt));
    if (combo >= 2) return .none;
    if (modifiers.shift) return if (button == .left) .salvage else .none;
    if (modifiers.ctrl) return if (button == .left) .equip_main else .equip_off;
    if (modifiers.alt) return if (button == .left) .equip_off else .equip_main;
    return if (is_double) (if (button == .left) .equip_main else .equip_off) else .none;
}

/// Resolve an inventory-slot click into an orchestrator action, with double-
/// click detection. Only inventory slots are clickable this slice (gear /
/// skills panels have no builders yet); non-inventory sources are ignored.
/// Anytime — not gated on the event stack (salvaging/equipping/learning
/// during enemy turns is allowed). See `handleDrag`.
fn resolveInventoryClick(
    history: *GameStateHistory,
    source: ui.SlotRef,
    button: ui.ClickButton,
    modifiers: types.Modifiers,
) void {
    const slot_index = switch (source) {
        .inventory => |i| i,
        else => return, // gear/skill slots: no click behavior yet
    };
    const ui_state = &history.session.ui_state;
    const now = history.session.session_clock;

    // Double-click = a prior plain single click on the same slot + same
    // button within the threshold window.
    const is_double = if (ui_state.last_item_click) |last| blk: {
        if (last.slot_index == slot_index and last.button == button and
            now - last.time <= ui.double_click_threshold_us)
            break :blk true;
        break :blk false;
    } else false;

    const intent = resolveItemClick(button, modifiers, is_double);
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();
    switch (intent) {
        .equip_main, .equip_off => {
            event_handlers.pushPlayerAction(current, .{ .player_use_inventory_item = .{
                .inventory_slot_index = slot_index,
                .off_hand = intent == .equip_off,
            } }, allocator);
            ui_state.last_item_click = null; // consumed
        },
        .salvage => {
            event_handlers.pushPlayerAction(current, .{ .player_salvage_inventory_item = .{
                .inventory_slot_index = slot_index,
            } }, allocator);
            ui_state.last_item_click = null;
        },
        .none => {
            // Seed a pending double ONLY for plain (no-modifier) single
            // clicks that didn't fire. Modifier-clicks that no-op (combos,
            // shift+right) clear it so they don't pair with a later plain click.
            const combo: u8 = @as(u8, @intFromBool(modifiers.shift)) + @as(u8, @intFromBool(modifiers.ctrl)) + @as(u8, @intFromBool(modifiers.alt));
            if (combo == 0 and !is_double) {
                ui_state.last_item_click = .{ .slot_index = slot_index, .button = button, .time = now };
            } else {
                ui_state.last_item_click = null;
            }
        },
    }
}

/// Camera pan (right-drag): grab the world point under the cursor and drag
/// it so it stays under the cursor. Runs anytime (not gated on the event
/// stack) so the player can look around mid-wait / mid-turn. Levels/hubs/
/// editor only. The pan offset lives on SessionState (transient view state, replay-
/// safe by construction — see DESIGN → Replay & Side Effects). `camera` must already include the
/// current pan offset (so screenToTile / floatWorldPoint map the cursor
/// against the camera the player is actually seeing).
///
/// Pan-start is suppressed when the pointer is over a blocking UI element
/// (same occlusion check as the tile cursor) — right-clicking a panel pans
/// nothing. On player move (detected in frame()) the pan is cleared so the
/// camera recenters; on screen transition frame() also clears it. Here we
/// only own the drag itself.
pub fn handleCameraPan(
    history: *GameStateHistory,
    pointer: input.PointerInput,
    ui_elements: []const ui.UiElement,
    camera: types.Camera,
    camera_zoom: f32,
    viewport: input.ViewportSize,
) void {
    const current = &history.current_state;
    const session = &history.session;

    // Outside a level/hub/editor there's nothing to pan. Clear any stale
    // pan/anchor so re-entering a world doesn't inherit it (frame() also
    // clears on screen transition, but this covers direct entry without a
    // transition).
    if (current.screen != .level and current.screen != .hub and current.screen != .editor) {
        session.camera_pan = null;
        session.camera_pan_anchor = null;
        return;
    }

    // Right-button press begins a pan — unless the cursor is over blocking UI.
    if (pointer.right_pressed) {
        if (ui.blockingElementAt(ui_elements, pointer.position) != null) {
            session.camera_pan_anchor = null;
            return;
        }
        const world = input.floatWorldPoint(pointer.position, camera, camera_zoom, viewport);
        session.camera_pan_anchor = .{ .world_x = world.x, .world_y = world.y };
        return;
    }

    // No active drag — nothing to do on held/moved/released.
    if (session.camera_pan_anchor == null) {
        if (pointer.right_released) session.camera_pan_anchor = null;
        return;
    }

    // Drag in progress (right held). Solve for the camera position that keeps
    // the anchored world point exactly under the cursor, then store the
    // offset from the player-centered camera as `camera_pan`.
    //
    //   world = (camera.position + (cursor - viewport/2)) / tile_pixels
    //   => camera.position = world * tile_pixels - (cursor - viewport/2)
    //
    // pan = camera.position - player_centered_camera.position (computed here
    // without the pan offset, so the offset is relative to the recentered
    // camera and survives a player move only until frame() clears it).
    if (pointer.right_held) {
        const tile_pixels = input.tile_size_pixels * camera_zoom;
        const anchor = session.camera_pan_anchor.?;
        const cursor_x: f32 = @floatFromInt(pointer.position.x);
        const cursor_y: f32 = @floatFromInt(pointer.position.y);
        const target_camera_x = anchor.world_x * tile_pixels - (cursor_x - viewport.width / 2.0);
        const target_camera_y = anchor.world_y * tile_pixels - (cursor_y - viewport.height / 2.0);

        const player_centered = view_mod.computeCamera(current, camera_zoom, null);
        session.camera_pan = .{
            .x = @intFromFloat(@round(target_camera_x - @as(f32, @floatFromInt(player_centered.position.x)))),
            .y = @intFromFloat(@round(target_camera_y - @as(f32, @floatFromInt(player_centered.position.y)))),
        };
    }

    if (pointer.right_released) {
        session.camera_pan_anchor = null;
    }
}

/// Right-click entity inspection (levels only). A right-press on a world
/// tile with an entity records a pending right-click; movement beyond
/// `drag_threshold_pixels` cancels it (the press became a camera pan); a
/// clean release toggles the entity inspect panel on that entity (same
/// entity → close, different → switch, none open → open). Suppressed over
/// blocking UI (same occlusion check as the tile cursor + camera pan) so a
/// right-click on a panel never inspects the world behind it. Hubs are
/// excluded — inspection is level-only by design.
///
/// Runs anytime alongside `handleCameraPan` / `handleDrag`. The two right-
/// click consumers coexist without conflict: a no-movement right-press sets
/// the pan anchor + a pending right-click, and on release the anchor clears
/// (no pan offset was ever computed) while the pending right-click fires
/// the inspect. A right-drag past the threshold cancels the pending right-
/// click and lets the pan proceed.

/// Compute an integer slider value from a pointer x position over the
/// slider's track. Clamps to `[min, max]`, step 1.
fn sliderValueFromPointer(slider: ui.Slider, pointer_x: i32) u32 {
    const track_x: f32 = @floatFromInt(slider.screen_position.x);
    const track_w: f32 = @floatFromInt(slider.width);
    const px: f32 = @floatFromInt(pointer_x);
    const fraction = if (track_w > 0)
        @max(0.0, @min(1.0, (px - track_x) / track_w))
    else
        0.0;
    const range: f32 = if (slider.max > slider.min) @floatFromInt(slider.max - slider.min) else 0;
    return slider.min + @as(u32, @intFromFloat(@round(fraction * range)));
}

/// Apply a slider value to `history.settings` based on the slider's
/// `setting_id`. Mutates settings directly (off the undo timeline) + marks
/// dirty for debounced persistence. Called on every drag step (the debounce
/// coalesces — the write fires 1s after the last scrub).
fn applySliderValue(history: *GameStateHistory, slider: ui.Slider, pointer_x: i32) void {
    const value = sliderValueFromPointer(slider, pointer_x);
    const settings = &history.settings;
    switch (slider.setting_id) {
        .master_volume => settings.master_volume = value,
        .music_volume => settings.music_volume = value,
        .sound_effects_volume => settings.sound_effects_volume = value,
        .render_fps_cap => settings.render_fps_cap = value,
        .animation_fps => settings.animation_fps = value,
        else => return,
    }
    markSettingsDirty(history);
}

/// Settings slider drag handler. Runs before the options-menu gate (sliders
/// must work while the settings overlay is open on top of the options menu).
/// Left-press on a slider begins a drag + jumps to the pointer; left-held
/// scrubs; left-release ends the drag. The slider is hit-tested against the
/// previous frame's UI (same as the button model). See DESIGN → UI Framework
/// → Settings screen.
pub fn handleSliderDrag(
    history: *GameStateHistory,
    pointer: input.PointerInput,
    ui_elements: []const ui.UiElement,
) void {
    const session = &history.session;
    if (!session.ui_state.settings_open) {
        if (session.ui_state.active_slider != null) session.ui_state.active_slider = null;
        return;
    }

    // Left-press over a slider begins a drag + jumps to the pointer.
    if (pointer.pressed) {
        if (ui.sliderAt(ui_elements, pointer.position)) |slider| {
            session.ui_state.active_slider = slider.setting_id;
            applySliderValue(history, slider, pointer.position.x);
        }
    }

    // Left-held with an active slider: scrub (find the slider for the active
    // setting in the current UI + apply the value from the pointer x).
    if (pointer.held and session.ui_state.active_slider != null) {
        if (ui.findSlider(ui_elements, session.ui_state.active_slider.?)) |slider| {
            applySliderValue(history, slider, pointer.position.x);
        }
    }

    // Left-release ends the drag.
    if (pointer.released) {
        session.ui_state.active_slider = null;
    }
}
pub fn handleRightClickInspect(
    history: *GameStateHistory,
    pointer: input.PointerInput,
    ui_elements: []const ui.UiElement,
    camera: types.Camera,
    camera_zoom: f32,
    viewport: input.ViewportSize,
) void {
    const current = &history.current_state;
    const ui_state = &history.session.ui_state;

    // Levels only.
    if (current.screen != .level) {
        ui_state.pending_right_click = null;
        return;
    }
    const level = current.level orelse {
        ui_state.pending_right_click = null;
        return;
    };

    // Right-press: if over a world tile (not blocking UI) with an entity,
    // record a pending right-click. Over blocking UI or an empty tile, clear
    // any stale pending (a right-click on a panel or empty ground inspects
    // nothing).
    if (pointer.right_pressed) {
        if (ui.blockingElementAt(ui_elements, pointer.position) != null) {
            ui_state.pending_right_click = null;
            return;
        }
        const mouse_tile = input.screenToTile(
            .{ .x = @floatFromInt(pointer.position.x), .y = @floatFromInt(pointer.position.y) },
            camera,
            camera_zoom,
            viewport,
        );
        for (level.entities, 0..) |entity, index| {
            if (entity.position.x == mouse_tile.x and entity.position.y == mouse_tile.y) {
                ui_state.pending_right_click = .{
                    .entity_index = @intCast(index),
                    .press_position = pointer.position,
                };
                return;
            }
        }
        ui_state.pending_right_click = null;
        return;
    }

    // Movement beyond the threshold cancels the pending right-click (it
    // became a camera pan). Checked on every call while the right button is
    // held. Uses `>` (strict) so a zero-threshold config still tolerates a
    // no-movement press+release — `0 > 0` is false, so a clean click survives.
    // Same convention as the inventory drag promotion in `handleDrag`.
    if (ui_state.pending_right_click) |press| {
        if (pointer.right_held) {
            const dx = pointer.position.x - press.press_position.x;
            const dy = pointer.position.y - press.press_position.y;
            if (dx * dx + dy * dy > input.drag_threshold_pixels * input.drag_threshold_pixels) {
                ui_state.pending_right_click = null;
            }
        }
    }

    // Right-release: if a pending right-click survived (no threshold
    // crossing), toggle inspect on that entity.
    if (pointer.right_released) {
        if (ui_state.pending_right_click) |press| {
            if (ui_state.inspected_entity_index) |current_inspected| {
                if (current_inspected == press.entity_index) {
                    // Same entity — close the panel.
                    ui_state.toggleMiddlePanel(.entity_inspect);
                    ui_state.inspected_entity_index = null;
                } else {
                    // Different entity — switch target.
                    ui_state.inspected_entity_index = press.entity_index;
                }
            } else {
                // Not inspecting — open the panel.
                ui_state.inspected_entity_index = press.entity_index;
                ui_state.toggleMiddlePanel(.entity_inspect);
            }
        }
        ui_state.pending_right_click = null;
    }
}
pub fn warnIfSessionLogFromDifferentBuild(log_game_version: []const u8) void {
    if (!std.mem.eql(u8, log_game_version, build_info.game_version)) {
        std.debug.print(
            "warning: session log recorded on game_version {s}, this build is {s}; replay may diverge\n",
            .{ log_game_version, build_info.game_version },
        );
    }
}

/// Write the full session event history to `logs/session_log_YYYYMMDD_HHMMSS.txt`
/// in the persistent data dir (config format; see session_log.writeEventLog). A dev
/// tool bound to ctrl+L. Runs only from the input path, so it never fires during
/// replay. The timestamp is UTC (no timezone handling) — fine for a filename.
pub fn dumpEventLog(history: *GameStateHistory) void {
    var arena = std.heap.ArenaAllocator.init(history.backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const created = formatSessionTimestamp(allocator, history.io);
    const file_name = std.fmt.allocPrint(
        allocator,
        "logs/session_log_{s}.txt",
        .{created},
    ) catch @panic("failed to format session-log file name");
    const body = session_log.writeEventLog(
        history.event_history.items,
        created,
        allocator,
    ) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to serialize session log",
        );
        return;
    };
    history.file_source.writeFile(file_name, body) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to write session log file",
        );
        return;
    };

    // Feedback for this dev tool: the file lands in the persistent data dir
    // (~/.ziglop/logs/).
    std.debug.print("wrote session log: {s} ({d} events)\n", .{
        file_name,
        history.event_history.items.len,
    });
}

/// Format the current wall-clock time (UTC) as "YYYYMMDD_HHMMSS".
pub fn formatSessionTimestamp(
    allocator: std.mem.Allocator,
    io: std.Io,
) []const u8 {
    const seconds: u64 = @intCast(std.Io.Clock.now(.real, io).toSeconds());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            @as(u32, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    ) catch @panic("failed to format session-log timestamp");
}

/// Push a player-action orchestrator event and drain it (plus its handler-
/// pushed children) to completion within this call. Used by the
/// options_action dispatch and the Escape overlay chain, both inside
/// handleAnytimeInput — which runs before update()'s options-menu/pause
/// gates, so the drain proceeds even while a modal overlay is open. The
/// overlay opened in a previous frame and nothing drains while it's open
/// (update() returns at its gate), so event_stack.len on entry equals the
/// depth when the overlay opened — that's the drain baseline. Draining back
/// DOWN to the baseline leaves anything pushed beneath (e.g. a mid-drain
/// enemy turn) intact. Idle-point recording is left to the normal
/// maybeRecordIdlePoint in gameLoop (no special case): if the stack empties
/// (overlay opened from idle) an undo stop is recorded; mid-enemy-turn the
/// action bundles into that drain's idle point. Aborts on load_error (the
/// drain-loop convention — the error popup takes over).
fn pushPlayerActionAndDrain(
    history: *GameStateHistory,
    action: events.PlayerInputEvent,
) void {
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();
    const baseline = current.event_stack.len;
    event_handlers.pushPlayerAction(current, action, allocator);
    while (current.event_stack.len > baseline) {
        if (history.load_error) break;
        event_handlers.processEvent(history);
    }
}

/// Queue the menu sound for an Escape keypress that does something (a
/// closing overlay or a triggered action). Keybind-triggered actions have no
/// button, so the input-handler site queues the feedback sound (see DESIGN →
/// Audio → Button press/release model).
fn queueMenuSound(history: *GameStateHistory) void {
    if (!history.replaying) history.session.queueSound(history.backing_allocator, .menu);
}

/// Escape: close the topmost open overlay; with nothing closable open (and
/// on level/hub), open the options menu. The steps mirror the view's z-order
/// (topmost surface first; the error popup is more-modal still but is
/// consumed by the pending_error gate at the top of handleAnytimeInput).
/// Mission fail/complete reuse the exact orchestrator events their overlay
/// buttons push, so Escape ≡ clicking the button — both land on the undo
/// timeline as recorded player actions. See DESIGN → Input → Escape overlay
/// chain.
fn handleEscapeKey(history: *GameStateHistory) void {
    const current = &history.current_state;
    const ui_state = &history.session.ui_state;

    // Settings overlay (drawn above everything but the error popup). In-game
    // it opens on top of the options menu, so Escape steps back to the menu
    // underneath — only the settings layer closes.
    if (ui_state.settings_open) {
        queueMenuSound(history);
        ui_state.settings_open = false;
        return;
    }

    // Mission-fail overlay: Escape fires the same orchestrator its Exit
    // Mission button does (end_level routes PlayerData persistence + the
    // return to the hub). Undo (processed earlier in handleAnytimeInput)
    // remains the other escape from the fail state.
    if (view_mod.playerDead(current)) {
        if (current.screen != .level) return;
        queueMenuSound(history);
        pushPlayerActionAndDrain(history, .player_exit_mission);
        return;
    }

    // Mission-complete overlay: Escape fires the Continue button's
    // dismiss_mission_complete (on the undo timeline — undo re-shows, redo
    // dismisses).
    if (current.last_completed_mission != null) {
        queueMenuSound(history);
        pushPlayerActionAndDrain(history, .dismiss_mission_complete);
        return;
    }

    // Main-menu overlays (the options menu and mission overlays can never be
    // open on the main menu, so these sit topmost whenever they're up).
    if (ui_state.load_save_menu_open) {
        queueMenuSound(history);
        ui_state.load_save_menu_open = false;
        return;
    }
    if (ui_state.credits_open) {
        queueMenuSound(history);
        ui_state.credits_open = false;
        return;
    }

    // Options menu (always-on-top modal): close it, leaving any full-screen
    // overlay beneath it open.
    if (ui_state.options_menu_open) {
        queueMenuSound(history);
        ui_state.options_menu_open = false;
        return;
    }

    // Full-screen overlays (world map, full combat log): close the topmost
    // open one (the last occupied slot draws on top).
    var topmost_overlay_slot: ?usize = null;
    for (ui_state.open_full_screen_overlays, 0..) |overlay, slot_index| {
        if (overlay != null) topmost_overlay_slot = slot_index;
    }
    if (topmost_overlay_slot) |slot_index| {
        queueMenuSound(history);
        ui_state.open_full_screen_overlays[slot_index] = null;
        return;
    }

    // Nothing to close: open the options menu. It is the in-game pause/exit
    // menu — its entries (Restart/Exit Mission/Exit to Main Menu) are
    // meaningful only in level/hub; the main menu has its own button stack,
    // so Escape is a no-op there.
    if (current.screen == .main_menu) return;
    queueMenuSound(history);
    ui_state.options_menu_open = true;
}

pub fn handleAnytimeInput(
    history: *GameStateHistory,
    anytime: input.AnytimeInput,
    /// Pointer position this frame, for scroll-delta routing (skills browser
    /// scroll vs camera zoom). The skills panel is scrolled when the pointer
    /// is over one of its slots — see `skillsSlotUnderPointer`.
    pointer_position: types.ScreenPosition,
    /// Last frame's UI elements — the pointer is over what was just drawn.
    ui_elements: []const ui.UiElement,
) void {
    // Recoverable error popup is modal: when a pending error is set, only
    // `dismiss_error` and the scroll actions get through; everything else
    // (including undo/redo, the options-menu toggle, and the camera-zoom
    // wheel) is swallowed until the popup is dismissed. The state has
    // already been reverted by the time the error is set, so there is
    // nothing to undo. The wheel (`scroll_delta`) is redirected here to
    // scroll the popup body instead of zooming the camera. The scroll offset
    // is clamped in `buildErrorPopup` (the view is the only place that knows
    // `max_scroll`, which depends on the wrapped line count). See DESIGN →
    // Error Handling.
    if (history.session.pending_error != null) {
        if (anytime.dismiss_error) {
            history.session.clearPendingError();
            return;
        }
        const scroll_step: i32 = 3 * ui.error_scroll_line_height;
        if (anytime.error_scroll_up) {
            history.session.error_scroll_offset -= scroll_step;
        }
        if (anytime.error_scroll_down) {
            history.session.error_scroll_offset += scroll_step;
        }
        if (anytime.scroll_delta != 0) {
            history.session.error_scroll_offset += @intFromFloat(anytime.scroll_delta * @as(f32, @floatFromInt(scroll_step)));
        }
        return;
    }

    if (anytime.undo) {
        _ = history.undo(&event_handlers.processEvent);
    }

    if (anytime.redo) {
        _ = history.redo(&event_handlers.processEvent);
    }

    if (anytime.dump_event_log) {
        dumpEventLog(history);
    }

    if (anytime.toggle_options_menu) {
        handleEscapeKey(history);
    }

    // Options menu actions dispatch before the modal gate so they take effect
    // immediately despite the menu pausing the game. Draining is
    // pushPlayerActionAndDrain's job (see its doc for the baseline reasoning).
    if (anytime.options_action) |action| {
        const current = &history.current_state;
        const allocator = history.current_arena.allocator();
        switch (action) {
            .save_game => {
                const timestamp = formatSessionTimestamp(allocator, history.io);
                const save_path = std.fmt.allocPrint(
                    allocator,
                    "saves/save_{s}.txt",
                    .{timestamp},
                ) catch @panic("failed to format save path");
                pushPlayerActionAndDrain(history, .{ .save_game = .{ .save_path = save_path } });
            },
            // Exit-path buttons: push the player orchestrator event, then
            // drain. The orchestrator handler pushes the machinery (end_level
            // or end_hub + open_main_menu) as children. See events.zig.
            .restart_mission => {
                if (current.screen != .level) return;
                pushPlayerActionAndDrain(history, .player_restart_mission);
            },
            .exit_mission => {
                if (current.screen != .level) return;
                pushPlayerActionAndDrain(history, .player_exit_mission);
            },
            .exit_to_menu => {
                pushPlayerActionAndDrain(history, .player_exit_to_menu);
            },
            // Mission-complete overlay: Continue pushes dismiss_mission_complete
            // (on the undo timeline — undo re-shows, redo dismisses). Replay
            // re-enters the mission: end_hub syncs the hub player entity first
            // (LIFO), then start_mission reloads from the completed-mission
            // path. The overlay disappears on the screen transition (renders
            // only in the hub); undo from the level back to the hub re-shows
            // it (last_completed_mission is in the snapshot).
            .continue_after_mission => {
                pushPlayerActionAndDrain(history, .dismiss_mission_complete);
            },
            .replay_mission => {
                if (current.last_completed_mission == null) return;
                pushPlayerActionAndDrain(history, .player_replay_mission);
            },
            .overwrite_clone => {
                const info = current.last_completed_mission orelse return;
                if (!info.overwrite_offered) return;
                pushPlayerActionAndDrain(history, .player_overwrite_clone);
            },
            // Settings button (main menu OR options menu): toggle the
            // settings overlay. From the options menu it opens on top
            // (drill-in; Back returns here); from the main menu it opens
            // over the menu directly. Routed through `options_action` so
            // one handler serves both contexts. See DESIGN → UI Framework
            // → Settings screen.
            .open_settings =>
                history.session.ui_state.settings_open = !history.session.ui_state.settings_open,
            // A settings toggle or choice was clicked. The SettingRef rode
            // in `anytime.clicked_setting`. Mutate `history.settings` (a
            // direct write — settings are off the undo timeline, like
            // `ui_state` toggles) + mark dirty for debounced persistence.
            // See DESIGN → UI Framework → Settings screen.
            .change_setting => {
                const sref = anytime.clicked_setting orelse return;
                const settings = &history.settings;
                switch (sref.id) {
                    .vsync => settings.vsync = !settings.vsync,
                    .auto_skip_attack_step_out_of_combat =>
                        settings.auto_skip_attack_step_out_of_combat = !settings.auto_skip_attack_step_out_of_combat,
                    .auto_target_at_cursor =>
                        settings.auto_target_at_cursor = !settings.auto_target_at_cursor,
                    .show_fps => settings.show_fps = !settings.show_fps,
                    .camera_zoom => settings.camera_zoom = sref.choice_value orelse return,
                    .player_color_index => settings.player_color_index = sref.choice_value orelse return,
                    // Sliders are handled by the drag handler (slice 3b),
                    // not by this click path. A click on a slider label
                    // area without a choice_value is a no-op here.
                    .master_volume,
                    .music_volume,
                    .sound_effects_volume,
                    .render_fps_cap,
                    .animation_fps,
                    => return,
                }
                if (!history.replaying) history.session.queueSound(history.backing_allocator, .button_click_up);
                markSettingsDirty(history);
            },
            // Editor palette group header (expand/collapse). The group
            // index rode in `anytime.clicked_editor_group`. View-side
            // display state — a direct UiState write, off the undo timeline
            // (same class as the panel-toggle flags). Accordion: expanding
            // a group collapses the others (one group open at a time);
            // collapsing just closes the clicked one.
            .toggle_editor_palette_group => {
                const group_index = anytime.clicked_editor_group orelse return;
                if (group_index >= 3) return;
                if (history.session.ui_state.editor_palette_collapsed[group_index]) {
                    for (&history.session.ui_state.editor_palette_collapsed) |*is_collapsed| {
                        is_collapsed.* = true;
                    }
                    history.session.ui_state.editor_palette_collapsed[group_index] = false;
                } else {
                    history.session.ui_state.editor_palette_collapsed[group_index] = true;
                }
            },
            // Editor tool cell click (make it the active tool). The
            // EditorToolId rode in `anytime.clicked_editor_tool`. View-side
            // display state for now; migrates onto the Editor via
            // `editor_set_tool` when the edit-verb handlers land.
            .select_editor_tool => {
                const tool = anytime.clicked_editor_tool orelse return;
                history.session.ui_state.editor_active_tool = tool;
            },
            // Level-tab click: push the orchestrator (the EditorEvent owns
            // the mutation; the switch rides the undo timeline) and drain.
            .select_editor_level => {
                const level_index = anytime.clicked_editor_level orelse return;
                pushPlayerActionAndDrain(history, .{ .player_set_editor_level = .{
                    .level_index = level_index,
                } });
            },
            else => {},
        }
    }

    // When options menu is open, block all other input
    if (history.session.ui_state.options_menu_open) return;

    if (anytime.scroll_delta != 0) {
        // Editor palette group under the pointer, if any. Computed up front
        // (the screen + editor gating lives here, not in the chain below).
        // Geometric detection over the emitted tool cells — see
        // `ui.editorPaletteGroupAt`.
        const editor_palette_group: ?usize = if (history.current_state.screen == .editor)
            if (history.current_state.editor) |editor|
                ui.editorPaletteGroupAt(
                    editor,
                    history.session.ui_state.editor_palette_collapsed,
                    ui_elements,
                    pointer_position,
                )
            else
                null
        else
            null;
        // Load-save browser open: the wheel scrolls the save list, one full
        // row per notch (whole-row ticks keep text placement identical at
        // every offset). The panel is a fullscreen modal, so any wheel input
        // while it's open belongs to the list — never the camera (which has
        // no meaning on the main menu anyway). Upper clamp is authoritative
        // in the builder; the lower clamp here prevents negative drift.
        if (history.session.ui_state.load_save_menu_open) {
            const delta_rows: i32 = @intFromFloat(anytime.scroll_delta);
            history.session.ui_state.load_save_scroll_offset -= delta_rows;
            if (history.session.ui_state.load_save_scroll_offset < 0) {
                history.session.ui_state.load_save_scroll_offset = 0;
            }
        } else if (skillsSlotUnderPointer(ui_elements, pointer_position)) {
            const delta_rows: i32 = @intFromFloat(anytime.scroll_delta);
            history.session.ui_state.skills_scroll_offset -= delta_rows;
            if (history.session.ui_state.skills_scroll_offset < 0) {
                history.session.ui_state.skills_scroll_offset = 0;
            }
        } else if (editor_palette_group) |group_index| {
            // Editor palette window scroll (horizontal): one wheel notch =
            // one tool cell, wheel-up = earlier tools (matches the skills
            // panel's wheel-up = earlier rows). Both bounds clamped here;
            // the builder clamps in place too (authoritative).
            const editor = history.current_state.editor.?;
            const delta: i32 = @intFromFloat(anytime.scroll_delta);
            const group_size = ui.editorPaletteGroupSize(editor, group_index);
            const max_offset: i32 = @intCast(group_size -| ui.editor_palette_max_tools);
            const scrolled: i32 = @min(
                @max(history.session.ui_state.editor_palette_scroll[group_index] - delta, 0),
                max_offset,
            );
            history.session.ui_state.editor_palette_scroll[group_index] = scrolled;
        } else {
            // Additive zoom in fixed steps, clamped to [min, max]. Additive
            // (not multiplicative) so one zoom-in followed by one zoom-out
            // always returns to the exact same value. scroll_delta is
            // accumulated wheel notches (positive = scroll up = zoom in); a
            // single notch is ±1 step (25 hundredths). Only 25/50/75/100 are
            // valid, so the step lands exactly on a choice value.
            const delta_steps: i32 = @intFromFloat(anytime.scroll_delta);
            const delta: i32 = delta_steps * @as(i32, @intCast(camera_zoom_step));
            const clamped: u32 = @intCast(@max(@as(i32, @intCast(min_camera_zoom)), @min(@as(i32, @intCast(max_camera_zoom)), @as(i32, @intCast(history.settings.camera_zoom)) + delta)));
            if (clamped != history.settings.camera_zoom) {
                history.settings.camera_zoom = clamped;
                markSettingsDirty(history);
            }
        }
    }

    // Keyboard zoom shortcuts (ctrl+I / ctrl+O / ctrl+0). Same additive
    // step + bounds as the wheel. Reset snaps to the default.
    if (anytime.zoom_in) {
        const new_zoom = @min(max_camera_zoom, history.settings.camera_zoom + camera_zoom_step);
        if (new_zoom != history.settings.camera_zoom) {
            history.settings.camera_zoom = new_zoom;
            markSettingsDirty(history);
        }
    }
    if (anytime.zoom_out) {
        const new_zoom = @max(min_camera_zoom, history.settings.camera_zoom - camera_zoom_step);
        if (new_zoom != history.settings.camera_zoom) {
            history.settings.camera_zoom = new_zoom;
            markSettingsDirty(history);
        }
    }
    if (anytime.zoom_reset) {
        if (history.settings.camera_zoom != default_camera_zoom) {
            history.settings.camera_zoom = default_camera_zoom;
            markSettingsDirty(history);
        }
    }

    // In-game inputs only apply when in a hub or level
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();
    const ui_state = &history.session.ui_state;
    if (current.screen == .hub or current.screen == .level) {
        const in_game = anytime.in_game;

        if (in_game.toggle_inventory) {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .menu);
            ui_state.toggleMiddlePanel(.inventory);
        }

        if (in_game.toggle_gear) {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .menu);
            ui_state.toggleMiddlePanel(.gear);
        }

        if (in_game.toggle_skills) {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .menu);
            ui_state.toggleMiddlePanel(.skills);
        }

        if (in_game.toggle_entity_inspect) {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .menu);
            ui_state.toggleMiddlePanel(.entity_inspect);
            ui_state.inspected_entity_index = null;
        }

        // Entity inspect is also right-click driven (handleRightClickInspect,
        // run later in update); a keyboard binding for it is not wired.

        if (in_game.toggle_world_map) {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .menu);
            ui_state.toggleFullScreenOverlay(.world_map);
        }
        // Cursor resolution (mouse vs arrows vs UI occlusion) happens in a
        // dedicated step in update(), after UI arbitration — it needs
        // ui_elements + world tiles, which live in main.zig's world.

        if (in_game.swap_weapons) {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .swap_skill);
            event_handlers.pushPlayerAction(current, .swap_hands, allocator);
        }
    }
}

/// Handle inputs that are only accepted when the event stack is empty.
/// A resolved skill-bar slot press: use the skill now (auto-target hit or
/// no-targeting skill, with an optional target tile) or begin targeting
/// (prepare). Produced by `resolveSkillSlotAction` and consumed by both the
/// player_move and player_attack turn phases.
const SkillSlotAction = union(enum) {
    use: struct { skill_id: SkillId, target: ?Vector2 },
    prepare: SkillId,
};

/// Resolve a skill-bar slot press into a concrete action. Returns null when
/// the slot is empty, the skill is on cooldown, or the skill definition is
/// missing — the caller drops the input silently (matching the prior inline
/// behavior). Shared by the player_move (skip-to-skill) and player_attack
/// (in-phase) paths so both follow one resolution path. Targeting
/// resolution depends on the transient `tile_cursor` (SessionState, off
/// GameState), so it lives here in the input path, not in an event handler
/// (replay doesn't re-resolve input — the orchestrator carries the result).
fn resolveSkillSlotAction(
    history: *GameStateHistory,
    current: *GameState,
    level: *const Level,
    slot: u8,
    allocator: std.mem.Allocator,
) ?SkillSlotAction {
    const player = level.entities[0];
    const skill_id = player.skillInSlot(slot, history.weapon_type_definitions) orelse return null;
    if (player.skill_cooldowns.get(skill_id) > 0) return null;
    const skill_definition = lookups.getSkillDefinition(skill_id) orelse return null;
    if (!skill_definition.uses_targeting) {
        return .{ .use = .{ .skill_id = skill_id, .target = null } };
    }
    // Targeted skill: auto-target at the cursor if it sits on a valid target.
    if (history.settings.auto_target_at_cursor) {
        if (history.session.tile_cursor) |cursor_position| {
            const valid_targets = skill_definition.getValidTargets(0, current.*, allocator);
            if (valid_targets) |targets| {
                for (targets) |target| {
                    if (target.x == cursor_position.x and target.y == cursor_position.y) {
                        return .{ .use = .{ .skill_id = skill_id, .target = cursor_position } };
                    }
                }
            }
        }
    }
    return .{ .prepare = skill_id };
}

/// Rescan saves/ into `session.save_files`, freeing the previous list.
/// Allocation goes through the backing allocator (session-lifetime, like
/// the sound/anim queues); the only leak is the final list at process exit.
fn rescanSaveFilesNow(history: *GameStateHistory) void {
    const files = history.file_source.listSaveFiles(history.backing_allocator) catch {
        // Unreadable dir mid-session (permissions, external deletion):
        // keep the previous list rather than blanking the browser.
        return;
    };
    file_source_mod.freeSaveFiles(history.backing_allocator, history.session.save_files);
    history.session.save_files = files;
    history.session.save_files_last_scan_us = history.session.animation_clock;
}

/// Rescan interval in animation-clock microseconds. One directory iterate +
/// stat-per-file + sort per interval — cheap, but not free, so not per-frame.
const save_file_rescan_interval_us: u64 = 500_000;

/// Throttled wrapper: rescans only when the interval elapsed since the last
/// scan (the on-open scan stamps the clock, so the first periodic rescan is
/// one full interval after open).
fn rescanSaveFilesIfDue(history: *GameStateHistory) void {
    if (history.session.save_files_last_scan_us == state.SessionState.save_files_never_scanned) {
        rescanSaveFilesNow(history);
        return;
    }
    if (history.session.animation_clock - history.session.save_files_last_scan_us >=
        save_file_rescan_interval_us)
    {
        rescanSaveFilesNow(history);
    }
}

/// Consume the web import marker, if present: the picked file has landed in
/// saves/ — delete the marker, rescan (so the file shows in the list), and
/// load it. A parse failure inside the load surfaces the recoverable popup
/// and leaves the browser open with the imported file visible for retry.
fn pollImportMarker(history: *GameStateHistory) void {
    if (!history.file_source.fileExists(file_source_mod.import_marker_path)) return;

    const allocator = history.backing_allocator;
    const marker_bytes = history.file_source.readFile(allocator, file_source_mod.import_marker_path) catch {
        // Unreadable marker: delete it so we don't spin on a corrupt file;
        // the imported save (if any) still shows up via the periodic rescan.
        history.file_source.deleteFile(file_source_mod.import_marker_path) catch {};
        return;
    };
    defer allocator.free(marker_bytes);
    history.file_source.deleteFile(file_source_mod.import_marker_path) catch {};

    // The marker body is the persistent-relative save path written by the
    // import JS. Trim any trailing newline for robustness.
    const save_path = std.mem.trim(u8, marker_bytes, "\r\n");
    if (save_path.len == 0) return;

    const path_copy = allocator.dupe(u8, save_path) catch
        @panic("failed to allocate imported save path");
    rescanSaveFilesNow(history);
    event_handlers.pushPlayerAction(&history.current_state, .{ .player_load_save = .{
        .save_path = path_copy,
    } }, history.current_arena.allocator());
}

pub fn handleIdleInput(
    history: *GameStateHistory,
    idle_input: input.IdleInput,
    modifiers: input.Modifiers,
) void {
    // Enter acts as a click on the active tile cursor: fold it into
    // tile_clicked so the existing click handlers (player_move, player_attack,
    // hub) do the work — one path, no duplication. Only when a real click
    // didn't already happen this frame (a click takes precedence).
    var idle = idle_input;
    if (idle.confirm and idle.tile_clicked == null) {
        if (history.session.tile_cursor) |cursor| {
            idle.tile_clicked = cursor;
        }
    }

    const current = &history.current_state;
    const allocator = history.current_arena.allocator();

    // Main menu: menu buttons emit a menu_action (no keybind path).
    if (current.screen == .main_menu) {
        if (idle.menu_action) |action| {
            switch (action) {
                .new_game => event_handlers.pushPlayerAction(current, .start_new_game, allocator),
                // Dev entry point: open the editor on the shipped beginnings
                // mission (hardcoded path so the editor building blocks are
                // reachable).
                .open_editor => event_handlers.pushPlayerAction(current, .{ .open_editor = .{
                    .mission_path = "data/campaigns/main_campaign/missions/beginnings",
                } }, allocator),
                // Continue: resume the last game. Two branches in the handler
                // (populated PlayerData → resume from memory; empty → load the
                // autosave first).
                .continue_game => event_handlers.pushPlayerAction(current, .player_continue, allocator),
                // Load-save browser: toggle the panel; on open, scan now +
                // reset the scroll (the list may be stale from a previous
                // open or never scanned this session).
                .toggle_load_save_menu => {
                    history.session.ui_state.load_save_menu_open = !history.session.ui_state.load_save_menu_open;
                    if (history.session.ui_state.load_save_menu_open) {
                        history.session.ui_state.load_save_scroll_offset = 0;
                        rescanSaveFilesNow(history);
                    }
                },
                // A save row was clicked. The row index rode in
                // clicked_save_row (set by the button-release dispatch in
                // main.zig) and refers to the list the CLICKED BUTTON was
                // rendered from — which is why the rescan/poll below runs
                // AFTER this switch: it must not replace the list between
                // the dispatch (start of update) and this resolution.
                // Bounds-checked against the current list as a belt-and-
                // suspenders stale guard.
                .load_save_row => {
                    if (!history.session.ui_state.load_save_menu_open) return;
                    const row = idle.clicked_save_row orelse return;
                    if (row >= history.session.save_files.len) return;
                    event_handlers.pushPlayerAction(current, .{ .player_load_save = .{
                        .save_path = history.session.save_files[row].path,
                    } }, allocator);
                },
                // Web import: open the browser file picker. The picked file
                // lands in saves/ and the import marker is written; the poll
                // above picks it up next frame. No-op on native (the button
                // is never emitted there — drop files into the persistent
                // saves/ dir by hand instead).
                .import_save => file_source_mod.triggerBrowserUpload(),
                // Credits screen: toggle the panel (the Back button reuses
                // this action to close — same toggle pattern as the
                // load-save browser).
                .open_credits => history.session.ui_state.credits_open =
                    !history.session.ui_state.credits_open,
                else => {},
            }
        }

        // Load-save browser housekeeping (every frame while open, AFTER the
        // action switch — see the load_save_row arm for why). Poll the
        // import marker (web — a picked file has landed in saves/) and
        // rescan the directory on a throttle so files dropped in from
        // outside appear live. Both are acquisition steps in idle input —
        // never in an event handler (see DESIGN → Custom Missions for the
        // replay-safety rationale).
        if (history.session.ui_state.load_save_menu_open) {
            pollImportMarker(history);
            rescanSaveFilesIfDue(history);
        }
        return;
    }

    // Dev tool: skip the current level (ctrl+Enter). Gated to dev builds
    // (`-Ddev-mode`, defaulted to debug) — the binding ships in
    // default_settings.txt and no-ops in release/web builds. Pushes end_level
    // with the default continuation (next level or mission-end cascade —
    // the same path the options-menu exit uses). handleIdleInput only runs
    // with an empty stack + no active wait, so this never interleaves with a
    // draining enemy turn. See DESIGN → Input + AGENTS → Dev Tools.
    if (idle.skip_level and build_info.dev_mode and current.screen == .level) {
        event_handlers.pushPlayerAction(current, .player_skip_level, allocator);
        return;
    }

    // Editor edit mode: viewport clicks are fully modal on the active
    // tool. The press-side world/UI arbitration in update() already
    // consumed clicks over blocking UI (palette, tabs), so a surviving
    // tile_clicked is a viewport click. Enter folds into tile_clicked at
    // the top of handleIdleInput, so the keyboard path acts at the tile
    // cursor too. Landed tools: tile paint + enemy placement; the
    // decoration / item / selection tools land in later slices.
    if (current.screen == .editor) {
        if (idle.tile_clicked) |clicked_position| {
            switch (history.session.ui_state.editor_active_tool) {
                .tile => event_handlers.pushPlayerAction(current, .{ .player_paint_editor_tile = .{
                    .position = clicked_position,
                } }, allocator),
                .entity_type => |type_id| event_handlers.pushPlayerAction(current, .{ .player_place_editor_entity = .{
                    .type_id = type_id,
                    .position = clicked_position,
                } }, allocator),
                .select, .decoration_type, .item_type => {},
            }
        }
        return;
    }

    // Level turn phase input handling
    if (current.level) |*level| {
        if (level.turn_phase) |turn_phase| {
            switch (turn_phase) {
                .player_move => {
                    // Pressing a skill slot during the move step skips the
                    // move and acts in the attack step instead — no need to
                    // manually skip the move when you don't intend to move.
                    if (idle.skill_slot_selected) |slot| {
                        if (resolveSkillSlotAction(history, current, level, slot, allocator)) |action| {
                            switch (action) {
                                .use => |use| event_handlers.pushPlayerAction(current, .{ .player_skip_move_to_skill = .{
                                    .skill_id = use.skill_id,
                                    .target = use.target,
                                    .prepare = false,
                                } }, allocator),
                                .prepare => |skill_id| {
                                    if (!history.replaying) history.session.queueSound(history.backing_allocator, .button_click_up);
                                    event_handlers.pushPlayerAction(current, .{ .player_skip_move_to_skill = .{
                                        .skill_id = skill_id,
                                        .target = null,
                                        .prepare = true,
                                    } }, allocator);
                                },
                            }
                            return;
                        }
                    }

                    if (idle.tile_clicked) |clicked_position| {
                        // Check if the clicked tile is in the highlighted (reachable) set
                        var is_reachable = false;
                        for (level.highlighted_tiles) |tile| {
                            if (tile.x == clicked_position.x and tile.y == clicked_position.y) {
                                is_reachable = true;
                                break;
                            }
                        }
                        if (is_reachable) {
                            event_handlers.pushPlayerAction(current, .{ .player_move_action = .{
                                .destination = clicked_position,
                                .force_attack_step = modifiers.ctrl,
                            } }, allocator);
                        }
                    }

                    if (idle.skip) {
                        // Skip movement, go straight to attack phase
                        event_handlers.pushPlayerAction(current, .{ .player_skip_move = .{
                            .force_attack_step = modifiers.ctrl,
                        } }, allocator);
                    }
                },
                .player_attack => {
                    if (idle.skill_slot_selected) |slot| {
                        if (resolveSkillSlotAction(history, current, level, slot, allocator)) |action| {
                            switch (action) {
                                .use => |use| event_handlers.pushPlayerSkillUse(
                                    current,
                                    use.skill_id,
                                    use.target,
                                    allocator,
                                ),
                                .prepare => |skill_id| {
                                    if (!history.replaying) history.session.queueSound(history.backing_allocator, .button_click_up);
                                    event_handlers.pushPlayerAction(current, .{ .player_prepare_skill = .{
                                        .caster_index = 0,
                                        .skill_id = skill_id,
                                    } }, allocator);
                                },
                            }
                            return;
                        }
                    }

                    // Mouse path: a tile click on a highlighted (valid) tile
                    // fires the prepared skill at that tile. Mirrors how
                    // player_move consumes tile_clicked.
                    if (idle.tile_clicked) |clicked_position| {
                        if (level.prepared_skill) |skill_id| {
                            var is_valid = false;
                            for (level.highlighted_tiles) |tile| {
                                if (tile.x == clicked_position.x and tile.y == clicked_position.y) {
                                    is_valid = true;
                                    break;
                                }
                            }
                            if (is_valid) {
                                if (lookups.getSkillDefinition(skill_id) != null) {
                                    event_handlers.pushPlayerSkillUse(current, skill_id, clicked_position, allocator);
                                }
                            }
                        }
                    }

                    // Enter (confirm) is folded into tile_clicked at the top
                    // of handleIdleInput, so the mouse tile_clicked handler
                    // above already covers the keyboard path when a cursor
                    // is active.

                    if (idle.cancel) {
                        // Cancel skill targeting
                        if (level.prepared_skill != null) {
                            // Stay in player_attack phase
                            event_handlers.pushPlayerAction(current, .player_cancel_skill, allocator);
                        }
                    }

                    if (idle.skip) {
                        // Skip attack, end turn
                        event_handlers.pushPlayerAction(current, .player_skip_attack, allocator);
                    }
                },
            }
            return;
        }
    }

    if (idle.tile_clicked) |clicked_position| {
        if (current.hub) |hub| {
            // Check if an NPC is on the clicked tile
            var clicked_npc: ?u32 = null;
            for (hub.npcs, 0..) |npc, npc_index| {
                if (npc.entity.position.x == clicked_position.x and
                    npc.entity.position.y == clicked_position.y)
                {
                    clicked_npc = @intCast(npc_index);
                    break;
                }
            }

            if (clicked_npc) |npc_index| {
                event_handlers.pushPlayerAction(current, .{ .interact_with_npc = .{
                    .npc_index = npc_index,
                } }, allocator);
            } else {
                // Move to clicked tile if walkable
                var is_walkable = false;
                for (hub.hub_tiles) |tile| {
                    if (tile.x == clicked_position.x and tile.y == clicked_position.y) {
                        is_walkable = true;
                        break;
                    }
                }
                if (is_walkable) {
                    event_handlers.pushPlayerAction(current, .{ .move_player = .{
                        .destination = clicked_position,
                    } }, allocator);
                }
            }
        }
    }

}

/// Resolve the logical tile cursor (`session.tile_cursor`) for this frame.
///
/// Mouse takes precedence when it moved this tick: the cursor follows the
/// mouse, but is cleared when the pointer is over a blocking UI element (so
/// panels/buttons don't leave a world-cursor ghost) or over a non-tile. When
/// the mouse didn't move, arrow keys nudge the cursor one tile; if the cursor
/// is null, it snaps to the player's tile first. Runs in a level/hub (needs
/// world tiles + the player position); the editor screen has its own arm
/// with paint semantics (`resolveEditorTileCursor` — no tile-membership
/// check, no nudge clamp).
pub fn resolveTileCursor(
    history: *GameStateHistory,
    player_input: PlayerInput,
    ui_elements: []const ui.UiElement,
) void {
    const current = &history.current_state;

    // Editor edit mode: the tile tool's cursor — its own semantics (any tile
    // position is a legal paint target, so no tile-membership check and no
    // nudge clamp). Other tools have no tile cursor yet.
    if (current.screen == .editor) {
        resolveEditorTileCursor(history, player_input, ui_elements);
        return;
    }

    if (current.screen != .level and current.screen != .hub) return;

    const in_game = player_input.anytime.in_game;
    const world_tiles: []const types.Vector2 = if (current.level) |*level|
        level.level_tiles
    else if (current.hub) |*hub|
        hub.hub_tiles
    else
        &.{};

    if (in_game.mouse_moved_this_tick) {
        // Mouse owns the cursor this frame.
        if (ui.blockingElementAt(ui_elements, player_input.pointer.position) != null) {
            history.session.tile_cursor = null;
            return;
        }
        if (in_game.mouse_tile) |mouse_tile| {
            for (world_tiles) |tile| {
                if (tile.x == mouse_tile.x and tile.y == mouse_tile.y) {
                    history.session.tile_cursor = mouse_tile;
                    return;
                }
            }
        }
        history.session.tile_cursor = null;
        return;
    }

    // Mouse idle — arrow keys nudge the cursor. The four move_cursor_* bools
    // are the TRIGGER (an edge/repeat fired this frame); the nudge VECTOR is
    // derived from HELD cursor keys (cursor_direction), so a diagonal nudge
    // fires when any one of the two held keys edges/repeats — two physical
    // presses rarely land in one tick, and per-key repeat timers drift, so
    // requiring both to fire in the same frame was inconsistent.
    const nudge_up = in_game.move_cursor_up;
    const nudge_down = in_game.move_cursor_down;
    const nudge_left = in_game.move_cursor_left;
    const nudge_right = in_game.move_cursor_right;
    if (!nudge_up and !nudge_down and !nudge_left and !nudge_right) return;

    // Snap to the player's tile if the cursor is null.
    var cursor = history.session.tile_cursor orelse blk: {
        const player_pos = if (current.level) |*level|
            level.entities[0].position
        else if (current.hub) |*hub|
            hub.player.position
        else
            return;
        break :blk player_pos;
    };

    // Nudge by the held-key direction (each axis independently; diagonals
    // work via two held keys, opposite keys cancel).
    cursor.x += in_game.cursor_direction.x;
    cursor.y += in_game.cursor_direction.y;

    // Clamp to a real tile — if the nudged position isn't a world tile, leave
    // the cursor where it was (don't follow the cursor off the map).
    for (world_tiles) |tile| {
        if (tile.x == cursor.x and tile.y == cursor.y) {
            history.session.tile_cursor = cursor;
            return;
        }
    }
}
/// Editor arm of the tile-cursor resolution (tile tool active — see
/// `resolveTileCursor`). The cursor follows the mouse to ANY tile position
/// (cleared over blocking UI, like levels/hubs); arrow keys nudge freely —
/// there is no clamp-to-real-tile because painting over empty space is the
/// point. A null cursor snaps to the active level's player_start (the '!',
/// the editor's player-position analog).
fn resolveEditorTileCursor(
    history: *GameStateHistory,
    player_input: PlayerInput,
    ui_elements: []const ui.UiElement,
) void {
    const current = &history.current_state;
    if (history.session.ui_state.editor_active_tool != .tile) {
        history.session.tile_cursor = null;
        return;
    }

    const in_game = player_input.anytime.in_game;
    if (in_game.mouse_moved_this_tick) {
        // Mouse owns the cursor this frame.
        if (ui.blockingElementAt(ui_elements, player_input.pointer.position) != null) {
            history.session.tile_cursor = null;
            return;
        }
        history.session.tile_cursor = in_game.mouse_tile;
        return;
    }

    // Mouse idle — arrow keys nudge the cursor (same trigger/derive split
    // as levels/hubs: the move_cursor_* edges fire, the direction comes
    // from held keys).
    const nudge_up = in_game.move_cursor_up;
    const nudge_down = in_game.move_cursor_down;
    const nudge_left = in_game.move_cursor_left;
    const nudge_right = in_game.move_cursor_right;
    if (!nudge_up and !nudge_down and !nudge_left and !nudge_right) return;

    var cursor = history.session.tile_cursor orelse blk: {
        const editor = current.editor orelse return;
        if (editor.levels.len == 0) return;
        break :blk editor.levels[@min(editor.active_level_index, editor.levels.len - 1)].player_start;
    };

    cursor.x += in_game.cursor_direction.x;
    cursor.y += in_game.cursor_direction.y;
    history.session.tile_cursor = cursor;
}

test "dragToOrchestrator maps valid drags and blocks cross-domain drops" {
    // inventory → gear = player_equip_to_gear
    {
        const orchestrator = dragToOrchestrator(.{ .inventory = 2 }, .{ .gear = .boots }).?;
        try std.testing.expectEqual(@as(u32, 2), orchestrator.player_equip_to_gear.inventory_slot_index);
        try std.testing.expectEqual(types.GearSlot.boots, orchestrator.player_equip_to_gear.gear_slot);
    }
    // gear → inventory = player_unequip_from_gear
    {
        const orchestrator = dragToOrchestrator(.{ .gear = .amulet }, .{ .inventory = 5 }).?;
        try std.testing.expectEqual(types.GearSlot.amulet, orchestrator.player_unequip_from_gear.gear_slot);
        try std.testing.expectEqual(@as(u32, 5), orchestrator.player_unequip_from_gear.inventory_slot_index);
    }
    // learned skill → skill bar = player_assign_utility_skill
    {
        const orchestrator = dragToOrchestrator(.{ .learned_skill = .replenish }, .{ .skill_bar = 1 }).?;
        try std.testing.expectEqual(types.SkillId.replenish, orchestrator.player_assign_utility_skill.skill_id);
        try std.testing.expectEqual(@as(u32, 1), orchestrator.player_assign_utility_skill.slot_index);
    }
    // skill bar → skill bar = player_swap_utility_skills
    {
        const orchestrator = dragToOrchestrator(.{ .skill_bar = 0 }, .{ .skill_bar = 3 }).?;
        try std.testing.expectEqual(@as(u32, 0), orchestrator.player_swap_utility_skills.slot_a_index);
        try std.testing.expectEqual(@as(u32, 3), orchestrator.player_swap_utility_skills.slot_b_index);
    }
    // skill bar → learned skill (skills menu) = player_clear_utility_skill
    {
        const orchestrator = dragToOrchestrator(.{ .skill_bar = 2 }, .{ .learned_skill = .slice }).?;
        try std.testing.expectEqual(@as(u32, 2), orchestrator.player_clear_utility_skill.slot_index);
    }
    // inventory → inventory = player_swap_inventory_items
    {
        const orchestrator = dragToOrchestrator(.{ .inventory = 0 }, .{ .inventory = 1 }).?;
        try std.testing.expectEqual(@as(u32, 0), orchestrator.player_swap_inventory_items.slot_a_index);
        try std.testing.expectEqual(@as(u32, 1), orchestrator.player_swap_inventory_items.slot_b_index);
    }
    // Dropping back on the source slot is a no-op for every domain.
    try std.testing.expectEqual(@as(?events.PlayerInputEvent, null), dragToOrchestrator(.{ .inventory = 3 }, .{ .inventory = 3 }));
    try std.testing.expectEqual(@as(?events.PlayerInputEvent, null), dragToOrchestrator(.{ .skill_bar = 1 }, .{ .skill_bar = 1 }));

    // Cross-domain and nonsensical drops are no-ops.
    try std.testing.expectEqual(@as(?events.PlayerInputEvent, null), dragToOrchestrator(.{ .inventory = 0 }, .{ .skill_bar = 0 }));
    try std.testing.expectEqual(@as(?events.PlayerInputEvent, null), dragToOrchestrator(.{ .learned_skill = .slice }, .{ .gear = .coat }));
    try std.testing.expectEqual(@as(?events.PlayerInputEvent, null), dragToOrchestrator(.{ .gear = .coat }, .{ .gear = .boots }));
}

test "resolveItemClick: modifier precedence and double-click" {
    const none_mods: types.Modifiers = .{};
    // Plain single clicks seed no intent (awaiting a double).
    try std.testing.expectEqual(ItemIntent.none, resolveItemClick(.left, none_mods, false));
    try std.testing.expectEqual(ItemIntent.none, resolveItemClick(.right, none_mods, false));
    // Plain double-clicks fire the equip intent (left → main, right → off).
    try std.testing.expectEqual(ItemIntent.equip_main, resolveItemClick(.left, none_mods, true));
    try std.testing.expectEqual(ItemIntent.equip_off, resolveItemClick(.right, none_mods, true));
    // ctrl+click mirrors double-click (left → main, right → off), single fires.
    try std.testing.expectEqual(ItemIntent.equip_main, resolveItemClick(.left, .{ .ctrl = true }, false));
    try std.testing.expectEqual(ItemIntent.equip_off, resolveItemClick(.right, .{ .ctrl = true }, false));
    // alt swaps the button's handedness (left → off, right → main).
    try std.testing.expectEqual(ItemIntent.equip_off, resolveItemClick(.left, .{ .alt = true }, false));
    try std.testing.expectEqual(ItemIntent.equip_main, resolveItemClick(.right, .{ .alt = true }, false));
    // shift+left → salvage; shift+right → none.
    try std.testing.expectEqual(ItemIntent.salvage, resolveItemClick(.left, .{ .shift = true }, false));
    try std.testing.expectEqual(ItemIntent.none, resolveItemClick(.right, .{ .shift = true }, false));
    // Combos (2+ modifiers) are no-ops regardless of button.
    try std.testing.expectEqual(ItemIntent.none, resolveItemClick(.left, .{ .shift = true, .ctrl = true }, false));
    try std.testing.expectEqual(ItemIntent.none, resolveItemClick(.right, .{ .ctrl = true, .alt = true }, true));
    try std.testing.expectEqual(ItemIntent.none, resolveItemClick(.left, .{ .shift = true, .alt = true }, true));
}

test "isSkillLearned: found / not found" {
    const learned = [_]types.SkillId{ .slice, .bash };
    try std.testing.expect(event_handlers.isSkillLearned(&learned, .slice));
    try std.testing.expect(!event_handlers.isSkillLearned(&learned, .blink));
}


test "skillsSlotUnderPointer: true over a learned_skill slot, false elsewhere" {
    const elements = [_]ui.UiElement{
        .{ .slot = .{
            .screen_position = .{ .x = 0, .y = 0 },
            .size = 256,
            .icon_sprite_id = "ui/skill_button",
            .ref = .{ .learned_skill = .slice },
        } },
        .{ .slot = .{
            .screen_position = .{ .x = 300, .y = 0 },
            .size = 128,
            .icon_sprite_id = "ui/item_slot",
            .ref = .{ .inventory = 0 },
        } },
    };
    // Over the learned-skill slot.
    try std.testing.expect(skillsSlotUnderPointer(&elements, .{ .x = 10, .y = 10 }));
    // Over the inventory slot.
    try std.testing.expect(!skillsSlotUnderPointer(&elements, .{ .x = 310, .y = 10 }));
    // Over empty space.
    try std.testing.expect(!skillsSlotUnderPointer(&elements, .{ .x = 500, .y = 500 }));
}

test "resolveEditorTileCursor: mouse follows to any tile position, blocked over UI, nudges unclamped" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{ .player_start = .{ .x = 2, .y = 3 } }};
    var history = harness.newHistory(.{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = &levels },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });

    // Mouse owns the cursor when it moved — at a position with NO tile
    // (paint semantics: any tile position is a legal target).
    history.session.ui_state.editor_active_tool = .tile;
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .mouse_moved_this_tick = true,
            .mouse_tile = .{ .x = 9, .y = 9 },
        } }, .pointer = .{ .position = .{ .x = 500, .y = 500 } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 9, .y = 9 }, history.session.tile_cursor.?);

    // Over a blocking UI element the cursor clears (no world-cursor ghost
    // behind panels).
    const blocking_panel = [_]ui.UiElement{.{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = .{ .x = 400, .y = 400 },
        .width = 400,
        .height = 400,
    } }};
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .mouse_moved_this_tick = true,
            .mouse_tile = .{ .x = 9, .y = 9 },
        } }, .pointer = .{ .position = .{ .x = 500, .y = 500 } } },
        &blocking_panel,
    );
    try std.testing.expectEqual(@as(?types.Vector2, null), history.session.tile_cursor);

    // Non-tile tools have no cursor.
    history.session.ui_state.editor_active_tool = .select;
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .mouse_moved_this_tick = true,
            .mouse_tile = .{ .x = 9, .y = 9 },
        } }, .pointer = .{ .position = .{ .x = 500, .y = 500 } } },
        &.{},
    );
    try std.testing.expectEqual(@as(?types.Vector2, null), history.session.tile_cursor);

    // Arrow nudge with a null cursor snaps to player_start first, then
    // nudges — no clamp-to-real-tile (empty space is a legal paint target).
    history.session.ui_state.editor_active_tool = .tile;
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .move_cursor_right = true,
            .cursor_direction = .{ .x = 1, .y = 0 },
        } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 3, .y = 3 }, history.session.tile_cursor.?);
}
