//! Config file parser + all loaders + the save/session-log writers. CamelCase
//! sections / snake_case keys / raw layout grids (see AGENTS → Config File
//! Format). Each loader validates `file_format_version` as a hard gate
//! (`validateFileFormatVersion`) then parses into `types.*`. Owns decoration
//! footprint/anchor validation, the editor dedup (`buildEditorMission`),
//! editor level instantiation, the session-log comptime-generic serializer/
//! deserializer (`writeEventLog`/`loadEventLog`), and the `free*` helpers for
//! test ownership.

const std = @import("std");
const types = @import("types.zig");
const build_info = @import("build_info");
const events_mod = @import("events.zig");
const file_source_mod = @import("file_source.zig");
const sprite_metadata = @import("generated_sprite_metadata");

const FileSource = file_source_mod.FileSource;

/// PNG signature (first 8 bytes) for validating image bytes before reading the
/// IHDR chunk.
const png_signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Parse pixel dimensions from a PNG file's raw bytes by reading the IHDR
/// chunk (big-endian u32 width/height at byte offset 16/20). Returns null if
/// the bytes are too short or don't start with the PNG signature. Used at
/// runtime for custom (non-shipped) sprite PNGs; shipped sprites resolve from
/// the comptime `generated_sprite_metadata` table instead.
fn parsePngDimensions(bytes: []const u8) ?types.Vector2 {
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[0..8], &png_signature)) return null;
    const width: i32 = @intCast(std.mem.readInt(u32, bytes[16..20], .big));
    const height: i32 = @intCast(std.mem.readInt(u32, bytes[20..24], .big));
    return .{ .x = width, .y = height };
}

/// Resolve a sprite's pixel dimensions. Shipped sprites (in the comptime
/// `generated_sprite_metadata` table) resolve with zero I/O. Custom sprites
/// fall back to reading the PNG via `file_source` and parsing its IHDR. Panics
/// if the dims can't be resolved — a level referencing a sprite with no known
/// dims is a bug (shipped art is always in the table; custom art must be
/// resident in the file source before the level loads).
fn resolveSpriteDimensions(
    sprite_id: []const u8,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
) types.Vector2 {
    // 1. Shipped sprite → comptime table (no I/O).
    if (sprite_metadata.map.get(sprite_id)) |dims_str| {
        return parseDimsString(dims_str);
    }

    // 2. Custom sprite → read PNG bytes via file source, parse IHDR.
    if (file_source) |source| {
        const path = std.fmt.allocPrint(allocator, "assets/{s}.png", .{sprite_id}) catch
            @panic("failed to build sprite path for dims resolution");
        defer allocator.free(path);
        const bytes = source.readFile(allocator, path) catch
            @panic("failed to read sprite PNG for dims resolution");
        defer allocator.free(bytes);
        return parsePngDimensions(bytes) orelse
            @panic("sprite PNG is not a valid PNG");
    }

    @panic("cannot resolve sprite dimensions: not a shipped sprite and no file source");
}

/// Parse a `"w h"` string (as emitted by generated_sprite_metadata.zig) into a
/// Vector2. Panics on malformed input — the table is build-generated, so a
/// bad value is a build bug.
fn parseDimsString(dims_str: []const u8) types.Vector2 {
    var it = std.mem.tokenizeScalar(u8, dims_str, ' ');
    const width_str = it.next() orelse @panic("malformed sprite dims string");
    const height_str = it.next() orelse @panic("malformed sprite dims string");
    return .{
        .x = asI32(width_str) orelse @panic("malformed sprite dims width"),
        .y = asI32(height_str) orelse @panic("malformed sprite dims height"),
    };
}

const Event = events_mod.Event;

/// Monotonic schema version for the session-log file format ("can this parser
/// read the file?"). Bump on any breaking change to the EventLog layout.
pub const session_log_file_format_version: u32 = 1;

/// Monotonic schema versions for each config-file type. Bump on any breaking
/// change to that file's layout. The loader validates the file's
/// `file_format_version` (in its Metadata/Info section) against the expected
/// constant and returns `error.UnsupportedFileFormatVersion` on mismatch — a
/// HARD gate. The version is validate-and-discard (not stored on the parsed
/// type): it's a parse-time compatibility check, not runtime state. The save
/// writer emits the current constant. See AGENTS → Versioning.
pub const level_file_format_version: u32 = 1;
pub const hub_file_format_version: u32 = 1;
pub const mission_file_format_version: u32 = 1;
pub const campaign_file_format_version: u32 = 1;
pub const player_save_file_format_version: u32 = 1;
pub const settings_file_format_version: u32 = 1;
pub const color_themes_file_format_version: u32 = 1;
pub const player_loadout_file_format_version: u32 = 1;
pub const decorations_file_format_version: u32 = 1;

// ── Balance bounds (parse-time, uniform across all content) ──
//
// Every parsed gear-stat field routes through `boundedU32`, which clamps
// out-of-range values to the max and appends a warning (so the game stays
// playable + the author is told). See AGENTS → Custom Missions → Balance
// bounds. Entity base stats (max_health, defense, speed, aggro_range) are
// NOT bounded — only gear stats.
pub const max_weapon_damage: u32 = 10;
pub const max_spell_damage: u32 = 10;
pub const max_health_bonus: u32 = 10;
pub const max_defense_bonus: u32 = 5;
pub const max_gloves_damage: u32 = 5;
pub const max_pickup_radius: u32 = 5;
pub const max_boots_speed: u32 = 2;

const Settings = types.Settings;
const Level = types.Level;
const Hub = types.Hub;
const Campaign = types.Campaign;
const Mission = types.Mission;
const PlayerData = types.PlayerData;
const WeaponType = types.WeaponType;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const Color = types.Color;
const ColorGradient = types.ColorGradient;
const ColorThemeDefinitions = types.ColorThemeDefinitions;
const ActiveColorTheme = types.ActiveColorTheme;
const MaterialType = types.MaterialType;
const SalvageSplit = types.SalvageSplit;
const SalvageDefinition = types.SalvageDefinition;
const SalvageDefinitions = types.SalvageDefinitions;

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
/// it into sections. See AGENTS.md "File System & IO".
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
fn validateSections(
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
fn validateFileFormatVersion(
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
/// parse failure (same as `asU32`). See AGENTS → Custom Missions → Balance
/// bounds.
fn boundedU32(
    value_str: []const u8,
    max: u32,
    field_name: []const u8,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) u32 {
    const parsed = asU32(value_str) orelse return 0;
    if (parsed > max) {
        if (warnings) |w| {
            const msg = std.fmt.allocPrint(allocator, "Value {d} for '{s}' in {s} exceeds max {d}; clamped", .{
                parsed, field_name, file_path, max,
            }) catch return max;
            w.append(allocator, msg) catch return max;
        }
        return max;
    }
    return parsed;
}

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
fn findSection(
    sections: []const Section,
    header: []const u8,
) ?Section {
    for (sections) |section| {
        if (std.mem.eql(u8, section.header, header)) return section;
    }
    return null;
}

/// Find a value by key in a single entry group. Returns null if not found.
fn findValue(
    pairs: []const KeyValuePair,
    key: []const u8,
) ?[]const u8 {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, key)) return pair.value;
    }
    return null;
}

/// Convert a string to any enum value by matching field names.
fn parseEnum(
    comptime E: type,
    value: []const u8,
) ?E {
    const fields = @typeInfo(E).@"enum".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

const settings_sections = [_][]const u8{ "Metadata", "Audio", "Display", "Gameplay", "InputBindings" };
const weapon_type_sections = [_][]const u8{"Skills"};
const level_sections = [_][]const u8{ "Metadata", "Layout", "Enemies", "Decorations", "Items" };
const hub_sections = [_][]const u8{ "Metadata", "Layout", "NPCs", "Decorations", "Exits" };
const campaign_sections = [_][]const u8{"Metadata"};
const mission_sections = [_][]const u8{"Metadata"};
const decoration_registry_sections = [_][]const u8{ "Metadata", "Decorations" };
const player_save_sections = [_][]const u8{
    "Metadata",       "Info",           "DiscoveredHubs",  "UnlockedSkills", "MainHandWeapon",
    "OffHandWeapon",  "Amulet",          "Coat",           "Gloves",
    "Pants",          "Boots",           "Inventory",      "UtilitySkills",
    "CloneData",
};

// ============================================================
// Key validation (approach A — see AGENTS → Error Handling)
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
/// layout char). See AGENTS → Decorations & Footprint.
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

const mission_metadata_keys = [_][]const u8{ "file_format_version", "name", "start_hub", "end_hub", "level_count" };

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

const settings_audio_keys = [_][]const u8{ "music_volume", "sound_effects_volume" };
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
// slot_4..slot_8. CloneData entries carry clone_name + turn count +
// materials. DiscoveredHubs entries carry `name`.

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
    "clone_name", "turns_to_complete",
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

pub fn loadSettings(
    sections: []const Section,
    allocator: std.mem.Allocator,
) !Settings {
    try validateSections(sections, &settings_sections);
    try validateFileFormatVersion(sections, "Metadata", settings_file_format_version);
    var settings: Settings = .{ .input_bindings = &.{} };

    // Audio
    if (findSection(sections, "Audio")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "music_volume")) |value| {
                settings.music_volume = asF32(value) orelse settings.music_volume;
            }
            if (findValue(pairs, "sound_effects_volume")) |value| {
                settings.sound_effects_volume = asF32(value) orelse settings.sound_effects_volume;
            }
        }
    }

    // Display
    if (findSection(sections, "Display")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "vsync")) |value| {
                settings.vsync = asBool(value) orelse settings.vsync;
            }
            if (findValue(pairs, "render_fps_cap")) |value| {
                settings.render_fps_cap = asU32(value) orelse settings.render_fps_cap;
            }
            if (findValue(pairs, "camera_zoom")) |value| {
                settings.camera_zoom = asF32(value) orelse settings.camera_zoom;
            }
            if (findValue(pairs, "animation_fps")) |value| {
                settings.animation_fps = asU32(value) orelse settings.animation_fps;
            }
        }
    }

    // Gameplay
    if (findSection(sections, "Gameplay")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "auto_skip_attack_step_out_of_combat")) |value| {
                settings.auto_skip_attack_step_out_of_combat = asBool(value) orelse settings.auto_skip_attack_step_out_of_combat;
            }
            if (findValue(pairs, "auto_target_at_cursor")) |value| {
                settings.auto_target_at_cursor = asBool(value) orelse settings.auto_target_at_cursor;
            }
            if (findValue(pairs, "player_color_index")) |value| {
                settings.player_color_index = asU32(value) orelse settings.player_color_index;
            }
        }
    }

    // InputBindings
    if (findSection(sections, "InputBindings")) |section| {
        var bindings: std.ArrayList(types.InputBinding) = .empty;

        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const input_type = findValue(pairs, "input_type") orelse continue;
            const input_name = findValue(pairs, "input_name") orelse continue;
            const action_string = findValue(pairs, "action") orelse continue;
            const action = parseEnum(types.Action,action_string) orelse continue;

            const InputTypeId = enum { key, mouse_button, gamepad_button };
            const input_type_id = parseEnum(InputTypeId, input_type) orelse continue;

            const input: types.RawInput = switch (input_type_id) {
                .key => .{ .key = input_name },
                .mouse_button => .{ .mouse_button = input_name },
                .gamepad_button => .{ .gamepad_button = input_name },
            };

            const modifiers = types.Modifiers{
                .ctrl = asBool(findValue(pairs, "ctrl") orelse "false") orelse false,
                .shift = asBool(findValue(pairs, "shift") orelse "false") orelse false,
                .alt = asBool(findValue(pairs, "alt") orelse "false") orelse false,
            };

            try bindings.append(allocator, .{
                .input = input,
                .modifiers = modifiers,
                .action = action,
            });
        }

        settings.input_bindings = try bindings.toOwnedSlice(allocator);
    }

    return settings;
}

/// Parse an entity definition (the shared body of an Enemies entry, a player
/// loadout, or an editor EntityTypeDef template) from a set of key-value
/// pairs. `team` is set by the caller (enemies = 1, player = 0) since the
/// format doesn't carry it. `default_name` / `default_sprite` are used when
/// the pairs don't specify name/sprite (player loadout defaults to
/// "Player"/"player"). current_health is set to max_health (reset by
/// instantiateEditorLevel for placements). Utility skills are read from
/// `slot_4`..`slot_8` keys (matching the save format), so the player loadout
/// carries its bar; enemy types can too if present.
pub fn parseEntityDefinition(
    pairs: []const KeyValuePair,
    team: u32,
    default_name: []const u8,
    default_sprite: []const u8,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) types.Entity {
    var entity: types.Entity = .{ .team = team };
    entity.name = findValue(pairs, "name") orelse default_name;
    entity.sprite = findValue(pairs, "sprite") orelse default_sprite;
    if (findValue(pairs, "color_index")) |value| {
        entity.color_index = asU32(value) orelse 0;
    }
    if (findValue(pairs, "displays_weapons")) |value| {
        entity.displays_weapons = asBool(value) orelse true;
    }
    if (findValue(pairs, "max_health")) |value| {
        entity.max_health = asU32(value) orelse 20;
        entity.current_health = entity.max_health;
    }
    if (findValue(pairs, "defense")) |value| entity.defense = asU32(value) orelse 0;
    if (findValue(pairs, "speed")) |value| entity.speed = asU32(value) orelse 1;
    if (findValue(pairs, "aggro_range")) |value| entity.aggro_range = asU32(value) orelse 3;

    // Main hand weapon
    if (findValue(pairs, "main_hand_weapon_name")) |name| {
        entity.main_hand_weapon = .{
            .name = name,
            .weapon_type = if (findValue(pairs, "main_hand_weapon_type")) |value| parseEnum(types.WeaponType, value) orelse .sword else .sword,
            .weapon_damage = if (findValue(pairs, "main_hand_weapon_damage")) |value| boundedU32(value, max_weapon_damage, "main_hand_weapon_damage", file_path, warnings, allocator) else 0,
        };
    }
    // Off hand weapon
    if (findValue(pairs, "off_hand_weapon_name")) |name| {
        entity.off_hand_weapon = .{
            .name = name,
            .weapon_type = if (findValue(pairs, "off_hand_weapon_type")) |value| parseEnum(types.WeaponType, value) orelse .sword else .sword,
            .weapon_damage = if (findValue(pairs, "off_hand_weapon_damage")) |value| boundedU32(value, max_weapon_damage, "off_hand_weapon_damage", file_path, warnings, allocator) else 0,
        };
    }
    // Gear
    if (findValue(pairs, "amulet_name")) |name| {
        entity.amulet = .{ .name = name, .spell_damage = if (findValue(pairs, "amulet_spell_damage")) |value| boundedU32(value, max_spell_damage, "amulet_spell_damage", file_path, warnings, allocator) else 0 };
    }
    if (findValue(pairs, "coat_name")) |name| {
        entity.coat = .{
            .name = name,
            .defense_bonus = if (findValue(pairs, "coat_defense_bonus")) |value| boundedU32(value, max_defense_bonus, "coat_defense_bonus", file_path, warnings, allocator) else 0,
            .health_bonus = if (findValue(pairs, "coat_health_bonus")) |value| boundedU32(value, max_health_bonus, "coat_health_bonus", file_path, warnings, allocator) else 0,
        };
    }
    if (findValue(pairs, "gloves_name")) |name| {
        entity.gloves = .{
            .name = name,
            .damage_bonus = if (findValue(pairs, "gloves_damage_bonus")) |value| boundedU32(value, max_gloves_damage, "gloves_damage_bonus", file_path, warnings, allocator) else 0,
            .health_bonus = if (findValue(pairs, "gloves_health_bonus")) |value| boundedU32(value, max_health_bonus, "gloves_health_bonus", file_path, warnings, allocator) else 0,
        };
    }
    if (findValue(pairs, "pants_name")) |name| {
        entity.pants = .{
            .name = name,
            .pickup_radius_bonus = if (findValue(pairs, "pants_pickup_radius_bonus")) |value| boundedU32(value, max_pickup_radius, "pants_pickup_radius_bonus", file_path, warnings, allocator) else 0,
            .health_bonus = if (findValue(pairs, "pants_health_bonus")) |value| boundedU32(value, max_health_bonus, "pants_health_bonus", file_path, warnings, allocator) else 0,
        };
    }
    if (findValue(pairs, "boots_name")) |name| {
        entity.boots = .{
            .name = name,
            .speed_bonus = if (findValue(pairs, "boots_speed_bonus")) |value| boundedU32(value, max_boots_speed, "boots_speed_bonus", file_path, warnings, allocator) else 0,
            .health_bonus = if (findValue(pairs, "boots_health_bonus")) |value| boundedU32(value, max_health_bonus, "boots_health_bonus", file_path, warnings, allocator) else 0,
        };
    }

    // Utility skills (slot_4..slot_8, matching the save format). Enemy types
    // can carry a bar if present; the player loadout normally does.
    var slot_key_buf: [16]u8 = undefined;
    for (0..types.utility_skill_count) |i| {
        const key = std.fmt.bufPrint(&slot_key_buf, "slot_{d}", .{i + 4}) catch continue;
        if (findValue(pairs, key)) |value| {
            if (parseEnum(types.SkillId, value)) |skill_id| {
                entity.equipped_utility_skills[i] = skill_id;
            }
        }
    }

    // Overlay layers: `layer` delimiter starts a sub-group whose following
    // `sprite`/`color_index` pairs belong to it (same convention as
    // decorations). Layers share the entity's fixed frame, so no dims to
    // resolve or validate.
    var layers: std.ArrayList(types.EntityLayer) = .empty;
    var current_layer_sprite: ?[]const u8 = null;
    var current_layer_color: u32 = 0;
    var in_layer = false;
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, "layer")) {
            if (in_layer) {
                if (current_layer_sprite) |layer_sprite| {
                    layers.append(allocator, .{
                        .sprite = layer_sprite,
                        .color_index = current_layer_color,
                    }) catch @panic("failed to append entity layer");
                }
            }
            in_layer = true;
            current_layer_sprite = null;
            current_layer_color = 0;
            continue;
        }
        if (in_layer) {
            if (std.mem.eql(u8, pair.key, "sprite")) {
                current_layer_sprite = pair.value;
            } else if (std.mem.eql(u8, pair.key, "color_index")) {
                current_layer_color = asU32(pair.value) orelse 0;
            }
        }
    }
    if (in_layer) {
        if (current_layer_sprite) |layer_sprite| {
            layers.append(allocator, .{
                .sprite = layer_sprite,
                .color_index = current_layer_color,
            }) catch @panic("failed to append entity layer");
        }
    }
    entity.layers = layers.toOwnedSlice(allocator) catch @panic("failed to own entity layers");

    return entity;
}

/// Load a player start loadout from a player.txt's parsed sections. The player
/// is team 0, defaults name "Player" / sprite "player". Reuses
/// parseEntityDefinition so the loadout has the same field set as an enemy type
/// template.
pub fn loadPlayerLoadout(
    sections: []const Section,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !types.Entity {
    try validateFileFormatVersion(sections, "Metadata", player_loadout_file_format_version);
    for (sections) |section| {
        for (section.entry_groups) |group| {
            return parseEntityDefinition(group.pairs, 0, "Player", "player", allocator, file_path, warnings);
        }
    }
    return .{ .name = "Player", .sprite = "player", .team = 0 };
}

/// Compare two entity definitions for palette dedup. Compares the DEFINITION
/// fields only (name, sprite, team, stats, weapons, gear, utility skills) —
/// NOT runtime fields (position, current_health, is_active, momentum, stun,
/// cooldowns, active_effects, inventory), which are reset on instantiate and
/// meaningless on a template. Slice fields (names) compared by content.
pub fn entityDefinitionsEqual(a: types.Entity, b: types.Entity) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (!std.mem.eql(u8, a.sprite, b.sprite)) return false;
    if (a.team != b.team) return false;
    if (a.max_health != b.max_health) return false;
    if (a.defense != b.defense) return false;
    if (a.speed != b.speed) return false;
    if (a.aggro_range != b.aggro_range) return false;
    // Weapons (optionals of structs with a name slice + scalar fields).
    if (!optionalWeaponEqual(a.main_hand_weapon, b.main_hand_weapon)) return false;
    if (!optionalWeaponEqual(a.off_hand_weapon, b.off_hand_weapon)) return false;
    if (!optionalAmuletEqual(a.amulet, b.amulet)) return false;
    if (!optionalCoatEqual(a.coat, b.coat)) return false;
    if (!optionalGlovesEqual(a.gloves, b.gloves)) return false;
    if (!optionalPantsEqual(a.pants, b.pants)) return false;
    if (!optionalBootsEqual(a.boots, b.boots)) return false;
    if (a.color_index != b.color_index) return false;
    if (a.displays_weapons != b.displays_weapons) return false;
    if (!entityLayersEqual(a.layers, b.layers)) return false;
    return std.mem.eql(?types.SkillId, a.equipped_utility_skills[0..], b.equipped_utility_skills[0..]);
}

fn entityLayersEqual(a: []const types.EntityLayer, b: []const types.EntityLayer) bool {
    if (a.len != b.len) return false;
    for (a, b) |la, lb| {
        if (!std.mem.eql(u8, la.sprite, lb.sprite)) return false;
        if (la.color_index != lb.color_index) return false;
    }
    return true;
}

fn optionalWeaponEqual(a: ?types.Weapon, b: ?types.Weapon) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const ax = a.?;
    const bx = b.?;
    return std.mem.eql(u8, ax.name, bx.name) and ax.weapon_type == bx.weapon_type and ax.weapon_damage == bx.weapon_damage;
}
fn optionalAmuletEqual(a: ?types.Amulet, b: ?types.Amulet) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?.name, b.?.name) and a.?.spell_damage == b.?.spell_damage;
}
fn optionalCoatEqual(a: ?types.Coat, b: ?types.Coat) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?.name, b.?.name) and a.?.defense_bonus == b.?.defense_bonus and a.?.health_bonus == b.?.health_bonus;
}
fn optionalGlovesEqual(a: ?types.Gloves, b: ?types.Gloves) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?.name, b.?.name) and a.?.damage_bonus == b.?.damage_bonus and a.?.health_bonus == b.?.health_bonus;
}
fn optionalPantsEqual(a: ?types.Pants, b: ?types.Pants) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?.name, b.?.name) and a.?.pickup_radius_bonus == b.?.pickup_radius_bonus and a.?.health_bonus == b.?.health_bonus;
}
fn optionalBootsEqual(a: ?types.Boots, b: ?types.Boots) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?.name, b.?.name) and a.?.speed_bonus == b.?.speed_bonus and a.?.health_bonus == b.?.health_bonus;
}

/// Compare two decoration definitions for palette dedup (sprite + footprint
/// + color_index + layers by content).
pub fn decorationDefinitionsEqual(a: types.Decoration, b: types.Decoration) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.footprint.len != b.footprint.len) return false;
    for (a.footprint, b.footprint) |fa, fb| {
        if (fa.x != fb.x or fa.y != fb.y) return false;
    }
    if (a.color_index != b.color_index) return false;
    return decorationLayersEqual(a.layers, b.layers);
}

/// Compare two decoration layer slices for palette dedup.
pub fn decorationLayersEqual(a: []const types.DecorationLayer, b: []const types.DecorationLayer) bool {
    if (a.len != b.len) return false;
    for (a, b) |la, lb| {
        if (!std.mem.eql(u8, la.sprite, lb.sprite)) return false;
        if (la.color_index != lb.color_index) return false;
    }
    return true;
}

/// Build an Editor session from already-parsed mission/player/level sections.
/// Pure (no file I/O) — the caller (open_editor handler) reads via
/// history.readReconstructionFile so the reconstruction cache makes undo
/// replay deterministic. Dedups the levels' inline entity/decoration
/// definitions into a shared palette (entity_types / decoration_types).
/// The result is reference-based (EditorLevel + placements); save flattens
/// back to the existing inline format. Unused palette types are lost on
/// editor close (accepted). See AGENTS → Architecture → Level Editor.
pub fn buildEditorMission(
    mission: types.Mission,
    player_entity: types.Entity,
    parsed_level_sections: []const []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !types.Editor {
    var entity_types: std.ArrayList(types.EntityTypeDef) = .empty;
    var decoration_types: std.ArrayList(types.DecorationTypeDef) = .empty;
    var editor_levels: std.ArrayList(types.EditorLevel) = .empty;

    for (parsed_level_sections) |sections| {
        const level = try loadLevel(sections, file_source, allocator, file_path, warnings);

        // Entity placements: entity 0 is the player (skip — loadout comes from
        // player_def, spawn is player_start). entities 1..N dedup into the palette.
        var placements: std.ArrayList(types.EntityPlacement) = .empty;
        for (level.entities[1..]) |entity| {
            var type_id: ?u32 = null;
            for (entity_types.items, 0..) |et, et_index| {
                if (entityDefinitionsEqual(et.template, entity)) {
                    type_id = @intCast(et_index);
                    break;
                }
            }
            if (type_id == null) {
                type_id = @intCast(entity_types.items.len);
                entity_types.append(allocator, .{
                    .id = entity.name,
                    .template = entity,
                }) catch @panic("failed to append entity type");
            }
            placements.append(allocator, .{
                .type_id = type_id.?,
                .position = entity.position,
            }) catch @panic("failed to append entity placement");
        }

        // Decoration placements: dedup by sprite + footprint + color_index +
        // layers (the full visual identity).
        var deco_placements: std.ArrayList(types.DecorationPlacement) = .empty;
        for (level.decorations) |decoration| {
            var type_id: ?u32 = null;
            for (decoration_types.items, 0..) |dt, dt_index| {
                if (std.mem.eql(u8, dt.sprite, decoration.name) and
                    decorationFootprintEqual(dt.footprint, decoration.footprint) and
                    dt.color_index == decoration.color_index and
                    decorationLayersEqual(dt.layers, decoration.layers))
                {
                    type_id = @intCast(dt_index);
                    break;
                }
            }
            if (type_id == null) {
                type_id = @intCast(decoration_types.items.len);
                const fp = allocator.dupe(types.Vector2, decoration.footprint) catch @panic("failed to dupe footprint");
                const ly = allocator.dupe(types.DecorationLayer, decoration.layers) catch @panic("failed to dupe layers");
                decoration_types.append(allocator, .{
                    .id = decoration.name,
                    .sprite = decoration.name,
                    .footprint = fp,
                    .pixel_dims = decoration.pixel_dims,
                    .color_index = decoration.color_index,
                    .layers = ly,
                }) catch @panic("failed to append decoration type");
            }
            deco_placements.append(allocator, .{
                .type_id = type_id.?,
                .position = decoration.position,
            }) catch @panic("failed to append decoration placement");
        }

        editor_levels.append(allocator, .{
            .name = level.name,
            .color_wheel_index = level.color_wheel_index,
            .level_tiles = level.level_tiles,
            .player_start = level.entities[0].position,
            .level_end = level.level_end,
            .entity_placements = placements.items,
            .decoration_placements = deco_placements.items,
        }) catch @panic("failed to append editor level");
    }

    return .{
        .mission = mission,
        .levels = editor_levels.items,
        .entity_types = entity_types.items,
        .decoration_types = decoration_types.items,
        .player_def = .{ .id = "Player", .template = player_entity },
    };
}

fn decorationFootprintEqual(a: []const types.Vector2, b: []const types.Vector2) bool {
    if (a.len != b.len) return false;
    for (a, b) |fa, fb| {
        if (fa.x != fb.x or fa.y != fb.y) return false;
    }
    return true;
}

/// Instantiate a concrete gameplay Level from an EditorLevel + the editor's
/// palette + player_def. Entity 0 is the player (from player_def at
/// player_start); each placement becomes an entity from its palette type at
/// the placement's position. Runtime fields are reset (current_health =
/// max_health, is_active = false, momentum/stun/cooldowns/effects/inventory
/// zeroed/empty). The gameplay engine runs on the result unmodified.
pub fn instantiateEditorLevel(
    editor: types.Editor,
    level_index: usize,
    allocator: std.mem.Allocator,
) types.Level {
    const editor_level = editor.levels[level_index];
    var entities: std.ArrayList(types.Entity) = .empty;

    // Entity 0: the player.
    var player = editor.player_def.template;
    resetRuntimeFields(&player);
    player.position = editor_level.player_start;
    entities.append(allocator, player) catch @panic("failed to append player entity");

    // Enemy placements.
    for (editor_level.entity_placements) |placement| {
        var entity = editor.entity_types[placement.type_id].template;
        resetRuntimeFields(&entity);
        entity.position = placement.position;
        entities.append(allocator, entity) catch @panic("failed to append entity");
    }

    // Decorations (concrete, for rendering).
    var decorations: std.ArrayList(types.Decoration) = .empty;
    for (editor_level.decoration_placements) |placement| {
        const dt = editor.decoration_types[placement.type_id];
        decorations.append(allocator, .{
            .name = dt.sprite,
            .position = placement.position,
            .footprint = dt.footprint,
            .pixel_dims = dt.pixel_dims,
            .color_index = dt.color_index,
            .layers = dt.layers,
        }) catch @panic("failed to append decoration");
    }

    return .{
        .name = editor_level.name,
        .color_wheel_index = editor_level.color_wheel_index,
        .level_tiles = editor_level.level_tiles,
        .entities = entities.items,
        .decorations = decorations.items,
        .ground_items = &.{},
        .level_end = editor_level.level_end,
    };
}

/// Reset an entity's runtime fields to a fresh-start state (used by
/// instantiateEditorLevel). Definition fields (stats, weapons, gear, skills)
/// are kept; only per-playthrough state is zeroed.
fn resetRuntimeFields(entity: *types.Entity) void {
    entity.current_health = entity.max_health;
    entity.momentum = 0;
    entity.is_active = false;
    entity.stun_duration = 0;
    entity.skill_cooldowns = std.EnumArray(types.SkillId, u32).initFill(0);
    entity.active_effects = &.{};
    entity.inventory = .{};
}

/// A decoration definition parsed from a Decorations section entry group,
/// keyed by character code (like enemy/item definitions). Carries the
/// sprite-grid footprint list, resolved pixel dims, color index, and overlay
/// layers so the layout walk can build `Decoration` values without re-reading
/// the section. See AGENTS.md "Decorations & Footprint".
const DecorationDefinition = struct {
    sprite: []const u8,
    footprint: []const types.Vector2, // sprite-grid coords
    pixel_dims: types.Vector2,
    color_index: u32 = 0,
    layers: []const types.DecorationLayer = &.{},
};

/// Derive the anchor (bottom-most-then-left-most) from a sprite-grid footprint.
/// Returns null if the footprint is empty — the caller panics (a decoration
/// with no footprint tiles is a malformed level).
fn decorationAnchor(footprint: []const types.Vector2) ?types.Vector2 {
    if (footprint.len == 0) return null;
    var anchor = footprint[0];
    for (footprint[1..]) |tile| {
        // Bottom-most = highest y (sprite-grid y increases downward). Tiebreak
        // by left-most = lowest x. This is the convention from AGENTS →
        // Decorations & Footprint.
        if (tile.y > anchor.y or (tile.y == anchor.y and tile.x < anchor.x)) {
            anchor = tile;
        }
    }
    return anchor;
}

/// Validate a decoration's footprint against its sprite bbox and the level/hub
/// tile set. Panics on violation (fail fast — see AGENTS → Error Handling):
///   - empty footprint (no anchor, no reserved tiles)
///   - footprint tile outside the sprite bbox
///   - a world footprint tile overlapping a level/hub tile (placement invariant)
fn validateDecorationFootprint(
    decoration: types.Decoration,
    tile_set: *const std.AutoHashMap(types.Vector2, void),
) void {
    if (decoration.footprint.len == 0) {
        @panic("decoration has no footprint tiles");
    }
    const tiles_w: i32 = @divTrunc(decoration.pixel_dims.x, 256);
    const tiles_h: i32 = @divTrunc(decoration.pixel_dims.y, 256);
    const anchor = decorationAnchor(decoration.footprint) orelse
        @panic("decoration has no footprint anchor");
    for (decoration.footprint) |fp_grid| {
        // Footprint must be within the sprite bbox.
        if (fp_grid.x < 0 or fp_grid.x >= tiles_w or fp_grid.y < 0 or fp_grid.y >= tiles_h) {
            @panic("decoration footprint tile is outside the sprite bbox");
        }
        // World footprint tile = anchor world pos + (fp_grid - anchor_grid).
        const world_tile = types.Vector2{
            .x = decoration.position.x + (fp_grid.x - anchor.x),
            .y = decoration.position.y + (fp_grid.y - anchor.y),
        };
        if (tile_set.contains(world_tile)) {
            @panic("decoration footprint overlaps a level/hub tile");
        }
    }
}

/// Parse one decoration entry's pairs (sprite / color_index / footprint /
/// layers) into a `DecorationDefinition`. Shared by the per-level inline
/// parser (keyed by `character_code`) and the registry parser (no
/// `character_code`). The `character_code` key, if present, is ignored here —
/// the caller handles it. See `parseDecorationDefinitions` for the entry
/// shape + `layer` delimiter semantics.
fn parseDecorationEntry(
    pairs: []const KeyValuePair,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
) DecorationDefinition {
    const base_sprite = findValue(pairs, "sprite") orelse &.{};
    const base_color_index = asU32(findValue(pairs, "color_index") orelse "0") orelse 0;
    const base_pixel_dims = resolveDecorationSpriteDimensions(base_sprite, file_source, allocator);

    // Collect base footprint + parse layer sub-groups. The pairs list is
    // flat; a `layer` key delimits a new sub-group whose following
    // `sprite`/`color_index` pairs belong to it.
    var footprint: std.ArrayList(types.Vector2) = .empty;
    var layers: std.ArrayList(types.DecorationLayer) = .empty;
    var current_layer_sprite: ?[]const u8 = null;
    var current_layer_color: u32 = 0;
    var in_layer = false;

    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, "layer")) {
            // Finish the previous layer sub-group (if any).
            if (in_layer) finishLayer(
                current_layer_sprite,
                current_layer_color,
                base_pixel_dims,
                file_source,
                allocator,
                &layers,
            );
            // Start a new layer sub-group.
            in_layer = true;
            current_layer_sprite = null;
            current_layer_color = 0;
            continue;
        }

        if (in_layer) {
            if (std.mem.eql(u8, pair.key, "sprite")) {
                current_layer_sprite = pair.value;
            } else if (std.mem.eql(u8, pair.key, "color_index")) {
                current_layer_color = asU32(pair.value) orelse 0;
            }
            // Other keys (footprint, character_code) are ignored inside a
            // layer sub-group.
        } else {
            // Base-level fields.
            if (std.mem.eql(u8, pair.key, "footprint")) {
                const coords = parseVector2Pair(pair.value) orelse
                    @panic("malformed footprint coordinate line");
                footprint.append(allocator, coords) catch @panic("failed to append footprint");
            }
            // character_code / sprite / color_index are already handled
            // above; ignore them here.
        }
    }
    // Finish the last layer sub-group (if the entry ended mid-layer).
    if (in_layer) finishLayer(
        current_layer_sprite,
        current_layer_color,
        base_pixel_dims,
        file_source,
        allocator,
        &layers,
    );

    return .{
        .sprite = base_sprite,
        .footprint = footprint.toOwnedSlice(allocator) catch @panic("failed to own footprint slice"),
        .pixel_dims = base_pixel_dims,
        .color_index = base_color_index,
        .layers = layers.toOwnedSlice(allocator) catch @panic("failed to own layers slice"),
    };
}

/// Resolve a pending layer sub-group's sprite + color into a `DecorationLayer`,
/// validate its pixel dims match the base, and append it. Shared by the two
/// layer-finish sites in `parseDecorationEntry` (mid-entry `layer` delimiter
/// + end-of-entry). No-op (appends nothing) when the layer had no `sprite`.
fn finishLayer(
    layer_sprite: ?[]const u8,
    layer_color: u32,
    base_pixel_dims: types.Vector2,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    layers: *std.ArrayList(types.DecorationLayer),
) void {
    if (layer_sprite) |sprite| {
        const layer_dims = resolveDecorationSpriteDimensions(sprite, file_source, allocator);
        if (layer_dims.x != base_pixel_dims.x or layer_dims.y != base_pixel_dims.y) {
            @panic("decoration layer sprite must be the same pixel dimensions as the base");
        }
        layers.append(allocator, .{
            .sprite = sprite,
            .color_index = layer_color,
            .pixel_dims = layer_dims,
        }) catch @panic("failed to append decoration layer");
    }
}

/// Parse all decoration definitions from a level/hub's Decorations section
/// into a hashmap keyed by character code. Each entry group has:
///   character_code X  (single char)
///   sprite <name>        (base sprite)
///   color_index N        (optional, default 0 — world gradient index)
///   footprint x y        (one or more lines, sprite-grid coords)
///   layer                (delimiter — starts a layer sub-group)
///     sprite <name>      (layer sprite, must be same pixel dims as base)
///     color_index N      (layer color index)
/// A `layer` line is a delimiter: the following `sprite`/`color_index` pairs
/// belong to that layer until the next `layer` or end of entry. Pixel dims
/// are resolved from the comptime sprite-metadata table (shipped) or the file
/// source (custom); layer dims are validated == base dims at load.
fn parseDecorationDefinitions(
    sections: []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
) std.AutoHashMap(u8, DecorationDefinition) {
    var definitions = std.AutoHashMap(u8, DecorationDefinition).init(allocator);
    if (findSection(sections, "Decorations")) |section| {
        for (section.entry_groups) |group| {
            const code_string = findValue(group.pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;
            definitions.put(code_string[0], parseDecorationEntry(group.pairs, file_source, allocator)) catch
                @panic("failed to insert decoration definition");
        }
    }
    return definitions;
}

/// Load the decoration registry (`data/decorations.txt`) — one entry per
/// shipped decoration sprite, as editor-palette prefabs for "add new
/// decoration." Each entry has the same shape as a level's Decorations entry
/// MINUS `character_code` (registry entries are prefabs identified by sprite
/// stem, not placed by layout char). Returns `[]DecorationTypeDef` (the
/// editor palette type): `id` = sprite stem. Used ONLY by the editor; never
/// read during gameplay/replay (custom decorations carry their footprint
/// inline in the level file, sharing this parser path). See AGENTS →
/// Decorations & Footprint.
pub fn loadDecorationRegistry(
    sections: []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
) ![]types.DecorationTypeDef {
    try validateSections(sections, &decoration_registry_sections);
    try validateFileFormatVersion(sections, "Metadata", decorations_file_format_version);
    var list: std.ArrayList(types.DecorationTypeDef) = .empty;
    if (findSection(sections, "Decorations")) |section| {
        for (section.entry_groups) |group| {
            // Skip an empty group (no sprite) — e.g. a trailing blank-line
            // artifact. A real entry must have a `sprite` key.
            if (findValue(group.pairs, "sprite") == null) continue;
            const def = parseDecorationEntry(group.pairs, file_source, allocator);
            list.append(allocator, .{
                .id = def.sprite,
                .sprite = def.sprite,
                .footprint = def.footprint,
                .pixel_dims = def.pixel_dims,
                .color_index = def.color_index,
                .layers = def.layers,
            }) catch @panic("failed to append decoration registry entry");
        }
    }
    return list.toOwnedSlice(allocator) catch @panic("failed to own decoration registry slice");
}

/// Parse a `"x y"` pair of integers into a Vector2. Returns null on failure.
fn parseVector2Pair(value: []const u8) ?types.Vector2 {
    var it = std.mem.tokenizeScalar(u8, value, ' ');
    const x_str = it.next() orelse return null;
    const y_str = it.next() orelse return null;
    const x = asI32(x_str) orelse return null;
    const y = asI32(y_str) orelse return null;
    return .{ .x = x, .y = y };
}

/// Resolve a decoration sprite's pixel dimensions. Config stores the bare
/// stem (e.g. `tree_1`); the comptime sprite-metadata table is keyed by the
/// asset-relative path (`decorations/tree_1`), so this prepends `decorations/`
/// before calling `resolveSpriteDimensions`. Custom sprites (`custom/...`)
/// resolve via the file source fallback inside `resolveSpriteDimensions`.
fn resolveDecorationSpriteDimensions(
    sprite_stem: []const u8,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
) types.Vector2 {
    const full_id = std.fmt.allocPrint(allocator, "decorations/{s}", .{sprite_stem}) catch
        @panic("failed to build decoration sprite id for dims");
    defer allocator.free(full_id);
    return resolveSpriteDimensions(full_id, file_source, allocator);
}

// -- Ownership helpers --
//
// `parseEntityDefinition` and `parseDecorationDefinitions` return definitions
// whose STRING fields are BORROWED from the parsed config's `pairs` backing
// (freed by `freeParsedSections`) and whose ARRAY fields (footprint, layers)
// are OWNED via `toOwnedSlice`. The layout walk CLONES each placed
// entity/decoration/item so the level fully owns its data (no sharing with
// the definition hashmaps). `freeLevel`/`freeHub` then deep-free everything
// uniformly — use them in tests with `std.testing.allocator`. In production,
// the arena absorbs all allocations, so these frees are no-ops.

fn dupeString(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    return allocator.dupe(u8, s) catch @panic("failed to dupe string");
}

/// Deep-clone an entity's owned fields (all string slices + layers) into
/// `allocator`. Used in the layout walk so each placed entity fully owns its
/// data, independent of the definition hashmap.
fn cloneEntityOwned(entity: *types.Entity, allocator: std.mem.Allocator) void {
    entity.name = dupeString(allocator, entity.name);
    entity.sprite = dupeString(allocator, entity.sprite);
    if (entity.main_hand_weapon) |*w| w.name = dupeString(allocator, w.name);
    if (entity.off_hand_weapon) |*w| w.name = dupeString(allocator, w.name);
    if (entity.amulet) |*a| a.name = dupeString(allocator, a.name);
    if (entity.coat) |*c| c.name = dupeString(allocator, c.name);
    if (entity.gloves) |*g| g.name = dupeString(allocator, g.name);
    if (entity.pants) |*p| p.name = dupeString(allocator, p.name);
    if (entity.boots) |*b| b.name = dupeString(allocator, b.name);
    const duped_layers = allocator.alloc(types.EntityLayer, entity.layers.len) catch
        @panic("failed to alloc entity layers");
    for (entity.layers, 0..) |layer, i| {
        duped_layers[i] = .{
            .sprite = dupeString(allocator, layer.sprite),
            .color_index = layer.color_index,
        };
    }
    entity.layers = duped_layers;
}

/// Free an entity's owned fields (all string slices + layers). After
/// `cloneEntityOwned`, every string and the layers array are owned; this
/// frees them all.
pub fn freeEntity(entity: types.Entity, allocator: std.mem.Allocator) void {
    allocator.free(entity.name);
    allocator.free(entity.sprite);
    if (entity.main_hand_weapon) |w| allocator.free(w.name);
    if (entity.off_hand_weapon) |w| allocator.free(w.name);
    if (entity.amulet) |a| allocator.free(a.name);
    if (entity.coat) |c| allocator.free(c.name);
    if (entity.gloves) |g| allocator.free(g.name);
    if (entity.pants) |p| allocator.free(p.name);
    if (entity.boots) |b| allocator.free(b.name);
    for (entity.layers) |layer| allocator.free(layer.sprite);
    allocator.free(entity.layers);
}

/// Deep-clone a decoration's owned fields (name + footprint + layers) into
/// `allocator`.
fn cloneDecorationOwned(decoration: *types.Decoration, allocator: std.mem.Allocator) void {
    decoration.name = dupeString(allocator, decoration.name);
    decoration.footprint = allocator.dupe(types.Vector2, decoration.footprint) catch
        @panic("failed to dupe decoration footprint");
    const duped_layers = allocator.alloc(types.DecorationLayer, decoration.layers.len) catch
        @panic("failed to alloc decoration layers");
    for (decoration.layers, 0..) |layer, i| {
        duped_layers[i] = .{
            .sprite = dupeString(allocator, layer.sprite),
            .color_index = layer.color_index,
            .pixel_dims = layer.pixel_dims,
        };
    }
    decoration.layers = duped_layers;
}

/// Free a decoration's owned fields (name + footprint + layers).
pub fn freeDecoration(decoration: types.Decoration, allocator: std.mem.Allocator) void {
    allocator.free(decoration.name);
    allocator.free(decoration.footprint);
    for (decoration.layers) |layer| allocator.free(layer.sprite);
    allocator.free(decoration.layers);
}

/// Free owned arrays (footprint + layers) in a decoration-registry slice.
/// String fields (`id`, `sprite`, each layer's `sprite`) are borrowed from
/// the parsed sections and freed by `freeParsedSections`; only the
/// `footprint` and `layers` arrays are owned. Mirrors `freeDecoration` but
/// for `DecorationTypeDef` (registry prefab, no cloned strings).
pub fn freeDecorationRegistry(registry: []types.DecorationTypeDef, allocator: std.mem.Allocator) void {
    for (registry) |def| {
        allocator.free(def.footprint);
        allocator.free(def.layers);
    }
    allocator.free(registry);
}

/// Deep-clone an item's name string into `allocator`.
fn cloneItemOwned(item: *types.Item, allocator: std.mem.Allocator) void {
    switch (item.*) {
        .weapon => |*w| w.name = dupeString(allocator, w.name),
        .amulet => |*a| a.name = dupeString(allocator, a.name),
        .coat => |*c| c.name = dupeString(allocator, c.name),
        .gloves => |*g| g.name = dupeString(allocator, g.name),
        .pants => |*p| p.name = dupeString(allocator, p.name),
        .boots => |*b| b.name = dupeString(allocator, b.name),
        .skill_tome => {},
    }
}

/// Free an item's name string.
pub fn freeItem(item: types.Item, allocator: std.mem.Allocator) void {
    switch (item) {
        .weapon => |w| allocator.free(w.name),
        .amulet => |a| allocator.free(a.name),
        .coat => |c| allocator.free(c.name),
        .gloves => |g| allocator.free(g.name),
        .pants => |p| allocator.free(p.name),
        .boots => |b| allocator.free(b.name),
        .skill_tome => {},
    }
}

/// Free all heap-allocated data in a Level (tiles, entities, decorations,
/// ground items). Each entity/decoration/item is deep-freed. Use in tests
/// with `std.testing.allocator`; in production, the arena absorbs everything.
pub fn freeLevel(level: types.Level, allocator: std.mem.Allocator) void {
    allocator.free(level.level_tiles);
    for (level.entities) |entity| freeEntity(entity, allocator);
    allocator.free(level.entities);
    for (level.decorations) |decoration| freeDecoration(decoration, allocator);
    allocator.free(level.decorations);
    for (level.ground_items) |ground_items| {
        for (ground_items.items) |item| freeItem(item, allocator);
        allocator.free(ground_items.items);
    }
    allocator.free(level.ground_items);
}

/// Free all heap-allocated data in a Hub (tiles, player, npcs, decorations,
/// mission exits).
pub fn freeHub(hub: types.Hub, allocator: std.mem.Allocator) void {
    allocator.free(hub.hub_tiles);
    freeEntity(hub.player, allocator);
    for (hub.npcs) |npc| freeEntity(npc.entity, allocator);
    allocator.free(hub.npcs);
    for (hub.decorations) |decoration| freeDecoration(decoration, allocator);
    allocator.free(hub.decorations);
    for (hub.mission_exits) |exit| allocator.free(exit.mission_id);
    allocator.free(hub.mission_exits);
}

/// Free owned arrays (footprint + layers) in a decoration-definitions hashmap,
/// then deinit. String fields are borrowed (freed by `freeParsedSections`).
fn freeDecorationDefinitions(definitions: *std.AutoHashMap(u8, DecorationDefinition), allocator: std.mem.Allocator) void {
    var it = definitions.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.value_ptr.footprint);
        allocator.free(entry.value_ptr.layers);
    }
    definitions.deinit();
}

/// Free owned arrays (layers) in an enemy-definitions hashmap, then deinit.
/// String fields are borrowed.
fn freeEnemyDefinitions(definitions: *std.AutoHashMap(u8, types.Entity), allocator: std.mem.Allocator) void {
    var it = definitions.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.value_ptr.layers);
    }
    definitions.deinit();
}

pub fn loadLevel(
    sections: []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !Level {
    try validateSections(sections, &level_sections);
    try validateFileFormatVersion(sections, "Metadata", level_file_format_version);
    var level: Level = .{};
    if (findSection(sections, "Metadata")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "name")) |value| {
                level.name = value;
            }
            if (findValue(pairs, "color_wheel_index")) |value| {
                level.color_wheel_index = asU32(value) orelse 0;
            }
        }
    }

    // Parse decoration definitions keyed by character code (sprite +
    // sprite-grid footprint + pixel dims). Replaces the old decoration_codes
    // list — the layout walk now looks up the full definition per char.
    var decoration_definitions = parseDecorationDefinitions(sections, file_source, allocator);
    defer freeDecorationDefinitions(&decoration_definitions, allocator);
    var enemy_definitions = std.AutoHashMap(u8, types.Entity).init(allocator);
    defer freeEnemyDefinitions(&enemy_definitions, allocator);
    if (findSection(sections, "Enemies")) |section| {
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const code_string = findValue(pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;
            const entity = parseEntityDefinition(pairs, 1, &.{}, &.{}, allocator, file_path, warnings);
            try enemy_definitions.put(code_string[0], entity);
        }
    }

    // Parse item definitions keyed by character code
    var item_definitions = std.AutoHashMap(u8, types.Item).init(allocator);
    defer item_definitions.deinit();
    if (findSection(sections, "Items")) |section| {
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const code_string = findValue(pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;
            const item_type = findValue(pairs, "item_type") orelse continue;

            const ItemTypeId = enum { weapon, amulet, coat, gloves, pants, boots };
            const item_type_id = parseEnum(ItemTypeId, item_type) orelse continue;
            const item_name = findValue(pairs, "item_name") orelse &.{};

            const item: types.Item = switch (item_type_id) {
                .weapon => .{ .weapon = .{
                    .name = item_name,
                    .weapon_type = parseEnum(types.WeaponType, findValue(pairs, "weapon_type") orelse "sword") orelse .sword,
                    .weapon_damage = boundedU32(findValue(pairs, "damage") orelse "0", max_weapon_damage, "damage", file_path, warnings, allocator),
                } },
                .amulet => .{ .amulet = .{
                    .name = item_name,
                    .spell_damage = boundedU32(findValue(pairs, "spell_damage") orelse "0", max_spell_damage, "spell_damage", file_path, warnings, allocator),
                } },
                .coat => .{ .coat = .{
                    .name = item_name,
                    .defense_bonus = boundedU32(findValue(pairs, "defense") orelse "0", max_defense_bonus, "defense", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
                } },
                .gloves => .{ .gloves = .{
                    .name = item_name,
                    .damage_bonus = boundedU32(findValue(pairs, "damage") orelse "0", max_gloves_damage, "damage", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
                } },
                .pants => .{ .pants = .{
                    .name = item_name,
                    .pickup_radius_bonus = boundedU32(findValue(pairs, "pickup_radius") orelse "0", max_pickup_radius, "pickup_radius", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
                } },
                .boots => .{ .boots = .{
                    .name = item_name,
                    .speed_bonus = boundedU32(findValue(pairs, "speed") orelse "0", max_boots_speed, "speed", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
                } },
            };

            try item_definitions.put(code_string[0], item);
        }
    }

    // Parse layout grid
    var tile_positions: std.ArrayList(types.Vector2) = .empty;
    // Player is always entity index 0
    var entity_list: std.ArrayList(types.Entity) = .empty;
    var player_entity: types.Entity = .{ .name = "Player", .sprite = "player", .team = 0 };
    cloneEntityOwned(&player_entity, allocator);
    try entity_list.append(allocator, player_entity);
    var decoration_list: std.ArrayList(types.Decoration) = .empty;
    var ground_item_list: std.ArrayList(types.GroundItems) = .empty;
    var player_start: ?types.Vector2 = null;

    if (findSection(sections, "Layout")) |section| {
        for (section.raw_lines, 0..) |row, raw_y| {
            const y: i32 = @intCast(raw_y);
            for (row, 0..) |character, raw_x| {
                const x: i32 = @intCast(raw_x);
                const position = types.Vector2{ .x = x, .y = y };

                switch (character) {
                    ' ' => {},
                    '.' => try tile_positions.append(allocator, position),
                    '!' => {
                        player_start = position;
                        try tile_positions.append(allocator, position);
                    },
                    '=' => {
                        level.level_end = position;
                        try tile_positions.append(allocator, position);
                    },
                    else => {
                        // Check if this character is a decoration (no tile underneath)
                        if (decoration_definitions.get(character)) |deco_def| {
                            // Decoration: no tile at the anchor; footprint
                            // tiles are validated after the full layout walk.
                            var decoration: types.Decoration = .{
                                .name = deco_def.sprite,
                                .position = position,
                                .footprint = deco_def.footprint,
                                .pixel_dims = deco_def.pixel_dims,
                                .color_index = deco_def.color_index,
                                .layers = deco_def.layers,
                            };
                            cloneDecorationOwned(&decoration, allocator);
                            decoration_list.append(allocator, decoration) catch @panic("failed to append decoration");
                        } else {
                            // Not a decoration — this tile is walkable.
                            try tile_positions.append(allocator, position);

                            // Match character to enemy or item definition.
                            if (enemy_definitions.get(character)) |definition| {
                                var entity = definition;
                                entity.position = position;
                                cloneEntityOwned(&entity, allocator);
                                try entity_list.append(allocator, entity);
                            } else if (item_definitions.get(character)) |item| {
                                const items = try allocator.alloc(types.Item, 1);
                                items[0] = item;
                                cloneItemOwned(&items[0], allocator);
                                try ground_item_list.append(allocator, .{
                                    .position = position,
                                    .items = items,
                                });
                            }
                        }
                    },
                }
            }
        }
    }

    // Set player start position (entity index 0)
    if (player_start) |position| {
        entity_list.items[0].position = position;
    }

    // Validate decoration footprints: each world footprint tile must not
    // overlap a level tile (placement invariant — see AGENTS → Decorations
    // & Footprint). Build a tile-position set for O(1) lookup.
    var tile_set = std.AutoHashMap(types.Vector2, void).init(allocator);
    defer tile_set.deinit();
    for (tile_positions.items) |tile| {
        tile_set.put(tile, {}) catch @panic("failed to insert tile into set");
    }
    for (decoration_list.items) |decoration| {
        validateDecorationFootprint(decoration, &tile_set);
    }

    level.level_tiles = try tile_positions.toOwnedSlice(allocator);
    level.entities = try entity_list.toOwnedSlice(allocator);
    level.decorations = try decoration_list.toOwnedSlice(allocator);
    level.ground_items = try ground_item_list.toOwnedSlice(allocator);

    return level;
}

pub fn loadHub(
    sections: []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
) !Hub {
    try validateSections(sections, &hub_sections);
    try validateFileFormatVersion(sections, "Metadata", hub_file_format_version);
    var hub: Hub = .{};

    // Metadata
    if (findSection(sections, "Metadata")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "name")) |value| {
                hub.name = value;
            }
            if (findValue(pairs, "color_wheel_index")) |value| {
                hub.color_wheel_index = asU32(value) orelse 0;
            }
        }
    }

    // Parse decoration definitions keyed by character code (same as levels).
    var decoration_definitions = parseDecorationDefinitions(sections, file_source, allocator);
    defer freeDecorationDefinitions(&decoration_definitions, allocator);

    // Collect exit character codes
    var exit_codes: std.ArrayList(u8) = .empty;
    defer exit_codes.deinit(allocator);
    var exit_definitions = std.AutoHashMap(u8, types.MissionExit).init(allocator);
    defer exit_definitions.deinit();
    if (findSection(sections, "Exits")) |section| {
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const code_string = findValue(pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;
            try exit_codes.append(allocator, code_string[0]);
            try exit_definitions.put(code_string[0], .{
                .mission_id = findValue(pairs, "mission_id") orelse &.{},
                .position = .{ .x = 0, .y = 0 },
            });
        }
    }

    // Collect NPC definitions
    var npc_definitions = std.AutoHashMap(u8, types.NPC).init(allocator);
    defer npc_definitions.deinit();
    if (findSection(sections, "NPCs")) |section| {
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const code_string = findValue(pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;
            var entity: types.Entity = .{};
            if (findValue(pairs, "name")) |value| entity.name = value;
            if (findValue(pairs, "sprite")) |value| entity.sprite = value;
            try npc_definitions.put(code_string[0], .{ .entity = entity });
        }
    }

    // Parse layout grid
    var tile_positions: std.ArrayList(types.Vector2) = .empty;
    var decoration_list: std.ArrayList(types.Decoration) = .empty;
    var npc_list: std.ArrayList(types.NPC) = .empty;
    var exit_list: std.ArrayList(types.MissionExit) = .empty;

    if (findSection(sections, "Layout")) |section| {
        for (section.raw_lines, 0..) |row, raw_y| {
            const y: i32 = @intCast(raw_y);
            for (row, 0..) |character, raw_x| {
                const x: i32 = @intCast(raw_x);
                const position = types.Vector2{ .x = x, .y = y };

                switch (character) {
                    ' ' => {},
                    '.' => try tile_positions.append(allocator, position),
                    '!' => {
                        hub.player.position = position;
                        hub.player.name = dupeString(allocator, "Player");
                        hub.player.sprite = dupeString(allocator, "player");
                        try tile_positions.append(allocator, position);
                    },
                    else => {
                        if (decoration_definitions.get(character)) |deco_def| {
                            var decoration: types.Decoration = .{
                                .name = deco_def.sprite,
                                .position = position,
                                .footprint = deco_def.footprint,
                                .pixel_dims = deco_def.pixel_dims,
                                .color_index = deco_def.color_index,
                                .layers = deco_def.layers,
                            };
                            cloneDecorationOwned(&decoration, allocator);
                            decoration_list.append(allocator, decoration) catch @panic("failed to append decoration");
                        } else {
                            try tile_positions.append(allocator, position);

                            if (exit_definitions.getPtr(character)) |exit| {
                                exit.position = position;
                                var exit_copy = exit.*;
                                exit_copy.mission_id = dupeString(allocator, exit_copy.mission_id);
                                try exit_list.append(allocator, exit_copy);
                            } else if (npc_definitions.getPtr(character)) |npc| {
                                var npc_copy = npc.*;
                                npc_copy.entity.position = position;
                                cloneEntityOwned(&npc_copy.entity, allocator);
                                try npc_list.append(allocator, npc_copy);
                            }
                        }
                    },
                }
            }
        }
    }

    // Validate decoration footprints (same as levels — see AGENTS →
    // Decorations & Footprint).
    var tile_set = std.AutoHashMap(types.Vector2, void).init(allocator);
    defer tile_set.deinit();
    for (tile_positions.items) |tile| {
        tile_set.put(tile, {}) catch @panic("failed to insert tile into set");
    }
    for (decoration_list.items) |decoration| {
        validateDecorationFootprint(decoration, &tile_set);
    }

    hub.hub_tiles = try tile_positions.toOwnedSlice(allocator);
    hub.decorations = try decoration_list.toOwnedSlice(allocator);
    hub.npcs = try npc_list.toOwnedSlice(allocator);
    hub.mission_exits = try exit_list.toOwnedSlice(allocator);

    return hub;
}

pub fn loadCampaign(
    sections: []const Section,
    allocator: std.mem.Allocator,
) !Campaign {
    _ = allocator;
    try validateSections(sections, &campaign_sections);
    try validateFileFormatVersion(sections, "Metadata", campaign_file_format_version);
    var campaign: Campaign = .{};

    if (findSection(sections, "Metadata")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "name")) |value| campaign.name = value;
            if (findValue(pairs, "start_hub")) |value| campaign.start_hub = value;
        }
    }

    return campaign;
}

pub fn loadMission(
    sections: []const Section,
    allocator: std.mem.Allocator,
) !Mission {
    _ = allocator;
    try validateSections(sections, &mission_sections);
    try validateFileFormatVersion(sections, "Metadata", mission_file_format_version);
    var mission: Mission = .{};

    if (findSection(sections, "Metadata")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "name")) |value| mission.name = value;
            if (findValue(pairs, "start_hub")) |value| mission.start_hub = value;
            if (findValue(pairs, "end_hub")) |value| mission.end_hub = value;
            if (findValue(pairs, "level_count")) |value| mission.level_count = asU32(value) orelse 0;
        }
    }

    return mission;
}

pub fn loadPlayerSave(
    sections: []const Section,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !PlayerData {
    try validateSections(sections, &player_save_sections);
    try validateFileFormatVersion(sections, "Metadata", player_save_file_format_version);
    var player_data: PlayerData = .{};

    // Info
    if (findSection(sections, "Info")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "player_name")) |value| player_data.player_name = value;
            if (findValue(pairs, "current_campaign")) |value| player_data.current_campaign = value;
            if (findValue(pairs, "current_hub")) |value| player_data.current_hub = value;
            if (findValue(pairs, "turns")) |value| player_data.turns = asU32(value) orelse 0;
            if (findValue(pairs, "deaths")) |value| player_data.deaths = asU32(value) orelse 0;
            if (findValue(pairs, "defeated_enemies")) |value| player_data.defeated_enemies = asU32(value) orelse 0;
            if (findValue(pairs, "skills_used")) |value| player_data.skills_used = asU32(value) orelse 0;
            if (findValue(pairs, "wood_salvage")) |value| player_data.materials.wood = asU32(value) orelse 0;
            if (findValue(pairs, "metal_salvage")) |value| player_data.materials.metal = asU32(value) orelse 0;
            if (findValue(pairs, "leather_salvage")) |value| player_data.materials.leather = asU32(value) orelse 0;
            if (findValue(pairs, "cloth_salvage")) |value| player_data.materials.cloth = asU32(value) orelse 0;
            if (findValue(pairs, "knowledge")) |value| player_data.materials.knowledge = asU32(value) orelse 0;
        }
    }

    // UnlockedSkills
    if (findSection(sections, "UnlockedSkills")) |section| {
        var skills: std.ArrayList(types.SkillId) = .empty;
        for (section.entry_groups) |group| {
            if (findValue(group.pairs, "name")) |value| {
                if (parseEnum(types.SkillId, value)) |skill_id| {
                    try skills.append(allocator, skill_id);
                }
            }
        }
        player_data.learned_skills = try skills.toOwnedSlice(allocator);
    }

    // MainHandWeapon
    if (findSection(sections, "MainHandWeapon")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.main_hand_weapon = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .weapon_type = parseEnum(types.WeaponType, findValue(pairs, "weapon_type") orelse "sword") orelse .sword,
                .weapon_damage = boundedU32(findValue(pairs, "damage") orelse "0", max_weapon_damage, "damage", file_path, warnings, allocator),
            };
        }
    }

    // OffHandWeapon
    if (findSection(sections, "OffHandWeapon")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.off_hand_weapon = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .weapon_type = parseEnum(types.WeaponType, findValue(pairs, "weapon_type") orelse "sword") orelse .sword,
                .weapon_damage = boundedU32(findValue(pairs, "damage") orelse "0", max_weapon_damage, "damage", file_path, warnings, allocator),
            };
        }
    }

    // Amulet
    if (findSection(sections, "Amulet")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.amulet = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .spell_damage = boundedU32(findValue(pairs, "spell_damage") orelse "0", max_spell_damage, "spell_damage", file_path, warnings, allocator),
            };
        }
    }

    // Coat
    if (findSection(sections, "Coat")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.coat = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .defense_bonus = boundedU32(findValue(pairs, "armor") orelse "0", max_defense_bonus, "armor", file_path, warnings, allocator),
                .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
            };
        }
    }

    // Gloves
    if (findSection(sections, "Gloves")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.gloves = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .damage_bonus = boundedU32(findValue(pairs, "damage") orelse "0", max_gloves_damage, "damage", file_path, warnings, allocator),
                .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
            };
        }
    }

    // Pants
    if (findSection(sections, "Pants")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.pants = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .pickup_radius_bonus = boundedU32(findValue(pairs, "pickup_radius") orelse "0", max_pickup_radius, "pickup_radius", file_path, warnings, allocator),
                .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
            };
        }
    }

    // Boots
    if (findSection(sections, "Boots")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.boots = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .speed_bonus = boundedU32(findValue(pairs, "speed") orelse "0", max_boots_speed, "speed", file_path, warnings, allocator),
                .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
            };
        }
    }

    // Inventory
    if (findSection(sections, "Inventory")) |section| {
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const item_type = findValue(pairs, "item_type") orelse continue;
            const slot_index = asU32(findValue(pairs, "slot") orelse continue) orelse continue;
            if (slot_index >= types.inventory_slot_count) continue;

            const ItemTypeId = enum { weapon, amulet, coat, gloves, pants, boots, skill_tome };
            const item_type_id = parseEnum(ItemTypeId, item_type) orelse continue;
            const item_name = findValue(pairs, "item_name") orelse &.{};

            const item: types.Item = switch (item_type_id) {
                .weapon => .{ .weapon = .{
                    .name = item_name,
                    .weapon_type = parseEnum(types.WeaponType, findValue(pairs, "weapon_type") orelse "sword") orelse .sword,
                    .weapon_damage = boundedU32(findValue(pairs, "damage") orelse "0", max_weapon_damage, "damage", file_path, warnings, allocator),
                } },
                .amulet => .{ .amulet = .{
                    .name = item_name,
                    .spell_damage = boundedU32(findValue(pairs, "spell_damage") orelse "0", max_spell_damage, "spell_damage", file_path, warnings, allocator),
                } },
                .coat => .{ .coat = .{
                    .name = item_name,
                    .defense_bonus = boundedU32(findValue(pairs, "armor") orelse "0", max_defense_bonus, "armor", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
                } },
                .gloves => .{ .gloves = .{
                    .name = item_name,
                    .damage_bonus = boundedU32(findValue(pairs, "damage") orelse "0", max_gloves_damage, "damage", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
                } },
                .pants => .{ .pants = .{
                    .name = item_name,
                    .pickup_radius_bonus = boundedU32(findValue(pairs, "pickup_radius") orelse "0", max_pickup_radius, "pickup_radius", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
                } },
                .boots => .{ .boots = .{
                    .name = item_name,
                    .speed_bonus = boundedU32(findValue(pairs, "speed") orelse "0", max_boots_speed, "speed", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", max_health_bonus, "health", file_path, warnings, allocator),
                } },
                .skill_tome => .{ .skill_tome = .{
                    .skill = parseEnum(types.SkillId, findValue(pairs, "skill_name") orelse "") orelse continue,
                } },
            };

            player_data.inventory.slots[slot_index] = item;
        }
    }

    // UtilitySkills
    // Keys are "slot_N" where N starts at 4 (bar slots 4-8). We place each
    // skill at its explicit index so empty (null) slots keep their position.
    if (findSection(sections, "UtilitySkills")) |section| {
        if (section.entry_groups.len > 0) {
            for (section.entry_groups[0].pairs) |pair| {
                if (!std.mem.startsWith(u8, pair.key, "slot_")) continue;
                const slot_number = asU32(pair.key["slot_".len..]) orelse continue;
                if (slot_number < 4) continue;
                const slot_index = slot_number - 4;
                if (slot_index >= types.utility_skill_count) continue;
                if (parseEnum(types.SkillId, pair.value)) |skill_id| {
                    player_data.equipped_utility_skills[slot_index] = skill_id;
                }
            }
        }
    }

    // CloneData
    if (findSection(sections, "CloneData")) |section| {
        var clones: std.ArrayList(types.Clone) = .empty;
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            try clones.append(allocator, .{
                .name = findValue(pairs, "clone_name") orelse &.{},
                .turns_to_complete = asU32(findValue(pairs, "turns_to_complete") orelse "0") orelse 0,
                .materials_collected = .{
                    .wood = asU32(findValue(pairs, "wood") orelse "0") orelse 0,
                    .metal = asU32(findValue(pairs, "metal") orelse "0") orelse 0,
                    .leather = asU32(findValue(pairs, "leather") orelse "0") orelse 0,
                    .cloth = asU32(findValue(pairs, "cloth") orelse "0") orelse 0,
                    .knowledge = asU32(findValue(pairs, "knowledge") orelse "0") orelse 0,
                },
            });
        }
        player_data.clones = try clones.toOwnedSlice(allocator);
    }

    return player_data;
}

pub fn loadWeaponTypeDefinition(
    sections: []const Section,
) !WeaponTypeDefinition {
    try validateSections(sections, &weapon_type_sections);
    const skills_section = findSection(sections, "Skills") orelse return error.InvalidData;
    if (skills_section.entry_groups.len == 0) return error.InvalidData;

    const pairs = skills_section.entry_groups[0].pairs;

    return .{
        .skill_1 = parseEnum(types.SkillId, findValue(pairs, "skill_1") orelse return error.InvalidData) orelse return error.InvalidData,
        .skill_2 = parseEnum(types.SkillId, findValue(pairs, "skill_2") orelse return error.InvalidData) orelse return error.InvalidData,
        .skill_3 = parseEnum(types.SkillId, findValue(pairs, "skill_3") orelse return error.InvalidData) orelse return error.InvalidData,
    };
}

const color_theme_sections = [_][]const u8{ "Metadata", "GlobalColors", "Gradients" };

pub fn loadColorThemeDefinitions(
    sections: []const Section,
    allocator: std.mem.Allocator,
) !ColorThemeDefinitions {
    try validateSections(sections, &color_theme_sections);
    try validateFileFormatVersion(sections, "Metadata", color_themes_file_format_version);

    var theme: ColorThemeDefinitions = .{
        .lightest = .{ .r = 255, .g = 255, .b = 240 },
        .darkest = .{ .r = 20, .g = 15, .b = 25 },
        .gradients = &.{},
    };

    // GlobalColors
    if (findSection(sections, "GlobalColors")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "lightest")) |value| {
                theme.lightest = asColor(value) orelse theme.lightest;
            }
            if (findValue(pairs, "darkest")) |value| {
                theme.darkest = asColor(value) orelse theme.darkest;
            }
        }
    }

    // Gradients — each entry group is one gradient, starting with gradient_index
    if (findSection(sections, "Gradients")) |section| {
        var gradient_list: std.ArrayList(ColorGradient) = .empty;

        for (section.entry_groups) |group| {
            const pairs = group.pairs;

            // Verify gradient_index matches expected position
            const gradient_index = asU32(findValue(pairs, "gradient_index") orelse continue) orelse continue;
            if (gradient_index != gradient_list.items.len) return error.InvalidData;

            var gradient: ColorGradient = .{
                .colors = .{Color{ .r = 0, .g = 0, .b = 0 }} ** types.gradient_color_count,
            };

            inline for (0..types.gradient_color_count) |color_index| {
                const key = "color_" ++ comptime blk: {
                    break :blk &[1]u8{'0' + color_index};
                };
                if (findValue(pairs, key)) |value| {
                    gradient.colors[color_index] = asColor(value) orelse gradient.colors[color_index];
                }
            }

            try gradient_list.append(allocator, gradient);
        }

        theme.gradients = try gradient_list.toOwnedSlice(allocator);
    }

    return theme;
}

/// Derive the active color theme for a level or hub from the color wheel.
/// The world gradient is at the given index, enemy and player gradients
/// are evenly spaced around the wheel (at 1/3 and 2/3 offsets).
pub fn deriveActiveColorTheme(
    color_theme_definitions: ColorThemeDefinitions,
    color_wheel_index: u32,
) ActiveColorTheme {
    const gradient_count: u32 = @intCast(color_theme_definitions.gradients.len);
    if (gradient_count == 0) {
        return .{
            .lightest = color_theme_definitions.lightest,
            .darkest = color_theme_definitions.darkest,
            .world_gradient = .{ .colors = .{Color{ .r = 128, .g = 128, .b = 128 }} ** types.gradient_color_count },
            .enemy_gradient = .{ .colors = .{Color{ .r = 128, .g = 128, .b = 128 }} ** types.gradient_color_count },
            .player_gradient = .{ .colors = .{Color{ .r = 128, .g = 128, .b = 128 }} ** types.gradient_color_count },
        };
    }

    const world_index = color_wheel_index % gradient_count;
    const enemy_index = (color_wheel_index + gradient_count / 3) % gradient_count;
    const player_index = (color_wheel_index + 2 * gradient_count / 3) % gradient_count;

    return .{
        .lightest = color_theme_definitions.lightest,
        .darkest = color_theme_definitions.darkest,
        .world_gradient = color_theme_definitions.gradients[world_index],
        .enemy_gradient = color_theme_definitions.gradients[enemy_index],
        .player_gradient = color_theme_definitions.gradients[player_index],
    };
}

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

    // MainHandWeapon
    try buffer.appendSlice(allocator, "\nMainHandWeapon\n");
    if (player_data.main_hand_weapon) |weapon| {
        try writeWeapon(&buffer, allocator, weapon);
    }

    // OffHandWeapon
    try buffer.appendSlice(allocator, "\nOffHandWeapon\n");
    if (player_data.off_hand_weapon) |weapon| {
        try writeWeapon(&buffer, allocator, weapon);
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
            try writeInventoryItem(&buffer, allocator, item, @intCast(slot_index));
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

    // CloneData
    try buffer.appendSlice(allocator, "\nCloneData\n");
    for (player_data.clones, 0..) |clone, index| {
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
// Session log writer (event history serialization)
// ============================================================
//
// Serializes an event history to the config format so a whole session can be
// dumped (ctrl+L) and later re-read to reconstruct/step through it (see
// AGENTS.md "Logging & Replay"). The event stream alone reproduces a session;
// no player input is logged. The writer is comptime-generic over the `Event`
// union, so new events serialize with no changes here.
//
// Layout:
//   Metadata
//   file_format_version <int>
//   game_version <string>
//   created <YYYYMMDD_HHMMSS>
//
//   EventLog
//
//   event_index <N>
//   event <category> <variant>
//   <field> <value>
//   ...
//
// Each event is one blank-line-separated entry group: a decorative
// `event_index <N>` header line (purely for human readability — the reader
// ignores it, and hand-edited/externally-authored logs may omit it), then the
// `event` pair as the discriminator (outer union tag = category, inner tag =
// variant). Payload fields follow, one per line. Optionals omit their line
// when null. Vector2 / Materials serialize as space-separated ints; slices of
// them (e.g. highlight_tiles) flatten into one space-separated line; enums via
// @tagName.

/// Serialize an event history (+ a created timestamp) into a session-log file
/// body. `created` is expected as "YYYYMMDD_HHMMSS" but is written verbatim.
pub fn writeEventLog(
    event_history: []const Event,
    created: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;

    try buffer.appendSlice(allocator, "Metadata\n");
    try buffer.print(allocator, "file_format_version {d}\n", .{session_log_file_format_version});
    try buffer.print(allocator, "game_version {s}\n", .{build_info.game_version});
    try buffer.print(allocator, "created {s}\n", .{created});

    try buffer.appendSlice(allocator, "\nEventLog\n");
    for (event_history, 0..) |event, index| {
        try buffer.appendSlice(allocator, "\n");
        // Decorative index header — purely for human readability when scanning
        // a log. The reader ignores it (not required to parse), so hand-edited
        // or externally-authored logs can omit it entirely.
        try buffer.print(allocator, "event_index {d}\n", .{index});
        try writeEvent(&buffer, allocator, event);
    }

    return try buffer.toOwnedSlice(allocator);
}

/// Write one event as an entry group: the `event <category> <variant>`
/// discriminator followed by one line per payload field.
fn writeEvent(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    event: Event,
) !void {
    switch (event) {
        inline else => |category_payload, category_tag| {
            switch (category_payload) {
                inline else => |variant_payload, variant_tag| {
                    try buffer.print(allocator, "event {s} {s}\n", .{
                        @tagName(category_tag),
                        @tagName(variant_tag),
                    });
                    const Payload = @TypeOf(variant_payload);
                    if (Payload != void) {
                        inline for (@typeInfo(Payload).@"struct".fields) |field| {
                            try writeEventField(
                                buffer,
                                allocator,
                                field.name,
                                @field(variant_payload, field.name),
                            );
                        }
                    }
                },
            }
        },
    }
}

/// Write one payload field as `<name> <value>`. Optionals with a null value
/// omit their line entirely (absence encodes null, matching UtilitySkills).
fn writeEventField(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    value: anytype,
) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => {
            if (value) |inner| try writeEventField(buffer, allocator, name, inner);
        },
        else => {
            try buffer.appendSlice(allocator, name);
            try buffer.appendSlice(allocator, " ");
            try appendEventScalar(buffer, allocator, value);
            try buffer.appendSlice(allocator, "\n");
        },
    }
}

/// Append a single (non-optional) field value: ints as decimals, bools as
/// true/false, enums via @tagName, `[]const u8` verbatim, and structs
/// (Vector2, Materials) as their fields space-separated.
fn appendEventScalar(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: anytype,
) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => try buffer.print(allocator, "{d}", .{value}),
        .bool => try buffer.appendSlice(allocator, if (value) "true" else "false"),
        .@"enum" => try buffer.appendSlice(allocator, @tagName(value)),
        .pointer => |pointer| {
            if (pointer.size != .slice) {
                @compileError("unsupported event field pointer type: " ++ @typeName(T));
            }
            if (pointer.child == u8) {
                // `[]const u8` — a string, verbatim.
                try buffer.appendSlice(allocator, value);
            } else {
                // A slice of scalars/structs (e.g. `[]const Vector2`) flattened
                // as space-separated element reprs. Elements have fixed arity
                // (Vector2 = 2 ints), so decoding regroups; an empty slice
                // writes nothing (an empty value).
                for (value, 0..) |element, index| {
                    if (index != 0) try buffer.appendSlice(allocator, " ");
                    try appendEventScalar(buffer, allocator, element);
                }
            }
        },
        .@"struct" => |info| {
            inline for (info.fields, 0..) |field, index| {
                if (index != 0) try buffer.appendSlice(allocator, " ");
                try appendEventScalar(buffer, allocator, @field(value, field.name));
            }
        },
        .@"union" => |union_info| {
            // A tagged-union field value (e.g. EntityEditTarget, Item):
            // `<tag> <payload-fields...>`. The tag is the first token, then
            // the active payload's fields (recursively flattened). A void
            // payload (e.g. EntityEditTarget.player_def) writes just the tag.
            if (union_info.tag_type) |_| {
                try buffer.appendSlice(allocator, @tagName(value));
                switch (value) {
                    inline else => |payload, tag| {
                        // `tag` is a comptime-known enum value, so indexing
                        // union_info.fields (a comptime tuple) works. A void
                        // payload (e.g. EntityEditTarget.player_def) writes
                        // just the tag — no payload fields appended.
                        const field_info = union_info.fields[@intFromEnum(tag)];
                        if (field_info.type != void) {
                            try buffer.appendSlice(allocator, " ");
                            try appendEventScalar(buffer, allocator, payload);
                        }
                    },
                }
            } else {
                @compileError("unsupported event field: untagged union " ++ @typeName(T));
            }
        },
        .array => {
            // Fixed-size array (e.g. [6]Color in a ColorGradient): flattened
            // as space-separated element reprs, same as a slice. Elements have
            // fixed arity so decoding regroups.
            for (value, 0..) |element, index| {
                if (index != 0) try buffer.appendSlice(allocator, " ");
                try appendEventScalar(buffer, allocator, element);
            }
        },
        else => @compileError("unsupported event field type: " ++ @typeName(T)),
    }
}

// ============================================================
// Session log reader (event history deserialization)
// ============================================================
//
// The comptime-generic inverse of writeEventLog: parses a session-log file
// (already run through parseConfigFile) back into an event history. Reload
// feeds these into the existing replay machinery (NOT the input path) to
// reconstruct/step a session. New events deserialize with no changes here.

pub const SessionLog = struct {
    file_format_version: u32,
    /// The build that produced the log (advisory; caller warns on mismatch).
    game_version: []const u8,
    /// "YYYYMMDD_HHMMSS" (UTC) verbatim from the file.
    created: []const u8,
    events: []const Event,
};

pub const SessionLogError = error{
    /// Metadata / EventLog section missing, or an event entry malformed.
    MalformedSessionLog,
    /// file_format_version is not one this build can read.
    UnsupportedFileFormatVersion,
    OutOfMemory,
};

/// Parse a session log from config sections. All returned memory (events,
/// strings, tile slices) is allocated with `allocator`. `game_version` is
/// returned for the caller to compare against the running build (advisory);
/// file_format_version is a hard gate.
pub fn loadEventLog(
    sections: []const Section,
    allocator: std.mem.Allocator,
) SessionLogError!SessionLog {
    const metadata = findSection(sections, "Metadata") orelse return error.MalformedSessionLog;
    const meta_pairs = if (metadata.entry_groups.len > 0)
        metadata.entry_groups[0].pairs
    else
        return error.MalformedSessionLog;

    const version_string = findValue(meta_pairs, "file_format_version") orelse
        return error.MalformedSessionLog;
    const file_format_version = asU32(version_string) orelse return error.MalformedSessionLog;
    if (file_format_version != session_log_file_format_version) {
        return error.UnsupportedFileFormatVersion;
    }

    const game_version = try allocator.dupe(u8, findValue(meta_pairs, "game_version") orelse "");
    const created = try allocator.dupe(u8, findValue(meta_pairs, "created") orelse "");

    const event_log = findSection(sections, "EventLog") orelse return error.MalformedSessionLog;
    var events: std.ArrayList(Event) = .empty;
    for (event_log.entry_groups) |group| {
        try events.append(allocator, try parseEvent(group.pairs, allocator));
    }

    return .{
        .file_format_version = file_format_version,
        .game_version = game_version,
        .created = created,
        .events = try events.toOwnedSlice(allocator),
    };
}

/// Parse one event entry group: read the `event <category> <variant>`
/// discriminator, then build the payload struct field-by-field by name.
fn parseEvent(
    pairs: []const KeyValuePair,
    allocator: std.mem.Allocator,
) SessionLogError!Event {
    const discriminator = findValue(pairs, "event") orelse return error.MalformedSessionLog;
    var tokens = std.mem.tokenizeScalar(u8, discriminator, ' ');
    const category = tokens.next() orelse return error.MalformedSessionLog;
    const variant = tokens.next() orelse return error.MalformedSessionLog;

    inline for (@typeInfo(Event).@"union".fields) |category_field| {
        if (std.mem.eql(u8, category, category_field.name)) {
            const Inner = category_field.type;
            inline for (@typeInfo(Inner).@"union".fields) |variant_field| {
                if (std.mem.eql(u8, variant, variant_field.name)) {
                    const Payload = variant_field.type;
                    const inner_value = if (Payload == void)
                        @unionInit(Inner, variant_field.name, {})
                    else inner: {
                        var payload: Payload = undefined;
                        inline for (@typeInfo(Payload).@"struct".fields) |payload_field| {
                            @field(payload, payload_field.name) = try parseEventFieldValue(
                                payload_field.type,
                                findValue(pairs, payload_field.name),
                                allocator,
                            );
                        }
                        break :inner @unionInit(Inner, variant_field.name, payload);
                    };
                    return @unionInit(Event, category_field.name, inner_value);
                }
            }
            return error.MalformedSessionLog; // unknown variant for this category
        }
    }
    return error.MalformedSessionLog; // unknown category
}

/// Read one payload field. An absent key is null for optionals (matching the
/// writer's omit-when-null) and malformed for required fields.
fn parseEventFieldValue(
    comptime T: type,
    maybe_value: ?[]const u8,
    allocator: std.mem.Allocator,
) SessionLogError!T {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            const value = maybe_value orelse return null;
            return try parseEventFieldValue(optional.child, value, allocator);
        },
        else => {
            const value = maybe_value orelse return error.MalformedSessionLog;
            return try parseEventScalar(T, value, allocator);
        },
    }
}

/// Inverse of appendEventScalar: `[]const u8` verbatim (duped), a slice of
/// scalars/structs from all space-separated tokens, everything else from the
/// tokenized value.
fn parseEventScalar(
    comptime T: type,
    value: []const u8,
    allocator: std.mem.Allocator,
) SessionLogError!T {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size != .slice) {
                @compileError("unsupported event field pointer type: " ++ @typeName(T));
            }
            if (pointer.child == u8) return try allocator.dupe(u8, value);
            // Slice of fixed-arity elements (e.g. Vector2): consume elements
            // until the tokens run out.
            var elements: std.ArrayList(pointer.child) = .empty;
            var tokens = std.mem.tokenizeScalar(u8, value, ' ');
            while (tokens.peek() != null) {
                try elements.append(allocator, try parseScalarTokens(pointer.child, &tokens, allocator));
            }
            return try elements.toOwnedSlice(allocator);
        },
        else => {
            var tokens = std.mem.tokenizeScalar(u8, value, ' ');
            return parseScalarTokens(T, &tokens, allocator);
        },
    }
}

/// Parse one value from a token stream: ints/bools/enums consume one token,
/// structs (Vector2, Materials) consume one token per (recursively flattened)
/// field — mirroring appendEventScalar's flattening.
fn parseScalarTokens(
    comptime T: type,
    tokens: anytype,
    allocator: std.mem.Allocator,
) SessionLogError!T {
    switch (@typeInfo(T)) {
        .int => {
            const token = tokens.next() orelse return error.MalformedSessionLog;
            return std.fmt.parseInt(T, token, 10) catch error.MalformedSessionLog;
        },
        .bool => {
            const token = tokens.next() orelse return error.MalformedSessionLog;
            if (std.mem.eql(u8, token, "true")) return true;
            if (std.mem.eql(u8, token, "false")) return false;
            return error.MalformedSessionLog;
        },
        .@"enum" => {
            const token = tokens.next() orelse return error.MalformedSessionLog;
            return std.meta.stringToEnum(T, token) orelse error.MalformedSessionLog;
        },
        .pointer => |pointer| {
            // A string field inside a struct/union payload (e.g. Weapon.name,
            // EntityLayer.sprite). Slices of non-u8 aren't handled here —
            // they go through parseEventScalar's token-stream loop at the top
            // level. The string is duped into the caller's allocator so it
            // outlives the input buffer (mirrors parseEventScalar's []const u8).
            if (pointer.size != .slice) {
                @compileError("unsupported event field pointer type: " ++ @typeName(T));
            }
            if (pointer.child != u8) {
                @compileError("parseScalarTokens: slice of non-u8 not supported inside a struct/union — use a top-level field");
            }
            const token = tokens.next() orelse return error.MalformedSessionLog;
            return try allocator.dupe(u8, token);
        },
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = try parseScalarTokens(field.type, tokens, allocator);
            }
            return result;
        },
        .@"union" => |union_info| {
            // A tagged-union field value: `<tag> <payload-fields...>`. The
            // tag is the first token; for a void payload (e.g.
            // EntityEditTarget.player_def) the tag alone suffices.
            if (union_info.tag_type) |_| {
                const tag_token = tokens.next() orelse return error.MalformedSessionLog;
                inline for (union_info.fields) |field| {
                    if (std.mem.eql(u8, tag_token, field.name)) {
                        if (field.type == void) {
                            return @unionInit(T, field.name, {});
                        } else {
                            const payload = try parseScalarTokens(field.type, tokens, allocator);
                            return @unionInit(T, field.name, payload);
                        }
                    }
                }
                return error.MalformedSessionLog;
            } else {
                @compileError("unsupported event field: untagged union " ++ @typeName(T));
            }
        },
        .array => |array| {
            // Fixed-size array (e.g. [6]Color): consume one element per cell,
            // mirroring appendEventScalar's flattening.
            var result: T = undefined;
            inline for (0..array.len) |index| {
                result[index] = try parseScalarTokens(array.child, tokens, allocator);
            }
            return result;
        },
        else => @compileError("unsupported event field type: " ++ @typeName(T)),
    }
}

// ============================================================
// Tests
// ============================================================

/// Helper to free all memory allocated by parseConfigFile.
fn freeParsedSections(
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

test "loadSettings parses settings sections into a Settings struct" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\
        \\Audio
        \\music_volume 0.8
        \\sound_effects_volume 0.3
        \\
        \\Display
        \\vsync false
        \\render_fps_cap 144
        \\camera_zoom 2.0
        \\
        \\Gameplay
        \\auto_skip_attack_step_out_of_combat false
        \\auto_target_at_cursor true
        \\
        \\InputBindings
        \\input_type key
        \\input_name Space
        \\action skip
        \\
        \\input_type mouse_button
        \\input_name left
        \\ctrl true
        \\action confirm
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const settings = try loadSettings(sections, allocator);
    defer allocator.free(settings.input_bindings);

    // Audio values
    try std.testing.expectApproxEqAbs(0.8, settings.music_volume, 0.001);
    try std.testing.expectApproxEqAbs(0.3, settings.sound_effects_volume, 0.001);

    // Display values
    try std.testing.expectEqual(false, settings.vsync);
    try std.testing.expectEqual(@as(u32, 144), settings.render_fps_cap);
    try std.testing.expectApproxEqAbs(2.0, settings.camera_zoom, 0.001);

    // Gameplay values
    try std.testing.expectEqual(false, settings.auto_skip_attack_step_out_of_combat);
    try std.testing.expectEqual(true, settings.auto_target_at_cursor);

    // Input bindings
    try std.testing.expectEqual(2, settings.input_bindings.len);

    // First binding: Space → skip, no modifiers
    try std.testing.expectEqualStrings("Space", settings.input_bindings[0].input.key);
    try std.testing.expectEqual(.skip, settings.input_bindings[0].action);
    try std.testing.expectEqual(false, settings.input_bindings[0].modifiers.ctrl);

    // Second binding: left mouse + ctrl → confirm
    try std.testing.expectEqualStrings("left", settings.input_bindings[1].input.mouse_button);
    try std.testing.expectEqual(.confirm, settings.input_bindings[1].action);
    try std.testing.expectEqual(true, settings.input_bindings[1].modifiers.ctrl);
}

test "loadWeaponTypeDefinition parses skill IDs from config" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Skills
        \\skill_1 slice
        \\skill_2 spinblade
        \\skill_3 flash_strike
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const definition = try loadWeaponTypeDefinition(sections);

    try std.testing.expectEqual(.slice, definition.skill_1);
    try std.testing.expectEqual(.spinblade, definition.skill_2);
    try std.testing.expectEqual(.flash_strike, definition.skill_3);
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

test "loadLevel parses a complete level" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Test Level
        \\
        \\Layout
        \\  1..
        \\..!..
        \\  ..=
        \\
        \\Enemies
        \\character_code 1
        \\name Skeleton
        \\max_health 10
        \\speed 2
        \\main_hand_weapon_name Bone Sword
        \\main_hand_weapon_type sword
        \\main_hand_weapon_damage 3
        \\
        \\Decorations
        \\
        \\Items
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const level = try loadLevel(sections, null, allocator, "", null);
    defer freeLevel(level, allocator);

    // Metadata
    try std.testing.expectEqualStrings("Test Level", level.name);

    // Level end found
    try std.testing.expect(level.level_end != null);

    // Player is entity index 0
    try std.testing.expectEqualStrings("Player", level.entities[0].name);
    try std.testing.expectEqual(0, level.entities[0].team);

    // Enemy is entity index 1
    try std.testing.expectEqual(2, level.entities.len);
    try std.testing.expectEqualStrings("Skeleton", level.entities[1].name);
    try std.testing.expectEqual(1, level.entities[1].team);
    try std.testing.expectEqual(10, level.entities[1].max_health);
    try std.testing.expectEqual(2, level.entities[1].speed);
    try std.testing.expectEqualStrings("Bone Sword", level.entities[1].main_hand_weapon.?.name);
    try std.testing.expectEqual(3, level.entities[1].main_hand_weapon.?.weapon_damage);

    // Tiles: all '.' and '!' and '=' positions, plus enemy position
    // Layout (top row = y=0, natural reading order):
    //   row 0 (y=0) "  1.." -> tiles at (2,0) enemy, (3,0), (4,0)
    //   row 1 (y=1) "..!.." -> tiles at (0,1), (1,1), (2,1) player, (3,1), (4,1)
    //   row 2 (y=2) "  ..=" -> tiles at (2,2), (3,2), (4,2) level_end
    try std.testing.expectEqual(11, level.level_tiles.len);

    // Player position matches '!' location
    try std.testing.expectEqual(2, level.entities[0].position.x);
    try std.testing.expectEqual(1, level.entities[0].position.y);

    // Level end matches '=' location
    try std.testing.expectEqual(4, level.level_end.?.x);
    try std.testing.expectEqual(2, level.level_end.?.y);
}

test "loadLevel decorations do not create tiles" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Decoration Test
        \\
        \\Layout
        \\.!.
        \\.A.
        \\...
        \\
        \\Enemies
        \\
        \\Decorations
        \\character_code A
        \\sprite stone_1
        \\footprint 0 0
        \\
        \\Items
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const level = try loadLevel(sections, null, allocator, "", null);
    defer freeLevel(level, allocator);

    // 8 tiles: 9 positions minus 1 decoration
    try std.testing.expectEqual(8, level.level_tiles.len);

    // 1 decoration
    try std.testing.expectEqual(1, level.decorations.len);
    try std.testing.expectEqualStrings("stone_1", level.decorations[0].name);

    // Decoration position: row 1 (middle), col 1 -> y=1 (natural reading order)
    // Row 0 (y=0) ".!.", Row 1 (y=1) ".A.", Row 2 (y=2) "..."
    try std.testing.expectEqual(1, level.decorations[0].position.x);
    try std.testing.expectEqual(1, level.decorations[0].position.y);

    // Footprint (sprite-grid) + pixel dims resolved from the comptime table.
    try std.testing.expectEqual(1, level.decorations[0].footprint.len);
    try std.testing.expectEqual(@as(i32, 0), level.decorations[0].footprint[0].x);
    try std.testing.expectEqual(@as(i32, 0), level.decorations[0].footprint[0].y);
    try std.testing.expectEqual(@as(i32, 256), level.decorations[0].pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 256), level.decorations[0].pixel_dims.y);
}

test "loadLevel multi-tile decoration footprint" {
    const allocator = std.testing.allocator;
    // tree_1 is 768x768 = 3x3 bbox. Footprint is just the trunk tile at
    // sprite-grid (1,2) (bottom-middle). The canopy overhangs the other 8
    // bbox tiles — those are NOT footprint tiles and may overlap level tiles.
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Tree Test
        \\
        \\Layout
        \\T..
        \\...
        \\...
        \\
        \\Enemies
        \\
        \\Decorations
        \\character_code T
        \\sprite tree_1
        \\footprint 1 2
        \\
        \\Items
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const level = try loadLevel(sections, null, allocator, "", null);
    defer freeLevel(level, allocator);

    // T is at row 0, col 0 -> world (0, 0) (natural reading order). The
    // footprint world tile is (0, 0) — not a level tile (decoration char adds
    // no tile). The other 8 positions are all '.' -> 8 tiles.
    try std.testing.expectEqual(8, level.level_tiles.len);

    // 1 decoration with a single footprint tile (the trunk).
    try std.testing.expectEqual(1, level.decorations.len);
    try std.testing.expectEqualStrings("tree_1", level.decorations[0].name);
    try std.testing.expectEqual(0, level.decorations[0].position.x);
    try std.testing.expectEqual(0, level.decorations[0].position.y);
    try std.testing.expectEqual(1, level.decorations[0].footprint.len);
    try std.testing.expectEqual(@as(i32, 1), level.decorations[0].footprint[0].x);
    try std.testing.expectEqual(@as(i32, 2), level.decorations[0].footprint[0].y);
    // 768x768 pixel dims from the comptime sprite-metadata table.
    try std.testing.expectEqual(@as(i32, 768), level.decorations[0].pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 768), level.decorations[0].pixel_dims.y);
}

test "loadLevel decoration with layers" {
    const allocator = std.testing.allocator;
    // A decoration with a base (tree_trunk) + a layer (tree_canopy) of the
    // same pixel dims, each with its own color index. Both are real shipped
    // sprites so dims resolve from the comptime table.
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Layer Test
        \\
        \\Layout
        \\T..
        \\...
        \\...
        \\
        \\Enemies
        \\
        \\Decorations
        \\character_code T
        \\sprite tree_1
        \\color_index 4
        \\footprint 1 2
        \\layer
        \\sprite tree_1
        \\color_index 2
        \\
        \\Items
    ;
    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const level = try loadLevel(sections, null, allocator, "", null);
    defer freeLevel(level, allocator);

    try std.testing.expectEqual(1, level.decorations.len);
    try std.testing.expectEqualStrings("tree_1", level.decorations[0].name);
    try std.testing.expectEqual(@as(u32, 4), level.decorations[0].color_index);

    // 1 layer, same sprite (reused for the test), color_index 2, same dims.
    try std.testing.expectEqual(1, level.decorations[0].layers.len);
    try std.testing.expectEqualStrings("tree_1", level.decorations[0].layers[0].sprite);
    try std.testing.expectEqual(@as(u32, 2), level.decorations[0].layers[0].color_index);
    try std.testing.expectEqual(@as(i32, 768), level.decorations[0].layers[0].pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 768), level.decorations[0].layers[0].pixel_dims.y);
}

test "loadDecorationRegistry parses prefabs (no character_code)" {
    const allocator = std.testing.allocator;
    // The shipped registry: Metadata + Decorations with one entry per sprite,
    // no character_code. Entries are blank-line-separated; the tree carries a
    // canopy layer. Read from the embedded map via the real FileSource so the
    // test exercises the shipped file.
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = @import("file_source.zig").FileSource.init(io, std.Io.Dir.cwd());

    const bytes = try file_source.readFile(allocator, "data/decorations.txt");
    defer allocator.free(bytes);
    const sections = try parseConfigFile(bytes, allocator);
    defer freeParsedSections(sections, allocator);

    const registry = try loadDecorationRegistry(sections, &file_source, allocator);
    defer freeDecorationRegistry(registry, allocator);

    // One entry per shipped decoration sprite: tree_1 + 11 ruins + 5 statues
    // + 6 stones = 23. (tree_1_canopy is a layer of tree_1, not its own entry.)
    try std.testing.expectEqual(@as(usize, 23), registry.len);

    // Find the tree entry (first, with a layer) and a stone (single-tile).
    var tree: ?types.DecorationTypeDef = null;
    var stone_6: ?types.DecorationTypeDef = null;
    for (registry) |def| {
        if (std.mem.eql(u8, def.sprite, "tree_1")) tree = def;
        if (std.mem.eql(u8, def.sprite, "stone_6")) stone_6 = def;
    }
    try std.testing.expect(tree != null);
    try std.testing.expect(stone_6 != null);

    // tree_1: 3x3 bbox (768x768), footprint at (1,2), color 4, one canopy
    // layer (color 2, same dims).
    const t = tree.?;
    try std.testing.expectEqual(@as(i32, 768), t.pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 768), t.pixel_dims.y);
    try std.testing.expectEqual(@as(usize, 1), t.footprint.len);
    try std.testing.expectEqual(@as(i32, 1), t.footprint[0].x);
    try std.testing.expectEqual(@as(i32, 2), t.footprint[0].y);
    try std.testing.expectEqual(@as(u32, 4), t.color_index);
    try std.testing.expectEqual(@as(usize, 1), t.layers.len);
    try std.testing.expectEqualStrings("tree_1_canopy", t.layers[0].sprite);
    try std.testing.expectEqual(@as(u32, 2), t.layers[0].color_index);
    try std.testing.expect(std.mem.eql(u8, "tree_1", t.id));

    // stone_6: 1x2 bbox (256x512), footprint at (0,1), color 5, no layers.
    const s = stone_6.?;
    try std.testing.expectEqual(@as(i32, 256), s.pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 512), s.pixel_dims.y);
    try std.testing.expectEqual(@as(usize, 1), s.footprint.len);
    try std.testing.expectEqual(@as(i32, 0), s.footprint[0].x);
    try std.testing.expectEqual(@as(i32, 1), s.footprint[0].y);
    try std.testing.expectEqual(@as(u32, 5), s.color_index);
    try std.testing.expectEqual(@as(usize, 0), s.layers.len);
}

test "boundedU32 clamps out-of-range gear stats and warns" {
    // Out-of-range gear stats are clamped to max + a warning is appended.
    // In-range values pass through unchanged. A null warnings list clamps
    // silently (the test/no-warnings path).
    const allocator = std.testing.allocator;
    var warnings: std.ArrayList([]const u8) = .empty;
    defer warnings.deinit(allocator);

    // Over max → clamped + warned.
    try std.testing.expectEqual(@as(u32, 10), boundedU32("99", max_weapon_damage, "damage", "test.txt", &warnings, allocator));
    try std.testing.expectEqual(@as(u32, 5), boundedU32("6", max_defense_bonus, "armor", "test.txt", &warnings, allocator));
    try std.testing.expectEqual(@as(u32, 2), boundedU32("3", max_boots_speed, "speed", "test.txt", &warnings, allocator));
    // At max → unchanged, no warning.
    try std.testing.expectEqual(@as(u32, 10), boundedU32("10", max_weapon_damage, "damage", "test.txt", &warnings, allocator));
    // Under max → unchanged, no warning.
    try std.testing.expectEqual(@as(u32, 3), boundedU32("3", max_weapon_damage, "damage", "test.txt", &warnings, allocator));
    // Unparseable → 0, no warning.
    try std.testing.expectEqual(@as(u32, 0), boundedU32("abc", max_weapon_damage, "damage", "test.txt", &warnings, allocator));
    // Null warnings → clamps silently.
    try std.testing.expectEqual(@as(u32, 10), boundedU32("99", max_weapon_damage, "damage", "test.txt", null, allocator));

    // 3 warnings appended (the 99, 6, and 3 over-max; the at-max and under-max
    // values produced none).
    try std.testing.expectEqual(@as(usize, 3), warnings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "exceeds max") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "99") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "damage") != null);
    for (warnings.items) |w| allocator.free(w);
}

test "loadLevel rejects unexpected sections" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Bad Level
        \\
        \\Layout
        \\.!.
        \\
        \\Enemies
        \\
        \\Decorations
        \\
        \\Items
        \\
        \\Audio
        \\file_format_version 1
        \\music_volume 0.5
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const result = loadLevel(sections, null, allocator, "", null);
    try std.testing.expectError(error.UnexpectedSection, result);
}

test "loadHub parses a complete hub" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Test Village
        \\
        \\Layout
        \\...N.
        \\.!...
        \\..E..
        \\
        \\NPCs
        \\character_code N
        \\name Blacksmith
        \\
        \\Decorations
        \\
        \\Exits
        \\character_code E
        \\mission_id first_mission
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const hub = try loadHub(sections, null, allocator);
    defer freeHub(hub, allocator);

    // Metadata
    try std.testing.expectEqualStrings("Test Village", hub.name);

    // Player position from '!'
    try std.testing.expectEqualStrings("Player", hub.player.name);
    try std.testing.expectEqual(1, hub.player.position.x);
    try std.testing.expectEqual(1, hub.player.position.y);

    // NPC
    try std.testing.expectEqual(1, hub.npcs.len);
    try std.testing.expectEqualStrings("Blacksmith", hub.npcs[0].entity.name);
    // N at column 3, row 0 -> y=0 (natural reading order)
    try std.testing.expectEqual(3, hub.npcs[0].entity.position.x);
    try std.testing.expectEqual(0, hub.npcs[0].entity.position.y);

    // Mission exit
    try std.testing.expectEqual(1, hub.mission_exits.len);
    try std.testing.expectEqualStrings("first_mission", hub.mission_exits[0].mission_id);
    // E at column 2, row 2 -> y=2
    try std.testing.expectEqual(2, hub.mission_exits[0].position.x);
    try std.testing.expectEqual(2, hub.mission_exits[0].position.y);

    // Tiles: all positions except decorations. No decorations here, so all non-space chars get tiles.
    // 5 + 5 + 5 = 15 total characters, minus 0 spaces = 15... wait, rows are 5 chars each
    // Row 0 "...N." -> 5 tiles (NPC gets a tile)
    // Row 1 ".!..." -> 5 tiles
    // Row 2 "..E.." -> 5 tiles (exit gets a tile)
    try std.testing.expectEqual(15, hub.hub_tiles.len);
}

test "loadCampaign parses campaign metadata" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Main Campaign
        \\start_hub starting_village
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const campaign = try loadCampaign(sections, allocator);

    try std.testing.expectEqualStrings("Main Campaign", campaign.name);
    try std.testing.expectEqualStrings("starting_village", campaign.start_hub);
}

test "loadMission parses mission metadata" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name First Mission
        \\start_hub camp
        \\end_hub village
        \\level_count 3
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const mission = try loadMission(sections, allocator);

    try std.testing.expectEqualStrings("First Mission", mission.name);
    try std.testing.expectEqualStrings("camp", mission.start_hub.?);
    try std.testing.expectEqualStrings("village", mission.end_hub.?);
    try std.testing.expectEqual(3, mission.level_count);
}

test "loadPlayerSave parses a save file" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\
        \\Info
        \\player_name Test Player
        \\turns 100
        \\deaths 3
        \\defeated_enemies 42
        \\wood_salvage 50
        \\metal_salvage 60
        \\
        \\DiscoveredHubs
        \\
        \\UnlockedSkills
        \\name slice
        \\
        \\name replenish
        \\
        \\MainHandWeapon
        \\item_name Iron Sword
        \\weapon_type sword
        \\damage 5
        \\
        \\OffHandWeapon
        \\item_name Wooden Shield
        \\weapon_type shield
        \\damage 2
        \\
        \\Amulet
        \\item_name Basic Amulet
        \\spell_damage 3
        \\
        \\Coat
        \\item_name Leather Coat
        \\armor 1
        \\health 2
        \\
        \\Gloves
        \\item_name Leather Gloves
        \\damage 1
        \\health 1
        \\
        \\Pants
        \\item_name Leather Pants
        \\pickup_radius 1
        \\health 1
        \\
        \\Boots
        \\item_name Leather Boots
        \\speed 1
        \\health 1
        \\
        \\Inventory
        \\item_type weapon
        \\item_name Rusty Dagger
        \\weapon_type dagger
        \\damage 3
        \\slot 1
        \\
        \\item_type coat
        \\item_name Old Coat
        \\armor 0
        \\health 1
        \\slot 2
        \\
        \\UtilitySkills
        \\slot_4 replenish
        \\
        \\CloneData
        \\clone_name First Clone
        \\wood 10
        \\metal 20
        \\leather 5
        \\cloth 5
        \\knowledge 0
        \\turns_to_complete 15
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const player_data = try loadPlayerSave(sections, allocator, "", null);
    defer allocator.free(player_data.learned_skills);
    defer allocator.free(player_data.clones);

    // Info
    try std.testing.expectEqualStrings("Test Player", player_data.player_name);
    try std.testing.expectEqual(100, player_data.turns);
    try std.testing.expectEqual(3, player_data.deaths);
    try std.testing.expectEqual(42, player_data.defeated_enemies);
    try std.testing.expectEqual(50, player_data.materials.wood);
    try std.testing.expectEqual(60, player_data.materials.metal);

    // Unlocked skills
    try std.testing.expectEqual(2, player_data.learned_skills.len);

    // Equipment
    try std.testing.expectEqualStrings("Iron Sword", player_data.main_hand_weapon.?.name);
    try std.testing.expectEqual(5, player_data.main_hand_weapon.?.weapon_damage);
    try std.testing.expectEqualStrings("Wooden Shield", player_data.off_hand_weapon.?.name);
    try std.testing.expectEqual(.shield, player_data.off_hand_weapon.?.weapon_type);
    try std.testing.expectEqual(3, player_data.amulet.?.spell_damage);
    try std.testing.expectEqual(1, player_data.coat.?.defense_bonus);
    try std.testing.expectEqual(1, player_data.gloves.?.damage_bonus);
    try std.testing.expectEqual(1, player_data.pants.?.pickup_radius_bonus);
    try std.testing.expectEqual(1, player_data.boots.?.speed_bonus);

    // Inventory — items at slots 1 and 2
    try std.testing.expect(player_data.inventory.slots[1] != null);
    try std.testing.expect(player_data.inventory.slots[2] != null);
    try std.testing.expectEqualStrings("Rusty Dagger", player_data.inventory.slots[1].?.weapon.name);
    try std.testing.expectEqualStrings("Old Coat", player_data.inventory.slots[2].?.coat.name);

    // Utility skills — first slot is replenish, rest are defaults
    try std.testing.expectEqual(.replenish, player_data.equipped_utility_skills[0]);

    // Clone data
    try std.testing.expectEqual(1, player_data.clones.len);
    try std.testing.expectEqualStrings("First Clone", player_data.clones[0].name);
    try std.testing.expectEqual(15, player_data.clones[0].turns_to_complete);
    try std.testing.expectEqual(10, player_data.clones[0].materials_collected.wood);
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
        .learned_skills = &.{ .slice, .replenish },
        // Gap in the middle: slots 5 and 7-8 empty, to verify the save writer
        // and loader preserve slot positions instead of compacting.
        .equipped_utility_skills = .{ .replenish, null, .slice, null, null },
        .clones = &.{.{
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
    try std.testing.expectEqual(2, loaded.learned_skills.len);
    try std.testing.expectEqual(.slice, loaded.learned_skills[0]);
    try std.testing.expectEqual(.replenish, loaded.learned_skills[1]);
    try std.testing.expectEqual(.replenish, loaded.equipped_utility_skills[0]);
    try std.testing.expectEqual(null, loaded.equipped_utility_skills[1]);
    try std.testing.expectEqual(.slice, loaded.equipped_utility_skills[2]);
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

test "loadColorThemeDefinitions parses global colors and gradients" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\
        \\GlobalColors
        \\lightest #FFFFF0
        \\darkest #140F19
        \\
        \\Gradients
        \\gradient_index 0
        \\color_0 #C83C3C
        \\color_1 #A02828
        \\color_2 #781E1E
        \\color_3 #5A1414
        \\color_4 #3C0F0F
        \\color_5 #280A0A
        \\
        \\gradient_index 1
        \\color_0 #3C3CC8
        \\color_1 #2828A0
        \\color_2 #1E1E78
        \\color_3 #14145A
        \\color_4 #0F0F3C
        \\color_5 #0A0A28
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const theme = try loadColorThemeDefinitions(sections, allocator);
    defer allocator.free(theme.gradients);

    // Global colors
    try std.testing.expectEqual(255, theme.lightest.r);
    try std.testing.expectEqual(255, theme.lightest.g);
    try std.testing.expectEqual(240, theme.lightest.b);
    try std.testing.expectEqual(20, theme.darkest.r);
    try std.testing.expectEqual(15, theme.darkest.g);
    try std.testing.expectEqual(25, theme.darkest.b);

    // Two gradients
    try std.testing.expectEqual(2, theme.gradients.len);

    // First gradient, first color
    try std.testing.expectEqual(0xC8, theme.gradients[0].colors[0].r);
    try std.testing.expectEqual(0x3C, theme.gradients[0].colors[0].g);
    try std.testing.expectEqual(0x3C, theme.gradients[0].colors[0].b);

    // First gradient, last color
    try std.testing.expectEqual(0x28, theme.gradients[0].colors[5].r);
    try std.testing.expectEqual(0x0A, theme.gradients[0].colors[5].g);
    try std.testing.expectEqual(0x0A, theme.gradients[0].colors[5].b);

    // Second gradient, first color
    try std.testing.expectEqual(0x3C, theme.gradients[1].colors[0].r);
    try std.testing.expectEqual(0x3C, theme.gradients[1].colors[0].g);
    try std.testing.expectEqual(0xC8, theme.gradients[1].colors[0].b);
}

test "deriveActiveColorTheme picks evenly spaced gradients" {
    // Create a theme with 9 gradients (so offsets of 3 and 6)
    var gradients: [9]types.ColorGradient = undefined;
    for (&gradients, 0..) |*gradient, index| {
        const value: u8 = @intCast(index * 20 + 10);
        gradient.* = .{
            .colors = .{Color{ .r = value, .g = value, .b = value }} ** types.gradient_color_count,
        };
    }

    const theme = ColorThemeDefinitions{
        .lightest = .{ .r = 255, .g = 255, .b = 240 },
        .darkest = .{ .r = 20, .g = 15, .b = 25 },
        .gradients = &gradients,
    };

    // With world at index 0, enemy at 3, player at 6
    const active = deriveActiveColorTheme(theme, 0);
    try std.testing.expectEqual(10, active.world_gradient.colors[0].r); // gradient 0
    try std.testing.expectEqual(70, active.enemy_gradient.colors[0].r); // gradient 3
    try std.testing.expectEqual(130, active.player_gradient.colors[0].r); // gradient 6
}

test "color_themes.txt parses from disk" {
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    const parsed = try parseConfigFileFromPath(
        &file_source,
        "data/color_themes.txt",
        allocator,
    );
    defer allocator.free(parsed.raw_text);
    defer freeParsedSections(parsed.sections, allocator);

    const theme = try loadColorThemeDefinitions(parsed.sections, allocator);
    defer allocator.free(theme.gradients);

    // Should have 3 gradients (world / enemy / player for the first full theme).
    try std.testing.expectEqual(3, theme.gradients.len);

    // Lightest and darkest should be parsed
    try std.testing.expectEqual(0xfe, theme.lightest.r);
    try std.testing.expectEqual(0x4c, theme.darkest.r);
}

// ============================================================
// Salvage definitions
// ============================================================

const salvage_sections = [_][]const u8{
    "Sword",  "Shield", "Spear",    "Dagger",
    "Axe",    "Staff",  "Crossbow", "Idol",
    "Amulet", "Coat",   "Gloves",   "Pants",
    "Boots",  "SkillTome",
};

fn parseSalvageSplits(
    section: Section,
    allocator: std.mem.Allocator,
) !SalvageDefinition {
    if (section.entry_groups.len == 0) return .{ .splits = &.{} };

    var splits: std.ArrayList(SalvageSplit) = .empty;
    for (section.entry_groups) |group| {
        for (group.pairs) |pair| {
            const material = parseEnum(MaterialType, pair.key) orelse return error.InvalidData;
            const parts = asU32(pair.value) orelse return error.InvalidData;
            splits.append(allocator, .{
                .material = material,
                .parts = parts,
            }) catch return error.OutOfMemory;
        }
    }

    return .{
        .splits = splits.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

fn loadWeaponSalvage(
    sections: []const Section,
    comptime header: []const u8,
    allocator: std.mem.Allocator,
) !SalvageDefinition {
    const section = findSection(sections, header) orelse return .{ .splits = &.{} };
    return parseSalvageSplits(section, allocator);
}

pub fn loadSalvageDefinitions(
    sections: []const Section,
    allocator: std.mem.Allocator,
) !SalvageDefinitions {
    try validateSections(sections, &salvage_sections);

    const weapon_type_fields = @typeInfo(WeaponType).@"enum".fields;
    var weapon_definitions: [types.weapon_type_count]SalvageDefinition = undefined;

    inline for (weapon_type_fields, 0..) |field, index| {
        const capitalized = comptime blk: {
            var name: [field.name.len]u8 = undefined;
            @memcpy(&name, field.name);
            name[0] = std.ascii.toUpper(name[0]);
            break :blk name;
        };
        weapon_definitions[index] = try loadWeaponSalvage(sections, &capitalized, allocator);
    }

    return .{
        .weapon = weapon_definitions,
        .amulet = try parseSalvageSplits(findSection(sections, "Amulet") orelse return error.InvalidData, allocator),
        .coat = try parseSalvageSplits(findSection(sections, "Coat") orelse return error.InvalidData, allocator),
        .gloves = try parseSalvageSplits(findSection(sections, "Gloves") orelse return error.InvalidData, allocator),
        .pants = try parseSalvageSplits(findSection(sections, "Pants") orelse return error.InvalidData, allocator),
        .boots = try parseSalvageSplits(findSection(sections, "Boots") orelse return error.InvalidData, allocator),
        .skill_tome = try parseSalvageSplits(findSection(sections, "SkillTome") orelse return error.InvalidData, allocator),
    };
}

test "game_version is populated from the build seam" {
    // Verifies the build.zig version seam reaches code: YYYY.MM.<count>[-dirty].
    // Not asserting exact digits (they change per commit/date); just the shape.
    const version = build_info.game_version;
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.count(u8, version, ".") >= 2);
}

test "writeEventLog serializes representative event shapes" {
    const allocator = std.testing.allocator;

    const history = [_]Event{
        // void payload
        .{ .meta_event = .open_main_menu },
        // struct with a Vector2
        .{ .hub_event = .{ .move_player = .{ .destination = .{ .x = 3, .y = 4 } } } },
        // optional present (target) + enum
        .{ .level_event = .{ .use_skill = .{
            .caster_index = 0,
            .skill_id = .slice,
            .target = .{ .x = 2, .y = 5 },
        } } },
        // optional absent (target null) -> the line is omitted
        .{ .level_event = .{ .use_skill = .{
            .caster_index = 1,
            .skill_id = .slice,
            .target = null,
        } } },
        // bool fields (via defaults)
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = 0,
            .defender_index = 3,
            .outgoing_damage = 12,
        } } },
        // signed int
        .{ .sub_level_event = .{ .change_momentum = .{ .entity_index = 2, .delta = -1 } } },
        // slice of structs (flattened) + an empty slice
        .{ .level_event = .{ .highlight_tiles = .{ .tile_positions = &.{
            .{ .x = 1, .y = 2 },
            .{ .x = 3, .y = 4 },
        } } } },
        .{ .level_event = .{ .highlight_tiles = .{ .tile_positions = &.{} } } },
        // string + Materials struct
        .{ .super_event = .{ .save_clone_info = .{
            .mission_name = "first_mission",
            .total_turns = 7,
            .total_materials = .{ .wood = 1, .metal = 2, .leather = 3, .cloth = 4, .knowledge = 5 },
        } } },
    };

    const output = try writeEventLog(&history, "20260815_143022", allocator);
    defer allocator.free(output);

    // Metadata header
    try std.testing.expect(std.mem.indexOf(u8, output, "file_format_version 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "game_version ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "created 20260815_143022\n") != null);

    // Discriminators + field shapes
    try std.testing.expect(std.mem.indexOf(u8, output, "event meta_event open_main_menu\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event hub_event move_player\ndestination 3 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event level_event use_skill\ncaster_index 0\nskill_id slice\ntarget 2 5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "outgoing_damage 12\ntriggers_effects true\nheals_attacker false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "delta -1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mission_name first_mission\ntotal_turns 7\ntotal_materials 1 2 3 4 5\n") != null);
    // Slice of Vector2 flattened; empty slice writes an empty value.
    try std.testing.expect(std.mem.indexOf(u8, output, "event level_event highlight_tiles\ntile_positions 1 2 3 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event level_event highlight_tiles\ntile_positions \n") != null);

    // Null optional omits its line: exactly one "target " across both use_skills.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\ntarget "));

    // The output round-trips through the generic config parser structurally:
    // Metadata + EventLog sections, with one entry group per event.
    const sections = try parseConfigFile(output, allocator);
    defer freeParsedSections(sections, allocator);
    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expectEqualStrings("Metadata", sections[0].header);
    try std.testing.expectEqualStrings("EventLog", sections[1].header);
    try std.testing.expectEqual(history.len, sections[1].entry_groups.len);
    // Each event group begins with the decorative `event_index` header, then
    // the `event` discriminator (event_index is purely for human readability
    // — the reader ignores it).
    try std.testing.expectEqualStrings("event_index", sections[1].entry_groups[0].pairs[0].key);
    try std.testing.expectEqualStrings("0", sections[1].entry_groups[0].pairs[0].value);
    try std.testing.expectEqualStrings("event", sections[1].entry_groups[0].pairs[1].key);
    try std.testing.expectEqualStrings("meta_event open_main_menu", sections[1].entry_groups[0].pairs[1].value);
}

test "data/default_settings.txt binds ctrl+L to dump_event_log" {
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

    const settings = try loadSettings(parsed.sections, allocator);
    defer allocator.free(settings.input_bindings);

    var found = false;
    for (settings.input_bindings) |binding| {
        if (binding.action == .dump_event_log) {
            found = true;
            try std.testing.expect(binding.modifiers.ctrl);
            switch (binding.input) {
                .key => |key| try std.testing.expectEqualStrings("KeyL", key),
                else => return error.TestUnexpectedResult,
            }
        }
    }
    try std.testing.expect(found);
}

test "writeEventLog / loadEventLog round-trips an event history" {
    const allocator = std.testing.allocator;

    const history = [_]Event{
        .{ .meta_event = .open_main_menu },
        // ?[]const u8 present (start_hub_id) + absent (end_hub_id omitted) + string
        .{ .meta_event = .{ .start_mission = .{
            .mission_path = "data/campaigns/main/missions/first",
            .start_hub_id = "starting_village",
            .end_hub_id = null,
        } } },
        .{ .meta_event = .{ .wait = .{ .duration_milliseconds = 500 } } },
        .{ .hub_event = .{ .move_player = .{ .destination = .{ .x = 2, .y = 0 } } } },
        // ?Vector2 present + enum
        .{ .level_event = .{ .use_skill = .{
            .caster_index = 0,
            .skill_id = .slice,
            .target = .{ .x = 4, .y = 2 },
        } } },
        // ?Vector2 absent
        .{ .level_event = .{ .use_skill = .{
            .caster_index = 0,
            .skill_id = .spinblade,
            .target = null,
        } } },
        // bools (incl. a non-default false triggers_effects)
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = 0,
            .defender_index = 1,
            .outgoing_damage = 5,
            .triggers_effects = false,
            .heals_attacker = false,
        } } },
        .{ .sub_level_event = .{ .change_momentum = .{ .entity_index = 2, .delta = -3 } } },
        .{ .sub_level_event = .{ .create_effect = .{
            .caster_index = 1,
            .receiver_index = 1,
            .effect_id = .reflect,
            .duration = 1,
        } } },
        .{ .sub_level_event = .{ .death = .{ .entity_index = 1 } } },
        // slice of Vector2 (non-empty + empty)
        .{ .level_event = .{ .highlight_tiles = .{ .tile_positions = &.{
            .{ .x = 1, .y = 2 },
            .{ .x = 3, .y = 4 },
            .{ .x = 5, .y = 6 },
        } } } },
        .{ .level_event = .{ .highlight_tiles = .{ .tile_positions = &.{} } } },
        // GearSlot enum + Materials struct
        .{ .player_event = .{ .equip_item = .{ .inventory_slot_index = 7, .gear_slot = .boots } } },
        .{ .super_event = .{ .save_clone_info = .{
            .mission_name = "first",
            .total_turns = 9,
            .total_materials = .{ .wood = 1, .metal = 0, .leather = 2, .cloth = 3, .knowledge = 4 },
        } } },
    };

    const body = try writeEventLog(&history, "20260818_142958", allocator);
    defer allocator.free(body);

    const sections = try parseConfigFile(body, allocator);
    defer freeParsedSections(sections, allocator);

    // Reader allocations go on an arena for easy cleanup.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const log = try loadEventLog(sections, arena.allocator());

    try std.testing.expectEqual(session_log_file_format_version, log.file_format_version);
    try std.testing.expectEqualStrings("20260818_142958", log.created);
    try std.testing.expectEqualDeep(history[0..], log.events);
}

test "loadEventLog rejects an unsupported file_format_version" {
    const allocator = std.testing.allocator;
    const raw =
        \\Metadata
        \\file_format_version 999
        \\game_version test
        \\created 20260818_000000
        \\
        \\EventLog
        \\
        \\event meta_event open_main_menu
    ;
    const sections = try parseConfigFile(raw, allocator);
    defer freeParsedSections(sections, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnsupportedFileFormatVersion,
        loadEventLog(sections, arena.allocator()),
    );
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
