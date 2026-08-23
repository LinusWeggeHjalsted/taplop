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
const lookups = @import("generated_lookups.zig");
const ui = @import("ui.zig");
const event_handlers = @import("event_handlers.zig");
const view_mod = @import("view.zig");
const build_info = @import("build_info");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;

/// Mouse-wheel zoom cadence + bounds. Additive in fixed steps (one zoom-in
/// then one zoom-out returns to the exact same value — no float drift).
/// Default 0.5; scroll up zooms in, scroll down zooms out. The minimum is
/// always one step (so the floor divides evenly into the range). Tune from
/// feel; if linear spacing feels uneven across the range, swap the additive
/// step for a generated level table (a localized change here).
const camera_zoom_step: f32 = 0.25;
const min_camera_zoom: f32 = camera_zoom_step;
const max_camera_zoom: f32 = 1.0;
const default_camera_zoom: f32 = 0.5;
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

pub fn dragToEvent(from: ui.SlotRef, to: ui.SlotRef) ?Event {
    return switch (from) {
        .inventory => |inventory_index| switch (to) {
            .gear => |gear_slot| .{ .player_event = .{ .equip_item = .{
                .inventory_slot_index = inventory_index,
                .gear_slot = gear_slot,
            } } },
            else => null, // inventory→inventory move + skill targets: no handler
        },
        .gear => |gear_slot| switch (to) {
            .inventory => |inventory_index| .{ .player_event = .{ .unequip_item = .{
                .gear_slot = gear_slot,
                .inventory_slot_index = inventory_index,
            } } },
            else => null,
        },
        .learned_skill => |skill_id| switch (to) {
            .skill_bar => |slot_index| .{ .player_event = .{ .equip_utility_skill = .{
                .skill_id = skill_id,
                .slot_index = slot_index,
            } } },
            else => null,
        },
        .skill_bar => |from_index| switch (to) {
            .skill_bar => |to_index| .{ .player_event = .{ .swap_utility_skills = .{
                .slot_a_index = from_index,
                .slot_b_index = to_index,
            } } },
            // Dropping a bar skill back onto the skills menu clears the slot.
            .learned_skill => .{ .player_event = .{ .unequip_utility_skill = .{
                .slot_index = from_index,
            } } },
            else => null,
        },
    };
}

/// Pointer-driven drag lifecycle. Runs every tick (anytime): press over a
/// slot with content begins a drag; release hit-tests the target slot and
/// pushes the resolved event. Hit-tests against the previous frame's UI.
pub fn handleDrag(
    history: *GameStateHistory,
    pointer: input.PointerInput,
    ui_elements: []const ui.UiElement,
) void {
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();
    const ui_state = &history.session.ui_state;

    if (pointer.pressed) {
        // Begin a drag only when the pointer goes down on a slot that both has
        // an identity and holds something (icon present).
        if (ui.slotAt(ui_elements, pointer.position)) |slot| {
            if (slot.ref) |ref| {
                if (slot.icon_sprite_id) |icon| {
                    ui_state.drag = .{ .source = ref, .icon_sprite_id = icon };
                }
            }
        }
    }

    if (pointer.released) {
        if (ui_state.drag) |drag| {
            if (ui.slotRefAt(ui_elements, pointer.position)) |target| {
                if (dragToEvent(drag.source, target)) |event| {
                    event_handlers.pushEvents(current, &.{event}, allocator);
                }
            }
            ui_state.drag = null;
        }
    }
}

/// Camera pan (right-drag): grab the world point under the cursor and drag
/// it so it stays under the cursor. Runs anytime (not gated on the event
/// stack) so the player can look around mid-wait / mid-turn. Levels/hubs
/// only. The pan offset lives on SessionState (transient view state, replay-
/// safe by construction — see AGENTS.md). `camera` must already include the
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

    // Outside a level/hub there's nothing to pan. Clear any stale pan/anchor
    // so re-entering a world doesn't inherit it (frame() also clears on
    // screen transition, but this covers direct entry without a transition).
    if (current.screen != .level and current.screen != .hub) {
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
pub fn warnIfSessionLogFromDifferentBuild(log_game_version: []const u8) void {
    if (!std.mem.eql(u8, log_game_version, build_info.game_version)) {
        std.debug.print(
            "warning: session log recorded on game_version {s}, this build is {s}; replay may diverge\n",
            .{ log_game_version, build_info.game_version },
        );
    }
}

/// Write the full session event history to `logs/session_log_YYYYMMDD_HHMMSS.txt`
/// in the persistent data dir (config format; see parser.writeEventLog). A dev
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
    const body = parser.writeEventLog(
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

pub fn handleAnytimeInput(
    history: *GameStateHistory,
    anytime: input.AnytimeInput,
) void {
    // Recoverable error popup is modal: when a pending error is set, only
    // `dismiss_error` and the scroll actions get through; everything else
    // (including undo/redo, the options-menu toggle, and the camera-zoom
    // wheel) is swallowed until the popup is dismissed. The state has
    // already been reverted by the time the error is set, so there is
    // nothing to undo. The wheel (`scroll_delta`) is redirected here to
    // scroll the popup body instead of zooming the camera. The scroll offset
    // is clamped in `buildErrorPopup` (the view is the only place that knows
    // `max_scroll`, which depends on the wrapped line count). See AGENTS →
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
        history.session.ui_state.options_menu_open = !history.session.ui_state.options_menu_open;
    }

    // When options menu is open, block all other input
    if (history.session.ui_state.options_menu_open) return;

    if (anytime.scroll_delta != 0) {
        // Additive zoom in fixed steps, clamped to [min, max]. Additive (not
        // multiplicative) so one zoom-in followed by one zoom-out always
        // returns to the exact same value (no float drift). scroll_delta is
        // accumulated wheel notches (positive = scroll up = zoom in); a single
        // notch is ±1.0, scaled by the step. Tune the step/bounds from feel.
        const zoom_step: f32 = camera_zoom_step;
        const delta: f32 = anytime.scroll_delta * zoom_step;
        const clamped = @max(min_camera_zoom, @min(max_camera_zoom, history.settings.camera_zoom + delta));
        history.settings.camera_zoom = clamped;
    }

    // Keyboard zoom shortcuts (ctrl+I / ctrl+O / ctrl+0). Same additive
    // step + bounds as the wheel. Reset snaps to the default.
    if (anytime.zoom_in) {
        history.settings.camera_zoom = @min(max_camera_zoom, history.settings.camera_zoom + camera_zoom_step);
    }
    if (anytime.zoom_out) {
        history.settings.camera_zoom = @max(min_camera_zoom, history.settings.camera_zoom - camera_zoom_step);
    }
    if (anytime.zoom_reset) {
        history.settings.camera_zoom = default_camera_zoom;
    }

    // In-game inputs only apply when in a hub or level
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();
    const ui_state = &history.session.ui_state;
    if (current.screen == .hub or current.screen == .level) {
        const in_game = anytime.in_game;

        if (in_game.toggle_inventory) {
            ui_state.toggleMiddlePanel(.inventory);
        }

        if (in_game.toggle_gear) {
            ui_state.toggleMiddlePanel(.gear);
        }

        if (in_game.toggle_skills) {
            ui_state.toggleMiddlePanel(.skills);
        }

        if (in_game.toggle_entity_inspect) |entity_index| {
            if (ui_state.inspected_entity_index) |current_inspected| {
                if (current_inspected == entity_index) {
                    // Same entity — close the panel
                    ui_state.toggleMiddlePanel(.enemy_inspect);
                    ui_state.inspected_entity_index = null;
                } else {
                    // Different entity — switch target
                    ui_state.inspected_entity_index = entity_index;
                }
            } else {
                // Not inspecting — open panel
                ui_state.inspected_entity_index = entity_index;
                ui_state.toggleMiddlePanel(.enemy_inspect);
            }
        }

        if (in_game.toggle_world_map) {
            ui_state.toggleFullScreenOverlay(.world_map);
        }
        // Cursor resolution (mouse vs arrows vs UI occlusion) happens in a
        // dedicated step in update(), after UI arbitration — it needs
        // ui_elements + world tiles, which live in main.zig's world.

        if (in_game.swap_weapons) {
            event_handlers.pushEvents(current, &.{
                .{ .player_event = .swap_hands },
            }, allocator);
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
                .new_game => event_handlers.pushEvents(current, &.{
                    .{ .meta_event = .start_new_game },
                }, allocator),
                // Dev entry point: open the editor on the shipped beginnings
                // mission (hardcoded path so the editor building blocks are
                // reachable).
                .open_editor => event_handlers.pushEvents(current, &.{
                    .{ .meta_event = .{ .open_editor = .{
                        .mission_path = "data/campaigns/main_campaign/missions/beginnings",
                    } } },
                }, allocator),
                // continue_game / load_save need an autosave path + file picker,
                // and open_settings / open_credits need their screens. Wired
                // when those land (Continue isn't even shown on a fresh start).
                .continue_game, .load_save, .open_settings, .open_credits => {},
                else => {},
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
                                .use => |use| event_handlers.pushEvents(current, &.{
                                    .{ .level_event = .{ .player_skip_move_to_skill = .{
                                        .skill_id = use.skill_id,
                                        .target = use.target,
                                        .prepare = false,
                                    } } },
                                }, allocator),
                                .prepare => |skill_id| event_handlers.pushEvents(current, &.{
                                    .{ .level_event = .{ .player_skip_move_to_skill = .{
                                        .skill_id = skill_id,
                                        .target = null,
                                        .prepare = true,
                                    } } },
                                }, allocator),
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
                            event_handlers.pushEvents(current, &.{
                                .{ .level_event = .{ .player_move_action = .{
                                    .destination = clicked_position,
                                    .force_attack_step = modifiers.ctrl,
                                } } },
                            }, allocator);
                        }
                    }

                    if (idle.skip) {
                        // Skip movement, go straight to attack phase
                        event_handlers.pushEvents(current, &.{
                            .{ .level_event = .{ .player_skip_move = .{
                                .force_attack_step = modifiers.ctrl,
                            } } }}, allocator);
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
                                .prepare => |skill_id| event_handlers.pushEvents(current, &.{
                                    .{ .level_event = .{ .player_prepare_skill = .{
                                        .caster_index = 0,
                                        .skill_id = skill_id,
                                    } } },
                                }, allocator),
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
                            event_handlers.pushEvents(current, &.{
                                .{ .level_event = .player_cancel_skill }}, allocator);
                        }
                    }

                    if (idle.skip) {
                        // Skip attack, end turn
                        event_handlers.pushEvents(current, &.{
                            .{ .level_event = .player_skip_attack }}, allocator);
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
                event_handlers.pushEvents(current, &.{
                    .{ .hub_event = .{ .interact_with_npc = .{
                        .npc_index = npc_index,
                    } } },
                }, allocator);
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
                    event_handlers.pushEvents(current, &.{
                        .{ .hub_event = .{ .move_player = .{
                            .destination = clicked_position,
                        } } },
                    }, allocator);
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
/// is null, it snaps to the player's tile first. Only runs in a level/hub
/// (needs world tiles + the player position).
pub fn resolveTileCursor(
    history: *GameStateHistory,
    player_input: PlayerInput,
    ui_elements: []const ui.UiElement,
) void {
    const current = &history.current_state;
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
test "dragToEvent maps valid drags and blocks cross-domain drops" {
    // inventory → gear = equip
    {
        const event = dragToEvent(.{ .inventory = 2 }, .{ .gear = .boots }).?;
        try std.testing.expectEqual(@as(u32, 2), event.player_event.equip_item.inventory_slot_index);
        try std.testing.expectEqual(types.GearSlot.boots, event.player_event.equip_item.gear_slot);
    }
    // gear → inventory = unequip
    {
        const event = dragToEvent(.{ .gear = .amulet }, .{ .inventory = 5 }).?;
        try std.testing.expectEqual(types.GearSlot.amulet, event.player_event.unequip_item.gear_slot);
        try std.testing.expectEqual(@as(u32, 5), event.player_event.unequip_item.inventory_slot_index);
    }
    // learned skill → skill bar = equip utility skill
    {
        const event = dragToEvent(.{ .learned_skill = .replenish }, .{ .skill_bar = 1 }).?;
        try std.testing.expectEqual(types.SkillId.replenish, event.player_event.equip_utility_skill.skill_id);
        try std.testing.expectEqual(@as(u32, 1), event.player_event.equip_utility_skill.slot_index);
    }
    // skill bar → skill bar = swap
    {
        const event = dragToEvent(.{ .skill_bar = 0 }, .{ .skill_bar = 3 }).?;
        try std.testing.expectEqual(@as(u32, 0), event.player_event.swap_utility_skills.slot_a_index);
        try std.testing.expectEqual(@as(u32, 3), event.player_event.swap_utility_skills.slot_b_index);
    }
    // skill bar → learned skill (skills menu) = unequip utility skill
    {
        const event = dragToEvent(.{ .skill_bar = 2 }, .{ .learned_skill = .slice }).?;
        try std.testing.expectEqual(@as(u32, 2), event.player_event.unequip_utility_skill.slot_index);
    }
    // Cross-domain and nonsensical drops are no-ops.
    try std.testing.expectEqual(@as(?Event, null), dragToEvent(.{ .inventory = 0 }, .{ .skill_bar = 0 }));
    try std.testing.expectEqual(@as(?Event, null), dragToEvent(.{ .learned_skill = .slice }, .{ .gear = .coat }));
    try std.testing.expectEqual(@as(?Event, null), dragToEvent(.{ .gear = .coat }, .{ .gear = .boots }));
    // inventory → inventory move is unsupported (returns null).
    try std.testing.expectEqual(@as(?Event, null), dragToEvent(.{ .inventory = 0 }, .{ .inventory = 1 }));
}

