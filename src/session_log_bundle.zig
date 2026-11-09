//! Session-log BUNDLE - the folder artifact that makes a saved session
//! replayable cross-session: `session_log.txt` (the ordinary session-log
//! body plus a `ReconstructionCache` manifest section) and `content/`
//! (exact raw byte copies of every file the session's reconstruction-read
//! events read). Every cached read is embedded, shipped content included,
//! because mod-shadowing means any path can change between sessions (the
//! autosave is continuously overwritten; custom missions are re-saved by the
//! editor). See DESIGN → Logging & Replay and DESIGN → File System & IO →
//! Reconstruction cache.
//!
//! Writer: FileSource/persistent-dir IO (the game's own artifacts - the
//! ctrl+L dump, the crash dump). Loader: `std.Io.Dir` IO (the `--replay`
//! CLI reads any path; tests read a temp dir). Content files are written
//! FIRST, `session_log.txt` LAST, so a half-written bundle fails to load
//! cleanly instead of replaying against missing bytes.
//!
//! The validation replay deliberately does NOT use bundles: it stays a
//! single file inside the mission dir it validates and replays against the
//! mission's CURRENT files, hash-gated, via `reconstructFromEventLogChecking`
//! (see DESIGN → Custom Missions & Online Services → Validation replay).

const std = @import("std");
const events_mod = @import("events.zig");
const parser = @import("parser.zig");
const session_log = @import("session_log.zig");
const content_hash = @import("content_hash.zig");
const file_source_mod = @import("file_source.zig");
const state = @import("state.zig");

const Event = events_mod.Event;
const FileSource = file_source_mod.FileSource;
const Section = parser.Section;
const ReconstructionCacheEntry = state.ReconstructionCacheEntry;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Read limit for bundle files (`session_log.txt` + content copies) -
/// matches FileSource's own limit, so a bundle can round-trip anything the
/// game could have read in the first place.
const bundle_read_limit: std.Io.Limit = .limited(256 * 1024 * 1024);

/// Aggregate cap on the content copies: a hostile bundle with many
/// distinct-hash copies would otherwise drive unbounded total allocation
/// during load (each copy's read is per-file limited, the running total
/// was not). Checked on each copy's size BEFORE it is read, so a bomb
/// bundle fails without allocating a byte of content. 1 GB is far past
/// any legit bundle (a session's reconstruction reads: KB-scale configs
/// + ~100 KB art) while still covering the game's own 256 MB per-file
/// read limit plus a whole campaign's worth of content.
const bundle_max_total_content_bytes: u64 = 1024 * 1024 * 1024;

/// One manifest entry group in the `ReconstructionCache` section: the file
/// bytes one reconstruction-read event applied, and where the copy lives.
/// The section's entry groups preserve cache order (monotonic
/// `event_index` - the replay-side binary search invariant).
pub const CacheManifestEntry = struct {
    /// Index into the EventLog of the event whose handler read the file.
    event_index: u32,
    /// The path the original session read, verbatim (may contain spaces).
    /// Together with `event_index` this is the replay cache key.
    path: []const u8,
    /// SHA-256 of the content bytes as 64 lowercase hex chars - the
    /// integrity check the loader verifies against every copy.
    hash_hex: []const u8,
    /// Name of the copy under `content/` ("<first 8 hex>_<original file
    /// name>"). The loader trusts this line: a wrong entry points at the
    /// wrong bytes, which the hash check rejects.
    file_name: []const u8,
};

pub const SessionLogBundleError = error{
    /// No `session_log.txt`, or no `ReconstructionCache` section - the
    /// difference between a bundle's log and a bare session log (e.g. the
    /// validation replay).
    NotSessionLogBundle,
    /// A manifest group is malformed (missing field, bad number, non-
    /// monotonic event_index, non-hex hash).
    MalformedManifest,
    /// A referenced content copy is missing or its bytes don't match the
    /// recorded hash.
    ContentMismatch,
    /// The content copies' total size exceeds the aggregate bundle cap
    /// (`bundle_max_total_content_bytes`).
    BundleTooLarge,
    /// Propagated from session_log.loadEventLog.
    MalformedSessionLog,
    UnsupportedFileFormatVersion,
    /// Propagated from parser.parseConfigFile (the per-format header
    /// grammar - a session-log file with a header-shaped line outside
    /// session_log_sections, or any other non-conforming line).
    UnknownSectionHeader,
    UnknownLine,
    EmptyLayout,
    LayoutTruncated,
    OutOfMemory,
} || std.Io.Dir.ReadFileAllocError;

/// The writer-side per-entry artifact identity: the manifest text and the
/// content-file writes agree by construction (one struct carries both).
const CacheEntryArtifact = struct {
    event_index: u32,
    path: []const u8,
    bytes: []const u8,
    hash_hex: [64]u8,
    file_name: []u8,
};

/// Compute a file's SHA-256 as 64 lowercase hex chars.
fn hashBytesToHex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return content_hash.hashToHex(digest);
}

/// The final '/'-separated segment of a VFS path. VFS paths always use '/',
/// never the platform separator, so this is not std.fs.path.basename.
fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| return path[index + 1 ..];
    return path;
}

/// Write a session-log bundle to `<bundle_dir>/` in the persistent dir:
/// the content copies first (deduped by hash - identical bytes, e.g. a
/// level file read on every re-entry, are stored once), then
/// `session_log.txt` (the ordinary session-log body with the manifest
/// section appended after EventLog). `created` is the "YYYYMMDD_HHMMSS"
/// stamp. All scratch memory is `allocator`'s; the writes go through
/// `file_source` (parent dirs created as needed).
pub fn writeSessionLogBundle(
    file_source: *const FileSource,
    event_history: []const Event,
    cache_entries: []const ReconstructionCacheEntry,
    bundle_dir: []const u8,
    created: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const artifacts = try planCacheEntryArtifacts(cache_entries, allocator);
    defer {
        for (artifacts) |artifact| allocator.free(artifact.file_name);
        allocator.free(artifacts);
    }

    // Content copies, deduped by hash. Distinct bytes of the SAME path (the
    // autosave written mid-session, then re-loaded) hash differently →
    // distinct files; identical bytes read at many event indices → one.
    var written_hashes: std.ArrayList([64]u8) = .empty;
    defer written_hashes.deinit(allocator);
    for (artifacts) |artifact| {
        if (containsHash(written_hashes.items, artifact.hash_hex)) continue;
        const content_path = try std.fmt.allocPrint(
            allocator,
            "{s}/content/{s}",
            .{ bundle_dir, artifact.file_name },
        );
        defer allocator.free(content_path);
        try file_source.writeFile(content_path, artifact.bytes);
        try written_hashes.append(allocator, artifact.hash_hex);
    }

    const body = try session_log.writeEventLog(event_history, created, allocator);
    defer allocator.free(body);
    const manifest = try writeCacheManifestSection(artifacts, allocator);
    defer allocator.free(manifest);
    const log_bytes = try std.mem.concat(allocator, u8, &.{ body, manifest });
    defer allocator.free(log_bytes);

    const log_path = try std.fmt.allocPrint(allocator, "{s}/session_log.txt", .{bundle_dir});
    defer allocator.free(log_path);
    try file_source.writeFile(log_path, log_bytes);
}

/// Derive the per-entry artifact identities: hash the bytes, name the copy
/// "<first 8 hex>_<original file name>". Order follows `cache_entries`
/// (cache order - monotonic by event_index).
fn planCacheEntryArtifacts(
    cache_entries: []const ReconstructionCacheEntry,
    allocator: std.mem.Allocator,
) ![]CacheEntryArtifact {
    var artifacts: std.ArrayList(CacheEntryArtifact) = .empty;
    errdefer {
        for (artifacts.items) |artifact| allocator.free(artifact.file_name);
        artifacts.deinit(allocator);
    }
    for (cache_entries) |entry| {
        const hash_hex = hashBytesToHex(entry.bytes);
        const file_name = try std.fmt.allocPrint(
            allocator,
            "{s}_{s}",
            .{ hash_hex[0..8], baseName(entry.path) },
        );
        try artifacts.append(allocator, .{
            .event_index = entry.event_index,
            .path = entry.path,
            .bytes = entry.bytes,
            .hash_hex = hash_hex,
            .file_name = file_name,
        });
    }
    return try artifacts.toOwnedSlice(allocator);
}

fn containsHash(written: []const [64]u8, hash_hex: [64]u8) bool {
    for (written) |candidate| {
        if (std.mem.eql(u8, &candidate, &hash_hex)) return true;
    }
    return false;
}

/// The manifest section text: "\nReconstructionCache\n" then one blank-line
/// separated entry group per cached read, mirroring the EventLog group
/// conventions (so the shared parser reads both the same way).
fn writeCacheManifestSection(
    artifacts: []const CacheEntryArtifact,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "\nReconstructionCache\n");
    for (artifacts) |artifact| {
        try buffer.appendSlice(allocator, "\n");
        try buffer.print(allocator, "event_index {d}\n", .{artifact.event_index});
        try buffer.print(allocator, "path {s}\n", .{artifact.path});
        try buffer.print(allocator, "hash {s}\n", .{&artifact.hash_hex});
        try buffer.print(allocator, "file {s}\n", .{artifact.file_name});
    }
    return try buffer.toOwnedSlice(allocator);
}

/// A successfully loaded bundle: the parsed session log plus cache entries
/// ready to append into `GameStateHistory.reconstruction_cache` via
/// `loadReconstructionCache`. All returned memory (log events, manifest
/// strings, content bytes) is owned by the caller's allocator - pass the
/// history arena in production, so the embedded bytes survive as long as
/// the replayed session does.
pub const LoadedSessionLogBundle = struct {
    log: session_log.SessionLog,
    cache_entries: []const ReconstructionCacheEntry,
};

/// Load a session-log bundle from `<bundle_path>/session_log.txt` +
/// `content/`, verifying every content copy against its recorded hash.
/// The manifest section is REQUIRED (a bare session log is not a bundle).
/// A missing or corrupt content copy is `error.ContentMismatch` - never a
/// silent fallback to some other file on disk.
pub fn loadSessionLogBundle(
    dir: std.Io.Dir,
    bundle_path: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
) SessionLogBundleError!LoadedSessionLogBundle {
    const log_bytes = try readBundleFile(dir, io, bundle_path, "session_log.txt", allocator);
    const sections = try parser.parseConfigFile(log_bytes, allocator, &parser.session_log_sections);
    const log = try session_log.loadEventLog(sections, allocator);
    const manifest = try loadCacheManifest(sections, allocator);

    // Read each distinct content copy once (dedup by hash - many manifest
    // entries can share bytes) and verify it against the recorded hash.
    const ContentBytes = struct { hash_hex: []const u8, bytes: []const u8 };
    var copies: std.ArrayList(ContentBytes) = .empty;
    defer copies.deinit(allocator);
    var total_content_bytes: u64 = 0;
    var cache_entries: std.ArrayList(ReconstructionCacheEntry) = .empty;
    errdefer cache_entries.deinit(allocator);
    for (manifest) |entry| {
        var copy: ?ContentBytes = null;
        for (copies.items) |candidate| {
            if (std.mem.eql(u8, candidate.hash_hex, entry.hash_hex)) {
                copy = candidate;
                break;
            }
        }
        if (copy == null) {
            // The content copies live under `content/` (the manifest's
            // `file` names are relative to it).
            const content_sub_path = std.fmt.allocPrint(allocator, "content/{s}", .{entry.file_name}) catch
                return error.OutOfMemory;
            defer allocator.free(content_sub_path);
            // The aggregate cap fires on the copy's size BEFORE the read
            // (see bundle_max_total_content_bytes).
            const full_content_path = std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ bundle_path, content_sub_path },
            ) catch return error.OutOfMemory;
            defer allocator.free(full_content_path);
            if (dir.statFile(io, full_content_path, .{})) |stat| {
                total_content_bytes += stat.size;
                if (total_content_bytes > bundle_max_total_content_bytes) return error.BundleTooLarge;
            } else |_| {} // unstatable: the read below surfaces the proper error
            const bytes = readBundleFile(dir, io, bundle_path, content_sub_path, allocator) catch
                return error.ContentMismatch;
            if (!std.mem.eql(u8, &hashBytesToHex(bytes), entry.hash_hex)) {
                allocator.free(bytes);
                return error.ContentMismatch;
            }
            copy = .{ .hash_hex = entry.hash_hex, .bytes = bytes };
            try copies.append(allocator, copy.?);
        }
        // The path points into the manifest entry's owned string (both
        // allocated by the caller's allocator); the bytes are shared
        // between entries of the same hash - replay serves copies either
        // way, they are only ever read.
        try cache_entries.append(allocator, .{
            .event_index = entry.event_index,
            .path = entry.path,
            .bytes = copy.?.bytes,
        });
    }

    return .{
        .log = log,
        .cache_entries = try cache_entries.toOwnedSlice(allocator),
    };
}

/// Read `<bundle_path>/<file_name>` via the bundle's dir handle.
fn readBundleFile(
    dir: std.Io.Dir,
    io: std.Io,
    bundle_path: []const u8,
    file_name: []const u8,
    allocator: std.mem.Allocator,
) std.Io.Dir.ReadFileAllocError![]u8 {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ bundle_path, file_name }) catch
        return error.OutOfMemory;
    defer allocator.free(path);
    return dir.readFileAlloc(io, path, allocator, bundle_read_limit);
}

/// Parse the `ReconstructionCache` manifest from a bundle's sections. The
/// section is REQUIRED - its absence is what distinguishes a bundle's
/// session_log.txt from a bare session log (the validation replay). All
/// strings are duped into `allocator` (the manifest's parsed slices point
/// into the caller's scratch log bytes and must outlive them).
fn loadCacheManifest(
    sections: []const Section,
    allocator: std.mem.Allocator,
) SessionLogBundleError![]CacheManifestEntry {
    const section = parser.findSection(sections, "ReconstructionCache") orelse
        return error.NotSessionLogBundle;
    var entries: std.ArrayList(CacheManifestEntry) = .empty;
    errdefer entries.deinit(allocator);
    var last_event_index: ?u32 = null;
    for (section.entry_groups) |group| {
        const pairs = group.pairs;
        const event_index = parseManifestU32(pairs, "event_index") orelse
            return error.MalformedManifest;
        // Cache order is monotonic by event_index (the replay-side binary
        // search invariant) - a hand-merged manifest would break it.
        if (last_event_index) |last| {
            if (event_index < last) return error.MalformedManifest;
        }
        last_event_index = event_index;
        const path = parser.findValue(pairs, "path") orelse return error.MalformedManifest;
        const hash_hex = parser.findValue(pairs, "hash") orelse return error.MalformedManifest;
        const file_name = parser.findValue(pairs, "file") orelse return error.MalformedManifest;
        if (hash_hex.len != 64) return error.MalformedManifest;
        try entries.append(allocator, .{
            .event_index = event_index,
            .path = try allocator.dupe(u8, path),
            .hash_hex = try allocator.dupe(u8, hash_hex),
            .file_name = try allocator.dupe(u8, file_name),
        });
    }
    return try entries.toOwnedSlice(allocator);
}

fn parseManifestU32(pairs: []const parser.KeyValuePair, key: []const u8) ?u32 {
    const value = parser.findValue(pairs, key) orelse return null;
    return std.fmt.parseInt(u32, value, 10) catch null;
}

// ============================================================
// Tests
// ============================================================

test "content file name: hash prefix + original file name" {
    const bytes = "some config bytes";
    const hash_hex = hashBytesToHex(bytes);
    const entries = [_]ReconstructionCacheEntry{
        .{ .event_index = 0, .path = "missions/My Mission/mission.txt", .bytes = bytes },
    };
    const allocator = std.testing.allocator;
    const artifacts = try planCacheEntryArtifacts(&entries, allocator);
    defer {
        for (artifacts) |artifact| allocator.free(artifact.file_name);
        allocator.free(artifacts);
    }
    // <first 8 hex>_<basename of the path> (hash of these exact bytes).
    const expected_name = try std.fmt.allocPrint(allocator, "{s}_mission.txt", .{hash_hex[0..8]});
    defer allocator.free(expected_name);
    try std.testing.expectEqualStrings(expected_name, artifacts[0].file_name);
}

test "bundle write + load round-trips, and the embedded bytes survive source changes" {
    const allocator = std.testing.allocator;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir under zig-cache: FileSource writes the bundle
    // there; the loader reads it back from the same dir handle.
    const scratch_path = "zig-cache/test-session-log-bundle";
    const persistent_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch_path) catch {};
    const file_source = FileSource.init(io, persistent_dir);

    // The motivating scenario: the autosave read at the start of a session,
    // then overwritten by a LATER session before the log is replayed. Two
    // versions of the same path at different event indices (the mid-session
    // write_save + re-load shape), plus a path with spaces.
    const entries = [_]ReconstructionCacheEntry{
        .{ .event_index = 0, .path = "saves/autosave.txt", .bytes = "version1" },
        .{ .event_index = 3, .path = "missions/My Mission/mission.txt", .bytes = "mission bytes" },
        .{ .event_index = 7, .path = "saves/autosave.txt", .bytes = "version2" },
        // The known-absent marker (readReconstructionFileOptional's
        // FileNotFound cache entry - the level-count probe's terminator):
        // empty bytes, and it must round-trip like any other entry so
        // bundle replay re-derives the same absence.
        .{ .event_index = 9, .path = "missions/My Mission/level_3.txt", .bytes = "" },
    };
    const event_history = [_]Event{.{ .meta_event = .open_main_menu }};

    try writeSessionLogBundle(
        &file_source,
        &event_history,
        &entries,
        "logs/test_bundle",
        "20260815_143022",
        allocator,
    );

    // The source file changes after the bundle was written (a later
    // session's autosave overwrite). The bundle must still carry the
    // ORIGINAL bytes.
    try file_source.writeFile("saves/autosave.txt", "version3");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const loaded = try loadSessionLogBundle(persistent_dir, "logs/test_bundle", io, arena.allocator());

    try std.testing.expectEqual(@as(usize, 1), loaded.log.events.len);
    try std.testing.expectEqual(@as(usize, 4), loaded.cache_entries.len);
    // Manifest order preserved, bytes are the version the SESSION saw.
    try std.testing.expectEqualStrings("version1", loaded.cache_entries[0].bytes);
    try std.testing.expectEqualStrings("mission bytes", loaded.cache_entries[1].bytes);
    try std.testing.expectEqualStrings("version2", loaded.cache_entries[2].bytes);
    // Two versions of the same path → two distinct content files.
    try std.testing.expect(!std.mem.eql(u8, loaded.cache_entries[0].bytes, loaded.cache_entries[2].bytes));

    // The manifest's paths round-trip verbatim, spaces included.
    try std.testing.expectEqualStrings("missions/My Mission/mission.txt", loaded.cache_entries[1].path);
    // The absent marker survives as an empty-bytes entry.
    try std.testing.expectEqual(@as(usize, 0), loaded.cache_entries[3].bytes.len);
    try std.testing.expectEqualStrings("missions/My Mission/level_3.txt", loaded.cache_entries[3].path);
}

test "bundle with zero cache entries round-trips (a menu-only session)" {
    const allocator = std.testing.allocator;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch_path = "zig-cache/test-session-log-bundle-empty";
    const persistent_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch_path) catch {};
    const file_source = FileSource.init(io, persistent_dir);

    const event_history = [_]Event{.{ .meta_event = .open_main_menu }};
    try writeSessionLogBundle(
        &file_source,
        &event_history,
        &.{},
        "logs/test_bundle",
        "20260815_143022",
        allocator,
    );

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const loaded = try loadSessionLogBundle(persistent_dir, "logs/test_bundle", io, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), loaded.cache_entries.len);
}

test "tampered content copy rejects with ContentMismatch" {
    const allocator = std.testing.allocator;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch_path = "zig-cache/test-session-log-bundle-tamper";
    const persistent_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch_path) catch {};
    const file_source = FileSource.init(io, persistent_dir);

    const entries = [_]ReconstructionCacheEntry{
        .{ .event_index = 0, .path = "saves/autosave.txt", .bytes = "version1" },
    };
    try writeSessionLogBundle(
        &file_source,
        &.{.{ .meta_event = .open_main_menu }},
        &entries,
        "logs/test_bundle",
        "20260815_143022",
        allocator,
    );

    // Corrupt the content copy under the bundle (a truncated or hand-edited
    // bundle): the recorded hash must catch it.
    const copy_path = try std.fmt.allocPrint(
        allocator,
        "logs/test_bundle/content/{s}_autosave.txt",
        .{hashBytesToHex("version1")[0..8]},
    );
    defer allocator.free(copy_path);
    try file_source.writeFile(copy_path, "tampered");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.ContentMismatch,
        loadSessionLogBundle(persistent_dir, "logs/test_bundle", io, arena.allocator()),
    );
}

test "a bare session log (no ReconstructionCache section) is not a bundle" {
    const allocator = std.testing.allocator;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch_path = "zig-cache/test-session-log-bundle-bare";
    const persistent_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch_path) catch {};
    const file_source = FileSource.init(io, persistent_dir);

    // A bare v2 log (the validation replay's shape): loadEventLog-legal,
    // but not a bundle.
    const body = try session_log.writeEventLog(
        &.{.{ .meta_event = .open_main_menu }},
        "20260815_143022",
        allocator,
    );
    defer allocator.free(body);
    try file_source.writeFile("logs/bare/session_log.txt", body);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.NotSessionLogBundle,
        loadSessionLogBundle(persistent_dir, "logs/bare", io, arena.allocator()),
    );
}

test "non-monotonic manifest event_index rejects with MalformedManifest" {
    const allocator = std.testing.allocator;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch_path = "zig-cache/test-session-log-bundle-order";
    const persistent_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch_path) catch {};

    try persistent_dir.createDirPath(io, "logs/merged");
    // A hand-merged manifest with event_index out of order: the parser
    // must reject it before the replay's binary search is lied to.
    const bytes = try std.fmt.allocPrint(allocator,
        \\Metadata
        \\file_format_version 3
        \\game_version test
        \\created 20260815_143022
        \\
        \\EventLog
        \\
        \\event_index 0
        \\event meta_event open_main_menu
        \\
        \\ReconstructionCache
        \\
        \\event_index 5
        \\path saves/autosave.txt
        \\hash {s}
        \\file whatever.txt
        \\
        \\event_index 2
        \\path saves/autosave.txt
        \\hash {s}
        \\file whatever.txt
        \\
    , .{ hashBytesToHex("version1"), hashBytesToHex("version1") });
    defer allocator.free(bytes);
    try persistent_dir.writeFile(io, .{ .sub_path = "logs/merged/session_log.txt", .data = bytes });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.MalformedManifest,
        loadSessionLogBundle(persistent_dir, "logs/merged", io, arena.allocator()),
    );
}

test "bundle content aggregate cap: a bomb bundle fails before any copy is read" {
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch_path = "zig-cache/test-session-log-bundle-bomb";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch_path, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch_path) catch {};

    // A loadable log body plus a one-entry manifest (dummy hex hash -
    // never verified: the cap fires on the stat size before any read).
    // The copy is a SPARSE 1.1 GB file (setLength - no bytes on disk, no
    // allocation): its size alone crosses the 1 GB aggregate cap, so the
    // load must fail WITHOUT reading a byte of it. (Many distinct-hash
    // copies summing past the cap hit the same accumulate line; a single
    // over-cap copy is the cheap shape that proves the read never fires.)
    const log_body = try session_log.writeEventLog(
        &.{.{ .meta_event = .open_main_menu }},
        "20260815_143022",
        allocator,
    );
    defer allocator.free(log_body);
    var session_log_txt: std.ArrayList(u8) = .empty;
    defer session_log_txt.deinit(allocator);
    try session_log_txt.appendSlice(allocator, log_body);
    try session_log_txt.appendSlice(allocator, "\nReconstructionCache\n");
    try session_log_txt.appendSlice(allocator, "\nevent_index 0\n");
    try session_log_txt.appendSlice(allocator, "path missions/bomb/mission.txt\n");
    try session_log_txt.print(allocator, "hash {x:0>64}\n", .{@as(u64, 1)});
    try session_log_txt.appendSlice(allocator, "file bomb.dat\n");
    _ = dir.createDirPath(io, "bombbundle/content") catch
        @panic("failed to create bundle content dir");
    dir.writeFile(io, .{
        .sub_path = "bombbundle/session_log.txt",
        .data = session_log_txt.items,
    }) catch @panic("failed to write bundle session log");

    var file = dir.createFile(io, "bombbundle/content/bomb.dat", .{}) catch
        @panic("failed to create sparse content file");
    file.setLength(io, 1024 * 1024 * 1024 + 64 * 1024 * 1024) catch
        @panic("failed to extend sparse content file");
    file.close(io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.BundleTooLarge,
        loadSessionLogBundle(dir, "bombbundle", io, arena.allocator()),
    );
}
