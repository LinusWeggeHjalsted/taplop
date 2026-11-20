//! Gradient contrast report generator - a build tool, never part of the
//! game. `zig build gradient-report` (wrapped by scripts/gradient_report.sh)
//! reads `data/color_themes.txt` through the GAME'S OWN parser + loader (no
//! duplicate color list to drift) and writes `gradient_report.md` at the
//! project root: for every gradient, the perceptual spacing (ΔE76) of each
//! adjacent ramp step + the contrast of the seams the renderer actually
//! places adjacent (even tile vs background, checkerboard, odd tile vs
//! background), flags for "too close" pairs, and suggested replacement
//! colors for violations. Built for the artist: the numbers decide, not
//! memory. See DESIGN → Level Editor → Level theme.

const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");

/// The step floor: the minimum perceptual distance (ΔE76) between any two
/// colors the renderer places adjacent (ramp neighbors 0-1..4-5, plus the
/// checkerboard pair 1-3). Calibrated on the shipped wheel: the seam that
/// reads as broken (gradient 0's 1-2 step) sits at ΔE 5.4; seams that read
/// fine start at ΔE ~6.8.
const flag_min_delta_e: f32 = 6.0;

/// The luminance guard on the structural seams: a WCAG contrast ratio below
/// this flags even when ΔE passes - same-luminance hue swaps score high on
/// ΔE while flat patches still read as one surface.
const flag_min_contrast_ratio: f32 = 1.06;

/// The repair target for suggestions: a violating step's moved color slides
/// until it clears the floor plus this headroom, so a re-run doesn't sit
/// exactly on the edge.
const repair_target_delta_e: f32 = 6.5;

/// The color-wheel file the report reads (the game's own loader path).
const color_themes_path = "data/color_themes.txt";

/// The report file, at the project root where the developer/artist expects
/// it (the sound_report.md convention).
const report_path = "gradient_report.md";

const read_limit: std.Io.Limit = .limited(4 * 1024 * 1024);

/// One color in CIE L\*a\*b\* (D65) - the perceptually-uniform-ish space the
/// spacing math runs in.
const Lab = struct {
    lightness: f32,
    a: f32,
    b: f32,
};

/// A ramp step that fell below the ΔE floor, plus its computed repair: the
/// step's moved color (the darker of the pair, unless it is the last ramp
/// color - then the lighter one moves instead), slid along the Lab line
/// toward its next neighbor until the step reaches the repair target.
const StepViolation = struct {
    gradient_index: usize,
    /// The step's LIGHTER color index (step i = colors i and i+1).
    step_index: usize,
    delta_e: f32,
    moved_index: usize,
    toward_index: usize,
    suggested: types.Color,
    /// The violating step's ΔE after applying the suggestion.
    repaired_delta_e: f32,
    /// The moved↔toward neighbor step's ΔE after applying the suggestion
    /// (the repair must not push THAT step below the floor).
    neighbor_delta_e: f32,
};

/// A structural seam that fell below the luminance guard (ΔE may pass -
/// this is the same-luminance catch). No computed repair: it fires only on
/// hand-authored hue swaps, which need an artist's eye.
const SeamViolation = struct {
    gradient_index: usize,
    lighter_color_index: usize,
    darker_color_index: usize,
    contrast_ratio: f32,
};

/// The checkerboard pair 1-3 below the ΔE floor - a rendering-adjacent
/// seam that is NOT a ramp step, so no slide repair exists (moving color_2
/// doesn't change it; the artist moves 1 or 3 by hand).
const PairViolation = struct {
    gradient_index: usize,
    delta_e: f32,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();

    const bytes = try cwd.readFileAlloc(io, color_themes_path, allocator, read_limit);
    const sections = try parser.parseConfigFile(bytes, allocator, &parser.color_theme_sections);
    const definitions = try loaders.loadColorThemeDefinitions(sections, allocator);
    const gradients = definitions.gradients;

    var step_violations: std.ArrayList(StepViolation) = .empty;
    var pair_violations: std.ArrayList(PairViolation) = .empty;
    var seam_violations: std.ArrayList(SeamViolation) = .empty;

    for (gradients, 0..) |gradient, gradient_index| {
        const labs = rampLabs(gradient.colors);
        for (0..types.gradient_color_count - 1) |step_index| {
            const delta_e = deltaE76(labs[step_index], labs[step_index + 1]);
            if (delta_e < flag_min_delta_e) {
                try step_violations.append(allocator, try stepRepair(
                    labs,
                    gradient_index,
                    step_index,
                    delta_e,
                ));
            }
        }
        if (deltaE76(labs[1], labs[3]) < flag_min_delta_e) {
            try pair_violations.append(allocator, .{
                .gradient_index = gradient_index,
                .delta_e = deltaE76(labs[1], labs[3]),
            });
        }
        for ([_][2]usize{ .{ 1, 2 }, .{ 1, 3 }, .{ 2, 3 } }) |pair| {
            if (contrastRatio(gradient.colors[pair[0]], gradient.colors[pair[1]]) < flag_min_contrast_ratio) {
                try seam_violations.append(allocator, .{
                    .gradient_index = gradient_index,
                    .lighter_color_index = pair[0],
                    .darker_color_index = pair[1],
                    .contrast_ratio = contrastRatio(gradient.colors[pair[0]], gradient.colors[pair[1]]),
                });
            }
        }
    }

    var report: std.ArrayList(u8) = .empty;

    try report.print(allocator,
        \\# taplop gradient contrast report
        \\
        \\Auto-generated from `{s}` through the game's own parser + loader -
        \\regenerate with `scripts/gradient_report.sh` (the sound_report.md
        \\pattern). The numbers decide what is "too close", not memory.
        \\
        \\## How the renderer uses the ramp (why some pairs matter)
        \\
        \\Every level/hub's world gradient colors the scene at FIXED indices:
        \\
        \\- screen background: color 2
        \\- tiles: a checkerboard of color 1 (even tiles) and color 3 (odd tiles)
        \\- decorations default color 0; flag poles color 5; banners color 0
        \\
        \\So the seams the renderer actually places adjacent are 1-2 (even
        \\tiles vs background), 1-3 (checkerboard), and 2-3 (odd tiles vs
        \\background). A gradient with a small 1-2 step shows the even tiles
        \\dissolving into the background.
        \\
        \\## The rule - what "too close" means
        \\
        \\- **Step floor:** any two colors the renderer places adjacent (ramp
        \\  steps 0-1 through 4-5, plus the checkerboard pair 1-3) must be at
        \\  least ΔE {d} apart. ΔE76 is the CIE76 perceptual distance in Lab
        \\  space - hue and lightness both count. Calibrated on the shipped
        \\  wheel: the broken seam sits at ΔE 5.4, seams that read fine start
        \\  at ~6.8.
        \\- **Luminance guard:** the structural seams (1-2, 1-3, 2-3) must keep
        \\  a WCAG contrast ratio of at least {d} - catches same-luminance hue
        \\  swaps, which ΔE can score high while flat patches still read as
        \\  one surface.
        \\
        \\Not covered here: entity colors vs the tiles they stand on (team
        \\gradients are separate gradients from the level's world gradient -
        \\cross-gradient pairs, a separate calibration).
        \\
        \\
    , .{ color_themes_path, flag_min_delta_e, flag_min_contrast_ratio });

    try report.print(allocator,
        \\## Adjacent-step spacing (ΔE76, floor {d})
        \\
        \\| gradient | 0-1 | 1-2 | 2-3 | 3-4 | 4-5 | worst |
        \\|---:|---:|---:|---:|---:|---:|---:|
        \\
    , .{flag_min_delta_e});
    for (gradients, 0..) |gradient, gradient_index| {
        const labs = rampLabs(gradient.colors);
        var worst_index: usize = 0;
        var worst_delta_e: f32 = deltaE76(labs[0], labs[1]);
        try report.print(allocator, "| {d} ", .{gradient_index});
        for (0..types.gradient_color_count - 1) |step_index| {
            const delta_e = deltaE76(labs[step_index], labs[step_index + 1]);
            if (delta_e < worst_delta_e) {
                worst_delta_e = delta_e;
                worst_index = step_index;
            }
            try reportStepCell(allocator, &report, delta_e);
        }
        // The worst-step summary cell: "<pair> <ΔE>" in ONE cell (the
        // flagged value in bold under the floor).
        if (worst_delta_e < flag_min_delta_e) {
            try report.print(allocator, "| **{d}-{d} {d:.1}** |\n", .{ worst_index, worst_index + 1, worst_delta_e });
        } else {
            try report.print(allocator, "| {d}-{d} {d:.1} |\n", .{ worst_index, worst_index + 1, worst_delta_e });
        }
    }

    try report.print(allocator,
        \\
        \\## Structural seams (ΔE76 / WCAG contrast ratio)
        \\
        \\| gradient | 1-2 even tiles vs bg | 1-3 checkerboard | 2-3 odd tiles vs bg |
        \\|---:|---:|---:|---:|
        \\
    , .{});
    for (gradients, 0..) |gradient, gradient_index| {
        const labs = rampLabs(gradient.colors);
        try report.print(allocator, "| {d} ", .{gradient_index});
        for ([_][2]usize{ .{ 1, 2 }, .{ 1, 3 }, .{ 2, 3 } }) |pair| {
            try report.print(allocator, "| {d:.1} / {d:.2} ", .{
                deltaE76(labs[pair[0]], labs[pair[1]]),
                contrastRatio(gradient.colors[pair[0]], gradient.colors[pair[1]]),
            });
        }
        try report.print(allocator, "|\n", .{});
    }

    try report.print(allocator, "\n## Flags\n\n", .{});
    if (step_violations.items.len == 0 and pair_violations.items.len == 0 and
        seam_violations.items.len == 0)
    {
        try report.print(allocator, "CLEAN - no gradient below the floors.\n", .{});
    }
    for (step_violations.items) |violation| {
        const gradient = gradients[violation.gradient_index];
        try report.print(allocator,
            \\- **gradient {d}, step {d}-{d}: ΔE {d:.1} < {d}** - color_{d} sits on top of color_{d}.
            \\  Suggested repair: color_{d} `{s}` → `{s}` (moved toward color_{d} `{s}`)
            \\  → step {d}-{d} becomes ΔE {d:.1}, step {d}-{d} becomes ΔE {d:.1}.
            \\
        , .{
            violation.gradient_index,
            violation.step_index,
            violation.step_index + 1,
            violation.delta_e,
            flag_min_delta_e,
            violation.step_index + 1,
            violation.step_index,
            violation.moved_index,
            colorHex(allocator, gradient.colors[violation.moved_index]),
            colorHex(allocator, violation.suggested),
            violation.toward_index,
            colorHex(allocator, gradient.colors[violation.toward_index]),
            violation.step_index,
            violation.step_index + 1,
            violation.repaired_delta_e,
            violation.moved_index,
            violation.toward_index,
            violation.neighbor_delta_e,
        });
    }
    for (pair_violations.items) |violation| {
        try report.print(allocator,
            \\- **gradient {d}, checkerboard pair 1-3: ΔE {d:.1} < {d}** - the even/odd
            \\  tiles read as one surface. No computed repair (moving color_2
            \\  doesn't change it) - widen the 1-to-3 span by hand.
            \\
        , .{ violation.gradient_index, violation.delta_e, flag_min_delta_e });
    }
    for (seam_violations.items) |violation| {
        try report.print(allocator,
            \\- **gradient {d}, seam {d}-{d}: contrast {d:.2} < {d}** -
            \\  near-identical luminance (ΔE may pass; hue is carrying it).
            \\  Needs an artist's eye - no computed repair.
            \\
        , .{
            violation.gradient_index,
            violation.lighter_color_index,
            violation.darker_color_index,
            violation.contrast_ratio,
            flag_min_contrast_ratio,
        });
    }

    try cwd.writeFile(io, .{
        .sub_path = report_path,
        .data = report.items,
    });
    std.debug.print(
        "{s} written: {d} flagged of {d} gradients ({d} step floor, {d} checkerboard pair, {d} luminance guard)\n",
        .{
            report_path,
            step_violations.items.len + pair_violations.items.len + seam_violations.items.len,
            gradients.len,
            step_violations.items.len,
            pair_violations.items.len,
            seam_violations.items.len,
        },
    );
}

/// The ramp's colors in Lab, ready for distance math.
fn rampLabs(colors: [types.gradient_color_count]types.Color) [types.gradient_color_count]Lab {
    var labs: [types.gradient_color_count]Lab = undefined;
    for (&labs, colors) |*lab, color| lab.* = colorToLab(color);
    return labs;
}

/// One flagged step's repair: slide the step's MOVED color (the darker of
/// the pair, unless it is the last ramp color - then the lighter one moves
/// toward its own lighter neighbor instead) along the Lab line toward its
/// next neighbor until the step reaches the repair target. Returns null if
/// even adopting the neighbor outright can't clear the target (a compressed
/// ramp the artist must rebalance by hand).
fn stepRepair(
    labs: [types.gradient_color_count]Lab,
    gradient_index: usize,
    step_index: usize,
    delta_e: f32,
) !StepViolation {
    const lighter_index = step_index;
    const darker_index = step_index + 1;
    const moved_index: usize = if (darker_index == types.gradient_color_count - 1)
        lighter_index
    else
        darker_index;
    const toward_index: usize = if (moved_index == darker_index)
        darker_index + 1
    else
        lighter_index - 1;
    const fixed_index: usize = if (moved_index == darker_index) lighter_index else darker_index;

    // Binary search the slide fraction: ΔE from the fixed color grows
    // monotonically along the ramp's own direction.
    var low: f32 = 0;
    var high: f32 = 1;
    if (deltaE76(labs[fixed_index], labs[toward_index]) < repair_target_delta_e) {
        // Even adopting the neighbor outright can't clear the target - a
        // compressed ramp; suggest the neighbor as the best available slide
        // and report it honestly (the repaired step still misses).
        return .{
            .gradient_index = gradient_index,
            .step_index = step_index,
            .delta_e = delta_e,
            .moved_index = moved_index,
            .toward_index = toward_index,
            .suggested = labToColor(labs[toward_index]),
            .repaired_delta_e = deltaE76(labs[fixed_index], labs[toward_index]),
            .neighbor_delta_e = deltaE76(labs[toward_index], labs[nextToward(toward_index, moved_index)]),
        };
    }
    for (0..60) |_| {
        const mid = (low + high) / 2;
        const moved = lerpLab(labs[moved_index], labs[toward_index], mid);
        if (deltaE76(labs[fixed_index], moved) < repair_target_delta_e) low = mid else high = mid;
    }
    const suggested_lab = lerpLab(labs[moved_index], labs[toward_index], high);
    const suggested = labToColor(suggested_lab);
    // Re-measure from the SUGGESTED COLOR's own bytes (the Lab→sRGB round
    // trip quantizes), so the printed numbers match what lands in the file.
    const suggested_lab_rounded = colorToLab(suggested);
    return .{
        .gradient_index = gradient_index,
        .step_index = step_index,
        .delta_e = delta_e,
        .moved_index = moved_index,
        .toward_index = toward_index,
        .suggested = suggested,
        .repaired_delta_e = deltaE76(labs[fixed_index], suggested_lab_rounded),
        .neighbor_delta_e = deltaE76(suggested_lab_rounded, labs[toward_index]),
    };
}

/// The neighbor BEYOND `toward` (for reporting the far side's step after a
/// repair) - the ramp's next index in the same direction, clamped.
fn nextToward(toward_index: usize, moved_index: usize) usize {
    if (toward_index > moved_index) {
        return @min(toward_index + 1, types.gradient_color_count - 1);
    }
    return if (toward_index > 0) toward_index - 1 else 0;
}

fn lerpLab(from: Lab, to: Lab, fraction: f32) Lab {
    return .{
        .lightness = from.lightness + fraction * (to.lightness - from.lightness),
        .a = from.a + fraction * (to.a - from.a),
        .b = from.b + fraction * (to.b - from.b),
    };
}

/// One ΔE table cell, flagged in bold when below the floor.
fn reportStepCell(
    allocator: std.mem.Allocator,
    report: *std.ArrayList(u8),
    delta_e: f32,
) !void {
    if (delta_e < flag_min_delta_e) {
        try report.print(allocator, "| **{d:.1}** ", .{delta_e});
    } else {
        try report.print(allocator, "| {d:.1} ", .{delta_e});
    }
}

/// `#rrggbb` for a color (the data file's own format).
fn colorHex(allocator: std.mem.Allocator, color: types.Color) []const u8 {
    return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{
        color.r, color.g, color.b,
    }) catch @panic("failed to format color hex");
}

// ---------------------------------------------------------------------------
// Color math: sRGB → (D65) CIE L*a*b* and back, ΔE76, WCAG contrast ratio.
// Standard reference constants (sRGB transfer curve + D65 matrices); float
// precision is plenty for a report - the values are compared to a floor of
// 6.0, not to each other's last digit.
// ---------------------------------------------------------------------------

fn deltaE76(a: Lab, b: Lab) f32 {
    const delta_lightness = a.lightness - b.lightness;
    const delta_a = a.a - b.a;
    const delta_b = a.b - b.b;
    return @sqrt(delta_lightness * delta_lightness + delta_a * delta_a + delta_b * delta_b);
}

fn contrastRatio(a: types.Color, b: types.Color) f32 {
    const luminance_a = relativeLuminance(a);
    const luminance_b = relativeLuminance(b);
    const hi = @max(luminance_a, luminance_b);
    const lo = @min(luminance_a, luminance_b);
    return (hi + 0.05) / (lo + 0.05);
}

fn relativeLuminance(color: types.Color) f32 {
    const r = srgbChannelToLinear(color.r);
    const g = srgbChannelToLinear(color.g);
    const b = srgbChannelToLinear(color.b);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

fn colorToLab(color: types.Color) Lab {
    const r = srgbChannelToLinear(color.r);
    const g = srgbChannelToLinear(color.g);
    const b = srgbChannelToLinear(color.b);
    // Linear sRGB → XYZ (D65).
    const x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b;
    const y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
    const z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b;
    return xyzToLab(x, y, z);
}

fn xyzToLab(x: f32, y: f32, z: f32) Lab {
    // D65 reference white.
    const fx = labForward(x / 0.95047);
    const fy = labForward(y / 1.0);
    const fz = labForward(z / 1.08883);
    return .{
        .lightness = 116 * fy - 16,
        .a = 500 * (fx - fy),
        .b = 200 * (fy - fz),
    };
}

fn labForward(t: f32) f32 {
    if (t > 216.0 / 24389.0) {
        return std.math.pow(f32, t, 1.0 / 3.0);
    }
    return (841.0 / 108.0) * t + 4.0 / 29.0;
}

fn labInverse(f: f32) f32 {
    if (f > 6.0 / 29.0) {
        return f * f * f;
    }
    return (108.0 / 841.0) * (f - 4.0 / 29.0);
}

fn labToColor(lab: Lab) types.Color {
    const fy = (lab.lightness + 16) / 116;
    const fx = lab.a / 500 + fy;
    const fz = fy - lab.b / 200;
    const x = labInverse(fx) * 0.95047;
    const y = labInverse(fy) * 1.0;
    const z = labInverse(fz) * 1.08883;
    // XYZ → linear sRGB (D65).
    const r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
    const g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
    const b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;
    return .{
        .r = linearChannelToSrgb(r),
        .g = linearChannelToSrgb(g),
        .b = linearChannelToSrgb(b),
    };
}

fn srgbChannelToLinear(channel: u8) f32 {
    const value: f32 = @as(f32, @floatFromInt(channel)) / 255.0;
    if (value <= 0.04045) {
        return value / 12.92;
    }
    return std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

fn linearChannelToSrgb(linear: f32) u8 {
    const clamped = @min(@max(linear, 0.0), 1.0);
    const encoded = if (clamped <= 0.0031308)
        12.92 * clamped
    else
        1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
    const scaled = @min(@max(encoded, 0.0), 1.0) * 255.0;
    return @intFromFloat(@round(scaled));
}
