//! Text subsystem of the raylib backend: ALL text draws through the SDF
//! pipeline (plain fill = the same shader with a zero outline width - see
//! `drawSdfText`), built at init from the build-time blob. When the
//! pipeline fails to init (broken blob / texture upload / shader compile -
//! see DESIGN → Platform Seam → SDF text outline for why that is
//! near-unreachable), text falls back to raylib's default bitmap font:
//! legible ASCII, no outline band, no deinit ownership. The backend keeps
//! `fontMetrics` as a thin wrapper (main.zig's RenderContext seam) and
//! passes its frame arena as the per-frame scratch to the draw fns.

const std = @import("std");
const rl = @import("raylib");
const types = @import("../types.zig");
const ui = @import("../ui.zig");
const font_codepoints = @import("../font_codepoints.zig");
const conversions = @import("conversions.zig");

const toRaylibColor = conversions.toRaylibColor;

/// Base rasterization size the build-time SDF atlas is baked at (see
/// tools/sdf_atlas_generator.zig); `drawTextEx` scales from it. Sized to
/// cover the largest `font_size` in use (96, menu buttons); the SDF
/// pipeline's AA is analytic, so no runtime raster is involved. The atlas
/// is one GPU texture (see DESIGN → Platform Seam → SDF text outline for
/// the size budget).
const font_base_size: i32 = 128;

/// Outline thickness for floating TEXT overlays (damage/heal numbers) and
/// outlined UI text labels: the black edge-outline width, in the drawn
/// text's own pixel space. Rendered by the SDF text-outline pipeline (see
/// `SdfTextOutline`) with the 8-direction offset-shadow ring as fallback
/// (see `drawOutlinedText`). Tune from in-game viewing.
pub const text_outline_thickness: i32 = 8;

/// SDF text-outline encoding scale: the build-time atlas generator (tools/
/// sdf_atlas_generator.zig) bakes each atlas texel as `alpha = 128 +
/// sdf_pixel_dist_scale * distance_px` (clamped 0..255), distance in ATLAS
/// pixels from the glyph edge (positive inside). MUST match the
/// `-DFONT_SDF_PIXEL_DIST_SCALE` define on the generator's raylib dependency
/// in build.zig - the fragment shader decodes the field assuming this value,
/// and `initSdfTextOutline` validates the blob's baked params against it
/// (mismatch → warning + shadow-ring fallback). 128/6 ≈ ±21 atlas px of
/// range. The range is NOT sufficient for every requested outline - see
/// `sdf_max_outline_atlas_pixels` (drawSdfText clamps) - it covers an 8px
/// outline at 56px+ (8*128/56 ≈ 18 atlas px, clear of the clamp floor).
const sdf_pixel_dist_scale: f32 = 6.0;

/// SDF glyph raster margin around each glyph bbox, in atlas pixels. MUST
/// match `-DFONT_SDF_CHAR_PADDING` on the generator's raylib dependency
/// in build.zig (baked into the blob, validated at parse). Must be ≥ the
/// encoding range (±21 px) so the distance field isn't cropped at the glyph
/// rect edge - the outline band would clamp there otherwise.
const sdf_char_padding: i32 = 22;

/// Maximum outline width the atlas can actually encode, in atlas px.
/// `drawSdfText` clamps the requested width to this. WHY: the field clamps
/// at −(128/scale) ≈ −21.3, and the shader fades the band over the window
/// [−W−aa, −W+aa] - a request whose window dips to the clamp floor makes
/// every clamped texel evaluate band ≈ 0.5. Clamped texels are exactly the
/// rect-CORNER diagonals (true distance to the ink runs ~30px there while
/// the rect is only 22px padded per axis), so the result is ghost squares
/// at each glyph quad's corners - seen on the 48px material-count labels
/// (8*128/48 ≈ 21.3, right AT the floor). The −2 margin covers the fwidth
/// window at the smallest outlined size on the smallest render target
/// (~1.1 d-units at 48px on a 720p target); clamped requests draw a
/// marginally thinner outline (7.2px instead of 8 at 48px) - never squares.
const sdf_max_outline_atlas_pixels: f32 = 128.0 / sdf_pixel_dist_scale - 2.0;

comptime {
    if (sdf_pixel_dist_scale != 6.0 or sdf_char_padding != 22) {
        @compileError("SDF constants changed - update the matching -DFONT_SDF_* defines in build.zig (generator raylib dep), tools/sdf_atlas_generator.zig's baked_* constants, and the /6.0 decode in the sdf_outline_fs_* shaders");
    }
}

/// Fragment shader for the SDF text outline, desktop GL (GLSL 3.30; same
/// structure as raylib's text_font_sdf example). Decodes the distance
/// field, builds an antialiased fill (inside the glyph edge) and outline
/// band (within `outlineWidth` atlas px outside the edge), composites the
/// outline under the fill (source-over), and outputs PREMULTIPLIED alpha
/// for the render pass's `BLEND_ALPHA_PREMULTIPLY` blend (the RGB is already
/// scaled by outA - no straight-alpha division). `fwidth` sizes the
/// antialias band to ~1 screen pixel. The `/6.0` decode matches
/// `sdf_pixel_dist_scale`.
const sdf_outline_fs_glsl330 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform float outlineWidth;
    \\uniform vec4 outlineColor;
    \\out vec4 finalColor;
    \\void main()
    \\{
    \\    float d = (texture(texture0, fragTexCoord).a*255.0 - 128.0)/6.0;
    \\    float aa = fwidth(d);
    \\    float fill = smoothstep(-aa, aa, d);
    \\    float band = smoothstep(-outlineWidth - aa, -outlineWidth + aa, d);
    \\    float fa = fill*fragColor.a;
    \\    float ba = band*outlineColor.a;
    \\    float outA = fa + ba*(1.0 - fa);
    \\    vec3 outRGB = fragColor.rgb*fa + outlineColor.rgb*ba*(1.0 - fa);
    \\    finalColor = vec4(outRGB, outA);
    \\}
;

/// WebGL variant (GLSL ES 3.00 - the web context is WebGL 2, requested via
/// `opengl_version = .gles_3` on the web raylib dependency in build.zig;
/// see DESIGN → Platform Seam → WebGL 2). Same math as the desktop variant,
/// including `fwidth`-sized antialiasing (GLSL ES 3.00 has derivatives).
/// Highp floats: the decoded field spans ±21 and the AA band is a small
/// `fwidth` delta - mediump's 10-bit mantissa would visibly band it.
const sdf_outline_fs_glsl300es =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform float outlineWidth;
    \\uniform vec4 outlineColor;
    \\out vec4 finalColor;
    \\void main()
    \\{
    \\    float d = (texture(texture0, fragTexCoord).a*255.0 - 128.0)/6.0;
    \\    float aa = fwidth(d);
    \\    float fill = smoothstep(-aa, aa, d);
    \\    float band = smoothstep(-outlineWidth - aa, -outlineWidth + aa, d);
    \\    float fa = fill*fragColor.a;
    \\    float ba = band*outlineColor.a;
    \\    float outA = fa + ba*(1.0 - fa);
    \\    vec3 outRGB = fragColor.rgb*fa + outlineColor.rgb*ba*(1.0 - fa);
    \\    finalColor = vec4(outRGB, outA);
    \\}
;

/// The shader source for this build target: GLSL ES 3.00 on web (emscripten),
/// GLSL 3.30 on desktop.
const sdf_outline_fs_source: [:0]const u8 = if (@import("builtin").target.cpu.arch == .wasm32)
    sdf_outline_fs_glsl300es
else
    sdf_outline_fs_glsl330;

/// The SDF text pipeline (see `drawSdfText`): a glyph atlas whose texels
/// encode signed distance-to-glyph-edge (instead of coverage) plus the
/// fragment shader that thresholds the field into fill + outline band -
/// the ONE font every text draw uses (plain fill included, at outline
/// width 0). Built once at init from the build-time blob (see
/// `initSdfTextOutline`); null means unavailable (blob invalid, texture
/// upload, or shader compile failed) and ALL text falls back to raylib's
/// default bitmap font (outlined text additionally to the offset-shadow
/// ring). All-or-nothing by construction: an SDF atlas drawn without the
/// shader renders raw distances (garbage), a shader without the atlas is
/// useless.
///
/// Ownership: `recs`/`glyphs` are Zig-allocator slices that the assembled
/// `font`'s C pointers alias - deinit frees them directly and must NOT call
/// `rl.unloadFont` (raylib would free() Zig-allocated memory).
const SdfTextOutline = struct {
    font: rl.Font,
    shader: rl.Shader,
    /// Cached uniform locations. -1 = not found (raylib's SetShaderValue
    /// no-ops on -1, so a miss degrades to "no outline", never a crash).
    width_location: i32,
    color_location: i32,
    /// Backing storage for `font.recs` / `font.glyphs` (see Ownership above).
    recs: []rl.Rectangle,
    glyphs: []rl.GlyphInfo,
};

/// Parses the build-time SDF font blob (written by tools/
/// sdf_atlas_generator.zig, embedded via the `generated_sdf_font` module -
/// see build.zig) and assembles the SDF text-outline pipeline: one texture
/// upload + one shader compile. The expensive part (SDF glyph generation,
/// ~1.4s in a release build when it ran at runtime) is baked at build time,
/// so this runs in microseconds. Blob layout (all little-endian):
///   header:  "ZSDF", version u32, baseSize i32, glyphCount i32,
///            atlasWidth i32, atlasHeight i32, bakedPadding i32,
///            bakedDistScale f32-bits   (32 bytes)
///   glyphs:  glyphCount × { value, offsetX, offsetY, advanceX,
///            rec.x, rec.y, rec.w, rec.h } (i32 / f32-bits, 32 bytes each)
///   atlas:   atlasWidth*atlasHeight grayscale bytes
/// Every failure logs a warning and returns null (text falls back to
/// raylib's default bitmap font; outlined text to its shadow ring). No
/// TTF is read at runtime - the blob is baked from the shipped font at
/// build time.
fn initSdfTextOutline(allocator: std.mem.Allocator) ?SdfTextOutline {
    const blob = @import("generated_sdf_font").bytes;

    const header_len = 32;
    const glyph_record_len = 32;
    if (blob.len < header_len) return invalidSdfBlob("truncated header");
    if (!std.mem.eql(u8, blob[0..4], "ZSDF")) return invalidSdfBlob("bad magic");
    if (std.mem.readInt(u32, blob[4..8], .little) != 1) return invalidSdfBlob("unsupported version");
    const base_size = std.mem.readInt(i32, blob[8..12], .little);
    const glyph_count: usize = @intCast(std.mem.readInt(i32, blob[12..16], .little));
    const atlas_width = std.mem.readInt(i32, blob[16..20], .little);
    const atlas_height = std.mem.readInt(i32, blob[20..24], .little);
    const baked_padding = std.mem.readInt(i32, blob[24..28], .little);
    const baked_scale: f32 = @bitCast(std.mem.readInt(u32, blob[28..32], .little));
    if (base_size != font_base_size) return invalidSdfBlob("base size mismatch");
    if (baked_padding != sdf_char_padding or baked_scale != sdf_pixel_dist_scale)
        return invalidSdfBlob("encoding mismatch - regenerate the blob (build.zig generator) with matching constants");
    if (glyph_count == 0 or glyph_count > font_codepoints.max_atlas_codepoints)
        return invalidSdfBlob("glyph count out of range");
    if (atlas_width <= 0 or atlas_height <= 0) return invalidSdfBlob("atlas dimensions out of range");
    const atlas_len: usize = @intCast(atlas_width * atlas_height);
    if (blob.len != header_len + glyph_count * glyph_record_len + atlas_len)
        return invalidSdfBlob("length mismatch");

    const recs = allocator.alloc(rl.Rectangle, glyph_count) catch @panic("OOM");
    const glyph_infos = allocator.alloc(rl.GlyphInfo, glyph_count) catch @panic("OOM");
    for (0..glyph_count) |i| {
        const off = header_len + i * glyph_record_len;
        // Glyph images are left zeroed: only DrawTextEx consumes this font
        // (recs + metrics + texture), and it never reads glyph images.
        glyph_infos[i] = .{
            .value = readLe(i32, blob[off..]),
            .offsetX = readLe(i32, blob[off + 4 ..]),
            .offsetY = readLe(i32, blob[off + 8 ..]),
            .advanceX = readLe(i32, blob[off + 12 ..]),
            .image = std.mem.zeroes(rl.Image),
        };
        recs[i] = .{
            .x = @bitCast(readLe(u32, blob[off + 16 ..])),
            .y = @bitCast(readLe(u32, blob[off + 20 ..])),
            .width = @bitCast(readLe(u32, blob[off + 24 ..])),
            .height = @bitCast(readLe(u32, blob[off + 28 ..])),
        };
    }

    const shader = rl.loadShaderFromMemory(null, sdf_outline_fs_source) catch {
        std.debug.print("warning: SDF font: outline shader failed to compile; outlined text falls back to the shadow ring\n", .{});
        allocator.free(recs);
        allocator.free(glyph_infos);
        return null;
    };

    // Reconstruct the GRAY_ALPHA image GenImageFontAtlas produces (gray=255,
    // alpha=SDF distance) rather than a single-channel grayscale one: raylib
    // swizzles GRAY_ALPHA to (r, r, r, g) on desktop GL / uses alpha directly
    // on WebGL, so sampling .a yields the SDF value in both. A grayscale
    // texture would sample .a = 1 everywhere (solid-box rendering).
    const gray_alpha = allocator.alloc(u8, atlas_len * 2) catch @panic("OOM");
    defer allocator.free(gray_alpha);
    const atlas_bytes = blob[blob.len - atlas_len ..];
    for (atlas_bytes, 0..) |byte, i| {
        gray_alpha[i * 2] = 255;
        gray_alpha[i * 2 + 1] = byte;
    }

    // The gray-alpha buffer is scratch for the upload (raylib copies to GPU
    // memory; no ownership transfer, no unloadImage).
    const atlas_image = rl.Image{
        .data = gray_alpha.ptr,
        .width = atlas_width,
        .height = atlas_height,
        .mipmaps = 1,
        .format = .uncompressed_gray_alpha,
    };
    const texture = rl.loadTextureFromImage(atlas_image) catch {
        std.debug.print("warning: SDF font: atlas texture upload failed; outlined text falls back to the shadow ring\n", .{});
        rl.unloadShader(shader);
        allocator.free(recs);
        allocator.free(glyph_infos);
        return null;
    };
    // Bilinear sampling is what makes the field interpolate smoothly between
    // atlas texels (point sampling would step the outline edges).
    rl.setTextureFilter(texture, .bilinear);
    // Clamp wrap so bilinear sampling at glyph rects touching the atlas
    // border can't wrap around to a distant glyph's distance field (would
    // render as outline-colored specks); the baked per-glyph margin keeps
    // interior rect-edge sampling between clamped-zero texels.
    rl.setTextureWrap(texture, .clamp);

    return .{
        .font = .{
            .baseSize = base_size,
            .glyphCount = @intCast(glyph_count),
            .glyphPadding = 0,
            .texture = texture,
            .recs = recs.ptr,
            .glyphs = glyph_infos.ptr,
        },
        .shader = shader,
        .width_location = rl.getShaderLocation(shader, "outlineWidth"),
        .color_location = rl.getShaderLocation(shader, "outlineColor"),
        .recs = recs,
        .glyphs = glyph_infos,
    };
}

fn invalidSdfBlob(why: []const u8) ?SdfTextOutline {
    std.debug.print("warning: SDF font blob invalid ({s}); outlined text falls back to the shadow ring\n", .{why});
    return null;
}

/// Collect the active font's non-ASCII glyph advances for the measurement
/// seam (see `fontMetrics`), sorted ascending by codepoint. ASCII glyphs
/// are skipped - they ride the fixed `advances` array; codepoints past
/// Unicode's range are skipped defensively (a malformed font can't crash
/// the init path).
fn collectNonAsciiAdvances(
    allocator: std.mem.Allocator,
    font: rl.Font,
) std.mem.Allocator.Error![]ui.NonAsciiAdvance {
    const count: usize = @intCast(font.glyphCount);
    var pairs: std.ArrayListUnmanaged(ui.NonAsciiAdvance) = .empty;
    errdefer pairs.deinit(allocator);
    for (font.glyphs[0..count]) |glyph| {
        const value: i32 = @intCast(glyph.value);
        if (value <= 126 or value > 0x10FFFF) continue;
        try pairs.append(allocator, .{
            .codepoint = @intCast(value),
            .advance = @intCast(glyph.advanceX),
        });
    }
    std.mem.sort(ui.NonAsciiAdvance, pairs.items, {}, struct {
        fn lessThan(_: void, a: ui.NonAsciiAdvance, b: ui.NonAsciiAdvance) bool {
            return a.codepoint < b.codepoint;
        }
    }.lessThan);
    return pairs.toOwnedSlice(allocator);
}

fn readLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

pub const TextRenderer = struct {
    /// raylib's DEFAULT bitmap font, set ONLY when the SDF pipeline failed
    /// to init (see `sdf`): legible ASCII, no outline band, straight-alpha
    /// (slightly bright under the premult blend - acceptable for this
    /// near-unreachable path). Raylib-owned memory: deinit must NOT unload
    /// it. null in the normal path.
    font: ?rl.Font = null,
    /// The SDF text pipeline - the font EVERY text draw uses when available
    /// (plain fill included; see `drawSdfText`). null → raylib's default
    /// bitmap font above (outlined text additionally degrades to the
    /// 8-direction offset-shadow ring), decided once at init and fixed for
    /// the session.
    sdf: ?SdfTextOutline = null,

    /// The allocator `non_ascii_advances` below was created with (kept so
    /// deinit, which takes no arguments, can free it).
    allocator: std.mem.Allocator,
    /// Non-ASCII glyph advances for `fontMetrics`, extracted ONCE at init
    /// from the active font's glyphs (sorted by codepoint) - the session's
    /// font is fixed at init, so the per-frame `fontMetrics()` borrows this
    /// instead of allocating. Empty in the default-font fallback (ASCII
    /// only - multibyte text measures via the 0.5em approximation). Freed
    /// in deinit.
    non_ascii_advances: []ui.NonAsciiAdvance = &.{},

    /// Assemble the SDF pipeline; ONLY on failure fall back to raylib's
    /// default bitmap font (borrowed, nothing to build or own). No TTF is
    /// read at runtime - the atlas is baked from the shipped font at build
    /// time, so a persistent-dir font shadow can never affect text.
    pub fn init(allocator: std.mem.Allocator) TextRenderer {
        const sdf = initSdfTextOutline(allocator);
        const font: ?rl.Font = if (sdf == null)
            rl.getFontDefault() catch @panic("failed to load default font")
        else
            null;
        var self = TextRenderer{
            .allocator = allocator,
            .font = font,
            .sdf = sdf,
        };
        self.non_ascii_advances = collectNonAsciiAdvances(allocator, self.activeFont()) catch &.{};
        return self;
    }

    pub fn deinit(self: *TextRenderer) void {
        if (self.sdf) |sdf| {
            // Manual teardown - NOT rl.unloadFont: the font's recs/glyphs are
            // Zig-allocator slices (raylib's free() would corrupt the heap).
            rl.unloadShader(sdf.shader);
            rl.unloadTexture(sdf.font.texture);
            self.allocator.free(sdf.recs);
            self.allocator.free(sdf.glyphs);
        }
        if (self.non_ascii_advances.len > 0) self.allocator.free(self.non_ascii_advances);
        // self.font (the default bitmap font) is raylib-owned: never unload.
    }

    /// The font every draw actually uses: the SDF font when the pipeline is
    /// available, else raylib's default bitmap font. `fontMetrics` reads from
    /// it so layout always measures with the advances the renderer draws
    /// with - whichever path is active.
    fn activeFont(self: *const TextRenderer) rl.Font {
        if (self.sdf) |sdf| return sdf.font;
        return self.font.?;
    }

    /// Extract per-glyph advance widths from the ACTIVE font (see
    /// `activeFont`) into a raylib-free `ui.FontMetrics` value, so the layout
    /// seam (`view()` + UI builders) measures text with the same advances
    /// the renderer draws with. ASCII codepoints 32..126 index `advances`;
    /// non-ASCII codepoints ride the session-lifetime `non_ascii_advances`
    /// (filled once at init - the font is fixed for the session; empty in
    /// the default-font fallback), so layout matches whichever font is
    /// active.
    pub fn fontMetrics(self: *TextRenderer) ui.FontMetrics {
        const font = self.activeFont();
        var metrics = ui.FontMetrics{
            .base_size = @intCast(font.baseSize),
            .advances = @as([95]i32, @splat(0)),
            .non_ascii = self.non_ascii_advances,
        };
        const count: usize = @intCast(font.glyphCount);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const glyph = font.glyphs[i];
            const value: i32 = @intCast(glyph.value);
            if (value >= 32 and value <= 126) {
                metrics.advances[@intCast(value - 32)] = @intCast(glyph.advanceX);
            }
        }
        return metrics;
    }

    /// Draw one string through the SDF pipeline: set the outline uniforms,
    /// then draw under the SDF shader. `outline_width` is in the drawn text's
    /// own pixel space; 0 is the PLAIN-TEXT path - the outline band
    /// collapses to nothing (with the transparent outline color the band
    /// contributes zero alpha), leaving the `fwidth`-antialiased fill, so
    /// every string in the game is resolution-independent. Never draw the
    /// SDF font without the shader: its texels are distances, not coverage,
    /// so it renders garbage raw.
    fn drawSdfText(
        sdf: SdfTextOutline,
        text: [:0]const u8,
        position: rl.Vector2,
        font_size: f32,
        spacing: f32,
        fill: rl.Color,
        outline_width: f32,
    ) void {
        // The field's distances are in BASE-atlas pixels; convert the
        // drawn-pixel width (font_size/baseSize = atlas→screen scale),
        // CLAMPED to the encodable range - see `sdf_max_outline_atlas_pixels`
        // (a request past the clamp floor renders ghost squares at the glyph
        // quad corners; a clamped request just draws a thinner outline).
        const requested_width_in_atlas_pixels = outline_width * @as(f32, @floatFromInt(sdf.font.baseSize)) / font_size;
        const width_in_atlas_pixels = @min(requested_width_in_atlas_pixels, sdf_max_outline_atlas_pixels);
        rl.setShaderValue(sdf.shader, sdf.width_location, &width_in_atlas_pixels, .float);
        // A zero width MUST pair with a transparent outline color: the band
        // collapses exactly onto the fill edge (band == fill), and an opaque
        // one would source-over-composite black into the antialiased fringe
        // (outA = 2fa - fa² - a dark, over-bright edge on every glyph).
        const outline_color = if (outline_width == 0)
            [4]f32{ 0, 0, 0, 0 }
        else
            [4]f32{ 0, 0, 0, 1 };
        rl.setShaderValue(sdf.shader, sdf.color_location, &outline_color, .vec4);
        rl.beginShaderMode(sdf.shader);
        rl.drawTextEx(sdf.font, text, position, font_size, spacing, fill);
        rl.endShaderMode();
    }

    /// Draw text with a black edge-outline of `outline_width` px (in the drawn
    /// text's own pixel space) - the SDF pipeline's fill + outline band in
    /// ONE shader-driven draw. The 8-direction offset-shadow ring (9 draws,
    /// on raylib's default bitmap font) remains the fallback for the
    /// near-unreachable case where the SDF pipeline failed to init.
    pub fn drawOutlinedText(
        self: *TextRenderer,
        text: [:0]const u8,
        position: rl.Vector2,
        font_size: f32,
        spacing: f32,
        fill: rl.Color,
        outline_width: f32,
    ) void {
        if (self.sdf) |sdf| {
            drawSdfText(sdf, text, position, font_size, spacing, fill, outline_width);
            return;
        }
        // Fallback ring: 8 black copies offset in a square ring, fill on top.
        const font = self.font.?;
        const black = toRaylibColor(.{ .r = 0, .g = 0, .b = 0 }, 255);
        const dirs = [_]struct { dx: f32, dy: f32 }{
            .{ .dx = -outline_width, .dy = -outline_width }, .{ .dx = 0, .dy = -outline_width },            .{ .dx = outline_width, .dy = -outline_width },
            .{ .dx = -outline_width, .dy = 0 },              .{ .dx = outline_width, .dy = 0 },             .{ .dx = -outline_width, .dy = outline_width },
            .{ .dx = 0, .dy = outline_width },               .{ .dx = outline_width, .dy = outline_width },
        };
        for (dirs) |d| {
            rl.drawTextEx(font, text, .{ .x = position.x + d.dx, .y = position.y + d.dy }, font_size, spacing, black);
        }
        rl.drawTextEx(font, text, position, font_size, spacing, fill);
    }

    /// Draw a UI text label. `scratch` is the caller's per-frame arena
    /// (raylib needs a null-terminated copy of the text).
    pub fn drawTextLabel(
        self: *TextRenderer,
        scratch: std.mem.Allocator,
        label: ui.TextLabel,
        theme_lightest: types.Color,
    ) void {
        // raylib needs a null-terminated string; copy into the scratch arena.
        // bold/italic are still ignored (no bold/italic faces loaded).
        // `default_tint` (pure white) is the "unset" sentinel: a text label
        // or span that didn't pick an explicit color inherits the active
        // theme's `lightest` (the artist's offwhite). Explicitly colored
        // spans pass a non-`default_tint` color and are unaffected. Sprite
        // tints (Button/Slot/Image) keep `default_tint` meaning "no tint" -
        // this substitution is text-only.
        const text = scratch.dupeSentinel(u8, label.text, 0) catch return;
        const font_size: f32 = @floatFromInt(label.font_size);
        const spacing: f32 = font_size / @as(f32, @floatFromInt(ui.glyph_spacing_font_divisor));
        const color = if (std.meta.eql(label.color, ui.default_tint)) theme_lightest else label.color;
        const pos = rl.Vector2{ .x = @floatFromInt(label.screen_position.x), .y = @floatFromInt(label.screen_position.y) };
        // Plain = the SAME SDF shader with a zero outline width - one text
        // path for everything (see `drawSdfText`); outlined = width 8 (UI is
        // drawn 1:1 at reference resolution into the render target, so the
        // width needs no world_scale). Fallback (SDF init failed): raylib's
        // default bitmap font, plain drawTextEx / shadow ring respectively.
        if (label.outlined) {
            self.drawOutlinedText(text, pos, font_size, spacing, toRaylibColor(color, 255), @floatFromInt(text_outline_thickness));
        } else if (self.sdf) |sdf| {
            drawSdfText(sdf, text, pos, font_size, spacing, toRaylibColor(color, 255), 0);
        } else {
            rl.drawTextEx(self.font.?, text, pos, font_size, spacing, toRaylibColor(color, 255));
        }
    }
};
