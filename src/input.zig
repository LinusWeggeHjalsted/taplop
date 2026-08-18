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
    mouse_screen_position: ScreenPosition = .{ .x = 0, .y = 0 },
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
    pointer: PointerInput = .{},
};

/// Raw primary-pointer facts for the UI-resolution step (hit-testing, drag
/// lifecycle). Deliberately semantic-free: main.zig decides what a press/
/// release over a given position means. Position is in reference-resolution
/// space (types.ScreenPosition), matching where ui_elements are laid out.
pub const PointerInput = struct {
    pressed: bool = false, // primary button went down this tick
    released: bool = false, // primary button went up this tick
    position: types.ScreenPosition = .{ .x = 0, .y = 0 },
};

/// Actions that can be handled regardless of event stack state.
pub const AnytimeInput = struct {
    undo: bool = false,
    redo: bool = false,
    toggle_options_menu: bool = false,
    dump_event_log: bool = false,
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

/// Actions that are only handled when the event stack is empty
/// (i.e. the game is waiting for player input).
pub const IdleInput = struct {
    tile_clicked: ?Vector2 = null,
    skill_slot_selected: ?u8 = null, // 1-8, game logic resolves to SkillId
    confirm: bool = false,
    cancel: bool = false,
    skip: bool = false,
    /// A main-menu command (New Game / Load Save / ...), set only when a menu
    /// button is clicked (no keybind path). Handled by the main_menu branch of
    /// handleIdleInput.
    menu_action: ?types.Action = null,
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
        .toggle_inventory => player_input.anytime.in_game.toggle_inventory = true,
        .toggle_gear => player_input.anytime.in_game.toggle_gear = true,
        .toggle_skills => player_input.anytime.in_game.toggle_skills = true,
        .toggle_world_map => player_input.anytime.in_game.toggle_world_map = true,
        .swap_weapons => player_input.anytime.in_game.swap_weapons = true,
        .confirm => player_input.idle.confirm = true,
        .cancel => player_input.idle.cancel = true,
        .skip => player_input.idle.skip = true,
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
        .load_save,
        .open_settings,
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
            .key => |key| InputState.isHeld(keys_pressed, key),
            .mouse_button => |button| InputState.isHeld(mouse_pressed, button),
            .gamepad_button => |gamepad| InputState.isHeld(gamepad_pressed, gamepad),
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
    var mouse_released: [InputState.max_held_mouse]?[]const u8 = .{null} ** InputState.max_held_mouse;
    var gamepad_pressed: [InputState.max_held_gamepad]?[]const u8 = .{null} ** InputState.max_held_gamepad;

    // Accumulate scroll delta across all events this tick
    var scroll_delta: f32 = 0;

    // Process each raw event
    for (platform.events) |event| {
        switch (event) {
            .key_down => |key| {
                if (!InputState.isHeld(&state.keys_held, key)) {
                    InputState.addHeld(&keys_pressed, key);
                }
                InputState.addHeld(&state.keys_held, key);
            },
            .key_up => |key| {
                InputState.removeHeld(&state.keys_held, key);
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
    const zoom = settings.camera_zoom;

    // Build PlayerInput from triggered actions
    var result = PlayerInput{};

    // Anytime actions
    result.anytime.undo = checkAction(.undo, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.redo = checkAction(.redo, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.toggle_options_menu = checkAction(.toggle_options_menu, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.dump_event_log = checkAction(.dump_event_log, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.scroll_delta = scroll_delta;

    // In-game anytime actions
    result.anytime.in_game.toggle_inventory = checkAction(.toggle_inventory, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.toggle_gear = checkAction(.toggle_gear, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.toggle_skills = checkAction(.toggle_skills, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.toggle_world_map = checkAction(.toggle_world_map, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);
    result.anytime.in_game.swap_weapons = checkAction(.swap_weapons, bindings, &keys_pressed, &mouse_pressed, &gamepad_pressed, modifiers);

    // Mouse move → tile cursor
    result.anytime.in_game.move_tile_cursor_to = screenToTile(state.mouse_screen_position, camera, zoom, platform.viewport);

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
        result.idle.tile_clicked = screenToTile(state.mouse_screen_position, camera, zoom, platform.viewport);
    }

    // Primary-pointer facts for the UI-resolution step. The pointer is assumed
    // to already be in reference-resolution space (same assumption screenToTile
    // makes); update alongside it if the platform viewport mapping changes.
    result.pointer = .{
        .pressed = InputState.isHeld(&mouse_pressed, "left"),
        .released = InputState.isHeld(&mouse_released, "left"),
        .position = .{
            .x = @intFromFloat(state.mouse_screen_position.x),
            .y = @intFromFloat(state.mouse_screen_position.y),
        },
    };

    return result;
}
