//! The game-folder zip (taplop.zip) - the web build's cross-session data
//! path (browser storage never persists sessions, so a downloaded archive is
//! the only durable home for a web player's data; DESIGN → File System & IO →
//! Web storage model). Both halves of the round trip:
//!   - EXPORT (options menu, every variant): list the persistent dir
//!     recursively (`FileSource.listPersistentDirFiles`), read every file,
//!     write a STORE archive (zip_writer; entry names are the persistent-
//!     relative paths), stage it at the `.game_export.zip` temp, download it
//!     as taplop.zip, delete the temp. Called from the input path
//!     (live-only - input handling never replays, so no replay gate), AFTER
//!     the `.export_game` orchestrator arm drained the autosave write, so
//!     mid-level progress is in the archive.
//!   - IMPORT (main menu): the picked taplop.zip lands at the
//!     `.game_import.zip` staging temp (the upload JS + marker - see
//!     pollGameImportMarker, called every frame from the web driver), then
//!     importGameFolder overlays it onto the persistent dir: validated
//!     WHOLE before the first write (names, caps, a dry-run decode pass),
//!     then streamed entry-by-entry through the RAW persistent-dir handle.

const std = @import("std");
const state = @import("state.zig");
const zip_writer = @import("zip_writer.zig");
const zip_reader = @import("zip_reader.zig");
const file_source_mod = @import("file_source.zig");

const FileSource = file_source_mod.FileSource;

/// The downloaded archive's name. One site - the web Export Game download
/// filename (the import side accepts any zip).
pub const export_download_name = "taplop.zip";

/// Export the full game folder (the whole persistent dir) as a taplop.zip
/// browser download. Best-effort (the autosave-backup policy - see DESIGN →
/// File System & IO): any failure surfaces the recoverable popup and
/// aborts; the staging temp is cleaned up best-effort (the listing also
/// excludes it, so a leftover can never ride in a later export).
pub fn exportGameFolder(history: *state.GameStateHistory) void {
    // The per-frame arena (the mission export's scratch convention):
    // everything here is transient - the listing, the file bytes, the
    // archive - and compacts away at the next idle point.
    const scratch = history.current_arena.allocator();
    const fail = struct {
        fn note(history_arg: *state.GameStateHistory, reason: []const u8) void {
            history_arg.session.setPendingError(
                history_arg.history_arena.allocator(),
                reason,
            );
        }
    };

    // Every file in the persistent dir, as archive entries.
    const paths = history.file_source.listPersistentDirFiles(scratch) catch {
        fail.note(history, "failed to export game folder: could not list the game folder");
        return;
    };
    var entries: std.ArrayList(zip_writer.ZipEntry) = .empty;
    for (paths) |path| {
        const bytes = history.file_source.readFile(scratch, path) catch {
            const reason = std.fmt.allocPrint(
                scratch,
                "failed to export game folder: could not read {s}",
                .{path},
            ) catch "failed to export game folder: could not read a file";
            fail.note(history, reason);
            return;
        };
        entries.append(scratch, .{ .name = path, .bytes = bytes }) catch
            @panic("failed to append zip entry");
    }

    // The archive (STORE - the mission export's writer).
    const archive = zip_writer.writeZipArchive(entries.items, scratch) catch {
        fail.note(history, "failed to export game folder: could not build the zip archive");
        return;
    };

    // Stage + download + clean up. The download seam reads the staging file
    // synchronously (its whole script runs before this call returns), so the
    // delete after it is safe.
    history.file_source.writeFile(file_source_mod.game_export_temp_path, archive) catch {
        fail.note(history, "failed to export game folder: could not stage the zip");
        return;
    };
    file_source_mod.triggerBrowserDownload(
        scratch,
        file_source_mod.game_export_temp_path,
        export_download_name,
    );
    history.file_source.deleteFile(file_source_mod.game_export_temp_path) catch {};
}

/// Safety caps for an imported archive (the untrusted-zip rules - DESIGN →
/// File System & IO → Web storage model): a generous tripwire, not a quota -
/// legitimate folders are a few MB, and under the in-memory model the caps
/// protect a busy tab, not storage. The entry-count cap is unreachable
/// through a real archive (the EOCD entry count is u16 with 0xFFFF reserved
/// as the zip64 marker, so a non-zip64 zip cannot carry more than 65,534
/// entries); the check stays as the documented tripwire regardless.
const import_max_entries: usize = 65_536;
const import_max_entry_bytes: usize = 512 * 1024 * 1024;
const import_max_total_bytes: usize = 2 * 1024 * 1024 * 1024;

/// Overlay a picked taplop.zip onto the persistent dir (Import Game - web
/// only by reachability, platform-neutral by construction). The overlay
/// semantics: same-path files are OVERWRITTEN by the zip (restore wins),
/// files the zip doesn't mention are kept (this session's new work
/// survives), shadow trees (data/ + assets/ names under the persistent dir)
/// are the point of a restore - written through the RAW persistent-dir
/// handle, NOT `FileSource.writeFile`, whose shipped-path write guard panics
/// by design. The untrusted-zip rules: every name + size cap is validated
/// BEFORE the first write and every entry is DECODED in a dry-run pass
/// before the write pass, so a hostile or corrupt archive fails WHOLE,
/// never half-imported. Streaming: one entry is in memory at a time (the
/// per-entry reset arena), bounded by the per-entry cap. Best-effort (the
/// autosave-backup policy): any failure surfaces the recoverable popup
/// naming the entry + aborts; the staging zip is deleted on every exit (the
/// original stays wherever the player picked it from). On success sets the
/// pending re-boot flag - the web driver re-runs the boot sequence at the
/// frame boundary so everything the folder carries applies (see web.zig).
fn importGameFolder(
    history: *state.GameStateHistory,
    zip_path: []const u8,
) void {
    const scratch = history.current_arena.allocator();
    const fail = struct {
        fn note(history_arg: *state.GameStateHistory, reason: []const u8) void {
            history_arg.session.setPendingError(
                history_arg.history_arena.allocator(),
                reason,
            );
        }
    };

    // The staging copy is transient: the original stays wherever the player
    // picked it from, so every exit (success + every failure) deletes it.
    defer history.file_source.deleteFile(zip_path) catch {};

    // The staging read goes through the RAW persistent-dir handle: the shared
    // read path's read_limit (256 MB) is sized for shipped assets, while a
    // legit game folder can reach this import's own 2 GB total cap.
    const zip_bytes = history.file_source.persistent_dir.readFileAlloc(
        history.file_source.io,
        zip_path,
        scratch,
        .limited(import_max_total_bytes),
    ) catch {
        fail.note(history, "failed to import game folder: could not read the uploaded zip");
        return;
    };

    // Pass one: every central-directory header (all names + sizes, no data).
    const headers = zip_reader.readZipEntryHeaders(zip_bytes, scratch) catch {
        fail.note(history, "failed to import game folder: the zip is corrupt or uses an unsupported format");
        return;
    };
    if (headers.len > import_max_entries) {
        fail.note(history, "failed to import game folder: the zip has too many files");
        return;
    }
    var total_bytes: usize = 0;
    for (headers) |header| {
        if (header.uncompressed_size > import_max_entry_bytes) {
            const reason = std.fmt.allocPrint(
                scratch,
                "failed to import game folder: a file in the zip is too large ({s})",
                .{header.name},
            ) catch "failed to import game folder: a file in the zip is too large";
            fail.note(history, reason);
            return;
        }
        total_bytes += header.uncompressed_size;
    }
    if (total_bytes > import_max_total_bytes) {
        fail.note(history, "failed to import game folder: the zip is too large to import");
        return;
    }

    // Pass two: validate every name BEFORE the first write. Junk entries
    // (an OS "compress folder" zip's macOS artifacts + directory records)
    // are skipped outright so an OS-made zip round-trips clean; everything
    // else must pass the shared Zip-Slip rules (see zip_reader).
    for (headers) |header| {
        if (zip_reader.isOsZipJunkEntry(header.name)) continue;
        if (zip_reader.isUnsafeZipEntryName(header.name)) {
            const reason = std.fmt.allocPrint(
                scratch,
                "failed to import game folder: unsafe file name in the zip ({s})",
                .{header.name},
            ) catch "failed to import game folder: unsafe file name in the zip";
            fail.note(history, reason);
            return;
        }
    }

    // Pass three (dry run): decode every non-junk entry + free it
    // immediately (the per-entry reset arena keeps memory at one entry).
    // This validates the local headers, methods, CRCs, and recorded sizes
    // WITHOUT writing, so a corrupt entry also fails whole, never
    // half-imported - the write pass below re-extracts each entry and can
    // then only fail at the IO level, which the popup also names.
    var entry_arena = std.heap.ArenaAllocator.init(history.backing_allocator);
    defer entry_arena.deinit();
    for (headers) |header| {
        if (zip_reader.isOsZipJunkEntry(header.name)) continue;
        _ = zip_reader.extractZipEntry(zip_bytes, entry_arena.allocator(), header) catch {
            const reason = std.fmt.allocPrint(
                scratch,
                "failed to import game folder: could not read {s} from the zip (it may be corrupt)",
                .{header.name},
            ) catch "failed to import game folder: could not read a file from the zip (it may be corrupt)";
            fail.note(history, reason);
            return;
        };
        _ = entry_arena.reset(.retain_capacity);
    }

    // Pass four (the overlay write): streamed, one entry at a time, through
    // the raw dir handle. Directories are created per entry (createDirPath is
    // idempotent), root-level files have no parent to create.
    for (headers) |header| {
        if (zip_reader.isOsZipJunkEntry(header.name)) continue;
        const entry = zip_reader.extractZipEntry(zip_bytes, entry_arena.allocator(), header) catch {
            // Unreachable in practice: the dry run decoded this same entry
            // from the same bytes. Kept defensive rather than a panic so an
            // allocation failure surfaces the popup like the rest.
            const reason = std.fmt.allocPrint(
                scratch,
                "failed to import game folder: could not read {s} from the zip",
                .{header.name},
            ) catch "failed to import game folder: could not read a file from the zip";
            fail.note(history, reason);
            return;
        };
        if (std.fs.path.dirname(entry.name)) |parent| {
            history.file_source.persistent_dir.createDirPath(history.file_source.io, parent) catch {
                const reason = std.fmt.allocPrint(
                    scratch,
                    "failed to import game folder: could not create the folder for {s}",
                    .{header.name},
                ) catch "failed to import game folder: could not create a folder";
                fail.note(history, reason);
                return;
            };
        }
        history.file_source.persistent_dir.writeFile(history.file_source.io, .{
            .sub_path = entry.name,
            .data = entry.bytes,
        }) catch {
            const reason = std.fmt.allocPrint(
                scratch,
                "failed to import game folder: could not write {s}",
                .{header.name},
            ) catch "failed to import game folder: could not write a file";
            fail.note(history, reason);
            return;
        };
        _ = entry_arena.reset(.retain_capacity);
    }

    // Success: the re-boot (the web driver's job, at the frame boundary)
    // applies everything the folder now carries - settings, shadow data/
    // trees, and the imported autosave (the main-menu Continue button).
    history.session.pending_import_reboot = true;
}

/// Consume the web game-import marker, if present: the picked taplop.zip
/// has landed at the staging temp - delete the marker, overlay the zip onto
/// the persistent dir (see importGameFolder). Called every frame from the
/// web driver's frame path (gated comptime at the call site - see main.zig);
/// the marker can land between any two frames, and the import re-boots the
/// session at the next frame boundary regardless of what screen is up (an
/// import replaces the session - mid-level progress since the last autosave
/// is included in that). A failure surfaces the recoverable popup; the
/// staging zip is deleted either way (importGameFolder owns the cleanup).
pub fn pollGameImportMarker(history: *state.GameStateHistory) void {
    if (!history.file_source.fileExists(file_source_mod.game_import_marker_path)) return;

    const scratch = history.current_arena.allocator();
    const marker_bytes = history.file_source.readFile(
        scratch,
        file_source_mod.game_import_marker_path,
    ) catch {
        // Unreadable marker: delete it so we don't spin on a corrupt file
        // (the pollImportMarker discipline).
        history.file_source.deleteFile(file_source_mod.game_import_marker_path) catch {};
        return;
    };
    history.file_source.deleteFile(file_source_mod.game_import_marker_path) catch {};
    importGameFolder(history, std.mem.trim(u8, marker_bytes, " \r\n\t"));
}

test "listPersistentDirFiles + zip round-trip: the full tree, temps excluded" {
    // The export's source list + the archive writer, round-tripped through
    // the reader (the import's future parse). Dedicated scratch trees (the
    // harness's deleteTree-then-create pattern - fresh per run, nothing of
    // the project's or other tests' rides along).
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const tree_scratch = "zig-cache/game-zip-test-tree";
    std.Io.Dir.cwd().deleteTree(io, tree_scratch) catch {};
    const tree_dir = std.Io.Dir.cwd().createDirPathOpen(io, tree_scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch return error.TestUnexpectedError;
    defer tree_dir.close(io);
    const file_source = FileSource.init(io, tree_dir);

    // A tree shaped like a real game folder: root files, saves/, a nested
    // custom mission, and the export + import staging + marker temps that
    // must NOT ride along (the whole persistent-dir artifact set).
    try file_source.writeFile("settings.txt", "Settings");
    try file_source.writeFile("saves/autosave.txt", "autosave");
    try file_source.writeFile("missions/mine/mission.txt", "mission");
    try file_source.writeFile("missions/mine/sprites/art.png", "png");
    try file_source.writeFile(file_source_mod.game_export_temp_path, "stale export staging temp");
    try file_source.writeFile(file_source_mod.game_import_temp_path, "stale import staging temp");
    try file_source.writeFile(file_source_mod.game_import_marker_path, "stale import marker");
    try file_source.writeFile(file_source_mod.import_marker_path, "stale save import marker");
    try file_source.writeFile(file_source_mod.mission_import_marker_path, "stale mission import marker");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const paths = try file_source.listPersistentDirFiles(allocator);
    // The exact expected list, derived from the same names (sorted - the
    // listing is ordered for determinism).
    const expected = [_][]const u8{
        "missions/mine/mission.txt",
        "missions/mine/sprites/art.png",
        "saves/autosave.txt",
        "settings.txt",
    };
    try std.testing.expectEqual(expected.len, paths.len);
    for (expected, paths) |expected_path, path| {
        try std.testing.expectEqualStrings(expected_path, path);
    }

    // Round-trip: entries → STORE archive → reader → identical names +
    // bytes (what the Import Game overlay will consume).
    var entries: std.ArrayList(zip_writer.ZipEntry) = .empty;
    for (paths) |path| {
        const bytes = try file_source.readFile(allocator, path);
        try entries.append(allocator, .{ .name = path, .bytes = bytes });
    }
    const archive = try zip_writer.writeZipArchive(entries.items, allocator);
    const read_back = try zip_reader.readZipArchive(archive, allocator);
    try std.testing.expectEqual(expected.len, read_back.len);
    for (read_back, expected) |entry, expected_path| {
        try std.testing.expectEqualStrings(expected_path, entry.name);
        const expected_bytes = try file_source.readFile(allocator, expected_path);
        try std.testing.expectEqualSlices(u8, expected_bytes, entry.bytes);
    }

    // Empty tree → empty listing (a fresh web session).
    const empty_scratch = "zig-cache/game-zip-test-empty";
    std.Io.Dir.cwd().deleteTree(io, empty_scratch) catch {};
    const empty_dir = std.Io.Dir.cwd().createDirPathOpen(io, empty_scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch return error.TestUnexpectedError;
    defer empty_dir.close(io);
    const empty_source = FileSource.init(io, empty_dir);
    const empty_paths = try empty_source.listPersistentDirFiles(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_paths.len);
}

// --- Import Game tests ---

/// Build a zip from entries + write it at the Import Game staging temp
/// (the upload JS's landing spot), so the tests drive the real import path.
fn stageImportZip(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    entries: []const zip_writer.ZipEntry,
) !void {
    const archive = try zip_writer.writeZipArchive(entries, allocator);
    try file_source.writeFile(file_source_mod.game_import_temp_path, archive);
}

test "importGameFolder: overlay - zip wins on same paths, unmentioned kept, shadow trees written" {
    const Harness = @import("test_harness.zig").Harness;
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    const scratch = history.current_arena.allocator();

    // This session's own work: a file the zip overwrites (same path, zip
    // wins) + one the zip doesn't mention (kept).
    try harness.file_source.writeFile("settings.txt", "old settings");
    try harness.file_source.writeFile("missions/mine/mission.txt", "mine");

    try stageImportZip(&harness.file_source, scratch, &.{
        .{ .name = "settings.txt", .bytes = "new settings" },
        .{ .name = "saves/autosave.txt", .bytes = "autosave" },
        // A shadow data/ tree: written through the RAW dir handle, the
        // shipped-path write guard must NOT fire (a restore shadows shipped
        // content by design).
        .{ .name = "data/color_themes.txt", .bytes = "shadow themes" },
        .{ .name = "missions/imported/mission.txt", .bytes = "imported" },
    });

    importGameFolder(&history, file_source_mod.game_import_temp_path);

    // Success: the re-boot flag is set, no error, the staging temp deleted.
    try std.testing.expect(history.session.pending_import_reboot);
    try std.testing.expectEqual(@as(?[]const u8, null), history.session.pending_error);
    try std.testing.expect(!history.file_source.fileExists(file_source_mod.game_import_temp_path));

    // Overlay semantics.
    try std.testing.expectEqualStrings(
        "new settings",
        try history.file_source.readFile(scratch, "settings.txt"),
    );
    try std.testing.expectEqualStrings(
        "mine",
        try history.file_source.readFile(scratch, "missions/mine/mission.txt"),
    );
    try std.testing.expectEqualStrings(
        "autosave",
        try history.file_source.readFile(scratch, "saves/autosave.txt"),
    );
    try std.testing.expectEqualStrings(
        "shadow themes",
        try history.file_source.readFile(scratch, "data/color_themes.txt"),
    );
    try std.testing.expectEqualStrings(
        "imported",
        try history.file_source.readFile(scratch, "missions/imported/mission.txt"),
    );
}

test "importGameFolder: a hostile name aborts whole - nothing written" {
    const Harness = @import("test_harness.zig").Harness;
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    const scratch = history.current_arena.allocator();

    try harness.file_source.writeFile("settings.txt", "old settings");
    // "saves/good.txt" sorts before the hostile entry and passes validation
    // itself; the validate-BEFORE-write passes mean NEITHER lands.
    try stageImportZip(&harness.file_source, scratch, &.{
        .{ .name = "saves/good.txt", .bytes = "good" },
        .{ .name = "../evil.txt", .bytes = "evil" },
    });

    importGameFolder(&history, file_source_mod.game_import_temp_path);

    try std.testing.expect(!history.session.pending_import_reboot);
    const pending_error = history.session.pending_error orelse
        @panic("the unsafe name did not surface the recoverable popup");
    try std.testing.expect(std.mem.indexOf(u8, pending_error, "../evil.txt") != null);
    // Zero writes: the same-path file is unchanged + the earlier valid
    // entry never landed.
    try std.testing.expectEqualStrings(
        "old settings",
        try history.file_source.readFile(scratch, "settings.txt"),
    );
    try std.testing.expect(!history.file_source.fileExists("saves/good.txt"));
    try std.testing.expect(!history.file_source.fileExists(file_source_mod.game_import_temp_path));
}

test "importGameFolder: OS-junk entries skipped, not written" {
    const Harness = @import("test_harness.zig").Harness;
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    const scratch = history.current_arena.allocator();

    try stageImportZip(&harness.file_source, scratch, &.{
        .{ .name = "__MACOSX/metadata", .bytes = "junk" },
        .{ .name = "saves/._autosave", .bytes = "junk" },
        .{ .name = ".DS_Store", .bytes = "junk" },
        // A directory entry (trailing '/').
        .{ .name = "missions/", .bytes = "" },
        .{ .name = "settings.txt", .bytes = "new settings" },
    });

    importGameFolder(&history, file_source_mod.game_import_temp_path);

    // The real content imported clean; the junk is not on disk.
    try std.testing.expect(history.session.pending_import_reboot);
    try std.testing.expectEqual(@as(?[]const u8, null), history.session.pending_error);
    try std.testing.expectEqualStrings(
        "new settings",
        try history.file_source.readFile(scratch, "settings.txt"),
    );
    try std.testing.expect(!history.file_source.fileExists("__MACOSX/metadata"));
    try std.testing.expect(!history.file_source.fileExists("saves/._autosave"));
    try std.testing.expect(!history.file_source.fileExists(".DS_Store"));
    try std.testing.expect(!history.file_source.fileExists("missions"));
}

test "importGameFolder: the size caps abort before any write" {
    const Harness = @import("test_harness.zig").Harness;
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    const scratch = history.current_arena.allocator();

    // Uniform 6-char names ("f0.txt".."f4.txt"), so each central-directory
    // record occupies 46 + 6 = 52 bytes at a constant stride. The caps are
    // checked from the central records alone (pass one), so only the
    // recorded uncompressed size needs patching - nothing is ever decoded.
    const entries = [_]zip_writer.ZipEntry{
        .{ .name = "f0.txt", .bytes = "" },
        .{ .name = "f1.txt", .bytes = "" },
        .{ .name = "f2.txt", .bytes = "" },
        .{ .name = "f3.txt", .bytes = "" },
        .{ .name = "f4.txt", .bytes = "" },
    };
    const archive = try zip_writer.writeZipArchive(&entries, scratch);

    // Patch one record's recorded uncompressed size past the per-entry cap.
    const central_directory_offset: usize = std.mem.readInt(
        u32,
        archive[archive.len - 22 ..][16..20],
        .little,
    );
    const record_stride = 46 + 6;

    const per_entry = try scratch.dupe(u8, archive);
    std.mem.writeInt(
        u32,
        per_entry[central_directory_offset + 0 * record_stride + 24 ..][0..4],
        @intCast(import_max_entry_bytes + 1),
        .little,
    );
    try harness.file_source.writeFile(file_source_mod.game_import_temp_path, per_entry);
    importGameFolder(&history, file_source_mod.game_import_temp_path);

    try std.testing.expect(!history.session.pending_import_reboot);
    try std.testing.expect(std.mem.indexOf(u8, history.session.pending_error orelse
        @panic("the per-entry cap did not surface the popup"), "too large") != null);
    try std.testing.expect(!history.file_source.fileExists("f0.txt"));

    // Five records each under the per-entry cap but summing past the total
    // cap (5 x 450 MB = 2.25 GB > 2 GB).
    const oversize_total = @as(u32, 450) * 1024 * 1024;
    const total = try scratch.dupe(u8, archive);
    for (0..entries.len) |record_index| {
        std.mem.writeInt(
            u32,
            total[central_directory_offset + record_index * record_stride + 24 ..][0..4],
            oversize_total,
            .little,
        );
    }
    try harness.file_source.writeFile(file_source_mod.game_import_temp_path, total);
    importGameFolder(&history, file_source_mod.game_import_temp_path);

    try std.testing.expect(!history.session.pending_import_reboot);
    try std.testing.expect(std.mem.indexOf(u8, history.session.pending_error orelse
        @panic("the total cap did not surface the popup"), "too large to import") != null);
    try std.testing.expect(!history.file_source.fileExists("f0.txt"));
    try std.testing.expect(!history.file_source.fileExists(file_source_mod.game_import_temp_path));
}

test "pollGameImportMarker: consumes the marker + staging zip, sets the re-boot flag" {
    const Harness = @import("test_harness.zig").Harness;
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    const scratch = history.current_arena.allocator();

    // The upload JS's landing: the staging zip + the marker naming it.
    try stageImportZip(&harness.file_source, scratch, &.{
        .{ .name = "settings.txt", .bytes = "new settings" },
        .{ .name = "saves/autosave.txt", .bytes = "autosave" },
    });
    try harness.file_source.writeFile(
        file_source_mod.game_import_marker_path,
        file_source_mod.game_import_temp_path,
    );

    pollGameImportMarker(&history);

    try std.testing.expect(history.session.pending_import_reboot);
    try std.testing.expectEqual(@as(?[]const u8, null), history.session.pending_error);
    // Both temps are consumed.
    try std.testing.expect(!history.file_source.fileExists(file_source_mod.game_import_marker_path));
    try std.testing.expect(!history.file_source.fileExists(file_source_mod.game_import_temp_path));
    try std.testing.expectEqualStrings(
        "new settings",
        try history.file_source.readFile(scratch, "settings.txt"),
    );

    // No marker (the normal case, every frame): a no-op - no spin, no error.
    pollGameImportMarker(&history);
    try std.testing.expectEqual(@as(?[]const u8, null), history.session.pending_error);
    try std.testing.expect(history.session.pending_import_reboot);
}
