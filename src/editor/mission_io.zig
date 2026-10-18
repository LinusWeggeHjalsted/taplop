//! Editor mission file I/O: save-to-disk (uuid resolution + dir naming),
//! export (save + configs + sprites bundled into a STORE zip, browser
//! download on web), import (the web zip-upload marker poll + extraction
//! with junk/root-strip/safety filtering), the mission-list /
//! mission-sprite rescans, and the validation-replay write (the one
//! HANDLER-owned side effect here - the end_validation success handler
//! calls it gated `!replaying`; everything else is an input-layer side
//! effect off the undo timeline, dump_event_log-class - no recorded
//! events). See DESIGN → Level Editor (the save/export flow + the mission
//! browser) + DESIGN → Custom Missions & Online Services → Validation
//! replay + DESIGN → File System & IO.
const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const parser = @import("../parser.zig");
const loaders = @import("../loaders.zig");
const writers = @import("../writers.zig");
const file_source_mod = @import("../file_source.zig");
const zip_writer = @import("../zip_writer.zig");
const zip_reader = @import("../zip_reader.zig");
const session_log = @import("../session_log.zig");
const validation_replay = @import("../validation_replay.zig");
const content_hash = @import("../content_hash.zig");

const GameStateHistory = state.GameStateHistory;

/// Scan the mission directory's .pngs into `session.editor_mission_sprites`
/// (the sprite picker's mission-local tab): one entry per file, each
/// carrying its namespaced id (`custom/<mission-dir>/<stem>`, minted HERE
/// so the pick payload + the commit id reference session-owned bytes -
/// see MissionSprite.stored_id) and the PNG's pixel dims (IHDR read at
/// scan time - the decoration cells' aspect-fit needs them; an
/// unreadable/non-PNG file degrades to (0, 0), `scaleToFit`'s fallback).
/// Frees the previous scan - the list is session-owned (backing
/// allocator); the final list's leak at process exit is bounded (the
/// save_files pattern). An IO failure degrades to an empty list - the
/// Mission tab shows "No sprites" while the Official tab stays usable
/// (recoverable-degrade; a popup would interrupt the click flow for a dev
/// tool).
pub fn rescanEditorMissionSprites(history: *GameStateHistory, editor: types.Editor) void {
    const allocator = history.backing_allocator;
    const session = &history.session;
    for (session.editor_mission_sprites) |entry| {
        allocator.free(entry.file_name);
        allocator.free(entry.stored_id);
    }
    allocator.free(session.editor_mission_sprites);
    const mission_directory = types.missionDirectoryName(editor.mission.path);
    const names = history.file_source.listPersistentPngFiles(
        allocator,
        editor.mission.path,
    ) catch &[_][]const u8{};
    defer allocator.free(names);

    var sprites: std.ArrayList(state.MissionSprite) = .empty;
    for (names) |file_name| {
        const stem = file_name[0 .. std.mem.lastIndexOfScalar(u8, file_name, '.') orelse file_name.len];
        const pixel_dims = loaders.resolveMissionSpriteDimensions(
            history.file_source,
            editor.mission.path,
            stem,
            allocator,
        ) orelse types.Vector2{ .x = 0, .y = 0 };
        const stored_id = std.fmt.allocPrint(
            allocator,
            "custom/{s}/{s}",
            .{ mission_directory, stem },
        ) catch @panic("failed to scan mission sprites");
        sprites.append(allocator, .{
            .file_name = file_name,
            .stored_id = stored_id,
            .pixel_dims = pixel_dims,
        }) catch @panic("failed to scan mission sprites");
    }
    session.editor_mission_sprites = sprites.toOwnedSlice(allocator) catch
        @panic("failed to own mission sprite scan");
}

/// A random v4-format uuid (the shipped mission.txt format: 8-4-4-4-12
/// lowercase hex). Called ONLY from the save path - an input-layer side
/// effect that never enters GameState or a recorded event, so the
/// randomness is replay-safe by construction. See DESIGN → Level Editor →
/// Mission identity.
fn generateMissionUuid(history: *GameStateHistory, allocator: std.mem.Allocator) []const u8 {
    var bytes: [16]u8 = undefined;
    // Seed a CSPRNG from the wall clock (the same clock the session
    // timestamps read) + the raw nanoseconds - good enough for identity
    // minting, and the result never enters replayed state anyway.
    const now = std.Io.Clock.now(.real, history.io);
    var seed: [32]u8 = std.mem.zeroes([32]u8);
    const nanoseconds: [8]u8 = @bitCast(@as(i64, @truncate(now.nanoseconds)));
    @memcpy(seed[0..8], &nanoseconds);
    var csprng = std.Random.DefaultCsprng.init(seed);
    csprng.random().bytes(&bytes);
    // RFC 4122 v4: version nibble 4, variant 10xx.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}",
        .{
            std.mem.readInt(u32, bytes[0..4], .big),
            std.mem.readInt(u16, bytes[4..6], .big),
            std.mem.readInt(u16, bytes[6..8], .big),
            std.mem.readInt(u16, bytes[8..10], .big),
            std.mem.readInt(u48, bytes[10..16], .big),
        },
    ) catch @panic("failed to format mission uuid");
}

/// Make a mission name safe as a path segment: path separators + control
/// characters become '_', an empty result falls back to "Unnamed" (a
/// mission can be renamed to an empty string via the metadata sidebar).
fn sanitizeMissionNameForPath(name: []const u8, allocator: std.mem.Allocator) []const u8 {
    const sanitized = allocator.dupe(u8, name) catch @panic("failed to sanitize mission name");
    for (sanitized) |*character| {
        const invalid = character.* == '/' or character.* == '\\' or character.* < 0x20 or character.* == 0x7f;
        if (invalid) character.* = '_';
    }
    if (sanitized.len == 0) {
        allocator.free(sanitized);
        return "Unnamed";
    }
    return sanitized;
}

/// Save the edited mission to the persistent dir: resolve the mission's
/// uuid (in-memory if it was opened from disk, else the session memo of a
/// previous save - stable identity across saves - else a fresh mint),
/// project the Editor into files with the pure writer
/// (writers.writeEditorMission), and write mission.txt + player.txt +
/// level_N.txt under `missions/<uuid>_<name>/`. The session memo records
/// the uuid + dir for subsequent saves.
///
/// Returns the saved dir path on success (borrowed from the session memo
/// - stable until the NEXT save replaces the memo; deep-copy if kept past
/// that), null on failure. On failure a recoverable popup is already
/// surfaced and the memo is NOT updated - callers must not read it after
/// a null return (it would point at a PREVIOUS save's dir). Callers that
/// need the save to have landed (validate - the run reads the dir; export
/// - the bundle reads the files) gate on the return value.
///
/// A pure side effect - the dump_event_log class, NOT the save_game class:
/// there is no GameState component to record, so it pushes no event and
/// takes no undo step (a recorded event would mint dead undo steps), and
/// replay never runs the input layer so it never re-fires. Always deriving
/// the dir as `<uuid>_<name>` gives the settled semantics for free: a
/// re-save of an unchanged custom mission lands in the same dir, a RENAMED
/// mission lands in a NEW dir (the old one stays behind), and an OFFICIAL
/// mission opened for editing is saved as a persistent-dir copy (shipped
/// data is immutable - FileSource refuses data/ writes). Failures are
/// recoverable (the pending_error popup; nothing to revert - state is
/// fine, the files just didn't land). See DESIGN → Level Editor → Mission
/// identity.
pub fn saveEditorMission(history: *GameStateHistory) ?[]const u8 {
    const editor = if (history.current_state.editor) |*some_editor| some_editor else return null;
    const scratch = history.current_arena.allocator();
    const durable = history.backing_allocator;

    // 1. Resolve the uuid: opened-from-disk → in memory; saved this session
    //    → the memo; else mint (the write-only rule - the minted value
    //    never enters GameState).
    var uuid: []const u8 = editor.mission.uuid;
    if (uuid.len == 0) {
        if (history.session.editor_saved_mission) |saved| uuid = saved.uuid;
    }
    var minted_uuid: ?[]const u8 = null;
    if (uuid.len == 0) {
        minted_uuid = generateMissionUuid(history, durable);
        uuid = minted_uuid.?;
    }

    // 2. Derive the save target's dir name - the stem-namespace target
    //    (the writer normalizes custom sprite stems to it) + the art-copy
    //    target - then project the editor into file contents (transient -
    //    the scratch arena reclaims them at the next idle point).
    const sanitized_name = sanitizeMissionNameForPath(editor.mission.name, scratch);
    const mission_dir_name = std.fmt.allocPrint(
        scratch,
        "{s}_{s}",
        .{ uuid, sanitized_name },
    ) catch @panic("failed to format mission dir name");
    const written = writers.writeEditorMission(editor.*, uuid, mission_dir_name, scratch) catch |write_error| {
        const message = switch (write_error) {
            error.TooManyLayoutCodes => "failed to save: a single level places more distinct tools than the layout char set provides",
            else => "failed to save: out of memory",
        };
        history.session.setPendingError(history.history_arena.allocator(), message);
        if (minted_uuid) |minted| durable.free(minted);
        return null;
    };

    // 3. Write into missions/<uuid>_<name>/.
    const dir_path = std.fmt.allocPrint(
        durable,
        "missions/{s}",
        .{mission_dir_name},
    ) catch @panic("failed to allocate mission dir path");
    const mission_path = std.fmt.allocPrint(scratch, "{s}/mission.txt", .{dir_path}) catch
        @panic("failed to allocate mission.txt path");
    const player_path = std.fmt.allocPrint(scratch, "{s}/player.txt", .{dir_path}) catch
        @panic("failed to allocate player.txt path");
    history.file_source.writeFile(mission_path, written.mission_txt) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to save: could not write mission.txt",
        );
        durable.free(dir_path);
        if (minted_uuid) |minted| durable.free(minted);
        return null;
    };
    history.file_source.writeFile(player_path, written.player_txt) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to save: could not write player.txt",
        );
        durable.free(dir_path);
        if (minted_uuid) |minted| durable.free(minted);
        return null;
    };
    for (written.level_txts, 0..) |level_txt, level_index| {
        const level_path = std.fmt.allocPrint(
            scratch,
            "{s}/level_{d}.txt",
            .{ dir_path, level_index + 1 },
        ) catch @panic("failed to allocate level path");
        history.file_source.writeFile(level_path, level_txt) catch {
            const message = std.fmt.allocPrint(
                history.history_arena.allocator(),
                "failed to save: could not write level_{d}.txt",
                .{level_index + 1},
            ) catch @panic("failed to format save failure message");
            history.session.setPendingError(history.history_arena.allocator(), message);
            durable.free(dir_path);
            if (minted_uuid) |minted| durable.free(minted);
            return null;
        };
    }

    // 3b. Carry the referenced custom art into the save target (the
    //     single-dir rule - see copyReferencedCustomSprites). A copy WRITE
    //     failure fails the save like a config write failure.
    if (!copyReferencedCustomSprites(history, editor, dir_path)) {
        durable.free(dir_path);
        if (minted_uuid) |minted| durable.free(minted);
        return null;
    }

    // 4. Record the save on the session (the editor_mission_sprites
    //    ownership pattern: free the previous memo's strings, then store).
    //    The uuid slice: a fresh mint or the previous memo's REUSED slice is
    //    memo-owned; an OPENED mission's uuid borrows the editor's
    //    (current-arena) graph - dupe it durable so the memo never dangles
    //    past an arena compaction.
    var reused_previous_uuid = false;
    if (history.session.editor_saved_mission) |previous| {
        durable.free(previous.dir_path);
        if (previous.uuid.ptr == uuid.ptr) {
            reused_previous_uuid = true;
        } else {
            durable.free(previous.uuid);
        }
    }
    const memo_uuid: []const u8 = if (minted_uuid) |minted|
        minted
    else if (reused_previous_uuid)
        uuid
    else
        durable.dupe(u8, uuid) catch @panic("failed to dupe saved mission uuid");
    history.session.editor_saved_mission = .{
        .uuid = memo_uuid,
        .dir_path = dir_path,
    };
    return dir_path;
}

/// Copy every REFERENCED custom sprite PNG - entity + decoration palette
/// types, base + layers (placements reference types; the player has no
/// custom sprite) - into the save target dir. The single-dir rule: custom
/// art lives in the mission's OWN directory, and the save is where a
/// renamed mission carries its art forward (the writer normalizes the
/// stems' namespace to the same target in the same save). Source
/// resolution: the mission's CURRENT dir first (the rule's home), then
/// the stem's embedded namespace - legacy content authored before a
/// rename, a one-time migration read that self-heals it. A missing
/// source is skipped - the load side already warned. Returns false only
/// on a target WRITE failure (the config-write failure class), with the
/// popup already surfaced.
fn copyReferencedCustomSprites(
    history: *GameStateHistory,
    editor: *const types.Editor,
    dir_path: []const u8,
) bool {
    for (editor.entity_types) |entity_type| {
        if (!copyOneReferencedCustomSprite(history, editor.mission.path, entity_type.template.sprite, dir_path)) return false;
        for (entity_type.template.layers) |layer| {
            if (!copyOneReferencedCustomSprite(history, editor.mission.path, layer.sprite, dir_path)) return false;
        }
    }
    for (editor.decoration_types) |decoration_type| {
        if (!copyOneReferencedCustomSprite(history, editor.mission.path, decoration_type.sprite, dir_path)) return false;
        for (decoration_type.layers) |layer| {
            if (!copyOneReferencedCustomSprite(history, editor.mission.path, layer.sprite, dir_path)) return false;
        }
    }
    return true;
}

/// One referenced stem's PNG: resolve a source (current dir, then the
/// stem's embedded namespace), read it, write it into `dir_path` under the
/// FILE STEM (the namespace is identity-only). Non-custom and degenerate
/// stems no-op; a missing source skips; a write failure surfaces the
/// popup + returns false.
fn copyOneReferencedCustomSprite(
    history: *GameStateHistory,
    mission_path: []const u8,
    sprite_stem: []const u8,
    dir_path: []const u8,
) bool {
    if (!std.mem.startsWith(u8, sprite_stem, "custom/")) return true;
    const slash = std.mem.lastIndexOfScalar(u8, sprite_stem, '/') orelse return true;
    const file_stem = sprite_stem[slash + 1 ..];
    if (file_stem.len == 0) return true;
    const scratch = history.current_arena.allocator();

    const current_dir_path = std.fmt.allocPrint(
        scratch,
        "{s}/{s}.png",
        .{ mission_path, file_stem },
    ) catch @panic("failed to build custom sprite source path");
    const bytes = history.file_source.readFile(scratch, current_dir_path) catch blk: {
        // Legacy source: the stem's embedded namespace (pre-rename
        // content - the migration read).
        const embedded_path = std.fmt.allocPrint(
            scratch,
            "missions/{s}.png",
            .{sprite_stem["custom/".len..]},
        ) catch @panic("failed to build custom sprite legacy source path");
        break :blk history.file_source.readFile(scratch, embedded_path) catch
            return true; // missing source: skip - already warned at load
    };
    const target_path = std.fmt.allocPrint(
        scratch,
        "{s}/{s}.png",
        .{ dir_path, file_stem },
    ) catch @panic("failed to build custom sprite target path");
    history.file_source.writeFile(target_path, bytes) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to save: could not copy a custom sprite into the mission directory",
        );
        return false;
    };
    return true;
}

/// Free the previous stash + store the new replay bytes on the session,
/// backing-owned (the editor_saved_mission ownership pattern - the stash
/// must survive arena compaction; the Overwrite Replay button may be
/// clicked long after the run's idle point).
fn stashValidationReplay(history: *GameStateHistory, bytes: []const u8) void {
    const durable = history.backing_allocator;
    if (history.session.pending_validation_replay) |previous| durable.free(previous);
    history.session.pending_validation_replay = durable.dupe(u8, bytes) catch
        @panic("failed to stash the validation replay");
}

/// Drop the stash + the offer flag: after an auto-write, after a manual
/// overwrite write, or when the next run starts (a new run retires the
/// previous offer). The callers gate on `!replaying` - side-effect state,
/// replay must not eat a pending offer on undo/redo scrubbing.
pub fn clearPendingValidationReplay(history: *GameStateHistory) void {
    if (history.session.pending_validation_replay) |stashed| {
        history.backing_allocator.free(stashed);
    }
    history.session.pending_validation_replay = null;
    history.session.validation_replay_overwrite_offered = false;
}

/// Write the validation replay for a just-SUCCEEDED validation run - the
/// end_validation success handler calls this, gated `!replaying` at the
/// call site (the save_game class: a recorded event owns the side effect,
/// replay never re-fires it, undo past the run doesn't rewrite). The
/// artifact is the final attempt's verbatim event slice - event_history
/// from the LAST player_start_validation through the end_validation itself
/// - with `mission_uuid` + `content_hash` Metadata (the replay certifies
/// THIS content; a later hash mismatch reads as "unvalidated"). The
/// personal-best guard decides: auto-write when the old file is
/// absent/unreadable, its hash no longer matches the mission, or the new
/// run is strictly faster; otherwise keep the old file + stash the new
/// bytes + flag the manual-overwrite offer (the stats screen's Overwrite
/// Replay button writes the STASHED bytes - never a re-slice of a possibly
/// trimmed timeline). Turn count is DERIVED from the events (never
/// stored). See DESIGN → Custom Missions & Online Services → Validation
/// replay.
pub fn writeValidationReplay(history: *GameStateHistory) void {
    const current = &history.current_state;
    const mission = if (current.mission) |*some_mission| some_mission else return;
    const scratch = history.current_arena.allocator();

    // The slice start: the LAST player_start_validation in the recorded
    // stream. Every attempt begins with that orchestrator (the edit-mode
    // button or the restart re-entry), so the last one is the final
    // attempt's start - restarts and failed attempts fall outside the
    // slice by construction.
    var slice_start: ?usize = null;
    for (history.event_history.items, 0..) |event, index| {
        if (event == .player_input_event and event.player_input_event == .player_start_validation) {
            slice_start = index;
        }
    }
    const start = slice_start orelse return; // unreachable live; nothing to write
    if (start + 2 > history.event_history.items.len) return;
    const slice = history.event_history.items[start..];

    const hash = content_hash.computeMissionHash(
        history.file_source,
        scratch,
        mission.path,
        mission.level_count,
    ) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to save the validation replay: could not hash the mission files",
        );
        return;
    };
    const hash_hex = content_hash.hashToHex(hash);
    const created = session_log.formatSessionTimestamp(scratch, history.io);
    const replay_bytes = session_log.writeEventLogWithMetadata(
        slice,
        created,
        &.{
            .{ .name = "mission_uuid", .value = mission.uuid },
            .{ .name = "content_hash", .value = &hash_hex },
        },
        scratch,
    ) catch @panic("failed to serialize the validation replay");

    // The personal-best decision: what does the existing replay (if any)
    // say? Unreadable/absent → treated as absent (auto-write).
    const new_turns = validation_replay.deriveValidationTurns(slice);
    const existing: ?validation_replay.ExistingReplaySummary = blk: {
        const replay_path = std.fmt.allocPrint(
            scratch,
            "{s}/validation_replay.txt",
            .{mission.path},
        ) catch @panic("failed to allocate validation replay path");
        const bytes = history.file_source.readFile(scratch, replay_path) catch break :blk null;
        const sections = parser.parseConfigFile(bytes, scratch) catch break :blk null;
        const replay = validation_replay.loadValidationReplay(sections, scratch) catch break :blk null;
        break :blk .{
            .turns = validation_replay.deriveValidationTurns(replay.events),
            .content_hash = replay.content_hash,
        };
    };
    switch (validation_replay.replayOverwriteDecision(existing, new_turns, &hash_hex)) {
        .keep_offer_overwrite => {
            stashValidationReplay(history, replay_bytes);
            history.session.validation_replay_overwrite_offered = true;
            // The personal-best line follows the FILE - the kept old run.
            if (existing) |old| {
                history.session.validation_personal_best_turns = old.turns;
            }
        },
        .write => {
            const replay_path = std.fmt.allocPrint(
                scratch,
                "{s}/validation_replay.txt",
                .{mission.path},
            ) catch @panic("failed to allocate validation replay path");
            history.file_source.writeFile(replay_path, replay_bytes) catch {
                history.session.setPendingError(
                    history.history_arena.allocator(),
                    "failed to save the validation replay: could not write validation_replay.txt",
                );
                return;
            };
            clearPendingValidationReplay(history);
            history.session.validation_personal_best_turns = new_turns;
        },
    }
}

/// Write the stashed (slower-run) validation replay over the personal
/// best - the validation stats screen's manual Overwrite Replay button
/// (a pure input-layer side effect, the dump_event_log class - the bytes
/// are session-side, no GameState component to record). The stash was
/// captured at end_validation (the BYTES, not a re-slice - the timeline
/// may have moved since) and is SELF-DESCRIBING: its first event carries
/// the mission dir the run validated, so that's where it goes back - no
/// session-memo dependency (a stashed run always has one, but the stash
/// naming its own target is stricter). Clears the stash + the offer on
/// success and follows the personal-best line to the newly written file;
/// a write failure surfaces the popup and KEEPS the offer (re-clickable).
pub fn overwritePendingValidationReplay(history: *GameStateHistory) void {
    const stashed = history.session.pending_validation_replay orelse return;
    const scratch = history.current_arena.allocator();

    // The stash is our own serialized output - a parse failure is
    // impossible, but a corrupt stash must never overwrite the best:
    // drop the offer instead of writing garbage.
    const sections = parser.parseConfigFile(stashed, scratch) catch {
        clearPendingValidationReplay(history);
        return;
    };
    const replay = validation_replay.loadValidationReplay(sections, scratch) catch {
        clearPendingValidationReplay(history);
        return;
    };
    const mission_path = replay.events[0].player_input_event.player_start_validation.mission_path;
    const replay_path = std.fmt.allocPrint(
        scratch,
        "{s}/validation_replay.txt",
        .{mission_path},
    ) catch @panic("failed to allocate validation replay path");
    history.file_source.writeFile(replay_path, stashed) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to overwrite the validation replay: could not write validation_replay.txt",
        );
        return;
    };
    // The offer is consumed; the personal-best line follows the file.
    clearPendingValidationReplay(history);
    history.session.validation_personal_best_turns =
        validation_replay.deriveValidationTurns(replay.events);
}

/// Read one file from the persistent dir and append it to the export
/// entries under `archive_name`. Errors propagate (the caller surfaces
/// the popup).
fn appendExportFile(
    entries: *std.ArrayList(zip_writer.ZipEntry),
    file_source: *const file_source_mod.FileSource,
    allocator: std.mem.Allocator,
    path: []const u8,
    archive_name: []const u8,
) !void {
    const bytes = try file_source.readFile(allocator, path);
    try entries.append(allocator, .{ .name = archive_name, .bytes = bytes });
}

/// Export the edited mission as a .zip (the editor options menu's Export
/// Mission button - button-only, no keybind): SAVE first (the settled
/// order - the bundle is always the current state), then bundle the saved
/// mission files + the mission directory's custom sprites (a fresh
/// mission's pngs sit in its placeholder dir - they bundle even though the
/// save itself writes elsewhere) + a validation_replay.txt when one
/// exists (it lands with the validation slice) into a STORE archive at
/// `exported_missions/<uuid>_<name>.zip` in the persistent dir. On web
/// that file is then offered as a browser download (the Export Save seam -
/// triggerBrowserDownload reads it back from the mounted FS; a comptime
/// no-op on native). A pure side effect like the save (the dump_event_log
/// class). See DESIGN → Level Editor (the export flow).
pub fn exportEditorMission(history: *GameStateHistory) void {
    // Save first (the settled order - the bundle is always the current
    // state). A failed save surfaces its own popup and the memo is NOT
    // current (it would point at a PREVIOUS save's dir) - abort.
    if (saveEditorMission(history) == null) return;
    const saved = history.session.editor_saved_mission.?;
    const editor = if (history.current_state.editor) |*some_editor| some_editor else return;
    const scratch = history.current_arena.allocator();

    const fail = struct {
        fn note(history_arg: *GameStateHistory, reason: []const u8) void {
            history_arg.session.setPendingError(
                history_arg.history_arena.allocator(),
                reason,
            );
        }
    };

    var entries: std.ArrayList(zip_writer.ZipEntry) = .empty;

    // The generated mission files, read back from the save's directory.
    appendExportFile(
        &entries,
        history.file_source,
        scratch,
        std.fmt.allocPrint(scratch, "{s}/mission.txt", .{saved.dir_path}) catch
            @panic("failed to allocate export path"),
        "mission.txt",
    ) catch {
        fail.note(history, "failed to export: could not read the saved mission.txt");
        return;
    };
    appendExportFile(
        &entries,
        history.file_source,
        scratch,
        std.fmt.allocPrint(scratch, "{s}/player.txt", .{saved.dir_path}) catch
            @panic("failed to allocate export path"),
        "player.txt",
    ) catch {
        fail.note(history, "failed to export: could not read the saved player.txt");
        return;
    };
    for (0..editor.levels.len) |level_index| {
        const level_path = std.fmt.allocPrint(
            scratch,
            "{s}/level_{d}.txt",
            .{ saved.dir_path, level_index + 1 },
        ) catch @panic("failed to allocate export path");
        const archive_name = std.fmt.allocPrint(
            scratch,
            "level_{d}.txt",
            .{level_index + 1},
        ) catch @panic("failed to allocate export archive name");
        appendExportFile(&entries, history.file_source, scratch, level_path, archive_name) catch {
            fail.note(history, "failed to export: could not read a saved level file");
            return;
        };
    }

    // Custom sprites from the editor's CURRENT mission dir.
    const sprite_names = history.file_source.listPersistentPngFiles(
        scratch,
        editor.mission.path,
    ) catch &[_][]const u8{};
    for (sprite_names) |sprite_name| {
        const sprite_path = std.fmt.allocPrint(
            scratch,
            "{s}/{s}",
            .{ editor.mission.path, sprite_name },
        ) catch @panic("failed to allocate sprite export path");
        appendExportFile(&entries, history.file_source, scratch, sprite_path, sprite_name) catch {
            fail.note(history, "failed to export: could not read a mission sprite");
            return;
        };
    }

    // A validation replay, when one exists in the saved dir (written by
    // the validation flow once it lands). Absent or unreadable → not
    // bundled.
    if (appendExportFile(
        &entries,
        history.file_source,
        scratch,
        std.fmt.allocPrint(scratch, "{s}/validation_replay.txt", .{saved.dir_path}) catch
            @panic("failed to allocate export path"),
        "validation_replay.txt",
    )) |_| {} else |_| {}

    const archive = zip_writer.writeZipArchive(entries.items, scratch) catch {
        fail.note(history, "failed to export: could not build the zip archive");
        return;
    };
    const sanitized_name = sanitizeMissionNameForPath(editor.mission.name, scratch);
    const zip_path = std.fmt.allocPrint(
        scratch,
        "exported_missions/{s}_{s}.zip",
        .{ saved.uuid, sanitized_name },
    ) catch @panic("failed to allocate export zip path");
    history.file_source.writeFile(zip_path, archive) catch {
        fail.note(history, "failed to export: could not write the zip file");
        return;
    };
    // Web: offer it as a download (reads it back from the mounted FS);
    // native: a comptime no-op.
    file_source_mod.triggerBrowserDownload(scratch, zip_path, std.fs.path.basename(zip_path));
}

/// Consume the mission-import marker, if present: the picked .zip has landed
/// in imported_missions/ - delete the marker, extract the zip into missions/
/// (see importMissionFromZip), and rescan so the row appears. The web-only
/// upload (the browser's Import button / ctrl+I) lands the zip + marker; the
/// extraction is platform-neutral file I/O. A failure surfaces the
/// recoverable popup and keeps the zip (re-uploadable; the marker is gone
/// either way).
pub fn pollMissionImportMarker(history: *GameStateHistory) void {
    const marker = file_source_mod.mission_import_marker_path;
    if (!history.file_source.fileExists(marker)) return;

    const scratch = history.current_arena.allocator();
    const marker_bytes = history.file_source.readFile(scratch, marker) catch {
        // Unreadable marker: delete it so we don't spin on a corrupt file
        // (the pollImportMarker discipline).
        history.file_source.deleteFile(marker) catch {};
        return;
    };
    history.file_source.deleteFile(marker) catch {};
    importMissionFromZip(history, std.mem.trim(u8, marker_bytes, " \r\n\t"));
}

/// A safety cap on imported archive size: a mission dir is a handful of
/// config files + sprites; four orders of magnitude past that is a hostile
/// or mis-picked archive, not content. Keeps the scratch arena bounded.
const mission_import_max_entries: usize = 1024;

/// The set of junk a macOS "Compress" zip carries alongside the real
/// content - skipped so an OS-made mission zip imports clean. The shared
/// untrusted-archive policy (see `zip_reader.isOsZipJunkEntry`).
fn isMissionImportJunk(name: []const u8) bool {
    return zip_reader.isOsZipJunkEntry(name);
}

/// Strip a single common ROOT folder from every entry name, if there is
/// one: an OS "compress folder" zip wraps the mission's files in
/// `<folder>/...`, while our own exports are flat at the archive root.
/// Mixed shapes (some entries at the root, some under a folder, or two
/// different folders) strip nothing - the mission.txt lookup then fails and
/// the popup explains. Mutates `entries` in place (the caller's scratch-
/// arena copy of the filtered list).
fn missionImportRootStrip(entries: []zip_reader.ZipEntry) void {
    if (entries.len == 0) return;
    const first_slash = std.mem.indexOfScalar(u8, entries[0].name, '/') orelse return;
    const root = entries[0].name[0..first_slash];
    if (root.len == 0) return;
    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.name, root) or
            entry.name.len <= root.len or
            entry.name[root.len] != '/') return;
    }
    for (entries) |*entry| {
        entry.name = entry.name[root.len + 1 ..];
    }
}

/// A safe extraction name: the shared untrusted-archive policy (see
/// `zip_reader.isUnsafeZipEntryName`) - no absolute paths, no `..`
/// traversal, no backslashes, no NUL bytes, no empty segments. Applied
/// AFTER the root strip.
fn isUnsafeMissionImportName(name: []const u8) bool {
    return zip_reader.isUnsafeZipEntryName(name);
}

/// Extract one mission zip into `missions/<uuid>_<sanitized name>/` (the
/// editor save's dir convention - a re-import of the same zip overwrites
/// the same dir, idempotent; a mission without a uuid lands under
/// `missions/<sanitized name>/`). All names are validated BEFORE the first
/// write: a hostile or malformed zip fails whole, never half-imported.
fn importMissionFromZip(history: *GameStateHistory, zip_path: []const u8) void {
    const scratch = history.current_arena.allocator();
    const fail = struct {
        fn note(history_arg: *GameStateHistory, reason: []const u8) void {
            history_arg.session.setPendingError(
                history_arg.history_arena.allocator(),
                reason,
            );
        }
    };

    const zip_bytes = history.file_source.readFile(scratch, zip_path) catch {
        fail.note(history, "failed to import: could not read the uploaded zip");
        return;
    };
    const all_entries = zip_reader.readZipArchive(zip_bytes, scratch) catch {
        fail.note(history, "failed to import: the zip is corrupt or uses an unsupported format");
        return;
    };
    if (all_entries.len > mission_import_max_entries) {
        fail.note(history, "failed to import: the zip has too many files");
        return;
    }

    // Filter OS junk, then strip a single common root folder.
    var file_entries: std.ArrayList(zip_reader.ZipEntry) = .empty;
    for (all_entries) |entry| {
        if (!isMissionImportJunk(entry.name)) file_entries.append(scratch, entry) catch
            @panic("failed to collect zip entries");
    }
    missionImportRootStrip(file_entries.items);
    const stripped = file_entries.items;

    // The mission's identity: mission.txt at the (stripped) archive root.
    const mission_txt = blk: for (stripped) |entry| {
        if (std.mem.eql(u8, entry.name, "mission.txt")) break :blk entry.bytes;
    } else {
        fail.note(history, "failed to import: the zip has no mission.txt at its root");
        return;
    };
    const sections = parser.parseConfigFile(mission_txt, scratch) catch {
        fail.note(history, "failed to import: the zip's mission.txt is not valid");
        return;
    };
    const mission = loaders.loadMission(sections, scratch) catch {
        fail.note(history, "failed to import: the zip's mission.txt is not valid");
        return;
    };

    // Validate every name up front (nothing written on any bad entry).
    for (stripped) |entry| {
        if (isUnsafeMissionImportName(entry.name)) {
            const message = std.fmt.allocPrint(
                history.history_arena.allocator(),
                "failed to import: unsafe file name in the zip ({s})",
                .{entry.name},
            ) catch "failed to import: unsafe file name in the zip";
            fail.note(history, message);
            return;
        }
    }

    // The target dir, derived exactly like the editor save's.
    const sanitized_name = sanitizeMissionNameForPath(mission.name, scratch);
    var name_prefix: []const u8 = sanitized_name;
    if (mission.uuid.len > 0) {
        name_prefix = std.fmt.allocPrint(
            scratch,
            "{s}_{s}",
            .{ mission.uuid, sanitized_name },
        ) catch @panic("failed to allocate imported mission dir path");
    }
    const dir_path = std.fmt.allocPrint(
        scratch,
        "missions/{s}",
        .{name_prefix},
    ) catch @panic("failed to allocate imported mission dir path");

    for (stripped) |entry| {
        const file_path = std.fmt.allocPrint(scratch, "{s}/{s}", .{ dir_path, entry.name }) catch
            @panic("failed to allocate imported mission file path");
        history.file_source.writeFile(file_path, entry.bytes) catch {
            const message = std.fmt.allocPrint(
                history.history_arena.allocator(),
                "failed to import: could not write {s}",
                .{entry.name},
            ) catch "failed to import: could not write a mission file";
            fail.note(history, message);
            return;
        };
    }

    // Success: the zip has served its purpose (delete it - the extracted
    // folder is the artifact), and the browser's list rescans so the row
    // appears immediately.
    history.file_source.deleteFile(zip_path) catch {};
    rescanEditorMissionsNow(history);
}

/// Scan both mission-browser lists into SessionState, freeing the previous
/// local list (the save_files pattern). The LOCAL list is the persistent
/// `missions/` dir; the OFFICIAL list is parsed from the embedded mission
/// files ONCE per session (the embedded map is immutable per build - no
/// rescan). Runs when the browser OPENS (never in `view()`, which stays
/// file-free) - no periodic rescan while open: nothing can add a local
/// mission while the modal is up (a web import triggers its own explicit
/// rescan), so reopening is the refresh path. An unreadable dir keeps the
/// previous list rather than blanking the browser.
pub fn rescanEditorMissionsNow(history: *GameStateHistory) void {
    const allocator = history.backing_allocator;

    // The two scans are INDEPENDENT: a failure in one keeps that list's
    // previous contents and never blocks the other (a local-scan failure
    // on web's broken-readdir mount must not blank the OFFICIAL tab too -
    // the tabs fail separately or not at all).
    if (history.file_source.listMissions(allocator)) |local| {
        file_source_mod.freeMissions(allocator, history.session.editor_local_missions);
        history.session.editor_local_missions = local;
    } else |_| {} // unreadable dir mid-session: keep the previous list

    if (!history.session.editor_official_missions_scanned) {
        if (history.file_source.listOfficialMissions(allocator)) |official| {
            file_source_mod.freeMissions(allocator, history.session.editor_official_missions);
            history.session.editor_official_missions = official;
            history.session.editor_official_missions_scanned = true;
        } else |_| {} // one-time scan failed: retry on the next open
    }
}
