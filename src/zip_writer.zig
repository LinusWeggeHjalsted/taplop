//! Minimal ZIP archive writer — STORE method only (no compression), the
//! shape `std.zip` (the read side) accepts. Used by the editor's mission
//! export (see input_handlers.exportEditorMission — DESIGN → Level Editor,
//! the export flow). Pure: bytes in, archive bytes out, no IO — directly
//! round-trip-testable.

const std = @import("std");

/// One archived file: its archive-relative name (flat names — no `/`
/// hierarchy; a mission zip is the mission directory's files at the root)
/// and contents.
pub const ZipEntry = struct {
    name: []const u8,
    bytes: []const u8,
};

/// The fixed modification timestamp written into every record: 1980-01-01
/// 00:00 (the DOS epoch — the earliest representable date). The export is
/// a transient artifact; real mtimes are not worth threading through.
const dos_time: u16 = 0;
const dos_date: u16 = (1 << 5) | 1; // 1980-01-01 (year 0, month 1, day 1).

/// Build a ZIP archive from `entries`. All entries are stored uncompressed
/// (STORE): mission files are text (tiny) and custom sprites are PNGs
/// (already compressed) — deflating buys nothing for either.
pub fn writeZipArchive(
    entries: []const ZipEntry,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var archive: std.ArrayList(u8) = .empty;

    // Local file headers + data, remembering each header's offset for the
    // central directory.
    var header_offsets = try allocator.alloc(u32, entries.len);
    defer allocator.free(header_offsets);
    for (entries, 0..) |entry, index| {
        header_offsets[index] = @intCast(archive.items.len);
        // Local file header (30 bytes + name).
        try appendInt(&archive, allocator, u32, 0x04034b50);
        try appendInt(&archive, allocator, u16, 20); // version needed (2.0)
        try appendInt(&archive, allocator, u16, 0x0800); // flags: UTF-8 names
        try appendInt(&archive, allocator, u16, 0); // method: store
        try appendInt(&archive, allocator, u16, dos_time);
        try appendInt(&archive, allocator, u16, dos_date);
        try appendInt(&archive, allocator, u32, std.hash.Crc32.hash(entry.bytes));
        try appendInt(&archive, allocator, u32, @intCast(entry.bytes.len)); // compressed size (store: same)
        try appendInt(&archive, allocator, u32, @intCast(entry.bytes.len)); // uncompressed size
        try appendInt(&archive, allocator, u16, @intCast(entry.name.len));
        try appendInt(&archive, allocator, u16, 0); // extra field length
        try archive.appendSlice(allocator, entry.name);
        try archive.appendSlice(allocator, entry.bytes);
    }

    // Central directory (46 bytes + name per entry).
    const central_directory_offset: u32 = @intCast(archive.items.len);
    for (entries, 0..) |entry, index| {
        try appendInt(&archive, allocator, u32, 0x02014b50);
        try appendInt(&archive, allocator, u16, 20); // version made by
        try appendInt(&archive, allocator, u16, 20); // version needed
        try appendInt(&archive, allocator, u16, 0x0800); // flags: UTF-8
        try appendInt(&archive, allocator, u16, 0); // method: store
        try appendInt(&archive, allocator, u16, dos_time);
        try appendInt(&archive, allocator, u16, dos_date);
        try appendInt(&archive, allocator, u32, std.hash.Crc32.hash(entry.bytes));
        try appendInt(&archive, allocator, u32, @intCast(entry.bytes.len));
        try appendInt(&archive, allocator, u32, @intCast(entry.bytes.len));
        try appendInt(&archive, allocator, u16, @intCast(entry.name.len));
        try appendInt(&archive, allocator, u16, 0); // extra length
        try appendInt(&archive, allocator, u16, 0); // comment length
        try appendInt(&archive, allocator, u16, 0); // disk number start
        try appendInt(&archive, allocator, u16, 0); // internal attributes
        try appendInt(&archive, allocator, u32, 0); // external attributes
        try appendInt(&archive, allocator, u32, header_offsets[index]);
        try archive.appendSlice(allocator, entry.name);
    }
    const central_directory_size: u32 = @intCast(archive.items.len - central_directory_offset);

    // End of central directory (22 bytes).
    try appendInt(&archive, allocator, u32, 0x06054b50);
    try appendInt(&archive, allocator, u16, 0); // this disk
    try appendInt(&archive, allocator, u16, 0); // central directory disk
    try appendInt(&archive, allocator, u16, @intCast(entries.len)); // records this disk
    try appendInt(&archive, allocator, u16, @intCast(entries.len)); // records total
    try appendInt(&archive, allocator, u32, central_directory_size);
    try appendInt(&archive, allocator, u32, central_directory_offset);
    try appendInt(&archive, allocator, u16, 0); // comment length

    return archive.toOwnedSlice(allocator);
}

fn appendInt(
    archive: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime Int: type,
    value: Int,
) !void {
    var buffer: [@sizeOf(Int)]u8 = undefined;
    std.mem.writeInt(Int, &buffer, value, .little);
    try archive.appendSlice(allocator, &buffer);
}

test "zip archive: central directory walk verifies names, sizes, and stored contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]ZipEntry{
        .{ .name = "mission.txt", .bytes = "Metadata\nfile_format_version 2\n" },
        .{ .name = "level_1.txt", .bytes = "!=" },
        .{ .name = "boss.png", .bytes = "pretend png bytes" },
    };
    const archive = try writeZipArchive(&entries, allocator);

    // End of central directory: the last 22 bytes of the archive.
    try std.testing.expect(archive.len >= 22);
    const end_record = archive[archive.len - 22 ..];
    try std.testing.expectEqual(@as(u32, 0x06054b50), readInt(u32, end_record[0..4]));
    try std.testing.expectEqual(@as(u16, 3), readInt(u16, end_record[10..12]));
    const central_directory_size = readInt(u32, end_record[12..16]);
    const central_directory_offset = readInt(u32, end_record[16..20]);
    try std.testing.expectEqual(@as(u32, @intCast(archive.len - 22)), central_directory_offset + central_directory_size);

    // Walk the central directory; each record points at a local header
    // whose STORED data is the raw entry bytes.
    var offset: usize = central_directory_offset;
    for (entries) |expected| {
        const record = archive[offset .. offset + 46];
        try std.testing.expectEqual(@as(u32, 0x02014b50), readInt(u32, record[0..4]));
        try std.testing.expectEqual(@as(u16, 0), readInt(u16, record[10..12])); // method: store
        const crc32 = readInt(u32, record[16..20]);
        const size = readInt(u32, record[20..24]);
        const name_length: usize = readInt(u16, record[28..30]);
        const header_offset: usize = readInt(u32, record[42..46]);
        const name = archive[offset + 46 .. offset + 46 + name_length];
        try std.testing.expectEqualStrings(expected.name, name);
        try std.testing.expectEqual(expected.bytes.len, size);
        try std.testing.expectEqual(std.hash.Crc32.hash(expected.bytes), crc32);

        // The local header (30 + name length) then the raw stored bytes.
        const local = archive[header_offset .. header_offset + 30 + name_length];
        try std.testing.expectEqual(@as(u32, 0x04034b50), readInt(u32, local[0..4]));
        try std.testing.expectEqualStrings(expected.name, local[30 .. 30 + name_length]);
        try std.testing.expectEqualStrings(expected.bytes, archive[header_offset + 30 + name_length ..][0..size]);

        offset += 46 + name_length;
    }
    try std.testing.expectEqual(offset, central_directory_offset + central_directory_size);
}

fn readInt(comptime Int: type, bytes: []const u8) Int {
    return std.mem.readInt(Int, bytes[0..@sizeOf(Int)], .little);
}
