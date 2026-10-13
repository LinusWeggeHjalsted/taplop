//! Text subsystem of the raylib backend: ALL text draws through the SDF
//! pipeline (plain fill = the same shader with a zero outline width — see
//! `drawSdfText`), with the runtime coverage-atlas font (the pre-SDF text
//! path) kept ONLY as the fallback when the SDF pipeline fails to init, and
//! the SDF text-outline blob+shader (build-time blob; shadow-ring fallback
//! on the fallback font). The backend keeps `fontMetrics` as a thin wrapper
//! (main.zig's RenderContext seam) and passes its frame arena as the
//! per-frame scratch to the draw fns. See DESIGN → Platform Seam → SDF text
//! outline.

const std = @import("std");
const rl = @import("raylib");
const types = @import("../types.zig");
const ui = @import("../ui.zig");
const transient_allocator = @import("../transient_allocator.zig");
const conversions = @import("conversions.zig");
const textures_mod = @import("textures.zig");

const toRaylibColor = conversions.toRaylibColor;

/// Base rasterization size for the TTF font. Both the build-time SDF blob
/// and the runtime coverage-atlas fallback bake glyphs at this size;
/// `drawTextEx` scales from it. Sized to cover the largest `font_size` in
/// use (96, menu buttons); the fallback atlas is bilinear-filtered so its
/// downscaled draws stay smooth (the SDF pipeline needs no such raster —
/// its AA is analytic). This is a runtime GPU/texture memory cost, not
/// binary size (only the raw ~12 KB TTF bytes are embedded).
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
/// in build.zig — the fragment shader decodes the field assuming this value,
/// and `initSdfTextOutline` validates the blob's baked params against it
/// (mismatch → warning + shadow-ring fallback). 128/6 ≈ ±21 atlas px of
/// range. The range is NOT sufficient for every requested outline — see
/// `sdf_max_outline_atlas_pixels` (drawSdfText clamps) — it covers an 8px
/// outline at 56px+ (8*128/56 ≈ 18 atlas px, clear of the clamp floor).
const sdf_pixel_dist_scale: f32 = 6.0;

/// SDF glyph raster margin around each glyph bbox, in atlas pixels. MUST
/// match `-DFONT_SDF_CHAR_PADDING` on the generator's raylib dependency
/// in build.zig (baked into the blob, validated at parse). Must be ≥ the
/// encoding range (±21 px) so the distance field isn't cropped at the glyph
/// rect edge — the outline band would clamp there otherwise.
const sdf_char_padding: i32 = 22;

/// Maximum outline width the atlas can actually encode, in atlas px.
/// `drawSdfText` clamps the requested width to this. WHY: the field clamps
/// at −(128/scale) ≈ −21.3, and the shader fades the band over the window
/// [−W−aa, −W+aa] — a request whose window dips to the clamp floor makes
/// every clamped texel evaluate band ≈ 0.5. Clamped texels are exactly the
/// rect-CORNER diagonals (true distance to the ink runs ~30px there while
/// the rect is only 22px padded per axis), so the result is ghost squares
/// at each glyph quad's corners — seen on the 48px material-count labels
/// (8*128/48 ≈ 21.3, right AT the floor). The −2 margin covers the fwidth
/// window at the smallest outlined size on the smallest render target
/// (~1.1 d-units at 48px on a 720p target); clamped requests draw a
/// marginally thinner outline (7.2px instead of 8 at 48px) — never squares.
const sdf_max_outline_atlas_pixels: f32 = 128.0 / sdf_pixel_dist_scale - 2.0;

comptime {
    if (sdf_pixel_dist_scale != 6.0 or sdf_char_padding != 22) {
        @compileError("SDF constants changed — update the matching -DFONT_SDF_* defines in build.zig (generator raylib dep), tools/sdf_atlas_generator.zig's baked_* constants, and the /6.0 decode in the sdf_outline_fs_* shaders");
    }
}

/// Fragment shader for the SDF text outline, desktop GL (GLSL 3.30; same
/// structure as raylib's text_font_sdf example). Decodes the distance
/// field, builds an antialiased fill (inside the glyph edge) and outline
/// band (within `outlineWidth` atlas px outside the edge), composites the
/// outline under the fill (source-over), and outputs PREMULTIPLIED alpha
/// for the render pass's `BLEND_ALPHA_PREMULTIPLY` blend (the RGB is already
/// scaled by outA — no straight-alpha division). `fwidth` sizes the
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

/// WebGL variant (GLSL ES 3.00 — the web context is WebGL 2, requested via
/// `opengl_version = .gles_3` on the web raylib dependency in build.zig;
/// see DESIGN → Platform Seam → WebGL 2). Same math as the desktop variant,
/// including `fwidth`-sized antialiasing (GLSL ES 3.00 has derivatives).
/// Highp floats: the decoded field spans ±21 and the AA band is a small
/// `fwidth` delta — mediump's 10-bit mantissa would visibly band it.
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

/// Load the FALLBACK font — only called when the SDF pipeline failed to
/// init (see `TextRenderer.init`); the normal path never builds this
/// atlas. Reads the embedded TTF (`assets/fonts/freezilla.ttf`) through
/// the FileSource and rasterizes a glyph atlas at `font_base_size`.
/// The atlas is built ENTIRELY ON THE CPU (`loadFontData` →
/// `genImageFontAtlas`) so it can be PREMULTIPLIED before upload — text
/// composites correctly under the render pass's `BLEND_ALPHA_PREMULTIPLY`
/// blend. A GPU-readback premultiply (`loadImageFromTexture` →
/// `updateTexture`) is NOT portable: raylib's GL readback always returns
/// RGBA (`glReadPixels` with GL_RGBA) regardless of the texture's
/// GRAY_ALPHA format, and re-uploading 4bpp data to the 2bpp texture
/// garbles the atlas (observed on web — blank/garbled glyphs in panels).
/// Mirrors raylib's `LoadFontFromMemory` (95 default ASCII glyphs, padding
/// 4 = FONT_TTF_DEFAULT_CHARS_PADDING, pack method 0) minus the per-glyph
/// sub-image refresh (only needed for ImageDrawText, which we never use).
/// The assembled Font's glyphs/recs are C-allocated by the raylib calls, so
/// `rl.unloadFont` frees them correctly (see deinit).
///
/// On any failure (missing file, decode error) falls back to raylib's
/// default bitmap font so the game stays playable — the recoverable-error
/// policy applies because a persistent-dir shadow
/// (`~/.ziglop/assets/fonts/...`) can break the read at runtime. The
/// default font is left straight-alpha (rendering too bright under premult
/// blend) — acceptable for this near-unreachable fallback; its atlas is
/// raylib-owned and can't be rebuilt on the CPU. Returns the font + whether
/// it is the default (so deinit can skip unloading raylib-owned the
/// default).
fn loadFont(file_source: *const @import("../file_source.zig").FileSource) struct { font: rl.Font, is_default: bool } {
    const bytes = file_source.readFile(transient_allocator.allocator, "assets/fonts/freezilla.ttf") catch |err| {
        std.debug.print("warning: failed to load font ({}); falling back to default\n", .{err});
        const fallback = rl.getFontDefault() catch @panic("failed to load default font");
        return .{ .font = fallback, .is_default = true };
    };
    defer transient_allocator.allocator.free(bytes);

    // Decode glyph rasterizations (95 default ASCII glyphs — the same set
    // LoadFontFromMemory's null-codepoints path uses). C-owned; freed by
    // `unloadFontData` (via unloadFont on success, or explicitly on error).
    const glyphs = rl.loadFontData(bytes, font_base_size, null, .default) catch {
        std.debug.print("warning: failed to decode font; falling back to default\n", .{});
        const fallback = rl.getFontDefault() catch @panic("failed to load default font");
        return .{ .font = fallback, .is_default = true };
    };

    // Build the atlas on the CPU. GenImageFontAtlas produces a GRAY_ALPHA
    // image (gray = color, alpha = coverage); premultiply in that native
    // format (gray = gray*alpha/255). C-owned recs; freed by unloadFont.
    const glyph_padding: i32 = 4; // FONT_TTF_DEFAULT_CHARS_PADDING
    const built = rl.genImageFontAtlas(glyphs, font_base_size, glyph_padding, 0) catch {
        rl.unloadFontData(glyphs);
        std.debug.print("warning: failed to build font atlas; falling back to default\n", .{});
        const fallback = rl.getFontDefault() catch @panic("failed to load default font");
        return .{ .font = fallback, .is_default = true };
    };
    var atlas_image = built[0];
    const recs = built[1];
    defer rl.unloadImage(atlas_image);

    switch (atlas_image.format) {
        .uncompressed_gray_alpha => {
            const w: usize = @intCast(atlas_image.width);
            const h: usize = @intCast(atlas_image.height);
            if (w > 0 and h > 0) {
                const px: [*]u8 = @ptrCast(atlas_image.data);
                for (0..w * h) |i| {
                    const a: u16 = px[i * 2 + 1];
                    px[i * 2] = @intCast((@as(u16, px[i * 2]) * a + 127) / 255);
                }
            }
        },
        .uncompressed_r8g8b8a8 => textures_mod.premultiplyAlpha(&atlas_image),
        else => std.debug.print("warning: font atlas has unexpected format {}; text may render slightly dark\n", .{atlas_image.format}),
    }

    const texture = rl.loadTextureFromImage(atlas_image) catch {
        // recs is C-allocated with no zig-facing free fn — it leaks on this
        // rare once-per-process failure path. Glyphs are freed explicitly.
        rl.unloadFontData(glyphs);
        std.debug.print("warning: failed to upload font atlas; falling back to default\n", .{});
        const fallback = rl.getFontDefault() catch @panic("failed to load default font");
        return .{ .font = fallback, .is_default = true };
    };
    // Bilinear so downscaling from the base size to smaller `font_size`s is
    // smooth (matches the reference->window blit). Upcasting would blur, but
    // no size in use exceeds `font_base_size`.
    rl.setTextureFilter(texture, .bilinear);

    return .{ .font = .{
        .baseSize = font_base_size,
        .glyphCount = @intCast(glyphs.len),
        .glyphPadding = glyph_padding,
        .texture = texture,
        .recs = recs.ptr,
        .glyphs = glyphs.ptr,
    }, .is_default = false };
}

/// The SDF text pipeline (see `drawSdfText`): a glyph atlas whose texels
/// encode signed distance-to-glyph-edge (instead of coverage) plus the
/// fragment shader that thresholds the field into fill + outline band —
/// the ONE font every text draw uses (plain fill included, at outline
/// width 0). Built once at init from the build-time blob (see
/// `initSdfTextOutline`); null means unavailable (blob invalid, texture
/// upload, or shader compile failed) and ALL text falls back to the
/// coverage-atlas font (outlined text additionally to the offset-shadow
/// ring). All-or-nothing by construction: an SDF atlas drawn without the
/// shader renders raw distances (garbage), a shader without the atlas is
/// useless.
///
/// Ownership: `recs`/`glyphs` are Zig-allocator slices that the assembled
/// `font`'s C pointers alias — deinit frees them directly and must NOT call
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
/// sdf_atlas_generator.zig, embedded via the `generated_sdf_font` module —
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
/// Every failure logs a warning and returns null (the ring fallback keeps
/// outlined text working). A persistent-dir font shadow does NOT affect
/// outlined text (the blob is baked from the shipped TTF at build time).
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
        return invalidSdfBlob("encoding mismatch — regenerate the blob (build.zig generator) with matching constants");
    if (glyph_count == 0 or glyph_count > 1024) return invalidSdfBlob("glyph count out of range");
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

fn readLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

pub const TextRenderer = struct {
    /// FALLBACK font, built ONLY when the SDF pipeline failed to init (see
    /// `sdf`): the embedded TTF as a runtime coverage atlas — the pre-SDF
    /// text path, kept for the failure case (broken blob / texture upload /
    /// shader compile). null in the normal path, which never pays its build
    /// or VRAM. Normally the embedded TTF; falls back to raylib's default
    /// bitmap font if the TTF is missing or fails to load (e.g. a broken
    /// persistent-dir shadow). `font_is_default` tracks that fallback so
    /// deinit skips unloading raylib-owned memory.
    font: ?rl.Font = null,
    font_is_default: bool = false,
    /// The SDF text pipeline — the font EVERY text draw uses when available
    /// (plain fill included; see `drawSdfText`). null → the coverage-atlas
    /// fallback font above (outlined text additionally degrades to the
    /// 8-direction offset-shadow ring), decided once at init and fixed for
    /// the session.
    sdf: ?SdfTextOutline = null,

    /// Assemble the SDF pipeline first; the coverage-atlas fallback font is
    /// built ONLY when that fails. Neither failure is hard: a broken SDF
    /// pipeline falls back to the coverage font (plus the shadow ring for
    /// outlined text), a broken TTF below that falls back to raylib's
    /// default — the game stays playable.
    pub fn init(
        allocator: std.mem.Allocator,
        file_source: *const @import("../file_source.zig").FileSource,
    ) TextRenderer {
        const sdf = initSdfTextOutline(allocator);
        var font: ?rl.Font = null;
        var font_is_default = false;
        if (sdf == null) {
            const loaded = loadFont(file_source);
            font = loaded.font;
            font_is_default = loaded.is_default;
        }
        return .{
            .font = font,
            .font_is_default = font_is_default,
            .sdf = sdf,
        };
    }

    pub fn deinit(self: *TextRenderer) void {
        if (self.sdf) |sdf| {
            // Manual teardown — NOT rl.unloadFont: the font's recs/glyphs are
            // Zig-allocator slices (raylib's free() would corrupt the heap).
            rl.unloadShader(sdf.shader);
            rl.unloadTexture(sdf.font.texture);
        }
        if (self.font) |font| {
            if (!self.font_is_default) rl.unloadFont(font);
        }
    }

    /// The font every draw actually uses: the SDF font when the pipeline is
    /// available, else the coverage-atlas fallback. `fontMetrics` reads from
    /// it so layout always measures with the advances the renderer draws
    /// with — whichever path is active.
    fn activeFont(self: *const TextRenderer) rl.Font {
        if (self.sdf) |sdf| return sdf.font;
        return self.font.?;
    }

    /// Extract per-glyph advance widths from the ACTIVE font (see
    /// `activeFont`) into a raylib-free `ui.FontMetrics` value, so the layout
    /// seam (`view()` + UI builders) measures text with the same advances
    /// the renderer draws with. ASCII codepoints 32..126 index `font.glyphs`;
    /// missing glyphs keep the zero-init advance (the 0.5em fallback handles
    /// them in `measureSpanWidth`). Uniform across the SDF font, the TTF
    /// fallback, and the default-font fallback, so layout matches whichever
    /// font is active.
    pub fn fontMetrics(self: *TextRenderer) ui.FontMetrics {
        const font = self.activeFont();
        var metrics = ui.FontMetrics{
            .base_size = @intCast(font.baseSize),
            .advances = [_]i32{0} ** 95,
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
    /// own pixel space; 0 is the PLAIN-TEXT path — the outline band
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
        // CLAMPED to the encodable range — see `sdf_max_outline_atlas_pixels`
        // (a request past the clamp floor renders ghost squares at the glyph
        // quad corners; a clamped request just draws a thinner outline).
        const requested_width_in_atlas_pixels = outline_width * @as(f32, @floatFromInt(sdf.font.baseSize)) / font_size;
        const width_in_atlas_pixels = @min(requested_width_in_atlas_pixels, sdf_max_outline_atlas_pixels);
        rl.setShaderValue(sdf.shader, sdf.width_location, &width_in_atlas_pixels, .float);
        // A zero width MUST pair with a transparent outline color: the band
        // collapses exactly onto the fill edge (band == fill), and an opaque
        // one would source-over-composite black into the antialiased fringe
        // (outA = 2fa - fa² — a dark, over-bright edge on every glyph).
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
    /// text's own pixel space) — the SDF pipeline's fill + outline band in
    /// ONE shader-driven draw. The 8-direction offset-shadow ring (9 draws,
    /// on the coverage-atlas fallback font) remains the fallback for
    /// environments where the SDF pipeline failed to init.
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
        // tints (Button/Slot/Image) keep `default_tint` meaning "no tint" —
        // this substitution is text-only.
        const text = scratch.dupeZ(u8, label.text) catch return;
        const font_size: f32 = @floatFromInt(label.font_size);
        const spacing: f32 = font_size / @as(f32, @floatFromInt(ui.glyph_spacing_font_divisor));
        const color = if (std.meta.eql(label.color, ui.default_tint)) theme_lightest else label.color;
        const pos = rl.Vector2{ .x = @floatFromInt(label.screen_position.x), .y = @floatFromInt(label.screen_position.y) };
        // Plain = the SAME SDF shader with a zero outline width — one text
        // path for everything (see `drawSdfText`); outlined = width 8 (UI is
        // drawn 1:1 at reference resolution into the render target, so the
        // width needs no world_scale). Fallback (SDF init failed): the
        // coverage-atlas font, plain drawTextEx / shadow ring respectively.
        if (label.outlined) {
            self.drawOutlinedText(text, pos, font_size, spacing, toRaylibColor(color, 255), @floatFromInt(text_outline_thickness));
        } else if (self.sdf) |sdf| {
            drawSdfText(sdf, text, pos, font_size, spacing, toRaylibColor(color, 255), 0);
        } else {
            rl.drawTextEx(self.font.?, text, pos, font_size, spacing, toRaylibColor(color, 255));
        }
    }
};
