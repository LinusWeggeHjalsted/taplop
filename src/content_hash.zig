//! Content identity for missions: a SHA-256 over the mission's raw file
//! bytes, canonicalized so identical content hashes identically regardless
//! of file read order.
//!
//! See DESIGN → Custom Missions & Online Services → Content identity.
//! The hash is a DERIVED property (computed on demand from the file set),
//! not a stored field on Mission. It is load-bearing for replay pinning:
//! the session-log bundle's manifest carries a per-file SHA-256 (the
//! integrity + dedup key of its embedded content copies - see
//! session_log_bundle.zig), and this mission-level content hash gates the
//! validation replay's staleness (a mission edited since its replay was
//! recorded shows "unvalidated").
//!
//! Scope: the mission's ARTIFACT set minus the game-written records (the
//! challenge identity - see DESIGN → Custom Missions & Online Services →
//! Content identity for the artifact-scope rule + the two-axis doctrine):
//! mission.txt + player.txt if present + level_1..level_{count}.txt + every
//! PNG in the mission folder. Stray non-bundled files (author notes) and
//! validation_replay.txt are outside the artifact's content tier and are
//! never hashed. The whole-artifact version hash (records included) is the
//! server seam's axis and lands there.

const std = @import("std");
const file_source_mod = @import("file_source.zig");
const transient_allocator = @import("transient_allocator.zig");

const FileSource = file_source_mod.FileSource;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// A SHA-256 digest (32 bytes).
pub const ContentHash = [32]u8;

/// Compute the content hash of a mission. `mission_path` is the
/// content-root-relative folder path (e.g. "campaigns/main_campaign/
/// missions/beginnings" or "missions/<dir>" for a persistent-dir custom
/// mission). The level
/// count is DERIVED here (the same rule as everywhere: the largest N with
/// `{mission_path}/level_{1..N}.txt` all present, probed consecutively from
/// 1 - a gap truncates); mission.txt no longer declares it. This is a
/// side-effect context (not the reconstruction cache), so the probe reads
/// file_source directly.
///
/// The file set also includes every direct PNG in the mission folder (the
/// artifact's custom-sprite tier, both read tiers via `listDirFiles`) - an
/// art edit changes the hash exactly like a config edit, so the staleness
/// gate catches art-only edits too. Non-PNG files in the folder are outside
/// the artifact's content tier and contribute nothing.
///
/// Canonicalization: the file set is sorted lexicographically by path. Each
/// file is fed into the hash as a path-prefixed entry - `<path>\n` then the
/// raw bytes - so two files with identical content but different paths
/// contribute differently. No line-ending normalization (our files are
/// authored consistently); tighten only if cross-platform drift shows up.
///
/// `player.txt` is OPTIONAL - official missions ship one, but its absence is
/// a normal state (editor playtest loads it lazily). A missing optional file
/// is simply skipped (contributes nothing to the hash). A missing REQUIRED
/// file (mission.txt, level_1.txt) is an error - the mission is broken, fail
/// fast - a mission dir with no level_1.txt is the broken case.
pub fn computeMissionHash(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    mission_path: []const u8,
) !ContentHash {
    // Collect the file set as owned path strings.
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    // mission.txt - required.
    try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/mission.txt", .{mission_path}));

    // player.txt - optional (skip if absent).
    const player_path = try std.fmt.allocPrint(allocator, "{s}/player.txt", .{mission_path});
    if (fileExists(file_source, player_path)) {
        try paths.append(allocator, player_path);
    } else {
        allocator.free(player_path);
    }

    // level_1..level_N.txt - required, N derived by probing consecutive
    // level files until one is absent (level_1 missing = error below: the
    // required-file check fires on the empty level set's first entry).
    var level_index: u32 = 1;
    while (true) : (level_index += 1) {
        const level_path = try std.fmt.allocPrint(
            allocator,
            "{s}/level_{d}.txt",
            .{ mission_path, level_index },
        );
        if (!fileExists(file_source, level_path)) {
            allocator.free(level_path);
            break;
        }
        try paths.append(allocator, level_path);
    }
    // A mission with no level_1.txt is broken (the required-file
    // contract): fail fast rather than hashing a levelless mission.
    if (level_index == 1) return error.MissingRequiredMissionLevel;

    // The artifact's custom-sprite tier: every direct PNG in the mission
    // folder, both read tiers (persistent + embedded - `listDirFiles`
    // unions exactly the tiers readFile resolves between). Non-PNG files
    // (author notes, the validation replay) are outside the artifact's
    // content tier and contribute nothing.
    const dir_names = try file_source.listDirFiles(allocator, mission_path);
    defer file_source_mod.freeDirFiles(allocator, dir_names);
    for (dir_names) |file_name| {
        if (!std.mem.endsWith(u8, file_name, ".png")) continue;
        try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mission_path, file_name }));
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
    // Read with a tiny limit into a throwaway buffer - a FileNotFound miss
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
    file_source.writeFile("test_mission/mission.txt", "Metadata\nfile_format_version 1\nlevel_count 1\nname Test\n") catch @panic("write mission");
    file_source.writeFile("test_mission/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n.\n!\n") catch @panic("write level");

    const h1 = try computeMissionHash(&file_source, arena, "test_mission");
    const h2 = try computeMissionHash(&file_source, arena, "test_mission");
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

    const h1 = try computeMissionHash(&file_source, arena, "m");

    // Mutate level_1.txt content.
    file_source.writeFile("m/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n.!\n") catch @panic("w3");

    const h2 = try computeMissionHash(&file_source, arena, "m");
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

    // No level_1.txt in the dir (the derived count is zero).
    file_source.writeFile("m/mission.txt", "Metadata\nfile_format_version 1\n") catch @panic("w");

    try testing.expectError(
        error.MissingRequiredMissionLevel,
        computeMissionHash(&file_source, arena, "m"),
    );
}

test "computeMissionHash: art is content - PNG changes re-hash" {
    const allocator = testing.allocator;
    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-content-hash-art";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    file_source.writeFile("m/mission.txt", "Metadata\nfile_format_version 1\nlevel_count 1\n") catch @panic("w1");
    file_source.writeFile("m/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w2");

    const h1 = try computeMissionHash(&file_source, arena, "m");

    // A new PNG joins the artifact's sprite tier: the hash moves.
    file_source.writeFile("m/sprite.png", "fake png one") catch @panic("w3");
    const h2 = try computeMissionHash(&file_source, arena, "m");
    try testing.expect(!std.mem.eql(u8, &h1, &h2));

    // An art byte change alone (no config touched) re-hashes - the
    // art-only-edit gap this extension exists to close.
    file_source.writeFile("m/sprite.png", "fake png two") catch @panic("w4");
    const h3 = try computeMissionHash(&file_source, arena, "m");
    try testing.expect(!std.mem.eql(u8, &h2, &h3));
}

test "computeMissionHash: the artifact scope - stray files + the validation replay are not hashed" {
    const allocator = testing.allocator;
    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-content-hash-scope";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    file_source.writeFile("m/mission.txt", "Metadata\nfile_format_version 1\nlevel_count 1\n") catch @panic("w1");
    file_source.writeFile("m/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w2");

    const h1 = try computeMissionHash(&file_source, arena, "m");

    // Stray non-bundled files + the game-written record are outside the
    // artifact's content tier (DESIGN → Content identity): neither moves
    // the hash.
    file_source.writeFile("m/notes.txt", "author notes") catch @panic("w3");
    file_source.writeFile("m/validation_replay.txt", "Metadata\ncontent_hash deadbeef\n") catch @panic("w4");
    const h2 = try computeMissionHash(&file_source, arena, "m");
    try testing.expect(std.mem.eql(u8, &h1, &h2));
}

test "hashToHex: encodes 32 bytes as 64 lowercase hex chars" {
    const hash: ContentHash = blk: {
        const pattern = [4]u8{ 0x00, 0x01, 0x02, 0x03 };
        var bytes: ContentHash = undefined;
        for (&bytes, 0..) |*byte, index| byte.* = pattern[index % pattern.len];
        break :blk bytes;
    };
    const hex = hashToHex(hash);
    try testing.expectEqual(@as(usize, 64), hex.len);
    try testing.expectEqualStrings("00010203", hex[0..8]);
    // last nibble of the repeating pattern
    try testing.expectEqual(@as(u8, '3'), hex[63]);
}
