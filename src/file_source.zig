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
//!   1. in-memory VFS - uploaded zips / fetched custom missions (transient;
//!      not wired)
//!   2. persistent dir - `~/.ziglop/<path>`
//!   3. embedded map - `data/**` + `assets/**` baked into the exe
//!
//! Because the persistent dir is checked before the embedded map, a player can
//! drop a file at `~/.ziglop/<shipped-path>` to shadow shipped content - a
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

/// The content-root path policy, enforced at the readFile/writeFile seam:
/// a path must be relative (no leading `/`), stay inside the root (no `..`
/// segment), use `/` separators only (no backslash), contain no NUL, and
/// have no empty segment (which covers the empty path). Reads treat a
/// violation as `error.FileNotFound` (a path outside the content root is
/// not addressable); writes panic (every write caller is a constant or an
/// already-validated import path - a violation is a programmer error).
/// Defense in depth against crafted session-log bundles / validation
/// replays seeding reconstruction reads outside the persistent dir
/// (PROJECTREVIEW m-5.1 - a must-have before the server seam). Same rule
/// set as `zip_reader.isUnsafeZipEntryName`, kept separate on purpose:
/// this is the lower layer and zip_reader stays import-free of it.
fn isInvalidRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return true;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return true;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return true;
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

/// The shipped campaign mission-directory paths, content-root-relative
/// (e.g. "campaigns/main_campaign/missions/beginnings") - the mission
/// browser's Official tab, and the shape every campaign-content path uses
/// (the official campaign's bytes resolve through readFile's embedded
/// `data/`-prefix bridge; see DESIGN → Campaigns & the Campaign Editor →
/// Campaign content paths). Comptime from the embedded map (shipped
/// content is immutable per build; the map KEYS are `data/`-prefixed, so
/// the scan strips the prefix at the boundary). Sorted for a stable
/// browser order. Mirrors ui/editor_pickers.zig's
/// `official_entity_sprite_stems` comptime scan.
/// The OFFICIAL missions' level counts, comptime from the embedded map:
/// dir path -> the largest N with level_1..level_N embedded. Shipped
/// content is immutable per build, so this is machine-walked truth with
/// zero runtime cost (the runtime probe + the persistent scan derive the
/// same rule from disk listings).
const official_mission_level_counts: []const u32 = build: {
    @setEvalBranchQuota(20000);
    var counts: []const u32 = &.{};
    for (official_mission_dir_paths) |dir_path| {
        var count: u32 = 0;
        probe: while (true) {
            const probe_path = "data/" ++ dir_path ++ "/level_" ++
                std.fmt.comptimePrint("{d}", .{count + 1}) ++ ".txt";
            for (embedded_assets.map.kvs.keys[0..embedded_assets.map.kvs.len]) |key| {
                if (std.mem.eql(u8, key, probe_path)) {
                    count += 1;
                    continue :probe;
                }
            }
            break :probe;
        }
        counts = counts ++ [_]u32{count};
    }
    break :build counts;
};

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
        // Strip the embedded map's `data/` addressing prefix: the dir path
        // is a CONTENT path from here on (readFile/readEmbeddedFile re-add
        // the prefix when they need the embedded key).
        const dir_path = key["data/".len .. key.len - "/mission.txt".len];
        // Insert in sorted position (comptime slices have const elements -
        // no in-place sort).
        var insert_index: usize = 0;
        while (insert_index < paths.len and std.mem.lessThan(u8, paths[insert_index], dir_path)) : (insert_index += 1) {}
        paths = paths[0..insert_index] ++ [_][]const u8{dir_path} ++ paths[insert_index..];
    }
    break :build paths;
};

/// The content-root-relative location a `custom/...` sprite id resolves
/// to: everything after the `custom/` path segment IS the file's location
/// (sans `.png`). The id bakes in its own path - `custom/missions/<dir>/<s>`
/// (dreams), `custom/campaigns/<campaign>/missions|hubs/<dir>/<s>`
/// (campaign-bundled art) - so resolution is context-free and the same id
/// means the same file everywhere (a requirement of the texture cache's
/// global id keys). Accepts either form callers carry: a bare stem
/// (`custom/...`) or a kind-prefixed sprite id (`entities/custom/...`) -
/// both find the `custom/` segment. Returns null when there is no
/// `custom/` segment or nothing follows it. The ONE resolution rule -
/// both the loader (dims) and the texture store (bytes) go through this;
/// see DESIGN → Custom Missions & Online Services → Custom-asset paths.
pub fn customAssetTail(sprite: []const u8) ?[]const u8 {
    const prefix = "custom/";
    const index = std.mem.indexOf(u8, sprite, prefix) orelse return null;
    const tail = sprite[index + prefix.len ..];
    if (tail.len == 0) return null;
    return tail;
}

/// Mint a custom sprite stem for art living at `content_path` (a
/// content-root-relative dir, e.g. `missions/<dir>` or
/// `campaigns/<c>/hubs/<h>`; a leading `data/` is also accepted and
/// stripped - embedded content addresses as `data/<tail>` inside
/// readFile's tiers). The inverse of `customAssetTail`: the minted
/// stem's tail IS the dir.
pub fn customStemForContentPath(content_path: []const u8, file_stem: []const u8, allocator: std.mem.Allocator) []const u8 {
    const path = if (std.mem.startsWith(u8, content_path, "data/"))
        content_path["data/".len..]
    else
        content_path;
    return std.fmt.allocPrint(allocator, "custom/{s}/{s}", .{ path, file_stem }) catch
        @panic("failed to mint custom sprite stem");
}

pub const FileSource = struct {
    io: std.Io,
    // The persistent data directory (~/.ziglop/). All writes land here, and
    // reads of shipped paths check here first (player overrides / custom
    // content) before falling back to the embedded map.
    persistent_dir: std.Io.Dir,

    pub fn init(io: std.Io, persistent_dir: std.Io.Dir) FileSource {
        return .{ .io = io, .persistent_dir = persistent_dir };
    }

    /// Read a file by content-root-relative path. Lookup order:
    /// persistent dir -> embedded map (as-is; `assets/...` art) -> embedded
    /// map under a `data/` prefix (campaign-bundled content: a path like
    /// `campaigns/<c>/hubs/<h>/<s>.png` addresses the embedded
    /// `data/campaigns/...` bytes). Always returns freshly allocated bytes
    /// owned by the caller (embedded bytes are duped so the caller can free
    /// uniformly). Returns `error.FileNotFound` if no layer has the path -
    /// including for a path rejected by `isInvalidRelativePath` (a path
    /// outside the content root is not addressable, so it is "not found";
    /// see that fn for why the gate lives here).
    pub fn readFile(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) ![]u8 {
        // 1. in-memory VFS - not wired.

        if (isInvalidRelativePath(path)) return error.FileNotFound;

        // 2. persistent dir (player overrides / custom content).
        if (self.persistent_dir.readFileAlloc(self.io, path, allocator, read_limit)) |bytes| {
            return bytes;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        // 3. embedded map (shipped data/ + assets/).
        if (embedded_assets.map.get(path)) |bytes| {
            return allocator.dupe(u8, bytes) catch @panic("failed to dupe embedded file bytes");
        }

        // 4. embedded map under the `data/` prefix - campaign-bundled
        // content addressed content-root-relative (see customAssetTail;
        // `data/data/` is never a real key, so already-prefixed paths skip).
        if (!std.mem.startsWith(u8, path, "data/")) {
            const embedded_key = std.fmt.allocPrint(allocator, "data/{s}", .{path}) catch
                @panic("failed to build embedded data/ lookup key");
            defer allocator.free(embedded_key);
            if (embedded_assets.map.get(embedded_key)) |bytes| {
                return allocator.dupe(u8, bytes) catch @panic("failed to dupe embedded file bytes");
            }
        }

        return error.FileNotFound;
    }

    /// Read a file from the embedded map ONLY, skipping the persistent
    /// dir. Used by the startup-config fallback (see DESIGN → Error
    /// Handling): when a persistent-dir shadow of a shipped config file
    /// fails to parse, the loader retries against the embedded copy so a
    /// broken override can't crash the game. Same lookup tiers as
    /// `readFile` minus the persistent dir: embedded as-is, then embedded
    /// under a `data/` prefix (so a content-root-relative campaign path
    /// like `campaigns/<c>/campaign.txt` addresses its embedded copy).
    /// Returns `error.FileNotFound` if the path isn't in the embedded map.
    /// Always returns freshly allocated bytes (the caller owns them).
    pub fn readEmbeddedFile(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) ![]u8 {
        _ = self; // the embedded map is a comptime-global, no instance state
        if (embedded_assets.map.get(path)) |bytes| {
            return allocator.dupe(u8, bytes) catch @panic("failed to dupe embedded file bytes");
        }
        if (!std.mem.startsWith(u8, path, "data/")) {
            const embedded_key = std.fmt.allocPrint(allocator, "data/{s}", .{path}) catch
                @panic("failed to build embedded data/ lookup key");
            defer allocator.free(embedded_key);
            if (embedded_assets.map.get(embedded_key)) |bytes| {
                return allocator.dupe(u8, bytes) catch @panic("failed to dupe embedded file bytes");
            }
        }
        return error.FileNotFound;
    }

    /// An audio file resolved through the layered source: the raw bytes
    /// (caller-owned) + the raylib format tag (the extension, dot included)
    /// matching whichever accepted candidate hit.
    pub const AudioFile = struct {
        bytes: []u8,
        format: [:0]const u8,
    };

    /// The accepted audio-file extensions, in lookup priority order - see
    /// DESIGN → Audio (file formats). `.wav` MUST be tried first: the
    /// layering is per-path and every shipped sound is an `.ogg` in the
    /// embedded map, so an `.ogg`-first order would always hit the embedded
    /// copy and a dropped `.wav` would never load. Pub: the sound-report
    /// tool walks the same order so its statuses name the file that
    /// actually resolves.
    pub const audio_file_extensions = [2][:0]const u8{ ".wav", ".ogg" };

    /// Read the first existing audio file at `path_without_extension` plus
    /// each accepted extension, in `audio_file_extensions` priority order -
    /// every candidate goes through the normal `readFile` layering
    /// (persistent dir first, embedded second). Returns the bytes + the
    /// extension that hit as the format tag, or null when no candidate
    /// exists in any layer. Any read error on a candidate counts as a miss
    /// for that candidate (audio load failures degrade to silence in the
    /// backend, never a crash).
    pub fn readAudioFile(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        path_without_extension: []const u8,
    ) ?AudioFile {
        for (audio_file_extensions) |extension| {
            const path = std.fmt.allocPrint(
                allocator,
                "{s}{s}",
                .{ path_without_extension, extension },
            ) catch @panic("failed to build audio file path");
            defer allocator.free(path);
            if (self.readFile(allocator, path)) |bytes| {
                return .{ .bytes = bytes, .format = extension };
            } else |_| {}
        }
        return null;
    }

    /// Whether a file exists in the persistent dir at the given project-root-
    /// relative path. Does NOT consult the embedded map (shipped content is
    /// always present; this is for detecting player-written artifacts like an
    /// autosave). No allocation. Returns false on any non-FileNotFound stat
    /// error too (treated as "not available" - the caller degrades to
    /// "no autosave" rather than crashing at startup over a permission quirk).
    pub fn fileExists(self: *const FileSource, path: []const u8) bool {
        _ = self.persistent_dir.statFile(self.io, path, .{}) catch return false;
        return true;
    }

    /// List the `.png` FILE NAMES (sorted, extension included) directly
    /// inside `dir_path` under the persistent dir - the mission-local
    /// sprite picker's source list (a flat scan of the mission directory;
    /// see DESIGN → Architecture → Level Editor → Editor UI layout - the
    /// centered sprite picker). Empty when the dir doesn't exist. Shipped
    /// (embedded) dirs are NOT scanned - shipped missions carry no PNGs,
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
    /// prefixes - shipped content is immutable from the game's perspective
    /// (players may still drop override files into the persistent dir by hand;
    /// that's the modding seam, not a game-driven write). Creates parent
    /// directories as needed so callers can write any subpath (e.g.
    /// `logs/session_log_*.txt`) without pre-creating the tree. On web
    /// (emscripten), the write lands in the in-memory (MEMFS) persistent
    /// mount only - the session-scoped storage model touches no browser
    /// storage at all (no syncfs, no IDBFS; see DESIGN → File System & IO →
    /// Web storage model).
    pub fn writeFile(
        self: *const FileSource,
        path: []const u8,
        bytes: []const u8,
    ) !void {
        if (std.mem.startsWith(u8, path, "data/") or std.mem.startsWith(u8, path, "assets/")) {
            @panic("FileSource.writeFile: refused write to shipped path - built-in data/assets are immutable");
        }
        // Same class as the shipped-path refusal above: every write caller
        // is a fixed constant or an already-validated import path, so a
        // path that escapes the content root is a programmer error, not an
        // input problem (see isInvalidRelativePath).
        if (isInvalidRelativePath(path)) {
            @panic("FileSource.writeFile: refused write outside the content root");
        }
        try self.ensureParentDirs(path);
        try self.persistent_dir.writeFile(self.io, .{
            .sub_path = path,
            .data = bytes,
        });
    }

    /// Create intermediate directories in the persistent dir for a file's
    /// parent, as needed (mkdir -p, idempotent). No-op for top-level files.
    fn ensureParentDirs(self: *const FileSource, path: []const u8) !void {
        const dir = std.fs.path.dirname(path) orelse return;
        if (dir.len == 0) return;
        // createDirPath is idempotent (succeeds if the dir already exists), so
        // any error here is a genuine problem (permissions, disk full, etc.) -
        // propagate it rather than silently swallowing.
        try self.persistent_dir.createDirPath(self.io, dir);
    }

    /// One mission in the player's local collection. `id` is the folder
    /// name under `missions/` - for editor-saved and online-downloaded
    /// missions this is `<uuid>_<slug>`; for hand-placed or imported
    /// folders it's whatever the folder is named (all accepted). `path` is
    /// the mission-directory path ("missions/<id>") as `open_editor` /
    /// `start_mission` consume it. `name` is the display name from
    /// mission.txt. `has_custom_assets` is true if the folder contains any
    /// file beyond the known config set (mission.txt / player.txt /
    /// level_*.txt). `author_turns` is the validation run's turn count (the
    /// author medal target), read from the validation replay file's
    /// metadata - null when the mission hasn't been validated (no replay
    /// file). Medal targets (gold/silver/bronze) are DERIVED from
    /// `author_turns` at display time, not stored here.
    pub const MissionEntry = struct {
        id: []const u8,
        path: []const u8,
        name: []const u8,
        level_count: u32,
        has_custom_assets: bool,
        author_turns: ?u32,
        /// The local tab's recency sort key: the MAX mtime across the
        /// mission folder's files - any change (editor save, custom png,
        /// validation replay) counts as an update. 0 for official entries
        /// (embedded content has no filesystem; the Official tab keeps its
        /// comptime order).
        mtime_ns: i128 = 0,
    };

    /// Enumerate the player's local mission collection under `missions/`
    /// in the persistent dir (editor saves land in `missions/<uuid>_<slug>/`;
    /// hand-placed and imported folders of any name are accepted too - the
    /// id is whatever the folder is named). Returns one entry per
    /// subdirectory, with metadata read from each mission's `mission.txt`,
    /// sorted NEWEST FIRST (max folder-file mtime descending - any change
    /// to any file is an update; name ascending breaks mtime ties
    /// deterministically - the load-save browser's ordering).
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
    /// The per-mission work (mission.txt probe + parse + the custom-assets
    /// check) is shared below - the folder scan runs the same
    /// `Dir.iterate` path on every platform (the old IDBFS-era platform
    /// split is gone; see DONE.md "web storage model slice 5").
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
            // read goes through the same layering as gameplay reads - though
            // for local missions it's always the persistent dir).
            const mission_bytes = self.readFile(allocator, mission_txt_path) catch |err| switch (err) {
                // No mission.txt (or unreadable) → skip this folder; it's not
                // an openable mission. `continue` discards the errdefers, so
                // free manually. (On `return err` below the errdefers fire -
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
            // arena - the sections are large and we only keep two duped
            // strings out of them. A full loadMission would also validate
            // file_format_version etc.; for a browser listing we tolerate
            // slightly-malformed missions (show it's there), skipping on
            // parse failure.
            var parse_arena = std.heap.ArenaAllocator.init(allocator);
            defer parse_arena.deinit();
            const pa = parse_arena.allocator();
            const sections = parser.parseConfigFile(mission_bytes, pa, &parser.mission_sections) catch {
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

            // loadMission owns its strings into the throwaway parse arena
            // (which dies below) - dupe the name out of it for the entry.
            const owned_name = try allocator.dupe(u8, mission.name);
            errdefer allocator.free(owned_name);
            allocator.free(mission_bytes);

            // Folder scan: custom-asset detection, the recency stamp (the
            // max file mtime - any change is an update), + the derived
            // level count (the folder's consecutive level files).
            const folder_scan = try self.scanMissionFolder(
                allocator,
                mission_id,
            );

            try entries.append(allocator, .{
                .id = owned_id,
                .path = mission_dir_path,
                .name = owned_name,
                .level_count = folder_scan.level_count,
                .has_custom_assets = folder_scan.has_custom_assets,
                .author_turns = null, // no validation replay format
                .mtime_ns = folder_scan.max_mtime_ns,
            });
        }

        // Newest first (the load-save browser's ordering).
        std.mem.sort(MissionEntry, entries.items, {}, missionOrder);
        return entries.toOwnedSlice(allocator);
    }

    /// The mission FOLDER names under `missions/` (directories only, no
    /// files). A missing missions/ (fresh install) is an empty list, not an
    /// error. The caller owns the returned names + slice.
    fn listMissionFolderNames(
        self: *const FileSource,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
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

    /// One mission folder's scan results for the browser listing: whether
    /// the folder holds anything beyond the known config files
    /// (mission.txt / player.txt / level_<N>.txt), and the recency stamp
    /// (the max mtime across the folder's files - see
    /// `MissionEntry.mtime_ns`). An unreadable folder behaves the same -
    /// the scan never blocks the listing.
    fn scanMissionFolder(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        mission_id: []const u8,
    ) !MissionFolderScan {
        var result: MissionFolderScan = .{};
        const dir_path = try std.fmt.allocPrint(allocator, "missions/{s}", .{mission_id});
        defer allocator.free(dir_path);
        const mission_dir = self.persistent_dir.openDir(self.io, dir_path, .{
            .access_sub_paths = true,
            .iterate = true,
        }) catch return result; // unreadable folder → no custom assets, mtime 0
        defer std.Io.Dir.close(mission_dir, self.io);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(allocator);
        var it = mission_dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind == .directory) continue; // subdirs aren't config files
            names.append(allocator, allocator.dupe(u8, entry.name) catch
                @panic("failed to dupe mission folder entry name")) catch
                @panic("failed to collect mission folder entry name");
            if (!isKnownMissionConfigFile(entry.name)) result.has_custom_assets = true;
            // Stat through the open mission dir by bare name (the
            // save-listing pattern); a stat failure (vanished between
            // iterate + stat) just skips the stamp.
            const stat = mission_dir.statFile(self.io, entry.name, .{}) catch continue;
            result.max_mtime_ns = @max(result.max_mtime_ns, stat.mtime.nanoseconds);
        }
        // The derived level count: consecutive level_1..level_N present.
        // (One pass would track presence per N; the folder is small, so
        // the simple probe over the collected names is clearer.)
        count: while (true) {
            const level_name = std.fmt.allocPrint(allocator, "level_{d}.txt", .{result.level_count + 1}) catch
                @panic("failed to format level probe name");
            defer allocator.free(level_name);
            for (names.items) |name| {
                if (std.mem.eql(u8, name, level_name)) {
                    result.level_count += 1;
                    continue :count;
                }
            }
            break :count;
        }
        for (names.items) |name| allocator.free(name);
        return result;
    }

    /// Enumerate the OFFICIAL missions (shipped embedded campaign content)
    /// for the mission browser's Official tab. The name is parsed from
    /// each mission's embedded mission.txt at call time (the path list is
    /// comptime-known, the parse is not); the level count is comptime-
    /// derived (official_mission_level_counts).
    /// Entries mirror `listMissions` (same `MissionEntry` shape; `id` is the
    /// mission's folder stem, `path` is the embedded dir path exactly as
    /// `open_editor` consumes it). The caller owns the returned slice +
    /// strings (`freeMissions`). A mission whose mission.txt is unreadable
    /// or unparseable is SKIPPED (shouldn't happen for shipped content - an
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

        for (official_mission_dir_paths, 0..) |dir_path, dir_index| {
            const mission_txt_path = try std.fmt.allocPrint(allocator, "{s}/mission.txt", .{dir_path});
            defer allocator.free(mission_txt_path);
            const mission_bytes = self.readEmbeddedFile(allocator, mission_txt_path) catch continue;

            // Throwaway parse arena - same shape as listMissions: keep only
            // the duped id/path/name out of it.
            var parse_arena = std.heap.ArenaAllocator.init(allocator);
            defer parse_arena.deinit();
            const pa = parse_arena.allocator();
            const sections = parser.parseConfigFile(mission_bytes, pa, &parser.mission_sections) catch {
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
            // loadMission borrows into the parse arena - dupe before it dies.
            const name = try allocator.dupe(u8, mission.name);
            errdefer allocator.free(name);
            allocator.free(mission_bytes);

            try entries.append(allocator, .{
                .id = id,
                .path = path,
                .name = name,
                // Comptime-derived (the embedded map's consecutive level
                // files) - see official_mission_level_counts.
                .level_count = official_mission_level_counts[dir_index],
                .has_custom_assets = false,
                .author_turns = null,
            });
        }

        return entries.toOwnedSlice(allocator);
    }

    /// List the save files in saves/ (including the autosave), newest first
    /// (mtime descending; name ascending breaks mtime ties deterministically).
    /// Only `*.txt` files count - the dir is also where stray non-save artifacts
    /// would land. A missing saves/ dir is an empty list (fresh install), not an
    /// error. Caller owns the returned slice + its strings (`freeSaveFiles`).
    pub fn listSaveFiles(
        self: *const FileSource,
        allocator: std.mem.Allocator,
    ) ![]SaveFileEntry {
        var entries: std.ArrayList(SaveFileEntry) = .empty;
        errdefer freeSaveFiles(allocator, entries.items);

        // The one path, every platform: open saves/, iterate, filter .txt,
        // stat each. (The old emscripten platform split - a JS enumeration
        // via a listing temp because IDBFS's readdir was broken - died with
        // the IDBFS mount itself: plain MEMFS readdir works; browser-verified,
        // see DONE.md "web storage model slice 5".)
        const maybe_saves_dir = self.persistent_dir.openDir(self.io, "saves", .{
            .access_sub_paths = true,
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => null, // fresh install: empty list, not an error
            else => return err,
        };
        if (maybe_saves_dir) |saves_dir| {
            defer std.Io.Dir.close(saves_dir, self.io);

            var it = saves_dir.iterate();
            while (try it.next(self.io)) |dir_entry| {
                if (dir_entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, dir_entry.name, ".txt")) continue;

                // Stat through the open saves_dir by bare name - a failure
                // here (vanished between iterate + stat, permissions
                // quirk) skips the entry without having allocated
                // anything for it yet.
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

        std.mem.sort(SaveFileEntry, entries.items, {}, saveFileOrder);
        return entries.toOwnedSlice(allocator);
    }

    /// Delete a file from the persistent dir (used to consume the import
    /// marker). Missing file is an error like any other - callers poll with
    /// `fileExists` first.
    pub fn deleteFile(self: *const FileSource, path: []const u8) !void {
        try self.persistent_dir.deleteFile(self.io, path);
    }

    /// Recursively list every FILE under the persistent dir as
    /// `/`-separated persistent-relative paths - the game-folder zip's
    /// source list (Export Game; see game_zip.zig). Platform-split (the
    /// `Dir.iterate`-is-broken-on-IDBFS story - see `listSaveFiles`):
    /// native walks the tree via `Dir.iterate` recursion; web walks it via
    /// JS (a recursive `FS.lookupPath` pass writing the path list to a
    /// temp listing - the `.saves_listing` pattern at tree scale), then
    /// reads the list back. The staging + listing temps + import markers
    /// (`persistent_dir_artifact_names` - the whole root-artifact set) are
    /// excluded on both platforms: a crashed export's or import's
    /// leftovers must not ride in a later export. Caller owns the returned
    /// slice + strings (free via `freePersistentDirFiles`, or pass a
    /// throwaway arena). Sorted for determinism. Empty when the dir is
    /// empty (a fresh web session).
    pub fn listPersistentDirFiles(
        self: *const FileSource,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        var paths: std.ArrayList([]const u8) = .empty;
        errdefer freePersistentDirFiles(allocator, paths.items);
        // The one path, every platform (the old emscripten JS-walk split
        // died with the IDBFS mount - plain MEMFS readdir works; see
        // DONE.md "web storage model slice 5").
        try collectPersistentDirFiles(self.persistent_dir, self.io, "", allocator, &paths);
        std.mem.sort([]const u8, paths.items, {}, pathOrder);
        return paths.toOwnedSlice(allocator);
    }

    /// `Dir.iterate` recursion. `prefix` is `dir`'s
    /// persistent-relative path ("" at the root).
    fn collectPersistentDirFiles(
        dir: std.Io.Dir,
        io: std.Io,
        prefix: []const u8,
        allocator: std.mem.Allocator,
        paths: *std.ArrayList([]const u8),
    ) anyerror!void {
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (isPersistentDirArtifactName(entry.name)) continue;
            const relative_path = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            switch (entry.kind) {
                .directory => {
                    var sub_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch {
                        allocator.free(relative_path);
                        continue;
                    };
                    defer sub_dir.close(io);
                    defer allocator.free(relative_path);
                    try collectPersistentDirFiles(sub_dir, io, relative_path, allocator, paths);
                },
                .file => try paths.append(allocator, relative_path),
                else => allocator.free(relative_path),
            }
        }
    }
};

/// Free a `listPersistentDirFiles` result.
fn freePersistentDirFiles(allocator: std.mem.Allocator, paths: [][]const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// Deterministic listing order: lexicographic path order.
fn pathOrder(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Every dot-file artifact the game's own machinery stages in the
/// persistent-dir root: the Export/Import Game staging zips, the two listing
/// temps, and the web import markers (each can linger if a browser closed
/// between staging and consumption). None of it is player data, and none of
/// it may ride in an Export Game archive - `listPersistentDirFiles` excludes
/// the whole set on BOTH platforms, both walks deriving from this ONE list
/// so the native + JS filters can never drift apart.
const persistent_dir_artifact_names = [_][]const u8{
    game_export_temp_path,
    game_import_temp_path,
    game_import_marker_path,
    import_marker_path,
    mission_import_marker_path,
};

/// True for a persistent-dir-root artifact name (the staging + marker set -
/// see `persistent_dir_artifact_names`).
fn isPersistentDirArtifactName(name: []const u8) bool {
    for (persistent_dir_artifact_names) |artifact_name| {
        if (std.mem.eql(u8, name, artifact_name)) return true;
    }
    return false;
}

/// Scan a mission folder for files beyond the known config set
/// (mission.txt, player.txt, level_<N>.txt) - anything else is a custom
/// asset (sprites, audio). The ENUMERATION is platform-split (see
/// `FileSource.hasMissionCustomAssets`): native iterates the folder; web
/// uses a JS listing. Both share `isKnownMissionConfigFile`.
/// True if `name` is one of the KNOWN mission config files (mission.txt,
/// player.txt, any well-formed level_<N>.txt with N >= 1) - anything else
/// is a custom asset. Count-free: a level file is config regardless of
/// where the consecutive-from-1 derivation stops (a gapped level_3.txt is
/// a level file, not an asset).
fn isKnownMissionConfigFile(name: []const u8) bool {
    if (std.mem.eql(u8, name, "mission.txt")) return true;
    if (std.mem.eql(u8, name, "player.txt")) return true;
    if (!std.mem.startsWith(u8, name, "level_")) return false;
    if (!std.mem.endsWith(u8, name, ".txt")) return false;
    const digits = name["level_".len .. name.len - ".txt".len];
    if (digits.len == 0) return false;
    const n = std.fmt.parseInt(u32, digits, 10) catch return false;
    return n >= 1;
}

/// One save file in the load-save browser. `path` is persistent-dir
/// relative (what load_save expects); `name` is the bare filename (the
/// browser's display label); `mtime_ns` is the file's last-modified time,
/// the browser's sort key (newest first). Saves are write-once, so mtime
/// is the creation time in practice - Linux commonly doesn't expose a
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
/// slice (`&.{}` from an empty collection) is a no-op - `allocator.free`
/// on an empty slice at a non-owned address would be invalid.
pub fn freeMissions(allocator: std.mem.Allocator, missions: []const FileSource.MissionEntry) void {
    if (missions.len == 0) return;
    for (missions) |entry| freeMissionEntry(allocator, entry);
    allocator.free(missions);
}

/// Newest-first ordering for the mission browser's local tab (the
/// `saveFileOrder` discipline): mtime descending, name ascending as the
/// deterministic tiebreak.
fn missionOrder(_: void, a: FileSource.MissionEntry, b: FileSource.MissionEntry) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// One mission folder's scan results (`FileSource.scanMissionFolder`):
/// custom-asset detection + the recency stamp. Defaults are the degraded
/// results (no custom assets, mtime 0) for unreadable/JS-unsafe folders.
const MissionFolderScan = struct {
    has_custom_assets: bool = false,
    max_mtime_ns: i128 = 0,
    /// DERIVED from the folder's files (never mission.txt - it carries no
    /// count anymore): the largest N with level_1..level_N all present.
    /// Same rule as the runtime probe
    /// (handlers/shared.countMissionLevelsCached) + content_hash's
    /// derivation - three implementations of one rule, cross-referenced.
    level_count: u32 = 0,
};

/// Newest-first ordering: mtime descending, name ascending as the
/// deterministic tiebreak.
fn saveFileOrder(_: void, a: SaveFileEntry, b: SaveFileEntry) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
    return std.mem.lessThan(u8, a.name, b.name);
}

// Web-only: run inline JS at the emscripten seams (browser download /
// upload). The extern is declared here (not gated) because Zig only emits
// a symbol reference when the call site is reachable - and every call site
// lives in comptime-gated emscripten branches, so native (and the headless
// test build) never needs to resolve it.
extern fn emscripten_run_script(script: [*:0]const u8) void;

/// The virtual path where web mounts the in-memory persistent dir
/// (mirrors $HOME/.ziglop on native - an in-memory MEMFS mount; see DESIGN
/// → File System & IO → Web storage model). Single source of truth for
/// the mount (web.zig) and for absolute FS paths in JS seams like
/// `triggerBrowserDownload`.
pub const persistent_mount_path = "/ziglop";

/// Marker file (persistent-dir root) written by the web import JS after the
/// picked save file has landed in saves/. Zig polls it while the load-save
/// browser is open; finding it means "an import completed - load this path".
/// Deleted immediately after reading. Lives OUTSIDE saves/ so the save-list
/// scan never sees it.
pub const import_marker_path = ".import_marker";

/// Marker file (persistent-dir root) written by the web mission-import JS
/// after the picked mission .zip has landed in imported_missions/. Zig polls
/// it while the editor's mission browser is open; finding it means "an import
/// upload completed - extract this zip into missions/". Deleted immediately
/// after reading - same shape as `import_marker_path`.
pub const mission_import_marker_path = ".mission_import_marker";

/// Export Game's archive staging file (persistent-dir root, dot-prefixed
/// so no scan sees it; see game_zip.zig). The persistent-dir listing
/// EXCLUDES it - a crashed export's leftover must not ride in a later
/// export. Deleted after the download reads it.
pub const game_export_temp_path = ".game_export.zip";

/// Import Game's archive staging file (persistent-dir root, dot-prefixed
/// like the export staging temp; see game_zip.zig). The web game-import JS
/// writes the picked ziglop.zip here under this FIXED name, then the import
/// marker so the Zig-side poll picks it up. The persistent-dir listing
/// EXCLUDES it - a leftover must not ride in a later export. Deleted by the
/// import on every exit (the original stays in the player's Downloads).
pub const game_import_temp_path = ".game_import.zip";

/// Marker file (persistent-dir root) written by the web game-import JS
/// after the picked ziglop.zip has landed at `game_import_temp_path`. Zig
/// polls it every frame on web (an import re-boots the session - see
/// DESIGN → File System & IO → Web storage model); finding it means "an
/// Import Game upload completed - overlay this zip onto the persistent
/// dir". The marker body carries the staging zip path. Deleted immediately
/// after reading - same shape as `mission_import_marker_path`.
pub const game_import_marker_path = ".game_import_marker";

/// On web, offer a file from the persistent dir to the player as a browser
/// download (anchor click on a Blob of the file's bytes) under the given
/// download name (the staging path can be a dot-temp the download must not
/// carry). The file must already be written - this reads it back from the
/// emscripten in-memory FS as BINARY (no `{encoding:'utf8'}` - emscripten's
/// utf8 read has C-string semantics: it stops at the FIRST NUL byte, which
/// truncated every downloaded ZIP to its first 5 bytes (`PK\x03\x04\x14`,
/// the header up to the first NUL - the shipped ziglop.zip + mission
/// exports; a binary read is correct for every file, text included) and
/// blobbed as octet-stream). On native this is a no-op (comptime-dead
/// branch), so the extern is never linked outside web builds. `allocator`
/// only backs the script-string formatting.
pub fn triggerBrowserDownload(allocator: std.mem.Allocator, path: []const u8, download_name: []const u8) void {
    if (@import("builtin").target.os.tag == .emscripten) {
        const script_body = std.fmt.allocPrint(
            allocator,
            "(function() {{" ++
                "var data = FS.readFile('{s}/{s}');" ++
                "var blob = new Blob([data], {{type:'application/octet-stream'}});" ++
                "var url = URL.createObjectURL(blob);" ++
                "var a = document.createElement('a');" ++
                "a.href = url;" ++
                "a.download = '{s}';" ++
                "document.body.appendChild(a);" ++
                "a.click();" ++
                "setTimeout(function() {{ URL.revokeObjectURL(url); a.remove(); }}, 1000);" ++
                "}})();",
            .{ persistent_mount_path, path, download_name },
        ) catch @panic("failed to format download script");
        defer allocator.free(script_body);
        const script = allocator.dupeSentinel(u8, script_body, 0) catch @panic("failed to null-terminate download script");
        defer allocator.free(script);
        emscripten_run_script(script);
    }
}

/// On web, open a browser file picker for importing a save: the picked file
/// is written into saves/ under its (sanitized) own name, then the import
/// marker is written so the Zig-side poll picks it up and loads it. The
/// write order (save first, marker second) guarantees the bytes exist when
/// the marker does. Native is a no-op (comptime-dead branch). The filename
/// is sanitized in JS (path-traversal + quote safety) - barebones allowlist.
/// Static script (no per-call formatting), so no allocator needed.
pub fn triggerBrowserUpload() void {
    if (@import("builtin").target.os.tag == .emscripten) {
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
/// `triggerBrowserUpload`. Native is a no-op (comptime-dead branch) -
/// the editor browser never emits the button there, and the ctrl+I
/// binding parses but no-ops (the skip_level discipline).
pub fn triggerBrowserMissionUpload() void {
    if (@import("builtin").target.os.tag == .emscripten) {
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

/// On web, open a browser file picker for Import Game: the picked ziglop.zip
/// (the player's own Export Game archive, or an OS-made zip of an extracted
/// folder) is written at the FIXED staging path (`game_import_temp_path` -
/// the fixed name is what the listing excludes by exact name, and there is
/// no name to sanitize: the staging copy is transient + deleted on every
/// import exit), then the game import marker (body = the staging path, the
/// write-order discipline of the other two markers: staging first, marker
/// second, so the bytes exist when the marker does). The Zig-side poll
/// consumes the marker whenever it lands (see game_zip.zig). Native is a
/// no-op (comptime-dead branch) - the main-menu button that triggers this is
/// web-only (the persistent-dir-path-null signal, the Export Game discipline).
pub fn triggerBrowserGameUpload() void {
    if (@import("builtin").target.os.tag == .emscripten) {
        const script =
            "(function() {" ++
            "var input = document.createElement('input');" ++
            "input.type = 'file';" ++
            "input.accept = '.zip';" ++
            "input.onchange = function() {" ++
            "  var file = input.files[0];" ++
            "  if (!file) return;" ++
            "  var reader = new FileReader();" ++
            "  reader.onload = function() {" ++
            "    FS.writeFile('" ++ persistent_mount_path ++ "/" ++ game_import_temp_path ++ "', new Uint8Array(reader.result));" ++
            "    FS.writeFile('" ++ persistent_mount_path ++ "/" ++ game_import_marker_path ++ "', '" ++ game_import_temp_path ++ "');" ++
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
    file_source.writeFile("missions/skeleton_attack/mission.txt", "Metadata\nfile_format_version 3\nmission_uuid 11111111-1111-1111-1111-111111111111\nname Skeleton Attack\n") catch @panic("w1");
    file_source.writeFile("missions/skeleton_attack/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w2");
    // Sleep between the two missions so their mtimes are strictly ordered
    // (sequential writes can tie within filesystem mtime resolution - the
    // listSaveFiles test's discipline).
    try io.sleep(std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms), .real);

    // Mission 2: UUID_slug folder name, config + a custom sprite (custom assets).
    file_source.writeFile("missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/mission.txt", "Metadata\nfile_format_version 3\nmission_uuid 22222222-2222-2222-2222-222222222222\nname Tree Grove\n") catch @panic("w3");
    file_source.writeFile("missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w4");
    file_source.writeFile("missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/level_2.txt", "Metadata\nfile_format_version 1\n\nLayout\n.!\n") catch @panic("w5");
    file_source.writeFile("missions/a1b2c3d4-e5f6-7890-abcd-ef1234567890_tree_grove/custom_tree.png", "fake png bytes") catch @panic("w6");

    // Mission 3: missing mission.txt - should be SKIPPED.
    file_source.writeFile("missions/broken/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w7");

    const list = try file_source.listMissions(allocator);
    defer freeMissions(allocator, list);

    // Two openable missions (broken one is skipped). The list is sorted
    // NEWEST FIRST - Tree Grove was written after Skeleton Attack, so it
    // leads; find-by-id below still checks each entry's metadata.
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expect(std.mem.startsWith(u8, list[0].id, "a1b2c3d4"));
    try testing.expectEqualStrings("skeleton_attack", list[1].id);
    try testing.expect(list[0].mtime_ns > list[1].mtime_ns);
    try testing.expect(list[1].mtime_ns > 0);

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

test "listMissions: newest first - any file change (custom png) is an update" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-missions-recency";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Alpha saved first, beta second - then a custom png lands in ALPHA's
    // folder. The png is NOT a config file, but it must bump alpha's
    // recency above beta's: the sort key is the max mtime across ALL
    // folder files. Sleeps force distinct stamps (the tie discipline
    // above).
    file_source.writeFile("missions/alpha/mission.txt", "Metadata\nfile_format_version 3\nmission_uuid 33333333-3333-3333-3333-333333333333\nname Alpha\n") catch @panic("w1");
    file_source.writeFile("missions/alpha/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w2");
    try io.sleep(std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms), .real);
    file_source.writeFile("missions/beta/mission.txt", "Metadata\nfile_format_version 3\nmission_uuid 44444444-4444-4444-4444-444444444444\nname Beta\n") catch @panic("w3");
    file_source.writeFile("missions/beta/level_1.txt", "Metadata\nfile_format_version 1\n\nLayout\n!\n") catch @panic("w4");
    try io.sleep(std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms), .real);
    file_source.writeFile("missions/alpha/custom.png", "fake png bytes") catch @panic("w5");

    const list = try file_source.listMissions(allocator);
    defer freeMissions(allocator, list);

    try testing.expectEqual(@as(usize, 2), list.len);
    // Alpha leads: its png write is the most recent change in either
    // folder, even though beta's config files are newer than alpha's.
    try testing.expectEqualStrings("Alpha", list[0].name);
    try testing.expectEqualStrings("Beta", list[1].name);
    try testing.expect(list[0].mtime_ns > list[1].mtime_ns);
    try testing.expect(list[1].mtime_ns > 0);
}

test "missionOrder: mtime descending, name ascending tiebreak" {
    const MissionEntry = FileSource.MissionEntry;
    var entries = [_]MissionEntry{
        .{ .id = "c", .path = "", .name = "Older", .level_count = 1, .has_custom_assets = false, .author_turns = null },
        .{ .id = "a", .path = "", .name = "Beta", .level_count = 1, .has_custom_assets = false, .author_turns = null, .mtime_ns = 100 },
        .{ .id = "b", .path = "", .name = "Alpha", .level_count = 1, .has_custom_assets = false, .author_turns = null, .mtime_ns = 100 },
    };
    std.mem.sort(MissionEntry, &entries, {}, missionOrder);
    // Equal mtimes → name ascending; mtime 0 sorts last.
    try testing.expectEqualStrings("Alpha", entries[0].name);
    try testing.expectEqualStrings("Beta", entries[1].name);
    try testing.expectEqualStrings("Older", entries[2].name);
}

test "listOfficialMissions: the shipped campaign missions with paths + metadata" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, undefined);

    const list = try file_source.listOfficialMissions(allocator);
    defer freeMissions(allocator, list);

    // The four shipped main-campaign missions (fixed shipped content - a
    // missing entry means a broken build, so exact stems are asserted).
    try testing.expectEqual(@as(usize, 4), list.len);
    const expected = [_][]const u8{ "beginnings", "forest", "seatown", "wetlands" };
    for (list, expected) |entry, stem| {
        try testing.expectEqualStrings(stem, entry.id);
        try testing.expect(std.mem.startsWith(
            u8,
            entry.path,
            "campaigns/main_campaign/missions/",
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

// --- tests for readAudioFile ---

test "readAudioFile: embedded .ogg fallback, .wav shadow wins, priority order" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-read-audio-file";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Shadows are hand-dropped files, so they can't go through
    // FileSource.writeFile (it refuses assets/ paths) - write through the
    // raw dir handle, exactly like a player would by hand.
    try dir.createDirPath(io, "assets/audio/sfx");

    // No shadow: the shipped damage sound is served from the embedded map
    // as .ogg (we ship no .wav - that's what makes a .wav-first candidate
    // order safe).
    const embedded = file_source.readAudioFile(allocator, "assets/audio/sfx/damage") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(embedded.bytes);
    try testing.expectEqualStrings(".ogg", embedded.format);
    try testing.expect(embedded.bytes.len > 0);

    // A dropped .wav shadows the shipped .ogg. This is THE case the
    // .wav-first order exists for: the .ogg candidate exists in the
    // embedded map at the same relative path, so an .ogg-first order would
    // always hit the embedded copy and this .wav would never load.
    try dir.writeFile(io, .{ .sub_path = "assets/audio/sfx/damage.wav", .data = "fake wav bytes" });
    const wav = file_source.readAudioFile(allocator, "assets/audio/sfx/damage") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(wav.bytes);
    try testing.expectEqualStrings(".wav", wav.format);
    try testing.expectEqualStrings("fake wav bytes", wav.bytes);

    // Both extensions dropped: .wav keeps priority (deterministic pick).
    try dir.writeFile(io, .{ .sub_path = "assets/audio/sfx/damage.ogg", .data = "fake ogg bytes" });
    const both = file_source.readAudioFile(allocator, "assets/audio/sfx/damage") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(both.bytes);
    try testing.expectEqualStrings(".wav", both.format);
    try testing.expectEqualStrings("fake wav bytes", both.bytes);

    // A .ogg-only shadow still shadows the embedded copy (per-path
    // layering, the plain readFile behavior).
    try dir.writeFile(io, .{ .sub_path = "assets/audio/sfx/move.ogg", .data = "shadowed ogg bytes" });
    const ogg_shadow = file_source.readAudioFile(allocator, "assets/audio/sfx/move") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(ogg_shadow.bytes);
    try testing.expectEqualStrings(".ogg", ogg_shadow.format);
    try testing.expectEqualStrings("shadowed ogg bytes", ogg_shadow.bytes);

    // No candidate in any layer → null (the backend caches silence).
    try testing.expect(file_source.readAudioFile(allocator, "assets/audio/sfx/nonexistent") == null);
}

test "customAssetTail: the segment chain after custom/ is the path (stem or kind-prefixed id)" {
    // Bare stem (config-authored) and kind-prefixed sprite id (render
    // side) both find the custom/ segment - one resolution rule.
    try testing.expectEqualStrings(
        "missions/artists_den/boss",
        customAssetTail("custom/missions/artists_den/boss").?,
    );
    try testing.expectEqualStrings(
        "campaigns/main_campaign/hubs/camp/tree",
        customAssetTail("decorations/custom/campaigns/main_campaign/hubs/camp/tree").?,
    );
    try testing.expectEqualStrings(
        "campaigns/main_campaign/missions/forest/boss",
        customAssetTail("entities/custom/campaigns/main_campaign/missions/forest/boss").?,
    );
    // Non-custom + degenerate shapes.
    try testing.expect(customAssetTail("skeleton_1") == null);
    try testing.expect(customAssetTail("entities/skeleton_1") == null);
    try testing.expect(customAssetTail("custom/") == null);
}

test "customStemForContentPath: mints the tail (data/ stripped) + round-trips customAssetTail" {
    const allocator = testing.allocator;
    // A dream mission dir (already content-root-relative).
    {
        const stem = customStemForContentPath("missions/uuid_Artists Den", "boss", allocator);
        defer allocator.free(stem);
        try testing.expectEqualStrings("custom/missions/uuid_Artists Den/boss", stem);
        try testing.expectEqualStrings("missions/uuid_Artists Den/boss", customAssetTail(stem).?);
    }
    // An embedded (official campaign) dir: the data/ prefix is stripped -
    // the minted tail addresses the embedded copy through readFile's
    // data/-prefixed tier.
    {
        const stem = customStemForContentPath("data/campaigns/main_campaign/hubs/camp", "tree", allocator);
        defer allocator.free(stem);
        try testing.expectEqualStrings("custom/campaigns/main_campaign/hubs/camp/tree", stem);
    }
}

test "readFile: campaign-bundled content resolves through the embedded data/ tier" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    // cwd-backed: the persistent tier misses (no campaigns/ in the repo
    // cwd), so the embedded data/-prefixed tier must serve the bytes.
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    const bytes = try file_source.readFile(allocator, "campaigns/main_campaign/campaign.txt");
    defer allocator.free(bytes);
    try testing.expect(bytes.len > 0);
    try testing.expect(std.mem.indexOf(u8, bytes, "Main Campaign") != null);

    // And the customAssetTail shape addresses the same file: tail + .png
    // is the read path for art; here we prove the tail + extension form
    // resolves against the same tiers with a non-png extension.
    const config_via_tail = try file_source.readFile(allocator, "campaigns/main_campaign/hubs/camp_at_the_crossroads/hub.txt");
    defer allocator.free(config_via_tail);
    try testing.expect(std.mem.indexOf(u8, config_via_tail, "Camp at the Crossroads") != null);

    // A path no tier has still misses cleanly.
    try testing.expectError(error.FileNotFound, file_source.readFile(allocator, "campaigns/nowhere/x.txt"));
}

test "readFile/writeFile: hostile paths are rejected at the seam" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-path-gate";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Every escape shape reads as FileNotFound - including paths that
    // WOULD resolve outside the content root if handed to the dir handle.
    const hostile = [_][]const u8{
        "",
        "/absolute.txt",
        "../escape.txt",
        "missions/../../escape.txt",
        "a/../b",
        "back\\slash.txt",
        "nul\x00byte.txt",
        "double//slash",
        "trailing/",
    };
    for (hostile) |path| {
        try testing.expectError(error.FileNotFound, file_source.readFile(allocator, path));
    }

    // A path with a "." segment is safe (the dir handle resolves it) -
    // the gate must not over-reject.
    try file_source.writeFile("nested/./deeper/file.txt", "content");
    const round_tripped = try file_source.readFile(allocator, "nested/deeper/file.txt");
    defer allocator.free(round_tripped);
    try testing.expectEqualStrings("content", round_tripped);
}
