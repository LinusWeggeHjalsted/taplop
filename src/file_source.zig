//! Unified file I/O for the game. See DESIGN → File System & IO.
//!
//! The game ships as a single-file executable: all `data/` + `assets/` content
//! is embedded at build time (see `generated_assets.zig`, emitted by build.zig).
//! Writable artifacts (saves, session logs) live in a persistent data
//! directory (`~/.ziglop/` by default). Both content reads and artifact
//! reads/writes funnel through this one session-resident `FileSource` so the
//! game never depends on the current working directory.
//!
//! Read order (first hit wins):
//!   1. in-memory VFS — uploaded zips / fetched custom missions (transient;
//!      not wired)
//!   2. persistent dir — `~/.ziglop/<path>`
//!   3. embedded map — `data/**` + `assets/**` baked into the exe
//!
//! Because the persistent dir is checked before the embedded map, a player can
//! drop a file at `~/.ziglop/<shipped-path>` to shadow shipped content — a
//! modding seam by side effect (accepted as-is; see DESIGN → File System & IO). Writes
//! target the persistent dir only and reject `data/`/`assets/` prefixes so the
//! game itself can never shadow its own shipped content.
//!
//! `FileSource` lives on `GameStateHistory` next to `settings`: session-resident,
//! never deep-copied into snapshots, never touched by replay.

const std = @import("std");
const embedded_assets = @import("generated_assets");
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");

/// A generous upper bound on a single file read, guarding against runaway
/// reads while comfortably covering any shipped asset (largest current asset
/// is ~70 KB).
const read_limit: std.Io.Limit = .limited(256 * 1024 * 1024);

pub const FileSource = struct {
    io: std.Io,
    // The persistent data directory (~/.ziglop/). All writes land here, and
    // reads of shipped paths check here first (player overrides / custom
    // content) before falling back to the embedded map.
    persistent_dir: std.Io.Dir,

    pub fn init(io: std.Io, persistent_dir: std.Io.Dir) FileSource {
        return .{ .io = io, .persistent_dir = persistent_dir };
    }

    /// Read a file by project-root-relative path. Lookup order:
    /// persistent dir -> embedded map. Always returns freshly allocated bytes
    /// owned by the caller (embedded bytes are duped so the caller can free
    /// uniformly). Returns `error.FileNotFound` if no layer has the path.
    pub fn readFile(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) ![]u8 {
        // 1. in-memory VFS — not wired.

        // 2. persistent dir (player overrides / custom content).
        if (self.persistent_dir.readFileAlloc(self.io, path, allocator, read_limit)) |bytes| {
            return bytes;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        // 3. embedded map (shipped data/ + assets/).
        if (embedded_assets.map.get(path)) |bytes| {
            return try allocator.dupe(u8, bytes);
        }

        return error.FileNotFound;
    }

    /// Read a file from the embedded map ONLY, skipping the persistent
    /// dir. Used by the startup-config fallback (see DESIGN → Error
    /// Handling): when a persistent-dir shadow of a shipped config file
    /// fails to parse, the loader retries against the embedded copy so a
    /// broken override can't crash the game. Returns `error.FileNotFound`
    /// if the path isn't in the embedded map. Always returns freshly
    /// allocated bytes (the caller owns them).
    pub fn readEmbeddedFile(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) ![]u8 {
        _ = self; // the embedded map is a comptime-global, no instance state
        if (embedded_assets.map.get(path)) |bytes| {
            return try allocator.dupe(u8, bytes);
        }
        return error.FileNotFound;
    }

    /// Whether a file exists in the persistent dir at the given project-root-
    /// relative path. Does NOT consult the embedded map (shipped content is
    /// always present; this is for detecting player-written artifacts like an
    /// autosave). No allocation. Returns false on any non-FileNotFound stat
    /// error too (treated as "not available" — the caller degrades to
    /// "no autosave" rather than crashing at startup over a permission quirk).
    pub fn fileExists(self: *const FileSource, path: []const u8) bool {
        _ = self.persistent_dir.statFile(self.io, path, .{}) catch return false;
        return true;
    }

    /// Write a file to the persistent dir only. Rejects `data/`/`assets/`
    /// prefixes — shipped content is immutable from the game's perspective
    /// (players may still drop override files into the persistent dir by hand;
    /// that's the modding seam, not a game-driven write). Creates parent
    /// directories as needed so callers can write any subpath (e.g.
    /// `logs/session_log_*.txt`) without pre-creating the tree. On web
    /// (emscripten), flushes the IDBFS layer to IndexedDB after the write so
    /// the data survives a page refresh / browser close.
    pub fn writeFile(
        self: *const FileSource,
        path: []const u8,
        bytes: []const u8,
    ) !void {
        if (std.mem.startsWith(u8, path, "data/") or std.mem.startsWith(u8, path, "assets/")) {
            @panic("FileSource.writeFile: refused write to shipped path — built-in data/assets are immutable");
        }
        try self.ensureParentDirs(path);
        try self.persistent_dir.writeFile(self.io, .{
            .sub_path = path,
            .data = bytes,
        });
        // On web, the emscripten FS writes to an in-memory layer; syncfs
        // persists it to IndexedDB. The comptime gate ensures this branch is
        // dead code on native (the extern is never referenced, so it won't
        // need to link). The syncfs callback just logs errors — the write is
        // already safe in memory, and the flush is best-effort persistence.
        if (@import("builtin").os.tag == .emscripten) {
            flushPersistentDir();
        }
    }

    /// Create intermediate directories in the persistent dir for a file's
    /// parent, as needed (mkdir -p, idempotent). No-op for top-level files.
    fn ensureParentDirs(self: *const FileSource, path: []const u8) !void {
        const dir = std.fs.path.dirname(path) orelse return;
        if (dir.len == 0) return;
        // createDirPath is idempotent (succeeds if the dir already exists), so
        // any error here is a genuine problem (permissions, disk full, etc.) —
        // propagate it rather than silently swallowing.
        try self.persistent_dir.createDirPath(self.io, dir);
    }

    /// One custom mission in the player's local collection. `id` is the
    /// folder name under `custom_missions/` — for editor-generated and
    /// online-downloaded missions this is `<uuid>_<slug>`; for hand-placed
    /// folders it's whatever the user named it (both are accepted). `name`
    /// is the display name from mission.txt. `has_custom_assets` is true if
    /// the folder contains any file beyond the known config set
    /// (mission.txt / player.txt / level_*.txt). `author_turns` is the
    /// validation run's turn count (the author medal target), read from the
    /// validation replay file's metadata — null when the mission hasn't been
    /// validated (no replay file). Medal targets (gold/silver/bronze) are
    /// DERIVED from `author_turns` at display time, not stored here.
    pub const CustomMissionEntry = struct {
        id: []const u8,
        name: []const u8,
        level_count: u32,
        has_custom_assets: bool,
        author_turns: ?u32,
    };

    /// Enumerate the player's local custom-mission collection under
    /// `custom_missions/` in the persistent dir. Returns one entry per
    /// subdirectory, with metadata read from each mission's `mission.txt`.
    /// Folders without a readable `mission.txt` are SKIPPED (a half-installed
    /// or broken mission is not listed; the browser shouldn't offer to start
    /// something unparseable). The caller owns the returned slice and all
    /// strings within (allocated from `allocator`).
    ///
    /// Persistent-dir only (no VFS): the local collection is the source of
    /// truth for "your custom missions." Transient acquisitions (online
    /// fetch-to-local, zip preview) persist into this dir first, then appear
    /// here. See DESIGN → Custom Missions & Online Services.
    pub fn listCustomMissions(
        self: *const FileSource,
        allocator: std.mem.Allocator,
    ) ![]CustomMissionEntry {
        // Open custom_missions/ with iterate capability. If the dir doesn't
        // exist yet (fresh install, no custom missions acquired), return an
        // empty list — not an error.
        const custom_dir = self.persistent_dir.openDir(self.io, "custom_missions", .{
            .access_sub_paths = true,
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer std.Io.Dir.close(custom_dir, self.io);

        var entries: std.ArrayList(CustomMissionEntry) = .empty;
        errdefer {
            for (entries.items) |e| {
                allocator.free(e.id);
                allocator.free(e.name);
            }
            entries.deinit(allocator);
        }

        var it = custom_dir.iterate();
        while (try it.next(self.io)) |dir_entry| {
            if (dir_entry.kind != .directory) continue;

            const mission_id = try allocator.dupe(u8, dir_entry.name);
            errdefer allocator.free(mission_id);

            // Read mission.txt from this subfolder via the FileSource (so the
            // read goes through the same layering as gameplay reads — though
            // for custom missions it's always the persistent dir).
            const mission_path = try std.fmt.allocPrint(allocator, "custom_missions/{s}/mission.txt", .{mission_id});
            defer allocator.free(mission_path);
            const mission_bytes = self.readFile(allocator, mission_path) catch |err| switch (err) {
                // No mission.txt (or unreadable) → skip this folder; it's not
                // a playable custom mission. Free the id we duped.
                error.FileNotFound => {
                    allocator.free(mission_id);
                    continue;
                },
                else => {
                    allocator.free(mission_id);
                    return err;
                },
            };

            // Parse just enough metadata (name + level_count) in a throwaway
            // arena — the sections are large and we only keep two duped
            // strings out of them. A full loadMission would also validate
            // file_format_version etc.; for a browser listing we tolerate
            // slightly-malformed missions (show it's there), skipping on
            // parse failure.
            var parse_arena = std.heap.ArenaAllocator.init(allocator);
            defer parse_arena.deinit();
            const pa = parse_arena.allocator();
            const sections = parser.parseConfigFile(mission_bytes, pa) catch {
                allocator.free(mission_id);
                allocator.free(mission_bytes);
                continue;
            };
            const mission = loaders.loadMission(sections, pa) catch {
                allocator.free(mission_id);
                allocator.free(mission_bytes);
                continue;
            };

            // loadMission returns borrowed strings pointing into the parsed
            // sections (which point into mission_bytes). Dupe the name BEFORE
            // freeing mission_bytes so the source is still valid.
            const owned_name = try allocator.dupe(u8, mission.name);
            errdefer allocator.free(owned_name);
            allocator.free(mission_bytes);

            // has_custom_assets: scan the folder for any file that isn't a
            // known config file. Known config: mission.txt, player.txt,
            // level_<N>.txt. Anything else (sprites, audio, etc.) → true.
            const has_custom_assets = try folderHasCustomAssets(self, custom_dir, dir_entry.name, mission.level_count);

            try entries.append(allocator, .{
                .id = mission_id,
                .name = owned_name,
                .level_count = mission.level_count,
                .has_custom_assets = has_custom_assets,
                .author_turns = null, // no validation replay format
            });
        }

        return entries.toOwnedSlice(allocator);
    }
};

/// Scan a custom-mission folder for files beyond the known config set
/// (mission.txt, player.txt, level_<N>.txt). Returns true if any such file
/// exists (custom sprites/audio/assets). `level_count` is the mission's
/// declared level count, used to know which level_*.txt names are expected.
fn folderHasCustomAssets(
    file_source: *const FileSource,
    custom_dir: std.Io.Dir,
    mission_id: []const u8,
    level_count: u32,
) !bool {
    const mission_dir = custom_dir.openDir(file_source.io, mission_id, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch return false; // unreadable folder → treat as no custom assets
    defer std.Io.Dir.close(mission_dir, file_source.io);

    var it = mission_dir.iterate();
    while (try it.next(file_source.io)) |entry| {
        if (entry.kind == .directory) continue; // subdirs aren't config files
        const name = entry.name;
        if (std.mem.eql(u8, name, "mission.txt")) continue;
        if (std.mem.eql(u8, name, "player.txt")) continue;
        // level_<N>.txt — match the pattern.
        if (matchesLevelFile(name, level_count)) continue;
        // Anything else is a custom asset.
        return true;
    }
    return false;
}

/// Returns true if `name` is `level_<N>.txt` for some 1 <= N <= level_count.
fn matchesLevelFile(name: []const u8, level_count: u32) bool {
    if (!std.mem.startsWith(u8, name, "level_")) return false;
    if (!std.mem.endsWith(u8, name, ".txt")) return false;
    const digits = name["level_".len .. name.len - ".txt".len];
    if (digits.len == 0) return false;
    const n = std.fmt.parseInt(u32, digits, 10) catch return false;
    return n >= 1 and n <= level_count;
}

// Web-only: flush the IDBFS in-memory layer to IndexedDB. The extern is
// declared here (not gated) because Zig only emits a symbol reference when the
// call site is reachable — and flushPersistentDir is only called from the
// comptime-gated emscripten branch in writeFile, so on native the linker never
// needs to resolve emscripten_run_script. This keeps file_source.zig in the
// headless test build without a link-time dependency on emscripten.
extern fn emscripten_run_script(script: [*:0]const u8) void;

/// Flush the IDBFS layer to IndexedDB (web only). Called after each
/// FileSource.writeFile on emscripten. Best-effort: the syncfs callback just
/// logs errors — the write is already safe in memory, and this persists it to
/// IndexedDB so it survives a refresh/browser close. The JS runs synchronously
/// up to the async syncfs call, which the browser completes in the background.
fn flushPersistentDir() void {
    emscripten_run_script("FS.syncfs(false, function(err) { if (err) console.error('IDBFS flush failed:', err); });");
}

// --- tests for listCustomMissions ---

const testing = std.testing;

test "listCustomMissions: empty when custom_missions/ absent" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-custom-empty";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    const list = try file_source.listCustomMissions(allocator);
    defer allocator.free(list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "listCustomMissions: lists missions with metadata + custom-asset detection" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-custom-populated";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Mission 1: plain folder name, config files only (no custom assets).
    file_source.writeFile("custom_missions/skeleton_attack/mission.txt",
        "Metadata\nfile_format_version 1\nlevel_count 1\nname Skeleton Attack\n") catch @panic("w1");
    file_source.writeFile("custom_missions/skeleton_attack/level_1.txt",
        "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w2");

    // Mission 2: UUID_slug folder name, config + a custom sprite (custom assets).
    file_source.writeFile("custom_missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/mission.txt",
        "Metadata\nfile_format_version 1\nlevel_count 2\nname Tree Grove\n") catch @panic("w3");
    file_source.writeFile("custom_missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/level_1.txt",
        "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w4");
    file_source.writeFile("custom_missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/level_2.txt",
        "Metadata\nfile_format_version 1\n\nLayout\n.!\n") catch @panic("w5");
    file_source.writeFile("custom_missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/custom_tree.png",
        "fake png bytes") catch @panic("w6");

    // Mission 3: missing mission.txt — should be SKIPPED.
    file_source.writeFile("custom_missions/broken/level_1.txt",
        "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w7");

    const list = try file_source.listCustomMissions(allocator);
    defer {
        for (list) |e| {
            allocator.free(e.id);
            allocator.free(e.name);
        }
        allocator.free(list);
    }

    // Two playable missions (broken one is skipped). Order is filesystem-
    // dependent, so find each by id.
    try testing.expectEqual(@as(usize, 2), list.len);

    var found_skeleton = false;
    var found_tree = false;
    for (list) |entry| {
        if (std.mem.eql(u8, entry.id, "skeleton_attack")) {
            found_skeleton = true;
            try testing.expectEqualStrings("Skeleton Attack", entry.name);
            try testing.expectEqual(@as(u32, 1), entry.level_count);
            try testing.expectEqual(false, entry.has_custom_assets);
            try testing.expectEqual(@as(?u32, null), entry.author_turns);
        } else if (std.mem.startsWith(u8, entry.id, "a1b2c3d4")) {
            found_tree = true;
            try testing.expectEqualStrings("Tree Grove", entry.name);
            try testing.expectEqual(@as(u32, 2), entry.level_count);
            try testing.expectEqual(true, entry.has_custom_assets);
        }
    }
    try testing.expect(found_skeleton);
    try testing.expect(found_tree);
}
