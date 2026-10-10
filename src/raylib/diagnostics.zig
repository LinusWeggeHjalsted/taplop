//! Diagnostics probe sites for the raylib backend — the GL-touching half
//! of the diagnostics subsystem. The raylib-free `src/diagnostics.zig`
//! owns the buffer + section policy + flush scheduling; these functions
//! gather raw values at the backend's probe sites (GL context identity,
//! first-draw draw state, render-target pixels) and record them as plain
//! data, so all `rl.*` stays in this directory and the type compiles in
//! the headless test build. Activation is a RUNTIME flag on the type
//! (`Diagnostics.enabled`: the `--diagnostics` CLI flag, defaulting to
//! `default_enabled` below — dev-mode native builds); the code ships in
//! every native build. Settled design: DESIGN → Platform Seam →
//! Diagnostics.

const std = @import("std");
const rl = @import("raylib");
const types = @import("../types.zig");
const ui = @import("../ui.zig");
const diagnostics_mod = @import("../diagnostics.zig");

const Diagnostics = diagnostics_mod.Diagnostics;

/// Default activation: dev-mode native builds. The `--diagnostics` CLI
/// flag ORs in on top of this (any build, release included); web has no
/// flag and stays off.
pub const default_enabled = @import("build_info").dev_mode and
    @import("builtin").os.tag != .emscripten;

// GL context identity, for the boot section. raylib links GL on every
// native target (framework on mac, libGL on Linux, opengl32 on Windows), so
// the symbol resolves; only referenced from here (ships in all native
// builds; the call is skipped unless active).
extern "c" fn glGetString(name: c_int) ?[*:0]const u8;
const gl_vendor: c_int = 0x1F00;
const gl_renderer: c_int = 0x1F01;
const gl_version: c_int = 0x1F02;
const gl_shading_language_version: c_int = 0x8B8C;

fn glString(name: c_int) []const u8 {
    const string = glGetString(name) orelse return "(null)";
    return std.mem.sliceTo(string, 0);
}

fn referenceRectangle(rect: rl.Rectangle) types.Rectangle {
    return .{
        .x = @intFromFloat(rect.x),
        .y = @intFromFloat(rect.y),
        .width = @intFromFloat(rect.width),
        .height = @intFromFloat(rect.height),
    };
}

/// Boot section: gather window/framebuffer/render-target dims + the GL
/// identity strings (called at first render, when the context is live)
/// and record them.
pub fn recordBoot(
    diagnostics: *Diagnostics,
    render_width: i32,
    render_height: i32,
    sprite_shader_compiled: bool,
    outline_stripe_shader_compiled: bool,
    sdf_shader_compiled: bool,
) void {
    diagnostics.recordBoot(.{
        .window_width = rl.getScreenWidth(),
        .window_height = rl.getScreenHeight(),
        .framebuffer_width = rl.getRenderWidth(),
        .framebuffer_height = rl.getRenderHeight(),
        .render_target_width = render_width,
        .render_target_height = render_height,
        .gl_vendor = glString(gl_vendor),
        .gl_renderer = glString(gl_renderer),
        .gl_version = glString(gl_version),
        .gl_shading_language_version = glString(gl_shading_language_version),
        .sprite_shader_compiled = sprite_shader_compiled,
        .outline_stripe_shader_compiled = outline_stripe_shader_compiled,
        .sdf_shader_compiled = sdf_shader_compiled,
    });
}

/// First plain-sprite-draw probe (the known-WORKING control): convert the
/// raylib draw state to values and record.
pub fn recordFirstSpriteDraw(
    diagnostics: *Diagnostics,
    sprite_id: []const u8,
    texture: rl.Texture2D,
    source: rl.Rectangle,
    destination: rl.Rectangle,
    tint: types.Color,
    alpha: u8,
) void {
    diagnostics.recordFirstSpriteDraw(.{
        .sprite_id = sprite_id,
        .texture_id = texture.id,
        .texture_width = texture.width,
        .texture_height = texture.height,
        .source = referenceRectangle(source),
        .destination = referenceRectangle(destination),
        .tint = tint,
        .alpha = alpha,
    });
}

/// First 9-slice-panel-draw probe: full draw state (texture, tint before +
/// after default-tint resolution, destination, all nine rect pairs) to
/// diff against the control.
pub fn recordFirstPanelDraw(
    diagnostics: *Diagnostics,
    panel: ui.NineSlicePanel,
    texture: rl.Texture2D,
    resolved_tint: rl.Color,
    theme_darkest: types.Color,
    destination: types.Rectangle,
    pieces: [9]ui.NineSlicePiece,
) void {
    diagnostics.recordFirstPanelDraw(.{
        .sprite_id = panel.sprite_id,
        .texture_id = texture.id,
        .texture_width = texture.width,
        .texture_height = texture.height,
        .panel_color = panel.color,
        .theme_darkest = theme_darkest,
        .resolved_tint = .{ .r = resolved_tint.r, .g = resolved_tint.g, .b = resolved_tint.b },
        .resolved_tint_alpha = resolved_tint.a,
        .destination = destination,
        .pieces = pieces,
    });
}

/// Read back the render target at the end of a frame where a probe fired
/// and record the pixels at the probed destinations. Loads the target +
/// computes the samples here (all `rl.*` stays raylib-side); the type only
/// formats + flushes the values. Samples are in TARGET space (reference ×
/// the render camera zoom); RenderTextures are stored y-flipped, so the
/// sampled row is flipped back.
pub fn recordTargetReadback(
    diagnostics: *Diagnostics,
    render_target: rl.RenderTexture2D,
    render_width: i32,
    render_height: i32,
    render_scale: f32,
) void {
    const image = rl.loadImageFromTexture(render_target.texture) catch return;
    defer rl.unloadImage(image);
    const colors = rl.loadImageColors(image) catch return;
    defer rl.unloadImageColors(colors);

    // At most 2 destinations x 3 samples each.
    var samples: [6]diagnostics_mod.PixelSample = undefined;
    var sample_count: usize = 0;
    if (diagnostics.panelDestination()) |rect| {
        sample_count += collectSamples(
            samples[sample_count..],
            colors,
            "panel",
            rect,
            render_width,
            render_height,
            render_scale,
        );
    }
    if (diagnostics.spriteDestination()) |rect| {
        sample_count += collectSamples(
            samples[sample_count..],
            colors,
            "control",
            rect,
            render_width,
            render_height,
            render_scale,
        );
    }
    diagnostics.recordTargetReadback(samples[0..sample_count], image.width, image.height);
}

/// Sample three pixels along the horizontal center line of a probed
/// destination (25/50/75% — inside the 9-slice corner band at both ends
/// for a typical panel, center in the stretched middle) into `out`;
/// returns how many landed in bounds. Bounds are target space; the stored
/// row is flipped back (RenderTextures are y-up).
fn collectSamples(
    out: []diagnostics_mod.PixelSample,
    colors: []rl.Color,
    label: []const u8,
    rect: types.Rectangle,
    render_width: i32,
    render_height: i32,
    render_scale: f32,
) usize {
    const target_width: i64 = render_width;
    const target_height: i64 = render_height;
    var count: usize = 0;
    for ([_]f32{ 0.25, 0.5, 0.75 }) |fraction| {
        const column: i64 = @intFromFloat((@as(f32, @floatFromInt(rect.x)) +
            @as(f32, @floatFromInt(rect.width)) * fraction) * render_scale);
        const target_row: i64 = @intFromFloat((@as(f32, @floatFromInt(rect.y)) +
            @as(f32, @floatFromInt(rect.height)) * 0.5) * render_scale);
        const stored_row: i64 = target_height - 1 - target_row;
        if (column < 0 or stored_row < 0 or column >= target_width or stored_row >= target_height) continue;
        const index: usize = @intCast(stored_row * target_width + column);
        if (index >= colors.len) continue;
        const color = colors[index];
        out[count] = .{
            .label = label,
            .fraction = fraction,
            .column = column,
            .row = target_row,
            .color = .{ .r = color.r, .g = color.g, .b = color.b },
            .alpha = color.a,
        };
        count += 1;
    }
    return count;
}
