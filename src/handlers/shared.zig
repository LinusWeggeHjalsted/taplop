//! Cross-category event-handler helpers shared by the dispatch
//! (event_handlers.zig), the player-input handler, and the editor
//! handlers (editor/handlers.zig): entity accessors, the recoverable
//! reconstruction-read failure (popup + revert flag), config-key
//! validation + warning surfacing, the campaign load, and the gameplay
//! start batch. A policy layer over state.zig's history machinery -
//! imports nothing back from the handlers.

const std = @import("std");
const types = @import("../types.zig");
const events = @import("../events.zig");
const state = @import("../state.zig");
const parser = @import("../parser.zig");
const file_source_mod = @import("../file_source.zig");
const loaders = @import("../loaders.zig");
const functions = @import("../functions.zig");
const event_push = @import("../event_push.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;
const Entity = types.Entity;

const pushEvents = event_push.pushEvents;

/// Set by a reconstruction-read handler when its config read or parse
/// fails during LIVE play. Sets the user-facing pending_error (the
/// descriptive `message`, duped into history_arena so it survives the
/// revert) + the `load_error` flag (the drain loop checks it and reverts).
/// During replay, panics instead (fail-fast - a reconstruction-read
/// failure during replay is unexpected; in-session replay has cached bytes,
/// and cross-session bundle replay serves the embedded copies).
/// See DESIGN → Error Handling → three contexts.
pub fn failReconstructionRead(history: *GameStateHistory, message: []const u8) void {
    if (history.replaying) @panic("replay: reconstruction read failed (content changed?)");
    history.session.setPendingError(history.history_arena.allocator(), message);
    history.load_error = true;
}

/// Surface collected warnings (key-validation or balance-bound) as a single
/// `pending_error` popup. No-op when the list is empty or during replay.
pub fn surfaceWarnings(
    history: *GameStateHistory,
    warnings: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) void {
    if (history.replaying) return;
    if (warnings.items.len == 0) return;
    var message: std.ArrayList(u8) = .empty;
    for (warnings.items, 0..) |warning, index| {
        if (index > 0) message.appendSlice(allocator, "\n") catch
            @panic("failed to assemble warning message");
        message.appendSlice(allocator, warning) catch
            @panic("failed to assemble warning message");
    }
    history.session.setPendingError(history.history_arena.allocator(), message.items);
}

/// Run key validation on `sections` and, if any unknown keys are found,
/// surface them as a pending_error popup. Advisory - the load continues
/// regardless (unknown keys are dropped, not fatal). Gated on !replaying
/// so undo/redo doesn't re-surface warnings from the recording. See AGENTS
/// → Error Handling → key validation.
pub fn validateConfigKeys(
    history: *GameStateHistory,
    sections: []const parser.Section,
    key_map: std.StaticStringMap([]const []const u8),
    file_path: []const u8,
    allocator: std.mem.Allocator,
) void {
    if (history.replaying) return;
    var key_warnings: std.ArrayList([]const u8) = .empty;
    parser.validateKeys(sections, key_map, file_path, allocator, &key_warnings);
    surfaceWarnings(history, &key_warnings, allocator);
}

/// Get a mutable pointer to the player entity, whether in a level or hub.
pub fn getPlayerEntity(
    current: *GameState,
    entity_index: u32,
) *Entity {
    if (current.level) |*level| {
        return &@constCast(level.entities)[entity_index];
    } else if (current.hub) |*hub| {
        return &hub.player;
    }
    @panic("getPlayerEntity called with no level or hub");
}

/// Get a mutable pointer to an entity in the current level.
pub fn getLevelEntity(
    current: *GameState,
    entity_index: u32,
) *Entity {
    if (current.level) |*level| {
        return &@constCast(level.entities)[entity_index];
    }
    @panic("getLevelEntity called with no level");
}

/// Load the ACTIVE campaign's graph through the reconstruction cache and
/// install it on GameState: parse campaign.txt, run the resolution scans,
/// derive the edge table + background dims, run the integrity checks,
/// surface warnings, and update the PlayerData identity fields. Shared by
/// `loadCampaignAndPushHub` (the continue/load-save path - reads the
/// PLAYER'S current campaign) and the `install_campaign` handler (the
/// world-map cross-campaign switch - reads the event's named campaign).
/// A read/parse failure takes the recoverable reconstruction-read path
/// (popup + revert via `failReconstructionRead`); null on `current.campaign`
/// afterward means it fired. `campaign_dir` is the campaign's dir name
/// under campaigns/.
pub fn installCampaignGraph(
    current: *GameState,
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    campaign_dir: []const u8,
) void {
    // Build campaign file path: campaigns/{campaign_id}/campaign.txt -
    // content-root-relative (the official campaign resolves through the
    // embedded `data/`-prefix bridge; custom campaigns live in the
    // persistent dir at the same shape). See DESIGN → Campaigns & the
    // Campaign Editor → Campaign content paths.
    const campaign_path = std.fmt.allocPrint(
        allocator,
        "campaigns/{s}/campaign.txt",
        .{campaign_dir},
    ) catch @panic("failed to allocate campaign path");
    // The campaign's content dir (the background mint + the integrity
    // checks' hub/mission reads resolve from here).
    const campaign_dir_path = std.fs.path.dirname(campaign_path) orelse
        @panic("campaign path has no directory component");

    const campaign_sections = blk: {
        const bytes = history.readReconstructionFile(campaign_path) catch {
            failReconstructionRead(history, "failed to read campaign file");
            return;
        };
        break :blk parser.parseConfigFile(bytes, allocator, &parser.campaign_sections) catch {
            failReconstructionRead(history, "failed to parse campaign file");
            return;
        };
    };
    validateConfigKeys(history, campaign_sections, parser.campaign_key_map, campaign_path, allocator);
    var campaign_warnings: std.ArrayList([]const u8) = .empty;
    current.campaign = loaders.loadCampaign(
        campaign_sections,
        campaign_dir_path,
        allocator,
        &campaign_warnings,
    ) catch {
        failReconstructionRead(history, "failed to parse campaign file");
        return;
    };

    // The uuid resolution scans (hub dirs + the mission table): the
    // LOADING side runs them live; the results ride GameState as the
    // resolution tables recorded handlers read (replay never scans -
    // see DESIGN → Campaigns & the Campaign Editor → Uuid→dir
    // resolution).
    loaders.resolveCampaignHubs(&current.campaign.?, history.file_source, allocator, &campaign_warnings);
    current.campaign.?.missions = loaders.resolveCampaignMissions(
        current.campaign.?,
        history.file_source,
        allocator,
        &campaign_warnings,
    );

    // The derived edge table + hub display names (the graph the map view
    // renders + map-acting legality reads - one walk over the resolved
    // hubs' hub.txt, missions resolved through the table above).
    loaders.deriveCampaignEdges(&current.campaign.?, history.file_source, allocator, &campaign_warnings);
    loaders.resolveCampaignBackgroundDims(&current.campaign.?, history.file_source, allocator, &campaign_warnings);

    // Graph integrity checks (dangling destinations, unresolvable
    // missions, unplaced/unreachable hubs - pure over the derived edge
    // table, warn-only).
    loaders.checkCampaignGraph(current.campaign.?, allocator, &campaign_warnings);
    surfaceWarnings(history, &campaign_warnings, allocator);

    // The PlayerData identity fields follow the installed graph.
    current.player_data.current_campaign = current.campaign.?.dir;
    current.player_data.current_campaign_uuid = current.campaign.?.uuid;
}

/// Load the player's current campaign (through the reconstruction cache)
/// and push start_hub for `player_data.current_hub` - the continue /
/// load-save resume path over `installCampaignGraph`.
pub fn loadCampaignAndPushHub(
    current: *GameState,
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
) void {
    const resume_uuid = current.player_data.current_campaign_uuid;
    installCampaignGraph(current, history, allocator, current.player_data.current_campaign);
    if (current.campaign == null) return; // the recoverable-read path fired

    // Verify the save's campaign identity against the loaded campaign
    // (a mismatch means the dir's content changed under the save - the
    // shadow case; warn + proceed, the untrusted-content posture).
    if (resume_uuid.len > 0 and
        current.campaign.?.uuid.len > 0 and
        !std.mem.eql(u8, resume_uuid, current.campaign.?.uuid))
    {
        var campaign_warnings: std.ArrayList([]const u8) = .empty;
        defer campaign_warnings.deinit(allocator);
        campaign_warnings.append(allocator, std.fmt.allocPrint(
            allocator,
            "campaign '{s}' identity changed since the save was written (expected uuid {s}, found {s})",
            .{ current.campaign.?.dir, resume_uuid, current.campaign.?.uuid },
        ) catch @panic("failed to format campaign identity warning")) catch
            @panic("failed to append campaign identity warning");
        surfaceWarnings(history, &campaign_warnings, allocator);
    }

    // Push start_hub with the player's current hub
    const hub_id = current.player_data.current_hub;
    pushEvents(current, &.{.{ .meta_event = .{ .start_hub = .{
        .hub_id = hub_id,
    } } }}, allocator);
}

/// Derive one campaign's full graph for the world-map VIEW cache: parse
/// campaign.txt + the same loader chain the active campaign's load runs
/// (loadCampaign → resolveCampaignHubs → resolveCampaignMissions →
/// deriveCampaignEdges → resolveCampaignBackgroundDims + the integrity
/// check), all through PLAIN file reads (never the reconstruction cache -
/// viewing is session-side acquisition, nothing about it is
/// event-relevant; see DESIGN → Campaigns & the Campaign Editor →
/// Campaign switching). Returns the campaign owned by `allocator` (free
/// via `loaders.freeCampaign`), or null when the campaign.txt is
/// unreadable/unparseable (not viewable - the caller surfaces a popup).
/// `campaign_content_dir` is content-root-relative ("campaigns/<id>" -
/// the CampaignEntry.dir addressing, resolving through readFile's
/// persistent-then-embedded bridge).
pub fn loadCampaignGraph(
    history: *GameStateHistory,
    campaign_content_dir: []const u8,
    allocator: std.mem.Allocator,
) ?types.Campaign {
    const campaign_txt_path = std.fmt.allocPrint(
        allocator,
        "{s}/campaign.txt",
        .{campaign_content_dir},
    ) catch @panic("failed to allocate campaign.txt path");
    defer allocator.free(campaign_txt_path);

    const campaign_bytes = history.file_source.readFile(allocator, campaign_txt_path) catch return null;
    defer allocator.free(campaign_bytes);
    const sections = parser.parseConfigFile(campaign_bytes, allocator, &parser.campaign_sections) catch return null;
    defer parser.freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }
    var campaign = loaders.loadCampaign(sections, campaign_content_dir, allocator, &warnings) catch return null;
    errdefer loaders.freeCampaign(campaign, allocator);
    loaders.resolveCampaignHubs(&campaign, history.file_source, allocator, &warnings);
    campaign.missions = loaders.resolveCampaignMissions(campaign, history.file_source, allocator, &warnings);
    loaders.deriveCampaignEdges(&campaign, history.file_source, allocator, &warnings);
    loaders.resolveCampaignBackgroundDims(&campaign, history.file_source, allocator, &warnings);
    loaders.checkCampaignGraph(campaign, allocator, &warnings);

    // Warn to the popup surface (a broken-but-viewable campaign shows its
    // graph defects - the same posture as the active campaign's load);
    // the graph still renders (warn-only, the loader convention).
    surfaceWarnings(history, &warnings, allocator);
    return campaign;
}

/// Scan both campaign-browser lists into SessionState, freeing the
/// previous local list (the rescanEditorMissionsNow pattern). The LOCAL
/// list is the persistent `campaigns/` dir; the OFFICIAL list is parsed
/// from the embedded map ONCE per session (immutable per build). Runs
/// when the browser OPENS (view stays file-free); reopening is the
/// refresh path. An unreadable dir keeps the previous list.
pub fn rescanCampaignBrowserLists(history: *GameStateHistory) void {
    const allocator = history.backing_allocator;
    if (history.file_source.listCampaigns(allocator)) |local| {
        file_source_mod.freeCampaigns(allocator, history.session.campaign_browser_local);
        history.session.campaign_browser_local = local;
    } else |_| {}
    if (!history.session.campaign_browser_official_scanned) {
        if (history.file_source.listOfficialCampaigns(allocator)) |official| {
            file_source_mod.freeCampaigns(allocator, history.session.campaign_browser_official);
            history.session.campaign_browser_official = official;
            history.session.campaign_browser_official_scanned = true;
        } else |_| {}
    }
}

/// Derive a mission's level count: the largest N such that
/// `{mission_path}/level_1.txt` .. `level_N.txt` all exist, probed
/// consecutively from 1 through `readReconstructionFileOptional` (the
/// absence-tolerant reconstruction read - every hit is cached, and the
/// terminating miss caches a known-absent marker, so replay re-derives
/// the SAME count even if files change mid-session; a plain listing
/// would drift). The level bytes cached here are the ones start_level
/// reads as the mission progresses - the probe adds no IO beyond the
/// terminator. A gap (level_2 missing, level_3 present) truncates the
/// count at 1 - deterministic, documented, broken-content-tolerant.
/// Used by start_mission + start_validation; the non-replay consumers
/// (browser scan, content hash) derive the same rule through
/// file_source directly. Propagates non-FileNotFound read errors (the
/// recoverable-read convention - callers failReconstructionRead).
pub fn countMissionLevelsCached(
    history: *GameStateHistory,
    mission_path: []const u8,
    allocator: std.mem.Allocator,
) !u32 {
    var count: u32 = 0;
    while (true) {
        const level_path = std.fmt.allocPrint(
            allocator,
            "{s}/level_{d}.txt",
            .{ mission_path, count + 1 },
        ) catch @panic("failed to allocate level probe path");
        defer allocator.free(level_path);
        const bytes = try history.readReconstructionFileOptional(level_path);
        if (bytes == null) break;
        count += 1;
    }
    return count;
}

/// Push the gameplay start batch for a freshly-loaded level: player sync
/// (build_player_from_data, runs first) + per-entity aggro checks + the
/// player's turn_start (runs last). Shared by start_level (normal gameplay
/// AND validation runs - sync_player=true - the level's bare player entity
/// gets its loadout from PlayerData; a validation run's player_data was
/// built from the saved player.txt at start_validation, and
/// playerLoadoutEntity maps the same field set, so the sync round-trips
/// the loadout identically) and start_playtest (editor, sync_player=false -
/// the player is already fully instantiated from editor.player_def, so
/// build_player_from_data would clobber it with the campaign's PlayerData).
pub fn pushGameplayStartEvents(current: *GameState, allocator: std.mem.Allocator, sync_player: bool) void {
    var start_events: std.ArrayList(Event) = .empty;
    // Player turn_start at bottom of LIFO (processed last, after sync + aggro).
    start_events.append(allocator, .{ .level_event = .{ .turn_start = .{
        .entity_index = 0,
    } } }) catch @panic("failed to append turn_start");
    // Aggro check: one event scans every inactive entity against its own
    // aggro_range. No `check_level_end` at level start - the player spawn
    // (`!`) and the level end (`=`) are always different tiles.
    start_events.append(allocator, .{ .sub_level_event = .{ .aggro_check = .{} } }) catch
        @panic("failed to append aggro_check event");
    // Player sync on top (processed first) - only for normal gameplay.
    if (sync_player) {
        start_events.append(allocator, .{ .super_event = .{ .build_player_from_data = .{
            .entity_index = 0,
        } } }) catch @panic("failed to append build_player_from_data");
    }
    pushEvents(current, start_events.items, allocator);
}

/// Recompute the reachable tiles shown during the player's move step.
/// No-op unless we're in a level and currently in the .player_move phase
/// (e.g. changing boots in the hub or during the attack step should not
/// touch highlighted_tiles).
pub fn refreshMoveHighlights(
    current: *GameState,
    allocator: std.mem.Allocator,
) void {
    const level = if (current.level) |*level| level else return;
    if (level.turn_phase != .player_move) return;

    const player = level.entities[0];
    level.highlighted_tiles = functions.reachableTiles(
        level.*,
        player.position,
        player.getEffectiveSpeed(),
        allocator,
    );
}

/// Cancel any in-progress skill targeting during the player's attack step.
/// No-op unless we're in a level with a prepared skill. Call this whenever
/// the player's available skills change mid-attack-step (swapping or equipping
/// weapons rewrites the first three skill slots), so a skill prepared from the
/// old weapon does not linger with stale targeting highlights.
pub fn cancelPreparedSkill(current: *GameState) void {
    const level = if (current.level) |*level| level else return;
    if (level.prepared_skill == null) return;

    level.prepared_skill = null;
    level.highlighted_tiles = &.{};
}

/// Resolve a hub uuid to its storage dir through the loaded campaign's
/// table (state; never the filesystem - replay-safe by construction).
/// Null when the campaign isn't loaded or no placed hub matches (a
/// hand-edited dangling reference).
pub fn hubDirForUuid(current: *GameState, hub_uuid: []const u8) ?[]const u8 {
    const campaign = current.campaign orelse return null;
    for (campaign.hubs) |hub| {
        if (std.mem.eql(u8, hub.uuid, hub_uuid) and hub.dir.len > 0) return hub.dir;
    }
    return null;
}

/// Resolve a mission uuid to its dir (basename) through the loaded
/// campaign's mission table. Null when no mission matches (a dangling
/// exit reference - the caller decides the posture).
pub fn missionDirForUuid(current: *GameState, mission_uuid: []const u8) ?[]const u8 {
    const campaign = current.campaign orelse return null;
    for (campaign.missions) |mission| {
        if (std.mem.eql(u8, mission.uuid, mission_uuid)) return std.fs.path.basename(mission.dir);
    }
    return null;
}

/// The discovery half of arrival: idempotently append the hub uuid to the
/// active campaign's discovered group, creating the group when the
/// campaign is new to the player (new_game's first arrival). A pure
/// PlayerData transform - undo/redo/replay consistent by construction.
pub fn discoverHub(current: *GameState, allocator: std.mem.Allocator, hub_uuid: []const u8) void {
    const campaign = current.campaign orelse return;
    if (campaign.uuid.len == 0) return;
    for (current.player_data.discovered_hubs) |group| {
        if (!std.mem.eql(u8, group.campaign_uuid, campaign.uuid)) continue;
        for (group.hub_uuids) |discovered| {
            if (std.mem.eql(u8, discovered, hub_uuid)) return; // already discovered
        }
        // Rebuild the whole groups slice (the field is []const - the
        // PlayerData convention): the matching group with one more uuid.
        var groups: std.ArrayList(types.DiscoveredCampaignHubs) = .empty;
        for (current.player_data.discovered_hubs) |existing| {
            if (std.mem.eql(u8, existing.campaign_uuid, campaign.uuid)) {
                var rebuilt_hub_uuids: std.ArrayList([]const u8) = .empty;
                rebuilt_hub_uuids.appendSlice(allocator, existing.hub_uuids) catch @panic("failed to copy discovered hubs");
                rebuilt_hub_uuids.append(allocator, hub_uuid) catch @panic("failed to append discovered hub");
                groups.append(allocator, .{
                    .campaign_uuid = existing.campaign_uuid,
                    .hub_uuids = rebuilt_hub_uuids.toOwnedSlice(allocator) catch @panic("failed to own discovered hubs slice"),
                }) catch @panic("failed to append discovered group");
            } else {
                groups.append(allocator, existing) catch @panic("failed to append discovered group");
            }
        }
        current.player_data.discovered_hubs = groups.toOwnedSlice(allocator) catch @panic("failed to own discovered groups slice");
        return;
    }
    // No group for this campaign yet - create one (the new-game seeding
    // IS this branch: the first arrival at a campaign's start hub).
    var groups: std.ArrayList(types.DiscoveredCampaignHubs) = .empty;
    groups.appendSlice(allocator, current.player_data.discovered_hubs) catch @panic("failed to copy discovered groups");
    const hub_uuids = allocator.dupe([]const u8, &.{hub_uuid}) catch @panic("failed to dupe discovered hub uuids");
    groups.append(allocator, .{
        .campaign_uuid = campaign.uuid,
        .hub_uuids = hub_uuids,
    }) catch @panic("failed to append discovered group");
    current.player_data.discovered_hubs = groups.toOwnedSlice(allocator) catch @panic("failed to own discovered groups slice");
}
