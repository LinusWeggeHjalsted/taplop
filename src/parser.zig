const std = @import("std");
const types = @import("types.zig");

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
/// For example, each input binding in settings.txt is one entry group.
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

/// Read a file from disk and parse it into sections.
pub fn parseConfigFileFromPath(
    directory: std.Io.Dir,
    io: std.Io,
    file_path: []const u8,
    allocator: std.mem.Allocator,
) !ParsedConfigFile {
    const raw_text = try directory.readFileAlloc(io, file_path, allocator, .limited(1024 * 1024));
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

pub fn asU32(value: []const u8) ?u32 {
    return std.fmt.parseInt(u32, value, 10) catch null;
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

const settings_sections = [_][]const u8{ "Audio", "Display", "Gameplay", "InputBindings" };
const weapon_type_sections = [_][]const u8{"Skills"};
const level_sections = [_][]const u8{ "Metadata", "Layout", "Enemies", "Decorations", "Items" };
const hub_sections = [_][]const u8{ "Metadata", "Layout", "NPCs", "Decorations", "Exits" };
const campaign_sections = [_][]const u8{"Metadata"};
const mission_sections = [_][]const u8{"Metadata"};
const player_save_sections = [_][]const u8{
    "Info",           "DiscoveredHubs",  "UnlockedSkills", "MainHandWeapon",
    "OffHandWeapon",  "Amulet",          "Coat",           "Gloves",
    "Pants",          "Boots",           "Inventory",      "UtilitySkills",
    "CloneData",
};

pub fn loadSettings(
    sections: []const Section,
    allocator: std.mem.Allocator,
) !Settings {
    try validateSections(sections, &settings_sections);
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
            if (findValue(pairs, "camera_zoom")) |value| {
                settings.camera_zoom = asF32(value) orelse settings.camera_zoom;
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

pub fn loadLevel(
    sections: []const Section,
    allocator: std.mem.Allocator,
) !Level {
    try validateSections(sections, &level_sections);
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

    // Collect decoration character codes so layout parsing knows which chars block tiles
    var decoration_codes: std.ArrayList(u8) = .empty;
    defer decoration_codes.deinit(allocator);
    if (findSection(sections, "Decorations")) |section| {
        for (section.entry_groups) |group| {
            const code_string = findValue(group.pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;
            try decoration_codes.append(allocator, code_string[0]);
        }
    }

    // Parse enemy definitions keyed by character code
    var enemy_definitions = std.AutoHashMap(u8, types.Entity).init(allocator);
    defer enemy_definitions.deinit();
    if (findSection(sections, "Enemies")) |section| {
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const code_string = findValue(pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;

            var entity: types.Entity = .{
                .team = 1, // enemies are team 1
            };

            if (findValue(pairs, "name")) |value| entity.name = value;
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
                    .weapon_damage = if (findValue(pairs, "main_hand_weapon_damage")) |value| asU32(value) orelse 0 else 0,
                };
            }

            // Off hand weapon
            if (findValue(pairs, "off_hand_weapon_name")) |name| {
                entity.off_hand_weapon = .{
                    .name = name,
                    .weapon_type = if (findValue(pairs, "off_hand_weapon_type")) |value| parseEnum(types.WeaponType, value) orelse .sword else .sword,
                    .weapon_damage = if (findValue(pairs, "off_hand_weapon_damage")) |value| asU32(value) orelse 0 else 0,
                };
            }

            // Gear
            if (findValue(pairs, "amulet_name")) |name| {
                entity.amulet = .{
                    .name = name,
                    .spell_damage = if (findValue(pairs, "amulet_spell_damage")) |value| asU32(value) orelse 0 else 0,
                };
            }
            if (findValue(pairs, "coat_name")) |name| {
                entity.coat = .{
                    .name = name,
                    .defense_bonus = if (findValue(pairs, "coat_defense_bonus")) |value| asU32(value) orelse 0 else 0,
                    .health_bonus = if (findValue(pairs, "coat_health_bonus")) |value| asU32(value) orelse 0 else 0,
                };
            }
            if (findValue(pairs, "gloves_name")) |name| {
                entity.gloves = .{
                    .name = name,
                    .damage_bonus = if (findValue(pairs, "gloves_damage_bonus")) |value| asU32(value) orelse 0 else 0,
                    .health_bonus = if (findValue(pairs, "gloves_health_bonus")) |value| asU32(value) orelse 0 else 0,
                };
            }
            if (findValue(pairs, "pants_name")) |name| {
                entity.pants = .{
                    .name = name,
                    .pickup_radius_bonus = if (findValue(pairs, "pants_pickup_radius_bonus")) |value| asU32(value) orelse 0 else 0,
                    .health_bonus = if (findValue(pairs, "pants_health_bonus")) |value| asU32(value) orelse 0 else 0,
                };
            }
            if (findValue(pairs, "boots_name")) |name| {
                entity.boots = .{
                    .name = name,
                    .speed_bonus = if (findValue(pairs, "boots_speed_bonus")) |value| asU32(value) orelse 0 else 0,
                    .health_bonus = if (findValue(pairs, "boots_health_bonus")) |value| asU32(value) orelse 0 else 0,
                };
            }

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
                    .weapon_damage = asU32(findValue(pairs, "damage") orelse "0") orelse 0,
                } },
                .amulet => .{ .amulet = .{
                    .name = item_name,
                    .spell_damage = asU32(findValue(pairs, "spell_damage") orelse "0") orelse 0,
                } },
                .coat => .{ .coat = .{
                    .name = item_name,
                    .defense_bonus = asU32(findValue(pairs, "defense") orelse "0") orelse 0,
                    .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
                } },
                .gloves => .{ .gloves = .{
                    .name = item_name,
                    .damage_bonus = asU32(findValue(pairs, "damage") orelse "0") orelse 0,
                    .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
                } },
                .pants => .{ .pants = .{
                    .name = item_name,
                    .pickup_radius_bonus = asU32(findValue(pairs, "pickup_radius") orelse "0") orelse 0,
                    .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
                } },
                .boots => .{ .boots = .{
                    .name = item_name,
                    .speed_bonus = asU32(findValue(pairs, "speed") orelse "0") orelse 0,
                    .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
                } },
            };

            try item_definitions.put(code_string[0], item);
        }
    }

    // Parse layout grid
    var tile_positions: std.ArrayList(types.Vector2) = .empty;
    // Player is always entity index 0
    var entity_list: std.ArrayList(types.Entity) = .empty;
    try entity_list.append(allocator, .{ .name = "Player", .team = 0 });
    var decoration_list: std.ArrayList(types.Decoration) = .empty;
    var ground_item_list: std.ArrayList(types.GroundItems) = .empty;
    var player_start: ?types.Vector2 = null;

    if (findSection(sections, "Layout")) |section| {
        const row_count: i32 = @intCast(section.raw_lines.len);
        for (section.raw_lines, 0..) |row, raw_y| {
            const y: i32 = row_count - 1 - @as(i32, @intCast(raw_y));
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
                        var is_decoration = false;
                        for (decoration_codes.items) |code| {
                            if (character == code) {
                                is_decoration = true;
                                break;
                            }
                        }

                        if (!is_decoration) {
                            try tile_positions.append(allocator, position);
                        }

                        // Match character to enemy, decoration, or item definition
                        if (enemy_definitions.get(character)) |definition| {
                            var entity = definition;
                            entity.position = position;
                            try entity_list.append(allocator, entity);
                        } else if (is_decoration) {
                            // Decoration info is parsed from the Decorations section entry groups
                            // For now, create a basic decoration with the position
                            if (findSection(sections, "Decorations")) |decoration_section| {
                                for (decoration_section.entry_groups) |group| {
                                    const code_string = findValue(group.pairs, "character_code") orelse continue;
                                    if (code_string.len == 1 and code_string[0] == character) {
                                        try decoration_list.append(allocator, .{
                                            .decoration_id = null,
                                            .name = findValue(group.pairs, "sprite") orelse &.{},
                                            .position = position,
                                            .footprint = &.{position},
                                        });
                                        break;
                                    }
                                }
                            }
                        } else if (item_definitions.get(character)) |item| {
                            const items = try allocator.alloc(types.Item, 1);
                            items[0] = item;
                            try ground_item_list.append(allocator, .{
                                .position = position,
                                .items = items,
                            });
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

    level.level_tiles = try tile_positions.toOwnedSlice(allocator);
    level.entities = try entity_list.toOwnedSlice(allocator);
    level.decorations = try decoration_list.toOwnedSlice(allocator);
    level.ground_items = try ground_item_list.toOwnedSlice(allocator);

    return level;
}

pub fn loadHub(
    sections: []const Section,
    allocator: std.mem.Allocator,
) !Hub {
    try validateSections(sections, &hub_sections);
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

    // Collect decoration character codes
    var decoration_codes: std.ArrayList(u8) = .empty;
    defer decoration_codes.deinit(allocator);
    if (findSection(sections, "Decorations")) |section| {
        for (section.entry_groups) |group| {
            const code_string = findValue(group.pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;
            try decoration_codes.append(allocator, code_string[0]);
        }
    }

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
            try npc_definitions.put(code_string[0], .{ .entity = entity });
        }
    }

    // Parse layout grid
    var tile_positions: std.ArrayList(types.Vector2) = .empty;
    var decoration_list: std.ArrayList(types.Decoration) = .empty;
    var npc_list: std.ArrayList(types.NPC) = .empty;
    var exit_list: std.ArrayList(types.MissionExit) = .empty;

    if (findSection(sections, "Layout")) |section| {
        const row_count: i32 = @intCast(section.raw_lines.len);
        for (section.raw_lines, 0..) |row, raw_y| {
            const y: i32 = row_count - 1 - @as(i32, @intCast(raw_y));
            for (row, 0..) |character, raw_x| {
                const x: i32 = @intCast(raw_x);
                const position = types.Vector2{ .x = x, .y = y };

                switch (character) {
                    ' ' => {},
                    '.' => try tile_positions.append(allocator, position),
                    '!' => {
                        hub.player.position = position;
                        hub.player.name = "Player";
                        try tile_positions.append(allocator, position);
                    },
                    else => {
                        var is_decoration = false;
                        for (decoration_codes.items) |code| {
                            if (character == code) {
                                is_decoration = true;
                                break;
                            }
                        }

                        if (!is_decoration) {
                            try tile_positions.append(allocator, position);
                        }

                        if (is_decoration) {
                            if (findSection(sections, "Decorations")) |decoration_section| {
                                for (decoration_section.entry_groups) |group| {
                                    const code_string = findValue(group.pairs, "character_code") orelse continue;
                                    if (code_string.len == 1 and code_string[0] == character) {
                                        try decoration_list.append(allocator, .{
                                            .decoration_id = null,
                                            .name = findValue(group.pairs, "sprite") orelse &.{},
                                            .position = position,
                                            .footprint = &.{position},
                                        });
                                        break;
                                    }
                                }
                            }
                        } else if (exit_definitions.getPtr(character)) |exit| {
                            exit.position = position;
                            try exit_list.append(allocator, exit.*);
                        } else if (npc_definitions.getPtr(character)) |npc| {
                            npc.entity.position = position;
                            try npc_list.append(allocator, npc.*);
                        }
                    },
                }
            }
        }
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
) !PlayerData {
    try validateSections(sections, &player_save_sections);
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
                .weapon_damage = asU32(findValue(pairs, "damage") orelse "0") orelse 0,
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
                .weapon_damage = asU32(findValue(pairs, "damage") orelse "0") orelse 0,
            };
        }
    }

    // Amulet
    if (findSection(sections, "Amulet")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.amulet = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .spell_damage = asU32(findValue(pairs, "spell_damage") orelse "0") orelse 0,
            };
        }
    }

    // Coat
    if (findSection(sections, "Coat")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.coat = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .defense_bonus = asU32(findValue(pairs, "armor") orelse "0") orelse 0,
                .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
            };
        }
    }

    // Gloves
    if (findSection(sections, "Gloves")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.gloves = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .damage_bonus = asU32(findValue(pairs, "damage") orelse "0") orelse 0,
                .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
            };
        }
    }

    // Pants
    if (findSection(sections, "Pants")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.pants = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .pickup_radius_bonus = asU32(findValue(pairs, "pickup_radius") orelse "0") orelse 0,
                .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
            };
        }
    }

    // Boots
    if (findSection(sections, "Boots")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.boots = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .speed_bonus = asU32(findValue(pairs, "speed") orelse "0") orelse 0,
                .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
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
                    .weapon_damage = asU32(findValue(pairs, "damage") orelse "0") orelse 0,
                } },
                .amulet => .{ .amulet = .{
                    .name = item_name,
                    .spell_damage = asU32(findValue(pairs, "spell_damage") orelse "0") orelse 0,
                } },
                .coat => .{ .coat = .{
                    .name = item_name,
                    .defense_bonus = asU32(findValue(pairs, "armor") orelse "0") orelse 0,
                    .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
                } },
                .gloves => .{ .gloves = .{
                    .name = item_name,
                    .damage_bonus = asU32(findValue(pairs, "damage") orelse "0") orelse 0,
                    .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
                } },
                .pants => .{ .pants = .{
                    .name = item_name,
                    .pickup_radius_bonus = asU32(findValue(pairs, "pickup_radius") orelse "0") orelse 0,
                    .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
                } },
                .boots => .{ .boots = .{
                    .name = item_name,
                    .speed_bonus = asU32(findValue(pairs, "speed") orelse "0") orelse 0,
                    .health_bonus = asU32(findValue(pairs, "health") orelse "0") orelse 0,
                } },
                .skill_tome => .{ .skill_tome = .{
                    .skill = parseEnum(types.SkillId, findValue(pairs, "skill_name") orelse "") orelse continue,
                } },
            };

            player_data.inventory.slots[slot_index] = item;
        }
    }

    // UtilitySkills
    if (findSection(sections, "UtilitySkills")) |section| {
        if (section.entry_groups.len > 0) {
            var slot_index: usize = 0;
            for (section.entry_groups[0].pairs) |pair| {
                if (parseEnum(types.SkillId, pair.value)) |skill_id| {
                    if (slot_index < types.utility_skill_count) {
                        player_data.equipped_utility_skills[slot_index] = skill_id;
                        slot_index += 1;
                    }
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

const color_theme_sections = [_][]const u8{ "GlobalColors", "Gradients" };

pub fn loadColorThemeDefinitions(
    sections: []const Section,
    allocator: std.mem.Allocator,
) !ColorThemeDefinitions {
    try validateSections(sections, &color_theme_sections);

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
    try buffer.appendSlice(allocator, "Info\n");
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
    try buffer.appendSlice(allocator, "\nUtilitySkills\n");
    for (player_data.equipped_utility_skills, 0..) |skill_id, index| {
        const slot_number = index + 4; // slots start at 4
        try buffer.print(allocator, "slot_{d} {s}\n", .{ slot_number, @tagName(skill_id) });
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

/// Write a PlayerData struct to a file on disk (standalone mode).
pub fn writePlayerSaveToFile(
    directory: std.Io.Dir,
    io: std.Io,
    file_path: []const u8,
    player_data: PlayerData,
    allocator: std.mem.Allocator,
) !void {
    const save_data = try writePlayerSave(player_data, allocator);
    defer allocator.free(save_data);
    try directory.writeFile(io, .{
        .sub_path = file_path,
        .data = save_data,
    });
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
    try std.testing.expectEqualStrings("Metadata", sections[3].header);

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

    const parsed = try parseConfigFileFromPath(
        std.Io.Dir.cwd(),
        io,
        "data/settings.txt",
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
        \\Audio
        \\music_volume 0.8
        \\sound_effects_volume 0.3
        \\
        \\Display
        \\vsync false
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

    const level = try loadLevel(sections, allocator);
    defer allocator.free(level.level_tiles);
    defer allocator.free(level.entities);
    defer allocator.free(level.decorations);
    defer allocator.free(level.ground_items);

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
    // Layout (flipped Y):
    //   row 0 "  1.." -> y=2: tiles at (2,2) enemy, (3,2), (4,2)
    //   row 1 "..!.." -> y=1: tiles at (0,1), (1,1), (2,1) player, (3,1), (4,1)
    //   row 2 "  ..=" -> y=0: tiles at (2,0), (3,0), (4,0) level_end
    try std.testing.expectEqual(11, level.level_tiles.len);

    // Player position matches '!' location
    try std.testing.expectEqual(2, level.entities[0].position.x);
    try std.testing.expectEqual(1, level.entities[0].position.y);

    // Level end matches '=' location
    try std.testing.expectEqual(4, level.level_end.?.x);
    try std.testing.expectEqual(0, level.level_end.?.y);
}

test "loadLevel decorations do not create tiles" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
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
        \\sprite BigTree
        \\
        \\Items
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const level = try loadLevel(sections, allocator);
    defer allocator.free(level.level_tiles);
    defer allocator.free(level.entities);
    defer allocator.free(level.decorations);
    defer allocator.free(level.ground_items);

    // 8 tiles: 9 positions minus 1 decoration
    try std.testing.expectEqual(8, level.level_tiles.len);

    // 1 decoration
    try std.testing.expectEqual(1, level.decorations.len);
    try std.testing.expectEqualStrings("BigTree", level.decorations[0].name);

    // Decoration position: column 1, row 1 in text -> y is flipped
    // Row 0 ".!." -> y=2, Row 1 ".A." -> y=1, Row 2 "..." -> y=0
    try std.testing.expectEqual(1, level.decorations[0].position.x);
    try std.testing.expectEqual(1, level.decorations[0].position.y);
}

test "loadLevel rejects unexpected sections" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
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
        \\music_volume 0.5
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const result = loadLevel(sections, allocator);
    try std.testing.expectError(error.UnexpectedSection, result);
}

test "loadHub parses a complete hub" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
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

    const hub = try loadHub(sections, allocator);
    defer allocator.free(hub.hub_tiles);
    defer allocator.free(hub.npcs);
    defer allocator.free(hub.decorations);
    defer allocator.free(hub.mission_exits);

    // Metadata
    try std.testing.expectEqualStrings("Test Village", hub.name);

    // Player position from '!'
    try std.testing.expectEqualStrings("Player", hub.player.name);
    try std.testing.expectEqual(1, hub.player.position.x);
    try std.testing.expectEqual(1, hub.player.position.y);

    // NPC
    try std.testing.expectEqual(1, hub.npcs.len);
    try std.testing.expectEqualStrings("Blacksmith", hub.npcs[0].entity.name);
    // N at column 3, row 0 in text -> y=2
    try std.testing.expectEqual(3, hub.npcs[0].entity.position.x);
    try std.testing.expectEqual(2, hub.npcs[0].entity.position.y);

    // Mission exit
    try std.testing.expectEqual(1, hub.mission_exits.len);
    try std.testing.expectEqualStrings("first_mission", hub.mission_exits[0].mission_id);
    // E at column 2, row 2 in text -> y=0
    try std.testing.expectEqual(2, hub.mission_exits[0].position.x);
    try std.testing.expectEqual(0, hub.mission_exits[0].position.y);

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

    const player_data = try loadPlayerSave(sections, allocator);
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
        .equipped_utility_skills = .{ .replenish, .slice, .slice, .slice, .slice },
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

    const loaded = try loadPlayerSave(sections, allocator);
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
    try std.testing.expectEqual(.slice, loaded.equipped_utility_skills[1]);

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

    // Parse the file from disk
    const parsed = try parseConfigFileFromPath(
        std.Io.Dir.cwd(),
        io,
        "data/new_player.txt",
        allocator,
    );
    defer allocator.free(parsed.raw_text);
    defer freeParsedSections(parsed.sections, allocator);

    const player_data = try loadPlayerSave(parsed.sections, allocator);
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

    const reloaded = try loadPlayerSave(sections2, allocator);
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

    const parsed = try parseConfigFileFromPath(
        std.Io.Dir.cwd(),
        io,
        "data/color_themes.txt",
        allocator,
    );
    defer allocator.free(parsed.raw_text);
    defer freeParsedSections(parsed.sections, allocator);

    const theme = try loadColorThemeDefinitions(parsed.sections, allocator);
    defer allocator.free(theme.gradients);

    // Should have 9 gradients
    try std.testing.expectEqual(9, theme.gradients.len);

    // Lightest and darkest should be parsed
    try std.testing.expectEqual(255, theme.lightest.r);
    try std.testing.expectEqual(20, theme.darkest.r);
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
