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
const campaign_io = @import("io.zig");
const editor_handlers = @import("../editor/handlers.zig");

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
            editor.selection = if (select.hub) |handle| .{ .hub = handle } else null;
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
            editor.selection = .{ .hub = handle };
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
                if (hub.handle == delete.hub) {
                    deleted_position = hub.position;
                    // The dir rides the session deletion list (reconciled
                    // at the next full save - never at the delete; an
                    // undo restores the content and the save skips it).
                    // Fresh content's dir lives in the save memo (its
                    // state dir is still empty - the write-only mint).
                    if (!history.replaying) {
                        const dir = if (hub.dir.len > 0) hub.dir else if (campaign_io.campaignSaveMemoFor(history, hub.handle)) |memo| memo.dir else &.{};
                        campaign_io.recordCampaignContentDeletion(history, dir);
                    }
                }
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
            if (editor.selection) |selection| {
                if (selection == .hub and selection.hub == delete.hub) editor.selection = null;
            }
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

        .editor_campaign_toggle_inspector => {
            editor.inspector_open = !editor.inspector_open;
        },

        .editor_campaign_toggle_metadata_sidebar => {
            editor.metadata_sidebar_open = !editor.metadata_sidebar_open;
        },

        .editor_campaign_select_mission => |select| {
            editor.selection = .{ .mission = select.mission };
        },

        .editor_campaign_place_mission => |place| {
            const handle = editor.next_handle;
            editor.next_handle += 1;
            var missions: std.ArrayList(types.CampaignMissionEdit) = .empty;
            missions.appendSlice(allocator, editor.missions) catch
                @panic("failed to copy campaign missions for placement");
            missions.append(allocator, .{
                .handle = handle,
                .dir = mintMissionAnchor(editor.missions, allocator),
                .name = "New Mission",
                .start = place.start,
                .destination = place.destination,
            }) catch @panic("failed to append placed campaign mission");
            editor.missions = missions.toOwnedSlice(allocator) catch
                @panic("failed to own placed campaign missions slice");
            // Placing selects (the last-placed-object rule).
            editor.selection = .{ .mission = handle };
        },

        .editor_campaign_set_mission_name => |set| {
            const name = allocator.dupe(u8, set.name) catch
                @panic("failed to dupe campaign mission name");
            var missions: std.ArrayList(types.CampaignMissionEdit) = .empty;
            for (editor.missions) |mission| {
                var updated = mission;
                if (mission.handle == set.mission) updated.name = name;
                missions.append(allocator, updated) catch
                    @panic("failed to copy campaign missions for rename");
            }
            editor.missions = missions.toOwnedSlice(allocator) catch
                @panic("failed to own renamed campaign missions slice");
        },

        .editor_campaign_set_mission_direction => |set| {
            var missions: std.ArrayList(types.CampaignMissionEdit) = .empty;
            for (editor.missions) |mission| {
                var updated = mission;
                if (mission.handle == set.mission) updated.direction = set.direction;
                missions.append(allocator, updated) catch
                    @panic("failed to copy campaign missions for direction set");
            }
            editor.missions = missions.toOwnedSlice(allocator) catch
                @panic("failed to own campaign missions for direction set");
        },

        .editor_campaign_reattach_mission => |set| {
            var missions: std.ArrayList(types.CampaignMissionEdit) = .empty;
            for (editor.missions) |mission| {
                var updated = mission;
                if (mission.handle == set.mission) {
                    if (set.end == .start) {
                        // The re-attached start drops its exit marker from
                        // the old start hub (the marker is re-placed in the
                        // new hub via the hub editor; until then the
                        // mission is unstartable - the validation finding).
                        if (mission.start) |old_start| {
                            removeExitPlacement(editor, old_start, mission.handle, allocator);
                        }
                        updated.start = set.hub;
                        updated.orphan_start_position = null;
                    } else {
                        updated.destination = set.hub;
                        updated.orphan_destination_position = null;
                    }
                }
                missions.append(allocator, updated) catch
                    @panic("failed to copy campaign missions for re-attach");
            }
            editor.missions = missions.toOwnedSlice(allocator) catch
                @panic("failed to own campaign missions for re-attach");
            // The old-start marker removal may have rebuilt the hubs list;
            // the re-attach itself does not touch hubs further.
        },

        .editor_campaign_delete_mission => |delete| {
            var surviving_start: ?u32 = null;
            for (editor.missions) |mission| {
                if (mission.handle == delete.mission) {
                    surviving_start = mission.start;
                    if (!history.replaying) {
                        const dir = if (mission.dir.len > 0) mission.dir else if (campaign_io.campaignSaveMemoFor(history, mission.handle)) |memo| memo.dir else &.{};
                        campaign_io.recordCampaignContentDeletion(history, dir);
                    }
                }
            }
            // The mission IS the edge: the entry + its exit placement in
            // its start hub go together.
            if (surviving_start) |start_hub| {
                removeExitPlacement(editor, start_hub, delete.mission, allocator);
            }
            var missions: std.ArrayList(types.CampaignMissionEdit) = .empty;
            for (editor.missions) |mission| {
                if (mission.handle != delete.mission) {
                    missions.append(allocator, mission) catch
                        @panic("failed to copy surviving campaign missions");
                }
            }
            editor.missions = missions.toOwnedSlice(allocator) catch
                @panic("failed to own surviving campaign missions slice");
            if (editor.selection) |selection| {
                if (selection == .mission and selection.mission == delete.mission) editor.selection = null;
            }
        },

        .editor_campaign_import_mission => |set| {
            const handle = editor.next_handle;
            editor.next_handle += 1;
            var missions: std.ArrayList(types.CampaignMissionEdit) = .empty;
            missions.appendSlice(allocator, editor.missions) catch
                @panic("failed to copy campaign missions for import");
            missions.append(allocator, .{
                .handle = handle,
                .uuid = allocator.dupe(u8, set.uuid) catch
                    @panic("failed to dupe imported mission uuid"),
                .dir = allocator.dupe(u8, set.dir) catch
                    @panic("failed to dupe imported mission dir"),
                .name = allocator.dupe(u8, set.name) catch
                    @panic("failed to dupe imported mission name"),
            }) catch @panic("failed to append imported campaign mission");
            editor.missions = missions.toOwnedSlice(allocator) catch
                @panic("failed to own imported campaign missions slice");
            // The import lands selected (the inspector's
            // last-placed-object rule).
            editor.selection = .{ .mission = handle };
        },
    }
}

/// The hub editor drill-in open (the hub inspector's Open Hub Editor
/// button -> the `open_hub_editor` orchestrator): resolve the target
/// handle against the live authored graph (a crafted dead handle no-ops
/// - the defensive convention), snapshot the camera clamp over the hub
/// grid, load the spawn-preview template (max player, through the
/// reconstruction cache - the orchestrator is recorded, so replay
/// re-reads the same bytes), and install the drill-in state. The CALLER
/// transitions to .hub_editor (whose scope keeps campaign_editor alive;
/// the scope rule drops the drill-in state on the way back out - DESIGN
/// → The editor-state split). A failed template read surfaces the
/// recoverable error + leaves hub_editor unset (the arm's null check
/// skips the transition - the openFreshEditorMission contract).
pub fn openHubEditor(
    history: *GameStateHistory,
    current: *GameState,
    allocator: std.mem.Allocator,
    balance_warnings: *std.ArrayList([]const u8),
    target_handle: u32,
) void {
    const editor = current.campaign_editor orelse return;
    var target: ?types.CampaignHubEdit = null;
    for (editor.hubs) |hub| {
        if (hub.handle == target_handle) {
            target = hub;
            break;
        }
    }
    const hub = target orelse return;
    const player_entity = editor_handlers.loadMaxPlayerLoadout(history, allocator, balance_warnings) orelse
        return;
    current.hub_editor = .{
        .hub = hub.handle,
        .clamp_bounds = hubGridClampBounds(hub),
        .player_def = .{ .id = "Player", .template = player_entity },
    };
}

/// The camera-clamp snapshot over a hub grid's tiles (the
/// refreshEditorClampBounds math): taken once at drill-in open, never
/// re-taken mid-edit, so painting never reframes the camera (see DESIGN
/// → Platform Seam → Camera clamping). Null on an empty tile list (the
/// unclamped camera).
fn hubGridClampBounds(hub: types.CampaignHubEdit) ?types.TileBounds {
    const tiles = hub.grid.level_tiles;
    if (tiles.len == 0) return null;
    var min_x = tiles[0].x;
    var max_x = tiles[0].x;
    var min_y = tiles[0].y;
    var max_y = tiles[0].y;
    for (tiles[1..]) |tile| {
        if (tile.x < min_x) min_x = tile.x;
        if (tile.x > max_x) max_x = tile.x;
        if (tile.y < min_y) min_y = tile.y;
        if (tile.y > max_y) max_y = tile.y;
    }
    return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

/// Open a FRESH campaign (the editor browser's New Campaign button /
/// `open_campaign_editor` with a null dir): one start hub placed at the
/// map origin with the single-'!'-tile default grid, no missions, empty
/// palette. Pure in-memory construction - no reads, so no failure path;
/// files are written only at the campaign save (3e), where the campaign
/// uuid is minted (write-only, never held in state - the
/// openFreshEditorMission convention).
pub fn openFreshCampaignEditor(
    history: *GameStateHistory,
    current: *GameState,
    allocator: std.mem.Allocator,
) void {
    campaign_io.clearCampaignSaveState(history);
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
/// rescanEditorMissionSprites pattern): BOTH tiers of the EFFECTIVE
/// campaign dir's direct PNGs (the persistent scan + the embedded map -
/// a forked session scans the fork, the campaign save memo's dir, not
/// the opened original; the official campaign's shipped background is
/// offered regardless of the current stem) PLUS the current stem
/// (deduped across all sources - a stem may exist in several). Frees the
/// previous scan; the final list's leak at process exit is bounded (the
/// save_files pattern). An IO failure degrades to the tiers the scan
/// could read (recoverable-degrade - a popup would interrupt the click
/// flow).
pub fn rescanCampaignBackgroundStems(history: *GameStateHistory) void {
    const allocator = history.backing_allocator;
    const session = &history.session;
    for (session.campaign_background_stems) |stem| allocator.free(stem);
    allocator.free(session.campaign_background_stems);

    const editor = history.current_state.campaign_editor orelse {
        session.campaign_background_stems = &.{};
        return;
    };

    // The deduping collector (first occurrence wins - the persistent
    // tier leads, the embedded original follows, the current stem
    // trails).
    var stems: std.ArrayList([]const u8) = .empty;
    const appendStem = struct {
        fn append(
            list: *std.ArrayList([]const u8),
            alloc: std.mem.Allocator,
            stem: []const u8,
        ) void {
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing, stem)) return;
            }
            const owned = alloc.dupe(u8, stem) catch
                @panic("failed to dupe background stem");
            list.append(alloc, owned) catch
                @panic("failed to append background stem");
        }
    }.append;

    // Both read tiers of the effective campaign dir's direct PNGs in one
    // listing (a forked session scans the fork, the campaign save memo's
    // dir, not the opened original; the official campaign's shipped
    // background is offered whatever the current stem is, so choosing
    // None never hides it - subdirs are not backgrounds, `listDirFiles`
    // lists direct files only). An IO failure degrades to an empty
    // listing (recoverable-degrade - a popup would interrupt the click
    // flow).
    const campaign_dir = campaign_io.effectiveCampaignDir(history, editor);
    const names: [][]const u8 = history.file_source.listDirFiles(
        allocator,
        campaign_dir,
    ) catch &[_][]const u8{};
    defer file_source_mod.freeDirFiles(allocator, names);
    for (names) |file_name| {
        if (!std.mem.endsWith(u8, file_name, ".png")) continue;
        const stem = file_name[0 .. file_name.len - ".png".len];
        appendStem(&stems, allocator, stem);
    }

    // The current stem last (the setting stays visible even when its
    // file is unreadable - the row lets the player see + change it).
    if (editor.background_stem.len > 0) {
        appendStem(&stems, allocator, editor.background_stem);
    }
    session.campaign_background_stems = stems.toOwnedSlice(allocator) catch
        @panic("failed to own background stems");
}

/// Remove `mission_handle`'s exit placement from `hub_handle`'s list (the
/// copy-on-write convention). A no-op when the hub or the placement is
/// absent.
fn removeExitPlacement(
    editor: *types.CampaignEditor,
    hub_handle: u32,
    mission_handle: u32,
    allocator: std.mem.Allocator,
) void {
    var hubs: std.ArrayList(types.CampaignHubEdit) = .empty;
    for (editor.hubs) |hub| {
        var updated = hub;
        if (hub.handle == hub_handle) {
            var placements: std.ArrayList(types.ExitPlacement) = .empty;
            for (hub.grid.exit_placements) |placement| {
                if (placement.mission != mission_handle) {
                    placements.append(allocator, placement) catch
                        @panic("failed to copy surviving exit placements");
                }
            }
            updated.grid.exit_placements = placements.toOwnedSlice(allocator) catch
                @panic("failed to own surviving exit placements slice");
        }
        hubs.append(allocator, updated) catch
            @panic("failed to copy campaign hubs for placement removal");
    }
    editor.hubs = hubs.toOwnedSlice(allocator) catch
        @panic("failed to own campaign hubs for placement removal");
}

/// Mint a unique temp anchor dir for a fresh mission ("New Mission",
/// "New Mission 2", ... - unique among the editor's mission entries; the
/// fresh-mission `missions/New Mission` precedent, anchoring the
/// mission-editor hand-off under the campaign's missions/). Deterministic
/// on replay (the mission list is state).
fn mintMissionAnchor(
    missions: []const types.CampaignMissionEdit,
    allocator: std.mem.Allocator,
) []const u8 {
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const candidate = if (attempt == 1)
            "New Mission"
        else
            std.fmt.allocPrint(allocator, "New Mission {d}", .{attempt}) catch
                @panic("failed to format mission anchor");
        var taken = false;
        for (missions) |mission| {
            if (std.mem.eql(u8, mission.dir, candidate)) taken = true;
        }
        if (!taken) return candidate;
    }
}
