//! The shared campaign-map geometry - the ONE implementation behind the
//! "one data model, two renderers" rule: buildWorldMap (the in-game
//! world-map overlay) and the campaign editor's view (slice 3) both
//! derive edge shapes through `deriveEdgeGeometry`. Owns the map-space ->
//! screen-space framing transform (`mapToScreen`), the three edge-shape
//! derivations (self-loop teardrop, straight + parallel spread, dangling
//! stub), the shared view constants (geometry + arrow stroke style), and
//! the baked-arrow classification + rasterization (the edge rendering
//! rework: a curve's identity in the baked-texture cache + the pixel math
//! that paints it). Pure over its inputs: no file access, no session
//! state, no renderer dependencies.
//! See DESIGN → Campaigns & the Campaign Editor → Edge geometry and
//! The map coordinate model.

const std = @import("std");
const types = @import("../types.zig");
const element = @import("element.zig");

const ScreenPosition = types.ScreenPosition;
const Vector2 = types.Vector2;

/// Edge endpoints anchor this far from the hub's CENTER - deliberately
/// decoupled from the hub icon's draw size (the icon can shrink without
/// dragging edge geometry along): self-loops + stubs along the exit's
/// configured direction, straight edges along the hub-position difference.
const hub_edge_anchor_radius: i32 = 64;

/// Self-loop geometry: the teardrop's reach along the exit direction (L)
/// and half-width across it (w). Fixed view constants in v1 (style
/// consistency); tweak freely.
const self_loop_length: i32 = 300;
const self_loop_half_width: i32 = 120;

/// The dangling-stub reach along the exit direction.
const stub_length: i32 = 300;

/// Perpendicular spacing between PARALLEL straight edges connecting the
/// same hub pair (spread by exit index).
const parallel_edge_spacing: i32 = 64;

/// The mission-edge stroke width + its pure-black outline (each side adds
/// `edge_outline_width`, so the under-stroke is
/// `edge_width + 2 * edge_outline_width` wide). Shared by both renderers'
/// stroke pairs AND the clickable button's hit_curve width (the hit
/// region is the drawn arrow, outline-inclusive).
pub const edge_width: i32 = 8;
pub const edge_outline_width: i32 = 8;

/// The edge stroke's outline color.
pub const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };

/// The hub icon's draw size (reference px, centered on the hub's map
/// position). A dedicated icon ships eventually; until then the id is
/// MISSING and draws the magenta placeholder (the art_report shopping list
/// carries it automatically). Deliberately decoupled from
/// `hub_edge_anchor_radius` (the icon can shrink without dragging edge
/// geometry along).
pub const hub_icon_size: i32 = 64;

/// The placeholder sprite id for the hub icon (both renderers draw it).
pub const hub_icon_sprite_id = "world/hub_icon";

/// Map space -> reference screen space. The default framing region IS the
/// reference resolution (both 3840x2160, centered on the origin - see
/// DESIGN → The map coordinate model), so the transform is a pure
/// translation; the framing constant and this function change together if
/// the default framing ever moves.
pub fn mapToScreen(position: Vector2) ScreenPosition {
    return .{
        .x = position.x + @divTrunc(types.reference_width, 2),
        .y = position.y + @divTrunc(types.reference_height, 2),
    };
}

/// The direction unit vector for a compass degree value (0 = north = up,
/// clockwise - the screen's y axis points down, so north is -y).
fn directionUnitVector(direction_degrees: i32) struct { x: f32, y: f32 } {
    const radians = std.math.degreesToRadians(@as(f32, @floatFromInt(direction_degrees)));
    return .{ .x = @sin(radians), .y = -@cos(radians) };
}

fn screenPoint(x: f32, y: f32) ScreenPosition {
    return .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
}

/// How an edge's destination end resolves - the three geometric classes
/// (see DESIGN → Edge geometry). The CALLER resolves its own graph's
/// references into this union, so the runtime edge table and the editor's
/// authored graph share the derivation without sharing types.
pub const EdgeEndpoint = union(enum) {
    /// The destination IS the from hub - the teardrop along the exit's
    /// direction bearing.
    self_loop,
    /// The destination hub's map position.
    hub: Vector2,
    /// Destination unplaced or unresolvable - the dashed stub along the
    /// direction bearing.
    dangling,
};

/// Where a straight edge sits among its same-pair siblings: `index` is
/// the edge's 1-based position (by exit_index) among the `count` edges
/// sharing the same (from, destination) pair. The caller scans its own
/// edge list to compute this (pair identity is the caller's vocabulary -
/// uuids at runtime, handles in the editor); only the straight class
/// consumes it.
pub const ParallelSpread = struct {
    index: i32,
    count: i32,
};

/// One derived edge shape: the four bezier points (straight edges are the
/// degenerate bezier - all controls on the segment) + the dashed flag
/// (the dangling-stub class). Both renderers draw the stroke pair from
/// this and the clickable button's hit_curve copies it, so the drawn
/// edge, its hit region, and its tooltip bounds cannot disagree.
pub const EdgeGeometry = struct {
    start: ScreenPosition,
    control_start: ScreenPosition,
    control_end: ScreenPosition,
    end: ScreenPosition,
    dashed: bool,
};

/// Derive an edge's on-screen shape. `from_position` is the from hub's
/// map position; `endpoint` resolves the destination (see EdgeEndpoint);
/// `direction_degrees` is the exit's EFFECTIVE direction (authored, else
/// the auto-spread default); `parallel` spreads same-pair straight edges
/// perpendicular (see ParallelSpread). Pure: identical inputs give
/// identical geometry.
pub fn deriveEdgeGeometry(
    from_position: Vector2,
    endpoint: EdgeEndpoint,
    direction_degrees: i32,
    parallel: ParallelSpread,
) EdgeGeometry {
    const start = mapToScreen(from_position);

    switch (endpoint) {
        .self_loop => {
            // The anchor sits on the exit's direction bearing at the
            // hub's edge; the teardrop extends from it -
            // {a, a + d*L + n*w, a + d*L - n*w, a} with a = hub + d*R.
            const direction = directionUnitVector(direction_degrees);
            const px = -direction.y;
            const py = direction.x;
            const radius: f32 = @floatFromInt(hub_edge_anchor_radius);
            const hub_x: f32 = @floatFromInt(start.x);
            const hub_y: f32 = @floatFromInt(start.y);
            const anchor_x: f32 = hub_x + direction.x * radius;
            const anchor_y: f32 = hub_y + direction.y * radius;
            const length: f32 = @floatFromInt(self_loop_length);
            const half_width: f32 = @floatFromInt(self_loop_half_width);
            return .{
                .start = screenPoint(anchor_x, anchor_y),
                .control_start = screenPoint(
                    anchor_x + direction.x * length + px * half_width,
                    anchor_y + direction.y * length + py * half_width,
                ),
                .control_end = screenPoint(
                    anchor_x + direction.x * length - px * half_width,
                    anchor_y + direction.y * length - py * half_width,
                ),
                .end = screenPoint(anchor_x, anchor_y),
                .dashed = false,
            };
        },
        .hub => |to_position| {
            // Straight edge: the direction is the HUB-POSITION difference
            // (well-defined), the endpoints displaced to each hub's
            // boundary along it. Controls on the segment at 1/3 + 2/3,
            // slid perpendicular by the parallel-spread offset for
            // same-pair edges. Coincident hubs (distinct hubs placed at
            // the same map position - legal, nothing forbids it) fall
            // back to east so the shape stays finite.
            const hub_start = start;
            const hub_end = mapToScreen(to_position);
            const hub_dx: f32 = @floatFromInt(hub_end.x - hub_start.x);
            const hub_dy: f32 = @floatFromInt(hub_end.y - hub_start.y);
            const hub_length = @sqrt(hub_dx * hub_dx + hub_dy * hub_dy);
            const radius: f32 = @floatFromInt(hub_edge_anchor_radius);
            const unit_x = if (hub_length > 0) hub_dx / hub_length else 1;
            const unit_y = if (hub_length > 0) hub_dy / hub_length else 0;
            const from_x: f32 = @floatFromInt(hub_start.x);
            const from_y: f32 = @floatFromInt(hub_start.y);
            const to_x: f32 = @floatFromInt(hub_end.x);
            const to_y: f32 = @floatFromInt(hub_end.y);
            const start_x: f32 = from_x + unit_x * radius;
            const start_y: f32 = from_y + unit_y * radius;
            const end_x: f32 = to_x - unit_x * radius;
            const end_y: f32 = to_y - unit_y * radius;
            const dx: f32 = end_x - start_x;
            const dy: f32 = end_y - start_y;
            const offset: f32 = @as(f32, @floatFromInt(parallel_edge_spacing)) *
                (@as(f32, @floatFromInt(parallel.index)) -
                    (@as(f32, @floatFromInt(parallel.count)) + 1.0) / 2.0);
            const ox = (-dy / @max(@sqrt(dx * dx + dy * dy), 1.0)) * offset;
            const oy = (dx / @max(@sqrt(dx * dx + dy * dy), 1.0)) * offset;
            return .{
                .start = screenPoint(start_x, start_y),
                .control_start = screenPoint(start_x + dx / 3.0 + ox, start_y + dy / 3.0 + oy),
                .control_end = screenPoint(start_x + 2.0 * dx / 3.0 + ox, start_y + 2.0 * dy / 3.0 + oy),
                .end = screenPoint(end_x, end_y),
                .dashed = false,
            };
        },
        .dangling => {
            // Dangling stub: along the direction bearing from the hub's
            // boundary, dashed.
            const direction = directionUnitVector(direction_degrees);
            const radius: f32 = @floatFromInt(hub_edge_anchor_radius);
            const length: f32 = @floatFromInt(stub_length);
            const hub_x: f32 = @floatFromInt(start.x);
            const hub_y: f32 = @floatFromInt(start.y);
            const anchor_x: f32 = hub_x + direction.x * radius;
            const anchor_y: f32 = hub_y + direction.y * radius;
            return .{
                .start = screenPoint(anchor_x, anchor_y),
                .control_start = screenPoint(
                    anchor_x + direction.x * length / 3.0,
                    anchor_y + direction.y * length / 3.0,
                ),
                .control_end = screenPoint(
                    anchor_x + 2.0 * direction.x * length / 3.0,
                    anchor_y + 2.0 * direction.y * length / 3.0,
                ),
                .end = screenPoint(anchor_x + direction.x * length, anchor_y + direction.y * length),
                .dashed = true,
            };
        },
    }
}

// ============================================================
// Baked arrow textures (the edge rendering rework)
// ============================================================
// A map edge draws as ONE rotated textured quad instead of ~48 capped
// segments x2 layers per frame: the curve is classified into a canonical
// east-pointing arrow, rasterized once into the texture cache (black
// outline + white inner stroke), and every edge of that shape reuses the
// texture. Everything here is pure + headless; the raylib seam owns the
// cache + the rotated draw.

/// Length granularity of the baked-arrow cache's straight family: the
/// drawn chord snaps to a multiple of this, so the bucketed texture is
/// stretched by at most half a bucket (< 1% stroke-width distortion at
/// map-scale lengths) and near-identical edges share one cache entry.
const baked_arrow_length_bucket: i32 = 8;

/// Perpendicular-bow granularity (the parallel-spread offset axis of the
/// straight family's cache key).
const baked_arrow_bow_bucket: i32 = 8;

/// How far a curve's samples may deviate from its bucketed canonical
/// reconstruction and still bake as it (reference px). The classification
/// is a FIT, not a shape enumeration: anything within this distance of a
/// family member renders as that member; anything farther falls back to
/// the per-segment draw. Generous against integer-rounded control points,
/// tight enough that a genuinely foreign curve keeps the exact path.
const baked_arrow_fit_tolerance: f32 = 8.0;

/// The anti-aliased falloff at the baked silhouette's outer edge (px).
const baked_arrow_edge_falloff: f32 = 1.0;

const FloatVec = struct { x: f32, y: f32 };

fn floatVec(position: ScreenPosition) FloatVec {
    return .{ .x = @floatFromInt(position.x), .y = @floatFromInt(position.y) };
}

fn floatLength(vec: FloatVec) f32 {
    return @sqrt(vec.x * vec.x + vec.y * vec.y);
}

fn floatDistance(a: FloatVec, b: FloatVec) f32 {
    return floatLength(.{ .x = a.x - b.x, .y = a.y - b.y });
}

/// Rotate `point` by -`angle_radians`: the classifier's world -> canonical
/// local transform (the inverse of the placement rotation the draw applies).
fn unrotate(point: FloatVec, angle_radians: f32) FloatVec {
    const cos = @cos(angle_radians);
    const sin = @sin(angle_radians);
    return .{ .x = point.x * cos + point.y * sin, .y = -point.x * sin + point.y * cos };
}

fn bucketToMultiple(value: f32, granularity: i32) i32 {
    return @as(i32, @intFromFloat(@round(value / @as(f32, @floatFromInt(granularity))))) * granularity;
}

/// The baked-arrow families: which canonical shape a curve bakes as. The
/// straight family covers plain straight edges, the parallel-spread bow,
/// and the dashed dangling stub (dashed is a cache-key axis, not a shape);
/// the self_loop family is the fixed-constant teardrop.
pub const BakedArrowVariant = enum { straight, self_loop };

/// One curve's baked-arrow identity: everything the render seam needs to
/// look up (or bake) the texture and place it. `length`/`bow` are the
/// cache-key axes (bucketed); `rotation_degrees` rotates the canonical
/// east-pointing bake onto the curve's placement about the curve's START
/// point (the draw pivot). The width is the outline-INCLUSIVE stroke width
/// (the single decorative curve per edge), so the raster's black outline
/// reaches width/2 and the white inner stroke width/2 - edge_outline_width.
pub const BakedArrowParams = struct {
    variant: BakedArrowVariant,
    /// The bucketed chord length (straight family) or the teardrop's fixed
    /// reach (self_loop family), reference px.
    length: i32,
    /// The bucketed perpendicular control offset - the parallel-spread
    /// bow. Always 0 for self_loop.
    bow: i32,
    width: i32,
    dashed: bool,
    arrowhead: bool,
    /// Clockwise degrees in screen space (y-down); the canonical bake
    /// points east (+x).
    rotation_degrees: f32,
};

/// Classify `curve` into its baked-arrow params, or null when it fits no
/// family (the render seam falls back to the per-segment draw). The fit
/// check is the honest gate: a curve bakes only when its bucketed
/// canonical reconstruction draws within `baked_arrow_fit_tolerance` of
/// the curve's own samples + chevron arms. `max_baked_length` bounds the
/// straight family's baked length (the platform texture limit, expected
/// bucket-rounded): longer edges draw CLAMPED - the accepted shortening -
/// rather than falling back. The self_loop family ignores the bound (its
/// canvas is small). Pure: identical curves give identical params.
pub fn bakedArrowParams(curve: element.Curve, max_baked_length: i32) ?BakedArrowParams {
    if (max_baked_length < baked_arrow_length_bucket) return null;
    if (curve.start.x == curve.end.x and curve.start.y == curve.end.y)
        return bakedLoopParams(curve);
    return bakedStraightParams(curve, max_baked_length);
}

/// The longest straight-arrow length bakeable against a platform texture
/// size limit: the canvas pads the drawn length on both sides (the
/// outline reach + falloff + slack, at the standard edge width) and the
/// classifier expects bucket-aligned bounds, so the bound floors to a
/// bucket multiple. The self_loop family ignores the bound - its canvas
/// is small, and a bake that somehow exceeds the real limit simply fails
/// and the draw falls back to the per-segment path.
pub fn maxBakedArrowLength(max_texture_size: i32) i32 {
    const overhead = 2 * (@divTrunc(edge_width + 2 * edge_outline_width, 2) +
        @as(i32, @intFromFloat(baked_arrow_edge_falloff)) + 1);
    const bounded = @max(baked_arrow_length_bucket, max_texture_size - overhead);
    return @divTrunc(bounded, baked_arrow_length_bucket) * baked_arrow_length_bucket;
}

fn bakedStraightParams(curve: element.Curve, max_baked_length: i32) ?BakedArrowParams {
    const start = floatVec(curve.start);
    const end = floatVec(curve.end);
    const chord = FloatVec{ .x = end.x - start.x, .y = end.y - start.y };
    const length = floatLength(chord);
    if (length < @as(f32, @floatFromInt(baked_arrow_length_bucket))) return null;

    const angle_radians = std.math.atan2(chord.y, chord.x);
    const control_start = unrotate(
        .{ .x = floatVec(curve.control_start).x - start.x, .y = floatVec(curve.control_start).y - start.y },
        angle_radians,
    );
    const control_end = unrotate(
        .{ .x = floatVec(curve.control_end).x - start.x, .y = floatVec(curve.control_end).y - start.y },
        angle_radians,
    );

    // The family's one structural demand: both controls carry the SAME
    // perpendicular offset (the parallel-spread bow). Along-chord control
    // placement is left to the fit check - the reconstruction places
    // controls at the chord thirds and rejects anything the placement
    // moves beyond the tolerance.
    if (@abs(control_start.y - control_end.y) > baked_arrow_fit_tolerance) return null;
    const bow = (control_start.y + control_end.y) / 2.0;

    const length_bucket = bucketToMultiple(length, baked_arrow_length_bucket);
    const bow_bucket = bucketToMultiple(bow, baked_arrow_bow_bucket);
    const canonical = bakedArrowCanonical(.{
        .variant = .straight,
        .length = length_bucket,
        .bow = bow_bucket,
        .width = curve.width,
        .dashed = curve.dashed,
        .arrowhead = curve.arrowhead,
        .rotation_degrees = 0,
    });
    if (!bakedArrowFits(curve, canonical, angle_radians)) return null;

    // The clamp is policy, not classification: the fit was verified
    // against the unclamped bucket, then the drawn length shortens to the
    // platform limit.
    return .{
        .variant = .straight,
        .length = @min(length_bucket, max_baked_length),
        .bow = bow_bucket,
        .width = curve.width,
        .dashed = curve.dashed,
        .arrowhead = curve.arrowhead,
        .rotation_degrees = std.math.radiansToDegrees(angle_radians),
    };
}

fn bakedLoopParams(curve: element.Curve) ?BakedArrowParams {
    const start = floatVec(curve.start);
    const control_start = floatVec(curve.control_start);
    const control_end = floatVec(curve.control_end);
    // The teardrop's axis runs through the control midpoint: both controls
    // sit at the same reach along the departure direction, mirrored across
    // the axis by the half-width, so their midpoint is exactly on the axis.
    const axis = FloatVec{
        .x = (control_start.x + control_end.x) / 2.0 - start.x,
        .y = (control_start.y + control_end.y) / 2.0 - start.y,
    };
    if (floatLength(axis) < baked_arrow_fit_tolerance) return null;
    const angle_radians = std.math.atan2(axis.y, axis.x);

    const canonical = bakedArrowCanonical(.{
        .variant = .self_loop,
        .length = self_loop_length,
        .bow = 0,
        .width = curve.width,
        .dashed = curve.dashed,
        .arrowhead = curve.arrowhead,
        .rotation_degrees = 0,
    });
    if (!bakedArrowFits(curve, canonical, angle_radians)) return null;
    return .{
        .variant = .self_loop,
        .length = self_loop_length,
        .bow = 0,
        .width = curve.width,
        .dashed = curve.dashed,
        .arrowhead = curve.arrowhead,
        .rotation_degrees = std.math.radiansToDegrees(angle_radians),
    };
}

/// The canonical LOCAL curve a params set bakes: oriented east (+x) with
/// the curve's start point at the local origin (0, 0). Straight family:
/// controls at the chord thirds carrying the bow; self_loop family: the
/// fixed teardrop constants (the east-oriented twin of `deriveEdgeGeometry`'s
/// self-loop arm). The rasterizer and the fit check both consume this, so
/// the baked art and the verified shape are the same thing.
fn bakedArrowCanonical(params: BakedArrowParams) element.Curve {
    return switch (params.variant) {
        .straight => element.Curve{
            .start = .{ .x = 0, .y = 0 },
            .control_start = .{ .x = @divTrunc(params.length, 3), .y = params.bow },
            .control_end = .{ .x = @divTrunc(2 * params.length, 3), .y = params.bow },
            .end = .{ .x = params.length, .y = 0 },
            .width = params.width,
            .dashed = params.dashed,
            .arrowhead = params.arrowhead,
        },
        .self_loop => element.Curve{
            .start = .{ .x = 0, .y = 0 },
            .control_start = .{ .x = self_loop_length, .y = self_loop_half_width },
            .control_end = .{ .x = self_loop_length, .y = -self_loop_half_width },
            .end = .{ .x = 0, .y = 0 },
            .width = params.width,
            .dashed = params.dashed,
            .arrowhead = params.arrowhead,
        },
    };
}

/// Whether `curve` (un-rotated by `angle_radians` about its start point)
/// stays within `baked_arrow_fit_tolerance` of the canonical's samples +
/// chevron arms. Corresponding samples are compared point-to-point (both
/// curves are the same family up to a rigid transform, so corresponding
/// points are the near ones).
fn bakedArrowFits(curve: element.Curve, canonical: element.Curve, angle_radians: f32) bool {
    var curve_samples: [element.curve_sample_count + 1]ScreenPosition = undefined;
    var canonical_samples: [element.curve_sample_count + 1]ScreenPosition = undefined;
    element.sampleCurve(curve, &curve_samples);
    element.sampleCurve(canonical, &canonical_samples);

    const origin = floatVec(curve.start);
    for (curve_samples, canonical_samples) |curve_sample, canonical_sample| {
        const local = unrotate(.{
            .x = @as(f32, @floatFromInt(curve_sample.x)) - origin.x,
            .y = @as(f32, @floatFromInt(curve_sample.y)) - origin.y,
        }, angle_radians);
        if (floatDistance(local, floatVec(canonical_sample)) > baked_arrow_fit_tolerance) return false;
    }

    if (curve.arrowhead) {
        const curve_arms = element.arrowheadArms(curve);
        const canonical_arms = element.arrowheadArms(canonical);
        for (curve_arms, canonical_arms) |curve_arm, canonical_arm| {
            const local = unrotate(.{
                .x = @as(f32, @floatFromInt(curve_arm.x)) - origin.x,
                .y = @as(f32, @floatFromInt(curve_arm.y)) - origin.y,
            }, angle_radians);
            if (floatDistance(local, floatVec(canonical_arm)) > baked_arrow_fit_tolerance) return false;
        }
    }
    return true;
}

/// The baked texture's dimensions + the draw pivot (the local origin,
/// i.e. the curve's start point) in canvas pixels.
pub const BakedArrowCanvas = struct {
    width: u32,
    height: u32,
    pivot_x: u32,
    pivot_y: u32,
};

/// The rasterizer's segment budget: the sampled stroke (worst case all
/// `curve_sample_count` segments) + the chevron's two arms.
const max_baked_arrow_segments = element.curve_sample_count + 2;

const BakedArrowSegment = struct { start: FloatVec, end: FloatVec };

/// The local segments the raster strokes: the canonical's sampled polyline
/// (dashed keeps every other segment - the same rule as the per-segment
/// draw) + the chevron arms. Derived from the same samples the hit region
/// uses, so the baked silhouette IS the hit region's shape.
fn bakedArrowSegments(params: BakedArrowParams, segments: *[max_baked_arrow_segments]BakedArrowSegment) usize {
    const canonical = bakedArrowCanonical(params);
    var samples: [element.curve_sample_count + 1]ScreenPosition = undefined;
    element.sampleCurve(canonical, &samples);

    var count: usize = 0;
    var index: usize = 0;
    while (index + 1 < samples.len) : (index += 1) {
        if (params.dashed and index % 2 == 1) continue;
        segments[count] = .{ .start = floatVec(samples[index]), .end = floatVec(samples[index + 1]) };
        count += 1;
    }
    if (params.arrowhead) {
        const tip = floatVec(samples[samples.len - 1]);
        for (element.arrowheadArms(canonical)) |arm| {
            segments[count] = .{ .start = tip, .end = floatVec(arm) };
            count += 1;
        }
    }
    return count;
}

/// Compute the baked texture's canvas for `params`: the local segments'
/// bounding box padded by the outline's reach + the anti-aliased falloff +
/// slack. The padding MUST clear the full outline half-width - the
/// silhouette clips at the canvas border, which would shave the black rim.
pub fn bakedArrowCanvas(params: BakedArrowParams) BakedArrowCanvas {
    var segments: [max_baked_arrow_segments]BakedArrowSegment = undefined;
    const count = bakedArrowSegments(params, &segments);

    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    for (segments[0..count]) |segment| {
        for ([_]FloatVec{ segment.start, segment.end }) |point| {
            min_x = @min(min_x, point.x);
            max_x = @max(max_x, point.x);
            min_y = @min(min_y, point.y);
            max_y = @max(max_y, point.y);
        }
    }

    const pad = @as(f32, @floatFromInt(@divTrunc(params.width, 2))) + baked_arrow_edge_falloff + 1.0;
    min_x -= pad;
    min_y -= pad;
    max_x += pad;
    max_y += pad;

    // The local origin (the curve's start point, the draw pivot) sits at
    // (0, 0); its canvas position is the negated bbox minimum. Every
    // variant's first segment starts at the origin, so the bbox always
    // contains it and both pivots are non-negative.
    return .{
        .width = @intFromFloat(@ceil(max_x - min_x)),
        .height = @intFromFloat(@ceil(max_y - min_y)),
        .pivot_x = @intFromFloat(@ceil(-min_x)),
        .pivot_y = @intFromFloat(@ceil(-min_y)),
    };
}

/// Rasterize `params` into `pixels` (straight-alpha RGBA8, caller-owned,
/// `canvas.width * canvas.height * 4` bytes): the black outline stroke +
/// the WHITE inner stroke in one texture - white overdraws black, so the
/// draw-site tint recolors the white while black stays black under any
/// multiply tint. The stroke is the distance-to-polyline sausage (via
/// `element.distanceToSegment`, the same math the hit region uses): round
/// caps + round joins by construction, with a ~1px anti-aliased falloff at
/// the outer edge. Pure: identical params give identical pixels.
pub fn rasterizeBakedArrow(params: BakedArrowParams, canvas: BakedArrowCanvas, pixels: []u8) void {
    std.debug.assert(pixels.len == @as(usize, @intCast(canvas.width)) * @as(usize, @intCast(canvas.height)) * 4);

    var segments: [max_baked_arrow_segments]BakedArrowSegment = undefined;
    const count = bakedArrowSegments(params, &segments);

    const outline_half = @as(f32, @floatFromInt(@divTrunc(params.width, 2)));
    const inner_half = outline_half - @as(f32, @floatFromInt(edge_outline_width));
    const pivot_x: f32 = @floatFromInt(canvas.pivot_x);
    const pivot_y: f32 = @floatFromInt(canvas.pivot_y);
    const width: usize = @intCast(canvas.width);

    @memset(pixels, 0);
    var pixel_y: usize = 0;
    while (pixel_y < canvas.height) : (pixel_y += 1) {
        var pixel_x: usize = 0;
        while (pixel_x < canvas.width) : (pixel_x += 1) {
            // The pixel's center in local coordinates (canvas pixel
            // (0, 0) covers the bbox corner cell; the pivot is the origin).
            const point = FloatVec{
                .x = @as(f32, @floatFromInt(pixel_x)) + 0.5 - pivot_x,
                .y = @as(f32, @floatFromInt(pixel_y)) + 0.5 - pivot_y,
            };
            var distance: f32 = std.math.floatMax(f32);
            for (segments[0..count]) |segment| {
                distance = @min(
                    distance,
                    element.distanceToSegment(point, segment.start, segment.end),
                );
            }
            if (distance > outline_half + baked_arrow_edge_falloff) continue;

            const alpha: u8 = if (distance <= outline_half)
                255
            else
                @intFromFloat(@max(0.0, (outline_half + baked_arrow_edge_falloff - distance) / baked_arrow_edge_falloff) * 255.0);
            const offset = (pixel_y * width + pixel_x) * 4;
            const is_inner_stroke = distance <= inner_half;
            pixels[offset] = if (is_inner_stroke) 255 else 0;
            pixels[offset + 1] = if (is_inner_stroke) 255 else 0;
            pixels[offset + 2] = if (is_inner_stroke) 255 else 0;
            pixels[offset + 3] = alpha;
        }
    }
}

// ============================================================
// Pure geometry tests - the three classes' shape contracts, asserted
// here in isolation so the builder tests can assert "the drawn curve
// equals deriveEdgeGeometry's output" instead of restating geometry.
// ============================================================

const map_origin_on_screen = ScreenPosition{
    .x = @divTrunc(types.reference_width, 2),
    .y = @divTrunc(types.reference_height, 2),
};

fn expectScreenPositionEqual(expected: ScreenPosition, actual: ScreenPosition) !void {
    if (expected.x != actual.x or expected.y != actual.y) {
        std.debug.print("expected ({d},{d}) got ({d},{d})\n", .{ expected.x, expected.y, actual.x, actual.y });
        return error.TestUnexpectedResult;
    }
}

test "deriveEdgeGeometry: self-loop teardrop anchors on the bearing, controls mirrored" {
    // A self-loop authored north (0 degrees) on the hub at the map origin.
    const geometry = deriveEdgeGeometry(.{ .x = 0, .y = 0 }, .self_loop, 0, .{ .index = 1, .count = 1 });

    // The anchor sits `hub_edge_anchor_radius` NORTH of the hub's screen
    // center; start == end == anchor.
    const anchor = ScreenPosition{
        .x = map_origin_on_screen.x,
        .y = map_origin_on_screen.y - hub_edge_anchor_radius,
    };
    try expectScreenPositionEqual(anchor, geometry.start);
    try expectScreenPositionEqual(anchor, geometry.end);
    try std.testing.expect(!geometry.dashed);

    // The teardrop is symmetric about the direction axis: both controls
    // at the same reach along it, mirrored across it by the half-width.
    try expectScreenPositionEqual(
        .{ .x = anchor.x + self_loop_half_width, .y = anchor.y - self_loop_length },
        geometry.control_start,
    );
    try expectScreenPositionEqual(
        .{ .x = anchor.x - self_loop_half_width, .y = anchor.y - self_loop_length },
        geometry.control_end,
    );
}

test "deriveEdgeGeometry: straight edge endpoints displace to each hub boundary" {
    // Two hubs offset purely horizontally, so the pair axis is east and
    // the displacement math is exact.
    const from_position = Vector2{ .x = -400, .y = 0 };
    const to_position = Vector2{ .x = 400, .y = 0 };
    const geometry = deriveEdgeGeometry(
        from_position,
        .{ .hub = to_position },
        0,
        .{ .index = 1, .count = 1 },
    );

    const from_center = mapToScreen(from_position);
    const to_center = mapToScreen(to_position);
    try expectScreenPositionEqual(
        .{ .x = from_center.x + hub_edge_anchor_radius, .y = from_center.y },
        geometry.start,
    );
    try expectScreenPositionEqual(
        .{ .x = to_center.x - hub_edge_anchor_radius, .y = to_center.y },
        geometry.end,
    );
    try std.testing.expect(!geometry.dashed);

    // A lone edge's controls sit on the segment at 1/3 + 2/3.
    const segment_length = geometry.end.x - geometry.start.x;
    try expectScreenPositionEqual(
        .{ .x = geometry.start.x + @divTrunc(segment_length, 3), .y = from_center.y },
        geometry.control_start,
    );
    try expectScreenPositionEqual(
        .{ .x = geometry.start.x + @divTrunc(2 * segment_length, 3), .y = from_center.y },
        geometry.control_end,
    );
}

test "deriveEdgeGeometry: parallel same-pair edges spread symmetrically" {
    // Two edges sharing the pair, spread by exit index - the shape
    // official content lacks (only self-loops ship), so asserted here on
    // synthetic inputs. A horizontal pair axis makes the perpendicular
    // offsets purely vertical. Only the CONTROLS slide - the endpoints
    // stay anchored at the hub boundaries, so siblings bow apart
    // mid-segment and converge at the hubs.
    const from_position = Vector2{ .x = -400, .y = 0 };
    const to_position = Vector2{ .x = 400, .y = 0 };
    const lone = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 1, .count = 1 });
    const first = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 1, .count = 2 });
    const second = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 2, .count = 2 });

    // Both siblings' controls offset from the lone-edge axis by exactly
    // half the spacing, on OPPOSITE sides (their midpoint is the axis).
    const half_spacing = @divTrunc(parallel_edge_spacing, 2);
    try expectEqualInt(lone.control_start.y - half_spacing, first.control_start.y);
    try expectEqualInt(lone.control_start.y + half_spacing, second.control_start.y);
    try expectEqualInt(
        first.control_start.y + second.control_start.y,
        2 * lone.control_start.y,
    );
    // The endpoints are NOT offset - the hub-boundary anchors hold for
    // every sibling.
    try expectScreenPositionEqual(lone.start, first.start);
    try expectScreenPositionEqual(lone.end, second.end);
}

fn expectEqualInt(expected: i32, actual: i32) !void {
    try std.testing.expectEqual(expected, actual);
}

test "deriveEdgeGeometry: dangling stub dashes along the bearing" {
    // A stub authored south (180 degrees) from the hub at the origin.
    const geometry = deriveEdgeGeometry(.{ .x = 0, .y = 0 }, .dangling, 180, .{ .index = 1, .count = 1 });

    const center = map_origin_on_screen;
    try expectScreenPositionEqual(
        .{ .x = center.x, .y = center.y + hub_edge_anchor_radius },
        geometry.start,
    );
    try expectScreenPositionEqual(
        .{ .x = center.x, .y = center.y + hub_edge_anchor_radius + stub_length },
        geometry.end,
    );
    try std.testing.expect(geometry.dashed);
    // The controls sit on the stub's segment (at 1/3 + 2/3 of its reach).
    try std.testing.expect(geometry.control_start.y > geometry.start.y);
    try std.testing.expect(geometry.control_end.y > geometry.control_start.y);
}

test "deriveEdgeGeometry: coincident hubs fall back to east" {
    // Distinct hubs placed at the SAME map position are legal (positions
    // are unbounded, nothing forbids coincidence); the zero-length pair
    // axis would divide by zero, so the shape falls back to east and
    // stays finite.
    const position = Vector2{ .x = 100, .y = 200 };
    const geometry = deriveEdgeGeometry(position, .{ .hub = position }, 0, .{ .index = 1, .count = 1 });

    const center = mapToScreen(position);
    try expectScreenPositionEqual(.{ .x = center.x + hub_edge_anchor_radius, .y = center.y }, geometry.start);
    try expectScreenPositionEqual(.{ .x = center.x - hub_edge_anchor_radius, .y = center.y }, geometry.end);
    try std.testing.expect(!geometry.dashed);
}

// ============================================================
// Baked arrow tests - classification (the three families + the fit
// gate) and rasterization (layering, round caps, dash gaps, canvas
// padding). Fixtures derive through deriveEdgeGeometry wherever
// possible so the tests assert the REAL emission shapes, not
// hand-built near-misses.
// ============================================================

/// The decorative curve the builders emit for a derived edge, in its
/// post-rework single-curve shape: one curve per edge at the
/// outline-inclusive width carrying the color/alpha state.
fn drawnCurve(geometry: EdgeGeometry) element.Curve {
    return .{
        .start = geometry.start,
        .control_start = geometry.control_start,
        .control_end = geometry.control_end,
        .end = geometry.end,
        .width = edge_width + 2 * edge_outline_width,
        .dashed = geometry.dashed,
        .arrowhead = true,
    };
}

test "bakedArrowParams: straight edge classifies with the chord rotation + exact bucket" {
    // Two hubs offset purely horizontally: the chord is east, and the
    // 800px pair distance minus the two anchor displacements gives a
    // 672px chord - already a multiple of the 8px bucket.
    const from_position = Vector2{ .x = -400, .y = 0 };
    const to_position = Vector2{ .x = 400, .y = 0 };
    const geometry = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 1, .count = 1 });
    const params = bakedArrowParams(drawnCurve(geometry), 4096) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(BakedArrowVariant.straight, params.variant);
    try expectEqualInt(672, params.length);
    try expectEqualInt(0, params.bow);
    try expectEqualInt(edge_width + 2 * edge_outline_width, params.width);
    try std.testing.expect(!params.dashed);
    try std.testing.expect(params.arrowhead);
    try std.testing.expectEqual(@as(f32, 0), params.rotation_degrees);
}

test "bakedArrowParams: diagonal chord rounds the length bucket + derives rotation" {
    // A 3-4-5 pair axis: the chord direction is atan2(4, 3) and the
    // 500px pair distance minus the anchors leaves a ~372.8px chord,
    // which the 8px bucket rounds UP to 376.
    const from_position = Vector2{ .x = 0, .y = 0 };
    const to_position = Vector2{ .x = 300, .y = 400 };
    const geometry = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 1, .count = 1 });
    const params = bakedArrowParams(drawnCurve(geometry), 4096) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(BakedArrowVariant.straight, params.variant);
    try expectEqualInt(376, params.length);
    const expected_rotation = std.math.radiansToDegrees(std.math.atan2(
        @as(f32, @floatFromInt(geometry.end.y - geometry.start.y)),
        @as(f32, @floatFromInt(geometry.end.x - geometry.start.x)),
    ));
    try std.testing.expectApproxEqAbs(expected_rotation, params.rotation_degrees, 0.01);
}

test "bakedArrowParams: parallel siblings bow into opposite buckets, same length" {
    // The same pair with two siblings: the controls slide perpendicular
    // by half the spacing on opposite sides (see the deriveEdgeGeometry
    // parallel test), which is the straight family's bow axis.
    const from_position = Vector2{ .x = -400, .y = 0 };
    const to_position = Vector2{ .x = 400, .y = 0 };
    const first_geometry = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 1, .count = 2 });
    const second_geometry = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 2, .count = 2 });
    const first = bakedArrowParams(drawnCurve(first_geometry), 4096) orelse
        return error.TestUnexpectedResult;
    const second = bakedArrowParams(drawnCurve(second_geometry), 4096) orelse
        return error.TestUnexpectedResult;

    // East chord, so the perpendicular offsets land purely on the bow
    // axis: -half-spacing and +half-spacing.
    try expectEqualInt(-@divTrunc(parallel_edge_spacing, 2), first.bow);
    try expectEqualInt(@divTrunc(parallel_edge_spacing, 2), second.bow);
    // Siblings share the chord: same length bucket, same rotation.
    try expectEqualInt(first.length, second.length);
    try std.testing.expectEqual(first.rotation_degrees, second.rotation_degrees);
}

test "bakedArrowParams: self-loop classifies as the fixed teardrop" {
    // A loop authored north: the axis points north (rotation -90 in
    // screen space), the shape is the fixed-constant teardrop.
    const geometry = deriveEdgeGeometry(.{ .x = 0, .y = 0 }, .self_loop, 0, .{ .index = 1, .count = 1 });
    const params = bakedArrowParams(drawnCurve(geometry), 4096) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(BakedArrowVariant.self_loop, params.variant);
    try expectEqualInt(self_loop_length, params.length);
    try expectEqualInt(0, params.bow);
    try std.testing.expectEqual(@as(f32, -90), params.rotation_degrees);
}

test "bakedArrowParams: dangling stub classifies dashed at the fixed reach" {
    // A stub authored south: the chord is the fixed 300px reach along
    // the bearing, rendered dashed. 300 is NOT a multiple of the 8px
    // bucket (37.5 buckets rounds up), so the drawn stub snaps to 304.
    const geometry = deriveEdgeGeometry(.{ .x = 0, .y = 0 }, .dangling, 180, .{ .index = 1, .count = 1 });
    const params = bakedArrowParams(drawnCurve(geometry), 4096) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(BakedArrowVariant.straight, params.variant);
    try expectEqualInt(304, params.length);
    try std.testing.expect(params.dashed);
    try std.testing.expectEqual(@as(f32, 90), params.rotation_degrees);
}

test "bakedArrowParams: long straight edges clamp to the max baked length" {
    // The 672px chord against a 400px platform limit: the arrow draws
    // CLAMPED (the accepted shortening), not fallen back.
    const from_position = Vector2{ .x = -400, .y = 0 };
    const to_position = Vector2{ .x = 400, .y = 0 };
    const geometry = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 1, .count = 1 });
    const params = bakedArrowParams(drawnCurve(geometry), 400) orelse
        return error.TestUnexpectedResult;
    try expectEqualInt(400, params.length);
}

test "bakedArrowParams: near-family curves snap to their bucket" {
    // Controls nudged by 3px (within the fit tolerance): the bow snaps
    // to the 0 bucket and the curve still bakes - the fit, not exact
    // control equality, is the gate.
    const from_position = Vector2{ .x = -400, .y = 0 };
    const to_position = Vector2{ .x = 400, .y = 0 };
    const geometry = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 1, .count = 1 });
    var nudged = drawnCurve(geometry);
    nudged.control_start.y += 3;
    nudged.control_end.y += 3;
    const params = bakedArrowParams(nudged, 4096) orelse
        return error.TestUnexpectedResult;
    try expectEqualInt(0, params.bow);
}

test "bakedArrowParams: foreign curves fall back to the per-segment draw" {
    // An S-curve: unequal control bows - outside every family.
    const s_curve = element.Curve{
        .start = .{ .x = 0, .y = 0 },
        .control_start = .{ .x = 30, .y = 40 },
        .control_end = .{ .x = 70, .y = -40 },
        .end = .{ .x = 100, .y = 0 },
        .width = edge_width + 2 * edge_outline_width,
        .arrowhead = true,
    };
    try std.testing.expectEqual(@as(?BakedArrowParams, null), bakedArrowParams(s_curve, 4096));

    // A chord shorter than one bucket: degenerate, not bakeable.
    const tiny = element.Curve{
        .start = .{ .x = 0, .y = 0 },
        .control_start = .{ .x = 1, .y = 0 },
        .control_end = .{ .x = 3, .y = 0 },
        .end = .{ .x = 4, .y = 0 },
        .width = edge_width + 2 * edge_outline_width,
    };
    try std.testing.expectEqual(@as(?BakedArrowParams, null), bakedArrowParams(tiny, 4096));

    // A closed curve that is not the standard teardrop: the reach is
    // 500, not the fixed 300 - the sample fit rejects it.
    const foreign_loop = element.Curve{
        .start = .{ .x = 0, .y = 0 },
        .control_start = .{ .x = 500, .y = 100 },
        .control_end = .{ .x = 500, .y = -100 },
        .end = .{ .x = 0, .y = 0 },
        .width = edge_width + 2 * edge_outline_width,
        .arrowhead = true,
    };
    try std.testing.expectEqual(@as(?BakedArrowParams, null), bakedArrowParams(foreign_loop, 4096));

    // A teardrop with its controls SWAPPED: the point set is the same
    // (swapping the controls reverses the traversal, b(t) <-> b(1-t)),
    // but the reversed end tangent flips the chevron onto the other side
    // of the anchor - a DIFFERENT drawn arrow. The fit compares samples
    // point-to-point in traversal order precisely because the chevron is
    // order-sensitive, so the swap must fall back.
    const north_loop = deriveEdgeGeometry(.{ .x = 0, .y = 0 }, .self_loop, 0, .{ .index = 1, .count = 1 });
    const swapped = element.Curve{
        .start = north_loop.end,
        .control_start = north_loop.control_end,
        .control_end = north_loop.control_start,
        .end = north_loop.start,
        .width = edge_width + 2 * edge_outline_width,
        .arrowhead = true,
    };
    try std.testing.expectEqual(@as(?BakedArrowParams, null), bakedArrowParams(swapped, 4096));
}

test "maxBakedArrowLength: the bound subtracts the canvas padding, floors to a bucket" {
    // The canvas pads 12 (outline reach) + 1 (falloff) + 1 (slack) per
    // side = 28 total at the standard edge width; the remainder floors
    // to an 8px multiple (a BOUND rounds down - rounding up could exceed
    // the platform limit).
    try expectEqualInt(4064, maxBakedArrowLength(4096));
    try expectEqualInt(2016, maxBakedArrowLength(2048));
    // A degenerate limit still yields one bucket, never zero or negative
    // (the classifier guards max < bucket itself).
    try expectEqualInt(16, maxBakedArrowLength(50));
}

fn pixelColor(pixels: []const u8, canvas: BakedArrowCanvas, x: usize, y: usize) [4]u8 {
    const offset = (y * @as(usize, @intCast(canvas.width)) + x) * 4;
    return .{ pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3] };
}

fn rasterBuffer(canvas: BakedArrowCanvas) ![]u8 {
    const size = @as(usize, @intCast(canvas.width)) * @as(usize, @intCast(canvas.height)) * 4;
    const pixels = try std.testing.allocator.alloc(u8, size);
    @memset(pixels, 0);
    return pixels;
}

test "rasterizeBakedArrow: the straight arrow layers white inner + black outline with a round cap" {
    const params = BakedArrowParams{
        .variant = .straight,
        .length = 128,
        .bow = 0,
        .width = edge_width + 2 * edge_outline_width,
        .dashed = false,
        .arrowhead = false,
        .rotation_degrees = 0,
    };
    const canvas = bakedArrowCanvas(params);
    const pixels = try rasterBuffer(canvas);
    defer std.testing.allocator.free(pixels);
    rasterizeBakedArrow(params, canvas, pixels);

    // The canvas pads the outline half-width (12) + falloff (1) + slack
    // (1) = 14 on every side; a bow-0 arrow with no chevron spans
    // exactly [0, length] on the axis, so the width is length + 2x14
    // and the pivot sits 14px in.
    try expectEqualInt(14, @intCast(canvas.pivot_x));
    try expectEqualInt(params.length + 28, @intCast(canvas.width));

    const pivot_x: usize = @intCast(canvas.pivot_x);
    const pivot_y: usize = @intCast(canvas.pivot_y);
    const white = [4]u8{ 255, 255, 255, 255 };
    const opaque_black = [4]u8{ 0, 0, 0, 255 };
    const transparent = [4]u8{ 0, 0, 0, 0 };

    // On the centerline: white inner stroke (tail, mid, and just past
    // the tail - the ROUND CAP, the clamped projection's reach).
    try std.testing.expectEqual(white, pixelColor(pixels, canvas, pivot_x, pivot_y));
    try std.testing.expectEqual(white, pixelColor(pixels, canvas, pivot_x + 64, pivot_y));
    try std.testing.expectEqual(white, pixelColor(pixels, canvas, pivot_x - 2, pivot_y));

    // 5.5px off the axis: inside the outline band (inner half is 4),
    // past the inner stroke - black.
    try std.testing.expectEqual(opaque_black, pixelColor(pixels, canvas, pivot_x, pivot_y - 6));

    // 13.5px off the axis: beyond the outline + falloff - transparent.
    try std.testing.expectEqual(transparent, pixelColor(pixels, canvas, pivot_x, 0));
}

test "rasterizeBakedArrow: the chevron arms rasterize with the stroke" {
    const params = BakedArrowParams{
        .variant = .straight,
        .length = 128,
        .bow = 0,
        .width = edge_width + 2 * edge_outline_width,
        .dashed = false,
        .arrowhead = true,
        .rotation_degrees = 0,
    };
    const canvas = bakedArrowCanvas(params);
    const pixels = try rasterBuffer(canvas);
    defer std.testing.allocator.free(pixels);
    rasterizeBakedArrow(params, canvas, pixels);

    // The upper arm runs from the tip (128, 0) back to
    // (128 - 48cos15, 48sin15) ~ (81.5, 12.4); its midpoint is white
    // (the arm carries the same inner stroke).
    const pivot_x: usize = @intCast(canvas.pivot_x);
    const pivot_y: usize = @intCast(canvas.pivot_y);
    const arm_midpoint_x = pivot_x + 105;
    const arm_midpoint_y = pivot_y - 6;
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixelColor(pixels, canvas, arm_midpoint_x, arm_midpoint_y));
}

test "rasterizeBakedArrow: dash gaps render empty at map-scale lengths" {
    // 48 segments over 2400px = 50px per segment, so the skipped
    // odd segments leave 50px gaps that the 12px round caps cannot
    // bridge (at the 300px stub scale the gaps are 6.25px and the caps
    // DO bridge them - the current segment draw has the same property).
    const params = BakedArrowParams{
        .variant = .straight,
        .length = 2400,
        .bow = 0,
        .width = edge_width + 2 * edge_outline_width,
        .dashed = true,
        .arrowhead = false,
        .rotation_degrees = 0,
    };
    const canvas = bakedArrowCanvas(params);
    const pixels = try rasterBuffer(canvas);
    defer std.testing.allocator.free(pixels);
    rasterizeBakedArrow(params, canvas, pixels);

    const pivot_x: usize = @intCast(canvas.pivot_x);
    const pivot_y: usize = @intCast(canvas.pivot_y);

    // Kept segment 0 spans local x [0, 50]: its midpoint is white.
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixelColor(pixels, canvas, pivot_x + 25, pivot_y));
    // Skipped segment 1 spans local x [50, 100]: its midpoint sits 24.5px
    // from either kept segment - past outline + falloff, transparent.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, pixelColor(pixels, canvas, pivot_x + 75, pivot_y));
}

test "rasterizeBakedArrow: the teardrop silhouette stays inside its control hull" {
    const params = BakedArrowParams{
        .variant = .self_loop,
        .length = self_loop_length,
        .bow = 0,
        .width = edge_width + 2 * edge_outline_width,
        .dashed = false,
        .arrowhead = true,
        .rotation_degrees = 0,
    };
    const canvas = bakedArrowCanvas(params);
    const pixels = try rasterBuffer(canvas);
    defer std.testing.allocator.free(pixels);
    rasterizeBakedArrow(params, canvas, pixels);

    // The bezier never reaches its controls: the teardrop's farthest
    // sample is exactly (3/4 x 300, 0) = (225, 0) at t = 0.5, so the
    // canvas is 225 + 2x14 wide - NOT control-width + padding.
    try expectEqualInt(225 + 28, @intCast(canvas.width));

    const pivot_x: usize = @intCast(canvas.pivot_x);
    const pivot_y: usize = @intCast(canvas.pivot_y);

    // The anchor (the local origin) is the curve's start + end: white.
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixelColor(pixels, canvas, pivot_x, pivot_y));
    // The mid-bulb axis point (225, 0): white.
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixelColor(pixels, canvas, pivot_x + 225, pivot_y));
    // Well past the silhouette's widest reach (~35px off-axis at the
    // bulb): transparent.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, pixelColor(pixels, canvas, pivot_x + 225, pivot_y + 45));
}
