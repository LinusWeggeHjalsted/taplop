//! raylib platform backend. This is the ONLY file (besides native.zig) that
//! imports raylib, and it is compiled solely into the native exe (and, later,
//! the wasm32-emscripten exe). The shared game logic in main.zig never touches
//! raylib; gameLoop drives this backend through a small duck-typed interface:
//!   shouldClose() bool
//!   deltaMicroseconds() u64
//!   pollInput() input.PlatformInput
//!   render(view_state, viewport) void
//!
//! Rendering model: all UI/world content is authored in a fixed reference
//! resolution (types.reference_width x reference_height). We draw it 1:1 into a
//! reference-sized RenderTexture, then blit that to the window letterboxed
//! (aspect-preserving, centered). Input maps the pointer back through the
//! inverse of that same letterbox transform, so clicks line up with what is
//! drawn. World-layer drawing (tiles/entities) lands in a later phase; today
//! render() draws the background + the flat UI element list.

const std = @import("std");
const rl = @import("raylib");
const input = @import("input.zig");
const types = @import("types.zig");
const ui = @import("ui.zig");

const reference_width_int: i32 = types.reference_width;
const reference_height_int: i32 = types.reference_height;
const reference_width: f32 = @floatFromInt(reference_width_int);
const reference_height: f32 = @floatFromInt(reference_height_int);

/// A raylib key mapped to the game's binding id (Web KeyboardEvent.code style,
/// e.g. "KeyZ", "Escape", "Digit1"). Only the keys the game actually binds are
/// listed; unmapped keys are ignored. Modifiers are included so getModifiers()
/// can detect ctrl/shift/alt for chorded bindings (undo/redo).
const KeyMapping = struct {
    key: rl.KeyboardKey,
    id: []const u8,
};

const key_mappings = [_]KeyMapping{
    // Modifiers (tracked as held keys so getModifiers can read them).
    .{ .key = .left_control, .id = "ControlLeft" },
    .{ .key = .right_control, .id = "ControlRight" },
    .{ .key = .left_shift, .id = "ShiftLeft" },
    .{ .key = .right_shift, .id = "ShiftRight" },
    .{ .key = .left_alt, .id = "AltLeft" },
    .{ .key = .right_alt, .id = "AltRight" },
    // Action keys bound in data/settings.txt.
    .{ .key = .z, .id = "KeyZ" },
    .{ .key = .y, .id = "KeyY" },
    .{ .key = .i, .id = "KeyI" },
    .{ .key = .g, .id = "KeyG" },
    .{ .key = .s, .id = "KeyS" },
    .{ .key = .m, .id = "KeyM" },
    .{ .key = .l, .id = "KeyL" },
    .{ .key = .escape, .id = "Escape" },
    .{ .key = .enter, .id = "Enter" },
    .{ .key = .backspace, .id = "Backspace" },
    .{ .key = .space, .id = "Space" },
    .{ .key = .one, .id = "Digit1" },
    .{ .key = .two, .id = "Digit2" },
    .{ .key = .three, .id = "Digit3" },
    .{ .key = .four, .id = "Digit4" },
    .{ .key = .five, .id = "Digit5" },
    .{ .key = .six, .id = "Digit6" },
    .{ .key = .seven, .id = "Digit7" },
    .{ .key = .eight, .id = "Digit8" },
};

const MouseMapping = struct {
    button: rl.MouseButton,
    id: []const u8,
};

const mouse_mappings = [_]MouseMapping{
    .{ .button = .left, .id = "left" },
    .{ .button = .right, .id = "right" },
    .{ .button = .middle, .id = "middle" },
};

/// Upper bound on events emitted in a single frame: one edge per mapped
/// key/button (down or up, never both in one frame) plus one mouse-move.
const max_events_per_frame = key_mappings.len + mouse_mappings.len + 1;

/// Maps reference-space content to the actual window: a uniform scale plus a
/// centering offset (the letterbox bars). `render` uses it to blit; `pollInput`
/// inverts it to bring the pointer back into reference space.
const ViewTransform = struct {
    scale: f32,
    offset_x: f32,
    offset_y: f32,
};

fn viewTransform() ViewTransform {
    const window_width: f32 = @floatFromInt(rl.getScreenWidth());
    const window_height: f32 = @floatFromInt(rl.getScreenHeight());
    const scale = @min(window_width / reference_width, window_height / reference_height);
    return .{
        .scale = scale,
        .offset_x = (window_width - reference_width * scale) / 2,
        .offset_y = (window_height - reference_height * scale) / 2,
    };
}

pub const RaylibBackend = struct {
    allocator: std.mem.Allocator,
    /// sprite_id -> loaded texture. A cached `null` means "known missing" so a
    /// failed load is not retried (and spammed) every frame. Keys are duped
    /// into `allocator`; the loaded textures live until deinit.
    texture_cache: std.StringHashMapUnmanaged(?rl.Texture2D) = .empty,
    /// Reference-resolution offscreen target; blitted to the window each frame.
    render_target: rl.RenderTexture2D,
    /// Default bitmap font for text labels (real TTF + glyph metrics later).
    font: rl.Font,
    /// Transient per-frame allocations (null-terminated strings for raylib,
    /// asset paths). Reset at the start of every render.
    frame_arena: std.heap.ArenaAllocator,
    /// Scratch for the events emitted by pollInput each frame. Valid only until
    /// the next pollInput; translateInput consumes it synchronously.
    event_buffer: [max_events_per_frame]input.PlatformInputEvent = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        width: i32,
        height: i32,
        title: [:0]const u8,
    ) RaylibBackend {
        rl.setConfigFlags(.{ .window_resizable = true, .vsync_hint = true });
        rl.initWindow(width, height, title);
        rl.setExitKey(.null); // Escape is a game binding (options menu), not quit.

        const render_target = rl.loadRenderTexture(reference_width_int, reference_height_int) catch
            @panic("failed to create reference-resolution render target");
        const font = rl.getFontDefault() catch @panic("failed to load default font");

        return .{
            .allocator = allocator,
            .render_target = render_target,
            .font = font,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *RaylibBackend) void {
        var textures = self.texture_cache.valueIterator();
        while (textures.next()) |maybe_texture| {
            if (maybe_texture.*) |texture| rl.unloadTexture(texture);
        }
        self.texture_cache.deinit(self.allocator);
        self.frame_arena.deinit();
        rl.unloadRenderTexture(self.render_target);
        rl.closeWindow();
    }

    pub fn shouldClose(_: *RaylibBackend) bool {
        return rl.windowShouldClose();
    }

    pub fn deltaMicroseconds(_: *RaylibBackend) u64 {
        const seconds = rl.getFrameTime(); // time the previous frame took
        if (seconds <= 0) return 0;
        return @intFromFloat(seconds * std.time.us_per_s);
    }

    pub fn pollInput(self: *RaylibBackend) input.PlatformInput {
        var count: usize = 0;

        // Mouse position, mapped from window pixels back into reference space
        // through the inverse of the render letterbox transform.
        const transform = viewTransform();
        const mouse = rl.getMousePosition();
        self.event_buffer[count] = .{ .mouse_move = .{
            .x = if (transform.scale > 0) (mouse.x - transform.offset_x) / transform.scale else 0,
            .y = if (transform.scale > 0) (mouse.y - transform.offset_y) / transform.scale else 0,
        } };
        count += 1;

        // Keyboard edges.
        for (key_mappings) |mapping| {
            if (rl.isKeyPressed(mapping.key)) {
                self.event_buffer[count] = .{ .key_down = mapping.id };
                count += 1;
            } else if (rl.isKeyReleased(mapping.key)) {
                self.event_buffer[count] = .{ .key_up = mapping.id };
                count += 1;
            }
        }

        // Mouse button edges.
        for (mouse_mappings) |mapping| {
            if (rl.isMouseButtonPressed(mapping.button)) {
                self.event_buffer[count] = .{ .mouse_button_down = mapping.id };
                count += 1;
            } else if (rl.isMouseButtonReleased(mapping.button)) {
                self.event_buffer[count] = .{ .mouse_button_up = mapping.id };
                count += 1;
            }
        }

        return .{
            .events = self.event_buffer[0..count],
            // The game works entirely in reference space (the pointer above is
            // mapped there), so report the reference resolution as the viewport.
            .viewport = .{ .width = reference_width, .height = reference_height },
        };
    }

    pub fn render(
        self: *RaylibBackend,
        view_state: types.ViewState,
        viewport: input.ViewportSize,
    ) void {
        _ = viewport;
        _ = self.frame_arena.reset(.retain_capacity);

        // Draw all reference-space content into the offscreen target.
        rl.beginTextureMode(self.render_target);
        rl.clearBackground(toRaylibColor(view_state.background_color, 255));
        // World layers first (tiles, then overlays + ground drawables as they
        // land), then the UI on top.
        for (view_state.tiles) |tile| self.drawWorldSprite(
            "world/tile",
            tile.screen_position,
            view_state.world_scale,
            tile.color,
        );
        for (view_state.tile_overlays) |overlay| drawTileOverlay(overlay, view_state.world_scale);
        for (view_state.ground_drawables) |ground| self.drawGroundDrawable(ground, view_state.world_scale);
        for (view_state.ui_elements) |element| self.drawUiElement(element);
        rl.endTextureMode();

        // Blit the target to the window, letterboxed. RenderTextures are stored
        // y-flipped, so the source height is negated.
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.Color.black);
        const transform = viewTransform();
        const source = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = reference_width,
            .height = -reference_height,
        };
        const destination = rl.Rectangle{
            .x = transform.offset_x,
            .y = transform.offset_y,
            .width = reference_width * transform.scale,
            .height = reference_height * transform.scale,
        };
        rl.drawTexturePro(self.render_target.texture, source, destination, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
    }

    // -- World drawing --

    /// Draw a tile overlay as a primitive (no overlay art): a translucent fill
    /// for move-range highlights, an outline for the cursor / range outlines.
    /// Sized to one tile at the current world scale.
    fn drawTileOverlay(overlay: types.TileOverlayDrawable, world_scale: f32) void {
        const tile_size = input.tile_size_pixels * world_scale;
        const rectangle = rl.Rectangle{
            .x = @floatFromInt(overlay.screen_position.x),
            .y = @floatFromInt(overlay.screen_position.y),
            .width = tile_size,
            .height = tile_size,
        };
        switch (overlay.overlay_type) {
            .highlight => rl.drawRectangleRec(rectangle, toRaylibColor(overlay.color, 90)),
            .cursor, .range_outline, .radius_outline, .aggro_outline => {
                rl.drawRectangleLinesEx(rectangle, 6 * world_scale, toRaylibColor(overlay.color, 255));
            },
        }
    }

    /// Draw a world sprite at its native texture size scaled by `world_scale`
    /// (see ViewState.world_scale), anchored at `screen_position` (reference
    /// space). `tint` multiplies the grayscale sprite (theme coloring).
    fn drawWorldSprite(
        self: *RaylibBackend,
        sprite_id: []const u8,
        screen_position: types.ScreenPosition,
        world_scale: f32,
        tint: types.Color,
    ) void {
        const texture = self.getTexture(sprite_id) orelse return;
        const width: f32 = @as(f32, @floatFromInt(texture.width)) * world_scale;
        const height: f32 = @as(f32, @floatFromInt(texture.height)) * world_scale;
        const destination = rl.Rectangle{
            .x = @floatFromInt(screen_position.x),
            .y = @floatFromInt(screen_position.y),
            .width = width,
            .height = height,
        };
        const source = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(texture.width),
            .height = @floatFromInt(texture.height),
        };
        rl.drawTexturePro(texture, source, destination, .{ .x = 0, .y = 0 }, 0, toRaylibColor(tint, 255));
    }

    /// Draw a world SpriteDrawable: its screen_position is the top-left anchor
    /// (reference space, pivot already applied by view()); size is the source
    /// region (or whole texture) scaled by world_scale. Honors source-rect
    /// cropping and draw_offset (used by decoration overhang).
    fn drawSpriteDrawable(
        self: *RaylibBackend,
        sprite: types.SpriteDrawable,
        world_scale: f32,
    ) void {
        const texture = self.getTexture(sprite.sprite_id) orelse return;
        var source = if (sprite.source_rectangle) |rectangle| rl.Rectangle{
            .x = @floatFromInt(rectangle.x),
            .y = @floatFromInt(rectangle.y),
            .width = @floatFromInt(rectangle.width),
            .height = @floatFromInt(rectangle.height),
        } else rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(texture.width),
            .height = @floatFromInt(texture.height),
        };
        // A negative source width tells DrawTexturePro to mirror horizontally.
        if (sprite.flip_horizontal) source.width = -source.width;
        const destination = rl.Rectangle{
            .x = @floatFromInt(sprite.screen_position.x + sprite.draw_offset.x),
            .y = @floatFromInt(sprite.screen_position.y + sprite.draw_offset.y),
            .width = source.width * world_scale,
            .height = source.height * world_scale,
        };
        rl.drawTexturePro(texture, source, destination, .{ .x = 0, .y = 0 }, 0, toRaylibColor(sprite.color, 255));
    }

    /// Draw one ground drawable (entity stack, decoration piece, ground items,
    /// or level-end marker). Entity sub-sprites are drawn back-to-front.
    fn drawGroundDrawable(
        self: *RaylibBackend,
        ground: types.GroundDrawable,
        world_scale: f32,
    ) void {
        switch (ground) {
            .entity => |entity| {
                for (entity.back_effect_sprites) |sprite| self.drawSpriteDrawable(sprite, world_scale);
                self.drawSpriteDrawable(entity.base_sprite, world_scale);
                for (entity.weapon_sprites) |maybe_sprite| {
                    if (maybe_sprite) |sprite| self.drawSpriteDrawable(sprite, world_scale);
                }
                for (entity.gear_sprites) |sprite| self.drawSpriteDrawable(sprite, world_scale);
                for (entity.front_effect_sprites) |sprite| self.drawSpriteDrawable(sprite, world_scale);
                // health_bar: deferred (drawn as a small bar later).
            },
            .decoration_piece => |decoration| self.drawSpriteDrawable(.{
                .sprite_id = decoration.sprite_id,
                .screen_position = decoration.screen_position,
                .draw_offset = decoration.draw_offset,
                .source_rectangle = decoration.source_rectangle,
                .color = decoration.color,
            }, world_scale),
            .ground_items => |items| self.drawWorldSprite(items.sprite_id, items.screen_position, world_scale, items.color),
            .level_end => |marker| self.drawWorldSprite(marker.sprite_id, marker.screen_position, world_scale, marker.color),
        }
    }

    // -- UI element drawing --

    fn drawUiElement(self: *RaylibBackend, element: ui.UiElement) void {
        switch (element) {
            .nine_slice_panel => |panel| self.drawNineSlice(panel),
            .slot => |slot| {
                if (slot.icon_sprite_id) |sprite_id| {
                    self.drawSprite(sprite_id, referenceRectangle(slot.screen_position, slot.size, slot.size), null, slot.icon_color);
                }
            },
            .button => |button| {
                // Spriteless buttons are pure action/hit-test targets over a
                // separate background; the renderer draws nothing for them.
                if (button.sprite_id) |sprite_id| {
                    self.drawSprite(sprite_id, referenceRectangle(button.screen_position, button.width, button.height), null, button.color);
                }
            },
            .text_label => |label| self.drawTextLabel(label),
            .fill_sprite => |fill| self.drawFillSprite(fill),
            .image => |image| self.drawSprite(image.sprite_id, referenceRectangle(image.screen_position, image.width, image.height), null, image.color),
        }
    }

    /// Draw a sprite into `destination`. `source` selects a sub-region of the
    /// texture (null = whole texture). `tint` multiplies the (grayscale) sprite
    /// — this is the grayscale×color theming path. Missing textures draw a
    /// magenta box so absent art is obvious without crashing.
    fn drawSprite(
        self: *RaylibBackend,
        sprite_id: []const u8,
        destination: rl.Rectangle,
        source: ?rl.Rectangle,
        tint: types.Color,
    ) void {
        const texture = self.getTexture(sprite_id) orelse {
            rl.drawRectangleRec(destination, rl.Color.magenta);
            return;
        };
        const whole = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(texture.width),
            .height = @floatFromInt(texture.height),
        };
        rl.drawTexturePro(texture, source orelse whole, destination, .{ .x = 0, .y = 0 }, 0, toRaylibColor(tint, 255));
    }

    /// 9-slice: the four corners are drawn 1:1 (at the source slice size), and
    /// the edges + center are stretched to fill the remaining area. TODO: the
    /// edges/center should tile rather than stretch (see TODO.txt).
    fn drawNineSlice(self: *RaylibBackend, panel: ui.NineSlicePanel) void {
        const texture = self.getTexture(panel.sprite_id) orelse {
            rl.drawRectangleRec(referenceRectangle(panel.screen_position, panel.width, panel.height), rl.Color.magenta);
            return;
        };
        const tint = toRaylibColor(panel.color, 255);
        const source_slice_width: f32 = @as(f32, @floatFromInt(texture.width)) / 3;
        const source_slice_height: f32 = @as(f32, @floatFromInt(texture.height)) / 3;

        const destination_x: f32 = @floatFromInt(panel.screen_position.x);
        const destination_y: f32 = @floatFromInt(panel.screen_position.y);
        const destination_width: f32 = @floatFromInt(panel.width);
        const destination_height: f32 = @floatFromInt(panel.height);

        // Corner size in reference pixels = source slice size (1:1), clamped so
        // corners never overlap on a small panel.
        const corner_width = @min(source_slice_width, destination_width / 2);
        const corner_height = @min(source_slice_height, destination_height / 2);

        const source_columns = [3]f32{ 0, source_slice_width, source_slice_width * 2 };
        const source_widths = [3]f32{ source_slice_width, source_slice_width, source_slice_width };
        const source_rows = [3]f32{ 0, source_slice_height, source_slice_height * 2 };
        const source_heights = [3]f32{ source_slice_height, source_slice_height, source_slice_height };

        const destination_columns = [3]f32{ destination_x, destination_x + corner_width, destination_x + destination_width - corner_width };
        const destination_widths = [3]f32{ corner_width, destination_width - corner_width * 2, corner_width };
        const destination_rows = [3]f32{ destination_y, destination_y + corner_height, destination_y + destination_height - corner_height };
        const destination_heights = [3]f32{ corner_height, destination_height - corner_height * 2, corner_height };

        for (0..3) |row| {
            for (0..3) |column| {
                const source = rl.Rectangle{
                    .x = source_columns[column],
                    .y = source_rows[row],
                    .width = source_widths[column],
                    .height = source_heights[row],
                };
                const destination = rl.Rectangle{
                    .x = destination_columns[column],
                    .y = destination_rows[row],
                    .width = destination_widths[column],
                    .height = destination_heights[row],
                };
                rl.drawTexturePro(texture, source, destination, .{ .x = 0, .y = 0 }, 0, tint);
            }
        }
    }

    fn drawTextLabel(self: *RaylibBackend, label: ui.TextLabel) void {
        // raylib needs a null-terminated string; copy into the frame arena.
        // TODO: honor bold/italic and load a real TTF (default font is a small
        // bitmap that blurs when scaled up).
        const text = self.frame_arena.allocator().dupeZ(u8, label.text) catch return;
        const font_size: f32 = @floatFromInt(label.font_size);
        rl.drawTextEx(
            self.font,
            text,
            .{ .x = @floatFromInt(label.screen_position.x), .y = @floatFromInt(label.screen_position.y) },
            font_size,
            font_size / 10, // spacing (roughly one default-font pixel per glyph)
            toRaylibColor(label.color, 255),
        );
    }

    fn drawFillSprite(self: *RaylibBackend, fill: ui.FillSprite) void {
        const destination = referenceRectangle(fill.screen_position, fill.width, fill.height);
        // Background (e.g. depleted health) drawn whole.
        self.drawSprite(fill.background_sprite_id, destination, null, fill.background_color);

        const texture = self.getTexture(fill.fill_sprite_id) orelse return;
        const fraction = std.math.clamp(fill.fill_fraction, 0, 1);
        const texture_width: f32 = @floatFromInt(texture.width);
        const texture_height: f32 = @floatFromInt(texture.height);

        var source = rl.Rectangle{ .x = 0, .y = 0, .width = texture_width, .height = texture_height };
        var filled = destination;
        // Keep the portion in the direction the fill grows toward: `.up` keeps
        // the bottom slice (a globe filling upward), etc.
        switch (fill.fill_direction) {
            .up => {
                const remainder = 1 - fraction;
                source.y = texture_height * remainder;
                source.height = texture_height * fraction;
                filled.y += destination.height * remainder;
                filled.height = destination.height * fraction;
            },
            .down => {
                source.height = texture_height * fraction;
                filled.height = destination.height * fraction;
            },
            .left => {
                const remainder = 1 - fraction;
                source.x = texture_width * remainder;
                source.width = texture_width * fraction;
                filled.x += destination.width * remainder;
                filled.width = destination.width * fraction;
            },
            .right => {
                source.width = texture_width * fraction;
                filled.width = destination.width * fraction;
            },
        }
        rl.drawTexturePro(texture, source, filled, .{ .x = 0, .y = 0 }, 0, toRaylibColor(fill.fill_color, 255));
    }

    /// Load a texture for `sprite_id` (assets/<id>.png), caching the result.
    /// Returns null (and caches the miss) if the asset can't be loaded.
    fn getTexture(self: *RaylibBackend, sprite_id: []const u8) ?rl.Texture2D {
        if (self.texture_cache.get(sprite_id)) |cached| return cached;

        const path = std.fmt.allocPrintSentinel(
            self.frame_arena.allocator(),
            "assets/{s}.png",
            .{sprite_id},
            0,
        ) catch @panic("failed to build asset path");

        const key = self.allocator.dupe(u8, sprite_id) catch @panic("failed to dupe sprite id");
        const loaded: ?rl.Texture2D = rl.loadTexture(path) catch null;
        self.texture_cache.put(self.allocator, key, loaded) catch @panic("failed to cache texture");
        return loaded;
    }
};

fn toRaylibColor(color: types.Color, alpha: u8) rl.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha };
}

fn referenceRectangle(screen_position: types.ScreenPosition, width: i32, height: i32) rl.Rectangle {
    return .{
        .x = @floatFromInt(screen_position.x),
        .y = @floatFromInt(screen_position.y),
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    };
}
