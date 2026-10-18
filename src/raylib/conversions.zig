//! Shared raylib conversion helpers for the backend's files: game Color →
//! raylib Color (straight + premultiplied) and reference-space rect
//! construction. Pure value mapping, no state.

const rl = @import("raylib");
const types = @import("../types.zig");

pub fn toRaylibColor(color: types.Color, alpha: u8) rl.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha };
}

/// Premultiplied tint for draws under `BLEND_ALPHA_PREMULTIPLY`: the RGB is
/// scaled by alpha so a translucent draw contributes proportionally dimmed
/// color (raylib multiplies the fragment color by the tint; with a straight-
/// alpha tint the RGB contribution wouldn't be scaled by the alpha and the
/// draw would render too bright). For textures the premultiplied texel RGB
/// is additionally scaled by the tint RGB, so the total contribution is
/// texelRGB*texelA*tintA - exactly "the sprite at opacity tintA". Used for
/// translucent rectangle fills (tile highlights) and partial-alpha sprite
/// draws (`UiElement.image.alpha`). Opaque (255) tints are identity.
/// See DESIGN → Platform Seam → Render target resolution (premultiplied
/// alpha).
pub fn toPremultipliedColor(color: types.Color, alpha: u8) rl.Color {
    const a: u16 = alpha;
    return .{
        .r = @intCast((@as(u16, color.r) * a + 127) / 255),
        .g = @intCast((@as(u16, color.g) * a + 127) / 255),
        .b = @intCast((@as(u16, color.b) * a + 127) / 255),
        .a = alpha,
    };
}

pub fn referenceRectangle(screen_position: types.ScreenPosition, width: i32, height: i32) rl.Rectangle {
    return .{
        .x = @floatFromInt(screen_position.x),
        .y = @floatFromInt(screen_position.y),
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    };
}
