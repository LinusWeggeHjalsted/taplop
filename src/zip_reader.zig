//! Minimal ZIP archive READER — the sibling of zip_writer.zig (the export
//! path; see input_handlers.importMissionFromZip for the import flow).
//! Pure: archive bytes in, entries out, no IO — directly round-trip-
//! testable against zip_writer. Supports the two methods mission zips
//! carry in practice: STORE (our own exports) and DEFLATE (any OS file
//! manager's "compress" default — inflate via std.compress.flate). Zip64,
//! encryption, and other methods are rejected with descriptive errors (a
//! mission zip never legitimately uses them). Entry names + bytes are
//! uniformly allocated from the passed allocator — free via
//! `freeZipArchive`, or hand the caller's throwaway arena.

const std = @import("std");
const zip_writer = @import("zip_writer.zig");

/// One archived file, same shape as the writer's entries (name + contents).
pub const ZipEntry = zip_writer.ZipEntry;

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

/// Read every entry out of a ZIP archive. Walks the central directory (the
/// authoritative index), reads each entry's data via its local header, and
/// inflates DEFLATE entries. STORE entry bytes are duped (uniform ownership
/// with inflated bytes — the caller frees everything via `freeZipArchive`,
/// or passes a throwaway arena). On error the partially built list is freed.
pub fn readZipArchive(
    archive: []const u8,
    allocator: std.mem.Allocator,
) ReadError![]ZipEntry {
    // Find the end-of-central-directory record: scan backwards from the
    // archive end for its signature (the LAST occurrence wins — junk bytes
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

    var entries: std.ArrayList(ZipEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.bytes);
        }
        entries.deinit(allocator);
    }

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

        // The entry's data lives at the LOCAL header's data offset — which
        // carries its own name/extra lengths, so they must be read there,
        // not reused from the central directory record.
        if (local_header_offset + local_file_header_size > archive.len)
            return ZipError.ZipTruncated;
        const local = archive[local_header_offset .. local_header_offset + local_file_header_size];
        if (readInt(u32, local[0..4]) != 0x04034b50) return ZipError.ZipBadSignature;
        const local_name_length: usize = readInt(u16, local[26..28]);
        const local_extra_length: usize = readInt(u16, local[28..30]);
        const data_offset = local_header_offset + local_file_header_size +
            local_name_length + local_extra_length;
        if (data_offset + compressed_size > archive.len) return ZipError.ZipTruncated;
        const compressed = archive[data_offset .. data_offset + compressed_size];

        // Decode first (per-entry errdefers cover the not-yet-appended
        // allocation), verify the CRC regardless of method (flate checks
        // match distances, but a valid stream can still decode to bytes
        // other than what was recorded), then take ownership via append.
        const bytes: []u8 = switch (method) {
            0 => blk: { // store — the bytes are the contents, verbatim.
                if (compressed.len != uncompressed_size) return ZipError.ZipBadSize;
                break :blk try allocator.dupe(u8, compressed);
            },
            8 => try inflate(compressed, uncompressed_size, allocator),
            else => return ZipError.ZipUnsupportedMethod,
        };
        errdefer allocator.free(bytes);
        if (std.hash.Crc32.hash(bytes) != crc32) return ZipError.ZipCrcMismatch;
        if (bytes.len != uncompressed_size) return ZipError.ZipBadSize;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try entries.append(allocator, .{ .name = owned_name, .bytes = bytes });
    }

    return entries.toOwnedSlice(allocator);
}

/// Free a slice returned by `readZipArchive` (names + bytes + the slice).
/// A zero-length slice is a no-op (the empty-archive case returns an
/// allocated-but-empty slice; nothing to free per entry).
pub fn freeZipArchive(allocator: std.mem.Allocator, entries: []const ZipEntry) void {
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
    // bytes; the payload sits at 41..) — the CRC no longer matches what the
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
