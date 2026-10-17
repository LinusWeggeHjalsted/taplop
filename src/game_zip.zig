//! The game-folder zip (ziglop.zip) — Export Game's writer, the web build's
//! cross-session data path (browser storage never persists sessions, so a
//! downloaded archive is the only durable home for a web player's data; the
//! future Import Game overlays the archive back — DESIGN → File System &
//! IO → Web storage model). The export: list the persistent dir recursively
//! (`FileSource.listPersistentDirFiles` — the platform-split listing), read
//! every file, write a STORE archive (zip_writer — the mission export's
//! writer; entry names are the persistent-relative paths), stage it at the
//! `.game_export.zip` temp, download it as ziglop.zip, delete the temp.
//! Called from the input path (live-only — input handling never replays, so
//! no replay gate), AFTER the `.export_game` orchestrator arm drained the
//! autosave write, so mid-level progress is in the archive.

const std = @import("std");
const state = @import("state.zig");
const zip_writer = @import("zip_writer.zig");
const zip_reader = @import("zip_reader.zig");
const file_source_mod = @import("file_source.zig");

/// The downloaded archive's name: ziglop.zip until the project rename to
/// taplop, at which point this constant (the one site) becomes taplop.zip.
pub const export_download_name = "ziglop.zip";

/// Export the full game folder (the whole persistent dir) as a ziglop.zip
/// browser download. Best-effort (the autosave-backup policy — see DESIGN →
/// File System & IO): any failure surfaces the recoverable popup and
/// aborts; the staging temp is cleaned up best-effort (the listing also
/// excludes it, so a leftover can never ride in a later export).
pub fn exportGameFolder(history: *state.GameStateHistory) void {
    // The per-frame arena (the mission export's scratch convention):
    // everything here is transient — the listing, the file bytes, the
    // archive — and compacts away at the next idle point.
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

    // The archive (STORE — the mission export's writer).
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

test "listPersistentDirFiles + zip round-trip: the full tree, temps excluded" {
    // The export's source list + the archive writer, round-tripped through
    // the reader (the import's future parse). Dedicated scratch trees (the
    // harness's deleteTree-then-create pattern — fresh per run, nothing of
    // the project's or other tests' rides along).
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const FileSource = @import("file_source.zig").FileSource;
    const tree_scratch = "zig-cache/game-zip-test-tree";
    std.Io.Dir.cwd().deleteTree(io, tree_scratch) catch {};
    const tree_dir = std.Io.Dir.cwd().createDirPathOpen(io, tree_scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch return error.TestUnexpectedError;
    defer tree_dir.close(io);
    const file_source = FileSource.init(io, tree_dir);

    // A tree shaped like a real game folder: root files, saves/, a nested
    // custom mission, and the two temps that must NOT ride along.
    try file_source.writeFile("settings.txt", "Settings");
    try file_source.writeFile("saves/autosave.txt", "autosave");
    try file_source.writeFile("missions/mine/mission.txt", "mission");
    try file_source.writeFile("missions/mine/sprites/art.png", "png");
    try file_source.writeFile(file_source_mod.game_export_temp_path, "stale staging temp");
    try file_source.writeFile(file_source_mod.game_folder_listing_temp, "stale listing temp");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const paths = try file_source.listPersistentDirFiles(allocator);
    // The exact expected list, derived from the same names (sorted — the
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
