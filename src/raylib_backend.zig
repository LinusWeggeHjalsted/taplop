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
//! (design) resolution (types.reference_width x types.reference_height = 4K).
//! We draw it into a RenderTexture at a SEPARATE, possibly smaller render
//! target resolution (types.render_width/height, build option, default 1080p)
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
const input = @import("input.zig");
const types = @import("types.zig");
const ui = @import("ui.zig");
const transient_allocator = @import("transient_allocator.zig");

const reference_width_int: i32 = types.reference_width;
const reference_height_int: i32 = types.reference_height;
const reference_width: f32 = @floatFromInt(reference_width_int);
const reference_height: f32 = @floatFromInt(reference_height_int);
// Offscreen render target dims (build option, default 1920×1080) + the
// uniform camera zoom that scales 4K design-space draws into the target.
// See DESIGN → Platform Seam → Render target resolution.
const render_width_int: i32 = types.render_width;
const render_height_int: i32 = types.render_height;
const render_width: f32 = @floatFromInt(render_width_int);
const render_height: f32 = @floatFromInt(render_height_int);
const render_scale: f32 = render_width / reference_width;

/// Base rasterization size for the TTF font. raylib bakes glyphs into an
/// atlas at this fixed size; `drawTextEx` scales from it. Sized to cover the
/// largest `font_size` in use (96, menu buttons) with a modest supersample,
/// so all current sizes render crisp; the atlas texture is bilinear-filtered
/// so downscaling to smaller sizes stays smooth. This is a runtime GPU/texture
/// memory cost, not binary size (only the raw ~12 KB TTF bytes are embedded).
const font_base_size: i32 = 128;

/// Edge-highlight outline thickness in source pixels (OUTER band sitting
/// just outside the sprite silhouette). Drawn via a precomputed outline mask
/// (see `getOutlineTexture`); reused by the occlusion inset (see
/// `getInsetOutlineTexture`). Tune from in-game viewing.
const outline_thickness: i32 = 8;

/// Text-field caret bar thickness (reference px) — matches the unified
/// outline thickness so the caret reads at the same visual weight as the
/// world outlines.
const caret_width: i32 = 8;

/// Which side of the silhouette an outline mask sits on. OUTER = the band
/// of transparent pixels within `thickness` of an opaque pixel (a halo
/// outside the silhouette, used by highlighted UI). INNER = the morphological
/// dual: opaque pixels within `thickness` of a transparent pixel (a rim
/// just inside the silhouette, used by the occlusion inset). See
/// `generateOutlineMask` and DESIGN → Decorations & Footprint → Occlusion inset.
const OutlineSide = enum { outer, inner };

/// One (dx, dy) offset in a disk structuring element (see
/// `generateOutlineMask`). Small enough that a slice of these is the disk.
const DiskOffset = struct { dx: i32, dy: i32 };

/// Outline thickness for floating TEXT overlays (damage/heal numbers) and
/// outlined UI text labels: the black edge-outline width, in the drawn
/// text's own pixel space. Rendered by the SDF text-outline pipeline (see
/// `SdfTextOutline`) with the 8-direction offset-shadow ring as fallback
/// (see `drawOutlinedText`). Tune from in-game viewing.
const text_outline_thickness: i32 = 8;

/// SDF text-outline encoding scale: the build-time atlas generator (tools/
/// sdf_atlas_generator.zig) bakes each atlas texel as `alpha = 128 +
/// sdf_pixel_dist_scale * distance_px` (clamped 0..255), distance in ATLAS
/// pixels from the glyph edge (positive inside). MUST match the
/// `-DFONT_SDF_PIXEL_DIST_SCALE` define on the generator's raylib dependency
/// in build.zig — the fragment shader decodes the field assuming this value,
/// and `initSdfTextOutline` validates the blob's baked params against it
/// (mismatch → warning + shadow-ring fallback). 128/6 ≈ ±21 atlas px of
/// range, covering an 8px outline at the smallest outlined font size
/// (48 drawn from the 128px base atlas: 8 * 128/48 ≈ 21.3 atlas px).
const sdf_pixel_dist_scale: f32 = 6.0;

/// SDF glyph raster margin around each glyph bbox, in atlas pixels. MUST
/// match `-DFONT_SDF_CHAR_PADDING` on the generator's raylib dependency in
/// build.zig (baked into the blob, validated at parse). Must be ≥ the
/// encoding range (±21 px) so the distance field isn't cropped at the glyph
/// rect edge — the outline band would clamp there otherwise.
const sdf_char_padding: i32 = 22;

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

/// WebGL variant (GLSL ES 1.00 — valid in both WebGL1 and WebGL2 contexts).
/// Same math, but GLSL ES 1.00 has no `fwidth`, so the antialias band is a
/// fixed smoothing constant (in field-alpha units; 1/32 ≈ 1.3 atlas px).
const sdf_outline_fs_glsl100 =
    \\#version 100
    \\precision mediump float;
    \\varying vec2 fragTexCoord;
    \\varying vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform float outlineWidth;
    \\uniform vec4 outlineColor;
    \\const float smoothing = 1.0/32.0;
    \\void main()
    \\{
    \\    float dist = texture2D(texture0, fragTexCoord).a;
    \\    float fill = smoothstep(0.5 - smoothing, 0.5 + smoothing, dist);
    \\    float outlineEdge = 0.5 - outlineWidth*6.0/255.0;
    \\    float band = smoothstep(outlineEdge - smoothing, outlineEdge + smoothing, dist);
    \\    float fa = fill*fragColor.a;
    \\    float ba = band*outlineColor.a;
    \\    float outA = fa + ba*(1.0 - fa);
    \\    vec3 outRGB = fragColor.rgb*fa + outlineColor.rgb*ba*(1.0 - fa);
    \\    gl_FragColor = vec4(outRGB, outA);
    \\}
;

/// The shader source for this build target: GLSL 1.00 on web (emscripten),
/// GLSL 3.30 on desktop.
const sdf_outline_fs_source: [:0]const u8 = if (@import("builtin").target.cpu.arch == .wasm32)
    sdf_outline_fs_glsl100
else
    sdf_outline_fs_glsl330;

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
    .{ .key = .n, .id = "KeyN" },
    .{ .key = .page_up, .id = "PageUp" },
    .{ .key = .page_down, .id = "PageDown" },
    .{ .key = .g, .id = "KeyG" },
    .{ .key = .s, .id = "KeyS" },
    .{ .key = .a, .id = "KeyA" },
    .{ .key = .d, .id = "KeyD" },
    .{ .key = .e, .id = "KeyE" },
    .{ .key = .m, .id = "KeyM" },
    .{ .key = .l, .id = "KeyL" },
    .{ .key = .escape, .id = "Escape" },
    .{ .key = .enter, .id = "Enter" },
    .{ .key = .backspace, .id = "Backspace" },
    .{ .key = .delete, .id = "Delete" },
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

/// Like `viewTransform` but for the render-target → window blit (the
/// offscreen target is `render_width × render_height`, not the 4K reference).
/// The pointer transform (`viewTransform`) stays reference-based — the game
/// thinks in 4K design space — so these differ when the render target is
/// smaller than reference. They share the same aspect ratio (16:9, comptime-
/// checked in types.zig), so the on-screen content is identical; only the
/// intermediate pixel count changes. See DESIGN → Platform Seam → Render
/// target resolution.
fn blitTransform() ViewTransform {
    const window_width: f32 = @floatFromInt(rl.getScreenWidth());
    const window_height: f32 = @floatFromInt(rl.getScreenHeight());
    const scale = @min(window_width / render_width, window_height / render_height);
    return .{
        .scale = scale,
        .offset_x = (window_width - render_width * scale) / 2,
        .offset_y = (window_height - render_height * scale) / 2,
    };
}

/// Load the game font. Reads the embedded TTF (`assets/fonts/freezilla.ttf`)
/// through the FileSource and rasterizes a glyph atlas at `font_base_size`.
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
fn loadFont(file_source: *const @import("file_source.zig").FileSource) struct { font: rl.Font, is_default: bool } {
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
        .uncompressed_r8g8b8a8 => RaylibBackend.premultiplyAlpha(&atlas_image),
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

/// The SDF text-outline pipeline (see `drawOutlinedText`): a glyph atlas
/// whose texels encode signed distance-to-glyph-edge (instead of coverage)
/// plus the fragment shader that thresholds the field into fill + outline
/// band. Built once at init from the build-time blob (see
/// `initSdfTextOutline`); null means unavailable (blob invalid, texture
/// upload, or shader compile failed) and outlined text falls back to the
/// offset-shadow ring. All-or-nothing by construction: an SDF atlas drawn
/// without the shader renders raw distances (garbage), a shader without the
/// atlas is useless.
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
    /// stack-key -> precomputed INNER outline mask texture for a COMPOSITED
    /// silhouette (entity base + layers + weapons, flag pole + banner frame,
    /// or a single ground-items sprite). Keyed by a string built from the
    /// stack's sprite ids + flips + source rects + frame size, so two
    /// entities with the same loadout share one mask. Generated lazily by
    /// `ensureCompositeInsetLoaded` on the first `getCompositeInsetTexture`
    /// request. Used by the occlusion inset pass — see DESIGN → Decorations &
    /// Footprint → Occlusion inset.
    composite_inset_cache: std.StringHashMapUnmanaged(?rl.Texture2D) = .empty,
    /// sprite_id -> opaque-pixel bounding box (top/bottom/left/right, in
    /// SOURCE pixels), generated lazily by `ensureSpriteBoundsLoaded` on the
    /// first `getSpriteBounds` request (same shape as `outline_cache`). A
    /// cached `null` means the sprite is missing (or the scan failed) -> the
    /// caller falls back to the frame edges. Used by `view()` to place
    /// overlays against an entity's actual rendered art. See DESIGN →
    /// Animation.
    sprite_bounds_cache: std.StringHashMapUnmanaged(?types.SpriteBounds) = .empty,
    /// Reference-resolution offscreen target; blitted to the window each frame.
    render_target: rl.RenderTexture2D,
    /// Text-label font. Normally the embedded TTF (loaded from
    /// `assets/fonts/freezilla.ttf` via the FileSource); falls back to
    /// raylib's default bitmap font if the TTF is missing or fails to load
    /// (e.g. a broken persistent-dir shadow). `font_is_default` tracks the
    /// fallback so deinit skips unloading raylib-owned the default.
    font: rl.Font,
    font_is_default: bool,
    /// SDF text-outline pipeline for outlined text (see `drawOutlinedText`).
    /// null → the 8-direction offset-shadow ring fallback, decided once at
    /// init and fixed for the session.
    sdf: ?SdfTextOutline = null,
    /// Transient per-frame allocations (null-terminated strings for raylib,
    /// asset paths). Reset at the start of every render.
    frame_arena: std.heap.ArenaAllocator,
    /// Scratch for the events emitted by pollInput each frame. Valid only until
    /// the next pollInput; translateInput consumes it synchronously.
    event_buffer: [max_events_per_frame]input.PlatformInputEvent = undefined,
    /// Scratch for the UTF-8 text characters drained from the platform
    /// char queue each pollInput (see PlatformInput.text_characters). Same
    /// lifetime as `event_buffer`.
    char_buffer: [64]u8 = undefined,
    /// Unified file source for asset bytes (embedded map / persistent dir).
    /// The texture cache loads via loadImageFromMemory from this instead of
    /// touching the filesystem directly — see DESIGN → File System & IO.
    file_source: *const @import("file_source.zig").FileSource,

    /// One-shot sound effects, one per `SoundId`, loaded via
    /// `loadWaveFromMemory` + `loadSoundFromWave` from the file source.
    /// Missing audio is a normal in-progress state (like missing sprites) ->
    /// cache null and skip play. See DESIGN → Audio.
    sound_cache: std.AutoHashMapUnmanaged(types.SoundId, ?rl.Sound) = .empty,
    /// The always-on ambient music stream, loaded via
    /// `loadMusicStreamFromMemory`. null if the audio device isn't ready or
    /// the asset failed to load. Looping; updated each frame by
    /// `updateMusic`. See DESIGN → Audio.
    music: ?rl.Music = null,
    /// The raw OGG bytes backing `music`. raylib's `LoadMusicStreamFromMemory`
    /// (stb_vorbis) keeps a POINTER to the passed buffer (no internal copy),
    /// so the bytes must outlive the stream — freed in `deinitAudio` alongside
    /// the music unload. null when no music loaded.
    music_data: ?[]const u8 = null,
    /// Whether `initAudio` succeeded in opening the audio device. If false,
    /// all audio methods no-op (the game runs silent, never crashes).
    audio_ready: bool = false,

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

        const render_target = rl.loadRenderTexture(render_width_int, render_height_int) catch
            @panic("failed to create render target");
        // Smooth the universal reference(4K) -> window blit. raylib defaults
        // textures to point (nearest-neighbor) filtering, which on the
        // downscale turns smooth alpha edges into jagged chunky boundaries
        // (every content layer passes through this blit). Bilinear fixes the
        // transparent-edge artifact at no per-frame cost.
        rl.setTextureFilter(render_target.texture, .bilinear);
        const font = loadFont(file_source);
        const sdf = initSdfTextOutline(allocator);

        return .{
            .allocator = allocator,
            .render_target = render_target,
            .font = font.font,
            .font_is_default = font.is_default,
            .sdf = sdf,
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
        var composite_insets = self.composite_inset_cache.valueIterator();
        while (composite_insets.next()) |maybe_texture| {
            if (maybe_texture.*) |texture| rl.unloadTexture(texture);
        }
        self.composite_inset_cache.deinit(self.allocator);
        self.sprite_bounds_cache.deinit(self.allocator);
        self.deinitAudio();
        if (self.sdf) |sdf| {
            // Manual teardown — NOT rl.unloadFont: the font's recs/glyphs are
            // Zig-allocator slices (raylib's free() would corrupt the heap).
            rl.unloadShader(sdf.shader);
            rl.unloadTexture(sdf.font.texture);
            self.allocator.free(sdf.recs);
            self.allocator.free(sdf.glyphs);
        }
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

    /// Open the audio device and load all sfx + the music stream from the
    /// file source. Called once after construction (settings are available).
    /// Idempotent: a second call when already ready no-ops. If the audio
    /// device can't open, `audio_ready` stays false and all audio methods
    /// no-op — the game runs silent, never crashes. See DESIGN → Audio.
    pub fn initAudio(self: *RaylibBackend, settings: types.Settings) void {
        if (self.audio_ready) return;
        rl.initAudioDevice();
        if (!rl.isAudioDeviceReady()) return;
        self.audio_ready = true;

        // Load + start the music stream FIRST (looping). raylib's stb_vorbis
        // keeps a POINTER to the buffer (no copy), so the bytes must outlive
        // the stream — hold them in `music_data`, freed in `deinitAudio`.
        // Loading music before sfx: LoadSoundFromWave converts to the device
        // format, and the music stream's setup must happen first so the sfx
        // conversion targets the right state.
        const music_path = "assets/audio/music/ambient.ogg";
        if (self.file_source.readFile(self.allocator, music_path)) |bytes| {
            if (rl.loadMusicStreamFromMemory(".ogg", bytes) catch null) |music_value| {
                var music = music_value;
                music.looping = true;
                self.music = music;
                self.music_data = bytes;
                rl.playMusicStream(music);
            } else {
                self.allocator.free(bytes);
            }
        } else |_| {}

        // Load every sfx AFTER the music stream is set up. A missing/unreadable
        // file caches null (the game continues silent for that sound).
        for (std.meta.tags(types.SoundId)) |sound| {
            self.ensureSoundLoaded(sound);
        }

        self.applyVolumes(settings);
    }

    /// Load a single sfx from the file source into the sound cache. Caches
    /// null on miss/failure (idempotent via cache presence).
    fn ensureSoundLoaded(self: *RaylibBackend, sound: types.SoundId) void {
        if (self.sound_cache.contains(sound)) return;
        const stem = soundFileName(sound);
        const path = std.fmt.allocPrintSentinel(
            self.frame_arena.allocator(),
            "assets/audio/sfx/{s}.ogg",
            .{stem},
            0,
        ) catch @panic("failed to build sfx path");
        const loaded: ?rl.Sound = blk: {
            const bytes = self.file_source.readFile(self.allocator, path) catch
                break :blk null;
            defer self.allocator.free(bytes);
            const wave = rl.loadWaveFromMemory(".ogg", bytes) catch break :blk null;
            defer rl.unloadWave(wave);
            const s = rl.loadSoundFromWave(wave);
            if (!rl.isSoundValid(s)) break :blk null;
            break :blk s;
        };
        self.sound_cache.put(self.allocator, sound, loaded) catch
            @panic("failed to cache sound");
    }

    /// The on-disk stem for a `SoundId` (matches the file names under
    /// `assets/audio/sfx/`).
    fn soundFileName(sound: types.SoundId) []const u8 {
        return switch (sound) {
            .move => "move",
            .weapon_swing => "weapon_swing",
            .spell => "spell",
            .damage => "damage",
            .pickup => "pickup",
            .skip => "skip",
            .equip => "equip",
            .learn_skill => "learn_skill",
            .salvage => "salvage",
            .swap_skill => "swap_skill",
            .button_click_down => "button_click_down",
            .button_click_up => "button_click_up",
            .menu => "menu",
            .defeat => "defeat",
            .mission_completion => "mission_completion",
        };
    }

    /// Tear down audio: stop + unload music, unload all sfx, close the audio
    /// device. Safe to call when audio was never initialized (no-op).
    pub fn deinitAudio(self: *RaylibBackend) void {
        if (!self.audio_ready) return;
        if (self.music) |music| {
            rl.stopMusicStream(music);
            rl.unloadMusicStream(music);
            self.music = null;
        }
        if (self.music_data) |bytes| {
            self.allocator.free(bytes);
            self.music_data = null;
        }
        var sounds = self.sound_cache.valueIterator();
        while (sounds.next()) |maybe_sound| {
            if (maybe_sound.*) |sound| rl.unloadSound(sound);
        }
        self.sound_cache.deinit(self.allocator);
        rl.closeAudioDevice();
        self.audio_ready = false;
    }

    /// Apply music + sfx volumes from settings. Sfx volume is applied per-play
    /// (see `playSounds`); this sets the music stream volume. Master scales
    /// both. Volumes are u32 0–100 in Settings; converted to f32 0.0–1.0
    /// here at the raylib seam. No-op when audio isn't ready. See DESIGN → UI
    /// Framework → Settings screen (Volume integer migration).
    pub fn applyVolumes(self: *RaylibBackend, settings: types.Settings) void {
        if (!self.audio_ready) return;
        if (self.music) |music| {
            const master = @as(f32, @floatFromInt(settings.master_volume)) / 100.0;
            const music_vol = @as(f32, @floatFromInt(settings.music_volume)) / 100.0;
            rl.setMusicVolume(music, music_vol * master);
        }
    }

    /// Play all queued one-shot sounds (drained from `SessionState`), each at
    /// `sfx_volume * master_volume`. Volumes are u32 0–100 in Settings;
    /// converted to f32 0.0–1.0 here at the raylib seam. Missing sounds
    /// (cached null) are skipped. No-op when audio isn't ready. See DESIGN →
    /// Audio.
    pub fn playSounds(self: *RaylibBackend, sounds: []const types.SoundId, settings: types.Settings) void {
        if (!self.audio_ready) return;
        const master = @as(f32, @floatFromInt(settings.master_volume)) / 100.0;
        const sfx_vol = @as(f32, @floatFromInt(settings.sound_effects_volume)) / 100.0;
        const volume = sfx_vol * master;
        for (sounds) |sound| {
            if (self.sound_cache.get(sound)) |maybe_loaded| {
                if (maybe_loaded) |loaded| {
                    rl.setSoundVolume(loaded, volume);
                    rl.playSound(loaded);
                }
            }
        }
    }

    /// Advance the music stream each frame. Must be called every frame the
    /// game runs (raylib requires it for streaming audio). No-op when audio
    /// isn't ready or music failed to load.
    pub fn updateMusic(self: *RaylibBackend) void {
        if (!self.audio_ready) return;
        if (self.music) |music| rl.updateMusicStream(music);
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

        // Text characters: drain the platform char queue (the text-input /
        // IME path — distinct from key edges) into UTF-8. Drained
        // unconditionally so the queue can't back up between frames;
        // consumers only read it while a text field is focused. Read before
        // the pump like the wheel (the queue accumulates between polls).
        var char_count: usize = 0;
        while (char_count < self.char_buffer.len) {
            const codepoint = rl.getCharPressed();
            if (codepoint <= 0) break;
            // Out-of-range values (control junk from the platform) are
            // skipped, not fatal — `@intCast` to u21 would panic otherwise.
            if (codepoint > 0x10FFFF) continue;
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch continue;
            if (char_count + length > self.char_buffer.len) break;
            @memcpy(self.char_buffer[char_count .. char_count + length], encoded[0..length]);
            char_count += length;
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
            .text_characters = self.char_buffer[0..char_count],
        };
    }

    pub fn render(
        self: *RaylibBackend,
        view_state: types.ViewState,
        viewport: input.ViewportSize,
    ) void {
        _ = viewport;
        _ = self.frame_arena.reset(.retain_capacity);

        // Draw all reference-space content into the offscreen target. The
        // target may be smaller than the 4K reference (build option, default
        // 1080p); a `beginMode2D` camera zoom scales every draw call down so
        // layout math stays in 4K design space while fill happens at the
        // target resolution. clearBackground is NOT camera-affected, so it
        // runs before the camera block and clears the full target. See
        // DESIGN → Platform Seam → Render target resolution.
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
        rl.beginMode2D(.{ .offset = .{ .x = 0, .y = 0 }, .target = .{ .x = 0, .y = 0 }, .rotation = 0, .zoom = render_scale });
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
        const transform = blitTransform();
        const source = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = render_width,
            .height = -render_height,
        };
        const destination = rl.Rectangle{
            .x = transform.offset_x,
            .y = transform.offset_y,
            .width = render_width * transform.scale,
            .height = render_height * transform.scale,
        };
        rl.drawTexturePro(self.render_target.texture, source, destination, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
    }

    // -- World drawing --

    /// Draw a tile overlay as a primitive (no overlay art): a translucent fill
    /// for move-range highlights, an outline for the cursor / range outlines.
    /// The outline thickness is the shared `outline_thickness` (8 source px)
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
        const line_width = @as(f32, @floatFromInt(outline_thickness)) * world_scale;
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
                if (self.getTexture("world/tile_highlight")) |texture| {
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
                const texture = self.getTexture(icon.sprite_id) orelse return;
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
                self.drawOutlinedText(
                    text_z,
                    .{ .x = @floatFromInt(ftext.screen_position.x), .y = @floatFromInt(ftext.screen_position.y) },
                    drawn_font_size,
                    spacing,
                    toRaylibColor(ftext.color, 255),
                    @as(f32, @floatFromInt(text_outline_thickness)) * world_scale,
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
        const fill_texture = self.getTexture("world/entity_health_bar_background") orelse return;
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
                    const t: i32 = outline_thickness;
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
            .text_label => |label| self.drawTextLabel(label, highlight_color),
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
                self.drawTextLabel(.{
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
        const mask = self.getOutlineTexture(sprite_id) orelse {
            // Fallback for missing sprites (or mask build failures): ring
            // the destination rectangle directly. Lets the hover highlight
            // work on placeholder magenta boxes before the real asset lands.
            rl.drawRectangleLinesEx(destination, @floatFromInt(outline_thickness), toRaylibColor(highlight_color, 255));
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
        const mask = self.getCompositeInsetTexture(inset.sprite_stack, inset.frame_width, inset.frame_height) orelse return;
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
        rl.drawTexturePro(texture, source orelse whole, destination, .{ .x = 0, .y = 0 }, 0, toPremultipliedColor(tint, alpha));
    }

    /// 9-slice: every corner is drawn square (aspect-true 1:1) and the edges
    /// + center stretch to fill — the rect math lives in the pure, tested
    /// `ui.nineSlicePieces` (corners shrink proportionally on panels smaller
    /// than two slices instead of being squashed).
    fn drawNineSlice(self: *RaylibBackend, panel: ui.NineSlicePanel, theme_darkest: types.Color) void {
        const texture = self.getTexture(panel.sprite_id) orelse {
            rl.drawRectangleRec(referenceRectangle(panel.screen_position, panel.width, panel.height), rl.Color.magenta);
            return;
        };
        // `default_tint` (pure white) is the "unset" sentinel: a panel that
        // didn't pick an explicit color inherits the active theme's `darkest`
        // (mirrors the text-label convention in `drawTextLabel`). An explicit
        // `.color` overrides it.
        const tint = if (std.meta.eql(panel.color, ui.default_tint))
            toRaylibColor(theme_darkest, 255)
        else
            toRaylibColor(panel.color, 255);

        const destination = types.Rectangle{
            .x = panel.screen_position.x,
            .y = panel.screen_position.y,
            .width = panel.width,
            .height = panel.height,
        };
        for (ui.nineSlicePieces(texture.width, texture.height, destination)) |piece| {
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

    /// Draw text with a black edge-outline of `outline_width` px (in the drawn
    /// text's own pixel space). Uses the SDF pipeline when available — ONE
    /// shader-driven draw where the fragment shader thresholds the distance
    /// field into fill + outline band — with the 8-direction offset-shadow
    /// ring (9 draws) as the fallback for environments where the SDF
    /// pipeline failed to init. Never draw the SDF font without the shader:
    /// its texels are distances, not coverage, so it renders garbage raw.
    fn drawOutlinedText(
        self: *RaylibBackend,
        text: [:0]const u8,
        position: rl.Vector2,
        font_size: f32,
        spacing: f32,
        fill: rl.Color,
        outline_width: f32,
    ) void {
        if (self.sdf) |sdf| {
            // The field's distances are in BASE-atlas pixels; convert the
            // drawn-pixel width (font_size/baseSize = atlas→screen scale).
            const width_in_atlas_pixels = outline_width * @as(f32, @floatFromInt(sdf.font.baseSize)) / font_size;
            rl.setShaderValue(sdf.shader, sdf.width_location, &width_in_atlas_pixels, .float);
            const outline_color = [4]f32{ 0, 0, 0, 1 };
            rl.setShaderValue(sdf.shader, sdf.color_location, &outline_color, .vec4);
            rl.beginShaderMode(sdf.shader);
            rl.drawTextEx(sdf.font, text, position, font_size, spacing, fill);
            rl.endShaderMode();
            return;
        }
        // Fallback ring: 8 black copies offset in a square ring, fill on top.
        const black = toRaylibColor(.{ .r = 0, .g = 0, .b = 0 }, 255);
        const dirs = [_]struct { dx: f32, dy: f32 }{
            .{ .dx = -outline_width, .dy = -outline_width }, .{ .dx = 0, .dy = -outline_width }, .{ .dx = outline_width, .dy = -outline_width },
            .{ .dx = -outline_width, .dy = 0 }, .{ .dx = outline_width, .dy = 0 },
            .{ .dx = -outline_width, .dy = outline_width }, .{ .dx = 0, .dy = outline_width }, .{ .dx = outline_width, .dy = outline_width },
        };
        for (dirs) |d| {
            rl.drawTextEx(self.font, text, .{ .x = position.x + d.dx, .y = position.y + d.dy }, font_size, spacing, black);
        }
        rl.drawTextEx(self.font, text, position, font_size, spacing, fill);
    }

    fn drawTextLabel(self: *RaylibBackend, label: ui.TextLabel, theme_lightest: types.Color) void {
        // raylib needs a null-terminated string; copy into the frame arena.
        // bold/italic are still ignored (no bold/italic faces loaded).
        // `default_tint` (pure white) is the "unset" sentinel: a text label
        // or span that didn't pick an explicit color inherits the active
        // theme's `lightest` (the artist's offwhite). Explicitly colored
        // spans pass a non-`default_tint` color and are unaffected. Sprite
        // tints (Button/Slot/Image) keep `default_tint` meaning "no tint" —
        // this substitution is text-only.
        const text = self.frame_arena.allocator().dupeZ(u8, label.text) catch return;
        const font_size: f32 = @floatFromInt(label.font_size);
        const spacing: f32 = font_size / @as(f32, @floatFromInt(ui.glyph_spacing_font_divisor));
        const color = if (std.meta.eql(label.color, ui.default_tint)) theme_lightest else label.color;
        const pos = rl.Vector2{ .x = @floatFromInt(label.screen_position.x), .y = @floatFromInt(label.screen_position.y) };
        // Outlined text: black edge-outline under the fill via the SDF
        // pipeline (shadow-ring fallback) — see `drawOutlinedText`. UI is
        // drawn 1:1 at reference resolution into the render target, so the
        // outline width needs no world_scale.
        if (label.outlined) {
            self.drawOutlinedText(text, pos, font_size, spacing, toRaylibColor(color, 255), @floatFromInt(text_outline_thickness));
        } else {
            rl.drawTextEx(self.font, text, pos, font_size, spacing, toRaylibColor(color, 255));
        }
    }

    fn drawFillSprite(self: *RaylibBackend, fill: ui.FillSprite) void {
        const destination = referenceRectangle(fill.screen_position, fill.width, fill.height);
        // Background (e.g. depleted health) drawn whole.
        self.drawSprite(fill.background_sprite_id, destination, null, fill.background_color, 255);

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

    /// The precomputed INNER outline mask for a COMPOSITED silhouette
    /// (`stack` = base + layers + weapons / pole + banner frame / single
    /// ground-items sprite). Lazily generated on first request via
    /// `ensureCompositeInsetLoaded`; cached by a key built from the stack so
    /// identical stacks share one mask. null if the mask could not be built
    /// (e.g. every sprite in the stack is missing). Used by the occlusion
    /// inset — see DESIGN → Decorations & Footprint → Occlusion inset.
    fn getCompositeInsetTexture(
        self: *RaylibBackend,
        stack: []const types.StackSprite,
        frame_width: i32,
        frame_height: i32,
    ) ?rl.Texture2D {
        const key = self.buildStackKey(stack, frame_width, frame_height);
        defer self.allocator.free(key);
        if (!self.composite_inset_cache.contains(key)) {
            self.ensureCompositeInsetLoaded(key, stack, frame_width, frame_height);
        }
        return self.composite_inset_cache.get(key).?;
    }

    /// Build and cache the INNER outline mask for a composited silhouette.
    /// Decodes each sprite in `stack`, ORs its alpha (alpha > 16) into a
    /// frame-sized opaque mask (honoring `flip_horizontal` and
    /// `source_rectangle`), then dilates the union. Compositing before
    /// dilating is required for the INNER band: a weapon overlapping the
    /// body would otherwise leave a spurious internal edge (dilation doesn't
    /// distribute over intersection for the inner dual). Caches into
    /// `composite_inset_cache` under `key` (already built by the caller and
    /// freed there — `ensureCompositeInsetLoaded` dupes its own copy).
    fn ensureCompositeInsetLoaded(
        self: *RaylibBackend,
        key: []const u8,
        stack: []const types.StackSprite,
        frame_width: i32,
        frame_height: i32,
    ) void {
        const owned_key = self.allocator.dupe(u8, key) catch @panic("failed to dupe composite inset key");
        const outline: ?rl.Texture2D = self.generateCompositeOutlineMask(stack, frame_width, frame_height, .inner) catch null;
        self.composite_inset_cache.put(self.allocator, owned_key, outline) catch @panic("failed to cache composite inset mask");
    }

    /// Build a compositing key for a silhouette stack: a string encoding
    /// each sprite's id + flip + source rect, plus the frame size. Two stacks
    /// with the same key share one cached mask. Caller frees the returned
    /// slice. The format is compact and unambiguous (pipe-delimited fields,
    /// fixed component order); it's a cache key, not a stable serialization.
    fn buildStackKey(
        self: *RaylibBackend,
        stack: []const types.StackSprite,
        frame_width: i32,
        frame_height: i32,
    ) []const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        buf.print(self.allocator, "{d}x{d}", .{ frame_width, frame_height }) catch
            @panic("failed to format stack key");
        for (stack) |s| {
            buf.print(self.allocator, "|{s}|{d}", .{ s.sprite_id, @intFromBool(s.flip_horizontal) }) catch
                @panic("failed to format stack key");
            if (s.source_rectangle) |r| {
                buf.print(self.allocator, "|{d},{d},{d},{d}", .{ r.x, r.y, r.width, r.height }) catch
                    @panic("failed to format stack key");
            } else {
                buf.appendSlice(self.allocator, "|*") catch @panic("failed to format stack key");
            }
        }
        return buf.toOwnedSlice(self.allocator) catch @panic("failed to own stack key");
    }

    /// Decode each sprite in `stack`, OR its alpha into a frame-sized opaque
    /// mask, then dilate. Each sprite's source region (whole sprite if
    /// `source_rectangle` is null) is blitted at the frame's top-left; the
    /// source region must fit within the frame (current art: entity sprites
    /// are 512×640 = frame, flag pole 256×512 = frame, banner frame slice
    /// 256×512 = frame, ground items 256×256 = frame). `flip_horizontal`
    /// mirrors the alpha within the source region. A missing/unreadable
    /// sprite contributes nothing (the rest of the stack still composites).
    fn generateCompositeOutlineMask(
        self: *RaylibBackend,
        stack: []const types.StackSprite,
        frame_width: i32,
        frame_height: i32,
        side: OutlineSide,
    ) !rl.Texture2D {
        const pixel_count: usize = @intCast(frame_width * frame_height);
        const opaque_mask = try self.allocator.alloc(u8, pixel_count);
        defer self.allocator.free(opaque_mask);
        @memset(opaque_mask, 0);

        for (stack) |s| {
            self.blitSpriteAlpha(opaque_mask, frame_width, frame_height, s) catch continue;
        }

        const buf = try self.dilateToMask(opaque_mask, frame_width, frame_height, outline_thickness, side);
        defer self.allocator.free(buf);
        return self.rgbaBufToTexture(buf, frame_width, frame_height);
    }

    /// Read `sprite.sprite_id` from the file source, decode, and OR its alpha
    /// (alpha > 16) into `opaque_mask` (frame-sized). The sprite's source
    /// region (whole sprite if `source_rectangle` is null) is blitted at the
    /// frame's top-left; pixels outside the source region or beyond the frame
    /// are skipped. `flip_horizontal` mirrors the source columns within the
    /// region. A missing/unreadable sprite returns `error.MissingSprite` (the
    /// caller continues with the rest of the stack).
    fn blitSpriteAlpha(
        self: *RaylibBackend,
        opaque_mask: []u8,
        frame_width: i32,
        frame_height: i32,
        sprite: types.StackSprite,
    ) !void {
        const path = std.fmt.allocPrintSentinel(
            self.frame_arena.allocator(),
            "assets/{s}.png",
            .{sprite.sprite_id},
            0,
        ) catch @panic("failed to build asset path");
        const bytes = self.file_source.readFile(self.allocator, path) catch return error.MissingSprite;
        defer self.allocator.free(bytes);
        var image = rl.loadImageFromMemory(".png", bytes) catch return error.MissingSprite;
        defer rl.unloadImage(image);
        image.setFormat(.uncompressed_r8g8b8a8);
        const colors = try rl.loadImageColors(image);
        defer rl.unloadImageColors(colors);

        const src_w: i32 = image.width;
        const src_h: i32 = image.height;
        // Source region within the sprite (defaults to the whole sprite).
        const r = sprite.source_rectangle orelse types.Rectangle{ .x = 0, .y = 0, .width = src_w, .height = src_h };
        // Blit the source region at the frame's top-left; clip to the frame.
        const blit_w = @min(r.width, frame_width);
        const blit_h = @min(r.height, frame_height);
        var fy: i32 = 0;
        while (fy < blit_h) : (fy += 1) {
            const sy = r.y + fy;
            if (sy < 0 or sy >= src_h) continue;
            var fx: i32 = 0;
            while (fx < blit_w) : (fx += 1) {
                // Mirror within the source region when flipping.
                const sx_in_region = if (sprite.flip_horizontal) (r.width - 1 - fx) else fx;
                const sx = r.x + sx_in_region;
                if (sx < 0 or sx >= src_w) continue;
                const src_idx: usize = @intCast(sy * src_w + sx);
                if (colors[src_idx].a > 16) {
                    const dst_idx: usize = @intCast(fy * frame_width + fx);
                    opaque_mask[dst_idx] = 1;
                }
            }
        }
    }

    /// Premultiply RGB by alpha in-place (for `BLEND_ALPHA_PREMULTIPLY`).
    /// For each pixel: r = r*a/255, g = g*a/255, b = b*a/255 (alpha
    /// unchanged). With premultiplied textures, bilinear downsampling blends
    /// in premultiplied space — transparent-edge pixels (RGB=0) contribute
    /// zero color, killing the dark halo straight-alpha textures show when
    /// downscaled. The image MUST be `.uncompressed_r8g8b8a8` (convert first).
    /// See DESIGN → Platform Seam → Render target resolution (premultiplied
    /// alpha).
    fn premultiplyAlpha(image: *rl.Image) void {
        if (image.format != .uncompressed_r8g8b8a8) return;
        const w: usize = @intCast(image.width);
        const h: usize = @intCast(image.height);
        if (w == 0 or h == 0) return;
        const px: [*]u8 = @ptrCast(image.data);
        const stride = w * 4;
        for (0..h * stride) |i| {
            if (i % 4 == 3) continue; // skip alpha byte
            const a: u16 = px[(i / 4) * 4 + 3];
            px[i] = @intCast((@as(u16, px[i]) * a + 127) / 255);
        }
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
            var image = rl.loadImageFromMemory(".png", bytes) catch break :blk null;
            defer rl.unloadImage(image);
            // Normalize to RGBA8 so premultiply has a stable byte layout.
            image.setFormat(.uncompressed_r8g8b8a8);
            // Premultiply RGB by alpha before upload. With the render pass's
            // `BLEND_ALPHA_PREMULTIPLY` blend mode, bilinear downsampling
            // (the 4K design space → smaller render target) blends in
            // premultiplied space, so transparent-edge pixels (RGB=0 after
            // premultiply) contribute zero color — no dark halo. Straight-
            // alpha textures under a premultiplied blend render too dark, so
            // EVERY composited texture must be premultiplied. See DESIGN →
            // Platform Seam → Render target resolution (premultiplied alpha).
            premultiplyAlpha(&image);
            const tex = rl.loadTextureFromImage(image) catch break :blk null;
            // Bilinear so downscaled draws sample smoothly instead of with
            // hard nearest-neighbor edges. At a 1:1 render target this is a
            // no-op visually; it only matters when the target is smaller
            // than the design space. See DESIGN → Platform Seam → Render
            // target resolution.
            rl.setTextureFilter(tex, .bilinear);
            break :blk tex;
        };

        self.texture_cache.put(self.allocator, key, texture) catch @panic("failed to cache texture");
    }

    /// Build and cache the OUTER edge-outline mask for `sprite_id`. Re-reads
    /// the asset bytes and decodes — outlines are requested for few sprites
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
            break :blk self.generateOutlineMask(image, outline_thickness, .outer) catch null;
        };

        self.outline_cache.put(self.allocator, key, outline) catch @panic("failed to cache outline mask");
    }

    /// The opaque-pixel bounding box of `sprite_id` (top/bottom/left/right,
    /// in SOURCE pixels), or null if the sprite can't be loaded/decoded.
    /// Lazily generated on first request via `ensureSpriteBoundsLoaded`
    /// (one decode fills all four edges). Used by `view()` (via the
    /// `RenderContext.sprite_bounds` lookup) to place overlays against an
    /// entity's actual rendered art. See AGENTS Animation.
    pub fn getSpriteBounds(self: *RaylibBackend, sprite_id: []const u8) ?types.SpriteBounds {
        if (!self.sprite_bounds_cache.contains(sprite_id)) self.ensureSpriteBoundsLoaded(sprite_id);
        return self.sprite_bounds_cache.get(sprite_id).?;
    }

    /// Convenience wrapper: look up the opaque-pixel bounding box for an
    /// ENTITY sprite given its bare stem (e.g. `skeleton_1`), prefixing the
    /// `entities/` folder so `frame()` can query without knowing the
    /// asset-path format. See AGENTS Animation.
    pub fn entitySpriteBounds(self: *RaylibBackend, allocator: std.mem.Allocator, bare_stem: []const u8) ?types.SpriteBounds {
        const sprite_id = std.fmt.allocPrint(allocator, "entities/{s}", .{bare_stem}) catch
            @panic("failed to build entity sprite id for bounds lookup");
        return self.getSpriteBounds(sprite_id);
    }

    fn ensureSpriteBoundsLoaded(self: *RaylibBackend, sprite_id: []const u8) void {
        if (self.sprite_bounds_cache.contains(sprite_id)) return;

        const path = std.fmt.allocPrintSentinel(
            self.frame_arena.allocator(),
            "assets/{s}.png",
            .{sprite_id},
            0,
        ) catch @panic("failed to build asset path");

        const key = self.allocator.dupe(u8, sprite_id) catch @panic("failed to dupe sprite id");

        const bounds: ?types.SpriteBounds = blk: {
            const bytes = self.file_source.readFile(self.allocator, path) catch
                break :blk null;
            defer self.allocator.free(bytes);
            const image = rl.loadImageFromMemory(".png", bytes) catch break :blk null;
            defer rl.unloadImage(image);
            // `loadImageColors` returns []rl.Color regardless of source format
            // (raylib normalizes internally), so no manual setFormat needed.
            break :blk self.scanOpaqueBounds(image) catch null;
        };

        self.sprite_bounds_cache.put(self.allocator, key, bounds) catch
            @panic("failed to cache sprite bounds");
    }

    /// Find the opaque-pixel bounding box of `image`: the min/max x and y of
    /// pixels with alpha > 16 (same threshold as the outline mask). One pass
    /// over the pixels. Returns null for a fully transparent image (no opaque
    /// pixel) -- the caller falls back to the frame edges.
    fn scanOpaqueBounds(self: *RaylibBackend, image: rl.Image) !?types.SpriteBounds {
        _ = self;
        const width: i32 = image.width;
        const height: i32 = image.height;
        const colors = try rl.loadImageColors(image);
        defer rl.unloadImageColors(colors);
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);
        var y: i32 = 0;
        while (y < height) : (y += 1) {
            const row_start: usize = @intCast(y * width);
            var x: i32 = 0;
            while (x < width) : (x += 1) {
                if (colors[row_start + @as(usize, @intCast(x))].a > 16) {
                    if (x < min_x) min_x = x;
                    if (x > max_x) max_x = x;
                    if (y < min_y) min_y = y;
                    if (y > max_y) max_y = y;
                }
            }
        }
        if (max_x < min_x) return null; // no opaque pixel
        return .{ .top = min_y, .bottom = max_y, .left = min_x, .right = max_x };
    }

    /// Build a white-opaque edge-outline mask. OUTER: transparent pixels
    /// within `thickness` (Euclidean) of an opaque pixel become white; opaque
    /// pixels stay transparent — a halo just OUTSIDE the silhouette, so the
    /// sprite's own art is never overpainted. INNER: the morphological dual —
    /// opaque pixels within `thickness` of a transparent pixel become white;
    /// transparent pixels stay transparent — a rim just INSIDE the silhouette,
    /// used by the occlusion inset to trace an occluded entity's edge over a
    /// decoration. Dilation uses a DISK structuring element (offsets with
    /// dx²+dy² ≤ t²), which is not separable — a single 2D pass,
    /// O(|band pixels| × |disk|), instead of the square (Chebyshev) SE's
    /// O(w·h·2t) separable path. The mask is cached per sprite (built once),
    /// so the higher cost is amortized; the payoff is smoother 45° corners
    /// (the square SE's band was ~√2 thicker along diagonals). The band is
    /// clipped at the canvas border (a sprite filling its canvas edge-to-edge
    /// gets no band on that side); current art ships with enough margin that
    /// this never shows. See DESIGN → Decorations & Footprint → Occlusion inset.
    fn generateOutlineMask(self: *RaylibBackend, image: rl.Image, thickness: i32, side: OutlineSide) !rl.Texture2D {
        const width: i32 = image.width;
        const height: i32 = image.height;
        const colors = try rl.loadImageColors(image);
        defer rl.unloadImageColors(colors);

        const pixel_count: usize = @intCast(width * height);
        // opaque_mask[i] = 1 if the source pixel is opaque, else 0.
        const opaque_mask = try self.allocator.alloc(u8, pixel_count);
        defer self.allocator.free(opaque_mask);
        for (colors, 0..) |c, i| opaque_mask[i] = if (c.a > 16) 1 else 0;

        const buf = try self.dilateToMask(opaque_mask, width, height, thickness, side);
        defer self.allocator.free(buf);
        return self.rgbaBufToTexture(buf, width, height);
    }

    /// Dilate `opaque_mask` (1 = opaque, 0 = transparent) with a DISK
    /// structuring element and write the outline band into an RGBA buffer
    /// (white where the band, transparent elsewhere). Shared by the single-
    /// sprite path (`generateOutlineMask`) and the composite-silhouette path
    /// (`generateCompositeOutlineMask`): the silhouette source differs, the
    /// dilation is identical. OUTER marks transparent pixels within Euclidean
    /// t of an opaque pixel; INNER marks opaque pixels within t of a
    /// transparent pixel (the morphological dual). Disk SE: offsets with
    /// dx²+dy² ≤ t² (smoother 45° corners than the square/Chebyshev SE; not
    /// separable, but the mask is cached so the cost is amortized). Caller
    /// frees the returned buffer.
    fn dilateToMask(
        self: *RaylibBackend,
        opaque_mask: []const u8,
        width: i32,
        height: i32,
        thickness: i32,
        side: OutlineSide,
    ) ![]u8 {
        const pixel_count: usize = @intCast(width * height);
        // OUTER dilates the opaque silhouette and marks transparent pixels in
        // the band; INNER dilates the transparent mask and marks opaque pixels.
        // `dilate_val` selects which pixels expand; `band_val` selects which
        // pixels are eligible for the band (the complement).
        const dilate_val: u8 = if (side == .outer) 1 else 0;
        const band_val: u8 = if (side == .outer) 0 else 1;

        // Disk structuring element: the set of (dx, dy) offsets within
        // Euclidean radius `thickness` (dx²+dy² ≤ t²). Built once per call;
        // |disk| ≈ π·t² (~217 offsets at t=8). The (0,0) offset is skipped —
        // a band-eligible pixel matches `band_val`, so it can never itself be
        // a `dilate_val` source hit.
        const t = thickness;
        var disk: std.ArrayList(DiskOffset) = .empty;
        defer disk.deinit(self.allocator);
        var dy: i32 = -t;
        while (dy <= t) : (dy += 1) {
            var dx: i32 = -t;
            while (dx <= t) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                if (dx * dx + dy * dy <= t * t) {
                    disk.append(self.allocator, .{ .dx = dx, .dy = dy }) catch
                        @panic("failed to build disk offset");
                }
            }
        }

        // Band output: a pixel joins the band iff it matches `band_val` AND
        // some pixel within the disk neighborhood matches `dilate_val`.
        const buf = try self.allocator.alloc(u8, pixel_count * 4);
        @memset(buf, 0);
        var y: i32 = 0;
        while (y < height) : (y += 1) {
            const row_start: usize = @intCast(y * width);
            var x: i32 = 0;
            while (x < width) : (x += 1) {
                const i: usize = row_start + @as(usize, @intCast(x));
                if (opaque_mask[i] != band_val) continue; // not eligible -> transparent
                for (disk.items) |off| {
                    const nx = x + off.dx;
                    const ny = y + off.dy;
                    if (nx < 0 or nx >= width or ny < 0 or ny >= height) continue;
                    const ni: usize = @intCast(ny * width + nx);
                    if (opaque_mask[ni] == dilate_val) {
                        buf[i * 4 + 0] = 255;
                        buf[i * 4 + 1] = 255;
                        buf[i * 4 + 2] = 255;
                        buf[i * 4 + 3] = 255;
                        break;
                    }
                }
            }
        }
        return buf;
    }

    /// Wrap an RGBA buffer as a raylib Image and upload it to a texture. The
    /// caller's `buf` is copied into the GPU upload; `buf` is freed by the
    /// caller. Shared by the single-sprite and composite outline paths.
    fn rgbaBufToTexture(self: *RaylibBackend, buf: []u8, width: i32, height: i32) !rl.Texture2D {
        _ = self;
        const mask_image = rl.Image{
            .data = @ptrCast(buf.ptr),
            .width = width,
            .height = height,
            .mipmaps = 1,
            .format = .uncompressed_r8g8b8a8,
        };
        const tex = rl.loadTextureFromImage(mask_image) catch return error.LoadTexture;
        // Bilinear: outline masks are drawn scaled (by world_scale + the
        // render camera zoom), so nearest-neighbor would show hard edges.
        rl.setTextureFilter(tex, .bilinear);
        return tex;
    }
};

fn toRaylibColor(color: types.Color, alpha: u8) rl.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha };
}

/// Premultiplied tint for draws under `BLEND_ALPHA_PREMULTIPLY`: the RGB is
/// scaled by alpha so a translucent draw contributes proportionally dimmed
/// color (raylib multiplies the fragment color by the tint; with a straight-
/// alpha tint the RGB contribution wouldn't be scaled by the alpha and the
/// draw would render too bright). For textures the premultiplied texel RGB
/// is additionally scaled by the tint RGB, so the total contribution is
/// texelRGB*texelA*tintA — exactly "the sprite at opacity tintA". Used for
/// translucent rectangle fills (tile highlights) and partial-alpha sprite
/// draws (`UiElement.image.alpha`). Opaque (255) tints are identity.
/// See DESIGN → Platform Seam → Render target resolution (premultiplied
/// alpha).
fn toPremultipliedColor(color: types.Color, alpha: u8) rl.Color {
    const a: u16 = alpha;
    return .{
        .r = @intCast((@as(u16, color.r) * a + 127) / 255),
        .g = @intCast((@as(u16, color.g) * a + 127) / 255),
        .b = @intCast((@as(u16, color.b) * a + 127) / 255),
        .a = alpha,
    };
}

fn referenceRectangle(screen_position: types.ScreenPosition, width: i32, height: i32) rl.Rectangle {
    return .{
        .x = @floatFromInt(screen_position.x),
        .y = @floatFromInt(screen_position.y),
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    };
}
