//! View — builds a `ViewState` each frame from the current game state.
//!
//! `view()` is pure over `GameState` + `SessionState` + the per-frame arena;
//! everything the ViewState points at lives until the next frame. The world
//! layers (tiles, overlays, ground drawables, occlusion insets) and the flat
//! `ui_elements` slice are assembled here. Camera math (`computeCamera`,
//! `tileToScreen`) lives here too — `gameLoop` computes the camera once per
//! frame and feeds it to both `view()` and input translation so input/render
//! never drift.

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const tween = @import("tween.zig");
const ui = @import("ui.zig");
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");
const combat_log = @import("combat_log.zig");
const event_handlers = @import("event_handlers.zig");
const lookups = @import("generated_lookups.zig");
const test_harness = @import("test_harness.zig");

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
    /// Per-frame lookup of entity-sprite opaque-pixel bounding boxes: bare
    /// sprite stem (e.g. `skeleton_1`) -> `SpriteBounds` (top/bottom/left/
    /// right in SOURCE pixels), or null if the sprite can't be loaded/decoded.
    /// Built by `frame()` by querying the backend (which lazily decodes +
    /// caches -- same shape as the outline-mask cache) for each entity in the
    /// current world. Used by `view()` to place overlays against an entity's
    /// actual rendered art (skill icon above the top, hit flash at the
    /// vertical center, damage number at a corner) rather than the 512x640
    /// frame edges. Frame-arena-backed (no deinit). See AGENTS Animation.
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
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
    // DESIGN → Decorations & Footprint). Tiles + overlays are separate layers.
    var ground_entries: std.ArrayList(GroundEntry) = .empty;
    if (current_state.level) |*level| {
        buildTiles(&tiles, frame_allocator, level.level_tiles, active_theme, camera, camera_zoom);
        buildHighlightOverlays(&tile_overlays, frame_allocator, level.highlighted_tiles, active_theme, camera, camera_zoom);
        buildCursorOverlay(&tile_overlays, frame_allocator, level.level_tiles, session, active_theme, camera, camera_zoom);
        buildPreparedSkillRadiusOutline(&tile_overlays, frame_allocator, level, session, active_theme, camera, camera_zoom);
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
            collectEntityEntries(&ground_entries, frame_allocator, entity_ptrs, active_theme, settings.player_color_index, camera, camera_zoom, render.sprite_bounds, true);
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
            collectEntityEntries(&ground_entries, frame_allocator, hub_entity_ptrs, active_theme, settings.player_color_index, camera, camera_zoom, render.sprite_bounds, false);
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

    // Occlusion insets: for each non-decoration ground entry, emit an inner
    // outline if a decoration piece drawn AFTER it (greater sort order)
    // overlaps the entry's screen rect. Pure view-side → replay-safe. See
    // DESIGN → Decorations & Footprint → Occlusion inset.
    const occlusion_insets = buildOcclusionInsets(
        frame_allocator,
        ground_entries.items,
        camera_zoom,
        render.sprite_bounds,
    );

    // World overlays: one-shot anims (skill icons, etc.) drawn above ground
    // sprites. Built from `session.active_anims`; see DESIGN → Animation.
    const world_overlays = buildWorldOverlays(
        frame_allocator,
        session,
        current_state,
        camera,
        camera_zoom,
        current_event_index,
        render.sprite_bounds,
        active_theme,
        font_metrics,
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

        // Range/radius outline: when the pointer hovers a skill button,
        // preview the skill's reach as a single square outline (Chebyshev
        // ≤ range, else ≤ radius) centered on the player. Pure, off
        // SessionState — replay-safe like the cursor/tooltip. See AGENTS
        // → Input (hover-driven previews).
        buildSkillRangeOutline(
            &tile_overlays,
            frame_allocator,
            ui_elements.items,
            session,
            current_state,
            weapon_type_definitions,
            active_theme,
            camera,
            camera_zoom,
        );
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
        const ghost_pos = pointer.toScreenPosition();
        ui_elements.append(frame_allocator, .{ .image = .{
            .sprite_id = drag.icon_sprite_id,
            .screen_position = .{
                .x = ghost_pos.x - @divTrunc(ui.slot_size, 2),
                .y = ghost_pos.y - @divTrunc(ui.slot_size, 2),
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
        const point = pointer.toScreenPosition();
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
    // DESIGN → Error Handling.
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
        const hover_point = hover_pointer.toScreenPosition();
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
        .occlusion_insets = occlusion_insets,
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
    return loaders.deriveActiveColorTheme(color_theme_definitions, color_wheel_index);
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
/// Integer frame dims for the compositing canvas (occlusion inset stack).
const entity_frame_width_int: i32 = 512;
const entity_frame_height_int: i32 = 640;
const entity_pivot_x: f32 = 0.5;
const entity_pivot_y: f32 = 0.8;

/// One-shot skill-icon anim: square edge in native reference pixels (the
/// renderer multiplies by `world_scale`, matching tiles/entities), and the
/// gap above the entity's actual art top (found at runtime from the sprite's
/// topmost non-transparent pixel — see `RenderContext.sprite_bounds`). Tunable
/// — eyeball in `zig build run`. See DESIGN → Animation.
const skill_icon_size_native: i32 = 256;
const skill_icon_gap_native: i32 = 16;
/// Native (unscaled) pixel size of the aggro indicator icon drawn above an
/// entity's health bar when it gets aggroed (one-shot, 500ms). 1:1 with the
/// ported EnemyAggro.png art (128×128). Placed like the skill icon. See
/// DESIGN → Animation.
const aggro_indicator_size_native: i32 = 128;
/// Native (unscaled) pixel size of the stun overlay icon drawn above the
/// health bar of a stunned entity (while `stun_duration > 0`). 1:1 with the
/// StunEffect.png art (128×128). Tunable. See DESIGN → Animation.
const stun_icon_size_native: i32 = 128;

/// One-shot hit-flash anim: the `world/hit_flash` sprite (256x256, ported
/// from the Unity project's 512x512 Hit.png at 0.5x) flashed over a damaged
/// entity's rendered art center for 250ms, tinted with the active theme's
/// `lightest` color (the artist's offwhite). Drawn centered on the entity's
/// horizontal frame center and the real vertical center of its opaque art
/// (via `sprite_bounds` top + bottom). Tunable -- eyeball in
/// `zig build run`. See DESIGN → Animation.
const hit_flash_size_native: i32 = 256;
/// Native (unscaled) pixel size of an effect overlay sprite (drawn centered
/// on the entity's art bbox, scaled by `zoom` at render time). Tunable.
const effect_overlay_size_native: i32 = 90;

/// One-shot number anims (damage/heal): the number travels 1 tile from the
/// entity's sprite bbox edge/corner, eased with `tween.easeOutCubic` (fast
/// then slow). 500ms duration (queued by handlers; the constant lives here
/// for the `view()`-side travel distance + font size). Font size is
/// independent of the tooltip body — damage numbers read best large.
/// Tunable — eyeball in `zig build run`. See DESIGN → Animation.
const number_anim_duration_microseconds: u32 = 500_000;
const number_travel_tiles: f32 = 0.5;
const number_font_size: i32 = 112;

/// Entity health bar. The bar + outline sprites are 155x31 native (cropped
/// to the outline's opaque bbox and downscaled 0.5x from the 384x128 Unity
/// art). Drawn above the entity's actual art top (same `sprite_bounds` scan
/// as the skill icon). The skill icon sits above the health bar, so it's
/// offset by the bar's height + this gap. Tunable — eyeball in `zig build
/// run`. See DESIGN → Entity & UI Coloring.
const health_bar_native_width: i32 = 155;
const health_bar_native_height: i32 = 31;
const health_bar_gap_native: i32 = 8;

/// Ground-items sprite: `world/ground_items.png` (256x256, centered pivot
/// 0.5/0.5). Tinted at world gradient index 5 (a fixed color independent of
/// the player's body color, like the UI palette). Drawn at the stack's tile;
/// `item_count` is unused at draw time (the renderer draws just the sprite).
const ground_items_sprite_id = "world/ground_items";
const ground_items_size: f32 = 256.0;
/// Integer frame dim for the ground-items compositing canvas (occlusion inset).
const ground_items_size_int: i32 = 256;
const ground_items_pivot_x: f32 = 0.5;
const ground_items_pivot_y: f32 = 0.5;

/// Flag pole frame: 256x512 (1 tile wide x 2 tall). Pivot (0.5, 0.75) centers
/// the bottom tile-half of the frame on the marker's tile. Used for both level
/// ends and hub mission-start markers; only the static pole is drawn here.
const flag_pole_width: f32 = 256.0;
const flag_pole_height: f32 = 512.0;
/// Integer frame dims for the flag compositing canvas (occlusion inset).
const flag_pole_width_int: i32 = 256;
const flag_pole_height_int: i32 = 512;
const flag_pivot_x: f32 = 0.5;
const flag_pivot_y: f32 = 0.75;

/// Animated banner sprite (`world/flag.png`): a horizontal strip of 8 frames,
/// each 256x512 (same dims + pivot as the pole). Drawn over the pole at the
/// same screen position. Looping at `settings.animation_fps` (default 8 →
/// 125 ms/frame, 1.0 s loop). See DESIGN → Animation.
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
/// stack on top (the most recent skill use reads on top). See DESIGN →
/// Animation.
fn buildWorldOverlays(
    allocator: std.mem.Allocator,
    session: *state.SessionState,
    current_state: *const GameState,
    camera: types.Camera,
    zoom: f32,
    current_event_index: u32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
    active_theme: types.ActiveColorTheme,
    font_metrics: ui.FontMetrics,
) []const types.WorldOverlayDrawable {
    const level = current_state.level orelse return &.{};
    var overlays: std.ArrayList(types.WorldOverlayDrawable) = .empty;
    for (session.active_anims.items) |anim| {
        if (anim.event_index >= current_event_index) continue;
        // `start_clock` gate: a staggered number anim is invisible before its
        // start; all anims vanish past `end_clock`. See AGENTS Animation.
        if (session.animation_clock < anim.start_clock) continue;
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
                const art_top_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
                    if (maybe_bounds) |bounds|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
                    else
                        @as(f32, @floatFromInt(top_left.y))
                else
                    @as(f32, @floatFromInt(top_left.y));
                // The health bar sits above the art top (always-on), so the
                // icon is offset further by the bar's height + gap to avoid
                // overlap. See DESIGN → Animation / Entity & UI Coloring.
                const health_bar_total: f32 =
                    @as(f32, @floatFromInt(health_bar_native_height + health_bar_gap_native)) * zoom;
                const icon_y = art_top_y - health_bar_total - drawn_size - gap;
                const sprite_id = std.fmt.allocPrint(allocator, "skills/{s}", .{@tagName(info.skill_id)}) catch
                    @panic("failed to build skill-icon sprite id");
                // Tinted with the caster's team gradient index 1 (player →
                // player gradient, enemy → enemy gradient — same convention
                // as weapon colors). See DESIGN → Entity & UI Coloring.
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
            .aggro_indicator => |info| {
                // Mirrors the skill-icon placement (above the health bar)
                // but tinted with the active theme's `lightest`. The
                // indicator is a one-shot cosmetic marker that the entity
                // was aggroed this event; skip dead entities (a newly-dead
                // aggroed entity shouldn't show it). See DESIGN → Animation.
                if (info.entity_index >= level.entities.len) continue;
                const entity = &level.entities[info.entity_index];
                if (entity.current_health == 0) continue;

                const top_left = entityFrameTopLeft(entity, camera, zoom);
                const draw_width = entity_frame_width * zoom;
                const drawn_size: f32 = @as(f32, @floatFromInt(aggro_indicator_size_native)) * zoom;
                const gap: f32 = @as(f32, @floatFromInt(skill_icon_gap_native)) * zoom;
                const icon_x = @as(f32, @floatFromInt(top_left.x)) + draw_width / 2 - drawn_size / 2;
                const art_top_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
                    if (maybe_bounds) |bounds|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
                    else
                        @as(f32, @floatFromInt(top_left.y))
                else
                    @as(f32, @floatFromInt(top_left.y));
                const health_bar_total: f32 =
                    @as(f32, @floatFromInt(health_bar_native_height + health_bar_gap_native)) * zoom;
                const icon_y = art_top_y - health_bar_total - drawn_size - gap;
                overlays.append(allocator, .{ .floating_icon = .{
                    .sprite_id = "world/aggro",
                    .screen_position = .{
                        .x = @intFromFloat(@round(icon_x)),
                        .y = @intFromFloat(@round(icon_y)),
                    },
                    .size = aggro_indicator_size_native,
                    .color = active_theme.lightest,
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
                const art_top_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
                    if (maybe_bounds) |bounds|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
                    else
                        @as(f32, @floatFromInt(top_left.y))
                else
                    @as(f32, @floatFromInt(top_left.y));
                const art_bottom_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
                    if (maybe_bounds) |bounds|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.bottom.?)) * zoom
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
            .damage_number => |info| {
                if (info.entity_index >= level.entities.len) continue;
                const entity = &level.entities[info.entity_index];
                const progress = animProgress(anim, session.animation_clock);
                const text = std.fmt.allocPrint(allocator, "{d}", .{info.value}) catch
                    @panic("failed to format damage number");
                const pos = numberAnimPosition(
                    entity,
                    sprite_bounds,
                    camera,
                    zoom,
                    info.direction,
                    progress,
                    font_metrics,
                    text,
                );
                overlays.append(allocator, .{ .floating_text = .{
                    .text = text,
                    .screen_position = pos,
                    .font_size = number_font_size,
                    .color = active_theme.lightest,
                } }) catch @panic("failed to append world overlay");
            },
            .heal_number => |info| {
                if (info.entity_index >= level.entities.len) continue;
                const entity = &level.entities[info.entity_index];
                const progress = animProgress(anim, session.animation_clock);
                // Heals have no attacker: fixed up-right from the top-left
                // bbox corner. See AGENTS Animation.
                const text = std.fmt.allocPrint(allocator, "+{d}", .{info.value}) catch
                    @panic("failed to format heal number");
                const pos = numberAnimPosition(
                    entity,
                    sprite_bounds,
                    camera,
                    zoom,
                    .{ .x = 1, .y = -1 },
                    progress,
                    font_metrics,
                    text,
                );
                overlays.append(allocator, .{ .floating_text = .{
                    .text = text,
                    .screen_position = pos,
                    .font_size = number_font_size,
                    .color = active_theme.lightest,
                } }) catch @panic("failed to append world overlay");
            },
        }
    }

    // Stun overlay: a persistent icon drawn above the health bar of any
    // entity with `stun_duration > 0`. Not an anim — no clock, no duration,
    // no `active_anims` entry — just a direct GameState read, so it's
    // replay-safe by construction (stun_duration is on the snapshot
    // timeline). Shares the skill-icon's placement (above the health bar,
    // which sits above the art top). A stunned entity skips its turn (no
    // skill use) so the stun icon and a skill-icon pop never co-occur on
    // the same entity — same position is safe. See DESIGN → Animation.
    for (level.entities) |*entity| {
        if (entity.stun_duration == 0) continue;
        if (entity.current_health == 0) continue;

        const top_left = entityFrameTopLeft(entity, camera, zoom);
        const draw_width = entity_frame_width * zoom;
        const drawn_size: f32 = @as(f32, @floatFromInt(stun_icon_size_native)) * zoom;
        const gap: f32 = @as(f32, @floatFromInt(skill_icon_gap_native)) * zoom;
        const icon_x = @as(f32, @floatFromInt(top_left.x)) + draw_width / 2 - drawn_size / 2;
        const art_top_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
            if (maybe_bounds) |bounds|
                @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
            else
                @as(f32, @floatFromInt(top_left.y))
        else
            @as(f32, @floatFromInt(top_left.y));
        const health_bar_total: f32 =
            @as(f32, @floatFromInt(health_bar_native_height + health_bar_gap_native)) * zoom;
        const icon_y = art_top_y - health_bar_total - drawn_size - gap;
        overlays.append(allocator, .{ .floating_icon = .{
            .sprite_id = "effects/stun",
            .screen_position = .{
                .x = @intFromFloat(@round(icon_x)),
                .y = @intFromFloat(@round(icon_y)),
            },
            .size = stun_icon_size_native,
            .color = active_theme.lightest,
        } }) catch @panic("failed to append stun overlay");
    }
    return overlays.items;
}

/// Eased progress for a one-shot anim: `(clock - start) / duration` clamped
/// to [0, 1], passed through `tween.easeOutCubic` (fast then slow). Callers
/// that don't move (skill icon, hit flash) ignore this; number anims use it
/// to interpolate position. Pure, rendering-side, reads the pause-gated
/// session clock. See AGENTS Animation.
fn animProgress(anim: types.ActiveAnim, animation_clock: u64) f32 {
    if (anim.end_clock <= anim.start_clock) return 1.0;
    const elapsed: f32 = @floatFromInt(animation_clock - anim.start_clock);
    const duration: f32 = @floatFromInt(anim.end_clock - anim.start_clock);
    const raw = std.math.clamp(elapsed / duration, 0.0, 1.0);
    return tween.easeOutCubic(raw);
}

/// Compute the screen-space top-left for a floating number anim, given the
/// entity, its sprite bbox, the travel `direction` (-1/0/1 per axis), and the
/// eased `progress` in [0, 1]. The number starts at the bbox edge/corner
/// nearest the direction and travels `number_travel_tiles` along the
/// normalized direction. The text is offset so it grows AWAY from the sprite
/// (left-going → right edge at anchor; up-going → bottom at anchor; centered
/// on the pure-vertical/horizontal axes). See AGENTS Animation.
fn numberAnimPosition(
    entity: *const types.Entity,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
    camera: types.Camera,
    zoom: f32,
    direction: types.Vector2,
    progress: f32,
    font_metrics: ui.FontMetrics,
    text: []const u8,
) types.ScreenPosition {
    const top_left = entityFrameTopLeft(entity, camera, zoom);
    const draw_width = entity_frame_width * zoom;
    const draw_height = entity_frame_height * zoom;
    // Resolve the opaque-art bbox in screen space; fall back to the frame
    // edges on a miss/transparent sprite.
    const maybe_bounds = sprite_bounds.get(entity.sprite);
    const left_x: f32 = if (maybe_bounds) |b| if (b) |bounds|
        @as(f32, @floatFromInt(top_left.x)) + @as(f32, @floatFromInt(bounds.left.?)) * zoom
    else
        @as(f32, @floatFromInt(top_left.x)) else @as(f32, @floatFromInt(top_left.x));
    const right_x: f32 = if (maybe_bounds) |b| if (b) |bounds|
        @as(f32, @floatFromInt(top_left.x)) + @as(f32, @floatFromInt(bounds.right.?)) * zoom
    else
        @as(f32, @floatFromInt(top_left.x)) + draw_width else @as(f32, @floatFromInt(top_left.x)) + draw_width;
    const top_y: f32 = if (maybe_bounds) |b| if (b) |bounds|
        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
    else
        @as(f32, @floatFromInt(top_left.y)) else @as(f32, @floatFromInt(top_left.y));
    const bottom_y: f32 = if (maybe_bounds) |b| if (b) |bounds|
        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.bottom.?)) * zoom
    else
        @as(f32, @floatFromInt(top_left.y)) + draw_height else @as(f32, @floatFromInt(top_left.y)) + draw_height;

    // Start point: the bbox edge/corner nearest the travel direction.
    const dx: i32 = direction.x;
    const dy: i32 = direction.y;
    const start_x: f32 = if (dx < 0) left_x else if (dx > 0) right_x else (left_x + right_x) / 2;
    const start_y: f32 = if (dy < 0) top_y else if (dy > 0) bottom_y else (top_y + bottom_y) / 2;

    // Travel 1 tile along the normalized direction (diagonal → magnitude 1,
    // not √2, so the visual distance is consistent across the 8 directions).
    const mag = @sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy)));
    const unit_x = @as(f32, @floatFromInt(dx)) / mag;
    const unit_y = @as(f32, @floatFromInt(dy)) / mag;
    const travel = number_travel_tiles * input.tile_size_pixels * zoom;
    const end_x = start_x + unit_x * travel;
    const end_y = start_y + unit_y * travel;
    var x = start_x + (end_x - start_x) * progress;
    var y = start_y + (end_y - start_y) * progress;

    // Offset so the text grows away from the sprite: left-going → right edge
    // at anchor; up-going → bottom at anchor; pure vertical → horizontally
    // centered; pure horizontal → vertically centered.
    const text_width: f32 = @as(f32, @floatFromInt(
        font_metrics.measureSpanWidth(.{ .text = text }, number_font_size),
    )) * zoom;
    const text_height: f32 = @as(f32, @floatFromInt(number_font_size)) * zoom;
    if (dx < 0) {
        x -= text_width;
    } else if (dx == 0) {
        x -= text_width / 2;
    }
    if (dy < 0) {
        y -= text_height;
    } else if (dy == 0) {
        y -= text_height / 2;
    }
    return .{
        .x = @intFromFloat(@round(x)),
        .y = @intFromFloat(@round(y)),
    };
}

/// Build an EntityDrawable for `entity`, aligning the shared sprite pivot to
/// the center of the entity's tile. Populates the base sprite, body overlay
/// layers, and weapons; active-effect overlays populate front_effect_sprites
/// from each effect's `effect_sprite`. Gear sprites are not wired. The health
/// bar is populated (always-on for alive entities), placed above the entity's
/// actual art top via the `sprite_bounds` lookup. See DESIGN → Entity & UI
/// Coloring.
fn entityDrawable(
    entity: *const Entity,
    active_theme: types.ActiveColorTheme,
    player_color_index: u32,
    camera: types.Camera,
    zoom: f32,
    allocator: std.mem.Allocator,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
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

    // Active-effect overlays: one front_effect_sprite per effect that
    // declares an `effect_sprite`, centered on the entity's opaque-art bbox
    // (horizontal = frame center; vertical = midpoint of the bbox top/bottom,
    // falling back to the frame's vertical center on a miss/transparent
    // sprite — same resolution as the hit-flash one-shot). Tinted with the
    // active theme's lightest color. See DESIGN → Entity & UI Coloring.
    var front_effect_sprites: std.ArrayList(types.SpriteDrawable) = .empty;
    if (entity.active_effects.len > 0) {
        const draw_width = entity_frame_width * zoom;
        const draw_height = entity_frame_height * zoom;
        const center_x: f32 = @as(f32, @floatFromInt(top_left.x)) + draw_width / 2;
        const maybe_bounds = sprite_bounds.get(entity.sprite);
        const art_top_y: f32 = if (maybe_bounds) |maybe| if (maybe) |bounds|
            @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
        else
            @as(f32, @floatFromInt(top_left.y))
        else
            @as(f32, @floatFromInt(top_left.y));
        const art_bottom_y: f32 = if (maybe_bounds) |maybe| if (maybe) |bounds|
            @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.bottom.?)) * zoom
        else
            @as(f32, @floatFromInt(top_left.y)) + draw_height
        else
            @as(f32, @floatFromInt(top_left.y)) + draw_height;
        const center_y: f32 = (art_top_y + art_bottom_y) / 2;
        const drawn_size: f32 = @as(f32, @floatFromInt(effect_overlay_size_native)) * zoom;
        const overlay_top_left: types.ScreenPosition = .{
            .x = @intFromFloat(@round(center_x - drawn_size / 2)),
            .y = @intFromFloat(@round(center_y - drawn_size / 2)),
        };
        for (entity.active_effects) |active_effect| {
            const definition = lookups.getEffectDefinition(active_effect.effect_id);
            const effect_stem = definition.effect_sprite orelse continue;
            const sprite_id = std.fmt.allocPrint(allocator, "effects/{s}", .{effect_stem}) catch
                @panic("failed to build effect overlay sprite id");
            front_effect_sprites.append(allocator, .{
                .sprite_id = sprite_id,
                .screen_position = overlay_top_left,
                .draw_offset = .{ .x = 0, .y = 0 },
                .source_rectangle = null,
                .color = active_theme.lightest,
            }) catch @panic("failed to append effect overlay sprite");
        }
    }
    const front_effect_slice = front_effect_sprites.toOwnedSlice(allocator) catch
        @panic("failed to own effect overlay sprites");

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
        .front_effect_sprites = front_effect_slice,
        .health_bar = if (show_health_bar) buildHealthBar(entity, active_theme, top_left, zoom, sprite_bounds) else null,
    };
}

/// Build the always-on health bar above the entity's actual art top.
/// Depleted = global theme darkest; fill = team gradient index 1. The bar
/// canvas (155x31 native) is centered horizontally over the entity frame;
/// the outline sprite is drawn on top by the renderer at the same rect.
/// See DESIGN → Entity & UI Coloring.
fn buildHealthBar(
    entity: *const Entity,
    active_theme: types.ActiveColorTheme,
    frame_top_left: types.ScreenPosition,
    zoom: f32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
) ?types.HealthBarDrawable {
    if (entity.max_health == 0) return null;
    const draw_width = entity_frame_width * zoom;
    const art_top_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
        if (maybe_bounds) |bounds|
            // `bounds.top` is in source pixels (0..640); the drawn frame height is
            // `entity_frame_height * zoom`, so the art top in screen space is
            // `frame_top + bounds.top * zoom`.
            @as(f32, @floatFromInt(frame_top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
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
/// `entity_sprite` carries the entity's bare sprite stem for entries built
/// from an entity (used by the occlusion test's tight-bbox lookup); null for
/// non-entity entries.
const GroundEntry = struct {
    sort_y: i32,
    sort_x: i32,
    drawable: types.GroundDrawable,
    entity_sprite: ?[]const u8 = null,
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
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
    show_health_bar: bool,
) void {
    // Dead entities (current_health == 0) are not rendered — their sprite
    // vanishes on death.
    for (entities) |entity| {
        if (entity.current_health == 0) continue;
        list.append(allocator, .{
            .sort_y = entity.position.y,
            .sort_x = entity.position.x,
            .drawable = .{ .entity = entityDrawable(entity, active_theme, player_color_index, camera, zoom, allocator, sprite_bounds, show_health_bar) },
            .entity_sprite = entity.sprite,
        }) catch @panic("failed to append entity entry");
    }
}

/// Tile size in pixels (decorations are authored at 256px/tile). Matches
/// input.tile_size_pixels — duplicated here to avoid a cross-module constant
/// for a value that's part of the rendering contract.
const tile_size_pixels: i32 = 256;

/// Float rect in reference screen space, used by the occlusion overlap test.
const ScreenRect = struct { x: f32, y: f32, w: f32, h: f32 };

fn rectsOverlap(a: ScreenRect, b: ScreenRect) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}

/// The screen-space bounding rect of a ground entry. Entities use the opaque-
/// art bbox (tight, via `sprite_bounds`) so an entity standing NEXT TO a
/// decoration doesn't falsely trigger an inset; falls back to the full
/// 512×640 frame when bounds are unavailable. Decoration pieces, ground
/// items, and flag poles use their full sprite frame (single-sprite drawables
/// whose frame is tight enough).
fn groundEntryScreenRect(
    entry: GroundEntry,
    zoom: f32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
) ScreenRect {
    return switch (entry.drawable) {
        .entity => |e| entityScreenRect(e, entry.entity_sprite, zoom, sprite_bounds),
        .decoration_piece => |d| rectFromTopLeft(d.screen_position, tile_size_pixels, tile_size_pixels, zoom),
        .ground_items => |g| rectFromTopLeft(g.screen_position, ground_items_size, ground_items_size, zoom),
        .level_end => |l| rectFromTopLeft(l.screen_position, flag_pole_width, flag_pole_height, zoom),
    };
}

fn rectFromTopLeft(top_left: types.ScreenPosition, width: f32, height: f32, zoom: f32) ScreenRect {
    return .{
        .x = @floatFromInt(top_left.x),
        .y = @floatFromInt(top_left.y),
        .w = width * zoom,
        .h = height * zoom,
    };
}

fn entityScreenRect(
    entity: types.EntityDrawable,
    sprite_bare_stem: ?[]const u8,
    zoom: f32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
) ScreenRect {
    const top_left = entity.base_sprite.screen_position;
    if (sprite_bare_stem) |stem| {
        if (sprite_bounds.get(stem)) |maybe_bounds| {
            if (maybe_bounds) |b| {
                return .{
                    .x = @as(f32, @floatFromInt(top_left.x)) + @as(f32, @floatFromInt(b.left.?)) * zoom,
                    .y = @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(b.top.?)) * zoom,
                    .w = @as(f32, @floatFromInt(b.right.? - b.left.?)) * zoom,
                    .h = @as(f32, @floatFromInt(b.bottom.? - b.top.?)) * zoom,
                };
            }
        }
    }
    return rectFromTopLeft(top_left, entity_frame_width, entity_frame_height, zoom);
}

/// The inset draw target (sprite stack + frame dims + frame top-left) for a
/// ground entry, or null for decoration pieces (which are occluders, never
/// occluded). The stack is built into `allocator`: entity = base + layers +
/// weapons; flag = pole + current banner frame; ground items = single sprite.
const InsetTarget = struct {
    sprite_stack: []const types.StackSprite,
    screen_position: types.ScreenPosition,
    frame_width: i32,
    frame_height: i32,
};

fn occlusionInsetTarget(entry: GroundEntry, allocator: std.mem.Allocator) ?InsetTarget {
    return switch (entry.drawable) {
        .decoration_piece => null,
        .entity => |e| entityInsetTarget(e, allocator),
        .ground_items => |g| .{
            .sprite_stack = singleStack(allocator, g.sprite_id),
            .screen_position = g.screen_position,
            .frame_width = ground_items_size_int,
            .frame_height = ground_items_size_int,
        },
        .level_end => |l| flagInsetTarget(l, allocator),
    };
}

fn singleStack(allocator: std.mem.Allocator, sprite_id: []const u8) []const types.StackSprite {
    const stack = allocator.alloc(types.StackSprite, 1) catch
        @panic("failed to alloc single-stack");
    stack[0] = .{ .sprite_id = sprite_id };
    return stack;
}

fn entityInsetTarget(entity: types.EntityDrawable, allocator: std.mem.Allocator) InsetTarget {
    // base + layers + weapons (non-null). Gear and effect sprites are
    // excluded — gear is a separate concern and effects are transient
    // (including them would make the outline flicker and balloon the cache).
    var stack: std.ArrayList(types.StackSprite) = .empty;
    stack.append(allocator, .{ .sprite_id = entity.base_sprite.sprite_id }) catch
        @panic("failed to append base to entity stack");
    for (entity.layer_sprites) |layer| {
        stack.append(allocator, .{
            .sprite_id = layer.sprite_id,
            .source_rectangle = layer.source_rectangle,
            .flip_horizontal = layer.flip_horizontal,
        }) catch @panic("failed to append layer to entity stack");
    }
    for (entity.weapon_sprites) |maybe_weapon| {
        if (maybe_weapon) |weapon| {
            stack.append(allocator, .{
                .sprite_id = weapon.sprite_id,
                .source_rectangle = weapon.source_rectangle,
                .flip_horizontal = weapon.flip_horizontal,
            }) catch @panic("failed to append weapon to entity stack");
        }
    }
    return .{
        .sprite_stack = stack.toOwnedSlice(allocator) catch @panic("failed to own entity stack"),
        .screen_position = entity.base_sprite.screen_position,
        .frame_width = entity_frame_width_int,
        .frame_height = entity_frame_height_int,
    };
}

fn flagInsetTarget(marker: types.LevelEndDrawable, allocator: std.mem.Allocator) InsetTarget {
    // pole + current banner frame. The banner's source rectangle selects the
    // animation frame from the 2048×512 sheet; compositing it with the pole
    // means the occluded flag shows the animated banner's silhouette, not just
    // the static pole.
    var stack: std.ArrayList(types.StackSprite) = .empty;
    stack.append(allocator, .{ .sprite_id = marker.sprite_id }) catch
        @panic("failed to append pole to flag stack");
    if (marker.banner_source_rectangle) |banner_rect| {
        stack.append(allocator, .{
            .sprite_id = flag_banner_sprite_id,
            .source_rectangle = banner_rect,
        }) catch @panic("failed to append banner to flag stack");
    }
    return .{
        .sprite_stack = stack.toOwnedSlice(allocator) catch @panic("failed to own flag stack"),
        .screen_position = marker.screen_position,
        .frame_width = flag_pole_width_int,
        .frame_height = flag_pole_height_int,
    };
}

/// Run the occlusion test over the sorted ground entries. For each non-
/// decoration entry, emit one `OcclusionInsetDrawable` if any decoration
/// piece at a higher sort index (drawn after it) has an overlapping screen
/// rect. O(entries × decoration_pieces) per frame — fine at current caps.
/// Pure, view-side → off GameState → replay-safe. See DESIGN → Decorations &
/// Footprint → Occlusion inset.
fn buildOcclusionInsets(
    allocator: std.mem.Allocator,
    entries: []const GroundEntry,
    zoom: f32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
) []const types.OcclusionInsetDrawable {
    if (entries.len == 0) return &.{};

    // Screen rects parallel to `entries`.
    const entry_rects = allocator.alloc(ScreenRect, entries.len) catch
        @panic("failed to alloc entry rects");
    for (entries, 0..) |entry, i| {
        entry_rects[i] = groundEntryScreenRect(entry, zoom, sprite_bounds);
    }

    // Decoration piece indices (the occluders).
    var deco_indices: std.ArrayList(usize) = .empty;
    for (entries, 0..) |entry, i| {
        if (entry.drawable == .decoration_piece) deco_indices.append(allocator, i) catch
            @panic("failed to append decoration index");
    }

    var insets: std.ArrayList(types.OcclusionInsetDrawable) = .empty;
    for (entries, 0..) |entry, i| {
        const target = occlusionInsetTarget(entry, allocator) orelse continue;
        for (deco_indices.items) |j| {
            if (j <= i) continue; // only decorations drawn AFTER this entry occlude it
            if (rectsOverlap(entry_rects[i], entry_rects[j])) {
                insets.append(allocator, .{
                    .sprite_stack = target.sprite_stack,
                    .screen_position = target.screen_position,
                    .frame_width = target.frame_width,
                    .frame_height = target.frame_height,
                    .alpha = 128,
                }) catch @panic("failed to append occlusion inset");
                break;
            }
        }
    }
    return insets.toOwnedSlice(allocator) catch @panic("failed to own occlusion insets");
}

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
/// footprint. Mirrors `loaders.decorationAnchor` — duplicated in view to keep
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

/// Range/radius outline: when the pointer hovers a skill button on the
/// bottom bar, preview that skill's reach as a single square outline
/// centered on the player. The square's half-side is the skill's `range`
/// (preferred) or `radius` (fallback); a skill with neither draws nothing.
/// Drawn in full (may extend past level edges / over gaps) at Chebyshev
/// ≤ N — a geometric preview, not pathfinding reachability. Tinted with
/// `active_theme.lightest`, same as the cursor. Suppressed while dragging
/// (the pointer is dragging, not hovering). Works in levels and hubs
/// (skill slots appear on the bottom bar in both). Pure over SessionState
/// (off the undoable GameState) → replay-safe by construction.
fn buildSkillRangeOutline(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    ui_elements: []const ui.UiElement,
    session: *const state.SessionState,
    current_state: *const GameState,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    if (session.ui_state.drag != null) return;

    const pointer = session.input_state.mouse_screen_position;
    const point = pointer.toScreenPosition();
    const button = ui.buttonAt(ui_elements, point) orelse return;
    const slot = ui.actionSkillSlot(button.action) orelse return;

    const player = ui.playerEntity(current_state) orelse return;
    const skill_id = player.skillInSlot(slot, weapon_type_definitions) orelse return;
    const definition = lookups.getSkillDefinition(skill_id) orelse return;

    const n: u32 = if (definition.range) |r| r else if (definition.radius) |rad| rad else return;
    const overlay_type: types.TileOverlayType = if (definition.range != null) .range_outline else .radius_outline;

    const top_left = types.Vector2{ .x = player.position.x - @as(i32, @intCast(n)), .y = player.position.y - @as(i32, @intCast(n)) };
    list.append(allocator, .{
        .screen_position = tileToScreen(top_left, camera, zoom),
        .overlay_type = overlay_type,
        .color = active_theme.lightest,
        .extent = 2 * n + 1,
    }) catch @panic("failed to append skill range outline");
}

/// Radius outline around the tile cursor while a targeting skill with a
/// radius is prepared (e.g. Flash Strike: teleport to a target tile within
/// range, then attack within radius of the landing). The valid-target
/// highlights show where the player can land; this previews the AoE that
/// will hit around the cursor's current tile as the player aims. Drawn in
/// full (may extend past level edges / over gaps) at Chebyshev ≤ radius —
/// a geometric preview. Tinted with `active_theme.lightest`. Levels only
/// (`prepared_skill` is null in a hub). Pure over SessionState (off the
/// undoable GameState) → replay-safe by construction.
fn buildPreparedSkillRadiusOutline(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    level: *const types.Level,
    session: *const state.SessionState,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    const prepared = level.prepared_skill orelse return;
    const definition = lookups.getSkillDefinition(prepared) orelse return;
    if (!definition.uses_targeting) return;
    const radius = definition.radius orelse return;
    const cursor = session.tile_cursor orelse return;

    const n: i32 = @intCast(radius);
    const top_left = types.Vector2{ .x = cursor.x - n, .y = cursor.y - n };
    list.append(allocator, .{
        .screen_position = tileToScreen(top_left, camera, zoom),
        .overlay_type = .radius_outline,
        .color = active_theme.lightest,
        .extent = 2 * radius + 1,
    }) catch @panic("failed to append prepared-skill radius outline");
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

test "skill range outline: range/radius/none/drag" {
    // Hovering a skill button previews the skill's reach as a single square
    // outline centered on the player: Chebyshev ≤ range (else ≤ radius),
    // extent = 2*N + 1. A skill with neither draws nothing; dragging
    // suppresses the preview. Pure, off SessionState.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const dummy_theme = types.ActiveColorTheme{
        .lightest = .{ .r = 255, .g = 255, .b = 255 },
        .darkest = .{ .r = 0, .g = 0, .b = 0 },
        .world_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .enemy_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .player_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
    };
    const camera = types.Camera{ .position = .{ .x = 0, .y = 0 } };

    // Player at (5, 5) with a sword (slot 1 -> Slice, range 1) and a utility
    // skill in slot 4 we swap per case.
    const player = types.Entity{
        .position = .{ .x = 5, .y = 5 },
        .main_hand_weapon = .{ .weapon_type = .sword },
    };

    // Case 1: slot 1 -> Slice (range 1) -> range_outline, extent 3.
    {
        const state_ = test_harness.levelStateWithEntities(arena, &.{player}, &.{});
        var session = state.SessionState{};
        session.input_state.mouse_screen_position = .{ .x = 200, .y = 200 };
        const ui_elements = [_]ui.UiElement{.{ .button = .{
            .action = .skill_slot_1,
            .screen_position = .{ .x = 100, .y = 100 },
            .width = 256,
            .height = 256,
        } }};
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildSkillRangeOutline(&overlays, arena, &ui_elements, &session, &state_, &harness.weapon_type_definitions, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 1), overlays.items.len);
        const ov = overlays.items[0];
        try std.testing.expectEqual(types.TileOverlayType.range_outline, ov.overlay_type);
        try std.testing.expectEqual(@as(u32, 3), ov.extent);
        try std.testing.expectEqual(dummy_theme.lightest, ov.color);
    }

    // Case 2: slot 4 -> Slam (radius 1) -> radius_outline, extent 3.
    {
        var p2 = player;
        p2.equipped_utility_skills[0] = .slam;
        const state_ = test_harness.levelStateWithEntities(arena, &.{p2}, &.{});
        var session = state.SessionState{};
        session.input_state.mouse_screen_position = .{ .x = 200, .y = 200 };
        const ui_elements = [_]ui.UiElement{.{ .button = .{
            .action = .skill_slot_4,
            .screen_position = .{ .x = 100, .y = 100 },
            .width = 256,
            .height = 256,
        } }};
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildSkillRangeOutline(&overlays, arena, &ui_elements, &session, &state_, &harness.weapon_type_definitions, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 1), overlays.items.len);
        const ov = overlays.items[0];
        try std.testing.expectEqual(types.TileOverlayType.radius_outline, ov.overlay_type);
        try std.testing.expectEqual(@as(u32, 3), ov.extent);
    }

    // Case 3: slot 4 -> Focus (no range, no radius) -> no outline.
    {
        var p3 = player;
        p3.equipped_utility_skills[0] = .focus;
        const state_ = test_harness.levelStateWithEntities(arena, &.{p3}, &.{});
        var session = state.SessionState{};
        session.input_state.mouse_screen_position = .{ .x = 200, .y = 200 };
        const ui_elements = [_]ui.UiElement{.{ .button = .{
            .action = .skill_slot_4,
            .screen_position = .{ .x = 100, .y = 100 },
            .width = 256,
            .height = 256,
        } }};
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildSkillRangeOutline(&overlays, arena, &ui_elements, &session, &state_, &harness.weapon_type_definitions, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }

    // Case 4: drag suppresses the outline even for a range skill.
    {
        const state_ = test_harness.levelStateWithEntities(arena, &.{player}, &.{});
        var session = state.SessionState{};
        session.input_state.mouse_screen_position = .{ .x = 200, .y = 200 };
        session.ui_state.drag = .{ .icon_sprite_id = "skills/slice", .source = .{ .skill_bar = 0 } };
        const ui_elements = [_]ui.UiElement{.{ .button = .{
            .action = .skill_slot_1,
            .screen_position = .{ .x = 100, .y = 100 },
            .width = 256,
            .height = 256,
        } }};
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildSkillRangeOutline(&overlays, arena, &ui_elements, &session, &state_, &harness.weapon_type_definitions, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }
}

test "prepared skill radius outline: follows cursor while targeting" {
    // While a targeting skill with a radius is prepared (e.g. Flash Strike),
    // a radius outline follows the tile cursor — previewing the AoE around
    // the landing tile the player is aiming at. Extent = 2*radius + 1,
    // .radius_outline, theme lightest. Levels only (prepared_skill is null
    // in a hub); no overlay when no skill is prepared, the skill has no
    // radius, or the cursor is null.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    const dummy_theme = types.ActiveColorTheme{
        .lightest = .{ .r = 255, .g = 255, .b = 255 },
        .darkest = .{ .r = 0, .g = 0, .b = 0 },
        .world_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .enemy_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .player_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
    };
    const camera = types.Camera{ .position = .{ .x = 0, .y = 0 } };

    // Case 1: Flash Strike prepared (uses_targeting, radius 1), cursor at
    // (5,5) -> radius_outline, extent 3, centered on cursor.
    {
        var state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{});
        state_.level.?.prepared_skill = .flash_strike;
        var session = state.SessionState{};
        session.tile_cursor = .{ .x = 5, .y = 5 };
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildPreparedSkillRadiusOutline(&overlays, arena, &state_.level.?, &session, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 1), overlays.items.len);
        const ov = overlays.items[0];
        try std.testing.expectEqual(types.TileOverlayType.radius_outline, ov.overlay_type);
        try std.testing.expectEqual(@as(u32, 3), ov.extent);
        try std.testing.expectEqual(dummy_theme.lightest, ov.color);
    }

    // Case 2: no skill prepared -> no overlay.
    {
        const state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{});
        var session = state.SessionState{};
        session.tile_cursor = .{ .x = 5, .y = 5 };
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildPreparedSkillRadiusOutline(&overlays, arena, &state_.level.?, &session, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }

    // Case 3: a non-targeting radius skill (Spinblade) prepared -> no overlay
    // (uses_targeting is false; its radius is already shown as the skill's own
    // reach, not a cursor-following preview).
    {
        var state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{});
        state_.level.?.prepared_skill = .spinblade;
        var session = state.SessionState{};
        session.tile_cursor = .{ .x = 5, .y = 5 };
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildPreparedSkillRadiusOutline(&overlays, arena, &state_.level.?, &session, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }

    // Case 4: Flash Strike prepared but cursor null -> no overlay.
    {
        var state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{});
        state_.level.?.prepared_skill = .flash_strike;
        var session = state.SessionState{};
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildPreparedSkillRadiusOutline(&overlays, arena, &state_.level.?, &session, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }
}
