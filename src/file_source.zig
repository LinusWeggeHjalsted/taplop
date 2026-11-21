//! Unified file I/O for the game. See DESIGN → File System & IO.
//!
//! The game ships as a single-file executable: all `data/` + `assets/` content
//! is embedded at build time (see `generated_assets.zig`, emitted by build.zig).
//! Writable artifacts (saves, session logs) live in a persistent data
//! directory (`~/.local/share/taplop/` on Linux - see persistent_path.zig).
//! Both content reads and artifact
//! reads/writes funnel through this one session-resident `FileSource` so the
//! game never depends on the current working directory.
//!
//! Read order (first hit wins):
//!   1. in-memory VFS - uploaded zips / fetched custom missions (transient;
//!      not wired)
//!   2. persistent dir - `~/.local/share/taplop/<path>`
//!   3. embedded map - `data/**` + `assets/**` baked into the exe
//!
//! Because the persistent dir is checked before the embedded map, a player can
//! drop a file at `~/.local/share/taplop/<shipped-path>` to shadow shipped content - a
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
/// (DONE.md, "FileSource: the relative-path gate at the readFile/writeFile
/// seam" - a must-have before the server seam). Same rule
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
/// (e.g. "campaigns/<campaign>/missions/<mission>") - the mission
/// browser's Official tab, and the shape every campaign-content path uses
/// (the official campaign's bytes resolve through readFile's embedded
/// `data/`-prefix bridge; see DESIGN → Campaigns & the Campaign Editor →
/// Campaign content paths). RUNTIME scan of the embedded map, sorted for
/// a stable browser order - deliberately NOT comptime: comptime-built
/// arrays over the map's key slices mis-materialize on this toolchain
/// (Zig 0.17.1 - elements read back as 0xaa undefined fill in every
/// array/growth shape tried; isolated with an in-file minimal test), while
/// the map's own keys are reliably readable at runtime (every readFile
/// depends on that). Caller owns the slice + every element (free each,
/// then the slice). Mirrors ui/editor_pickers.zig's
/// `official_entity_sprite_stems` comptime scan in purpose.
fn officialMissionDirPaths(allocator: std.mem.Allocator) []const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (dirs.items) |dir| allocator.free(dir);
        dirs.deinit(allocator);
    }
    for (embedded_assets.map.kvs.keys[0..embedded_assets.map.kvs.len]) |key| {
        if (!isOfficialMissionDirKey(key)) continue;
        // Strip the embedded map's `data/` addressing prefix: the dir
        // path is a CONTENT path from here on (readFile/readEmbeddedFile
        // re-add the prefix when they need the embedded key).
        const content_dir = key["data/".len .. key.len - "/mission.txt".len];
        dirs.append(allocator, allocator.dupe(u8, content_dir) catch
            @panic("failed to dupe official mission dir")) catch
            @panic("failed to append official mission dir");
    }
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn before(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.before);
    return dirs.toOwnedSlice(allocator) catch @panic("failed to own official mission dirs");
}

/// One embedded-map key is an official campaign mission dir's mission.txt
/// (data/campaigns/<campaign>/missions/<stem>/mission.txt with single
/// plain campaign + stem segments).
fn isOfficialMissionDirKey(key: []const u8) bool {
    if (!std.mem.startsWith(u8, key, "data/campaigns/")) return false;
    if (!std.mem.endsWith(u8, key, "/mission.txt")) return false;
    const missions_index = std.mem.indexOf(u8, key, "/missions/") orelse return false;
    const campaign = key["data/campaigns/".len..missions_index];
    if (campaign.len == 0 or std.mem.indexOfScalar(u8, campaign, '/') != null) return false;
    const stem = key[missions_index + "/missions/".len .. key.len - "/mission.txt".len];
    if (stem.len == 0 or std.mem.indexOfScalar(u8, stem, '/') != null) return false;
    return true;
}

/// The OFFICIAL missions' level counts, derived from the embedded map at
/// runtime: dir path -> the largest N with level_1..level_N embedded (the
/// same rule as everywhere - a gap truncates). Used by the Official tab;
/// the runtime probe + the persistent scan derive the same rule from
/// their sources.
fn officialMissionLevelCount(dir_path: []const u8) u32 {
    var count: u32 = 0;
    while (true) {
        // 256: the uuid-prefixed campaign mission dirs run long (the
        // 128-byte probe silently truncated to count 0 once the Polpat
        // dir names landed - a bufPrint overflow hits the `catch break`
        // and reads as "no levels").
        var probe_buf: [256]u8 = undefined;
        const probe_path = std.fmt.bufPrint(
            &probe_buf,
            "data/{s}/level_{d}.txt",
            .{ dir_path, count + 1 },
        ) catch break;
        if (embedded_assets.map.get(probe_path) == null) break;
        count += 1;
    }
    return count;
}

/// The embedded map's keys (project-root-relative, `data/`-prefixed for
/// campaign content). The raw comptime list for scans that walk arbitrary
/// embedded subtrees (the hub-dir scan). Returns a RUNTIME slice duped
/// into `allocator` (comptime slices can't be returned as mutable-length
/// runtime slices).
pub fn embeddedMapKeys(allocator: std.mem.Allocator) []const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    for (embedded_assets.map.kvs.keys[0..embedded_assets.map.kvs.len]) |key| {
        keys.append(allocator, key) catch @panic("failed to append embedded key");
    }
    return keys.toOwnedSlice(allocator) catch @panic("failed to own embedded keys");
}

/// The embedded campaign ROOT dirs (content-root-relative,
/// "campaigns/<name>" - campaign roots only, no deeper keys), the
/// campaign-level analog of `officialMissionDirPathsForCampaign`.
/// Runtime slicing of static map keys (the comptime-array gotcha - AGENTS
/// → Zig Gotchas), duped into `allocator` (caller-owned). Derived, never
/// hand-maintained: tests + consumers walk the SHIPPED campaigns without
/// pinning their authored names (AGENTS → machine-walked truth).
pub fn officialCampaignDirs(allocator: std.mem.Allocator) []const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    const keys = embeddedMapKeys(allocator);
    defer allocator.free(keys);
    for (keys) |key| {
        if (!std.mem.startsWith(u8, key, "data/campaigns/")) continue;
        if (!std.mem.endsWith(u8, key, "/campaign.txt")) continue;
        const campaign_dir = key["data/".len .. key.len - "/campaign.txt".len];
        // Campaign roots only: content-root-relative with no slash after
        // the campaigns/ prefix.
        if (!std.mem.startsWith(u8, campaign_dir, "campaigns/")) continue;
        if (std.mem.indexOfScalar(u8, campaign_dir["campaigns/".len..], '/') != null) continue;
        dirs.append(allocator, allocator.dupe(u8, campaign_dir) catch
            @panic("failed to dupe embedded campaign dir")) catch
            @panic("failed to append embedded campaign dir");
    }
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn before(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.before);
    return dirs.toOwnedSlice(allocator) catch @panic("failed to own embedded campaign dirs");
}

/// The embedded campaign's mission dirs under one campaign
/// (content-root-relative), for the embedded tier of mission uuid
/// resolution. Caller-owned.
pub fn officialMissionDirPathsForCampaign(campaign_dir: []const u8, allocator: std.mem.Allocator) []const []const u8 {
    const official_dirs = officialMissionDirPaths(allocator);
    defer {
        for (official_dirs) |dir| allocator.free(dir);
        allocator.free(official_dirs);
    }
    var dirs: std.ArrayList([]const u8) = .empty;
    for (official_dirs) |dir_path| {
        if (!std.mem.startsWith(u8, dir_path, campaign_dir)) continue;
        if (dir_path.len <= campaign_dir.len or dir_path[campaign_dir.len] != '/') continue;
        dirs.append(allocator, allocator.dupe(u8, dir_path) catch
            @panic("failed to dupe embedded mission dir")) catch
            @panic("failed to append embedded mission dir");
    }
    return dirs.toOwnedSlice(allocator) catch @panic("failed to own embedded mission dirs");
}

/// Read just the Metadata `<uuid_key>` value out of a small config file
/// (campaign.txt / hub.txt / mission.txt) - the uuid-resolution probe.
/// Returns null when the file is unreadable/unparsable or carries no such
/// key. Uses a throwaway arena: the returned slice is duped into
/// `allocator` and owns nothing else.
fn readConfigUuid(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    path: []const u8,
    sections: []const []const u8,
    uuid_key: []const u8,
) ?[]const u8 {
    var probe_arena = std.heap.ArenaAllocator.init(allocator);
    defer probe_arena.deinit();
    const bytes = file_source.readFile(probe_arena.allocator(), path) catch return null;
    const parsed = parser.parseConfigFile(bytes, probe_arena.allocator(), sections) catch return null;
    const metadata = parser.findSection(parsed, "Metadata") orelse return null;
    if (metadata.entry_groups.len == 0) return null;
    const value = parser.findValue(metadata.entry_groups[0].pairs, uuid_key) orelse return null;
    return allocator.dupe(u8, value) catch @panic("failed to dupe config uuid");
}

/// One uuid-resolution candidate: a dir + its evidence (the uuid read
/// from its config file + the folder mtime for duplicate tiebreaking).
const UuidDirCandidate = struct {
    dir: []const u8,
    uuid: []const u8,
    mtime_ns: i128,
};

/// The result of a uuid->dir resolution: the winning dir (caller-owned)
/// + whether duplicates were seen (the caller surfaces the warning).
pub const UuidDirResolution = struct {
    dir: []const u8,
    duplicate: bool,
};

/// Resolve a content uuid to its storage dir under one parent (both
/// tiers: the persistent dir +, for campaign content, the embedded map).
/// TIER SHADOWING: a persistent candidate for the uuid makes every
/// embedded candidate UNREACHABLE - FileSource's persistent-first read
/// order means the embedded files can never load - so the embedded tier
/// is skipped entirely and the pair is NOT a duplicate. This is the
/// normal state after a save of official content materializes a
/// persistent copy (and the deliberate hand-installed override path).
/// Duplicate uuids resolve
/// LATEST-MTIME WINS, name-ascending on exact ties (see DESIGN →
/// Campaigns & the Campaign Editor → Uuid→dir resolution). Returns the
/// winning dir (caller-owned) + true when duplicates were seen, so the
/// caller can surface the warning. Null when no candidate matches.
pub fn resolveUuidDir(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    parent: []const u8,
    embedded_dirs: []const []const u8,
    config_name: []const u8,
    sections: []const []const u8,
    uuid_key: []const u8,
    uuid: []const u8,
) ?UuidDirResolution {
    var candidates: std.ArrayList(UuidDirCandidate) = .empty;
    defer {
        for (candidates.items) |candidate| {
            allocator.free(candidate.dir);
            allocator.free(candidate.uuid);
        }
        candidates.deinit(allocator);
    }

    // Tier 1: the persistent dir's subdirs (absent parent dir - fresh
    // install - simply contributes no candidates; the embedded tier
    // below still runs).
    if (file_source.listPersistentDirEntries(allocator, parent) catch null) |entries| {
        defer freePersistentDirEntries(allocator, entries);
        for (entries) |entry| {
            if (entry.kind != .directory) continue;
            const dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, entry.name }) catch
                @panic("failed to build candidate dir");
            defer allocator.free(dir);
            const config_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, config_name }) catch
                @panic("failed to build candidate config path");
            defer allocator.free(config_path);
            const found_uuid = readConfigUuid(file_source, allocator, config_path, sections, uuid_key) orelse continue;
            defer allocator.free(found_uuid);
            if (!std.mem.eql(u8, found_uuid, uuid)) continue;
            const mtime = dirMtime(file_source, allocator, dir);
            candidates.append(allocator, .{
                .dir = allocator.dupe(u8, dir) catch @panic("failed to dupe candidate dir"),
                .uuid = allocator.dupe(u8, found_uuid) catch @panic("failed to dupe candidate uuid"),
                .mtime_ns = mtime,
            }) catch @panic("failed to append candidate");
        }
    }

    // Tier 2: the embedded dirs - SKIPPED when the persistent tier
    // matched this uuid: the persistent copy shadows the embedded
    // original (unreachable through the read order), so it contributes
    // neither a candidate nor a duplicate (see the doc comment above).
    if (candidates.items.len == 0) for (embedded_dirs) |embedded_dir| {
        const config_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ embedded_dir, config_name }) catch
            @panic("failed to build candidate config path");
        defer allocator.free(config_path);
        const found_uuid = readConfigUuid(file_source, allocator, config_path, sections, uuid_key) orelse continue;
        defer allocator.free(found_uuid);
        if (!std.mem.eql(u8, found_uuid, uuid)) continue;
        candidates.append(allocator, .{
            .dir = allocator.dupe(u8, embedded_dir) catch @panic("failed to dupe candidate dir"),
            .uuid = allocator.dupe(u8, found_uuid) catch @panic("failed to dupe candidate uuid"),
            .mtime_ns = 0,
        }) catch @panic("failed to append candidate");
    };

    if (candidates.items.len == 0) return null;

    // Latest mtime wins; name-ascending breaks exact ties. All surviving
    // candidates are same-tier (the shadow rule above), so the duplicate
    // flag is a genuine same-tier collision. Deterministic under all
    // inputs (the settle's requirement).
    var best: usize = 0;
    var index: usize = 1;
    while (index < candidates.items.len) : (index += 1) {
        const better = candidates.items[index].mtime_ns > candidates.items[best].mtime_ns or
            (candidates.items[index].mtime_ns == candidates.items[best].mtime_ns and
                std.mem.lessThan(u8, candidates.items[index].dir, candidates.items[best].dir));
        if (better) best = index;
    }
    const winner = candidates.items[best];
    return .{
        .dir = allocator.dupe(u8, winner.dir) catch @panic("failed to dupe resolved dir"),
        .duplicate = candidates.items.len > 1,
    };
}

/// Move a content entry (a mission/campaign DIRECTORY, or a save FILE)
/// into `deleted/<kind>/` with a deletion timestamp appended to its name -
/// the browser delete button. As far as the game is concerned the entry is
/// GONE: no scan ever touches `deleted/` (the lists iterate `missions/`,
/// `campaigns/`, `saves/` specifically), so it disappears from every
/// browser - but the player can recover it by hand (move it back, strip
/// the stamp). The stamp (the session-log format, UTC) prevents same-name
/// collisions; a same-second collision appends a counter. A FILE name's
/// extension stays last ("autosave_20261117_122233.txt" - the id stays
/// recognizable). `kind_dir` is the entry's owning dir ("missions" /
/// "campaigns" / "saves"); `name` is the entry's own file/dir name within
/// it. The `deleted/<kind>/` tree is created as needed; the move is a
/// rename inside the persistent dir (atomic on native, plain MEMFS on
/// web - same semantics).
pub fn moveEntryToDeleted(
    self: *const FileSource,
    allocator: std.mem.Allocator,
    kind_dir: []const u8,
    name: []const u8,
) !void {
    const session_log = @import("session_log.zig");
    const stamp = session_log.formatSessionTimestamp(allocator, self.io);
    defer allocator.free(stamp);

    // Split the extension so the stamp lands before it (files only -
    // directory names carry no extension by convention).
    const extension = std.fs.path.extension(name);
    const stem = name[0 .. name.len - extension.len];

    const deleted_kind_path = std.fmt.allocPrint(allocator, "deleted/{s}", .{kind_dir}) catch
        @panic("failed to allocate deleted kind path");
    defer allocator.free(deleted_kind_path);
    try self.persistent_dir.createDirPath(self.io, deleted_kind_path);

    // Candidate targets: "<stem>_<stamp><extension>", then _2, _3... on a
    // same-second collision. Existence is CHECKED FIRST: POSIX rename
    // silently overwrites a same-named FILE (and an empty dir) instead of
    // erroring, so the stat check is the only collision gate (the game is
    // single-threaded here - no concurrent deletes can race it).
    const source_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ kind_dir, name }) catch
        @panic("failed to allocate delete source path");
    defer allocator.free(source_path);

    var counter: usize = 0;
    while (counter < 100) : (counter += 1) {
        const counter_suffix: []const u8 = if (counter == 0)
            ""
        else
            std.fmt.allocPrint(allocator, "_{d}", .{counter + 1}) catch
                @panic("failed to allocate delete counter suffix");
        defer if (counter_suffix.len > 0) allocator.free(counter_suffix);

        const target_name = std.fmt.allocPrint(allocator, "{s}_{s}{s}{s}", .{ stem, stamp, counter_suffix, extension }) catch
            @panic("failed to allocate deleted target name");
        defer allocator.free(target_name);
        const target_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ deleted_kind_path, target_name }) catch
            @panic("failed to allocate deleted target path");
        defer allocator.free(target_path);

        const stat = self.persistent_dir.statFile(self.io, target_path, .{});
        if (stat) |_| {
            // Taken (same-second delete of an identically-named entry):
            // the next counter.
            continue;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        try self.persistent_dir.rename(source_path, self.persistent_dir, target_path, self.io);
        return;
    }
    return error.PathAlreadyExists;
}

/// Does a file exist in the persistent tier (the player's dir) at this
/// content-relative path? The editor saves' ORIGIN CHECK: content whose
/// files exist only in the embedded map is OFFICIAL - saving it forks
/// (a fresh identity + a new dir) instead of writing a persistent copy
/// that shadows the shipped original.
pub fn persistentFileExists(file_source: *const FileSource, path: []const u8) bool {
    if (isInvalidRelativePath(path)) return false;
    _ = file_source.persistent_dir.statFile(file_source.io, path, .{}) catch return false;
    return true;
}

/// The max mtime across a dir's direct file entries (the duplicate-
/// resolution recency stamp - any change to any file is an update). An
/// unreadable dir reports 0. Pub: the campaign load's scans share the
/// stamp.
pub fn dirMtime(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    dir: []const u8,
) i128 {
    const entries = file_source.listPersistentDirEntries(allocator, dir) catch return 0;
    defer freePersistentDirEntries(allocator, entries);
    var max_mtime: i128 = 0;
    for (entries) |entry| {
        if (entry.kind == .directory) continue;
        const relative_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name }) catch
            @panic("failed to build stat path");
        defer allocator.free(relative_path);
        const stat = file_source.persistent_dir.statFile(file_source.io, relative_path, .{}) catch
            continue;
        max_mtime = @max(max_mtime, stat.mtime.nanoseconds);
    }
    return max_mtime;
}

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
    // The persistent data directory (~/.local/share/taplop/). All writes land here, and
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
            if (embedded_assets.map.get(embedded_key)) |bytes2| {
                return allocator.dupe(u8, bytes2) catch @panic("failed to dupe embedded file bytes");
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
        const dir_entries = try self.listPersistentDirEntries(allocator, dir_path);
        defer freePersistentDirEntries(allocator, dir_entries);
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }
        for (dir_entries) |dir_entry| {
            if (dir_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, dir_entry.name, ".png")) continue;
            try names.append(allocator, try allocator.dupe(u8, dir_entry.name));
        }
        const SortContext = struct {
            fn lessThan(_: void, first: []const u8, second: []const u8) bool {
                return std.mem.lessThan(u8, first, second);
            }
        };
        std.mem.sort([]const u8, names.items, {}, SortContext.lessThan);
        return names.toOwnedSlice(allocator);
    }

    /// Direct-file names of one content dir, BOTH read tiers unioned
    /// (persistent-dir iterate + embedded `data/<dir>/` map scan - the
    /// same two tiers `readFile` resolves between, so every name listed
    /// here reads back through `readFile`). Subdirectories are not
    /// listed (a subdir's files belong to their own dir listing); a name
    /// present in both tiers appears once (its bytes resolve
    /// persistent-first, exactly as `readFile` does). Sorted
    /// lexicographically. The names are caller-owned (free each + the
    /// slice). A dir absent from the persistent tier lists the embedded
    /// tier alone; absent from both, it lists empty.
    pub fn listDirFiles(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        dir_path: []const u8,
    ) ![][]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }

        // Tier 1: the persistent dir's direct files.
        if (self.listPersistentDirEntries(allocator, dir_path)) |dir_entries| {
            defer freePersistentDirEntries(allocator, dir_entries);
            for (dir_entries) |dir_entry| {
                if (dir_entry.kind == .directory) continue;
                try names.append(allocator, try allocator.dupe(u8, dir_entry.name));
            }
        } else |list_error| switch (list_error) {
            error.FileNotFound => {},
            else => return list_error,
        }

        // Tier 2: the embedded map's direct files under data/<dir_path>/.
        // The keys slice is owned (the elements are static map keys -
        // runtime slicing, never comptime arrays over them; see AGENTS →
        // Zig Gotchas).
        const keys = embeddedMapKeys(allocator);
        defer allocator.free(keys);
        const embedded_prefix = std.fmt.allocPrint(allocator, "data/{s}/", .{dir_path}) catch
            @panic("failed to build embedded dir listing prefix");
        defer allocator.free(embedded_prefix);
        for (keys) |key| {
            if (!std.mem.startsWith(u8, key, embedded_prefix)) continue;
            const file_name = key[embedded_prefix.len..];
            if (std.mem.indexOfScalar(u8, file_name, '/') != null) continue;
            var already_listed = false;
            for (names.items) |existing| {
                if (std.mem.eql(u8, existing, file_name)) {
                    already_listed = true;
                    break;
                }
            }
            if (already_listed) continue;
            try names.append(allocator, try allocator.dupe(u8, file_name));
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
    /// Rename a directory within the persistent dir (the campaign
    /// editor's cosmetic dir tidy + the future rename seams). Both paths
    /// are content-root-relative; the target must not already exist (the
    /// callers check - a collision keeps the old name + warns instead).
    pub fn renameDir(
        self: *const FileSource,
        old_path: []const u8,
        new_path: []const u8,
    ) !void {
        try self.persistent_dir.rename(old_path, self.persistent_dir, new_path, self.io);
    }

    /// Delete a directory tree within the persistent dir (the campaign
    /// save's explicit-deletion reconciliation - directory-level, never
    /// per-file: readFile's per-file persistent-then-embedded fallback
    /// would resurrect a deleted single file from the embedded campaign
    /// while its dir lingered). A missing dir is a no-op (an unsaved
    /// fresh entry's dir never existed).
    pub fn deleteDir(
        self: *const FileSource,
        path: []const u8,
    ) !void {
        try self.persistent_dir.deleteTree(self.io, path);
    }

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

    /// One campaign in the player's local collection (the campaign
    /// browser's Local tab - the MissionEntry pattern). `dir` is the
    /// campaign's content-root-relative dir ("campaigns/<id>") as the
    /// graph-derivation loader consumes it; `uuid` + `name` come from its
    /// campaign.txt Metadata. No mtime/custom-asset/level-count fields:
    /// campaigns are a short list of worlds, not a browsable collection
    /// (the picker rows show the name alone - add fields when a surface
    /// needs them).
    pub const CampaignEntry = struct {
        uuid: []const u8,
        dir: []const u8,
        name: []const u8,
        /// The local tab's recency sort key (the MissionEntry discipline):
        /// the MAX mtime across the campaign folder's files - any change
        /// (campaign.txt, a hub, a mission) counts as an update. 0 for
        /// official entries (embedded content has no filesystem; the
        /// Official tab keeps its name order).
        mtime_ns: i128 = 0,
    };

    /// Enumerate the player's local campaigns under `campaigns/` in the
    /// persistent dir (the listMissions pattern). Returns one entry per
    /// subdirectory with a readable campaign.txt (name + campaign_uuid
    /// parsed in a throwaway arena; folders without one are SKIPPED - a
    /// half-installed campaign is not viewable). Sorted NEWEST FIRST (max
    /// folder-file mtime descending - the mission list's recency
    /// discipline, so every browser list agrees on one order). The caller owns the returned slice + all
    /// strings (free via `freeCampaigns`).
    pub fn listCampaigns(
        self: *const FileSource,
        allocator: std.mem.Allocator,
    ) ![]CampaignEntry {
        const campaign_ids = try self.listRootSubfolders(allocator, "campaigns");
        defer {
            for (campaign_ids) |id| allocator.free(id);
            allocator.free(campaign_ids);
        }

        var entries: std.ArrayList(CampaignEntry) = .empty;
        errdefer {
            for (entries.items) |entry| freeCampaignEntry(allocator, entry);
            entries.deinit(allocator);
        }

        for (campaign_ids) |campaign_id| {
            const entry = probeCampaignDir(self, allocator, "campaigns", campaign_id) orelse continue;
            errdefer freeCampaignEntry(allocator, entry);
            try entries.append(allocator, entry);
        }

        std.mem.sort(CampaignEntry, entries.items, {}, campaignEntryOrder);
        return entries.toOwnedSlice(allocator);
    }

    /// Enumerate the OFFICIAL campaigns (shipped embedded content) for the
    /// campaign browser's Official tab: every `data/campaigns/<campaign>/
    /// campaign.txt` in the embedded map (the runtime key scan -
    /// `officialMissionDirPaths`'s comptime-array avoidance), name + uuid
    /// parsed from the embedded bytes. The caller owns the returned slice +
    /// strings (free via `freeCampaigns`). A campaign whose campaign.txt is
    /// unreadable or unparseable is SKIPPED (shouldn't happen for shipped
    /// content - an absent row means a broken build).
    pub fn listOfficialCampaigns(
        self: *const FileSource,
        allocator: std.mem.Allocator,
    ) ![]CampaignEntry {
        var entries: std.ArrayList(CampaignEntry) = .empty;
        errdefer {
            for (entries.items) |entry| freeCampaignEntry(allocator, entry);
            entries.deinit(allocator);
        }

        for (embedded_assets.map.kvs.keys[0..embedded_assets.map.kvs.len]) |key| {
            if (!isOfficialCampaignKey(key)) continue;
            const content_dir = key["data/".len .. key.len - "/campaign.txt".len];
            const campaign_bytes = self.readEmbeddedFile(allocator, key) catch continue;
            defer allocator.free(campaign_bytes);
            const entry = parseCampaignEntry(allocator, campaign_bytes, content_dir) orelse continue;
            errdefer freeCampaignEntry(allocator, entry);
            try entries.append(allocator, entry);
        }

        std.mem.sort(CampaignEntry, entries.items, {}, campaignEntryOrder);
        return entries.toOwnedSlice(allocator);
    }

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
        const mission_ids = try self.listRootSubfolders(allocator, "missions");
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

    /// The subfolder names under a persistent root (`missions/`,
    /// `campaigns/` - directories only, no files). A missing root (fresh
    /// install) is an empty list, not an error. The caller owns the
    /// returned names + slice.
    fn listRootSubfolders(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        root_name: []const u8,
    ) ![][]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }
        const dir_entries = self.listPersistentDirEntries(allocator, root_name) catch |err| switch (err) {
            error.FileNotFound => return names.toOwnedSlice(allocator),
            else => return err,
        };
        defer freePersistentDirEntries(allocator, dir_entries);
        for (dir_entries) |dir_entry| {
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
        const dir_entries = self.listPersistentDirEntries(allocator, dir_path) catch
            return result; // unreadable folder → no custom assets, mtime 0
        defer freePersistentDirEntries(allocator, dir_entries);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(allocator);
        for (dir_entries) |entry| {
            if (entry.kind == .directory) continue; // subdirs aren't config files
            names.append(allocator, allocator.dupe(u8, entry.name) catch
                @panic("failed to dupe mission folder entry name")) catch
                @panic("failed to collect mission folder entry name");
            if (!isKnownMissionConfigFile(entry.name)) result.has_custom_assets = true;
            // Stat by full persistent-relative path; a stat failure
            // (vanished between listing + stat) just skips the stamp.
            const stat_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch
                @panic("failed to build mission stat path");
            defer allocator.free(stat_path);
            const stat = self.persistent_dir.statFile(self.io, stat_path, .{}) catch continue;
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

        const official_dirs = officialMissionDirPaths(allocator);
        defer {
            for (official_dirs) |dir| allocator.free(dir);
            allocator.free(official_dirs);
        }
        for (official_dirs) |dir_path| {
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
                // Derived from the embedded map's consecutive level files
                // (the same rule as everywhere - see
                // officialMissionLevelCount).
                .level_count = officialMissionLevelCount(dir_path),
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

        // The one seam, every platform: list saves/, filter .txt, stat
        // each. A missing saves/ dir is a fresh install - empty list, not
        // an error. (The listing itself goes through
        // `listPersistentDirEntries`: on web, `std.Io.Dir.iterate` is
        // unimplemented in Zig 0.17's Io dispatch - the seam's libc arm
        // is what makes the save browser work there at all.)
        const maybe_save_entries = self.listPersistentDirEntries(allocator, "saves") catch |err| switch (err) {
            error.FileNotFound => null, // fresh install: empty list, not an error
            else => return err,
        };
        if (maybe_save_entries) |save_entries| {
            defer freePersistentDirEntries(allocator, save_entries);

            for (save_entries) |dir_entry| {
                if (dir_entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, dir_entry.name, ".txt")) continue;

                // Stat by full persistent-relative path - a failure here
                // (vanished between listing + stat, permissions quirk)
                // skips the entry without having allocated anything for
                // it yet.
                const relative_path = try std.fmt.allocPrint(allocator, "saves/{s}", .{dir_entry.name});
                const stat = self.persistent_dir.statFile(self.io, relative_path, .{}) catch {
                    allocator.free(relative_path);
                    continue;
                };

                const name = try allocator.dupe(u8, dir_entry.name);
                errdefer allocator.free(name);
                errdefer allocator.free(relative_path);
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

    /// One directory's direct entries (name + kind) - the listing seam
    /// every persistent-dir walk goes through (the save scan, the
    /// mission/campaign folder scans, the Export Game tree walk).
    /// Comptime-split by necessity: Zig 0.17's `std.Io.Threaded` dirRead
    /// dispatch has no `.emscripten` arm (it falls to
    /// `dirReadUnimplemented`), so `std.Io.Dir.iterate` returns
    /// `error.Unexpected` on web; every other platform keeps the std.Io
    /// walk unchanged, emscripten walks libc opendir/readdir through the
    /// in-memory mount (std.c.dirent covers emscripten). `dir_path` is
    /// persistent-dir-relative ("" = the root). A missing dir is
    /// `error.FileNotFound`, the openDir convention callers already
    /// switch on. Names are caller-owned dupes (free via
    /// `freePersistentDirEntries`); order is the OS's readdir order, same
    /// as the underlying iterators - callers that need determinism sort,
    /// as they always have.
    pub fn listPersistentDirEntries(
        self: *const FileSource,
        allocator: std.mem.Allocator,
        dir_path: []const u8,
    ) anyerror![]DirEntryInfo {
        if (comptime @import("builtin").target.os.tag == .emscripten) {
            // <mount>[/<dir_path>] - the in-memory persistent mount.
            if (dir_path.len == 0) return listDirEntriesLibc(allocator, persistent_mount_path);
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
                persistent_mount_path,
                dir_path,
            });
            defer allocator.free(full_path);
            return listDirEntriesLibc(allocator, full_path);
        }
        var dir: std.Io.Dir = undefined;
        var dir_is_owned = false;
        if (dir_path.len == 0) {
            // The root: the session's own handle (opened with iteration
            // capability by both entry files) - never closed here.
            dir = self.persistent_dir;
        } else {
            dir = try self.persistent_dir.openDir(self.io, dir_path, .{
                .access_sub_paths = true,
                .iterate = true,
            });
            dir_is_owned = true;
        }
        defer if (dir_is_owned) std.Io.Dir.close(dir, self.io);
        var entries: std.ArrayList(DirEntryInfo) = .empty;
        errdefer freePersistentDirEntries(allocator, entries.items);
        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |dir_entry| {
            try entries.append(allocator, .{
                .name = try allocator.dupe(u8, dir_entry.name),
                .kind = dirEntryKindFromFileKind(dir_entry.kind),
            });
        }
        return entries.toOwnedSlice(allocator);
    }

    /// Recursively list every FILE under the persistent dir as
    /// `/`-separated persistent-relative paths - the game-folder zip's
    /// source list (Export Game; see game_zip.zig). The per-level listing
    /// goes through `listPersistentDirEntries` (the platform seam: on web,
    /// `std.Io.Dir.iterate` is unimplemented in Zig 0.17's Io dispatch).
    /// The staging zips + import markers
    /// (`persistent_dir_artifact_names` - the whole root-artifact set) are
    /// excluded: a crashed export's or import's leftovers must not ride in
    /// a later export. Caller owns the returned
    /// slice + strings (free via `freePersistentDirFiles`, or pass a
    /// throwaway arena). Sorted for determinism. Empty when the dir is
    /// empty (a fresh web session).
    pub fn listPersistentDirFiles(
        self: *const FileSource,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        var paths: std.ArrayList([]const u8) = .empty;
        errdefer freePersistentDirFiles(allocator, paths.items);
        // The root call propagates listing failures (an unlistable game
        // folder fails the export with the recoverable popup); recursion
        // below skips unreadable subtrees instead.
        try collectPersistentDirFiles(self, "", allocator, &paths);
        std.mem.sort([]const u8, paths.items, {}, pathOrder);
        return paths.toOwnedSlice(allocator);
    }

    /// `listPersistentDirEntries` recursion. `prefix` is the directory's
    /// persistent-relative path ("" at the root). An unreadable SUBTREE is
    /// skipped (an export lists what it can); only the root call's
    /// failures propagate to the caller.
    fn collectPersistentDirFiles(
        file_source: *const FileSource,
        prefix: []const u8,
        allocator: std.mem.Allocator,
        paths: *std.ArrayList([]const u8),
    ) anyerror!void {
        const entries = try file_source.listPersistentDirEntries(allocator, prefix);
        defer freePersistentDirEntries(allocator, entries);
        for (entries) |entry| {
            if (isPersistentDirArtifactName(entry.name)) continue;
            const relative_path = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            switch (entry.kind) {
                .directory => {
                    collectPersistentDirFiles(file_source, relative_path, allocator, paths) catch {
                        allocator.free(relative_path);
                        continue;
                    };
                    allocator.free(relative_path);
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

/// A directory entry's coarse kind, as the listing sites filter on it.
/// Symlinks are their own arm (never followed by a listing) so a walker
/// can decide; `other` covers everything a listing site skips today
/// (sockets, fifos, unknown - MEMFS reports DT_UNKNOWN when a filesystem
/// does not fill d_type).
pub const DirEntryKind = enum { file, directory, symlink, other };

/// One entry of a `listPersistentDirEntries` listing. `name` is a
/// caller-owned dupe (freed by `freePersistentDirEntries`).
pub const DirEntryInfo = struct {
    name: []const u8,
    kind: DirEntryKind,
};

/// Free a `listPersistentDirEntries` result (each entry's name + the
/// slice).
pub fn freePersistentDirEntries(allocator: std.mem.Allocator, entries: []DirEntryInfo) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

/// The native listing arm's kind mapping (`std.Io.File.Kind` -> the seam's
/// coarse kind).
fn dirEntryKindFromFileKind(kind: std.Io.File.Kind) DirEntryKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        else => .other,
    };
}

/// The emscripten listing arm: libc opendir/readdir over a FULL path.
/// Free-standing (the path, not the FileSource) so the test build drives
/// it directly against a scratch dir - comptime-selected for emscripten,
/// but its logic is plain POSIX and covered natively. The d_type values
/// are the POSIX constants (shared by `std.os.linux.DT`, the namespace
/// emscripten builds against).
fn listDirEntriesLibc(
    allocator: std.mem.Allocator,
    path: []const u8,
) anyerror![]DirEntryInfo {
    const DT = std.os.linux.DT;
    var path_buffer: [std.posix.PATH_MAX + 1]u8 = undefined;
    const path_z = std.mem.printSentinel(&path_buffer, "{s}", .{path}, 0) catch
        return error.NameTooLong;
    const dir_handle = std.c.opendir(path_z.ptr) orelse {
        const errno = std.posix.errno(-1);
        return switch (errno) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            else => error.Unexpected,
        };
    };
    defer _ = std.c.closedir(dir_handle);
    var entries: std.ArrayList(DirEntryInfo) = .empty;
    errdefer freePersistentDirEntries(allocator, entries.items);
    while (std.c.readdir(dir_handle)) |dirent| {
        const name = std.mem.sliceTo(&dirent.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const kind: DirEntryKind = switch (dirent.type) {
            DT.REG => .file,
            DT.DIR => .directory,
            DT.LNK => .symlink,
            else => .other,
        };
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .kind = kind,
        });
    }
    return entries.toOwnedSlice(allocator);
}

/// Free a `listDirFiles` result (each owned name + the slice).
pub fn freeDirFiles(allocator: std.mem.Allocator, files: [][]const u8) void {
    for (files) |file| allocator.free(file);
    allocator.free(files);
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

/// Free one `FileSource.CampaignEntry`'s strings (not the entry itself).
fn freeCampaignEntry(allocator: std.mem.Allocator, entry: FileSource.CampaignEntry) void {
    allocator.free(entry.uuid);
    allocator.free(entry.dir);
    allocator.free(entry.name);
}

/// Free a slice returned by `FileSource.listCampaigns` or
/// `FileSource.listOfficialCampaigns` (entries + strings). A zero-length
/// slice is a no-op (the freeMissions rule).
pub fn freeCampaigns(allocator: std.mem.Allocator, campaigns: []const FileSource.CampaignEntry) void {
    if (campaigns.len == 0) return;
    for (campaigns) |entry| freeCampaignEntry(allocator, entry);
    allocator.free(campaigns);
}

/// Newest-first ordering for the campaign browser's local tab (the
/// `missionOrder` discipline): mtime descending, name ascending as the
/// deterministic tiebreak. Official entries carry mtime 0 - all equal, so
/// the tiebreak keeps their name order.
fn campaignEntryOrder(_: void, a: FileSource.CampaignEntry, b: FileSource.CampaignEntry) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// One embedded-map key is an official campaign's campaign.txt
/// (data/campaigns/<campaign>/campaign.txt with a single plain campaign
/// segment - missions live deeper, under /missions/).
fn isOfficialCampaignKey(key: []const u8) bool {
    if (!std.mem.startsWith(u8, key, "data/campaigns/")) return false;
    if (!std.mem.endsWith(u8, key, "/campaign.txt")) return false;
    const campaign = key["data/campaigns/".len .. key.len - "/campaign.txt".len];
    return campaign.len > 0 and std.mem.indexOfScalar(u8, campaign, '/') == null;
}

/// Parse one campaign.txt into a browser entry: name + campaign_uuid from
/// its Metadata (a missing name falls back to the dir stem - the row needs
/// SOMETHING to show; a missing uuid stays empty - viewing scopes the
/// discovered groups by uuid, and an empty one simply matches nothing). A
/// campaign.txt that doesn't parse as the campaign format is NOT a
/// viewable campaign: null. `content_dir` is borrowed (duped into the
/// entry); `campaign_bytes` is borrowed (parsed in a throwaway arena).
fn parseCampaignEntry(
    allocator: std.mem.Allocator,
    campaign_bytes: []const u8,
    content_dir: []const u8,
) ?FileSource.CampaignEntry {
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const pa = parse_arena.allocator();
    const sections = parser.parseConfigFile(campaign_bytes, pa, &parser.campaign_sections) catch return null;

    var name: []const u8 = std.fs.path.basename(content_dir);
    var uuid: []const u8 = "";
    if (parser.findSection(sections, "Metadata")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (parser.findValue(pairs, "name")) |value| {
                if (value.len > 0) name = value;
            }
            if (parser.findValue(pairs, "campaign_uuid")) |value| uuid = value;
        }
    }

    return .{
        .uuid = allocator.dupe(u8, uuid) catch @panic("failed to dupe campaign uuid"),
        .dir = allocator.dupe(u8, content_dir) catch @panic("failed to dupe campaign dir"),
        .name = allocator.dupe(u8, name) catch @panic("failed to dupe campaign name"),
    };
}

/// Probe one persistent-root subfolder for a viewable campaign: reads
/// `<root>/<id>/campaign.txt` (readFile - persistent-first, so the entry
/// reflects the LOCAL copy even when an embedded campaign shares the
/// path) and parses it. No campaign.txt (or an unparseable one) is not a
/// viewable campaign: null. The entry OWNS its `dir`
/// ("<root>/<id>", content-root-relative - the graph-derivation
/// loader's addressing).
fn probeCampaignDir(
    self: *const FileSource,
    allocator: std.mem.Allocator,
    root: []const u8,
    id: []const u8,
) ?FileSource.CampaignEntry {
    const campaign_txt_path = std.fmt.allocPrint(allocator, "{s}/{s}/campaign.txt", .{ root, id }) catch
        @panic("failed to allocate campaign.txt path");
    defer allocator.free(campaign_txt_path);
    const campaign_bytes = self.readFile(allocator, campaign_txt_path) catch return null;
    defer allocator.free(campaign_bytes);

    const content_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, id }) catch
        @panic("failed to allocate campaign dir path");
    defer allocator.free(content_dir);
    var entry = parseCampaignEntry(allocator, campaign_bytes, content_dir) orelse return null;
    // The recency stamp rides the entry (the browser lists sort newest
    // first - the MissionEntry discipline).
    entry.mtime_ns = dirMtime(self, allocator, content_dir);
    return entry;
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
/// (mirrors the native per-OS default - persistent_path.zig - as an
/// in-memory MEMFS mount; see DESIGN → File System & IO → Web storage
/// model). Single source of truth for
/// the mount (web.zig) and for absolute FS paths in JS seams like
/// `triggerBrowserDownload`.
pub const persistent_mount_path = "/taplop";

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
/// writes the picked taplop.zip here under this FIXED name, then the import
/// marker so the Zig-side poll picks it up. The persistent-dir listing
/// EXCLUDES it - a leftover must not ride in a later export. Deleted by the
/// import on every exit (the original stays in the player's Downloads).
pub const game_import_temp_path = ".game_import.zip";

/// Marker file (persistent-dir root) written by the web game-import JS
/// after the picked taplop.zip has landed at `game_import_temp_path`. Zig
/// polls it every frame on web (an import re-boots the session - see
/// DESIGN → File System & IO → Web storage model); finding it means "an
/// Import Game upload completed - overlay this zip onto the persistent
/// dir". The marker body carries the staging zip path. Deleted immediately
/// after reading - same shape as `mission_import_marker_path`.
pub const game_import_marker_path = ".game_import_marker";

/// After reading - same shape as `mission_import_marker_path`, for the
/// campaign import: the picked campaign .zip lands in
/// `imported_campaigns/` and this marker names it (the Zig side polls
/// the marker, deletes it, and extracts the zip into campaigns/ - see
/// campaign_editor/io.zig's pollCampaignImportMarker).
pub const campaign_import_marker_path = ".campaign_import_marker";

/// On web, offer a file from the persistent dir to the player as a browser
/// download (anchor click on a Blob of the file's bytes) under the given
/// download name (the staging path can be a dot-temp the download must not
/// carry). The file must already be written - this reads it back from the
/// emscripten in-memory FS as BINARY (no `{encoding:'utf8'}` - emscripten's
/// utf8 read has C-string semantics: it stops at the FIRST NUL byte, which
/// truncated every downloaded ZIP to its first 5 bytes (`PK\x03\x04\x14`,
/// the header up to the first NUL - the shipped taplop.zip + mission
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

/// On web, open a browser file picker for a CAMPAIGN .zip (both campaign
/// browsers' Import button): the picked zip is written into
/// imported_campaigns/ under its (sanitized) file name + the campaign
/// import marker names it. Mirrors `triggerBrowserMissionUpload` exactly.
/// Comptime-dead on native (the button is never emitted there).
pub fn triggerBrowserCampaignUpload() void {
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
            "    FS.mkdirTree('" ++ persistent_mount_path ++ "/imported_campaigns');" ++
            "    FS.writeFile('" ++ persistent_mount_path ++ "/imported_campaigns/' + name, new Uint8Array(reader.result));" ++
            "    FS.writeFile('" ++ persistent_mount_path ++ "/" ++ campaign_import_marker_path ++ "', 'imported_campaigns/' + name);" ++
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

/// On web, open a browser file picker for Import Game: the picked taplop.zip
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

test "listPersistentDirEntries: names + kinds + missing-dir convention (both arms)" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-dir-entries";
    std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch return error.TestUnexpectedError;
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" }) catch return error.TestUnexpectedError;
    dir.createDirPath(io, "nested") catch return error.TestUnexpectedError;
    dir.writeFile(io, .{ .sub_path = "nested/b.txt", .data = "b" }) catch return error.TestUnexpectedError;
    const file_source = FileSource.init(io, dir);

    // The seam (the native arm under the test build; the platform split
    // is comptime). The root listing ("" - the session handle, not an
    // openDir) and a subdirectory listing.
    const root_entries = try file_source.listPersistentDirEntries(allocator, "");
    defer freePersistentDirEntries(allocator, root_entries);
    var saw_file = false;
    var saw_dir = false;
    for (root_entries) |entry| {
        if (std.mem.eql(u8, entry.name, "a.txt")) {
            try testing.expectEqual(DirEntryKind.file, entry.kind);
            saw_file = true;
        }
        if (std.mem.eql(u8, entry.name, "nested")) {
            try testing.expectEqual(DirEntryKind.directory, entry.kind);
            saw_dir = true;
        }
    }
    try testing.expect(saw_file and saw_dir);
    const nested_entries = try file_source.listPersistentDirEntries(allocator, "nested");
    defer freePersistentDirEntries(allocator, nested_entries);
    try testing.expectEqual(@as(usize, 1), nested_entries.len);
    try testing.expectEqualStrings("b.txt", nested_entries[0].name);
    try testing.expectEqual(DirEntryKind.file, nested_entries[0].kind);
    try testing.expectError(
        error.FileNotFound,
        file_source.listPersistentDirEntries(allocator, "no-such-dir"),
    );

    // The libc arm DIRECTLY (the web platform's implementation - plain
    // POSIX, so it runs + leak-checks natively; the cwd-relative path is
    // what opendir takes on both platforms, the mount prefix being the
    // only web-specific part, added at the call site).
    const libc_entries = try listDirEntriesLibc(allocator, scratch);
    defer freePersistentDirEntries(allocator, libc_entries);
    var libc_saw_file = false;
    var libc_saw_dir = false;
    for (libc_entries) |entry| {
        if (std.mem.eql(u8, entry.name, "a.txt")) {
            try testing.expectEqual(DirEntryKind.file, entry.kind);
            libc_saw_file = true;
        }
        if (std.mem.eql(u8, entry.name, "nested")) {
            try testing.expectEqual(DirEntryKind.directory, entry.kind);
            libc_saw_dir = true;
        }
    }
    try testing.expect(libc_saw_file and libc_saw_dir);
    try testing.expectError(error.FileNotFound, listDirEntriesLibc(allocator, scratch ++ "-nope"));
}

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

test "officialMissionDirPaths: content-shaped, sorted, unique, each readable" {
    const allocator = testing.allocator;
    const dirs = officialMissionDirPaths(allocator);
    defer {
        for (dirs) |dir| allocator.free(dir);
        allocator.free(dirs);
    }
    // The shipped missions are authored content (the campaign is built
    // in place) - assert the SHAPE, never the names/counts: every dir is
    // content-root-relative under a campaign's missions/, no data/ prefix,
    // sorted ascending, unique, and each dir's mission.txt is readable
    // through the embedded tier (the scan's own addressing contract).
    try testing.expect(dirs.len > 0);
    for (dirs, 0..) |dir, index| {
        try testing.expect(std.mem.startsWith(u8, dir, "campaigns/"));
        try testing.expect(std.mem.indexOf(u8, dir, "/missions/") != null);
        try testing.expect(!std.mem.startsWith(u8, dir, "data/"));
        if (index > 0) {
            try testing.expect(std.mem.lessThan(u8, dirs[index - 1], dir));
        }
        for (dirs[0..index]) |earlier| {
            try testing.expect(!std.mem.eql(u8, earlier, dir));
        }
        var threaded_io = std.Io.Threaded.init(allocator, .{});
        defer threaded_io.deinit();
        const file_source = FileSource.init(threaded_io.io(), undefined);
        const mission_txt_path = try std.fmt.allocPrint(allocator, "{s}/mission.txt", .{dir});
        defer allocator.free(mission_txt_path);
        const mission_txt = try file_source.readEmbeddedFile(allocator, mission_txt_path);
        defer allocator.free(mission_txt);
        try testing.expect(mission_txt.len > 0);
    }
}

test "listOfficialMissions: the shipped campaign missions with paths + metadata" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    // Scratch-backed persistent tier: the test derives custom-art
    // presence via listDirFiles (the two-tier union), which touches the
    // persistent dir - it must be a real (empty) dir, not undefined.
    const scratch = "zig-cache/test-official-missions-list";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    const list = try file_source.listOfficialMissions(allocator);
    defer freeMissions(allocator, list);

    // The shipped missions are authored content (asserted by shape, not
    // by name - see the officialMissionDirPaths test): one entry per
    // embedded mission dir, each entry's path IS that dir, ids unique,
    // name + level count resolved from the content itself, and custom
    // art presence DERIVED from the dir's PNGs (never assumed).
    const official_dirs = officialMissionDirPaths(allocator);
    defer {
        for (official_dirs) |owned_dir| allocator.free(owned_dir);
        allocator.free(official_dirs);
    }
    try testing.expectEqual(official_dirs.len, list.len);
    for (list) |entry| {
        var matched = false;
        for (official_dirs) |official_dir| {
            if (std.mem.eql(u8, official_dir, entry.path)) matched = true;
        }
        try testing.expect(matched);
        try testing.expectEqualStrings(std.fs.path.basename(entry.path), entry.id);
        try testing.expect(entry.name.len > 0);
        try testing.expect(entry.level_count > 0);
        const dir_files = try file_source.listDirFiles(allocator, entry.path);
        defer freeDirFiles(allocator, dir_files);
        var png_count: usize = 0;
        for (dir_files) |name| {
            if (std.mem.endsWith(u8, name, ".png")) png_count += 1;
        }
        try testing.expectEqual(png_count > 0, entry.has_custom_assets);
    }
    for (list, 0..) |entry, index| {
        for (list[0..index]) |earlier| {
            try testing.expect(!std.mem.eql(u8, earlier.id, entry.id));
        }
    }
}

// --- tests for listSaveFiles ---

// --- tests for listCampaigns / listOfficialCampaigns ---

test "moveEntryToDeleted: the recoverable delete - dirs, files, name collisions" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-move-to-deleted";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // A mission folder + a save file.
    file_source.writeFile("missions/alpha/mission.txt", "Metadata\nfile_format_version 3\n") catch @panic("w1");
    file_source.writeFile("saves/backup.txt", "save bytes") catch @panic("w2");

    // Delete the mission: the folder is GONE from missions/ and lands in
    // deleted/missions/ with a stamp appended to its name.
    try moveEntryToDeleted(&file_source, allocator, "missions", "alpha");
    try testing.expectError(error.FileNotFound, dir.statFile(io, "missions/alpha/mission.txt", .{}));
    const deleted_missions = try dir.openDir(io, "deleted/missions", .{ .iterate = true });
    var deleted_names: usize = 0;
    var first_name: []const u8 = "";
    var it = deleted_missions.iterate();
    while (try it.next(io)) |entry| {
        deleted_names += 1;
        first_name = entry.name;
    }
    try testing.expectEqual(@as(usize, 1), deleted_names);
    try testing.expect(std.mem.startsWith(u8, first_name, "alpha_"));
    try testing.expect(first_name.len > "alpha_".len); // the stamp is appended

    // Delete the save FILE: the extension stays LAST (the id stays
    // recognizable).
    try moveEntryToDeleted(&file_source, allocator, "saves", "backup.txt");
    try testing.expectError(error.FileNotFound, dir.statFile(io, "saves/backup.txt", .{}));
    const deleted_saves = try dir.openDir(io, "deleted/saves", .{ .iterate = true });
    var save_names: usize = 0;
    var save_name: []const u8 = "";
    var save_it = deleted_saves.iterate();
    while (try save_it.next(io)) |entry| {
        save_names += 1;
        save_name = entry.name;
    }
    try testing.expectEqual(@as(usize, 1), save_names);
    try testing.expect(std.mem.startsWith(u8, save_name, "backup_"));
    try testing.expect(std.mem.endsWith(u8, save_name, ".txt"));

    // A same-name second delete never OVERWRITES: recreate + delete again,
    // and the deleted/missions dir holds TWO distinct entries (either a
    // later stamp or the same-second counter suffix).
    file_source.writeFile("missions/alpha/mission.txt", "Metadata\nfile_format_version 3\n") catch @panic("w3");
    try moveEntryToDeleted(&file_source, allocator, "missions", "alpha");
    var deleted_names_after: usize = 0;
    var it2 = deleted_missions.iterate();
    while (try it2.next(io)) |_| {
        deleted_names_after += 1;
    }
    try testing.expectEqual(@as(usize, 2), deleted_names_after);
}

test "listCampaigns: local campaigns with metadata; skips + name fallbacks" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-campaigns";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    file_source.writeFile("campaigns/zeta_lands/campaign.txt", "Metadata\nfile_format_version 3\ncampaign_uuid 33333333-3333-3333-3333-333333333333\nname Zeta Lands\n") catch @panic("w1");
    try io.sleep(std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms), .real);
    // No name key: the entry falls back to the dir stem.
    file_source.writeFile("campaigns/unnamed/campaign.txt", "Metadata\nfile_format_version 3\ncampaign_uuid 44444444-4444-4444-4444-444444444444\n") catch @panic("w2");
    try io.sleep(std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms), .real);
    // Missing campaign.txt - SKIPPED (not viewable).
    file_source.writeFile("campaigns/broken/hub_a.txt", "Metadata\nfile_format_version 1\n") catch @panic("w3");

    const list = try file_source.listCampaigns(allocator);
    defer freeCampaigns(allocator, list);

    // Newest first (the sleep forces distinct stamps): the later-saved
    // "unnamed" (the stem fallback) leads, "Zeta Lands" follows.
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("campaigns/unnamed", list[0].dir);
    try testing.expectEqualStrings("unnamed", list[0].name);
    try testing.expectEqualStrings("44444444-4444-4444-4444-444444444444", list[0].uuid);
    try testing.expectEqualStrings("campaigns/zeta_lands", list[1].dir);
    try testing.expectEqualStrings("Zeta Lands", list[1].name);
    try testing.expectEqualStrings("33333333-3333-3333-3333-333333333333", list[1].uuid);
    try testing.expect(list[0].mtime_ns > list[1].mtime_ns);
}

test "campaignEntryOrder: mtime descending, name ascending tiebreak" {
    const CampaignEntry = FileSource.CampaignEntry;
    var entries = [_]CampaignEntry{
        .{ .uuid = "", .dir = "", .name = "Older" },
        .{ .uuid = "", .dir = "", .name = "Beta", .mtime_ns = 100 },
        .{ .uuid = "", .dir = "", .name = "Alpha", .mtime_ns = 100 },
    };
    std.mem.sort(CampaignEntry, &entries, {}, campaignEntryOrder);
    // Equal mtimes -> name ascending; mtime 0 (official entries) sorts
    // last.
    try testing.expectEqualStrings("Alpha", entries[0].name);
    try testing.expectEqualStrings("Beta", entries[1].name);
    try testing.expectEqualStrings("Older", entries[2].name);
}

test "listCampaigns: empty when campaigns/ absent" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-campaigns-empty";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    const list = try file_source.listCampaigns(allocator);
    defer freeCampaigns(allocator, list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "officialCampaignDirs: content-shaped, sorted, unique, each readable" {
    const allocator = testing.allocator;
    const dirs = officialCampaignDirs(allocator);
    defer {
        for (dirs) |dir| allocator.free(dir);
        allocator.free(dirs);
    }
    // Same shape contract as the mission-dir scan: campaign ROOTS only
    // (content-root-relative, no deeper keys), no data/ prefix, sorted,
    // unique, each dir's campaign.txt readable through the embedded tier.
    try testing.expect(dirs.len > 0);
    for (dirs, 0..) |dir, index| {
        try testing.expect(std.mem.startsWith(u8, dir, "campaigns/"));
        try testing.expect(std.mem.indexOfScalar(u8, dir["campaigns/".len..], '/') == null);
        if (index > 0) {
            try testing.expect(std.mem.lessThan(u8, dirs[index - 1], dir));
        }
        for (dirs[0..index]) |earlier| {
            try testing.expect(!std.mem.eql(u8, earlier, dir));
        }
        var threaded_io = std.Io.Threaded.init(allocator, .{});
        defer threaded_io.deinit();
        const file_source = FileSource.init(threaded_io.io(), undefined);
        const campaign_txt_path = try std.fmt.allocPrint(allocator, "{s}/campaign.txt", .{dir});
        defer allocator.free(campaign_txt_path);
        const campaign_txt = try file_source.readEmbeddedFile(allocator, campaign_txt_path);
        defer allocator.free(campaign_txt);
        try testing.expect(campaign_txt.len > 0);
    }
}

test "listOfficialCampaigns: the shipped campaigns, metadata cross-checked" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, undefined);

    const list = try file_source.listOfficialCampaigns(allocator);
    defer freeCampaigns(allocator, list);

    // The shipped campaigns are authored content - never pinned by name or
    // count. The contract: at least one campaign, each entry's dir is a
    // content-root-relative campaign root, and its name + uuid match the
    // campaign.txt the scan read them from (the discovered-group scoping
    // check - parse the same bytes independently and compare).
    try testing.expect(list.len >= 1);
    for (list) |entry| {
        try testing.expect(std.mem.startsWith(u8, entry.dir, "campaigns/"));
        try testing.expect(std.mem.indexOfScalar(
            u8,
            entry.dir["campaigns/".len..],
            '/',
        ) == null);
        const campaign_txt_path = try std.fmt.allocPrint(allocator, "{s}/campaign.txt", .{entry.dir});
        defer allocator.free(campaign_txt_path);
        const bytes = try file_source.readEmbeddedFile(allocator, campaign_txt_path);
        defer allocator.free(bytes);
        const sections = try parser.parseConfigFile(bytes, allocator, &parser.campaign_sections);
        defer parser.freeParsedSections(sections, allocator);
        const metadata = parser.findSection(sections, "Metadata").?;
        const name = parser.findValue(metadata.entry_groups[0].pairs, "name").?;
        const uuid = parser.findValue(metadata.entry_groups[0].pairs, "campaign_uuid").?;
        try testing.expectEqualStrings(name, entry.name);
        try testing.expectEqualStrings(uuid, entry.uuid);
    }
}

test "resolveUuidDir: a persistent copy shadows its embedded namesake; same-tier duplicates flag" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-resolve-uuid-dir-tiers";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    const uuid = "11111111-1111-1111-1111-111111111111";
    const hub_txt = "Metadata\nhub_uuid " ++ uuid ++ "\n";
    const sections = [_][]const u8{"Metadata"};
    const free_resolution = struct {
        fn free(alloc: std.mem.Allocator, resolution: UuidDirResolution) void {
            alloc.free(resolution.dir);
        }
    }.free;

    // The save outcome: the persistent copy (under the scanned parent) +
    // the embedded original (outside it - reachable only through the
    // caller-passed embedded dirs, like the real embedded tier) share
    // the uuid. The persistent copy shadows: resolves to it, NO
    // duplicate flag.
    file_source.writeFile("campaigns/alpha/hubs/aaa/hub.txt", hub_txt) catch @panic("w1");
    file_source.writeFile("campaigns/embedded_mirror/hubs/orig/hub.txt", hub_txt) catch @panic("w2");
    {
        const resolution = resolveUuidDir(
            &file_source,
            allocator,
            "campaigns/alpha/hubs",
            &.{"campaigns/embedded_mirror/hubs/orig"},
            "hub.txt",
            &sections,
            "hub_uuid",
            uuid,
        ).?;
        defer free_resolution(allocator, resolution);
        try testing.expectEqualStrings("campaigns/alpha/hubs/aaa", resolution.dir);
        try testing.expectEqual(false, resolution.duplicate);
    }

    // A same-tier fork: a second persistent dir with the same uuid. The
    // duplicate flag fires + latest-mtime wins (bbb written after aaa).
    try io.sleep(std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms), .real);
    file_source.writeFile("campaigns/alpha/hubs/bbb/hub.txt", hub_txt) catch @panic("w3");
    {
        const resolution = resolveUuidDir(
            &file_source,
            allocator,
            "campaigns/alpha/hubs",
            &.{"campaigns/embedded_mirror/hubs/orig"},
            "hub.txt",
            &sections,
            "hub_uuid",
            uuid,
        ).?;
        defer free_resolution(allocator, resolution);
        try testing.expectEqualStrings("campaigns/alpha/hubs/bbb", resolution.dir);
        try testing.expectEqual(true, resolution.duplicate);
    }

    // Embedded-only collisions (a shipped-content bug): no persistent
    // tier at all, two embedded dirs with the uuid - duplicate flags,
    // name-ascending picks the winner.
    file_source.writeFile("campaigns/embedded_mirror/hubs/second/hub.txt", hub_txt) catch @panic("w4");
    {
        const resolution = resolveUuidDir(
            &file_source,
            allocator,
            "campaigns/beta/hubs",
            &.{ "campaigns/embedded_mirror/hubs/second", "campaigns/embedded_mirror/hubs/orig" },
            "hub.txt",
            &sections,
            "hub_uuid",
            uuid,
        ).?;
        defer free_resolution(allocator, resolution);
        try testing.expectEqualStrings("campaigns/embedded_mirror/hubs/orig", resolution.dir);
        try testing.expectEqual(true, resolution.duplicate);
    }
}

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

test "listDirFiles: both tiers unioned, deduped, direct files only, sorted" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-list-dir-files";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // A dir in neither tier lists empty.
    const absent = try file_source.listDirFiles(allocator, "no/such/dir");
    defer freeDirFiles(allocator, absent);
    try testing.expectEqual(@as(usize, 0), absent.len);

    // The official campaign dir is embedded: its ROOT files derived from
    // the embedded map (authored content - never pinned), with the scratch
    // shadows joining the union (sorted in); a same-name shadow of an
    // embedded file dedupes to one entry.
    const campaign_dirs = officialCampaignDirs(allocator);
    defer {
        for (campaign_dirs) |owned_dir| allocator.free(owned_dir);
        allocator.free(campaign_dirs);
    }
    const campaign_dir = campaign_dirs[0];
    var expected_files: std.ArrayList([]const u8) = .empty;
    defer expected_files.deinit(allocator);
    const data_prefix = try std.fmt.allocPrint(allocator, "data/{s}/", .{campaign_dir});
    defer allocator.free(data_prefix);
    const keys = embeddedMapKeys(allocator);
    defer allocator.free(keys);
    for (keys) |key| {
        if (!std.mem.startsWith(u8, key, data_prefix)) continue;
        // Root files only (subdir entries never list).
        if (std.mem.indexOfScalar(u8, key[data_prefix.len..], '/') != null) continue;
        try expected_files.append(allocator, key[data_prefix.len..]);
    }
    try testing.expect(expected_files.items.len > 0);
    for (expected_files.items) |name| {
        const shadow_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ campaign_dir, name });
        defer allocator.free(shadow_path);
        file_source.writeFile(shadow_path, "shadow") catch @panic("write embedded shadow");
    }
    {
        const zz_path = try std.fmt.allocPrint(allocator, "{s}/zz_shadow.png", .{campaign_dir});
        defer allocator.free(zz_path);
        file_source.writeFile(zz_path, "shadow png") catch @panic("write png shadow");
    }
    try expected_files.append(allocator, "zz_shadow.png");

    const files = try file_source.listDirFiles(allocator, campaign_dir);
    defer freeDirFiles(allocator, files);
    std.mem.sort([]const u8, expected_files.items, {}, struct {
        fn before(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.before);
    try testing.expectEqual(expected_files.items.len, files.len);
    for (files, expected_files.items) |actual, want| {
        try testing.expectEqualStrings(want, actual);
        try testing.expect(std.mem.indexOfScalar(u8, actual, '/') == null);
    }
}

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

    // The shipped campaign + a hub config, both DERIVED (authored content
    // - never pinned): the campaign.txt bytes carry the campaign's own
    // name, and the hub dir comes from the embedded map keys.
    const campaign_dirs = officialCampaignDirs(allocator);
    defer {
        for (campaign_dirs) |dir| allocator.free(dir);
        allocator.free(campaign_dirs);
    }
    const campaign_txt_path = try std.fmt.allocPrint(
        allocator,
        "{s}/campaign.txt",
        .{campaign_dirs[0]},
    );
    defer allocator.free(campaign_txt_path);
    const bytes = try file_source.readFile(allocator, campaign_txt_path);
    defer allocator.free(bytes);
    try testing.expect(bytes.len > 0);
    {
        const sections = try parser.parseConfigFile(bytes, allocator, &parser.campaign_sections);
        defer parser.freeParsedSections(sections, allocator);
        const metadata = parser.findSection(sections, "Metadata").?;
        const name = parser.findValue(metadata.entry_groups[0].pairs, "name").?;
        try testing.expect(name.len > 0);
        try testing.expect(std.mem.indexOf(u8, bytes, name) != null);
    }

    // And the customAssetTail shape addresses the same tier: derive one
    // hub.txt under the campaign from the map keys (the tail + extension
    // form is the read path for art; here we prove it resolves configs).
    const hub_prefix = try std.fmt.allocPrint(allocator, "data/{s}/hubs/", .{campaign_dirs[0]});
    defer allocator.free(hub_prefix);
    const keys = embeddedMapKeys(allocator);
    defer allocator.free(keys);
    var hub_txt_key: ?[]const u8 = null;
    for (keys) |key| {
        if (std.mem.startsWith(u8, key, hub_prefix) and std.mem.endsWith(u8, key, "/hub.txt")) {
            hub_txt_key = key;
            break;
        }
    }
    try testing.expect(hub_txt_key != null);
    const hub_txt_tail = hub_txt_key.?[@min(hub_txt_key.?.len, "data/".len)..];
    const config_via_tail = try file_source.readFile(allocator, hub_txt_tail);
    defer allocator.free(config_via_tail);
    try testing.expect(config_via_tail.len > 0);

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
