//! raylib platform backend. This is the ONLY file that imports raylib
//! directly (native.zig and web.zig import it through the backend). It is
//! compiled into both the native exe and the wasm32-emscripten exe. The shared
//! game logic in main.zig never touches raylib; gameLoop drives this backend
//! through a small duck-typed interface:
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
//! drawn. render() draws the background, the world drawables (tiles,
//! decorations, entities, markers), and the flat UI element list.

const std = @import("std");
const rl = @import("raylib");
const input = @import("input.zig");
const types = @import("types.zig");
const ui = @import("ui.zig");

const reference_width_int: i32 = types.reference_width;
const reference_height_int: i32 = types.reference_height;
const reference_width: f32 = @floatFromInt(reference_width_int);
const reference_height: f32 = @floatFromInt(reference_height_int);

/// Base rasterization size for the TTF font. raylib bakes glyphs into an
/// atlas at this fixed size; `drawTextEx` scales from it. Sized to cover the
/// largest `font_size` in use (96, menu buttons) with a modest supersample,
/// so all current sizes render crisp; the atlas texture is bilinear-filtered
/// so downscaling to smaller sizes stays smooth. This is a runtime GPU/texture
/// memory cost, not binary size (only the raw ~12 KB TTF bytes are embedded).
const font_base_size: i32 = 128;

/// Edge-highlight outline thickness in source pixels (inner band hugging the
/// sprite silhouette). Drawn via a precomputed outline mask (see
/// `getOutlineTexture`). Tune from in-game viewing.
const outline_thickness: i32 = 8;

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
    // Action keys bound in data/default_settings.txt.
    .{ .key = .z, .id = "KeyZ" },
    .{ .key = .y, .id = "KeyY" },
    .{ .key = .i, .id = "KeyI" },
    .{ .key = .o, .id = "KeyO" },
    .{ .key = .g, .id = "KeyG" },
    .{ .key = .s, .id = "KeyS" },
    .{ .key = .m, .id = "KeyM" },
    .{ .key = .l, .id = "KeyL" },
    .{ .key = .escape, .id = "Escape" },
    .{ .key = .enter, .id = "Enter" },
    .{ .key = .backspace, .id = "Backspace" },
    .{ .key = .space, .id = "Space" },
    .{ .key = .one, .id = "Digit1" },
    .{ .key = .zero, .id = "Digit0" },
    .{ .key = .two, .id = "Digit2" },
    .{ .key = .three, .id = "Digit3" },
    .{ .key = .four, .id = "Digit4" },
    .{ .key = .five, .id = "Digit5" },
    .{ .key = .six, .id = "Digit6" },
    .{ .key = .seven, .id = "Digit7" },
    .{ .key = .eight, .id = "Digit8" },
    .{ .key = .up, .id = "ArrowUp" },
    .{ .key = .down, .id = "ArrowDown" },
    .{ .key = .left, .id = "ArrowLeft" },
    .{ .key = .right, .id = "ArrowRight" },
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

/// Upper bound on events emitted in a single frame. Each mapped key/button
/// contributes at most ONE event per frame (down or up — never both, the
/// pollInput loop uses `else if`), so `key_mappings.len + mouse_mappings.len`
/// bounds the edge events. The non-edge events (always-one mouse-move, the
/// mouse-scroll wheel delta) add `non_edge_events_per_frame`. Adding a new
/// mapping array (gamepad, touch) only needs to be added to the sum below;
/// adding a new non-edge event source bumps `non_edge_events_per_frame`.
/// No manual bumping on per-source changes — the formula tracks the counts.
const non_edge_events_per_frame: usize = 2; // mouse-move + mouse-scroll
const max_events_per_frame = key_mappings.len + mouse_mappings.len + non_edge_events_per_frame;

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

/// Load the game font. Reads the embedded TTF (`assets/fonts/freezilla.ttf`)
/// through the FileSource and rasterizes a glyph atlas at `font_base_size`.
/// On any failure (missing file, decode error) falls back to raylib's default
/// bitmap font so the game stays playable — the recoverable-error policy
/// applies because a persistent-dir shadow (`~/.ziglop/assets/fonts/...`)
/// can break the read at runtime. Returns the font + whether it is the
/// default (so deinit can skip unloading raylib-owned the default).
fn loadFont(file_source: *const @import("file_source.zig").FileSource) struct { font: rl.Font, is_default: bool } {
    const bytes = file_source.readFile(std.heap.page_allocator, "assets/fonts/freezilla.ttf") catch |err| {
        std.debug.print("warning: failed to load font ({}); falling back to default\n", .{err});
        const fallback = rl.getFontDefault() catch @panic("failed to load default font");
        return .{ .font = fallback, .is_default = true };
    };
    defer std.heap.page_allocator.free(bytes);

    const font = rl.loadFontFromMemory(".ttf", bytes, font_base_size, null) catch {
        std.debug.print("warning: failed to decode font; falling back to default\n", .{});
        const fallback = rl.getFontDefault() catch @panic("failed to load default font");
        return .{ .font = fallback, .is_default = true };
    };
    // Bilinear so downscaling from the base size to smaller `font_size`s is
    // smooth (matches the reference->window blit). Upcasting would blur, but
    // no size in use exceeds `font_base_size`.
    rl.setTextureFilter(font.texture, .bilinear);
    return .{ .font = font, .is_default = false };
}

pub const RaylibBackend = struct {
    allocator: std.mem.Allocator,
    /// sprite_id -> loaded texture. A cached `null` means "known missing" so a
    /// failed load is not retried (and spammed) every frame. Keys are duped
    /// into `allocator`; the loaded textures live until deinit.
    texture_cache: std.StringHashMapUnmanaged(?rl.Texture2D) = .empty,
    /// sprite_id -> precomputed edge-outline mask texture (white opaque halo
    /// sitting just outside the silhouette). Generated lazily by
    /// `ensureOutlineLoaded` on the first `getOutlineTexture` request, so
    /// only sprites that actually get outlined pay the cost (the tile cursor
    /// + highlighted UI icons). A cached `null` means the sprite is missing
    /// (or the mask failed) -> callers skip the outline.
    outline_cache: std.StringHashMapUnmanaged(?rl.Texture2D) = .empty,
    /// Reference-resolution offscreen target; blitted to the window each frame.
    render_target: rl.RenderTexture2D,
    /// Text-label font. Normally the embedded TTF (loaded from
    /// `assets/fonts/freezilla.ttf` via the FileSource); falls back to
    /// raylib's default bitmap font if the TTF is missing or fails to load
    /// (e.g. a broken persistent-dir shadow). `font_is_default` tracks the
    /// fallback so deinit skips unloading raylib-owned the default.
    font: rl.Font,
    font_is_default: bool,
    /// Transient per-frame allocations (null-terminated strings for raylib,
    /// asset paths). Reset at the start of every render.
    frame_arena: std.heap.ArenaAllocator,
    /// Scratch for the events emitted by pollInput each frame. Valid only until
    /// the next pollInput; translateInput consumes it synchronously.
    event_buffer: [max_events_per_frame]input.PlatformInputEvent = undefined,
    /// Unified file source for asset bytes (embedded map / persistent dir).
    /// The texture cache loads via loadImageFromMemory from this instead of
    /// touching the filesystem directly — see AGENTS.md "File System & IO".
    file_source: *const @import("file_source.zig").FileSource,

    /// Last real-clock sample (microseconds) for delta computation. Updated
    /// each deltaMicroseconds() call. Real-clock based (rl.getTime), not
    /// frame-rate based, so waits and gameplay logic are independent of the
    /// render framerate.
    last_time_microseconds: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        width: i32,
        height: i32,
        title: [:0]const u8,
        file_source: *const @import("file_source.zig").FileSource,
    ) RaylibBackend {
        // Vsync defaults on (matching Settings.vsync default); run() calls
        // applyVsync after loading settings to sync the window to the setting.
        rl.setConfigFlags(.{ .window_resizable = true, .vsync_hint = true });
        rl.initWindow(width, height, title);
        rl.setExitKey(.null); // Escape is a game binding (options menu), not quit.

        const render_target = rl.loadRenderTexture(reference_width_int, reference_height_int) catch
            @panic("failed to create reference-resolution render target");
        // Smooth the universal reference(4K) -> window blit. raylib defaults
        // textures to point (nearest-neighbor) filtering, which on the
        // downscale turns smooth alpha edges into jagged chunky boundaries
        // (every content layer passes through this blit). Bilinear fixes the
        // transparent-edge artifact at no per-frame cost.
        rl.setTextureFilter(render_target.texture, .bilinear);
        const font = loadFont(file_source);

        return .{
            .allocator = allocator,
            .render_target = render_target,
            .font = font.font,
            .font_is_default = font.is_default,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .last_time_microseconds = @intFromFloat(rl.getTime() * std.time.us_per_s),
            .file_source = file_source,
        };
    }

    pub fn deinit(self: *RaylibBackend) void {
        var textures = self.texture_cache.valueIterator();
        while (textures.next()) |maybe_texture| {
            if (maybe_texture.*) |texture| rl.unloadTexture(texture);
        }
        self.texture_cache.deinit(self.allocator);
        var outlines = self.outline_cache.valueIterator();
        while (outlines.next()) |maybe_texture| {
            if (maybe_texture.*) |texture| rl.unloadTexture(texture);
        }
        self.outline_cache.deinit(self.allocator);
        if (!self.font_is_default) rl.unloadFont(self.font);
        self.frame_arena.deinit();
        rl.unloadRenderTexture(self.render_target);
        rl.closeWindow();
    }

    /// Apply the vsync setting at runtime (toggles the vsync window state
    /// flag). Called after settings load, since setConfigFlags must run before
    /// initWindow — init defaults to vsync-on (matching the Settings default),
    /// and this syncs the window to the loaded setting.
    pub fn applyVsync(_: *RaylibBackend, vsync: bool) void {
        if (vsync) {
            rl.setWindowState(.{ .vsync_hint = true });
        } else {
            rl.clearWindowState(.{ .vsync_hint = true });
        }
    }

    /// Extract per-glyph advance widths from the loaded font into a
    /// raylib-free `ui.FontMetrics` value, so the layout seam (`view()` +
    /// UI builders) measures text with the same advances the renderer draws
    /// with. ASCII codepoints 32..126 index `font.glyphs`; missing glyphs
    /// keep the zero-init advance (the 0.5em fallback handles them in
    /// `measureSpanWidth`). Uniform for the TTF and the default-font
    /// fallback, so layout matches whichever font is active.
    pub fn fontMetrics(self: *RaylibBackend) ui.FontMetrics {
        var metrics = ui.FontMetrics{
            .base_size = @intCast(self.font.baseSize),
            .advances = [_]i32{0} ** 95,
        };
        const count: usize = @intCast(self.font.glyphCount);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const glyph = self.font.glyphs[i];
            const value: i32 = @intCast(glyph.value);
            if (value >= 32 and value <= 126) {
                metrics.advances[@intCast(value - 32)] = @intCast(glyph.advanceX);
            }
        }
        return metrics;
    }

    pub fn shouldClose(_: *RaylibBackend) bool {
        return rl.windowShouldClose();
    }

    pub fn deltaMicroseconds(self: *RaylibBackend) u64 {
        const now_us: u64 = @intFromFloat(rl.getTime() * std.time.us_per_s);
        const delta = now_us - self.last_time_microseconds;
        self.last_time_microseconds = now_us;
        return delta;
    }

    /// Current real-clock time in microseconds (rl.getTime based). Used by the
    /// game loop's render gate to pace renders independent of the logic loop.
    pub fn realClockMicroseconds(_: *RaylibBackend) u64 {
        return @intFromFloat(rl.getTime() * std.time.us_per_s);
    }

    /// The render frame interval in microseconds, derived from settings. When
    /// vsync is on, paces to the current monitor's refresh rate (queried each
    /// call so a monitor swap is picked up); the render_fps_cap setting is
    /// ignored. When vsync is off and cap > 0, paces to 1/cap. When vsync is
    /// off and cap is 0, returns 0 (render every iteration — uncapped).
    ///
    /// On web (emscripten), the browser's requestAnimationFrame IS the vsync
    /// pacer — getCurrentMonitor/getMonitorRefreshRate aren't implemented and
    /// spam warnings. So on web with vsync on, return 0 (render every rAF
    /// call); the browser already paces to the display refresh.
    pub fn renderIntervalMicroseconds(
        _: *RaylibBackend,
        settings: @import("types.zig").Settings,
    ) u64 {
        if (@import("builtin").os.tag == .emscripten) {
            // The browser paces rAF to the display refresh; render every call.
            if (settings.vsync) return 0;
            if (settings.render_fps_cap == 0) return 0;
            return @as(u64, std.time.us_per_s) / settings.render_fps_cap;
        }
        if (settings.vsync) {
            const monitor = rl.getCurrentMonitor();
            const refresh_hz = rl.getMonitorRefreshRate(monitor);
            if (refresh_hz <= 0) return std.time.us_per_s / 60; // sane fallback
            return @as(u64, std.time.us_per_s) / @as(u64, @intCast(refresh_hz));
        }
        if (settings.render_fps_cap == 0) return 0;
        return @as(u64, std.time.us_per_s) / settings.render_fps_cap;
    }

    /// Sleep for the given number of seconds (raylib waitTime). Used by the
    /// game loop to yield briefly when idle (stack empty, no wait) so the loop
    /// doesn't busy-spin at 100% CPU while waiting for player input.
    pub fn waitTime(_: *RaylibBackend, seconds: f64) void {
        rl.waitTime(seconds);
    }

    pub fn pollInput(self: *RaylibBackend) input.PlatformInput {
        // Read input edges and position FIRST, before pumping.
        //
        // Why this order: raylib's PollInputEvents() copies previous = current
        // (advancing the "previous" snapshot). IsMouseButtonPressed /
        // IsKeyPressed check current vs previous. On native, PollInputEvents
        // copies THEN calls glfwPollEvents() (which fires callbacks that update
        // current) — so pumping-then-reading works (the copy sees the old
        // state, game code sees the new state). But on web, events arrive
        // asynchronously via JS callbacks BETWEEN frames (current is already
        // set when we arrive). Pumping first would copy previous = current,
        // erasing the edge (current == previous → no press detected). Reading
        // first, then pumping, works on BOTH platforms: web sees current (from
        // JS callbacks) vs previous (from last frame's copy); native sees
        // current (from last iteration's glfwPollEvents) vs previous (from
        // last iteration's copy), with ~1 iteration of latency at the uncapped
        // loop speed (negligible).
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

        // Mouse wheel: accumulated scroll delta since last frame (positive =
        // scroll up = zoom in). Not an edge — raylib accumulates it internally
        // and resets on pollInputEvents — so reading before the pump is fine
        // (same as the mouse position read above).
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) {
            self.event_buffer[count] = .{ .mouse_scroll = wheel };
            count += 1;
        }

        // Pump the OS event queue AFTER reading edges. On native this calls
        // glfwPollEvents() (fires callbacks that update current for the next
        // iteration) + copies previous = current. On web it just copies
        // previous = current (events are async). Without this call on native,
        // the window would hang between renders (OS events not processed).
        rl.pollInputEvents();

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
        for (view_state.tile_overlays) |overlay| self.drawTileOverlay(overlay, view_state.world_scale);
        for (view_state.ground_drawables) |ground| self.drawGroundDrawable(ground, view_state.world_scale);
        for (view_state.ui_elements) |element| self.drawUiElement(element, view_state.active_color_theme.lightest);
        rl.endTextureMode();

        // Blit the target to the window, letterboxed. RenderTextures are stored
        // y-flipped, so the source height is negated.
        rl.beginDrawing();
        // With SUPPORT_CUSTOM_FRAME_CONTROL, endDrawing() only flushes the
        // render batch — we swap the buffer ourselves (vsync paces here).
        defer {
            rl.endDrawing();
            rl.swapScreenBuffer();
        }
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
    fn drawTileOverlay(self: *RaylibBackend, overlay: types.TileOverlayDrawable, world_scale: f32) void {
        const tile_size = input.tile_size_pixels * world_scale;
        const rectangle = rl.Rectangle{
            .x = @floatFromInt(overlay.screen_position.x),
            .y = @floatFromInt(overlay.screen_position.y),
            .width = tile_size,
            .height = tile_size,
        };
        switch (overlay.overlay_type) {
            .highlight => rl.drawRectangleRec(rectangle, toRaylibColor(overlay.color, 90)),
            .cursor => {
                // Outline hugging the tile graphic's silhouette instead of
                // a plain rectangle: draw the precomputed edge mask of
                // world/tile tinted with the cursor color. Falls back to
                // rectangle lines if the mask is unavailable.
                if (self.getOutlineTexture("world/tile")) |mask| {
                    const source = rl.Rectangle{
                        .x = 0,
                        .y = 0,
                        .width = @floatFromInt(mask.width),
                        .height = @floatFromInt(mask.height),
                    };
                    rl.drawTexturePro(mask, source, rectangle, .{ .x = 0, .y = 0 }, 0, toRaylibColor(overlay.color, 255));
                } else {
                    rl.drawRectangleLinesEx(rectangle, 6 * world_scale, toRaylibColor(overlay.color, 255));
                }
            },
            .range_outline, .radius_outline, .aggro_outline => {
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
                for (entity.layer_sprites) |sprite| self.drawSpriteDrawable(sprite, world_scale);
                for (entity.weapon_sprites) |maybe_sprite| {
                    if (maybe_sprite) |sprite| self.drawSpriteDrawable(sprite, world_scale);
                }
                for (entity.gear_sprites) |sprite| self.drawSpriteDrawable(sprite, world_scale);
                for (entity.front_effect_sprites) |sprite| self.drawSpriteDrawable(sprite, world_scale);
                // health_bar is not rendered (the field is currently null).
            },
            .decoration_piece => |decoration| {
                self.drawSpriteDrawable(.{
                    .sprite_id = decoration.sprite_id,
                    .screen_position = decoration.screen_position,
                    .draw_offset = decoration.draw_offset,
                    .source_rectangle = decoration.source_rectangle,
                    .color = decoration.color,
                }, world_scale);
                // Overlay layers: same position + source rect, different
                // sprite + color, drawn in slice order (base first).
                for (decoration.layers) |layer| {
                    self.drawSpriteDrawable(layer, world_scale);
                }
            },
            .ground_items => |items| self.drawWorldSprite(items.sprite_id, items.screen_position, world_scale, items.color),
            .level_end => |marker| {
                self.drawWorldSprite(marker.sprite_id, marker.screen_position, world_scale, marker.color);
                // Animated banner over the pole: same screen position + pivot,
                // each banner frame is 256x512 (identical to the pole). Drawn
                // via drawSpriteDrawable so the source rectangle + world_scale
                // apply. See AGENTS → Animation.
                if (marker.banner_source_rectangle) |banner_rect| {
                    self.drawSpriteDrawable(.{
                        .sprite_id = "world/flag",
                        .screen_position = marker.screen_position,
                        .draw_offset = .{ .x = 0, .y = 0 },
                        .source_rectangle = banner_rect,
                        .color = marker.banner_color,
                    }, world_scale);
                }
            },
        }
    }

    // -- UI element drawing --

    fn drawUiElement(self: *RaylibBackend, element: ui.UiElement, highlight_color: types.Color) void {
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
                    const dest = referenceRectangle(button.screen_position, button.width, button.height);
                    self.drawSprite(sprite_id, dest, null, button.color);
                    if (button.highlighted) self.drawHighlightOutline(sprite_id, dest, highlight_color);
                }
            },
            .text_label => |label| self.drawTextLabel(label),
            .fill_sprite => |fill| self.drawFillSprite(fill),
            .image => |image| {
                const dest = referenceRectangle(image.screen_position, image.width, image.height);
                self.drawSprite(image.sprite_id, dest, null, image.color);
                if (image.highlighted) self.drawHighlightOutline(image.sprite_id, dest, highlight_color);
            },
            .solid_rect => |rect| rl.drawRectangleRec(referenceRectangle(rect.screen_position, rect.width, rect.height), toRaylibColor(rect.color, 255)),
        }
    }

    /// Draw a precomputed edge-outline mask over `destination`, tinted with
    /// `highlight_color`. Used by highlighted UI elements (Button/Image) to
    /// ring the sprite silhouette. No-op if the sprite or its mask is
    /// unavailable.
    fn drawHighlightOutline(self: *RaylibBackend, sprite_id: []const u8, destination: rl.Rectangle, highlight_color: types.Color) void {
        const mask = self.getOutlineTexture(sprite_id) orelse return;
        const source = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(mask.width),
            .height = @floatFromInt(mask.height),
        };
        rl.drawTexturePro(mask, source, destination, .{ .x = 0, .y = 0 }, 0, toRaylibColor(highlight_color, 255));
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
    /// the edges + center are stretched to fill the remaining area.
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
        // bold/italic are still ignored (no bold/italic faces loaded).
        const text = self.frame_arena.allocator().dupeZ(u8, label.text) catch return;
        const font_size: f32 = @floatFromInt(label.font_size);
        const spacing: f32 = font_size / @as(f32, @floatFromInt(ui.glyph_spacing_font_divisor));
        rl.drawTextEx(
            self.font,
            text,
            .{ .x = @floatFromInt(label.screen_position.x), .y = @floatFromInt(label.screen_position.y) },
            font_size,
            spacing, // per-glyph spacing shared with FontMetrics measure
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
    /// Reads bytes through the FileSource (embedded map / persistent-dir
    /// override) and decodes via loadImageFromMemory, so the backend never
    /// touches the filesystem directly. Returns null (and caches the miss) if
    /// the asset can't be loaded. The outline mask is NOT built here — it is
    /// generated lazily by `ensureOutlineLoaded` only for sprites that
    /// actually get outlined, so loading a level pays no outline cost.
    fn getTexture(self: *RaylibBackend, sprite_id: []const u8) ?rl.Texture2D {
        if (!self.texture_cache.contains(sprite_id)) self.ensureSpriteLoaded(sprite_id);
        return self.texture_cache.get(sprite_id).?;
    }

    /// The precomputed edge-outline mask for `sprite_id` (a white opaque halo
    /// sitting just outside the silhouette). Lazily generated on first
    /// request via `ensureOutlineLoaded`, so only sprites that actually get
    /// outlined pay the cost (`world/tile` for the cursor, highlighted UI
    /// icons). null if the sprite is missing or the mask could not be built.
    fn getOutlineTexture(self: *RaylibBackend, sprite_id: []const u8) ?rl.Texture2D {
        if (!self.outline_cache.contains(sprite_id)) self.ensureOutlineLoaded(sprite_id);
        return self.outline_cache.get(sprite_id).?;
    }

    /// Load `sprite_id` from the file source, decode, and cache the main
    /// texture only (the outline mask is generated lazily by
    /// `ensureOutlineLoaded`). A missing/unreadable asset is a normal
    /// in-progress state -> cache null and fall through to the magenta
    /// fallback at draw sites. Idempotent: presence in `texture_cache` marks
    /// the load attempted.
    fn ensureSpriteLoaded(self: *RaylibBackend, sprite_id: []const u8) void {
        if (self.texture_cache.contains(sprite_id)) return;

        const path = std.fmt.allocPrintSentinel(
            self.frame_arena.allocator(),
            "assets/{s}.png",
            .{sprite_id},
            0,
        ) catch @panic("failed to build asset path");

        const key = self.allocator.dupe(u8, sprite_id) catch @panic("failed to dupe sprite id");

        const texture: ?rl.Texture2D = blk: {
            const bytes = self.file_source.readFile(self.allocator, path) catch
                break :blk null;
            defer self.allocator.free(bytes);
            const image = rl.loadImageFromMemory(".png", bytes) catch break :blk null;
            defer rl.unloadImage(image);
            break :blk rl.loadTextureFromImage(image) catch null;
        };

        self.texture_cache.put(self.allocator, key, texture) catch @panic("failed to cache texture");
    }

    /// Build and cache the edge-outline mask for `sprite_id`. Re-reads the
    /// asset bytes and decodes — outlines are requested for few sprites
    /// (`world/tile` + a handful of UI icons), so a second read per outlined
    /// sprite is far cheaper than holding decoded images for every sprite.
    /// Caches null on miss/failure. Idempotent via `outline_cache` presence.
    fn ensureOutlineLoaded(self: *RaylibBackend, sprite_id: []const u8) void {
        if (self.outline_cache.contains(sprite_id)) return;

        const path = std.fmt.allocPrintSentinel(
            self.frame_arena.allocator(),
            "assets/{s}.png",
            .{sprite_id},
            0,
        ) catch @panic("failed to build asset path");

        const key = self.allocator.dupe(u8, sprite_id) catch @panic("failed to dupe sprite id");

        const outline: ?rl.Texture2D = blk: {
            const bytes = self.file_source.readFile(self.allocator, path) catch
                break :blk null;
            defer self.allocator.free(bytes);
            var image = rl.loadImageFromMemory(".png", bytes) catch break :blk null;
            defer rl.unloadImage(image);
            // Normalize to RGBA so alpha is always at the same byte offset.
            image.setFormat(.uncompressed_r8g8b8a8);
            break :blk self.generateOutlineMask(image) catch null;
        };

        self.outline_cache.put(self.allocator, key, outline) catch @panic("failed to cache outline mask");
    }

    /// Build a white-opaque edge-outline mask as an OUTER band: transparent
    /// pixels within `outline_thickness` (Chebyshev) of an opaque pixel become
    /// white; opaque pixels stay transparent. The band sits just outside the
    /// silhouette, so the sprite's own art is never overpainted. Dilation by a
    /// square is separable: dilate horizontally, then vertically —
    /// O(w·h·(2t+1)) instead of O(w·h·(2t+1)²). The band is clipped at the
    /// canvas border (a sprite filling its canvas edge-to-edge gets no halo on
    /// that side); current art ships with enough margin that this never shows.
    fn generateOutlineMask(self: *RaylibBackend, image: rl.Image) !rl.Texture2D {
        const width: i32 = image.width;
        const height: i32 = image.height;
        const colors = try rl.loadImageColors(image);
        defer rl.unloadImageColors(colors);

        const pixel_count: usize = @intCast(width * height);
        // opaque_mask[i] = 1 if the source pixel is opaque, else 0.
        const opaque_mask = try self.allocator.alloc(u8, pixel_count);
        defer self.allocator.free(opaque_mask);
        for (colors, 0..) |c, i| opaque_mask[i] = if (c.a > 16) 1 else 0;

        // Horizontal dilation: opaque_h_mask[i] = 1 if any opaque pixel is within
        // `t` columns (same row), else 0.
        const opaque_h_mask = try self.allocator.alloc(u8, pixel_count);
        defer self.allocator.free(opaque_h_mask);
        const t = outline_thickness;
        var y: i32 = 0;
        while (y < height) : (y += 1) {
            const row_start: usize = @intCast(y * width);
            var x: i32 = 0;
            while (x < width) : (x += 1) {
                var hit: u8 = 0;
                var dx: i32 = -t;
                while (dx <= t) : (dx += 1) {
                    const nx = x + dx;
                    if (nx < 0 or nx >= width) continue;
                    if (opaque_mask[row_start + @as(usize, @intCast(nx))] == 1) {
                        hit = 1;
                        break;
                    }
                }
                opaque_h_mask[row_start + @as(usize, @intCast(x))] = hit;
            }
        }

        // Vertical dilation + band output: a pixel joins the band iff it is
        // transparent but some horizontally-dilated pixel is within `t` rows
        // (same column). Written straight into the RGBA upload buffer.
        const buf = try self.allocator.alloc(u8, pixel_count * 4);
        defer self.allocator.free(buf);
        @memset(buf, 0);
        y = 0;
        while (y < height) : (y += 1) {
            const row_start: usize = @intCast(y * width);
            var x: i32 = 0;
            while (x < width) : (x += 1) {
                const i: usize = row_start + @as(usize, @intCast(x));
                if (opaque_mask[i] == 1) continue; // opaque -> keep transparent
                var hit = false;
                var dy: i32 = -t;
                while (dy <= t) : (dy += 1) {
                    const ny = y + dy;
                    if (ny < 0 or ny >= height) continue;
                    if (opaque_h_mask[@as(usize, @intCast(ny)) * @as(usize, @intCast(width)) + @as(usize, @intCast(x))] == 1) {
                        hit = true;
                        break;
                    }
                }
                if (hit) {
                    buf[i * 4 + 0] = 255;
                    buf[i * 4 + 1] = 255;
                    buf[i * 4 + 2] = 255;
                    buf[i * 4 + 3] = 255;
                }
            }
        }

        const mask_image = rl.Image{
            .data = @ptrCast(buf.ptr),
            .width = width,
            .height = height,
            .mipmaps = 1,
            .format = .uncompressed_r8g8b8a8,
        };
        return rl.loadTextureFromImage(mask_image) catch error.LoadTexture;
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
