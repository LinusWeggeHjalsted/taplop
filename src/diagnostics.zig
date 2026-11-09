//! Diagnostics: the Terminal-less platform-troubleshooting log - one
//! `Diagnostics` instance (owned by the raylib backend) accumulating boot
//! info, first-draw one-shot probes, and render-target readback samples
//! into `logs/diagnostics.txt` in the persistent dir. Raylib-FREE by
//! design: the backend gathers the GL-touching values at its probe sites
//! and records them here as plain data, so this file compiles in the
//! headless test build and its section/flush policy is unit-tested.
//! Activation is a RUNTIME flag (the `--diagnostics` CLI flag; dev-mode
//! builds default active) - the code ships in every native build, so the
//! binary that exhibits a release-only failure can produce its own data.
//! Writes are event-driven (a handful per session) and flushed at the
//! end-of-frame safe point, never mid-draw; the file is rewritten whole on
//! every flush, so it is always self-consistent. Best-effort everywhere: a
//! failed write never surfaces. Settled design: DESIGN → Platform Seam →
//! Diagnostics.

const std = @import("std");
const types = @import("types.zig");
const ui = @import("ui.zig");
const FileSource = @import("file_source.zig").FileSource;

/// Where the log lands (persistent dir; rewritten whole on every flush).
pub const diagnostics_file_path = "logs/diagnostics.txt";

/// "compiled" / "FAILED" for the shader-status boot lines.
fn statusString(compiled: bool) []const u8 {
    return if (compiled) "compiled" else "FAILED";
}

/// Boot-section values, gathered by the backend at first render (window +
/// GL context are live there). GL identity strings are read raylib-side;
/// only the values cross the seam.
pub const BootValues = struct {
    /// Window size in POINTS vs framebuffer PIXELS: a 2x gap means a
    /// retina context without raylib's high-dpi flag - the letterbox /
    /// pointer math operates on points either way.
    window_width: i32,
    window_height: i32,
    framebuffer_width: i32,
    framebuffer_height: i32,
    render_target_width: i32,
    render_target_height: i32,
    gl_vendor: []const u8,
    gl_renderer: []const u8,
    gl_version: []const u8,
    gl_shading_language_version: []const u8,
    /// Compile status of the three silent-degrade shaders: a FAILED
    /// compile never crashes - the pass falls back to its pre-shader look
    /// (sprite LOD: trilinear; outline stripes: solid tint; SDF text:
    /// shadow ring) - and nothing else surfaces it. The boot section is
    /// where the degrade becomes visible.
    sprite_shader_compiled: bool,
    outline_stripe_shader_compiled: bool,
    sdf_shader_compiled: bool,
};

/// First plain-sprite-draw probe values - the known-WORKING control the
/// first panel probe is diffed against.
pub const SpriteDrawValues = struct {
    sprite_id: []const u8,
    texture_id: u32,
    texture_width: i32,
    texture_height: i32,
    source: types.Rectangle,
    destination: types.Rectangle,
    tint: types.Color,
    alpha: u8,
};

/// First 9-slice-panel-draw probe values - the full draw state (texture,
/// tint before + after default-tint resolution, destination, all nine
/// source/destination rect pairs) to diff against the control. The pieces
/// are the pure `ui.nineSlicePiecesAtScale` output (raylib-free - same seam).
pub const PanelDrawValues = struct {
    sprite_id: []const u8,
    texture_id: u32,
    texture_width: i32,
    texture_height: i32,
    panel_color: types.Color,
    theme_darkest: types.Color,
    resolved_tint: types.Color,
    /// The tint's alpha after default-tint resolution (types.Color carries
    /// no alpha; the resolved raylib color does).
    resolved_tint_alpha: u8,
    destination: types.Rectangle,
    pieces: [9]ui.NineSlicePiece,
};

/// One render-target pixel sample at a probed destination: the readback
/// splits the pipeline in half - pixels PRESENT = the draw landed in the
/// offscreen target, so a missing panel on screen is the blit/present
/// path; pixels ABSENT = the batch draw itself failed. Coordinates are in
/// TARGET space; the raylib side computes them (RenderTextures are stored
/// y-flipped).
pub const PixelSample = struct {
    label: []const u8,
    fraction: f32,
    column: i64,
    row: i64,
    color: types.Color,
    alpha: u8,
};

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    file_source: *const FileSource,

    /// Runtime activation (the `--diagnostics` CLI flag, defaulting to the
    /// dev-mode build option). Set by the entry point before the first
    /// render; never toggled afterwards. False on web (native-only, like
    /// the whole subsystem).
    enabled: bool = false,

    /// Log buffer: the accumulated file content, rewritten whole on every
    /// flush. Freed in deinit.
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    boot_logged: bool = false,
    sprite_probe_logged: bool = false,
    panel_probe_logged: bool = false,
    /// Reference-space destinations captured by the one-shot probes, read
    /// back from the render target at the end of the same frame - the
    /// probes fire mid-draw, the pixels only exist after `endTextureMode`.
    panel_destination: ?types.Rectangle = null,
    sprite_destination: ?types.Rectangle = null,
    readback_pending: bool = false,
    /// A section appended since the last flush; the end-of-frame safe point
    /// (and clean shutdown) executes it. Never written mid-draw.
    flush_pending: bool = false,

    pub fn deinit(self: *Diagnostics) void {
        self.flushIfPending();
        self.buffer.deinit(self.allocator);
    }

    /// Whether the boot section still needs recording this session. Call
    /// sites check this (not `enabled` alone) so the GL-gathering work is
    /// skipped when there is nothing to log.
    pub fn shouldRecordBoot(self: *const Diagnostics) bool {
        return self.enabled and !self.boot_logged;
    }

    /// Whether the first plain-sprite probe still needs recording.
    pub fn shouldRecordFirstSpriteDraw(self: *const Diagnostics) bool {
        return self.enabled and !self.sprite_probe_logged;
    }

    /// Whether the first 9-slice panel probe still needs recording.
    pub fn shouldRecordFirstPanelDraw(self: *const Diagnostics) bool {
        return self.enabled and !self.panel_probe_logged;
    }

    /// Append a pre-formatted message (the audio subsystem's load-time
    /// warning sink). Gated on `enabled`: an inactive instance must not
    /// accumulate (nothing would ever flush it). Best-effort - an OOM
    /// write is dropped, never surfaced.
    pub fn append(self: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled) return;
        self.buffer.print(self.allocator, fmt, args) catch return;
        self.flush_pending = true;
    }

    /// Boot section: build identity + GL context info. One-shot; records
    /// only when active + not yet logged.
    pub fn recordBoot(self: *Diagnostics, values: BootValues) void {
        if (!self.shouldRecordBoot()) return;
        self.boot_logged = true;
        self.appendUnchecked("ziglop diagnostics\n", .{});
        self.appendUnchecked("game_version {s}\n", .{@import("build_info").game_version});
        self.appendUnchecked("target {s}-{s}\n", .{
            @tagName(@import("builtin").target.os.tag),
            @tagName(@import("builtin").cpu.arch),
        });
        self.appendUnchecked("window {d}x{d} points, framebuffer {d}x{d} pixels\n", .{
            values.window_width,
            values.window_height,
            values.framebuffer_width,
            values.framebuffer_height,
        });
        self.appendUnchecked("render target {d}x{d}\n", .{
            values.render_target_width,
            values.render_target_height,
        });
        self.appendUnchecked("sprite_lod_shader {s} (fallback: plain trilinear)\n", .{
            statusString(values.sprite_shader_compiled),
        });
        self.appendUnchecked("outline_stripe_shader {s} (fallback: solid tint)\n", .{
            statusString(values.outline_stripe_shader_compiled),
        });
        self.appendUnchecked("sdf_text_shader {s} (fallback: shadow ring)\n", .{
            statusString(values.sdf_shader_compiled),
        });
        self.appendUnchecked("GL_VENDOR {s}\n", .{values.gl_vendor});
        self.appendUnchecked("GL_RENDERER {s}\n", .{values.gl_renderer});
        self.appendUnchecked("GL_VERSION {s}\n", .{values.gl_version});
        self.appendUnchecked("GL_SHADING_LANGUAGE_VERSION {s}\n", .{values.gl_shading_language_version});
        self.markFlushPending();
    }

    /// One-shot probe of the first plain sprite draw - the known-WORKING
    /// control the first panel probe is diffed against. Captures the
    /// destination for the end-of-frame readback.
    pub fn recordFirstSpriteDraw(self: *Diagnostics, values: SpriteDrawValues) void {
        if (!self.shouldRecordFirstSpriteDraw()) return;
        self.sprite_probe_logged = true;
        self.sprite_destination = values.destination;
        self.readback_pending = true;
        self.appendUnchecked("\n[control] first drawSprite\n", .{});
        self.appendUnchecked("sprite_id {s}\n", .{values.sprite_id});
        self.appendUnchecked("texture id {d} {d}x{d}\n", .{
            values.texture_id, values.texture_width, values.texture_height,
        });
        self.appendUnchecked("source x {d} y {d} w {d} h {d}\n", .{
            values.source.x, values.source.y, values.source.width, values.source.height,
        });
        self.appendUnchecked("destination x {d} y {d} w {d} h {d}\n", .{
            values.destination.x, values.destination.y, values.destination.width, values.destination.height,
        });
        self.appendUnchecked("tint r {d} g {d} b {d} alpha {d}\n", .{
            values.tint.r, values.tint.g, values.tint.b, values.alpha,
        });
        self.markFlushPending();
    }

    /// One-shot probe of the first 9-slice panel draw - full draw state to
    /// diff against the control. Captures the destination for the
    /// end-of-frame readback.
    pub fn recordFirstPanelDraw(self: *Diagnostics, values: PanelDrawValues) void {
        if (!self.shouldRecordFirstPanelDraw()) return;
        self.panel_probe_logged = true;
        self.panel_destination = values.destination;
        self.readback_pending = true;
        self.appendUnchecked("\n[probe] first drawNineSlice\n", .{});
        self.appendUnchecked("sprite_id {s}\n", .{values.sprite_id});
        self.appendUnchecked("texture id {d} {d}x{d}\n", .{
            values.texture_id, values.texture_width, values.texture_height,
        });
        self.appendUnchecked("panel_color r {d} g {d} b {d}\n", .{
            values.panel_color.r, values.panel_color.g, values.panel_color.b,
        });
        self.appendUnchecked("theme_darkest r {d} g {d} b {d}\n", .{
            values.theme_darkest.r, values.theme_darkest.g, values.theme_darkest.b,
        });
        self.appendUnchecked("resolved_tint r {d} g {d} b {d} a {d}\n", .{
            values.resolved_tint.r, values.resolved_tint.g, values.resolved_tint.b, values.resolved_tint_alpha,
        });
        self.appendUnchecked("destination x {d} y {d} w {d} h {d}\n", .{
            values.destination.x, values.destination.y, values.destination.width, values.destination.height,
        });
        for (values.pieces, 0..) |piece, index| {
            self.appendUnchecked(
                "piece {d}: source x {d} y {d} w {d} h {d} destination x {d} y {d} w {d} h {d}\n",
                .{
                    index,
                    piece.source.x,
                    piece.source.y,
                    piece.source.width,
                    piece.source.height,
                    piece.destination.x,
                    piece.destination.y,
                    piece.destination.width,
                    piece.destination.height,
                },
            );
        }
        self.markFlushPending();
    }

    /// End-of-frame readback section: pixels sampled at the probed
    /// destinations (the backend loads the render target + computes the
    /// samples; only values cross the seam). One-shot per probe burst.
    pub fn recordTargetReadback(
        self: *Diagnostics,
        samples: []const PixelSample,
        image_width: i32,
        image_height: i32,
    ) void {
        self.readback_pending = false;
        self.appendUnchecked("\n[readback] render target {d}x{d}\n", .{ image_width, image_height });
        for (samples) |sample| {
            self.appendUnchecked(
                "readback {s} at {d} pixel({d},{d}) r {d} g {d} b {d} a {d}\n",
                .{
                    sample.label,
                    sample.fraction,
                    sample.column,
                    sample.row,
                    sample.color.r,
                    sample.color.g,
                    sample.color.b,
                    sample.alpha,
                },
            );
        }
        self.markFlushPending();
    }

    /// Execute a pending flush: rewrite the whole file from the buffer.
    /// Called at the end-of-frame safe point (after present) and at clean
    /// shutdown. Best-effort - a failed write is silent (diagnostics must
    /// never crash the game).
    pub fn flushIfPending(self: *Diagnostics) void {
        if (!self.enabled or !self.flush_pending) return;
        self.flush_pending = false;
        self.file_source.writeFile(diagnostics_file_path, self.buffer.items) catch return;
    }

    /// Whether the end-of-frame readback should run this frame (a probe
    /// fired earlier in the same frame; the pixels only exist after
    /// `endTextureMode`).
    pub fn shouldReadBackTarget(self: *const Diagnostics) bool {
        return self.enabled and self.readback_pending;
    }

    /// The reference-space destinations captured by the one-shot probes,
    /// for the backend's readback sampling.
    pub fn panelDestination(self: *const Diagnostics) ?types.Rectangle {
        return self.panel_destination;
    }

    pub fn spriteDestination(self: *const Diagnostics) ?types.Rectangle {
        return self.sprite_destination;
    }

    fn markFlushPending(self: *Diagnostics) void {
        if (self.enabled) self.flush_pending = true;
    }

    fn appendUnchecked(self: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
        self.buffer.print(self.allocator, fmt, args) catch return;
    }
};

// --- tests (headless: the raylib-free seam is the whole point) ---

const testing = std.testing;

/// A scratch-dir FileSource for one test (the file_source.zig test
/// pattern): created under zig-cache/, removed on scope exit. The
/// allocator is the test's own; the FileSource allocates nothing (its
/// reads use the caller's allocator).
fn initTestFileSource(io: std.Io, scratch: []const u8) FileSource {
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    return FileSource.init(io, dir);
}

fn deinitTestFileSource(io: std.Io, scratch: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
}

fn testBootValues() BootValues {
    return .{
        .window_width = 1920,
        .window_height = 1080,
        .framebuffer_width = 1920,
        .framebuffer_height = 1080,
        .render_target_width = 1920,
        .render_target_height = 1080,
        .gl_vendor = "Test Vendor",
        .gl_renderer = "Test Renderer",
        .gl_version = "4.1 Core",
        .gl_shading_language_version = "4.10",
        .sprite_shader_compiled = true,
        .outline_stripe_shader_compiled = true,
        .sdf_shader_compiled = false,
    };
}

test "section policy: one-shots record once, probes capture the readback destinations" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = initTestFileSource(io, "zig-cache/test-diagnostics-sections");
    defer deinitTestFileSource(io, "zig-cache/test-diagnostics-sections");

    var diagnostics = Diagnostics{ .allocator = allocator, .file_source = &file_source, .enabled = true };
    defer diagnostics.deinit();

    // Idle: nothing pending.
    try testing.expect(!diagnostics.flush_pending);

    // Boot records once and marks a flush.
    diagnostics.recordBoot(testBootValues());
    try testing.expect(diagnostics.boot_logged);
    try testing.expect(diagnostics.flush_pending);
    // The shader-status lines land in the boot section (the fixture has the
    // SDF deliberately FAILED - the silent-degrade case the line exists
    // to surface).
    try testing.expect(std.mem.indexOf(u8, diagnostics.buffer.items, "sprite_lod_shader compiled") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostics.buffer.items, "outline_stripe_shader compiled") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostics.buffer.items, "sdf_text_shader FAILED (fallback: shadow ring)") != null);
    const buffer_after_boot = diagnostics.buffer.items.len;
    // One-shot: a second boot with DIFFERENT values records nothing.
    var second_boot = testBootValues();
    second_boot.gl_renderer = "Different Renderer";
    diagnostics.recordBoot(second_boot);
    try testing.expectEqual(buffer_after_boot, diagnostics.buffer.items.len);

    // The sprite probe records once, captures its destination, arms the
    // readback.
    try testing.expect(diagnostics.shouldRecordFirstSpriteDraw());
    diagnostics.recordFirstSpriteDraw(.{
        .sprite_id = "entities/player",
        .texture_id = 1,
        .texture_width = 512,
        .texture_height = 640,
        .source = .{ .x = 0, .y = 0, .width = 512, .height = 640 },
        .destination = .{ .x = 128, .y = 256, .width = 256, .height = 320 },
        .tint = .{ .r = 255, .g = 255, .b = 255 },
        .alpha = 255,
    });
    try testing.expect(!diagnostics.shouldRecordFirstSpriteDraw());
    try testing.expectEqual(types.Rectangle{ .x = 128, .y = 256, .width = 256, .height = 320 }, diagnostics.spriteDestination().?);
    try testing.expect(diagnostics.shouldReadBackTarget());

    // The readback consumes the pending flag and appends the samples.
    diagnostics.recordTargetReadback(&.{
        .{ .label = "control", .fraction = 0.5, .column = 256, .row = 416, .color = .{ .r = 10, .g = 20, .b = 30 }, .alpha = 255 },
    }, 1920, 1080);
    try testing.expect(!diagnostics.shouldReadBackTarget());
    // The sprite probe stays a one-shot after the readback.
    const buffer_after_readback = diagnostics.buffer.items.len;
    diagnostics.recordFirstSpriteDraw(.{
        .sprite_id = "again",
        .texture_id = 2,
        .texture_width = 1,
        .texture_height = 1,
        .source = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .tint = .{ .r = 0, .g = 0, .b = 0 },
        .alpha = 0,
    });
    try testing.expectEqual(buffer_after_readback, diagnostics.buffer.items.len);
    // Boot section content sanity (the one GL-identity line per string).
    try testing.expect(std.mem.indexOf(u8, diagnostics.buffer.items, "GL_VENDOR Test Vendor") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostics.buffer.items, "readback control at 0.5 pixel(256,416)") != null);
}

test "flushIfPending rewrites the whole file and clears the pending flag" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = initTestFileSource(io, "zig-cache/test-diagnostics-flush");
    defer deinitTestFileSource(io, "zig-cache/test-diagnostics-flush");

    var diagnostics = Diagnostics{ .allocator = allocator, .file_source = &file_source, .enabled = true };
    defer diagnostics.deinit();

    diagnostics.recordBoot(testBootValues());
    diagnostics.flushIfPending();
    try testing.expect(!diagnostics.flush_pending);

    // Whole-file rewrite: the file is exactly the buffer.
    const written = try file_source.readFile(allocator, diagnostics_file_path);
    defer allocator.free(written);
    try testing.expectEqualSlices(u8, diagnostics.buffer.items, written);

    // Appending after a flush re-marks pending; the file only updates at
    // the next flush (never mid-draw).
    diagnostics.append("warning {s}\n", .{"music phase-lock mismatch"});
    try testing.expect(diagnostics.flush_pending);
    const stale = try file_source.readFile(allocator, diagnostics_file_path);
    defer allocator.free(stale);
    try testing.expect(std.mem.indexOf(u8, stale, "music phase-lock mismatch") == null);
    // The deinit flush (clean shutdown) writes it.
}

test "disabled: nothing recorded, no file written" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = initTestFileSource(io, "zig-cache/test-diagnostics-disabled");
    defer deinitTestFileSource(io, "zig-cache/test-diagnostics-disabled");

    var diagnostics = Diagnostics{ .allocator = allocator, .file_source = &file_source, .enabled = false };
    defer diagnostics.deinit();

    // No section records, no sink append, no flush - the file never exists.
    try testing.expect(!diagnostics.shouldRecordBoot());
    try testing.expect(!diagnostics.shouldRecordFirstSpriteDraw());
    try testing.expect(!diagnostics.shouldRecordFirstPanelDraw());
    diagnostics.recordBoot(testBootValues());
    diagnostics.append("warning {s}\n", .{"never buffered"});
    diagnostics.flushIfPending();
    try testing.expectEqual(@as(usize, 0), diagnostics.buffer.items.len);
    try testing.expectError(error.FileNotFound, file_source.readFile(allocator, diagnostics_file_path));
}
