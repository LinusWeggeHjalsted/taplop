//! Build-time SDF font-atlas generator. Runs as a HOST tool during `zig
//! build` (wired in build.zig): reads the embedded game TTF, bakes the SDF
//! glyph atlas via raylib's own `loadFontData(.sdf)` + `genImageFontAtlas`
//! (the exact code path the runtime used previously - metrics can't drift),
//! and serializes atlas pixels + per-glyph metrics into a binary blob that
//! `src/raylib/text.zig` parses at init (`initSdfTextOutline`). The SDF
//! encoding range (padding 22 / dist scale 6.0) comes from the
//! `-DFONT_SDF_*` defines on this tool's raylib dependency; see
//! src/raylib/text.zig's `sdf_pixel_dist_scale` / `sdf_char_padding`.
//!
//! Usage: sdf_atlas_generator <font.ttf> <output.blob>
//! Invocation is positional because build.zig passes file args in order.

const std = @import("std");
const rl = @import("raylib");
const font_codepoints = @import("font_codepoints");

/// Must match `font_base_size` in src/raylib/text.zig - the atlas is baked at
/// this size and the runtime scales from it. Validated at blob-parse time.
const font_base_size: i32 = 128;

/// Blob format version - bump on any format change (the runtime hard-gates
/// on this + the magic).
const blob_format_version: u32 = 1;

/// Mirrors the `-DFONT_SDF_*` defines on this tool's raylib dependency, so
/// the blob records the encoding its pixels were baked with. The runtime
/// validates these against its own constants (the shader decode depends on
/// them) and falls back to the shadow-ring outline on mismatch.
const baked_char_padding: i32 = 22;
const baked_pixel_dist_scale: f32 = 6.0;

pub fn main(init: std.process.Init.Minimal) void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var args_iter = std.process.Args.Iterator.init(init.args);
    defer args_iter.deinit();
    _ = args_iter.next(); // program name
    const input_path = args_iter.next() orelse @panic("usage: sdf_atlas_generator <font.ttf> <output.blob>");
    const output_path = args_iter.next() orelse @panic("usage: sdf_atlas_generator <font.ttf> <output.blob>");

    // read TTF
    const ttf_bytes = std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .limited(16 * 1024 * 1024)) catch
        @panic("sdf_atlas_generator: failed to read font file");
    defer allocator.free(ttf_bytes);

    // Bake SDF glyphs for EXACTLY the codepoints the font's cmap maps (see
    // src/font_codepoints.zig) - the full-coverage set, not raylib's default
    // 95-ASCII bake. A set over the shared atlas bound is a build-time
    // failure (a deliberate font swap must revisit the bound, not silently
    // bake an enormous atlas).
    const codepoints = font_codepoints.fontCodepoints(allocator, ttf_bytes) catch
        @panic("sdf_atlas_generator: failed to parse the font's cmap");
    defer allocator.free(codepoints);
    if (codepoints.len > font_codepoints.max_atlas_codepoints)
        @panic("sdf_atlas_generator: font maps too many codepoints for the atlas bound");
    const codepoints_i32 = allocator.alloc(i32, codepoints.len) catch @panic("OOM");
    defer allocator.free(codepoints_i32);
    for (codepoints, codepoints_i32) |codepoint, *target| target.* = codepoint;

    const glyphs = rl.loadFontData(ttf_bytes, font_base_size, codepoints_i32, .sdf) catch
        @panic("sdf_atlas_generator: SDF glyph generation failed");
    defer rl.unloadFontData(glyphs);

    // Pack into an atlas. padding 0: the SDF glyphs carry their own 22px
    // margin (baked into glyph images by loadFontData); pack method 1
    // (skyline), matching raylib's own SDF example.
    const packed_atlas = rl.genImageFontAtlas(glyphs, font_base_size, 0, 1) catch
        @panic("sdf_atlas_generator: atlas packing failed");
    const atlas_image = packed_atlas[0];
    const recs = packed_atlas[1];

    // GenImageFontAtlas returns GRAY_ALPHA (gray=255, alpha=SDF distance);
    // serialize just the alpha channel - the runtime reconstructs a
    // grayscale image from it (halves blob size + VRAM texture).
    if (atlas_image.format != .uncompressed_gray_alpha) @panic("sdf_atlas_generator: unexpected atlas format");
    const gray_alpha: []const u8 = @as([*]const u8, @ptrCast(atlas_image.data))[0 .. @as(usize, @intCast(atlas_image.width * atlas_image.height)) * 2];
    const atlas_bytes = allocator.alloc(u8, gray_alpha.len / 2) catch @panic("OOM");
    defer allocator.free(atlas_bytes);
    for (atlas_bytes, 0..) |*byte, i| byte.* = gray_alpha[i * 2 + 1];

    // Serialize: header, glyph records, atlas bytes (all little-endian).
    // Layout documented alongside the parser in src/raylib/text.zig
    // (`initSdfTextOutline`).
    var blob: std.ArrayListUnmanaged(u8) = .empty;
    defer blob.deinit(allocator);

    blob.appendSlice(allocator, "ZSDF") catch @panic("OOM");
    appendInt(u32, &blob, allocator, blob_format_version);
    appendInt(i32, &blob, allocator, font_base_size);
    appendInt(i32, &blob, allocator, @intCast(glyphs.len));
    appendInt(i32, &blob, allocator, atlas_image.width);
    appendInt(i32, &blob, allocator, atlas_image.height);
    appendInt(i32, &blob, allocator, baked_char_padding);
    appendInt(u32, &blob, allocator, @bitCast(baked_pixel_dist_scale));

    for (glyphs, recs) |glyph, rec| {
        appendInt(i32, &blob, allocator, glyph.value);
        appendInt(i32, &blob, allocator, glyph.offsetX);
        appendInt(i32, &blob, allocator, glyph.offsetY);
        appendInt(i32, &blob, allocator, glyph.advanceX);
        appendInt(u32, &blob, allocator, @bitCast(rec.x));
        appendInt(u32, &blob, allocator, @bitCast(rec.y));
        appendInt(u32, &blob, allocator, @bitCast(rec.width));
        appendInt(u32, &blob, allocator, @bitCast(rec.height));
    }
    blob.appendSlice(allocator, atlas_bytes) catch @panic("OOM");

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = blob.items }) catch
        @panic("sdf_atlas_generator: failed to write blob");
}

fn appendInt(comptime T: type, blob: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: T) void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    blob.appendSlice(allocator, &buf) catch @panic("OOM");
}
