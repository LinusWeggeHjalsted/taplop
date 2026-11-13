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
