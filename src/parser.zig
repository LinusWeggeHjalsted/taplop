//! Generic config-file format layer: `Section`/`EntryGroup`/`KeyValuePair`
//! types, `parseConfigFile`, `validateSections`/`validateFileFormatVersion`/
//! `validateKeys` (+ the per-type section/key whitelists), value coercion
//! (`asU32`/`asI32`/`asF32`/`asBool`/`asColor`/`parseEnum`), `findSection`/
//! `findValue`, and the shared `file_format_version` constants. The
//! game-content loaders live in `loaders.zig`, the save/settings writers in
//! `writers.zig`, and the session-log serializer/deserializer in
//! `session_log.zig` — they all build on this file. See AGENTS → Config File
//! Format / DESIGN → File System & IO.

const std = @import("std");
const types = @import("types.zig");
const build_info = @import("build_info");
const file_source_mod = @import("file_source.zig");

const FileSource = file_source_mod.FileSource;

/// Monotonic schema versions for each config-file type. Bump on any breaking
/// change to that file's layout. The loader validates the file's
/// `file_format_version` (in its Metadata/Info section) against the expected
/// constant and returns `error.UnsupportedFileFormatVersion` on mismatch — a
/// HARD gate. The version is validate-and-discard (not stored on the parsed
/// type): it's a parse-time compatibility check, not runtime state. The save
/// writer emits the current constant. See DESIGN → Versioning.
pub const level_file_format_version: u32 = 1;
pub const hub_file_format_version: u32 = 1;
pub const mission_file_format_version: u32 = 2;
pub const campaign_file_format_version: u32 = 1;
pub const player_save_file_format_version: u32 = 2;
pub const settings_file_format_version: u32 = 1;
pub const color_themes_file_format_version: u32 = 1;
pub const player_loadout_file_format_version: u32 = 1;
pub const decorations_file_format_version: u32 = 1;


const Color = types.Color;

// ============================================================
// Generic config file parser
// ============================================================

pub const KeyValuePair = struct {
    key: []const u8,
    value: []const u8,
};

/// A group of key-value pairs separated by blank lines within a section.
/// For example, each input binding in default_settings.txt is one entry group.
pub const EntryGroup = struct {
    pairs: []const KeyValuePair,
};

pub const Section = struct {
    header: []const u8,
    entry_groups: []const EntryGroup,
    /// Raw lines of the section, for sections like Layout that aren't key-value based.
    raw_lines: []const []const u8,
};

const valid_section_headers = [_][]const u8{
    "Metadata",
    "Layout",
    "Enemies",
    "Decorations",
    "Items",
    "Exits",
    "NPCs",
    "Audio",
    "Display",
    "Gameplay",
    "InputBindings",
    "Skills",
    "Info",
    "DiscoveredHubs",
    "UnlockedSkills",
    "MainHandWeapon",
    "OffHandWeapon",
    "Amulet",
    "Coat",
    "Gloves",
    "Pants",
    "Boots",
    "Inventory",
    "UtilitySkills",
    "CloneData",
    "GlobalColors",
    "Gradients",
    "EventLog",
    "PlayerLoadout",
    "Sword",
    "Shield",
    "Spear",
    "Dagger",
    "Axe",
    "Staff",
    "Crossbow",
    "Idol",
    "SkillTome",
};

fn isValidSectionHeader(line: []const u8) bool {
    for (&valid_section_headers) |header| {
        if (std.mem.eql(u8, line, header)) return true;
    }
    return false;
}

/// Parse a .txt config file into sections with entry groups.
/// Sections start with a recognized header name after a blank line.
/// Key-value pairs within a section are grouped by blank lines.
pub fn parseConfigFile(
    raw_text: []const u8,
    allocator: std.mem.Allocator,
) ![]const Section {
    var sections: std.ArrayList(Section) = .empty;
    var current_entry_groups: std.ArrayList(EntryGroup) = .empty;
    var current_pairs: std.ArrayList(KeyValuePair) = .empty;
    var current_raw_lines: std.ArrayList([]const u8) = .empty;
    var current_header: ?[]const u8 = null;
    var after_blank_line = true; // start of file counts as "after blank line"

    var line_iterator = std.mem.splitScalar(u8, raw_text, '\n');

    while (line_iterator.next()) |raw_line| {
        // Strip trailing carriage return for Windows line endings
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        // Inside a Layout section, everything is raw content until the next header.
        const in_layout = if (current_header) |header|
            std.mem.eql(u8, header, "Layout")
        else
            false;

        if (in_layout) {
            if (line.len == 0) {
                // Blank lines in Layout are empty rows — store as raw content
                try current_raw_lines.append(allocator, line);
                continue;
            }
            // Check if this line ends the Layout section
            if (isValidSectionHeader(line)) {
                // Strip trailing blank lines from layout
                while (current_raw_lines.items.len > 0 and
                    current_raw_lines.items[current_raw_lines.items.len - 1].len == 0)
                {
                    _ = current_raw_lines.pop();
                }
                // Finish Layout section
                try sections.append(allocator, .{
                    .header = current_header.?,
                    .entry_groups = try current_entry_groups.toOwnedSlice(allocator),
                    .raw_lines = try current_raw_lines.toOwnedSlice(allocator),
                });
                current_entry_groups = .empty;
                current_raw_lines = .empty;
                current_header = line;
                after_blank_line = false;
                continue;
            }
            // Otherwise it's layout content
            try current_raw_lines.append(allocator, line);
            continue;
        }

        // Empty lines separate entry groups and enable header detection
        if (line.len == 0) {
            // Finish the current entry group if it has any pairs
            if (current_pairs.items.len > 0) {
                try current_entry_groups.append(allocator, .{
                    .pairs = try current_pairs.toOwnedSlice(allocator),
                });
                current_pairs = .empty;
            }
            after_blank_line = true;
            continue;
        }

        // Section headers: recognized header name, only after a blank line or start of file.
        const is_header = after_blank_line and isValidSectionHeader(line);

        // Key-value pairs: start with a lowercase letter.
        const is_key_value = line[0] >= 'a' and line[0] <= 'z';

        if (is_header) {
            // Finish the current section if one exists.
            if (current_header) |header| {
                if (current_pairs.items.len > 0) {
                    try current_entry_groups.append(allocator, .{
                        .pairs = try current_pairs.toOwnedSlice(allocator),
                    });
                    current_pairs = .empty;
                }

                try sections.append(allocator, .{
                    .header = header,
                    .entry_groups = try current_entry_groups.toOwnedSlice(allocator),
                    .raw_lines = try current_raw_lines.toOwnedSlice(allocator),
                });
                current_entry_groups = .empty;
                current_raw_lines = .empty;
            }
            current_header = line;
        } else if (is_key_value) {
            // Key-value pair — split on first space
            if (std.mem.indexOfScalar(u8, line, ' ')) |space_index| {
                try current_pairs.append(allocator, .{
                    .key = line[0..space_index],
                    .value = line[space_index + 1 ..],
                });
            } else {
                // Key with no value
                try current_pairs.append(allocator, .{
                    .key = line,
                    .value = "",
                });
            }
        } else {
            // Raw content line (layout grids, etc.)
            try current_raw_lines.append(allocator, line);
        }

        after_blank_line = false;
    }

    // Finish the last section
    if (current_header) |header| {
        if (current_pairs.items.len > 0) {
            try current_entry_groups.append(allocator, .{
                .pairs = try current_pairs.toOwnedSlice(allocator),
            });
        }

        try sections.append(allocator, .{
            .header = header,
            .entry_groups = try current_entry_groups.toOwnedSlice(allocator),
            .raw_lines = try current_raw_lines.toOwnedSlice(allocator),
        });
    }

    return try sections.toOwnedSlice(allocator);
}

pub const ParsedConfigFile = struct {
    sections: []const Section,
    /// The raw file text that section keys/values point into. Must be freed after sections.
    raw_text: []const u8,
};

/// Read a file via the FileSource (persistent dir / embedded map) and parse
/// it into sections. See DESIGN → File System & IO.
pub fn parseConfigFileFromPath(
    file_source: *const FileSource,
    file_path: []const u8,
    allocator: std.mem.Allocator,
) !ParsedConfigFile {
    const raw_text = try file_source.readFile(allocator, file_path);
    const sections = try parseConfigFile(raw_text, allocator);
    return .{
        .sections = sections,
        .raw_text = raw_text,
    };
}

// ============================================================
// Value conversion helpers
// ============================================================

/// Verify that all sections in the parsed file are in the expected set.
/// Returns an error if an unexpected section is found.
pub fn validateSections(
    sections: []const Section,
    expected_headers: []const []const u8,
) !void {
    for (sections) |section| {
        var found = false;
        for (expected_headers) |expected| {
            if (std.mem.eql(u8, section.header, expected)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnexpectedSection;
    }
}

/// Validate `file_format_version` from a parsed Metadata/Info section's first
/// entry group. Required (hard gate): a file without it returns
/// `error.UnsupportedFileFormatVersion`. Mismatch returns the same error.
/// Validate-and-discard — the version is not stored on the parsed type.
pub fn validateFileFormatVersion(
    sections: []const Section,
    section_header: []const u8,
    expected_version: u32,
) !void {
    const section = findSection(sections, section_header) orelse
        return error.UnsupportedFileFormatVersion;
    if (section.entry_groups.len == 0) return error.UnsupportedFileFormatVersion;
    const pairs = section.entry_groups[0].pairs;
    const version_str = findValue(pairs, "file_format_version") orelse
        return error.UnsupportedFileFormatVersion;
    const version = asU32(version_str) orelse return error.UnsupportedFileFormatVersion;
    if (version != expected_version) return error.UnsupportedFileFormatVersion;
}

pub fn asU32(value: []const u8) ?u32 {
    return std.fmt.parseInt(u32, value, 10) catch null;
}

/// Parse a gear-stat value and clamp it to `max`. If the value exceeds `max`,
/// append a warning to `warnings` (when non-null) naming the field, value,
/// file, and max — then return `max` so the game stays playable. Returns 0 on

pub fn asI32(value: []const u8) ?i32 {
    return std.fmt.parseInt(i32, value, 10) catch null;
}

pub fn asF32(value: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, value) catch null;
}

pub fn asBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

/// Parse a hex digit character to its numeric value (0-15).
fn hexDigitValue(character: u8) ?u8 {
    if (character >= '0' and character <= '9') return character - '0';
    if (character >= 'a' and character <= 'f') return character - 'a' + 10;
    if (character >= 'A' and character <= 'F') return character - 'A' + 10;
    return null;
}

/// Parse a hex color string like "#FF8800" into a Color.
/// The '#' prefix is required.
pub fn asColor(value: []const u8) ?Color {
    if (value.len != 7) return null;
    if (value[0] != '#') return null;

    const r_high = hexDigitValue(value[1]) orelse return null;
    const r_low = hexDigitValue(value[2]) orelse return null;
    const g_high = hexDigitValue(value[3]) orelse return null;
    const g_low = hexDigitValue(value[4]) orelse return null;
    const b_high = hexDigitValue(value[5]) orelse return null;
    const b_low = hexDigitValue(value[6]) orelse return null;

    return .{
        .r = r_high * 16 + r_low,
        .g = g_high * 16 + g_low,
        .b = b_high * 16 + b_low,
    };
}

// ============================================================
// Per-type loaders
// ============================================================

/// Find a section by header name. Returns null if not found.
pub fn findSection(
    sections: []const Section,
    header: []const u8,
) ?Section {
    for (sections) |section| {
        if (std.mem.eql(u8, section.header, header)) return section;
    }
    return null;
}

/// Find a value by key in a single entry group. Returns null if not found.
pub fn findValue(
    pairs: []const KeyValuePair,
    key: []const u8,
) ?[]const u8 {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, key)) return pair.value;
    }
    return null;
}

/// Convert a string to any enum value by matching field names.
pub fn parseEnum(
    comptime E: type,
    value: []const u8,
) ?E {
    const fields = @typeInfo(E).@"enum".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub const settings_sections = [_][]const u8{ "Metadata", "Audio", "Display", "Gameplay", "InputBindings" };
pub const weapon_type_sections = [_][]const u8{"Skills"};
pub const level_sections = [_][]const u8{ "Metadata", "Layout", "Enemies", "Decorations", "Items" };
pub const hub_sections = [_][]const u8{ "Metadata", "Layout", "NPCs", "Decorations", "Exits" };
pub const campaign_sections = [_][]const u8{"Metadata"};
pub const mission_sections = [_][]const u8{"Metadata"};
pub const decoration_registry_sections = [_][]const u8{ "Metadata", "Decorations" };
pub const player_save_sections = [_][]const u8{
    "Metadata",       "Info",           "DiscoveredHubs",  "UnlockedSkills", "MainHandWeapon",
    "OffHandWeapon",  "Amulet",          "Coat",           "Gloves",
    "Pants",          "Boots",           "Inventory",      "UtilitySkills",
    "CloneData",
};

// ============================================================
// Key validation (approach A — see DESIGN → Error Handling)
// ============================================================
//
// Per-section key whitelists, analogous to the section whitelists above.
// A file type's key map is a StaticStringMap from section header → valid
// keys. validateKeys walks all sections, looks up each section's header in
// the map, and warns on any key not in the whitelist. Warnings are advisory
// (the file still loads); they surface via the pending_error popup. This
// catches typo'd keys (e.g. `chracter_code` instead of `character_code`)
// that the permissive parser would otherwise silently drop.
//
// Adding a new key to a loader: add it to the section's whitelist here too,
// or valid content will false-positive a warning. The whitelist is the
// single source of truth for "what keys does this section accept."

// --- Level file key whitelists ---
//
// Enemies entries use the full entity-definition key set (parseEntityDefinition)
// plus character_code. Items entries use item-type-specific keys. Decorations
// entries use sprite/footprint/layer keys. Metadata carries level metadata.
// Layout is a raw char grid (no key-value pairs) so it has no key whitelist.

const level_metadata_keys = [_][]const u8{ "file_format_version", "name", "color_wheel_index" };

const level_enemies_keys = [_][]const u8{
    "character_code",
    "name",
    "sprite",
    "color_index",
    "displays_weapons",
    "max_health",
    "defense",
    "speed",
    "aggro_range",
    "main_hand_weapon_type",
    "main_hand_weapon_name",
    "main_hand_weapon_damage",
    "off_hand_weapon_type",
    "off_hand_weapon_name",
    "off_hand_weapon_damage",
    "amulet_name",
    "amulet_spell_damage",
    "coat_name",
    "coat_health_bonus",
    "coat_defense_bonus",
    "gloves_name",
    "gloves_health_bonus",
    "gloves_damage_bonus",
    "pants_name",
    "pants_health_bonus",
    "pants_pickup_radius_bonus",
    "boots_name",
    "boots_health_bonus",
    "boots_speed_bonus",
    "slot_4", "slot_5", "slot_6", "slot_7", "slot_8",
    "layer",
};

const level_decorations_keys = [_][]const u8{
    "character_code",
    "sprite",
    "color_index",
    "footprint",
    "layer",
};

/// Same as level_decorations_keys but without `character_code` — registry
/// entries are prefabs identified by sprite stem, not placed by layout char.
const decoration_registry_decorations_keys = [_][]const u8{
    "sprite",
    "color_index",
    "footprint",
    "layer",
};

const level_items_keys = [_][]const u8{
    "character_code",
    "item_type",
    "item_name",
    "weapon_type",
    "damage",
    "spell_damage",
    "defense",
    "health",
    "pickup_radius",
    "speed",
};

/// Static key map for level files: section header → valid keys. Sections
/// not in the map (e.g. Layout, which has no key-value pairs) are skipped by
/// validateKeys. Pass this to validateKeys when loading a level file.
pub const level_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Metadata", &level_metadata_keys },
    .{ "Enemies", &level_enemies_keys },
    .{ "Decorations", &level_decorations_keys },
    .{ "Items", &level_items_keys },
});

/// Static key map for the decoration registry (data/decorations.txt). The
/// Decorations section uses the same keys as a level's Decorations section
/// minus `character_code` (registry entries are prefabs, not placed by
/// layout char). See DESIGN → Decorations & Footprint.
pub const decoration_registry_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Metadata", &level_metadata_keys },
    .{ "Decorations", &decoration_registry_decorations_keys },
});

// --- Hub file key whitelists ---
//
// Metadata carries hub metadata. NPCs entries are simple entity definitions
// (character_code + name + sprite). Exits entries carry character_code +
// mission_id. Decorations share the level decoration key set. Layout is a
// raw grid (excluded).

const hub_metadata_keys = [_][]const u8{ "file_format_version", "name", "color_wheel_index" };

const hub_npcs_keys = [_][]const u8{ "character_code", "name", "sprite" };

const hub_exits_keys = [_][]const u8{ "character_code", "mission_id" };

/// Hub file key map: section header → valid keys. Decorations share the
/// level decoration key set (same format). Layout is excluded (raw grid).
pub const hub_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Metadata", &hub_metadata_keys },
    .{ "NPCs", &hub_npcs_keys },
    .{ "Exits", &hub_exits_keys },
    .{ "Decorations", &level_decorations_keys },
});

// --- Mission file key whitelists ---
//
// Only a Metadata section with name, start_hub, end_hub, level_count.

const mission_metadata_keys = [_][]const u8{ "file_format_version", "mission_uuid", "name", "start_hub", "end_hub", "level_count" };

pub const mission_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Metadata", &mission_metadata_keys },
});

// --- Campaign file key whitelists ---
//
// Only a Metadata section with name + start_hub.

const campaign_metadata_keys = [_][]const u8{ "file_format_version", "name", "start_hub" };

pub const campaign_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Metadata", &campaign_metadata_keys },
});

// --- Settings file key whitelists ---
//
// Metadata carries file_format_version. Audio/Display/Gameplay carry their
// respective keys. InputBindings entries carry input_type, input_name,
// action + modifier flags.

const settings_audio_keys = [_][]const u8{ "master_volume", "music_volume", "sound_effects_volume" };
const settings_display_keys = [_][]const u8{ "vsync", "render_fps_cap", "camera_zoom", "animation_fps" };
const settings_gameplay_keys = [_][]const u8{ "auto_skip_attack_step_out_of_combat", "auto_target_at_cursor", "player_color_index" };
const settings_input_bindings_keys = [_][]const u8{ "input_type", "input_name", "action", "ctrl", "shift", "alt" };

pub const settings_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Metadata", &level_metadata_keys }, // Metadata keys are shared (file_format_version + name)
    .{ "Audio", &settings_audio_keys },
    .{ "Display", &settings_display_keys },
    .{ "Gameplay", &settings_gameplay_keys },
    .{ "InputBindings", &settings_input_bindings_keys },
});

// --- Color theme file key whitelists ---
//
// Metadata carries file_format_version. GlobalColors has lightest +
// darkest. Gradients entries carry gradient_index + color_0..color_5.

const color_theme_global_keys = [_][]const u8{ "lightest", "darkest" };
const color_theme_gradient_keys = [_][]const u8{
    "gradient_index",
    "color_0", "color_1", "color_2", "color_3", "color_4", "color_5",
};

pub const color_theme_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Metadata", &level_metadata_keys },
    .{ "GlobalColors", &color_theme_global_keys },
    .{ "Gradients", &color_theme_gradient_keys },
});

// --- Weapon type file key whitelists ---
//
// Only a Skills section with skill_1, skill_2, skill_3.

const weapon_type_skills_keys = [_][]const u8{ "skill_1", "skill_2", "skill_3" };

pub const weapon_type_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Skills", &weapon_type_skills_keys },
});

// --- Salvage file key whitelists ---
//
// Each weapon-type section + armor sections + SkillTome use MaterialType
// enum values as keys (wood, metal, leather, cloth, knowledge). No Metadata
// section in the salvage file (it starts with the weapon sections).

const salvage_split_keys = [_][]const u8{ "wood", "metal", "leather", "cloth", "knowledge" };

pub const salvage_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Sword", &salvage_split_keys },
    .{ "Shield", &salvage_split_keys },
    .{ "Spear", &salvage_split_keys },
    .{ "Dagger", &salvage_split_keys },
    .{ "Axe", &salvage_split_keys },
    .{ "Staff", &salvage_split_keys },
    .{ "Crossbow", &salvage_split_keys },
    .{ "Idol", &salvage_split_keys },
    .{ "Amulet", &salvage_split_keys },
    .{ "Coat", &salvage_split_keys },
    .{ "Gloves", &salvage_split_keys },
    .{ "Pants", &salvage_split_keys },
    .{ "Boots", &salvage_split_keys },
    .{ "SkillTome", &salvage_split_keys },
});

// --- Player save file key whitelists ---
//
// Metadata carries file_format_version. Info carries player stats +
// materials. UnlockedSkills entries carry `name`. Weapon sections carry
// item_name + weapon_type + damage. Armor sections carry item_name + their
// stat bonuses. Inventory entries carry slot + item_type + item-specific
// keys (same as level Items but with `slot`). UtilitySkills carries
// slot_4..slot_8. CloneData entries carry mission_uuid (the clone key) +
// clone_name + turn count + materials. DiscoveredHubs entries carry `name`.

const save_info_keys = [_][]const u8{
    "player_name", "current_campaign", "current_hub",
    "turns", "deaths", "defeated_enemies", "skills_used",
    "wood_salvage", "metal_salvage", "leather_salvage", "cloth_salvage", "knowledge",
};
const save_unlocked_skills_keys = [_][]const u8{"name"};
const save_weapon_keys = [_][]const u8{ "item_name", "weapon_type", "damage" };
const save_amulet_keys = [_][]const u8{ "item_name", "spell_damage" };
const save_coat_keys = [_][]const u8{ "item_name", "armor", "health" };
const save_gloves_keys = [_][]const u8{ "item_name", "damage", "health" };
const save_pants_keys = [_][]const u8{ "item_name", "pickup_radius", "health" };
const save_boots_keys = [_][]const u8{ "item_name", "speed", "health" };
const save_inventory_keys = [_][]const u8{
    "slot", "item_type", "item_name",
    "weapon_type", "damage", "spell_damage", "armor", "health", "pickup_radius", "speed", "skill_name",
};
const save_utility_skills_keys = [_][]const u8{ "slot_4", "slot_5", "slot_6", "slot_7", "slot_8" };
const save_clone_data_keys = [_][]const u8{
    "mission_uuid", "clone_name", "turns_to_complete",
    "wood", "metal", "leather", "cloth", "knowledge",
};
const save_discovered_hubs_keys = [_][]const u8{"name"};

pub const player_save_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Metadata", &level_metadata_keys },
    .{ "Info", &save_info_keys },
    .{ "DiscoveredHubs", &save_discovered_hubs_keys },
    .{ "UnlockedSkills", &save_unlocked_skills_keys },
    .{ "MainHandWeapon", &save_weapon_keys },
    .{ "OffHandWeapon", &save_weapon_keys },
    .{ "Amulet", &save_amulet_keys },
    .{ "Coat", &save_coat_keys },
    .{ "Gloves", &save_gloves_keys },
    .{ "Pants", &save_pants_keys },
    .{ "Boots", &save_boots_keys },
    .{ "Inventory", &save_inventory_keys },
    .{ "UtilitySkills", &save_utility_skills_keys },
    .{ "CloneData", &save_clone_data_keys },
});

// --- Player loadout (player.txt) key whitelists ---
//
// Uses parseEntityDefinition (same key set as level Enemies, minus
// character_code — the player isn't placed by char code). The file has a
// Metadata section + a PlayerLoadout section whose entry group is the
// entity definition.

const player_loadout_def_keys = [_][]const u8{
    "name", "sprite", "color_index", "displays_weapons",
    "max_health", "defense", "speed", "aggro_range",
    "main_hand_weapon_type", "main_hand_weapon_name", "main_hand_weapon_damage",
    "off_hand_weapon_type", "off_hand_weapon_name", "off_hand_weapon_damage",
    "amulet_name", "amulet_spell_damage",
    "coat_name", "coat_health_bonus", "coat_defense_bonus",
    "gloves_name", "gloves_health_bonus", "gloves_damage_bonus",
    "pants_name", "pants_health_bonus", "pants_pickup_radius_bonus",
    "boots_name", "boots_health_bonus", "boots_speed_bonus",
    "slot_4", "slot_5", "slot_6", "slot_7", "slot_8",
    "layer",
};

pub const player_loadout_key_map = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "Metadata", &level_metadata_keys },
    .{ "PlayerLoadout", &player_loadout_def_keys },
});

/// Validate that every key in every entry group of every section is in the
/// key map for that section. Appends a warning per unknown key to `warnings`.
/// Sections not in `key_map` are skipped (they may be raw-grid sections like
/// Layout, or sections without a defined key set yet). `file_path` is
/// included in the warning message so the author knows which file to fix.
/// Advisory: never returns an error, never rejects the file.
pub fn validateKeys(
    sections: []const Section,
    key_map: std.StaticStringMap([]const []const u8),
    file_path: []const u8,
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]const u8),
) void {
    for (sections) |section| {
        const valid_keys = key_map.get(section.header) orelse continue;
        for (section.entry_groups) |group| {
            for (group.pairs) |pair| {
                if (keyInList(valid_keys, pair.key)) continue;
                warnings.append(allocator, std.fmt.allocPrint(allocator,
                    "Unknown key '{s}' in {s} section of {s}",
                    .{ pair.key, section.header, file_path },
                ) catch @panic("failed to allocate key validation warning")) catch
                    @panic("failed to append key validation warning");
            }
        }
    }
}

/// Check if `key` is in the list of valid keys. Linear scan (the lists are
/// small, typically 5-30 keys).
fn keyInList(list: []const []const u8, key: []const u8) bool {
    for (list) |valid| {
        if (std.mem.eql(u8, valid, key)) return true;
    }
    return false;
}


pub const color_theme_sections = [_][]const u8{ "Metadata", "GlobalColors", "Gradients" };



// ============================================================
// Tests
// ============================================================

/// Helper to free all memory allocated by parseConfigFile.
pub fn freeParsedSections(
    sections: []const Section,
    allocator: std.mem.Allocator,
) void {
    for (sections) |section| {
        for (section.entry_groups) |group| {
            allocator.free(group.pairs);
        }
        allocator.free(section.entry_groups);
        allocator.free(section.raw_lines);
    }
    allocator.free(sections);
}

test "parseConfigFile handles sections, key-value pairs, and entry groups" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Audio
        \\key_a value_a
        \\key_b value with spaces
        \\
        \\Gameplay
        \\first_key 123
        \\
        \\second_key true
        \\
        \\Layout
        \\
        \\Metadata
        \\only_key only_value
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    // Correct number of sections
    try std.testing.expectEqual(4, sections.len);

    // Section headers are parsed correctly
    try std.testing.expectEqualStrings("Audio", sections[0].header);
    try std.testing.expectEqualStrings("Gameplay", sections[1].header);
    try std.testing.expectEqualStrings("Layout", sections[2].header);

    // Key-value pairs within a single entry group
    try std.testing.expectEqual(1, sections[0].entry_groups.len);
    try std.testing.expectEqual(2, sections[0].entry_groups[0].pairs.len);
    try std.testing.expectEqualStrings("key_a", sections[0].entry_groups[0].pairs[0].key);
    try std.testing.expectEqualStrings("value_a", sections[0].entry_groups[0].pairs[0].value);

    // Values can contain spaces
    try std.testing.expectEqualStrings("value with spaces", sections[0].entry_groups[0].pairs[1].value);

    // Blank lines separate entry groups within a section
    try std.testing.expectEqual(2, sections[1].entry_groups.len);
    try std.testing.expectEqualStrings("first_key", sections[1].entry_groups[0].pairs[0].key);
    try std.testing.expectEqualStrings("second_key", sections[1].entry_groups[1].pairs[0].key);

    // Empty sections have no entry groups
    try std.testing.expectEqual(0, sections[2].entry_groups.len);

    // Last section without trailing newline
    try std.testing.expectEqual(1, sections[3].entry_groups.len);
    try std.testing.expectEqualStrings("only_key", sections[3].entry_groups[0].pairs[0].key);
}

test "parseConfigFileFromPath reads a file from disk without error" {
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    const parsed = try parseConfigFileFromPath(
        &file_source,
        "data/default_settings.txt",
        allocator,
    );
    defer allocator.free(parsed.raw_text);
    defer freeParsedSections(parsed.sections, allocator);

    // Just verify we got sections — don't check specific content
    try std.testing.expect(parsed.sections.len > 0);
    for (parsed.sections) |section| {
        try std.testing.expect(section.header.len > 0);
    }
}

test "value conversion helpers" {
    try std.testing.expectEqual(42, asU32("42").?);
    try std.testing.expectEqual(null, asU32("abc"));

    try std.testing.expectEqual(-5, asI32("-5").?);
    try std.testing.expectEqual(null, asI32("xyz"));

    try std.testing.expectApproxEqAbs(0.5, asF32("0.5").?, 0.001);
    try std.testing.expectEqual(null, asF32("nope"));

    try std.testing.expectEqual(true, asBool("true").?);
    try std.testing.expectEqual(false, asBool("false").?);
    try std.testing.expectEqual(null, asBool("yes"));
}



test "parseConfigFile handles layout grids as raw lines" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Test Level
        \\
        \\Layout
        \\   1..
        \\ ..!..
        \\   ..=
        \\
        \\Enemies
        \\character_code 1
        \\name Skeleton
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    try std.testing.expectEqual(3, sections.len);

    // Layout section has raw lines, not entry groups
    try std.testing.expectEqualStrings("Layout", sections[1].header);
    try std.testing.expectEqual(0, sections[1].entry_groups.len);
    try std.testing.expectEqual(3, sections[1].raw_lines.len);
    try std.testing.expectEqualStrings("   1..", sections[1].raw_lines[0]);
    try std.testing.expectEqualStrings(" ..!..", sections[1].raw_lines[1]);
    try std.testing.expectEqualStrings("   ..=", sections[1].raw_lines[2]);

    // Enemies section has key-value pairs as normal
    try std.testing.expectEqualStrings("Enemies", sections[2].header);
    try std.testing.expectEqual(1, sections[2].entry_groups.len);
    try std.testing.expectEqualStrings("character_code", sections[2].entry_groups[0].pairs[0].key);
    try std.testing.expectEqualStrings("1", sections[2].entry_groups[0].pairs[0].value);
}

test "section headers only recognized after blank lines" {
    const allocator = std.testing.allocator;
    // "ABC" on line 3 should be a raw line, not a header, because
    // there's no blank line before it
    const raw_text =
        \\Layout
        \\ .A.
        \\ABC.
        \\ ...
        \\
        \\Metadata
        \\file_format_version 1
        \\name test
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    try std.testing.expectEqual(2, sections.len);

    // All lines including ABC should be raw lines in Layout
    try std.testing.expectEqualStrings("Layout", sections[0].header);
    try std.testing.expectEqual(3, sections[0].raw_lines.len);
    try std.testing.expectEqualStrings(" .A.", sections[0].raw_lines[0]);
    try std.testing.expectEqualStrings("ABC.", sections[0].raw_lines[1]);
    try std.testing.expectEqualStrings(" ...", sections[0].raw_lines[2]);

    // Metadata is a real section (after blank line)
    try std.testing.expectEqualStrings("Metadata", sections[1].header);
}

test "layout with blank rows and tricky characters preserves all content" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Layout
        \\...!...
        \\
        \\A.....A
        \\
        \\a.. ..a
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    try std.testing.expectEqual(1, sections.len);
    try std.testing.expectEqualStrings("Layout", sections[0].header);

    // 5 raw lines: 3 content rows + 2 blank rows (gaps in the level)
    try std.testing.expectEqual(5, sections[0].raw_lines.len);
    try std.testing.expectEqualStrings("...!...", sections[0].raw_lines[0]);
    try std.testing.expectEqualStrings("", sections[0].raw_lines[1]);
    try std.testing.expectEqualStrings("A.....A", sections[0].raw_lines[2]);
    try std.testing.expectEqualStrings("", sections[0].raw_lines[3]);
    try std.testing.expectEqualStrings("a.. ..a", sections[0].raw_lines[4]);

    // Nothing parsed as key-value or entry groups
    try std.testing.expectEqual(0, sections[0].entry_groups.len);
}














test "asColor parses hex color codes" {
    const red = asColor("#FF0000").?;
    try std.testing.expectEqual(255, red.r);
    try std.testing.expectEqual(0, red.g);
    try std.testing.expectEqual(0, red.b);

    const mixed = asColor("#1A2B3C").?;
    try std.testing.expectEqual(0x1A, mixed.r);
    try std.testing.expectEqual(0x2B, mixed.g);
    try std.testing.expectEqual(0x3C, mixed.b);

    // Invalid inputs
    try std.testing.expectEqual(null, asColor("FF0000")); // missing #
    try std.testing.expectEqual(null, asColor("#FFF")); // too short
    try std.testing.expectEqual(null, asColor("#GGGGGG")); // invalid hex digits
}





test "game_version is populated from the build seam" {
    // Verifies the build.zig version seam reaches code: YYYY.MM.<count>[-dirty].
    // Not asserting exact digits (they change per commit/date); just the shape.
    const version = build_info.game_version;
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.count(u8, version, ".") >= 2);
}




test "validateKeys: warns on unknown keys in level file sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config =
        \\Metadata
        \\file_format_version 1
        \\name Test Level
        \\chracter_code X
        \\
        \\Layout
        \\!.
        \\
        \\Enemies
        \\character_code 1
        \\name Skeleton
        \\chracter_code 1
        \\sprite skeleton_1
        \\
        \\Decorations
        \\character_code T
        \\sprite tree_1
        \\unknwon_key blah
        \\
    ;
    const sections = try parseConfigFile(config, allocator);
    var warnings: std.ArrayList([]const u8) = .empty;
    validateKeys(sections, level_key_map, "test/level_1.txt", allocator, &warnings);

    // chracter_code in Metadata (X) + chracter_code in Enemies + unknwon_key in Decorations.
    try std.testing.expectEqual(@as(usize, 3), warnings.items.len);

    // Each warning names the unknown key + section + file path.
    var found_chracter_metadata = false;
    var found_chracter_enemies = false;
    var found_unknown_deco = false;
    for (warnings.items) |warning| {
        if (std.mem.indexOf(u8, warning, "chracter_code") != null and std.mem.indexOf(u8, warning, "Metadata") != null)
            found_chracter_metadata = true;
        if (std.mem.indexOf(u8, warning, "chracter_code") != null and std.mem.indexOf(u8, warning, "Enemies") != null)
            found_chracter_enemies = true;
        if (std.mem.indexOf(u8, warning, "unknwon_key") != null and std.mem.indexOf(u8, warning, "Decorations") != null)
            found_unknown_deco = true;
    }
    try std.testing.expect(found_chracter_metadata);
    try std.testing.expect(found_chracter_enemies);
    try std.testing.expect(found_unknown_deco);
}

test "validateKeys: no warnings for valid keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config =
        \\Metadata
        \\file_format_version 1
        \\name Test Level
        \\color_wheel_index 3
        \\
        \\Layout
        \\!.
        \\
        \\Enemies
        \\character_code 1
        \\name Skeleton
        \\sprite skeleton_1
        \\max_health 20
        \\
    ;
    const sections = try parseConfigFile(config, allocator);
    var warnings: std.ArrayList([]const u8) = .empty;
    validateKeys(sections, level_key_map, "test/level_1.txt", allocator, &warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "validateKeys: no warnings for player save with CloneData" {
    // Regression guard: the CloneData section carries mission_uuid (the clone
    // key) alongside clone_name + materials + turns_to_complete. An earlier
    // whitelist omitted mission_uuid, so loading an autosave surfaced a
    // spurious unknown-key popup on Continue.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config =
        \\Metadata
        \\file_format_version 1
        \\
        \\Info
        \\player_name Test Player
        \\current_campaign first_mission
        \\current_hub starting_village
        \\turns 0
        \\deaths 0
        \\defeated_enemies 0
        \\skills_used 0
        \\wood_salvage 0
        \\metal_salvage 0
        \\leather_salvage 0
        \\cloth_salvage 0
        \\knowledge 0
        \\
        \\CloneData
        \\mission_uuid bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
        \\clone_name First Clone
        \\wood 10
        \\metal 20
        \\leather 5
        \\cloth 5
        \\knowledge 0
        \\turns_to_complete 15
    ;
    const sections = try parseConfigFile(config, allocator);
    var warnings: std.ArrayList([]const u8) = .empty;
    validateKeys(sections, player_save_key_map, "saves/autosave.txt", allocator, &warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}
