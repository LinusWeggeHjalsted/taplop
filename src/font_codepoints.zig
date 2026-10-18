//! The TTF cmap reader behind the glyph-atlas codepoint set: every font
//! bake (the build-time SDF atlas generator AND the runtime coverage-atlas
//! fallback in src/raylib/text.zig) bakes EXACTLY the codepoints the font
//! itself maps - derived from the font file, never a hand-maintained list,
//! so a font swap changes the coverage automatically. Pure bytes-in,
//! codepoints-out (raylib-free, I/O-free); on malformed input the callers
//! degrade to raylib's default 95-ASCII bake (or panic, at build time).
//! See DESIGN → Platform Seam → SDF text outline.

const std = @import("std");

/// Every error `fontCodepoints` can produce: malformed TTF structure
/// (truncated tables, missing cmap, unsupported subtable format) or
/// allocation failure. Never produced by a merely unusual-but-valid font.
pub const FontCodepointsError = error{ InvalidFont, OutOfMemory };

/// Upper bound on baked codepoints, shared by every consumer: the SDF blob
/// parser's sanity guard in src/raylib/text.zig, the generator's build-time
/// gate, and the runtime fallback's degradation check. A font mapping more
/// than this (e.g. a pan-CJK font) would bake an enormous atlas; swapping
/// such a font in is a deliberate act that must revisit this bound.
pub const max_atlas_codepoints: usize = 1024;

/// Every codepoint the font's cmap maps to a glyph (glyph 0 / notdef and
/// NUL excluded - no string contains NUL, and many fonts map it to the
/// blank .null glyph), sorted ascending and deduplicated. Caller owns the
/// slice.
pub fn fontCodepoints(
    allocator: std.mem.Allocator,
    ttf_bytes: []const u8,
) FontCodepointsError![]u21 {
    var codepoints: std.ArrayListUnmanaged(u21) = .empty;
    errdefer codepoints.deinit(allocator);

    const subtable = try findCmapSubtable(ttf_bytes);
    switch (subtable.format) {
        4 => try collectFormat4(allocator, &codepoints, subtable.bytes),
        12 => try collectFormat12(allocator, &codepoints, subtable.bytes),
        else => unreachable, // findCmapSubtable only yields formats 4 and 12
    }

    std.mem.sort(u21, codepoints.items, {}, struct {
        fn lessThan(_: void, a: u21, b: u21) bool {
            return a < b;
        }
    }.lessThan);
    var write_index: usize = 0;
    for (codepoints.items) |codepoint| {
        if (codepoint == 0) continue; // NUL: see the doc comment above
        if (write_index == 0 or codepoint != codepoints.items[write_index - 1]) {
            codepoints.items[write_index] = codepoint;
            write_index += 1;
        }
    }
    codepoints.shrinkRetainingCapacity(write_index);
    return codepoints.toOwnedSlice(allocator);
}

const CmapSubtable = struct {
    format: u16,
    /// The subtable bytes, running to the end of the cmap table (the format
    /// parsers bound-check their own fields against this slice).
    bytes: []const u8,
};

/// Locate the cmap table and pick its best subtable (the standard
/// "best cmap" preference: Windows Unicode-full, then Windows Unicode-BMP,
/// then any platform-0 Unicode, then the first parseable one). Only
/// subtables of format 4 (BMP segments) or 12 (full Unicode groups) are
/// usable; a cmap offering neither is an invalid font for our purposes.
fn findCmapSubtable(ttf_bytes: []const u8) error{InvalidFont}!CmapSubtable {
    if (ttf_bytes.len < 12) return error.InvalidFont;
    const table_count = try be16(ttf_bytes, 4);
    if (table_count == 0) return error.InvalidFont;
    const directory_end = 12 + @as(usize, table_count) * 16;
    if (directory_end > ttf_bytes.len) return error.InvalidFont;

    var cmap_bytes: ?[]const u8 = null;
    var table_index: usize = 0;
    while (table_index < table_count) : (table_index += 1) {
        const record_offset = 12 + table_index * 16;
        if (!std.mem.eql(u8, ttf_bytes[record_offset..][0..4], "cmap")) continue;
        const table_offset = try be32(ttf_bytes, record_offset + 8);
        if (table_offset >= ttf_bytes.len) return error.InvalidFont;
        // The record's length can be stale on hand-patched fonts; clamp to
        // the buffer end rather than trust it.
        const table_end = @min(table_offset + try be32(ttf_bytes, record_offset + 12), ttf_bytes.len);
        if (table_end < table_offset + 4) return error.InvalidFont;
        cmap_bytes = ttf_bytes[table_offset..table_end];
        break;
    }
    const cmap = cmap_bytes orelse return error.InvalidFont;

    if (cmap.len < 4) return error.InvalidFont;
    const subtable_count = try be16(cmap, 2);
    if (subtable_count == 0) return error.InvalidFont;
    const records_end = 4 + @as(usize, subtable_count) * 8;
    if (records_end > cmap.len) return error.InvalidFont;

    // Preference passes: (3,10) then (3,1), then any platform-0 record,
    // then any record at all. Each pass resolves the FIRST record whose
    // subtable has a supported format.
    var pass: usize = 0;
    while (pass < 4) : (pass += 1) {
        var record_index: usize = 0;
        while (record_index < subtable_count) : (record_index += 1) {
            const record_offset = 4 + record_index * 8;
            const platform = try be16(cmap, record_offset);
            const encoding = try be16(cmap, record_offset + 2);
            const matches = switch (pass) {
                0 => platform == 3 and encoding == 10,
                1 => platform == 3 and encoding == 1,
                2 => platform == 0,
                else => true,
            };
            if (!matches) continue;
            if (try subtableAt(cmap, try be32(cmap, record_offset + 4))) |subtable| return subtable;
        }
    }
    return error.InvalidFont;
}

/// Resolve one subtable (offset relative to the cmap start); null when it
/// is out of bounds or has an unsupported format.
fn subtableAt(cmap: []const u8, offset: u32) error{InvalidFont}!?CmapSubtable {
    const start: usize = @intCast(offset);
    if (start + 2 > cmap.len) return error.InvalidFont;
    const format = try be16(cmap, start);
    if (format != 4 and format != 12) return null;
    return .{ .format = format, .bytes = cmap[start..] };
}

/// Format 4 (BMP segmented coverage). Layout (offsets from subtable start):
///   format u16, length u16, language u16, segCountX2 u16, searchRange u16,
///   entrySelector u16, rangeShift u16, then per-segment arrays
///   endCode[segCount] u16, reservedPad u16, startCode[segCount] u16,
///   idDelta[segCount] i16, idRangeOffset[segCount] u16, glyphIdArray u16[].
/// A codepoint is mapped iff its glyph id resolves nonzero: idDelta added
/// mod 2^16 when idRangeOffset is 0, else the glyphIdArray entry addressed
/// by idRangeOffset (a byte offset from the idRangeOffset entry itself).
fn collectFormat4(
    allocator: std.mem.Allocator,
    codepoints: *std.ArrayListUnmanaged(u21),
    subtable: []const u8,
) FontCodepointsError!void {
    if (subtable.len < 14) return error.InvalidFont;
    const segment_count_x2 = try be16(subtable, 6);
    if (segment_count_x2 == 0 or segment_count_x2 % 2 != 0) return error.InvalidFont;
    const segment_count: usize = segment_count_x2 / 2;
    const arrays_end = 16 + segment_count * 8;
    if (subtable.len < arrays_end) return error.InvalidFont;

    const end_code_base = 14;
    const start_code_base = 16 + segment_count * 2;
    const id_delta_base = 16 + segment_count * 4;
    const id_range_offset_base = 16 + segment_count * 6;

    for (0..segment_count) |segment_index| {
        const start = try be16(subtable, start_code_base + segment_index * 2);
        const end = try be16(subtable, end_code_base + segment_index * 2);
        // Malformed segment (start past end) - skip, not fail: the rest of
        // the cmap can still be valid.
        if (start > end) continue;
        // The mandatory trailing segment maps 0xFFFF to glyph 0 (notdef);
        // it never contributes a real codepoint.
        if (end == 0xFFFF) continue;
        const delta = try be16(subtable, id_delta_base + segment_index * 2);
        const range_offset = try be16(subtable, id_range_offset_base + segment_index * 2);

        var codepoint: u32 = start;
        while (codepoint <= end) : (codepoint += 1) {
            const mapped = if (range_offset == 0)
                ((codepoint + delta) & 0xFFFF) != 0
            else blk: {
                // glyphIdArray address: idRangeOffset[i] entry position +
                // idRangeOffset value + 2*(cp - segment start).
                const address = id_range_offset_base + segment_index * 2 + range_offset + 2 * (codepoint - start);
                if (address + 2 > subtable.len) break :blk false;
                break :blk (try be16(subtable, address)) != 0;
            };
            if (mapped) try codepoints.append(allocator, @intCast(codepoint));
        }
    }
}

/// Format 12 (segmented coverage over full Unicode). Groups of
/// { startCharCode u32, endCharCode u32, startGlyphID u32 }; every
/// codepoint in the range is mapped, except groups mapping to glyph 0.
fn collectFormat12(
    allocator: std.mem.Allocator,
    codepoints: *std.ArrayListUnmanaged(u21),
    subtable: []const u8,
) FontCodepointsError!void {
    if (subtable.len < 16) return error.InvalidFont;
    const group_count = try be32(subtable, 12);
    // Each group is 12 bytes; a count exceeding the remaining bytes is a
    // malformed table, not a huge-but-valid one.
    if (group_count > (subtable.len - 16) / 12) return error.InvalidFont;

    for (0..group_count) |group_index| {
        const group_offset = 16 + group_index * 12;
        const start = try be32(subtable, group_offset);
        const end = try be32(subtable, group_offset + 4);
        const start_glyph = try be32(subtable, group_offset + 8);
        if (start_glyph == 0) continue;
        if (start > end or start > max_unicode) continue;
        const clamped_end = @min(end, max_unicode);
        var codepoint = start;
        while (codepoint <= clamped_end) : (codepoint += 1) {
            try codepoints.append(allocator, @intCast(codepoint));
        }
    }
}

const max_unicode: u32 = 0x10FFFF;

fn be16(bytes: []const u8, offset: usize) error{InvalidFont}!u16 {
    if (offset + 2 > bytes.len) return error.InvalidFont;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn be32(bytes: []const u8, offset: usize) error{InvalidFont}!u32 {
    if (offset + 4 > bytes.len) return error.InvalidFont;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

// ============================================================
// Tests (hand-built fixture TTFs; the shipped-font contract test lives
// in font_codepoints_tests.zig where the generated_assets module exists)
// ============================================================

/// Assemble a minimal TTF: 12-byte offset table, one table-directory record
/// pointing at `cmap_bytes`, then the cmap payload. Enough structure for
/// findCmapSubtable to walk.
fn fixtureTtf(allocator: std.mem.Allocator, cmap_bytes: []const u8) []u8 {
    var ttf: std.ArrayListUnmanaged(u8) = .empty;
    ttf.appendSlice(allocator, &.{ 0x00, 0x01, 0x00, 0x00 }) catch unreachable; // sfnt version
    ttf.appendSlice(allocator, &.{ 0x00, 0x01 }) catch unreachable; // numTables = 1
    ttf.appendSlice(allocator, &([_]u8{0} ** 6)) catch unreachable; // search fields (unused)
    ttf.appendSlice(allocator, "cmap") catch unreachable;
    ttf.appendSlice(allocator, &([_]u8{0} ** 4)) catch unreachable; // checksum
    ttf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x1C }) catch unreachable; // offset = 28
    const length: u32 = @intCast(cmap_bytes.len);
    ttf.append(allocator, @truncate(length >> 24)) catch unreachable;
    ttf.append(allocator, @truncate(length >> 16)) catch unreachable;
    ttf.append(allocator, @truncate(length >> 8)) catch unreachable;
    ttf.append(allocator, @truncate(length)) catch unreachable;
    ttf.appendSlice(allocator, cmap_bytes) catch unreachable;
    return ttf.toOwnedSlice(allocator) catch unreachable;
}

/// Wrap `subtable` in a cmap header carrying one (platform 3, encoding 1)
/// record pointing at it - the common Windows Unicode-BMP shape.
fn fixtureCmap(allocator: std.mem.Allocator, subtable: []const u8) []u8 {
    var cmap: std.ArrayListUnmanaged(u8) = .empty;
    cmap.appendSlice(allocator, &.{ 0x00, 0x00 }) catch unreachable; // version
    cmap.appendSlice(allocator, &.{ 0x00, 0x01 }) catch unreachable; // numTables = 1
    cmap.appendSlice(allocator, &.{ 0x00, 0x03 }) catch unreachable; // platformID = 3
    cmap.appendSlice(allocator, &.{ 0x00, 0x01 }) catch unreachable; // encodingID = 1
    cmap.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x0C }) catch unreachable; // offset = 12
    cmap.appendSlice(allocator, subtable) catch unreachable;
    return cmap.toOwnedSlice(allocator) catch unreachable;
}

/// Build a format-4 subtable from segments. `segments` carries
/// { start, end, delta, range_offset } in order; `glyph_ids` becomes the
/// glyphIdArray the range_offset segments address. The mandatory 0xFFFF
/// sentinel segment is appended automatically.
const Segment = struct { start: u16, end: u16, delta: u16, range_offset: u16 };

fn fixtureFormat4(allocator: std.mem.Allocator, segments: []const Segment, glyph_ids: []const u16) []u8 {
    const all = segments.len + 1; // + sentinel
    var sub: std.ArrayListUnmanaged(u8) = .empty;
    sub.appendSlice(allocator, &.{ 0x00, 0x04 }) catch unreachable; // format
    const length: u16 = @intCast(16 + all * 8 + glyph_ids.len * 2);
    sub.append(allocator, @truncate(length >> 8)) catch unreachable;
    sub.append(allocator, @truncate(length)) catch unreachable;
    sub.appendSlice(allocator, &([_]u8{0} ** 2)) catch unreachable; // language
    sub.append(allocator, @truncate((all * 2) >> 8)) catch unreachable; // segCountX2
    sub.append(allocator, @truncate(all * 2)) catch unreachable;
    sub.appendSlice(allocator, &([_]u8{0} ** 6)) catch unreachable; // search fields

    for (segments) |segment| {
        sub.append(allocator, @truncate(segment.end >> 8)) catch unreachable;
        sub.append(allocator, @truncate(segment.end)) catch unreachable;
    }
    sub.appendSlice(allocator, &.{ 0xFF, 0xFF }) catch unreachable; // sentinel endCode
    sub.appendSlice(allocator, &.{ 0x00, 0x00 }) catch unreachable; // reservedPad
    for (segments) |segment| {
        sub.append(allocator, @truncate(segment.start >> 8)) catch unreachable;
        sub.append(allocator, @truncate(segment.start)) catch unreachable;
    }
    sub.appendSlice(allocator, &.{ 0xFF, 0xFF }) catch unreachable; // sentinel startCode
    for (segments) |segment| {
        sub.append(allocator, @truncate(segment.delta >> 8)) catch unreachable;
        sub.append(allocator, @truncate(segment.delta)) catch unreachable;
    }
    sub.appendSlice(allocator, &.{ 0x00, 0x01 }) catch unreachable; // sentinel idDelta
    for (segments) |segment| {
        sub.append(allocator, @truncate(segment.range_offset >> 8)) catch unreachable;
        sub.append(allocator, @truncate(segment.range_offset)) catch unreachable;
    }
    sub.appendSlice(allocator, &.{ 0x00, 0x00 }) catch unreachable; // sentinel idRangeOffset
    for (glyph_ids) |glyph_id| {
        sub.append(allocator, @truncate(glyph_id >> 8)) catch unreachable;
        sub.append(allocator, @truncate(glyph_id)) catch unreachable;
    }
    return sub.toOwnedSlice(allocator) catch unreachable;
}

/// Build a format-12 subtable from groups of { start, end, start_glyph }.
const Group = struct { start: u32, end: u32, start_glyph: u32 };

fn fixtureFormat12(allocator: std.mem.Allocator, groups: []const Group) []u8 {
    var sub: std.ArrayListUnmanaged(u8) = .empty;
    sub.appendSlice(allocator, &.{ 0x00, 0x0C }) catch unreachable; // format
    sub.appendSlice(allocator, &([_]u8{0} ** 2)) catch unreachable; // reserved
    sub.appendSlice(allocator, &([_]u8{0} ** 4)) catch unreachable; // length (unused by parser)
    sub.appendSlice(allocator, &([_]u8{0} ** 4)) catch unreachable; // language
    const count: u32 = @intCast(groups.len);
    sub.append(allocator, @truncate(count >> 24)) catch unreachable;
    sub.append(allocator, @truncate(count >> 16)) catch unreachable;
    sub.append(allocator, @truncate(count >> 8)) catch unreachable;
    sub.append(allocator, @truncate(count)) catch unreachable;
    for (groups) |group| {
        for ([_]u32{ group.start, group.end, group.start_glyph }) |value| {
            sub.append(allocator, @truncate(value >> 24)) catch unreachable;
            sub.append(allocator, @truncate(value >> 16)) catch unreachable;
            sub.append(allocator, @truncate(value >> 8)) catch unreachable;
            sub.append(allocator, @truncate(value)) catch unreachable;
        }
    }
    return sub.toOwnedSlice(allocator) catch unreachable;
}

test "format 4: mapped codepoints collected, glyph-0 and sentinel skipped" {
    const allocator = std.testing.allocator;
    // Segment 0: NUL mapped to glyph 1 - the blank .null glyph many fonts
    // carry; no string contains NUL, so it must be EXCLUDED.
    // Segment 1: 'A'..'D' with delta -0x44 → 'D' resolves to glyph 0
    // (unmapped), 'A'..'C' to glyphs 1..3. Segment 2: en/em-dash via
    // idRangeOffset into glyphIdArray [7, 0] → em-dash unmapped.
    // idRangeOffset[2] sits at 16 + 4*6 + 2*2 = 44 in this 4-segment table
    // (3 real + sentinel); glyphIdArray starts at 16 + 4*8 = 48 → offset 4.
    const segments = [_]Segment{
        .{ .start = 0, .end = 0, .delta = 1, .range_offset = 0 },
        .{ .start = 'A', .end = 'D', .delta = 0x10000 - 0x44, .range_offset = 0 },
        .{ .start = 0x2013, .end = 0x2014, .delta = 0, .range_offset = 4 },
    };
    const subtable = fixtureFormat4(allocator, &segments, &.{ 7, 0 });
    defer allocator.free(subtable);
    const cmap = fixtureCmap(allocator, subtable);
    defer allocator.free(cmap);
    const ttf = fixtureTtf(allocator, cmap);
    defer allocator.free(ttf);

    const codepoints = try fontCodepoints(allocator, ttf);
    defer allocator.free(codepoints);
    try std.testing.expectEqualSlices(u21, &.{ 'A', 'B', 'C', 0x2013 }, codepoints);
}

test "format 12: groups collected, glyph-0 groups skipped" {
    const allocator = std.testing.allocator;
    const groups = [_]Group{
        .{ .start = 0x41, .end = 0x43, .start_glyph = 1 },
        .{ .start = 0x2014, .end = 0x2014, .start_glyph = 9 },
        .{ .start = 0x3000, .end = 0x3002, .start_glyph = 0 }, // notdef → skipped
    };
    const subtable = fixtureFormat12(allocator, &groups);
    defer allocator.free(subtable);
    const cmap = fixtureCmap(allocator, subtable);
    defer allocator.free(cmap);
    const ttf = fixtureTtf(allocator, cmap);
    defer allocator.free(ttf);

    const codepoints = try fontCodepoints(allocator, ttf);
    defer allocator.free(codepoints);
    try std.testing.expectEqualSlices(u21, &.{ 0x41, 0x42, 0x43, 0x2014 }, codepoints);
}

test "format 12: a range ending past max Unicode is clamped, not rejected" {
    const allocator = std.testing.allocator;
    const groups = [_]Group{.{ .start = 0x10FFFE, .end = 0x200000, .start_glyph = 1 }};
    const subtable = fixtureFormat12(allocator, &groups);
    defer allocator.free(subtable);
    const cmap = fixtureCmap(allocator, subtable);
    defer allocator.free(cmap);
    const ttf = fixtureTtf(allocator, cmap);
    defer allocator.free(ttf);

    const codepoints = try fontCodepoints(allocator, ttf);
    defer allocator.free(codepoints);
    try std.testing.expectEqualSlices(u21, &.{ 0x10FFFE, 0x10FFFF }, codepoints);
}

test "overlapping ranges are deduplicated into a sorted set" {
    const allocator = std.testing.allocator;
    const groups = [_]Group{
        .{ .start = 0x2013, .end = 0x2014, .start_glyph = 1 },
        .{ .start = 'A', .end = 'B', .start_glyph = 1 },
        .{ .start = 0x2014, .end = 0x2014, .start_glyph = 5 },
    };
    const subtable = fixtureFormat12(allocator, &groups);
    defer allocator.free(subtable);
    const cmap = fixtureCmap(allocator, subtable);
    defer allocator.free(cmap);
    const ttf = fixtureTtf(allocator, cmap);
    defer allocator.free(ttf);

    const codepoints = try fontCodepoints(allocator, ttf);
    defer allocator.free(codepoints);
    try std.testing.expectEqualSlices(u21, &.{ 'A', 'B', 0x2013, 0x2014 }, codepoints);
}

test "malformed inputs are errors, never panics" {
    const allocator = std.testing.allocator;

    // A table directory with no cmap record.
    const no_cmap = blk: {
        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        defer bytes.deinit(allocator);
        bytes.appendSlice(allocator, &.{ 0x00, 0x01, 0x00, 0x00 }) catch unreachable;
        bytes.appendSlice(allocator, &.{ 0x00, 0x01 }) catch unreachable;
        bytes.appendSlice(allocator, &([_]u8{0} ** 6)) catch unreachable;
        bytes.appendSlice(allocator, "glyf") catch unreachable;
        bytes.appendSlice(allocator, &([_]u8{0} ** 12)) catch unreachable;
        break :blk bytes.toOwnedSlice(allocator) catch unreachable;
    };
    defer allocator.free(no_cmap);

    // A cmap whose only subtable is an unsupported format (6).
    const unsupported_format = blk: {
        const subtable = [_]u8{ 0x00, 0x06 } ++ [_]u8{0} ** 10;
        const cmap = fixtureCmap(allocator, &subtable);
        defer allocator.free(cmap);
        break :blk fixtureTtf(allocator, cmap);
    };
    defer allocator.free(unsupported_format);

    // Static literals + the two built fixtures above; nothing is freed in
    // the loop (the literals live in static memory).
    const cases = [_][]const u8{
        &.{}, // empty
        &.{ 0x00, 0x01, 0x00, 0x00, 0x00 }, // truncated header
        &.{ 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // zero tables
        // directory declaring more tables than bytes present
        &.{ 0x00, 0x01, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        no_cmap,
        unsupported_format,
    };
    for (cases) |ttf_bytes| {
        try std.testing.expectError(error.InvalidFont, fontCodepoints(allocator, ttf_bytes));
    }
}
