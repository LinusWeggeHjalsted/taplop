const std = @import("std");
const types = @import("types.zig");

const Vector2 = types.Vector2;
const SkillId = types.SkillId;
const Modifiers = types.Modifiers;
const InputBinding = types.InputBinding;
const RawInput = types.RawInput;
const Settings = types.Settings;
const Camera = types.Camera;

// ============================================================
// Platform layer types — raw input from JS/native
// ============================================================

/// Screen-space position in CSS/logical pixels. Floats because browser
/// coordinates can be fractional (device pixel ratio, touch precision).
pub const ScreenPosition = struct {
    x: f32,
    y: f32,
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
    mouse_move: ScreenPosition,
    mouse_scroll: f32, // positive = scroll up, negative = scroll down
    gamepad_button_down: []const u8,
    gamepad_button_up: []const u8,
    touch_start: TouchEvent,
    touch_move: TouchEvent,
    touch_end: TouchEvent,
};

pub const TouchEvent = struct {
    id: TouchId,
    position: ScreenPosition,
};

/// Everything the platform layer hands to the game each update tick.
pub const PlatformInput = struct {
    events: []const PlatformInputEvent,
    viewport: ViewportSize,
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
    mouse_screen_positionition: ScreenPosition = .{ .x = 0, .y = 0 },
    active_touches: [max_touch_points]?ActiveTouch = .{null} ** max_touch_points,

    pub const max_held_keys = 16;
    pub const max_held_mouse = 5;
    pub const max_held_gamepad = 16;
    pub const max_touch_points = 10;

    pub const ActiveTouch = struct {
        id: TouchId,
        position: ScreenPosition,
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
};

// ============================================================
// Player input — semantic actions for the game logic
// ============================================================

pub const PlayerInput = struct {
    anytime: AnytimeInput = .{},
    idle: IdleInput = .{},
};

/// Actions that can be handled regardless of event queue state.
pub const AnytimeInput = struct {
    undo: bool = false,
    redo: bool = false,
    toggle_options_menu: bool = false,
    scroll_delta: f32 = 0,

    /// Only handled when the player is in a hub or level.
    in_game: InGameInput = .{},
};

/// Anytime actions that are only valid in a hub or level context.
pub const InGameInput = struct {
    toggle_inventory: bool = false,
    toggle_gear: bool = false,
    toggle_skills: bool = false,
    toggle_entity_inspect: ?u32 = null,
    toggle_world_map: bool = false,
    swap_weapons: bool = false,
    move_tile_cursor_to: ?Vector2 = null,
};

/// Actions that are only handled when the event queue is empty
/// (i.e. the game is waiting for player input).
pub const IdleInput = struct {
    tile_clicked: ?Vector2 = null,
    skill_slot_selected: ?u8 = null, // 1-8, game logic resolves to SkillId
    confirm: bool = false,
    cancel: bool = false,
    skip: bool = false,
};

// ============================================================
// Input translation — raw platform events → semantic PlayerInput
// ============================================================

pub const tile_size_pixels: f32 = 512.0;

/// Convert a screen-space position to tile coordinates.
/// Takes into account camera position and zoom level.
fn screenToTile(
    screen_position: ScreenPosition,
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

/// Check if an action was triggered by any just-pressed input this tick.
fn checkAction(
    action: types.Action,
    bindings: []const InputBinding,
    keys_pressed: []const ?[]const u8,
    mouse_pressed: []const ?[]const u8,
    gamepad_pressed: []const ?[]const u8,
    modifiers: Modifiers,
) bool {
    for (bindings) |binding| {
        if (binding.action != action) continue;

        // Check modifiers match
        if (binding.modifiers.ctrl != modifiers.ctrl) continue;
        if (binding.modifiers.shift != modifiers.shift) continue;
        if (binding.modifiers.alt != modifiers.alt) continue;

        // Check if the bound input was just pressed
        const pressed = switch (binding.input) {
            .key => |k| InputState.isHeld(keys_pressed, k),
            .mouse_button => |m| InputState.isHeld(mouse_pressed, m),
            .gamepad_button => |g| InputState.isHeld(gamepad_pressed, g),
        };

        if (pressed) return true;
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
) PlayerInput {
    // Track which inputs were just pressed this tick (edge detection)
    var keys_pressed: [InputState.max_held_keys]?[]const u8 = .{null} ** InputState.max_held_keys;
    var mouse_pressed: [InputState.max_held_mouse]?[]const u8 = .{null} ** InputState.max_held_mouse;
    var gamepad_pressed: [InputState.max_held_gamepad]?[]const u8 = .{null} ** InputState.max_held_gamepad;

    // Accumulate scroll delta across all events this tick
    var scroll_delta: f32 = 0;

    // Process each raw event
    for (platform.events) |event| {
        switch (event) {
            .key_down => |k| {
                if (!InputState.isHeld(&state.keys_held, k)) {
                    InputState.addHeld(&keys_pressed, k);
                }
                InputState.addHeld(&state.keys_held, k);
            },
            .key_up => |k| {
                InputState.removeHeld(&state.keys_held, k);
            },
            .mouse_button_down => |m| {
                if (!InputState.isHeld(&state.mouse_buttons_held, m)) {
                    InputState.addHeld(&mouse_pressed, m);
                }
                InputState.addHeld(&state.mouse_buttons_held, m);
            },
            .mouse_button_up => |m| {
                InputState.removeHeld(&state.mouse_buttons_held, m);
            },
            .mouse_move => |position| {
                state.mouse_screen_positionition = position;
            },
            .mouse_scroll => |delta| {
                scroll_delta += delta;
            },
            .gamepad_button_down => |g| {
                if (!InputState.isHeld(&state.gamepad_buttons_held, g)) {
                    InputState.addHeld(&gamepad_pressed, g);
                }
                InputState.addHeld(&state.gamepad_buttons_held, g);
            },
            .gamepad_button_up => |g| {
                InputState.removeHeld(&state.gamepad_buttons_held, g);
            },
            .touch_start => |t| {
                for (&state.active_touches) |*slot| {
                    if (slot.* == null) {
                        slot.* = .{ .id = t.id, .position = t.position };
                        break;
                    }
                }
            },
            .touch_move => |t| {
                for (&state.active_touches) |*slot| {
                    if (slot.*) |*active| {
                        if (active.id == t.id) {
                            active.position = t.position;
                            break;
                        }
                    }
                }
            },
            .touch_end => |t| {
                for (&state.active_touches) |*slot| {
                    if (slot.*) |active| {
                        if (active.id == t.id) {
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
    const zoom = settings.camera_zoom;

    // Build PlayerInput from triggered actions
    var result = PlayerInput{};

    // Anytime actions
    result.anytime.undo = checkAction(.undo, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.redo = checkAction(.redo, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.toggle_options_menu = checkAction(.toggle_options_menu, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.scroll_delta = scroll_delta;

    // In-game anytime actions
    result.anytime.in_game.toggle_inventory = checkAction(.toggle_inventory, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.toggle_gear = checkAction(.toggle_gear, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.toggle_skills = checkAction(.toggle_skills, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.toggle_world_map = checkAction(.toggle_world_map, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.swap_weapons = checkAction(.swap_weapons, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);

    // Mouse move → tile cursor
    result.anytime.in_game.move_tile_cursor_to = screenToTile(state.mouse_screen_positionition, camera, zoom, platform.viewport);

    // Idle actions
    result.idle.confirm = checkAction(.confirm, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.idle.cancel = checkAction(.cancel, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.idle.skip = checkAction(.skip, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);

    // Skill slots 1-8
    const skill_slot_actions = [_]types.Action{
        .skill_slot_1, .skill_slot_2, .skill_slot_3, .skill_slot_4,
        .skill_slot_5, .skill_slot_6, .skill_slot_7, .skill_slot_8,
    };
    for (skill_slot_actions, 1..) |action, slot| {
        if (checkAction(action, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers)) {
            result.idle.skill_slot_selected = @intCast(slot);
            break;
        }
    }

    // Left mouse click → tile_clicked
    if (InputState.isHeld(&mouse_pressed, "left")) {
        result.idle.tile_clicked = screenToTile(state.mouse_screen_positionition, camera, zoom, platform.viewport);
    }

    return result;
}
