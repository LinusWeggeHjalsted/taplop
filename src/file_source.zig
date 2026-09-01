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

/// The shipped campaign mission-directory paths (e.g.
/// "data/campaigns/main_campaign/missions/beginnings") — the mission
/// browser's Official tab. Comptime from the embedded map (shipped content
/// is immutable per build); sorted for a stable browser order. Mirrors
/// ui.zig's `official_entity_sprite_stems` comptime scan.
const official_mission_dir_paths: []const []const u8 = build: {
    @setEvalBranchQuota(20000);
    var paths: []const []const u8 = &.{};
    for (embedded_assets.map.kvs.keys[0..embedded_assets.map.kvs.len]) |key| {
        if (!std.mem.startsWith(u8, key, "data/campaigns/")) continue;
        if (!std.mem.endsWith(u8, key, "/mission.txt")) continue;
        const missions_index = std.mem.indexOf(u8, key, "/missions/") orelse continue;
        // The campaign segment between the prefix and "/missions/" must be
        // a single plain path segment (no nesting beyond campaign/missions/).
        const campaign = key["data/campaigns/".len..missions_index];
        if (campaign.len == 0 or std.mem.indexOfScalar(u8, campaign, '/') != null) continue;
        const stem = key[missions_index + "/missions/".len .. key.len - "/mission.txt".len];
        if (stem.len == 0 or std.mem.indexOfScalar(u8, stem, '/') != null) continue;
        const dir_path = key[0 .. key.len - "/mission.txt".len];
        // Insert in sorted position (comptime slices have const elements —
        // no in-place sort).
        var insert_index: usize = 0;
        while (insert_index < paths.len and std.mem.lessThan(u8, paths[insert_index], dir_path)) : (insert_index += 1) {}
        paths = paths[0..insert_index] ++ [_][]const u8{dir_path} ++ paths[insert_index..];
    }
    break :build paths;
};

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

    /// List the `.png` FILE NAMES (sorted, extension included) directly
    /// inside `dir_path` under the persistent dir — the mission-local
    /// sprite picker's source list (a flat scan of the mission directory;
    /// see DESIGN → Architecture → Level Editor → Editor UI layout — the
    /// centered sprite picker). Empty when the dir doesn't exist. Shipped
    /// (embedded) dirs are NOT scanned — shipped missions carry no PNGs,
    /// so the mission-local tab is empty for them by construction.
    pub fn listPersistentPngFiles(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        dir_path: []const u8,
    ) ![][]const u8 {
        var sub_dir = self.persistent_dir.openDir(self.io, dir_path, .{ .iterate = true }) catch |open_error| switch (open_error) {
            error.FileNotFound => return &[_][]const u8{},
            else => return open_error,
        };
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }
        var iterator = sub_dir.iterate();
        while (iterator.next(self.io) catch |iterate_error| return iterate_error) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".png")) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        const SortContext = struct {
            fn lessThan(_: void, first: []const u8, second: []const u8) bool {
                return std.mem.lessThan(u8, first, second);
            }
        };
        std.mem.sort([]const u8, names.items, {}, SortContext.lessThan);
        return names.toOwnedSlice(allocator);
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

    /// One mission in the player's local collection. `id` is the folder
    /// name under `missions/` — for editor-saved and online-downloaded
    /// missions this is `<uuid>_<slug>`; for hand-placed or imported
    /// folders it's whatever the folder is named (all accepted). `path` is
    /// the mission-directory path ("missions/<id>") as `open_editor` /
    /// `start_mission` consume it. `name` is the display name from
    /// mission.txt. `has_custom_assets` is true if the folder contains any
    /// file beyond the known config set (mission.txt / player.txt /
    /// level_*.txt). `author_turns` is the validation run's turn count (the
    /// author medal target), read from the validation replay file's
    /// metadata — null when the mission hasn't been validated (no replay
    /// file). Medal targets (gold/silver/bronze) are DERIVED from
    /// `author_turns` at display time, not stored here.
    pub const MissionEntry = struct {
        id: []const u8,
        path: []const u8,
        name: []const u8,
        level_count: u32,
        has_custom_assets: bool,
        author_turns: ?u32,
    };

    /// Enumerate the player's local mission collection under `missions/`
    /// in the persistent dir (editor saves land in `missions/<uuid>_<slug>/`;
    /// hand-placed and imported folders of any name are accepted too — the
    /// id is whatever the folder is named). Returns one entry per
    /// subdirectory, with metadata read from each mission's `mission.txt`.
    /// Folders without a readable `mission.txt` are SKIPPED (a half-installed
    /// or broken mission is not listed; the browser shouldn't offer to start
    /// something unparseable). The caller owns the returned slice and all
    /// strings within (allocated from `allocator`; free via `freeMissions`).
    ///
    /// Persistent-dir only (no VFS): the local collection is the source of
    /// truth for "your missions." Transient acquisitions (online
    /// fetch-to-local, zip import preview) persist into this dir first, then
    /// appear here. See DESIGN → Custom Missions & Online Services.
    ///
    /// The folder ENUMERATION is platform-split (the save-list scan's
    /// `Dir.iterate`-is-broken-on-IDBFS story — see `listSaveFiles`): web
    /// lists the mission folders via JS + a temp listing file, native
    /// iterates. The per-mission work (mission.txt probe + parse + the
    /// custom-assets check) is shared below — individual file reads + stats
    /// work on IDBFS, so only the directory listings need the JS path.
    pub fn listMissions(
        self: *const FileSource,
        allocator: std.mem.Allocator,
    ) ![]MissionEntry {
        const mission_ids = try self.listMissionFolderNames(allocator);
        defer {
            for (mission_ids) |id| allocator.free(id);
            allocator.free(mission_ids);
        }

        var entries: std.ArrayList(MissionEntry) = .empty;
        errdefer {
            for (entries.items) |e| freeMissionEntry(allocator, e);
            entries.deinit(allocator);
        }

        for (mission_ids) |mission_id| {
            // The entry OWNS its id (the folder-name array is freed by the
            // caller's defer after the loop).
            const owned_id = try allocator.dupe(u8, mission_id);
            errdefer allocator.free(owned_id);

            const mission_dir_path = try std.fmt.allocPrint(allocator, "missions/{s}", .{mission_id});
            errdefer allocator.free(mission_dir_path);
            const mission_txt_path = try std.fmt.allocPrint(allocator, "{s}/mission.txt", .{mission_dir_path});
            defer allocator.free(mission_txt_path);

            // Read mission.txt from this subfolder via the FileSource (so the
            // read goes through the same layering as gameplay reads — though
            // for local missions it's always the persistent dir).
            const mission_bytes = self.readFile(allocator, mission_txt_path) catch |err| switch (err) {
                // No mission.txt (or unreadable) → skip this folder; it's not
                // an openable mission. `continue` discards the errdefers, so
                // free manually. (On `return err` below the errdefers fire —
                // never free manually on an error-return path; that's a
                // double-free.)
                error.FileNotFound => {
                    allocator.free(mission_dir_path);
                    allocator.free(owned_id);
                    continue;
                },
                else => return err,
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
                // Same continue-frees-manually rule as the FileNotFound arm.
                allocator.free(mission_dir_path);
                allocator.free(owned_id);
                allocator.free(mission_bytes);
                continue;
            };
            const mission = loaders.loadMission(sections, pa) catch {
                allocator.free(mission_dir_path);
                allocator.free(owned_id);
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
            // known config file (mission.txt / player.txt / level_<N>.txt —
            // anything else is a custom asset). Platform-split enumeration
            // (see listSaveFiles for the IDBFS story).
            const has_custom_assets = try self.hasMissionCustomAssets(allocator, mission_id, mission.level_count);

            try entries.append(allocator, .{
                .id = owned_id,
                .path = mission_dir_path,
                .name = owned_name,
                .level_count = mission.level_count,
                .has_custom_assets = has_custom_assets,
                .author_turns = null, // no validation replay format
            });
        }

        return entries.toOwnedSlice(allocator);
    }

    /// The mission FOLDER names under `missions/` (directories only, no
    /// files). Native iterates the persistent dir; web enumerates via JS
    /// (`Dir.iterate` fails with `error.Unexpected` on the IDBFS mount —
    /// the `listSaveFiles` story, see `listSaveFilesWeb`). A missing
    /// missions/ (fresh install) is an empty list, not an error. The
    /// caller owns the returned names + slice.
    fn listMissionFolderNames(
        self: *const FileSource,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        if (@import("builtin").os.tag == .emscripten) {
            return listPersistentDirNamesWeb(
                self,
                allocator,
                persistent_mount_path ++ "/missions",
                true,
            );
        }
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }
        const missions_dir = self.persistent_dir.openDir(self.io, "missions", .{
            .access_sub_paths = true,
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return names.toOwnedSlice(allocator),
            else => return err,
        };
        defer std.Io.Dir.close(missions_dir, self.io);
        var it = missions_dir.iterate();
        while (try it.next(self.io)) |dir_entry| {
            if (dir_entry.kind != .directory) continue;
            try names.append(allocator, try allocator.dupe(u8, dir_entry.name));
        }
        return names.toOwnedSlice(allocator);
    }

    /// Does the mission folder contain any file beyond the known config
    /// set (mission.txt / player.txt / level_<N>.txt)? Native iterates the
    /// folder; web enumerates its FILE children via JS (the
    /// `listMissionFolderNames` story) + the shared name check. A
    /// pathological folder name (quote/backslash — can't be embedded in the
    /// JS path) reports false on web (the mission still lists; the flag is
    /// advisory).
    fn hasMissionCustomAssets(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        mission_id: []const u8,
        level_count: u32,
    ) !bool {
        if (@import("builtin").os.tag == .emscripten) {
            if (!isSafeForJsEmbedding(mission_id)) return false;
            const fs_dir_path = try std.fmt.allocPrint(
                allocator,
                "{s}/missions/{s}",
                .{ persistent_mount_path, mission_id },
            );
            defer allocator.free(fs_dir_path);
            const names = try listPersistentDirNamesWeb(self, allocator, fs_dir_path, false);
            defer {
                for (names) |name| allocator.free(name);
                allocator.free(names);
            }
            for (names) |name| {
                if (!isKnownMissionConfigFile(name, level_count)) return true;
            }
            return false;
        }
        const dir_path = try std.fmt.allocPrint(allocator, "missions/{s}", .{mission_id});
        defer allocator.free(dir_path);
        const mission_dir = self.persistent_dir.openDir(self.io, dir_path, .{
            .access_sub_paths = true,
            .iterate = true,
        }) catch return false; // unreadable folder → treat as no custom assets
        defer std.Io.Dir.close(mission_dir, self.io);
        var it = mission_dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind == .directory) continue; // subdirs aren't config files
            if (!isKnownMissionConfigFile(entry.name, level_count)) return true;
        }
        return false;
    }

    /// Enumerate the OFFICIAL missions (shipped embedded campaign content)
    /// for the mission browser's Official tab. Metadata (name +
    /// level_count) is parsed from each mission's embedded mission.txt at
    /// call time — the path list is comptime-known, the parse is not.
    /// Entries mirror `listMissions` (same `MissionEntry` shape; `id` is the
    /// mission's folder stem, `path` is the embedded dir path exactly as
    /// `open_editor` consumes it). The caller owns the returned slice +
    /// strings (`freeMissions`). A mission whose mission.txt is unreadable
    /// or unparseable is SKIPPED (shouldn't happen for shipped content — an
    /// absent row means a broken build).
    pub fn listOfficialMissions(
        self: *const FileSource,
        allocator: std.mem.Allocator,
    ) ![]MissionEntry {
        var entries: std.ArrayList(MissionEntry) = .empty;
        errdefer {
            for (entries.items) |e| freeMissionEntry(allocator, e);
            entries.deinit(allocator);
        }

        for (official_mission_dir_paths) |dir_path| {
            const mission_txt_path = try std.fmt.allocPrint(allocator, "{s}/mission.txt", .{dir_path});
            defer allocator.free(mission_txt_path);
            const mission_bytes = self.readEmbeddedFile(allocator, mission_txt_path) catch continue;

            // Throwaway parse arena — same shape as listMissions: keep only
            // the duped id/path/name out of it.
            var parse_arena = std.heap.ArenaAllocator.init(allocator);
            defer parse_arena.deinit();
            const pa = parse_arena.allocator();
            const sections = parser.parseConfigFile(mission_bytes, pa) catch {
                allocator.free(mission_bytes);
                continue;
            };
            const mission = loaders.loadMission(sections, pa) catch {
                allocator.free(mission_bytes);
                continue;
            };

            const stem = std.fs.path.basename(dir_path);
            const id = try allocator.dupe(u8, stem);
            errdefer allocator.free(id);
            const path = try allocator.dupe(u8, dir_path);
            errdefer allocator.free(path);
            // loadMission borrows into the parse arena — dupe before it dies.
            const name = try allocator.dupe(u8, mission.name);
            errdefer allocator.free(name);
            allocator.free(mission_bytes);

            try entries.append(allocator, .{
                .id = id,
                .path = path,
                .name = name,
                .level_count = mission.level_count,
                .has_custom_assets = false,
                .author_turns = null,
            });
        }

        return entries.toOwnedSlice(allocator);
    }

/// List the save files in saves/ (including the autosave), newest first
/// (mtime descending; name ascending breaks mtime ties deterministically).
/// Only `*.txt` files count — the dir is also where stray non-save artifacts
/// would land. A missing saves/ dir is an empty list (fresh install), not an
/// error. Caller owns the returned slice + its strings (`freeSaveFiles`).
///
/// On web (emscripten IDBFS), `readdir` is broken (returns undefined entries,
/// and Zig's `Dir.iterate` fails with `error.Unexpected`). The web path
/// enumerates `saves/` via JS (`FS.lookupPath` + `Object.keys(node.contents)`)
/// writing the name list to a temp file, then stats each file from Zig
/// (individual file `stat` calls work on IDBFS). See DESIGN → File System & IO.
pub fn listSaveFiles(
    self: *const FileSource,
    allocator: std.mem.Allocator,
) ![]SaveFileEntry {
    var entries: std.ArrayList(SaveFileEntry) = .empty;
    errdefer freeSaveFiles(allocator, entries.items);

    if (@import("builtin").os.tag == .emscripten) {
        try self.listSaveFilesWeb(allocator, &entries);
    } else {
        try self.listSaveFilesNative(allocator, &entries);
    }

    std.mem.sort(SaveFileEntry, entries.items, {}, saveFileOrder);
    return entries.toOwnedSlice(allocator);
}

/// Temp file (persistent-dir root, outside saves/) used by the web path to
/// pass the JS-enumerated filename list back to Zig. Written by JS, read +
/// deleted by Zig. Mirrors the `.import_marker` pattern.
const saves_listing_temp = ".saves_listing";

/// Native path: open saves/, iterate entries, filter .txt, stat each.
fn listSaveFilesNative(
    self: *const FileSource,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(SaveFileEntry),
) !void {
    const saves_dir = self.persistent_dir.openDir(self.io, "saves", .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer std.Io.Dir.close(saves_dir, self.io);

    var it = saves_dir.iterate();
    while (try it.next(self.io)) |dir_entry| {
        if (dir_entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, dir_entry.name, ".txt")) continue;

        // Stat through the open saves_dir by bare name — a failure here
        // (vanished between iterate + stat, permissions quirk) skips the
        // entry without having allocated anything for it yet.
        const stat = saves_dir.statFile(self.io, dir_entry.name, .{}) catch continue;

        const relative_path = try std.fmt.allocPrint(allocator, "saves/{s}", .{dir_entry.name});
        errdefer allocator.free(relative_path);
        const name = try allocator.dupe(u8, dir_entry.name);
        errdefer allocator.free(name);
        try entries.append(allocator, .{
            .name = name,
            .path = relative_path,
            .mtime_ns = stat.mtime.nanoseconds,
        });
    }
}

/// Web path: emscripten IDBFS `readdir` is broken (returns undefined entries),
/// so enumerate `saves/` via JS (`FS.lookupPath` + `Object.keys(node.contents)`)
/// and write the `.txt` filename list to a temp file. Zig reads the temp file,
/// then stats each file individually (stat works on IDBFS — only readdir is
/// broken). The temp file is deleted after reading.
fn listSaveFilesWeb(
    self: *const FileSource,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(SaveFileEntry),
) !void {
    // JS: enumerate saves/ via lookupPath + Object.keys, filter .txt, write
    // the newline-separated name list to a temp file. If saves/ doesn't exist
    // (fresh install), write an empty file so Zig reads an empty list.
    const script =
        "(function() {" ++
        "try {" ++
        "  var node = FS.lookupPath('" ++ persistent_mount_path ++ "/saves');" ++
        "  if (!node || !node.node) { FS.writeFile('" ++ persistent_mount_path ++ "/" ++ saves_listing_temp ++ "', ''); return; }" ++
        "  var names = Object.keys(node.node.contents).filter(function(n) { return n.endsWith('.txt'); });" ++
        "  FS.writeFile('" ++ persistent_mount_path ++ "/" ++ saves_listing_temp ++ "', names.join('\\n'));" ++
        "} catch(e) {" ++
        "  try { FS.writeFile('" ++ persistent_mount_path ++ "/" ++ saves_listing_temp ++ "', ''); } catch(e2) {}" ++
        "}" ++
        "})();";
    emscripten_run_script(script);

    // Read the temp file (individual file reads work on IDBFS).
    const listing_bytes = self.persistent_dir.readFileAlloc(self.io, saves_listing_temp, allocator, read_limit) catch |err| switch (err) {
        error.FileNotFound => return, // JS didn't write it — empty saves
        else => return err,
    };
    defer allocator.free(listing_bytes);
    // Clean up the temp file.
    self.persistent_dir.deleteFile(self.io, saves_listing_temp) catch {};

    // Parse newline-separated filenames, stat each, build entries.
    var lines = std.mem.splitScalar(u8, listing_bytes, '\n');
    while (lines.next()) |name| {
        if (name.len == 0) continue;

        const relative_path = try std.fmt.allocPrint(allocator, "saves/{s}", .{name});
        errdefer allocator.free(relative_path);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        // Stat via the persistent dir (individual file stats work on IDBFS).
        // A stat failure (vanished between enumerate + stat) skips the entry.
        const stat = self.persistent_dir.statFile(self.io, relative_path, .{}) catch {
            allocator.free(relative_path);
            allocator.free(owned_name);
            continue;
        };
        try entries.append(allocator, .{
            .name = owned_name,
            .path = relative_path,
            .mtime_ns = stat.mtime.nanoseconds,
        });
    }
}

/// Temp listing file for the web JS directory enumeration (the
/// `saves_listing_temp` pattern, reused by both mission-listing call
/// sites — the script runs are sequential + synchronous, so one temp
/// path serves both).
const missions_listing_temp = ".missions_listing";

/// A name that can be safely embedded inside a single-quoted JS string
/// literal (the web listing scripts format paths into them): no quotes,
/// backslashes, or newlines. Our own saved mission dirs are sanitized to
/// this by construction; a hand-placed folder that isn't is skipped by the
/// caller (its flags degrade, the mission still lists).
fn isSafeForJsEmbedding(name: []const u8) bool {
    for (name) |character| {
        if (character == '\'' or character == '"' or character == '\\' or
            character == '\n' or character == '\r') return false;
    }
    return true;
}

/// Web: enumerate one persistent-dir folder's children via JS — Zig's
/// `Dir.iterate` fails with `error.Unexpected` on the IDBFS mount (see
/// `listSaveFiles`). The JS writes the newline-separated names of children
/// whose `isDir` matches `keep_directories` to the temp listing file (empty
/// when the folder is missing or the lookup fails); Zig reads + deletes it.
/// Caller owns the returned names + slice.
fn listPersistentDirNamesWeb(
    self: *const FileSource,
    allocator: std.mem.Allocator,
    /// The ABSOLUTE in-FS path to enumerate (e.g. "/ziglop/missions") —
    /// must be safe to embed in the JS string (the caller filters).
    fs_dir_path: []const u8,
    keep_directories: bool,
) ![][]const u8 {
    const keep_flag: []const u8 = if (keep_directories) "true" else "false";
    const temp_fs_path = persistent_mount_path ++ "/" ++ missions_listing_temp;
    const script_body = std.fmt.allocPrint(
        allocator,
        "(function() {{" ++
            "try {{" ++
            "  var node = FS.lookupPath('{s}');" ++
            "  var names = [];" ++
            "  if (node && node.node) {{" ++
            "    Object.keys(node.node.contents).forEach(function(n) {{" ++
            "      var child = node.node.contents[n];" ++
            "      if (child && FS.isDir(child.mode) === {s}) names.push(n);" ++
            "    }});" ++
            "  }}" ++
            "  FS.writeFile('{s}', names.join('\\n'));" ++
            "}} catch(e) {{" ++
            "  try {{ FS.writeFile('{s}', ''); }} catch(e2) {{}}" ++
            "}}" ++
            "}})();",
        .{ fs_dir_path, keep_flag, temp_fs_path, temp_fs_path },
    ) catch @panic("failed to format web dir listing script");
    defer allocator.free(script_body);
    const script = allocator.dupeZ(u8, script_body) catch
        @panic("failed to null-terminate web dir listing script");
    defer allocator.free(script);
    emscripten_run_script(script);

    // Read the temp listing back (individual file reads work on IDBFS),
    // delete it, split + dupe the names.
    const listing_bytes = self.persistent_dir.readFileAlloc(
        self.io,
        missions_listing_temp,
        allocator,
        read_limit,
    ) catch |err| switch (err) {
        error.FileNotFound => return &.{}, // JS didn't write it — empty dir
        else => return err,
    };
    defer allocator.free(listing_bytes);
    self.persistent_dir.deleteFile(self.io, missions_listing_temp) catch {};

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, listing_bytes, '\n');
    while (lines.next()) |name| {
        if (name.len == 0) continue;
        try names.append(allocator, try allocator.dupe(u8, name));
    }
    return names.toOwnedSlice(allocator);
}

/// Delete a file from the persistent dir (used to consume the import
/// marker). Missing file is an error like any other — callers poll with
/// `fileExists` first.
pub fn deleteFile(self: *const FileSource, path: []const u8) !void {
    try self.persistent_dir.deleteFile(self.io, path);
}
};

/// Scan a mission folder for files beyond the known config set
/// (mission.txt, player.txt, level_<N>.txt) — anything else is a custom
/// asset (sprites, audio). The ENUMERATION is platform-split (see
/// `FileSource.hasMissionCustomAssets`): native iterates the folder; web
/// uses a JS listing. Both share `isKnownMissionConfigFile`.

/// True if `name` is one of the KNOWN mission config files (mission.txt,
/// player.txt, level_<N>.txt for 1 <= N <= level_count) — anything else is
/// a custom asset. Shared by the native folder iteration + the web JS
/// listing (both has-custom-assets paths).
fn isKnownMissionConfigFile(name: []const u8, level_count: u32) bool {
    if (std.mem.eql(u8, name, "mission.txt")) return true;
    if (std.mem.eql(u8, name, "player.txt")) return true;
    return matchesLevelFile(name, level_count);
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

/// One save file in the load-save browser. `path` is persistent-dir
/// relative (what load_save expects); `name` is the bare filename (the
/// browser's display label); `mtime_ns` is the file's last-modified time,
/// the browser's sort key (newest first). Saves are write-once, so mtime
/// is the creation time in practice — Linux commonly doesn't expose a
/// true creation time, and Io.Stat's mtime works on both native and the
/// IDBFS mount.
pub const SaveFileEntry = struct {
    name: []const u8,
    path: []const u8,
    mtime_ns: i128,
};

/// Free a slice returned by `listSaveFiles` (entries + strings).
pub fn freeSaveFiles(allocator: std.mem.Allocator, files: []const SaveFileEntry) void {
    for (files) |file| {
        allocator.free(file.name);
        allocator.free(file.path);
    }
    allocator.free(files);
}

/// Free one `FileSource.MissionEntry`'s strings (not the entry itself).
fn freeMissionEntry(allocator: std.mem.Allocator, entry: FileSource.MissionEntry) void {
    allocator.free(entry.id);
    allocator.free(entry.path);
    allocator.free(entry.name);
}

/// Free a slice returned by `FileSource.listMissions` or
/// `FileSource.listOfficialMissions` (entries + strings). A zero-length
/// slice (`&.{}` from an empty collection) is a no-op — `allocator.free`
/// on an empty slice at a non-owned address would be invalid.
pub fn freeMissions(allocator: std.mem.Allocator, missions: []const FileSource.MissionEntry) void {
    if (missions.len == 0) return;
    for (missions) |entry| freeMissionEntry(allocator, entry);
    allocator.free(missions);
}

/// Newest-first ordering: mtime descending, name ascending as the
/// deterministic tiebreak.
fn saveFileOrder(_: void, a: SaveFileEntry, b: SaveFileEntry) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
    return std.mem.lessThan(u8, a.name, b.name);
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

/// The virtual path where web mounts the IDBFS-backed persistent dir
/// (mirrors $HOME/.ziglop on native). Single source of truth for the mount
/// (web.zig) and for absolute FS paths in JS seams like
/// `triggerBrowserDownload`.
pub const persistent_mount_path = "/ziglop";

/// Marker file (persistent-dir root) written by the web import JS after the
/// picked save file has landed in saves/. Zig polls it while the load-save
/// browser is open; finding it means "an import completed — load this path".
/// Deleted immediately after reading. Lives OUTSIDE saves/ so the save-list
/// scan never sees it.
pub const import_marker_path = ".import_marker";

/// Marker file (persistent-dir root) written by the web mission-import JS
/// after the picked mission .zip has landed in imported_missions/. Zig polls
/// it while the editor's mission browser is open; finding it means "an import
/// upload completed — extract this zip into missions/". Deleted immediately
/// after reading — same shape as `import_marker_path`.
pub const mission_import_marker_path = ".mission_import_marker";

/// On web, offer a file from the persistent dir to the player as a browser
/// download (anchor click on a Blob of the file's bytes). The file must
/// already be written — this reads it back from the emscripten in-memory FS.
/// On native this is a no-op (comptime-dead branch), so the extern is never
/// linked outside web builds. `allocator` only backs the script-string
/// formatting.
pub fn triggerBrowserDownload(allocator: std.mem.Allocator, path: []const u8) void {
    if (@import("builtin").os.tag == .emscripten) {
        const file_name = std.fs.path.basename(path);
        const script_body = std.fmt.allocPrint(
            allocator,
            "(function() {{" ++
                "var data = FS.readFile('{s}/{s}', {{encoding:'utf8'}});" ++
                "var blob = new Blob([data], {{type:'text/plain'}});" ++
                "var url = URL.createObjectURL(blob);" ++
                "var a = document.createElement('a');" ++
                "a.href = url;" ++
                "a.download = '{s}';" ++
                "document.body.appendChild(a);" ++
                "a.click();" ++
                "setTimeout(function() {{ URL.revokeObjectURL(url); a.remove(); }}, 1000);" ++
                "}})();",
            .{ persistent_mount_path, path, file_name },
        ) catch @panic("failed to format download script");
        defer allocator.free(script_body);
        const script = allocator.dupeZ(u8, script_body) catch @panic("failed to null-terminate download script");
        defer allocator.free(script);
        emscripten_run_script(script);
    }
}

/// On web, open a browser file picker for importing a save: the picked file
/// is written into saves/ under its (sanitized) own name, then the import
/// marker is written so the Zig-side poll picks it up and loads it. The
/// write order (save first, marker second) guarantees the bytes exist when
/// the marker does. Native is a no-op (comptime-dead branch). The filename
/// is sanitized in JS (path-traversal + quote safety) — barebones allowlist.
/// Static script (no per-call formatting), so no allocator needed.
pub fn triggerBrowserUpload() void {
    if (@import("builtin").os.tag == .emscripten) {
        const script =
            "(function() {" ++
            "var input = document.createElement('input');" ++
            "input.type = 'file';" ++
            "input.accept = '.txt';" ++
            "input.onchange = function() {" ++
            "  var file = input.files[0];" ++
            "  if (!file) return;" ++
            "  var name = file.name.replace(/[^A-Za-z0-9_.-]/g, '_');" ++
            "  if (name.indexOf('.') == 0) name = '_' + name;" ++
            "  var reader = new FileReader();" ++
            "  reader.onload = function() {" ++
            "    FS.mkdirTree('" ++ persistent_mount_path ++ "/saves');" ++
            "    FS.writeFile('" ++ persistent_mount_path ++ "/saves/' + name, new Uint8Array(reader.result));" ++
            "    FS.writeFile('" ++ persistent_mount_path ++ "/" ++ import_marker_path ++ "', 'saves/' + name);" ++
            "    FS.syncfs(false, function(err) { if (err) console.error('IDBFS flush failed:', err); });" ++
            "  };" ++
            "  reader.readAsArrayBuffer(file);" ++
            "};" ++
            "document.body.appendChild(input);" ++
            "input.click();" ++
            "setTimeout(function() { input.remove(); }, 5000);" ++
            "})();";
        emscripten_run_script(script);
    }
}

/// On web, open a browser file picker for importing a MISSION zip: the
/// picked .zip is written into imported_missions/ under its (sanitized)
/// own name, then the mission import marker is written so the Zig-side
/// poll (while the mission browser is open) picks it up and extracts it
/// into missions/. Same write-order + sanitization discipline as
/// `triggerBrowserUpload`. Native is a no-op (comptime-dead branch) —
/// the editor browser never emits the button there, and the ctrl+I
/// binding parses but no-ops (the skip_level discipline).
pub fn triggerBrowserMissionUpload() void {
    if (@import("builtin").os.tag == .emscripten) {
        const script =
            "(function() {" ++
            "var input = document.createElement('input');" ++
            "input.type = 'file';" ++
            "input.accept = '.zip';" ++
            "input.onchange = function() {" ++
            "  var file = input.files[0];" ++
            "  if (!file) return;" ++
            "  var name = file.name.replace(/[^A-Za-z0-9_.-]/g, '_');" ++
            "  if (name.indexOf('.') == 0) name = '_' + name;" ++
            "  var reader = new FileReader();" ++
            "  reader.onload = function() {" ++
            "    FS.mkdirTree('" ++ persistent_mount_path ++ "/imported_missions');" ++
            "    FS.writeFile('" ++ persistent_mount_path ++ "/imported_missions/' + name, new Uint8Array(reader.result));" ++
            "    FS.writeFile('" ++ persistent_mount_path ++ "/" ++ mission_import_marker_path ++ "', 'imported_missions/' + name);" ++
            "    FS.syncfs(false, function(err) { if (err) console.error('IDBFS flush failed:', err); });" ++
            "  };" ++
            "  reader.readAsArrayBuffer(file);" ++
            "};" ++
            "document.body.appendChild(input);" ++
            "input.click();" ++
            "setTimeout(function() { input.remove(); }, 5000);" ++
            "})();";
        emscripten_run_script(script);
    }
}

// --- tests for listMissions / listOfficialMissions ---

const testing = std.testing;

test "listMissions: empty when missions/ absent" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-missions-empty";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    const list = try file_source.listMissions(allocator);
    defer freeMissions(allocator, list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "listMissions: lists missions with metadata, paths, + custom-asset detection" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-missions-populated";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Mission 1: plain folder name, config files only (no custom assets).
    file_source.writeFile("missions/skeleton_attack/mission.txt",
        "Metadata\nfile_format_version 2\nmission_uuid 11111111-1111-1111-1111-111111111111\nlevel_count 1\nname Skeleton Attack\n") catch @panic("w1");
    file_source.writeFile("missions/skeleton_attack/level_1.txt",
        "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w2");

    // Mission 2: UUID_slug folder name, config + a custom sprite (custom assets).
    file_source.writeFile("missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/mission.txt",
        "Metadata\nfile_format_version 2\nmission_uuid 22222222-2222-2222-2222-222222222222\nlevel_count 2\nname Tree Grove\n") catch @panic("w3");
    file_source.writeFile("missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/level_1.txt",
        "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w4");
    file_source.writeFile("missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/level_2.txt",
        "Metadata\nfile_format_version 1\n\nLayout\n.!\n") catch @panic("w5");
    file_source.writeFile("missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/custom_tree.png",
        "fake png bytes") catch @panic("w6");

    // Mission 3: missing mission.txt — should be SKIPPED.
    file_source.writeFile("missions/broken/level_1.txt",
        "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w7");

    const list = try file_source.listMissions(allocator);
    defer freeMissions(allocator, list);

    // Two openable missions (broken one is skipped). Order is filesystem-
    // dependent, so find each by id.
    try testing.expectEqual(@as(usize, 2), list.len);

    var found_skeleton = false;
    var found_tree = false;
    for (list) |entry| {
        if (std.mem.eql(u8, entry.id, "skeleton_attack")) {
            found_skeleton = true;
            try testing.expectEqualStrings("Skeleton Attack", entry.name);
            try testing.expectEqualStrings("missions/skeleton_attack", entry.path);
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

test "listOfficialMissions: the shipped campaign missions with paths + metadata" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, undefined);

    const list = try file_source.listOfficialMissions(allocator);
    defer freeMissions(allocator, list);

    // The four shipped main-campaign missions (fixed shipped content — a
    // missing entry means a broken build, so exact stems are asserted).
    try testing.expectEqual(@as(usize, 4), list.len);
    const expected = [_][]const u8{ "beginnings", "forest", "seatown", "wetlands" };
    for (list, expected) |entry, stem| {
        try testing.expectEqualStrings(stem, entry.id);
        try testing.expect(std.mem.startsWith(
            u8,
            entry.path,
            "data/campaigns/main_campaign/missions/",
        ));
        try testing.expect(std.mem.endsWith(u8, entry.path, stem));
        try testing.expect(entry.name.len > 0);
        try testing.expect(entry.level_count > 0);
        try testing.expectEqual(false, entry.has_custom_assets);
    }
}

// --- tests for listSaveFiles ---

test "listSaveFiles: empty when saves/ absent" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-saves-empty";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    const files = try file_source.listSaveFiles(allocator);
    try testing.expectEqual(@as(usize, 0), files.len);
    freeSaveFiles(allocator, files);
}

test "listSaveFiles: only .txt files, newest first, non-txt excluded" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-saves";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Write oldest first, with a sleep between writes: sequential writes
    // can land within the filesystem's mtime resolution (ties would fall to
    // the name tiebreak), so force distinct stamps. 2ms is comfortably above
    // any current filesystem's timestamp granularity.
    std.Io.Dir.cwd().createDirPath(io, scratch) catch {};
    try dir.createDirPath(io, "saves");
    const saves_dir = dir.openDir(io, "saves", .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch @panic("failed to open saves dir");
    try saves_dir.writeFile(io, .{ .sub_path = "oldest.txt", .data = "old" });
    try io.sleep(std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms), .real);
    try saves_dir.writeFile(io, .{ .sub_path = "middle.txt", .data = "mid" });
    try io.sleep(std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms), .real);
    try saves_dir.writeFile(io, .{ .sub_path = "newest.txt", .data = "new" });
    try saves_dir.writeFile(io, .{ .sub_path = "notes.md", .data = "not a save" });
    std.Io.Dir.close(saves_dir, io);

    const files = try file_source.listSaveFiles(allocator);
    defer freeSaveFiles(allocator, files);

    try testing.expectEqual(@as(usize, 3), files.len);
    try testing.expectEqualStrings("newest.txt", files[0].name);
    try testing.expectEqualStrings("saves/newest.txt", files[0].path);
    try testing.expectEqualStrings("middle.txt", files[1].name);
    try testing.expectEqualStrings("oldest.txt", files[2].name);
    // Sanity on the sort key: mtimes strictly descending.
    try testing.expect(files[0].mtime_ns > files[1].mtime_ns);
    try testing.expect(files[1].mtime_ns > files[2].mtime_ns);
}
