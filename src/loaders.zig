//! Game-content loaders — convert parsed config sections (parser.zig) into
//! typed game objects (`types.*`). Owns decoration footprint/anchor validation,
//! the editor dedup (`buildEditorMission`), editor level instantiation, the
//! `free*`/`clone*`/equality helpers for test ownership, balance bounds
//! (`boundedU32` + `max_*`), custom-sprite PNG dim resolution, and salvage.
//! The inverse direction (typed objects -> config text) lives in writers.zig.
//! See DESIGN -> File System & IO / AGENTS -> Config File Format.

const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");
const deep_copy = @import("deep_copy.zig");
const lookups = @import("generated_lookups.zig");
const file_source_mod = @import("file_source.zig");
const sprite_metadata = @import("generated_sprite_metadata");

const FileSource = file_source_mod.FileSource;
const Section = parser.Section;
const KeyValuePair = parser.KeyValuePair;
const ParsedConfigFile = parser.ParsedConfigFile;
const parseConfigFile = parser.parseConfigFile;
const parseConfigFileFromPath = parser.parseConfigFileFromPath;
const findSection = parser.findSection;
const findValue = parser.findValue;
const asU32 = parser.asU32;
const asI32 = parser.asI32;
const asBool = parser.asBool;
const asColor = parser.asColor;
const parseEnum = parser.parseEnum;
const validateSections = parser.validateSections;
const validateFileFormatVersion = parser.validateFileFormatVersion;
const validateKeys = parser.validateKeys;
const freeParsedSections = parser.freeParsedSections;
const level_file_format_version = parser.level_file_format_version;
const hub_file_format_version = parser.hub_file_format_version;
const mission_file_format_version = parser.mission_file_format_version;
const campaign_file_format_version = parser.campaign_file_format_version;
const player_save_file_format_version = parser.player_save_file_format_version;
const settings_file_format_version = parser.settings_file_format_version;
const color_themes_file_format_version = parser.color_themes_file_format_version;
const player_loadout_file_format_version = parser.player_loadout_file_format_version;
const decorations_file_format_version = parser.decorations_file_format_version;
/// camera_zoom valid range (hundredths). Mirrors `input_handlers`'s
/// `min_camera_zoom`/`max_camera_zoom` — duplicated here because loaders
/// must not import the input layer; the 4-choice values (25/50/75/100) are
/// the single source of truth in DESIGN → UI Framework → Settings screen.
const min_camera_zoom: u32 = 25;
const max_camera_zoom: u32 = 100;
const Settings = types.Settings;
const Level = types.Level;
const Hub = types.Hub;
const Campaign = types.Campaign;
const Mission = types.Mission;
const PlayerData = types.PlayerData;
const WeaponType = types.WeaponType;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const ColorGradient = types.ColorGradient;
const ColorThemeDefinitions = types.ColorThemeDefinitions;
const ActiveColorTheme = types.ActiveColorTheme;
const MaterialType = types.MaterialType;
const SalvageSplit = types.SalvageSplit;
const SalvageDefinition = types.SalvageDefinition;
const SalvageDefinitions = types.SalvageDefinitions;
const Color = types.Color;
const settings_sections = parser.settings_sections;
const weapon_type_sections = parser.weapon_type_sections;
const level_sections = parser.level_sections;
const hub_sections = parser.hub_sections;
const campaign_sections = parser.campaign_sections;
const mission_sections = parser.mission_sections;
const decoration_registry_sections = parser.decoration_registry_sections;
const player_save_sections = parser.player_save_sections;
const color_theme_sections = parser.color_theme_sections;

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

// ── Balance bounds (parse-time, uniform across all content) ──
//
// Every parsed gear-stat field routes through `boundedU32`, which clamps
// out-of-range values to the max and appends a warning (so the game stays
// playable + the author is told). See DESIGN → Custom Missions → Balance
// bounds. Entity base stats (max_health, defense, speed, aggro_range) are
// NOT bounded — only gear stats.
pub const max_weapon_damage: u32 = 10;
pub const max_spell_damage: u32 = 10;
pub const max_health_bonus: u32 = 10;
pub const max_defense_bonus: u32 = 5;
pub const max_gloves_damage: u32 = 5;
pub const max_pickup_radius: u32 = 5;
pub const max_boots_speed: u32 = 2;

/// parse failure (same as `asU32`). See DESIGN → Custom Missions → Balance
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

pub fn loadSettings(
    sections: []const Section,
    allocator: std.mem.Allocator,
    base: ?Settings,
) !Settings {
    try validateSections(sections, &settings_sections);
    try validateFileFormatVersion(sections, "Metadata", settings_file_format_version);
    var settings: Settings = base orelse .{ .input_bindings = &.{} };
    const has_base = base != null;

    // Audio — volumes are u32 percentages 0–100, clamped inline (a
    // hand-edited file with >100 silently clamps; settings are preferences,
    // not gameplay, so no warning popup). See DESIGN → UI Framework →
    // Settings screen (Volume integer migration).
    if (findSection(sections, "Audio")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "master_volume")) |value| {
                if (asU32(value)) |v| settings.master_volume = @min(v, 100);
            }
            if (findValue(pairs, "music_volume")) |value| {
                if (asU32(value)) |v| settings.music_volume = @min(v, 100);
            }
            if (findValue(pairs, "sound_effects_volume")) |value| {
                if (asU32(value)) |v| settings.sound_effects_volume = @min(v, 100);
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
                // camera_zoom is a u32 4-choice (25/50/75/100 hundredths).
                // Clamp to the valid range; a hand-edited file with an
                // out-of-range value silently clamps (preferences, not
                // gameplay). See DESIGN → UI Framework → Settings screen.
                if (asU32(value)) |v| settings.camera_zoom = @max(min_camera_zoom, @min(max_camera_zoom, v));
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
            if (findValue(pairs, "show_fps")) |value| {
                settings.show_fps = asBool(value) orelse settings.show_fps;
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

            // Dupe the input_name into the allocator so the returned Settings
            // OWNS its strings (it doesn't borrow from the raw file buffer).
            // This makes the result self-contained — the caller may free the
            // raw bytes immediately — and enables leak-checked tests under
            // testing.allocator (the old borrow-into-freed-bytes pattern was
            // invisible under an arena). See DESIGN → File System & IO →
            // Settings ownership.
            const input_name_owned = try allocator.dupe(u8, input_name);
            const input: types.RawInput = switch (input_type_id) {
                .key => .{ .key = input_name_owned },
                .mouse_button => .{ .mouse_button = input_name_owned },
                .gamepad_button => .{ .gamepad_button = input_name_owned },
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

        // Inject default bindings for actions the user file doesn't mention
        // — the per-action migration (see DESIGN → Input → Binding overlay
        // semantics): the user file is authoritative for the actions it
        // names, but actions it doesn't name fall back to their defaults, so
        // a NEW official binding (skip_level, future editor keys, renames)
        // reaches existing installs instead of being shadowed by the
        // full-set replace. Idempotent by construction: the next debounced
        // settings write persists the injected bindings (writes are
        // full-format), so later loads see those actions as mentioned and
        // nothing re-injects. Only runs when a base was provided (the
        // overlay path); a standalone load has no defaults to inject.
        if (has_base) {
            for (settings.input_bindings) |default_binding| {
                var mentioned = false;
                for (bindings.items) |user_binding| {
                    if (user_binding.action == default_binding.action) {
                        mentioned = true;
                        break;
                    }
                }
                if (mentioned) continue;
                const default_name = switch (default_binding.input) {
                    .key => |name| name,
                    .mouse_button => |name| name,
                    .gamepad_button => |name| name,
                };
                const default_name_owned = try allocator.dupe(u8, default_name);
                const default_input: types.RawInput = switch (default_binding.input) {
                    .key => .{ .key = default_name_owned },
                    .mouse_button => .{ .mouse_button = default_name_owned },
                    .gamepad_button => .{ .gamepad_button = default_name_owned },
                };
                try bindings.append(allocator, .{
                    .input = default_input,
                    .modifiers = default_binding.modifiers,
                    .action = default_binding.action,
                });
            }
        }

        // Free the base's bindings before replacing (when a base is provided,
        // its bindings — and their owned input_name strings — were heap-
        // allocated by a prior loadSettings call; when no base,
        // input_bindings is the static &.{} and must not be freed). The
        // strings are owned (duped above), so free them too, not just the
        // slice — otherwise replacing bindings leaks the old names.
        if (has_base and settings.input_bindings.len > 0) {
            for (settings.input_bindings) |*binding| {
                freeRawInputString(binding.input, allocator);
            }
            allocator.free(settings.input_bindings);
        }
        settings.input_bindings = try bindings.toOwnedSlice(allocator);
    }

    return settings;
}

/// Free a `RawInput`'s owned string slice (the active union variant).
/// Only valid for inputs whose string was duped by `loadSettings` — a
/// borrowed slice (e.g. the static `&.{}` empty-bindings default, which has
/// no strings) must not be passed. Used by `freeSettings` and by the
/// binding-replace path in `loadSettings`.
fn freeRawInputString(input: types.RawInput, allocator: std.mem.Allocator) void {
    switch (input) {
        .key => |s| allocator.free(s),
        .mouse_button => |s| allocator.free(s),
        .gamepad_button => |s| allocator.free(s),
    }
}

/// Free a `Settings`' owned InputBindings (the slice + each binding's duped
/// input_name string). The non-binding fields are scalars/stack values with
/// no allocation. Use in tests under `testing.allocator` to assert no leaks;
/// production never frees settings (process lifetime). A `Settings` whose
/// `input_bindings` is the static `&.{}` default (len 0, never passed through
/// `loadSettings`) is safe to pass — the loop is empty and the len guard
/// skips the slice free.
pub fn freeSettings(settings: types.Settings, allocator: std.mem.Allocator) void {
    for (settings.input_bindings) |*binding| {
        freeRawInputString(binding.input, allocator);
    }
    if (settings.input_bindings.len > 0) {
        allocator.free(settings.input_bindings);
    }
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

    // Enter at full EFFECTIVE health (base + gear health_bonus). Gear is
    // applied above; current_health is derived from the now-complete loadout.
    // See `getEffectiveMaxHealth`.
    entity.current_health = entity.getEffectiveMaxHealth();

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
/// replay deterministic. Dedups the levels' inline entity/decoration/item
/// definitions into a shared palette (entity_types / decoration_types /
/// item_types).
/// The result is reference-based (EditorLevel + placements); save flattens
/// back to the existing inline format. Unused palette types are lost on
/// editor close (accepted). See DESIGN → Architecture → Level Editor.
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
    var item_types: std.ArrayList(types.ItemTypeDef) = .empty;
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

        // Ground item placements: one placement per item (level files author
        // single-item stacks — one layout char per item; runtime drops can
        // merge stacks, but those never round-trip through the editor).
        // Dedup by full item equality (name + stats + type) into the shared
        // item palette.
        var item_placements: std.ArrayList(types.ItemPlacement) = .empty;
        for (level.ground_items) |stack| {
            for (stack.items) |item| {
                var type_id: ?u32 = null;
                for (item_types.items, 0..) |item_type, it_index| {
                    if (deep_copy.deepEqual(types.Item, item_type.item, item)) {
                        type_id = @intCast(it_index);
                        break;
                    }
                }
                if (type_id == null) {
                    type_id = @intCast(item_types.items.len);
                    item_types.append(allocator, .{
                        .id = itemDisplayName(item, allocator),
                        .item = item,
                    }) catch @panic("failed to append item type");
                }
                item_placements.append(allocator, .{
                    .type_id = type_id.?,
                    .position = stack.position,
                }) catch @panic("failed to append item placement");
            }
        }

        editor_levels.append(allocator, .{
            .name = level.name,
            .color_wheel_index = level.color_wheel_index,
            .level_tiles = level.level_tiles,
            .player_start = level.entities[0].position,
            .level_end = level.level_end,
            .entity_placements = placements.items,
            .decoration_placements = deco_placements.items,
            .item_placements = item_placements.items,
        }) catch @panic("failed to append editor level");
    }

    return .{
        .mission = mission,
        .levels = editor_levels.items,
        .entity_types = entity_types.items,
        .decoration_types = decoration_types.items,
        .item_types = item_types.items,
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

/// User-facing palette id for a ground-item type: the item's own name, or
/// "<Skill> Tome" for skill tomes (which carry no name field — mirrors the
/// item-tooltip naming in ui.zig).
fn itemDisplayName(item: types.Item, allocator: std.mem.Allocator) []const u8 {
    return switch (item) {
        .weapon => |weapon| weapon.name,
        .amulet => |amulet| amulet.name,
        .coat => |coat| coat.name,
        .gloves => |gloves| gloves.name,
        .pants => |pants| pants.name,
        .boots => |boots| boots.name,
        .skill_tome => |tome| blk: {
            const definition = lookups.getSkillDefinition(tome.skill) orelse
                break :blk "Skill Tome";
            break :blk std.fmt.allocPrint(
                allocator,
                "{s} Tome",
                .{definition.name},
            ) catch @panic("failed to format skill tome palette name");
        },
    };
}

/// Instantiate a concrete gameplay Level from an EditorLevel + the editor's
/// palette + player_def. Entity 0 is the player (from player_def at
/// player_start); each placement becomes an entity from its palette type at
/// the placement's position; item placements regroup into ground-item stacks
/// by position. Runtime fields are reset (current_health =
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

    // Ground item stacks: regroup placements by position (first-seen order,
    // items in placement order). One placement = one item; co-located
    // placements share a stack (the editor UI can stack two item types on
    // one tile).
    var ground_items: std.ArrayList(types.GroundItems) = .empty;
    for (editor_level.item_placements) |placement| {
        const item = editor.item_types[placement.type_id].item;
        var existing_stack: ?*types.GroundItems = null;
        for (ground_items.items) |*stack| {
            if (stack.position.x == placement.position.x and
                stack.position.y == placement.position.y)
            {
                existing_stack = stack;
                break;
            }
        }
        if (existing_stack) |stack| {
            const grown = allocator.realloc(
                @constCast(stack.items),
                stack.items.len + 1,
            ) catch @panic("failed to grow ground item stack");
            grown[grown.len - 1] = item;
            stack.items = grown;
        } else {
            const items = allocator.alloc(types.Item, 1) catch @panic("failed to alloc ground item stack");
            items[0] = item;
            ground_items.append(allocator, .{
                .position = placement.position,
                .items = items,
            }) catch @panic("failed to append ground item stack");
        }
    }

    return .{
        .name = editor_level.name,
        .color_wheel_index = editor_level.color_wheel_index,
        .level_tiles = editor_level.level_tiles,
        .entities = entities.items,
        .decorations = decorations.items,
        .ground_items = ground_items.items,
        .level_end = editor_level.level_end,
    };
}

/// Reset an entity's runtime fields to a fresh-start state (used by
/// instantiateEditorLevel). Definition fields (stats, weapons, gear, skills)
/// are kept; only per-playthrough state is zeroed.
fn resetRuntimeFields(entity: *types.Entity) void {
    entity.current_health = entity.getEffectiveMaxHealth();
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
/// the section. See DESIGN → Decorations & Footprint.
const DecorationDefinition = struct {
    sprite: []const u8,
    footprint: []const types.Vector2, // sprite-grid coords
    pixel_dims: types.Vector2,
    color_index: u32 = 0,
    layers: []const types.DecorationLayer = &.{},
};

/// Derive the anchor (bottom-most-then-left-most) from a sprite-grid footprint.
/// Returns null if the footprint is empty — the caller panics (a decoration
/// with no footprint tiles is a malformed level). Shared with the editor's
/// placement hit-testing (event_handlers.decorationFootprintCovers).
pub fn decorationAnchor(footprint: []const types.Vector2) ?types.Vector2 {
    if (footprint.len == 0) return null;
    var anchor = footprint[0];
    for (footprint[1..]) |tile| {
        // Bottom-most = highest y (sprite-grid y increases downward). Tiebreak
        // by left-most = lowest x. This is the convention from DESIGN →
        // Decorations & Footprint.
        if (tile.y > anchor.y or (tile.y == anchor.y and tile.x < anchor.x)) {
            anchor = tile;
        }
    }
    return anchor;
}

/// Validate a decoration's footprint against its sprite bbox and the level/hub
/// tile set. Panics on violation (fail fast — see DESIGN → Error Handling):
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
/// inline in the level file, sharing this parser path). See DESIGN →
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
    // overlap a level tile (placement invariant — see DESIGN → Decorations
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

    // Validate decoration footprints (same as levels — see DESIGN →
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
            mission.uuid = findValue(pairs, "mission_uuid") orelse return error.MissingMissionUuid;
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
                .mission_uuid = findValue(pairs, "mission_uuid") orelse &.{},
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

test "loadSettings parses settings sections into a Settings struct" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\Audio
        \\music_volume 80
        \\sound_effects_volume 30
        \\
        \\Display
        \\vsync false
        \\render_fps_cap 144
        \\camera_zoom 75
        \\
        \\Gameplay
        \\auto_skip_attack_step_out_of_combat false
        \\auto_target_at_cursor true
        \\show_fps true
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

    const settings = try loadSettings(sections, allocator, null);
    defer freeSettings(settings, allocator);

    // Audio values (u32 percentages 0–100)
    try std.testing.expectEqual(@as(u32, 80), settings.music_volume);
    try std.testing.expectEqual(@as(u32, 30), settings.sound_effects_volume);

    // Display values
    try std.testing.expectEqual(false, settings.vsync);
    try std.testing.expectEqual(@as(u32, 144), settings.render_fps_cap);
    try std.testing.expectEqual(@as(u32, 75), settings.camera_zoom);

    // Gameplay values
    try std.testing.expectEqual(false, settings.auto_skip_attack_step_out_of_combat);
    try std.testing.expectEqual(true, settings.auto_target_at_cursor);
    try std.testing.expectEqual(true, settings.show_fps);

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

test "instantiateEditorLevel regroups co-located item placements into one stack" {
    // Level files author one item per stack, but the editor UI can place two
    // item types on the same tile — instantiation must regroup co-located
    // placements into a single multi-item stack (first-seen position order,
    // items in placement order).
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const allocator = backing.allocator();

    const item_types = [_]types.ItemTypeDef{
        .{ .id = "Boots", .item = .{ .boots = .{ .name = "Boots", .speed_bonus = 1 } } },
        .{ .id = "Spear", .item = .{ .weapon = .{ .name = "Spear", .weapon_type = .spear, .weapon_damage = 4 } } },
    };
    const placements = [_]types.ItemPlacement{
        .{ .type_id = 0, .position = .{ .x = 2, .y = 3 } },
        .{ .type_id = 1, .position = .{ .x = 2, .y = 3 } }, // co-located
        .{ .type_id = 1, .position = .{ .x = 5, .y = 1 } },
    };
    const levels = [_]types.EditorLevel{.{
        .item_placements = &placements,
    }};
    const editor = types.Editor{
        .levels = &levels,
        .item_types = &item_types,
    };

    const level = instantiateEditorLevel(editor, 0, allocator);

    try std.testing.expectEqual(@as(usize, 2), level.ground_items.len);
    // First-seen position order: (2,3) stack first with both items in
    // placement order, then the (5,1) stack.
    try std.testing.expectEqual(types.Vector2{ .x = 2, .y = 3 }, level.ground_items[0].position);
    try std.testing.expectEqual(@as(usize, 2), level.ground_items[0].items.len);
    try std.testing.expectEqualStrings("Boots", level.ground_items[0].items[0].boots.name);
    try std.testing.expectEqualStrings("Spear", level.ground_items[0].items[1].weapon.name);
    try std.testing.expectEqual(types.Vector2{ .x = 5, .y = 1 }, level.ground_items[1].position);
    try std.testing.expectEqual(@as(usize, 1), level.ground_items[1].items.len);
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
        \\file_format_version 2
        \\mission_uuid 11111111-1111-1111-1111-111111111111
        \\name First Mission
        \\start_hub camp
        \\end_hub village
        \\level_count 3
    ;

    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const mission = try loadMission(sections, allocator);

    try std.testing.expectEqualStrings("11111111-1111-1111-1111-111111111111", mission.uuid);
    try std.testing.expectEqualStrings("First Mission", mission.name);
    try std.testing.expectEqualStrings("camp", mission.start_hub.?);
    try std.testing.expectEqualStrings("village", mission.end_hub.?);
    try std.testing.expectEqual(3, mission.level_count);
}

test "loadPlayerSave parses a save file" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 2
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
        \\mission_uuid bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
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
    try std.testing.expectEqualStrings("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", player_data.clones[0].mission_uuid);
    try std.testing.expectEqualStrings("First Clone", player_data.clones[0].name);
    try std.testing.expectEqual(15, player_data.clones[0].turns_to_complete);
    try std.testing.expectEqual(10, player_data.clones[0].materials_collected.wood);
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

    const settings = try loadSettings(parsed.sections, allocator, null);
    defer freeSettings(settings, allocator);

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

/// Test helper: build an owned `[]InputBinding` (duped input names) so a
/// base Settings can be freed with `freeSettings` under `testing.allocator`.
fn testOwnedBindings(
    allocator: std.mem.Allocator,
    specs: []const struct { key: []const u8, ctrl: bool = false, action: types.Action },
) ![]types.InputBinding {
    var bindings: std.ArrayList(types.InputBinding) = .empty;
    for (specs) |spec| {
        try bindings.append(allocator, .{
            .input = .{ .key = try allocator.dupe(u8, spec.key) },
            .modifiers = .{ .ctrl = spec.ctrl },
            .action = spec.action,
        });
    }
    return bindings.toOwnedSlice(allocator);
}

test "loadSettings injects default bindings for actions the user file doesn't mention" {
    // The per-action migration: a user InputBindings section is authoritative
    // for the actions it names, but unmentioned actions fall back to their
    // DEFAULT bindings (injected) — so a new official binding reaches
    // existing installs whose user file predates it (the skip_level gap).
    const allocator = std.testing.allocator;

    // Defaults: skip → Space, dump_event_log → ctrl+L, undo → ctrl+Z.
    const base = Settings{
        .input_bindings = try testOwnedBindings(allocator, &.{
            .{ .key = "Space", .action = .skip },
            .{ .key = "L", .ctrl = true, .action = .dump_event_log },
            .{ .key = "Z", .ctrl = true, .action = .undo },
        }),
    };
    // loadSettings CONSUMES the base's bindings (frees them on replace;
    // aliases them otherwise) — only the merged result is freed here (same
    // ownership shape as the session_setup overlay test).

    // User file mentions ONLY skip (rebound to Enter) — e.g. an old install
    // whose file predates the dump_event_log + undo defaults.
    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name Enter
        \\action skip
    ;
    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const merged = try loadSettings(sections, allocator, base);
    defer freeSettings(merged, allocator);

    // The user's rebinding of skip wins (Enter), and the default Space→skip
    // is NOT carried over (mentioned = user-authoritative).
    try std.testing.expectEqual(@as(usize, 3), merged.input_bindings.len);
    // The user's skip binding is the ONLY skip binding (Enter, not the
    // default Space) — mentioned means user-authoritative, not additive.
    for (merged.input_bindings) |binding| {
        if (binding.action == .skip) {
            try std.testing.expectEqualStrings("Enter", binding.input.key);
        }
    }

    // Unmentioned actions get their defaults injected verbatim (key +
    // modifiers), so the player isn't silently missing bindings.
    const dump_binding = for (merged.input_bindings) |binding| {
        if (binding.action == .dump_event_log) break binding;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("L", dump_binding.input.key);
    try std.testing.expect(dump_binding.modifiers.ctrl);

    const undo_binding = for (merged.input_bindings) |binding| {
        if (binding.action == .undo) break binding;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Z", undo_binding.input.key);
    try std.testing.expect(undo_binding.modifiers.ctrl);
}

test "loadSettings binding overlay is idempotent once injected bindings are written back" {
    // Second load with a file that mentions every action (the shape the
    // debounced write produces after the first injection): nothing new is
    // injected, the user's set comes through unchanged.
    const allocator = std.testing.allocator;

    const base = Settings{
        .input_bindings = try testOwnedBindings(allocator, &.{
            .{ .key = "Space", .action = .skip },
            .{ .key = "L", .ctrl = true, .action = .dump_event_log },
        }),
    };
    // loadSettings consumes the base's bindings — free merged only.

    // The post-write file: skip (still default) + dump_event_log (still
    // default) — the exact content writeSettings would emit after injection.
    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name Space
        \\action skip
        \\
        \\input_type key
        \\input_name L
        \\ctrl true
        \\action dump_event_log
    ;
    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const merged = try loadSettings(sections, allocator, base);
    defer freeSettings(merged, allocator);

    // Exactly the user file's two bindings — no duplicate injection.
    try std.testing.expectEqual(@as(usize, 2), merged.input_bindings.len);
}

test "loadSettings without an InputBindings section keeps the base bindings untouched" {
    // A user file that only touches scalars (no bindings section) leaves the
    // defaults in place — the injection lives in the bindings branch only.
    const allocator = std.testing.allocator;

    const base = Settings{
        .input_bindings = try testOwnedBindings(allocator, &.{
            .{ .key = "Space", .action = .skip },
        }),
    };
    // No InputBindings section → the base's bindings are aliased into the
    // merged result (not consumed) — free merged only.

    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\Audio
        \\master_volume 40
    ;
    const sections = try parseConfigFile(raw_text, allocator);
    defer freeParsedSections(sections, allocator);

    const merged = try loadSettings(sections, allocator, base);
    defer freeSettings(merged, allocator);

    try std.testing.expectEqual(@as(u32, 40), merged.master_volume);
    try std.testing.expectEqual(@as(usize, 1), merged.input_bindings.len);
    try std.testing.expectEqual(.skip, merged.input_bindings[0].action);
}
