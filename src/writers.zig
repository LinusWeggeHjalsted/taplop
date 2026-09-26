//! Save/settings writers — the inverse of the loaders (loaders.zig). Converts
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
/// Returns an owned slice — caller must free with the same allocator.
/// This is the core function used by both web (download) and standalone (file write).
pub fn writePlayerSave(
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

    // DiscoveredHubs
    try buffer.appendSlice(allocator, "\nDiscoveredHubs\n");
    for (player_data.discovered_hubs, 0..) |hub, index| {
        try buffer.print(allocator, "name {s}\n", .{hub.name});
        if (index < player_data.discovered_hubs.len - 1) {
            try buffer.appendSlice(allocator, "\n");
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
    // the editor mission's player.txt — see writePlayerLoadout).
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
/// player.txt (the PlayerLoadout format — `parsePlayerLoadoutFields` is the
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
/// `~/.ziglop/settings.txt` — see DESIGN → Input. The full settings are
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
    // Audio — u32 percentages 0–100. See DESIGN → UI Framework → Settings
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

    // InputBindings — one entry group per binding, blank-line-separated.
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
        try buffer.print(allocator, "context {s}\n", .{@tagName(binding.context)});
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
// The pure projection of an `Editor` into mission-directory file contents —
// the inverse of loadLevel/loadMission/loadPlayerLoadout + buildEditorMission.
// The SAVE HANDLER owns the uuid resolution + the IO; this writer is
// deterministic + side-effect free (directly round-trip-testable).
// See DESIGN → Level Editor → Mission identity + Editor UI layout.

/// Everything the editor save writes for one mission.
pub const WrittenEditorMission = struct {
    mission_txt: []const u8,
    player_txt: []const u8,
    /// One per editor level, in tab order — the handler writes them as
    /// level_1.txt .. level_N.txt.
    level_txts: []const []const u8,
};

/// Layout char-code assignment order: digits, lowercase, uppercase, then
/// the remaining printable ASCII. The reserved layout chars (' ', '.',
/// '!', '=') are never assigned — 91 codes available per level.
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
    // '!', '=' are never assignable — ' ' isn't in this range to begin
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
/// the tools it uses), in palette order — entities, then decorations,
/// then items.
const LayoutCodeAssignment = struct {
    type_id: u32,
    code: u8,
};

/// Write the whole mission: mission.txt, player.txt, and one level file
/// per level. `mission_uuid` is passed in — the write-only mint lives at
/// the save site (a fresh mission's uuid is minted at first save and
/// never held in GameState; see DESIGN → Level Editor → Mission
/// identity). Fails with error.TooManyLayoutCodes when a single level
/// places more tools than the char-code set provides.
pub fn writeEditorMission(
    editor: types.Editor,
    mission_uuid: []const u8,
    mission_dir_name: []const u8,
    allocator: std.mem.Allocator,
) !WrittenEditorMission {
    var mission_buffer: std.ArrayList(u8) = .empty;
    try mission_buffer.appendSlice(allocator, "Metadata\n");
    try mission_buffer.print(allocator, "file_format_version {d}\n", .{parser.mission_file_format_version});
    try mission_buffer.print(allocator, "mission_uuid {s}\n", .{mission_uuid});
    try mission_buffer.print(allocator, "name {s}\n", .{editor.mission.name});
    try mission_buffer.print(allocator, "level_count {d}\n", .{editor.levels.len});

    const player_txt = try writePlayerLoadout(editor.player_def.template, allocator);

    var level_txts: std.ArrayList([]const u8) = .empty;
    for (editor.levels) |level| {
        try level_txts.append(allocator, try writeEditorLevel(
            level,
            editor.entity_types,
            editor.decoration_types,
            editor.item_types,
            mission_dir_name,
            allocator,
        ));
    }

    return .{
        .mission_txt = try mission_buffer.toOwnedSlice(allocator),
        .player_txt = player_txt,
        .level_txts = try level_txts.toOwnedSlice(allocator),
    };
}

/// Write the mission's player.txt — the PlayerLoadout format (the loadout
/// sections of a player save; no Info/stats/hubs — base stats aren't
/// authorable and the NAME is not part of the format, so a reloaded
/// loadout reads back as "Player" regardless of the template's name).
pub fn writePlayerLoadout(
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
/// definitions — a level file never carries a tool it doesn't place.
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
/// out-of-range cells (a footprint tile outside the bbox — impossible by
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

/// Rewrite a custom sprite stem's namespace to the save target:
/// `custom/<anything>/<file-stem>` → `custom/<mission_dir_name>/<file-stem>`.
/// The namespace component is IDENTITY ONLY, never a read path — custom
/// art resolves from the mission's own directory (see DESIGN → Custom
/// Missions & Online Services → the sprite id convention + the save flow's
/// art copy) — so the save is where a stale namespace (a mission renamed
/// after authoring keeps stems naming the old dir) is healed. Non-custom
/// stems and degenerate stems (no dir segment — the picker never writes
/// them) pass through unchanged.
fn normalizedCustomStem(
    sprite: []const u8,
    mission_dir_name: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    if (!std.mem.startsWith(u8, sprite, "custom/")) return sprite;
    const slash = std.mem.lastIndexOfScalar(u8, sprite, '/') orelse return sprite;
    const file_stem = sprite[slash + 1 ..];
    if (file_stem.len == 0) return sprite;
    return std.fmt.allocPrint(allocator, "custom/{s}/{s}", .{ mission_dir_name, file_stem });
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
    mission_dir_name: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const codes = try assignLayoutCodes(level, entity_types, decoration_types, item_types, allocator);

    // The bbox over everything placed — the player start is always present
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
    // Tiles first — the marker + code chars below overwrite their own
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

    // Layout — each row trimmed to its own last used column (no trailing
    // spaces; interior all-space rows stay as empty lines, which the
    // parser stores as empty raw rows).
    try buffer.appendSlice(allocator, "\nLayout\n");
    var row: i32 = 0;
    while (row < grid_height) : (row += 1) {
        const row_start: usize = @intCast(row * grid_width);
        const row_cells = grid[row_start .. row_start + @as(usize, @intCast(grid_width))];
        var row_length = row_cells.len;
        while (row_length > 0 and row_cells[row_length - 1] == ' ') row_length -= 1;
        try buffer.appendSlice(allocator, row_cells[0..row_length]);
        try buffer.appendSlice(allocator, "\n");
    }

    // Entities — used entity types, palette order, the full definition in
    // the parser's exact key vocabulary (the coupling contract).
    if (codes.entity.len > 0) {
        try buffer.appendSlice(allocator, "\nEntities\n");
        for (codes.entity, 0..) |assignment, index| {
            if (index > 0) try buffer.appendSlice(allocator, "\n");
            try writeEntityDefinition(&buffer, allocator, assignment.code, entity_types[assignment.type_id].template, mission_dir_name);
        }
    }

    // Decorations — used decoration types (sprite + footprint + layers).
    if (codes.decoration.len > 0) {
        try buffer.appendSlice(allocator, "\nDecorations\n");
        for (codes.decoration, 0..) |assignment, index| {
            if (index > 0) try buffer.appendSlice(allocator, "\n");
            const definition = decoration_types[assignment.type_id];
            try buffer.print(allocator, "character_code {s}\n", .{&[_]u8{assignment.code}});
            try buffer.print(allocator, "sprite {s}\n", .{try normalizedCustomStem(definition.sprite, mission_dir_name, allocator)});
            try buffer.print(allocator, "color_index {d}\n", .{definition.color_index});
            if (definition.keep_original_colors) {
                try buffer.print(allocator, "keep_original_colors true\n", .{});
            }
            for (definition.footprint) |footprint_tile| {
                try buffer.print(allocator, "footprint {d} {d}\n", .{ footprint_tile.x, footprint_tile.y });
            }
            for (definition.layers) |layer| {
                try buffer.appendSlice(allocator, "layer\n");
                try buffer.print(allocator, "sprite {s}\n", .{try normalizedCustomStem(layer.sprite, mission_dir_name, allocator)});
                try buffer.print(allocator, "color_index {d}\n", .{layer.color_index});
            }
        }
    }

    // Items — used item types. Skill tomes are not level-authorable (the
    // editor's item paths never create them); a tome here is a crafted
    // state the editor's own invariants forbid — fail fast.
    if (codes.item.len > 0) {
        try buffer.appendSlice(allocator, "\nItems\n");
        for (codes.item, 0..) |assignment, index| {
            if (index > 0) try buffer.appendSlice(allocator, "\n");
            try writeItemDefinition(&buffer, allocator, assignment.code, item_types[assignment.type_id].item);
        }
    }

    return try buffer.toOwnedSlice(allocator);
}

/// One Entities entry — every key `parseEntityDefinition` reads, in its
/// vocabulary (weapons / gear / utility skills / layers only when
/// present, so absent-on-reload equals absent-on-write).
fn writeEntityDefinition(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    code: u8,
    template: types.Entity,
    mission_dir_name: []const u8,
) !void {
    try buffer.print(allocator, "character_code {s}\n", .{&[_]u8{code}});
    try buffer.print(allocator, "name {s}\n", .{template.name});
    try buffer.print(allocator, "sprite {s}\n", .{try normalizedCustomStem(template.sprite, mission_dir_name, allocator)});
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
        try buffer.print(allocator, "sprite {s}\n", .{try normalizedCustomStem(layer.sprite, mission_dir_name, allocator)});
        try buffer.print(allocator, "color_index {d}\n", .{layer.color_index});
    }
}

/// One Items entry — the keys `parseItemEntry` reads for the item's kind.
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
        // utility skills on the bar (slice is a weapon skill — the parser
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
                var slots: [types.inventory_slot_count]?types.Item = .{null} ** types.inventory_slot_count;
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
    const sections = try parseConfigFile(save_text, allocator);
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

    // Inventory — items at slots 0, 1, 2
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

    const sections2 = try parseConfigFile(written, allocator);
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

    const sections = try parseConfigFile(save_text, allocator);
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
/// feature — translated layouts (everything offset from the origin), a rich
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
                var slots: [types.utility_skill_count]?types.SkillId = .{null} ** types.utility_skill_count;
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
        // Never placed anywhere — must appear in NO written file.
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
                var slots: [types.inventory_slot_count]?types.Item = .{null} ** types.inventory_slot_count;
                slots[0] = .{ .weapon = .{ .name = "Bag Sword", .weapon_type = .sword, .weapon_damage = 1 } };
                break :blk slots;
            },
        },
        .equipped_utility_skills = blk: {
            var slots: [types.utility_skill_count]?types.SkillId = .{null} ** types.utility_skill_count;
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

    const sections = try parser.parseConfigFile(bytes, allocator);
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
    const unknown_sections = try parser.parseConfigFile(raw_text, allocator);
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
        const sections = try parseConfigFile(written.mission_txt, arena);
        const mission = try loaders.loadMission(sections, arena);
        try std.testing.expectEqualStrings("436ab363-3588-42ce-950a-0bc813069c3d", mission.uuid);
        try std.testing.expectEqualStrings("My Mission", mission.name);
        try std.testing.expectEqual(@as(u32, 2), mission.level_count);
        try std.testing.expect(mission.start_hub == null);
        try std.testing.expect(mission.end_hub == null);
    }

    // player.txt: the loadout round-trips (the NAME is not part of the
    // format — a reloaded loadout reads back as "Player").
    {
        const sections = try parseConfigFile(written.player_txt, arena);
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
    // files), then a SEMANTIC compare — the reload dedups placements into a
    // fresh palette in layout-encounter order, so palette order/type ids can
    // differ from the original; positions compare TRANSLATED (the written
    // layout is normalized to the bbox origin).
    var level_sections: [2][]const parser.Section = undefined;
    for (written.level_txts, 0..) |level_txt, index| {
        level_sections[index] = try parseConfigFile(level_txt, arena);
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

    // Level 1: translated by (4,2) — '!' (0,0), '=' (1,0), Archer '1' at
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
    // equals absent-on-write — 1 is the load default); the team-2 Brute
    // carries `team 2` and reloads with it.
    {
        try std.testing.expect(std.mem.indexOf(u8, written.level_txts[0], "team ") == null);
        try std.testing.expect(std.mem.indexOf(u8, written.level_txts[1], "team 2") != null);
        try std.testing.expectEqual(@as(u32, 2),
            reloaded.entity_types[reloaded.levels[1].entity_placements[0].type_id].template.team);
    }
}

test "writeEditorMission normalizes custom sprite stems to the save target's namespace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Stale-namespace stems (authored under an old dir — the mission was
    // renamed since) on every channel that writes a sprite (entity base +
    // layer, decoration base + layer), plus shipped stems that must pass
    // through untouched.
    const entity_layers = [_]types.EntityLayer{
        .{ .sprite = "custom/old_dir/hero_hat", .color_index = 1 },
    };
    const decoration_layers = [_]types.DecorationLayer{
        .{ .sprite = "custom/old_dir/tree_top", .color_index = 2, .pixel_dims = .{ .x = 256, .y = 256 } },
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
            // Never placed — written to NO file (per-level tool filtering).
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
    // Ghost type included — unused types are not written). The trailing
    // newline keeps hero from matching hero_hat.
    const level_txt = written.level_txts[0];
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "custom/u_New Name/hero\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "custom/u_New Name/hero_hat") != null);
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "custom/u_New Name/tree\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "custom/u_New Name/tree_top") != null);
    try std.testing.expect(std.mem.indexOf(u8, level_txt, "old_dir") == null);
    // Shipped stems pass through (the load defaults + the decoration's
    // defaulted keys are part of the same contract — normalization only
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
    // its own last used column — interior alignment spaces stay, trailing
    // spaces never.
    const level_0_layout = parser.findSection(
        try parseConfigFile(written.level_txts[0], arena),
        "Layout",
    ).?;
    try std.testing.expectEqual(@as(usize, 3), level_0_layout.raw_lines.len);
    try std.testing.expectEqualStrings("!=2", level_0_layout.raw_lines[0]);
    try std.testing.expectEqualStrings("1.", level_0_layout.raw_lines[1]);
    try std.testing.expectEqualStrings("  3", level_0_layout.raw_lines[2]);

    // Level 2 (already at the origin): one compact row.
    const level_1_layout = parser.findSection(
        try parseConfigFile(written.level_txts[1], arena),
        "Layout",
    ).?;
    try std.testing.expectEqual(@as(usize, 1), level_1_layout.raw_lines.len);
    try std.testing.expectEqualStrings("!1=", level_1_layout.raw_lines[0]);
}

test "writeEditorMission fails when a level needs more codes than the ASCII set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 92 distinct used entity types in ONE level — one more than the 91
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
