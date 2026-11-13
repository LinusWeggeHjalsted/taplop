//! The campaign editor's handler module (the src/editor/ family's
//! campaign sibling - see DESIGN → Campaigns & the Campaign Editor,
//! esp. The editor-state split + The campaign editor surface). Owns the
//! open/close framing + the campaign-editor event arms on
//! GameState.campaign_editor. The state is the AUTHORED graph
//! (CampaignEditor in types.zig), not the load-derived Campaign type.

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;

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
