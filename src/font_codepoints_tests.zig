//! Contract tests for the shipped font against the cmap reader
//! (src/font_codepoints.zig). Lives in its own file (the
//! content_validation_tests.zig pattern) because it imports the
//! generated_assets module for the embedded TTF bytes — a named module the
//! generator tool, which also compiles font_codepoints.zig, does not have.
//! See DESIGN → Platform Seam → SDF text outline.

const std = @import("std");
const font_codepoints = @import("font_codepoints.zig");
const embedded_assets = @import("generated_assets");

/// Binary-search a sorted codepoint slice (std.sort.isIn does not exist in
/// 0.16's std).
fn covered(codepoint: u21, sorted_codepoints: []const u21) bool {
    return std.sort.binarySearch(u21, sorted_codepoints, codepoint, struct {
        fn compare(key: u21, item: u21) std.math.Order {
            return std.math.order(key, item);
        }
    }.compare) != null;
}

test "shipped font: cmap parse yields sorted, deduped, bounded codepoints" {
    const allocator = std.testing.allocator;
    const ttf_bytes = embedded_assets.map.get("assets/fonts/cause-semibold.ttf") orelse
        return error.TestUnexpectedResult;

    const codepoints = try font_codepoints.fontCodepoints(allocator, ttf_bytes);
    defer allocator.free(codepoints);

    // Sorted ascending + deduplicated.
    for (codepoints, 0..) |codepoint, index| {
        if (index > 0) try std.testing.expect(codepoint > codepoints[index - 1]);
    }
    // Within the bound every bake consumer shares (the SDF blob parser's
    // guard, the generator's gate, the runtime fallback's check).
    try std.testing.expect(codepoints.len <= font_codepoints.max_atlas_codepoints);
}

test "shipped font: full ASCII plus the atlas punctuation set is covered" {
    const allocator = std.testing.allocator;
    const ttf_bytes = embedded_assets.map.get("assets/fonts/cause-semibold.ttf") orelse
        return error.TestUnexpectedResult;

    const codepoints = try font_codepoints.fontCodepoints(allocator, ttf_bytes);
    defer allocator.free(codepoints);

    // The 95-codepoint set raylib's default bake uses stays covered — a
    // future font swap that drops any of it would render '?' for ASCII.
    for (0x20..0x7F) |codepoint| {
        try std.testing.expect(covered(@intCast(codepoint), codepoints));
    }
    // The punctuation the dash-sweep policy + rendered text rely on:
    // en-dash U+2013, em-dash U+2014, ellipsis U+2026.
    for ([_]u21{ 0x2013, 0x2014, 0x2026 }) |codepoint| {
        try std.testing.expect(covered(codepoint, codepoints));
    }
}
