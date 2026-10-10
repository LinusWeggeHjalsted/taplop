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
const diagnostics_mod = @import("../diagnostics.zig");
const diagnostics_probes = @import("diagnostics.zig");
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

/// Fragment shader for the sprite pass (see `beginSpritePass`): raylib's
/// default batch fragment shader (textured quad: texel × vertex tint) plus
/// an `lodBias` uniform that snaps mip selection to the SHARPER adjacent
/// level for the discrete camera-zoom × render-preset combos (see
/// `spriteLodSnapBias`). Mirrors the default shader EXACTLY otherwise —
/// untextured draws (rect fills) bind raylib's white 1x1 texture, so the
/// multiply passes them through untouched, and the blend mode is orthogonal
/// to the shader. Desktop GL (GLSL 3.30).
const sprite_pass_fs_glsl330 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform float lodBias;
    \\out vec4 finalColor;
    \\void main()
    \\{
    \\    vec4 texelColor = texture(texture0, fragTexCoord, lodBias);
    \\    finalColor = texelColor*fragColor;
    \\}
;

/// WebGL variant (GLSL ES 3.00 — the web context is WebGL 2; same math as
/// the desktop one).
const sprite_pass_fs_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform float lodBias;
    \\out vec4 finalColor;
    \\void main()
    \\{
    \\    vec4 texelColor = texture(texture0, fragTexCoord, lodBias);
    \\    finalColor = texelColor*fragColor;
    \\}
;

/// The sprite-pass fragment shader for this build target: GLSL ES 3.00 on
/// web (emscripten), GLSL 3.30 on desktop.
const sprite_pass_fs_source: [:0]const u8 = if (@import("builtin").target.cpu.arch == .wasm32)
    sprite_pass_fs_glsl300es
else
    sprite_pass_fs_glsl330;

/// Per-frame mip snap bias for the sprite pass: trilinear's fractional blend
/// at a NON-dyadic minification over-blurs — at LOD 1.41 (zoom 0.75 on a
/// 1080p target) it mixes 41% of the heavily-averaged level 2 into the
/// sample, which reads as the "washed out" zoom level. `total_scale` is the
/// drawn sprite's whole minification (camera zoom × renderScale for world
/// layers, renderScale for UI); the returned bias snaps sampling to the
/// SHARPER adjacent level (subtracting the LOD's fractional part). Residual
/// cost: the sharper level is undersampled by up to 2^frac (≤ 1.5× across
/// the discrete zoom × preset combos — mild sparkle on fine detail instead
/// of uniform blur). Returns 0 at exact powers of two and at magnification,
/// so the on-level combos are unaffected.
fn spriteLodSnapBias(total_scale: f32) f32 {
    if (total_scale >= 1.0) return 0.0;
    const lod = std.math.log2(1.0 / total_scale);
    const fractional_part = lod - @floor(lod);
    return -fractional_part;
}

/// Fragment shader for the outline stripe pass (see `beginOutlineStripeScope`):
/// raylib's default batch fragment shader plus a diagonal marching-stripe flip
/// between PURE WHITE and PURE BLACK bands — the animated read-boost for
/// outlines over busy art (hardcoded pair, chosen by eyeball over the earlier
/// theme `lightest`/`darkest` tint pair; the per-draw tint stays as the
/// compile-fail fallback look). Stripes run at 45° in render-target pixels
/// (gl_FragCoord): `s = x - y - phase*period` (the y-flipped render target
/// mirrors the on-screen diagonal), and `mod(s, period) < stripeBandWidth`
/// picks the band color at the texel's own alpha (premultiplied output — the
/// pass draws under BLEND_ALPHA_PREMULTIPLY; the halo-mask shapes and AA
/// edges come from that alpha). Works for BOTH outline draw shapes:
/// untextured quads (rectangle strokes bind the white 1×1 texture) and the
/// icon halo masks. Mirrors the default shader EXACTLY otherwise. Desktop
/// GL (GLSL 3.30).
const outline_stripe_fs_glsl330 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform float stripePhase;
    \\uniform float stripeBandWidth;
    \\out vec4 finalColor;
    \\void main()
    \\{
    \\    vec4 texelColor = texture(texture0, fragTexCoord)*fragColor;
    \\    float period = 2.0*stripeBandWidth;
    \\    float s = gl_FragCoord.x - gl_FragCoord.y - stripePhase*period;
    \\    if (mod(s, period) < stripeBandWidth) {
    \\        finalColor = vec4(0.0, 0.0, 0.0, texelColor.a);
    \\    } else {
    \\        finalColor = vec4(vec3(texelColor.a), texelColor.a);
    \\    }
    \\}
;

/// WebGL variant (GLSL ES 3.00 — the web context is WebGL 2; same math as
/// the desktop one).
const outline_stripe_fs_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform float stripePhase;
    \\uniform float stripeBandWidth;
    \\out vec4 finalColor;
    \\void main()
    \\{
    \\    vec4 texelColor = texture(texture0, fragTexCoord)*fragColor;
    \\    float period = 2.0*stripeBandWidth;
    \\    float s = gl_FragCoord.x - gl_FragCoord.y - stripePhase*period;
    \\    if (mod(s, period) < stripeBandWidth) {
    \\        finalColor = vec4(0.0, 0.0, 0.0, texelColor.a);
    \\    } else {
    \\        finalColor = vec4(vec3(texelColor.a), texelColor.a);
    \\    }
    \\}
;

/// The outline-stripe fragment shader for this build target: GLSL ES 3.00
/// on web (emscripten), GLSL 3.30 on desktop.
const outline_stripe_fs_source: [:0]const u8 = if (@import("builtin").target.cpu.arch == .wasm32)
    outline_stripe_fs_glsl300es
else
    outline_stripe_fs_glsl330;

/// The stripe band size in multiples of the shared outline thickness (8
/// source px), in REFERENCE pixels — ONE value for both outline families
/// (world + UI), zoom-independent: the crawl rate is one period per cycle,
/// so a shared band means a shared period — both families march at the
/// same size AND the same pixel speed (at the default zoom 0.5 a
/// zoom-scaled world band was half the UI band — half the crawl speed, the
/// observed mismatch). The world bands therefore do NOT track the outline
/// stroke's zoom-scaled thickness; family uniformity beats per-family
/// thickness matching. Doubled after the first eyeball pass.
const outline_stripe_band_multiplier: f32 = 2.0;

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
    /// Sprite-pass shader (see `beginSpritePass`): the default batch fragment
    /// shader + an `lodBias` uniform that snaps mip selection for the discrete
    /// camera-zoom × render-preset combos. null → the shader failed to
    /// compile and sprite draws use the plain default shader (trilinear —
    /// the washed-out intermediate zooms, accepted for a near-unreachable
    /// failure).
    sprite_shader: ?rl.Shader,
    /// Cached `lodBias` uniform location (-1 = not found; raylib's
    /// setShaderValue no-ops on -1, degrading to an unbiasd — trilinear —
    /// sprite pass, never a crash).
    sprite_lod_bias_location: i32,
    /// Outline-stripe shader (see `beginOutlineStripeScope`): the default
    /// batch fragment shader + the marching-stripe flip between the outline
    /// tint and the theme's `darkest`. null → the shader failed to compile
    /// and outline draws keep the plain solid tint (the pre-shader look).
    outline_stripe_shader: ?rl.Shader,
    /// Cached stripe uniform locations (-1 = not found; setShaderValue
    /// no-ops on -1, degrading to a solid tint, never a crash).
    outline_stripe_phase_location: i32,
    outline_stripe_band_location: i32,
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
    /// Diagnostics: the boot/probe/readback log (src/diagnostics.zig — raylib-
    /// free; the GL-gathering probe sites live in raylib/diagnostics.zig).
    /// Runtime activation (`enabled`: the --diagnostics CLI flag ORs onto the
    /// dev-mode default), so the code ships in every native build — a
    /// release build can produce its own diagnostics. Flushes at the
    /// end-of-frame safe point + shutdown.
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

        // Sprite-pass shader: the default batch fragment shader + an LOD snap
        // bias uniform (see `beginSpritePass`). Loaded unconditionally at init
        // — a compile failure just means sprite draws keep the plain
        // trilinear filter (slice-1 look, washed-out intermediate zooms).
        const sprite_shader = rl.loadShaderFromMemory(null, sprite_pass_fs_source) catch null;
        const sprite_lod_bias_location: i32 = if (sprite_shader) |shader|
            rl.getShaderLocation(shader, "lodBias")
        else
            -1;

        // Outline-stripe shader (see `beginOutlineStripeScope`). Loaded
        // unconditionally — a compile failure just means outline draws keep
        // the plain solid tint (the pre-shader look).
        const outline_stripe_shader = rl.loadShaderFromMemory(null, outline_stripe_fs_source) catch null;
        const outline_stripe_phase_location: i32 = if (outline_stripe_shader) |shader|
            rl.getShaderLocation(shader, "stripePhase")
        else
            -1;
        const outline_stripe_band_location: i32 = if (outline_stripe_shader) |shader|
            rl.getShaderLocation(shader, "stripeBandWidth")
        else
            -1;

        return .{
            .allocator = allocator,
            .render_target = render_target,
            .render_width = default_dims.width,
            .render_height = default_dims.height,
            .text = text_mod.TextRenderer.init(allocator, file_source),
            .sprite_shader = sprite_shader,
            .sprite_lod_bias_location = sprite_lod_bias_location,
            .outline_stripe_shader = outline_stripe_shader,
            .outline_stripe_phase_location = outline_stripe_phase_location,
            .outline_stripe_band_location = outline_stripe_band_location,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .textures = .{ .allocator = allocator, .file_source = file_source },
            .audio = .{ .allocator = allocator, .file_source = file_source },
            .diagnostics = .{
                .allocator = allocator,
                .file_source = file_source,
                .enabled = diagnostics_probes.default_enabled,
            },
            .last_time_microseconds = @intFromFloat(rl.getTime() * std.time.us_per_s),
            .file_source = file_source,
        };
    }

    pub fn deinit(self: *RaylibBackend) void {
        if (self.sprite_shader) |shader| rl.unloadShader(shader);
        if (self.outline_stripe_shader) |shader| rl.unloadShader(shader);
        self.textures.deinit();
        self.audio.deinit();
        self.text.deinit();
        self.frame_arena.deinit();
        self.diagnostics.deinit();
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
    /// target (`render_width / reference_width`). Draw sites call it to convert
    /// reference-space sizes (e.g. the outline band width) into
    /// render-target pixels — the space gl_FragCoord lives in.
    pub fn renderScale(self: *const RaylibBackend) f32 {
        return @as(f32, @floatFromInt(self.render_width)) / reference_width;
    }

    /// Per-frame outline-stripe uniforms — ALL of them (the shader has no
    /// per-scope state): the phase (0..1 of the stripe cycle — view-side,
    /// from the animation clock via `ViewState.outline_stripe_phase`), and
    /// the band width (the shared `outline_stripe_band_multiplier` × outline
    /// thickness × renderScale — one band for BOTH outline families, see
    /// the multiplier's doc). The band colors are hardcoded in the shader
    /// source (pure white + pure black). Called once per frame from
    /// `render`. No-op when the shader is unavailable.
    fn setOutlineStripeFrameUniforms(self: *RaylibBackend, phase: f32) void {
        const shader = self.outline_stripe_shader orelse return;
        const band_width: f32 = outline_stripe_band_multiplier *
            @as(f32, @floatFromInt(textures_mod.outline_thickness)) * self.renderScale();
        rl.setShaderValue(shader, self.outline_stripe_phase_location, &phase, .float);
        rl.setShaderValue(shader, self.outline_stripe_band_location, &band_width, .float);
    }

    /// Begin an outline-stripe draw scope: binds the stripe shader. Every
    /// stripe uniform is frame-level (see `setOutlineStripeFrameUniforms`)
    /// — there is no per-scope state, only the bind. No-op when the shader
    /// failed to compile (the outline draws keep the plain solid tint).
    /// Draw sites open this INSIDE an enclosing sprite pass —
    /// `endOutlineStripeScope` restores it (see the endShaderMode trap
    /// there).
    pub fn beginOutlineStripeScope(self: *RaylibBackend) void {
        const shader = self.outline_stripe_shader orelse return;
        rl.beginShaderMode(shader);
    }

    /// Close a `beginOutlineStripeScope` scope — `total_scale` is the
    /// ENCLOSING sprite pass's scale (camera zoom × renderScale for world
    /// outlines, renderScale for UI). THE endShaderMode TRAP: raylib's
    /// endShaderMode restores the DEFAULT shader, not the sprite-pass
    /// shader the scope opened inside — the rest of the enclosing pass
    /// would silently lose its LOD snap bias (the world layers share ONE
    /// sprite-pass scope; see `beginSpritePass`). So the close RE-OPENS the
    /// sprite pass with that scale. No-op when the stripe shader is
    /// unavailable (nothing was opened).
    pub fn endOutlineStripeScope(self: *RaylibBackend, total_scale: f32) void {
        if (self.outline_stripe_shader == null) return;
        rl.endShaderMode();
        self.beginSpritePass(total_scale);
    }

    /// Begin a sprite-pass draw scope under the sprite shader, with the LOD
    /// snap bias for `total_scale` — the drawn sprites' whole minification
    /// (camera zoom × renderScale for world layers, renderScale for UI).
    /// No-op when the shader failed to compile (plain trilinear). SCOPE
    /// GRANULARITY MATTERS: raylib's endShaderMode (nested SDF text draws)
    /// restores the DEFAULT shader, not this one, so a scope must not span
    /// text draws — sprite-only runs share one scope, anything that can
    /// contain text (world overlays, UI elements) scopes per item.
    /// See DESIGN → Platform Seam → Sprite-mipmap smoothing.
    fn beginSpritePass(self: *RaylibBackend, total_scale: f32) void {
        const shader = self.sprite_shader orelse return;
        const lod_bias = spriteLodSnapBias(total_scale);
        rl.setShaderValue(shader, self.sprite_lod_bias_location, &lod_bias, .float);
        rl.beginShaderMode(shader);
    }

    /// Close a `beginSpritePass` scope. No-op when the shader is unavailable.
    fn endSpritePass(self: *RaylibBackend) void {
        if (self.sprite_shader != null) rl.endShaderMode();
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
        if (self.diagnostics.shouldRecordBoot())
            diagnostics_probes.recordBoot(&self.diagnostics, self.render_width, self.render_height);

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
        // Frame-level outline-stripe uniforms (phase + band width): set once
        // per frame — uniform values live on the program, so the per-scope
        // beginOutlineStripeScope only binds.
        self.setOutlineStripeFrameUniforms(view_state.outline_stripe_phase);
        // Sprite passes (LOD snap; see beginSpritePass): ONE scope for the
        // text-free world layers, then per-item scopes where text can draw
        // mid-pass (combat numbers, UI labels switch to the SDF shader, and
        // raylib's endShaderMode would drop the bias for anything after
        // them). World layers first (tiles, then overlays + ground drawables
        // as they land), then the UI on top.
        const world_total_scale = view_state.world_scale * self.renderScale();
        self.beginSpritePass(world_total_scale);
        for (view_state.tiles) |tile| draw_mod.drawWorldSprite(
            self,
            "world/tile",
            tile.screen_position,
            view_state.world_scale,
            tile.color,
        );
        for (view_state.tile_overlays) |overlay| draw_mod.drawTileOverlay(self, overlay, view_state.world_scale);
        for (view_state.ground_drawables) |ground| draw_mod.drawGroundDrawable(self, ground, view_state.world_scale);
        for (view_state.occlusion_insets) |inset| draw_mod.drawOcclusionInset(self, inset, view_state.world_scale);
        self.endSpritePass();
        for (view_state.world_overlays) |overlay| {
            self.beginSpritePass(world_total_scale);
            draw_mod.drawWorldOverlay(self, overlay, view_state.world_scale);
            self.endSpritePass();
        }
        const theme_darkest = view_state.active_color_theme.darkest;
        for (view_state.ui_elements) |element| {
            self.beginSpritePass(self.renderScale());
            draw_mod.drawUiElement(self, element, view_state.active_color_theme.lightest, theme_darkest);
            self.endSpritePass();
        }
        rl.endMode2D();
        rl.endBlendMode();
        rl.endTextureMode();
        if (self.diagnostics.shouldReadBackTarget())
            diagnostics_probes.recordTargetReadback(&self.diagnostics, self.render_target, self.render_width, self.render_height, self.renderScale());

        // Blit the target to the window, letterboxed. RenderTextures are stored
        // y-flipped, so the source height is negated. The blit uses the RENDER
        // target dims (not the 4K reference) — the pointer transform
        // (`viewTransform`, window→4K) is independent and stays reference-
        // based.
        rl.beginDrawing();
        // With SUPPORT_CUSTOM_FRAME_CONTROL, endDrawing() only flushes the
        // render batch — we swap the buffer ourselves (vsync paces here).
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
        rl.endDrawing();
        rl.swapScreenBuffer();

        // End-of-frame diagnostics flush: AFTER present, never mid-draw —
        // observation work inside the draw path perturbs the observed
        // system (the mac-hunt lesson). Sections only mark pending; this is
        // the safe point that writes.
        self.diagnostics.flushIfPending();
    }
};

/// The Audio subsystem's load-time warning sink (see audio.zig): routes its
/// formatted messages — e.g. the music phase-lock mismatch — into the
/// diagnostics buffer. Wired unconditionally; the append self-gates on
/// `enabled`, so an inactive instance accumulates nothing.
fn audioDiagnosticsSink(context: ?*anyopaque, message: []const u8) void {
    const self: *RaylibBackend = @ptrCast(@alignCast(context orelse return));
    self.diagnostics.append("{s}", .{message});
}

const toRaylibColor = conversions.toRaylibColor;
const toPremultipliedColor = conversions.toPremultipliedColor;
const referenceRectangle = conversions.referenceRectangle;
