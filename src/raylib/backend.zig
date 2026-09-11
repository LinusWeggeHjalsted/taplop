//! raylib platform backend — the composition root + driver of `src/raylib/`
//! (the ONLY directory whose files import raylib directly; native.zig and
//! web.zig import it through `raylib/backend.zig`; every file in it is
//! excluded from the headless test-root scan in build.zig — see DESIGN →
//! Platform Seam). This file owns the window, the render target + render
//! pass, the real clock, and the duck-typed `RaylibBackend` interface; the
//! subsystems live in the sibling files (input_poll / audio / textures /
//! text / diagnostics / draw) and are owned as sub-structs or called as
//! free functions. The shared game logic in main.zig never touches raylib;
//! gameLoop drives this backend through a small duck-typed interface:
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
const input_poll = @import("input_poll.zig");
const audio_mod = @import("audio.zig");
const textures_mod = @import("textures.zig");
const text_mod = @import("text.zig");
const conversions = @import("conversions.zig");
const diagnostics_mod = @import("diagnostics.zig");
const draw_mod = @import("draw.zig");

const reference_width_int: i32 = types.reference_width;
const reference_height_int: i32 = types.reference_height;
const reference_width: f32 = @floatFromInt(reference_width_int);
const reference_height: f32 = @floatFromInt(reference_height_int);



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
        for (view_state.tiles) |tile| draw_mod.drawWorldSprite(self, 
            "world/tile",
            tile.screen_position,
            view_state.world_scale,
            tile.color,
        );
        for (view_state.tile_overlays) |overlay| draw_mod.drawTileOverlay(self, overlay, view_state.world_scale);
        for (view_state.ground_drawables) |ground| draw_mod.drawGroundDrawable(self, ground, view_state.world_scale);
        for (view_state.occlusion_insets) |inset| draw_mod.drawOcclusionInset(self, inset, view_state.world_scale);
        for (view_state.world_overlays) |overlay| draw_mod.drawWorldOverlay(self, overlay, view_state.world_scale);
        const theme_darkest = view_state.active_color_theme.darkest;
        for (view_state.ui_elements) |element| draw_mod.drawUiElement(self, element, view_state.active_color_theme.lightest, theme_darkest);
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
