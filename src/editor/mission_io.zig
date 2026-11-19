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
const campaign_io = @import("../campaign_editor/io.zig");

const GameStateHistory = state.GameStateHistory;

/// Scan the mission directory's .pngs into `session.editor_mission_sprites`
/// (the sprite picker's mission-local tab): one entry per file, each
/// carrying its content-addressed id (`custom/<mission content path>/<stem>`
/// - file_source.customStemForContentPath, minted HERE
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
        const stored_id = file_source_mod.customStemForContentPath(editor.mission.path, stem, allocator);
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
pub fn generateMissionUuid(history: *GameStateHistory, allocator: std.mem.Allocator) []const u8 {
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
pub fn sanitizeMissionNameForPath(name: []const u8, allocator: std.mem.Allocator) []const u8 {
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
    // The campaign-context branch (the slice-5 hand-off): the same save
    // verb, a different target + identity resolution (the campaign's
    // missions/ + the campaign memo machinery). Export + validate ride
    // this branch too (they call through saveEditorMission's
    // save-first contract).
    if (editor.campaign_mission != null) return saveCampaignContextMission(history, editor);
    const scratch = history.current_arena.allocator();
    const durable = history.backing_allocator;

    // 1. Resolve the uuid: opened-from-disk (a persistent origin) → in
    //    memory; OFFICIAL-ORIGIN (the opened content exists only embedded
    //    - an official mission) → a fresh mint, so saving forks it as a
    //    new work instead of re-using the official identity (the official
    //    campaign's mission table, clone records, and leaderboard keys
    //    stay the original's); saved this session → the memo; else mint
    //    (the write-only rule - the minted value never enters GameState).
    var uuid: []const u8 = &.{};
    if (editor.mission.uuid.len > 0) {
        const origin_mission_txt = std.fmt.allocPrint(
            scratch,
            "{s}/mission.txt",
            .{editor.mission.path},
        ) catch @panic("failed to allocate origin mission.txt path");
        if (file_source_mod.persistentFileExists(history.file_source, origin_mission_txt)) {
            uuid = editor.mission.uuid;
        }
    }
    if (uuid.len == 0) {
        if (history.session.editor_saved_mission) |saved| uuid = saved.uuid;
    }
    var minted_uuid: ?[]const u8 = null;
    if (uuid.len == 0) {
        minted_uuid = generateMissionUuid(history, durable);
        uuid = minted_uuid.?;
    }

    // 2. Derive the save target's dir path (the content path custom sprite
    //    stems normalize to - their tail IS the art's read path - and the
    //    art-copy target), then project the editor into file contents
    //    (transient - the scratch arena reclaims them at the next idle
    //    point).
    const sanitized_name = sanitizeMissionNameForPath(editor.mission.name, scratch);
    const mission_dir_name = std.fmt.allocPrint(
        scratch,
        "{s}_{s}",
        .{ uuid, sanitized_name },
    ) catch @panic("failed to format mission dir name");
    const dir_path = std.fmt.allocPrint(
        durable,
        "missions/{s}",
        .{mission_dir_name},
    ) catch @panic("failed to allocate mission dir path");
    const written = writers.writeEditorMission(editor.*, uuid, dir_path, scratch) catch |write_error| {
        const message = switch (write_error) {
            error.TooManyLayoutCodes => "failed to save: a single level places more distinct tools than the layout char set provides",
            else => "failed to save: out of memory",
        };
        history.session.setPendingError(history.history_arena.allocator(), message);
        durable.free(dir_path);
        if (minted_uuid) |minted| durable.free(minted);
        return null;
    };

    // 3. Write into missions/<uuid>_<name>/ (the shared config-write
    //    loop).
    if (!writeMissionFiles(history, written, dir_path, scratch)) {
        durable.free(dir_path);
        if (minted_uuid) |minted| durable.free(minted);
        return null;
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

/// The campaign-context save (the slice-5 hand-off - DESIGN → Campaigns
/// & the Campaign Editor → The mission-editor hand-off): the same
/// projection + write loop + art carry as the standalone save, but the
/// identity + target resolve through the campaign memo machinery
/// (campaignMissionSaveTarget - a fresh or forked campaign self-serves
/// HERE, no "save the campaign first" gate) and the mission memo
/// (handle -> uuid + dir) records in the campaign's memo table instead
/// of editor_saved_mission, so the next full campaign save resolves
/// the same identity in place + skips the lean mission.txt write. The
/// returned dir path is backing-allocated and deliberately never freed
/// (the session-lifetime class - the standalone return borrows a slot
/// the next save frees; the campaign branch has no replacing slot).
fn saveCampaignContextMission(
    history: *GameStateHistory,
    editor: *types.Editor,
) ?[]const u8 {
    const campaign = history.current_state.campaign_editor orelse {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to save: the campaign below the mission editor was lost",
        );
        return null;
    };
    const handle = editor.campaign_mission.?;
    var entry: ?types.CampaignMissionEdit = null;
    for (campaign.missions) |mission| {
        if (mission.handle == handle) entry = mission;
    }
    const mission = entry orelse {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to save: the campaign's mission entry no longer resolves",
        );
        return null;
    };
    const scratch = history.current_arena.allocator();
    const durable = history.backing_allocator;

    // 1. Identity + target + the campaign-side recording (the root
    //    carry for a fork, the mission memo, the owned marker).
    const target = campaign_io.campaignMissionSaveTarget(history, scratch, campaign, mission) orelse {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to save: could not carry the opened campaign's files into the new campaign dir",
        );
        return null;
    };

    // 2. Project the editor into file contents (transient - the scratch
    //    arena reclaims them at the next idle point), then write.
    const written = writers.writeEditorMission(editor.*, target.uuid, target.dir_path, scratch) catch |write_error| {
        const message = switch (write_error) {
            error.TooManyLayoutCodes => "failed to save: a single level places more distinct tools than the layout char set provides",
            else => "failed to save: out of memory",
        };
        history.session.setPendingError(history.history_arena.allocator(), message);
        return null;
    };
    if (!writeMissionFiles(history, written, target.dir_path, scratch)) return null;

    // 3. The art carry (the single-dir rule, same as standalone).
    if (!copyReferencedCustomSprites(history, editor, target.dir_path)) return null;

    // 4. The graph table write (the in-place rule -
    //    campaign_io.saveCampaignGraphAtMissionSave): campaign.txt must
    //    reference the mission dir this save just persisted, in the same
    //    save. A fork/minted target stays invisible by design.
    if (!campaign_io.saveCampaignGraphAtMissionSave(history, campaign)) return null;

    return durable.dupe(u8, target.dir_path) catch
        @panic("failed to dupe the campaign mission dir path");
}

/// The shared config-write loop (mission.txt + player.txt + level_N
/// into the save target): the standalone + campaign-context saves'
/// common body. A write failure surfaces the popup + returns false
/// (the caller aborts; nothing to revert - state is fine).
fn writeMissionFiles(
    history: *GameStateHistory,
    written: writers.WrittenEditorMission,
    dir_path: []const u8,
    scratch: std.mem.Allocator,
) bool {
    const mission_path = std.fmt.allocPrint(scratch, "{s}/mission.txt", .{dir_path}) catch
        @panic("failed to allocate mission.txt path");
    const player_path = std.fmt.allocPrint(scratch, "{s}/player.txt", .{dir_path}) catch
        @panic("failed to allocate player.txt path");
    history.file_source.writeFile(mission_path, written.mission_txt) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to save: could not write mission.txt",
        );
        return false;
    };
    history.file_source.writeFile(player_path, written.player_txt) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to save: could not write player.txt",
        );
        return false;
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
            return false;
        };
    }
    return true;
}

/// Copy every REFERENCED custom sprite PNG - entity + decoration palette
/// types, base + layers (placements reference types; the player has no
/// custom sprite) - into the save target dir. The single-dir rule: custom
/// art is content-addressed (the stem's tail IS its read path - see
/// file_source.customAssetTail), and the save is where a renamed mission
/// carries its art forward: the writer rewrites the stems to the new dir
/// (normalizedCustomStem) and this copy reads each PNG from the path its
/// OLD stem addresses (readFile's tiers) + writes it into the new dir. A
/// missing source is skipped - the load side already warned. Returns
/// false only on a target WRITE failure (the config-write failure class),
/// with the popup already surfaced.
fn copyReferencedCustomSprites(
    history: *GameStateHistory,
    editor: *const types.Editor,
    dir_path: []const u8,
) bool {
    for (editor.entity_types) |entity_type| {
        if (!copyOneReferencedCustomSprite(history, entity_type.template.sprite, dir_path)) return false;
        for (entity_type.template.layers) |layer| {
            if (!copyOneReferencedCustomSprite(history, layer.sprite, dir_path)) return false;
        }
    }
    for (editor.decoration_types) |decoration_type| {
        if (!copyOneReferencedCustomSprite(history, decoration_type.sprite, dir_path)) return false;
        for (decoration_type.layers) |layer| {
            if (!copyOneReferencedCustomSprite(history, layer.sprite, dir_path)) return false;
        }
    }
    return true;
}

/// One referenced stem's PNG: read it from the path its id addresses (the
/// tail after `custom/` - file_source.customAssetTail; readFile's tiers
/// cover both the persistent root and embedded `data/` content), write it
/// into `dir_path` under the FILE STEM. Non-custom and degenerate stems
/// no-op; a missing source skips (already warned at load); a write failure
/// surfaces the popup + returns false.
fn copyOneReferencedCustomSprite(
    history: *GameStateHistory,
    sprite_stem: []const u8,
    dir_path: []const u8,
) bool {
    const tail = file_source_mod.customAssetTail(sprite_stem) orelse return true;
    const slash = std.mem.lastIndexOfScalar(u8, tail, '/') orelse return true;
    const file_stem = tail[slash + 1 ..];
    if (file_stem.len == 0) return true;
    const scratch = history.current_arena.allocator();

    const source_path = std.fmt.allocPrint(
        scratch,
        "{s}.png",
        .{tail},
    ) catch @panic("failed to build custom sprite source path");
    const bytes = history.file_source.readFile(scratch, source_path) catch
        return true; // missing source: skip - already warned at load
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

    // The attempt boundary: the LAST start_validation in the recorded
    // stream. Every attempt begins with one (the Validate click's child or
    // the restart re-entry's child - the machinery event is the boundary
    // both ways, which is what lets handlers push it with no
    // orchestrator-shaped exception). The slice START then backs up to the
    // nearest preceding player action - the genuine initiator (the Validate
    // click, or the restart click that began this attempt): a fresh-state
    // replay must seed a player action at depth 0, so the slice begins
    // where the player actually acted. Restarted and failed attempts fall
    // outside the slice by construction (only the final attempt's
    // boundary is taken).
    var boundary_index: ?usize = null;
    for (history.event_history.items, 0..) |event, index| {
        if (event == .meta_event and event.meta_event == .start_validation) {
            boundary_index = index;
        }
    }
    const boundary = boundary_index orelse return; // unreachable live; nothing to write
    var slice_start: ?usize = null;
    var scan = boundary;
    while (scan > 0) {
        scan -= 1;
        if (history.event_history.items[scan] == .player_input_event) {
            slice_start = scan;
            break;
        }
    }
    const start = slice_start orelse return; // unreachable live; nothing to write
    if (start + 2 > history.event_history.items.len) return;
    const slice = history.event_history.items[start..];

    const hash = content_hash.computeMissionHash(
        history.file_source,
        scratch,
        mission.path,
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
        const sections = parser.parseConfigFile(bytes, scratch, &parser.session_log_sections) catch break :blk null;
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
    const sections = parser.parseConfigFile(stashed, scratch, &parser.session_log_sections) catch {
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
/// The caps are checked over the central-directory HEADERS before any
/// entry is decoded - a hostile declared `uncompressed_size` would
/// otherwise be allocated upfront by the extraction (see importGameFolder,
/// whose pass structure this mirrors).
const mission_import_max_entries: usize = 1024;

/// Per-entry cap. The largest legit mission content is a custom-art PNG
/// (~100 KB in practice); 64 MB is ~600x headroom past that.
const mission_import_max_entry_bytes: usize = 64 * 1024 * 1024;

/// Total cap. Coherent with the zip-bytes read itself (readFile's 256 MB
/// limit) - a legit mission archive can't exceed it anyway.
const mission_import_max_total_bytes: usize = 256 * 1024 * 1024;

/// The set of junk a macOS "Compress" zip carries alongside the real
/// content - skipped so an OS-made mission zip imports clean. The shared
/// untrusted-archive policy (see `zip_reader.isOsZipJunkEntry`).
fn isMissionImportJunk(name: []const u8) bool {
    return zip_reader.isOsZipJunkEntry(name);
}

const missionImportRootStrip = zip_reader.stripCommonRootFolder;

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
/// `missions/<sanitized name>/`). Every cap + every name is validated
/// over the central-directory headers BEFORE the first decode or write:
/// a hostile or malformed zip fails whole, never half-imported (the
/// pass structure mirrors importGameFolder - see game_zip.zig).
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

    // Pass one: every central-directory header (all names + sizes, no
    // data). The caps are checked from these alone, BEFORE any entry is
    // decoded - extraction allocates the declared uncompressed size
    // upfront, so a cap that runs after it is too late.
    const headers = zip_reader.readZipEntryHeaders(zip_bytes, scratch) catch {
        fail.note(history, "failed to import: the zip is corrupt or uses an unsupported format");
        return;
    };
    if (headers.len > mission_import_max_entries) {
        fail.note(history, "failed to import: the zip has too many files");
        return;
    }
    var total_bytes: usize = 0;
    for (headers) |header| {
        if (header.uncompressed_size > mission_import_max_entry_bytes) {
            fail.note(history, "failed to import: a file in the zip is too large");
            return;
        }
        total_bytes += header.uncompressed_size;
    }
    if (total_bytes > mission_import_max_total_bytes) {
        fail.note(history, "failed to import: the zip is too large to import");
        return;
    }

    // Filter OS junk, then strip a single common root folder.
    var file_headers: std.ArrayList(zip_reader.ZipEntryHeader) = .empty;
    for (headers) |header| {
        if (!isMissionImportJunk(header.name)) file_headers.append(scratch, header) catch
            @panic("failed to collect zip entries");
    }
    zip_reader.stripCommonRootFolder(file_headers.items);
    const stripped = file_headers.items;

    // Validate every name up front (nothing decoded, nothing written on
    // any bad entry).
    for (stripped) |header| {
        if (isUnsafeMissionImportName(header.name)) {
            const message = std.fmt.allocPrint(
                history.history_arena.allocator(),
                "failed to import: unsafe file name in the zip ({s})",
                .{header.name},
            ) catch "failed to import: unsafe file name in the zip";
            fail.note(history, message);
            return;
        }
    }

    // The mission's identity: mission.txt at the (stripped) archive root.
    // Entries are decoded one at a time from here on (the per-entry reset
    // arena keeps memory at one entry through the whole import).
    const mission_txt_header = blk: for (stripped) |header| {
        if (std.mem.eql(u8, header.name, "mission.txt")) break :blk header;
    } else {
        fail.note(history, "failed to import: the zip has no mission.txt at its root");
        return;
    };
    var entry_arena = std.heap.ArenaAllocator.init(history.backing_allocator);
    defer entry_arena.deinit();
    const mission_txt = zip_reader.extractZipEntry(
        zip_bytes,
        entry_arena.allocator(),
        mission_txt_header,
    ) catch {
        fail.note(history, "failed to import: could not read mission.txt from the zip (it may be corrupt)");
        return;
    };
    _ = entry_arena.reset(.retain_capacity);

    const sections = parser.parseConfigFile(mission_txt.bytes, scratch, &parser.mission_sections) catch {
        fail.note(history, "failed to import: the zip's mission.txt is not valid");
        return;
    };
    const mission = loaders.loadMission(sections, scratch) catch {
        fail.note(history, "failed to import: the zip's mission.txt is not valid");
        return;
    };

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

    for (stripped) |header| {
        const entry = zip_reader.extractZipEntry(zip_bytes, entry_arena.allocator(), header) catch {
            const message = std.fmt.allocPrint(
                history.history_arena.allocator(),
                "failed to import: could not read {s} from the zip (it may be corrupt)",
                .{header.name},
            ) catch "failed to import: could not read a file from the zip (it may be corrupt)";
            fail.note(history, message);
            return;
        };
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
        _ = entry_arena.reset(.retain_capacity);
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

test "importMissionFromZip: the size caps abort before any decode or write" {
    const Harness = @import("../test_harness.zig").Harness;
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    const scratch = history.current_arena.allocator();

    // Uniform 6-char names ("f0.txt".."f4.txt"), so each central-directory
    // record occupies 46 + 6 = 52 bytes at a constant stride. The caps are
    // checked from the central records alone (pass one), so only the
    // recorded uncompressed size needs patching - nothing is ever decoded
    // (no mission.txt is needed: the caps fire before the identity lookup).
    const entries = [_]zip_writer.ZipEntry{
        .{ .name = "f0.txt", .bytes = "" },
        .{ .name = "f1.txt", .bytes = "" },
        .{ .name = "f2.txt", .bytes = "" },
        .{ .name = "f3.txt", .bytes = "" },
        .{ .name = "f4.txt", .bytes = "" },
    };
    const archive = try zip_writer.writeZipArchive(&entries, scratch);

    const central_directory_offset: usize = std.mem.readInt(
        u32,
        archive[archive.len - 22 ..][16..20],
        .little,
    );
    const record_stride = 46 + 6;

    // Patch one record's recorded uncompressed size past the per-entry cap.
    const per_entry = try scratch.dupe(u8, archive);
    std.mem.writeInt(
        u32,
        per_entry[central_directory_offset + 0 * record_stride + 24 ..][0..4],
        @intCast(mission_import_max_entry_bytes + 1),
        .little,
    );
    try harness.file_source.writeFile("mission.zip", per_entry);
    importMissionFromZip(&history, "mission.zip");

    try std.testing.expect(std.mem.indexOf(u8, history.session.pending_error orelse
        @panic("the per-entry cap did not surface the popup"), "too large") != null);

    // Five records each under the per-entry cap but summing past the total
    // cap (5 x 60 MB = 300 MB > 256 MB).
    const oversize_total: u32 = 60 * 1024 * 1024;
    const total = try scratch.dupe(u8, archive);
    for (0..entries.len) |record_index| {
        std.mem.writeInt(
            u32,
            total[central_directory_offset + record_index * record_stride + 24 ..][0..4],
            oversize_total,
            .little,
        );
    }
    try harness.file_source.writeFile("mission.zip", total);
    importMissionFromZip(&history, "mission.zip");

    try std.testing.expect(std.mem.indexOf(u8, history.session.pending_error orelse
        @panic("the total cap did not surface the popup"), "too large to import") != null);

    // Nothing was extracted into the persistent dir on either failure -
    // only the staged zip itself (not under missions/).
    const written = try history.file_source.listPersistentDirFiles(scratch);
    for (written) |path| {
        try std.testing.expect(!std.mem.startsWith(u8, path, "missions/"));
    }
}

test "importMissionFromZip: a valid mission zip lands whole (headers-first streaming)" {
    const Harness = @import("../test_harness.zig").Harness;
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    const scratch = history.current_arena.allocator();

    const mission_txt =
        \\Metadata
        \\file_format_version 3
        \\mission_uuid 11111111-1111-1111-1111-111111111111
        \\name First Mission
    ;
    const entries = [_]zip_writer.ZipEntry{
        .{ .name = "mission.txt", .bytes = mission_txt },
        .{ .name = "level_1.txt", .bytes = "level one" },
    };
    const archive = try zip_writer.writeZipArchive(&entries, scratch);
    try harness.file_source.writeFile("mission.zip", archive);

    importMissionFromZip(&history, "mission.zip");

    // Success: no error, the zip is deleted, the browser list rescans.
    try std.testing.expectEqual(@as(?[]const u8, null), history.session.pending_error);
    try std.testing.expect(!history.file_source.fileExists("mission.zip"));
    try std.testing.expectEqual(@as(usize, 1), history.session.editor_local_missions.len);

    // The files landed under the imported dir (id derived from the same
    // rescan the import triggered, not hand-computed), contents verbatim.
    const mission_id = history.session.editor_local_missions[0].id;
    try std.testing.expectEqualStrings(
        "First Mission",
        history.session.editor_local_missions[0].name,
    );
    const mission_path = try std.fmt.allocPrint(scratch, "missions/{s}/mission.txt", .{mission_id});
    const level_path = try std.fmt.allocPrint(scratch, "missions/{s}/level_1.txt", .{mission_id});
    try std.testing.expectEqualStrings(mission_txt, try history.file_source.readFile(scratch, mission_path));
    try std.testing.expectEqualStrings("level one", try history.file_source.readFile(scratch, level_path));
}
