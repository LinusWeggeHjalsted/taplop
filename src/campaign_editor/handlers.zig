//! The campaign editor's handler module (the src/editor/ family's
//! campaign sibling - see DESIGN → Campaigns & the Campaign Editor,
//! esp. The editor-state split + The campaign editor surface). Owns the
//! open/close framing + the campaign-editor event arms on
//! GameState.campaign_editor. The state is the AUTHORED graph
//! (CampaignEditor in types.zig), not the load-derived Campaign type.

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const loaders = @import("../loaders.zig");
const file_source_mod = @import("../file_source.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const CampaignEditorEvent = events.CampaignEditorEvent;

/// Handle a campaign-editor event (the handleEditorEvent mirror - pure
/// state transforms on current.campaign_editor.?, mutably in place via
/// the current arena; deepCopy snapshots make undo/redo work by
/// construction). No-ops when the campaign editor is unset (defensive -
/// nothing live produces that shape). `history` is the one live seam:
/// the set-background event's PNG dims read (deterministic on replay -
/// same files; the open path's posture).
pub fn handleCampaignEditorEvent(
    history: *GameStateHistory,
    current: *GameState,
    event: CampaignEditorEvent,
    allocator: std.mem.Allocator,
) void {
    if (current.campaign_editor == null) return;
    const editor = &current.campaign_editor.?;

    switch (event) {
        .editor_campaign_set_tool => |set| {
            editor.active_tool = set.tool;
            if (set.tool != .select) editor.selection = null;
        },

        .editor_campaign_select_hub => |select| {
            editor.selection = select.hub;
        },

        .editor_campaign_place_hub => |place| {
            const handle = editor.next_handle;
            editor.next_handle += 1;
            var hubs: std.ArrayList(types.CampaignHubEdit) = .empty;
            hubs.appendSlice(allocator, editor.hubs) catch
                @panic("failed to copy campaign hubs for placement");
            hubs.append(allocator, .{
                .handle = handle,
                .name = "New Hub",
                .position = place.position,
                .grid = .{
                    .level_tiles = &.{.{ .x = 0, .y = 0 }},
                    .player_start = .{ .x = 0, .y = 0 },
                },
            }) catch @panic("failed to append placed campaign hub");
            editor.hubs = hubs.toOwnedSlice(allocator) catch
                @panic("failed to own placed campaign hubs slice");
            // Placing selects (the inspector's "or the last placed
            // object" rule).
            editor.selection = handle;
        },

        .editor_campaign_set_hub_position => |set| {
            // Copy-on-write (the []const slice convention - every mutation
            // rebuilds the list).
            var hubs: std.ArrayList(types.CampaignHubEdit) = .empty;
            for (editor.hubs) |hub| {
                var updated = hub;
                if (hub.handle == set.hub) updated.position = set.position;
                hubs.append(allocator, updated) catch
                    @panic("failed to copy campaign hubs for move");
            }
            editor.hubs = hubs.toOwnedSlice(allocator) catch
                @panic("failed to own moved campaign hubs slice");
        },

        .editor_campaign_set_hub_name => |set| {
            const name = allocator.dupe(u8, set.name) catch
                @panic("failed to dupe campaign hub name");
            var hubs: std.ArrayList(types.CampaignHubEdit) = .empty;
            for (editor.hubs) |hub| {
                var updated = hub;
                if (hub.handle == set.hub) updated.name = name;
                hubs.append(allocator, updated) catch
                    @panic("failed to copy campaign hubs for rename");
            }
            editor.hubs = hubs.toOwnedSlice(allocator) catch
                @panic("failed to own renamed campaign hubs slice");
        },

        .editor_campaign_set_start_hub => |set| {
            // Radio semantics: overwrite the single slot (untoggling the
            // current start hub is vetoed at the input layer, never here).
            editor.start_hub = set.hub;
        },

        .editor_campaign_delete_hub => |delete| {
            // The hub's position, frozen into every touching mission's
            // ghost slot BEFORE the entry dies (orphans render in place -
            // see DESIGN → The campaign editor surface).
            var deleted_position: ?types.Vector2 = null;
            for (editor.hubs) |hub| {
                if (hub.handle == delete.hub) deleted_position = hub.position;
            }
            const ghost = deleted_position orelse return;
            // The missions the hub touches orphan: the dead end nulls +
            // freezes the ghost; the surviving end keeps its live hub (or
            // its own ghost, when both ends were this hub - the
            // fully-orphaned case falls out: each slot freezes
            // independently). The hub's exit placements die with its
            // entry - no marker cleanup, the salvage re-place covers it.
            var missions: std.ArrayList(types.CampaignMissionEdit) = .empty;
            for (editor.missions) |mission| {
                var updated = mission;
                if (mission.start == delete.hub) {
                    updated.start = null;
                    updated.orphan_start_position = ghost;
                }
                if (mission.destination == delete.hub) {
                    updated.destination = null;
                    updated.orphan_destination_position = ghost;
                }
                missions.append(allocator, updated) catch
                    @panic("failed to copy orphaned campaign missions");
            }
            editor.missions = missions.toOwnedSlice(allocator) catch
                @panic("failed to own orphaned campaign missions slice");
            var hubs: std.ArrayList(types.CampaignHubEdit) = .empty;
            for (editor.hubs) |hub| {
                if (hub.handle != delete.hub) {
                    hubs.append(allocator, hub) catch
                        @panic("failed to copy surviving campaign hubs");
                }
            }
            editor.hubs = hubs.toOwnedSlice(allocator) catch
                @panic("failed to own surviving campaign hubs slice");
            if (editor.selection == delete.hub) editor.selection = null;
        },

        .editor_campaign_set_campaign_name => |set| {
            editor.campaign_name = allocator.dupe(u8, set.name) catch
                @panic("failed to dupe campaign name");
        },

        .editor_campaign_set_background => |set| {
            editor.background_stem = allocator.dupe(u8, set.stem) catch
                @panic("failed to dupe background stem");
            // Re-resolve the dims live (deterministic on replay - same
            // files). Null dims = the view skips the background; the
            // picker lists files that exist, so an unresolvable pick is
            // a non-PNG in the dir - the next open's loader posture
            // carries that warning.
            editor.background_dims = loaders.resolveCampaignBackgroundDimsForStem(
                editor.campaign_dir,
                set.stem,
                history.file_source,
                allocator,
            );
        },

        .editor_campaign_open_picker => |open| {
            editor.picker = open.picker;
        },

        .editor_campaign_close_picker => {
            editor.picker = null;
        },
    }
}

/// Open a FRESH campaign (the editor browser's New Campaign button /
/// `open_campaign_editor` with a null dir): one start hub placed at the
/// map origin with the single-'!'-tile default grid, no missions, empty
/// palette. Pure in-memory construction - no reads, so no failure path;
/// files are written only at the campaign save (3e), where the campaign
/// uuid is minted (write-only, never held in state - the
/// openFreshEditorMission convention).
pub fn openFreshCampaignEditor(
    current: *GameState,
    allocator: std.mem.Allocator,
) void {
    var hubs: std.ArrayList(types.CampaignHubEdit) = .empty;
    hubs.append(allocator, .{
        .handle = 0,
        .name = "New Hub",
        .position = .{ .x = 0, .y = 0 },
        .grid = .{
            .level_tiles = &.{.{ .x = 0, .y = 0 }},
            .player_start = .{ .x = 0, .y = 0 },
        },
    }) catch @panic("failed to append campaign hub");
    current.campaign_editor = .{
        .campaign_name = "New Campaign",
        .start_hub = 0,
        .hubs = hubs.toOwnedSlice(allocator) catch @panic("failed to own campaign hubs slice"),
        .next_handle = 1,
    };
}

/// Scan the campaign dir's PNG stems into
/// `session.campaign_background_stems` (the background picker's list - the
/// rescanEditorMissionSprites pattern): the persistent dir's PNGs PLUS the
/// current stem (deduped - the official campaign's embedded background is
/// offered even though the persistent scan can't see it). Frees the
/// previous scan; the final list's leak at process exit is bounded (the
/// save_files pattern). An IO failure degrades to the current-stem-only
/// list (recoverable-degrade - a popup would interrupt the click flow).
pub fn rescanCampaignBackgroundStems(history: *GameStateHistory) void {
    const allocator = history.backing_allocator;
    const session = &history.session;
    for (session.campaign_background_stems) |stem| allocator.free(stem);
    allocator.free(session.campaign_background_stems);

    const editor = history.current_state.campaign_editor orelse {
        session.campaign_background_stems = &.{};
        return;
    };
    const names = history.file_source.listPersistentPngFiles(
        allocator,
        editor.campaign_dir,
    ) catch &[_][]const u8{};
    defer allocator.free(names);

    var stems: std.ArrayList([]const u8) = .empty;
    for (names) |file_name| {
        const stem = file_name[0 .. std.mem.lastIndexOfScalar(u8, file_name, '.') orelse file_name.len];
        const owned = allocator.dupe(u8, stem) catch
            @panic("failed to dupe background stem");
        stems.append(allocator, owned) catch
            @panic("failed to append background stem");
    }
    if (editor.background_stem.len > 0) {
        var present = false;
        for (stems.items) |stem| {
            if (std.mem.eql(u8, stem, editor.background_stem)) present = true;
        }
        if (!present) {
            const owned = allocator.dupe(u8, editor.background_stem) catch
                @panic("failed to dupe current background stem");
            stems.append(allocator, owned) catch
                @panic("failed to append current background stem");
        }
    }
    session.campaign_background_stems = stems.toOwnedSlice(allocator) catch
        @panic("failed to own background stems");
}
