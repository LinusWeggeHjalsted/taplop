//! Content identity for missions: a SHA-256 over the mission's raw file
//! bytes, canonicalized so identical content hashes identically regardless
//! of file read order.
//!
//! See DESIGN → Custom Missions & Online Services → Content identity.
//! The hash is a DERIVED property (computed on demand from the file set),
//! not a stored field on Mission. It is load-bearing for replay pinning:
//! the session-log bundle's manifest carries a per-file SHA-256 (the
//! integrity + dedup key of its embedded content copies — see
//! session_log_bundle.zig), and this mission-level content hash gates the
//! validation replay's staleness (a mission edited since its replay was
//! recorded shows "unvalidated").
//!
//! v1 scope: hashes CONFIG files only (mission.txt + player.txt if present +
//! level_1..level_{count}.txt). Custom assets (sprites/audio under the
//! mission folder) are not hashed — FileSource has no directory-listing API.
//! The canonicalization scheme (path-sorted, path-prefixed entries) is stable
//! and already handles an arbitrary file set, so extending to custom assets is
//! additive.

const std = @import("std");
const file_source_mod = @import("file_source.zig");
const transient_allocator = @import("transient_allocator.zig");

const FileSource = file_source_mod.FileSource;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// A SHA-256 digest (32 bytes).
pub const ContentHash = [32]u8;

/// Compute the content hash of a mission. `mission_path` is the project-root-
/// relative folder path (e.g. "data/campaigns/main_campaign/missions/
/// beginnings" or a VFS/persistent-dir custom-mission path). `level_count`
/// is the mission's declared level count (from mission.txt); levels are read
/// as `{mission_path}/level_{1..level_count}.txt`.
///
/// Canonicalization: the file set is sorted lexicographically by path. Each
/// file is fed into the hash as a path-prefixed entry — `<path>\n` then the
/// raw bytes — so two files with identical content but different paths
/// contribute differently. No line-ending normalization (our files are
/// authored consistently); tighten only if cross-platform drift shows up.
///
/// `player.txt` is OPTIONAL — official missions ship one, but its absence is
/// a normal state (editor playtest loads it lazily). A missing optional file
/// is simply skipped (contributes nothing to the hash). A missing REQUIRED
/// file (mission.txt, any level_N.txt within the declared count) is an error
/// — the mission is broken, fail fast.
pub fn computeMissionHash(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    mission_path: []const u8,
    level_count: u32,
) !ContentHash {
    // Collect the file set as owned path strings.
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    // mission.txt — required.
    try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/mission.txt", .{mission_path}));

    // player.txt — optional (skip if absent).
    const player_path = try std.fmt.allocPrint(allocator, "{s}/player.txt", .{mission_path});
    if (fileExists(file_source, player_path)) {
        try paths.append(allocator, player_path);
    } else {
        allocator.free(player_path);
    }

    // level_1..level_{count}.txt — required (count comes from mission.txt).
    var level_index: u32 = 1;
    while (level_index <= level_count) : (level_index += 1) {
        try paths.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}/level_{d}.txt",
            .{ mission_path, level_index },
        ));
    }

    // Sort lexicographically by path for a canonical, order-independent hash.
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var hasher = Sha256.init(.{});
    for (paths.items) |path| {
        // Path prefix: the path itself, then a newline separator. This
        // ensures files with identical content but different paths hash
        // differently, and the separator avoids path/bytes ambiguity.
        hasher.update(path);
        hasher.update("\n");

        const bytes = try file_source.readFile(allocator, path);
        defer allocator.free(bytes);
        hasher.update(bytes);
    }

    var digest: ContentHash = undefined;
    hasher.final(&digest);
    return digest;
}

/// Check whether a file exists in the file source (without allocating the
/// full read). Used for the optional player.txt probe.
fn fileExists(file_source: *const FileSource, path: []const u8) bool {
    // Read with a tiny limit into a throwaway buffer — a FileNotFound miss
    // returns false; any hit (even truncated) returns true. We don't need
    // the bytes, only existence. readFile dupes embedded bytes, so to avoid
    // leaking even a small allocation we free immediately on the hit path.
    const allocator = transient_allocator.allocator;
    if (file_source.readFile(allocator, path)) |bytes| {
        allocator.free(bytes);
        return true;
    } else |_| {
        return false;
    }
}

/// Encode a content hash as lowercase hex into a 64-byte array.
pub fn hashToHex(hash: ContentHash) [64]u8 {
    var hex: [64]u8 = undefined;
    const charset = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        hex[i * 2] = charset[byte >> 4];
        hex[i * 2 + 1] = charset[byte & 0x0f];
    }
    return hex;
}

// --- tests ---

/// In-memory file source for hashing tests: serves bytes from a static
/// string map (path -> bytes), no IO. Mirrors FileSource.readFile's
/// allocator-owned-bytes contract by duping into the caller's allocator.
const TestSource = struct {
    files: std.StaticStringMap([]const u8),

    fn readFile(self: *const TestSource, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (self.files.get(path)) |bytes| {
            return try allocator.dupe(u8, bytes);
        }
        return error.FileNotFound;
    }
};

// Adapt TestSource.readFile to the FileSource shape expected by
// computeMissionHash. We pass a *const FileSource; for tests we build a
// real FileSource pointing at a scratch dir and write the test files there.
// That keeps the test exercising the REAL read path (persistent dir layer)
// rather than a parallel implementation.

const testing = std.testing;

test "computeMissionHash: deterministic for the same file set" {
    const allocator = testing.allocator;
    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-content-hash-determinism";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Write a minimal mission: mission.txt + level_1.txt (no player.txt).
    file_source.writeFile("test_mission/mission.txt",
        "Metadata\nfile_format_version 1\nlevel_count 1\nname Test\n") catch @panic("write mission");
    file_source.writeFile("test_mission/level_1.txt",
        "Metadata\nfile_format_version 1\n\nLayout\n.\n!\n") catch @panic("write level");

    const h1 = try computeMissionHash(&file_source, arena, "test_mission", 1);
    const h2 = try computeMissionHash(&file_source, arena, "test_mission", 1);
    try testing.expectEqualSlices(u8, &h1, &h2);
}

test "computeMissionHash: content change changes the hash" {
    const allocator = testing.allocator;
    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-content-hash-mutation";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    file_source.writeFile("m/mission.txt", "Metadata\nfile_format_version 1\nlevel_count 1\n") catch @panic("w1");
    file_source.writeFile("m/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w2");

    const h1 = try computeMissionHash(&file_source, arena, "m", 1);

    // Mutate level_1.txt content.
    file_source.writeFile("m/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n.!\n") catch @panic("w3");

    const h2 = try computeMissionHash(&file_source, arena, "m", 1);
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "computeMissionHash: missing required file errors" {
    const allocator = testing.allocator;
    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-content-hash-missing";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // mission.txt declares level_count 1 but no level_1.txt is written.
    file_source.writeFile("m/mission.txt", "Metadata\nfile_format_version 1\nlevel_count 1\n") catch @panic("w");

    try testing.expectError(
        error.FileNotFound,
        computeMissionHash(&file_source, arena, "m", 1),
    );
}

test "hashToHex: encodes 32 bytes as 64 lowercase hex chars" {
    const hash: ContentHash = .{ 0x00, 0x01, 0x02, 0x03 } ** 8;
    const hex = hashToHex(hash);
    try testing.expectEqual(@as(usize, 64), hex.len);
    try testing.expectEqualStrings("00010203", hex[0..8]);
    // last nibble of the repeating pattern
    try testing.expectEqual(@as(u8, '3'), hex[63]);
}
