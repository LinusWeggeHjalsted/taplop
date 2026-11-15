//! Save/settings writers - the inverse of the loaders (loaders.zig). Converts
//! typed game objects (`PlayerData`, `Settings`) back into the config-file
//! text format. See DESIGN → File System & IO / AGENTS → Config File Format.

const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");
const file_source_mod = @import("file_source.zig");

const FileSource = file_source_mod.FileSource;
const PlayerData = types.PlayerData;

/// Persistent path of the autosave. Written on every hub/level transition
/// (after the player-entity → PlayerData sync) so the main-menu Continue
/// button can resume from the last visited hub on a fresh launch. See
/// DESIGN → File System & IO (autosave).
pub const autosave_path = "saves/autosave.txt";
const Settings = types.Settings;
const Weapon = types.Weapon;
const Item = types.Item;
const player_save_file_format_version = parser.player_save_file_format_version;
const settings_file_format_version = parser.settings_file_format_version;
const loadPlayerSave = loaders.loadPlayerSave;
const parseConfigFile = parser.parseConfigFile;
const parseConfigFileFromPath = parser.parseConfigFileFromPath;
const freeParsedSections = parser.freeParsedSections;
const freeSettings = loaders.freeSettings;

// ============================================================
// Save file writer
// ============================================================

/// Format a PlayerData struct into the .txt save file format.
/// Returns an owned slice - caller must free with the same allocator.
/// This is the core function used by both web (download) and standalone (file write).
fn writePlayerSave(
    player_data: PlayerData,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;

    // Info
    try buffer.appendSlice(allocator, "Metadata\n");
    try buffer.print(allocator, "file_format_version {d}\n", .{player_save_file_format_version});
    try buffer.appendSlice(allocator, "\nInfo\n");
    try buffer.print(allocator, "player_name {s}\n", .{player_data.player_name});
    try buffer.print(allocator, "current_campaign {s}\n", .{player_data.current_campaign});
    try buffer.print(allocator, "current_campaign_uuid {s}\n", .{player_data.current_campaign_uuid});
    try buffer.print(allocator, "current_hub {s}\n", .{player_data.current_hub});
    try buffer.print(allocator, "turns {d}\n", .{player_data.turns});
    try buffer.print(allocator, "deaths {d}\n", .{player_data.deaths});
    try buffer.print(allocator, "defeated_enemies {d}\n", .{player_data.defeated_enemies});
    try buffer.print(allocator, "skills_used {d}\n", .{player_data.skills_used});
    try buffer.print(allocator, "wood_salvage {d}\n", .{player_data.materials.wood});
    try buffer.print(allocator, "metal_salvage {d}\n", .{player_data.materials.metal});
    try buffer.print(allocator, "leather_salvage {d}\n", .{player_data.materials.leather});
    try buffer.print(allocator, "cloth_salvage {d}\n", .{player_data.materials.cloth});
    try buffer.print(allocator, "knowledge {d}\n", .{player_data.materials.knowledge});

    // DiscoveredHubs - one group per campaign: the campaign_uuid line,
    // then one `name` (hub uuid) per entry group (the parser's grouping
    // shape: names after their campaign_uuid line belong to it).
    try buffer.appendSlice(allocator, "\nDiscoveredHubs\n");
    for (player_data.discovered_hubs, 0..) |group, group_index| {
        try buffer.print(allocator, "campaign_uuid {s}\n\n", .{group.campaign_uuid});
        for (group.hub_uuids, 0..) |hub_uuid, hub_index| {
            try buffer.print(allocator, "name {s}\n", .{hub_uuid});
            const last_in_group = hub_index == group.hub_uuids.len - 1;
            const last_group = group_index == player_data.discovered_hubs.len - 1;
            if (!last_in_group or !last_group) {
                try buffer.appendSlice(allocator, "\n");
            }
        }
    }

    // UnlockedSkills
    try buffer.appendSlice(allocator, "\nUnlockedSkills\n");
    for (player_data.learned_skills, 0..) |skill_id, index| {
        try buffer.print(allocator, "name {s}\n", .{@tagName(skill_id)});
        if (index < player_data.learned_skills.len - 1) {
            try buffer.appendSlice(allocator, "\n");
        }
    }

    // MainHandWeapon .. UtilitySkills: the shared loadout sections (also
    // the editor mission's player.txt - see writePlayerLoadout).
    try writeLoadoutSections(player_data, &buffer, allocator);

    // CloneData
    try buffer.appendSlice(allocator, "\nCloneData\n");
    for (player_data.clones, 0..) |clone, index| {
        try buffer.print(allocator, "mission_uuid {s}\n", .{clone.mission_uuid});
        try buffer.print(allocator, "clone_name {s}\n", .{clone.name});
        try buffer.print(allocator, "wood {d}\n", .{clone.materials_collected.wood});
        try buffer.print(allocator, "metal {d}\n", .{clone.materials_collected.metal});
        try buffer.print(allocator, "leather {d}\n", .{clone.materials_collected.leather});
        try buffer.print(allocator, "cloth {d}\n", .{clone.materials_collected.cloth});
        try buffer.print(allocator, "knowledge {d}\n", .{clone.materials_collected.knowledge});
        try buffer.print(allocator, "turns_to_complete {d}\n", .{clone.turns_to_complete});
        if (index < player_data.clones.len - 1) {
            try buffer.appendSlice(allocator, "\n");
        }
    }

    return try buffer.toOwnedSlice(allocator);
}

/// The loadout sections shared by the player SAVE and the editor mission's
/// player.txt (the PlayerLoadout format - `parsePlayerLoadoutFields` is the
/// shared reader; see DESIGN → Level Editor → Player loadout). The save
/// embeds these between UnlockedSkills and CloneData; the mission player.txt
/// is exactly these sections under its own Metadata.
fn writeLoadoutSections(
    player_data: PlayerData,
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    // MainHandWeapon
    try buffer.appendSlice(allocator, "\nMainHandWeapon\n");
    if (player_data.main_hand_weapon) |weapon| {
        try writeWeapon(buffer, allocator, weapon);
    }

    // OffHandWeapon
    try buffer.appendSlice(allocator, "\nOffHandWeapon\n");
    if (player_data.off_hand_weapon) |weapon| {
        try writeWeapon(buffer, allocator, weapon);
    }

    // Amulet
    try buffer.appendSlice(allocator, "\nAmulet\n");
    if (player_data.amulet) |amulet| {
        try buffer.print(allocator, "item_name {s}\n", .{amulet.name});
        try buffer.print(allocator, "spell_damage {d}\n", .{amulet.spell_damage});
    }

    // Coat
    try buffer.appendSlice(allocator, "\nCoat\n");
    if (player_data.coat) |coat| {
        try buffer.print(allocator, "item_name {s}\n", .{coat.name});
        try buffer.print(allocator, "armor {d}\n", .{coat.defense_bonus});
        try buffer.print(allocator, "health {d}\n", .{coat.health_bonus});
    }

    // Gloves
    try buffer.appendSlice(allocator, "\nGloves\n");
    if (player_data.gloves) |gloves| {
        try buffer.print(allocator, "item_name {s}\n", .{gloves.name});
        try buffer.print(allocator, "health {d}\n", .{gloves.health_bonus});
        try buffer.print(allocator, "damage {d}\n", .{gloves.damage_bonus});
    }

    // Pants
    try buffer.appendSlice(allocator, "\nPants\n");
    if (player_data.pants) |pants| {
        try buffer.print(allocator, "item_name {s}\n", .{pants.name});
        try buffer.print(allocator, "health {d}\n", .{pants.health_bonus});
        try buffer.print(allocator, "pickup_radius {d}\n", .{pants.pickup_radius_bonus});
    }

    // Boots
    try buffer.appendSlice(allocator, "\nBoots\n");
    if (player_data.boots) |boots| {
        try buffer.print(allocator, "item_name {s}\n", .{boots.name});
        try buffer.print(allocator, "health {d}\n", .{boots.health_bonus});
        try buffer.print(allocator, "speed {d}\n", .{boots.speed_bonus});
    }

    // Inventory
    try buffer.appendSlice(allocator, "\nInventory\n");
    var wrote_inventory_item = false;
    for (player_data.inventory.slots, 0..) |maybe_item, slot_index| {
        if (maybe_item) |item| {
            if (wrote_inventory_item) {
                try buffer.appendSlice(allocator, "\n");
            }
            try writeInventoryItem(buffer, allocator, item, @intCast(slot_index));
            wrote_inventory_item = true;
        }
    }

    // UtilitySkills
    // Only filled slots are written, keyed by their bar slot number (4-8), so
    // empty (null) slots are simply omitted and reload to null.
    try buffer.appendSlice(allocator, "\nUtilitySkills\n");
    for (player_data.equipped_utility_skills, 0..) |slot, index| {
        if (slot) |skill_id| {
            const slot_number = index + 4; // slots start at 4
            try buffer.print(allocator, "slot_{d} {s}\n", .{ slot_number, @tagName(skill_id) });
        }
    }
}

fn writeWeapon(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    weapon: types.Weapon,
) !void {
    try buffer.print(allocator, "item_name {s}\n", .{weapon.name});
    try buffer.print(allocator, "weapon_type {s}\n", .{@tagName(weapon.weapon_type)});
    try buffer.print(allocator, "damage {d}\n", .{weapon.weapon_damage});
}

fn writeInventoryItem(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    item: types.Item,
    slot_index: u32,
) !void {
    switch (item) {
        .weapon => |weapon| {
            try buffer.appendSlice(allocator, "item_type weapon\n");
            try buffer.print(allocator, "item_name {s}\n", .{weapon.name});
            try buffer.print(allocator, "weapon_type {s}\n", .{@tagName(weapon.weapon_type)});
            try buffer.print(allocator, "damage {d}\n", .{weapon.weapon_damage});
        },
        .amulet => |amulet| {
            try buffer.appendSlice(allocator, "item_type amulet\n");
            try buffer.print(allocator, "item_name {s}\n", .{amulet.name});
            try buffer.print(allocator, "spell_damage {d}\n", .{amulet.spell_damage});
        },
        .coat => |coat| {
            try buffer.appendSlice(allocator, "item_type coat\n");
            try buffer.print(allocator, "item_name {s}\n", .{coat.name});
            try buffer.print(allocator, "armor {d}\n", .{coat.defense_bonus});
            try buffer.print(allocator, "health {d}\n", .{coat.health_bonus});
        },
        .gloves => |gloves| {
            try buffer.appendSlice(allocator, "item_type gloves\n");
            try buffer.print(allocator, "item_name {s}\n", .{gloves.name});
            try buffer.print(allocator, "health {d}\n", .{gloves.health_bonus});
            try buffer.print(allocator, "damage {d}\n", .{gloves.damage_bonus});
        },
        .pants => |pants| {
            try buffer.appendSlice(allocator, "item_type pants\n");
            try buffer.print(allocator, "item_name {s}\n", .{pants.name});
            try buffer.print(allocator, "health {d}\n", .{pants.health_bonus});
            try buffer.print(allocator, "pickup_radius {d}\n", .{pants.pickup_radius_bonus});
        },
        .boots => |boots| {
            try buffer.appendSlice(allocator, "item_type boots\n");
            try buffer.print(allocator, "item_name {s}\n", .{boots.name});
            try buffer.print(allocator, "health {d}\n", .{boots.health_bonus});
            try buffer.print(allocator, "speed {d}\n", .{boots.speed_bonus});
        },
        .skill_tome => |tome| {
            try buffer.appendSlice(allocator, "item_type skill_tome\n");
            try buffer.print(allocator, "item_name {s} Tome\n", .{@tagName(tome.skill)});
            try buffer.print(allocator, "skill_name {s}\n", .{@tagName(tome.skill)});
        },
    }
    try buffer.print(allocator, "slot {d}\n", .{slot_index});
}

/// Serialize a `Settings` struct to the config-file format (same shape as
/// `data/default_settings.txt`). Used to persist user preferences to
/// `~/.ziglop/settings.txt` - see DESIGN → Input. The full settings are
/// written (audio + display + gameplay + InputBindings) so the user file is
/// the same format as the defaults. The loader overlays this onto the shipped
/// defaults at startup (per-field scalars, binding replace).
pub fn writeSettings(
    settings: types.Settings,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;

    // Metadata
    try buffer.appendSlice(allocator, "Metadata\n");
    try buffer.print(allocator, "file_format_version {d}\n", .{settings_file_format_version});

    // Audio
    try buffer.appendSlice(allocator, "\nAudio\n");
    // Audio - u32 percentages 0-100. See DESIGN → UI Framework → Settings
    // screen (Volume integer migration).
    try buffer.print(allocator, "master_volume {d}\n", .{settings.master_volume});
    try buffer.print(allocator, "music_volume {d}\n", .{settings.music_volume});
    try buffer.print(allocator, "sound_effects_volume {d}\n", .{settings.sound_effects_volume});

    // Display
    try buffer.appendSlice(allocator, "\nDisplay\n");
    try buffer.print(allocator, "vsync {}\n", .{settings.vsync});
    try buffer.print(allocator, "render_fps_cap {d}\n", .{settings.render_fps_cap});
    try buffer.print(allocator, "camera_zoom {d}\n", .{settings.camera_zoom});
    try buffer.print(allocator, "animation_fps {d}\n", .{settings.animation_fps});
    try buffer.print(allocator, "render_resolution {s}\n", .{settings.render_resolution.label()});

    // Gameplay
    try buffer.appendSlice(allocator, "\nGameplay\n");
    try buffer.print(allocator, "auto_skip_attack_step_out_of_combat {}\n", .{settings.auto_skip_attack_step_out_of_combat});
    try buffer.print(allocator, "auto_target_at_cursor {}\n", .{settings.auto_target_at_cursor});
    try buffer.print(allocator, "show_fps {}\n", .{settings.show_fps});
    try buffer.print(allocator, "player_color_index {d}\n", .{settings.player_color_index});

    // InputBindings - one entry group per binding, blank-line-separated.
    try buffer.appendSlice(allocator, "\nInputBindings\n");
    for (settings.input_bindings, 0..) |binding, index| {
        if (index > 0) try buffer.appendSlice(allocator, "\n");
        const input_type_str = switch (binding.input) {
            .key => "key",
            .mouse_button => "mouse_button",
            .gamepad_button => "gamepad_button",
        };
        const input_name = switch (binding.input) {
            .key => |name| name,
            .mouse_button => |name| name,
            .gamepad_button => |name| name,
        };
        try buffer.print(allocator, "input_type {s}\n", .{input_type_str});
        try buffer.print(allocator, "input_name {s}\n", .{input_name});
        if (binding.modifiers.ctrl) try buffer.appendSlice(allocator, "ctrl true\n");
        if (binding.modifiers.shift) try buffer.appendSlice(allocator, "shift true\n");
        if (binding.modifiers.alt) try buffer.appendSlice(allocator, "alt true\n");
        try buffer.print(allocator, "action {s}\n", .{@tagName(binding.action)});
        // Informational only - a binding's active contexts are DERIVED
        // from the action at load (`actionBindingContexts`); the line is
        // written so the file stays the same shape an older binary (or a
        // human) expects. See DESIGN → Input → Binding contexts.
        try buffer.print(allocator, "context {s}\n", .{@tagName(types.primaryBindingContext(binding.action))});
    }

    return try buffer.toOwnedSlice(allocator);
}

/// Write a PlayerData struct to the persistent data dir via the FileSource.
pub fn writePlayerSaveToFile(
    file_source: *const FileSource,
    file_path: []const u8,
    player_data: PlayerData,
    allocator: std.mem.Allocator,
) !void {
    const save_data = try writePlayerSave(player_data, allocator);
    defer allocator.free(save_data);
    try file_source.writeFile(file_path, save_data);
}

// ============================================================
// Editor mission writer
// ============================================================
//
// The pure projection of an `Editor` into mission-directory file contents -
// the inverse of loadLevel/loadMission/loadPlayerLoadout + buildEditorMission.
// The SAVE HANDLER owns the uuid resolution + the IO; this writer is
// deterministic + side-effect free (directly round-trip-testable).
// See DESIGN → Level Editor → Mission identity + Editor UI layout.

/// Everything the editor save writes for one mission.
pub const WrittenEditorMission = struct {
    mission_txt: []const u8,
    player_txt: []const u8,
    /// One per editor level, in tab order - the handler writes them as
    /// level_1.txt .. level_N.txt.
    level_txts: []const []const u8,
};

/// Layout char-code assignment order: digits, lowercase, uppercase, then
/// the remaining printable ASCII. The reserved layout chars (' ', '.',
/// '!', '=') are never assigned - 91 codes available per level.
const layout_code_order: [91]u8 = blk: {
    var codes: [91]u8 = undefined;
    var length: usize = 0;
    // The primary sequence in assignment order: digits 1-9, lowercase,
    // uppercase.
    var code: u8 = '1';
    while (code <= '9') : (code += 1) {
        codes[length] = code;
        length += 1;
    }
    code = 'a';
    while (code <= 'z') : (code += 1) {
        codes[length] = code;
        length += 1;
    }
    code = 'A';
    while (code <= 'Z') : (code += 1) {
        codes[length] = code;
        length += 1;
    }
    // Then the remaining printable ASCII (reserved layout chars ' ', '.',
    // '!', '=' are never assignable - ' ' isn't in this range to begin
    // with).
    code = 0x21;
    while (code <= 0x7e) : (code += 1) {
        const is_primary = (code >= '1' and code <= '9') or
            (code >= 'a' and code <= 'z') or (code >= 'A' and code <= 'Z');
        if (is_primary or code == '!' or code == '.' or code == '=') continue;
        codes[length] = code;
        length += 1;
    }
    break :blk codes;
};

/// One per-level char-code assignment: a tool the level places → its
/// layout char. Codes are assigned PER LEVEL (a level file only defines
/// the tools it uses), in palette order - entities, then decorations,
/// then items.
const LayoutCodeAssignment = struct {
    type_id: u32,
    code: u8,
};

/// Write the whole mission: mission.txt, player.txt, and one level file
/// per level. `mission_uuid` is passed in - the write-only mint lives at
/// the save site (a fresh mission's uuid is minted at first save and
/// never held in GameState; see DESIGN → Level Editor → Mission
/// identity). Fails with error.TooManyLayoutCodes when a single level
/// places more tools than the char-code set provides.
pub fn writeEditorMission(
    editor: types.Editor,
    mission_uuid: []const u8,
    mission_content_path: []const u8,
    allocator: std.mem.Allocator,
) !WrittenEditorMission {
    var mission_buffer: std.ArrayList(u8) = .empty;
    try mission_buffer.appendSlice(allocator, "Metadata\n");
    try mission_buffer.print(allocator, "file_format_version {d}\n", .{parser.mission_file_format_version});
    try mission_buffer.print(allocator, "mission_uuid {s}\n", .{mission_uuid});
    try mission_buffer.print(allocator, "name {s}\n", .{editor.mission.name});
    // No level_count: derived from the dir's level files (the loader's
    // probe) - nothing authored duplicates the dir's truth.

    const player_txt = try writePlayerLoadout(editor.player_def.template, allocator);

    var level_txts: std.ArrayList([]const u8) = .empty;
    for (editor.levels) |level| {
        try level_txts.append(allocator, try writeEditorLevel(
            level,
            editor.entity_types,
            editor.decoration_types,
            editor.item_types,
            mission_content_path,
            allocator,
        ));
    }

    return .{
        .mission_txt = try mission_buffer.toOwnedSlice(allocator),
        .player_txt = player_txt,
        .level_txts = try level_txts.toOwnedSlice(allocator),
    };
}

/// Write the mission's player.txt - the PlayerLoadout format (the loadout
/// sections of a player save; no Info/stats/hubs - base stats aren't
/// authorable and the NAME is not part of the format, so a reloaded
/// loadout reads back as "Player" regardless of the template's name).
fn writePlayerLoadout(
    template: types.Entity,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const loadout_data = PlayerData{
        .player_name = template.name,
        .main_hand_weapon = template.main_hand_weapon,
        .off_hand_weapon = template.off_hand_weapon,
        .amulet = template.amulet,
        .coat = template.coat,
        .gloves = template.gloves,
        .pants = template.pants,
        .boots = template.boots,
        .inventory = template.inventory,
        .equipped_utility_skills = template.equipped_utility_skills,
    };
    var buffer: std.ArrayList(u8) = .empty;
    try buffer.appendSlice(allocator, "Metadata\n");
    try buffer.print(allocator, "file_format_version {d}\n", .{parser.player_loadout_file_format_version});
    try writeLoadoutSections(loadout_data, &buffer, allocator);
    return try buffer.toOwnedSlice(allocator);
}

/// Does any placement in `placements` reference `type_id`? (All three
/// placement types carry `type_id`.)
fn levelUsesType(placements: anytype, type_id: u32) bool {
    for (placements) |placement| {
        if (placement.type_id == type_id) return true;
    }
    return false;
}

/// The code assigned to `type_id`, or null when the type isn't placed in
/// this level.
fn codeForType(assignments: []const LayoutCodeAssignment, type_id: u32) ?u8 {
    for (assignments) |assignment| {
        if (assignment.type_id == type_id) return assignment.code;
    }
    return null;
}

/// Assign per-level layout codes to the tools `level` places, in palette
/// order (entities → decorations → items). Only used tools get codes +
/// definitions - a level file never carries a tool it doesn't place.
fn assignLayoutCodes(
    level: types.EditorLevel,
    entity_types: []const types.EntityTypeDef,
    decoration_types: []const types.DecorationTypeDef,
    item_types: []const types.ItemTypeDef,
    allocator: std.mem.Allocator,
) !struct {
    entity: []const LayoutCodeAssignment,
    decoration: []const LayoutCodeAssignment,
    item: []const LayoutCodeAssignment,
} {
    var entity_codes: std.ArrayList(LayoutCodeAssignment) = .empty;
    var decoration_codes: std.ArrayList(LayoutCodeAssignment) = .empty;
    var item_codes: std.ArrayList(LayoutCodeAssignment) = .empty;

    var next_code: usize = 0;
    for (entity_types, 0..) |_, type_id| {
        if (!levelUsesType(level.entity_placements, @intCast(type_id))) continue;
        if (next_code >= layout_code_order.len) return error.TooManyLayoutCodes;
        try entity_codes.append(allocator, .{
            .type_id = @intCast(type_id),
            .code = layout_code_order[next_code],
        });
        next_code += 1;
    }
    for (decoration_types, 0..) |_, type_id| {
        if (!levelUsesType(level.decoration_placements, @intCast(type_id))) continue;
        if (next_code >= layout_code_order.len) return error.TooManyLayoutCodes;
        try decoration_codes.append(allocator, .{
            .type_id = @intCast(type_id),
            .code = layout_code_order[next_code],
        });
        next_code += 1;
    }
    for (item_types, 0..) |_, type_id| {
        if (!levelUsesType(level.item_placements, @intCast(type_id))) continue;
        if (next_code >= layout_code_order.len) return error.TooManyLayoutCodes;
        try item_codes.append(allocator, .{
            .type_id = @intCast(type_id),
            .code = layout_code_order[next_code],
        });
        next_code += 1;
    }

    return .{
        .entity = try entity_codes.toOwnedSlice(allocator),
        .decoration = try decoration_codes.toOwnedSlice(allocator),
        .item = try item_codes.toOwnedSlice(allocator),
    };
}

/// Set one cell of the translated layout grid. `origin` is the bbox min;
/// out-of-range cells (a footprint tile outside the bbox - impossible by
/// construction, the bbox includes every footprint) trap in debug builds.
fn setGridCell(
    grid: []u8,
    grid_width: i32,
    origin: types.Vector2,
    position: types.Vector2,
    character: u8,
) void {
    const x = position.x - origin.x;
    const y = position.y - origin.y;
    std.debug.assert(x >= 0 and y >= 0);
    std.debug.assert(x < grid_width and y * grid_width + x < @as(i32, @intCast(grid.len)));
    grid[@intCast(y * grid_width + x)] = character;
}

/// Rewrite a custom sprite stem to the save target: the last segment
/// (the file stem) is kept, everything else becomes `custom/<mission
/// content path>/<file-stem>` - the stem's tail IS the art's read path
/// (file_source.customAssetTail; see DESIGN → Custom Missions & Online
/// Services → Custom-asset paths), so the save is where a stale path (a
/// mission renamed after authoring keeps stems pointing at the old dir)
/// is healed: the stems rewrite to the new dir and the save's art copy
/// carries the bytes there. Non-custom stems and degenerate stems (no
/// dir segment - the picker never writes them) pass through unchanged.
fn normalizedCustomStem(
    sprite: []const u8,
    mission_content_path: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    if (!std.mem.startsWith(u8, sprite, "custom/")) return sprite;
    const slash = std.mem.lastIndexOfScalar(u8, sprite, '/') orelse return sprite;
    const file_stem = sprite[slash + 1 ..];
    if (file_stem.len == 0) return sprite;
    return std.fmt.allocPrint(allocator, "custom/{s}/{s}", .{ mission_content_path, file_stem });
}

/// Write one level file. The layout is TRANSLATED so the written grid is
/// minimal: the bbox over everything placed (tiles, placements, whole
/// decoration footprints, '!', '=') becomes the grid, each row trimmed to
/// its own last used column. Enemy/item chars imply their tile on reload
/// (the parser tiles under them), so a code overwrites the '.'; decoration
/// anchors take no tile (the rest of the footprint stays spaces).
fn writeEditorLevel(
    level: types.EditorLevel,
    entity_types: []const types.EntityTypeDef,
    decoration_types: []const types.DecorationTypeDef,
    item_types: []const types.ItemTypeDef,
    mission_content_path: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const codes = try assignLayoutCodes(level, entity_types, decoration_types, item_types, allocator);

    // The bbox over everything placed - the player start is always present
    // (the '!' can't be deleted), so the bbox is never empty.
    var min_x = level.player_start.x;
    var min_y = level.player_start.y;
    var max_x = level.player_start.x;
    var max_y = level.player_start.y;
    const expand = struct {
        fn bounds(
            bounds_min_x: *i32,
            bounds_min_y: *i32,
            bounds_max_x: *i32,
            bounds_max_y: *i32,
            position: types.Vector2,
        ) void {
            bounds_min_x.* = @min(bounds_min_x.*, position.x);
            bounds_min_y.* = @min(bounds_min_y.*, position.y);
            bounds_max_x.* = @max(bounds_max_x.*, position.x);
            bounds_max_y.* = @max(bounds_max_y.*, position.y);
        }
    };
    for (level.level_tiles) |tile| expand.bounds(&min_x, &min_y, &max_x, &max_y, tile);
    if (level.level_end) |level_end| expand.bounds(&min_x, &min_y, &max_x, &max_y, level_end);
    for (level.entity_placements) |placement| expand.bounds(&min_x, &min_y, &max_x, &max_y, placement.position);
    for (level.item_placements) |placement| expand.bounds(&min_x, &min_y, &max_x, &max_y, placement.position);
    for (level.decoration_placements) |placement| {
        const footprint_tiles = loaders.decorationFootprintWorldTiles(
            decoration_types[placement.type_id].footprint,
            placement.position,
            allocator,
        );
        defer allocator.free(footprint_tiles);
        for (footprint_tiles) |tile| expand.bounds(&min_x, &min_y, &max_x, &max_y, tile);
    }
    const origin = types.Vector2{ .x = min_x, .y = min_y };
    const grid_width: i32 = max_x - min_x + 1;
    const grid_height: i32 = max_y - min_y + 1;

    const grid = try allocator.alloc(u8, @intCast(grid_width * grid_height));
    defer allocator.free(grid);
    @memset(grid, ' ');
    // Tiles first - the marker + code chars below overwrite their own
    // tiles (each implies it on reload).
    for (level.level_tiles) |tile| setGridCell(grid, grid_width, origin, tile, '.');
    setGridCell(grid, grid_width, origin, level.player_start, '!');
    if (level.level_end) |level_end| setGridCell(grid, grid_width, origin, level_end, '=');
    for (level.entity_placements) |placement| {
        setGridCell(grid, grid_width, origin, placement.position, codeForType(codes.entity, placement.type_id).?);
    }
    for (level.item_placements) |placement| {
        setGridCell(grid, grid_width, origin, placement.position, codeForType(codes.item, placement.type_id).?);
    }
    for (level.decoration_placements) |placement| {
        setGridCell(grid, grid_width, origin, placement.position, codeForType(codes.decoration, placement.type_id).?);
    }

    var buffer: std.ArrayList(u8) = .empty;

    // Metadata
    try buffer.appendSlice(allocator, "Metadata\n");
    try buffer.print(allocator, "file_format_version {d}\n", .{parser.level_file_format_version});
    if (level.name.len > 0) {
        try buffer.print(allocator, "name {s}\n", .{level.name});
    }
    if (level.color_wheel_index != 0) {
        try buffer.print(allocator, "color_wheel_index {d}\n", .{level.color_wheel_index});
    }
    if (level.enemy_gradient_index) |gradient_index| {
        try buffer.print(allocator, "enemy_gradient_index {d}\n", .{gradient_index});
    }
    if (level.player_gradient_index) |gradient_index| {
        try buffer.print(allocator, "player_gradient_index {d}\n", .{gradient_index});
    }

    // Layout - each row trimmed to its own last used column (no trailing
    // spaces; interior all-space rows stay as empty lines, which the
    // parser stores as empty raw rows). The opening line carries the row
    // count (the counted grammar) so no row CONTENT can end the section -
    // a row can spell any section header.
    try buffer.print(allocator, "\nLayout {d}\n", .{grid_height});
    var row: i32 = 0;
    while (row < grid_height) : (row += 1) {
        const row_start: usize = @intCast(row * grid_width);
        const row_cells = grid[row_start .. row_start + @as(usize, @intCast(grid_width))];
        var row_length = row_cells.len;
        while (row_length > 0 and row_cells[row_length - 1] == ' ') row_length -= 1;
        try buffer.appendSlice(allocator, row_cells[0..row_length]);
        try buffer.appendSlice(allocator, "\n");
    }

    // Entities - used entity types, palette order, the full definition in
    // the parser's exact key vocabulary (the coupling contract).
    if (codes.entity.len > 0) {
        try buffer.appendSlice(allocator, "\nEntities\n");
        for (codes.entity, 0..) |assignment, index| {
            if (index > 0) try buffer.appendSlice(allocator, "\n");
            try writeEntityDefinition(&buffer, allocator, assignment.code, entity_types[assignment.type_id].template, mission_content_path);
        }
    }

    // Decorations - used decoration types (sprite + footprint + layers).
    if (codes.decoration.len > 0) {
        try buffer.appendSlice(allocator, "\nDecorations\n");
        for (codes.decoration, 0..) |assignment, index| {
            if (index > 0) try buffer.appendSlice(allocator, "\n");
            const definition = decoration_types[assignment.type_id];
            try buffer.print(allocator, "character_code {s}\n", .{&[_]u8{assignment.code}});
            try buffer.print(allocator, "sprite {s}\n", .{try normalizedCustomStem(definition.sprite, mission_content_path, allocator)});
            try buffer.print(allocator, "color_index {d}\n", .{definition.color_index});
            if (definition.keep_original_colors) {
                try buffer.print(allocator, "keep_original_colors true\n", .{});
            }
            for (definition.footprint) |footprint_tile| {
                try buffer.print(allocator, "footprint {d} {d}\n", .{ footprint_tile.x, footprint_tile.y });
            }
            for (definition.layers) |layer| {
                try buffer.appendSlice(allocator, "layer\n");
                try buffer.print(allocator, "sprite {s}\n", .{try normalizedCustomStem(layer.sprite, mission_content_path, allocator)});
                try buffer.print(allocator, "color_index {d}\n", .{layer.color_index});
                if (layer.behind) {
                    try buffer.appendSlice(allocator, "behind true\n");
                }
            }
        }
    }

    // Items - used item types. Skill tomes are not level-authorable (the
    // editor's item paths never create them); a tome here is a crafted
    // state the editor's own invariants forbid - fail fast.
    if (codes.item.len > 0) {
        try buffer.appendSlice(allocator, "\nItems\n");
        for (codes.item, 0..) |assignment, index| {
            if (index > 0) try buffer.appendSlice(allocator, "\n");
            try writeItemDefinition(&buffer, allocator, assignment.code, item_types[assignment.type_id].item);
        }
    }

    return try buffer.toOwnedSlice(allocator);
}

/// One Entities entry - every key `parseEntityDefinition` reads, in its
/// vocabulary (weapons / gear / utility skills / layers only when
/// present, so absent-on-reload equals absent-on-write).
fn writeEntityDefinition(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    code: u8,
    template: types.Entity,
    mission_content_path: []const u8,
) !void {
    try buffer.print(allocator, "character_code {s}\n", .{&[_]u8{code}});
    try buffer.print(allocator, "name {s}\n", .{template.name});
    try buffer.print(allocator, "sprite {s}\n", .{try normalizedCustomStem(template.sprite, mission_content_path, allocator)});
    if (template.team != 1) {
        try buffer.print(allocator, "team {d}\n", .{template.team});
    }
    try buffer.print(allocator, "color_index {d}\n", .{template.color_index});
    try buffer.print(allocator, "displays_weapons {s}\n", .{if (template.displays_weapons) "true" else "false"});
    if (template.keep_original_colors) {
        try buffer.print(allocator, "keep_original_colors true\n", .{});
    }
    try buffer.print(allocator, "max_health {d}\n", .{template.max_health});
    try buffer.print(allocator, "defense {d}\n", .{template.defense});
    try buffer.print(allocator, "speed {d}\n", .{template.speed});
    try buffer.print(allocator, "aggro_range {d}\n", .{template.aggro_range});
    if (template.main_hand_weapon) |weapon| {
        try buffer.print(allocator, "main_hand_weapon_name {s}\n", .{weapon.name});
        try buffer.print(allocator, "main_hand_weapon_type {s}\n", .{@tagName(weapon.weapon_type)});
        try buffer.print(allocator, "main_hand_weapon_damage {d}\n", .{weapon.weapon_damage});
    }
    if (template.off_hand_weapon) |weapon| {
        try buffer.print(allocator, "off_hand_weapon_name {s}\n", .{weapon.name});
        try buffer.print(allocator, "off_hand_weapon_type {s}\n", .{@tagName(weapon.weapon_type)});
        try buffer.print(allocator, "off_hand_weapon_damage {d}\n", .{weapon.weapon_damage});
    }
    if (template.amulet) |amulet| {
        try buffer.print(allocator, "amulet_name {s}\n", .{amulet.name});
        try buffer.print(allocator, "amulet_spell_damage {d}\n", .{amulet.spell_damage});
    }
    if (template.coat) |coat| {
        try buffer.print(allocator, "coat_name {s}\n", .{coat.name});
        try buffer.print(allocator, "coat_defense_bonus {d}\n", .{coat.defense_bonus});
        try buffer.print(allocator, "coat_health_bonus {d}\n", .{coat.health_bonus});
    }
    if (template.gloves) |gloves| {
        try buffer.print(allocator, "gloves_name {s}\n", .{gloves.name});
        try buffer.print(allocator, "gloves_damage_bonus {d}\n", .{gloves.damage_bonus});
        try buffer.print(allocator, "gloves_health_bonus {d}\n", .{gloves.health_bonus});
    }
    if (template.pants) |pants| {
        try buffer.print(allocator, "pants_name {s}\n", .{pants.name});
        try buffer.print(allocator, "pants_pickup_radius_bonus {d}\n", .{pants.pickup_radius_bonus});
        try buffer.print(allocator, "pants_health_bonus {d}\n", .{pants.health_bonus});
    }
    if (template.boots) |boots| {
        try buffer.print(allocator, "boots_name {s}\n", .{boots.name});
        try buffer.print(allocator, "boots_speed_bonus {d}\n", .{boots.speed_bonus});
        try buffer.print(allocator, "boots_health_bonus {d}\n", .{boots.health_bonus});
    }
    for (template.equipped_utility_skills, 0..) |slot, index| {
        if (slot) |skill_id| {
            try buffer.print(allocator, "slot_{d} {s}\n", .{ index + 4, @tagName(skill_id) });
        }
    }
    for (template.layers) |layer| {
        try buffer.appendSlice(allocator, "layer\n");
        try buffer.print(allocator, "sprite {s}\n", .{try normalizedCustomStem(layer.sprite, mission_content_path, allocator)});
        try buffer.print(allocator, "color_index {d}\n", .{layer.color_index});
    }
}

/// One Items entry - the keys `parseItemEntry` reads for the item's kind.
fn writeItemDefinition(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    code: u8,
    item: types.Item,
) !void {
    try buffer.print(allocator, "character_code {s}\n", .{&[_]u8{code}});
    switch (item) {
        .weapon => |weapon| {
            try buffer.appendSlice(allocator, "item_type weapon\n");
            try buffer.print(allocator, "item_name {s}\n", .{weapon.name});
            try buffer.print(allocator, "weapon_type {s}\n", .{@tagName(weapon.weapon_type)});
            try buffer.print(allocator, "damage {d}\n", .{weapon.weapon_damage});
        },
        .amulet => |amulet| {
            try buffer.appendSlice(allocator, "item_type amulet\n");
            try buffer.print(allocator, "item_name {s}\n", .{amulet.name});
            try buffer.print(allocator, "spell_damage {d}\n", .{amulet.spell_damage});
        },
        .coat => |coat| {
            try buffer.appendSlice(allocator, "item_type coat\n");
            try buffer.print(allocator, "item_name {s}\n", .{coat.name});
            try buffer.print(allocator, "defense {d}\n", .{coat.defense_bonus});
            try buffer.print(allocator, "health {d}\n", .{coat.health_bonus});
        },
        .gloves => |gloves| {
            try buffer.appendSlice(allocator, "item_type gloves\n");
            try buffer.print(allocator, "item_name {s}\n", .{gloves.name});
            try buffer.print(allocator, "damage {d}\n", .{gloves.damage_bonus});
            try buffer.print(allocator, "health {d}\n", .{gloves.health_bonus});
        },
        .pants => |pants| {
            try buffer.appendSlice(allocator, "item_type pants\n");
            try buffer.print(allocator, "item_name {s}\n", .{pants.name});
            try buffer.print(allocator, "pickup_radius {d}\n", .{pants.pickup_radius_bonus});
            try buffer.print(allocator, "health {d}\n", .{pants.health_bonus});
        },
        .boots => |boots| {
            try buffer.appendSlice(allocator, "item_type boots\n");
            try buffer.print(allocator, "item_name {s}\n", .{boots.name});
            try buffer.print(allocator, "speed {d}\n", .{boots.speed_bonus});
            try buffer.print(allocator, "health {d}\n", .{boots.health_bonus});
        },
        .skill_tome => @panic("skill tomes are not level-authorable (the editor's item paths never create them)"),
    }
}

test "writePlayerSave round-trips through loadPlayerSave" {
    const allocator = std.testing.allocator;

    // Build a PlayerData with values in every field
    const original = PlayerData{
        .player_name = "Round Trip Player",
        .current_campaign = "main_campaign",
        .current_hub = "test_hub",
        .materials = .{
            .wood = 10,
            .metal = 20,
            .leather = 30,
            .cloth = 40,
            .knowledge = 50,
        },
        .turns = 200,
        .deaths = 5,
        .defeated_enemies = 99,
        .skills_used = 77,
        .main_hand_weapon = .{
            .name = "Test Sword",
            .weapon_type = .sword,
            .weapon_damage = 7,
        },
        .off_hand_weapon = .{
            .name = "Test Shield",
            .weapon_type = .shield,
            .weapon_damage = 3,
        },
        .amulet = .{
            .name = "Test Amulet",
            .spell_damage = 4,
        },
        .coat = .{
            .name = "Test Coat",
            .defense_bonus = 2,
            .health_bonus = 3,
        },
        .gloves = .{
            .name = "Test Gloves",
            .damage_bonus = 1,
            .health_bonus = 2,
        },
        .pants = .{
            .name = "Test Pants",
            .pickup_radius_bonus = 1,
            .health_bonus = 2,
        },
        .boots = .{
            .name = "Test Boots",
            .speed_bonus = 1,
            .health_bonus = 2,
        },
        .learned_skills = &.{ .slice, .replenish, .swap },
        // Gap in the middle: slots 5 and 7-8 empty, to verify the save writer
        // and loader preserve slot positions instead of compacting. Only
        // utility skills on the bar (slice is a weapon skill - the parser
        // drops it from slots; learned_skills may still carry it).
        .equipped_utility_skills = .{ .replenish, null, .swap, null, null },
        .clones = &.{.{
            .mission_uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            .name = "Test Clone",
            .turns_to_complete = 25,
            .materials_collected = .{
                .wood = 5,
                .metal = 10,
                .leather = 15,
                .cloth = 20,
                .knowledge = 25,
            },
        }},
        .inventory = .{
            .slots = blk: {
                var slots: [types.inventory_slot_count]?types.Item = @splat(null);
                slots[0] = .{ .weapon = .{
                    .name = "Inventory Dagger",
                    .weapon_type = .dagger,
                    .weapon_damage = 4,
                } };
                slots[1] = .{ .coat = .{
                    .name = "Inventory Coat",
                    .defense_bonus = 1,
                    .health_bonus = 1,
                } };
                slots[2] = .{ .skill_tome = .{
                    .skill = .replenish,
                } };
                break :blk slots;
            },
        },
    };

    // Write to text
    const save_text = try writePlayerSave(original, allocator);
    defer allocator.free(save_text);

    // Parse back
    const sections = try parseConfigFile(save_text, allocator, &parser.player_save_sections);
    defer freeParsedSections(sections, allocator);

    const loaded = try loadPlayerSave(sections, allocator, "", null);
    defer allocator.free(loaded.learned_skills);
    defer allocator.free(loaded.clones);

    // Info
    try std.testing.expectEqualStrings("Round Trip Player", loaded.player_name);
    try std.testing.expectEqualStrings("main_campaign", loaded.current_campaign);
    try std.testing.expectEqualStrings("test_hub", loaded.current_hub);
    try std.testing.expectEqual(200, loaded.turns);
    try std.testing.expectEqual(5, loaded.deaths);
    try std.testing.expectEqual(99, loaded.defeated_enemies);
    try std.testing.expectEqual(77, loaded.skills_used);
    try std.testing.expectEqual(10, loaded.materials.wood);
    try std.testing.expectEqual(20, loaded.materials.metal);
    try std.testing.expectEqual(30, loaded.materials.leather);
    try std.testing.expectEqual(40, loaded.materials.cloth);
    try std.testing.expectEqual(50, loaded.materials.knowledge);

    // Equipment
    try std.testing.expectEqualStrings("Test Sword", loaded.main_hand_weapon.?.name);
    try std.testing.expectEqual(.sword, loaded.main_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(7, loaded.main_hand_weapon.?.weapon_damage);
    try std.testing.expectEqualStrings("Test Shield", loaded.off_hand_weapon.?.name);
    try std.testing.expectEqual(.shield, loaded.off_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(4, loaded.amulet.?.spell_damage);
    try std.testing.expectEqual(2, loaded.coat.?.defense_bonus);
    try std.testing.expectEqual(3, loaded.coat.?.health_bonus);
    try std.testing.expectEqual(1, loaded.gloves.?.damage_bonus);
    try std.testing.expectEqual(2, loaded.gloves.?.health_bonus);
    try std.testing.expectEqual(1, loaded.pants.?.pickup_radius_bonus);
    try std.testing.expectEqual(1, loaded.boots.?.speed_bonus);

    // Skills
    try std.testing.expectEqual(3, loaded.learned_skills.len);
    try std.testing.expectEqual(.slice, loaded.learned_skills[0]);
    try std.testing.expectEqual(.replenish, loaded.learned_skills[1]);
    try std.testing.expectEqual(.swap, loaded.learned_skills[2]);
    try std.testing.expectEqual(.replenish, loaded.equipped_utility_skills[0]);
    try std.testing.expectEqual(null, loaded.equipped_utility_skills[1]);
    try std.testing.expectEqual(.swap, loaded.equipped_utility_skills[2]);
    try std.testing.expectEqual(null, loaded.equipped_utility_skills[3]);
    try std.testing.expectEqual(null, loaded.equipped_utility_skills[4]);

    // Inventory - items at slots 0, 1, 2
    try std.testing.expect(loaded.inventory.slots[0] != null);
    try std.testing.expect(loaded.inventory.slots[1] != null);
    try std.testing.expect(loaded.inventory.slots[2] != null);
    try std.testing.expect(loaded.inventory.slots[3] == null);

    try std.testing.expectEqualStrings("Inventory Dagger", loaded.inventory.slots[0].?.weapon.name);
    try std.testing.expectEqual(.dagger, loaded.inventory.slots[0].?.weapon.weapon_type);
    try std.testing.expectEqualStrings("Inventory Coat", loaded.inventory.slots[1].?.coat.name);
    try std.testing.expectEqual(.replenish, loaded.inventory.slots[2].?.skill_tome.skill);

    // Clones
    try std.testing.expectEqual(1, loaded.clones.len);
    try std.testing.expectEqualStrings("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", loaded.clones[0].mission_uuid);
    try std.testing.expectEqualStrings("Test Clone", loaded.clones[0].name);
    try std.testing.expectEqual(25, loaded.clones[0].turns_to_complete);
    try std.testing.expectEqual(5, loaded.clones[0].materials_collected.wood);
    try std.testing.expectEqual(25, loaded.clones[0].materials_collected.knowledge);
}

test "new_player.txt parses and round-trips correctly" {
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    // Parse the file from disk
    const parsed = try parseConfigFileFromPath(
        &file_source,
        "data/new_player.txt",
        allocator,
        &parser.player_save_sections,
    );
    defer allocator.free(parsed.raw_text);
    defer freeParsedSections(parsed.sections, allocator);

    const player_data = try loadPlayerSave(parsed.sections, allocator, "", null);
    defer allocator.free(player_data.learned_skills);
    defer allocator.free(player_data.clones);

    // Verify new player defaults
    try std.testing.expectEqualStrings("New Player", player_data.player_name);
    try std.testing.expectEqual(0, player_data.turns);
    try std.testing.expectEqual(0, player_data.deaths);
    try std.testing.expectEqual(1, player_data.learned_skills.len);
    try std.testing.expectEqual(.replenish, player_data.learned_skills[0]);
    try std.testing.expectEqualStrings("Starter Sword", player_data.main_hand_weapon.?.name);
    try std.testing.expectEqual(.sword, player_data.main_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(3, player_data.main_hand_weapon.?.weapon_damage);
    try std.testing.expectEqualStrings("Starter Shield", player_data.off_hand_weapon.?.name);
    try std.testing.expectEqual(.shield, player_data.off_hand_weapon.?.weapon_type);
    // All inventory slots should be empty
    for (player_data.inventory.slots) |slot| {
        try std.testing.expect(slot == null);
    }
    try std.testing.expectEqual(.replenish, player_data.equipped_utility_skills[0]);
    try std.testing.expectEqual(0, player_data.clones.len);

    // Round-trip: write it back and parse again
    const written = try writePlayerSave(player_data, allocator);
    defer allocator.free(written);

    const sections2 = try parseConfigFile(written, allocator, &parser.player_save_sections);
    defer freeParsedSections(sections2, allocator);

    const reloaded = try loadPlayerSave(sections2, allocator, "", null);
    defer allocator.free(reloaded.learned_skills);
    defer allocator.free(reloaded.clones);

    try std.testing.expectEqualStrings("New Player", reloaded.player_name);
    try std.testing.expectEqualStrings("Starter Sword", reloaded.main_hand_weapon.?.name);
    try std.testing.expectEqual(.replenish, reloaded.equipped_utility_skills[0]);
}

test "loadPlayerSave utility gates: weapon skills dropped from slots and out of tomes, with warnings" {
    const allocator = std.testing.allocator;
    var original: types.PlayerData = .{};
    // slot_4 (slice, a weapon skill) must be dropped; slot_5 (blink) kept.
    original.equipped_utility_skills = .{ .slice, .blink, null, null, null };
    // A slice tome is disallowed entirely; a blink tome is fine.
    original.inventory.slots[0] = .{ .skill_tome = .{ .skill = .slice } };
    original.inventory.slots[1] = .{ .skill_tome = .{ .skill = .blink } };

    const save_text = try writePlayerSave(original, allocator);
    defer allocator.free(save_text);

    const sections = try parseConfigFile(save_text, allocator, &parser.player_save_sections);
    defer freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer warnings.deinit(allocator);
    const loaded = try loadPlayerSave(sections, allocator, "save.txt", &warnings);
    defer allocator.free(loaded.learned_skills);
    defer allocator.free(loaded.clones);

    try std.testing.expectEqual(null, loaded.equipped_utility_skills[0]);
    try std.testing.expectEqual(types.SkillId.blink, loaded.equipped_utility_skills[1]);
    try std.testing.expectEqual(null, loaded.inventory.slots[0]);
    try std.testing.expectEqual(types.SkillId.blink, loaded.inventory.slots[1].?.skill_tome.skill);
    try std.testing.expectEqual(@as(usize, 2), warnings.items.len);
    for (warnings.items) |w| allocator.free(w);
}

// ============================================================
// Editor mission writer tests
// ============================================================

/// The round-trip fixture: a two-level mission exercising every written
/// feature - translated layouts (everything offset from the origin), a rich
/// enemy (weapon + gear + utility skill + layer), per-level tool filtering
/// (Brute only in level 2, an unused item type in NO file), a decoration,
/// and a loaded-out player. File-scope comptime: the Editor's palette +
/// level slices borrow these arrays, so they must outlive the constructor
/// (an fn-local fixture would dangle).
const editor_write_fixture_levels = [_]types.EditorLevel{
    .{
        .level_tiles = &[_]types.Vector2{
            .{ .x = 4, .y = 2 }, .{ .x = 5, .y = 2 }, .{ .x = 4, .y = 3 },
            .{ .x = 5, .y = 3 }, .{ .x = 6, .y = 4 },
        },
        .player_start = .{ .x = 4, .y = 2 },
        .level_end = .{ .x = 5, .y = 2 },
        .entity_placements = &[_]types.EntityPlacement{
            .{ .type_id = 0, .position = .{ .x = 4, .y = 3 } },
        },
        .decoration_placements = &[_]types.DecorationPlacement{
            .{ .type_id = 0, .position = .{ .x = 6, .y = 2 } },
        },
        .item_placements = &[_]types.ItemPlacement{
            .{ .type_id = 0, .position = .{ .x = 6, .y = 4 } },
        },
    },
    .{
        .name = "Second",
        .color_wheel_index = 2,
        .enemy_gradient_index = 5,
        .level_tiles = &[_]types.Vector2{
            .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
        },
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 2, .y = 0 },
        .entity_placements = &[_]types.EntityPlacement{
            .{ .type_id = 1, .position = .{ .x = 1, .y = 0 } },
        },
    },
};

const editor_write_fixture: types.Editor = .{
    .mission = .{ .name = "My Mission", .level_count = 2 },
    .levels = &editor_write_fixture_levels,
    .entity_types = &[_]types.EntityTypeDef{
        .{ .id = "Archer", .template = .{
            .name = "Archer",
            .sprite = "skeleton_1",
            .team = 1,
            .color_index = 2,
            .displays_weapons = false,
            .keep_original_colors = true,
            .max_health = 30,
            .defense = 1,
            .speed = 2,
            .aggro_range = 4,
            .main_hand_weapon = .{ .name = "Arc Sword", .weapon_type = .sword, .weapon_damage = 3 },
            .coat = .{ .name = "Arc Coat", .defense_bonus = 1, .health_bonus = 2 },
            .equipped_utility_skills = blk: {
                var slots: [types.utility_skill_count]?types.SkillId = @splat(null);
                slots[0] = .blink;
                break :blk slots;
            },
            .layers = &[_]types.EntityLayer{
                .{ .sprite = "wolf", .color_index = 1 },
            },
        } },
        .{ .id = "Brute", .template = .{
            .name = "Brute",
            .sprite = "wolf",
            .team = 2,
        } },
    },
    .decoration_types = &[_]types.DecorationTypeDef{
        .{
            .id = "stone_1",
            .sprite = "stone_1",
            .color_index = 5,
            .keep_original_colors = true,
            .footprint = &[_]types.Vector2{.{ .x = 0, .y = 0 }},
        },
    },
    .item_types = &[_]types.ItemTypeDef{
        .{ .id = "New Sword", .item = .{ .weapon = .{
            .name = "New Sword",
            .weapon_type = .sword,
            .weapon_damage = 2,
        } } },
        // Never placed anywhere - must appear in NO written file.
        .{ .id = "Nice Coat", .item = .{ .coat = .{
            .name = "Nice Coat",
            .defense_bonus = 1,
            .health_bonus = 2,
        } } },
    },
    .player_def = .{ .id = "Player", .template = .{
        .name = "New Player",
        .sprite = "player",
        .team = 0,
        .main_hand_weapon = .{ .name = "Max Sword", .weapon_type = .sword, .weapon_damage = 3 },
        .amulet = .{ .name = "Charm", .spell_damage = 2 },
        .inventory = .{
            .slots = blk: {
                var slots: [types.inventory_slot_count]?types.Item = @splat(null);
                slots[0] = .{ .weapon = .{ .name = "Bag Sword", .weapon_type = .sword, .weapon_damage = 1 } };
                break :blk slots;
            },
        },
        .equipped_utility_skills = blk: {
            var slots: [types.utility_skill_count]?types.SkillId = @splat(null);
            slots[0] = .blink;
            break :blk slots;
        },
    } },
};

test "writeSettings round-trips render_resolution through loadSettings" {
    const allocator = std.testing.allocator;

    // Written by label ("2160p"), parsed back by the same label mapping.
    const settings: Settings = .{ .render_resolution = .p2160, .input_bindings = &.{} };
    const bytes = try writeSettings(settings, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "render_resolution 2160p") != null);

    const sections = try parser.parseConfigFile(bytes, allocator, &parser.settings_sections);
    defer parser.freeParsedSections(sections, allocator);
    const loaded = try loaders.loadSettings(sections, allocator, null, null);
    defer loaders.freeSettings(loaded, allocator);
    try std.testing.expectEqual(types.RenderResolution.p2160, loaded.render_resolution);

    // An unrecognized value keeps the default (preferences, not gameplay).
    const raw_text = try std.fmt.allocPrint(
        allocator,
        "Metadata\nfile_format_version {d}\n\nDisplay\nrender_resolution 4320p\n",
        .{parser.settings_file_format_version},
    );
    defer allocator.free(raw_text);
    const unknown_sections = try parser.parseConfigFile(raw_text, allocator, &parser.settings_sections);
    defer parser.freeParsedSections(unknown_sections, allocator);
    const unknown_loaded = try loaders.loadSettings(unknown_sections, allocator, null, null);
    defer loaders.freeSettings(unknown_loaded, allocator);
    try std.testing.expectEqual(types.default_render_resolution, unknown_loaded.render_resolution);
}

test "writeEditorMission round-trips through the load path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const editor = editor_write_fixture;
    const written = try writeEditorMission(editor, "436ab363-3588-42ce-950a-0bc813069c3d", "436ab363-3588-42ce-950a-0bc813069c3d_Beginnings", arena);

    // mission.txt: the identity + shape; no hub fields (editor missions have
    // no campaign context, and the loader treats them as optional).
    {
        const sections = try parseConfigFile(written.mission_txt, arena, &parser.mission_sections);
        const mission = try loaders.loadMission(sections, arena);
        try std.testing.expectEqualStrings("436ab363-3588-42ce-950a-0bc813069c3d", mission.uuid);
        try std.testing.expectEqualStrings("My Mission", mission.name);
        // level_count is no longer mission.txt data (derived from the
        // dir's level files); end_hub is runtime-only (the start_mission
        // override) - both default here.
        try std.testing.expectEqual(@as(u32, 0), mission.level_count);
        try std.testing.expect(mission.end_hub == null);
    }

    // player.txt: the loadout round-trips (the NAME is not part of the
    // format - a reloaded loadout reads back as "Player").
    {
        const sections = try parseConfigFile(written.player_txt, arena, &parser.player_loadout_sections);
        const loaded = try loaders.loadPlayerLoadout(sections, arena, "test/player.txt", null);
        try std.testing.expectEqualStrings("Player", loaded.name);
        try std.testing.expect(loaders.entityDefinitionsEqual(loaded, .{
            .name = "Player",
            .sprite = "player",
            .team = 0,
            .main_hand_weapon = editor.player_def.template.main_hand_weapon,
            .amulet = editor.player_def.template.amulet,
            .inventory = editor.player_def.template.inventory,
            .equipped_utility_skills = editor.player_def.template.equipped_utility_skills,
        }));
    }

    // The levels: the real reload path (buildEditorMission over the written
    // files), then a SEMANTIC compare - the reload dedups placements into a
    // fresh palette in layout-encounter order, so palette order/type ids can
    // differ from the original; positions compare TRANSLATED (the written
    // layout is normalized to the bbox origin).
    var level_sections: [2][]const parser.Section = undefined;
    for (written.level_txts, 0..) |level_txt, index| {
        level_sections[index] = try parseConfigFile(level_txt, arena, &parser.level_sections);
    }
    const reloaded = try loaders.buildEditorMission(
        .{ .name = "My Mission", .level_count = 2 },
        editor.player_def.template,
        &level_sections,
        null,
        arena,
        "test/mission",
        null,
    );

    try std.testing.expectEqual(@as(usize, 2), reloaded.levels.len);

    // Level 1: translated by (4,2) - '!' (0,0), '=' (1,0), Archer '1' at
    // (0,1) over its tile, the stone '2' at (2,0) (its footprint tile stays
    // tile-free), the sword '3' at (2,2).
    {
        const level = reloaded.levels[0];
        try std.testing.expectEqual(@as(usize, 0), level.name.len);
        try std.testing.expectEqual(@as(u32, 0), level.color_wheel_index);
        try std.testing.expect(level.enemy_gradient_index == null);
        try std.testing.expect(level.player_gradient_index == null);
        try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.player_start);
        try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, level.level_end.?);
        try std.testing.expectEqual(@as(usize, 5), level.level_tiles.len); // 2 markers + enemy + 2 bare
        try std.testing.expectEqual(@as(usize, 1), level.entity_placements.len);
        try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 1 }, level.entity_placements[0].position);
        try std.testing.expect(loaders.entityDefinitionsEqual(
            reloaded.entity_types[level.entity_placements[0].type_id].template,
            editor.entity_types[0].template,
        ));
        try std.testing.expectEqual(@as(usize, 1), level.decoration_placements.len);
        try std.testing.expectEqual(types.Vector2{ .x = 2, .y = 0 }, level.decoration_placements[0].position);
        const reloaded_decoration = reloaded.decoration_types[level.decoration_placements[0].type_id];
        try std.testing.expectEqualStrings("stone_1", reloaded_decoration.sprite);
        try std.testing.expectEqual(@as(u32, 5), reloaded_decoration.color_index);
        try std.testing.expect(reloaded_decoration.keep_original_colors);
        try std.testing.expect(loaders.decorationFootprintEqual(reloaded_decoration.footprint, editor.decoration_types[0].footprint));
        try std.testing.expectEqual(@as(usize, 1), level.item_placements.len);
        try std.testing.expectEqual(types.Vector2{ .x = 2, .y = 2 }, level.item_placements[0].position);
        try std.testing.expect(deepCopyEqual(types.Item, reloaded.item_types[level.item_placements[0].type_id].item, editor.item_types[0].item));
    }

    // Level 2: already at the origin; the gradient override survives.
    {
        const level = reloaded.levels[1];
        try std.testing.expectEqualStrings("Second", level.name);
        try std.testing.expectEqual(@as(u32, 2), level.color_wheel_index);
        try std.testing.expectEqual(@as(u32, 5), level.enemy_gradient_index.?);
        try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.player_start);
        try std.testing.expectEqual(types.Vector2{ .x = 2, .y = 0 }, level.level_end.?);
        try std.testing.expectEqual(@as(usize, 1), level.entity_placements.len);
        try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, level.entity_placements[0].position);
        try std.testing.expect(loaders.entityDefinitionsEqual(
            reloaded.entity_types[level.entity_placements[0].type_id].template,
            editor.entity_types[1].template,
        ));
    }

    // Per-level tool filtering: level 1's file defines only the Archer,
    // level 2's only the Brute; the never-placed coat item appears in NO
    // file.
    {
        const level_0_entities = parser.findSection(level_sections[0], "Entities").?;
        try std.testing.expectEqual(@as(usize, 1), level_0_entities.entry_groups.len);
        const level_1_entities = parser.findSection(level_sections[1], "Entities").?;
        try std.testing.expectEqual(@as(usize, 1), level_1_entities.entry_groups.len);
        try std.testing.expect(std.mem.indexOf(u8, written.level_txts[0], "Brute") == null);
        try std.testing.expect(std.mem.indexOf(u8, written.level_txts[1], "Archer") == null);
        for (written.level_txts) |level_txt| {
            try std.testing.expect(std.mem.indexOf(u8, level_txt, "Nice Coat") == null);
        }
    }

    // Team emission: the team-1 Archer omits the key (absent-on-reload
    // equals absent-on-write - 1 is the load default); the team-2 Brute
    // carries `team 2` and reloads with it.
    {
        try std.testing.expect(std.mem.indexOf(u8, written.level_txts[0], "team ") == null);
        try std.testing.expect(std.mem.indexOf(u8, written.level_txts[1], "team 2") != null);
        try std.testing.expectEqual(@as(u32, 2), reloaded.entity_types[reloaded.levels[1].entity_placements[0].type_id].template.team);
    }
}

test "writeEditorMission normalizes custom sprite stems to the save target's namespace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Stale-namespace stems (authored under an old dir - the mission was
    // renamed since) on every channel that writes a sprite (entity base +
    // layer, decoration base + layer), plus shipped stems that must pass
    // through untouched.
    const entity_layers = [_]types.EntityLayer{
        .{ .sprite = "custom/old_dir/hero_hat", .color_index = 1 },
    };
    const decoration_layers = [_]types.DecorationLayer{
        .{ .sprite = "custom/old_dir/tree_top", .color_index = 2, .pixel_dims = .{ .x = 256, .y = 256 } },
        .{ .sprite = "custom/old_dir/tree_base", .color_index = 5, .behind = true, .pixel_dims = .{ .x = 256, .y = 256 } },
    };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &[_]types.Vector2{.{ .x = 0, .y = 0 }},
        .player_start = .{ .x = 0, .y = 0 },
        .entity_placements = &[_]types.EntityPlacement{.{
            .type_id = 0,
            .position = .{ .x = 0, .y = 0 },
        }},
        .decoration_placements = &[_]types.DecorationPlacement{.{
            .type_id = 0,
            .position = .{ .x = 0, .y = 0 },
        }},
    }};
    const editor: types.Editor = .{
        .mission = .{ .name = "New Name", .level_count = 1 },
        .levels = &levels,
        .entity_types = &[_]types.EntityTypeDef{
            .{ .id = "Hero", .template = .{
                .name = "Hero",
                .sprite = "custom/old_dir/hero",
                .team = 1,
                .layers = &entity_layers,
            } },
            // Never placed - written to NO file (per-level tool filtering).
            .{ .id = "Ghost", .template = .{
                .name = "Ghost",
                .sprite = "custom/old_dir/ghost",
                .team = 1,
            } },
        },
        .decoration_types = &[_]types.DecorationTypeDef{
            .{ .id = "tree", .sprite = "custom/old_dir/tree", .layers = &decoration_layers },
        },
    };

    const written = try writeEditorMission(editor, "u", "u_New Name", arena);

    // Every PLACED custom stem is rewritten to the save target's
    // namespace; the stale namespace appears nowhere (the never-placed
    // Ghost type included - unused types are not written). The trailing
    // newline keeps hero from matching hero_hat.
    const level_txt = written.level_txts[0];
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "custom/u_New Name/hero\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "custom/u_New Name/hero_hat") != null);
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "custom/u_New Name/tree\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "custom/u_New Name/tree_top") != null);
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "old_dir") == null);
    // The behind layer's flag rides the sub-group (sprite, color_index,
    // then `behind true` - emitted only when set, so exactly once for
    // the one behind layer).
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "sprite custom/u_New Name/tree_base\ncolor_index 5\nbehind true\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, level_txt, "behind true\n"));
    // Shipped stems pass through (the load defaults + the decoration's
    // defaulted keys are part of the same contract - normalization only
    // ever touches custom stems).
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "name Hero") != null);
}

/// deep_copy.deepEqual under a shorter alias (the tests compare Item values).
const deepCopyEqual = @import("deep_copy.zig").deepEqual;

test "writeEditorLevel layout is translated + row-trimmed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const editor = editor_write_fixture;
    const written = try writeEditorMission(editor, "u", "u_My Mission", arena);

    // Level 1 (offset by (4,2)): the grid is the bbox, each row trimmed to
    // its own last used column - interior alignment spaces stay, trailing
    // spaces never. The opening line carries the row count (the counted
    // grammar) - asserted literally so a regression to the bare legacy
    // form cannot hide behind the (still-parsing) round trip.
    try std.testing.expect(std.mem.indexOf(u8, written.level_txts[0], "\nLayout 3\n") != null);
    const level_0_layout = parser.findSection(
        try parseConfigFile(written.level_txts[0], arena, &parser.level_sections),
        "Layout",
    ).?;
    try std.testing.expectEqual(@as(usize, 3), level_0_layout.raw_lines.len);
    try std.testing.expectEqualStrings("!=2", level_0_layout.raw_lines[0]);
    try std.testing.expectEqualStrings("1.", level_0_layout.raw_lines[1]);
    try std.testing.expectEqualStrings("  3", level_0_layout.raw_lines[2]);

    // Level 2 (already at the origin): one compact row.
    const level_1_layout = parser.findSection(
        try parseConfigFile(written.level_txts[1], arena, &parser.level_sections),
        "Layout",
    ).?;
    try std.testing.expectEqual(@as(usize, 1), level_1_layout.raw_lines.len);
    try std.testing.expectEqualStrings("!1=", level_1_layout.raw_lines[0]);
}

test "writeEditorMission fails when a level needs more codes than the ASCII set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 92 distinct used entity types in ONE level - one more than the 91
    // available layout chars.
    const type_count = 92;
    var entity_types: []types.EntityTypeDef = try arena.alloc(types.EntityTypeDef, type_count);
    var placements: []types.EntityPlacement = try arena.alloc(types.EntityPlacement, type_count);
    var tiles: []types.Vector2 = try arena.alloc(types.Vector2, type_count);
    for (0..type_count) |index| {
        entity_types[index] = .{ .id = "Type", .template = .{
            .name = try std.fmt.allocPrint(arena, "Enemy {d}", .{index}),
            .sprite = "skeleton_1",
            .team = 1,
        } };
        placements[index] = .{ .type_id = @intCast(index), .position = .{ .x = @intCast(index), .y = 0 } };
        tiles[index] = .{ .x = @intCast(index), .y = 0 };
    }
    const levels = [_]types.EditorLevel{.{
        .level_tiles = tiles,
        .player_start = .{ .x = 0, .y = 1 },
        .level_end = .{ .x = 1, .y = 1 },
        .entity_placements = placements,
    }};
    const editor = types.Editor{
        .mission = .{ .name = "M", .level_count = 1 },
        .levels = &levels,
        .entity_types = entity_types,
    };

    try std.testing.expectError(
        error.TooManyLayoutCodes,
        writeEditorMission(editor, "u", "u_My Mission", arena),
    );
}

// ============================================================
// Campaign writers (the campaign editor's save projection - DESIGN →
// Campaigns & the Campaign Editor → The campaign editor surface). Pure
// text builders; the save orchestration (uuid minting, the memo, dir
// tidy, deletions) lives in campaign_editor/io.zig.
// ============================================================

/// The resolved identity table the campaign writer needs: the campaign's
/// uuid + every hub's/mission's resolved uuid, INDEX-KEYED to the
/// editor's own hub/mission lists (the orchestrator builds them in the
// same order - the one-uuid-per-entry invariant).
pub const CampaignSaveIds = struct {
    campaign_uuid: []const u8,
    hub_uuids: []const []const u8,
    mission_uuids: []const []const u8,
};

/// One hub's layout-code assignment: exits take DIGITS ('0'-'9', the
/// shipped convention), decorations + NPCs take LETTERS (uppercase first,
/// matching the shipped files; then lowercase - 52 slots). Deterministic
/// in list order.
/// One NPC code assignment (by distinct used type, first-use order).
const HubNpcCodeAssignment = struct {
    npc_type: types.NpcType,
    code: u8,
};

const HubLayoutCodes = struct {
    /// Exit codes by the hub's exit-placement order.
    exit: []const u8,
    /// Decoration codes by palette type id (used types only).
    decoration: []const LayoutCodeAssignment,
    /// NPC codes by the distinct npc types used, in first-use order.
    npc: []const HubNpcCodeAssignment,
};

fn assignHubLayoutCodes(
    editor: types.CampaignEditor,
    hub: types.CampaignHubEdit,
    allocator: std.mem.Allocator,
) !HubLayoutCodes {
    // Exits: digits by placement order. Only placements whose mission
    // STARTS here (the one-edge invariant - a placement on a non-start
    // hub is a crafted state; the writer skips it rather than
    // laundering it into the file).
    var exit_codes: std.ArrayList(u8) = .empty;
    for (hub.grid.exit_placements) |placement| {
        for (editor.missions) |mission| {
            if (mission.handle != placement.mission) continue;
            if (mission.start == null or mission.start.? != hub.handle) continue;
            if (exit_codes.items.len >= 10) return error.TooManyExitsPerHub;
            try exit_codes.append(allocator, '0' + @as(u8, @intCast(exit_codes.items.len)));
        }
    }

    // Decorations: letters per used palette type.
    var decoration_codes: std.ArrayList(LayoutCodeAssignment) = .empty;
    var next_letter: usize = 0;
    for (editor.decoration_types, 0..) |_, type_id| {
        var used = false;
        for (hub.grid.decoration_placements) |placement| {
            if (placement.type_id == type_id) used = true;
        }
        if (!used) continue;
        const code = try hubLetterCode(next_letter);
        next_letter += 1;
        try decoration_codes.append(allocator, .{
            .type_id = @intCast(type_id),
            .code = code,
        });
    }

    // NPCs: letters per distinct used type, in first-use order.
    var npc_codes: std.ArrayList(HubNpcCodeAssignment) = .empty;
    for (hub.grid.npc_placements) |npc| {
        var seen = false;
        for (npc_codes.items) |existing| {
            if (existing.npc_type == npc.npc_type) seen = true;
        }
        if (seen) continue;
        const code = try hubLetterCode(next_letter);
        next_letter += 1;
        try npc_codes.append(allocator, .{ .npc_type = npc.npc_type, .code = code });
    }

    return .{
        .exit = try exit_codes.toOwnedSlice(allocator),
        .decoration = try decoration_codes.toOwnedSlice(allocator),
        .npc = try npc_codes.toOwnedSlice(allocator),
    };
}

/// The letter sequence for hub decoration/NPC codes: uppercase A-Z, then
/// lowercase (52 slots; a hub with more distinct kinds is not a real
/// state).
fn hubLetterCode(index: usize) !u8 {
    if (index < 26) return 'A' + @as(u8, @intCast(index));
    if (index < 52) return 'a' + @as(u8, @intCast(index - 26));
    return error.TooManyHubCodes;
}

fn hubCodeForType(assignments: []const LayoutCodeAssignment, type_id: u32) ?u8 {
    return codeForType(assignments, type_id);
}

/// Write one hub.txt (the campaign editor's save projection for a hub):
/// v4 Metadata + the counted Layout (tiles, '!', decoration anchors, NPC
/// cells, exit cells) + Decorations (the used campaign-palette
/// definitions, custom stems normalized into the HUB's content path) +
/// NPCs (per type) + Exits (the mission-centric graph's projection: each
/// placed marker whose mission STARTS here - the mission's uuid, the
/// destination hub's uuid or empty (dangling), the authored direction or
/// absent (the auto-spread default)). `ids` resolves the uuids.
pub fn writeCampaignHub(
    editor: types.CampaignEditor,
    hub: types.CampaignHubEdit,
    ids: CampaignSaveIds,
    hub_content_path: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const codes = try assignHubLayoutCodes(editor, hub, allocator);

    // The bbox over everything placed - the player start is always
    // present (the '!' is undeletable), so the bbox is never empty.
    var min_x = hub.grid.player_start.x;
    var min_y = hub.grid.player_start.y;
    var max_x = hub.grid.player_start.x;
    var max_y = hub.grid.player_start.y;
    const expand = struct {
        fn bounds(
            bounds_min_x: *i32,
            bounds_min_y: *i32,
            bounds_max_x: *i32,
            bounds_max_y: *i32,
            position: types.Vector2,
        ) void {
            bounds_min_x.* = @min(bounds_min_x.*, position.x);
            bounds_min_y.* = @min(bounds_min_y.*, position.y);
            bounds_max_x.* = @max(bounds_max_x.*, position.x);
            bounds_max_y.* = @max(bounds_max_y.*, position.y);
        }
    };
    for (hub.grid.level_tiles) |tile| expand.bounds(&min_x, &min_y, &max_x, &max_y, tile);
    for (hub.grid.npc_placements) |npc| expand.bounds(&min_x, &min_y, &max_x, &max_y, npc.position);
    for (hub.grid.exit_placements) |placement| expand.bounds(&min_x, &min_y, &max_x, &max_y, placement.position);
    for (hub.grid.decoration_placements) |placement| {
        const footprint_tiles = loaders.decorationFootprintWorldTiles(
            editor.decoration_types[placement.type_id].footprint,
            placement.position,
            allocator,
        );
        defer allocator.free(footprint_tiles);
        for (footprint_tiles) |tile| expand.bounds(&min_x, &min_y, &max_x, &max_y, tile);
    }
    const origin = types.Vector2{ .x = min_x, .y = min_y };
    const grid_width: i32 = max_x - min_x + 1;
    const grid_height: i32 = max_y - min_y + 1;

    const grid = try allocator.alloc(u8, @intCast(grid_width * grid_height));
    defer allocator.free(grid);
    @memset(grid, ' ');
    for (hub.grid.level_tiles) |tile| setGridCell(grid, grid_width, origin, tile, '.');
    setGridCell(grid, grid_width, origin, hub.grid.player_start, '!');
    for (hub.grid.decoration_placements) |placement| {
        setGridCell(
            grid,
            grid_width,
            origin,
            placement.position,
            hubCodeForType(codes.decoration, placement.type_id).?,
        );
    }
    for (hub.grid.npc_placements) |npc| {
        var npc_code: ?u8 = null;
        for (codes.npc) |assignment| {
            if (assignment.npc_type == npc.npc_type) npc_code = assignment.code;
        }
        setGridCell(grid, grid_width, origin, npc.position, npc_code.?);
    }
    // The exit cells + their mission-resolution (only start-here
    // placements - the code assignment's rule).
    var exit_index: usize = 0;
    for (hub.grid.exit_placements) |placement| {
        for (editor.missions) |mission| {
            if (mission.handle != placement.mission) continue;
            if (mission.start == null or mission.start.? != hub.handle) continue;
            setGridCell(grid, grid_width, origin, placement.position, codes.exit[exit_index]);
            exit_index += 1;
        }
    }

    var buffer: std.ArrayList(u8) = .empty;

    // Metadata
    try buffer.appendSlice(allocator, "Metadata\n");
    try buffer.print(allocator, "file_format_version {d}\n", .{parser.hub_file_format_version});
    if (hub.name.len > 0) {
        try buffer.print(allocator, "name {s}\n", .{hub.name});
    }
    const hub_index = hubIndexForHandle(editor, hub.handle) orelse return error.HubNotInList;
    try buffer.print(allocator, "hub_uuid {s}\n", .{ids.hub_uuids[hub_index]});
    if (hub.grid.color_wheel_index != 0) {
        try buffer.print(allocator, "color_wheel_index {d}\n", .{hub.grid.color_wheel_index});
    }
    if (hub.grid.enemy_gradient_index) |gradient_index| {
        try buffer.print(allocator, "enemy_gradient_index {d}\n", .{gradient_index});
    }
    if (hub.grid.player_gradient_index) |gradient_index| {
        try buffer.print(allocator, "player_gradient_index {d}\n", .{gradient_index});
    }

    // Layout - the counted grammar, rows trimmed (the level writer's
    // convention).
    try buffer.print(allocator, "\nLayout {d}\n", .{grid_height});
    var row: i32 = 0;
    while (row < grid_height) : (row += 1) {
        const row_start: usize = @intCast(row * grid_width);
        const row_cells = grid[row_start .. row_start + @as(usize, @intCast(grid_width))];
        var row_length = row_cells.len;
        while (row_length > 0 and row_cells[row_length - 1] == ' ') row_length -= 1;
        try buffer.appendSlice(allocator, row_cells[0..row_length]);
        try buffer.appendSlice(allocator, "\n");
    }

    // Decorations - used campaign-palette types (sprite + footprint +
    // layers), custom stems normalized into the hub's content path.
    if (codes.decoration.len > 0) {
        try buffer.appendSlice(allocator, "\nDecorations\n");
        for (codes.decoration, 0..) |assignment, index| {
            if (index > 0) try buffer.appendSlice(allocator, "\n");
            const definition = editor.decoration_types[assignment.type_id];
            try buffer.print(allocator, "character_code {s}\n", .{&[_]u8{assignment.code}});
            try buffer.print(allocator, "sprite {s}\n", .{try normalizedCustomStem(definition.sprite, hub_content_path, allocator)});
            try buffer.print(allocator, "color_index {d}\n", .{definition.color_index});
            if (definition.keep_original_colors) {
                try buffer.print(allocator, "keep_original_colors true\n", .{});
            }
            for (definition.footprint) |footprint_tile| {
                try buffer.print(allocator, "footprint {d} {d}\n", .{ footprint_tile.x, footprint_tile.y });
            }
            for (definition.layers) |layer| {
                try buffer.appendSlice(allocator, "layer\n");
                try buffer.print(allocator, "sprite {s}\n", .{try normalizedCustomStem(layer.sprite, hub_content_path, allocator)});
                try buffer.print(allocator, "color_index {d}\n", .{layer.color_index});
                if (layer.behind) {
                    try buffer.appendSlice(allocator, "behind true\n");
                }
            }
        }
    }

    // NPCs - per type (the sprite derives from it).
    if (codes.npc.len > 0) {
        try buffer.appendSlice(allocator, "\nNPCs\n");
        for (codes.npc, 0..) |assignment, index| {
            if (index > 0) try buffer.appendSlice(allocator, "\n");
            try buffer.print(allocator, "character_code {s}\n", .{&[_]u8{assignment.code}});
            try buffer.print(allocator, "npc_type {s}\n", .{@tagName(assignment.npc_type)});
        }
    }

    // Exits - the MARKER projection (pure tile materialization: the
    // marker's grid cell + the mission it starts; edge data lives in
    // campaign.txt's Missions section).
    if (codes.exit.len > 0) {
        try buffer.appendSlice(allocator, "\nExits\n");
        var written_exits: usize = 0;
        for (hub.grid.exit_placements) |placement| {
            for (editor.missions, 0..) |mission, mission_index| {
                if (mission.handle != placement.mission) continue;
                if (mission.start == null or mission.start.? != hub.handle) continue;
                if (written_exits > 0) try buffer.appendSlice(allocator, "\n");
                try buffer.print(allocator, "character_code {s}\n", .{&[_]u8{codes.exit[written_exits]}});
                try buffer.print(allocator, "mission_uuid {s}\n", .{ids.mission_uuids[mission_index]});
                written_exits += 1;
            }
        }
    }

    return try buffer.toOwnedSlice(allocator);
}

fn hubIndexForHandle(editor: types.CampaignEditor, handle: u32) ?usize {
    for (editor.hubs, 0..) |hub, index| {
        if (hub.handle == handle) return index;
    }
    return null;
}

/// Write campaign.txt (v5): Metadata (name, campaign uuid, the start
/// hub's uuid, the background stem) + the Hubs section (uuid + position
/// per placed hub) + the Missions section - THE first-class edge table,
/// one group per mission with its full edge data (start/destination hub
/// uuids when wired, the authored direction when set, the frozen ghost
/// positions when set). Any authored state is representable (subsumes
/// v4's Orphans: an unwired mission is a group with no start_hub; a
/// markerless mission saves identically - unstartable is a validation
/// finding, never a save blocker; see DESIGN → File formats).
pub fn writeCampaignFile(
    editor: types.CampaignEditor,
    ids: CampaignSaveIds,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;

    try buffer.appendSlice(allocator, "Metadata\n");
    try buffer.print(allocator, "file_format_version {d}\n", .{parser.campaign_file_format_version});
    try buffer.print(allocator, "name {s}\n", .{editor.campaign_name});
    try buffer.print(allocator, "campaign_uuid {s}\n", .{ids.campaign_uuid});
    if (editor.start_hub) |start_handle| {
        const start_index = hubIndexForHandle(editor, start_handle) orelse return error.StartHubNotInList;
        try buffer.print(allocator, "start_hub {s}\n", .{ids.hub_uuids[start_index]});
    }
    if (editor.background_stem.len > 0) {
        try buffer.print(allocator, "background {s}\n", .{editor.background_stem});
    }

    try buffer.appendSlice(allocator, "\nHubs\n");
    for (editor.hubs, 0..) |hub, index| {
        if (index > 0) try buffer.appendSlice(allocator, "\n");
        try buffer.print(allocator, "hub_uuid {s}\n", .{ids.hub_uuids[index]});
        try buffer.print(allocator, "position {d} {d}\n", .{ hub.position.x, hub.position.y });
    }

    // Missions - the first-class edge table: one group per mission, the
    // full edge data. Ghost positions are written whenever set (faithful
    // state; the editor clears them on re-attach).
    if (editor.missions.len > 0) {
        try buffer.appendSlice(allocator, "\nMissions\n");
    }
    for (editor.missions, 0..) |mission, index| {
        if (index > 0) try buffer.appendSlice(allocator, "\n");
        try buffer.print(allocator, "mission_uuid {s}\n", .{ids.mission_uuids[index]});
        if (mission.start) |start_handle| {
            const start_index = hubIndexForHandle(editor, start_handle) orelse continue;
            try buffer.print(allocator, "start_hub {s}\n", .{ids.hub_uuids[start_index]});
        }
        if (mission.destination) |destination_handle| {
            const destination_index = hubIndexForHandle(editor, destination_handle) orelse continue;
            try buffer.print(allocator, "destination_hub {s}\n", .{ids.hub_uuids[destination_index]});
        }
        if (mission.direction) |direction| {
            try buffer.print(allocator, "direction {d}\n", .{direction});
        }
        if (mission.orphan_start_position) |position| {
            try buffer.print(allocator, "start_position {d} {d}\n", .{ position.x, position.y });
        }
        if (mission.orphan_destination_position) |position| {
            try buffer.print(allocator, "destination_position {d} {d}\n", .{ position.x, position.y });
        }
    }

    return try buffer.toOwnedSlice(allocator);
}

/// Write one mission's mission.txt (the identity + name - Metadata-only;
/// the level files + player.txt are the mission editor's business, and a
/// fresh campaign mission deliberately ships WITHOUT player.txt (the
/// loader's max-default fallback - the loadout is authored via the
/// mission hand-off, slice 5).
pub fn writeCampaignMissionFile(
    mission: types.CampaignMissionEdit,
    mission_uuid: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    try buffer.appendSlice(allocator, "Metadata\n");
    try buffer.print(allocator, "file_format_version {d}\n", .{parser.mission_file_format_version});
    try buffer.print(allocator, "mission_uuid {s}\n", .{mission_uuid});
    try buffer.print(allocator, "name {s}\n", .{mission.name});
    return try buffer.toOwnedSlice(allocator);
}

// ============================================================
// Campaign writer tests - the round-trip pattern: build the authored
// graph, write the projection, parse it back through the LOADERS, and
// compare (the buildEditorMission precedent). The full save-to-disk
// round trip (the io orchestration) lives in the harness tests.
// ============================================================

fn campaignWriterFixture() types.CampaignEditor {
    return .{
        .campaign_name = "Fixture",
        .campaign_dir = "campaigns/fixture",
        .background_stem = "map",
        .start_hub = 0,
        .hubs = &.{
            // Alpha's grid is spawn-normalized (spawn at 0,0, all
            // coordinates >= 0) so the written bbox equals the authored
            // coordinates - the reload comparisons are exact.
            .{
                .handle = 0,
                .uuid = "a",
                .dir = "alpha",
                .name = "Alpha",
                .position = .{ .x = -200, .y = 0 },
                .grid = .{
                    .level_tiles = &.{
                        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
                        .{ .x = 0, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 0, .y = 2 },
                        .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 },
                    },
                    .player_start = .{ .x = 0, .y = 0 },
                    .decoration_placements = &.{
                        .{ .type_id = 0, .position = .{ .x = 2, .y = 0 } },
                        .{ .type_id = 1, .position = .{ .x = 0, .y = 2 } },
                        .{ .type_id = 0, .position = .{ .x = 1, .y = 0 } },
                    },
                    .npc_placements = &.{
                        .{ .npc_type = .gear_upgrader, .position = .{ .x = 1, .y = 1 } },
                        .{ .npc_type = .dream_guide, .position = .{ .x = 2, .y = 2 } },
                        .{ .npc_type = .gear_upgrader, .position = .{ .x = 0, .y = 1 } },
                    },
                    .exit_placements = &.{
                        .{ .mission = 2, .position = .{ .x = 2, .y = 1 } },
                        .{ .mission = 3, .position = .{ .x = 1, .y = 2 } },
                    },
                },
            },
            .{
                .handle = 1,
                .uuid = "b",
                .dir = "beta",
                .name = "Beta",
                .position = .{ .x = 400, .y = 300 },
                .grid = .{
                    .level_tiles = &.{.{ .x = 0, .y = 0 }},
                    .player_start = .{ .x = 0, .y = 0 },
                },
            },
        },
        .missions = &.{
            .{ .handle = 2, .uuid = "u1", .name = "One", .dir = "one", .start = 0, .destination = 1, .direction = 90 },
            .{ .handle = 3, .uuid = "u2", .name = "Beyond", .dir = "beyond", .start = 0 },
            .{ .handle = 4, .uuid = "u3", .name = "Salvage", .dir = "salvage", .destination = 1, .orphan_start_position = .{ .x = -600, .y = -300 } },
            .{ .handle = 5, .uuid = "u4", .name = "Ghost", .dir = "ghost", .orphan_start_position = .{ .x = -600, .y = -300 }, .orphan_destination_position = .{ .x = -600, .y = 300 } },
        },
        .decoration_types = &.{
            .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
            .{ .id = "rock", .sprite = "ruin_10", .footprint = &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } } },
        },
        .next_handle = 6,
    };
}

fn campaignWriterFixtureIds() CampaignSaveIds {
    return .{
        .campaign_uuid = "cu",
        .hub_uuids = &.{ "a", "b" },
        .mission_uuids = &.{ "u1", "u2", "u3", "u4" },
    };
}

test "writeCampaignHub: the round trip through loadHub" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const editor = campaignWriterFixture();
    const ids = campaignWriterFixtureIds();
    const hub_txt = try writeCampaignHub(editor, editor.hubs[0], ids, "campaigns/fixture/hubs/alpha", allocator);

    const sections = try parser.parseConfigFile(hub_txt, allocator, &parser.hub_sections);
    const hub = try loaders.loadHub(sections, null, allocator, "campaigns/fixture/hubs/alpha/hub.txt", null);

    try std.testing.expectEqualStrings("Alpha", hub.name);
    try std.testing.expectEqualStrings("a", hub.uuid);
    // The grid: the written bbox equals the authored coordinates (the
    // spawn-normalized fixture), so the reload is exact. Every authored
    // tile cell hosts a code or '!' (no bare '.'), and the reload counts
    // 1 (!) + 3 (NPC cells, walkable) + 2 (exit cells, walkable) - the
    // three decoration ANCHOR cells imply no tile (the level writer's
    // convention).
    try std.testing.expectEqual(@as(usize, 6), hub.hub_tiles.len);
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, hub.player.position);
    // The decorations: three placements, the sprites from the palette,
    // in the LAYOUT WALK order (row-major: (1,0) + (2,0) tree, then
    // (0,2) rock).
    try std.testing.expectEqual(@as(usize, 3), hub.decorations.len);
    try std.testing.expectEqualStrings("tree_1", hub.decorations[0].name);
    try std.testing.expectEqualStrings("tree_1", hub.decorations[1].name);
    try std.testing.expectEqualStrings("ruin_10", hub.decorations[2].name);
    // The NPCs: three placements, the types preserved (two of one kind
    // share a code + section entry), row-major order.
    try std.testing.expectEqual(@as(usize, 3), hub.npcs.len);
    try std.testing.expectEqual(types.NpcType.gear_upgrader, hub.npcs[0].npc_type);
    try std.testing.expectEqual(types.NpcType.gear_upgrader, hub.npcs[1].npc_type);
    try std.testing.expectEqual(types.NpcType.dream_guide, hub.npcs[2].npc_type);
    // The exits: the MARKER projection - the mission + the tile, no edge
    // data (destination + direction live in campaign.txt's Missions
    // section; DESIGN → File formats).
    try std.testing.expectEqual(@as(usize, 2), hub.mission_exits.len);
    try std.testing.expectEqualStrings("u1", hub.mission_exits[0].mission_uuid);
    try std.testing.expectEqual(types.Vector2{ .x = 2, .y = 1 }, hub.mission_exits[0].position);
    try std.testing.expectEqualStrings("u2", hub.mission_exits[1].mission_uuid);
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 2 }, hub.mission_exits[1].position);
}

test "writeCampaignFile: the round trip through loadCampaign + the Missions section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const editor = campaignWriterFixture();
    const ids = campaignWriterFixtureIds();
    const campaign_txt = try writeCampaignFile(editor, ids, allocator);

    const sections = try parser.parseConfigFile(campaign_txt, allocator, &parser.campaign_sections);
    const campaign = try loaders.loadCampaign(sections, "campaigns/fixture", allocator, null);

    try std.testing.expectEqualStrings("Fixture", campaign.name);
    try std.testing.expectEqualStrings("cu", campaign.uuid);
    try std.testing.expectEqualStrings("a", campaign.start_hub);
    try std.testing.expectEqualStrings("map", editor.background_stem);
    try std.testing.expectEqual(@as(usize, 2), campaign.hubs.len);
    try std.testing.expectEqualStrings("a", campaign.hubs[0].uuid);
    try std.testing.expectEqual(types.Vector2{ .x = -200, .y = 0 }, campaign.hubs[0].position);
    try std.testing.expectEqualStrings("b", campaign.hubs[1].uuid);

    // The Missions section: THE first-class edge table, one group per
    // mission in authored order - u1 (wired a -> b, authored direction),
    // u2 (started + dangling), u3 (unwired, live destination + its start
    // ghost), u4 (fully orphaned, both ghosts).
    const missions_section = parser.findSection(sections, "Missions").?;
    try std.testing.expectEqual(@as(usize, 4), missions_section.entry_groups.len);
    const first = missions_section.entry_groups[0].pairs;
    try std.testing.expectEqualStrings("u1", parser.findValue(first, "mission_uuid").?);
    try std.testing.expectEqualStrings("a", parser.findValue(first, "start_hub").?);
    try std.testing.expectEqualStrings("b", parser.findValue(first, "destination_hub").?);
    try std.testing.expectEqualStrings("90", parser.findValue(first, "direction").?);
    const second = missions_section.entry_groups[1].pairs;
    try std.testing.expectEqualStrings("u2", parser.findValue(second, "mission_uuid").?);
    try std.testing.expectEqualStrings("a", parser.findValue(second, "start_hub").?);
    try std.testing.expect(parser.findValue(second, "destination_hub") == null);
    try std.testing.expect(parser.findValue(second, "direction") == null);
    const third = missions_section.entry_groups[2].pairs;
    try std.testing.expectEqualStrings("u3", parser.findValue(third, "mission_uuid").?);
    try std.testing.expect(parser.findValue(third, "start_hub") == null);
    try std.testing.expectEqualStrings("b", parser.findValue(third, "destination_hub").?);
    try std.testing.expect(parser.findValue(third, "start_position") != null);
    try std.testing.expect(parser.findValue(third, "destination_position") == null);
    const fourth = missions_section.entry_groups[3].pairs;
    try std.testing.expectEqualStrings("u4", parser.findValue(fourth, "mission_uuid").?);
    try std.testing.expect(parser.findValue(fourth, "start_hub") == null);
    try std.testing.expect(parser.findValue(fourth, "destination_hub") == null);
    try std.testing.expect(parser.findValue(fourth, "start_position") != null);
    try std.testing.expect(parser.findValue(fourth, "destination_position") != null);
}

test "writeCampaignMissionFile: the identity round trip through loadMission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const editor = campaignWriterFixture();
    const mission_txt = try writeCampaignMissionFile(editor.missions[0], "u1", allocator);
    const sections = try parser.parseConfigFile(mission_txt, allocator, &parser.mission_sections);
    const mission = try loaders.loadMission(sections, allocator);
    try std.testing.expectEqualStrings("u1", mission.uuid);
    try std.testing.expectEqualStrings("One", mission.name);
}
