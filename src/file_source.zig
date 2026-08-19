//! Unified file I/O for the game. See AGENTS.md "File System & IO".
//!
//! The game ships as a single-file executable: all `data/` + `assets/` content
//! is embedded at build time (see `generated_assets.zig`, emitted by build.zig).
//! Writable artifacts (saves, session logs, future replays/custom missions)
//! live in a persistent data directory (`~/.ziglop/` by default). Both content
//! reads and artifact reads/writes funnel through this one session-resident
//! `FileSource` so the game never depends on the current working directory.
//!
//! Read order (first hit wins):
//!   1. in-memory VFS — uploaded zips / fetched custom missions (transient;
//!      lands when custom-mission support does — NOT yet wired)
//!   2. persistent dir — `~/.ziglop/<path>`
//!   3. embedded map — `data/**` + `assets/**` baked into the exe
//!
//! Because the persistent dir is checked before the embedded map, a player can
//! drop a file at `~/.ziglop/<shipped-path>` to shadow shipped content — a
//! modding seam by side effect (accepted as-is for now; see AGENTS.md). Writes
//! target the persistent dir only and reject `data/`/`assets/` prefixes so the
//! game itself can never shadow its own shipped content.
//!
//! `FileSource` lives on `GameStateHistory` next to `settings`: session-resident,
//! never deep-copied into snapshots, never touched by replay.

const std = @import("std");
const embedded_assets = @import("generated_assets");

/// A generous upper bound on a single file read, guarding against runaway
/// reads while comfortably covering any shipped asset (largest current asset
/// is ~70 KB; future audio is the only thing that could approach this).
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
        // 1. (future) in-memory VFS — not yet wired.

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
};

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
