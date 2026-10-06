//! Cross-category event-handler helpers shared by the dispatch
//! (event_handlers.zig), the player-input handler, and the editor
//! handlers (editor/handlers.zig): entity accessors, the recoverable
//! reconstruction-read failure (popup + revert flag), config-key
//! validation + warning surfacing, the campaign load, and the gameplay
//! start batch. A policy layer over state.zig's history machinery —
//! imports nothing back from the handlers.

const std = @import("std");
const types = @import("../types.zig");
const events = @import("../events.zig");
const state = @import("../state.zig");
const parser = @import("../parser.zig");
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
/// During replay, panics instead (fail-fast — a reconstruction-read
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
/// surface them as a pending_error popup. Advisory — the load continues
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

/// Load the campaign file for the player's current campaign (through the
/// reconstruction cache) and push start_hub for `player_data.current_hub`.
/// A read/parse failure takes the recoverable reconstruction-read path
/// (popup + revert via `failReconstructionRead`).
pub fn loadCampaignAndPushHub(
    current: *GameState,
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
) void {
    // Build campaign file path: data/campaigns/{campaign_id}/campaign.txt
    const campaign_path = std.fmt.allocPrint(
        allocator,
        "data/campaigns/{s}/campaign.txt",
        .{current.player_data.current_campaign},
    ) catch @panic("failed to allocate campaign path");

    const campaign_sections = blk: {
        const bytes = history.readReconstructionFile(campaign_path) catch {
            failReconstructionRead(history, "failed to read campaign file");
            return;
        };
        break :blk parser.parseConfigFile(bytes, allocator) catch {
            failReconstructionRead(history, "failed to parse campaign file");
            return;
        };
    };
    validateConfigKeys(history, campaign_sections, parser.campaign_key_map, campaign_path, allocator);
    current.campaign = loaders.loadCampaign(
        campaign_sections,
        allocator,
    ) catch {
        failReconstructionRead(history, "failed to parse campaign file");
        return;
    };

    // Push start_hub with the player's current hub
    const hub_id = current.player_data.current_hub;
    pushEvents(current, &.{.{ .meta_event = .{ .start_hub = .{
        .hub_id = hub_id,
    } } }}, allocator);
}

/// Push the gameplay start batch for a freshly-loaded level: player sync
/// (build_player_from_data, runs first) + per-entity aggro checks + the
/// player's turn_start (runs last). Shared by start_level (normal gameplay
/// AND validation runs — sync_player=true — the level's bare player entity
/// gets its loadout from PlayerData; a validation run's player_data was
/// built from the saved player.txt at start_validation, and
/// playerLoadoutEntity maps the same field set, so the sync round-trips
/// the loadout identically) and start_playtest (editor, sync_player=false —
/// the player is already fully instantiated from editor.player_def, so
/// build_player_from_data would clobber it with the campaign's PlayerData).
pub fn pushGameplayStartEvents(current: *GameState, allocator: std.mem.Allocator, sync_player: bool) void {
    var start_events: std.ArrayList(Event) = .empty;
    // Player turn_start at bottom of LIFO (processed last, after sync + aggro).
    start_events.append(allocator, .{ .level_event = .{ .turn_start = .{
        .entity_index = 0,
    } } }) catch @panic("failed to append turn_start");
    // Aggro check: one event scans every inactive entity against its own
    // aggro_range. No `check_level_end` at level start — the player spawn
    // (`!`) and the level end (`=`) are always different tiles.
    start_events.append(allocator, .{ .sub_level_event = .{ .aggro_check = .{} } }) catch
        @panic("failed to append aggro_check event");
    // Player sync on top (processed first) — only for normal gameplay.
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
