//! Dev diagnostics for the raylib backend (dev-mode native builds only):
//! a best-effort log flushed to "logs/diagnostics.txt" in the persistent dir after
//! every section. Purpose: troubleshooting on machines without a Terminal
//! workflow (the mac port bring-up; TODO → macOS native port) — the file
//! lands next to the session logs where a player can attach it. Sections:
//! boot-time GL context info, a one-shot probe of the first plain sprite
//! draw (the known-WORKING control), a one-shot probe of the first 9-slice
//! panel draw (the mac panels-don't-render bug — same drawTexturePro path
//! as sprites, so the probe dumps the full draw state to diff against the
//! control), and a render-target pixel readback on the frame a probe fired.
//! Not on web: the browser console + the node headless trick already cover
//! it (AGENTS → Build & Test). The `enabled` const is comptime-gated; in
//! non-dev builds the probe call sites compile out and none of this is
//! analyzed or linked. A REDESIGN is settled (a raylib-free
//! src/diagnostics.zig driven by a --diagnostics CLI flag — see DESIGN →
//! Platform Seam → Diagnostics); this file is the landing spot its
//! value-recording call sites will hollow out.

const std = @import("std");
const rl = @import("raylib");
const types = @import("../types.zig");
const ui = @import("../ui.zig");

/// Comptime gate: dev-mode builds, never on emscripten.
pub const enabled = @import("build_info").dev_mode and
    @import("builtin").os.tag != .emscripten;

// GL context identity, for the boot section. raylib links GL on every
// native target (framework on mac, libGL on Linux, opengl32 on Windows), so
// the symbol resolves; only referenced from diag code (dev builds).
extern "c" fn glGetString(name: c_int) ?[*:0]const u8;
const gl_vendor: c_int = 0x1F00;
const gl_renderer: c_int = 0x1F01;
const gl_version: c_int = 0x1F02;
const gl_shading_language_version: c_int = 0x8B8C;

fn glString(name: c_int) []const u8 {
    const string = glGetString(name) orelse return "(null)";
    return std.mem.sliceTo(string, 0);
}

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    file_source: *const @import("../file_source.zig").FileSource,

    /// Log buffer: holds the accumulated "logs/diagnostics.txt" content; rewritten
    /// whole on every flush. Freed in deinit (dev builds only — in non-dev
    /// builds the few unconditional appends are process-lifetime, same as
    /// the previous shape).
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    boot_logged: bool = false,
    sprite_probe_logged: bool = false,
    panel_probe_logged: bool = false,
    /// Reference-space destinations captured by the one-shot probes, read
    /// back from the render target at the end of the same frame — the probes
    /// fire mid-draw, the pixels only exist after `endTextureMode`.
    panel_destination: ?types.Rectangle = null,
    sprite_destination: ?types.Rectangle = null,
    readback_pending: bool = false,

    /// Free the log buffer (the file source outlives this).
    pub fn deinit(self: *Diagnostics) void {
        self.buffer.deinit(self.allocator);
    }

    /// Append a line to the buffer. Best-effort: an OOM write is
    /// dropped, never surfaced.
    pub fn append(self: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
        self.buffer.print(self.allocator, fmt, args) catch return;
    }

    /// Rewrite "logs/diagnostics.txt" from the buffer. Best-effort: a failed
    /// write is silent (diagnostics must never crash the game).
    fn flush(self: *Diagnostics) void {
        self.file_source.writeFile("logs/diagnostics.txt", self.buffer.items) catch return;
    }

    /// Boot section: build identity + GL context info. Called once from the
    /// first render, when the window + GL context are guaranteed live.
    pub fn logBoot(self: *Diagnostics, render_width: i32, render_height: i32) void {
        self.boot_logged = true;
        self.append("ziglop dev diagnostics\n", .{});
        self.append("game_version {s}\n", .{@import("build_info").game_version});
        self.append("target {s}-{s}\n", .{
            @tagName(@import("builtin").os.tag),
            @tagName(@import("builtin").cpu.arch),
        });
        // Screen (window points) vs render (framebuffer pixels): a 2x gap
        // here means a retina context without raylib's high-dpi flag — the
        // letterbox/pointer math operates on points either way.
        self.append("window {d}x{d} points, framebuffer {d}x{d} pixels\n", .{
            rl.getScreenWidth(),
            rl.getScreenHeight(),
            rl.getRenderWidth(),
            rl.getRenderHeight(),
        });
        self.append("render target {d}x{d}\n", .{ render_width, render_height });
        self.append("GL_VENDOR {s}\n", .{glString(gl_vendor)});
        self.append("GL_RENDERER {s}\n", .{glString(gl_renderer)});
        self.append("GL_VERSION {s}\n", .{glString(gl_version)});
        self.append("GL_SHADING_LANGUAGE_VERSION {s}\n", .{glString(gl_shading_language_version)});
        self.flush();
    }

    /// One-shot probe of the first plain sprite draw — the known-WORKING
    /// control the first panel probe is diffed against.
    pub fn logFirstSpriteDraw(
        self: *Diagnostics,
        sprite_id: []const u8,
        texture: rl.Texture2D,
        source: rl.Rectangle,
        destination: rl.Rectangle,
        tint: types.Color,
        alpha: u8,
    ) void {
        self.sprite_probe_logged = true;
        self.sprite_destination = .{
            .x = @intFromFloat(destination.x),
            .y = @intFromFloat(destination.y),
            .width = @intFromFloat(destination.width),
            .height = @intFromFloat(destination.height),
        };
        self.readback_pending = true;
        self.append("\n[control] first drawSprite\n", .{});
        self.append("sprite_id {s}\n", .{sprite_id});
        self.append("texture id {d} {d}x{d}\n", .{ texture.id, texture.width, texture.height });
        self.append("source x {d} y {d} w {d} h {d}\n", .{ source.x, source.y, source.width, source.height });
        self.append("destination x {d} y {d} w {d} h {d}\n", .{ destination.x, destination.y, destination.width, destination.height });
        self.append("tint r {d} g {d} b {d} alpha {d}\n", .{ tint.r, tint.g, tint.b, alpha });
        self.flush();
    }

    /// One-shot probe of the first 9-slice panel draw — full draw state
    /// (texture, tint before + after default_tint resolution, destination,
    /// all nine source/destination rect pairs) to diff against the control.
    pub fn logFirstPanelDraw(
        self: *Diagnostics,
        panel: ui.NineSlicePanel,
        texture: rl.Texture2D,
        resolved_tint: rl.Color,
        theme_darkest: types.Color,
        destination: types.Rectangle,
        pieces: [9]ui.NineSlicePiece,
    ) void {
        self.panel_probe_logged = true;
        self.panel_destination = destination;
        self.readback_pending = true;
        self.append("\n[probe] first drawNineSlice\n", .{});
        self.append("sprite_id {s}\n", .{panel.sprite_id});
        self.append("texture id {d} {d}x{d}\n", .{ texture.id, texture.width, texture.height });
        self.append("panel_color r {d} g {d} b {d}\n", .{ panel.color.r, panel.color.g, panel.color.b });
        self.append("theme_darkest r {d} g {d} b {d}\n", .{ theme_darkest.r, theme_darkest.g, theme_darkest.b });
        self.append("resolved_tint r {d} g {d} b {d} a {d}\n", .{ resolved_tint.r, resolved_tint.g, resolved_tint.b, resolved_tint.a });
        self.append("destination x {d} y {d} w {d} h {d}\n", .{ destination.x, destination.y, destination.width, destination.height });
        for (pieces, 0..) |piece, index| {
            self.append(
                "piece {d}: source x {d} y {d} w {d} h {d} destination x {d} y {d} w {d} h {d}\n",
                .{ index, piece.source.x, piece.source.y, piece.source.width, piece.source.height, piece.destination.x, piece.destination.y, piece.destination.width, piece.destination.height },
            );
        }
        self.flush();
    }

    /// Read back the render target at the end of a frame where a probe fired
    /// and log the pixels at the probed destinations. Splits the pipeline in
    /// half: pixels PRESENT = the draw landed in the offscreen target, so a
    /// missing panel on screen is the blit/present path (window/compositor);
    /// pixels ABSENT = the batch draw itself failed. Samples are in TARGET
    /// space (reference × the render camera zoom); RenderTextures are stored
    /// y-flipped, so the sampled row is flipped back.
    pub fn logTargetReadback(
        self: *Diagnostics,
        render_target: rl.RenderTexture2D,
        render_width: i32,
        render_height: i32,
        render_scale: f32,
    ) void {
        self.readback_pending = false;
        const image = rl.loadImageFromTexture(render_target.texture) catch return;
        defer rl.unloadImage(image);
        const colors = rl.loadImageColors(image) catch return;
        defer rl.unloadImageColors(colors);
        self.append("\n[readback] render target {d}x{d}\n", .{ image.width, image.height });
        if (self.panel_destination) |rect| {
            self.logSampledPixels(colors, "panel", rect, render_width, render_height, render_scale);
        }
        if (self.sprite_destination) |rect| {
            self.logSampledPixels(colors, "control", rect, render_width, render_height, render_scale);
        }
        self.flush();
    }

    /// Log three pixels along the horizontal center line of a probed
    /// destination (25/50/75% — inside the 9-slice corner band at both ends
    /// for a typical panel, center in the stretched middle).
    fn logSampledPixels(
        self: *Diagnostics,
        colors: []rl.Color,
        label: []const u8,
        rect: types.Rectangle,
        render_width: i32,
        render_height: i32,
        render_scale: f32,
    ) void {
        const target_width: i64 = render_width;
        const target_height: i64 = render_height;
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
            self.append(
                "readback {s} at {d} pixel({d},{d}) r {d} g {d} b {d} a {d}\n",
                .{ label, fraction, column, target_row, color.r, color.g, color.b, color.a },
            );
        }
    }
};
