//! The hub editor drill-in's handler module (the src/editor/handlers.zig
//! mirror over the hub grid - DESIGN → Campaigns & the Campaign Editor →
//! The hub editor surface): the HubEditorEvent arms, writing through into
//! `current.campaign_editor.?.hubs` by the drill-in's own handle (the
//! grid is never copied; copy-on-write over the []const hub list - the
//! campaign editor's mutation convention). The drill-in's view state
//! (active tool + selection, on `HubEditor`) mutates in the same events
//! so undo/redo and replay ride the shared timeline by construction.
//! Every arm resolves the target hub against the live authored graph and
//! no-ops on a dead handle (the crafted-log convention - live input
//! cannot produce one).

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const planning = @import("../editor/planning.zig");
const editor_handlers = @import("../editor/handlers.zig");
const functions = @import("../functions.zig");
const loaders = @import("../loaders.zig");
const event_push = @import("../event_push.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;
const Vector2 = types.Vector2;

/// The drilled-in hub, resolved against the live authored graph: the
/// drill-in state + the campaign editor + the target handle, or null (a
/// crafted log's dead handle - every arm and orchestrator no-ops on it).
pub fn drilledHub(current: *const GameState) ?*const types.CampaignHubEdit {
    const hub_editor = current.hub_editor orelse return null;
    const campaign_editor = current.campaign_editor orelse return null;
    for (campaign_editor.hubs) |*hub| {
        if (hub.handle == hub_editor.hub) return hub;
    }
    return null;
}

/// Copy-on-write over the []const hub list (the campaign editor's
/// convention): a MUTABLE copy the arm mutates in place, then re-owns as
/// the editor's hubs. The drill-in's grid edits rebuild one hub per
/// event; the arena absorbs them.
fn mutableHubCopy(editor: *types.CampaignEditor, allocator: std.mem.Allocator) []types.CampaignHubEdit {
    const hubs = allocator.alloc(types.CampaignHubEdit, editor.hubs.len) catch
        @panic("failed to copy campaign hubs");
    @memcpy(hubs, editor.hubs);
    return hubs;
}

/// The drilled-in hub's INDEX in the authored list (the copy-on-write
/// mutation address), or null on a dead handle.
fn drilledHubIndex(hub_editor: types.HubEditor, editor: *const types.CampaignEditor) ?usize {
    for (editor.hubs, 0..) |hub, index| {
        if (hub.handle == hub_editor.hub) return index;
    }
    return null;
}

/// Handle one hub-editor event. No-ops on a dead target handle (the
/// crafted-log convention); the screen-scope invariants guarantee the
/// states themselves alive on .hub_editor, so missing states are the
/// fail-fast class (the handleEditorEvent posture).
pub fn handleHubEditorEvent(
    history: *GameStateHistory,
    current: *GameState,
    event: events.HubEditorEvent,
    allocator: std.mem.Allocator,
) void {
    const hub_editor = &(current.hub_editor orelse
        @panic("hub editor event with no drill-in state"));
    const campaign_editor = &(current.campaign_editor orelse
        @panic("hub editor event with no campaign editor"));

    switch (event) {
        .hub_toggle_inspector => {
            hub_editor.inspector_open = !hub_editor.inspector_open;
        },
        .hub_add_decoration_type => {
            // The "+": append the default-template decoration type to the
            // CAMPAIGN-SHARED palette (every hub's placements index into
            // it) + select the new tool (the addEditorPaletteType
            // convention - the tool switch carries the selection clear).
            const defaults = editor_handlers.readEditorDefaults(history, allocator) orelse return;
            var palette: std.ArrayList(types.DecorationTypeDef) = .empty;
            palette.appendSlice(allocator, campaign_editor.decoration_types) catch
                @panic("failed to copy campaign decoration types");
            palette.append(allocator, defaults.decoration) catch
                @panic("failed to append the default decoration type");
            campaign_editor.decoration_types = palette.toOwnedSlice(allocator) catch
                @panic("failed to own the campaign decoration types");
            hub_editor.active_tool = .{ .decoration_type = @intCast(campaign_editor.decoration_types.len - 1) };
            hub_editor.selection = &.{};
            hub_editor.inspector_open = true;
        },
        .hub_set_tool => |set| {
            // Defensive against crafted logs (the editor_set_tool posture):
            // a mission tool must address an OUTGOING mission (start ==
            // this hub - the palette's live membership); an NPC tool is
            // always valid (the fixed enum).
            switch (set.tool) {
                .decoration_type => |type_id| {
                    if (type_id >= campaign_editor.decoration_types.len) return;
                },
                .mission => |mission_handle| {
                    var outgoing = false;
                    for (campaign_editor.missions) |mission| {
                        if (mission.handle == mission_handle and
                            mission.start != null and mission.start.? == hub_editor.hub)
                        {
                            outgoing = true;
                            break;
                        }
                    }
                    if (!outgoing) return;
                },
                .select, .tile, .npc => {},
            }
            hub_editor.active_tool = set.tool;
            // Invariant: selection nonempty <=> active tool is select - a
            // switch away takes the selection with it (same event, one
            // undo step - the editor_set_tool invariant).
            if (set.tool != .select) hub_editor.selection = &.{};
        },
        .hub_set_tile => |set| {
            const index = drilledHubIndex(hub_editor.*, campaign_editor) orelse return;
            var hubs = mutableHubCopy(campaign_editor, allocator);
            const grid = &hubs[index].grid;
            // A selected tile leaves the selection when the tile is
            // actually erased (an erase of an absent tile is an idempotent
            // no-op - nothing to prune). The editor_set_tile mirror.
            if (!set.is_floor and
                functions.tileListContains(grid.level_tiles, set.position))
            {
                hub_editor.selection = planning.selectionWithoutTile(hub_editor.selection, set.position, allocator);
            }
            grid.level_tiles = editor_handlers.setLevelTile(grid.level_tiles, set.position, set.is_floor, allocator);
            campaign_editor.hubs = hubs;
        },
        .hub_place_decoration => |place| {
            const index = drilledHubIndex(hub_editor.*, campaign_editor) orelse return;
            if (place.type_id >= campaign_editor.decoration_types.len) {
                @panic("hub_place_decoration: type id out of range");
            }
            var hubs = mutableHubCopy(campaign_editor, allocator);
            const grid = &hubs[index].grid;
            const footprint_tiles = loaders.decorationFootprintWorldTiles(
                campaign_editor.decoration_types[place.type_id].footprint,
                place.position,
                allocator,
            );
            // A decoration's footprint tiles are EXCLUSIVE - no level tile,
            // no other decoration's footprint under any of them (the
            // parse-time placement invariant, enforced at the placement
            // event - the click orchestrator clears occupants first, so
            // reaching here occupied is a logic bug. Fail fast. A hub grid
            // has no entity/item placements, so the tile check subsumes
            // them). The editor_place_decoration mirror.
            for (footprint_tiles) |tile| {
                if (functions.tileListContains(grid.level_tiles, tile)) {
                    @panic("hub_place_decoration onto a tile");
                }
                for (grid.decoration_placements) |placement| {
                    const other_footprint = loaders.decorationFootprintWorldTiles(
                        campaign_editor.decoration_types[placement.type_id].footprint,
                        placement.position,
                        allocator,
                    );
                    for (other_footprint) |other_tile| {
                        if (other_tile.x == tile.x and other_tile.y == tile.y) {
                            @panic("hub_place_decoration onto another decoration's footprint");
                        }
                    }
                }
            }
            const placements = allocator.alloc(types.DecorationPlacement, grid.decoration_placements.len + 1) catch
                @panic("failed to allocate hub decoration placements");
            @memcpy(placements[0..grid.decoration_placements.len], grid.decoration_placements);
            placements[grid.decoration_placements.len] = .{
                .type_id = place.type_id,
                .position = place.position,
            };
            grid.decoration_placements = placements;
            campaign_editor.hubs = hubs;
        },
        .hub_delete_decoration_placement => |delete| {
            const index = drilledHubIndex(hub_editor.*, campaign_editor) orelse return;
            var hubs = mutableHubCopy(campaign_editor, allocator);
            const grid = &hubs[index].grid;
            if (delete.placement_index >= grid.decoration_placements.len) {
                @panic("hub_delete_decoration_placement: placement index out of range");
            }
            // Order-preserving removal - placement indices are the identity
            // the move/delete events address (the orchestrator deletes
            // high-before-low for exactly this reason).
            const removal: usize = @intCast(delete.placement_index);
            const placements = allocator.alloc(
                types.DecorationPlacement,
                grid.decoration_placements.len - 1,
            ) catch @panic("failed to allocate hub decoration placements");
            @memcpy(placements[0..removal], grid.decoration_placements[0..removal]);
            @memcpy(placements[removal..], grid.decoration_placements[removal + 1 ..]);
            grid.decoration_placements = placements;
            hub_editor.selection = editor_handlers.reconcileSelectionAfterPlacementDelete(
                hub_editor.selection,
                .decoration_placement,
                delete.placement_index,
                allocator,
            );
            campaign_editor.hubs = hubs;
        },
        .hub_place_npc => |place| {
            const index = drilledHubIndex(hub_editor.*, campaign_editor) orelse return;
            var hubs = mutableHubCopy(campaign_editor, allocator);
            const grid = &hubs[index].grid;
            // One thing per cell (the entity-placement posture): the
            // planner clears occupants first, so reaching here occupied
            // is a logic bug - fail fast.
            for (grid.npc_placements) |placement| {
                if (placement.position.x == place.position.x and placement.position.y == place.position.y) {
                    @panic("hub_place_npc onto an occupied cell");
                }
            }
            for (grid.exit_placements) |placement| {
                if (placement.position.x == place.position.x and placement.position.y == place.position.y) {
                    @panic("hub_place_npc onto an exit marker");
                }
            }
            const placements = allocator.alloc(types.NPC, grid.npc_placements.len + 1) catch
                @panic("failed to allocate hub npc placements");
            @memcpy(placements[0..grid.npc_placements.len], grid.npc_placements);
            placements[grid.npc_placements.len] = .{
                .npc_type = place.npc_type,
                .position = place.position,
            };
            grid.npc_placements = placements;
            campaign_editor.hubs = hubs;
        },
        .hub_delete_npc_placement => |delete| {
            const index = drilledHubIndex(hub_editor.*, campaign_editor) orelse return;
            var hubs = mutableHubCopy(campaign_editor, allocator);
            const grid = &hubs[index].grid;
            if (delete.placement_index >= grid.npc_placements.len) {
                @panic("hub_delete_npc_placement: placement index out of range");
            }
            // Order-preserving removal - placement indices are the identity
            // the move/delete events address.
            const removal: usize = @intCast(delete.placement_index);
            const placements = allocator.alloc(
                types.NPC,
                grid.npc_placements.len - 1,
            ) catch @panic("failed to allocate hub npc placements");
            @memcpy(placements[0..removal], grid.npc_placements[0..removal]);
            @memcpy(placements[removal..], grid.npc_placements[removal + 1 ..]);
            grid.npc_placements = placements;
            hub_editor.selection = editor_handlers.reconcileSelectionAfterPlacementDelete(
                hub_editor.selection,
                .npc_placement,
                delete.placement_index,
                allocator,
            );
            campaign_editor.hubs = hubs;
        },
        .hub_set_exit_marker => |set| {
            const index = drilledHubIndex(hub_editor.*, campaign_editor) orelse return;
            var hubs = mutableHubCopy(campaign_editor, allocator);
            const grid = &hubs[index].grid;
            // The UPSERT: replace the mission's own entry in place, or
            // append when it has none (one marker per mission - the
            // layout format's one digit per cell). Another mission's
            // marker on the same cell is a crafted-log shape the planner
            // never produces - fail fast (the one-marker-per-cell rule).
            var upserted = false;
            const placements = allocator.alloc(types.ExitPlacement, grid.exit_placements.len + @intFromBool(!upserted)) catch
                @panic("failed to allocate hub exit placements");
            var length: usize = 0;
            for (grid.exit_placements) |placement| {
                if (placement.mission == set.mission) {
                    placements[length] = .{ .mission = set.mission, .position = set.position };
                    length += 1;
                    upserted = true;
                    continue;
                }
                if (placement.position.x == set.position.x and placement.position.y == set.position.y) {
                    @panic("hub_set_exit_marker onto another mission's marker");
                }
                placements[length] = placement;
                length += 1;
            }
            if (!upserted) {
                placements[length] = .{ .mission = set.mission, .position = set.position };
                length += 1;
            }
            grid.exit_placements = placements[0..length];
            campaign_editor.hubs = hubs;
        },
        .hub_delete_exit_marker => |delete| {
            const index = drilledHubIndex(hub_editor.*, campaign_editor) orelse return;
            var hubs = mutableHubCopy(campaign_editor, allocator);
            const grid = &hubs[index].grid;
            // Keyed removal (the mission handle); the selection reconcile
            // is index-keyed, so a selected exit entry is dropped the
            // conservative way: any selected exit index beyond the new
            // list is stale by the next plan's validation - the live
            // path deletes via the plan's own selection fan, which
            // reconciles inside the generic delete arms. Simplest sound
            // shape: drop ALL selected exit entries (a marker deletion
            // rarely coincides with a multi-marker selection, and a
            // stale index would address the WRONG mission).
            var length: usize = 0;
            const placements = allocator.alloc(types.ExitPlacement, grid.exit_placements.len) catch
                @panic("failed to allocate hub exit placements");
            for (grid.exit_placements) |placement| {
                if (placement.mission == delete.mission) continue;
                placements[length] = placement;
                length += 1;
            }
            grid.exit_placements = placements[0..length];
            {
                var kept: usize = 0;
                const rebuilt = allocator.alloc(types.Selectable, hub_editor.selection.len) catch
                    @panic("failed to allocate hub editor selection");
                for (hub_editor.selection) |selected| {
                    if (selected == .exit_placement) continue;
                    rebuilt[kept] = selected;
                    kept += 1;
                }
                hub_editor.selection = rebuilt[0..kept];
            }
            campaign_editor.hubs = hubs;
        },
        .hub_set_player_start => |set| {
            const index = drilledHubIndex(hub_editor.*, campaign_editor) orelse return;
            var hubs = mutableHubCopy(campaign_editor, allocator);
            hubs[index].grid.player_start = set.position;
            campaign_editor.hubs = hubs;
        },
        .hub_select => |select| {
            // Defensive against crafted logs: the select workflow only,
            // and placement entries must address the hub grid's lists (the
            // editor_select mirror).
            if (hub_editor.active_tool != .select) return;
            const hub = drilledHub(current) orelse return;
            const entry_valid = switch (select.entry) {
                .decoration_placement => |placement_index| placement_index < hub.grid.decoration_placements.len,
                .npc_placement => |placement_index| placement_index < hub.grid.npc_placements.len,
                .exit_placement => |placement_index| placement_index < hub.grid.exit_placements.len,
                .tile, .player_start => true,
                // Mission vocabulary a hub selection never carries (the
                // hub grid has no entities/items/level_end).
                .entity_placement, .ground_item_placement, .level_end => false,
            };
            if (!entry_valid) return;
            if (planning.selectionContains(hub_editor.selection, select.entry)) return;
            hub_editor.selection = planning.selectionWithEntry(hub_editor.selection, select.entry, allocator);
        },
        .hub_deselect => |deselect| {
            if (hub_editor.active_tool != .select) return;
            hub_editor.selection = planning.selectionWithoutEntry(hub_editor.selection, deselect.entry, allocator);
        },
        .hub_clear_selection => {
            hub_editor.selection = &.{};
        },
        .hub_commit_selection_move => |commit| {
            // Final link: the worklist is exhausted - a move deselects
            // (nothing is reselected; the clear phase's reconcile already
            // pruned the deleted entries, this drops the rest).
            if (commit.next_index >= commit.entries.len) {
                hub_editor.selection = &.{};
                return;
            }
            const hub = drilledHub(current) orelse return;
            const entry = commit.entries[commit.next_index];

            // Plan THIS entry against the live post-clear state - the
            // placement planners are the current placement rules. The
            // decoration type id from a crafted worklist is skipped
            // defensively (the live path derives it from a real placement).
            var plan: std.ArrayList(Event) = .empty;
            switch (entry) {
                .decoration => |move_entry| {
                    if (move_entry.type_id < campaign_editor.decoration_types.len) {
                        plan.appendSlice(
                            allocator,
                            planning.planHubDecorationPlacementActions(hub, campaign_editor.decoration_types, move_entry.type_id, move_entry.position, allocator),
                        ) catch @panic("failed to allocate hub editor selection move plan");
                    }
                },
                .tile => |position| {
                    plan.appendSlice(
                        allocator,
                        planning.planHubTilePaintActions(hub, campaign_editor.decoration_types, position, allocator),
                    ) catch @panic("failed to allocate hub editor selection move plan");
                },
                .npc => |move_entry| {
                    plan.appendSlice(
                        allocator,
                        planning.gridStepsToHubEvents(
                            planning.planGridNpcPlacement(&hub.grid, campaign_editor.decoration_types, move_entry.npc_type, move_entry.position, allocator),
                            allocator,
                        ),
                    ) catch @panic("failed to allocate hub editor selection move plan");
                },
                .exit_marker => |move_entry| {
                    plan.appendSlice(
                        allocator,
                        planning.gridStepsToHubEvents(
                            planning.planGridExitPlacement(&hub.grid, campaign_editor.decoration_types, move_entry.mission, move_entry.position, allocator),
                            allocator,
                        ),
                    ) catch @panic("failed to allocate hub editor selection move plan");
                },
                .player_start => |position| {
                    // A hub grid has no level_end - the marker-overlap
                    // block is structurally unreachable. A tile is ensured
                    // under the moved spawn (paint = the current
                    // replacement rules), then the marker moves. The
                    // editor_commit_selection_move mirror.
                    plan.appendSlice(
                        allocator,
                        planning.planHubTilePaintActions(hub, campaign_editor.decoration_types, position, allocator),
                    ) catch @panic("failed to allocate hub editor selection move plan");
                    plan.append(allocator, .{ .hub_editor_event = .{ .hub_set_player_start = .{
                        .position = position,
                    } } }) catch @panic("failed to allocate hub editor selection move plan");
                },
                // Mission vocabulary a hub worklist never carries (the
                // move plan derives entries from the hub grid's
                // placements; a crafted worklist's mission arms plan
                // nothing).
                .entity, .item, .level_end => {},
            }

            // Push [next link, ...plan] - LIFO runs this entry's plan
            // first, then the next link plans the following entry against
            // the result (the chain exists precisely so each entry sees
            // the fully-processed state).
            var push: std.ArrayList(Event) = .empty;
            push.append(allocator, .{ .hub_editor_event = .{ .hub_commit_selection_move = .{
                .entries = commit.entries,
                .next_index = commit.next_index + 1,
            } } }) catch @panic("failed to allocate hub editor selection move plan");
            push.appendSlice(allocator, plan.items) catch
                @panic("failed to allocate hub editor selection move plan");
            event_push.pushEvents(current, push.items, allocator);
        },
    }
}
