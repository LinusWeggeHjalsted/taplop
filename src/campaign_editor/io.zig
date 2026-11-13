//! The campaign editor's file IO (the editor/mission_io sibling): the
//! copy-at-pick import (a local mission's files copied into the
//! campaign's missions/ - the campaign owns a snapshot; later edits to
//! the original do not propagate, by design) + the mission identity read
//! (uuid + name for the duplicate check + the entry event). The save
//! projection (3e) grows in this module too. Input-layer side effects
//! (the mission save/export class): never recorded as events, never
//! replayed - the graph change rides the editor_campaign_import_mission
//! event the pick site pushes after the copy. See DESIGN → Campaigns &
//! the Campaign Editor → The campaign editor surface.

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const parser = @import("../parser.zig");

const GameStateHistory = state.GameStateHistory;

/// A mission's on-disk identity (read from its mission.txt).
pub const MissionIdentity = struct {
    uuid: []const u8,
    name: []const u8,
};

/// Read a local mission's identity (uuid + name) from its mission.txt - a
/// plain input-layer read; the import pick resolves BEFORE copying, so a
/// broken mission never copies. Returns null when the file is
/// unreadable/unparseable (the caller surfaces the refusal). Strings are
/// owned by `allocator`.
pub fn readMissionIdentity(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    mission_dir: []const u8,
) ?MissionIdentity {
    const path = std.fmt.allocPrint(
        allocator,
        "missions/{s}/mission.txt",
        .{mission_dir},
    ) catch @panic("failed to allocate mission.txt path");
    const bytes = history.file_source.readFile(allocator, path) catch return null;
    const sections = parser.parseConfigFile(bytes, allocator, &parser.mission_sections) catch return null;
    var uuid: []const u8 = &.{};
    var name: []const u8 = &.{};
    if (parser.findSection(sections, "Metadata")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (parser.findValue(pairs, "uuid")) |value| {
                uuid = allocator.dupe(u8, value) catch @panic("failed to dupe mission uuid");
            }
            if (parser.findValue(pairs, "name")) |value| {
                name = allocator.dupe(u8, value) catch @panic("failed to dupe mission name");
            }
        }
    }
    if (uuid.len == 0) return null; // a mission without identity is not importable
    return .{ .uuid = uuid, .name = name };
}

/// Copy one file from the source mission dir to the campaign's copy.
/// Returns false when the source is unreadable (absent OR broken) - the
/// caller decides whether that is fatal (mission.txt) or tolerated
/// (player.txt, levels, art).
fn copyMissionFile(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    campaign_content_dir: []const u8,
    mission_dir: []const u8,
    file_name: []const u8,
) bool {
    const source = std.fmt.allocPrint(
        allocator,
        "missions/{s}/{s}",
        .{ mission_dir, file_name },
    ) catch @panic("failed to allocate import source path");
    const bytes = history.file_source.readFile(allocator, source) catch return false;
    const destination = std.fmt.allocPrint(
        allocator,
        "{s}/missions/{s}/{s}",
        .{ campaign_content_dir, mission_dir, file_name },
    ) catch @panic("failed to allocate import destination path");
    history.file_source.writeFile(destination, bytes) catch return false;
    return true;
}

/// Copy a local mission's files into the campaign's missions/ dir (the
/// copy-at-pick import): mission.txt (required - false when unreadable),
/// player.txt + the consecutive level_N.txt files + every custom PNG in
/// the dir (each optional - a hand-authored minimal mission copies with
/// whatever it has). The destination dir keeps the source's name (dirs
/// are storage, uuids are identity).
pub fn copyMissionIntoCampaign(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    campaign_content_dir: []const u8,
    mission_dir: []const u8,
) bool {
    if (!copyMissionFile(history, allocator, campaign_content_dir, mission_dir, "mission.txt")) {
        return false;
    }
    _ = copyMissionFile(history, allocator, campaign_content_dir, mission_dir, "player.txt");
    var level_number: u32 = 1;
    while (true) : (level_number += 1) {
        const level_name = std.fmt.allocPrint(
            allocator,
            "level_{d}.txt",
            .{level_number},
        ) catch @panic("failed to allocate level file name");
        if (!copyMissionFile(history, allocator, campaign_content_dir, mission_dir, level_name)) break;
    }
    const source_dir = std.fmt.allocPrint(
        allocator,
        "missions/{s}",
        .{mission_dir},
    ) catch @panic("failed to allocate import source dir");
    const art_names = history.file_source.listPersistentPngFiles(allocator, source_dir) catch return true;
    for (art_names) |art_name| {
        _ = copyMissionFile(history, allocator, campaign_content_dir, mission_dir, art_name);
    }
    return true;
}

/// The save mode: an in-place save keeps the campaign's identity (the
/// memo stabilizes minted uuids across saves); a Save As Copy mints a
/// FRESH campaign uuid + dir (an intentional fork is a new work) and the
/// session continues saving THE COPY (the original dir stays untouched
/// behind).
pub const CampaignSaveMode = enum {
    in_place,
    as_copy,
};

/// Resolve the campaign's identity for the save: the state's uuid (a
/// loaded campaign), else the session memo (a prior save), else a fresh
/// mint (memo'd). `as_copy` always mints fresh (a new work). Returns the
/// uuid + the content dir.
fn resolveCampaignIdentity(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    editor: types.CampaignEditor,
    mode: CampaignSaveMode,
) types.CampaignSaveMemo {
    // The MEMO wins over the state identity (LAST-WINS): a Save As Copy
    // appends a fresh identity and the session continues saving the COPY
    // - the state still carries the original's identity (a side effect
    // never mutates replayed state), so state-first precedence would
    // keep writing the original forever. The memos are cleared at every
    // campaign open (see clearCampaignSaveState), so they can never leak
    // across campaigns.
    var latest: ?types.CampaignSaveMemo = null;
    for (history.session.campaign_save_memos) |memo| {
        if (memo.handle == types.campaign_save_memo_handle) latest = memo;
    }
    if (latest) |memo| return memo;
    if (mode == .in_place) {
        if (editor.campaign_uuid.len > 0) {
            return .{
                .handle = types.campaign_save_memo_handle,
                .uuid = allocator.dupe(u8, editor.campaign_uuid) catch @panic("failed to dupe campaign uuid"),
                .dir = allocator.dupe(u8, editor.campaign_dir) catch @panic("failed to dupe campaign dir"),
            };
        }
    }
    const uuid = generateCampaignUuid(history, allocator);
    const sanitized = sanitizeNameForDir(editor.campaign_name, allocator);
    const dir = std.fmt.allocPrint(allocator, "campaigns/{s}_{s}", .{ uuid, sanitized }) catch
        @panic("failed to format campaign dir");
    const memo = types.CampaignSaveMemo{
        .handle = types.campaign_save_memo_handle,
        .uuid = uuid,
        .dir = dir,
    };
    appendCampaignSaveMemo(history, memo);
    return memo;
}

/// Resolve one hub's/mission's uuid + canonical dir for the save: the
/// state's identity (loaded content), else the session memo (a prior
/// save), else a fresh uuid mint with the canonical `<uuid>_<name>` dir
/// (memo'd - repeated saves reuse both). Fresh missions carry a temp
/// anchor dir in state; the save writes the CANONICAL dir (the anchor
/// was never on disk for fresh missions; an imported mission's copy dir
/// is already canonical and its state uuid non-empty, so it resolves
/// through the state arm).
fn resolveContentIdentity(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    handle: u32,
    state_uuid: []const u8,
    state_dir: []const u8,
    name: []const u8,
) types.CampaignSaveMemo {
    if (state_uuid.len > 0 and state_dir.len > 0) {
        return .{
            .handle = handle,
            .uuid = allocator.dupe(u8, state_uuid) catch @panic("failed to dupe uuid"),
            .dir = allocator.dupe(u8, state_dir) catch @panic("failed to dupe dir"),
        };
    }
    // LAST-WINS (the campaign-sentinel rule: the most recent identity for
    // the handle is the session's current one).
    var latest: ?types.CampaignSaveMemo = null;
    for (history.session.campaign_save_memos) |memo| {
        if (memo.handle == handle) latest = memo;
    }
    if (latest) |memo| return memo;
    const uuid = generateCampaignUuid(history, allocator);
    const sanitized = sanitizeNameForDir(name, allocator);
    const dir = std.fmt.allocPrint(allocator, "{s}_{s}", .{ uuid, sanitized }) catch
        @panic("failed to format content dir");
    const memo = types.CampaignSaveMemo{ .handle = handle, .uuid = uuid, .dir = dir };
    appendCampaignSaveMemo(history, memo);
    return memo;
}

fn appendCampaignSaveMemo(history: *GameStateHistory, memo: types.CampaignSaveMemo) void {
    const backing = history.backing_allocator;
    var memos: std.ArrayList(types.CampaignSaveMemo) = .empty;
    memos.appendSlice(backing, history.session.campaign_save_memos) catch
        @panic("failed to copy campaign save memos");
    memos.append(backing, .{
        .handle = memo.handle,
        .uuid = backing.dupe(u8, memo.uuid) catch @panic("failed to own memo uuid"),
        .dir = backing.dupe(u8, memo.dir) catch @panic("failed to own memo dir"),
    }) catch @panic("failed to append campaign save memo");
    history.session.campaign_save_memos = memos.toOwnedSlice(backing) catch
        @panic("failed to own campaign save memos");
}

/// A random v4-format uuid (the mission generator's convention, shared:
/// one identity-mint shape everywhere). Called ONLY from the save path -
/// an input-layer side effect that never enters GameState or a recorded
/// event, so the randomness is replay-safe by construction.
fn generateCampaignUuid(history: *GameStateHistory, allocator: std.mem.Allocator) []const u8 {
    const mission_io = @import("../editor/mission_io.zig");
    return mission_io.generateMissionUuid(history, allocator);
}

/// Sanitize a name for a dir component (the mission convention: path-
/// hostile characters become '_', empty becomes "Unnamed").
fn sanitizeNameForDir(name: []const u8, allocator: std.mem.Allocator) []const u8 {
    const mission_io = @import("../editor/mission_io.zig");
    return mission_io.sanitizeMissionNameForPath(name, allocator);
}

/// Clear the campaign save's session state (the identity memos + the
/// deletion list) - called at every campaign-editor OPEN: both are
/// per-campaign-session bookkeeping, and neither may leak into a
/// different campaign's saves (a stale memo would redirect saves to the
/// previous campaign's dir; a stale deletion would remove the new
/// campaign's content).
pub fn clearCampaignSaveState(history: *GameStateHistory) void {
    if (history.replaying) return;
    const backing = history.backing_allocator;
    for (history.session.campaign_save_memos) |memo| {
        backing.free(memo.uuid);
        backing.free(memo.dir);
    }
    backing.free(history.session.campaign_save_memos);
    history.session.campaign_save_memos = &.{};
    for (history.session.campaign_deleted_dirs) |dir| backing.free(dir);
    backing.free(history.session.campaign_deleted_dirs);
    history.session.campaign_deleted_dirs = &.{};
}

/// The session's current save memo for a handle, if any (LAST-WINS - the
/// delete handlers use it to record the on-disk dir of fresh content
/// whose STATE dir is still empty).
pub fn campaignSaveMemoFor(history: *GameStateHistory, handle: u32) ?types.CampaignSaveMemo {
    var latest: ?types.CampaignSaveMemo = null;
    for (history.session.campaign_save_memos) |memo| {
        if (memo.handle == handle) latest = memo;
    }
    return latest;
}

/// Record a deleted content dir for the save's deletion reconciliation
/// (the delete handlers call this, gated !replaying). `dir` is the bare
/// folder name under the campaign's hubs/ or missions/ (the delete sites
/// know which; the save checks both roots - a name collision across the
/// two roots is a hand-edit state the reconciliation tolerates by
/// deleting what matches the deleted kind... v1: the save deletes
/// whichever of the two roots holds the dir).
pub fn recordCampaignContentDeletion(history: *GameStateHistory, dir: []const u8) void {
    if (dir.len == 0) return; // a fresh, never-saved entry has no dir
    const backing = history.backing_allocator;
    var dirs: std.ArrayList([]const u8) = .empty;
    dirs.appendSlice(backing, history.session.campaign_deleted_dirs) catch
        @panic("failed to copy campaign deleted dirs");
    dirs.append(backing, backing.dupe(u8, dir) catch @panic("failed to own deleted dir")) catch
        @panic("failed to append deleted dir");
    history.session.campaign_deleted_dirs = dirs.toOwnedSlice(backing) catch
        @panic("failed to own campaign deleted dirs");
}

/// Save the campaign editor's authored graph (the full save projection,
/// ctrl+S / Save Campaign / Save As Copy). THE reconciliation save - the
/// only write path that deletes anything:
///   1. resolve identities (state -> memo -> fresh mint, memo'd);
///   2. missions first (mission.txt name sync always; a FRESH mission
///      additionally gets level_1.txt - the default template, verbatim -
///      and deliberately NO player.txt: the loader's max-default
///      fallback, the loadout authored via the hand-off (slice 5));
///   3. hubs (hub.txt under hubs/<dir>/, the Exits projection; the
///      cosmetic dir tidy renames a mismatched dir when the target is
///      free);
///   4. campaign.txt (v4: Metadata + Hubs + Orphans);
///   5. the deletion reconciliation: each deleted dir from this session
///      whose content is NOT in the current graph (an undo restored it)
///      is removed, directory-level. An `as_copy` save never deletes
///      (the copy's dir starts clean; the deletions belong to the
///      original).
/// A pure input-layer side effect (the mission save's class): no
/// recorded event, never replayed.
pub fn saveCampaignEditor(
    history: *GameStateHistory,
    mode: CampaignSaveMode,
) void {
    const allocator = history.current_arena.allocator();
    const editor = history.current_state.campaign_editor orelse return;

    const campaign_memo = resolveCampaignIdentity(history, allocator, editor, mode);

    // Resolve EVERY identity first (the Exits projection references any
    // hub's uuid from any hub's file - the incremental order a
    // hub-by-hub resolution would give runs out of bounds on forward
    // references).
    var mission_ids: std.ArrayList([]const u8) = .empty;
    var mission_dirs: std.ArrayList([]const u8) = .empty;
    var mission_needs_template: std.ArrayList(bool) = .empty;
    for (editor.missions) |mission| {
        // A fresh mission materializes at its FIRST save: no state uuid
        // + no memo from a prior save (checked BEFORE the resolve - it
        // appends this save's own memo).
        const existed_before = mission.uuid.len > 0 or missionMemoExistedBefore(history, mission.handle);
        mission_needs_template.append(allocator, !existed_before) catch @panic("failed to collect template flag");
        const memo = resolveContentIdentity(history, allocator, mission.handle, mission.uuid, mission.dir, mission.name);
        mission_ids.append(allocator, memo.uuid) catch @panic("failed to collect mission uuid");
        mission_dirs.append(allocator, memo.dir) catch @panic("failed to collect mission dir");
    }
    var hub_ids: std.ArrayList([]const u8) = .empty;
    var hub_dirs: std.ArrayList([]const u8) = .empty;
    for (editor.hubs) |hub| {
        const memo = resolveContentIdentity(history, allocator, hub.handle, hub.uuid, hub.dir, hub.name);
        hub_ids.append(allocator, memo.uuid) catch @panic("failed to collect hub uuid");
        hub_dirs.append(allocator, memo.dir) catch @panic("failed to collect hub dir");
    }

    // 1. Missions first (mission.txt name sync always; a FRESH mission
    //    additionally gets level_1.txt - the default template, verbatim -
    //    and deliberately NO player.txt: the loader's max-default
    //    fallback, the loadout authored via the hand-off (slice 5)).
    for (editor.missions, 0..) |mission, mission_index| {
        const mission_dir_path = std.fmt.allocPrint(
            allocator,
            "{s}/missions/{s}",
            .{ campaign_memo.dir, mission_dirs.items[mission_index] },
        ) catch @panic("failed to format mission dir path");
        const mission_txt = writers.writeCampaignMissionFile(mission, mission_ids.items[mission_index], allocator) catch
            @panic("failed to write campaign mission file");
        const mission_txt_path = std.fmt.allocPrint(
            allocator,
            "{s}/mission.txt",
            .{mission_dir_path},
        ) catch @panic("failed to format mission.txt path");
        history.file_source.writeFile(mission_txt_path, mission_txt) catch {
            surfaceSaveError(history, "failed to write the campaign's mission file");
            return;
        };
        if (mission_needs_template.items[mission_index]) {
            const default_level = history.file_source.readFile(allocator, "data/default_level.txt") catch {
                surfaceSaveError(history, "failed to read the default level template");
                return;
            };
            const level_path = std.fmt.allocPrint(
                allocator,
                "{s}/level_1.txt",
                .{mission_dir_path},
            ) catch @panic("failed to format level_1 path");
            history.file_source.writeFile(level_path, default_level) catch {
                surfaceSaveError(history, "failed to write the fresh mission's default level");
                return;
            };
        }
    }

    // 2. Hubs (the Exits projection + the cosmetic dir tidy).
    for (editor.hubs, 0..) |hub, hub_index| {
        const hub_dir_path = std.fmt.allocPrint(
            allocator,
            "{s}/hubs/{s}",
            .{ campaign_memo.dir, hub_dirs.items[hub_index] },
        ) catch @panic("failed to format hub dir path");
        const hub_txt = writers.writeCampaignHub(
            editor,
            hub,
            .{
                .campaign_uuid = campaign_memo.uuid,
                .hub_uuids = hub_ids.items,
                .mission_uuids = mission_ids.items,
            },
            hub_dir_path,
            allocator,
        ) catch @panic("failed to write campaign hub file");
        const hub_txt_path = std.fmt.allocPrint(
            allocator,
            "{s}/hub.txt",
            .{hub_dir_path},
        ) catch @panic("failed to format hub.txt path");
        history.file_source.writeFile(hub_txt_path, hub_txt) catch {
            surfaceSaveError(history, "failed to write the campaign's hub file");
            return;
        };
        // The cosmetic dir tidy: a loaded dir whose name no longer
        // matches the canonical form is renamed in passing - only when
        // the target is free (a collision keeps the old name; the
        // duplicate-uuid resolution handles the rest). Fresh hubs have
        // no state dir (their canonical dir was created by the write
        // above - nothing to tidy).
        if (hub.dir.len > 0 and !std.mem.eql(u8, hub.dir, hub_dirs.items[hub_index])) {
            const old_path = std.fmt.allocPrint(
                allocator,
                "{s}/hubs/{s}",
                .{ campaign_memo.dir, hub.dir },
            ) catch @panic("failed to format tidy old path");
            history.file_source.renameDir(old_path, hub_dir_path) catch {};
        }
    }

    // 3. campaign.txt.
    const campaign_txt = writers.writeCampaignFile(
        editor,
        .{
            .campaign_uuid = campaign_memo.uuid,
            .hub_uuids = hub_ids.items,
            .mission_uuids = mission_ids.items,
        },
        allocator,
    ) catch @panic("failed to write campaign file");
    const campaign_txt_path = std.fmt.allocPrint(
        allocator,
        "{s}/campaign.txt",
        .{campaign_memo.dir},
    ) catch @panic("failed to format campaign.txt path");
    history.file_source.writeFile(campaign_txt_path, campaign_txt) catch {
        surfaceSaveError(history, "failed to write the campaign file");
        return;
    };

    // 4. The deletion reconciliation (in-place saves only - a copy's dir
    // starts clean).
    if (mode == .in_place) {
        for (history.session.campaign_deleted_dirs) |deleted_dir| {
            // An undo restored the content - skip. The presence check
            // resolves each entry's CURRENT dir: the state's, else the
            // save memo's (fresh content's state dir is still empty -
            // the write-only mint).
            var present = false;
            for (editor.hubs) |hub| {
                const dir = if (hub.dir.len > 0) hub.dir else if (campaignSaveMemoFor(history, hub.handle)) |memo| memo.dir else &.{};
                if (std.mem.eql(u8, dir, deleted_dir)) present = true;
            }
            for (editor.missions) |mission| {
                const dir = if (mission.dir.len > 0) mission.dir else if (campaignSaveMemoFor(history, mission.handle)) |memo| memo.dir else &.{};
                if (std.mem.eql(u8, dir, deleted_dir)) present = true;
            }
            if (present) continue;
            const hub_path = std.fmt.allocPrint(
                allocator,
                "{s}/hubs/{s}",
                .{ campaign_memo.dir, deleted_dir },
            ) catch @panic("failed to format hub deletion path");
            history.file_source.deleteDir(hub_path) catch {};
            const mission_path = std.fmt.allocPrint(
                allocator,
                "{s}/missions/{s}",
                .{ campaign_memo.dir, deleted_dir },
            ) catch @panic("failed to format mission deletion path");
            history.file_source.deleteDir(mission_path) catch {};
        }
    }

    // The session continues under the SAVED identity (a copy's saves hit
    // the copy; the original stays behind) - the memo carries it; ALSO
    // the browser lists need a rescan next open (they rescan on open
    // anyway).
}

/// Whether a memo for `handle` existed BEFORE this save's resolution
/// (the fresh-mission template check - the resolve pass appends this
/// save's own memo, so the caller checks first).
fn missionMemoExistedBefore(history: *GameStateHistory, handle: u32) bool {
    for (history.session.campaign_save_memos) |memo| {
        if (memo.handle == handle) return true;
    }
    return false;
}

fn surfaceSaveError(history: *GameStateHistory, message: []const u8) void {
    history.session.setPendingError(history.history_arena.allocator(), message);
}

const writers = @import("../writers.zig");
