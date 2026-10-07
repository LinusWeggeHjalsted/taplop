//! Pointer gesture resolution: the click-vs-drag disambiguation over the
//! shared drag threshold, the drag lifecycle (slot refs, item/skill
//! domains, click intents), camera pan, settings sliders, right-click
//! entity inspect, and the editor viewport gestures (right-click delete,
//! shift+drag marquee, selection move drag). Called from the live loop
//! (main.zig update) each frame; pushes via event_push, transient state on
//! UiState/SessionState. See DESIGN → Input + DESIGN → Level Editor →
//! Selection model.
const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const lookups = @import("generated_lookups.zig");
const ui = @import("ui.zig");
const event_handlers = @import("event_handlers.zig");
const player_handlers = @import("handlers/player.zig");
const event_push = @import("event_push.zig");
const planning = @import("editor/planning.zig");
const editor_handlers = @import("editor/handlers.zig");
const functions = @import("functions.zig");
const view_mod = @import("view.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const PlayerInput = input.PlayerInput;
const Vector2 = types.Vector2;
const Entity = types.Entity;
const SkillId = types.SkillId;
const markSettingsDirty = @import("state.zig").markSettingsDirty;
/// True when the pointer is over a skills-browser slot (a ref-bearing
/// element whose ref is `.learned_skill`). Used to route the mouse wheel to
/// skills-browser scroll instead of camera zoom. The skills panel's slots
/// are only emitted when the panel is open, so a hit here implies the panel
/// is open — no separate open-state check needed. See `handleAnytimeInput`.
pub fn skillsSlotUnderPointer(
    ui_elements: []const ui.UiElement,
    position: types.ScreenPosition,
) bool {
    const ref = ui.refAt(ui_elements, position) orelse return false;
    return switch (ref) {
        .learned_skill => true,
        else => false,
    };
}

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

/// Whether a resolved drag orchestrator would actually change state — the
/// no-op gate at the drag drop site (a drop that would change nothing never
/// fires, so it can't become a recorded no-op undo step). Mirrors the
/// machinery handlers' early-return guards: equip_item's item-fit check,
/// unequip_item's empty-source/filled-target-fit checks,
/// equip_utility_skill's same-skill re-assign, swap_utility_skills'
/// same-skill pair, unequip_utility_skill's empty slot. `skill_prepared`
/// (a level skill preparation is active) keeps the utility-skill cases
/// honest: those handlers also cancel a preparation, which IS a change.
/// Pure over the player entity — testable without input.
pub fn dragActionWouldChange(
    player: types.Entity,
    skill_prepared: bool,
    action: events.PlayerInputEvent,
) bool {
    return switch (action) {
        .player_equip_to_gear => |equip| {
            const item = player.inventory.slots[equip.inventory_slot_index] orelse return false;
            return player_handlers.itemFitsGearSlot(item, equip.gear_slot);
        },
        .player_unequip_from_gear => |unequip| {
            if (ui.gearSlotItem(player, unequip.gear_slot) == null) return false;
            const existing = player.inventory.slots[unequip.inventory_slot_index] orelse return true;
            return player_handlers.itemFitsGearSlot(existing, unequip.gear_slot);
        },
        .player_assign_utility_skill => |assign| {
            if (assign.slot_index >= player.equipped_utility_skills.len) return false;
            if (player.equipped_utility_skills[assign.slot_index] == assign.skill_id) {
                return skill_prepared;
            }
            return true;
        },
        .player_swap_utility_skills => |swap| {
            if (swap.slot_a_index >= player.equipped_utility_skills.len) return false;
            if (swap.slot_b_index >= player.equipped_utility_skills.len) return false;
            const same_skill = player.equipped_utility_skills[swap.slot_a_index] ==
                player.equipped_utility_skills[swap.slot_b_index];
            return !same_skill or skill_prepared;
        },
        .player_clear_utility_skill => |clear| {
            if (clear.slot_index >= player.equipped_utility_skills.len) return false;
            return player.equipped_utility_skills[clear.slot_index] != null or skill_prepared;
        },
        else => true,
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
        if (ui.refAt(ui_elements, pointer.position.toScreenPosition())) |ref| {
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
                    .press_position = pointer.position.toScreenPosition(),
                    .button = .left,
                    .shift_held = true,
                };
            } else if (ui.slotContentIcon(current, ref)) |icon| {
                ui_state.pending_slot_press = .{
                    .source = ref,
                    .icon_sprite_id = icon,
                    .press_position = pointer.position.toScreenPosition(),
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
            const dx = pointer.position.toScreenPosition().x - press.press_position.x;
            const dy = pointer.position.toScreenPosition().y - press.press_position.y;
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
        if (ui.refAt(ui_elements, pointer.position.toScreenPosition())) |ref| switch (ref) {
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
            // held, else cancel. Either way the selection clears. No-op
            // gate: an all-empty region (empty slots are valid region
            // corners) never fires — no dead undo step.
            if (pointer.modifiers.shift) {
                const player = ui.playerEntity(current) orelse types.Entity{};
                if (player_handlers.salvageRegionOccupiedSlots(
                    player,
                    region.start_slot,
                    region.end_slot,
                    allocator,
                ).len > 0) {
                    event_push.pushPlayerAction(current, .{ .player_salvage_inventory_region = .{
                        .start_slot = region.start_slot,
                        .end_slot = region.end_slot,
                    } }, allocator);
                }
            }
            ui_state.salvage_region = null;
            ui_state.pending_slot_press = null;
        } else if (ui_state.drag) |drag| {
            // Resolve the drop. `target` is null when the release is over empty
            // space (or non-ref UI like a panel background). A resolved
            // orchestrator (swap / assign / equip / clear) is pushed as-is.
            const target: ?ui.SlotRef = ui.refAt(ui_elements, pointer.position.toScreenPosition());
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
                // No-op gate: a drop that would change nothing (unfitting
                // item→gear or gear→occupied-slot pair, re-assigning the
                // skill already in the slot) never fires — see
                // dragActionWouldChange. The empty-entity fallback makes a
                // mid-drag screen transition (no player anymore) a safe
                // no-op drop instead of a panic.
                const player = ui.playerEntity(current) orelse types.Entity{};
                const skill_prepared = if (current.level) |level|
                    level.prepared_skill != null
                else
                    false;
                if (dragActionWouldChange(player, skill_prepared, orchestrator)) {
                    event_push.pushPlayerAction(current, orchestrator, allocator);
                }
            }
            ui_state.drag = null;
            ui_state.pending_slot_press = null;
        } else if (ui_state.pending_slot_press) |press| {
            if (press.button == .left) {
                // Release over the same slot = click; elsewhere = cancel.
                if (ui.refAt(ui_elements, pointer.position.toScreenPosition())) |target| {
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
        if (ui.refAt(ui_elements, pointer.position.toScreenPosition())) |ref| {
            // Same content gate as left-press: only occupied slots are
            // clickable (an empty slot has nothing to equip/salvage).
            if (ui.slotContentIcon(current, ref)) |icon| {
                ui_state.pending_slot_press = .{
                    .source = ref,
                    .icon_sprite_id = icon,
                    .press_position = pointer.position.toScreenPosition(),
                    .button = .right,
                };
            }
        }
    }

    // --- Right button: release → click ---
    if (pointer.right_released) {
        if (ui_state.pending_slot_press) |press| {
            if (press.button == .right and ui_state.drag == null) {
                if (ui.refAt(ui_elements, pointer.position.toScreenPosition())) |target| {
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
            event_push.pushPlayerAction(current, .{ .player_use_inventory_item = .{
                .inventory_slot_index = slot_index,
                .off_hand = intent == .equip_off,
            } }, allocator);
            ui_state.last_item_click = null; // consumed
        },
        .salvage => {
            event_push.pushPlayerAction(current, .{ .player_salvage_inventory_item = .{
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
/// The pan ENGAGES only once the pointer moves beyond
/// `ui.drag_threshold_pixels` from the right-press: the press records the
/// anchor (the world point under it) but a sub-threshold wiggle pans nothing,
/// so a clean right-click stays clean (the pending-right-click gestures
/// cancel at this same threshold). Once engaged the pan latches — a wiggle
/// back near the press point keeps panning.
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
        if (ui.blockingElementAt(ui_elements, pointer.position.toScreenPosition()) != null) {
            session.camera_pan_anchor = null;
            session.camera_pan_press = null;
            return;
        }
        const world = input.floatWorldPoint(pointer.position, camera, camera_zoom, viewport);
        session.camera_pan_anchor = .{ .world_x = world.x, .world_y = world.y };
        session.camera_pan_press = pointer.position;
        return;
    }

    // No active drag — nothing to do on held/moved/released.
    if (session.camera_pan_anchor == null) {
        if (pointer.right_released) {
            session.camera_pan_anchor = null;
            session.camera_pan_press = null;
        }
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
        // Threshold gate: until the pointer moves beyond the drag threshold
        // there is no pan (a sub-threshold wiggle pans nothing, so a clean
        // right-click stays clean — the pending-right-click gestures cancel
        // at this same threshold). Crossing it drops the press record,
        // latching the pan engaged: a later wiggle back near the press point
        // keeps panning. Strict `>` matches the other drag gestures.
        if (session.camera_pan_press) |press| {
            // Full-precision pointer math (press + cursor both f32) — the
            // threshold compare runs in float against the i32 threshold.
            const dx = pointer.position.x - press.x;
            const dy = pointer.position.y - press.y;
            const threshold: f32 = @floatFromInt(ui.drag_threshold_pixels);
            if (dx * dx + dy * dy <= threshold * threshold) return;
            session.camera_pan_press = null;
        }
        const tile_pixels = input.tile_size_pixels * camera_zoom;
        const anchor = session.camera_pan_anchor.?;
        const cursor_x: f32 = pointer.position.x;
        const cursor_y: f32 = pointer.position.y;
        const target_camera_x = anchor.world_x * tile_pixels - (cursor_x - viewport.width / 2.0);
        const target_camera_y = anchor.world_y * tile_pixels - (cursor_y - viewport.height / 2.0);

        // Unclamped (view_region null): the solve's pan is relative to the
        // recentered camera, and the clamp applies downstream — so the
        // grabbed point stays exactly under the cursor in the level
        // interior, with resistance only at the level edges.
        const player_centered = view_mod.computeCamera(current, camera_zoom, null, null);
        session.camera_pan = .{
            .x = @intFromFloat(@round(target_camera_x - @as(f32, @floatFromInt(player_centered.position.x)))),
            .y = @intFromFloat(@round(target_camera_y - @as(f32, @floatFromInt(player_centered.position.y)))),
        };
    }

    if (pointer.right_released) {
        session.camera_pan_anchor = null;
        session.camera_pan_press = null;
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
    if (!history.current_state.ui_surfaces.settings_open) {
        if (session.ui_state.active_slider != null) session.ui_state.active_slider = null;
        return;
    }

    // Left-press over a slider begins a drag + jumps to the pointer.
    if (pointer.pressed) {
        if (ui.sliderAt(ui_elements, pointer.position.toScreenPosition())) |slider| {
            session.ui_state.active_slider = slider.setting_id;
            applySliderValue(history, slider, pointer.position.toScreenPosition().x);
        }
    }

    // Left-held with an active slider: scrub (find the slider for the active
    // setting in the current UI + apply the value from the pointer x).
    if (pointer.held and session.ui_state.active_slider != null) {
        if (ui.findSlider(ui_elements, session.ui_state.active_slider.?)) |slider| {
            applySliderValue(history, slider, pointer.position.toScreenPosition().x);
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

    // Levels only. Not our screen — drop only OUR kind of pending (the
    // editor screen's delete gesture owns the field there; see
    // PendingRightClick).
    if (current.screen != .level) {
        clearPendingRightClick(ui_state, .inspect);
        return;
    }
    const level = current.level orelse {
        clearPendingRightClick(ui_state, .inspect);
        return;
    };

    // Right-press: if over a world tile (not blocking UI) with a LIVING
    // entity, record a pending right-click. Over blocking UI, an empty
    // tile, or a tile holding only corpses, clear any stale pending (a
    // right-click on a panel, empty ground, or a corpse inspects nothing).
    if (pointer.right_pressed) {
        if (ui.blockingElementAt(ui_elements, pointer.position.toScreenPosition()) != null) {
            clearPendingRightClick(ui_state, .inspect);
            return;
        }
        const mouse_tile = input.screenToTile(
            pointer.position,
            camera,
            camera_zoom,
            viewport,
        );
        // First ALIVE entity on the tile wins: corpses keep their tile
        // (death removes nothing from the entities array) and living
        // entities can stand on one (dead entities don't block movement),
        // so a lower-index corpse must not shadow the living entity on its
        // tile — skip the dead, keep scanning.
        for (level.entities, 0..) |entity, index| {
            if (entity.current_health == 0) continue;
            if (entity.position.x == mouse_tile.x and entity.position.y == mouse_tile.y) {
                ui_state.pending_right_click = .{ .inspect = .{
                    .entity_index = @intCast(index),
                    .press_position = pointer.position.toScreenPosition(),
                } };
                return;
            }
        }
        clearPendingRightClick(ui_state, .inspect);
        return;
    }

    // Movement beyond the threshold cancels the pending right-click (it
    // became a camera pan). Checked on every call while the right button is
    // held. Uses `>` (strict) so a zero-threshold config still tolerates a
    // no-movement press+release — `0 > 0` is false, so a clean click survives.
    // Same convention as the inventory drag promotion in `handleDrag`.
    if (ui_state.pending_right_click) |press| {
        switch (press) {
            .inspect => |pending| {
                if (pointer.right_held) {
                    const dx = pointer.position.toScreenPosition().x - pending.press_position.x;
                    const dy = pointer.position.toScreenPosition().y - pending.press_position.y;
                    if (dx * dx + dy * dy > ui.drag_threshold_pixels * ui.drag_threshold_pixels) {
                        ui_state.pending_right_click = null;
                    }
                }
            },
            else => {},
        }
    }

    // Right-release: if a pending right-click survived (no threshold
    // crossing), toggle inspect on that entity.
    if (pointer.right_released) {
        if (ui_state.pending_right_click) |press| {
            switch (press) {
                .inspect => |pending| {
                    // Resolve the gesture's intent against the current
                    // surface state (GameState — the entity-inspect surface
                    // rides the undo timeline): same target → close,
                    // different → retarget, none → open. One orchestrator
                    // carries the RESOLVED intent; the update() stack branch
                    // processes it this frame. See DESIGN → UI Framework →
                    // UI state classification.
                    const surfaces = &history.current_state.ui_surfaces;
                    const resolved: ?u32 =
                        if (surfaces.isSurfaceOpen(.entity_inspect) and
                            surfaces.inspected_entity_index == pending.entity_index)
                            null
                        else
                            pending.entity_index;
                    event_push.pushPlayerAction(
                        &history.current_state,
                        .{ .player_inspect_entity = .{
                            .entity_index = resolved,
                        } },
                        history.current_arena.allocator(),
                    );
                },
                else => {},
            }
        }
        clearPendingRightClick(ui_state, .inspect);
    }
}

/// Drop the pending right-click if it is of `kind` (a no-op otherwise —
/// each right-click handler owns only its own kind; see PendingRightClick).
fn clearPendingRightClick(
    ui_state: *ui.UiState,
    kind: std.meta.Tag(ui.PendingRightClick),
) void {
    if (ui_state.pending_right_click) |press| {
        if (std.meta.activeTag(press) == kind) ui_state.pending_right_click = null;
    }
}

/// Editor-screen right-click: the TOOL-INDEPENDENT delete. One clean
/// click deletes ONE thing at the pressed tile — priority: enemy / ground
/// item occupant, then covering decoration, then the bare tile; the '!' /
/// '=' and empty ground are no-ops. All of that policy lives in the shared
/// planner (`planEditorDeleteActions` — the pushed handler consumes the
/// same plan); this handler owns the gesture + the no-op gate (a click
/// whose plan is empty never fires, so it can't become an undo/replay
/// step). Same movement-threshold lifecycle as the inspect right-click: a
/// right-drag pans the camera (handleCameraPan) and cancels the pending; a
/// clean release fires the delete. The pressed tile is recorded at PRESS
/// (a clean click acts on what was under the pointer when the button went
/// down).
pub fn handleRightClickEditorDelete(
    history: *GameStateHistory,
    pointer: input.PointerInput,
    ui_elements: []const ui.UiElement,
    camera: types.Camera,
    camera_zoom: f32,
    viewport: input.ViewportSize,
) void {
    const current = &history.current_state;
    const ui_state = &history.session.ui_state;

    // Editor edit mode only (playtest/validate are the .level screen,
    // where the inspect handler owns right-clicks). Not our screen — drop
    // only OUR kind of pending.
    if (current.screen != .editor or current.editor == null) {
        clearPendingRightClick(ui_state, .editor_delete);
        return;
    }

    if (pointer.right_pressed) {
        if (ui.blockingElementAt(ui_elements, pointer.position.toScreenPosition()) != null) {
            clearPendingRightClick(ui_state, .editor_delete);
            return;
        }
        const mouse_tile = input.screenToTile(
            pointer.position,
            camera,
            camera_zoom,
            viewport,
        );
        ui_state.pending_right_click = .{ .editor_delete = .{
            .position = mouse_tile,
            .press_position = pointer.position.toScreenPosition(),
        } };
        return;
    }

    // Movement beyond the threshold cancels the pending (the press became
    // a camera pan). `>` strict, same convention as the inspect handler.
    if (ui_state.pending_right_click) |press| {
        switch (press) {
            .editor_delete => |pending| {
                if (pointer.right_held) {
                    const dx = pointer.position.toScreenPosition().x - pending.press_position.x;
                    const dy = pointer.position.toScreenPosition().y - pending.press_position.y;
                    if (dx * dx + dy * dy > ui.drag_threshold_pixels * ui.drag_threshold_pixels) {
                        ui_state.pending_right_click = null;
                    }
                }
            },
            else => {},
        }
    }

    if (pointer.right_released) {
        if (ui_state.pending_right_click) |press| {
            switch (press) {
                .editor_delete => |pending| {
                    // No-op gate: empty ground / the '!' / '=' never fire
                    // (see planEditorDeleteActions).
                    if (current.editor) |*editor| {
                        const arena = history.current_arena.allocator();
                        const plan = planning.planEditorDeleteActions(editor, pending.position, arena);
                        if (plan.len > 0) {
                            event_push.pushPlayerAction(current, .{ .player_delete_editor_at = .{
                                .position = pending.position,
                            } }, arena);
                        }
                    }
                },
                else => {},
            }
        }
        clearPendingRightClick(ui_state, .editor_delete);
    }
}

/// Editor-screen shift+left-drag: the select tool's MARQUEE. A press with
/// Shift held over the viewport records the press tile; moving beyond the
/// drag threshold promotes the gesture (the rectangle renders, the end
/// corner tracks the pointer live); release with Shift STILL held adds
/// everything inside the region (`player_select_editor_region` — skipping
/// already-selected entries; the marquee never removes). Shift released
/// mid-drag cancels. An UNPROMOTED release (no drag) IS the shift+click
/// TOGGLE path: the toggle fires at the press tile (the select arm in
/// `handleIdleInput` defers to this gesture while Shift is held; a plain
/// click there would REPLACE) — fired here with the same no-op gate. Mirrors the
/// inventory salvage-region gesture (`handleDrag`) + the right-click
/// clean-click disambiguation (`handleRightClickEditorDelete`).
pub fn handleEditorMarquee(
    history: *GameStateHistory,
    pointer: input.PointerInput,
    ui_elements: []const ui.UiElement,
    camera: types.Camera,
    camera_zoom: f32,
    viewport: input.ViewportSize,
) void {
    const current = &history.current_state;
    const ui_state = &history.session.ui_state;

    // Editor edit mode + the select tool only. Not our context — clear any
    // in-progress marquee (a stale gesture must not fire later).
    if (current.screen != .editor or current.editor == null or
        current.editor.?.active_tool != .select)
    {
        ui_state.editor_marquee = null;
        return;
    }

    if (pointer.pressed) {
        // Only a Shift press starts a marquee (Shift acquired mid-drag does
        // not); a press over blocking UI belongs to the panel, never the
        // world.
        if (!pointer.modifiers.shift) return;
        if (ui.blockingElementAt(ui_elements, pointer.position.toScreenPosition()) != null) return;
        const press_tile = input.screenToTile(
            pointer.position,
            camera,
            camera_zoom,
            viewport,
        );
        ui_state.editor_move_drag = null;
        ui_state.editor_marquee = .{
            .start_position = press_tile,
            .end_position = press_tile,
            .press_position = pointer.position.toScreenPosition(),
            .promoted = false,
        };
        return;
    }

    if (ui_state.editor_marquee) |*marquee| {
        // Promotion: movement beyond the threshold (strict `>` — a
        // zero-threshold config still tolerates a no-movement press+
        // release as a click; same convention as the inventory drag +
        // right-click cancel).
        if (pointer.held) {
            const dx = pointer.position.toScreenPosition().x - marquee.press_position.x;
            const dy = pointer.position.toScreenPosition().y - marquee.press_position.y;
            if (dx * dx + dy * dy > ui.drag_threshold_pixels * ui.drag_threshold_pixels) {
                marquee.promoted = true;
            }
        }
        // The end corner tracks the pointer live, but only over the
        // viewport (not blocking UI) — a release over a panel fires the
        // LAST VALID region (inventory salvage-region behavior: the region
        // keeps the last valid corner).
        if (pointer.held and marquee.promoted and
            ui.blockingElementAt(ui_elements, pointer.position.toScreenPosition()) == null)
        {
            marquee.end_position = input.screenToTile(
                pointer.position,
                camera,
                camera_zoom,
                viewport,
            );
        }
    }

    if (pointer.released) {
        if (ui_state.editor_marquee) |marquee| {
            if (marquee.promoted) {
                // Shift still held at release → add the region (no-op gate:
                // an empty or all-already-selected region never fires — no
                // dead undo step); Shift released mid-drag → cancel.
                if (pointer.modifiers.shift) {
                    if (current.editor) |*editor| {
                        const arena = history.current_arena.allocator();
                        if (planning.planEditorRegionSelectActions(
                            editor,
                            marquee.start_position,
                            marquee.end_position,
                            arena,
                        ).len > 0) {
                            event_push.pushPlayerAction(current, .{ .player_select_editor_region = .{
                                .start_position = marquee.start_position,
                                .end_position = marquee.end_position,
                            } }, arena);
                        }
                    }
                }
            } else {
                // No drag: the shift+click TOGGLE — fire it at the press
                // tile (the same no-op gate: empty ground never fires).
                if (current.editor) |*editor| {
                    const arena = history.current_arena.allocator();
                    if (planning.planEditorSelectionActions(
                        editor,
                        marquee.start_position,
                        arena,
                    ).len > 0) {
                        event_push.pushPlayerAction(current, .{ .player_toggle_editor_selection = .{
                            .position = marquee.start_position,
                        } }, arena);
                    }
                }
            }
        }
        ui_state.editor_marquee = null;
    }
}

/// Editor-screen selection MOVE drag (select tool, plain left press on a
/// selected thing OR on an unselected-but-selectable thing). Press claims
/// the gesture when the press tile hits the selection (a selected tile /
/// entity / item, a selected decoration's footprint, or a selected '!' /
/// '=' — see `editorSelectionContainsPosition`) or has a nonempty click
/// group (`editorClickGroupNonempty`; empty ground never claims, so the
/// click-to-deselect and a drag from empty ground are unchanged); the
/// drag threshold promotes it (the view translates the OUTLINES by the
/// live delta — the selection for a `selected_at_press` claim, the
/// grabbed group for an unselected one — the world stays put). Release
/// commits the move when the delta is nonzero
/// (`player_move_editor_selection` — see its doc for the clear +
/// chained-place semantics) and CLEARS the selection (a move deselects).
/// An unselected-claim release fires the replace + move CHAIN: the
/// replace is pushed SECOND (on top) so the LIFO drain selects the group
/// FIRST and the move orchestrator plans against the replaced selection;
/// both actions are pushed in the same frame, so the pair drains in one
/// drain and shares one idle point — a single undo step reverts the
/// whole drag. A zero delta drops just the replace (the
/// grab-and-drop-in-place = selected, like a click). An UNPROMOTED
/// release (no movement) acts as a plain click — the REPLACE fires at the
/// press tile (the select arm in `handleIdleInput` defers while a move
/// drag is in progress; usually a no-op for a selected-at-press claim,
/// since the pressed thing is selected). Shift+press never claims (the
/// marquee owns it); a press over blocking UI never claims.
pub fn handleEditorMoveDrag(
    history: *GameStateHistory,
    pointer: input.PointerInput,
    ui_elements: []const ui.UiElement,
    camera: types.Camera,
    camera_zoom: f32,
    viewport: input.ViewportSize,
) void {
    const current = &history.current_state;
    const ui_state = &history.session.ui_state;

    // Editor edit mode + the select tool only. Not our context — clear any
    // in-progress drag (a stale gesture must not fire later).
    if (current.screen != .editor or current.editor == null or
        current.editor.?.active_tool != .select)
    {
        ui_state.editor_move_drag = null;
        return;
    }

    if (pointer.pressed) {
        // A Shift press belongs to the marquee gesture; a press over
        // blocking UI belongs to the panel.
        if (pointer.modifiers.shift) return;
        if (ui.blockingElementAt(ui_elements, pointer.position.toScreenPosition()) != null) return;
        const press_tile = input.screenToTile(
            pointer.position,
            camera,
            camera_zoom,
            viewport,
        );
        const arena = history.current_arena.allocator();
        const selected_at_press = planning.editorSelectionContainsPosition(
            &current.editor.?,
            press_tile,
            arena,
        );
        // A press on an UNSELECTED thing claims too when it is
        // selectable (a nonempty click group). Empty ground claims
        // nothing — its click-to-deselect stays the plain release path.
        const claims = selected_at_press or planning.editorClickGroupNonempty(
            &current.editor.?,
            press_tile,
            arena,
        );
        if (!claims) return;
        ui_state.editor_marquee = null;
        ui_state.editor_move_drag = .{
            .press_position_tile = press_tile,
            .current_position_tile = press_tile,
            .press_position = pointer.position.toScreenPosition(),
            .promoted = false,
            .selected_at_press = selected_at_press,
        };
        return;
    }

    if (ui_state.editor_move_drag) |*move_drag| {
        // Promotion: movement beyond the threshold (strict `>`, the house
        // convention — a no-movement press+release stays a click).
        if (pointer.held) {
            const dx = pointer.position.toScreenPosition().x - move_drag.press_position.x;
            const dy = pointer.position.toScreenPosition().y - move_drag.press_position.y;
            if (dx * dx + dy * dy > ui.drag_threshold_pixels * ui.drag_threshold_pixels) {
                move_drag.promoted = true;
            }
        }
        // The live delta tracks the pointer, but only over the viewport
        // (not blocking UI) — a release over a panel commits the LAST
        // VALID delta (the marquee's end-corner behavior).
        if (pointer.held and move_drag.promoted and
            ui.blockingElementAt(ui_elements, pointer.position.toScreenPosition()) == null)
        {
            move_drag.current_position_tile = input.screenToTile(
                pointer.position,
                camera,
                camera_zoom,
                viewport,
            );
        }
    }

    if (pointer.released) {
        if (ui_state.editor_move_drag) |move_drag| {
            const arena = history.current_arena.allocator();
            if (move_drag.promoted) {
                const delta = types.Vector2{
                    .x = move_drag.current_position_tile.x - move_drag.press_position_tile.x,
                    .y = move_drag.current_position_tile.y - move_drag.press_position_tile.y,
                };
                const nonzero_delta = delta.x != 0 or delta.y != 0;
                // The move's no-op gate (the planners-shared-with-the-input
                // convention): a VETOED move — the drag would land a marker
                // on the other marker — never fires (no dead undo step). The
                // unselected-claim path evaluates against the click group at
                // the press tile (the replace drains first, so THAT is the
                // selection the move will plan against); the selected path
                // evaluates against the current selection. See
                // planning.editorSelectionMoveVetoed. The editor is
                // non-null here (the gesture's context guard).
                const editor = &current.editor.?;
                const selection_to_move: []const types.Selectable = if (move_drag.selected_at_press)
                    editor.selection
                else
                    planning.editorClickGroup(editor, move_drag.press_position_tile, arena);
                const move_fires = nonzero_delta and
                    !planning.editorSelectionMoveVetoed(editor, selection_to_move, delta);
                if (!move_drag.selected_at_press) {
                    // An unselected-claim drag: select the grabbed group
                    // AND move it. The replace is pushed SECOND (on top of
                    // the move) so the LIFO drain runs it first and the
                    // move orchestrator then plans against the replaced
                    // selection. Both actions push in this one frame, so
                    // they drain together and share one idle point — a
                    // single undo step reverts the whole drag. Zero delta
                    // is the grab-and-drop-in-place: just the replace (the
                    // thing ends up selected, like a click). An empty
                    // replace plan (the selection already IS the group —
                    // reachable only via a mid-drag selection change)
                    // skips the replace; the move still runs.
                    const replace_plan_nonempty =
                        planning.planEditorReplaceSelectionActions(
                            editor,
                            move_drag.press_position_tile,
                            arena,
                        ).len > 0;
                    if (move_fires) {
                        event_push.pushPlayerAction(
                            current,
                            .{ .player_move_editor_selection = .{ .delta = delta } },
                            arena,
                        );
                    }
                    if (replace_plan_nonempty) {
                        event_push.pushPlayerAction(current, .{ .player_replace_editor_selection = .{
                            .position = move_drag.press_position_tile,
                        } }, arena);
                    }
                } else if (move_fires) {
                    // A vetoed or zero-delta move → no event (no dead undo
                    // step). The commit machinery handles everything else.
                    event_push.pushPlayerAction(
                        current,
                        .{ .player_move_editor_selection = .{ .delta = delta } },
                        arena,
                    );
                }
            } else {
                // No drag: a plain click — fire the REPLACE at the press
                // tile (the same path + no-op gate as the select arm; a
                // plain click on the whole current selection changes
                // nothing and never fires).
                if (current.editor) |*editor| {
                    if (planning.planEditorReplaceSelectionActions(
                        editor,
                        move_drag.press_position_tile,
                        arena,
                    ).len > 0) {
                        event_push.pushPlayerAction(current, .{ .player_replace_editor_selection = .{
                            .position = move_drag.press_position_tile,
                        } }, arena);
                    }
                }
            }
        }
        ui_state.editor_move_drag = null;
    }
}

/// Editor tile-tool PAINT drag (tile tool active, plain left press over
/// the viewport). The press claims the gesture — and the tile directly
/// under the cursor paints immediately, so a clean click is the same paint
/// the idle-input arm always fired (same planner, same no-op gate; the arm
/// defers while the drag is active so a claimed press can't double-fire).
/// While the button is held, each tile the pointer ENTERS that the drag
/// hasn't visited yet paints the same way; the visited set
/// (`SessionState.editor_tile_drag_visited`, reset at press) stops re-
/// fires when the pointer wiggles back over painted ground, and the
/// planner's no-op gate additionally skips already-complete tiles the
/// drag merely crosses. Paints fire only at an EMPTY event stack: a plan
/// computed while earlier events sit unprocessed could reference
/// placement indices those events are about to shift (the decoration-
/// delete hazard; the chained selection-move planner exists for the same
/// reason), and a paint drains within a frame anyway. Over blocking UI the
/// drag PAUSES (no paint, no visited marks — the marquee's last-valid-
/// corner rule); painting resumes on re-entry at whatever tile is under
/// the pointer. Release (or context loss — tool switch away from tile,
/// tab/screen change) ends the drag. Mirrors the marquee + move-drag
/// gestures (input_gestures.zig); undo granularity is per tile by design
/// (see `editor_set_tile` in events.zig).
pub fn handleEditorTileDrag(
    history: *GameStateHistory,
    pointer: input.PointerInput,
    ui_elements: []const ui.UiElement,
    camera: types.Camera,
    camera_zoom: f32,
    viewport: input.ViewportSize,
) void {
    const current = &history.current_state;
    const ui_state = &history.session.ui_state;

    // Editor edit mode + the tile tool only. Not our context — clear any
    // in-progress drag (a stale gesture must not fire later).
    if (current.screen != .editor or current.editor == null or
        current.editor.?.active_tool != .tile)
    {
        ui_state.editor_tile_drag = false;
        return;
    }

    if (pointer.pressed) {
        // A press over blocking UI belongs to the panel — the drag never
        // starts there, and dragging out of a panel onto the world paints
        // nothing (the press wasn't a world press).
        if (ui.blockingElementAt(ui_elements, pointer.position.toScreenPosition()) != null) return;
        ui_state.editor_tile_drag = true;
        history.session.editor_tile_drag_visited.clearRetainingCapacity();
    }

    if (!ui_state.editor_tile_drag) return;
    if (pointer.released) {
        ui_state.editor_tile_drag = false;
        return;
    }
    // `held` is true on the press tick too (the input state marks the
    // button held at the press edge), so the press tile paints in this
    // same call — "as soon as the drag begins".
    if (!pointer.held or current.event_stack.len != 0 or
        ui.blockingElementAt(ui_elements, pointer.position.toScreenPosition()) != null)
    {
        return;
    }
    const tile = input.screenToTile(
        pointer.position,
        camera,
        camera_zoom,
        viewport,
    );
    for (history.session.editor_tile_drag_visited.items) |seen| {
        if (seen.x == tile.x and seen.y == tile.y) return;
    }
    history.session.editor_tile_drag_visited.append(history.backing_allocator, tile) catch
        @panic("failed to append tile-drag visited entry");
    if (current.editor) |*editor| {
        const arena = history.current_arena.allocator();
        if (planning.planEditorTilePaintActions(editor, tile, arena).len > 0) {
            event_push.pushPlayerAction(current, .{ .player_paint_editor_tile = .{
                .position = tile,
            } }, arena);
        }
    }
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


test "handleRightClickInspect: first LIVING entity on the tile wins; corpse tiles inspect nothing" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const harness_module = @import("test_harness.zig");
    var harness = harness_module.Harness.init(backing.allocator());

    // A corpse and a living entity SHARE tile (1,1) — the corpse has the
    // LOWER index, so a first-match loop would shadow the living one. A
    // lone corpse sits at (2,2). Entity 0 is a living player elsewhere.
    var player: types.Entity = .{};
    player.position = .{ .x = 0, .y = 0 };
    player.current_health = 30;
    var corpse: types.Entity = .{};
    corpse.position = .{ .x = 1, .y = 1 };
    corpse.current_health = 0;
    var living: types.Entity = .{};
    living.position = .{ .x = 1, .y = 1 };
    living.current_health = 10;
    var lone_corpse: types.Entity = .{};
    lone_corpse.position = .{ .x = 2, .y = 2 };
    lone_corpse.current_health = 0;
    const entities = [_]types.Entity{ player, corpse, living, lone_corpse };
    const tiles = [_]types.Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 },
    };
    var history = harness.newHistory(harness_module.levelStateWithEntities(
        backing.allocator(),
        &entities,
        &tiles,
    ));

    // The editor-marquee test's camera math: screen center = tile (0,0),
    // +256px per tile, zoom 1, reference viewport.
    const camera = types.Camera{ .position = .{ .x = 128, .y = 128 } };
    const viewport = input.ViewportSize{ .width = 3840, .height = 2160 };
    const center = input.PointerPosition{ .x = 1920, .y = 1080 };
    const at = struct {
        fn call(tile: types.Vector2) input.PointerPosition {
            return .{
                .x = center.x + @as(f32, @floatFromInt(tile.x)) * 256,
                .y = center.y + @as(f32, @floatFromInt(tile.y)) * 256,
            };
        }
    }.call;

    // Right-press on the shared tile: the LIVING entity (index 2) wins
    // over the lower-index corpse on the same tile.
    handleRightClickInspect(
        &history,
        .{ .right_pressed = true, .position = at(.{ .x = 1, .y = 1 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    const shared_pending = history.session.ui_state.pending_right_click.?;
    try std.testing.expect(shared_pending == .inspect);
    try std.testing.expectEqual(@as(u32, 2), shared_pending.inspect.entity_index);

    // Right-press on the lone corpse's tile: nothing to inspect — the
    // stale pending from the press above is cleared.
    handleRightClickInspect(
        &history,
        .{ .right_pressed = true, .position = at(.{ .x = 2, .y = 2 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.pending_right_click == null);

    // Release resolution: a clean release on the living entity's tile
    // pushes `player_inspect_entity` (the resolved intent) — drained, it
    // opens the entity-inspect surface on that entity. A second
    // press+release on the SAME entity resolves to CLOSE. See DESIGN →
    // UI Framework → UI state classification.
    const event_handlers_mod = @import("event_handlers.zig");
    const press_release = struct {
        fn call(
            history_ptr: *state.GameStateHistory,
            position: input.PointerPosition,
        ) void {
            handleRightClickInspect(
                history_ptr,
                .{ .right_pressed = true, .position = position },
                &.{},
                camera,
                1.0,
                viewport,
            );
            handleRightClickInspect(
                history_ptr,
                .{ .right_released = true, .position = position },
                &.{},
                camera,
                1.0,
                viewport,
            );
        }
    }.call;

    const living_tile: types.Vector2 = .{ .x = 1, .y = 1 };
    press_release(&history, at(living_tile));
    while (history.current_state.event_stack.len > 0) {
        event_handlers_mod.processEvent(&history);
    }
    try std.testing.expect(history.current_state.ui_surfaces.isSurfaceOpen(.entity_inspect));
    try std.testing.expectEqual(
        @as(?u32, 2),
        history.current_state.ui_surfaces.inspected_entity_index,
    );

    // Same entity again — the resolved intent is CLOSE.
    press_release(&history, at(living_tile));
    while (history.current_state.event_stack.len > 0) {
        event_handlers_mod.processEvent(&history);
    }
    try std.testing.expect(!history.current_state.ui_surfaces.isSurfaceOpen(.entity_inspect));
    try std.testing.expectEqual(
        @as(?u32, null),
        history.current_state.ui_surfaces.inspected_entity_index,
    );
}
