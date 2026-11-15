//! Texture subsystem of the raylib backend: the lazy sprite-texture
//! caches (main textures, edge-outline masks, composite occlusion-inset
//! masks, opaque-pixel bounds, baked arrow sprites + their hover-outline
//! masks) and all mask-generation math. Asset paths
//! are built into fixed stack buffers (sprite ids are bounded by filesystem
//! component limits; an overflow is a fail-fast panic, same class as the
//! old arena OOM). See DESIGN → Platform Seam (missing-art magenta
//! fallback) + Decorations & Footprint → Occlusion inset.

const std = @import("std");
const rl = @import("raylib");
const types = @import("../types.zig");
const ui = @import("../ui.zig");
const file_source = @import("../file_source.zig");

/// Which side of the silhouette an outline mask sits on. OUTER = the band
/// of transparent pixels within `thickness` of an opaque pixel (a halo
/// outside the silhouette, used by highlighted UI). INNER = the morphological
/// dual: opaque pixels within `thickness` of a transparent pixel (a rim
/// just inside the silhouette, used by the occlusion inset). See
/// `generateOutlineMask` and DESIGN → Decorations & Footprint → Occlusion inset.
const OutlineSide = enum { outer, inner };

/// The outline-cache key string for (sprite_id, band): `"{sprite_id}|{band}""
/// - a flat composite (std's auto hash refuses slice-containing struct
/// keys). One entry per (sprite, distinct drawn scale): the band is
/// scale-compensated, so one sprite drawn at two sizes gets two masks
/// (see `getOutlineTexture`). A STORED key owns its string (duped at
/// insert, freed in deinit); lookups may pass a stack-buffer borrow.
fn outlineCacheKey(buffer: []u8, sprite_id: []const u8, band_source_pixels: i32) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}|{d}", .{ sprite_id, band_source_pixels }) catch
        @panic("outline cache key overflow");
}

/// One (dx, dy) offset in a disk structuring element (see
/// `generateOutlineMask`). Small enough that a slice of these is the disk.
const DiskOffset = struct { dx: i32, dy: i32 };

/// Asset-path scratch: "assets/" + sprite id + ".png". Sprite ids are
/// bounded well below this (filesystem per-component limits cap custom
/// mission stems; 512 leaves generous margin). An overflow is a fail-fast
/// panic - the same class as the arena OOM it replaces.
const path_buffer_size = 512;

/// Map a sprite id to its file path. Shipped art is `assets/{id}.png`.
/// Custom ids are content-addressed by the ONE rule: the segment chain
/// after `custom/` IS the content path (file_source.customAssetTail - the
/// same rule the loader's dims resolution uses), so the tail + `.png` is
/// the read path and FileSource.readFile's tiers resolve it (persistent
/// root, then embedded `data/` content - dream vs campaign-bundled art).
/// Both id shapes ride it: bare `custom/<path>/<stem>` (campaign
/// backgrounds, mission-scanned art) and kind-prefixed
/// `entities|decorations/custom/<path>/<stem>`. See DESIGN → Custom
/// Missions & Online Services → Custom-asset paths.
fn assetPathFor(sprite_id: []const u8, path_buffer: []u8) []const u8 {
    if (file_source.customAssetTail(sprite_id)) |tail| {
        return std.fmt.bufPrint(path_buffer, "{s}.png", .{tail}) catch
            @panic("failed to build custom asset path");
    }
    return std.fmt.bufPrint(path_buffer, "assets/{s}.png", .{sprite_id}) catch
        @panic("failed to build asset path");
}

pub const TextureStore = struct {
    allocator: std.mem.Allocator,
    /// Unified file source for asset bytes (embedded map / persistent dir).
    /// Textures load via loadImageFromMemory from this instead of touching
    /// the filesystem directly - see DESIGN → File System & IO.
    file_source: *const @import("../file_source.zig").FileSource,

    /// sprite_id -> loaded texture. A cached `null` means "known missing" so a
    /// failed load is not retried (and spammed) every frame. Keys are duped
    /// into `allocator`; the loaded textures live until deinit.
    texture_cache: std.StringHashMapUnmanaged(?rl.Texture2D) = .empty,
    /// (sprite_id, band) composite key -> precomputed edge-outline mask
    /// texture (white opaque halo sitting just outside the silhouette).
    /// Generated lazily by `ensureOutlineLoaded` on the first
    /// `getOutlineTexture` request, so only sprites that actually get
    /// outlined pay the cost (highlighted UI icons). A cached `null` means
    /// the sprite is missing (or the mask failed) -> callers skip the
    /// outline. One entry per (sprite, distinct drawn scale) - see
    /// `outlineCacheKey`. Keys own their duped strings (freed in deinit).
    outline_cache: std.StringHashMapUnmanaged(?rl.Texture2D) = .empty,
    /// stack-key -> precomputed INNER outline mask texture for a COMPOSITED
    /// silhouette (entity base + layers + weapons, flag pole + banner frame,
    /// or a single ground-items sprite). Keyed by a string built from the
    /// stack's sprite ids + flips + source rects + frame size, so two
    /// entities with the same loadout share one mask. Generated lazily by
    /// `ensureCompositeInsetLoaded` on the first `getCompositeInsetTexture`
    /// request. Used by the occlusion inset pass - see DESIGN → Decorations &
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
    /// Baked-arrow params key -> the rasterized edge texture (the black
    /// outline + white inner stroke in one sprite; the shape math lives in
    /// campaign_geometry's baked-arrow section). Generated lazily by
    /// `ensureArrowBaked` on the first `getArrowTexture` request - the map
    /// edges' draw sites. A cached `null` means the bake failed (e.g. the
    /// canvas exceeds the platform texture limit) -> the caller falls back
    /// to the per-segment draw. Keys own their duped strings (freed in
    /// deinit).
    arrow_cache: std.StringHashMapUnmanaged(?rl.Texture2D) = .empty,

    /// The hover-outline masks for baked arrows (`getArrowOutlineTexture`):
    /// key = the arrow shape's key + `outline` (`arrowOutlineCacheKey`),
    /// value = the OUTER dilation of that arrow's rasterized silhouette at
    /// the constant outline width. One mask per distinct baked shape,
    /// generated lazily on the first hover. Same shape as `arrow_cache`
    /// (STORED keys own their strings, freed in deinit; a cached `null`
    /// means generation failed -> the caller falls back to the widened
    /// per-segment rim).
    arrow_outline_cache: std.StringHashMapUnmanaged(?rl.Texture2D) = .empty,

    /// Unload every cached texture + free the cache maps. No outline or
    /// inset masks outlive the textures they derive from.
    pub fn deinit(self: *TextureStore) void {
        // Every cache dupes its keys at insert (see the ensure* loaders) -
        // free them alongside the values, then the maps themselves.
        var textures = self.texture_cache.iterator();
        while (textures.next()) |entry| {
            if (entry.value_ptr.*) |texture| rl.unloadTexture(texture);
            self.allocator.free(entry.key_ptr.*);
        }
        self.texture_cache.deinit(self.allocator);
        var outlines = self.outline_cache.iterator();
        while (outlines.next()) |entry| {
            if (entry.value_ptr.*) |texture| rl.unloadTexture(texture);
            self.allocator.free(entry.key_ptr.*);
        }
        self.outline_cache.deinit(self.allocator);
        var composite_insets = self.composite_inset_cache.iterator();
        while (composite_insets.next()) |entry| {
            if (entry.value_ptr.*) |texture| rl.unloadTexture(texture);
            self.allocator.free(entry.key_ptr.*);
        }
        self.composite_inset_cache.deinit(self.allocator);
        var bounds = self.sprite_bounds_cache.iterator();
        while (bounds.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.sprite_bounds_cache.deinit(self.allocator);
        var arrows = self.arrow_cache.iterator();
        while (arrows.next()) |entry| {
            if (entry.value_ptr.*) |texture| rl.unloadTexture(texture);
            self.allocator.free(entry.key_ptr.*);
        }
        self.arrow_cache.deinit(self.allocator);
        var arrow_outlines = self.arrow_outline_cache.iterator();
        while (arrow_outlines.next()) |entry| {
            if (entry.value_ptr.*) |texture| rl.unloadTexture(texture);
            self.allocator.free(entry.key_ptr.*);
        }
        self.arrow_outline_cache.deinit(self.allocator);
    }

    /// Load a texture for `sprite_id` (assets/<id>.png), caching the result.
    /// Reads bytes through the FileSource (embedded map / persistent-dir
    /// override) and decodes via loadImageFromMemory, so the store never
    /// touches the filesystem directly. Returns null (and caches the miss) if
    /// the asset can't be loaded. The outline mask is NOT built here - it is
    /// generated lazily by `ensureOutlineLoaded` only for sprites that
    /// actually get outlined, so loading a level pays no outline cost.
    pub fn getTexture(self: *TextureStore, sprite_id: []const u8) ?rl.Texture2D {
        if (!self.texture_cache.contains(sprite_id)) self.ensureSpriteLoaded(sprite_id);
        return self.texture_cache.get(sprite_id).?;
    }

    /// The precomputed edge-outline mask for `sprite_id` drawn at
    /// `drawn_scale` (destination/source width): a white opaque halo just
    /// outside the silhouette, generated with a scale-compensated band -
    /// `ceil(types.outline_thickness / drawn_scale)` source pixels - so the
    /// DRAWN band is the constant outline width (reference px) at every
    /// element size; see `types.outline_thickness`. Lazily generated via
    /// `ensureOutlineLoaded` (one mask per (sprite, band)). null if the
    /// sprite is missing or the mask could not be built.
    pub fn getOutlineTexture(self: *TextureStore, sprite_id: []const u8, drawn_scale: f32) ?rl.Texture2D {
        const band_source_pixels: i32 = @max(1, @as(i32, @intFromFloat(@ceil(
            @as(f32, @floatFromInt(types.outline_thickness)) / drawn_scale,
        ))));
        var key_buffer: [path_buffer_size]u8 = undefined;
        const key = outlineCacheKey(&key_buffer, sprite_id, band_source_pixels);
        if (!self.outline_cache.contains(key)) self.ensureOutlineLoaded(sprite_id, band_source_pixels);
        return self.outline_cache.get(key).?;
    }

    /// The precomputed INNER outline mask for a COMPOSITED silhouette
    /// (`stack` = base + layers + weapons / pole + banner frame / single
    /// ground-items sprite). Lazily generated on first request via
    /// `ensureCompositeInsetLoaded`; cached by a key built from the stack so
    /// identical stacks share one mask. null if the mask could not be built
    /// (e.g. every sprite in the stack is missing). Used by the occlusion
    /// inset - see DESIGN → Decorations & Footprint → Occlusion inset.
    pub fn getCompositeInsetTexture(
        self: *TextureStore,
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

    /// The baked-arrow cache key for a params set:
    /// `arrow|{variant}|{length}|{bow}|{width}` - one
    /// entry per distinct baked shape (the flat-composite-key convention
    /// of `outlineCacheKey`). A STORED key owns its string (duped at
    /// insert, freed in deinit); lookups may pass a stack-buffer borrow.
    fn arrowCacheKey(buffer: []u8, params: ui.BakedArrowParams) []const u8 {
        return std.fmt.bufPrint(buffer, "arrow|{s}|{d}|{d}|{d}", .{
            @tagName(params.variant),
            params.length,
            params.bow,
            params.width,
        }) catch @panic("arrow cache key overflow");
    }

    /// The arrow hover-outline cache key: the arrow shape's key plus an
    /// `outline` marker. No band axis - baked arrows draw 1:1 (destination
    /// = canvas size), so the band is always the constant outline width in
    /// source px (unlike sprite masks, which compensate per drawn scale).
    fn arrowOutlineCacheKey(buffer: []u8, params: ui.BakedArrowParams) []const u8 {
        return std.fmt.bufPrint(buffer, "arrow|outline|{s}|{d}|{d}|{d}", .{
            @tagName(params.variant),
            params.length,
            params.bow,
            params.width,
        }) catch @panic("arrow outline cache key overflow");
    }

    /// The baked arrow texture for `params` (the black outline + white
    /// inner stroke rasterized from the arrow families' canonical shape -
    /// see campaign_geometry.zig): drawn once per distinct shape and
    /// reused by every edge of that shape, tinted + rotated at the draw
    /// site. Lazily baked via `ensureArrowBaked`. null if the bake failed
    /// (cached miss) - the caller falls back to the per-segment draw.
    pub fn getArrowTexture(self: *TextureStore, params: ui.BakedArrowParams) ?rl.Texture2D {
        var key_buffer: [path_buffer_size]u8 = undefined;
        const key = arrowCacheKey(&key_buffer, params);
        if (!self.arrow_cache.contains(key)) self.ensureArrowBaked(key, params);
        return self.arrow_cache.get(key).?;
    }

    /// The precomputed OUTER hover-outline mask for a baked arrow shape: a
    /// white opaque halo just outside the arrow's full silhouette (black
    /// outline included - the halo outlines the whole drawn thing, the
    /// sprite-hover convention), at the constant outline width in SOURCE px
    /// (baked arrows draw 1:1, so no scale compensation - see
    /// `arrowOutlineCacheKey`). The mask rides the arrow's own canvas, so
    /// the rim draw is the SAME rotated quad as the arrow's, texture + tint
    /// swapped. Lazily generated via `ensureArrowOutlineLoaded` on the first
    /// hover; null (cached) if generation failed - the caller falls back to
    /// the widened per-segment rim.
    pub fn getArrowOutlineTexture(self: *TextureStore, params: ui.BakedArrowParams) ?rl.Texture2D {
        var key_buffer: [path_buffer_size]u8 = undefined;
        const key = arrowOutlineCacheKey(&key_buffer, params);
        if (!self.arrow_outline_cache.contains(key)) self.ensureArrowOutlineLoaded(key, params);
        return self.arrow_outline_cache.get(key).?;
    }

    /// Rasterize + cache the arrow for `params`: the headless rasterizer
    /// paints the straight-alpha silhouette, then the same upload path
    /// every composited texture takes (premultiply for
    /// BLEND_ALPHA_PREMULTIPLY, trilinear mipmaps - see
    /// `premultiplyAlpha`/`rgbaBufToTexture`). Idempotent via
    /// `arrow_cache` presence; caches null on failure.
    fn ensureArrowBaked(self: *TextureStore, lookup_key: []const u8, params: ui.BakedArrowParams) void {
        const owned_key = self.allocator.dupe(u8, lookup_key) catch
            @panic("failed to dupe arrow cache key");

        const texture: ?rl.Texture2D = blk: {
            const canvas = ui.bakedArrowCanvas(params);
            const width: i32 = @intCast(canvas.width);
            const height: i32 = @intCast(canvas.height);
            const pixels = self.allocator.alloc(u8, @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4) catch
                break :blk null;
            defer self.allocator.free(pixels);
            ui.rasterizeBakedArrow(params, canvas, pixels);

            var image = rl.Image{
                .data = @ptrCast(pixels.ptr),
                .width = width,
                .height = height,
                .mipmaps = 1,
                .format = .uncompressed_r8g8b8a8,
            };
            premultiplyAlpha(&image);
            break :blk self.rgbaBufToTexture(pixels, width, height) catch null;
        };

        self.arrow_cache.put(self.allocator, owned_key, texture) catch
            @panic("failed to cache baked arrow");
    }

    /// Generate + cache the arrow's hover-outline mask: re-rasterize the
    /// arrow's silhouette (the same pure rasterizer the baked texture
    /// rides - identical pixels by purity, no GPU readback), threshold its
    /// alpha (same >16 cutoff as every other mask), and dilate it OUTER at
    /// the constant outline width - the third caller of `dilateToMask`
    /// (after the single-sprite and composite-inset paths). Idempotent via
    /// `arrow_outline_cache` presence; caches null on failure.
    fn ensureArrowOutlineLoaded(self: *TextureStore, lookup_key: []const u8, params: ui.BakedArrowParams) void {
        const owned_key = self.allocator.dupe(u8, lookup_key) catch
            @panic("failed to dupe arrow outline cache key");

        const mask: ?rl.Texture2D = blk: {
            const canvas = ui.bakedArrowCanvas(params);
            const width: i32 = @intCast(canvas.width);
            const height: i32 = @intCast(canvas.height);
            const pixel_count: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height));

            const pixels = self.allocator.alloc(u8, pixel_count * 4) catch break :blk null;
            defer self.allocator.free(pixels);
            ui.rasterizeBakedArrow(params, canvas, pixels);

            const opaque_mask = self.allocator.alloc(u8, pixel_count) catch break :blk null;
            defer self.allocator.free(opaque_mask);
            for (opaque_mask, 0..) |*slot, index| {
                // Straight-alpha RGBA: the alpha byte is the threshold input.
                slot.* = if (pixels[index * 4 + 3] > 16) 1 else 0;
            }

            const band = self.dilateToMask(opaque_mask, width, height, types.outline_thickness, .outer) catch break :blk null;
            defer self.allocator.free(band);
            break :blk self.rgbaBufToTexture(band, width, height) catch null;
        };

        self.arrow_outline_cache.put(self.allocator, owned_key, mask) catch
            @panic("failed to cache arrow outline mask");
    }

    /// Build and cache the INNER outline mask for a composited silhouette.
    /// Decodes each sprite in `stack`, ORs its alpha (alpha > 16) into a
    /// frame-sized opaque mask (honoring `flip_horizontal` and
    /// `source_rectangle`), then dilates the union. Compositing before
    /// dilating is required for the INNER band: a weapon overlapping the
    /// body would otherwise leave a spurious internal edge (dilation doesn't
    /// distribute over intersection for the inner dual). Caches into
    /// `composite_inset_cache` under `key` (already built by the caller and
    /// freed there - `ensureCompositeInsetLoaded` dupes its own copy).
    fn ensureCompositeInsetLoaded(
        self: *TextureStore,
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
        self: *TextureStore,
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
        self: *TextureStore,
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

        const buf = try self.dilateToMask(opaque_mask, frame_width, frame_height, types.outline_thickness, side);
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
        self: *TextureStore,
        opaque_mask: []u8,
        frame_width: i32,
        frame_height: i32,
        sprite: types.StackSprite,
    ) !void {
        var path_buffer: [path_buffer_size]u8 = undefined;
        const path = assetPathFor(sprite.sprite_id, &path_buffer);
        const bytes = self.file_source.readFile(self.allocator, path) catch return error.MissingSprite;
        defer self.allocator.free(bytes);
        var image = rl.loadImageFromMemory(".png", bytes) catch return error.MissingSprite;
        defer rl.unloadImage(image);
        // Same custom-art dims gate as the main texture path: a gated
        // sprite contributes no alpha to the composite mask (the inset
        // trace matches what's actually drawn - the magenta fallback).
        if (!types.customSpriteDimsPassGate(sprite.sprite_id, .{ .x = image.width, .y = image.height })) {
            return error.MissingSprite;
        }
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

    /// Load `sprite_id` from the file source, decode, and cache the main
    /// texture only (the outline mask is generated lazily by
    /// `ensureOutlineLoaded`). A missing/unreadable asset is a normal
    /// in-progress state -> cache null and fall through to the magenta
    /// fallback at draw sites. Idempotent: presence in `texture_cache` marks
    /// the load attempted.
    fn ensureSpriteLoaded(self: *TextureStore, sprite_id: []const u8) void {
        if (self.texture_cache.contains(sprite_id)) return;

        var path_buffer: [path_buffer_size]u8 = undefined;
        const path = assetPathFor(sprite_id, &path_buffer);
        const key = self.allocator.dupe(u8, sprite_id) catch @panic("failed to dupe sprite id");

        const texture: ?rl.Texture2D = blk: {
            const bytes = self.file_source.readFile(self.allocator, path) catch
                break :blk null;
            defer self.allocator.free(bytes);
            var image = rl.loadImageFromMemory(".png", bytes) catch break :blk null;
            defer rl.unloadImage(image);
            // Custom-art dims gate: non-conforming mission-bundled art is
            // treated as missing (the magenta fallback) - off-grid art is
            // never silently rendered. The load side already warned +
            // degraded the geometry (loaders.zig); shipped art and other
            // prefixes are never gated (`customSpriteDimsPassGate`).
            if (!types.customSpriteDimsPassGate(sprite_id, .{ .x = image.width, .y = image.height })) {
                break :blk null;
            }
            // Normalize to RGBA8 so premultiply has a stable byte layout.
            image.setFormat(.uncompressed_r8g8b8a8);
            // Premultiply RGB by alpha before upload. With the render pass's
            // `BLEND_ALPHA_PREMULTIPLY` blend mode, bilinear downsampling
            // (the 4K design space → smaller render target) blends in
            // premultiplied space, so transparent-edge pixels (RGB=0 after
            // premultiply) contribute zero color - no dark halo. Straight-
            // alpha textures under a premultiplied blend render too dark, so
            // EVERY composited texture must be premultiplied. See DESIGN →
            // Platform Seam → Render target resolution (premultiplied alpha).
            premultiplyAlpha(&image);
            var tex = rl.loadTextureFromImage(image) catch break :blk null;
            // Mipmapped trilinear filtering: sprite textures are minified
            // by world zoom x the render camera zoom, and bilinear-only
            // sampling hardens edges past 2:1 (see `enableTrilinearMipmaps`).
            enableTrilinearMipmaps(&tex);
            break :blk tex;
        };

        self.texture_cache.put(self.allocator, key, texture) catch @panic("failed to cache texture");
    }

    /// Build and cache the OUTER edge-outline mask for `sprite_id` at
    /// `band_source_pixels` (the scale-compensated band). Re-reads the
    /// asset bytes and decodes - outlines are requested for few sprites (a
    /// handful of UI icons), so a second read per outlined sprite is far
    /// cheaper than holding decoded images for every sprite. Caches null on
    /// miss/failure. Idempotent via `outline_cache` presence. The stored
    /// key owns its duped composite string (see `outlineCacheKey`).
    fn ensureOutlineLoaded(self: *TextureStore, sprite_id: []const u8, band_source_pixels: i32) void {
        var key_buffer: [path_buffer_size]u8 = undefined;
        const lookup_key = outlineCacheKey(&key_buffer, sprite_id, band_source_pixels);
        if (self.outline_cache.contains(lookup_key)) return;
        const key = self.allocator.dupe(u8, lookup_key) catch @panic("failed to dupe outline cache key");

        var path_buffer: [path_buffer_size]u8 = undefined;
        const path = assetPathFor(sprite_id, &path_buffer);

        const outline: ?rl.Texture2D = blk: {
            const bytes = self.file_source.readFile(self.allocator, path) catch
                break :blk null;
            defer self.allocator.free(bytes);
            var image = rl.loadImageFromMemory(".png", bytes) catch break :blk null;
            defer rl.unloadImage(image);
            // Same custom-art dims gate as the main texture path: a gated
            // sprite has no outline mask (the highlight falls back to a
            // rectangle ring around the magenta box).
            if (!types.customSpriteDimsPassGate(sprite_id, .{ .x = image.width, .y = image.height })) {
                break :blk null;
            }
            // Normalize to RGBA so alpha is always at the same byte offset.
            image.setFormat(.uncompressed_r8g8b8a8);
            break :blk self.generateOutlineMask(image, band_source_pixels, .outer) catch null;
        };

        self.outline_cache.put(self.allocator, key, outline) catch @panic("failed to cache outline mask");
    }

    /// The opaque-pixel bounding box of `sprite_id` (top/bottom/left/right,
    /// in SOURCE pixels), or null if the sprite can't be loaded/decoded.
    /// Lazily generated on first request via `ensureSpriteBoundsLoaded`
    /// (one decode fills all four edges). Used by `view()` (via the
    /// `RenderContext.sprite_bounds` lookup) to place overlays against an
    /// entity's actual rendered art. See AGENTS Animation.
    fn getSpriteBounds(self: *TextureStore, sprite_id: []const u8) ?types.SpriteBounds {
        if (!self.sprite_bounds_cache.contains(sprite_id)) self.ensureSpriteBoundsLoaded(sprite_id);
        return self.sprite_bounds_cache.get(sprite_id).?;
    }

    /// Convenience wrapper: look up the opaque-pixel bounding box for an
    /// ENTITY sprite given its bare stem (e.g. `skeleton_1`), prefixing the
    /// `entities/` folder so `frame()` can query without knowing the
    /// asset-path format. See AGENTS Animation.
    pub fn entitySpriteBounds(
        self: *TextureStore,
        allocator: std.mem.Allocator,
        bare_stem: []const u8,
    ) ?types.SpriteBounds {
        const sprite_id = std.fmt.allocPrint(allocator, "entities/{s}", .{bare_stem}) catch
            @panic("failed to build entity sprite id for bounds lookup");
        return self.getSpriteBounds(sprite_id);
    }

    /// Opaque-pixel bounding box for a FULL sprite id (any namespace) - the
    /// general form of `entitySpriteBounds`. Used for NPC bounds
    /// (`npcs/<npc_type>`).
    pub fn spriteBounds(self: *TextureStore, sprite_id: []const u8) ?types.SpriteBounds {
        return self.getSpriteBounds(sprite_id);
    }

    fn ensureSpriteBoundsLoaded(self: *TextureStore, sprite_id: []const u8) void {
        if (self.sprite_bounds_cache.contains(sprite_id)) return;

        var path_buffer: [path_buffer_size]u8 = undefined;
        const path = assetPathFor(sprite_id, &path_buffer);
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
    fn scanOpaqueBounds(self: *TextureStore, image: rl.Image) !?types.SpriteBounds {
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
    /// pixels stay transparent - a halo just OUTSIDE the silhouette, so the
    /// sprite's own art is never overpainted. INNER: the morphological dual -
    /// opaque pixels within `thickness` of a transparent pixel become white;
    /// transparent pixels stay transparent - a rim just INSIDE the silhouette,
    /// used by the occlusion inset to trace an occluded entity's edge over a
    /// decoration. Dilation uses a DISK structuring element (offsets with
    /// dx²+dy² ≤ t²), which is not separable - a single 2D pass,
    /// O(|band pixels| × |disk|), instead of the square (Chebyshev) SE's
    /// O(w·h·2t) separable path. The mask is cached per sprite (built once),
    /// so the higher cost is amortized; the payoff is smoother 45° corners
    /// (the square SE's band was ~√2 thicker along diagonals). The band is
    /// clipped at the canvas border (a sprite filling its canvas edge-to-edge
    /// gets no band on that side); current art ships with enough margin that
    /// this never shows. See DESIGN → Decorations & Footprint → Occlusion inset.
    fn generateOutlineMask(self: *TextureStore, image: rl.Image, thickness: i32, side: OutlineSide) !rl.Texture2D {
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
        self: *TextureStore,
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
        // |disk| ≈ π·t² (~217 offsets at t=8). The (0,0) offset is skipped -
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
    /// caller. Shared by the single-sprite, composite-inset, and
    /// baked-arrow-outline mask paths.
    fn rgbaBufToTexture(self: *TextureStore, buf: []u8, width: i32, height: i32) !rl.Texture2D {
        _ = self;
        const mask_image = rl.Image{
            .data = @ptrCast(buf.ptr),
            .width = width,
            .height = height,
            .mipmaps = 1,
            .format = .uncompressed_r8g8b8a8,
        };
        var tex = rl.loadTextureFromImage(mask_image) catch return error.LoadTexture;
        // Mipmapped trilinear filtering: masks are drawn scaled (world zoom
        // x the render camera zoom) and their binary edges minify harshly
        // past 2:1 (see `enableTrilinearMipmaps`). Mip-averaging turns the
        // binary edge into proper fractional coverage.
        enableTrilinearMipmaps(&tex);
        return tex;
    }
};

/// Generate a texture's mip chain and switch it to trilinear filtering -
/// the fix for harsh sprite edges at zooms below 1:1. Bilinear-only
/// minification reads just the 2x2 texels nearest each sample point:
/// correct at an aligned 2:1 (it degrades into a box filter), but past
/// that it skips the texels each destination pixel covers (default camera
/// zoom 50% x the 0.5 renderScale = 1/4 source scale on a 1080p target),
/// which reads as hard, shimmering edges. The mip chain gives the GPU
/// pre-box-filtered levels to sample at any scale, so every source texel
/// contributes; averaging premultiplied RGBA is correct by construction.
/// Trilinear = bilinear within a level + a linear blend between adjacent
/// levels, so zooming is continuous. Cost: ~33% extra VRAM per texture,
/// built GPU-side once at load; magnified/1:1 draws still sample the base
/// level, so nothing sharp gets blurred. Apply to EVERY sprite-side
/// texture (the TextureStore load sites cover shipped, shadowed, and
/// custom-mission art uniformly) - NOT to the SDF font atlas (a distance
/// field box-filtered between levels would move glyph edges; it stays
/// bilinear) or the render-target blit texture (a <=2:1 downscale per
/// frame; per-frame mip generation would cost for no visible gain - it
/// stays bilinear). See DESIGN → Platform Seam → Sprite-mipmap smoothing.
fn enableTrilinearMipmaps(texture: *rl.Texture2D) void {
    rl.genTextureMipmaps(texture);
    rl.setTextureFilter(texture.*, .trilinear);
}

/// Premultiply RGB by alpha in-place (for `BLEND_ALPHA_PREMULTIPLY`).
/// For each pixel: r = r*a/255, g = g*a/255, b = b*a/255 (alpha
/// unchanged). With premultiplied textures, bilinear downsampling blends
/// in premultiplied space - transparent-edge pixels (RGB=0) contribute
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
