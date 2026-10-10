//! World + UI element drawing for the raylib backend: the tile/overlay/
//! ground-drawable/world-overlay passes and the flat UI element list, as
//! free functions over the backend (the handlers/ pattern — the backend
//! driver in backend.zig calls these from `render`). Texture lookups go
//! through the backend's texture store, text through its text renderer;
//! see DESIGN → Platform Seam (rendering model).

const std = @import("std");
const rl = @import("raylib");
const types = @import("../types.zig");
const ui = @import("../ui.zig");
const input = @import("../input.zig");
const backend_mod = @import("backend.zig");
const conversions = @import("conversions.zig");
const textures_mod = @import("textures.zig");
const text_mod = @import("text.zig");
const diagnostics_mod = @import("diagnostics.zig");

const RaylibBackend = backend_mod.RaylibBackend;
const toRaylibColor = conversions.toRaylibColor;
const toPremultipliedColor = conversions.toPremultipliedColor;
const referenceRectangle = conversions.referenceRectangle;

/// Text-field caret bar thickness (reference px) — matches the unified
/// outline thickness so the caret reads at the same visual weight as the
/// world outlines.
const caret_width: i32 = 8;

// -- World drawing --

/// Draw a tile overlay as an outline-class primitive (no overlay art):
/// the clickable-tile highlight (an inset square outline), the cursor /
/// range / radius / aggro square outlines, and the region-edge bars. The
/// outline thickness is the shared mask thickness (8 source px, see
/// textures.zig) × `world_scale`; range/radius/aggro outlines may span
/// multiple tiles via `extent` (side in tiles, default 1).
pub fn drawTileOverlay(backend: *RaylibBackend, overlay: types.TileOverlayDrawable, world_scale: f32) void {
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
            // The clickable-tile highlight: an inset square outline — the
            // same outline class as the cursor/range outlines (shared
            // thickness + marching stripe treatment), inset 1/16 of the
            // tile: the retired `world/tile_highlight` marching-ants
            // sheet's band position (16 source px of the 256 tile).
            const inset = side /
                @as(f32, @floatFromInt(ui.tile_highlight_inset_divisor));
            const inset_rectangle = rl.Rectangle{
                .x = rectangle.x + inset,
                .y = rectangle.y + inset,
                .width = rectangle.width - 2 * inset,
                .height = rectangle.height - 2 * inset,
            };
            backend.beginOutlineStripeScope();
            rl.drawRectangleLinesEx(inset_rectangle, line_width, toRaylibColor(overlay.color, 255));
            backend.endOutlineStripeScope(world_scale * backend.renderScale());
        },
        // The square outlines (the hovered tile + the range/radius/aggro
        // region outlines — one primitive) all draw through the outline
        // stripe shader: the marching flip between the outline tint and
        // the theme's darkest (see DESIGN → Platform Seam → Outline stripe
        // shader). The scope wraps exactly this draw — endShaderMode
        // restores the DEFAULT shader, not the sprite pass (see
        // beginSpritePass).
        .cursor, .range_outline, .radius_outline, .aggro_outline => {
            backend.beginOutlineStripeScope();
            rl.drawRectangleLinesEx(rectangle, line_width, toRaylibColor(overlay.color, 255));
            backend.endOutlineStripeScope(world_scale * backend.renderScale());
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
            // Same stripe treatment as the square outlines (each bar is
            // one stroke segment of the same region outline).
            backend.beginOutlineStripeScope();
            rl.drawRectangleRec(bar, toRaylibColor(overlay.color, 255));
            backend.endOutlineStripeScope(world_scale * backend.renderScale());
        },
    }
}

/// Draw a world sprite at its native texture size scaled by `world_scale`
/// (see ViewState.world_scale), anchored at `screen_position` (reference
/// space). `tint` multiplies the grayscale sprite (theme coloring).
pub fn drawWorldSprite(
    backend: *RaylibBackend,
    sprite_id: []const u8,
    screen_position: types.ScreenPosition,
    world_scale: f32,
    tint: types.Color,
) void {
    const texture = backend.textures.getTexture(sprite_id) orelse return;
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
    backend: *RaylibBackend,
    sprite: types.SpriteDrawable,
    world_scale: f32,
) void {
    const texture = backend.textures.getTexture(sprite.sprite_id) orelse return;
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
pub fn drawGroundDrawable(
    backend: *RaylibBackend,
    ground: types.GroundDrawable,
    world_scale: f32,
) void {
    switch (ground) {
        .entity => |entity| {
            for (entity.back_effect_sprites) |sprite| drawSpriteDrawable(backend, sprite, world_scale);
            drawSpriteDrawable(backend, entity.base_sprite, world_scale);
            for (entity.layer_sprites) |sprite| drawSpriteDrawable(backend, sprite, world_scale);
            for (entity.weapon_sprites) |maybe_sprite| {
                if (maybe_sprite) |sprite| drawSpriteDrawable(backend, sprite, world_scale);
            }
            for (entity.gear_sprites) |sprite| drawSpriteDrawable(backend, sprite, world_scale);
            for (entity.front_effect_sprites) |sprite| drawSpriteDrawable(backend, sprite, world_scale);
            if (entity.health_bar) |bar| drawHealthBar(backend, bar, world_scale);
        },
        .decoration_piece => |decoration| {
            // Back layers (`behind` config key) draw BEFORE the base; the
            // base's transparent pixels let them show through. Then the
            // base, then overlay layers in slice order.
            for (decoration.back_layers) |layer| {
                drawSpriteDrawable(backend, layer, world_scale);
            }
            drawSpriteDrawable(backend, .{
                .sprite_id = decoration.sprite_id,
                .screen_position = decoration.screen_position,
                .draw_offset = decoration.draw_offset,
                .source_rectangle = decoration.source_rectangle,
                .color = decoration.color,
            }, world_scale);
            for (decoration.layers) |layer| {
                drawSpriteDrawable(backend, layer, world_scale);
            }
        },
        .ground_items => |items| drawWorldSprite(backend, items.sprite_id, items.screen_position, world_scale, items.color),
        .level_end => |marker| {
            drawWorldSprite(backend, marker.sprite_id, marker.screen_position, world_scale, marker.color);
            // Animated banner over the pole: same screen position + pivot,
            // each banner frame is 256x512 (identical to the pole). Drawn
            // via drawSpriteDrawable so the source rectangle + world_scale
            // apply. See DESIGN → Animation.
            if (marker.banner_source_rectangle) |banner_rect| {
                drawSpriteDrawable(backend, .{
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
pub fn drawWorldOverlay(
    backend: *RaylibBackend,
    overlay: types.WorldOverlayDrawable,
    world_scale: f32,
) void {
    switch (overlay) {
        .floating_icon => |icon| {
            const texture = backend.textures.getTexture(icon.sprite_id) orelse return;
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
            const text_z = backend.frame_arena.allocator().dupeZ(u8, ftext.text) catch return;
            backend.text.drawOutlinedText(
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
    backend: *RaylibBackend,
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
    drawSprite(backend, "world/entity_health_bar_background", destination, null, bar.depleted_color, 255, false);
    // Fill (cropped to fraction from the left — `.right` keeps the left
    // portion, matching a health bar that depletes from the right).
    const fill_texture = backend.textures.getTexture("world/entity_health_bar_background") orelse return;
    const fraction = std.math.clamp(bar.fill_fraction, 0, 1);
    const tex_w: f32 = @floatFromInt(fill_texture.width);
    const tex_h: f32 = @floatFromInt(fill_texture.height);
    const fill_source = rl.Rectangle{ .x = 0, .y = 0, .width = tex_w * fraction, .height = tex_h };
    const fill_dest = rl.Rectangle{ .x = destination.x, .y = destination.y, .width = destination.width * fraction, .height = destination.height };
    rl.drawTexturePro(fill_texture, fill_source, fill_dest, .{ .x = 0, .y = 0 }, 0, toRaylibColor(bar.fill_color, 255));
    // Outline frame on top (same rect), tinted with the fill color so the
    // bar's border matches the entity's team gradient index 1.
    drawSprite(backend, "world/entity_health_bar_outline", destination, null, bar.fill_color, 255, false);
}

// -- UI element drawing --

pub fn drawUiElement(backend: *RaylibBackend, element: ui.UiElement, highlight_color: types.Color, theme_darkest: types.Color) void {
    switch (element) {
        .nine_slice_panel => |panel| drawNineSlice(backend, panel, theme_darkest),
        .slot => |slot| {
            if (slot.icon_sprite_id) |sprite_id| {
                drawSprite(backend, sprite_id, referenceRectangle(slot.screen_position, slot.size, slot.size), null, slot.icon_color, 255, false);
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
                drawSprite(backend, sprite_id, dest, null, button.color, 255, false);
                if (button.highlighted) drawHighlightOutline(backend, sprite_id, dest, highlight_color);
            } else if (button.highlighted) {
                // Stroked rect OUTSIDE the bounds: inflate by the outline
                // thickness on all sides so the stroke frames the button
                // instead of overlapping its edge (drawRectangleLinesEx
                // centers the stroke on the rect boundary). Spriteless
                // buttons sit on 9-slice panel cells (the editor tool
                // palette) — this stroked rect is their lightest hover
                // outline, so it gets the same stripe treatment as the
                // sprite-backed outlines above.
                const t: i32 = textures_mod.outline_thickness;
                const dest = referenceRectangle(button.screen_position, button.width, button.height);
                const outer = rl.Rectangle{
                    .x = dest.x - @as(f32, @floatFromInt(t)),
                    .y = dest.y - @as(f32, @floatFromInt(t)),
                    .width = dest.width + 2 * @as(f32, @floatFromInt(t)),
                    .height = dest.height + 2 * @as(f32, @floatFromInt(t)),
                };
                backend.beginOutlineStripeScope();
                rl.drawRectangleLinesEx(outer, @floatFromInt(t), toRaylibColor(highlight_color, 255));
                backend.endOutlineStripeScope(backend.renderScale());
            }
        },
        .text_label => |label| backend.text.drawTextLabel(backend.frame_arena.allocator(), label, highlight_color),
        .text_field => |field| {
            // Frame (9-slice, builder-tinted), selection highlight
            // UNDER the text, text, caret bar OVER it. The builder
            // computed every coordinate — the backend just draws (see
            // TextFieldUi).
            drawNineSlice(backend, .{
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
            backend.text.drawTextLabel(backend.frame_arena.allocator(), .{
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
        .fill_sprite => |fill| drawFillSprite(backend, fill),
        .image => |image| {
            const dest = referenceRectangle(image.screen_position, image.width, image.height);
            drawSprite(backend, image.sprite_id, dest, null, image.color, image.alpha, image.flip_horizontal);
            if (image.highlighted) drawHighlightOutline(backend, image.sprite_id, dest, highlight_color);
        },
        .solid_rect => |rect| {
            const r = referenceRectangle(rect.screen_position, rect.width, rect.height);
            if (rect.filled) {
                rl.drawRectangleRec(r, toRaylibColor(rect.color, 255));
            } else {
                // Stroked solid_rect IS the outline class by construction
                // (the element doc: same drawRectangleLinesEx primitive as
                // the world range/radius outlines; today's user is the
                // inventory multi-salvage drag region) — same stripe
                // treatment. The close restores the enclosing per-item
                // sprite pass (the endShaderMode trap).
                backend.beginOutlineStripeScope();
                rl.drawRectangleLinesEx(r, @floatFromInt(rect.line_width), toRaylibColor(rect.color, 255));
                backend.endOutlineStripeScope(backend.renderScale());
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
/// box) so the hover highlight still reads. Both paths draw through the
/// outline stripe shader (the marching flip between the highlight tint
/// and the theme's darkest — see DESIGN → Platform Seam → Outline stripe
/// shader).
fn drawHighlightOutline(backend: *RaylibBackend, sprite_id: []const u8, destination: rl.Rectangle, highlight_color: types.Color) void {
    // The scope covers BOTH paths (mask + rectangle fallback) — the whole
    // function is one outlined draw. The close restores the enclosing
    // per-item sprite pass (the endShaderMode trap — see
    // endOutlineStripeScope).
    backend.beginOutlineStripeScope();
    defer backend.endOutlineStripeScope(backend.renderScale());
    const mask = backend.textures.getOutlineTexture(sprite_id) orelse {
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
pub fn drawOcclusionInset(
    backend: *RaylibBackend,
    inset: types.OcclusionInsetDrawable,
    world_scale: f32,
) void {
    const mask = backend.textures.getCompositeInsetTexture(inset.sprite_stack, inset.frame_width, inset.frame_height) orelse return;
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
    backend: *RaylibBackend,
    sprite_id: []const u8,
    destination: rl.Rectangle,
    source: ?rl.Rectangle,
    tint: types.Color,
    alpha: u8,
    flip_horizontal: bool,
) void {
    const texture = backend.textures.getTexture(sprite_id) orelse {
        rl.drawRectangleRec(destination, rl.Color.magenta);
        return;
    };
    const whole = rl.Rectangle{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(texture.width),
        .height = @floatFromInt(texture.height),
    };
    var effective = source orelse whole;
    // A negative source width tells DrawTexturePro to mirror horizontally
    // (the same trick as drawSpriteDrawable).
    if (flip_horizontal) effective.width = -effective.width;
    if (backend.diagnostics.shouldRecordFirstSpriteDraw()) {
        diagnostics_mod.recordFirstSpriteDraw(&backend.diagnostics, sprite_id, texture, source orelse whole, destination, tint, alpha);
    }
    rl.drawTexturePro(texture, effective, destination, .{ .x = 0, .y = 0 }, 0, toPremultipliedColor(tint, alpha));
}

/// 9-slice: every corner is drawn square (aspect-true 1:1) and the edges
/// + center stretch to fill — the rect math lives in the pure, tested
/// `ui.nineSlicePieces` (corners shrink proportionally on panels smaller
/// than two slices instead of being squashed).
fn drawNineSlice(backend: *RaylibBackend, panel: ui.NineSlicePanel, theme_darkest: types.Color) void {
    const texture = backend.textures.getTexture(panel.sprite_id) orelse {
        rl.drawRectangleRec(referenceRectangle(panel.screen_position, panel.width, panel.height), rl.Color.magenta);
        return;
    }; // `default_tint` (pure white) is the "unset" sentinel: a panel that
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
    if (backend.diagnostics.shouldRecordFirstPanelDraw()) {
        diagnostics_mod.recordFirstPanelDraw(&backend.diagnostics, panel, texture, tint, theme_darkest, destination, pieces);
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

fn drawFillSprite(backend: *RaylibBackend, fill: ui.FillSprite) void {
    const destination = referenceRectangle(fill.screen_position, fill.width, fill.height);
    // Background (e.g. depleted health) drawn whole.
    drawSprite(backend, fill.background_sprite_id, destination, null, fill.background_color, 255, false);

    const texture = backend.textures.getTexture(fill.fill_sprite_id) orelse return;
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
