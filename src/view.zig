//! View — builds a `ViewState` each frame from the current game state.
//!
//! `view()` is pure over `GameState` + `SessionState` + the per-frame arena;
//! everything the ViewState points at lives until the next frame. The world
//! layers (tiles, overlays, ground drawables) and the flat `ui_elements` slice
//! are assembled here. Camera math (`computeCamera`, `tileToScreen`) lives here
//! too — `gameLoop` computes the camera once per frame and feeds it to both
//! `view()` and input translation so input/render never drift.

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const ui = @import("ui.zig");
const parser = @import("parser.zig");
const combat_log = @import("combat_log.zig");
const event_handlers = @import("event_handlers.zig");

const GameState = state.GameState;
const SessionState = state.SessionState;
const Vector2 = types.Vector2;
const Entity = types.Entity;
const Level = types.Level;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const ColorThemeDefinitions = types.ColorThemeDefinitions;
const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;
const WeaponType = types.WeaponType;

pub fn view(
    current_state: *const GameState,
    session: *const state.SessionState,
    color_theme_definitions: types.ColorThemeDefinitions,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    camera: types.Camera,
    camera_zoom: f32,
    event_history: []const events.Event,
    level_start_index: ?u32,
    current_event_index: u32,
    frame_allocator: std.mem.Allocator,
) types.ViewState {
    const active_theme = activeThemeFor(current_state, color_theme_definitions);

    // World layer: checkerboard tiles + entity sprites for the hub/level.
    var tiles: std.ArrayList(types.TileDrawable) = .empty;
    var tile_overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
    var ground_drawables: std.ArrayList(types.GroundDrawable) = .empty;
    if (current_state.level) |*level| {
        buildTiles(&tiles, frame_allocator, level.level_tiles, active_theme, camera, camera_zoom);
        buildHighlightOverlays(&tile_overlays, frame_allocator, level.highlighted_tiles, active_theme, camera, camera_zoom);
        buildCursorOverlay(&tile_overlays, frame_allocator, level.level_tiles, session, active_theme, camera, camera_zoom);
        // Level-end marker drawn before entities so actors occlude it (a proper
        // mixed y-sort with entities is a later refinement).
        if (level.level_end) |end_position| {
            ground_drawables.append(frame_allocator, .{
                .level_end = levelEndDrawable(end_position, camera, camera_zoom),
            }) catch @panic("failed to append level-end drawable");
        }
        buildEntities(&ground_drawables, frame_allocator, level.entities, camera, camera_zoom);
    } else if (current_state.hub) |*hub| {
        buildTiles(&tiles, frame_allocator, hub.hub_tiles, active_theme, camera, camera_zoom);
        buildCursorOverlay(&tile_overlays, frame_allocator, hub.hub_tiles, session, active_theme, camera, camera_zoom);
        // Mission-start markers use the same flag sprite as level ends, drawn
        // before entities so actors occlude them.
        for (hub.mission_exits) |exit| {
            ground_drawables.append(frame_allocator, .{
                .level_end = levelEndDrawable(exit.position, camera, camera_zoom),
            }) catch @panic("failed to append mission-start drawable");
        }
        buildHubEntities(&ground_drawables, frame_allocator, hub, camera, camera_zoom);
    }

    var ui_elements: std.ArrayList(ui.UiElement) = .empty;

    if (current_state.screen == .level or current_state.screen == .hub) {
        ui.buildBottomBar(
            &ui_elements,
            frame_allocator,
            ui.screenRect(),
            current_state,
            weapon_type_definitions,
        ) catch @panic("failed to build bottom bar");
    } else if (current_state.screen == .main_menu) {
        // Continue is available when there is a game to resume. Today that is
        // populated PlayerData; a future standalone build also offers Continue
        // when an autosave file exists (detected once via the file layer, not
        // per frame here — see TODO.txt).
        const continue_available = current_state.player_data.current_campaign.len > 0;
        ui.buildMainMenu(
            &ui_elements,
            frame_allocator,
            ui.screenRect(),
            continue_available,
        ) catch @panic("failed to build main menu");
    }

    // Drag ghost: the dragged icon follows the pointer, drawn last (on top).
    // Pointer position is in reference-resolution space (see translateInput).
    if (session.ui_state.drag) |drag| {
        const pointer = session.input_state.mouse_screen_position;
        ui_elements.append(frame_allocator, .{ .image = .{
            .sprite_id = drag.icon_sprite_id,
            .screen_position = .{
                .x = @as(i32, @intFromFloat(pointer.x)) - @divTrunc(ui.slot_size, 2),
                .y = @as(i32, @intFromFloat(pointer.y)) - @divTrunc(ui.slot_size, 2),
            },
            .width = ui.slot_size,
            .height = ui.slot_size,
            // Follows the pointer; must not occlude drop-target hit-testing.
            .blocks_input = false,
        } }) catch @panic("failed to append drag ghost");
    }

    // Hover tooltip: the topmost element under the pointer that carries
    // tooltip content spawns a tooltip, appended last so it draws on top.
    // Suppressed while dragging.
    if (session.ui_state.drag == null) {
        const pointer = session.input_state.mouse_screen_position;
        const point = types.ScreenPosition{
            .x = @intFromFloat(pointer.x),
            .y = @intFromFloat(pointer.y),
        };
        if (ui.tooltipAt(ui_elements.items, point)) |hovered| {
            const bounds = ui.boundsOf(hovered);
            ui.buildTooltip(
                &ui_elements,
                frame_allocator,
                bounds.position(),
                bounds.width,
                bounds.height,
                ui.tooltipOf(hovered).?,
            ) catch @panic("failed to build tooltip");
        }
    }

    // Combat log: project the current level's events (up to the current
    // position) into a chronological filtered slice. None when not in a level
    // (no enclosing start_level in the prefix). Pure, per-frame, frame-arena.
    const projected_log: []const events.Event = if (level_start_index) |start|
        combat_log.projectCombatLog(event_history, start, current_event_index, frame_allocator)
    else
        &.{};

    return .{
        .background_color = active_theme.darkest,
        .active_color_theme = active_theme,
        .world_scale = camera_zoom,
        .tiles = tiles.items,
        .tile_overlays = tile_overlays.items,
        .ground_drawables = ground_drawables.items,
        .ui_elements = ui_elements.items,
        .combat_log = projected_log,
    };
}

/// The active color theme for the current screen, derived from its
/// color_wheel_index (level/hub); a neutral default elsewhere.
fn activeThemeFor(
    current_state: *const GameState,
    color_theme_definitions: types.ColorThemeDefinitions,
) types.ActiveColorTheme {
    const color_wheel_index = if (current_state.level) |level|
        level.color_wheel_index
    else if (current_state.hub) |hub|
        hub.color_wheel_index
    else
        0;
    return parser.deriveActiveColorTheme(color_theme_definitions, color_wheel_index);
}

/// The player's tile position for the current screen (entity 0 in a level,
/// the hub player), or the origin when neither is active.
fn playerPosition(current_state: *const GameState) types.Vector2 {
    if (current_state.level) |level| {
        if (level.entities.len > 0) return level.entities[0].position;
    }
    if (current_state.hub) |hub| return hub.player.position;
    return .{ .x = 0, .y = 0 };
}

/// Camera centered on the player: places the player tile's center at the
/// screen center. Position is in the same world-pixel space screenToTile
/// inverts (tile coord * tile_size_pixels * zoom).
pub fn computeCamera(current_state: *const GameState, zoom: f32) types.Camera {
    const player_tile = playerPosition(current_state);
    const tile_pixels = input.tile_size_pixels * zoom;
    return .{ .position = .{
        .x = @intFromFloat((@as(f32, @floatFromInt(player_tile.x)) + 0.5) * tile_pixels),
        .y = @intFromFloat((@as(f32, @floatFromInt(player_tile.y)) + 0.5) * tile_pixels),
    } };
}

/// Convert a tile coordinate to its top-left screen position (reference space).
/// Exact inverse of input.screenToTile so clicks land on the drawn tile.
fn tileToScreen(tile: types.Vector2, camera: types.Camera, zoom: f32) types.ScreenPosition {
    const tile_pixels = input.tile_size_pixels * zoom;
    const half_width: f32 = @floatFromInt(@divTrunc(types.reference_width, 2));
    const half_height: f32 = @floatFromInt(@divTrunc(types.reference_height, 2));
    const x = @as(f32, @floatFromInt(tile.x)) * tile_pixels - @as(f32, @floatFromInt(camera.position.x)) + half_width;
    const y = @as(f32, @floatFromInt(tile.y)) * tile_pixels - @as(f32, @floatFromInt(camera.position.y)) + half_height;
    return .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
}

/// Entity sprite frame: all entities/weapons share one 512x640 frame (2 tiles
/// wide x 2.5 tall) authored at tile_size_pixels, with one normalized pivot
/// (horizontal center, at the feet with 0.5 tile of foot/shadow overflow).
const entity_frame_width: f32 = 512.0;
const entity_frame_height: f32 = 640.0;
const entity_pivot_x: f32 = 0.5;
const entity_pivot_y: f32 = 0.8;

const world_white: types.Color = .{ .r = 255, .g = 255, .b = 255 };

/// Flag pole frame: 256x512 (1 tile wide x 2 tall). Pivot (0.5, 0.75) centers
/// the bottom tile-half of the frame on the marker's tile. Used for both level
/// ends and hub mission-start markers. The animated banner overlay is deferred
/// to the animation work.
const flag_pole_width: f32 = 256.0;
const flag_pole_height: f32 = 512.0;
const flag_pivot_x: f32 = 0.5;
const flag_pivot_y: f32 = 0.75;

fn levelEndDrawable(
    tile: types.Vector2,
    camera: types.Camera,
    zoom: f32,
) types.LevelEndDrawable {
    const tile_top_left = tileToScreen(tile, camera, zoom);
    const tile_pixels = input.tile_size_pixels * zoom;
    const center_x = @as(f32, @floatFromInt(tile_top_left.x)) + tile_pixels / 2;
    const center_y = @as(f32, @floatFromInt(tile_top_left.y)) + tile_pixels / 2;
    return .{
        .sprite_id = "world/flag_pole",
        .screen_position = .{
            .x = @intFromFloat(@round(center_x - flag_pivot_x * flag_pole_width * zoom)),
            .y = @intFromFloat(@round(center_y - flag_pivot_y * flag_pole_height * zoom)),
        },
        .color = world_white,
    };
}

/// Build an EntityDrawable for `entity`, aligning the shared sprite pivot to
/// the center of the entity's tile. Only the base sprite is populated for now
/// (weapons/gear/effects/health bar land later).
fn entityDrawable(
    entity: *const Entity,
    camera: types.Camera,
    zoom: f32,
    allocator: std.mem.Allocator,
) types.EntityDrawable {
    const tile_top_left = tileToScreen(entity.position, camera, zoom);
    const tile_pixels = input.tile_size_pixels * zoom;
    const center_x = @as(f32, @floatFromInt(tile_top_left.x)) + tile_pixels / 2;
    const center_y = @as(f32, @floatFromInt(tile_top_left.y)) + tile_pixels / 2;
    const draw_width = entity_frame_width * zoom;
    const draw_height = entity_frame_height * zoom;
    // Body and every weapon overlay share this pivot-aligned top-left, so they
    // register with no per-sprite offset (same 512x640 frame + pivot).
    const top_left = types.ScreenPosition{
        .x = @intFromFloat(@round(center_x - entity_pivot_x * draw_width)),
        .y = @intFromFloat(@round(center_y - entity_pivot_y * draw_height)),
    };
    const base_sprite_id = std.fmt.allocPrint(allocator, "entities/{s}", .{entity.sprite}) catch
        @panic("failed to build entity sprite id");

    // Weapons: main hand drawn as-authored (left), off hand mirrored (right).
    var weapon_sprites: [2]?types.SpriteDrawable = .{ null, null };
    if (entity.main_hand_weapon) |weapon| {
        weapon_sprites[0] = weaponSprite(entity, weapon.weapon_type, top_left, false, allocator);
    }
    if (entity.off_hand_weapon) |weapon| {
        weapon_sprites[1] = weaponSprite(entity, weapon.weapon_type, top_left, true, allocator);
    }

    return .{
        .back_effect_sprites = &.{},
        .base_sprite = .{
            .sprite_id = base_sprite_id,
            .screen_position = top_left,
            .draw_offset = .{ .x = 0, .y = 0 },
            .source_rectangle = null,
            .color = world_white,
        },
        .weapon_sprites = weapon_sprites,
        .gear_sprites = &.{},
        .front_effect_sprites = &.{},
        .health_bar = null,
    };
}

/// Build a weapon overlay sprite for an entity. The weapon art shares the
/// entity frame + pivot, so it uses the same top-left as the body. Player
/// bodies (team 0) use the plain art; enemy silhouettes use the enemy_ variant.
/// Off-hand weapons are mirrored to sit on the right.
fn weaponSprite(
    entity: *const Entity,
    weapon_type: types.WeaponType,
    top_left: types.ScreenPosition,
    flip_horizontal: bool,
    allocator: std.mem.Allocator,
) types.SpriteDrawable {
    const variant_prefix = if (entity.team == 0) "" else "enemy_";
    const sprite_id = std.fmt.allocPrint(allocator, "weapons/{s}{s}", .{ variant_prefix, @tagName(weapon_type) }) catch
        @panic("failed to build weapon sprite id");
    return .{
        .sprite_id = sprite_id,
        .screen_position = top_left,
        .draw_offset = .{ .x = 0, .y = 0 },
        .source_rectangle = null,
        .color = world_white,
        .flip_horizontal = flip_horizontal,
    };
}

/// Order entities back-to-front for painter's-algorithm occlusion. tileToScreen
/// maps higher tile.y to a LARGER screen y (lower on screen = nearer the
/// viewer), so lower tile.y is further back and drawn first (ascending y).
fn entityDrawsBefore(_: void, a: *const Entity, b: *const Entity) bool {
    if (a.position.y != b.position.y) return a.position.y < b.position.y;
    return a.position.x < b.position.x;
}

fn buildEntities(
    list: *std.ArrayList(types.GroundDrawable),
    allocator: std.mem.Allocator,
    entities: []const Entity,
    camera: types.Camera,
    zoom: f32,
) void {
    var order = allocator.alloc(*const Entity, entities.len) catch @panic("failed to alloc entity order");
    for (entities, 0..) |*entity, index| order[index] = entity;
    std.mem.sort(*const Entity, order, {}, entityDrawsBefore);
    for (order) |entity| {
        list.append(allocator, .{ .entity = entityDrawable(entity, camera, zoom, allocator) }) catch
            @panic("failed to append entity drawable");
    }
}

/// Hub actors: the player plus NPCs, sorted together back-to-front.
fn buildHubEntities(
    list: *std.ArrayList(types.GroundDrawable),
    allocator: std.mem.Allocator,
    hub: *const types.Hub,
    camera: types.Camera,
    zoom: f32,
) void {
    var order = allocator.alloc(*const Entity, hub.npcs.len + 1) catch @panic("failed to alloc hub order");
    order[0] = &hub.player;
    for (hub.npcs, 0..) |*npc, index| order[index + 1] = &npc.entity;
    std.mem.sort(*const Entity, order, {}, entityDrawsBefore);
    for (order) |entity| {
        list.append(allocator, .{ .entity = entityDrawable(entity, camera, zoom, allocator) }) catch
            @panic("failed to append hub entity drawable");
    }
}

/// Move-range highlights: a translucent fill over each reachable tile, tinted
/// with a player-gradient color.
fn buildHighlightOverlays(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    highlighted_tiles: []const types.Vector2,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    for (highlighted_tiles) |tile| {
        list.append(allocator, .{
            .screen_position = tileToScreen(tile, camera, zoom),
            .overlay_type = .highlight,
            .color = active_theme.player_gradient.colors[2],
        }) catch @panic("failed to append highlight overlay");
    }
}

/// Hover cursor: an outline on the tile under the logical cursor
/// (session.tile_cursor), when it is a real tile. The cursor is resolved in
/// the input/update path (mouse-move + arrow keys + UI occlusion) and stored
/// on SessionState; view() just renders it — no GameState mutation, so it is
/// replay-safe like the tooltip/drag-ghost.
fn buildCursorOverlay(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    world_tiles: []const types.Vector2,
    session: *const state.SessionState,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    const cursor = session.tile_cursor orelse return;
    for (world_tiles) |tile| {
        if (tile.x == cursor.x and tile.y == cursor.y) {
            list.append(allocator, .{
                .screen_position = tileToScreen(cursor, camera, zoom),
                .overlay_type = .cursor,
                .color = active_theme.lightest,
            }) catch @panic("failed to append cursor overlay");
            return;
        }
    }
}

/// Append a checkerboard TileDrawable per tile. The two shades come from world
/// gradient indices 1 and 3, chosen by (x + y) parity.
fn buildTiles(
    list: *std.ArrayList(types.TileDrawable),
    allocator: std.mem.Allocator,
    tiles: []const types.Vector2,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    for (tiles) |tile| {
        const color = if (@mod(tile.x + tile.y, 2) == 0)
            active_theme.world_gradient.colors[1]
        else
            active_theme.world_gradient.colors[3];
        list.append(allocator, .{
            .screen_position = tileToScreen(tile, camera, zoom),
            .color = color,
        }) catch @panic("failed to append tile drawable");
    }
}
