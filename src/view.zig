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

/// Per-frame render context: the camera, timing, event log view, and
/// frame arena that change every frame. Bundled so `view()` doesn't take a
/// long flat parameter list — the remaining params are session/game-state
/// that live across frames.
pub const RenderContext = struct {
    camera: types.Camera,
    camera_zoom: f32,
    event_history: []const events.Event,
    level_start_index: ?u32,
    current_event_index: u32,
    frame_allocator: std.mem.Allocator,
    /// Per-glyph font advances for the loaded font, so `view()` and the UI
    /// builders measure text with the same advances the renderer draws with.
    /// Extracted from the loaded raylib `Font` by the backend; raylib-free
    /// value type so it threads through the headless-tested `view()` path.
    font_metrics: ui.FontMetrics,
    /// Per-frame lookup of entity-sprite top-y: bare sprite stem (e.g.
    /// `skeleton_1`) -> y-coordinate (0-based from the top, in SOURCE pixels)
    /// of the topmost non-transparent pixel, or null if the sprite can't be
    /// loaded/decoded. Built by `frame()` by querying the backend (which
    /// lazily decodes + caches — same shape as the outline-mask cache) for
    /// each entity in the current world. Used by `view()` to place floating
    /// indicators just above an entity's actual art top rather than the
    /// 512x640 frame edge. Frame-arena-backed (no deinit). See AGENTS →
    /// Animation.
    sprite_top_y: std.StringHashMapUnmanaged(?i32),
    /// Per-frame lookup of entity-sprite bottom-y: mirror of `sprite_top_y`,
    /// the y-coordinate (0-based from the top, in SOURCE pixels) of the
    /// bottommost non-transparent pixel, or null on miss/failure. Lets
    /// `view()` place overlays at the rendered art's real vertical center
    /// (e.g. the hit flash) instead of the 512x640 frame edge. See AGENTS →
    /// Animation.
    sprite_bottom_y: std.StringHashMapUnmanaged(?i32),
};

pub fn view(
    current_state: *const GameState,
    session: *state.SessionState,
    settings: types.Settings,
    color_theme_definitions: types.ColorThemeDefinitions,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    render: RenderContext,
) types.ViewState {
    // Unpack the render context (local aliases keep the body readable).
    const camera = render.camera;
    const camera_zoom = render.camera_zoom;
    const frame_allocator = render.frame_allocator;
    const event_history = render.event_history;
    const level_start_index = render.level_start_index;
    const current_event_index = render.current_event_index;
    const font_metrics = render.font_metrics;

    const active_theme = activeThemeFor(current_state, color_theme_definitions);

    // World layer: checkerboard tiles + entity sprites for the hub/level.
    var tiles: std.ArrayList(types.TileDrawable) = .empty;
    var tile_overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
    // Ground drawables (entities, decoration pieces, level-end / mission-start
    // markers) are collected into a sortable list and unified y-sorted so
    // decoration overhang pieces interleave correctly with entities (see
    // AGENTS → Decorations & Footprint). Tiles + overlays are separate layers.
    var ground_entries: std.ArrayList(GroundEntry) = .empty;
    if (current_state.level) |*level| {
        buildTiles(&tiles, frame_allocator, level.level_tiles, active_theme, camera, camera_zoom);
        buildHighlightOverlays(&tile_overlays, frame_allocator, level.highlighted_tiles, active_theme, camera, camera_zoom);
        buildCursorOverlay(&tile_overlays, frame_allocator, level.level_tiles, session, active_theme, camera, camera_zoom);
        if (level.level_end) |end_position| {
            ground_entries.append(frame_allocator, .{
                .sort_y = end_position.y,
                .sort_x = end_position.x,
                .drawable = .{ .level_end = levelEndDrawable(end_position, active_theme, camera, camera_zoom, session.animation_clock, settings.animation_fps) },
            }) catch @panic("failed to append level-end entry");
        }
        // Level entities: build a pointer slice for the unified collector.
        {
            const entity_ptrs = frame_allocator.alloc(*const Entity, level.entities.len) catch
                @panic("failed to alloc entity pointer slice");
            for (level.entities, 0..) |*entity, index| entity_ptrs[index] = entity;
            collectEntityEntries(&ground_entries, frame_allocator, entity_ptrs, active_theme, settings.player_color_index, camera, camera_zoom, render.sprite_top_y, true);
        }
        for (level.decorations) |decoration| {
            const pieces = buildDecorationPieces(decoration, active_theme, camera, camera_zoom, frame_allocator);
            for (pieces) |entry| ground_entries.append(frame_allocator, entry) catch
                @panic("failed to append decoration piece entry");
        }
        for (level.ground_items) |stack| {
            ground_entries.append(frame_allocator, .{
                .sort_y = stack.position.y,
                .sort_x = stack.position.x,
                .drawable = .{ .ground_items = groundItemsDrawable(stack.position, @intCast(stack.items.len), active_theme, camera, camera_zoom) },
            }) catch @panic("failed to append ground-items entry");
        }
    } else if (current_state.hub) |*hub| {
        buildTiles(&tiles, frame_allocator, hub.hub_tiles, active_theme, camera, camera_zoom);
        buildCursorOverlay(&tile_overlays, frame_allocator, hub.hub_tiles, session, active_theme, camera, camera_zoom);
        for (hub.mission_exits) |exit| {
            ground_entries.append(frame_allocator, .{
                .sort_y = exit.position.y,
                .sort_x = exit.position.x,
                .drawable = .{ .level_end = levelEndDrawable(exit.position, active_theme, camera, camera_zoom, session.animation_clock, settings.animation_fps) },
            }) catch @panic("failed to append mission-start entry");
        }
        // Hub entities: the player + NPCs as a pointer slice.
        {
            const hub_entity_ptrs = frame_allocator.alloc(*const Entity, 1 + hub.npcs.len) catch
                @panic("failed to alloc hub entity pointer slice");
            hub_entity_ptrs[0] = &hub.player;
            for (hub.npcs, 0..) |*npc, index| hub_entity_ptrs[index + 1] = &npc.entity;
            collectEntityEntries(&ground_entries, frame_allocator, hub_entity_ptrs, active_theme, settings.player_color_index, camera, camera_zoom, render.sprite_top_y, false);
        }
        for (hub.decorations) |decoration| {
            const pieces = buildDecorationPieces(decoration, active_theme, camera, camera_zoom, frame_allocator);
            for (pieces) |entry| ground_entries.append(frame_allocator, entry) catch
                @panic("failed to append decoration piece entry");
        }
    }

    // Unified y-sort (ascending sort_y, then sort_x) and extract into the
    // ground_drawables list the ViewState carries.
    std.mem.sort(GroundEntry, ground_entries.items, {}, groundEntryBefore);
    var ground_drawables: std.ArrayList(types.GroundDrawable) = .empty;
    for (ground_entries.items) |entry| {
        ground_drawables.append(frame_allocator, entry.drawable) catch
            @panic("failed to append ground drawable");
    }

    // World overlays: one-shot anims (skill icons, etc.) drawn above ground
    // sprites. Built from `session.active_anims`; see AGENTS → Animation.
    const world_overlays = buildWorldOverlays(
        frame_allocator,
        session,
        current_state,
        camera,
        camera_zoom,
        current_event_index,
        render.sprite_top_y,
        render.sprite_bottom_y,
        active_theme,
    );

    var ui_elements: std.ArrayList(ui.UiElement) = .empty;

    if (current_state.screen == .level or current_state.screen == .hub) {
        ui.buildBottomBar(
            &ui_elements,
            frame_allocator,
            font_metrics,
            ui.screenRect(),
            current_state,
            weapon_type_definitions,
            active_theme,
            settings.player_color_index,
        ) catch @panic("failed to build bottom bar");
    } else if (current_state.screen == .main_menu) {
        // Continue is available when there is a game to resume (populated
        // PlayerData).
        const continue_available = current_state.player_data.current_campaign.len > 0;
        ui.buildMainMenu(
            &ui_elements,
            frame_allocator,
            font_metrics,
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
                font_metrics,
                bounds.position(),
                bounds.width,
                bounds.height,
                ui.tooltipOf(hovered).?,
            ) catch @panic("failed to build tooltip");
        }
    }

    // Recoverable error popup: modal, centered, drawn on top of all other
    // UI (including tooltips). Pure over SessionState.pending_error. See
    // AGENTS → Error Handling.
    if (session.pendingError()) |message| {
        ui.buildErrorPopup(&ui_elements, frame_allocator, font_metrics, session, message) catch
            @panic("failed to build error popup");
    }

    // Hover highlight: the topmost button under the pointer gets an edge
    // outline (same `highlighted` path as the active turn-step indicator).
    // Suppressed while dragging (the pointer is dragging, not hovering).
    // Mutates the element in place by index so the renderer sees the flag.
    // Occlusion-aware: a modal popup on top shields buttons behind it.
    if (session.ui_state.drag == null) {
        const hover_pointer = session.input_state.mouse_screen_position;
        const hover_point = types.ScreenPosition{
            .x = @intFromFloat(hover_pointer.x),
            .y = @intFromFloat(hover_pointer.y),
        };
        if (ui.buttonIndexAt(ui_elements.items, hover_point)) |i| {
            ui_elements.items[i].button.highlighted = true;
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
        .background_color = worldGradientColor(active_theme, 2),
        .active_color_theme = active_theme,
        .world_scale = camera_zoom,
        .tiles = tiles.items,
        .tile_overlays = tile_overlays.items,
        .ground_drawables = ground_drawables.items,
        .world_overlays = world_overlays,
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
pub fn playerPosition(current_state: *const GameState) types.Vector2 {
    if (current_state.level) |level| {
        if (level.entities.len > 0) return level.entities[0].position;
    }
    if (current_state.hub) |hub| return hub.player.position;
    return .{ .x = 0, .y = 0 };
}

/// Camera centered on the player (plus an optional right-drag pan offset):
/// places the player tile's center at the screen center, then adds `pan`.
/// Position is in the same world-pixel space screenToTile inverts
/// (tile coord * tile_size_pixels * zoom). `pan` is in world pixels too.
/// Both the input camera and the render camera pass through here so input
/// and rendering never drift relative to the pan offset.
pub fn computeCamera(
    current_state: *const GameState,
    zoom: f32,
    pan: ?types.Vector2,
) types.Camera {
    const player_tile = playerPosition(current_state);
    const tile_pixels = input.tile_size_pixels * zoom;
    var pos = types.Vector2{
        .x = @intFromFloat((@as(f32, @floatFromInt(player_tile.x)) + 0.5) * tile_pixels),
        .y = @intFromFloat((@as(f32, @floatFromInt(player_tile.y)) + 0.5) * tile_pixels),
    };
    if (pan) |offset| {
        pos.x += offset.x;
        pos.y += offset.y;
    }
    return .{ .position = pos };
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

/// One-shot skill-icon anim: square edge in native reference pixels (the
/// renderer multiplies by `world_scale`, matching tiles/entities), and the
/// gap above the entity's actual art top (found at runtime from the sprite's
/// topmost non-transparent pixel — see `RenderContext.sprite_top_y`). Tunable
/// — eyeball in `zig build run`. See AGENTS → Animation.
const skill_icon_size_native: i32 = 256;
const skill_icon_gap_native: i32 = 16;

/// One-shot hit-flash anim: the `world/hit_flash` sprite (256x256, ported
/// from the Unity project's 512x512 Hit.png at 0.5x) flashed over a damaged
/// entity's rendered art center for 250ms, tinted with the active theme's
/// `lightest` color (the artist's offwhite). Drawn centered on the entity's
/// horizontal frame center and the real vertical center of its opaque art
/// (via `sprite_top_y` + `sprite_bottom_y`). Tunable — eyeball in
/// `zig build run`. See AGENTS → Animation.
const hit_flash_size_native: i32 = 256;

/// Entity health bar. The bar + outline sprites are 155x31 native (cropped
/// to the outline's opaque bbox and downscaled 0.5x from the 384x128 Unity
/// art). Drawn above the entity's actual art top (same `sprite_top_y` scan
/// as the skill icon). The skill icon sits above the health bar, so it's
/// offset by the bar's height + this gap. Tunable — eyeball in `zig build
/// run`. See AGENTS → Entity & UI Coloring.
const health_bar_native_width: i32 = 155;
const health_bar_native_height: i32 = 31;
const health_bar_gap_native: i32 = 8;

/// Ground-items sprite: `world/ground_items.png` (256x256, centered pivot
/// 0.5/0.5). Tinted at world gradient index 5 (a fixed color independent of
/// the player's body color, like the UI palette). Drawn at the stack's tile;
/// `item_count` is unused at draw time (the renderer draws just the sprite).
const ground_items_sprite_id = "world/ground_items";
const ground_items_size: f32 = 256.0;
const ground_items_pivot_x: f32 = 0.5;
const ground_items_pivot_y: f32 = 0.5;

/// Flag pole frame: 256x512 (1 tile wide x 2 tall). Pivot (0.5, 0.75) centers
/// the bottom tile-half of the frame on the marker's tile. Used for both level
/// ends and hub mission-start markers; only the static pole is drawn here.
const flag_pole_width: f32 = 256.0;
const flag_pole_height: f32 = 512.0;
const flag_pivot_x: f32 = 0.5;
const flag_pivot_y: f32 = 0.75;

/// Animated banner sprite (`world/flag.png`): a horizontal strip of 8 frames,
/// each 256x512 (same dims + pivot as the pole). Drawn over the pole at the
/// same screen position. Looping at `settings.animation_fps` (default 8 →
/// 125 ms/frame, 1.0 s loop). See AGENTS → Animation.
const flag_banner_sprite_id = "world/flag";
const flag_banner_frame_count: u32 = 8;
const flag_banner_frame_width: i32 = 256;
const flag_banner_frame_height: i32 = 512;

fn levelEndDrawable(
    tile: types.Vector2,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
    animation_clock_microseconds: u64,
    animation_fps: u32,
) types.LevelEndDrawable {
    const tile_top_left = tileToScreen(tile, camera, zoom);
    const tile_pixels = input.tile_size_pixels * zoom;
    const center_x = @as(f32, @floatFromInt(tile_top_left.x)) + tile_pixels / 2;
    const center_y = @as(f32, @floatFromInt(tile_top_left.y)) + tile_pixels / 2;

    // Pick the banner frame: frame = (elapsed / frame_duration) % frame_count.
    // animation_fps is the one global rate all anims share (settings). A zero
    // fps is treated as the default (8) to avoid a divide-by-zero.
    const effective_fps: u32 = if (animation_fps == 0) 8 else animation_fps;
    const frame_duration_us: u64 = 1_000_000 / effective_fps;
    const elapsed_frames: u64 = animation_clock_microseconds / frame_duration_us;
    const frame_index: u32 = @intCast(elapsed_frames % flag_banner_frame_count);

    return .{
        .sprite_id = "world/flag_pole",
        .screen_position = .{
            .x = @intFromFloat(@round(center_x - flag_pivot_x * flag_pole_width * zoom)),
            .y = @intFromFloat(@round(center_y - flag_pivot_y * flag_pole_height * zoom)),
        },
        .color = worldGradientColor(active_theme, 5),
        .banner_color = worldGradientColor(active_theme, 0),
        .banner_source_rectangle = .{
            .x = @as(i32, @intCast(frame_index)) * flag_banner_frame_width,
            .y = 0,
            .width = flag_banner_frame_width,
            .height = flag_banner_frame_height,
        },
    };
}

/// Build a `GroundItemDrawable` for a ground-item stack at `tile`. The sprite
/// is centered on the tile (pivot 0.5/0.5), tinted at world gradient index 5
/// (fixed, independent of the player's body color). `item_count` is carried
/// on the drawable but unused at draw time (the renderer draws just the
/// sprite, no count badge).
fn groundItemsDrawable(
    tile: types.Vector2,
    item_count: u32,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) types.GroundItemDrawable {
    const tile_top_left = tileToScreen(tile, camera, zoom);
    const tile_pixels = input.tile_size_pixels * zoom;
    const center_x = @as(f32, @floatFromInt(tile_top_left.x)) + tile_pixels / 2;
    const center_y = @as(f32, @floatFromInt(tile_top_left.y)) + tile_pixels / 2;
    return .{
        .sprite_id = ground_items_sprite_id,
        .screen_position = .{
            .x = @intFromFloat(@round(center_x - ground_items_pivot_x * ground_items_size * zoom)),
            .y = @intFromFloat(@round(center_y - ground_items_pivot_y * ground_items_size * zoom)),
        },
        .color = worldGradientColor(active_theme, 5),
        .item_count = item_count,
    };
}

/// Top-left of an entity's 512x640 frame in reference-resolution space,
/// aligning the shared pivot (0.5, 0.8) to the center of the entity's tile.
/// Shared by `entityDrawable` (body + weapons + layers register here) and
/// the world-overlay builder (floating icons place above this point).
fn entityFrameTopLeft(entity: *const Entity, camera: types.Camera, zoom: f32) types.ScreenPosition {
    const tile_top_left = tileToScreen(entity.position, camera, zoom);
    const tile_pixels = input.tile_size_pixels * zoom;
    const center_x = @as(f32, @floatFromInt(tile_top_left.x)) + tile_pixels / 2;
    const center_y = @as(f32, @floatFromInt(tile_top_left.y)) + tile_pixels / 2;
    const draw_width = entity_frame_width * zoom;
    const draw_height = entity_frame_height * zoom;
    return .{
        .x = @intFromFloat(@round(center_x - entity_pivot_x * draw_width)),
        .y = @intFromFloat(@round(center_y - entity_pivot_y * draw_height)),
    };
}

/// Build the world-overlay list from `session.active_anims`. An anim shows
/// when its triggering event is in the projected history (`event_index <
/// current_event_index` — same exclusive bound the combat log uses, so undo
/// hides it) AND it hasn't elapsed (`animation_clock < end_clock`). Skill
/// icons track the entity (resolved from the CURRENT level each frame) and
/// skip dead entities; a screen/world transition clears the list, so an anim
/// never outlives its level. Later-pushed anims append later → draw later →
/// stack on top (the most recent skill use reads on top). See AGENTS →
/// Animation.
fn buildWorldOverlays(
    allocator: std.mem.Allocator,
    session: *state.SessionState,
    current_state: *const GameState,
    camera: types.Camera,
    zoom: f32,
    current_event_index: u32,
    sprite_top_y: std.StringHashMapUnmanaged(?i32),
    sprite_bottom_y: std.StringHashMapUnmanaged(?i32),
    active_theme: types.ActiveColorTheme,
) []const types.WorldOverlayDrawable {
    const level = current_state.level orelse return &.{};
    var overlays: std.ArrayList(types.WorldOverlayDrawable) = .empty;
    for (session.active_anims.items) |anim| {
        if (anim.event_index >= current_event_index) continue;
        if (session.animation_clock >= anim.end_clock) continue;
        switch (anim.kind) {
            .skill_icon => |info| {
                if (info.entity_index >= level.entities.len) continue;
                const entity = &level.entities[info.entity_index];
                if (entity.current_health == 0) continue;

                const top_left = entityFrameTopLeft(entity, camera, zoom);
                const draw_width = entity_frame_width * zoom;
                const drawn_size: f32 = @as(f32, @floatFromInt(skill_icon_size_native)) * zoom;
                const gap: f32 = @as(f32, @floatFromInt(skill_icon_gap_native)) * zoom;
                const icon_x = @as(f32, @floatFromInt(top_left.x)) + draw_width / 2 - drawn_size / 2;
                const art_top_y: f32 = if (sprite_top_y.get(entity.sprite)) |maybe_top_y|
                    if (maybe_top_y) |top_y|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(top_y)) * zoom
                    else
                        @as(f32, @floatFromInt(top_left.y))
                else
                    @as(f32, @floatFromInt(top_left.y));
                // The health bar sits above the art top (always-on), so the
                // icon is offset further by the bar's height + gap to avoid
                // overlap. See AGENTS → Animation / Entity & UI Coloring.
                const health_bar_total: f32 =
                    @as(f32, @floatFromInt(health_bar_native_height + health_bar_gap_native)) * zoom;
                const icon_y = art_top_y - health_bar_total - drawn_size - gap;
                const sprite_id = std.fmt.allocPrint(allocator, "skills/{s}", .{@tagName(info.skill_id)}) catch
                    @panic("failed to build skill-icon sprite id");
                // Tinted with the caster's team gradient index 1 (player →
                // player gradient, enemy → enemy gradient — same convention
                // as weapon colors). See AGENTS → Entity & UI Coloring.
                const icon_color = if (entity.team == 0)
                    playerColor(active_theme, 1)
                else
                    enemyColor(active_theme, 1);
                overlays.append(allocator, .{ .floating_icon = .{
                    .sprite_id = sprite_id,
                    .screen_position = .{
                        .x = @intFromFloat(@round(icon_x)),
                        .y = @intFromFloat(@round(icon_y)),
                    },
                    .size = skill_icon_size_native,
                    .color = icon_color,
                } }) catch @panic("failed to append world overlay");
            },
            .hit_flash => |info| {
                // A killing blow still flashes: `death` zeroes health but
                // leaves the entity slot in the array, so the index stays
                // valid. We bounds-check only (not `current_health == 0`,
                // which the skill-icon path uses to skip dead casters).
                if (info.entity_index >= level.entities.len) continue;
                const entity = &level.entities[info.entity_index];

                const top_left = entityFrameTopLeft(entity, camera, zoom);
                const draw_width = entity_frame_width * zoom;
                const draw_height = entity_frame_height * zoom;
                // Horizontal: entities are always horizontally centered in
                // the frame, so the art center is the frame's horizontal
                // center.
                const center_x: f32 = @as(f32, @floatFromInt(top_left.x)) + draw_width / 2;
                // Vertical: real center of the opaque art via top-y +
                // bottom-y; fall back to the frame's vertical center on a
                // miss/transparent sprite.
                const art_top_y: f32 = if (sprite_top_y.get(entity.sprite)) |maybe_top_y|
                    if (maybe_top_y) |top_y|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(top_y)) * zoom
                    else
                        @as(f32, @floatFromInt(top_left.y))
                else
                    @as(f32, @floatFromInt(top_left.y));
                const art_bottom_y: f32 = if (sprite_bottom_y.get(entity.sprite)) |maybe_bottom_y|
                    if (maybe_bottom_y) |bottom_y|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bottom_y)) * zoom
                    else
                        @as(f32, @floatFromInt(top_left.y)) + draw_height
                else
                    @as(f32, @floatFromInt(top_left.y)) + draw_height;
                const center_y: f32 = (art_top_y + art_bottom_y) / 2;
                const drawn_size: f32 = @as(f32, @floatFromInt(hit_flash_size_native)) * zoom;
                overlays.append(allocator, .{ .floating_icon = .{
                    .sprite_id = "world/hit_flash",
                    .screen_position = .{
                        .x = @intFromFloat(@round(center_x - drawn_size / 2)),
                        .y = @intFromFloat(@round(center_y - drawn_size / 2)),
                    },
                    .size = hit_flash_size_native,
                    .color = active_theme.lightest,
                } }) catch @panic("failed to append world overlay");
            },
        }
    }
    return overlays.items;
}

/// Build an EntityDrawable for `entity`, aligning the shared sprite pivot to
/// the center of the entity's tile. Populates the base sprite, body overlay
/// layers, and weapons; gear/effect sprites are not wired. The health bar
/// is populated (always-on for alive entities), placed above the entity's
/// actual art top via the `sprite_top_y` lookup. See AGENTS → Entity & UI
/// Coloring.
fn entityDrawable(
    entity: *const Entity,
    active_theme: types.ActiveColorTheme,
    player_color_index: u32,
    camera: types.Camera,
    zoom: f32,
    allocator: std.mem.Allocator,
    sprite_top_y: std.StringHashMapUnmanaged(?i32),
    show_health_bar: bool,
) types.EntityDrawable {
    const top_left = entityFrameTopLeft(entity, camera, zoom);
    const base_sprite_id = std.fmt.allocPrint(allocator, "entities/{s}", .{entity.sprite}) catch
        @panic("failed to build entity sprite id");

    // Body color: player uses the settings-driven player gradient index;
    // enemies use their own color_index into the enemy gradient.
    const body_color = if (entity.team == 0)
        playerColor(active_theme, player_color_index)
    else
        enemyColor(active_theme, entity.color_index);

    // Overlay layers: same frame + pivot as the base, drawn after base and
    // before weapons. Each colored by its own index into the team gradient.
    var layer_sprites: std.ArrayList(types.SpriteDrawable) = .empty;
    for (entity.layers) |layer| {
        const layer_sprite_id = std.fmt.allocPrint(allocator, "entities/{s}", .{layer.sprite}) catch
            @panic("failed to build entity layer sprite id");
        const layer_color = if (entity.team == 0)
            playerColor(active_theme, layer.color_index)
        else
            enemyColor(active_theme, layer.color_index);
        layer_sprites.append(allocator, .{
            .sprite_id = layer_sprite_id,
            .screen_position = top_left,
            .draw_offset = .{ .x = 0, .y = 0 },
            .source_rectangle = null,
            .color = layer_color,
        }) catch @panic("failed to append entity layer sprite");
    }
    const layer_slice = layer_sprites.toOwnedSlice(allocator) catch
        @panic("failed to own entity layer sprites");

    // Weapons: main hand drawn as-authored (left), off hand mirrored (right).
    // Suppressed for entities that don't display weapons (e.g. wolves).
    // Color = team gradient index 1 (player → player gradient, enemy → enemy
    // gradient).
    const weapon_color = if (entity.team == 0)
        playerColor(active_theme, 1)
    else
        enemyColor(active_theme, 1);
    var weapon_sprites: [2]?types.SpriteDrawable = .{ null, null };
    if (entity.displays_weapons) {
        if (entity.main_hand_weapon) |weapon| {
            weapon_sprites[0] = weaponSprite(entity, weapon.weapon_type, top_left, false, weapon_color, allocator);
        }
        if (entity.off_hand_weapon) |weapon| {
            weapon_sprites[1] = weaponSprite(entity, weapon.weapon_type, top_left, true, weapon_color, allocator);
        }
    }

    return .{
        .back_effect_sprites = &.{},
        .base_sprite = .{
            .sprite_id = base_sprite_id,
            .screen_position = top_left,
            .draw_offset = .{ .x = 0, .y = 0 },
            .source_rectangle = null,
            .color = body_color,
        },
        .layer_sprites = layer_slice,
        .weapon_sprites = weapon_sprites,
        .gear_sprites = &.{},
        .front_effect_sprites = &.{},
        .health_bar = if (show_health_bar) buildHealthBar(entity, active_theme, top_left, zoom, sprite_top_y) else null,
    };
}

/// Build the always-on health bar above the entity's actual art top.
/// Depleted = global theme darkest; fill = team gradient index 1. The bar
/// canvas (155x31 native) is centered horizontally over the entity frame;
/// the outline sprite is drawn on top by the renderer at the same rect.
/// See AGENTS → Entity & UI Coloring.
fn buildHealthBar(
    entity: *const Entity,
    active_theme: types.ActiveColorTheme,
    frame_top_left: types.ScreenPosition,
    zoom: f32,
    sprite_top_y: std.StringHashMapUnmanaged(?i32),
) ?types.HealthBarDrawable {
    if (entity.max_health == 0) return null;
    const draw_width = entity_frame_width * zoom;
    const art_top_y: f32 = if (sprite_top_y.get(entity.sprite)) |maybe_top_y|
        if (maybe_top_y) |top_y|
            // `top_y` is in source pixels (0..640); the drawn frame height is
            // `entity_frame_height * zoom`, so the art top in screen space is
            // `frame_top + top_y * zoom`.
            @as(f32, @floatFromInt(frame_top_left.y)) + @as(f32, @floatFromInt(top_y)) * zoom
        else
            @as(f32, @floatFromInt(frame_top_left.y))
    else
        @as(f32, @floatFromInt(frame_top_left.y));
    const bar_width: f32 = @as(f32, @floatFromInt(health_bar_native_width)) * zoom;
    const bar_height: f32 = @as(f32, @floatFromInt(health_bar_native_height)) * zoom;
    const gap: f32 = @as(f32, @floatFromInt(health_bar_gap_native)) * zoom;
    const bar_x = @as(f32, @floatFromInt(frame_top_left.x)) + draw_width / 2 - bar_width / 2;
    const bar_y = art_top_y - bar_height - gap;
    const fill_color = if (entity.team == 0)
        playerColor(active_theme, 1)
    else
        enemyColor(active_theme, 1);
    return .{
        .screen_position = .{
            .x = @intFromFloat(@round(bar_x)),
            .y = @intFromFloat(@round(bar_y)),
        },
        .width = health_bar_native_width,
        .height = health_bar_native_height,
        .fill_fraction = @as(f32, @floatFromInt(entity.current_health)) / @as(f32, @floatFromInt(entity.max_health)),
        .depleted_color = active_theme.darkest,
        .fill_color = fill_color,
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
    color: types.Color,
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
        .color = color,
        .flip_horizontal = flip_horizontal,
    };
}

/// Order entities back-to-front for painter's-algorithm occlusion. tileToScreen
/// maps higher tile.y to a LARGER screen y (lower on screen = nearer the
/// viewer), so lower tile.y is further back and drawn first (ascending y).
/// One entry in the unified ground-drawable sort. `sort_y` is the tile y
/// the drawable sorts at (entity tile y, decoration piece's assigned
/// footprint y, marker tile y); `sort_x` is the horizontal tiebreak.
const GroundEntry = struct {
    sort_y: i32,
    sort_x: i32,
    drawable: types.GroundDrawable,
};

/// Unified back-to-front order: ascending sort_y, then ascending sort_x.
/// Lower y is further back (drawn first); same-y ties break by lower x
/// (left-first), matching the previous entity-only sort convention.
fn groundEntryBefore(_: void, a: GroundEntry, b: GroundEntry) bool {
    if (a.sort_y != b.sort_y) return a.sort_y < b.sort_y;
    return a.sort_x < b.sort_x;
}

/// Append entity drawables into the unified ground-entry list, each keyed by
/// its tile (y, x). Replaces the old `buildEntities` (which sorted and
/// appended directly); the unified sort happens once after all entries
/// (entities + decorations + markers) are collected.
fn collectEntityEntries(
    list: *std.ArrayList(GroundEntry),
    allocator: std.mem.Allocator,
    entities: []const *const Entity,
    active_theme: types.ActiveColorTheme,
    player_color_index: u32,
    camera: types.Camera,
    zoom: f32,
    sprite_top_y: std.StringHashMapUnmanaged(?i32),
    show_health_bar: bool,
) void {
    // Dead entities (current_health == 0) are not rendered — their sprite
    // vanishes on death.
    for (entities) |entity| {
        if (entity.current_health == 0) continue;
        list.append(allocator, .{
            .sort_y = entity.position.y,
            .sort_x = entity.position.x,
            .drawable = .{ .entity = entityDrawable(entity, active_theme, player_color_index, camera, zoom, allocator, sprite_top_y, show_health_bar) },
        }) catch @panic("failed to append entity entry");
    }
}

/// Tile size in pixels (decorations are authored at 256px/tile). Matches
/// input.tile_size_pixels — duplicated here to avoid a cross-module constant
/// for a value that's part of the rendering contract.
const tile_size_pixels: i32 = 256;

/// Build per-bbox-tile ground entries for one decoration, each carrying its
/// sort key (assigned footprint y for overhang tiles, own y for footprint
/// tiles) and the `DecorationPieceDrawable`. The sprite is split into 256px
/// chunks; each chunk is one bbox tile. Overhang bbox tiles (art but not
/// footprint) are assigned to their nearest footprint tile (Chebyshev
/// distance, tie-break bottom-most-then-left-most) and sort at that footprint
/// tile's y so wide entities don't clip through the decoration (see AGENTS
/// → Decorations & Footprint). Horizontal tiebreak among same-y pieces uses
/// the piece's own world x.
fn buildDecorationPieces(
    decoration: types.Decoration,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
    allocator: std.mem.Allocator,
) []GroundEntry {
    const tiles_w: i32 = @divTrunc(decoration.pixel_dims.x, tile_size_pixels);
    const tiles_h: i32 = @divTrunc(decoration.pixel_dims.y, tile_size_pixels);
    const anchor = decorationAnchor(decoration.footprint) orelse
        @panic("decoration has no anchor in view");
    const base_color = worldGradientColor(active_theme, decoration.color_index);

    // Build a set of footprint sprite-grid coords for O(1) membership.
    var footprint_set = std.AutoHashMap(types.Vector2, void).init(allocator);
    defer footprint_set.deinit();
    for (decoration.footprint) |fp| {
        footprint_set.put(fp, {}) catch @panic("failed to insert footprint tile");
    }

    var entries: std.ArrayList(GroundEntry) = .empty;
    var grid_y: i32 = 0;
    while (grid_y < tiles_h) : (grid_y += 1) {
        var grid_x: i32 = 0;
        while (grid_x < tiles_w) : (grid_x += 1) {
            const grid_tile = types.Vector2{ .x = grid_x, .y = grid_y };
            const is_footprint = footprint_set.contains(grid_tile);

            // World tile this piece is drawn at (for screen position + sort x).
            const world_tile = types.Vector2{
                .x = decoration.position.x + (grid_x - anchor.x),
                .y = decoration.position.y + (grid_y - anchor.y),
            };

            // Sort y: footprint tiles sort at their own world y; overhang
            // tiles sort at their assigned footprint tile's world y.
            const sort_y = if (is_footprint)
                world_tile.y
            else
                decoration.position.y + (nearestFootprint(grid_tile, decoration.footprint).y - anchor.y);

            const screen_top_left = tileToScreen(world_tile, camera, zoom);
            const source_rect = types.Rectangle{
                .x = grid_x * tile_size_pixels,
                .y = grid_y * tile_size_pixels,
                .width = tile_size_pixels,
                .height = tile_size_pixels,
            };

            // Build overlay layer chunks for this bbox tile (same source
            // rect + screen position, different sprite + color).
            var layer_sprites: std.ArrayList(types.SpriteDrawable) = .empty;
            for (decoration.layers) |layer| {
                layer_sprites.append(allocator, .{
                    .sprite_id = decorationLayerSpriteId(layer.sprite, allocator),
                    .screen_position = screen_top_left,
                    .draw_offset = .{ .x = 0, .y = 0 },
                    .source_rectangle = source_rect,
                    .color = worldGradientColor(active_theme, layer.color_index),
                }) catch @panic("failed to append layer sprite");
            }
            const layer_slice = layer_sprites.toOwnedSlice(allocator) catch
                @panic("failed to own layer sprites");

            const piece = types.DecorationPieceDrawable{
                .sprite_id = decorationSpriteId(decoration, allocator),
                .screen_position = screen_top_left,
                .draw_offset = .{ .x = 0, .y = 0 },
                .source_rectangle = source_rect,
                .color = base_color,
                .layers = layer_slice,
            };
            entries.append(allocator, .{
                .sort_y = sort_y,
                .sort_x = world_tile.x,
                .drawable = .{ .decoration_piece = piece },
            }) catch @panic("failed to append decoration piece entry");
        }
    }
    return entries.toOwnedSlice(allocator) catch @panic("failed to own decoration entries");
}

/// Find the nearest footprint tile to a sprite-grid coord by Chebyshev
/// distance, tie-breaking by footprint scan order (bottom-most-then-left-most
/// — the anchor convention, which is how `decorationAnchor` orders). Used to
/// assign overhang bbox tiles to a footprint tile for render sorting.
fn nearestFootprint(grid_tile: types.Vector2, footprint: []const types.Vector2) types.Vector2 {
    std.debug.assert(footprint.len > 0);
    var best = footprint[0];
    var best_dist = chebyshev(grid_tile, best);
    for (footprint[1..]) |fp| {
        const dist = chebyshev(grid_tile, fp);
        if (dist < best_dist) {
            best = fp;
            best_dist = dist;
        }
        // Tie: keep the first found (footprint scan order). Since the
        // footprint list is authored in sprite-grid order and the anchor is
        // bottom-most-then-left-most, the scan order is deterministic. We
        // don't re-sort the footprint here — the caller's authoring order is
        // the tiebreak, matching `decorationAnchor`'s convention.
    }
    return best;
}

fn chebyshev(a: types.Vector2, b: types.Vector2) i32 {
    const dx: i32 = @intCast(@abs(a.x - b.x));
    const dy: i32 = @intCast(@abs(a.y - b.y));
    return @max(dx, dy);
}

/// Build the sprite id (`decorations/<name>`) for a decoration. The
/// decoration's `name` field carries the sprite stem (e.g. `tree_1` or
/// `decorations/tree_1` — the parser stores the `sprite` value as-is).
fn decorationSpriteId(decoration: types.Decoration, allocator: std.mem.Allocator) []const u8 {
    return decorationSpriteIdFromName(decoration.name, allocator);
}

/// Build the sprite id for a layer (`decorations/<name>` or the name as-is
/// if it already contains `/`). Same convention as the base sprite id.
fn decorationLayerSpriteId(sprite_name: []const u8, allocator: std.mem.Allocator) []const u8 {
    return decorationSpriteIdFromName(sprite_name, allocator);
}

fn decorationSpriteIdFromName(name: []const u8, allocator: std.mem.Allocator) []const u8 {
    // Config stores the bare stem (e.g. `tree_1`); the `decorations/` folder
    // is a code-level convention, same as `entities/{s}` for entity sprites.
    // Custom decorations use a stem like `custom/<mission>/<name>` which still
    // lands under `decorations/custom/<mission>/<name>`.
    return std.fmt.allocPrint(allocator, "decorations/{s}", .{name}) catch
        @panic("failed to build decoration sprite id");
}

/// Resolve a world-gradient color by index. Clamps to the valid range
/// (0..gradient_color_count-1) so a bad index draws something sane rather
/// than crashing — the config is authored, so an out-of-range value is a
/// content bug, but view() stays robust.
fn worldGradientColor(active_theme: types.ActiveColorTheme, color_index: u32) types.Color {
    const idx = @min(color_index, types.gradient_color_count - 1);
    return active_theme.world_gradient.colors[idx];
}

/// Resolve a player-gradient color by index (clamped).
fn playerColor(active_theme: types.ActiveColorTheme, color_index: u32) types.Color {
    const idx = @min(color_index, types.gradient_color_count - 1);
    return active_theme.player_gradient.colors[idx];
}

/// Resolve an enemy-gradient color by index (clamped).
fn enemyColor(active_theme: types.ActiveColorTheme, color_index: u32) types.Color {
    const idx = @min(color_index, types.gradient_color_count - 1);
    return active_theme.enemy_gradient.colors[idx];
}

/// Derive the anchor (bottom-most-then-left-most) from a sprite-grid
/// footprint. Mirrors `parser.decorationAnchor` — duplicated in view to keep
/// view.zig dependency-free from parser.zig (the parser's version operates on
/// the same coordinate convention). Returns null if the footprint is empty.
fn decorationAnchor(footprint: []const types.Vector2) ?types.Vector2 {
    if (footprint.len == 0) return null;
    var anchor = footprint[0];
    for (footprint[1..]) |tile| {
        if (tile.y > anchor.y or (tile.y == anchor.y and tile.x < anchor.x)) {
            anchor = tile;
        }
    }
    return anchor;
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

test "flag banner: frame advances with the animation clock and wraps" {
    // The flag banner is a looping anim: frame = (clock / frame_duration)
    // % frame_count. At fps=8 (default), frame_duration = 125ms and the loop
    // is 8 frames = 1.0s. Verify frame 0 at t=0, frame 4 at t=500ms, wraps to
    // frame 0 at t=1000ms. A camera at the origin + zoom 1.0 keeps screen
    // position stable so the test can focus on the source rectangle. A dummy
    // active theme is used (the colors are not asserted here).
    const camera = types.Camera{ .position = .{ .x = 0, .y = 0 } };
    const dummy_theme = types.ActiveColorTheme{
        .lightest = .{ .r = 255, .g = 255, .b = 255 },
        .darkest = .{ .r = 0, .g = 0, .b = 0 },
        .world_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .enemy_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .player_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
    };

    const d0 = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 0, 8);
    const rect0 = d0.banner_source_rectangle.?;
    try std.testing.expectEqual(@as(i32, 0), rect0.x);
    try std.testing.expectEqual(@as(i32, 0), rect0.y);
    try std.testing.expectEqual(@as(i32, 256), rect0.width);
    try std.testing.expectEqual(@as(i32, 512), rect0.height);

    // 500ms / 125ms = frame 4.
    const d4 = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 500_000, 8);
    try std.testing.expectEqual(@as(i32, 4 * 256), d4.banner_source_rectangle.?.x);

    // 1000ms = 8 frames elapsed → wraps to frame 0.
    const d_wrap = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 1_000_000, 8);
    try std.testing.expectEqual(@as(i32, 0), d_wrap.banner_source_rectangle.?.x);

    // fps=16 → frame_duration 62.5ms (integer div → 62ms); 500_000/62 = 8064
    // frames elapsed, % 8 = 0. Just assert it doesn't divide-by-zero and
    // produces a valid frame index (the exact frame at a fractional-duration
    // boundary isn't worth pinning).
    const d_fast = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 500_000, 16);
    try std.testing.expect(d_fast.banner_source_rectangle.?.x >= 0);
    try std.testing.expect(d_fast.banner_source_rectangle.?.x < 8 * 256);

    // fps=0 is treated as 8 (no divide-by-zero).
    const d_zero = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 500_000, 0);
    try std.testing.expectEqual(@as(i32, 4 * 256), d_zero.banner_source_rectangle.?.x);
}
