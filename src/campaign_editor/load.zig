//! The campaign editor's INVERSE PROJECTION - the open-from-dir path
//! (`open_campaign_editor` with a campaign dir): campaign.txt + every
//! placed hub's hub.txt + the campaign's mission table, projected into
//! the AUTHORED CampaignEditor graph (the mission-centric model - hub.txt
//! Exits are the forward projection at save, 3e). campaign.txt and the
//! hub files read through the RECONSTRUCTION CACHE (the open_editor
//! convention - the editor state is GameState, so its reads are
//! replay-relevant); the uuid resolution scans run LIVE (the
//! installCampaignGraph convention - listings are never cache-recorded).
//! Failures: an unreadable/unparseable campaign.txt returns false (the
//! caller surfaces the recoverable read error, the editor stays unset);
//! per-hub and per-entry problems WARN + degrade (the loader convention -
//! the integrity-check posture). All allocations go into the passed
//! arena and are never freed (the handler-load convention - the history
//! arenas absorb them; snapshots own their deep copies).
//! See DESIGN → Campaigns & the Campaign Editor → The editor-state
//! split + The campaign editor surface.

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const parser = @import("../parser.zig");
const loaders = @import("../loaders.zig");
const shared = @import("../handlers/shared.zig");
const campaign_io_shared = @import("io.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;

fn warn(
    warnings: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) void {
    const message = std.fmt.allocPrint(allocator, format, args) catch return;
    warnings.append(allocator, message) catch {};
}

/// Resolve a hub uuid to its in-editor handle among the projected hub
/// entries; null for an empty or unplaced uuid (the dangling case).
fn resolveHubHandle(hubs: []const types.CampaignHubEdit, hub_uuid: []const u8) ?u32 {
    if (hub_uuid.len == 0) return null;
    for (hubs) |hub| {
        if (std.mem.eql(u8, hub.uuid, hub_uuid)) return hub.handle;
    }
    return null;
}

/// Fill a mission entry's `dir` + `name` from the campaign's resolved
/// mission table (uuid-keyed). Returns false when no table entry matches
/// (the caller warns - the exit names a mission the campaign's missions/
/// does not resolve).
fn fillMissionIdentityFromTable(
    mission: *types.CampaignMissionEdit,
    table: []const types.CampaignMissionEntry,
) bool {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.uuid, mission.uuid)) {
            // The table's dir is the FULL content path
            // ("campaigns/<c>/missions/<dir>"); the EDITOR's convention is
            // the bare dir name (the hub + import shape - the save writes
            // "<campaign>/missions/<dir>").
            mission.dir = std.fs.path.basename(entry.dir);
            mission.name = entry.name;
            return true;
        }
    }
    return false;
}

/// The inverse projection (see the file header). Returns false on a
/// campaign.txt read/parse failure (the caller's recoverable-error
/// path); every lesser problem warns + degrades.
pub fn loadCampaignEditorIntoState(
    history: *GameStateHistory,
    current: *GameState,
    allocator: std.mem.Allocator,
    campaign_content_dir: []const u8,
    warnings: *std.ArrayList([]const u8),
) bool {
    campaign_io_shared.clearCampaignSaveState(history);
    // `campaign_content_dir` is the CONTENT dir ("campaigns/<id>" - the
    // CampaignEntry.dir addressing, the browser row's dir verbatim; the
    // mission-row's full-path convention). loadCampaign derives the bare
    // campaign name from it (Campaign.dir) - the hub/mission path
    // components below address through that, matching
    // deriveCampaignEdges' shapes.
    const campaign_path = std.fmt.allocPrint(
        allocator,
        "{s}/campaign.txt",
        .{campaign_content_dir},
    ) catch @panic("failed to allocate campaign.txt path");
    const campaign_sections = blk: {
        const bytes = history.readReconstructionFile(campaign_path) catch return false;
        break :blk parser.parseConfigFile(bytes, allocator, &parser.campaign_sections) catch return false;
    };
    shared.validateConfigKeys(history, campaign_sections, parser.campaign_key_map, campaign_path, allocator);

    var campaign = loaders.loadCampaign(campaign_sections, campaign_content_dir, allocator, warnings) catch return false;

    // The uuid resolution scans (hub dirs + the mission table): LIVE, the
    // installCampaignGraph convention - listings are never cache-recorded.
    loaders.resolveCampaignHubs(&campaign, history.file_source, allocator, warnings);
    campaign.missions = loaders.resolveCampaignMissions(campaign, history.file_source, allocator, warnings);

    // The background's pixel dims (native-size drawing) - resolved through
    // the custom-asset dims machinery exactly like the runtime load.
    loaders.resolveCampaignBackgroundDims(&campaign, history.file_source, allocator, warnings);

    // The bare background stem (authored truth - what the metadata picker
    // edits and the writer writes; loadCampaign minted the sprite id,
    // which the projection does not keep).
    var background_stem: []const u8 = &.{};
    if (parser.findSection(campaign_sections, "Metadata")) |section| {
        if (section.entry_groups.len > 0) {
            if (parser.findValue(section.entry_groups[0].pairs, "background")) |value| {
                background_stem = allocator.dupe(u8, value) catch
                    @panic("failed to dupe background stem");
            }
        }
    }

    var hub_entries: std.ArrayList(types.CampaignHubEdit) = .empty;
    var decoration_types: std.ArrayList(types.DecorationTypeDef) = .empty;
    var mission_entries: std.ArrayList(types.CampaignMissionEdit) = .empty;
    var next_handle: u32 = 0;

    // Placed hubs -> entries (identity + position now; grid content from
    // each hub.txt below).
    for (campaign.hubs) |placed| {
        hub_entries.append(allocator, .{
            .handle = next_handle,
            .uuid = placed.uuid,
            .dir = placed.dir,
            .position = placed.position,
        }) catch @panic("failed to append campaign hub entry");
        next_handle += 1;
    }

    // Hub files: grid content + exits + NPCs. Indexed mutation throughout
    // (no pointers held across list appends - the ArrayList stability
    // lock). Fields MOVE out of the loaded Hub (arena-absorbed, nothing
    // frees).
    for (campaign.hubs, 0..) |placed, hub_index| {
        if (placed.dir.len == 0) {
            warn(warnings, allocator, "hub '{s}' has no readable hub directory - the map entry loads with an empty grid", .{placed.uuid});
            continue;
        }
        const hub_path = std.fmt.allocPrint(
            allocator,
            "campaigns/{s}/hubs/{s}/hub.txt",
            .{ campaign.dir, placed.dir },
        ) catch @panic("failed to allocate hub.txt path");
        const hub_sections = blk: {
            const bytes = history.readReconstructionFile(hub_path) catch {
                warn(warnings, allocator, "{s}: unreadable - the hub loads with an empty grid", .{hub_path});
                continue;
            };
            break :blk parser.parseConfigFile(bytes, allocator, &parser.hub_sections) catch {
                warn(warnings, allocator, "{s}: unparseable - the hub loads with an empty grid", .{hub_path});
                continue;
            };
        };
        shared.validateConfigKeys(history, hub_sections, parser.hub_key_map, hub_path, allocator);
        const hub = loaders.loadHub(hub_sections, history.file_source, allocator, hub_path, warnings) catch {
            warn(warnings, allocator, "{s}: load failed - the hub loads with an empty grid", .{hub_path});
            continue;
        };

        hub_entries.items[hub_index].name = hub.name;
        hub_entries.items[hub_index].grid.level_tiles = hub.hub_tiles;
        hub_entries.items[hub_index].grid.player_start = hub.player.position;
        hub_entries.items[hub_index].grid.color_wheel_index = hub.color_wheel_index;
        hub_entries.items[hub_index].npc_placements = hub.npcs;

        // Decorations -> the campaign-SHARED palette: dedup by the full
        // visual identity (the buildEditorMission pattern), placements
        // index into it.
        var decoration_placements: std.ArrayList(types.DecorationPlacement) = .empty;
        for (hub.decorations) |decoration| {
            var type_id: ?u32 = null;
            for (decoration_types.items, 0..) |definition, definition_index| {
                if (std.mem.eql(u8, definition.sprite, decoration.name) and
                    loaders.decorationFootprintEqual(definition.footprint, decoration.footprint) and
                    definition.color_index == decoration.color_index and
                    definition.keep_original_colors == decoration.keep_original_colors and
                    loaders.decorationLayersEqual(definition.layers, decoration.layers))
                {
                    type_id = @intCast(definition_index);
                    break;
                }
            }
            if (type_id == null) {
                type_id = @intCast(decoration_types.items.len);
                const footprint = allocator.dupe(types.Vector2, decoration.footprint) catch
                    @panic("failed to dupe decoration footprint");
                const layers = allocator.alloc(types.DecorationLayer, decoration.layers.len) catch
                    @panic("failed to alloc decoration layers");
                for (decoration.layers, 0..) |layer, layer_index| {
                    layers[layer_index] = .{
                        .sprite = allocator.dupe(u8, layer.sprite) catch
                            @panic("failed to dupe decoration layer sprite"),
                        .color_index = layer.color_index,
                        .behind = layer.behind,
                        .pixel_dims = layer.pixel_dims,
                    };
                }
                const id = allocator.dupe(u8, decoration.name) catch
                    @panic("failed to dupe decoration id");
                decoration_types.append(allocator, .{
                    .id = id,
                    .sprite = id,
                    .footprint = footprint,
                    .pixel_dims = decoration.pixel_dims,
                    .color_index = decoration.color_index,
                    .keep_original_colors = decoration.keep_original_colors,
                    .layers = layers,
                }) catch @panic("failed to append campaign decoration type");
            }
            decoration_placements.append(allocator, .{
                .type_id = type_id.?,
                .position = decoration.position,
            }) catch @panic("failed to append decoration placement");
        }
        hub_entries.items[hub_index].grid.decoration_placements =
            decoration_placements.toOwnedSlice(allocator) catch
                @panic("failed to own decoration placements slice");

        // Exits -> mission entries + this hub's exit placements. One
        // mission entry per uuid (find-or-create); a second exit naming
        // an already-started mission is the one-edge-rule violation -
        // warn + drop (the duplicate check the settle requires at load).
        var exit_placements: std.ArrayList(types.ExitPlacement) = .empty;
        for (hub.mission_exits) |exit| {
            if (exit.mission_uuid.len == 0) {
                warn(warnings, allocator, "{s}: an exit has no mission_uuid - dropped", .{hub_path});
                continue;
            }
            var mission_index: ?usize = null;
            for (mission_entries.items, 0..) |mission, entry_index| {
                if (mission.uuid.len > 0 and std.mem.eql(u8, mission.uuid, exit.mission_uuid)) {
                    mission_index = entry_index;
                    break;
                }
            }
            if (mission_index == null) {
                mission_entries.append(allocator, .{
                    .handle = next_handle,
                    .uuid = exit.mission_uuid,
                }) catch @panic("failed to append campaign mission entry");
                mission_index = mission_entries.items.len - 1;
                next_handle += 1;
                if (!fillMissionIdentityFromTable(&mission_entries.items[mission_index.?], campaign.missions)) {
                    warn(warnings, allocator, "an exit names mission '{s}' which the campaign's missions/ does not resolve - the edge loads unresolved", .{exit.mission_uuid});
                }
            }
            const index = mission_index.?;
            if (mission_entries.items[index].start != null) {
                warn(warnings, allocator, "mission '{s}' is referenced by exits in more than one place (the one-edge rule) - the duplicate is dropped", .{exit.mission_uuid});
                continue;
            }
            mission_entries.items[index].start = hub_entries.items[hub_index].handle;
            mission_entries.items[index].destination = resolveHubHandle(hub_entries.items, exit.destination_hub);
            if (exit.destination_hub.len > 0 and mission_entries.items[index].destination == null) {
                warn(warnings, allocator, "an exit names unplaced destination hub '{s}' - dangling (legal by design; attach the hub or re-wire the mission)", .{exit.destination_hub});
            }
            mission_entries.items[index].direction = exit.direction;
            exit_placements.append(allocator, .{
                .mission = mission_entries.items[index].handle,
                .position = exit.position,
            }) catch @panic("failed to append exit placement");
        }
        hub_entries.items[hub_index].exit_placements =
            exit_placements.toOwnedSlice(allocator) catch
                @panic("failed to own exit placements slice");
    }

    // The Orphans section (campaign.txt v4): unwired missions, frozen in
    // place. An entry naming an already-WIRED mission is the
    // both-wired-and-orphaned conflict - warn + ignore (the exit wins).
    if (parser.findSection(campaign_sections, "Orphans")) |section| {
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const mission_uuid = parser.findValue(pairs, "mission_uuid") orelse {
                warn(warnings, allocator, "an Orphans entry has no mission_uuid - dropped", .{});
                continue;
            };
            if (mission_uuid.len == 0) {
                warn(warnings, allocator, "an Orphans entry has an empty mission_uuid - dropped", .{});
                continue;
            }
            var mission_index: ?usize = null;
            for (mission_entries.items, 0..) |mission, entry_index| {
                if (mission.uuid.len > 0 and std.mem.eql(u8, mission.uuid, mission_uuid)) {
                    mission_index = entry_index;
                    break;
                }
            }
            if (mission_index) |index| {
                if (mission_entries.items[index].start != null) {
                    warn(warnings, allocator, "mission '{s}' is both wired and orphaned - the Orphans entry is ignored", .{mission_uuid});
                    continue;
                }
            } else {
                mission_entries.append(allocator, .{
                    .handle = next_handle,
                    .uuid = allocator.dupe(u8, mission_uuid) catch
                        @panic("failed to dupe orphan mission uuid"),
                }) catch @panic("failed to append orphan mission entry");
                mission_index = mission_entries.items.len - 1;
                next_handle += 1;
                if (!fillMissionIdentityFromTable(&mission_entries.items[mission_index.?], campaign.missions)) {
                    warn(warnings, allocator, "an Orphans entry names mission '{s}' which the campaign's missions/ does not resolve - it loads unresolved", .{mission_uuid});
                }
            }
            const index = mission_index.?;
            const destination_uuid = parser.findValue(pairs, "destination_hub") orelse &.{};
            const destination = resolveHubHandle(hub_entries.items, destination_uuid);
            mission_entries.items[index].destination = destination;
            // Ghost positions: expected ONLY for ends that do not resolve
            // to a live hub (a live destination supplies its own geometry;
            // the save writes ghosts only for missing ends - a live
            // destination with no ghost is the normal state, not a warn).
            mission_entries.items[index].orphan_start_position =
                parseGhostPosition(pairs, "start_position", mission_uuid, warnings, allocator);
            if (destination == null) {
                mission_entries.items[index].orphan_destination_position =
                    parseGhostPosition(pairs, "destination_position", mission_uuid, warnings, allocator);
            }
        }
    }

    // The start hub: resolve the uuid against the projected entries (null
    // = unset - the toggle fixes it; the integrity-check warnings already
    // named the missing start).
    var start_hub: ?u32 = null;
    if (campaign.start_hub.len > 0) {
        start_hub = resolveHubHandle(hub_entries.items, campaign.start_hub);
    }

    current.campaign_editor = .{
        .campaign_name = campaign.name,
        .campaign_uuid = campaign.uuid,
        .campaign_dir = allocator.dupe(u8, campaign_content_dir) catch
            @panic("failed to dupe campaign dir"),
        .background_stem = background_stem,
        .background_dims = campaign.background_dims,
        .start_hub = start_hub,
        .hubs = hub_entries.toOwnedSlice(allocator) catch
            @panic("failed to own campaign hubs slice"),
        .missions = mission_entries.toOwnedSlice(allocator) catch
            @panic("failed to own campaign missions slice"),
        .decoration_types = decoration_types.toOwnedSlice(allocator) catch
            @panic("failed to own campaign decoration types slice"),
        .next_handle = next_handle,
    };
    return true;
}

/// One Orphans ghost position: warn + default to the map origin when
/// missing or unparsable (see the caller).
fn parseGhostPosition(
    pairs: []const parser.KeyValuePair,
    key: []const u8,
    mission_uuid: []const u8,
    warnings: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) types.Vector2 {
    const value = parser.findValue(pairs, key) orelse {
        warn(warnings, allocator, "orphaned mission '{s}' has no {s} - defaults to the map origin", .{ mission_uuid, key });
        return .{ .x = 0, .y = 0 };
    };
    return loaders.parseVector2Pair(value) orelse {
        warn(warnings, allocator, "orphaned mission '{s}' has an unparsable {s} '{s}' - defaults to the map origin", .{ mission_uuid, key, value });
        return .{ .x = 0, .y = 0 };
    };
}
