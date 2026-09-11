//! raylib platform backend. `src/raylib/` is the ONLY directory whose files
//! import raylib directly (native.zig and web.zig import it through
//! `raylib/backend.zig`); every file in it is excluded from the headless
//! test-root scan in build.zig (see DESIGN → Platform Seam). This file is
//! compiled into both the native exe and the wasm32-emscripten exe. The shared
//! game logic in main.zig never touches raylib; gameLoop drives this backend
//! through a small duck-typed interface:
//!   shouldClose() bool
//!   deltaMicroseconds() u64
//!   pollInput() input.PlatformInput
//!   render(view_state, viewport) void
//!
//! Rendering model: all UI/world content is authored in a fixed reference
//! (design) resolution (types.reference_width x types.reference_height = 4K).
//! We draw it into a RenderTexture at a SEPARATE, possibly smaller render
//! target resolution (the `render_resolution` setting — 720p…2160p presets,
//! default 1080p, applied live via `applyRenderResolution`)
//! via a `beginMode2D` camera zoom that scales 4K-space content down, then
//! blit the target to the window letterboxed (aspect-preserving, centered).
//! Input maps the pointer back through the inverse of the reference→window
//! letterbox transform (independent of the render target size — the game
//! thinks in 4K design space), so clicks line up with what is drawn. Decoupling
//! the render target from the design space lets us cut fill rate (the dominant
//! cost on fill-rate-limited GPUs) without touching layout/view math. See
//! DESIGN → Platform Seam → Render target resolution. render() draws the
//! background, the world drawables (tiles, decorations, entities, markers),
//! and the flat UI element list.

const std = @import("std");
const rl = @import("raylib");
const input = @import("../input.zig");
const types = @import("../types.zig");
const ui = @import("../ui.zig");
const transient_allocator = @import("../transient_allocator.zig");
const input_poll = @import("input_poll.zig");
const audio_mod = @import("audio.zig");
const textures_mod = @import("textures.zig");
const text_mod = @import("text.zig");
const conversions = @import("conversions.zig");
const diagnostics_mod = @import("diagnostics.zig");

const reference_width_int: i32 = types.reference_width;
const reference_height_int: i32 = types.reference_height;
const reference_width: f32 = @floatFromInt(reference_width_int);
const reference_height: f32 = @floatFromInt(reference_height_int);

/// Text-field caret bar thickness (reference px) — matches the unified
/// outline thickness so the caret reads at the same visual weight as the
/// world outlines.
const caret_width: i32 = 8;


/// Maps reference-space content to the actual window: a uniform scale plus a
/// centering offset (the letterbox bars). `render` uses it to blit; `pollInput`
/// inverts it to bring the pointer back into reference space.
pub const ViewTransform = struct {
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

/// Like `viewTransform` but for the render-target → window blit (the
/// offscreen target is `render_width × render_height`, not the 4K reference).
/// The pointer transform (`viewTransform`) stays reference-based — the game
/// thinks in 4K design space — so these differ when the render target is
/// smaller than reference. They share the same aspect ratio (16:9, comptime-
/// checked over the presets in types.zig), so the on-screen content is
/// identical; only the intermediate pixel count changes. See DESIGN →
/// Platform Seam → Render target resolution.
fn blitTransform(target_width_int: i32, target_height_int: i32) ViewTransform {
    const target_width: f32 = @floatFromInt(target_width_int);
    const target_height: f32 = @floatFromInt(target_height_int);
    const window_width: f32 = @floatFromInt(rl.getScreenWidth());
    const window_height: f32 = @floatFromInt(rl.getScreenHeight());
    const scale = @min(window_width / target_width, window_height / target_height);
    return .{
        .scale = scale,
        .offset_x = (window_width - target_width * scale) / 2,
        .offset_y = (window_height - target_height * scale) / 2,
    };
}



pub const RaylibBackend = struct {
    allocator: std.mem.Allocator,
    /// The texture subsystem: the lazy sprite caches (main textures,
    /// outline masks, composite inset masks, sprite bounds) + mask
    /// generation (see textures.zig). Draw sites go through
    /// `textures.getTexture`/`getOutlineTexture`/`getCompositeInsetTexture`;
    /// the entity-bounds lookup wrapper is below.
    textures: textures_mod.TextureStore,
    /// Reference-resolution offscreen target; blitted to the window each frame.
    render_target: rl.RenderTexture2D,
    /// Current render target pixel dimensions (a `RenderResolution` preset,
    /// applied via `applyRenderResolution`). The struct fields (not comptime
    /// consts) so the `render_resolution` setting can change them at runtime.
    render_width: i32,
    render_height: i32,
    /// The text subsystem: the TTF font (premultiplied CPU atlas) + the
    /// SDF text-outline pipeline + text drawing (see text.zig).
    /// `fontMetrics` below is the thin wrapper main.zig drives.
    text: text_mod.TextRenderer,
    /// Transient per-frame allocations (null-terminated strings for raylib,
    /// asset paths). Reset at the start of every render.
    frame_arena: std.heap.ArenaAllocator,
    /// Scratch for the events emitted by pollInput each frame. Valid only until
    /// the next pollInput; translateInput consumes it synchronously.
    event_buffer: [input_poll.max_events_per_frame]input.PlatformInputEvent = undefined,
    /// Scratch for the UTF-8 text characters drained from the platform
    /// char queue each pollInput (see PlatformInput.text_characters). Same
    /// lifetime as `event_buffer`.
    char_buffer: [input_poll.char_buffer_size]u8 = undefined,
    /// Unified file source for asset bytes (embedded map / persistent dir).
    /// The texture cache loads via loadImageFromMemory from this instead of
    /// touching the filesystem directly — see DESIGN → File System & IO.
    file_source: *const @import("../file_source.zig").FileSource,

    /// The audio subsystem: the layered-cue sound caches + the ambient
    /// music intensity stack (see audio.zig + DESIGN → Audio). Thin
    /// wrappers below keep the duck-typed interface unchanged.
    audio: audio_mod.Audio,
    /// Dev diagnostics: the boot/probe/readback log (see diag.zig; dev-mode
    /// native builds only — call sites are comptime-gated by
    /// `diagnostics_mod.enabled`, so none of it is analyzed or linked otherwise).
    diagnostics: diagnostics_mod.Diagnostics,

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
        file_source: *const @import("../file_source.zig").FileSource,
    ) RaylibBackend {
        // Vsync defaults on (matching Settings.vsync default); run() calls
        // applyVsync after loading settings to sync the window to the setting.
        rl.setConfigFlags(.{ .window_resizable = true, .vsync_hint = true });
        // raylib defaults to LOG_INFO, printing every init/asset-load line;
        // gate at warning so the console only shows real problems.
        rl.setTraceLogLevel(.warning);
        rl.initWindow(width, height, title);
        rl.setExitKey(.null); // Escape is a game binding (options menu), not quit.

        // Create the render target at the DEFAULT preset (settings load after
        // init — the backend is passed into createSessionSetup). `run`'s
        // per-frame diff-and-apply (main.zig) recreates it at the user's
        // `render_resolution` on the first frame after settings load.
        const default_dims = types.default_render_resolution.pixelDimensions();
        const render_target = rl.loadRenderTexture(default_dims.width, default_dims.height) catch
            @panic("failed to create render target");
        // Smooth the universal reference(4K) -> window blit. raylib defaults
        // textures to point (nearest-neighbor) filtering, which on the
        // downscale turns smooth alpha edges into jagged chunky boundaries
        // (every content layer passes through this blit). Bilinear fixes the
        // transparent-edge artifact at no per-frame cost.
        rl.setTextureFilter(render_target.texture, .bilinear);

        return .{
            .allocator = allocator,
            .render_target = render_target,
            .render_width = default_dims.width,
            .render_height = default_dims.height,
            .text = text_mod.TextRenderer.init(allocator, file_source),
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .textures = .{ .allocator = allocator, .file_source = file_source },
            .audio = .{ .allocator = allocator, .file_source = file_source },
            .diagnostics = .{ .allocator = allocator, .file_source = file_source },
            .last_time_microseconds = @intFromFloat(rl.getTime() * std.time.us_per_s),
            .file_source = file_source,
        };
    }

    pub fn deinit(self: *RaylibBackend) void {
        self.textures.deinit();
        self.audio.deinit();
        self.text.deinit();
        self.frame_arena.deinit();
        if (diagnostics_mod.enabled) self.diagnostics.deinit();
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

    /// Recreate the render target at a new resolution preset. Creates the NEW
    /// target first and only unloads the old one on success, so a failed apply
    /// (GPU/texture-size limits — `loadRenderTexture` returns an error) leaves
    /// the session rendering at the current preset, untouched. Returns false
    /// on failure; the caller (main.zig's diff-and-apply) reverts the setting
    /// + surfaces the popup. See DESIGN → Platform Seam → Render target
    /// resolution.
    pub fn applyRenderResolution(self: *RaylibBackend, resolution: types.RenderResolution) bool {
        const dims = resolution.pixelDimensions();
        if (dims.width == self.render_width and dims.height == self.render_height) return true;
        const new_target = rl.loadRenderTexture(dims.width, dims.height) catch return false;
        // Bilinear smoothing on the target→window blit — same reasoning as
        // init (point filtering turns smooth alpha edges into chunky
        // boundaries on the downscale).
        rl.setTextureFilter(new_target.texture, .bilinear);
        rl.unloadRenderTexture(self.render_target);
        self.render_target = new_target;
        self.render_width = dims.width;
        self.render_height = dims.height;
        return true;
    }

    /// The uniform camera zoom scaling 4K design-space draws into the render
    /// target (`render_width / reference_width`).
    fn renderScale(self: *const RaylibBackend) f32 {
        return @as(f32, @floatFromInt(self.render_width)) / reference_width;
    }

    /// Open the audio device and load all sfx + the music streams (the
    /// Audio subsystem — see audio.zig). Called once after construction
    /// (settings are available). Idempotent: a second call when already
    /// ready no-ops. If the audio device can't open, audio stays silent —
    /// the game runs, never crashes. See DESIGN → Audio.
    pub fn initAudio(self: *RaylibBackend, settings: types.Settings) void {
        self.audio.init(settings, audioDiagnosticsSink, self);
    }

    /// Play the drained sound cues at the sfx/master settings volume (the
    /// Audio subsystem — see audio.zig). No-op when audio isn't ready.
    pub fn playSounds(self: *RaylibBackend, sounds: []const types.SoundCue, settings: types.Settings) void {
        self.audio.playSounds(sounds, settings);
    }

    /// Advance the music streams + drive the intensity-layer volumes from
    /// the frame's active-enemy projection (the Audio subsystem — see
    /// audio.zig). No-op when audio isn't ready.
    pub fn updateMusic(
        self: *RaylibBackend,
        active_enemy_count: u32,
        delta_microseconds: u64,
        settings: types.Settings,
    ) void {
        self.audio.updateMusic(active_enemy_count, delta_microseconds, settings);
    }

    /// Extract per-glyph advance widths from the loaded font into a
    /// raylib-free `ui.FontMetrics` value (the text subsystem — see
    /// text.zig); the layout seam (`view()` + UI builders) measures text
    /// with the same advances the renderer draws with.
    pub fn fontMetrics(self: *RaylibBackend) ui.FontMetrics {
        return self.text.fontMetrics();
    }

    /// Look up an ENTITY sprite's opaque-pixel bounds by its bare stem
    /// (e.g. `skeleton_1`) — the texture subsystem (see textures.zig).
    /// Used by `frame()` to build `RenderContext.sprite_bounds`.
    pub fn entitySpriteBounds(
        self: *RaylibBackend,
        allocator: std.mem.Allocator,
        bare_stem: []const u8,
    ) ?types.SpriteBounds {
        return self.textures.entitySpriteBounds(allocator, bare_stem);
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
        settings: @import("../types.zig").Settings,
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
        return input_poll.poll(viewTransform(), &self.event_buffer, &self.char_buffer);
    }

    pub fn render(
        self: *RaylibBackend,
        view_state: types.ViewState,
        viewport: input.ViewportSize,
    ) void {
        _ = viewport;
        _ = self.frame_arena.reset(.retain_capacity);
        if (diagnostics_mod.enabled and !self.diagnostics.boot_logged) self.diagnostics.logBoot(self.render_width, self.render_height);

        // Draw all reference-space content into the offscreen target. The
        // target may be smaller than the 4K reference (the render_resolution
        // setting, default 1080p); a `beginMode2D` camera zoom scales every
        // draw call down so layout math stays in 4K design space while fill
        // happens at the target resolution. clearBackground is NOT
        // camera-affected, so it runs before the camera block and clears the
        // full target. See DESIGN → Platform Seam → Render target resolution.
        rl.beginTextureMode(self.render_target);
        rl.clearBackground(toRaylibColor(view_state.background_color, 255));
        // Premultiplied alpha blending for the compositing pass: every
        // composited texture (sprites, font atlas) is premultiplied at load,
        // so BLEND_ALPHA_PREMULTIPLY (ONE, ONE_MINUS_SRC_ALPHA) composites
        // them correctly AND lets bilinear downsampling blend in premult
        // space — killing the dark halo straight-alpha textures show at
        // transparent edges when downscaled. The SDF outline shader outputs
        // premultiplied too. Outline masks are binary (already premult).
        // See DESIGN → Platform Seam → Render target resolution.
        rl.beginBlendMode(.alpha_premultiply);
        rl.beginMode2D(.{ .offset = .{ .x = 0, .y = 0 }, .target = .{ .x = 0, .y = 0 }, .rotation = 0, .zoom = self.renderScale() });
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
        for (view_state.occlusion_insets) |inset| self.drawOcclusionInset(inset, view_state.world_scale);
        for (view_state.world_overlays) |overlay| self.drawWorldOverlay(overlay, view_state.world_scale);
        const theme_darkest = view_state.active_color_theme.darkest;
        for (view_state.ui_elements) |element| self.drawUiElement(element, view_state.active_color_theme.lightest, theme_darkest);
        rl.endMode2D();
        rl.endBlendMode();
        rl.endTextureMode();
        if (diagnostics_mod.enabled and self.diagnostics.readback_pending) self.diagnostics.logTargetReadback(self.render_target, self.render_width, self.render_height, self.renderScale());

        // Blit the target to the window, letterboxed. RenderTextures are stored
        // y-flipped, so the source height is negated. The blit uses the RENDER
        // target dims (not the 4K reference) — the pointer transform
        // (`viewTransform`, window→4K) is independent and stays reference-
        // based.
        rl.beginDrawing();
        // With SUPPORT_CUSTOM_FRAME_CONTROL, endDrawing() only flushes the
        // render batch — we swap the buffer ourselves (vsync paces here).
        defer {
            rl.endDrawing();
            rl.swapScreenBuffer();
        }
        rl.clearBackground(rl.Color.black);
        const transform = blitTransform(self.render_width, self.render_height);
        const target_width: f32 = @floatFromInt(self.render_width);
        const target_height: f32 = @floatFromInt(self.render_height);
        const source = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = target_width,
            .height = -target_height,
        };
        const destination = rl.Rectangle{
            .x = transform.offset_x,
            .y = transform.offset_y,
            .width = target_width * transform.scale,
            .height = target_height * transform.scale,
        };
        rl.drawTexturePro(self.render_target.texture, source, destination, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
    }

    // -- World drawing --

    /// Draw a tile overlay as a primitive (no overlay art): a translucent fill
    /// for move-range highlights, an outline for the cursor / range outlines.
    /// The outline thickness is the shared mask thickness (8 source px, see
    /// textures.zig)
    /// × `world_scale`; range/radius/aggro outlines may span multiple tiles
    /// via `extent` (side in tiles, default 1).
    fn drawTileOverlay(self: *RaylibBackend, overlay: types.TileOverlayDrawable, world_scale: f32) void {
        const tile_size = input.tile_size_pixels * world_scale;
        const side: f32 = @as(f32, @floatFromInt(overlay.extent)) * tile_size;
        const rectangle = rl.Rectangle{
            .x = @floatFromInt(overlay.screen_position.x),
            .y = @floatFromInt(overlay.screen_position.y),
            .width = side,
            .height = side,
        };
        const line_width = @as(f32, @floatFromInt(textures_mod.outline_thickness)) * world_scale;
        switch (overlay.overlay_type) {
            .highlight => {
                // Animated marching-ants sprite over each targetable tile
                // (`world/tile_highlight`), tinted with the overlay color.
                // `source_rectangle` (the current animation frame) is always
                // set by the producer (`buildHighlightOverlays`) — the
                // pre-animation-sheet translucent-fill shape is gone; only
                // the texture-load-miss fallback keeps the primitive draw
                // (defensive degrade, consistent with missing-art handling).
                const src_rect = overlay.source_rectangle.?;
                if (self.textures.getTexture("world/tile_highlight")) |texture| {
                    const source = rl.Rectangle{
                        .x = @floatFromInt(src_rect.x),
                        .y = @floatFromInt(src_rect.y),
                        .width = @floatFromInt(src_rect.width),
                        .height = @floatFromInt(src_rect.height),
                    };
                    rl.drawTexturePro(texture, source, rectangle, .{ .x = 0, .y = 0 }, 0, toRaylibColor(overlay.color, 255));
                } else {
                    rl.drawRectangleRec(rectangle, toPremultipliedColor(overlay.color, 90));
                }
            },
            .cursor => {
                // Square outline around the hovered tile (same primitive as
                // the range/radius/aggro outlines).
                rl.drawRectangleLinesEx(rectangle, line_width, toRaylibColor(overlay.color, 255));
            },
            .range_outline, .radius_outline, .aggro_outline => {
                rl.drawRectangleLinesEx(rectangle, line_width, toRaylibColor(overlay.color, 255));
            },
            .region_edge => {
                // One stroke segment of a tile-region outline (the editor
                // decoration footprint preview): a thin filled bar along
                // the chosen side of the 1-tile square, offset half a
                // thickness outward so it centers on the region boundary
                // like the square outlines above. Bars span the full tile
                // side, so adjacent segments join seamlessly (corners
                // included) and any region shape renders as one closed
                // outline.
                const half = line_width / 2;
                const bar = switch (overlay.edge) {
                    .top => rl.Rectangle{
                        .x = rectangle.x,
                        .y = rectangle.y - half,
                        .width = rectangle.width,
                        .height = line_width,
                    },
                    .bottom => rl.Rectangle{
                        .x = rectangle.x,
                        .y = rectangle.y + rectangle.height - half,
                        .width = rectangle.width,
                        .height = line_width,
                    },
                    .left => rl.Rectangle{
                        .x = rectangle.x - half,
                        .y = rectangle.y,
                        .width = line_width,
                        .height = rectangle.height,
                    },
                    .right => rl.Rectangle{
                        .x = rectangle.x + rectangle.width - half,
                        .y = rectangle.y,
                        .width = line_width,
                        .height = rectangle.height,
                    },
                };
                rl.drawRectangleRec(bar, toRaylibColor(overlay.color, 255));
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
        const texture = self.textures.getTexture(sprite_id) orelse return;
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
        const texture = self.textures.getTexture(sprite.sprite_id) orelse return;
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
                if (entity.health_bar) |bar| self.drawHealthBar(bar, world_scale);
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
                // apply. See DESIGN → Animation.
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

    /// Draw a world overlay (floating indicator above world sprites). Drawn
    /// after ground drawables, before the UI. See DESIGN → Animation.
    fn drawWorldOverlay(
        self: *RaylibBackend,
        overlay: types.WorldOverlayDrawable,
        world_scale: f32,
    ) void {
        switch (overlay) {
            .floating_icon => |icon| {
                const texture = self.textures.getTexture(icon.sprite_id) orelse return;
                const drawn_size: f32 = @as(f32, @floatFromInt(icon.size)) * world_scale;
                const destination = rl.Rectangle{
                    .x = @floatFromInt(icon.screen_position.x),
                    .y = @floatFromInt(icon.screen_position.y),
                    .width = drawn_size,
                    .height = drawn_size,
                };
                const source = rl.Rectangle{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(texture.width),
                    .height = @floatFromInt(texture.height),
                };
                rl.drawTexturePro(texture, source, destination, .{ .x = 0, .y = 0 }, 0, toRaylibColor(icon.color, 255));
            },
            .floating_text => |ftext| {
                // Outlined via the SDF pipeline (shadow-ring fallback) — see
                // `drawOutlinedText`. Avoids `rl.imageTextEx` (degenerate for
                // our TTF font's CPU-side per-glyph images) and GPU
                // render-texture readback (which perturbs the main render
                // target mid-pass). See AGENTS → Animation.
                const drawn_font_size: f32 = @as(f32, @floatFromInt(ftext.font_size)) * world_scale;
                const spacing: f32 = drawn_font_size / @as(f32, @floatFromInt(ui.glyph_spacing_font_divisor));
                const text_z = self.frame_arena.allocator().dupeZ(u8, ftext.text) catch return;
                self.text.drawOutlinedText(
                    text_z,
                    .{ .x = @floatFromInt(ftext.screen_position.x), .y = @floatFromInt(ftext.screen_position.y) },
                    drawn_font_size,
                    spacing,
                    toRaylibColor(ftext.color, 255),
                    @as(f32, @floatFromInt(text_mod.text_outline_thickness)) * world_scale,
                );
            },
        }
    }

    /// Draw the entity health bar: depleted background (full, darkest),
    /// fill (cropped to `fill_fraction` from the left, team gradient index 1),
    /// then the outline frame on top — all at the same rect (the bar +
    /// outline share a 155x31 canvas). `size` fields are native reference
    /// pixels; `world_scale` (camera zoom) scales them at draw time. See
    /// DESIGN → Entity & UI Coloring.
    fn drawHealthBar(
        self: *RaylibBackend,
        bar: types.HealthBarDrawable,
        world_scale: f32,
    ) void {
        const destination = rl.Rectangle{
            .x = @floatFromInt(bar.screen_position.x),
            .y = @floatFromInt(bar.screen_position.y),
            .width = @as(f32, @floatFromInt(bar.width)) * world_scale,
            .height = @as(f32, @floatFromInt(bar.height)) * world_scale,
        };
        // Depleted background (drawn full).
        self.drawSprite("world/entity_health_bar_background", destination, null, bar.depleted_color, 255);
        // Fill (cropped to fraction from the left — `.right` keeps the left
        // portion, matching a health bar that depletes from the right).
        const fill_texture = self.textures.getTexture("world/entity_health_bar_background") orelse return;
        const fraction = std.math.clamp(bar.fill_fraction, 0, 1);
        const tex_w: f32 = @floatFromInt(fill_texture.width);
        const tex_h: f32 = @floatFromInt(fill_texture.height);
        const fill_source = rl.Rectangle{ .x = 0, .y = 0, .width = tex_w * fraction, .height = tex_h };
        const fill_dest = rl.Rectangle{ .x = destination.x, .y = destination.y, .width = destination.width * fraction, .height = destination.height };
        rl.drawTexturePro(fill_texture, fill_source, fill_dest, .{ .x = 0, .y = 0 }, 0, toRaylibColor(bar.fill_color, 255));
        // Outline frame on top (same rect), tinted with the fill color so the
        // bar's border matches the entity's team gradient index 1.
        self.drawSprite("world/entity_health_bar_outline", destination, null, bar.fill_color, 255);
    }

    // -- UI element drawing --

    fn drawUiElement(self: *RaylibBackend, element: ui.UiElement, highlight_color: types.Color, theme_darkest: types.Color) void {
        switch (element) {
            .nine_slice_panel => |panel| self.drawNineSlice(panel, theme_darkest),
            .slot => |slot| {
                if (slot.icon_sprite_id) |sprite_id| {
                    self.drawSprite(sprite_id, referenceRectangle(slot.screen_position, slot.size, slot.size), null, slot.icon_color, 255);
                }
            },
            .button => |button| {
                // Spriteless buttons are pure action/hit-test targets over a
                // separate background (e.g. a 9-slice panel behind them); the
                // renderer draws nothing for them — UNLESS highlighted, in
                // which case a lightest stroked rect marks them (the active
                // settings choice, or a hovered clickable).
                if (button.sprite_id) |sprite_id| {
                    const dest = referenceRectangle(button.screen_position, button.width, button.height);
                    self.drawSprite(sprite_id, dest, null, button.color, 255);
                    if (button.highlighted) self.drawHighlightOutline(sprite_id, dest, highlight_color);
                } else if (button.highlighted) {
                    // Stroked rect OUTSIDE the bounds: inflate by the outline
                    // thickness on all sides so the stroke frames the button
                    // instead of overlapping its edge (drawRectangleLinesEx
                    // centers the stroke on the rect boundary).
                    const t: i32 = textures_mod.outline_thickness;
                    const dest = referenceRectangle(button.screen_position, button.width, button.height);
                    const outer = rl.Rectangle{
                        .x = dest.x - @as(f32, @floatFromInt(t)),
                        .y = dest.y - @as(f32, @floatFromInt(t)),
                        .width = dest.width + 2 * @as(f32, @floatFromInt(t)),
                        .height = dest.height + 2 * @as(f32, @floatFromInt(t)),
                    };
                    rl.drawRectangleLinesEx(outer, @floatFromInt(t), toRaylibColor(highlight_color, 255));
                }
            },
            .text_label => |label| self.text.drawTextLabel(self.frame_arena.allocator(), label, highlight_color),
            .text_field => |field| {
                // Frame (9-slice, builder-tinted), selection highlight
                // UNDER the text, text, caret bar OVER it. The builder
                // computed every coordinate — the backend just draws (see
                // TextFieldUi).
                self.drawNineSlice(.{
                    .sprite_id = "ui/panel",
                    .screen_position = field.screen_position,
                    .width = field.width,
                    .height = field.height,
                    .color = field.frame_color,
                }, theme_darkest);
                if (field.selection) |selection| {
                    const selection_rect = rl.Rectangle{
                        .x = @as(f32, @floatFromInt(field.text_position.x + selection.x)),
                        .y = @as(f32, @floatFromInt(field.text_position.y)),
                        .width = @as(f32, @floatFromInt(selection.width)),
                        .height = @as(f32, @floatFromInt(field.font_size)),
                    };
                    rl.drawRectangleRec(selection_rect, toRaylibColor(field.text_color, 128));
                }
                self.text.drawTextLabel(self.frame_arena.allocator(), .{
                    .text = field.text,
                    .screen_position = field.text_position,
                    .font_size = field.font_size,
                    .color = field.text_color,
                    .blocks_input = false,
                }, highlight_color);
                if (field.caret) |caret| {
                    const caret_rect = rl.Rectangle{
                        .x = @as(f32, @floatFromInt(field.text_position.x + caret.x)),
                        .y = @as(f32, @floatFromInt(field.text_position.y)),
                        .width = @as(f32, @floatFromInt(caret_width)),
                        .height = @as(f32, @floatFromInt(caret.height)),
                    };
                    rl.drawRectangleRec(caret_rect, toRaylibColor(field.text_color, 255));
                }
            },
            .fill_sprite => |fill| self.drawFillSprite(fill),
            .image => |image| {
                const dest = referenceRectangle(image.screen_position, image.width, image.height);
                const source: ?rl.Rectangle = if (image.source_rectangle) |rectangle|
                    referenceRectangle(rectangle.position(), rectangle.width, rectangle.height)
                else
                    null;
                self.drawSprite(image.sprite_id, dest, source, image.color, image.alpha);
                if (image.highlighted) self.drawHighlightOutline(image.sprite_id, dest, highlight_color);
            },
            .solid_rect => |rect| {
                const r = referenceRectangle(rect.screen_position, rect.width, rect.height);
                if (rect.filled) {
                    rl.drawRectangleRec(r, toRaylibColor(rect.color, 255));
                } else {
                    rl.drawRectangleLinesEx(r, @floatFromInt(rect.line_width), toRaylibColor(rect.color, 255));
                }
            },
            .slider => |slider| {
                // Integer slider: track (dark) + fill (lightest, proportional)
                // + thumb (lightest square at the fill end). The value label
                // is a separate text_label emitted by the builder.
                const dest = referenceRectangle(slider.screen_position, slider.width, slider.height);
                const track_height: f32 = 16;
                const track_y = dest.y + (dest.height - track_height) / 2;
                const track_rect = rl.Rectangle{ .x = dest.x, .y = track_y, .width = dest.width, .height = track_height };
                const track_color = rl.Color{ .r = 80, .g = 80, .b = 80, .a = 255 };
                rl.drawRectangleRec(track_rect, track_color);
                const range: f32 = if (slider.max > slider.min) @as(f32, @floatFromInt(slider.max - slider.min)) else 1;
                const fraction = @as(f32, @floatFromInt(slider.value - slider.min)) / range;
                const fill_width = dest.width * fraction;
                if (fill_width > 0) {
                    const fill_rect = rl.Rectangle{ .x = dest.x, .y = track_y, .width = fill_width, .height = track_height };
                    rl.drawRectangleRec(fill_rect, toRaylibColor(highlight_color, 255));
                }
                // Thumb: a square centered on the track at the fill end.
                const thumb_size: f32 = 48;
                const thumb_x = dest.x + fill_width - thumb_size / 2;
                const thumb_y = dest.y + (dest.height - thumb_size) / 2;
                const thumb_rect = rl.Rectangle{ .x = thumb_x, .y = thumb_y, .width = thumb_size, .height = thumb_size };
                rl.drawRectangleRec(thumb_rect, toRaylibColor(highlight_color, 255));
            },
        }
    }

    /// Draw a precomputed OUTER edge-outline mask over `destination`, tinted with
    /// `highlight_color`. Used by highlighted UI elements (Button/Image) to
    /// ring the sprite silhouette. Falls back to a rectangle outline when
    /// the sprite or its mask is unavailable (e.g. a placeholder magenta
    /// box) so the hover highlight still reads.
    fn drawHighlightOutline(self: *RaylibBackend, sprite_id: []const u8, destination: rl.Rectangle, highlight_color: types.Color) void {
        const mask = self.textures.getOutlineTexture(sprite_id) orelse {
            // Fallback for missing sprites (or mask build failures): ring
            // the destination rectangle directly. Lets the hover highlight
            // work on placeholder magenta boxes before the real asset lands.
            rl.drawRectangleLinesEx(destination, @floatFromInt(textures_mod.outline_thickness), toRaylibColor(highlight_color, 255));
            return;
        };
        const source = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(mask.width),
            .height = @floatFromInt(mask.height),
        };
        rl.drawTexturePro(mask, source, destination, .{ .x = 0, .y = 0 }, 0, toRaylibColor(highlight_color, 255));
    }

    /// Draw a precomputed INNER edge-outline mask for `sprite_id` over its
    /// full sprite frame at `screen_position` (the top-left), scaled by
    /// `world_scale`, tinted pure black at `alpha`. Used by the occlusion
    /// inset pass to trace an occluded entity/item/marker's silhouette edge
    /// over a decoration that draws in front of it. Drawn over the FULL
    /// sprite rect (no scissor): the unoccluded portion merges into the art's
    /// own black outline (self-subtle), the occluded portion darkens the
    /// decoration — see DESIGN → Decorations & Footprint → Occlusion inset.
    /// No-op if the sprite or its mask is unavailable.
    fn drawOcclusionInset(
        self: *RaylibBackend,
        inset: types.OcclusionInsetDrawable,
        world_scale: f32,
    ) void {
        const mask = self.textures.getCompositeInsetTexture(inset.sprite_stack, inset.frame_width, inset.frame_height) orelse return;
        const source = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(inset.frame_width),
            .height = @floatFromInt(inset.frame_height),
        };
        const destination = rl.Rectangle{
            .x = @floatFromInt(inset.screen_position.x),
            .y = @floatFromInt(inset.screen_position.y),
            .width = @as(f32, @floatFromInt(inset.frame_width)) * world_scale,
            .height = @as(f32, @floatFromInt(inset.frame_height)) * world_scale,
        };
        rl.drawTexturePro(mask, source, destination, .{ .x = 0, .y = 0 }, 0, toPremultipliedColor(.{ .r = 0, .g = 0, .b = 0 }, inset.alpha));
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
        alpha: u8,
    ) void {
        const texture = self.textures.getTexture(sprite_id) orelse {
            rl.drawRectangleRec(destination, rl.Color.magenta);
            return;
        };
        const whole = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(texture.width),
            .height = @floatFromInt(texture.height),
        };
        if (diagnostics_mod.enabled and !self.diagnostics.sprite_probe_logged) {
            self.diagnostics.logFirstSpriteDraw(sprite_id, texture, source orelse whole, destination, tint, alpha);
        }
        rl.drawTexturePro(texture, source orelse whole, destination, .{ .x = 0, .y = 0 }, 0, toPremultipliedColor(tint, alpha));
    }

    /// 9-slice: every corner is drawn square (aspect-true 1:1) and the edges
    /// + center stretch to fill — the rect math lives in the pure, tested
    /// `ui.nineSlicePieces` (corners shrink proportionally on panels smaller
    /// than two slices instead of being squashed).
    fn drawNineSlice(self: *RaylibBackend, panel: ui.NineSlicePanel, theme_darkest: types.Color) void {
        const texture = self.textures.getTexture(panel.sprite_id) orelse {
            rl.drawRectangleRec(referenceRectangle(panel.screen_position, panel.width, panel.height), rl.Color.magenta);
            return;
        };        // `default_tint` (pure white) is the "unset" sentinel: a panel that
        // didn't pick an explicit color inherits the active theme's `darkest`
        // (mirrors the text-label convention in `drawTextLabel`). An explicit
        // `.color` overrides it.
        // Select the SOURCE color first, then convert once — an if/else
        // EXPRESSION returning the extern rl.Color by value miscompiles on
        // aarch64-macos optimized builds (both branch stores vanish; the
        // draw tints with uninitialized stack — see DONE.md, "mac 9-slice
        // panels — ROOT CAUSE FOUND").
        const source_color = if (std.meta.eql(panel.color, ui.default_tint))
            theme_darkest
        else
            panel.color;
        const tint = toRaylibColor(source_color, 255);

        const destination = types.Rectangle{
            .x = panel.screen_position.x,
            .y = panel.screen_position.y,
            .width = panel.width,
            .height = panel.height,
        };
        const pieces = ui.nineSlicePieces(texture.width, texture.height, destination);
        if (diagnostics_mod.enabled and !self.diagnostics.panel_probe_logged) {
            self.diagnostics.logFirstPanelDraw(panel, texture, tint, theme_darkest, destination, pieces);
        }
        for (pieces) |piece| {
            if (piece.destination.width <= 0 or piece.destination.height <= 0) continue;
            const source = rl.Rectangle{
                .x = @floatFromInt(piece.source.x),
                .y = @floatFromInt(piece.source.y),
                .width = @floatFromInt(piece.source.width),
                .height = @floatFromInt(piece.source.height),
            };
            const piece_destination = rl.Rectangle{
                .x = @floatFromInt(piece.destination.x),
                .y = @floatFromInt(piece.destination.y),
                .width = @floatFromInt(piece.destination.width),
                .height = @floatFromInt(piece.destination.height),
            };
            rl.drawTexturePro(texture, source, piece_destination, .{ .x = 0, .y = 0 }, 0, tint);
        }
    }

    fn drawFillSprite(self: *RaylibBackend, fill: ui.FillSprite) void {
        const destination = referenceRectangle(fill.screen_position, fill.width, fill.height);
        // Background (e.g. depleted health) drawn whole.
        self.drawSprite(fill.background_sprite_id, destination, null, fill.background_color, 255);

        const texture = self.textures.getTexture(fill.fill_sprite_id) orelse return;
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
};

/// The Audio subsystem's load-time warning sink (see audio.zig): routes its
/// formatted messages — e.g. the music phase-lock mismatch — into the dev
/// diagnostics buffer. Wired unconditionally: the append is inert when
/// diagnostics are inactive (the buffer is simply never flushed in non-dev
/// builds).
fn audioDiagnosticsSink(context: ?*anyopaque, message: []const u8) void {
    const self: *RaylibBackend = @ptrCast(@alignCast(context orelse return));
    self.diagnostics.append("{s}", .{message});
}

const toRaylibColor = conversions.toRaylibColor;
const toPremultipliedColor = conversions.toPremultipliedColor;
const referenceRectangle = conversions.referenceRectangle;
