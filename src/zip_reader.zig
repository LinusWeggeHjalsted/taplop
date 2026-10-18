//! Minimal ZIP archive READER - the sibling of zip_writer.zig (the export
//! path; see editor/mission_io.zig's importMissionFromZip + game_zip.zig's
//! importGameFolder for the two import flows). Pure: archive bytes in,
//! entries out, no IO - directly round-trip-testable against zip_writer.
//! Supports the two methods mission zips carry in practice: STORE (our own
//! exports) and DEFLATE (any OS file manager's "compress" default - inflate
//! via std.compress.flate). Zip64, encryption, and other methods are rejected
//! with descriptive errors (a mission zip never legitimately uses them).
//! Entry names + bytes are uniformly allocated from the passed allocator -
//! free via `freeZipArchive`, or hand the caller's throwaway arena.
//!
//! The read is split in two so an importer can validate EVERYTHING before
//! extracting a single byte: `readZipEntryHeaders` walks the central
//! directory (the authoritative index: every name + size, no data), then
//! `extractZipEntry` decodes one entry at a time - streaming extraction with
//! memory = one entry. `readZipArchive` is both halves joined.

const std = @import("std");
const zip_writer = @import("zip_writer.zig");

/// One archived file, same shape as the writer's entries (name + contents).
pub const ZipEntry = zip_writer.ZipEntry;

/// One central-directory record: the authoritative metadata for an entry
/// (name + sizes + method), with NO data extracted. `name` is BORROWED from
/// the archive bytes - the headers slice owns only its own memory (free the
/// slice, nothing per entry). What an importer validates before extracting:
/// every Zip-Slip name rule + every size cap can be checked over the whole
/// archive from these alone.
pub const ZipEntryHeader = struct {
    name: []const u8,
    method: u16,
    crc32: u32,
    compressed_size: usize,
    uncompressed_size: usize,
    local_header_offset: usize,
};

/// The archive-level read errors (names mirror std.zip's vocabulary where
/// it has one).
pub const ZipError = error{
    /// No end-of-central-directory signature in the archive tail.
    ZipNoEndRecord,
    /// A header or entry points outside the archive bounds.
    ZipTruncated,
    /// An entry uses neither the store nor the deflate method.
    ZipUnsupportedMethod,
    /// An entry's sizes/offset sit at the 32-bit limits (a zip64 archive).
    ZipUnsupportedZip64,
    /// An entry's general-purpose flag bit 0 (encryption) is set.
    ZipEncrypted,
    /// A signature where one was expected didn't match.
    ZipBadSignature,
    /// An entry's contents don't hash to the recorded CRC-32.
    ZipCrcMismatch,
    /// The DEFLATE stream didn't decode (corrupt or truncated data).
    ZipBadDeflate,
    /// The decompressed size didn't match the recorded uncompressed size.
    ZipBadSize,
    /// An entry carries an empty name.
    ZipBadName,
};

pub const ReadError = ZipError || std.mem.Allocator.Error;

/// The furthest back from the archive end the EOCD record can sit: its own
/// 22 bytes plus the maximum 65535-byte archive comment.
const end_record_max_scan: usize = 22 + 65535;

const local_file_header_size = 30;
const central_directory_record_size = 46;
const end_record_size = 22;

/// Read every entry out of a ZIP archive: the central-directory headers plus
/// every entry's data, fully extracted. Walks the central directory (the
/// authoritative index), reads each entry's data via its local header, and
/// inflates DEFLATE entries. STORE entry bytes are duped (uniform ownership
/// with inflated bytes - the caller frees everything via `freeZipArchive`,
/// or passes a throwaway arena). On error the partially built list is freed.
pub fn readZipArchive(
    archive: []const u8,
    allocator: std.mem.Allocator,
) ReadError![]ZipEntry {
    const headers = try readZipEntryHeaders(archive, allocator);
    defer allocator.free(headers);

    var entries: std.ArrayList(ZipEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.bytes);
        }
        entries.deinit(allocator);
    }
    for (headers) |header| {
        const entry = try extractZipEntry(archive, allocator, header);
        errdefer {
            allocator.free(entry.name);
            allocator.free(entry.bytes);
        }
        try entries.append(allocator, entry);
    }

    return entries.toOwnedSlice(allocator);
}

/// Read every central-directory record (the authoritative index) without
/// extracting any data. `readZipArchive` joined with `extractZipEntry` is
/// this plus the data pass; importers that must validate the whole archive
/// before writing a byte (see importGameFolder) use this alone first.
pub fn readZipEntryHeaders(
    archive: []const u8,
    allocator: std.mem.Allocator,
) ReadError![]ZipEntryHeader {
    // Find the end-of-central-directory record: scan backwards from the
    // archive end for its signature (the LAST occurrence wins - junk bytes
    // earlier in a comment-sized tail can't shadow the real record).
    if (archive.len < end_record_size) return ZipError.ZipNoEndRecord;
    const scan_start = archive.len - @min(archive.len, end_record_max_scan);
    var end_record_offset: ?usize = null;
    var offset: usize = archive.len - end_record_size + 1;
    while (offset > scan_start) {
        offset -= 1;
        if (readInt(u32, archive[offset..]) == 0x06054b50) {
            end_record_offset = offset;
            break;
        }
    }
    const end_offset = end_record_offset orelse return ZipError.ZipNoEndRecord;
    const end_record = archive[end_offset .. end_offset + end_record_size];
    const entry_count: usize = readInt(u16, end_record[10..12]);
    if (entry_count == 0xFFFF) return ZipError.ZipUnsupportedZip64;
    const central_directory_size: usize = readInt(u32, end_record[12..16]);
    const central_directory_offset: usize = readInt(u32, end_record[16..20]);
    if (central_directory_offset + central_directory_size > end_offset)
        return ZipError.ZipTruncated;

    var headers: std.ArrayList(ZipEntryHeader) = .empty;
    errdefer headers.deinit(allocator);

    var record_offset = central_directory_offset;
    for (0..entry_count) |_| {
        if (record_offset + central_directory_record_size > archive.len)
            return ZipError.ZipTruncated;
        const record = archive[record_offset .. record_offset + central_directory_record_size];
        if (readInt(u32, record[0..4]) != 0x02014b50) return ZipError.ZipBadSignature;
        const flags: u16 = readInt(u16, record[8..10]);
        if (flags & 0b1 != 0) return ZipError.ZipEncrypted;
        const method: u16 = readInt(u16, record[10..12]);
        const crc32: u32 = readInt(u32, record[16..20]);
        const compressed_size: usize = readInt(u32, record[20..24]);
        const uncompressed_size: usize = readInt(u32, record[24..28]);
        if (compressed_size == 0xFFFF_FFFF or uncompressed_size == 0xFFFF_FFFF)
            return ZipError.ZipUnsupportedZip64;
        const name_length: usize = readInt(u16, record[28..30]);
        const extra_length: usize = readInt(u16, record[30..32]);
        const comment_length: usize = readInt(u16, record[32..34]);
        const local_header_offset: usize = readInt(u32, record[42..46]);
        if (local_header_offset == 0xFFFF_FFFF) return ZipError.ZipUnsupportedZip64;
        if (record_offset + central_directory_record_size + name_length > archive.len)
            return ZipError.ZipTruncated;
        const name = archive[record_offset + central_directory_record_size ..][0..name_length];
        if (name.len == 0) return ZipError.ZipBadName;
        record_offset += central_directory_record_size + name_length + extra_length + comment_length;

        try headers.append(allocator, .{
            .name = name,
            .method = method,
            .crc32 = crc32,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .local_header_offset = local_header_offset,
        });
    }

    return headers.toOwnedSlice(allocator);
}

/// Extract ONE entry's data (its local header's data offset + decode + CRC
/// verify). The returned entry owns its name + bytes (uniform with
/// `readZipArchive` - free both, or use a throwaway arena). Streaming
/// importers call this per header with a per-entry reset arena so memory
/// stays at one entry (see importGameFolder).
pub fn extractZipEntry(
    archive: []const u8,
    allocator: std.mem.Allocator,
    header: ZipEntryHeader,
) ReadError!ZipEntry {
    // The entry's data lives at the LOCAL header's data offset - which
    // carries its own name/extra lengths, so they must be read there,
    // not reused from the central directory record.
    if (header.local_header_offset + local_file_header_size > archive.len)
        return ZipError.ZipTruncated;
    const local = archive[header.local_header_offset .. header.local_header_offset + local_file_header_size];
    if (readInt(u32, local[0..4]) != 0x04034b50) return ZipError.ZipBadSignature;
    const local_name_length: usize = readInt(u16, local[26..28]);
    const local_extra_length: usize = readInt(u16, local[28..30]);
    const data_offset = header.local_header_offset + local_file_header_size +
        local_name_length + local_extra_length;
    if (data_offset + header.compressed_size > archive.len) return ZipError.ZipTruncated;
    const compressed = archive[data_offset .. data_offset + header.compressed_size];

    // Decode first (per-entry errdefers cover the not-yet-owned allocation),
    // verify the CRC regardless of method (flate checks match distances,
    // but a valid stream can still decode to bytes other than what was
    // recorded), then take ownership via the owned-name dupe.
    const bytes: []u8 = switch (header.method) {
        0 => blk: { // store - the bytes are the contents, verbatim.
            if (compressed.len != header.uncompressed_size) return ZipError.ZipBadSize;
            break :blk try allocator.dupe(u8, compressed);
        },
        8 => try inflate(compressed, header.uncompressed_size, allocator),
        else => return ZipError.ZipUnsupportedMethod,
    };
    errdefer allocator.free(bytes);
    if (std.hash.Crc32.hash(bytes) != header.crc32) return ZipError.ZipCrcMismatch;
    if (bytes.len != header.uncompressed_size) return ZipError.ZipBadSize;

    const owned_name = try allocator.dupe(u8, header.name);
    errdefer allocator.free(owned_name);
    return .{ .name = owned_name, .bytes = bytes };
}

/// Free a slice returned by `readZipArchive` (names + bytes + the slice).
/// A zero-length slice is a no-op (the empty-archive case returns an
/// allocated-but-empty slice; nothing to free per entry).
fn freeZipArchive(allocator: std.mem.Allocator, entries: []const ZipEntry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.bytes);
    }
    allocator.free(entries);
}

/// Inflate one raw-DEFLATE stream into a buffer of the expected size. The
/// flate reader surfaces decode failures as ReadFailed (the detail sits on
/// `decompress.err`), mapped here to ZipBadDeflate; a stream that decodes
/// cleanly to the wrong length is ZipBadSize.
fn inflate(
    compressed: []const u8,
    expected_size: usize,
    allocator: std.mem.Allocator,
) ReadError![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var decompress: std.compress.flate.Decompress = .init(&input, .raw, &.{});
    const output = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(output);
    var writer: std.Io.Writer = .fixed(output);
    _ = decompress.reader.streamRemaining(&writer) catch return ZipError.ZipBadDeflate;
    if (writer.end != expected_size) return ZipError.ZipBadSize;
    return output;
}

fn readInt(comptime Int: type, bytes: []const u8) Int {
    return std.mem.readInt(Int, bytes[0..@sizeOf(Int)], .little);
}

/// The set of junk an OS "Compress" zip carries alongside the real content
/// - skipped by both importers (mission + game folder) so an OS-made zip
/// round-trips clean. Directory entries (a trailing '/', zero contents),
/// the macOS resource-fork folder + its artifacts.
pub fn isOsZipJunkEntry(name: []const u8) bool {
    // Directory entries (a trailing '/', zero contents).
    if (std.mem.endsWith(u8, name, "/")) return true;
    // The macOS resource-fork folder + its artifacts.
    if (std.mem.startsWith(u8, name, "__MACOSX/")) return true;
    const basename = std.fs.path.basename(name);
    if (std.mem.startsWith(u8, basename, "._")) return true;
    if (std.mem.eql(u8, basename, ".DS_Store")) return true;
    return false;
}

/// A safe extraction name for an UNTRUSTED archive (the Zip-Slip class):
/// no absolute paths, no `..` traversal, no backslashes (spec names use '/';
/// a backslash is a malformed or hostile name - a literal filename
/// character on some platforms), no NUL bytes, no empty segments.
/// Applied BEFORE the first write by both importers: a hostile or malformed
/// zip fails whole, never half-imported.
pub fn isUnsafeZipEntryName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/') return true;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return true;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return true;
    var iterator = std.mem.splitScalar(u8, name, '/');
    while (iterator.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

// --- tests ---

const testing = std.testing;

test "readZipArchive: STORE round-trip against zip_writer" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const written = [_]ZipEntry{
        .{ .name = "mission.txt", .bytes = "Metadata\nfile_format_version 2\n" },
        .{ .name = "level_1.txt", .bytes = "!=" },
        .{ .name = "boss.png", .bytes = "pretend png bytes" },
    };
    const archive = try zip_writer.writeZipArchive(&written, arena_allocator);

    const read = try readZipArchive(archive, allocator);
    defer freeZipArchive(allocator, read);
    try testing.expectEqual(written.len, read.len);
    for (written, read) |expected, entry| {
        try testing.expectEqualStrings(expected.name, entry.name);
        try testing.expectEqualStrings(expected.bytes, entry.bytes);
    }
}

test "readZipArchive: DEFLATE entry inflates (OS-made zips)" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // A DEFLATE stream using stored blocks (BFINAL=1, BTYPE=00): a 5-byte
    // per-block header + raw bytes. Trivial to emit, valid for the inflater,
    // and enough to exercise the method-8 path end to end.
    const contents = "Metadata\nfile_format_version 2\nname Skeleton Attack\n";
    var deflated: std.ArrayList(u8) = .empty;
    try deflated.append(arena_allocator, 0b1); // BFINAL, BTYPE=stored
    const length: u16 = @intCast(contents.len);
    try deflated.append(arena_allocator, @truncate(length));
    try deflated.append(arena_allocator, @truncate(length >> 8));
    const nlength = ~length;
    try deflated.append(arena_allocator, @truncate(nlength));
    try deflated.append(arena_allocator, @truncate(nlength >> 8));
    try deflated.appendSlice(arena_allocator, contents);

    // A one-entry archive: local header + data, central directory, EOCD.
    // Hand-assembled (zip_writer is STORE-only) via a tiny int-appender.
    const crc = std.hash.Crc32.hash(contents);
    var archive: std.ArrayList(u8) = .empty;
    const appendInt = struct {
        fn append(bytes: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime Int: type, value: Int) !void {
            var buffer: [@sizeOf(Int)]u8 = undefined;
            std.mem.writeInt(Int, &buffer, value, .little);
            try bytes.appendSlice(alloc, &buffer);
        }
    }.append;
    const name = "mission.txt";
    try appendInt(&archive, arena_allocator, u32, 0x04034b50);
    try appendInt(&archive, arena_allocator, u16, 20); // version needed
    try appendInt(&archive, arena_allocator, u16, 0); // flags
    try appendInt(&archive, arena_allocator, u16, 8); // method: deflate
    try appendInt(&archive, arena_allocator, u16, 0); // time
    try appendInt(&archive, arena_allocator, u16, (1 << 5) | 1); // date (1980-01-01)
    try appendInt(&archive, arena_allocator, u32, crc);
    try appendInt(&archive, arena_allocator, u32, @intCast(deflated.items.len));
    try appendInt(&archive, arena_allocator, u32, @intCast(contents.len));
    try appendInt(&archive, arena_allocator, u16, name.len);
    try appendInt(&archive, arena_allocator, u16, 0); // extra length
    try archive.appendSlice(arena_allocator, name);
    try archive.appendSlice(arena_allocator, deflated.items);
    const central_offset: u32 = @intCast(archive.items.len);
    try appendInt(&archive, arena_allocator, u32, 0x02014b50);
    try appendInt(&archive, arena_allocator, u16, 20); // version made by
    try appendInt(&archive, arena_allocator, u16, 20); // version needed
    try appendInt(&archive, arena_allocator, u16, 0); // flags
    try appendInt(&archive, arena_allocator, u16, 8); // method
    try appendInt(&archive, arena_allocator, u16, 0); // time
    try appendInt(&archive, arena_allocator, u16, (1 << 5) | 1); // date
    try appendInt(&archive, arena_allocator, u32, crc);
    try appendInt(&archive, arena_allocator, u32, @intCast(deflated.items.len));
    try appendInt(&archive, arena_allocator, u32, @intCast(contents.len));
    try appendInt(&archive, arena_allocator, u16, name.len);
    try appendInt(&archive, arena_allocator, u16, 0); // extra
    try appendInt(&archive, arena_allocator, u16, 0); // comment
    try appendInt(&archive, arena_allocator, u16, 0); // disk start
    try appendInt(&archive, arena_allocator, u16, 0); // internal attrs
    try appendInt(&archive, arena_allocator, u32, 0); // external attrs
    try appendInt(&archive, arena_allocator, u32, 0); // local header offset
    try archive.appendSlice(arena_allocator, name);
    const central_size: u32 = @intCast(archive.items.len - central_offset);
    try appendInt(&archive, arena_allocator, u32, 0x06054b50);
    try appendInt(&archive, arena_allocator, u16, 0); // this disk
    try appendInt(&archive, arena_allocator, u16, 0); // cd disk
    try appendInt(&archive, arena_allocator, u16, 1); // records this disk
    try appendInt(&archive, arena_allocator, u16, 1); // records total
    try appendInt(&archive, arena_allocator, u32, central_size);
    try appendInt(&archive, arena_allocator, u32, central_offset);
    try appendInt(&archive, arena_allocator, u16, 0); // comment length

    const read = try readZipArchive(archive.items, allocator);
    defer freeZipArchive(allocator, read);
    try testing.expectEqual(@as(usize, 1), read.len);
    try testing.expectEqualStrings(name, read[0].name);
    try testing.expectEqualStrings(contents, read[0].bytes);
}

test "readZipEntryHeaders + extractZipEntry: headers borrow names, one entry at a time" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const written = [_]ZipEntry{
        .{ .name = "mission.txt", .bytes = "Metadata\nfile_format_version 2\n" },
        .{ .name = "sprites/boss.png", .bytes = "pretend png bytes" },
    };
    const archive = try zip_writer.writeZipArchive(&written, arena_allocator);

    const headers = try readZipEntryHeaders(archive, allocator);
    defer allocator.free(headers);
    try testing.expectEqual(written.len, headers.len);
    for (written, headers) |expected, header| {
        try testing.expectEqualStrings(expected.name, header.name);
        try testing.expectEqual(expected.bytes.len, header.uncompressed_size);
    }

    // One entry at a time, each freed before the next: the streaming-import
    // shape (memory = one entry - see importGameFolder).
    for (headers, 0..) |header, index| {
        const entry = try extractZipEntry(archive, allocator, header);
        defer allocator.free(entry.name);
        defer allocator.free(entry.bytes);
        try testing.expectEqualStrings(written[index].name, entry.name);
        try testing.expectEqualStrings(written[index].bytes, entry.bytes);
    }

    // The junk + name-safety policy, at the edge cases that matter.
    try testing.expect(isOsZipJunkEntry("saves/"));
    try testing.expect(isOsZipJunkEntry("__MACOSX/evil"));
    try testing.expect(isOsZipJunkEntry("missions/mine/._boss.png"));
    try testing.expect(isOsZipJunkEntry("missions/mine/.DS_Store"));
    try testing.expect(!isOsZipJunkEntry("saves/autosave.txt"));
    try testing.expect(isUnsafeZipEntryName("/absolute.txt"));
    try testing.expect(isUnsafeZipEntryName("../evil.txt"));
    try testing.expect(isUnsafeZipEntryName("saves/../evil.txt"));
    try testing.expect(isUnsafeZipEntryName("saves\\evil.txt"));
    try testing.expect(isUnsafeZipEntryName("saves/evil\x00.txt"));
    try testing.expect(isUnsafeZipEntryName("saves//evil.txt"));
    try testing.expect(isUnsafeZipEntryName(""));
    try testing.expect(!isUnsafeZipEntryName("saves/autosave.txt"));
    try testing.expect(!isUnsafeZipEntryName("missions/mine/sprites/art.png"));
}

test "readZipArchive: rejects a missing end record, an unsupported method, and a CRC mismatch" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const entries = [_]ZipEntry{
        .{ .name = "mission.txt", .bytes = "Metadata\nfile_format_version 2\n" },
    };
    const archive = try zip_writer.writeZipArchive(&entries, arena_allocator);

    // Cut the EOCD off entirely → no end record anywhere.
    const truncated = archive[0 .. archive.len - end_record_size];
    try testing.expectError(ZipError.ZipNoEndRecord, readZipArchive(truncated, allocator));

    // Corrupt the STORED ENTRY DATA (the local header is 30 + name 11 = 41
    // bytes; the payload sits at 41..) - the CRC no longer matches what the
    // central directory recorded.
    const corrupt = try arena_allocator.dupe(u8, archive);
    corrupt[46] ^= 0xFF;
    try testing.expectError(ZipError.ZipCrcMismatch, readZipArchive(corrupt, allocator));

    // Unsupported method (bzip2 = 12) in the central directory record: the
    // method field sits at cd_offset + 10. The decode switch rejects it
    // before any payload is read.
    const patched = try arena_allocator.dupe(u8, archive);
    const end_record = patched[patched.len - end_record_size ..];
    const central_directory_offset: usize = readInt(u32, end_record[16..20]);
    std.mem.writeInt(u16, patched[central_directory_offset + 10 ..][0..2], 12, .little);
    try testing.expectError(ZipError.ZipUnsupportedMethod, readZipArchive(patched, allocator));
}
