//! The campaign editor's file IO (the editor/mission_io sibling): the
//! copy-at-pick import (a local mission's files copied into the
//! campaign's missions/ - the campaign owns a snapshot; later edits to
//! the original do not propagate, by design) + the mission identity read
//! (uuid + name for the duplicate check + the entry event) + the save
//! projection (3e). SAVING OFFICIAL CONTENT FORKS: content that exists
//! only in the embedded map gets a fresh identity + a new dir at save
//! (the whole-dir carry re-creates its files under the fork) - the
//! editor never shadows shipped content; the only persistent shadow of
//! official content is one installed by hand. Input-layer side effects
//! (the mission save/export class): never recorded as events, never
//! replayed - the graph change rides the editor_campaign_import_mission
//! event the pick site pushes after the copy. See DESIGN → Campaigns &
//! the Campaign Editor → The campaign editor surface.

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const parser = @import("../parser.zig");
const file_source_mod = @import("../file_source.zig");
const loaders = @import("../loaders.zig");
const validation_replay = @import("../validation_replay.zig");
const shared = @import("../handlers/shared.zig");

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
/// player.txt + validation_replay.txt + the consecutive level_N.txt
/// files + every custom PNG in the dir (each optional - a hand-authored
/// minimal mission copies with whatever it has). The validation replay
/// rides along so an imported VALIDATED mission stays validated (the
/// campaign-level check reads it - a copy without it would read as
/// unvalidated). The destination dir keeps the source's name (dirs
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
    _ = copyMissionFile(history, allocator, campaign_content_dir, mission_dir, "validation_replay.txt");
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

/// Copy every FILE directly inside `source_dir` (no recursion - both
/// tiers: the persistent scan + the embedded map) to the same name under
/// `destination_dir`. The FORK save's whole-dir carry: an official-origin
/// save re-creates the opened content's files under the fork dir -
/// everything the save does not itself write fresh (levels, player.txt,
/// custom art, the campaign root's background). A file the source tiers
/// cannot read is skipped; a failed write fails the carry (the caller
/// surfaces the save error).
fn copyDirFiles(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    destination_dir: []const u8,
    exclude_name: ?[]const u8,
) bool {
    // Both read tiers of the source dir's direct files in one listing
    // (persistent + embedded; subdirs belong to their own carries - see
    // `listDirFiles`). Each copy reads through `readFile`, which resolves
    // the same tiers, so the listing and the byte source can't disagree.
    // A listing failure aborts the carry (the save surfaces its popup) -
    // an unreadable source dir is already fatal for the forked copy.
    // `exclude_name` drops one file from the carry: the hub-only save
    // excludes campaign.txt (the full save may carry it - its fresh
    // write lands on top immediately; the hub save has no such write,
    // so a carried one would make the fork LIST under a stale graph,
    // breaking the no-campaign.txt-means-unlisted rule).
    const file_names = history.file_source.listDirFiles(allocator, source_dir) catch return false;
    defer file_source_mod.freeDirFiles(allocator, file_names);
    for (file_names) |file_name| {
        if (exclude_name) |excluded| {
            if (std.mem.eql(u8, file_name, excluded)) continue;
        }
        if (!copyOneDirFile(history, allocator, source_dir, destination_dir, file_name)) return false;
    }
    return true;
}

fn copyOneDirFile(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    destination_dir: []const u8,
    file_name: []const u8,
) bool {
    const source = std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_dir, file_name }) catch
        @panic("failed to build carry source path");
    defer allocator.free(source);
    const bytes = history.file_source.readFile(allocator, source) catch return true;
    defer allocator.free(bytes);
    const destination = std.fmt.allocPrint(allocator, "{s}/{s}", .{ destination_dir, file_name }) catch
        @panic("failed to build carry destination path");
    defer allocator.free(destination);
    history.file_source.writeFile(destination, bytes) catch return false;
    return true;
}

/// Resolve the campaign's identity for the save: the session memo (a
/// fork minted earlier this session), else the state's uuid (a loaded
/// LOCAL campaign - the official-origin check below), else a fresh mint
/// (memo'd). Returns the uuid + the content dir.
fn resolveCampaignIdentity(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    editor: types.CampaignEditor,
) types.CampaignSaveMemo {
    // The MEMO wins over the state identity (LAST-WINS): a minted
    // identity (a fork from a prior save this session) is the session's
    // current one - the state still carries the original's identity (a
    // side effect never mutates replayed state), so state-first
    // precedence would keep writing the original forever. The memos are
    // cleared at every campaign open (see clearCampaignSaveState), so
    // they can never leak across campaigns.
    var latest: ?types.CampaignSaveMemo = null;
    for (history.session.campaign_save_memos) |memo| {
        if (memo.handle == types.campaign_save_memo_handle) latest = memo;
    }
    if (latest) |memo| return memo;
    if (editor.campaign_uuid.len > 0) {
        // OFFICIAL-ORIGIN check: the state identity is honored only
        // when the opened campaign exists in the persistent tier.
        // Content that lives only in the embedded map is official -
        // saving it FORKS (a fresh identity + dir below; the
        // campaign-dir carry in saveCampaignEditor re-creates its
        // root files) so the editor never shadows shipped content.
        const campaign_txt_path = std.fmt.allocPrint(
            allocator,
            "{s}/campaign.txt",
            .{editor.campaign_dir},
        ) catch @panic("failed to build campaign.txt origin path");
        defer allocator.free(campaign_txt_path);
        if (file_source_mod.persistentFileExists(history.file_source, campaign_txt_path)) {
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

/// The campaign dir this session's campaign-level writes belong to: the
/// save memo's dir once a fork has been minted (an official-origin
/// campaign's first save or import), else the state's opened dir. The
/// background scan reads here, so a forked session offers the FORK's
/// art, not the opened original's.
pub fn effectiveCampaignDir(history: *GameStateHistory, editor: types.CampaignEditor) []const u8 {
    if (campaignSaveMemoFor(history, types.campaign_save_memo_handle)) |memo| return memo.dir;
    return editor.campaign_dir;
}

/// The campaign-context mission save's identity + target (the drill-in
/// save rule, the hand-off save's half - DESIGN → Campaigns & the
/// Campaign Editor → The mission-editor hand-off): resolves the
/// campaign identity (a fresh or official-origin campaign mints + memos
/// HERE, with the official-origin root carry minus campaign.txt - the
/// hub save's exact shape) + the mission's own identity through the
/// memo machinery (memo-first, the state identity when in-place, else a
/// fresh mint with the canonical `<uuid>_<name>` dir). Returns the
/// uuid (for mission.txt) + the full dir path under the campaign's
/// missions/.
pub const CampaignMissionSave = struct {
    uuid: []const u8,
    dir_path: []const u8,
};

pub fn campaignMissionSaveTarget(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    campaign: types.CampaignEditor,
    mission: types.CampaignMissionEdit,
) ?CampaignMissionSave {
    const campaign_memo = resolveCampaignIdentity(history, allocator, campaign);
    // The official-origin / fresh fork's root carry, minus campaign.txt
    // (a carried one would make the fork LIST under the opened
    // campaign's stale graph - the hub save's rule).
    if (!std.mem.eql(u8, campaign_memo.dir, campaign.campaign_dir)) {
        const carried_campaign_txt = std.fmt.allocPrint(
            allocator,
            "{s}/campaign.txt",
            .{campaign_memo.dir},
        ) catch @panic("failed to build carried campaign.txt path");
        if (!file_source_mod.persistentFileExists(history.file_source, carried_campaign_txt)) {
            if (!copyDirFiles(history, allocator, campaign.campaign_dir, campaign_memo.dir, "campaign.txt")) {
                return null;
            }
        }
    }
    const mission_memo = resolveContentIdentity(
        history,
        allocator,
        .{
            .opened_campaign_dir = campaign.campaign_dir,
            .save_target_dir = campaign_memo.dir,
            .kind_dir = "missions",
            .config_name = "mission.txt",
        },
        mission.handle,
        mission.uuid,
        mission.dir,
        mission.name,
    );
    const dir_path = std.fmt.allocPrint(
        allocator,
        "{s}/missions/{s}",
        .{ campaign_memo.dir, mission_memo.dir },
    ) catch @panic("failed to format campaign mission dir path");
    return .{ .uuid = mission_memo.uuid, .dir_path = dir_path };
}

/// The mission-editor hand-off's read path (the input layer's
/// memo-aware computation - a RECORDED handler must never read the
/// session memos, so the resolved path rides the open event's payload
/// instead, the open_editor mission_path precedent): the campaign's
/// effective dir (the save memo's fork target when one exists, else
/// the opened dir) + the mission's resolved dir (the memo's when one
/// exists, else the state dir). Null for a FRESH mission (no uuid, no
/// memo - the fresh-template branch; a full save that materialized
/// template files mints the memo, so the path branch picks them up).
pub fn campaignMissionEditorPath(
    history: *GameStateHistory,
    editor: types.CampaignEditor,
    mission: types.CampaignMissionEdit,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const memo = campaignSaveMemoFor(history, mission.handle);
    if (mission.uuid.len == 0 and memo == null) return null;
    const campaign_dir = effectiveCampaignDir(history, editor);
    const mission_dir = if (memo) |entry| entry.dir else mission.dir;
    return std.fmt.allocPrint(
        allocator,
        "{s}/missions/{s}",
        .{ campaign_dir, mission_dir },
    ) catch @panic("failed to format campaign mission path");
}

/// The campaign dir an import copies INTO: this session's save target.
/// A local campaign imports into its own dir; an official-origin
/// campaign mints the fork identity HERE (the memo carries to the later
/// save - the fork dir materializes piecemeal and stays invisible to the
/// campaign browser until its campaign.txt lands at save, since a dir
/// without a readable campaign.txt never lists).
pub fn campaignImportDir(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    editor: types.CampaignEditor,
) []const u8 {
    return resolveCampaignIdentity(history, allocator, editor).dir;
}

/// Where a content entry's files live + where this session's saves put
/// them - the fork check's roots.
const ContentOrigin = struct {
    /// The opened campaign's dir - the state identity's root, and the
    /// fork carry's copy SOURCE.
    opened_campaign_dir: []const u8,
    /// This session's save target (the campaign memo's dir) - the
    /// in-place existence check + the carry's DESTINATION root.
    save_target_dir: []const u8,
    /// "missions" | "hubs" - the content kind's dir under the campaign.
    kind_dir: []const u8,
    /// The kind's config file name ("mission.txt" | "hub.txt").
    config_name: []const u8,
};

/// Resolve one hub's/mission's uuid + canonical dir for the save. The
/// session MEMO (LAST-WINS) first - a minted identity from a prior save
/// this session (fresh content or an official-origin fork) is the
/// session's current one. Then the state identity (loaded content),
/// honored only when the content exists in this session's save target:
/// a local campaign's own dir, or a fork dir the import already copied
/// into. Official-origin state content (its files only embedded, under
/// the OPENED dir) FORKS - a fresh uuid + canonical dir; the save caller
/// detects the fork and carries the opened dir's files under it. Fresh
/// content carries neither state identity nor files: a plain mint
/// (memo'd - repeated saves reuse it).
fn resolveContentIdentity(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    origin: ContentOrigin,
    handle: u32,
    state_uuid: []const u8,
    state_dir: []const u8,
    name: []const u8,
) types.CampaignSaveMemo {
    var latest: ?types.CampaignSaveMemo = null;
    for (history.session.campaign_save_memos) |memo| {
        if (memo.handle == handle) latest = memo;
    }
    if (latest) |memo| return memo;
    if (state_uuid.len > 0 and state_dir.len > 0) {
        const target_config = std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}/{s}",
            .{ origin.save_target_dir, origin.kind_dir, state_dir, origin.config_name },
        ) catch @panic("failed to build content origin path");
        defer allocator.free(target_config);
        if (file_source_mod.persistentFileExists(history.file_source, target_config)) {
            return .{
                .handle = handle,
                .uuid = allocator.dupe(u8, state_uuid) catch @panic("failed to dupe uuid"),
                .dir = allocator.dupe(u8, state_dir) catch @panic("failed to dupe dir"),
            };
        }
        // Official-origin state content: mint below - the save caller
        // detects the fork (the minted dir differs from the state dir)
        // and carries the opened dir's files under it.
    }
    return mintContentIdentity(history, allocator, handle, name);
}

fn mintContentIdentity(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    handle: u32,
    name: []const u8,
) types.CampaignSaveMemo {
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
/// ctrl+S / the options menu's Save Campaign). THE reconciliation save -
/// the only write path that deletes anything:
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
///      is removed, directory-level;
///   6. the campaign root's cosmetic dir tidy: the dir follows the
///      campaign's CURRENT name (the mission/hub saves' mirror).
/// A pure input-layer side effect (the mission save's class): no
/// recorded event, never replayed.
/// Returns the SAVED campaign's content dir ("campaigns/<id>" - the memo
/// target, current-arena-owned and valid through the frame) on success,
/// null on any failure (each failure surfaces its own popup - the
/// Validate consumption aborts without certifying a failed save). The
/// mission save's `?[]const u8` contract.
pub fn saveCampaignEditor(
    history: *GameStateHistory,
) ?[]const u8 {
    const allocator = history.current_arena.allocator();
    const editor = history.current_state.campaign_editor orelse return null;

    const campaign_memo = resolveCampaignIdentity(history, allocator, editor);

    // The campaign-root carry (the fork's own files - the background PNG
    // + anything else at the campaign root): when the save target is NOT
    // the opened dir (a minted fork - official-origin content, or a fresh
    // campaign), the opened dir's direct files re-create under the target
    // once; the fresh campaign.txt write below lands on top. Gated on
    // the target lacking campaign.txt, so repeated saves skip it.
    if (!std.mem.eql(u8, campaign_memo.dir, editor.campaign_dir)) {
        const carried_campaign_txt = std.fmt.allocPrint(allocator, "{s}/campaign.txt", .{campaign_memo.dir}) catch
            @panic("failed to build carried campaign.txt path");
        defer allocator.free(carried_campaign_txt);
        if (!file_source_mod.persistentFileExists(history.file_source, carried_campaign_txt)) {
            if (!copyDirFiles(history, allocator, editor.campaign_dir, campaign_memo.dir, null)) {
                surfaceSaveError(history, "failed to carry the opened campaign's files into the new campaign dir");
                return null;
            }
        }
    }

    // Resolve EVERY identity first (the Missions section references any
    // hub's uuid from campaign.txt - the incremental order a
    // hub-by-hub resolution would give runs out of bounds on forward
    // references).
    var mission_ids: std.ArrayList([]const u8) = .empty;
    var mission_dirs: std.ArrayList([]const u8) = .empty;
    var mission_needs_template: std.ArrayList(bool) = .empty;
    const mission_origin = ContentOrigin{
        .opened_campaign_dir = editor.campaign_dir,
        .save_target_dir = campaign_memo.dir,
        .kind_dir = "missions",
        .config_name = "mission.txt",
    };
    for (editor.missions) |mission| {
        // A fresh mission materializes at its FIRST save: no state uuid
        // + no memo from a prior save (checked BEFORE the resolve - it
        // appends this save's own memo).
        const existed_before = mission.uuid.len > 0 or missionMemoExistedBefore(history, mission.handle);
        mission_needs_template.append(allocator, !existed_before) catch @panic("failed to collect template flag");
        const memo = resolveContentIdentity(history, allocator, mission_origin, mission.handle, mission.uuid, mission.dir, mission.name);
        mission_ids.append(allocator, memo.uuid) catch @panic("failed to collect mission uuid");
        mission_dirs.append(allocator, memo.dir) catch @panic("failed to collect mission dir");
        // The official-origin fork's whole-dir carry: re-create the
        // opened mission dir's files (levels, player.txt, art) under the
        // minted dir; the fresh mission.txt write below lands on top.
        // Detected as a minted dir differing from a NON-EMPTY state dir
        // (fresh missions mint too, but carry nothing - they were never
        // on disk).
        if (mission.uuid.len > 0 and mission.dir.len > 0 and !std.mem.eql(u8, memo.dir, mission.dir)) {
            const carry_source = std.fmt.allocPrint(allocator, "{s}/missions/{s}", .{ editor.campaign_dir, mission.dir }) catch
                @panic("failed to build mission carry source");
            defer allocator.free(carry_source);
            const carry_destination = std.fmt.allocPrint(allocator, "{s}/missions/{s}", .{ campaign_memo.dir, memo.dir }) catch
                @panic("failed to build mission carry destination");
            defer allocator.free(carry_destination);
            if (!copyDirFiles(history, allocator, carry_source, carry_destination, null)) {
                surfaceSaveError(history, "failed to carry the opened mission's files into the fork");
                return null;
            }
        }
    }
    var hub_ids: std.ArrayList([]const u8) = .empty;
    var hub_dirs: std.ArrayList([]const u8) = .empty;
    const hub_origin = ContentOrigin{
        .opened_campaign_dir = editor.campaign_dir,
        .save_target_dir = campaign_memo.dir,
        .kind_dir = "hubs",
        .config_name = "hub.txt",
    };
    for (editor.hubs) |hub| {
        const memo = resolveContentIdentity(history, allocator, hub_origin, hub.handle, hub.uuid, hub.dir, hub.name);
        hub_ids.append(allocator, memo.uuid) catch @panic("failed to collect hub uuid");
        hub_dirs.append(allocator, memo.dir) catch @panic("failed to collect hub dir");
        // The hub fork's whole-dir carry (custom decoration art living
        // in the hub dir; hub.txt itself is written fresh below).
        if (hub.uuid.len > 0 and hub.dir.len > 0 and !std.mem.eql(u8, memo.dir, hub.dir)) {
            const carry_source = std.fmt.allocPrint(allocator, "{s}/hubs/{s}", .{ editor.campaign_dir, hub.dir }) catch
                @panic("failed to build hub carry source");
            defer allocator.free(carry_source);
            const carry_destination = std.fmt.allocPrint(allocator, "{s}/hubs/{s}", .{ campaign_memo.dir, memo.dir }) catch
                @panic("failed to build hub carry destination");
            defer allocator.free(carry_destination);
            if (!copyDirFiles(history, allocator, carry_source, carry_destination, null)) {
                surfaceSaveError(history, "failed to carry the opened hub's files into the fork");
                return null;
            }
        }
    }

    // 1. Missions first (the lean mission.txt - the name sync; it is
    //    CONTENT-EQUIVALENT to the mission editor's own mission.txt,
    //    which writes exactly the same three keys: version + uuid +
    //    name, both resolving the uuid through the same memo - so this
    //    write never clobbers the hand-off save's file, it only lands
    //    map-side renames into it. A FRESH mission additionally gets
    //    level_1.txt - the default template, verbatim - and
    //    deliberately NO player.txt: the loader's max-default fallback,
    //    the loadout authored via the hand-off).
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
            return null;
        };
        // The cosmetic dir tidy (the hub loop's mirror): a loaded dir
        // whose resolved dir differs is renamed in passing, only when
        // the target is free (a collision keeps the old name).
        if (mission.dir.len > 0 and !std.mem.eql(u8, mission.dir, mission_dirs.items[mission_index])) {
            const old_path = std.fmt.allocPrint(
                allocator,
                "{s}/missions/{s}",
                .{ campaign_memo.dir, mission.dir },
            ) catch @panic("failed to format mission tidy old path");
            history.file_source.renameDir(old_path, mission_dir_path) catch {};
        }
        if (mission_needs_template.items[mission_index]) {
            const default_level = history.file_source.readFile(allocator, "data/default_level.txt") catch {
                surfaceSaveError(history, "failed to read the default level template");
                return null;
            };
            const level_path = std.fmt.allocPrint(
                allocator,
                "{s}/level_1.txt",
                .{mission_dir_path},
            ) catch @panic("failed to format level_1 path");
            history.file_source.writeFile(level_path, default_level) catch {
                surfaceSaveError(history, "failed to write the fresh mission's default level");
                return null;
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
            return null;
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
    if (!writeCampaignGraphFile(history, allocator, editor, campaign_memo, hub_ids.items, mission_ids.items)) {
        return null;
    }

    // 4. The deletion reconciliation.
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

    // 5. The campaign root's cosmetic dir tidy (the mission/hub save's
    // mirror): the dir follows the campaign's CURRENT name. The tidy rides
    // only the FULL save - the name lives in campaign.txt, which only this
    // save rewrites (a hand-off/hub save resolving the campaign identity
    // never renames the root out from under a campaign.txt it doesn't
    // write). After the config writes succeed (content is the truth, the
    // rename is cosmetics), only when the canonical target is free (a
    // collision keeps the old dir - the duplicate-uuid sibling rule). A
    // fresh-mint identity already carries the canonical dir (the mint
    // built it from the current name), so only an in-place save of a
    // RENAMED campaign takes this path.
    const sanitized_name = sanitizeNameForDir(editor.campaign_name, allocator);
    const canonical_dir = std.fmt.allocPrint(
        allocator,
        "campaigns/{s}_{s}",
        .{ campaign_memo.uuid, sanitized_name },
    ) catch @panic("failed to format canonical campaign dir");
    var saved_dir = campaign_memo.dir;
    if (!std.mem.eql(u8, campaign_memo.dir, canonical_dir)) {
        if (history.file_source.renameDir(campaign_memo.dir, canonical_dir)) |_| {
            saved_dir = canonical_dir;
            // The session continues under the RENAMED dir (the fork
            // memo's rule: the state still carries the original dir, so
            // the memo carries the rename forward - last-wins).
            appendCampaignSaveMemo(history, .{
                .handle = types.campaign_save_memo_handle,
                .uuid = campaign_memo.uuid,
                .dir = canonical_dir,
            });
        } else |_| {} // collision / platform failure: keep the old dir
    }

    // The session continues under the SAVED identity (a fork's saves hit
    // the fork; a rename's too) - the memo carries it; ALSO the browser
    // lists need a rescan next open (they rescan on open anyway).
    // A save otherwise reads as silence (the screen does not change);
    // the toast is the confirmation. A caller that continues into a
    // bigger flow (Validate, Export) overwrites it with its own, more
    // specific toast - single-slot by design.
    history.session.setToast(history.history_arena.allocator(), "Campaign saved");
    return saved_dir;
}

/// Write campaign.txt from the live authored graph (the table projection
/// shared by the campaign save and the mission-context save - ONE writer,
/// so the two paths can never drift). `hub_uuids` / `mission_uuids` are the
/// CALLER's resolved identities (each save owns its resolution machinery);
/// failures surface the standard save popup.
fn writeCampaignGraphFile(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    editor: types.CampaignEditor,
    campaign_memo: types.CampaignSaveMemo,
    hub_uuids: []const []const u8,
    mission_uuids: []const []const u8,
) bool {
    const campaign_txt = writers.writeCampaignFile(
        editor,
        .{
            .campaign_uuid = campaign_memo.uuid,
            .hub_uuids = hub_uuids,
            .mission_uuids = mission_uuids,
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
        return false;
    };
    return true;
}

/// The mission-context save's graph write: campaign.txt must never LAG a
/// mission dir a save just persisted (the motivating authoring flow:
/// delete an edge, place a new one, save the mission from the mission
/// editor - the mission dir landed orphaned while the table kept
/// referencing the DELETED edge; the campaign only became consistent at
/// the next full save). Gated on the IN-PLACE rule: the save landed in
/// the campaign's OPENED, listed dir. A minted fork stays invisible -
/// no campaign.txt until the full save (the root-carry rule's
/// complement - `campaignMissionSaveTarget` carries everything EXCEPT
/// campaign.txt).
///
/// Identities resolve through the shared memo machinery: loaded content
/// stays in place; fresh content MINTS + memos here, so the later full
/// save reuses the same identity and skips the fresh-mission template
/// write. A fresh hub or mission minted here has no content file yet -
/// a load-side validation finding, never a save blocker (the
/// finalized-campaign doctrine).
pub fn saveCampaignGraphAtMissionSave(
    history: *GameStateHistory,
    campaign: types.CampaignEditor,
) bool {
    const allocator = history.current_arena.allocator();
    const campaign_memo = resolveCampaignIdentity(history, allocator, campaign);
    if (!std.mem.eql(u8, campaign_memo.dir, campaign.campaign_dir)) return true;

    var mission_uuids: std.ArrayList([]const u8) = .empty;
    const mission_origin = ContentOrigin{
        .opened_campaign_dir = campaign.campaign_dir,
        .save_target_dir = campaign_memo.dir,
        .kind_dir = "missions",
        .config_name = "mission.txt",
    };
    for (campaign.missions) |mission| {
        const memo = resolveContentIdentity(
            history,
            allocator,
            mission_origin,
            mission.handle,
            mission.uuid,
            mission.dir,
            mission.name,
        );
        mission_uuids.append(allocator, memo.uuid) catch
            @panic("failed to collect mission uuid");
    }
    var hub_uuids: std.ArrayList([]const u8) = .empty;
    const hub_origin = ContentOrigin{
        .opened_campaign_dir = campaign.campaign_dir,
        .save_target_dir = campaign_memo.dir,
        .kind_dir = "hubs",
        .config_name = "hub.txt",
    };
    for (campaign.hubs) |hub| {
        const memo = resolveContentIdentity(
            history,
            allocator,
            hub_origin,
            hub.handle,
            hub.uuid,
            hub.dir,
            hub.name,
        );
        hub_uuids.append(allocator, memo.uuid) catch
            @panic("failed to collect hub uuid");
    }
    return writeCampaignGraphFile(history, allocator, campaign, campaign_memo, hub_uuids.items, mission_uuids.items);
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

/// Validate the SAVED campaign files - the file-level certification (the
/// mission editor's Validate contract: save first, then certify exactly
/// the files a player receives). Runs the load-side pipeline over the
/// saved dir through PLAIN file-source reads (the input layer owns this
/// side effect; nothing is recorded, so the reconstruction cache stays
/// uninvolved - the import-read precedent), collecting:
///   - the graph findings (`loaders.checkCampaignGraph` + the derive's
///     inline orphan warnings - stubs, orphans, markerless missions,
///     unresolvable missions, unreachable hubs; the finalized-campaign
///     doctrine)
///   - the hub-content findings (`loaders.checkHubContent` over every
///     resolved hub's saved file - off-grid markers/NPCs, stacked
///     placements, decoration footprints on walkable ground or on each
///     other; the belt-and-braces layer over the edit-time planners)
///   - every declared mission's validation replay
///     (`validation_replay.checkMissionValidationArtifact` - a missing or
///     stale replay reads as unvalidated)
/// Findings surface as one popup through the standard warning surface; a
/// clean campaign gets the success TOAST (fire-and-forget - the
/// Revalidate-success precedent, upgraded from its old modal popup).
pub fn validateSavedCampaign(
    history: *GameStateHistory,
    campaign_content_dir: []const u8,
) void {
    const allocator = history.current_arena.allocator();
    var warnings: std.ArrayList([]const u8) = .empty;

    const campaign_txt_path = std.fmt.allocPrint(allocator, "{s}/campaign.txt", .{campaign_content_dir}) catch
        @panic("failed to allocate campaign.txt path");
    const campaign_bytes = history.file_source.readFile(allocator, campaign_txt_path) catch {
        surfaceSaveError(history, "validation failed: could not read the saved campaign.txt");
        return;
    };
    const sections = parser.parseConfigFile(campaign_bytes, allocator, &parser.campaign_sections) catch {
        surfaceSaveError(history, "validation failed: the saved campaign.txt is malformed");
        return;
    };
    var campaign = loaders.loadCampaign(sections, campaign_content_dir, allocator, &warnings) catch {
        surfaceSaveError(history, "validation failed: the saved campaign.txt is malformed");
        return;
    };
    loaders.resolveCampaignHubs(&campaign, history.file_source, allocator, &warnings);
    campaign.missions = loaders.resolveCampaignMissions(campaign, history.file_source, allocator, &warnings);
    loaders.deriveCampaignEdges(&campaign, sections, history.file_source, allocator, &warnings);
    loaders.checkCampaignGraph(campaign, allocator, &warnings);
    validateCampaignHubs(history, campaign, allocator, &warnings);
    validateCampaignMissions(history, sections, campaign, allocator, &warnings);

    if (warnings.items.len == 0) {
        // The success signal is a toast, not the modal popup it once was
        // (fire-and-forget: nothing to acknowledge on a clean bill).
        history.session.setToast(
            history.history_arena.allocator(),
            "Campaign validated - no findings",
        );
        return;
    }
    shared.surfaceWarnings(history, &warnings, allocator);
}

/// The hub-content findings (DESIGN → The hub editor surface →
/// Validation): every RESOLVED hub's file is read + loaded through the
/// same load-side pipeline a player's session uses, then the pure
/// `loaders.checkHubContent` certifies its content (off-grid markers /
/// NPCs, stacked placements, decoration footprints on walkable ground or
/// on each other). Unresolved hub dirs are skipped (the graph checks
/// already named them).
fn validateCampaignHubs(
    history: *GameStateHistory,
    campaign: types.Campaign,
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]const u8),
) void {
    for (campaign.hubs) |hub_entry| {
        if (hub_entry.dir.len == 0) continue;
        const hub_txt_path = std.fmt.allocPrint(
            allocator,
            "campaigns/{s}/hubs/{s}/hub.txt",
            .{ campaign.dir, hub_entry.dir },
        ) catch @panic("failed to format hub.txt validation path");
        const hub_bytes = history.file_source.readFile(allocator, hub_txt_path) catch {
            appendValidationWarning(allocator, warnings, "hub '{s}': could not read the saved hub.txt", .{hub_entry.name});
            continue;
        };
        const hub_sections = parser.parseConfigFile(hub_bytes, allocator, &parser.hub_sections) catch {
            appendValidationWarning(allocator, warnings, "hub '{s}': the saved hub.txt is malformed", .{hub_entry.name});
            continue;
        };
        const hub = loaders.loadHub(hub_sections, history.file_source, allocator, hub_txt_path, warnings) catch {
            appendValidationWarning(allocator, warnings, "hub '{s}': the saved hub.txt failed to load", .{hub_entry.name});
            continue;
        };
        loaders.checkHubContent(hub, allocator, warnings);
    }
}

/// Every mission the campaign DECLARES (the Missions section) must carry
/// a validation replay certifying its current content - the finalized-
/// campaign standard. Unresolved missions are skipped here (the graph
/// checks already named them); `entry.dir` is the scan table's full
/// content-relative mission path, the convention
/// `checkMissionValidationArtifact` + `computeMissionHash` take.
fn validateCampaignMissions(
    history: *GameStateHistory,
    sections: []const parser.Section,
    campaign: types.Campaign,
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]const u8),
) void {
    const missions_section = parser.findSection(sections, "Missions") orelse return;
    for (missions_section.entry_groups) |group| {
        const mission_uuid = parser.findValue(group.pairs, "mission_uuid") orelse continue;
        if (mission_uuid.len == 0) continue;
        var resolved: ?types.CampaignMissionEntry = null;
        for (campaign.missions) |entry| {
            if (std.mem.eql(u8, entry.uuid, mission_uuid)) {
                resolved = entry;
                break;
            }
        }
        const entry = resolved orelse continue;
        const status = validation_replay.checkMissionValidationArtifact(
            history.file_source,
            allocator,
            mission_uuid,
            entry.dir,
        );
        const label = if (entry.name.len > 0) entry.name else mission_uuid;
        switch (status) {
            .validated => {},
            .missing => appendValidationWarning(allocator, warnings, "mission '{s}': no validation replay - run Validate in the mission editor", .{label}),
            .malformed => appendValidationWarning(allocator, warnings, "mission '{s}': the stored validation replay is malformed", .{label}),
            .wrong_mission => appendValidationWarning(allocator, warnings, "mission '{s}': the stored validation replay belongs to a different mission", .{label}),
            .content_changed => appendValidationWarning(allocator, warnings, "mission '{s}': the mission changed since its validation run - re-run Validate", .{label}),
        }
    }
}

/// Append one formatted validation warning (the load.zig `warn` shape:
/// format + append both swallow allocation failure - warnings are
/// advisory, never a crash path).
fn appendValidationWarning(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]const u8),
    comptime format: []const u8,
    args: anytype,
) void {
    const message = std.fmt.allocPrint(allocator, format, args) catch return;
    warnings.append(allocator, message) catch {};
}

/// Save the drilled-in hub's hub.txt ONLY (the hub editor's ctrl+S - the
/// save-granularity-per-screen rule, see DESIGN → The editor save
/// model): the same writer + identity resolution as the full campaign
/// save, with the SKIP-UNSAVED-REFERENCES rule - exit entries whose
/// mission has no minted uuid yet (never saved) are omitted from the
/// written Exits section (and the grid's marker cells - the writer's
/// parallel gate) + warned; they stay in the editor graph and land at
/// the next full save. A partial save never deletes anything and never
/// creates campaign structure: a hub with no on-disk identity (no uuid
/// or dir - never saved by a full campaign save) writes nothing and
/// says so. The mission-save class: a pure input-layer side effect, no
/// recorded event, never replayed.
pub fn saveHubEditor(history: *GameStateHistory) void {
    const allocator = history.current_arena.allocator();
    const editor = history.current_state.campaign_editor orelse return;
    const hub_editor_state = history.current_state.hub_editor orelse return;
    var drilled: ?types.CampaignHubEdit = null;
    for (editor.hubs) |candidate_hub| {
        if (candidate_hub.handle == hub_editor_state.hub) drilled = candidate_hub;
    }
    const hub = drilled orelse {
        surfaceSaveError(history, "the drilled-in hub no longer resolves - nothing saved");
        return;
    };
    // The campaign's save target, SELF-SERVED (the drill-in save
    // rule): resolveCampaignIdentity returns the session's memo when
    // one exists, the state identity when the opened campaign is on
    // disk, and otherwise MINTS + memos a fresh identity right here -
    // so a hub-only save never gates on a prior full save. A fresh or
    // official-origin campaign gets the root carry (the full save's
    // own fork carry, same helper); writeFile mkdir-p materializes the
    // target dirs. The fork's transient hub.txt may reference mission
    // uuids that resolve only under the opened original - inert: a
    // campaign dir without campaign.txt never lists, and the next full
    // save rewrites the file with the resolved identities.
    const campaign_memo = resolveCampaignIdentity(history, allocator, editor);
    const campaign_dir = campaign_memo.dir;
    if (!std.mem.eql(u8, campaign_memo.dir, editor.campaign_dir)) {
        const carried_campaign_txt = std.fmt.allocPrint(
            allocator,
            "{s}/campaign.txt",
            .{campaign_memo.dir},
        ) catch @panic("failed to build carried campaign.txt path");
        defer allocator.free(carried_campaign_txt);
        if (!file_source_mod.persistentFileExists(history.file_source, carried_campaign_txt)) {
            // campaign.txt is excluded (the carry's exclude_name contract):
            // this save writes no campaign.txt, so a carried one would
            // make the fork LIST under the opened campaign's stale graph
            // (art files are the carry's real job - the background).
            if (!copyDirFiles(history, allocator, editor.campaign_dir, campaign_memo.dir, "campaign.txt")) {
                surfaceSaveError(history, "failed to carry the opened campaign's files into the new campaign dir");
                return;
            }
        }
    }

    // Resolve THIS hub's identity through the full save's own machinery
    // (a saved hub reuses its memo; a never-saved hub MINTS its uuid +
    // canonical dir, memoized so the next full save resolves the same
    // identity). The hub lands unlisted in campaign.txt's Hubs section
    // until that full save catches up - the same eventual-consistency
    // class as the skipped exit markers below.
    const hub_memo = resolveContentIdentity(
        history,
        allocator,
        .{
            .opened_campaign_dir = editor.campaign_dir,
            .save_target_dir = campaign_dir,
            .kind_dir = "hubs",
            .config_name = "hub.txt",
        },
        hub.handle,
        hub.uuid,
        hub.dir,
        hub.name,
    );

    // The identities: each entity's OWN state identity - only this hub's
    // uuid + the exit-referenced missions' uuids are read by the writer;
    // an empty mission uuid is the exit-skip gate's input (never-saved).
    var hub_uuids: std.ArrayList([]const u8) = .empty;
    for (editor.hubs) |candidate_hub| {
        // THIS hub resolves through the memo (a minted identity for a
        // never-saved hub); the others ride their own state uuids.
        hub_uuids.append(
            allocator,
            if (candidate_hub.handle == hub.handle) hub_memo.uuid else candidate_hub.uuid,
        ) catch @panic("failed to collect hub uuids");
    }
    var mission_uuids: std.ArrayList([]const u8) = .empty;
    for (editor.missions) |mission| {
        mission_uuids.append(allocator, mission.uuid) catch @panic("failed to collect mission uuids");
    }

    // Count the skipped exits for the never-silent warning (the writer's
    // gate, computed here over the same conditions).
    var skipped_exits: usize = 0;
    for (hub.grid.exit_placements) |placement| {
        for (editor.missions, 0..) |mission, mission_index| {
            if (mission.handle != placement.mission) continue;
            if (mission.start == null or mission.start.? != hub.handle) continue;
            if (mission_uuids.items[mission_index].len == 0) skipped_exits += 1;
        }
    }

    const hub_dir_path = std.fmt.allocPrint(
        allocator,
        "{s}/hubs/{s}",
        .{ campaign_dir, hub_memo.dir },
    ) catch @panic("failed to format hub dir path");
    const hub_txt = writers.writeCampaignHub(
        editor,
        hub,
        .{
            .campaign_uuid = "",
            .hub_uuids = hub_uuids.items,
            .mission_uuids = mission_uuids.items,
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
        surfaceSaveError(history, "failed to write the hub's file");
        return;
    };

    if (skipped_exits > 0) {
        const message = std.fmt.allocPrint(
            allocator,
            "hub saved - {d} exit marker(s) skipped (their mission(s) were never saved; a full campaign save places them)",
            .{skipped_exits},
        ) catch @panic("failed to format the skip warning");
        surfaceSaveError(history, message);
    }
}

/// Export the edited campaign as a .zip (the campaign editor's
/// options-menu Export Campaign button - button-only, no keybind): FULL
/// SAVE first (the settled order - the bundle is always the current
/// state; the save also forks official-origin content into a persistent
/// dir, so the walk below reads everything from one persistent tree),
/// then bundle EVERY file under the campaign dir (recursive - campaign
/// root + hubs/ + missions/ + all bundled art; the archive names are
/// the campaign's own content paths minus the campaign dir prefix, so
/// the import extracts symmetrically) into a STORE archive at
/// `exported_campaigns/<uuid>_<name>.zip` in the persistent dir. On web
/// that file is then offered as a browser download (the Export Mission
/// seam). A pure side effect (the dump_event_log class). See DESIGN →
/// Campaigns & the Campaign Editor → The mission-editor hand-off.
pub fn exportCampaignEditor(history: *GameStateHistory) void {
    const saved_dir = saveCampaignEditor(history) orelse return;
    const editor = history.current_state.campaign_editor orelse return;
    const scratch = history.current_arena.allocator();

    const fail = struct {
        fn note(history_arg: *GameStateHistory, reason: []const u8) void {
            history_arg.session.setPendingError(
                history_arg.history_arena.allocator(),
                reason,
            );
        }
    };

    // The walk: the whole persistent dir's recursive listing, filtered
    // to the campaign's subtree (the save landed everything there
    // persistently - root carries, hub carries, the mission saves; the
    // Export Game walker, prefix-scoped).
    const all_paths = history.file_source.listPersistentDirFiles(scratch) catch {
        fail.note(history, "failed to export: could not list the campaign's files");
        return;
    };
    var entries: std.ArrayList(zip_writer.ZipEntry) = .empty;
    const prefix = std.fmt.allocPrint(scratch, "{s}/", .{saved_dir}) catch
        @panic("failed to allocate campaign export prefix");
    for (all_paths) |path| {
        if (!std.mem.startsWith(u8, path, prefix)) continue;
        const archive_name = path[prefix.len..];
        const bytes = history.file_source.readFile(scratch, path) catch {
            fail.note(history, "failed to export: could not read a campaign file");
            return;
        };
        entries.append(scratch, .{ .name = archive_name, .bytes = bytes }) catch
            @panic("failed to append campaign export entry");
    }
    if (entries.items.len == 0) {
        fail.note(history, "failed to export: the campaign has no files on disk");
        return;
    }

    const archive = zip_writer.writeZipArchive(entries.items, scratch) catch {
        fail.note(history, "failed to export: could not build the zip archive");
        return;
    };
    const sanitized = sanitizeNameForDir(editor.campaign_name, scratch);
    const campaign_uuid = resolveCampaignIdentity(history, scratch, editor).uuid;
    const zip_path = std.fmt.allocPrint(
        scratch,
        "exported_campaigns/{s}_{s}.zip",
        .{ campaign_uuid, sanitized },
    ) catch @panic("failed to allocate campaign export zip path");
    history.file_source.writeFile(zip_path, archive) catch {
        fail.note(history, "failed to export: could not write the zip file");
        return;
    };
    // Web: offer it as a download (reads it back from the mounted FS);
    // native: a comptime no-op.
    file_source_mod.triggerBrowserDownload(scratch, zip_path, std.fs.path.basename(zip_path));

    // The save-first leg already toasted "Campaign saved"; the export's
    // own, more specific toast overwrites it (single-slot by design) -
    // without this, the flow's only signal is the browser download bar.
    history.session.setToast(history.history_arena.allocator(), "Campaign exported");
}

/// Consume the campaign-import marker, if present: the picked .zip has
/// landed in imported_campaigns/ - delete the marker, extract the zip
/// into campaigns/ (see importCampaignFromZip), and rescan both campaign
/// browser lists so the row appears. Mirrors pollMissionImportMarker
/// (the web-only upload lands the zip + marker; the extraction is
/// platform-neutral file I/O; a failure surfaces the popup and keeps
/// the zip).
pub fn pollCampaignImportMarker(history: *GameStateHistory) void {
    const marker = file_source_mod.campaign_import_marker_path;
    if (!history.file_source.fileExists(marker)) return;

    const scratch = history.current_arena.allocator();
    const marker_bytes = history.file_source.readFile(scratch, marker) catch {
        history.file_source.deleteFile(marker) catch {};
        return;
    };
    history.file_source.deleteFile(marker) catch {};
    importCampaignFromZip(history, std.mem.trim(u8, marker_bytes, " \r\n\t"));
}

/// The campaign import caps (the mission import family's values - a
/// campaign is a superset of a mission: configs + art for every hub +
/// every mission; the same generous headroom).
const campaign_import_max_entries: usize = 1024;
const campaign_import_max_entry_bytes: usize = 64 * 1024 * 1024;
const campaign_import_max_total_bytes: usize = 256 * 1024 * 1024;

/// Extract one campaign zip into `campaigns/<uuid>_<sanitized name>/`
/// (the campaign save's dir convention - a re-import of the same zip
/// overwrites the same dir, idempotent; a duplicate campaign uuid from
/// a DIFFERENT dir imports as a second dir - the scan's latest-wins
/// tolerance, never refused). The pass structure mirrors
/// importMissionFromZip: every cap + every name is validated over the
/// central-directory headers BEFORE the first decode or write; a
/// hostile or malformed zip fails whole, never half-imported.
fn importCampaignFromZip(history: *GameStateHistory, zip_path: []const u8) void {
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
    // data) - the caps run on these alone, before any decode.
    const headers = zip_reader.readZipEntryHeaders(zip_bytes, scratch) catch {
        fail.note(history, "failed to import: the zip is corrupt or uses an unsupported format");
        return;
    };
    if (headers.len > campaign_import_max_entries) {
        fail.note(history, "failed to import: the zip has too many files");
        return;
    }
    var total_bytes: usize = 0;
    for (headers) |header| {
        if (header.uncompressed_size > campaign_import_max_entry_bytes) {
            fail.note(history, "failed to import: a file in the zip is too large");
            return;
        }
        total_bytes += header.uncompressed_size;
    }
    if (total_bytes > campaign_import_max_total_bytes) {
        fail.note(history, "failed to import: the zip is too large to import");
        return;
    }

    // Filter OS junk, then strip a single common root folder (an
    // OS-made zip of the extracted folder).
    var file_headers: std.ArrayList(zip_reader.ZipEntryHeader) = .empty;
    for (headers) |header| {
        if (!zip_reader.isOsZipJunkEntry(header.name)) file_headers.append(scratch, header) catch
            @panic("failed to collect zip entries");
    }
    zip_reader.stripCommonRootFolder(file_headers.items);
    const stripped = file_headers.items;

    // Validate every name up front (nothing decoded, nothing written on
    // any bad entry).
    for (stripped) |header| {
        if (zip_reader.isUnsafeZipEntryName(header.name)) {
            const message = std.fmt.allocPrint(
                history.history_arena.allocator(),
                "failed to import: unsafe file name in the zip ({s})",
                .{header.name},
            ) catch "failed to import: unsafe file name in the zip";
            fail.note(history, message);
            return;
        }
    }

    // The campaign's identity: campaign.txt at the (stripped) archive
    // root. Entries are decoded one at a time from here on (the
    // per-entry reset arena keeps memory at one entry through the
    // whole import).
    const campaign_txt_header = blk: for (stripped) |header| {
        if (std.mem.eql(u8, header.name, "campaign.txt")) break :blk header;
    } else {
        fail.note(history, "failed to import: the zip has no campaign.txt at its root");
        return;
    };
    var entry_arena = std.heap.ArenaAllocator.init(history.backing_allocator);
    defer entry_arena.deinit();
    const campaign_txt = zip_reader.extractZipEntry(
        zip_bytes,
        entry_arena.allocator(),
        campaign_txt_header,
    ) catch {
        fail.note(history, "failed to import: could not read campaign.txt from the zip (it may be corrupt)");
        return;
    };
    _ = entry_arena.reset(.retain_capacity);

    const sections = parser.parseConfigFile(campaign_txt.bytes, scratch, &parser.campaign_sections) catch {
        fail.note(history, "failed to import: the zip's campaign.txt is not valid");
        return;
    };
    // The identity fields only (name + uuid) - the campaign dir stem
    // derivation; the graph itself resolves against the EXTRACTED files
    // when the campaign is opened, never at import.
    const campaign = loaders.loadCampaign(sections, "", scratch, null) catch {
        fail.note(history, "failed to import: the zip's campaign.txt is not valid");
        return;
    };

    // The target dir, derived exactly like the campaign save's mint.
    const sanitized = sanitizeNameForDir(campaign.name, scratch);
    var name_prefix: []const u8 = sanitized;
    if (campaign.uuid.len > 0) {
        name_prefix = std.fmt.allocPrint(
            scratch,
            "{s}_{s}",
            .{ campaign.uuid, sanitized },
        ) catch @panic("failed to allocate imported campaign dir path");
    }
    const dir_path = std.fmt.allocPrint(
        scratch,
        "campaigns/{s}",
        .{name_prefix},
    ) catch @panic("failed to allocate imported campaign dir path");

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
            @panic("failed to allocate imported campaign file path");
        history.file_source.writeFile(file_path, entry.bytes) catch {
            const message = std.fmt.allocPrint(
                history.history_arena.allocator(),
                "failed to import: could not write {s}",
                .{entry.name},
            ) catch "failed to import: could not write a campaign file";
            fail.note(history, message);
            return;
        };
        _ = entry_arena.reset(.retain_capacity);
    }

    // Success: the zip has served its purpose (delete it - the
    // extracted folder is the artifact), and both campaign browser
    // lists rescan so the row appears immediately.
    history.file_source.deleteFile(zip_path) catch {};
    shared.rescanCampaignBrowserLists(history);
}

fn surfaceSaveError(history: *GameStateHistory, message: []const u8) void {
    history.session.setPendingError(history.history_arena.allocator(), message);
}

const writers = @import("../writers.zig");
const zip_writer = @import("../zip_writer.zig");
const zip_reader = @import("../zip_reader.zig");
