//! Game-content loaders - convert parsed config sections (parser.zig) into
//! typed game objects (`types.*`). Owns decoration footprint/anchor validation,
//! the editor dedup (`buildEditorMission`), editor level instantiation, the
//! `free*`/`clone*`/equality helpers for test ownership, balance bounds
//! (`boundedU32` + `max_*`), custom-sprite PNG dim resolution, and salvage.
//! The inverse direction (typed objects -> config text) lives in writers.zig.
//! See DESIGN -> File System & IO / AGENTS -> Config File Format.

const std = @import("std");
const utility_skills = @import("utility_skills.zig");
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
const editor_defaults_file_format_version = parser.editor_defaults_file_format_version;
/// camera_zoom valid range (hundredths). Mirrors `input_handlers`'s
/// `min_camera_zoom`/`max_camera_zoom` - duplicated here because loaders
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
const player_loadout_sections = parser.player_loadout_sections;
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

/// The sprite-grid tile size, as a file-local alias for the shared fact's
/// home in types.zig (single source).
const sprite_grid_tile_pixels: i32 = types.sprite_grid_tile_pixels;

/// The soft ceiling for custom sprite dimensions (either axis): WebGL2's
/// guaranteed minimum max texture size is 2048 (ES 3.0 baseline), but 4096+
/// is universal in practice - beyond this a sprite may fail to upload on
/// some devices. Warned at load, never rejected.
const max_custom_sprite_dimension: i32 = 4096;

/// Floor sprite dims onto the 256px sprite grid, minimum one tile per axis
/// (sub-256 or non-multiple art degrades to its largest whole-tile region;
/// zero/negative dims clamp to one tile). Pure - the same file bytes always
/// produce the same result, so replay is unaffected.
fn flooredSpriteGridDims(dims: types.Vector2) types.Vector2 {
    const floorToGrid = struct {
        fn axis(pixels: i32) i32 {
            return @max(
                sprite_grid_tile_pixels,
                @divTrunc(pixels, sprite_grid_tile_pixels) * sprite_grid_tile_pixels,
            );
        }
    }.axis;
    return .{ .x = floorToGrid(dims.x), .y = floorToGrid(dims.y) };
}

/// Append a formatted warning to the optional load-warnings list (surfaced
/// as one pending_error popup via `surfaceWarnings` - advisory, the load
/// continues). Custom-content validation uses this everywhere: degrade +
/// warn, never reject, never crash.
fn appendLoadWarning(
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
    comptime format: []const u8,
    args: anytype,
) void {
    const list = warnings orelse return;
    const message = std.fmt.allocPrint(allocator, format, args) catch
        @panic("failed to format load warning");
    list.append(allocator, message) catch @panic("failed to append load warning");
}

/// Resolve a mission-local sprite's pixel dims (the decoration picker's
/// custom-stem commit path): read `<mission_path>/<file_stem>.png` via the
/// file source and parse its IHDR. Returns null when the file is missing
/// or not a valid PNG - the commit site degrades (nothing records; the
/// next picker open re-scans the directory, so a vanished file stops
/// being offered).
pub fn resolveMissionSpriteDimensions(
    file_source: *const FileSource,
    mission_path: []const u8,
    file_stem: []const u8,
    allocator: std.mem.Allocator,
) ?types.Vector2 {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}.png", .{ mission_path, file_stem }) catch
        @panic("failed to build mission sprite path for dims resolution");
    defer allocator.free(path);
    const bytes = file_source.readFile(allocator, path) catch return null;
    defer allocator.free(bytes);
    return parsePngDimensions(bytes);
}

/// Resolve a SHIPPED decoration sprite's dims from the comptime metadata
/// table (the layer picker's official-stem commit path - no IO). Returns
/// null when the stem isn't shipped decoration art.
pub fn resolveShippedDecorationSpriteDimensions(
    stem: []const u8,
    allocator: std.mem.Allocator,
) ?types.Vector2 {
    const full_id = std.fmt.allocPrint(allocator, "decorations/{s}", .{stem}) catch
        @panic("failed to build decoration sprite id for dims");
    defer allocator.free(full_id);
    const dims_str = sprite_metadata.map.get(full_id) orelse return null;
    return parseDimsString(dims_str);
}

/// Parse a `"w h"` string (as emitted by generated_sprite_metadata.zig) into a
/// Vector2. Panics on malformed input - the table is build-generated, so a
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
// The max_* constants live in types.zig (the single source shared with the
// editor inspector's commit-time clamp - see DESIGN → Custom Missions →
// Balance bounds + DESIGN → Level Editor → Inspector fields). Every parsed
// gear-stat field routes through `boundedU32`, which clamps out-of-range
// values to the max and appends a warning (so the game stays playable +
// the author is told). Entity base stats (max_health, defense, speed,
// aggro_range) are NOT bounded - only gear stats.

/// Append a formatted warning; no-op when `warnings` is null or the
/// allocation fails (a missing warning never blocks a load).
fn appendWarning(
    warnings: ?*std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) void {
    if (warnings) |w| {
        const msg = std.fmt.allocPrint(allocator, format, args) catch return;
        w.append(allocator, msg) catch {};
    }
}

/// Parse a gear-stat value and clamp it to `max`. If the value exceeds `max`,
/// append a warning to `warnings` (when non-null) naming the field, value,
/// file, and max - then return `max` so the game stays playable. Returns 0 on
/// parse failure (same as `asU32`). See DESIGN → Custom Missions & Online
/// Services → Balance bounds.
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
    /// Receives binding-level config warnings (unknown action; duplicate
    /// or conflicting combos - see the conflict scan below). Null on the
    /// defaults path (`loadSettingsWrapped`) - the shipped file is
    /// round-trip-tested, so binding warnings there are dev noise.
    warnings: ?*std.ArrayList([]const u8),
) !Settings {
    _ = try validateFileFormatVersion(sections, "Metadata", settings_file_format_version, settings_file_format_version);
    var settings: Settings = base orelse .{ .input_bindings = &.{} };
    const has_base = base != null;

    // Audio - volumes are u32 percentages 0-100, clamped inline (a
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
            if (findValue(pairs, "render_resolution")) |value| {
                // 4-choice preset, parsed by label so the file value matches
                // the settings screen ("1080p"). An unrecognized value keeps
                // the default (preferences, not gameplay). See DESIGN →
                // Platform Seam → Render target resolution.
                for (std.meta.tags(types.RenderResolution)) |resolution| {
                    if (std.mem.eql(u8, value, resolution.label())) {
                        settings.render_resolution = resolution;
                        break;
                    }
                }
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
            const action = parseEnum(types.Action, action_string) orelse {
                if (warnings) |w| {
                    const message = std.fmt.allocPrint(allocator, "InputBindings entry '{s}' names unknown action '{s}'; entry dropped", .{ input_name, action_string }) catch @panic("failed to format binding warning");
                    w.append(allocator, message) catch @panic("failed to append binding warning");
                }
                continue;
            };

            // The entry's `context` line, if present, is IGNORED - a
            // binding's active contexts are DERIVED from the action
            // (`actionBindingContexts`); see DESIGN → Input → Binding
            // contexts. (No validity check needed: there is nothing to
            // validate against.)

            const InputTypeId = enum { key, mouse_button, gamepad_button };
            const input_type_id = parseEnum(InputTypeId, input_type) orelse continue;

            // Dupe the input_name into the allocator so the returned Settings
            // OWNS its strings (it doesn't borrow from the raw file buffer).
            // This makes the result self-contained - the caller may free the
            // raw bytes immediately - and enables leak-checked tests under
            // testing.allocator (the old borrow-into-freed-bytes pattern was
            // invisible under an arena). See DESIGN → File System & IO →
            // Settings ownership.
            const input_name_owned = allocator.dupe(u8, input_name) catch
                @panic("failed to dupe binding input name");
            const input: types.RawInput = switch (input_type_id) {
                .key => .{ .key = input_name_owned },
                .mouse_button => .{ .mouse_button = input_name_owned },
                .gamepad_button => .{ .gamepad_button = input_name_owned },
            };

            // Dead-binding advisory (see `types.producible_key_ids`): a
            // binding naming an input id no platform table can produce can
            // never fire (a typo'd hand-edit - or a table/list drift bug;
            // the missing-Escape regression's failure mode). Warn + KEEP
            // the entry (the id may be valid on another platform or a
            // future table - dropping would lose it); the startup popup
            // deliberately repeats until the file names a producible id.
            if (warnings) |w| {
                if (!types.inputIdProducible(input)) {
                    const message = std.fmt.allocPrint(allocator, "InputBindings entry '{s}' (action '{s}') names input id '{s}' no platform mapping can produce; the binding can never fire", .{ input_name, action_string, input_name }) catch @panic("failed to format binding warning");
                    w.append(allocator, message) catch @panic("failed to append binding warning");
                }
            }

            const modifiers = types.Modifiers{
                .ctrl = asBool(findValue(pairs, "ctrl") orelse "false") orelse false,
                .shift = asBool(findValue(pairs, "shift") orelse "false") orelse false,
                .alt = asBool(findValue(pairs, "alt") orelse "false") orelse false,
            };

            bindings.append(allocator, .{
                .input = input,
                .modifiers = modifiers,
                .action = action,
            }) catch @panic("failed to append binding");
        }

        // How many entries came from the user file - everything appended
        // after this count is an INJECTED default (the per-action migration
        // below). The conflict scan uses it: a dropped INJECTED default is
        // silent (see the scan's comment).
        const user_binding_count = bindings.items.len;

        // Inject default bindings for actions the user file doesn't mention
        // - the per-action migration (see DESIGN → Input → Binding overlay
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
                const default_name_owned = allocator.dupe(u8, default_name) catch
                    @panic("failed to dupe injected default binding input name");
                const default_input: types.RawInput = switch (default_binding.input) {
                    .key => .{ .key = default_name_owned },
                    .mouse_button => .{ .mouse_button = default_name_owned },
                    .gamepad_button => .{ .gamepad_button = default_name_owned },
                };
                bindings.append(allocator, .{
                    .input = default_input,
                    .modifiers = default_binding.modifiers,
                    .action = default_binding.action,
                }) catch @panic("failed to append injected default binding");
            }
        }

        // Conflict scan (the load-time mirror of the keybind UI's rule -
        // see DESIGN → Input → Hybrid precedence + binding conflicts):
        // one combo (same input + same required modifiers) fires ONE
        // action per context. A duplicate combo on the SAME action, or on
        // DIFFERENT actions whose derived contexts intersect (they would
        // co-fire), is a config error: warn + drop the LATER entry (first
        // listed wins) - but ONLY when the dropped entry came from the
        // user file. A dropped INJECTED default is SILENT: the user bound
        // a combo that a default for an unmentioned action also occupies
        // (user Enter→skip vs injected confirm→Enter) - nothing in the
        // user's file is wrong, and the injection re-runs every launch, so
        // warning would pop the same message every launch with nothing to
        // repair. The engine's first-match-wins tiebreak makes any residual
        // conflict a redundancy rather than a behavior cliff, and the
        // startup repair write (see DESIGN → Input → Binding overlay
        // semantics) cleans a warned file on the same launch.
        {
            var kept: std.ArrayList(types.InputBinding) = .empty;
            outer: for (bindings.items, 0..) |binding, binding_index| {
                const dropped_is_user_entry = binding_index < user_binding_count;
                for (kept.items) |kept_binding| {
                    if (!types.sameCombo(binding, kept_binding)) continue;
                    // Same combo on the SAME action: a redundant duplicate,
                    // dropped regardless of contexts.
                    if (binding.action == kept_binding.action) {
                        if (dropped_is_user_entry) {
                            if (warnings) |w| {
                                const input_name = switch (binding.input) {
                                    .key => |name| name,
                                    .mouse_button => |name| name,
                                    .gamepad_button => |name| name,
                                };
                                const message = std.fmt.allocPrint(allocator, "InputBindings entry '{s}' duplicates the combo already bound to '{s}'; entry dropped", .{ input_name, @tagName(binding.action) }) catch @panic("failed to format binding warning");
                                w.append(allocator, message) catch @panic("failed to append binding warning");
                            }
                        }
                        freeRawInputString(binding.input, allocator);
                        continue :outer;
                    }
                    // Different actions: a conflict ONLY when their derived
                    // contexts can be SIMULTANEOUSLY ACTIVE (they would
                    // co-fire - `bindingContextsCoFire`, NOT plain
                    // intersection: {anytime} co-fires with {game} in-game
                    // though the sets are disjoint). Cross-context same-combo
                    // pairs (Digit1 = skill in game / tool in editor) are
                    // LEGAL - keep both, no warning.
                    if (!types.bindingContextsCoFire(
                        types.actionBindingContexts(binding.action),
                        types.actionBindingContexts(kept_binding.action),
                    )) continue;
                    if (dropped_is_user_entry) {
                        if (warnings) |w| {
                            const input_name = switch (binding.input) {
                                .key => |name| name,
                                .mouse_button => |name| name,
                                .gamepad_button => |name| name,
                            };
                            const message = std.fmt.allocPrint(allocator, "InputBindings combo '{s}' already fires '{s}'; the binding to '{s}' is dropped (one combo fires one action per context)", .{ input_name, @tagName(kept_binding.action), @tagName(binding.action) }) catch @panic("failed to format binding warning");
                            w.append(allocator, message) catch @panic("failed to append binding warning");
                        }
                    }
                    // The dropped entry's owned string dies here; kept
                    // entries keep theirs (they move into `kept`).
                    freeRawInputString(binding.input, allocator);
                    continue :outer;
                }
                kept.append(allocator, binding) catch @panic("failed to append kept binding");
            }
            bindings.deinit(allocator);
            bindings = kept;
        }

        // Free the base's bindings before replacing (when a base is provided,
        // its bindings - and their owned input_name strings - were heap-
        // allocated by a prior loadSettings call; when no base,
        // input_bindings is the static &.{} and must not be freed). The
        // strings are owned (duped above), so free them too, not just the
        // slice - otherwise replacing bindings leaks the old names.
        if (has_base and settings.input_bindings.len > 0) {
            for (settings.input_bindings) |*binding| {
                freeRawInputString(binding.input, allocator);
            }
            allocator.free(settings.input_bindings);
        }
        settings.input_bindings = bindings.toOwnedSlice(allocator) catch @panic("failed to own input bindings slice");
    }

    return settings;
}

/// Free a `RawInput`'s owned string slice (the active union variant).
/// Only valid for inputs whose string was duped by `loadSettings` - a
/// borrowed slice (e.g. the static `&.{}` empty-bindings default, which has
/// no strings) must not be passed. Used by `freeSettings` and by the
/// binding-replace path in `loadSettings`.
pub fn freeRawInputString(input: types.RawInput, allocator: std.mem.Allocator) void {
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
/// `loadSettings`) is safe to pass - the loop is empty and the len guard
/// skips the slice free.
pub fn freeSettings(settings: types.Settings, allocator: std.mem.Allocator) void {
    for (settings.input_bindings) |*binding| {
        freeRawInputString(binding.input, allocator);
    }
    if (settings.input_bindings.len > 0) {
        allocator.free(settings.input_bindings);
    }
}

/// Parse an entity definition (the shared body of an Entities entry, a player
/// loadout, or an editor EntityTypeDef template) from a set of key-value
/// pairs. `team` is set by the caller (enemies = 1, player = 0) since the
/// format doesn't carry it. `default_name` / `default_sprite` are used when
/// the pairs don't specify name/sprite (player loadout defaults to
/// "Player"/"player"). current_health is set to max_health (reset by
/// instantiateEditorLevel for placements). Utility skills are read from
/// `slot_4`..`slot_8` keys (matching the save format), so the player loadout
/// carries its bar; enemy types can too if present.
fn parseEntityDefinition(
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
    if (findValue(pairs, "team")) |value| {
        entity.team = asU32(value) orelse team;
    }
    if (findValue(pairs, "color_index")) |value| {
        entity.color_index = asU32(value) orelse 0;
    }
    if (findValue(pairs, "displays_weapons")) |value| {
        entity.displays_weapons = asBool(value) orelse true;
    }
    if (findValue(pairs, "keep_original_colors")) |value| {
        entity.keep_original_colors = asBool(value) orelse false;
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
            .weapon_damage = if (findValue(pairs, "main_hand_weapon_damage")) |value| boundedU32(value, types.max_weapon_damage, "main_hand_weapon_damage", file_path, warnings, allocator) else 0,
        };
    }
    // Off hand weapon
    if (findValue(pairs, "off_hand_weapon_name")) |name| {
        entity.off_hand_weapon = .{
            .name = name,
            .weapon_type = if (findValue(pairs, "off_hand_weapon_type")) |value| parseEnum(types.WeaponType, value) orelse .sword else .sword,
            .weapon_damage = if (findValue(pairs, "off_hand_weapon_damage")) |value| boundedU32(value, types.max_weapon_damage, "off_hand_weapon_damage", file_path, warnings, allocator) else 0,
        };
    }
    // Gear
    if (findValue(pairs, "amulet_name")) |name| {
        entity.amulet = .{ .name = name, .spell_damage = if (findValue(pairs, "amulet_spell_damage")) |value| boundedU32(value, types.max_spell_damage, "amulet_spell_damage", file_path, warnings, allocator) else 0 };
    }
    if (findValue(pairs, "coat_name")) |name| {
        entity.coat = .{
            .name = name,
            .defense_bonus = if (findValue(pairs, "coat_defense_bonus")) |value| boundedU32(value, types.max_defense_bonus, "coat_defense_bonus", file_path, warnings, allocator) else 0,
            .health_bonus = if (findValue(pairs, "coat_health_bonus")) |value| boundedU32(value, types.max_health_bonus, "coat_health_bonus", file_path, warnings, allocator) else 0,
        };
    }
    if (findValue(pairs, "gloves_name")) |name| {
        entity.gloves = .{
            .name = name,
            .damage_bonus = if (findValue(pairs, "gloves_damage_bonus")) |value| boundedU32(value, types.max_gloves_damage, "gloves_damage_bonus", file_path, warnings, allocator) else 0,
            .health_bonus = if (findValue(pairs, "gloves_health_bonus")) |value| boundedU32(value, types.max_health_bonus, "gloves_health_bonus", file_path, warnings, allocator) else 0,
        };
    }
    if (findValue(pairs, "pants_name")) |name| {
        entity.pants = .{
            .name = name,
            .pickup_radius_bonus = if (findValue(pairs, "pants_pickup_radius_bonus")) |value| boundedU32(value, types.max_pickup_radius, "pants_pickup_radius_bonus", file_path, warnings, allocator) else 0,
            .health_bonus = if (findValue(pairs, "pants_health_bonus")) |value| boundedU32(value, types.max_health_bonus, "pants_health_bonus", file_path, warnings, allocator) else 0,
        };
    }
    if (findValue(pairs, "boots_name")) |name| {
        entity.boots = .{
            .name = name,
            .speed_bonus = if (findValue(pairs, "boots_speed_bonus")) |value| boundedU32(value, types.max_boots_speed, "boots_speed_bonus", file_path, warnings, allocator) else 0,
            .health_bonus = if (findValue(pairs, "boots_health_bonus")) |value| boundedU32(value, types.max_health_bonus, "boots_health_bonus", file_path, warnings, allocator) else 0,
        };
    }

    // Utility skills (slot_4..slot_8, matching the save format). Enemy types
    // can carry a bar if present; the player loadout normally does. Only
    // UTILITY skills are legal on the bar (weapon skills belong to the
    // equipped weapon) - a weapon skill here is warned + dropped.
    var slot_key_buf: [16]u8 = undefined;
    for (0..types.utility_skill_count) |i| {
        const key = std.fmt.bufPrint(&slot_key_buf, "slot_{d}", .{i + 4}) catch continue;
        if (findValue(pairs, key)) |value| {
            if (parseEnum(types.SkillId, value)) |skill_id| {
                if (!utility_skills.isUtilitySkill(skill_id)) {
                    appendWarning(
                        warnings,
                        allocator,
                        "Weapon skill '{s}' in {s} is not allowed on the utility bar (slot_{d}); dropped",
                        .{ value, file_path, i + 4 },
                    );
                    continue;
                }
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

/// Load a player start loadout from a mission's player.txt. The file is
/// SAVE-SHAPED (the loadout sections of a player save: weapons, gear,
/// inventory, utility skills - no Info / stats / hubs / clones /
/// UnlockedSkills; base stats are NOT authorable, the template keeps the
/// Entity defaults, and learned is implied for the editor player). The
/// parsed fields map onto the player template exactly as
/// `build_player_from_data` maps PlayerData onto the level player.
pub fn loadPlayerLoadout(
    sections: []const Section,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !types.Entity {
    _ = try validateFileFormatVersion(sections, "Metadata", player_loadout_file_format_version, player_loadout_file_format_version);
    var player_data: PlayerData = .{};
    try parsePlayerLoadoutFields(sections, allocator, file_path, warnings, &player_data);
    return playerLoadoutEntity(player_data);
}

/// Map a PlayerData's loadout onto the editor player template - the
/// `build_player_from_data` field set (name, gear, inventory, utility
/// skills). BORROWS the source's slices; the caller owns both graphs (the
/// loaders parse into the same arena, the import handler deep-copies
/// first). A nameless source (a mission player.txt - the loadout sections
/// carry no name) defaults to "Player".
pub fn playerLoadoutEntity(player_data: PlayerData) types.Entity {
    return .{
        .name = if (player_data.player_name.len > 0) player_data.player_name else "Player",
        .sprite = "player",
        .team = 0,
        .main_hand_weapon = player_data.main_hand_weapon,
        .off_hand_weapon = player_data.off_hand_weapon,
        .amulet = player_data.amulet,
        .coat = player_data.coat,
        .gloves = player_data.gloves,
        .pants = player_data.pants,
        .boots = player_data.boots,
        .equipped_utility_skills = player_data.equipped_utility_skills,
        .inventory = player_data.inventory,
    };
}

/// Compare two entity definitions for palette dedup. Compares the DEFINITION
/// fields only (name, sprite, team, stats, weapons, gear, utility skills) -
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
    if (a.keep_original_colors != b.keep_original_colors) return false;
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
fn decorationDefinitionsEqual(a: types.Decoration, b: types.Decoration) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.footprint.len != b.footprint.len) return false;
    for (a.footprint, b.footprint) |fa, fb| {
        if (fa.x != fb.x or fa.y != fb.y) return false;
    }
    if (a.color_index != b.color_index) return false;
    if (a.keep_original_colors != b.keep_original_colors) return false;
    return decorationLayersEqual(a.layers, b.layers);
}

/// Compare two decoration layer slices for palette dedup.
pub fn decorationLayersEqual(a: []const types.DecorationLayer, b: []const types.DecorationLayer) bool {
    if (a.len != b.len) return false;
    for (a, b) |la, lb| {
        if (!std.mem.eql(u8, la.sprite, lb.sprite)) return false;
        if (la.color_index != lb.color_index) return false;
        if (la.behind != lb.behind) return false;
    }
    return true;
}

/// Free everything `buildEditorMission` allocates (the palette lists +
/// the editor levels' owned fields). NOT the Editor's `mission` or
/// `player_def` - those are moved in from the caller, not allocated by
/// the build. Per-kind ownership (the build's contract):
///   - entity types: the template is loadLevel's placed entity, MOVED
///     wholesale (fully clone-owned: strings + layers); `id` aliases
///     `template.name`, so it is freed with the template, never by
///     itself.
///   - decoration types: `id`/`sprite` alias ONE moved string (the
///     level decoration's owned name - freed once, via `id`);
///     `footprint` + `layers` are deep-duped with owned layer sprite
///     strings.
///   - item types: the item is MOVED (owns its name); the `id` is OWNED
///     by construction (duped - `itemDisplayName` allocates for skill
///     tomes and borrows for everything else, so every id frees the
///     same way).
///   - editor levels: `name` + `level_tiles` + the three placements
///     buffers are MOVED or duped (owned - nothing borrows the parsed
///     sections).
/// Takes EXACT slices (toOwnedSlice-shaped) - a bare ArrayList .items
/// slice can be shorter than its buffer's capacity, and freeing it
/// would be a size-mismatch free.
/// Used by the build's errdefer + its leak-checked tests.
fn freeEditorBuild(
    levels: []const types.EditorLevel,
    entity_types: []const types.EntityTypeDef,
    decoration_types: []const types.DecorationTypeDef,
    item_types: []const types.ItemTypeDef,
    allocator: std.mem.Allocator,
) void {
    for (entity_types) |entity_type| freeEntity(entity_type.template, allocator);
    allocator.free(entity_types);
    for (decoration_types) |decoration_type| {
        allocator.free(decoration_type.id);
        allocator.free(decoration_type.footprint);
        for (decoration_type.layers) |layer| allocator.free(layer.sprite);
        allocator.free(decoration_type.layers);
    }
    allocator.free(decoration_types);
    for (item_types) |item_type| {
        allocator.free(item_type.id);
        freeItem(item_type.item, allocator);
    }
    allocator.free(item_types);
    for (levels) |editor_level| {
        allocator.free(editor_level.name);
        allocator.free(editor_level.level_tiles);
        allocator.free(editor_level.entity_placements);
        allocator.free(editor_level.decoration_placements);
        allocator.free(editor_level.item_placements);
    }
    allocator.free(levels);
}

/// Build an Editor session from already-parsed mission/player/level sections.
/// Pure (no file I/O) - the caller (open_editor handler) reads via
/// history.readReconstructionFile so the reconstruction cache makes undo
/// replay deterministic. Dedups the levels' inline entity/decoration/item
/// definitions into a shared palette (entity_types / decoration_types /
/// item_types).
/// The result is reference-based (EditorLevel + placements); save flattens
/// back to the existing inline format. Unused palette types are lost on
/// editor close (accepted). See DESIGN → Architecture → Level Editor.
///
/// OWNERSHIP: the palette + editor levels own everything they keep
/// (moved wholesale, deep-copied, or duped - NOTHING borrows the parsed
/// sections); each level's remnants are freed at
/// the end of its iteration, and a later level failing loadLevel frees
/// the accumulated palette via the errdefer - `freeEditorBuild`'s doc is
/// the per-kind contract. `mission` + `player_def` are moved in from the
/// caller; the Editor does not own them.
pub fn buildEditorMission(
    mission: types.Mission,
    player_entity: types.Entity,
    parsed_level_sections: []const []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    mission_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !types.Editor {
    var entity_types: std.ArrayList(types.EntityTypeDef) = .empty;
    var decoration_types: std.ArrayList(types.DecorationTypeDef) = .empty;
    var item_types: std.ArrayList(types.ItemTypeDef) = .empty;
    var editor_levels: std.ArrayList(types.EditorLevel) = .empty;

    // Error-path cleanup: the only error return past this point is a
    // LATER level's loadLevel failing (everything after a successful
    // loadLevel allocates with inline panics, per the config-layer OOM
    // convention) - free the accumulated palette. Per-level remnants
    // are freed inside the loop; the ownership model is freeEditorBuild's
    // doc. The lists convert to exact slices first (a bare .items slice
    // can be shorter than the buffer's capacity - freeing it would be a
    // size-mismatch free; empty lists yield empty slices, whose frees
    // are no-ops).
    errdefer {
        const owned_levels = editor_levels.toOwnedSlice(allocator) catch @panic("failed to own editor levels slice");
        const owned_entity_types = entity_types.toOwnedSlice(allocator) catch @panic("failed to own entity types slice");
        const owned_decoration_types = decoration_types.toOwnedSlice(allocator) catch @panic("failed to own decoration types slice");
        const owned_item_types = item_types.toOwnedSlice(allocator) catch @panic("failed to own item types slice");
        freeEditorBuild(
            owned_levels,
            owned_entity_types,
            owned_decoration_types,
            owned_item_types,
            allocator,
        );
    }

    for (parsed_level_sections) |sections| {
        const level = try loadLevel(sections, file_source, allocator, mission_path, warnings);

        // Entity placements: entity 0 is the player (skip - loadout comes from
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
                // MOVED: the palette's template owns the entity's strings
                // + layers (loadLevel's placed entities are fully
                // clone-owned); id aliases template.name.
                entity_types.append(allocator, .{
                    .id = entity.name,
                    .template = entity,
                }) catch @panic("failed to append entity type");
            } else {
                // Dedup-hit: this level's copy is redundant - the palette
                // kept the first occurrence's.
                freeEntity(entity, allocator);
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
                    dt.keep_original_colors == decoration.keep_original_colors and
                    decorationLayersEqual(dt.layers, decoration.layers))
                {
                    type_id = @intCast(dt_index);
                    break;
                }
            }
            if (type_id == null) {
                type_id = @intCast(decoration_types.items.len);
                // Deep-copy the visual identity: the footprint array +
                // layers with OWNED sprite strings (a shallow dupe would
                // borrow the level decoration's strings, which are freed
                // as remnants below). The name string MOVES - id/sprite
                // alias it (one string, freed once, via id).
                const fp = allocator.dupe(types.Vector2, decoration.footprint) catch
                    @panic("failed to dupe decoration footprint");
                const ly = allocator.alloc(types.DecorationLayer, decoration.layers.len) catch
                    @panic("failed to alloc decoration layers");
                for (decoration.layers, 0..) |layer, layer_index| {
                    ly[layer_index] = .{
                        .sprite = dupeString(allocator, layer.sprite),
                        .color_index = layer.color_index,
                        .behind = layer.behind,
                        .pixel_dims = layer.pixel_dims,
                    };
                }
                decoration_types.append(allocator, .{
                    .id = decoration.name,
                    .sprite = decoration.name,
                    .footprint = fp,
                    .pixel_dims = decoration.pixel_dims,
                    .color_index = decoration.color_index,
                    .keep_original_colors = decoration.keep_original_colors,
                    .layers = ly,
                }) catch @panic("failed to append decoration type");
                // The name moved to the palette; free the original's
                // remainder (footprint + layers + layer sprite strings).
                allocator.free(decoration.footprint);
                for (decoration.layers) |layer| allocator.free(layer.sprite);
                allocator.free(decoration.layers);
            } else {
                // Dedup-hit: this level's copy is redundant.
                freeDecoration(decoration, allocator);
            }
            deco_placements.append(allocator, .{
                .type_id = type_id.?,
                .position = decoration.position,
            }) catch @panic("failed to append decoration placement");
        }

        // Ground item placements: one placement per item (level files author
        // single-item stacks - one layout char per item; runtime drops can
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
                    // The item MOVES (owns its name); the id is OWNED by
                    // construction - itemDisplayName allocates for skill
                    // tomes and borrows for everything else, so the
                    // borrowed names are duped and every id frees the
                    // same way (freeEditorBuild).
                    item_types.append(allocator, .{
                        .id = switch (item) {
                            .skill_tome => itemDisplayName(item, allocator),
                            else => dupeString(allocator, itemDisplayName(item, allocator)),
                        },
                        .item = item,
                    }) catch @panic("failed to append item type");
                } else {
                    // Dedup-hit: this level's copy is redundant.
                    freeItem(item, allocator);
                }
                item_placements.append(allocator, .{
                    .type_id = type_id.?,
                    .position = stack.position,
                }) catch @panic("failed to append item placement");
            }
            // The stack's item buffer: the items themselves moved into
            // the palette (or were freed as dedup-hits) - the buffer is
            // this level's own.
            allocator.free(stack.items);
        }

        editor_levels.append(allocator, .{
            // OWNED (duped) - the one field that used to borrow the parsed
            // sections; uniform with the rest of the editor level now
            // (freeEditorBuild frees it).
            .name = dupeString(allocator, level.name),
            .color_wheel_index = level.color_wheel_index,
            .enemy_gradient_index = level.enemy_gradient_index,
            .player_gradient_index = level.player_gradient_index,
            .level_tiles = level.level_tiles,
            .player_start = level.entities[0].position,
            .level_end = level.level_end,
            // toOwnedSlice (not a bare .items move): the exact-allocation
            // slice the editor level can hand to freeEditorBuild later -
            // .items can be shorter than the buffer's capacity.
            .entity_placements = placements.toOwnedSlice(allocator) catch @panic("failed to own entity placements slice"),
            .decoration_placements = deco_placements.toOwnedSlice(allocator) catch @panic("failed to own decoration placements slice"),
            .item_placements = item_placements.toOwnedSlice(allocator) catch @panic("failed to own item placements slice"),
        }) catch @panic("failed to append editor level");

        // End of iteration - free this level's remnants: everything the
        // palette and the editor level did not take. The entities,
        // decorations, and items were each MOVED or freed above; what
        // remains is the player entity (never palette material -
        // player_def is the caller's), the three definition-array
        // buffers, and the stack buffers (freed in the item loop).
        // level.name borrows the sections; level_tiles + the placements
        // moved into the editor level entry.
        freeEntity(level.entities[0], allocator);
        allocator.free(level.entities);
        allocator.free(level.decorations);
        allocator.free(level.ground_items);
    }

    return .{
        .mission = mission,
        // toOwnedSlice per the placements note above; catch @panic (not
        // try) because a mid-literal try failure would drop the already-
        // converted slices with no errdefer coverage.
        .levels = editor_levels.toOwnedSlice(allocator) catch @panic("failed to own editor levels slice"),
        .entity_types = entity_types.toOwnedSlice(allocator) catch @panic("failed to own entity types slice"),
        .decoration_types = decoration_types.toOwnedSlice(allocator) catch @panic("failed to own decoration types slice"),
        .item_types = item_types.toOwnedSlice(allocator) catch @panic("failed to own item types slice"),
        .player_def = .{ .id = "Player", .template = player_entity },
    };
}

/// The editor's new-level template (data/default_level.txt): the minimal
/// valid layout - '!' at (0,0), '=' at (1,0), no floor, no entries. Loaded
/// by the `editor_add_level` handler through the reconstruction cache. The
/// template contract is STRICT: a level end must be present (the `!=`
/// shape) and no enemies / decorations / ground items may be authored into
/// it - placements belong to the palette + the viewport, not the template,
/// so anything more is a content error surfaced at the read site (the
/// editor-defaults posture), never silently dropped.
pub fn loadEditorDefaultLevel(
    sections: []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !types.EditorLevel {
    // The template contract forbids decorations (the DefaultLevelHasEntries
    // check below enforces it).
    const level = try loadLevel(sections, file_source, allocator, file_path, warnings);
    // Error-path cleanup: both template-contract errors fire after the
    // level owns its allocations - freeLevel on the way out. On success
    // the EditorLevel owns name (duped - nothing borrows the sections)
    // + level_tiles (moved), and the remnants - the player entity's
    // cloned strings + the entities buffer - are freed before returning
    // (decorations / ground items are empty by the contract check, so
    // their frees are no-ops and are left to freeLevel's shape on the
    // error path only).
    errdefer freeLevel(level, allocator);
    if (level.level_end == null) return error.MissingDefaultLevelEnd;
    if (level.entities.len != 1 or level.decorations.len != 0 or level.ground_items.len != 0) {
        return error.DefaultLevelHasEntries;
    }
    const editor_level = types.EditorLevel{
        // OWNED (duped) - uniform with buildEditorMission's editor levels
        // (freeEditorBuild's contract: nothing borrows the sections).
        .name = dupeString(allocator, level.name),
        .color_wheel_index = level.color_wheel_index,
        .enemy_gradient_index = level.enemy_gradient_index,
        .player_gradient_index = level.player_gradient_index,
        .level_tiles = level.level_tiles,
        .player_start = level.entities[0].position,
        .level_end = level.level_end,
    };
    freeEntity(level.entities[0], allocator);
    allocator.free(level.entities);
    return editor_level;
}

test "loadEditorDefaultLevel: DefaultLevelHasEntries after a successful load leaks nothing" {
    // The leak-checked error path: the error fires AFTER loadLevel
    // succeeded (a spawn + level end + an entity - the whole level is
    // owned), so the errdefer must freeLevel it. testing.allocator flags
    // any leak.
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\Layout 1
        \\!e=
        \\
        \\Entities
        \\character_code e
        \\name Enemy
        \\sprite skeleton_1
    ;
    const sections = try parseConfigFile(raw_text, allocator, &parser.level_sections);
    defer freeParsedSections(sections, allocator);
    try std.testing.expectError(
        error.DefaultLevelHasEntries,
        loadEditorDefaultLevel(sections, null, allocator, "test/default_level.txt", null),
    );
}

test "loadEditorDefaultLevel: the shipped template loads clean (remnants freed)" {
    // Success-path ownership: the result owns level_tiles (name borrows
    // the sections); the player-entity remnants (cloned strings + the
    // entities buffer) are freed on the way out.
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    const parsed = try parseConfigFileFromPath(
        &file_source,
        "data/default_level.txt",
        allocator,
        &parser.level_sections,
    );
    defer allocator.free(parsed.raw_text);
    defer freeParsedSections(parsed.sections, allocator);

    const editor_level = try loadEditorDefaultLevel(
        parsed.sections,
        &file_source,
        allocator,
        "data/default_level.txt",
        null,
    );
    try std.testing.expectEqual(@as(i32, 1), editor_level.level_end.?.x);
    try std.testing.expectEqual(@as(i32, 0), editor_level.level_end.?.y);
    // The result owns name + level_tiles; both freed here (the sections
    // are freed by the defers above).
    allocator.free(editor_level.name);
    allocator.free(editor_level.level_tiles);
}

/// Compare two decoration footprints for palette dedup + the decoration
/// picker's would-change gate (public: the input-side commit site compares
/// the resolved pick against the current definition).
pub fn decorationFootprintEqual(a: []const types.Vector2, b: []const types.Vector2) bool {
    if (a.len != b.len) return false;
    for (a, b) |fa, fb| {
        if (fa.x != fb.x or fa.y != fb.y) return false;
    }
    return true;
}

/// User-facing palette id for a ground-item type: the item's own name, or
/// "<Skill> Tome" for skill tomes (which carry no name field - mirrors the
/// item-tooltip naming in ui/tooltip.zig).
/// The item's palette display name (the Items group's label; the editor's
/// item defs keep `id` synced to this - the decoration id-tracks-the-sprite
/// rule). pub: shared by the editor item-def handlers.
pub fn itemDisplayName(item: types.Item, allocator: std.mem.Allocator) []const u8 {
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
    // The player's inventory is LOADOUT data (imported or authored), not
    // a combat-runtime field - entity 0 keeps the template's.
    player.inventory = editor.player_def.template.inventory;
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
            .keep_original_colors = dt.keep_original_colors,
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
        .enemy_gradient_index = editor_level.enemy_gradient_index,
        .player_gradient_index = editor_level.player_gradient_index,
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
    keep_original_colors: bool = false,
    layers: []const types.DecorationLayer = &.{},
};

/// Derive the anchor (bottom-most-then-left-most) from a sprite-grid footprint.
/// Returns null if the footprint is empty - the caller panics (a decoration
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

/// The world tiles a decoration placement reserves: the footprint's
/// sprite-grid coords translated so the ANCHOR tile (bottom-most-then-
/// left-most) sits at `anchor_position` (the placement's position). The
/// single source of this formula - the parse-time invariant check, the
/// editor placement orchestrators, and the footprint preview all read it.
/// An empty footprint reserves nothing (the loader rejects those at parse;
/// callers treat empty as "covers nothing").
pub fn decorationFootprintWorldTiles(
    footprint: []const types.Vector2,
    anchor_position: types.Vector2,
    allocator: std.mem.Allocator,
) []const types.Vector2 {
    const anchor = decorationAnchor(footprint) orelse return &.{};
    const tiles = allocator.alloc(types.Vector2, footprint.len) catch
        @panic("failed to allocate footprint world tiles");
    for (footprint, 0..) |fp, index| {
        tiles[index] = .{
            .x = anchor_position.x + (fp.x - anchor.x),
            .y = anchor_position.y + (fp.y - anchor.y),
        };
    }
    return tiles;
}

/// Does a decoration placement's footprint cover `world_tile`? Thin
/// wrapper over `decorationFootprintWorldTiles`. An empty footprint
/// reserves nothing (the loader rejects those at parse, so this is
/// defensive only). Shared by the editor placement/delete orchestrators
/// (event_handlers) and the select tool's click resolution
/// (input_handlers).
pub fn decorationFootprintCovers(
    footprint: []const types.Vector2,
    placement_position: types.Vector2,
    world_tile: types.Vector2,
    allocator: std.mem.Allocator,
) bool {
    for (decorationFootprintWorldTiles(footprint, placement_position, allocator)) |covered| {
        if (covered.x == world_tile.x and covered.y == world_tile.y) return true;
    }
    return false;
}

/// Warn (never reject) when a custom entity sprite - base or layer -
/// doesn't follow the fixed 512x640 entity frame. Warn-only at load (the
/// entity still spawns); the render-side gate (`customSpriteDimsPassGate`)
/// makes wrong-dims art draw as the magenta fallback, and the warning
/// names it for the author. Shipped stems are certified by the comptime
/// metadata table and skip the check.
fn warnEntitySpriteDimensions(
    entity: types.Entity,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
    file_path: []const u8,
) void {
    if (!std.mem.startsWith(u8, entity.sprite, "custom/")) return;
    const dims = resolveCustomSpriteFileDims(entity.sprite, file_source, allocator) orelse {
        appendLoadWarning(
            allocator,
            warnings,
            "entity sprite '{s}' in {s} could not be resolved (missing or invalid mission PNG) - will render as fallback",
            .{ entity.sprite, file_path },
        );
        return;
    };
    if (dims.x != types.entity_sprite_frame_width or dims.y != types.entity_sprite_frame_height) {
        appendLoadWarning(
            allocator,
            warnings,
            "entity sprite '{s}' in {s} is {d}x{d} - entity art must be 512x640; will render as fallback",
            .{ entity.sprite, file_path, dims.x, dims.y },
        );
    }
    for (entity.layers) |layer| {
        if (!std.mem.startsWith(u8, layer.sprite, "custom/")) continue;
        const layer_dims = resolveCustomSpriteFileDims(layer.sprite, file_source, allocator) orelse {
            appendLoadWarning(
                allocator,
                warnings,
                "entity layer sprite '{s}' in {s} could not be resolved (missing or invalid mission PNG) - will render as fallback",
                .{ layer.sprite, file_path },
            );
            continue;
        };
        if (layer_dims.x != types.entity_sprite_frame_width or layer_dims.y != types.entity_sprite_frame_height) {
            appendLoadWarning(
                allocator,
                warnings,
                "entity layer sprite '{s}' in {s} is {d}x{d} - entity art must be 512x640; will render as fallback",
                .{ layer.sprite, file_path, layer_dims.x, layer_dims.y },
            );
        }
    }
}

/// Clamp a placed decoration's footprint to what the level can honor -
/// hand-authored content is UNTRUSTED: invalid footprint tiles are DROPPED
/// with a warning, never a crash, and an emptied (or authored-empty)
/// footprint falls back to the sprite grid's bottom-left tile (the pick-
/// commit default). The clamps are pure functions of the file bytes, so
/// replay is unaffected. Mutates `decoration.footprint` in place (the
/// walk's per-placement clone owns the slice).
///   - footprint tiles outside the sprite bbox → dropped
///   - world footprint tiles overlapping a level/hub tile → dropped
///     (placement invariant - see DESIGN → Decorations & Footprint)
fn clampDecorationFootprint(
    decoration: *types.Decoration,
    tile_set: *const std.AutoHashMap(types.Vector2, void),
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
    file_path: []const u8,
) void {
    const grid_width: i32 = @divTrunc(decoration.pixel_dims.x, sprite_grid_tile_pixels);
    const grid_height: i32 = @divTrunc(decoration.pixel_dims.y, sprite_grid_tile_pixels);

    // Pass 1: keep in-bbox tiles only.
    var kept: std.ArrayList(types.Vector2) = .empty;
    defer kept.deinit(allocator);
    var dropped_outside: usize = 0;
    for (decoration.footprint) |fp_grid| {
        if (fp_grid.x < 0 or fp_grid.x >= grid_width or fp_grid.y < 0 or fp_grid.y >= grid_height) {
            dropped_outside += 1;
            continue;
        }
        kept.append(allocator, fp_grid) catch @panic("failed to append footprint tile");
    }
    if (dropped_outside > 0) {
        appendLoadWarning(
            allocator,
            warnings,
            "{d} footprint tiles on decoration '{s}' in {s} are outside the sprite bbox - dropped",
            .{ dropped_outside, decoration.name, file_path },
        );
    }

    // Pass 2: drop world-tile overlaps. Runs on the SURVIVORS - world
    // positions derive from the anchor, which the survivors determine.
    var dropped_overlap: usize = 0;
    if (kept.items.len > 0) {
        const world_tiles = decorationFootprintWorldTiles(kept.items, decoration.position, allocator);
        defer allocator.free(world_tiles);
        var write_index: usize = 0;
        for (kept.items, 0..) |fp_grid, index| {
            if (tile_set.contains(world_tiles[index])) {
                dropped_overlap += 1;
                continue;
            }
            kept.items[write_index] = fp_grid;
            write_index += 1;
        }
        kept.shrinkRetainingCapacity(write_index);
    }
    if (dropped_overlap > 0) {
        appendLoadWarning(
            allocator,
            warnings,
            "{d} footprint tiles on decoration '{s}' in {s} overlap level/hub tiles - dropped",
            .{ dropped_overlap, decoration.name, file_path },
        );
    }

    // Empty footprint (authored empty, or everything was dropped) → the
    // sprite grid's bottom-left tile, the pick-commit default. Grid dims are
    // ≥1 per axis by construction (dims are floored ≥256 at parse).
    if (kept.items.len == 0) {
        if (decoration.footprint.len == 0) {
            appendLoadWarning(
                allocator,
                warnings,
                "decoration '{s}' in {s} has no footprint tiles - defaulted to the sprite grid's bottom-left tile",
                .{ decoration.name, file_path },
            );
        } else {
            appendLoadWarning(
                allocator,
                warnings,
                "decoration '{s}' in {s}: every footprint tile was dropped - defaulted to the sprite grid's bottom-left tile",
                .{ decoration.name, file_path },
            );
        }
        kept.append(allocator, .{ .x = 0, .y = @max(0, grid_height - 1) }) catch
            @panic("failed to append default footprint tile");
    }

    // Nothing changed → keep the original slice (no realloc churn).
    if (dropped_outside == 0 and dropped_overlap == 0 and
        kept.items.len == decoration.footprint.len)
    {
        return;
    }

    const new_footprint = allocator.dupe(types.Vector2, kept.items) catch
        @panic("failed to allocate clamped footprint");
    allocator.free(decoration.footprint);
    decoration.footprint = new_footprint;
}

/// Parse one decoration entry's pairs (sprite / color_index / footprint /
/// layers) into a `DecorationDefinition`. Shared by the per-level inline
/// parser (keyed by `character_code`) and the registry parser (no
/// `character_code`). The `character_code` key, if present, is ignored here -
/// the caller handles it. See `parseDecorationDefinitions` for the entry
/// shape + `layer` delimiter semantics.
fn parseDecorationEntry(
    pairs: []const KeyValuePair,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
    file_path: []const u8,
) DecorationDefinition {
    const base_sprite = findValue(pairs, "sprite") orelse &.{};
    const base_color_index = asU32(findValue(pairs, "color_index") orelse "0") orelse 0;
    const keep_original_colors = asBool(findValue(pairs, "keep_original_colors") orelse "false") orelse false;

    // Resolve the base sprite's dims, degrading with warnings on every
    // spec violation (custom content is untrusted: warn + degrade, never
    // reject, never crash - the balance-bounds posture):
    //   - unresolvable (unknown shipped stem / missing or invalid mission
    //     PNG) → a one-tile 256x256 fallback; renders magenta (the texture
    //     store can't resolve it either)
    //   - not a whole multiple of 256 → floored to the sprite grid (the
    //     view math chunks per 256px bbox tile; edge remainder crops)
    //   - beyond 4096px → kept, warned (may exceed device max texture size)
    var base_pixel_dims: types.Vector2 = undefined;
    if (resolveDecorationSpriteDimensions(base_sprite, file_source, allocator)) |dims| {
        base_pixel_dims = dims;
    } else {
        appendLoadWarning(
            allocator,
            warnings,
            "decoration sprite '{s}' in {s} could not be resolved (not shipped, or a missing/invalid mission PNG) - falling back to 256x256",
            .{ base_sprite, file_path },
        );
        base_pixel_dims = .{ .x = sprite_grid_tile_pixels, .y = sprite_grid_tile_pixels };
    }
    const floored_base_dims = flooredSpriteGridDims(base_pixel_dims);
    if (floored_base_dims.x != base_pixel_dims.x or floored_base_dims.y != base_pixel_dims.y) {
        appendLoadWarning(
            allocator,
            warnings,
            "decoration sprite '{s}' in {s} is {d}x{d} - not a whole multiple of 256; floored to {d}x{d} (edge pixels crop)",
            .{ base_sprite, file_path, base_pixel_dims.x, base_pixel_dims.y, floored_base_dims.x, floored_base_dims.y },
        );
        base_pixel_dims = floored_base_dims;
    }
    if (base_pixel_dims.x > max_custom_sprite_dimension or base_pixel_dims.y > max_custom_sprite_dimension) {
        appendLoadWarning(
            allocator,
            warnings,
            "decoration sprite '{s}' in {s} is {d}x{d} - exceeds 4096px and may not render on some devices (max texture size)",
            .{ base_sprite, file_path, base_pixel_dims.x, base_pixel_dims.y },
        );
    }

    // Collect base footprint + parse layer sub-groups. The pairs list is
    // flat; a `layer` key delimits a new sub-group whose following
    // `sprite`/`color_index` pairs belong to it.
    var footprint: std.ArrayList(types.Vector2) = .empty;
    var layers: std.ArrayList(types.DecorationLayer) = .empty;
    var current_layer_sprite: ?[]const u8 = null;
    var current_layer_color: u32 = 0;
    var current_layer_behind: bool = false;
    var in_layer = false;

    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, "layer")) {
            // Finish the previous layer sub-group (if any).
            if (in_layer) finishLayer(
                current_layer_sprite,
                current_layer_color,
                current_layer_behind,
                base_sprite,
                base_pixel_dims,
                file_source,
                allocator,
                warnings,
                file_path,
                &layers,
            );
            // Start a new layer sub-group.
            in_layer = true;
            current_layer_sprite = null;
            current_layer_color = 0;
            current_layer_behind = false;
            continue;
        }

        if (in_layer) {
            if (std.mem.eql(u8, pair.key, "sprite")) {
                current_layer_sprite = pair.value;
            } else if (std.mem.eql(u8, pair.key, "color_index")) {
                current_layer_color = asU32(pair.value) orelse 0;
            } else if (std.mem.eql(u8, pair.key, "behind")) {
                current_layer_behind = asBool(pair.value) orelse false;
            }
            // Other keys (footprint, character_code) are ignored inside a
            // layer sub-group.
        } else {
            // Base-level fields.
            if (std.mem.eql(u8, pair.key, "footprint")) {
                const coords = parseVector2Pair(pair.value) orelse {
                    appendLoadWarning(
                        allocator,
                        warnings,
                        "malformed footprint line '{s}' on decoration '{s}' in {s} - skipped",
                        .{ pair.value, base_sprite, file_path },
                    );
                    continue;
                };
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
        current_layer_behind,
        base_sprite,
        base_pixel_dims,
        file_source,
        allocator,
        warnings,
        file_path,
        &layers,
    );

    return .{
        .sprite = base_sprite,
        .footprint = footprint.toOwnedSlice(allocator) catch @panic("failed to own footprint slice"),
        .pixel_dims = base_pixel_dims,
        .color_index = base_color_index,
        .keep_original_colors = keep_original_colors,
        .layers = layers.toOwnedSlice(allocator) catch @panic("failed to own layers slice"),
    };
}

/// Resolve a pending layer sub-group's sprite + color into a `DecorationLayer`
/// and append it. Shared by the two layer-finish sites in
/// `parseDecorationEntry` (mid-entry `layer` delimiter + end-of-entry).
/// No-op (appends nothing) when the layer had no `sprite`. Degrade + warn on
/// spec violations, never a panic: an unresolvable layer sprite is kept
/// (renders as fallback), and a dims mismatch against the base is kept too
/// (renders cropped to the base's grid - the view builds layer pieces from
/// the BASE's source rects).
fn finishLayer(
    layer_sprite: ?[]const u8,
    layer_color: u32,
    layer_behind: bool,
    base_sprite: []const u8,
    base_pixel_dims: types.Vector2,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
    file_path: []const u8,
    layers: *std.ArrayList(types.DecorationLayer),
) void {
    const sprite = layer_sprite orelse return;
    const layer_dims = resolveDecorationSpriteDimensions(sprite, file_source, allocator) orelse {
        appendLoadWarning(
            allocator,
            warnings,
            "layer sprite '{s}' on decoration '{s}' in {s} could not be resolved - kept, will render as fallback",
            .{ sprite, base_sprite, file_path },
        );
        layers.append(allocator, .{
            .sprite = sprite,
            .color_index = layer_color,
            .behind = layer_behind,
            .pixel_dims = .{ .x = 0, .y = 0 },
        }) catch @panic("failed to append decoration layer");
        return;
    };
    const floored_layer_dims = flooredSpriteGridDims(layer_dims);
    if (floored_layer_dims.x != base_pixel_dims.x or floored_layer_dims.y != base_pixel_dims.y) {
        appendLoadWarning(
            allocator,
            warnings,
            "layer sprite '{s}' on decoration '{s}' in {s} is {d}x{d} but the base is {d}x{d} - kept, will render cropped to the base grid",
            .{ sprite, base_sprite, file_path, floored_layer_dims.x, floored_layer_dims.y, base_pixel_dims.x, base_pixel_dims.y },
        );
    }
    layers.append(allocator, .{
        .sprite = sprite,
        .color_index = layer_color,
        .behind = layer_behind,
        .pixel_dims = floored_layer_dims,
    }) catch @panic("failed to append decoration layer");
}

/// Parse all decoration definitions from a level/hub's Decorations section
/// into a hashmap keyed by character code. Each entry group has:
///   character_code X  (single char)
///   sprite <name>        (base sprite)
///   color_index N        (optional, default 0 - world gradient index)
///   footprint x y        (one or more lines, sprite-grid coords)
///   layer                (delimiter - starts a layer sub-group)
///     sprite <name>      (layer sprite, must be same pixel dims as base)
///     color_index N      (layer color index)
///     behind true|false  (optional - draw behind the base instead of over)
/// A `layer` line is a delimiter: the following `sprite`/`color_index` pairs
/// belong to that layer until the next `layer` or end of entry. Pixel dims
/// are resolved from the comptime sprite-metadata table (shipped) or the file
/// source (custom). Spec violations (unresolvable sprites, non-grid dims, a
/// layer/base dims mismatch) degrade with a warning - see
/// `parseDecorationEntry` + `finishLayer`.
fn parseDecorationDefinitions(
    sections: []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
    file_path: []const u8,
) std.AutoHashMap(u8, DecorationDefinition) {
    var definitions = std.AutoHashMap(u8, DecorationDefinition).init(allocator);
    if (findSection(sections, "Decorations")) |section| {
        for (section.entry_groups) |group| {
            const code_string = findValue(group.pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;
            definitions.put(code_string[0], parseDecorationEntry(group.pairs, file_source, allocator, warnings, file_path)) catch
                @panic("failed to insert decoration definition");
        }
    }
    return definitions;
}

/// Load the decoration registry (`data/decorations.txt`) - one entry per
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
    _ = try validateFileFormatVersion(sections, "Metadata", decorations_file_format_version, decorations_file_format_version);
    var list: std.ArrayList(types.DecorationTypeDef) = .empty;
    if (findSection(sections, "Decorations")) |section| {
        for (section.entry_groups) |group| {
            // Skip an empty group (no sprite) - e.g. a trailing blank-line
            // artifact. A real entry must have a `sprite` key.
            if (findValue(group.pairs, "sprite") == null) continue;
            // Shipped content; warnings are null (registry regressions are
            // caught by the content tests, not surfaced at runtime).
            const def = parseDecorationEntry(group.pairs, file_source, allocator, null, "");
            list.append(allocator, .{
                .id = def.sprite,
                .sprite = def.sprite,
                .footprint = def.footprint,
                .pixel_dims = def.pixel_dims,
                .color_index = def.color_index,
                .keep_original_colors = def.keep_original_colors,
                .layers = def.layers,
            }) catch @panic("failed to append decoration registry entry");
        }
    }
    return list.toOwnedSlice(allocator) catch @panic("failed to own decoration registry slice");
}

/// The three editor palette "+" defaults (data/editor_defaults.txt): one
/// entry per kind in the level-file section formats - Entities (the shared
/// parseEntityDefinition body, team 1), Decorations (a registry-shaped entry:
/// sprite + footprint + color_index + layers), Items (an Items entry). No
/// character_code anywhere - the code is a level-Layout concern (the
/// data/decorations.txt precedent). The file is shipped content, so a missing
/// section or entry is a CONTENT error surfaced as a load error (the
/// add-type handler turns it into the recoverable popup), never a silent
/// fallback. Key validation reuses the level key map - the sections are the
/// level formats verbatim.
pub const EditorDefaults = struct {
    entity: types.EntityTypeDef,
    decoration: types.DecorationTypeDef,
    item: types.ItemTypeDef,
};

pub fn loadEditorDefaults(
    sections: []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !EditorDefaults {
    _ = try validateFileFormatVersion(sections, "Metadata", editor_defaults_file_format_version, editor_defaults_file_format_version);

    // Entity: the first Entities entry. name + sprite are required - the
    // template's other absent keys are exactly the "none of it" defaults
    // (no weapons / gear / utility skills / layers).
    const entities_section = findSection(sections, "Entities") orelse return error.MissingDefaultEntry;
    if (entities_section.entry_groups.len == 0) return error.MissingDefaultEntry;
    const entity_pairs = entities_section.entry_groups[0].pairs;
    if (findValue(entity_pairs, "name") == null or findValue(entity_pairs, "sprite") == null) {
        return error.MissingDefaultEntry;
    }
    const entity_template = parseEntityDefinition(entity_pairs, 1, "", "", allocator, file_path, warnings);
    // Error-path cleanup, scoped per parse: the templates' STRING fields
    // borrow the parsed sections (freed by freeParsedSections); only the
    // ARRAY fields are owned here. The later MissingDefaultEntry returns
    // fire after these allocations - the entity's layers first ...
    errdefer allocator.free(entity_template.layers);

    // Decoration: the first Decorations entry, registry shape (a `sprite`
    // key is the entry's identity; footprint/color/layers as authored).
    const decorations_section = findSection(sections, "Decorations") orelse return error.MissingDefaultEntry;
    if (decorations_section.entry_groups.len == 0) return error.MissingDefaultEntry;
    const decoration_pairs = decorations_section.entry_groups[0].pairs;
    if (findValue(decoration_pairs, "sprite") == null) return error.MissingDefaultEntry;
    const decoration_definition = parseDecorationEntry(decoration_pairs, file_source, allocator, warnings, file_path);
    // ... then the decoration's footprint + layers arrays (the same
    // registry-shape ownership - see freeDecorationRegistry).
    errdefer {
        allocator.free(decoration_definition.footprint);
        allocator.free(decoration_definition.layers);
    }

    // Item: the first Items entry (a valid item_type is required).
    const items_section = findSection(sections, "Items") orelse return error.MissingDefaultEntry;
    if (items_section.entry_groups.len == 0) return error.MissingDefaultEntry;
    const item = parseItemEntry(items_section.entry_groups[0].pairs, file_path, warnings, allocator) orelse return error.MissingDefaultEntry;

    return .{
        .entity = .{ .id = entity_template.name, .template = entity_template },
        .decoration = .{
            .id = decoration_definition.sprite,
            .sprite = decoration_definition.sprite,
            .footprint = decoration_definition.footprint,
            .pixel_dims = decoration_definition.pixel_dims,
            .color_index = decoration_definition.color_index,
            .keep_original_colors = decoration_definition.keep_original_colors,
            .layers = decoration_definition.layers,
        },
        .item = .{ .id = itemDisplayName(item, allocator), .item = item },
    };
}

/// Parse a `"x y"` pair of integers into a Vector2. Returns null on failure.
/// Parse a two-integer space-separated pair ("-200 300") into a Vector2 -
/// the position-key convention (campaign.txt Hubs/Orphans entries).
pub fn parseVector2Pair(value: []const u8) ?types.Vector2 {
    var it = std.mem.tokenizeScalar(u8, value, ' ');
    const x_str = it.next() orelse return null;
    const y_str = it.next() orelse return null;
    const x = asI32(x_str) orelse return null;
    const y = asI32(y_str) orelse return null;
    return .{ .x = x, .y = y };
}

/// Resolve a custom sprite stem's pixel dims by reading the PNG its id
/// addresses (the tail after `custom/` IS the content path -
/// file_source.customAssetTail; readFile's tiers cover both the persistent
/// root and embedded `data/` content). Returns null when the stem is
/// malformed, the file source is missing, or the file is unreadable or not
/// a valid PNG - callers degrade with a warning (custom content is
/// untrusted; never a crash).
fn resolveCustomSpriteFileDims(
    sprite_stem: []const u8,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
) ?types.Vector2 {
    const tail = file_source_mod.customAssetTail(sprite_stem) orelse return null;
    const source = file_source orelse return null;
    const path = std.fmt.allocPrint(allocator, "{s}.png", .{tail}) catch
        @panic("failed to build custom sprite path for dims resolution");
    defer allocator.free(path);
    const bytes = source.readFile(allocator, path) catch return null;
    defer allocator.free(bytes);
    return parsePngDimensions(bytes);
}

/// Resolve a campaign background stem's PNG dims (the campaign editor's
/// set-background event - the open path's `resolveCampaignBackgroundDims`
/// as a direct call). The stem mints into the content-addressed sprite
/// id first (the load-side minting rule). Pub for the campaign editor's
/// handler (its pure-transform signature carries no history - the dims
/// read is the one live seam, passed the file source by the dispatch).
pub fn resolveCampaignBackgroundDimsForStem(
    campaign_content_dir: []const u8,
    stem: []const u8,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
) ?types.Vector2 {
    if (stem.len == 0) return null;
    const sprite_id = file_source_mod.customStemForContentPath(campaign_content_dir, stem, allocator);
    defer allocator.free(sprite_id);
    return resolveCustomSpriteFileDims(sprite_id, file_source, allocator);
}

/// The pick-commit backstop for custom ENTITY sprites (the picker filter's
/// defense-in-depth - a stale scan or crafted input): does the custom stem
/// resolve to a PNG with exactly the fixed 512x640 entity frame?
/// False on missing/invalid files too.
pub fn customEntitySpriteConforms(
    file_source: *const FileSource,
    sprite_stem: []const u8,
    allocator: std.mem.Allocator,
) bool {
    const dims = resolveCustomSpriteFileDims(sprite_stem, file_source, allocator) orelse
        return false;
    return types.entitySpriteDimsConform(dims);
}

/// Resolve a decoration sprite's pixel dims at LOAD time. Exactly two
/// channels - custom assets are always content-addressed and never live
/// under assets/ (see DESIGN → Custom Missions & Online Services →
/// Custom-asset paths):
///   1. a `custom/<content-path>/<file-stem>` stem reads the PNG its id
///      addresses (file_source.customAssetTail - the same rule the texture
///      store uses for the bytes)
///   2. anything else must be a shipped decoration (comptime table -
///      keyed by the asset-relative path `decorations/tree_1`, so the
///      bare config stem gets the `decorations/` prefix)
/// Returns null when neither channel resolves (an unknown shipped stem,
/// or a missing/invalid custom PNG) - the caller degrades with a
/// warning (custom content is untrusted; never a crash).
fn resolveDecorationSpriteDimensions(
    sprite_stem: []const u8,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
) ?types.Vector2 {
    if (std.mem.startsWith(u8, sprite_stem, "custom/")) {
        return resolveCustomSpriteFileDims(sprite_stem, file_source, allocator);
    }

    const full_id = std.fmt.allocPrint(allocator, "decorations/{s}", .{sprite_stem}) catch
        @panic("failed to build decoration sprite id for dims");
    defer allocator.free(full_id);
    const dims_str = sprite_metadata.map.get(full_id) orelse return null;
    return parseDimsString(dims_str);
}

// -- Ownership helpers --
//
// `parseEntityDefinition` and `parseDecorationDefinitions` return definitions
// whose STRING fields are BORROWED from the parsed config's `pairs` backing
// (freed by `freeParsedSections`) and whose ARRAY fields (footprint, layers)
// are OWNED via `toOwnedSlice`. The layout walk CLONES each placed
// entity/decoration/item so the level fully owns its data (no sharing with
// the definition hashmaps). `freeLevel`/`freeHub` then deep-free everything
// uniformly - use them in tests with `std.testing.allocator`. In production,
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
fn freeEntity(entity: types.Entity, allocator: std.mem.Allocator) void {
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
            .behind = layer.behind,
            .pixel_dims = layer.pixel_dims,
        };
    }
    decoration.layers = duped_layers;
}

/// Free a decoration's owned fields (name + footprint + layers).
fn freeDecoration(decoration: types.Decoration, allocator: std.mem.Allocator) void {
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
fn freeDecorationRegistry(registry: []types.DecorationTypeDef, allocator: std.mem.Allocator) void {
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
fn freeItem(item: types.Item, allocator: std.mem.Allocator) void {
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
fn freeLevel(level: types.Level, allocator: std.mem.Allocator) void {
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

/// Free all heap-allocated data in a Hub (name, tiles, player, npcs,
/// decorations, mission exits). The Hub is self-owned: after loadHub, no
/// field borrows from the parsed sections, so freeing the sections before
/// the Hub is safe. Use in tests with `std.testing.allocator`; in
/// production, the arena absorbs everything.
fn freeHub(hub: types.Hub, allocator: std.mem.Allocator) void {
    allocator.free(hub.name);
    allocator.free(hub.uuid);
    allocator.free(hub.hub_tiles);
    freeEntity(hub.player, allocator);
    allocator.free(hub.npcs);
    for (hub.decorations) |decoration| freeDecoration(decoration, allocator);
    allocator.free(hub.decorations);
    for (hub.mission_exits) |exit| {
        allocator.free(exit.mission_uuid);
    }
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
fn freeEntityDefinitions(definitions: *std.AutoHashMap(u8, types.Entity), allocator: std.mem.Allocator) void {
    var it = definitions.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.value_ptr.layers);
    }
    definitions.deinit();
}

/// Parse one Items entry's pairs (item_type + item_name + the kind's stat
/// keys) into an Item. Shared by the level Items parser (keyed by
/// character_code) and the editor palette defaults (no character_code -
/// nothing is placed). Returns null when the entry carries no valid
/// `item_type` (the level parser skips such groups). Skill tomes are not
/// level-authorable and have no entry shape here.
fn parseItemEntry(
    pairs: []const KeyValuePair,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) ?types.Item {
    const item_type = findValue(pairs, "item_type") orelse return null;

    const ItemTypeId = enum { weapon, amulet, coat, gloves, pants, boots };
    const item_type_id = parseEnum(ItemTypeId, item_type) orelse return null;
    const item_name = findValue(pairs, "item_name") orelse &.{};

    return switch (item_type_id) {
        .weapon => .{ .weapon = .{
            .name = item_name,
            .weapon_type = parseEnum(types.WeaponType, findValue(pairs, "weapon_type") orelse "sword") orelse .sword,
            .weapon_damage = boundedU32(findValue(pairs, "damage") orelse "0", types.max_weapon_damage, "damage", file_path, warnings, allocator),
        } },
        .amulet => .{ .amulet = .{
            .name = item_name,
            .spell_damage = boundedU32(findValue(pairs, "spell_damage") orelse "0", types.max_spell_damage, "spell_damage", file_path, warnings, allocator),
        } },
        .coat => .{ .coat = .{
            .name = item_name,
            .defense_bonus = boundedU32(findValue(pairs, "defense") orelse "0", types.max_defense_bonus, "defense", file_path, warnings, allocator),
            .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
        } },
        .gloves => .{ .gloves = .{
            .name = item_name,
            .damage_bonus = boundedU32(findValue(pairs, "damage") orelse "0", types.max_gloves_damage, "damage", file_path, warnings, allocator),
            .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
        } },
        .pants => .{ .pants = .{
            .name = item_name,
            .pickup_radius_bonus = boundedU32(findValue(pairs, "pickup_radius") orelse "0", types.max_pickup_radius, "pickup_radius", file_path, warnings, allocator),
            .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
        } },
        .boots => .{ .boots = .{
            .name = item_name,
            .speed_bonus = boundedU32(findValue(pairs, "speed") orelse "0", types.max_boots_speed, "speed", file_path, warnings, allocator),
            .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
        } },
    };
}

pub fn loadLevel(
    sections: []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !Level {
    const file_version = try validateFileFormatVersion(sections, "Metadata", parser.oldest_supported_level_file_format_version, level_file_format_version);
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
            // Optional per-role gradient overrides; absent (or unparsable)
            // = auto-derive from the world index. See DESIGN → Level Editor
            // → Level theme.
            if (findValue(pairs, "enemy_gradient_index")) |value| {
                level.enemy_gradient_index = asU32(value);
            }
            if (findValue(pairs, "player_gradient_index")) |value| {
                level.player_gradient_index = asU32(value);
            }
        }
    }

    // Parse decoration definitions keyed by character code (sprite +
    // sprite-grid footprint + pixel dims). Replaces the old decoration_codes
    // list - the layout walk now looks up the full definition per char.
    var decoration_definitions = parseDecorationDefinitions(sections, file_source, allocator, warnings, file_path);
    defer freeDecorationDefinitions(&decoration_definitions, allocator);
    var entity_definitions = std.AutoHashMap(u8, types.Entity).init(allocator);
    defer freeEntityDefinitions(&entity_definitions, allocator);
    if (findSection(sections, "Entities")) |section| {
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const code_string = findValue(pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;
            const entity = parseEntityDefinition(pairs, 1, &.{}, &.{}, allocator, file_path, warnings);
            warnEntitySpriteDimensions(entity, file_source, allocator, warnings, file_path);
            entity_definitions.put(code_string[0], entity) catch @panic("failed to insert entity definition");
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
            const item = parseItemEntry(pairs, file_path, warnings, allocator) orelse continue;

            item_definitions.put(code_string[0], item) catch @panic("failed to insert item definition");
        }
    }

    // Parse layout grid
    var tile_positions: std.ArrayList(types.Vector2) = .empty;
    // Player is always entity index 0
    var entity_list: std.ArrayList(types.Entity) = .empty;
    var player_entity: types.Entity = .{ .name = "Player", .sprite = "player", .team = 0 };
    cloneEntityOwned(&player_entity, allocator);
    entity_list.append(allocator, player_entity) catch @panic("failed to append player entity");
    var decoration_list: std.ArrayList(types.Decoration) = .empty;
    var ground_item_list: std.ArrayList(types.GroundItems) = .empty;
    var player_start: ?types.Vector2 = null;

    // Partial-build cleanup on any error return (missing markers, an
    // unknown layout character): the local lists own everything until
    // the tail's toOwnedSlice calls move it into `level`. Both halves
    // are safe together - a toOwnedSlice'd list is empty (its loop
    // no-ops) and a not-yet-assigned level field is an empty slice.
    errdefer {
        for (entity_list.items) |entity| freeEntity(entity, allocator);
        entity_list.deinit(allocator);
        for (decoration_list.items) |decoration| freeDecoration(decoration, allocator);
        decoration_list.deinit(allocator);
        for (ground_item_list.items) |stack| {
            for (stack.items) |item| freeItem(item, allocator);
            allocator.free(stack.items);
        }
        ground_item_list.deinit(allocator);
        tile_positions.deinit(allocator);
        freeLevel(level, allocator);
    }

    if (findSection(sections, "Layout")) |section| {
        // A current-version file must use the counted grammar - a bare
        // Layout here means a hand-authored v2 file that forgot the count,
        // silently falling back to the legacy grammar's known ambiguity
        // (a row spelling a header ends the section).
        if (file_version == level_file_format_version and section.layout_row_count == null) {
            return error.UncountedLayout;
        }
        for (section.raw_lines, 0..) |row, raw_y| {
            const y: i32 = @intCast(raw_y);
            for (row, 0..) |character, raw_x| {
                const x: i32 = @intCast(raw_x);
                const position = types.Vector2{ .x = x, .y = y };

                switch (character) {
                    ' ' => {},
                    '.' => tile_positions.append(allocator, position) catch @panic("failed to append tile position"),
                    '!' => {
                        player_start = position;
                        tile_positions.append(allocator, position) catch @panic("failed to append tile position");
                    },
                    '=' => {
                        level.level_end = position;
                        tile_positions.append(allocator, position) catch @panic("failed to append tile position");
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
                                .keep_original_colors = deco_def.keep_original_colors,
                                .layers = deco_def.layers,
                            };
                            cloneDecorationOwned(&decoration, allocator);
                            decoration_list.append(allocator, decoration) catch @panic("failed to append decoration");
                        } else if (entity_definitions.get(character)) |definition| {
                            // An entity's tile is walkable.
                            tile_positions.append(allocator, position) catch @panic("failed to append tile position");
                            var entity = definition;
                            entity.position = position;
                            cloneEntityOwned(&entity, allocator);
                            entity_list.append(allocator, entity) catch @panic("failed to append entity");
                        } else if (item_definitions.get(character)) |item| {
                            // An item's tile is walkable.
                            tile_positions.append(allocator, position) catch @panic("failed to append tile position");
                            const items = allocator.alloc(types.Item, 1) catch @panic("failed to alloc ground item stack");
                            items[0] = item;
                            cloneItemOwned(&items[0], allocator);
                            ground_item_list.append(allocator, .{
                                .position = position,
                                .items = items,
                            }) catch @panic("failed to append ground item stack");
                        } else {
                            // Declared nowhere in THIS file - not a
                            // decoration, entity, or item code, not a
                            // special. A typo'd character_code, not a
                            // walkable tile (the old silent fallback made
                            // it one).
                            return error.UnknownLayoutCharacter;
                        }
                    },
                }
            }
        }
    }

    // Both markers are mandatory: '!' is the player spawn (entity 0's
    // position + the spawn-relative origin), '=' the level end. The
    // editor's planners treat both as movable-never-deletable singletons
    // and the fresh-level template ships them, so a written level always
    // carries both - a missing one is a corrupt or hand-mangled file, not
    // a level to load with a default-positioned player / no exit.
    const spawn = player_start orelse return error.MissingPlayerSpawn;
    if (level.level_end == null) return error.MissingLevelEnd;

    // Set player start position (entity index 0)
    entity_list.items[0].position = spawn;

    // Spawn-relative coordinates: displace everything so the player
    // spawn ('!') is the origin (0,0). World positions then stay
    // invariant under layout-bbox growth in any direction - a decoration
    // placed off the playable area expands the grid but shifts nothing,
    // so absolute positions in recorded replays remain valid. The editor
    // load path (buildEditorMission) reuses this loader, so editor
    // coordinates agree; the editor's writer offsets by bbox origin, so
    // the load→save round trip is idempotent. See DESIGN → Logging & Replay
    // → Spawn-relative coordinates.
    {
        const offset = types.Vector2{ .x = -spawn.x, .y = -spawn.y };
        for (tile_positions.items) |*tile| {
            tile.* = .{ .x = tile.x + offset.x, .y = tile.y + offset.y };
        }
        for (entity_list.items) |*entity| {
            entity.position = .{ .x = entity.position.x + offset.x, .y = entity.position.y + offset.y };
        }
        for (decoration_list.items) |*decoration| {
            decoration.position = .{ .x = decoration.position.x + offset.x, .y = decoration.position.y + offset.y };
        }
        for (ground_item_list.items) |*stack| {
            stack.position = .{ .x = stack.position.x + offset.x, .y = stack.position.y + offset.y };
        }
        if (level.level_end) |*end| {
            end.* = .{ .x = end.x + offset.x, .y = end.y + offset.y };
        }
    }

    // Clamp decoration footprints: invalid tiles are dropped with a
    // warning (untrusted content - never a crash); a world footprint tile
    // must not overlap a level tile (placement invariant - see DESIGN →
    // Decorations & Footprint). Build a tile-position set for O(1) lookup.
    var tile_set = std.AutoHashMap(types.Vector2, void).init(allocator);
    defer tile_set.deinit();
    for (tile_positions.items) |tile| {
        tile_set.put(tile, {}) catch @panic("failed to insert tile into set");
    }
    for (decoration_list.items) |*decoration| {
        clampDecorationFootprint(decoration, &tile_set, allocator, warnings, file_path);
    }

    level.level_tiles = tile_positions.toOwnedSlice(allocator) catch @panic("failed to own level tiles slice");
    level.entities = entity_list.toOwnedSlice(allocator) catch @panic("failed to own level entities slice");
    level.decorations = decoration_list.toOwnedSlice(allocator) catch @panic("failed to own level decorations slice");
    level.ground_items = ground_item_list.toOwnedSlice(allocator) catch @panic("failed to own level ground items slice");

    return level;
}

/// Linear membership test over the dropped-NPC code list (a tiny list -
/// one entry per warned + dropped NPC entry, not worth a hash set).
fn containsCharacter(
    codes: []const u8,
    character: u8,
) bool {
    for (codes) |code| {
        if (code == character) return true;
    }
    return false;
}

pub fn loadHub(
    sections: []const Section,
    file_source: ?*const FileSource,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !Hub {
    const file_version = try validateFileFormatVersion(sections, "Metadata", parser.oldest_supported_hub_file_format_version, hub_file_format_version);
    var hub: Hub = .{};

    // Metadata
    if (findSection(sections, "Metadata")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "name")) |value| {
                hub.name = dupeString(allocator, value);
            }
            if (findValue(pairs, "hub_uuid")) |value| {
                hub.uuid = dupeString(allocator, value);
            }
            if (findValue(pairs, "color_wheel_index")) |value| {
                hub.color_wheel_index = asU32(value) orelse 0;
            }
        }
    }

    // Parse decoration definitions keyed by character code (same as levels;
    // custom stems are content-addressed - see DESIGN → Campaigns & the
    // Campaign Editor → File formats).
    var decoration_definitions = parseDecorationDefinitions(sections, file_source, allocator, warnings, file_path);
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
            exit_codes.append(allocator, code_string[0]) catch @panic("failed to append exit code");
            exit_definitions.put(code_string[0], .{
                .mission_uuid = findValue(pairs, "mission_uuid") orelse &.{},
                .position = .{ .x = 0, .y = 0 },
            }) catch @panic("failed to insert exit definition");
        }
    }

    // Collect NPC definitions: character_code + npc_type (the type is the
    // whole identity - the sprite derives from it; DESIGN → Campaigns &
    // the Campaign Editor → File formats). Missing/unknown type: warn +
    // drop the entry (the recoverable-problem convention).
    var npc_definitions = std.AutoHashMap(u8, types.NpcType).init(allocator);
    defer npc_definitions.deinit();
    // Codes whose NPC entry was warned + dropped (no/unknown npc_type).
    // The layout walk treats these as plain walkable tiles: the entry's
    // own warn+drop policy already fired, and erroring at the walk would
    // make the SAME defect fatal or not depending on whether the broken
    // NPC happens to be placed.
    var dropped_npc_codes: std.ArrayList(u8) = .empty;
    defer dropped_npc_codes.deinit(allocator);
    if (findSection(sections, "NPCs")) |section| {
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const code_string = findValue(pairs, "character_code") orelse continue;
            if (code_string.len != 1) continue;
            const type_value = findValue(pairs, "npc_type") orelse {
                appendWarning(warnings, allocator, "{s}: NPC entry '{c}' has no npc_type - dropped", .{ file_path, code_string[0] });
                dropped_npc_codes.append(allocator, code_string[0]) catch @panic("failed to append dropped NPC code");
                continue;
            };
            const npc_type = parseEnum(types.NpcType, type_value) orelse {
                appendWarning(warnings, allocator, "{s}: unknown npc_type '{s}' (NPC entry '{c}') - dropped", .{ file_path, type_value, code_string[0] });
                dropped_npc_codes.append(allocator, code_string[0]) catch @panic("failed to append dropped NPC code");
                continue;
            };
            npc_definitions.put(code_string[0], npc_type) catch @panic("failed to insert NPC definition");
        }
    }

    // Parse layout grid
    var tile_positions: std.ArrayList(types.Vector2) = .empty;
    var decoration_list: std.ArrayList(types.Decoration) = .empty;
    var npc_list: std.ArrayList(types.NPC) = .empty;
    var exit_list: std.ArrayList(types.MissionExit) = .empty;
    var player_start: ?types.Vector2 = null;

    // Partial-build cleanup on any error return (missing spawn, unknown
    // layout character) - same shape as loadLevel's errdefer: the
    // lists own everything until the tail moves it into `hub`.
    errdefer {
        for (decoration_list.items) |decoration| freeDecoration(decoration, allocator);
        decoration_list.deinit(allocator);
        for (exit_list.items) |exit| {
            allocator.free(exit.mission_uuid);
        }
        exit_list.deinit(allocator);
        npc_list.deinit(allocator);
        tile_positions.deinit(allocator);
        freeHub(hub, allocator);
    }

    if (findSection(sections, "Layout")) |section| {
        // A current-version file must use the counted grammar - see the
        // loadLevel site.
        if (file_version == hub_file_format_version and section.layout_row_count == null) {
            return error.UncountedLayout;
        }
        for (section.raw_lines, 0..) |row, raw_y| {
            const y: i32 = @intCast(raw_y);
            for (row, 0..) |character, raw_x| {
                const x: i32 = @intCast(raw_x);
                const position = types.Vector2{ .x = x, .y = y };

                switch (character) {
                    ' ' => {},
                    '.' => tile_positions.append(allocator, position) catch @panic("failed to append tile position"),
                    '!' => {
                        hub.player.position = position;
                        player_start = position;
                        hub.player.name = dupeString(allocator, "Player");
                        hub.player.sprite = dupeString(allocator, "player");
                        tile_positions.append(allocator, position) catch @panic("failed to append tile position");
                    },
                    else => {
                        if (decoration_definitions.get(character)) |deco_def| {
                            var decoration: types.Decoration = .{
                                .name = deco_def.sprite,
                                .position = position,
                                .footprint = deco_def.footprint,
                                .pixel_dims = deco_def.pixel_dims,
                                .color_index = deco_def.color_index,
                                .keep_original_colors = deco_def.keep_original_colors,
                                .layers = deco_def.layers,
                            };
                            cloneDecorationOwned(&decoration, allocator);
                            decoration_list.append(allocator, decoration) catch @panic("failed to append decoration");
                        } else if (exit_definitions.getPtr(character)) |exit| {
                            // An exit's tile is walkable.
                            tile_positions.append(allocator, position) catch @panic("failed to append tile position");
                            exit.position = position;
                            var exit_copy = exit.*;
                            exit_copy.mission_uuid = dupeString(allocator, exit_copy.mission_uuid);
                            exit_list.append(allocator, exit_copy) catch @panic("failed to append mission exit");
                        } else if (npc_definitions.get(character)) |npc_type| {
                            // An NPC's tile is walkable.
                            tile_positions.append(allocator, position) catch @panic("failed to append tile position");
                            npc_list.append(allocator, .{ .npc_type = npc_type, .position = position }) catch @panic("failed to append NPC");
                        } else if (containsCharacter(dropped_npc_codes.items, character)) {
                            // A code whose NPC entry was warned + dropped:
                            // the tile stays walkable, the defect stays
                            // non-fatal (see the dropped_npc_codes decl).
                            tile_positions.append(allocator, position) catch @panic("failed to append tile position");
                        } else {
                            // Declared nowhere in THIS file - not a
                            // decoration, exit, or NPC code, not a special.
                            // A typo'd character_code, not a walkable tile
                            // (the old silent fallback made it one).
                            return error.UnknownLayoutCharacter;
                        }
                    },
                }
            }
        }
    }

    // The '!' player spawn is mandatory in both Layout-bearing formats -
    // hub.player's position and the spawn-relative origin come from it.
    const spawn = player_start orelse return error.MissingPlayerSpawn;

    // Spawn-relative coordinates - the same normalization as loadLevel
    // ('!' → origin): session-log/crash replay reconstructs through hubs
    // against current files, so hub positions must be bbox-growth-invariant
    // too. See the loadLevel site + DESIGN → Logging & Replay →
    // Spawn-relative coordinates.
    {
        const offset = types.Vector2{ .x = -spawn.x, .y = -spawn.y };
        for (tile_positions.items) |*tile| {
            tile.* = .{ .x = tile.x + offset.x, .y = tile.y + offset.y };
        }
        for (decoration_list.items) |*decoration| {
            decoration.position = .{ .x = decoration.position.x + offset.x, .y = decoration.position.y + offset.y };
        }
        for (npc_list.items) |*npc| {
            npc.position = .{ .x = npc.position.x + offset.x, .y = npc.position.y + offset.y };
        }
        for (exit_list.items) |*exit| {
            exit.position = .{ .x = exit.position.x + offset.x, .y = exit.position.y + offset.y };
        }
        hub.player.position = .{ .x = hub.player.position.x + offset.x, .y = hub.player.position.y + offset.y };
    }

    // Clamp decoration footprints (same as levels - see DESIGN →
    // Decorations & Footprint).
    var tile_set = std.AutoHashMap(types.Vector2, void).init(allocator);
    defer tile_set.deinit();
    for (tile_positions.items) |tile| {
        tile_set.put(tile, {}) catch @panic("failed to insert tile into set");
    }
    for (decoration_list.items) |*decoration| {
        clampDecorationFootprint(decoration, &tile_set, allocator, warnings, file_path);
    }

    hub.hub_tiles = tile_positions.toOwnedSlice(allocator) catch @panic("failed to own hub tiles slice");
    hub.decorations = decoration_list.toOwnedSlice(allocator) catch @panic("failed to own hub decorations slice");
    hub.npcs = npc_list.toOwnedSlice(allocator) catch @panic("failed to own hub NPCs slice");
    hub.mission_exits = exit_list.toOwnedSlice(allocator) catch @panic("failed to own hub mission exits slice");

    return hub;
}

/// Load a campaign from parsed sections. Self-owned: `name`, `start_hub`,
/// `campaign_uuid`, and every hub uuid + dir are duped into `allocator`,
/// so the result does not borrow from the parse bytes - free with
/// `freeCampaign` (tests) or the arena (production). `background` is a
/// bare stem in the file naming a PNG in the campaign's own directory; it
/// is minted here into the content-addressed sprite id
/// (customStemForContentPath + `campaign_content_path`) so the render side
/// resolves it through the standard custom-asset rule.
/// `campaign_content_path` is the campaign dir the load resolved,
/// content-root-relative (e.g. `campaigns/main_campaign`; a leading
/// `data/` is also accepted and stripped by the mint); its basename lands
/// on `Campaign.dir`. Hubs entries: `hub_uuid` is the identity (missing →
/// silent skip); position is the payload (missing/unparsable → warn +
/// drop, the NPC-entry convention).
pub fn loadCampaign(
    sections: []const Section,
    campaign_content_path: []const u8,
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
) !Campaign {
    _ = try validateFileFormatVersion(
        sections,
        "Metadata",
        parser.oldest_supported_campaign_file_format_version,
        campaign_file_format_version,
    );
    var campaign: Campaign = .{};
    campaign.dir = dupeString(allocator, std.fs.path.basename(campaign_content_path));

    if (findSection(sections, "Metadata")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "name")) |value| campaign.name = dupeString(allocator, value);
            if (findValue(pairs, "campaign_uuid")) |value| campaign.uuid = dupeString(allocator, value);
            if (findValue(pairs, "start_hub")) |value| campaign.start_hub = dupeString(allocator, value);
            if (findValue(pairs, "background")) |value| {
                if (value.len > 0) {
                    campaign.background = file_source_mod.customStemForContentPath(
                        campaign_content_path,
                        value,
                        allocator,
                    );
                }
            }
        }
    }

    if (findSection(sections, "Hubs")) |section| {
        var hub_list: std.ArrayList(types.CampaignHub) = .empty;
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            const hub_uuid = findValue(pairs, "hub_uuid") orelse continue;
            const position_value = findValue(pairs, "position") orelse {
                appendWarning(warnings, allocator, "Hubs entry '{s}' has no position - dropped", .{hub_uuid});
                continue;
            };
            const position = parseVector2Pair(position_value) orelse {
                appendWarning(warnings, allocator, "Hubs entry '{s}' has an unparsable position '{s}' - dropped", .{ hub_uuid, position_value });
                continue;
            };
            // The hub's storage dir is resolved by the loading scan
            // (readHubUuidTable); the campaign table itself only carries
            // identity + position. A hub whose hub.txt cannot be found
            // keeps the empty dir here - the integrity checks flag it.
            hub_list.append(allocator, .{
                .uuid = dupeString(allocator, hub_uuid),
                .dir = &.{},
                .position = position,
            }) catch @panic("failed to append campaign hub");
        }
        campaign.hubs = hub_list.toOwnedSlice(allocator) catch @panic("failed to own campaign hubs slice");
    }

    return campaign;
}

/// Free a campaign's owned strings + hub list. The empty defaults are the
/// static empty slice, whose free is a no-op, so this is safe on a
/// campaign loaded without name/start_hub/background/hubs.
pub fn freeCampaign(campaign: types.Campaign, allocator: std.mem.Allocator) void {
    allocator.free(campaign.name);
    allocator.free(campaign.uuid);
    allocator.free(campaign.dir);
    allocator.free(campaign.start_hub);
    allocator.free(campaign.background);
    for (campaign.hubs) |hub| {
        allocator.free(hub.uuid);
        if (hub.dir.len > 0) allocator.free(hub.dir);
        if (hub.name.len > 0) allocator.free(hub.name);
    }
    allocator.free(campaign.hubs);
    for (campaign.edges) |edge| {
        allocator.free(edge.from);
        if (edge.destination.len > 0) allocator.free(edge.destination);
        allocator.free(edge.mission_uuid);
        if (edge.mission_dir.len > 0) allocator.free(edge.mission_dir);
        if (edge.mission_name.len > 0) allocator.free(edge.mission_name);
    }
    allocator.free(campaign.edges);
    for (campaign.missions) |mission| {
        allocator.free(mission.uuid);
        allocator.free(mission.dir);
        if (mission.name.len > 0) allocator.free(mission.name);
    }
    allocator.free(campaign.missions);
}

/// Derive the campaign's EDGE TABLE (`Campaign.edges`) + hub display names
/// (`CampaignHub.name`): the authored edge rows come from campaign.txt's
/// Missions section (`campaign_sections` - the first-class edge table,
/// one group per mission; orphans - no start_hub - are not gameplay and
/// stay out of the runtime table), and ONE walk over the placed hubs'
/// hub.txt captures each hub's Metadata name (denormalized for map labels
/// + warnings - the mission-table precedent) + its exit MARKERS for the
/// startability join (`exit_index`; null = a MARKERLESS edge - rendered,
/// not enterable). The effective direction is the authored value, else
/// the auto-spread default (the unauthored edges from the same start hub
/// share the full circle among themselves - see DESIGN → Campaigns & the
/// Campaign Editor → Edge geometry); an unparsable direction warns +
/// falls back to the default. A Missions entry whose start_hub names no
/// placed hub warns + drops the edge (hand-edit). Read/parse failures
/// warn + skip the hub's markers (the edges stay, markerless - the texts
/// the integrity checks used to emit; an unresolved hub dir is already
/// warned by resolveCampaignHubs). The LOADING side only - the table
/// rides GameState as the graph the map view renders and map-acting
/// legality reads (replay never scans; see DESIGN → The map surface).
/// Self-owned: every string is duped into `allocator`; freed by
/// `freeCampaign`.
pub fn deriveCampaignEdges(
    campaign: *types.Campaign,
    campaign_file_sections: []const Section,
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
) void {
    var edges: std.ArrayList(types.CampaignEdgeEntry) = .empty;
    var new_hubs: std.ArrayList(types.CampaignHub) = .empty;

    // The authored edge rows (borrowed from `campaign_sections` - the
    // caller's parse outlives this call; the emitted edges dupe
    // everything they keep). An unparsable direction already warned in
    // the collection loop below; here it is simply unauthored (a spread
    // slot).
    const MissionRow = struct {
        mission_uuid: []const u8,
        start_hub: []const u8,
        destination: []const u8,
        direction: ?i32,
    };
    var rows: std.ArrayList(MissionRow) = .empty;
    defer rows.deinit(allocator);
    if (findSection(campaign_file_sections, "Missions")) |missions_section| {
        for (missions_section.entry_groups) |group| {
            const pairs = group.pairs;
            const mission_uuid = findValue(pairs, "mission_uuid") orelse {
                appendWarning(warnings, allocator, "a Missions entry has no mission_uuid - dropped", .{});
                continue;
            };
            if (mission_uuid.len == 0) {
                appendWarning(warnings, allocator, "a Missions entry has an empty mission_uuid - dropped", .{});
                continue;
            }
            // No start_hub = an orphan: editor-honest intermediate state,
            // a validation finding (a finalized campaign wires every
            // mission) - never silently carried.
            const start_hub = findValue(pairs, "start_hub") orelse {
                appendWarning(warnings, allocator, "mission '{s}' has no start hub - it is not wired into the graph (an orphan)", .{mission_uuid});
                continue;
            };
            if (start_hub.len == 0) {
                appendWarning(warnings, allocator, "mission '{s}' has no start hub - it is not wired into the graph (an orphan)", .{mission_uuid});
                continue;
            }
            var direction: ?i32 = null;
            if (findValue(pairs, "direction")) |value| {
                if (asI32(value)) |authored| {
                    direction = authored;
                } else {
                    appendWarning(warnings, allocator, "mission '{s}' has an unparsable direction '{s}' - using the auto-spread default", .{ mission_uuid, value });
                }
            }
            rows.append(allocator, .{
                .mission_uuid = mission_uuid,
                .start_hub = start_hub,
                .destination = findValue(pairs, "destination_hub") orelse &.{},
                .direction = direction,
            }) catch @panic("failed to append campaign mission row");
        }
    }

    for (campaign.hubs) |hub| {
        // The rebuilt entry: the same uuid/dir/position, plus the name
        // this walk fills (the resolveCampaignHubs rebuild pattern -
        // Campaign.hubs is a const slice, so in-place writes are not
        // possible).
        var new_hub = types.CampaignHub{
            .uuid = dupeString(allocator, hub.uuid),
            .dir = if (hub.dir.len > 0) dupeString(allocator, hub.dir) else &.{},
            .position = hub.position,
        };
        // The hub's exit markers, collected inside the read below and
        // carried out as OWNED strings (the parsed sections die with the
        // read block).
        var marker_uuids: std.ArrayList([]const u8) = .empty;
        defer {
            for (marker_uuids.items) |marker_uuid| allocator.free(marker_uuid);
            marker_uuids.deinit(allocator);
        }
        read_hub: {
            if (hub.dir.len == 0) break :read_hub;
            const hub_file_path = std.fmt.allocPrint(
                allocator,
                "campaigns/{s}/hubs/{s}/hub.txt",
                .{ campaign.dir, hub.dir },
            ) catch @panic("failed to build hub file path");
            defer allocator.free(hub_file_path);

            const bytes = file_source.readFile(allocator, hub_file_path) catch {
                appendWarning(warnings, allocator, "placed hub '{s}' has no readable hub.txt ({s})", .{ hub.uuid, hub_file_path });
                break :read_hub;
            };
            defer allocator.free(bytes);

            const parsed_hub_sections = parseConfigFile(bytes, allocator, &hub_sections) catch {
                appendWarning(warnings, allocator, "placed hub '{s}' has an unparsable hub.txt", .{hub.uuid});
                break :read_hub;
            };
            defer freeParsedSections(parsed_hub_sections, allocator);

            if (findSection(parsed_hub_sections, "Metadata")) |section| {
                if (section.entry_groups.len > 0) {
                    if (findValue(section.entry_groups[0].pairs, "name")) |name| {
                        if (name.len > 0) new_hub.name = dupeString(allocator, name);
                    }
                }
            }

            // The hub's exit MARKERS, in Exits order (the startability
            // join - pure tile materialization; the edge data is the
            // Missions section's). A duplicate marker for one mission is
            // a hand-edit: the first is used + warned (the structural
            // one-edge rule - one mission, one marker).
            if (findSection(parsed_hub_sections, "Exits")) |exits_section| {
                for (exits_section.entry_groups) |group| {
                    const mission_uuid = findValue(group.pairs, "mission_uuid") orelse continue;
                    var duplicate = false;
                    for (marker_uuids.items) |existing| {
                        if (std.mem.eql(u8, existing, mission_uuid)) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) {
                        appendWarning(warnings, allocator, "hub '{s}' has multiple markers for mission '{s}' - the first is used", .{ hub.uuid, mission_uuid });
                        continue;
                    }
                    marker_uuids.append(allocator, allocator.dupe(u8, mission_uuid) catch
                        @panic("failed to dupe exit marker uuid")) catch
                        @panic("failed to append exit marker uuid");
                }
            }
        }
        // The rows starting here - OUTSIDE the read: the edge data is the
        // Missions section's, independent of the hub file's readability
        // (an unreadable hub.txt yields MARKERLESS edges, not lost ones).
        // The auto-spread: unauthored edges from THIS start hub share the
        // full circle among THEMSELVES (authored ones sit where placed) -
        // the campaign editor's rendering rule, one rule everywhere (see
        // DESIGN → Edge geometry).
        var unauthored_count: i32 = 0;
        for (rows.items) |row| {
            if (!std.mem.eql(u8, row.start_hub, hub.uuid)) continue;
            if (row.direction == null) unauthored_count += 1;
        }
        var unauthored_index: i32 = 0;
        for (rows.items) |row| {
            if (!std.mem.eql(u8, row.start_hub, hub.uuid)) continue;

            var direction_degrees: i32 = 0;
            if (row.direction) |authored| {
                direction_degrees = authored;
            } else {
                direction_degrees = if (unauthored_count > 0)
                    @divTrunc(360 * unauthored_index, unauthored_count)
                else
                    0;
                unauthored_index += 1;
            }

            // The marker join: the row's index among this hub's markers,
            // or null for a MARKERLESS edge (rendered, not enterable -
            // DESIGN → The map surface).
            var exit_index: ?u32 = null;
            for (marker_uuids.items, 0..) |marker_uuid, marker_index| {
                if (std.mem.eql(u8, marker_uuid, row.mission_uuid)) {
                    exit_index = @intCast(marker_index);
                    break;
                }
            }

            var mission_dir: []const u8 = &.{};
            var mission_name: []const u8 = &.{};
            for (campaign.missions) |mission| {
                if (!std.mem.eql(u8, mission.uuid, row.mission_uuid)) continue;
                mission_dir = mission.dir;
                mission_name = mission.name;
                break;
            }

            edges.append(allocator, .{
                .from = dupeString(allocator, hub.uuid),
                .destination = if (row.destination.len > 0) dupeString(allocator, row.destination) else &.{},
                .mission_uuid = dupeString(allocator, row.mission_uuid),
                .mission_dir = if (mission_dir.len > 0) dupeString(allocator, mission_dir) else &.{},
                .mission_name = if (mission_name.len > 0) dupeString(allocator, mission_name) else &.{},
                .direction_degrees = direction_degrees,
                .exit_index = exit_index,
            }) catch @panic("failed to append campaign edge entry");
        }
        new_hubs.append(allocator, new_hub) catch @panic("failed to append rebuilt campaign hub");
    }

    // Rows whose start hub is not placed (hand-edit): warn + drop - the
    // same orphan class as a missing start_hub.
    for (rows.items) |row| {
        var placed = false;
        for (campaign.hubs) |hub| {
            if (std.mem.eql(u8, hub.uuid, row.start_hub)) {
                placed = true;
                break;
            }
        }
        if (!placed) {
            appendWarning(warnings, allocator, "mission '{s}' start_hub '{s}' names an unplaced hub - it is not wired into the graph (an orphan)", .{ row.mission_uuid, row.start_hub });
        }
    }

    // Swap in the rebuilt hubs (freeing the resolveCampaignHubs-owned
    // originals - the same ownership handoff resolveCampaignHubs itself
    // performs).
    for (campaign.hubs) |hub| {
        allocator.free(hub.uuid);
        if (hub.dir.len > 0) allocator.free(hub.dir);
        if (hub.name.len > 0) allocator.free(hub.name);
    }
    if (campaign.hubs.len > 0) allocator.free(campaign.hubs);
    campaign.hubs = new_hubs.toOwnedSlice(allocator) catch @panic("failed to own rebuilt campaign hubs slice");

    if (campaign.edges.len > 0) {
        for (campaign.edges) |edge| {
            allocator.free(edge.from);
            if (edge.destination.len > 0) allocator.free(edge.destination);
            allocator.free(edge.mission_uuid);
            if (edge.mission_dir.len > 0) allocator.free(edge.mission_dir);
            if (edge.mission_name.len > 0) allocator.free(edge.mission_name);
        }
        allocator.free(campaign.edges);
    }
    campaign.edges = edges.toOwnedSlice(allocator) catch @panic("failed to own campaign edges slice");
}

/// Resolve every placed hub's storage dir (uuid -> dir) into
/// `campaign.hubs[i].dir` in place - the scan side of the loading
/// contract (DESIGN → Campaigns & the Campaign Editor → Uuid→dir
/// resolution). Called by the LOADING side (live play; the result is
/// state), never by a replayed handler - replay derives paths from the
/// loaded state. Duplicate uuids across candidate dirs resolve
/// latest-mtime-wins + a warning naming the winner.
pub fn resolveCampaignHubs(
    campaign: *types.Campaign,
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
) void {
    const hubs_dir = std.fmt.allocPrint(allocator, "campaigns/{s}/hubs", .{campaign.dir}) catch
        @panic("failed to build hubs dir path");
    defer allocator.free(hubs_dir);
    var resolved_hubs: std.ArrayList(types.CampaignHub) = .empty;
    for (campaign.hubs) |hub| {
        const embedded_dirs = embeddedHubDirs(campaign.dir, allocator);
        defer allocator.free(embedded_dirs);
        const resolved = file_source_mod.resolveUuidDir(
            file_source,
            allocator,
            hubs_dir,
            embedded_dirs,
            "hub.txt",
            &hub_sections,
            "hub_uuid",
            hub.uuid,
        ) orelse {
            appendWarning(warnings, allocator, "hub '{s}' has no resolvable directory (no hubs/<dir>/hub.txt carries its uuid)", .{hub.uuid});
            // The unresolved hub rides along with its uuid duped (the
            // original strings are freed below - the rebuild owns
            // everything it keeps).
            resolved_hubs.append(allocator, .{
                .uuid = dupeString(allocator, hub.uuid),
                .dir = &.{},
                .position = hub.position,
            }) catch @panic("failed to append unresolved campaign hub");
            continue;
        };
        defer allocator.free(resolved.dir);
        if (resolved.duplicate) {
            appendWarning(warnings, allocator, "duplicate hub uuid '{s}': resolved to {s} (latest-updated wins; delete one of the copies to split them)", .{ hub.uuid, resolved.dir });
        }
        resolved_hubs.append(allocator, .{
            .uuid = dupeString(allocator, hub.uuid),
            .dir = dupeString(allocator, std.fs.path.basename(resolved.dir)),
            .position = hub.position,
        }) catch @panic("failed to append resolved campaign hub");
    }
    // The empty default (no hubs section) is the static empty slice - its
    // free is a no-op, but the per-hub uuids are heap-owned either way.
    for (campaign.hubs) |hub| allocator.free(hub.uuid);
    if (campaign.hubs.len > 0) allocator.free(campaign.hubs);
    campaign.hubs = resolved_hubs.toOwnedSlice(allocator) catch @panic("failed to own resolved campaign hubs slice");
}

/// The embedded campaign's hub dirs (content-root-relative), for the
/// embedded tier of hub uuid resolution. Caller-owned.
fn embeddedHubDirs(campaign_dir: []const u8, allocator: std.mem.Allocator) []const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    const prefix = std.fmt.allocPrint(allocator, "data/campaigns/{s}/hubs/", .{campaign_dir}) catch
        @panic("failed to build embedded hubs prefix");
    defer allocator.free(prefix);
    // The keys slice is owned (the elements are static map keys - never
    // freed); only the outer slice is heap-owned.
    const keys = file_source_mod.embeddedMapKeys(allocator);
    defer allocator.free(keys);
    for (keys) |key| {
        if (!std.mem.startsWith(u8, key, prefix)) continue;
        if (!std.mem.endsWith(u8, key, "/hub.txt")) continue;
        const hub_dir = key["data/".len .. key.len - "/hub.txt".len];
        dirs.append(allocator, hub_dir) catch @panic("failed to append embedded hub dir");
    }
    return dirs.toOwnedSlice(allocator) catch @panic("failed to own embedded hub dirs");
}

/// Resolve the campaign background's pixel dims into
/// `Campaign.background_dims` (the map view draws it at native size,
/// centered on the origin). No background, no resolution; a background
/// whose file cannot be read warns + leaves the dims null (the map skips
/// the draw - untrusted content degrades, never crashes). The LOADING
/// side only.
pub fn resolveCampaignBackgroundDims(
    campaign: *types.Campaign,
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
) void {
    if (campaign.background.len == 0) return;
    const dims = resolveCustomSpriteFileDims(campaign.background, file_source, allocator) orelse {
        appendWarning(warnings, allocator, "campaign '{s}' background '{s}' is not a readable PNG - the world map renders without it", .{ campaign.dir, campaign.background });
        return;
    };
    campaign.background_dims = dims;
}

/// Build the campaign's mission table (scan every mission dir in the
/// campaign's `missions/` - persistent + embedded - read each
/// mission.txt's uuid + name). A uuid resolved in the persistent tier
/// SHADOWS its embedded namesake (unreachable through the read order -
/// the normal state after a save materializes a persistent copy; see
/// DESIGN → Campaigns & the Campaign Editor → Uuid→dir resolution),
/// so cross-tier repeats are silent; duplicates warn only SAME-TIER
/// (two persistent dirs - a hand fork; two embedded dirs - a shipped
/// collision), resolving latest-mtime-wins. Returns a caller-owned
/// table, empty when the campaign has no missions dir. The LOADING side
/// only - replay reads the table from state.
pub fn resolveCampaignMissions(
    campaign: types.Campaign,
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
) []const types.CampaignMissionEntry {
    var entries: std.ArrayList(types.CampaignMissionEntry) = .empty;
    const missions_dir = std.fmt.allocPrint(allocator, "campaigns/{s}/missions", .{campaign.dir}) catch
        @panic("failed to build missions dir path");
    defer allocator.free(missions_dir);

    // The candidate dirs: the persistent scan + the embedded campaign's
    // mission dirs (tier flag; mtime only orders within a tier). One
    // pass, then dedupe by uuid with the shadow rule.
    const Candidate = struct {
        dir: []const u8,
        mtime_ns: i128,
        persistent: bool,
    };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |candidate| allocator.free(candidate.dir);
        candidates.deinit(allocator);
    }

    if (file_source.persistent_dir.openDir(file_source.io, missions_dir, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch null) |persistent_dir| {
        defer std.Io.Dir.close(persistent_dir, file_source.io);
        var it = persistent_dir.iterate();
        while (it.next(file_source.io) catch null) |dir_entry| {
            if (dir_entry.kind != .directory) continue;
            const dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ missions_dir, dir_entry.name }) catch
                @panic("failed to build mission dir");
            candidates.append(allocator, .{
                .dir = dir,
                .mtime_ns = file_source_mod.dirMtime(file_source, dir),
                .persistent = true,
            }) catch @panic("failed to append mission candidate");
        }
    }

    const embedded_mission_dirs = file_source_mod.officialMissionDirPathsForCampaign(missions_dir, allocator);
    defer allocator.free(embedded_mission_dirs);
    for (embedded_mission_dirs) |embedded_dir| {
        defer allocator.free(embedded_dir);
        candidates.append(allocator, .{
            .dir = allocator.dupe(u8, embedded_dir) catch @panic("failed to dupe embedded mission dir"),
            .mtime_ns = 0,
            .persistent = false,
        }) catch @panic("failed to append mission candidate");
    }

    // Persistent tier first (so a persistent candidate always claims a
    // uuid before its embedded shadow - mtime alone can't guarantee that
    // when a persistent dir stamps 0), then mtime descending within a
    // tier (latest-updated wins), then name ascending (copied folders
    // carry identical mtimes - deterministic under all inputs).
    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn before(_: void, a: Candidate, b: Candidate) bool {
            if (a.persistent != b.persistent) return a.persistent;
            if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
            return std.mem.lessThan(u8, a.dir, b.dir);
        }
    }.before);
    const ClaimTier = enum { persistent, embedded };
    var seen_uuids = std.StringHashMap(ClaimTier).init(allocator);
    // The map owns duped keys - mission_uuid borrows the per-candidate
    // probe arena, which dies at each iteration's end; a borrowed key
    // is a dangling pointer the next get() would compare against.
    defer {
        var key_it = seen_uuids.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        seen_uuids.deinit();
    }
    for (candidates.items) |candidate| {
        var probe_arena = std.heap.ArenaAllocator.init(allocator);
        defer probe_arena.deinit();
        const config_path = std.fmt.allocPrint(probe_arena.allocator(), "{s}/mission.txt", .{candidate.dir}) catch
            @panic("failed to build mission config path");
        const bytes = file_source.readFile(probe_arena.allocator(), config_path) catch continue;
        const parsed = parseConfigFile(bytes, probe_arena.allocator(), &mission_sections) catch continue;
        const metadata = findSection(parsed, "Metadata") orelse continue;
        if (metadata.entry_groups.len == 0) continue;
        const pairs = metadata.entry_groups[0].pairs;
        const mission_uuid = findValue(pairs, "mission_uuid") orelse continue;
        if (seen_uuids.get(mission_uuid)) |claim_tier| {
            // A persistent claim shadowing an embedded candidate is the
            // normal save outcome - silent. Same-tier repeats are the
            // genuine forks; the sort guarantees a persistent candidate
            // never arrives after an embedded claim of its uuid.
            if (claim_tier == .persistent and !candidate.persistent) continue;
            appendWarning(warnings, allocator, "duplicate mission uuid '{s}': {s} shadows an earlier copy - latest-updated wins; delete one of the copies to split them", .{ mission_uuid, candidate.dir });
            continue;
        }
        const owned_uuid = dupeString(allocator, mission_uuid);
        seen_uuids.put(owned_uuid, if (candidate.persistent) ClaimTier.persistent else ClaimTier.embedded) catch @panic("failed to insert seen mission uuid");
        const name = findValue(pairs, "name") orelse "";
        entries.append(allocator, .{
            .uuid = dupeString(allocator, mission_uuid),
            .dir = dupeString(allocator, candidate.dir),
            .name = dupeString(allocator, name),
        }) catch @panic("failed to append campaign mission entry");
    }
    return entries.toOwnedSlice(allocator) catch @panic("failed to own campaign missions slice");
}

/// Load-time campaign graph INTEGRITY checks (warn-only, the loader
/// convention), shared by the in-game campaign load and the campaign
/// editor's Validate (the file-level certification - the same read
/// pipeline, the same findings). A finalized campaign wires every
/// mission fully: stubs, orphans, and markerless missions are
/// editor-intermediate state, findings here - a hand-edited or
/// third-party campaign must not carry one silently. PURE over the
/// derived edge table (see deriveCampaignEdges) - no file reads, so the
/// check adds nothing the derive did not already read (and replay purity
/// is unaffected by construction: the derive runs loading-side only).
/// Checks, each appending a warning:
///   - the start hub is placed (a start_hub naming no Hubs entry, or none
///     at all)
///   - every edge has a destination hub (the dangling stub) and it names
///     a placed hub (the dangling forward reference)
///   - every edge has an exit marker in its start hub (unstartable -
///     rendered, not enterable; see `CampaignEdgeEntry.exit_index`)
///   - no edge names a mission that resolves to nothing in the campaign's
///     mission table
///   - every placed hub is reachable from the start hub over hub → edge →
///     destination edges (an empty destination does not traverse - it is
///     the dangling case above)
pub fn checkCampaignGraph(
    campaign: types.Campaign,
    allocator: std.mem.Allocator,
    warnings: ?*std.ArrayList([]const u8),
) void {
    if (warnings == null) return;

    const hub_placed = struct {
        fn check(hubs: []const types.CampaignHub, uuid: []const u8) bool {
            for (hubs) |hub| {
                if (std.mem.eql(u8, hub.uuid, uuid)) return true;
            }
            return false;
        }
    }.check;

    // Start hub placed?
    if (campaign.start_hub.len == 0) {
        appendWarning(warnings, allocator, "campaign has no start_hub", .{});
    } else if (!hub_placed(campaign.hubs, campaign.start_hub)) {
        appendWarning(warnings, allocator, "start hub '{s}' is not placed in the Hubs section", .{campaign.start_hub});
    }

    // reachable_set doubles as the BFS frontier bookkeeping below.
    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();

    // Dangling destinations + unresolvable missions, over the derived
    // table (read/parse failures were already warned by the derive).
    for (campaign.edges) |edge| {
        if (edge.destination.len == 0) {
            appendWarning(warnings, allocator, "mission '{s}' from hub '{s}': no destination hub set (a dangling stub - a finalized campaign wires every mission's end)", .{ edge.mission_uuid, edge.from });
        } else if (!hub_placed(campaign.hubs, edge.destination)) {
            appendWarning(warnings, allocator, "mission '{s}' from hub '{s}': destination_hub '{s}' names an unplaced hub", .{ edge.mission_uuid, edge.from, edge.destination });
        }
        if (edge.mission_dir.len == 0) {
            appendWarning(warnings, allocator, "mission '{s}' from hub '{s}' resolves to no mission in the campaign's missions/", .{ edge.mission_uuid, edge.from });
        }
        if (edge.exit_index == null) {
            appendWarning(warnings, allocator, "mission '{s}' from hub '{s}': unstartable - no exit marker in the start hub (the mission renders but cannot be entered)", .{ edge.mission_uuid, edge.from });
        }
    }

    // Reachability: BFS from the start hub over destination edges.
    if (campaign.start_hub.len > 0 and hub_placed(campaign.hubs, campaign.start_hub)) {
        var frontier: std.ArrayList([]const u8) = .empty;
        defer frontier.deinit(allocator);
        reachable.put(campaign.start_hub, {}) catch @panic("failed to insert start hub");
        frontier.append(allocator, campaign.start_hub) catch @panic("failed to enqueue start hub");
        while (frontier.pop()) |current| {
            for (campaign.edges) |edge| {
                if (!std.mem.eql(u8, edge.from, current)) continue;
                if (edge.destination.len == 0) continue;
                if (reachable.contains(edge.destination)) continue;
                reachable.put(edge.destination, {}) catch @panic("failed to insert reachable hub");
                frontier.append(allocator, edge.destination) catch @panic("failed to enqueue hub");
            }
        }
        for (campaign.hubs) |hub| {
            if (!reachable.contains(hub.uuid)) {
                appendWarning(warnings, allocator, "hub '{s}' is unreachable from the start hub (no mission path leads there)", .{hub.uuid});
            }
        }
    }
}

/// Load a mission's metadata (uuid + name - the hub endpoints are the
/// campaign graph's, the level count is the dir's; both derived elsewhere).
/// Self-owned: `uuid` + `name` are duped into `allocator`, so the result
/// does not borrow from the parse bytes - free with `freeMission` (tests)
/// or the arena (production).
pub fn loadMission(
    sections: []const Section,
    allocator: std.mem.Allocator,
) !Mission {
    _ = try validateFileFormatVersion(sections, "Metadata", mission_file_format_version, mission_file_format_version);
    var mission: Mission = .{};

    if (findSection(sections, "Metadata")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            const uuid = findValue(pairs, "mission_uuid") orelse return error.MissingMissionUuid;
            mission.uuid = dupeString(allocator, uuid);
            if (findValue(pairs, "name")) |value| mission.name = dupeString(allocator, value);
        }
    }

    return mission;
}

/// Free a mission's owned strings (uuid + name). The empty defaults are
/// the static empty slice, whose free is a no-op.
fn freeMission(mission: types.Mission, allocator: std.mem.Allocator) void {
    allocator.free(mission.uuid);
    allocator.free(mission.name);
}

/// Parse the shared LOADOUT sections (MainHandWeapon .. UtilitySkills,
/// including Inventory) into `player_data` - the sections a player save
/// and a mission player.txt have in common. Used by `loadPlayerSave`
/// (which adds Info / DiscoveredHubs / UnlockedSkills / CloneData) and
/// `loadPlayerLoadout` (which maps the result onto the player template).
fn parsePlayerLoadoutFields(
    sections: []const Section,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
    player_data: *PlayerData,
) !void {
    // MainHandWeapon
    if (findSection(sections, "MainHandWeapon")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.main_hand_weapon = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .weapon_type = parseEnum(types.WeaponType, findValue(pairs, "weapon_type") orelse "sword") orelse .sword,
                .weapon_damage = boundedU32(findValue(pairs, "damage") orelse "0", types.max_weapon_damage, "damage", file_path, warnings, allocator),
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
                .weapon_damage = boundedU32(findValue(pairs, "damage") orelse "0", types.max_weapon_damage, "damage", file_path, warnings, allocator),
            };
        }
    }

    // Amulet
    if (findSection(sections, "Amulet")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.amulet = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .spell_damage = boundedU32(findValue(pairs, "spell_damage") orelse "0", types.max_spell_damage, "spell_damage", file_path, warnings, allocator),
            };
        }
    }

    // Coat
    if (findSection(sections, "Coat")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.coat = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .defense_bonus = boundedU32(findValue(pairs, "armor") orelse "0", types.max_defense_bonus, "armor", file_path, warnings, allocator),
                .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
            };
        }
    }

    // Gloves
    if (findSection(sections, "Gloves")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.gloves = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .damage_bonus = boundedU32(findValue(pairs, "damage") orelse "0", types.max_gloves_damage, "damage", file_path, warnings, allocator),
                .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
            };
        }
    }

    // Pants
    if (findSection(sections, "Pants")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.pants = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .pickup_radius_bonus = boundedU32(findValue(pairs, "pickup_radius") orelse "0", types.max_pickup_radius, "pickup_radius", file_path, warnings, allocator),
                .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
            };
        }
    }

    // Boots
    if (findSection(sections, "Boots")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            player_data.boots = .{
                .name = findValue(pairs, "item_name") orelse &.{},
                .speed_bonus = boundedU32(findValue(pairs, "speed") orelse "0", types.max_boots_speed, "speed", file_path, warnings, allocator),
                .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
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

            // A skill tome must never carry a weapon skill (weapon skills
            // belong to the equipped weapon, and can never sit on the
            // utility bar a tome feeds) - warned + the item dropped.
            if (item_type_id == .skill_tome) {
                if (findValue(pairs, "skill_name")) |skill_name| {
                    if (parseEnum(types.SkillId, skill_name)) |skill_id| {
                        if (!utility_skills.isUtilitySkill(skill_id)) {
                            appendWarning(
                                warnings,
                                allocator,
                                "Weapon skill '{s}' in {s} cannot be a skill tome; item dropped",
                                .{ skill_name, file_path },
                            );
                            continue;
                        }
                    }
                }
            }

            const item: types.Item = switch (item_type_id) {
                .weapon => .{ .weapon = .{
                    .name = item_name,
                    .weapon_type = parseEnum(types.WeaponType, findValue(pairs, "weapon_type") orelse "sword") orelse .sword,
                    .weapon_damage = boundedU32(findValue(pairs, "damage") orelse "0", types.max_weapon_damage, "damage", file_path, warnings, allocator),
                } },
                .amulet => .{ .amulet = .{
                    .name = item_name,
                    .spell_damage = boundedU32(findValue(pairs, "spell_damage") orelse "0", types.max_spell_damage, "spell_damage", file_path, warnings, allocator),
                } },
                .coat => .{ .coat = .{
                    .name = item_name,
                    .defense_bonus = boundedU32(findValue(pairs, "armor") orelse "0", types.max_defense_bonus, "armor", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
                } },
                .gloves => .{ .gloves = .{
                    .name = item_name,
                    .damage_bonus = boundedU32(findValue(pairs, "damage") orelse "0", types.max_gloves_damage, "damage", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
                } },
                .pants => .{ .pants = .{
                    .name = item_name,
                    .pickup_radius_bonus = boundedU32(findValue(pairs, "pickup_radius") orelse "0", types.max_pickup_radius, "pickup_radius", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
                } },
                .boots => .{ .boots = .{
                    .name = item_name,
                    .speed_bonus = boundedU32(findValue(pairs, "speed") orelse "0", types.max_boots_speed, "speed", file_path, warnings, allocator),
                    .health_bonus = boundedU32(findValue(pairs, "health") orelse "0", types.max_health_bonus, "health", file_path, warnings, allocator),
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
                    if (!utility_skills.isUtilitySkill(skill_id)) {
                        appendWarning(
                            warnings,
                            allocator,
                            "Weapon skill '{s}' in {s} is not allowed on the utility bar (slot_{d}); dropped",
                            .{ pair.value, file_path, slot_number },
                        );
                        continue;
                    }
                    player_data.equipped_utility_skills[slot_index] = skill_id;
                }
            }
        }
    }
}

pub fn loadPlayerSave(
    sections: []const Section,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    warnings: ?*std.ArrayList([]const u8),
) !PlayerData {
    _ = try validateFileFormatVersion(sections, "Metadata", player_save_file_format_version, player_save_file_format_version);
    var player_data: PlayerData = .{};

    // Info
    if (findSection(sections, "Info")) |section| {
        if (section.entry_groups.len > 0) {
            const pairs = section.entry_groups[0].pairs;
            if (findValue(pairs, "player_name")) |value| player_data.player_name = value;
            if (findValue(pairs, "current_campaign")) |value| player_data.current_campaign = value;
            if (findValue(pairs, "current_campaign_uuid")) |value| player_data.current_campaign_uuid = value;
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
                    skills.append(allocator, skill_id) catch @panic("failed to append learned skill");
                }
            }
        }
        player_data.learned_skills = skills.toOwnedSlice(allocator) catch @panic("failed to own learned skills slice");
    }

    // DiscoveredHubs - one `name` per entry group (the writer's shape;
    // parsing it here closes a writer/reader asymmetry that silently
    // dropped discovery on every save/load round trip). The campaign_uuid
    // keys each group; consecutive entries WITHOUT a campaign_uuid belong
    // to the most recent one (the writer emits one group per campaign,
    // names following their campaign_uuid line).
    if (findSection(sections, "DiscoveredHubs")) |section| {
        var groups: std.ArrayList(types.DiscoveredCampaignHubs) = .empty;
        var group_hub_names: std.ArrayList(std.ArrayList([]const u8)) = .empty;
        for (section.entry_groups) |group| {
            if (findValue(group.pairs, "campaign_uuid")) |campaign_uuid| {
                group_hub_names.append(allocator, .empty) catch @panic("failed to append discovered group");
                groups.append(allocator, .{ .campaign_uuid = campaign_uuid }) catch @panic("failed to append discovered group");
            }
            if (findValue(group.pairs, "name")) |name| {
                if (group_hub_names.items.len == 0) {
                    // A name with no campaign_uuid seen yet: a legacy
                    // pre-grouping save - warn + skip (unrecoverable
                    // without the campaign key).
                    appendWarning(warnings, allocator, "DiscoveredHubs entry '{s}' has no campaign_uuid - dropped", .{name});
                    continue;
                }
                group_hub_names.items[group_hub_names.items.len - 1].append(allocator, name) catch @panic("failed to append discovered hub");
            }
        }
        // Wire the name lists into the groups (a second pass so the
        // ArrayList reallocations above can't dangle the inner slices).
        var owned_groups: std.ArrayList(types.DiscoveredCampaignHubs) = .empty;
        for (groups.items, group_hub_names.items) |*group, *names| {
            var rebuilt: types.DiscoveredCampaignHubs = group.*;
            rebuilt.hub_uuids = names.toOwnedSlice(allocator) catch @panic("failed to own discovered hubs slice");
            owned_groups.append(allocator, rebuilt) catch @panic("failed to append discovered group");
        }
        groups.deinit(allocator);
        for (group_hub_names.items) |*names| names.deinit(allocator);
        group_hub_names.deinit(allocator);
        player_data.discovered_hubs = owned_groups.toOwnedSlice(allocator) catch @panic("failed to own discovered groups slice");
    }

    try parsePlayerLoadoutFields(sections, allocator, file_path, warnings, &player_data);

    // CloneData
    if (findSection(sections, "CloneData")) |section| {
        var clones: std.ArrayList(types.Clone) = .empty;
        for (section.entry_groups) |group| {
            const pairs = group.pairs;
            clones.append(allocator, .{
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
            }) catch @panic("failed to append clone");
        }
        player_data.clones = clones.toOwnedSlice(allocator) catch @panic("failed to own clones slice");
    }

    return player_data;
}

pub fn loadWeaponTypeDefinition(
    sections: []const Section,
) !WeaponTypeDefinition {
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
    _ = try validateFileFormatVersion(sections, "Metadata", color_themes_file_format_version, color_themes_file_format_version);

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

    // Gradients - each entry group is one gradient, starting with gradient_index
    if (findSection(sections, "Gradients")) |section| {
        var gradient_list: std.ArrayList(ColorGradient) = .empty;
        // Partial-list cleanup on a gradient_index mismatch (earlier
        // gradients are already appended when the InvalidData fires) -
        // items are value types, so deinit alone frees everything. OOM
        // panics inline (the config-layer convention - DESIGN → Error
        // Handling) and skips errdefer.
        errdefer gradient_list.deinit(allocator);

        for (section.entry_groups) |group| {
            const pairs = group.pairs;

            // Verify gradient_index matches expected position
            const gradient_index = asU32(findValue(pairs, "gradient_index") orelse continue) orelse continue;
            if (gradient_index != gradient_list.items.len) return error.InvalidData;

            var gradient: ColorGradient = .{
                .colors = @splat(Color{ .r = 0, .g = 0, .b = 0 }),
            };

            inline for (0..types.gradient_color_count) |color_index| {
                const key = "color_" ++ comptime blk: {
                    break :blk &[1]u8{'0' + color_index};
                };
                if (findValue(pairs, key)) |value| {
                    gradient.colors[color_index] = asColor(value) orelse gradient.colors[color_index];
                }
            }

            gradient_list.append(allocator, gradient) catch @panic("failed to append color gradient");
        }

        theme.gradients = gradient_list.toOwnedSlice(allocator) catch @panic("failed to own color gradients slice");
    }

    return theme;
}

/// The auto-derivation rule's gradient index for a role (world = the
/// wheel index itself; enemy / player = evenly spaced at 1/3 and 2/3
/// around the wheel). Single source for `deriveActiveColorTheme` +
/// `effectiveGradientIndex` (the auto arm).
pub fn autoDerivedGradientIndex(
    color_theme_definitions: ColorThemeDefinitions,
    color_wheel_index: u32,
    role: types.LevelGradientRole,
) u32 {
    const gradient_count: u32 = @intCast(color_theme_definitions.gradients.len);
    if (gradient_count == 0) return 0;
    return switch (role) {
        .world => color_wheel_index % gradient_count,
        .enemy => (color_wheel_index + gradient_count / 3) % gradient_count,
        .player => (color_wheel_index + 2 * gradient_count / 3) % gradient_count,
    };
}

/// The level's EFFECTIVE gradient index for a role - the role's explicit
/// override while manual, the auto-derived one otherwise - normalized by
/// the same modulo `deriveActiveColorTheme` applies. Single source for the
/// editor UI's index displays (the metadata sidebar's swatch number + the
/// theme picker's current-row highlight) so both always agree with the
/// active theme's actual colors.
pub fn effectiveGradientIndex(
    color_theme_definitions: ColorThemeDefinitions,
    color_wheel_index: u32,
    enemy_gradient_override: ?u32,
    player_gradient_override: ?u32,
    role: types.LevelGradientRole,
) u32 {
    const gradient_count: u32 = @intCast(color_theme_definitions.gradients.len);
    if (gradient_count == 0) return 0;
    return switch (role) {
        .world => color_wheel_index % gradient_count,
        .enemy => if (enemy_gradient_override) |override|
            override % gradient_count
        else
            autoDerivedGradientIndex(color_theme_definitions, color_wheel_index, .enemy),
        .player => if (player_gradient_override) |override|
            override % gradient_count
        else
            autoDerivedGradientIndex(color_theme_definitions, color_wheel_index, .player),
    };
}

/// Derive the active color theme for a level or hub from the color wheel.
/// The world gradient is at the given index; enemy and player gradients
/// are evenly spaced around the wheel (at 1/3 and 2/3 offsets) unless an
/// optional override index names a specific gradient (the editor's
/// per-role manual picks - null = auto-derive). See DESIGN → Level Editor
/// → Level theme.
pub fn deriveActiveColorTheme(
    color_theme_definitions: ColorThemeDefinitions,
    color_wheel_index: u32,
    enemy_gradient_override: ?u32,
    player_gradient_override: ?u32,
) ActiveColorTheme {
    const gradient_count: u32 = @intCast(color_theme_definitions.gradients.len);
    if (gradient_count == 0) {
        return .{
            .lightest = color_theme_definitions.lightest,
            .darkest = color_theme_definitions.darkest,
            .world_gradient = .{ .colors = @splat(Color{ .r = 128, .g = 128, .b = 128 }) },
            .enemy_gradient = .{ .colors = @splat(Color{ .r = 128, .g = 128, .b = 128 }) },
            .player_gradient = .{ .colors = @splat(Color{ .r = 128, .g = 128, .b = 128 }) },
        };
    }

    const world_index = color_wheel_index % gradient_count;
    const enemy_index = if (enemy_gradient_override) |override| override % gradient_count else autoDerivedGradientIndex(color_theme_definitions, color_wheel_index, .enemy);
    const player_index = if (player_gradient_override) |override| override % gradient_count else autoDerivedGradientIndex(color_theme_definitions, color_wheel_index, .player);

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
        \\render_resolution 1440p
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
        \\context game
        \\
        \\input_type mouse_button
        \\input_name left
        \\ctrl true
        \\action confirm
        \\context game
    ;

    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    const settings = try loadSettings(sections, allocator, null, null);
    defer freeSettings(settings, allocator);

    // Audio values (u32 percentages 0-100)
    try std.testing.expectEqual(@as(u32, 80), settings.music_volume);
    try std.testing.expectEqual(@as(u32, 30), settings.sound_effects_volume);

    // Display values
    try std.testing.expectEqual(false, settings.vsync);
    try std.testing.expectEqual(@as(u32, 144), settings.render_fps_cap);
    try std.testing.expectEqual(@as(u32, 75), settings.camera_zoom);
    try std.testing.expectEqual(types.RenderResolution.p1440, settings.render_resolution);

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

    const sections = try parseConfigFile(raw_text, allocator, &weapon_type_sections);
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
        \\  1.2
        \\..!..
        \\  ..=
        \\
        \\Entities
        \\character_code 1
        \\name Skeleton
        \\max_health 10
        \\speed 2
        \\main_hand_weapon_name Bone Sword
        \\main_hand_weapon_type sword
        \\main_hand_weapon_damage 3
        \\
        \\character_code 2
        \\name Wolf
        \\sprite wolf
        \\team 2
        \\max_health 12
        \\
        \\Decorations
        \\
        \\Items
    ;

    const sections = try parseConfigFile(raw_text, allocator, &level_sections);
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
    try std.testing.expectEqual(3, level.entities.len);
    try std.testing.expectEqualStrings("Skeleton", level.entities[1].name);
    try std.testing.expectEqual(1, level.entities[1].team);
    try std.testing.expectEqual(10, level.entities[1].max_health);
    try std.testing.expectEqual(2, level.entities[1].speed);
    try std.testing.expectEqualStrings("Bone Sword", level.entities[1].main_hand_weapon.?.name);
    try std.testing.expectEqual(3, level.entities[1].main_hand_weapon.?.weapon_damage);

    // The team-2 enemy (an explicit `team` key overrides the load default)
    try std.testing.expectEqualStrings("Wolf", level.entities[2].name);
    try std.testing.expectEqual(2, level.entities[2].team);
    try std.testing.expectEqual(12, level.entities[2].max_health);

    // Tiles: all '.' and '!' and '=' positions, plus enemy positions
    // Layout (top row = y=0, natural reading order; then displaced
    // spawn-relative so '!' is the origin):
    //   row 0 (y=0) "  1.2" -> tiles at (-2,-1) enemy, (-1,-1), (0,-1) enemy
    //   row 1 (y=1) "..!.." -> tiles at (-2,0), (-1,0), (0,0) player, (1,0), (2,0)
    //   row 2 (y=2) "  ..=" -> tiles at (0,1), (1,1), (2,1) level_end
    try std.testing.expectEqual(11, level.level_tiles.len);

    // Player position: the '!' location is the origin.
    try std.testing.expectEqual(0, level.entities[0].position.x);
    try std.testing.expectEqual(0, level.entities[0].position.y);

    // Level end: raw (4,2) displaced by the spawn (2,1) → (2,1)
    try std.testing.expectEqual(2, level.level_end.?.x);
    try std.testing.expectEqual(1, level.level_end.?.y);
}

test "loadLevel decorations do not create tiles" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Decoration Test
        \\
        \\Layout
        \\.!=
        \\.A.
        \\...
        \\
        \\Entities
        \\
        \\Decorations
        \\character_code A
        \\sprite stone_1
        \\footprint 0 0
        \\
        \\Items
    ;

    const sections = try parseConfigFile(raw_text, allocator, &level_sections);
    defer freeParsedSections(sections, allocator);

    const level = try loadLevel(sections, null, allocator, "", null);
    defer freeLevel(level, allocator);

    // 8 tiles: 9 positions minus 1 decoration
    try std.testing.expectEqual(8, level.level_tiles.len);

    // 1 decoration
    try std.testing.expectEqual(1, level.decorations.len);
    try std.testing.expectEqualStrings("stone_1", level.decorations[0].name);

    // Decoration position: raw (1,1), displaced spawn-relative by the
    // '!' at (1,0) → (0,1)
    try std.testing.expectEqual(0, level.decorations[0].position.x);
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
    // bbox tiles - those are NOT footprint tiles and may overlap level tiles.
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Tree Test
        \\
        \\Layout
        \\T!=
        \\...
        \\...
        \\
        \\Entities
        \\
        \\Decorations
        \\character_code T
        \\sprite tree_1
        \\footprint 1 2
        \\
        \\Items
    ;

    const sections = try parseConfigFile(raw_text, allocator, &level_sections);
    defer freeParsedSections(sections, allocator);

    const level = try loadLevel(sections, null, allocator, "", null);
    defer freeLevel(level, allocator);

    // T is at raw (0, 0); the '!' spawn at (1, 0) displaces everything by
    // (-1, 0), so T is at world (-1, 0). The footprint world tile is
    // (-1, 0) - not a level tile (decoration char adds no tile). The other
    // 8 positions are all tiles ('.' / '!' / '=') -> 8 tiles.
    try std.testing.expectEqual(8, level.level_tiles.len);

    // 1 decoration with a single footprint tile (the trunk).
    try std.testing.expectEqual(1, level.decorations.len);
    try std.testing.expectEqualStrings("tree_1", level.decorations[0].name);
    try std.testing.expectEqual(-1, level.decorations[0].position.x);
    try std.testing.expectEqual(0, level.decorations[0].position.y);
    try std.testing.expectEqual(1, level.decorations[0].footprint.len);
    try std.testing.expectEqual(@as(i32, 1), level.decorations[0].footprint[0].x);
    try std.testing.expectEqual(@as(i32, 2), level.decorations[0].footprint[0].y);
    // 768x768 pixel dims from the comptime sprite-metadata table.
    try std.testing.expectEqual(@as(i32, 768), level.decorations[0].pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 768), level.decorations[0].pixel_dims.y);
}

test "loadLevel errors on a layout character no entry in the file defines" {
    const allocator = std.testing.allocator;
    // 'Z' is neither a special (' ', '.', '!', '=') nor a defined
    // decoration/entity/item code - the old silent fallback made it a
    // walkable tile.
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Bad Code
        \\
        \\Layout
        \\..!
        \\.Z.
        \\
        \\Entities
        \\
        \\Decorations
        \\
        \\Items
    ;
    const sections = try parseConfigFile(raw_text, allocator, &level_sections);
    defer freeParsedSections(sections, allocator);
    try std.testing.expectError(
        error.UnknownLayoutCharacter,
        loadLevel(sections, null, allocator, "level.txt", null),
    );
}

test "loadLevel errors on a missing player spawn / level end" {
    const allocator = std.testing.allocator;
    {
        // No '!' anywhere: nothing to anchor the player entity or the
        // spawn-relative origin on.
        const raw_text =
            \\Metadata
            \\file_format_version 1
            \\
            \\Layout
            \\=..
        ;
        const sections = try parseConfigFile(raw_text, allocator, &level_sections);
        defer freeParsedSections(sections, allocator);
        try std.testing.expectError(
            error.MissingPlayerSpawn,
            loadLevel(sections, null, allocator, "level.txt", null),
        );
    }
    {
        // No '=': the level has no exit.
        const raw_text =
            \\Metadata
            \\file_format_version 1
            \\
            \\Layout
            \\..!
        ;
        const sections = try parseConfigFile(raw_text, allocator, &level_sections);
        defer freeParsedSections(sections, allocator);
        try std.testing.expectError(
            error.MissingLevelEnd,
            loadLevel(sections, null, allocator, "level.txt", null),
        );
    }
}

test "loadHub errors on an undefined layout character / missing player spawn" {
    const allocator = std.testing.allocator;
    {
        // 'Z' is declared nowhere (not an exit, NPC, or decoration code).
        const raw_text =
            \\Metadata
            \\file_format_version 5
            \\
            \\Layout 2
            \\..!
            \\.Z.
        ;
        const sections = try parseConfigFile(raw_text, allocator, &hub_sections);
        defer freeParsedSections(sections, allocator);
        try std.testing.expectError(
            error.UnknownLayoutCharacter,
            loadHub(sections, null, allocator, "hub.txt", null),
        );
    }
    {
        const raw_text =
            \\Metadata
            \\file_format_version 5
            \\
            \\Layout 1
            \\...
        ;
        const sections = try parseConfigFile(raw_text, allocator, &hub_sections);
        defer freeParsedSections(sections, allocator);
        try std.testing.expectError(
            error.MissingPlayerSpawn,
            loadHub(sections, null, allocator, "hub.txt", null),
        );
    }
}

test "level file_format_version is a supported range; current requires the counted Layout" {
    const allocator = std.testing.allocator;
    {
        // v2 + counted: the writer's shape.
        const raw_text =
            \\Metadata
            \\file_format_version 2
            \\
            \\Layout 2
            \\..!
            \\..=
        ;
        const sections = try parseConfigFile(raw_text, allocator, &level_sections);
        defer freeParsedSections(sections, allocator);
        const level = try loadLevel(sections, null, allocator, "level.txt", null);
        defer freeLevel(level, allocator);
        // Six tiles: four '.' plus the '!' and '=' marker tiles.
        try std.testing.expectEqual(6, level.level_tiles.len);
    }
    {
        // v2 + bare Layout: the count was forgotten - an error, not a
        // silent legacy-grammar fallback into the known ambiguity.
        const raw_text =
            \\Metadata
            \\file_format_version 2
            \\
            \\Layout
            \\..!
            \\..=
        ;
        const sections = try parseConfigFile(raw_text, allocator, &level_sections);
        defer freeParsedSections(sections, allocator);
        try std.testing.expectError(
            error.UncountedLayout,
            loadLevel(sections, null, allocator, "level.txt", null),
        );
    }
    {
        // Newer than this build.
        const raw_text =
            \\Metadata
            \\file_format_version 3
            \\
            \\Layout 2
            \\..!
            \\..=
        ;
        const sections = try parseConfigFile(raw_text, allocator, &level_sections);
        defer freeParsedSections(sections, allocator);
        try std.testing.expectError(
            error.UnsupportedFileFormatVersion,
            loadLevel(sections, null, allocator, "level.txt", null),
        );
    }
    {
        // Older than the supported floor (v1 is the oldest).
        const raw_text =
            \\Metadata
            \\file_format_version 0
            \\
            \\Layout
            \\..!
            \\..=
        ;
        const sections = try parseConfigFile(raw_text, allocator, &level_sections);
        defer freeParsedSections(sections, allocator);
        try std.testing.expectError(
            error.UnsupportedFileFormatVersion,
            loadLevel(sections, null, allocator, "level.txt", null),
        );
    }
}

test "hub file_format_version is a supported range; current requires the counted Layout" {
    const allocator = std.testing.allocator;
    {
        // v5 (current) + counted: the current hub shape (Exits entries
        // are markers - character_code + mission_uuid).
        const raw_text =
            \\Metadata
            \\file_format_version 5
            \\hub_uuid some-hub
            \\
            \\Layout 1
            \\..!
        ;
        const sections = try parseConfigFile(raw_text, allocator, &hub_sections);
        defer freeParsedSections(sections, allocator);
        const hub = try loadHub(sections, null, allocator, "hub.txt", null);
        defer freeHub(hub, allocator);
        try std.testing.expectEqualStrings("some-hub", hub.uuid);
    }
    {
        const raw_text =
            \\Metadata
            \\file_format_version 5
            \\
            \\Layout
            \\..!
        ;
        const sections = try parseConfigFile(raw_text, allocator, &hub_sections);
        defer freeParsedSections(sections, allocator);
        try std.testing.expectError(
            error.UncountedLayout,
            loadHub(sections, null, allocator, "hub.txt", null),
        );
    }
    {
        // Newer than this build.
        const raw_text =
            \\Metadata
            \\file_format_version 6
            \\
            \\Layout 1
            \\..!
        ;
        const sections = try parseConfigFile(raw_text, allocator, &hub_sections);
        defer freeParsedSections(sections, allocator);
        try std.testing.expectError(
            error.UnsupportedFileFormatVersion,
            loadHub(sections, null, allocator, "hub.txt", null),
        );
    }
    {
        // Older than the supported floor (v5 - the Exits reduction +
        // the campaign v5 settle landed together; older hub files are
        // pre-release artifacts).
        const raw_text =
            \\Metadata
            \\file_format_version 4
            \\
            \\Layout 1
            \\..!
        ;
        const sections = try parseConfigFile(raw_text, allocator, &hub_sections);
        defer freeParsedSections(sections, allocator);
        try std.testing.expectError(
            error.UnsupportedFileFormatVersion,
            loadHub(sections, null, allocator, "hub.txt", null),
        );
    }
}

test "keep_original_colors: parses for entities + decorations, default false, dedup-distinct" {
    const allocator = std.testing.allocator;
    // An entity + a decoration carrying `keep_original_colors true`, plus
    // a second decoration without the key (defaults false).
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Keep Colors Test
        \\
        \\Layout
        \\1T2
        \\!.
        \\..=
        \\
        \\Entities
        \\character_code 1
        \\name Skeleton
        \\sprite skeleton_1
        \\keep_original_colors true
        \\
        \\Decorations
        \\character_code T
        \\sprite tree_1
        \\color_index 4
        \\keep_original_colors true
        \\footprint 1 2
        \\
        \\character_code 2
        \\sprite stone_1
        \\footprint 0 0
        \\
        \\Items
    ;
    const sections = try parseConfigFile(raw_text, allocator, &level_sections);
    defer freeParsedSections(sections, allocator);

    const level = try loadLevel(sections, null, allocator, "", null);
    defer freeLevel(level, allocator);

    // The authored flags parse; the absent key defaults false.
    try std.testing.expect(level.entities[1].keep_original_colors);
    try std.testing.expect(level.decorations[0].keep_original_colors);
    try std.testing.expect(!level.decorations[1].keep_original_colors);

    // Dedup equality: the flag is part of a definition's visual identity.
    var flag_off_entity = level.entities[1];
    flag_off_entity.keep_original_colors = false;
    try std.testing.expect(entityDefinitionsEqual(level.entities[1], level.entities[1]));
    try std.testing.expect(!entityDefinitionsEqual(level.entities[1], flag_off_entity));
    var flag_off_decoration = level.decorations[0];
    flag_off_decoration.keep_original_colors = false;
    try std.testing.expect(decorationDefinitionsEqual(level.decorations[0], level.decorations[0]));
    try std.testing.expect(!decorationDefinitionsEqual(level.decorations[0], flag_off_decoration));
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
        \\T!=
        \\...
        \\...
        \\
        \\Entities
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
    const sections = try parseConfigFile(raw_text, allocator, &level_sections);
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

/// A minimal PNG byte sequence: signature + IHDR chunk (dims + zeros).
/// `parsePngDimensions` reads only the signature + IHDR dims, so the
/// pixel data + CRC are absent - this is a fixture, not a decodable image.
/// pub ONLY as the cross-file test-fixture helper (handler tests build
/// conforming custom-sprite PNGs with it; production code never calls it).
pub fn minimalPngHeader(allocator: std.mem.Allocator, width: u32, height: u32) []u8 {
    const bytes = allocator.alloc(u8, 33) catch @panic("failed to allocate PNG fixture");
    @memcpy(bytes[0..8], &png_signature);
    std.mem.writeInt(u32, bytes[8..12], 13, .big);
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    // bit depth / color type / compression / filter / interlace + CRC -
    // never parsed; zeroed for a well-formed-looking chunk.
    @memset(bytes[24..33], 0);
    return bytes;
}

test "loadLevel resolves mission-bundled custom decoration stems" {
    const allocator = std.testing.allocator;
    // Custom assets are content-addressed: a `custom/<content-path>/<stem>`
    // decoration stem resolves its pixel dims from the PNG its id addresses
    // (the tail after `custom/` + `.png`, through readFile's tiers), never
    // from assets/ - the reload path that used to panic (see DESIGN →
    // Custom Missions & Online Services → Custom-asset paths). Base + layer
    // both route.
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const scratch = "zig-cache/test-custom-decoration-stem";
    const temp_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = @import("file_source.zig").FileSource.init(io, temp_dir);

    // Two mission-local PNGs: 512x256 (a 2x1 tile grid).
    const boss_png = minimalPngHeader(allocator, 512, 256);
    defer allocator.free(boss_png);
    file_source.writeFile("missions/test_m/boss.png", boss_png) catch @panic("write boss.png");
    const banner_png = minimalPngHeader(allocator, 512, 256);
    defer allocator.free(banner_png);
    file_source.writeFile("missions/test_m/banner.png", banner_png) catch @panic("write banner.png");

    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Custom Stem Test
        \\
        \\Layout
        \\D!
        \\=.
        \\
        \\Entities
        \\
        \\Decorations
        \\character_code D
        \\sprite custom/missions/test_m/boss
        \\footprint 0 0
        \\layer
        \\sprite custom/missions/test_m/banner
        \\color_index 2
        \\
        \\Items
    ;
    const sections = try parseConfigFile(raw_text, allocator, &level_sections);
    defer freeParsedSections(sections, allocator);

    const level = try loadLevel(sections, &file_source, allocator, "test_m/level_1.txt", null);
    defer freeLevel(level, allocator);

    try std.testing.expectEqual(1, level.decorations.len);
    try std.testing.expectEqualStrings("custom/missions/test_m/boss", level.decorations[0].name);
    try std.testing.expectEqual(@as(i32, 512), level.decorations[0].pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 256), level.decorations[0].pixel_dims.y);
    try std.testing.expectEqual(@as(i32, 512), level.decorations[0].layers[0].pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 256), level.decorations[0].layers[0].pixel_dims.y);
}

/// Test helper: does the collected load-warnings list contain a message with
/// the given substring? Tests assert warning PRESENCE by substring rather
/// than exact counts or full text - the contract is WHICH conditions warn,
/// not the wording.
fn hasLoadWarningContaining(warnings: []const []const u8, needle: []const u8) bool {
    for (warnings) |warning| {
        if (std.mem.indexOf(u8, warning, needle) != null) return true;
    }
    return false;
}

test "loadLevel clamps invalid decoration footprints (malformed, out-of-bbox, overlap, empty) with warnings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Four decorations, one per clamp class. A: a malformed footprint line
    // is skipped, leaving an authored-empty footprint → the bottom-left
    // default. B: the only footprint tile is outside the 1x1 sprite bbox →
    // dropped → default. C (tree_1, 3x3 grid): one of two in-bbox footprint
    // tiles lands on the level tile at (2,1) → dropped, the survivor stays.
    // D (tree_1): a valid footprint → untouched, NO warning.
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Footprint Clamp Test
        \\
        \\Layout
        \\A.BD
        \\!C.=
        \\
        \\Entities
        \\
        \\Decorations
        \\character_code A
        \\sprite stone_1
        \\footprint x y
        \\
        \\character_code B
        \\sprite stone_1
        \\footprint 2 2
        \\
        \\character_code C
        \\sprite tree_1
        \\footprint 0 2
        \\footprint 1 2
        \\
        \\character_code D
        \\sprite tree_1
        \\footprint 1 2
        \\
        \\Items
    ;
    const sections = try parseConfigFile(raw_text, arena, &level_sections);

    var warnings: std.ArrayList([]const u8) = .empty;
    const level = try loadLevel(sections, null, arena, "", &warnings);

    try std.testing.expectEqual(4, level.decorations.len);
    // A: default bottom-left tile.
    try std.testing.expectEqual(1, level.decorations[0].footprint.len);
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.decorations[0].footprint[0]);
    // B: out-of-bbox tile dropped, default written.
    try std.testing.expectEqual(1, level.decorations[1].footprint.len);
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, level.decorations[1].footprint[0]);
    // C: the overlapping tile (world (2,1)) dropped, the survivor stays.
    try std.testing.expectEqual(1, level.decorations[3].footprint.len);
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 2 }, level.decorations[3].footprint[0]);
    // D: untouched.
    try std.testing.expectEqual(1, level.decorations[2].footprint.len);
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 2 }, level.decorations[2].footprint[0]);

    try std.testing.expect(hasLoadWarningContaining(warnings.items, "malformed footprint line"));
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "has no footprint tiles"));
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "outside the sprite bbox"));
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "every footprint tile was dropped"));
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "overlap level/hub tiles"));
    // Exactly one warning per clamp class: A 2 (malformed + empty), B 2
    // (out-of-bbox + emptied), C 1 (overlap), D 0 (valid) - pins that the
    // valid decoration never warns and no class double-warns.
    try std.testing.expectEqual(@as(usize, 5), warnings.items.len);
}

test "loadLevel custom decoration dims: grid floor, 4096 warn, missing fallback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const scratch = "zig-cache/test-custom-decoration-dims";
    const temp_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = @import("file_source.zig").FileSource.init(io, temp_dir);

    // wide: 1000x1200 → floored to 768x1024. huge: 8192x256 is already a
    // whole multiple of 256 → kept, only the >4096 device warning fires.
    // tiny: 250x250 → floored up to the 1x1 minimum. ghost: no PNG at all →
    // the 256x256 fallback (renders magenta). unknown: a typo'd bare stem →
    // the same fallback class.
    const fixtures = [_]struct { name: []const u8, width: u32, height: u32 }{
        .{ .name = "wide.png", .width = 1000, .height = 1200 },
        .{ .name = "huge.png", .width = 8192, .height = 256 },
        .{ .name = "tiny.png", .width = 250, .height = 250 },
    };
    for (fixtures) |fixture| {
        const png = minimalPngHeader(std.testing.allocator, fixture.width, fixture.height);
        defer std.testing.allocator.free(png);
        const path = std.fmt.allocPrint(std.testing.allocator, "missions/test_m/{s}", .{fixture.name}) catch
            @panic("failed to format fixture path");
        defer std.testing.allocator.free(path);
        file_source.writeFile(path, png) catch @panic("write fixture png");
    }

    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Custom Dims Test
        \\
        \\Layout
        \\WHTGU
        \\!.=..
        \\
        \\Entities
        \\
        \\Decorations
        \\character_code W
        \\sprite custom/missions/test_m/wide
        \\footprint 0 0
        \\
        \\character_code H
        \\sprite custom/missions/test_m/huge
        \\footprint 0 0
        \\
        \\character_code T
        \\sprite custom/missions/test_m/tiny
        \\footprint 0 0
        \\
        \\character_code G
        \\sprite custom/missions/test_m/ghost
        \\footprint 0 0
        \\
        \\character_code U
        \\sprite tree_99
        \\footprint 0 0
        \\
        \\Items
    ;
    const sections = try parseConfigFile(raw_text, arena, &level_sections);

    var warnings: std.ArrayList([]const u8) = .empty;
    const level = try loadLevel(sections, &file_source, arena, "test_m/level_1.txt", &warnings);

    try std.testing.expectEqual(5, level.decorations.len);
    // wide: floored to whole tiles.
    try std.testing.expectEqual(types.Vector2{ .x = 768, .y = 1024 }, level.decorations[0].pixel_dims);
    // huge: a multiple of 256 stays as-is.
    try std.testing.expectEqual(types.Vector2{ .x = 8192, .y = 256 }, level.decorations[1].pixel_dims);
    // tiny: sub-256 clamps up to the 1x1 minimum.
    try std.testing.expectEqual(types.Vector2{ .x = 256, .y = 256 }, level.decorations[2].pixel_dims);
    // ghost + unknown: the 256x256 fallback.
    try std.testing.expectEqual(types.Vector2{ .x = 256, .y = 256 }, level.decorations[3].pixel_dims);
    try std.testing.expectEqual(types.Vector2{ .x = 256, .y = 256 }, level.decorations[4].pixel_dims);

    try std.testing.expect(hasLoadWarningContaining(warnings.items, "floored to 768x1024"));
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "exceeds 4096px"));
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "floored to 256x256"));
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "'custom/missions/test_m/ghost'"));
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "'tree_99'"));
    // huge is grid-conformant: no floor warning for it (the >4096 device
    // warning still names its dims - different needle).
    try std.testing.expect(!hasLoadWarningContaining(warnings.items, "floored to 8192"));
}

test "decoration layer dims mismatch vs base: kept + warned (no panic)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // tree_1 base (768x768) with a stone_1 layer (256x256): the mismatch
    // warns and the layer is KEPT (renders cropped to the base grid) -
    // the old behavior was a load-time panic.
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Layer Mismatch Test
        \\
        \\Layout
        \\T!=
        \\...
        \\...
        \\
        \\Entities
        \\
        \\Decorations
        \\character_code T
        \\sprite tree_1
        \\footprint 1 2
        \\layer
        \\sprite stone_1
        \\color_index 2
        \\
        \\Items
    ;
    const sections = try parseConfigFile(raw_text, arena, &level_sections);

    var warnings: std.ArrayList([]const u8) = .empty;
    const level = try loadLevel(sections, null, arena, "", &warnings);

    try std.testing.expectEqual(1, level.decorations[0].layers.len);
    try std.testing.expectEqualStrings("stone_1", level.decorations[0].layers[0].sprite);
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "cropped to the base grid"));
}

test "loadLevel custom entity sprites: 512x640 warn-only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const scratch = "zig-cache/test-custom-entity-dims";
    const temp_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = @import("file_source.zig").FileSource.init(io, temp_dir);

    // hero: conforming 512x640 (silent). tiny: wrong dims. missing: no
    // PNG at all. All warn-only - the fixed-frame render continues.
    const hero_png = minimalPngHeader(std.testing.allocator, 512, 640);
    defer std.testing.allocator.free(hero_png);
    file_source.writeFile("missions/test_m/hero.png", hero_png) catch @panic("write hero.png");
    const tiny_png = minimalPngHeader(std.testing.allocator, 256, 256);
    defer std.testing.allocator.free(tiny_png);
    file_source.writeFile("missions/test_m/tiny.png", tiny_png) catch @panic("write tiny.png");

    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Custom Entity Dims Test
        \\
        \\Layout
        \\EFGH
        \\!.=.
        \\
        \\Entities
        \\character_code E
        \\name Hero
        \\sprite custom/missions/test_m/hero
        \\
        \\character_code F
        \\name WrongDims
        \\sprite custom/missions/test_m/tiny
        \\
        \\character_code G
        \\name Missing
        \\sprite custom/missions/test_m/missing
        \\
        \\character_code H
        \\name Layered
        \\sprite custom/missions/test_m/hero
        \\layer
        \\sprite custom/missions/test_m/tiny
        \\color_index 2
        \\
        \\Decorations
        \\
        \\Items
    ;
    const sections = try parseConfigFile(raw_text, arena, &level_sections);

    var warnings: std.ArrayList([]const u8) = .empty;
    const level = try loadLevel(sections, &file_source, arena, "test_m/level_1.txt", &warnings);

    // All four entities load regardless of sprite spec - warn-only.
    try std.testing.expectEqual(5, level.entities.len);
    try std.testing.expectEqualStrings("custom/missions/test_m/hero", level.entities[1].sprite);
    try std.testing.expectEqualStrings("custom/missions/test_m/tiny", level.entities[2].sprite);
    try std.testing.expectEqualStrings("custom/missions/test_m/missing", level.entities[3].sprite);

    // Exactly the three spec violations warn: wrong base dims, a missing
    // base PNG, a wrong-dims layer. The conforming hero base stays silent.
    try std.testing.expectEqual(@as(usize, 3), warnings.items.len);
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "entity sprite 'custom/missions/test_m/tiny'"));
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "entity sprite 'custom/missions/test_m/missing'"));
    try std.testing.expect(hasLoadWarningContaining(warnings.items, "entity layer sprite 'custom/missions/test_m/tiny'"));
    try std.testing.expect(!hasLoadWarningContaining(warnings.items, "'custom/missions/test_m/hero' in"));
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
    const sections = try parseConfigFile(bytes, allocator, &decoration_registry_sections);
    defer freeParsedSections(sections, allocator);

    const registry = try loadDecorationRegistry(sections, &file_source, allocator);
    defer freeDecorationRegistry(registry, allocator);

    // One entry per shipped decoration base sprite: 5 trees + tent + 11
    // ruins + 5 statues + 6 stones = 28. (Layer stems - canopy, moss, grass,
    // grass_back - belong to their base's entry, not their own.)
    try std.testing.expectEqual(@as(usize, 28), registry.len);

    // Find the tree entry (first, with a layer), a stone (single-tile), a
    // new-tree prefab, and the tent (the footprint-on-bottom-tile shape).
    var tree: ?types.DecorationTypeDef = null;
    var stone_6: ?types.DecorationTypeDef = null;
    var tree_5: ?types.DecorationTypeDef = null;
    var tent: ?types.DecorationTypeDef = null;
    for (registry) |def| {
        if (std.mem.eql(u8, def.sprite, "tree_1")) tree = def;
        if (std.mem.eql(u8, def.sprite, "stone_6")) stone_6 = def;
        if (std.mem.eql(u8, def.sprite, "tree_5")) tree_5 = def;
        if (std.mem.eql(u8, def.sprite, "tent")) tent = def;
    }
    try std.testing.expect(tree != null);
    try std.testing.expect(stone_6 != null);
    try std.testing.expect(tree_5 != null);
    try std.testing.expect(tent != null);

    // tree_5 (a new-tree prefab): same footprint + colors as tree_1, the
    // same four layer stems under its own namespace.
    const t5 = tree_5.?;
    try std.testing.expectEqual(@as(usize, 1), t5.footprint.len);
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 2 }, t5.footprint[0]);
    try std.testing.expectEqual(@as(u32, 4), t5.color_index);
    try std.testing.expectEqual(@as(usize, 4), t5.layers.len);
    for ([_][]const u8{ "tree_5_canopy", "tree_5_moss", "tree_5_grass", "tree_5_grass_back" }, t5.layers) |expected, layer| {
        try std.testing.expectEqualStrings(expected, layer.sprite);
    }
    try std.testing.expectEqual(true, t5.layers[3].behind);

    // tree_1: 3x3 bbox (768x768), footprint at (1,2), color 4, four layers
    // in config order (canopy, moss, grass, grass_back - each color 2, the
    // canopy's index, same dims).
    const t = tree.?;
    try std.testing.expectEqual(@as(i32, 768), t.pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 768), t.pixel_dims.y);
    try std.testing.expectEqual(@as(usize, 1), t.footprint.len);
    try std.testing.expectEqual(@as(i32, 1), t.footprint[0].x);
    try std.testing.expectEqual(@as(i32, 2), t.footprint[0].y);
    try std.testing.expectEqual(@as(u32, 4), t.color_index);
    try std.testing.expectEqual(@as(usize, 4), t.layers.len);
    try std.testing.expectEqualStrings("tree_1_canopy", t.layers[0].sprite);
    try std.testing.expectEqualStrings("tree_1_moss", t.layers[1].sprite);
    try std.testing.expectEqualStrings("tree_1_grass", t.layers[2].sprite);
    try std.testing.expectEqualStrings("tree_1_grass_back", t.layers[3].sprite);
    for (t.layers) |layer| {
        try std.testing.expectEqual(@as(u32, 2), layer.color_index);
        try std.testing.expectEqual(@as(i32, 768), layer.pixel_dims.x);
        try std.testing.expectEqual(@as(i32, 768), layer.pixel_dims.y);
    }
    // The `behind` key: grass_back is the one behind layer; the rest are
    // overlays (the flag defaults false when the key is absent).
    try std.testing.expectEqual(false, t.layers[0].behind);
    try std.testing.expectEqual(false, t.layers[1].behind);
    try std.testing.expectEqual(false, t.layers[2].behind);
    try std.testing.expectEqual(true, t.layers[3].behind);
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

    // tent: 1x2 bbox (256x512), footprint on the BOTTOM tile, no layers.
    const tent_def = tent.?;
    try std.testing.expectEqual(@as(i32, 256), tent_def.pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 512), tent_def.pixel_dims.y);
    try std.testing.expectEqual(@as(usize, 1), tent_def.footprint.len);
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 1 }, tent_def.footprint[0]);
    try std.testing.expectEqual(@as(u32, 0), tent_def.color_index);
    try std.testing.expectEqual(@as(usize, 0), tent_def.layers.len);
}

test "buildEditorMission: a later level failing loadLevel leaks nothing" {
    // The leak-checked error path: level 1 is VALID (entity + decoration
    // + item into the palette, a dedup-hit entity, remnants freed),
    // level 2 has an undefined layout character - loadLevel errors and
    // the errdefer must free the whole accumulated palette.
    // testing.allocator flags any leak.
    const allocator = std.testing.allocator;
    const good_level_text =
        \\Metadata
        \\file_format_version 2
        \\name Build Test
        \\
        \\Layout 3
        \\!.i
        \\ee.
        \\.d=
        \\
        \\Entities
        \\character_code e
        \\name Enemy
        \\sprite skeleton_1
        \\
        \\Decorations
        \\character_code d
        \\sprite stone_1
        \\footprint 0 0
        \\
        \\Items
        \\character_code i
        \\item_type weapon
        \\item_name Test Sword
        \\weapon_type sword
        \\damage 3
    ;
    const bad_level_text =
        \\Metadata
        \\file_format_version 2
        \\name Bad
        \\
        \\Layout 1
        \\!x=
    ;
    const good_sections = try parseConfigFile(good_level_text, allocator, &level_sections);
    defer freeParsedSections(good_sections, allocator);
    const bad_sections = try parseConfigFile(bad_level_text, allocator, &level_sections);
    defer freeParsedSections(bad_sections, allocator);

    const parsed_levels = [_][]const Section{ good_sections, bad_sections };
    try std.testing.expectError(
        error.UnknownLayoutCharacter,
        buildEditorMission(types.Mission{ .name = "M" }, .{}, parsed_levels[0..], null, allocator, "", null),
    );
}

test "buildEditorMission: the palette owns its data; a full build frees clean" {
    // Success-path ownership: one level with all three palette kinds + a
    // dedup-hit entity; the build owns everything (ids included), the
    // sections can go first, and freeEditorBuild sweeps the result.
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\name Build Test
        \\
        \\Layout 3
        \\!.i
        \\ee.
        \\.d=
        \\
        \\Entities
        \\character_code e
        \\name Enemy
        \\sprite skeleton_1
        \\
        \\Decorations
        \\character_code d
        \\sprite stone_1
        \\footprint 0 0
        \\
        \\Items
        \\character_code i
        \\item_type weapon
        \\item_name Test Sword
        \\weapon_type sword
        \\damage 3
    ;
    const sections = try parseConfigFile(raw_text, allocator, &level_sections);

    const parsed_levels = [_][]const Section{sections};
    const editor = try buildEditorMission(
        types.Mission{ .name = "M" },
        .{},
        parsed_levels[0..],
        null,
        allocator,
        "",
        null,
    );
    // Ownership contract: the parse bytes go FIRST - NOTHING in the
    // editor borrows them (level names are duped; every other field is
    // moved or deep-copied).
    freeParsedSections(sections, allocator);

    // Content: the two same-definition entities dedup into one palette
    // type with two placements; the decoration + item are one type each.
    try std.testing.expectEqual(@as(usize, 1), editor.entity_types.len);
    try std.testing.expectEqualStrings("Enemy", editor.entity_types[0].id);
    try std.testing.expectEqual(@as(usize, 2), editor.levels[0].entity_placements.len);
    try std.testing.expectEqual(@as(usize, 1), editor.decoration_types.len);
    try std.testing.expectEqual(@as(usize, 1), editor.item_types.len);
    // The item id is OWNED (duped) - uniform with the skill-tome case.
    try std.testing.expectEqualStrings("Test Sword", editor.item_types[0].id);
    // The level name too - readable AFTER the sections freed.
    try std.testing.expectEqualStrings("Build Test", editor.levels[0].name);

    freeEditorBuild(
        editor.levels,
        editor.entity_types,
        editor.decoration_types,
        editor.item_types,
        allocator,
    );
}

test "loadEditorDefaults parses the shipped palette defaults" {
    // The shipped data/editor_defaults.txt via the real FileSource - the
    // registry test's read-the-shipped-file pattern, so the test guards the
    // file's content against drift. Arena-wrapped: the parsed defs borrow
    // the section strings (the loader-borrowing convention).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = @import("file_source.zig").FileSource.init(io, std.Io.Dir.cwd());

    const bytes = try file_source.readFile(allocator, "data/editor_defaults.txt");
    const sections = try parseConfigFile(bytes, allocator, &parser.editor_defaults_sections);
    const defaults = try loadEditorDefaults(sections, &file_source, allocator, "data/editor_defaults.txt", null);

    // Entity: "New Entity" on skeleton_1, team 1, color 4, weapons shown,
    // 20/0/1/3 stats, and nothing else - no weapons, gear, utility skills,
    // or layers (the absent keys are the point).
    try std.testing.expectEqualStrings("New Entity", defaults.entity.id);
    try std.testing.expectEqualStrings("New Entity", defaults.entity.template.name);
    try std.testing.expectEqualStrings("skeleton_1", defaults.entity.template.sprite);
    try std.testing.expectEqual(@as(u32, 1), defaults.entity.template.team);
    try std.testing.expectEqual(@as(u32, 4), defaults.entity.template.color_index);
    try std.testing.expect(defaults.entity.template.displays_weapons);
    try std.testing.expectEqual(@as(u32, 20), defaults.entity.template.max_health);
    try std.testing.expectEqual(@as(u32, 0), defaults.entity.template.defense);
    try std.testing.expectEqual(@as(u32, 1), defaults.entity.template.speed);
    try std.testing.expectEqual(@as(u32, 3), defaults.entity.template.aggro_range);
    try std.testing.expect(defaults.entity.template.main_hand_weapon == null);
    try std.testing.expect(defaults.entity.template.off_hand_weapon == null);
    try std.testing.expect(defaults.entity.template.amulet == null);
    try std.testing.expect(defaults.entity.template.coat == null);
    try std.testing.expect(defaults.entity.template.gloves == null);
    try std.testing.expect(defaults.entity.template.pants == null);
    try std.testing.expect(defaults.entity.template.boots == null);
    for (defaults.entity.template.equipped_utility_skills) |slot| {
        try std.testing.expect(slot == null);
    }
    try std.testing.expectEqual(@as(usize, 0), defaults.entity.template.layers.len);

    // Decoration: the stone_1 prefab duplicated - single (0,0) footprint,
    // color 5, 256x256 dims, no layers; the palette id tracks the sprite.
    try std.testing.expectEqualStrings("stone_1", defaults.decoration.id);
    try std.testing.expectEqualStrings("stone_1", defaults.decoration.sprite);
    try std.testing.expectEqual(@as(usize, 1), defaults.decoration.footprint.len);
    try std.testing.expectEqual(@as(i32, 0), defaults.decoration.footprint[0].x);
    try std.testing.expectEqual(@as(i32, 0), defaults.decoration.footprint[0].y);
    try std.testing.expectEqual(@as(u32, 5), defaults.decoration.color_index);
    try std.testing.expectEqual(@as(i32, 256), defaults.decoration.pixel_dims.x);
    try std.testing.expectEqual(@as(i32, 256), defaults.decoration.pixel_dims.y);
    try std.testing.expectEqual(@as(usize, 0), defaults.decoration.layers.len);

    // Item: a New Sword (sword, 0 damage); the palette id is the item name.
    try std.testing.expectEqualStrings("New Sword", defaults.item.id);
    try std.testing.expectEqualStrings("New Sword", defaults.item.item.weapon.name);
    try std.testing.expectEqual(types.WeaponType.sword, defaults.item.item.weapon.weapon_type);
    try std.testing.expectEqual(@as(u32, 0), defaults.item.item.weapon.weapon_damage);
}

test "loadEditorDefaults rejects missing entries and format drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Metadata only - every kind's entry is missing.
    {
        const sections = try parseConfigFile(
            "Metadata\nfile_format_version 1\n",
            allocator,
            &parser.editor_defaults_sections,
        );
        try std.testing.expectError(
            error.MissingDefaultEntry,
            loadEditorDefaults(sections, null, allocator, "test/editor_defaults.txt", null),
        );
    }
    // An Entities entry without a name - a sprite-only entry is not a
    // usable enemy default.
    {
        const sections = try parseConfigFile(
            \\Metadata
            \\file_format_version 1
            \\
            \\Entities
            \\sprite skeleton_1
            \\
            \\Decorations
            \\sprite stone_1
            \\
            \\Items
            \\item_type weapon
            \\item_name New Sword
            \\
        , allocator, &parser.editor_defaults_sections);
        try std.testing.expectError(
            error.MissingDefaultEntry,
            loadEditorDefaults(sections, null, allocator, "test/editor_defaults.txt", null),
        );
    }
    // A version mismatch is the standard hard gate.
    {
        const sections = try parseConfigFile(
            "Metadata\nfile_format_version 2\n",
            allocator,
            &parser.editor_defaults_sections,
        );
        try std.testing.expectError(
            error.UnsupportedFileFormatVersion,
            loadEditorDefaults(sections, null, allocator, "test/editor_defaults.txt", null),
        );
    }
    // An unexpected section (a Layout snuck in) is rejected at the PARSE
    // (UnknownSectionHeader - Layout is not an editor-defaults section),
    // not later inside loadEditorDefaults.
    {
        try std.testing.expectError(
            error.UnknownSectionHeader,
            parseConfigFile(
                \\Metadata
                \\file_format_version 1
                \\
                \\Layout
                \\!
                \\
            , allocator, &parser.editor_defaults_sections),
        );
    }
}

test "loadEditorDefaults: MissingDefaultEntry after allocations leaks nothing" {
    // The leak-checked error path (the arena-wrapped test above cannot
    // see it - its fixtures error before any allocation): Entities +
    // Decorations parse (entity layers + decoration footprint/layers
    // allocated), then no Items section.
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\
        \\Entities
        \\name New Entity
        \\sprite skeleton_1
        \\
        \\Decorations
        \\sprite stone_1
        \\footprint 0 0
    ;
    const sections = try parseConfigFile(raw_text, allocator, &parser.editor_defaults_sections);
    defer freeParsedSections(sections, allocator);
    try std.testing.expectError(
        error.MissingDefaultEntry,
        loadEditorDefaults(sections, null, allocator, "test/editor_defaults.txt", null),
    );
}

test "instantiateEditorLevel regroups co-located item placements into one stack" {
    // Level files author one item per stack, but the editor UI can place two
    // item types on the same tile - instantiation must regroup co-located
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
    try std.testing.expectEqual(@as(u32, 10), boundedU32("99", types.max_weapon_damage, "damage", "test.txt", &warnings, allocator));
    try std.testing.expectEqual(@as(u32, 5), boundedU32("6", types.max_defense_bonus, "armor", "test.txt", &warnings, allocator));
    try std.testing.expectEqual(@as(u32, 2), boundedU32("3", types.max_boots_speed, "speed", "test.txt", &warnings, allocator));
    // At max → unchanged, no warning.
    try std.testing.expectEqual(@as(u32, 10), boundedU32("10", types.max_weapon_damage, "damage", "test.txt", &warnings, allocator));
    // Under max → unchanged, no warning.
    try std.testing.expectEqual(@as(u32, 3), boundedU32("3", types.max_weapon_damage, "damage", "test.txt", &warnings, allocator));
    // Unparseable → 0, no warning.
    try std.testing.expectEqual(@as(u32, 0), boundedU32("abc", types.max_weapon_damage, "damage", "test.txt", &warnings, allocator));
    // Null warnings → clamps silently.
    try std.testing.expectEqual(@as(u32, 10), boundedU32("99", types.max_weapon_damage, "damage", "test.txt", null, allocator));

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
        \\Entities
        \\
        \\Decorations
        \\
        \\Items
        \\
        \\Audio
        \\file_format_version 1
        \\music_volume 0.5
    ;

    // The per-format header grammar rejects the unexpected section at the
    // PARSE (UnknownSectionHeader, naming the offending line shape) - the
    // old path let it parse and errored UnexpectedSection inside loadLevel
    // after the damage was done.
    try std.testing.expectError(
        error.UnknownSectionHeader,
        parseConfigFile(raw_text, allocator, &level_sections),
    );
}

test "loadHub parses a complete hub" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 5
        \\hub_uuid hub-uuid-1
        \\name Test Village
        \\
        \\Layout 3
        \\...N.
        \\.!...
        \\..E..
        \\
        \\NPCs
        \\character_code N
        \\npc_type gear_upgrader
        \\
        \\Decorations
        \\
        \\Exits
        \\character_code E
        \\mission_uuid first_mission_uuid
    ;

    const sections = try parseConfigFile(raw_text, allocator, &hub_sections);

    const hub = try loadHub(sections, null, allocator, "", null);
    // Ownership contract: free the parse bytes BEFORE reading the hub -
    // every field must be owned (leak-checked by testing.allocator via
    // freeHub below). See DESIGN → File System & IO → Settings ownership.
    freeParsedSections(sections, allocator);

    // Metadata
    try std.testing.expectEqualStrings("Test Village", hub.name);

    // Player position from '!': the spawn is the origin.
    try std.testing.expectEqualStrings("Player", hub.player.name);
    try std.testing.expectEqual(0, hub.player.position.x);
    try std.testing.expectEqual(0, hub.player.position.y);

    // NPC: type + position (not an entity). N at raw (3,0), displaced by
    // the spawn (1,1) → (2,-1)
    try std.testing.expectEqual(1, hub.npcs.len);
    try std.testing.expectEqual(types.NpcType.gear_upgrader, hub.npcs[0].npc_type);
    try std.testing.expectEqual(2, hub.npcs[0].position.x);
    try std.testing.expectEqual(-1, hub.npcs[0].position.y);

    // Mission exit: the MARKER (mission_uuid + position; the edge data
    // is campaign.txt's Missions section). E at raw (2,2), displaced by
    // the spawn (1,1) → (1,1)
    try std.testing.expectEqual(1, hub.mission_exits.len);
    try std.testing.expectEqualStrings("first_mission_uuid", hub.mission_exits[0].mission_uuid);
    try std.testing.expectEqual(1, hub.mission_exits[0].position.x);
    try std.testing.expectEqual(1, hub.mission_exits[0].position.y);

    // Tiles: all positions except decorations. No decorations here, so all non-space chars get tiles.
    // 5 + 5 + 5 = 15 total characters, minus 0 spaces = 15... wait, rows are 5 chars each
    // Row 0 "...N." -> 5 tiles (NPC gets a tile)
    // Row 1 ".!..." -> 5 tiles
    // Row 2 "..E.." -> 5 tiles (exit gets a tile)
    try std.testing.expectEqual(15, hub.hub_tiles.len);

    freeHub(hub, allocator);
}

test "loadHub: NPC entries with missing/unknown npc_type warn and drop" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 5
        \\hub_uuid hub-uuid-2
        \\name Test Village
        \\
        \\Layout 3
        \\.!M.
        \\..U..
        \\..E..
        \\
        \\NPCs
        \\character_code M
        \\npc_type dream_guide
        \\
        \\character_code U
        \\npc_type blacksmith
        \\
        \\character_code X
        \\
        \\Exits
        \\character_code E
        \\mission_uuid first_mission_uuid
    ;

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }

    const sections = try parseConfigFile(raw_text, allocator, &hub_sections);
    const hub = try loadHub(sections, null, allocator, "hub.txt", &warnings);
    freeParsedSections(sections, allocator);

    // M parses; U (unknown type) and X (no npc_type) warn + drop.
    try std.testing.expectEqual(1, hub.npcs.len);
    try std.testing.expectEqual(types.NpcType.dream_guide, hub.npcs[0].npc_type);
    // M at raw (2,0), displaced by the spawn (1,0) → (1,0)
    try std.testing.expectEqual(1, hub.npcs[0].position.x);
    try std.testing.expectEqual(0, hub.npcs[0].position.y);

    try std.testing.expectEqual(@as(usize, 2), warnings.items.len);
    for (warnings.items) |warning| {
        try std.testing.expect(std.mem.indexOf(u8, warning, "hub.txt") != null);
    }

    freeHub(hub, allocator);
}

test "loadCampaign parses metadata, background mint, + the Hubs section" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 5
        \\campaign_uuid c-uuid
        \\name Main Campaign
        \\start_hub starting_village_uuid
        \\background map
        \\
        \\Hubs
        \\
        \\hub_uuid starting_village_uuid
        \\position 0 0
        \\
        \\hub_uuid far_camp_uuid
        \\position -1920 1080
    ;

    const sections = try parseConfigFile(raw_text, allocator, &campaign_sections);

    const campaign = try loadCampaign(sections, "campaigns/main_campaign", allocator, null);
    // Ownership contract: free the parse bytes BEFORE reading the campaign
    // (see the loadHub test above).
    freeParsedSections(sections, allocator);

    try std.testing.expectEqualStrings("Main Campaign", campaign.name);
    try std.testing.expectEqualStrings("starting_village_uuid", campaign.start_hub);
    try std.testing.expectEqualStrings("c-uuid", campaign.uuid);
    // The background's bare stem mints into the content-addressed id (the
    // data/ prefix strips; the tail resolves through readFile's tiers).
    try std.testing.expectEqualStrings("custom/campaigns/main_campaign/map", campaign.background);
    try std.testing.expectEqual(@as(usize, 2), campaign.hubs.len);
    try std.testing.expectEqualStrings("starting_village_uuid", campaign.hubs[0].uuid);
    try std.testing.expectEqual(@as(i32, 0), campaign.hubs[0].position.x);
    try std.testing.expectEqual(@as(i32, 0), campaign.hubs[0].position.y);
    try std.testing.expectEqualStrings("far_camp_uuid", campaign.hubs[1].uuid);
    // Center-offset integers, negative values legal (unbounded space).
    try std.testing.expectEqual(@as(i32, -1920), campaign.hubs[1].position.x);
    try std.testing.expectEqual(@as(i32, 1080), campaign.hubs[1].position.y);

    freeCampaign(campaign, allocator);
}

test "loadCampaign: Hubs entries without a parsable position warn and drop" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 5
        \\name C
        \\start_hub ok_uuid
        \\
        \\Hubs
        \\
        \\hub_uuid ok_uuid
        \\position 3 4
        \\
        \\hub_uuid no_position
        \\
        \\hub_uuid bad_position
        \\position over there
    ;

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }

    const sections = try parseConfigFile(raw_text, allocator, &campaign_sections);
    defer freeParsedSections(sections, allocator);

    const campaign = try loadCampaign(sections, "campaigns/test_c", allocator, &warnings);
    defer freeCampaign(campaign, allocator);

    try std.testing.expectEqual(@as(usize, 1), campaign.hubs.len);
    try std.testing.expectEqualStrings("ok_uuid", campaign.hubs[0].uuid);
    try std.testing.expectEqual(@as(usize, 2), warnings.items.len);
}

test "loadCampaign without name/start_hub/background/hubs defaults to empty and frees clean" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 5
    ;

    const sections = try parseConfigFile(raw_text, allocator, &campaign_sections);
    defer freeParsedSections(sections, allocator);

    const campaign = try loadCampaign(sections, "campaigns/none", allocator, null);
    try std.testing.expectEqualStrings("", campaign.name);
    try std.testing.expectEqualStrings("", campaign.start_hub);
    try std.testing.expectEqualStrings("", campaign.background);
    try std.testing.expectEqual(@as(usize, 0), campaign.hubs.len);

    // The empty defaults are the static empty slice - freeCampaign must
    // treat them as a no-op, not a double-free or a leak.
    freeCampaign(campaign, allocator);
}

test "official campaign: a saved persistent copy loads clean (shadow, not duplicate)" {
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const scratch = "zig-cache/test-official-campaign-save-shadow";
    const temp_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = file_source_mod.FileSource.init(io, temp_dir);

    // The save-then-load repro against REAL shipped content: materialize
    // the official campaign's hub + mission config files into the
    // persistent tier at the same content-relative paths (what a
    // campaign-editor save of the official campaign produces). Loading
    // then sees every uuid in BOTH tiers - the persistent copy must
    // shadow the embedded original silently, not warn "duplicate".
    const hub_dirs = embeddedHubDirs("main_campaign", allocator);
    defer allocator.free(hub_dirs);
    for (hub_dirs) |hub_dir| {
        const hub_txt_path = std.fmt.allocPrint(allocator, "{s}/hub.txt", .{hub_dir}) catch
            @panic("failed to build hub.txt path");
        defer allocator.free(hub_txt_path);
        const hub_txt = file_source.readFile(allocator, hub_txt_path) catch
            @panic("failed to read the embedded hub.txt");
        defer allocator.free(hub_txt);
        file_source.writeFile(hub_txt_path, hub_txt) catch @panic("failed to write the persistent hub copy");
    }
    const mission_dirs = file_source_mod.officialMissionDirPathsForCampaign("campaigns/main_campaign/missions", allocator);
    defer {
        for (mission_dirs) |mission_dir| allocator.free(mission_dir);
        allocator.free(mission_dirs);
    }
    for (mission_dirs) |mission_dir| {
        const mission_txt_path = std.fmt.allocPrint(allocator, "{s}/mission.txt", .{mission_dir}) catch
            @panic("failed to build mission.txt path");
        defer allocator.free(mission_txt_path);
        const mission_txt = file_source.readFile(allocator, mission_txt_path) catch
            @panic("failed to read the embedded mission.txt");
        defer allocator.free(mission_txt);
        file_source.writeFile(mission_txt_path, mission_txt) catch @panic("failed to write the persistent mission copy");
    }

    const campaign_txt = file_source.readFile(allocator, "campaigns/main_campaign/campaign.txt") catch
        @panic("failed to read the embedded campaign.txt");
    defer allocator.free(campaign_txt);
    const sections = try parseConfigFile(campaign_txt, allocator, &campaign_sections);
    defer freeParsedSections(sections, allocator);
    var campaign = try loadCampaign(sections, "campaigns/main_campaign", allocator, null);
    defer freeCampaign(campaign, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }

    resolveCampaignHubs(&campaign, &file_source, allocator, &warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqual(hub_dirs.len, campaign.hubs.len);
    for (campaign.hubs) |hub| try std.testing.expect(hub.dir.len > 0);

    campaign.missions = resolveCampaignMissions(campaign, &file_source, allocator, &warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    // Every shipped mission resolved (the count derived from the same
    // scan the copies came from), each to a non-empty dir.
    try std.testing.expectEqual(mission_dirs.len, campaign.missions.len);
    for (campaign.missions) |mission| try std.testing.expect(mission.dir.len > 0);
}

test "deriveCampaignEdges + checkCampaignGraph: derive the table, then warn per defect" {
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const scratch = "zig-cache/test-campaign-graph";
    const temp_dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = file_source_mod.FileSource.init(io, temp_dir);

    // The v5 shape: the edge data lives in campaign.txt's Missions
    // section; the hub files carry names + MARKERS only.
    file_source.writeFile(
        "campaigns/check/hubs/start/hub.txt",
        "Metadata\nfile_format_version 5\nhub_uuid start\nname Start\n\nExits\ncharacter_code E\nmission_uuid u1\n",
    ) catch @panic("write start hub");
    file_source.writeFile(
        "campaigns/check/hubs/far/hub.txt",
        "Metadata\nfile_format_version 5\nhub_uuid far\nname Far\n\nExits\ncharacter_code E\nmission_uuid u2\n",
    ) catch @panic("write far hub");
    file_source.writeFile("campaigns/check/missions/m1/mission.txt", "Metadata\nfile_format_version 3\nmission_uuid u1\nname M1\n") catch @panic("write m1");
    file_source.writeFile("campaigns/check/missions/m2/mission.txt", "Metadata\nfile_format_version 3\nmission_uuid u2\nname M2\n") catch @panic("write m2");
    file_source.writeFile("campaigns/check/missions/m3/mission.txt", "Metadata\nfile_format_version 3\nmission_uuid u3\nname M3\n") catch @panic("write m3");
    file_source.writeFile("campaigns/check/missions/m4/mission.txt", "Metadata\nfile_format_version 3\nmission_uuid u4\nname M4\n") catch @panic("write m4");

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }

    // The load-side pipeline, per run: a hand-authored Missions section
    // (the fixture's campaign.txt graph), a fresh heap-owned campaign
    // (the derive writes names into the hubs slice - static fixtures
    // would crash), the mission table scan, the edge-table derive, the
    // graph checks. Mirrors loadCampaignAndPushHub's sequence.
    const runPipeline = struct {
        fn run(
            fs: *const file_source_mod.FileSource,
            alloc: std.mem.Allocator,
            missions_text: []const u8,
            start_hub: []const u8,
            hub_specs: []const [2][]const u8,
            sink: ?*std.ArrayList([]const u8),
        ) types.Campaign {
            const campaign_text = std.fmt.allocPrint(
                alloc,
                "Metadata\nfile_format_version 5\ncampaign_uuid cu\nstart_hub {s}\n\nMissions\n{s}",
                .{ start_hub, missions_text },
            ) catch @panic("format campaign fixture");
            defer alloc.free(campaign_text);
            const sections = parseConfigFile(campaign_text, alloc, &campaign_sections) catch
                @panic("parse campaign fixture");
            defer freeParsedSections(sections, alloc);
            var hubs: std.ArrayList(types.CampaignHub) = .empty;
            for (hub_specs, 0..) |spec, index| {
                hubs.append(alloc, .{
                    .uuid = dupeString(alloc, spec[0]),
                    .dir = dupeString(alloc, spec[1]),
                    .position = .{ .x = @intCast(index * 900), .y = 0 },
                }) catch @panic("append hub");
            }
            var campaign = types.Campaign{
                .dir = dupeString(alloc, "check"),
                .start_hub = dupeString(alloc, start_hub),
                .hubs = hubs.toOwnedSlice(alloc) catch @panic("own hubs"),
            };
            campaign.missions = resolveCampaignMissions(campaign, fs, alloc, sink);
            deriveCampaignEdges(&campaign, sections, fs, alloc, sink);
            checkCampaignGraph(campaign, alloc, sink);
            return campaign;
        }
    }.run;

    const clean_hubs = [_][2][]const u8{ .{ "start", "start" }, .{ "far", "far" } };
    const clean_missions = "mission_uuid u1\nstart_hub start\ndestination_hub far\n\nmission_uuid u2\nstart_hub far\ndestination_hub start\n";

    // Run 1 - clean: two edges (start -> far via u1, far -> start via
    // u2), both marked + fully wired, hub names denormalized, everything
    // resolving. A finalized campaign's shape: no stubs, no orphans, no
    // markerless missions.
    const clean = runPipeline(&file_source, allocator, clean_missions, "start", &clean_hubs, &warnings);
    try std.testing.expectEqual(@as(usize, 2), clean.edges.len);
    try std.testing.expectEqualStrings("Start", clean.hubs[0].name);
    try std.testing.expectEqualStrings("Far", clean.hubs[1].name);
    try std.testing.expectEqualStrings("start", clean.edges[0].from);
    try std.testing.expectEqualStrings("far", clean.edges[0].destination);
    try std.testing.expectEqualStrings("u1", clean.edges[0].mission_uuid);
    try std.testing.expect(std.mem.endsWith(u8, clean.edges[0].mission_dir, "missions/m1"));
    try std.testing.expectEqualStrings("M1", clean.edges[0].mission_name);
    try std.testing.expectEqual(@as(i32, 0), clean.edges[0].direction_degrees);
    try std.testing.expectEqual(@as(?u32, 0), clean.edges[0].exit_index);
    try std.testing.expectEqualStrings("far", clean.edges[1].from);
    try std.testing.expectEqualStrings("start", clean.edges[1].destination);
    try std.testing.expectEqual(@as(?u32, 0), clean.edges[1].exit_index);
    freeCampaign(clean, allocator);

    // Run 2 - a MARKERLESS edge: u1 started + destined, but start's hub
    // carries no marker for it. The edge derives anyway (exit_index null
    // - rendered on the map, not enterable) + one warning (unstartable:
    // a finalized campaign enters every mission through its marker).
    file_source.writeFile(
        "campaigns/check/hubs/start/hub.txt",
        "Metadata\nfile_format_version 5\nhub_uuid start\nname Start\n",
    ) catch @panic("strip start's markers");
    const markerless = runPipeline(&file_source, allocator, clean_missions, "start", &clean_hubs, &warnings);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "unstartable - no exit marker") != null);
    try std.testing.expectEqual(@as(usize, 2), markerless.edges.len);
    try std.testing.expectEqual(@as(?u32, null), markerless.edges[0].exit_index);
    freeCampaign(markerless, allocator);
    clearWarnings(&warnings, allocator);
    file_source.writeFile(
        "campaigns/check/hubs/start/hub.txt",
        "Metadata\nfile_format_version 5\nhub_uuid start\nname Start\n\nExits\ncharacter_code E\nmission_uuid u1\n",
    ) catch @panic("restore start's marker");

    // Run 2b - a dangling STUB: u2 with no destination_hub at all -
    // editor-intermediate state (the mission inspector's unattached
    // end), one warning (a finalized campaign wires every mission's
    // end).
    const stub = runPipeline(
        &file_source,
        allocator,
        "mission_uuid u1\nstart_hub start\ndestination_hub far\n\nmission_uuid u2\nstart_hub far\n",
        "start",
        &clean_hubs,
        &warnings,
    );
    freeCampaign(stub, allocator);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "no destination hub set (a dangling stub") != null);
    clearWarnings(&warnings, allocator);

    // Run 2c - an ORPHAN: u3 present in the campaign's missions/ but
    // with no start_hub - editor-honest intermediate state (a hub
    // deletion unwires its missions), one warning. The runtime edge
    // table never sees it (orphans are not gameplay).
    const orphan = runPipeline(
        &file_source,
        allocator,
        "mission_uuid u1\nstart_hub start\ndestination_hub far\n\nmission_uuid u2\nstart_hub far\ndestination_hub start\n\nmission_uuid u3\n",
        "start",
        &clean_hubs,
        &warnings,
    );
    freeCampaign(orphan, allocator);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "mission 'u3' has no start hub") != null);
    clearWarnings(&warnings, allocator);

    // Run 3 - a Missions entry whose start_hub names an unplaced hub:
    // warn + drop (an edge cannot render from nothing); far then goes
    // unreachable (u1 was the only path there).
    const unplaced_start = runPipeline(
        &file_source,
        allocator,
        "mission_uuid u1\nstart_hub nowhere\ndestination_hub far\n\nmission_uuid u2\nstart_hub far\ndestination_hub start\n",
        "start",
        &clean_hubs,
        &warnings,
    );
    freeCampaign(unplaced_start, allocator);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "start_hub 'nowhere' names an unplaced hub") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[1], "'far' is unreachable") != null);
    clearWarnings(&warnings, allocator);

    // Run 4 - a dangling destination (names an unplaced hub) + the now
    // unreachable far hub: two check warnings.
    const dangling = runPipeline(
        &file_source,
        allocator,
        "mission_uuid u1\nstart_hub start\ndestination_hub beyond\n\nmission_uuid u2\nstart_hub far\ndestination_hub start\n",
        "start",
        &clean_hubs,
        &warnings,
    );
    freeCampaign(dangling, allocator);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "'beyond' names an unplaced hub") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[1], "'far' is unreachable") != null);
    clearWarnings(&warnings, allocator);

    // Run 5 - a Missions entry whose mission does not resolve: m1's dir
    // removed. One warning; far stays reachable through start's edge.
    std.Io.Dir.cwd().deleteTree(io, scratch ++ "/campaigns/check/missions/m1") catch @panic("remove m1");
    const missing_mission = runPipeline(&file_source, allocator, clean_missions, "start", &clean_hubs, &warnings);
    freeCampaign(missing_mission, allocator);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "mission 'u1' from hub 'start' resolves to no mission") != null);
    clearWarnings(&warnings, allocator);
    file_source.writeFile("campaigns/check/missions/m1/mission.txt", "Metadata\nfile_format_version 3\nmission_uuid u1\nname M1\n") catch @panic("restore m1");

    // Run 6 - direction handling: three missions from start - unauthored,
    // an authored 42, and an unparsable (warns + fully unauthored). The
    // two unauthored share the circle among themselves: 360*0/2 = 0 and
    // 360*1/2 = 180. far keeps its single edge (default 0). The fixture
    // is otherwise fully wired + marked (this run is about DIRECTIONS -
    // the stub/orphan/markerless findings have their own runs above).
    file_source.writeFile(
        "campaigns/check/hubs/start/hub.txt",
        "Metadata\nfile_format_version 5\nhub_uuid start\nname Start\n\nExits\ncharacter_code E\nmission_uuid u1\n\ncharacter_code F\nmission_uuid u3\n\ncharacter_code G\nmission_uuid u4\n",
    ) catch @panic("write start's three markers");
    const directions = runPipeline(
        &file_source,
        allocator,
        "mission_uuid u1\nstart_hub start\ndestination_hub far\n\nmission_uuid u3\nstart_hub start\ndestination_hub far\ndirection 42\n\nmission_uuid u2\nstart_hub far\ndestination_hub start\n\nmission_uuid u4\nstart_hub start\ndestination_hub far\ndirection abc\n",
        "start",
        &clean_hubs,
        &warnings,
    );
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "unparsable direction") != null);
    clearWarnings(&warnings, allocator);
    try std.testing.expectEqual(@as(usize, 4), directions.edges.len);
    try std.testing.expectEqual(@as(i32, 0), directions.edges[0].direction_degrees);
    try std.testing.expectEqual(@as(i32, 42), directions.edges[1].direction_degrees);
    try std.testing.expectEqual(@as(i32, 180), directions.edges[2].direction_degrees);
    try std.testing.expectEqual(@as(i32, 0), directions.edges[3].direction_degrees);
    freeCampaign(directions, allocator);

    // Run 7 - duplicate markers for one mission: warn + the first wins.
    file_source.writeFile(
        "campaigns/check/hubs/start/hub.txt",
        "Metadata\nfile_format_version 5\nhub_uuid start\nname Start\n\nExits\ncharacter_code E\nmission_uuid u1\n\ncharacter_code F\nmission_uuid u1\n",
    ) catch @panic("duplicate markers");
    const duplicate_markers = runPipeline(&file_source, allocator, clean_missions, "start", &clean_hubs, &warnings);
    freeCampaign(duplicate_markers, allocator);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "multiple markers for mission 'u1'") != null);
    clearWarnings(&warnings, allocator);
    file_source.writeFile(
        "campaigns/check/hubs/start/hub.txt",
        "Metadata\nfile_format_version 5\nhub_uuid start\nname Start\n\nExits\ncharacter_code E\nmission_uuid u1\n",
    ) catch @panic("restore start's marker");

    // Run 8 - a null warnings sink is a no-op through the whole pipeline.
    const null_sink = runPipeline(&file_source, allocator, clean_missions, "start", &clean_hubs, null);
    freeCampaign(null_sink, allocator);
}

/// Free + clear a test warnings list (each message is allocator-owned -
/// appendWarning's contract).
fn clearWarnings(warnings: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    for (warnings.items) |warning| allocator.free(warning);
    warnings.clearRetainingCapacity();
}

test "loadMission parses mission metadata (self-owned; hub endpoints + level count are gone)" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 3
        \\mission_uuid 11111111-1111-1111-1111-111111111111
        \\name First Mission
    ;

    const sections = try parseConfigFile(raw_text, allocator, &mission_sections);

    const mission = try loadMission(sections, allocator);
    // Ownership contract: free the parse bytes BEFORE reading the mission.
    freeParsedSections(sections, allocator);

    try std.testing.expectEqualStrings("11111111-1111-1111-1111-111111111111", mission.uuid);
    try std.testing.expectEqualStrings("First Mission", mission.name);
    // The hub endpoints + level count are no longer mission data: the
    // campaign graph owns the edge (the exit's destination_hub rides
    // start_mission.end_hub_id), and the level count derives from the
    // dir's files. All three default empty/zero here.
    try std.testing.expect(mission.end_hub == null);
    try std.testing.expectEqual(@as(u32, 0), mission.level_count);

    freeMission(mission, allocator);
}

test "loadPlayerSave parses a save file" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 3
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

    const sections = try parseConfigFile(raw_text, allocator, &player_save_sections);
    defer freeParsedSections(sections, allocator);

    const player_data = try loadPlayerSave(sections, allocator, "", null);
    defer allocator.free(player_data.learned_skills);
    defer allocator.free(player_data.clones);
    defer {
        for (player_data.discovered_hubs) |group| allocator.free(group.hub_uuids);
        allocator.free(player_data.discovered_hubs);
    }

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

    // Inventory - items at slots 1 and 2
    try std.testing.expect(player_data.inventory.slots[1] != null);
    try std.testing.expect(player_data.inventory.slots[2] != null);
    try std.testing.expectEqualStrings("Rusty Dagger", player_data.inventory.slots[1].?.weapon.name);
    try std.testing.expectEqualStrings("Old Coat", player_data.inventory.slots[2].?.coat.name);

    // Utility skills - first slot is replenish, rest are defaults
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

    const sections = try parseConfigFile(raw_text, allocator, &color_theme_sections);
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
            .colors = @splat(Color{ .r = value, .g = value, .b = value }),
        };
    }

    const theme = ColorThemeDefinitions{
        .lightest = .{ .r = 255, .g = 255, .b = 240 },
        .darkest = .{ .r = 20, .g = 15, .b = 25 },
        .gradients = &gradients,
    };

    // With world at index 0, enemy at 3, player at 6 (auto-derivation)
    const auto = deriveActiveColorTheme(theme, 0, null, null);
    try std.testing.expectEqual(10, auto.world_gradient.colors[0].r); // gradient 0
    try std.testing.expectEqual(70, auto.enemy_gradient.colors[0].r); // gradient 3
    try std.testing.expectEqual(130, auto.player_gradient.colors[0].r); // gradient 6

    // Overrides name specific gradients (enemy 8, player 1); indices wrap
    // modulo the gradient count like the world index does.
    const overridden = deriveActiveColorTheme(theme, 2, 8, 1);
    try std.testing.expectEqual(50, overridden.world_gradient.colors[0].r); // gradient 2
    try std.testing.expectEqual(170, overridden.enemy_gradient.colors[0].r); // gradient 8
    try std.testing.expectEqual(30, overridden.player_gradient.colors[0].r); // gradient 1
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
        &color_theme_sections,
    );
    defer allocator.free(parsed.raw_text);
    defer freeParsedSections(parsed.sections, allocator);

    const theme = try loadColorThemeDefinitions(parsed.sections, allocator);
    defer allocator.free(theme.gradients);

    // The full color wheel: 24 gradients, clockwise from the top spoke
    // (index 0 = the wheel's top; see DESIGN → Entity & UI Coloring).
    try std.testing.expectEqual(24, theme.gradients.len);

    // Lightest and darkest should be parsed
    try std.testing.expectEqual(0xff, theme.lightest.r);
    try std.testing.expectEqual(0x4c, theme.darkest.r);
}

test "color themes: a gradient_index mismatch InvalidData leaks nothing" {
    // The error-path ownership contract (the arena-blind-spot lesson):
    // the error must fire AFTER the first gradient is appended, and the
    // errdefer must free the partial list - testing.allocator flags any
    // leak.
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\
        \\Gradients
        \\
        \\gradient_index 0
        \\color_0 #f6f6bb
        \\
        \\gradient_index 2
        \\color_0 #f2ef90
    ;
    const sections = try parseConfigFile(raw_text, allocator, &color_theme_sections);
    defer freeParsedSections(sections, allocator);
    try std.testing.expectError(
        error.InvalidData,
        loadColorThemeDefinitions(sections, allocator),
    );
}

// ============================================================
// Salvage definitions
// ============================================================

fn parseSalvageSplits(
    section: Section,
    allocator: std.mem.Allocator,
) !SalvageDefinition {
    if (section.entry_groups.len == 0) return .{ .splits = &.{} };

    var splits: std.ArrayList(SalvageSplit) = .empty;
    // Partial-list cleanup on InvalidData mid-list (an unknown material or
    // unparsable value after earlier valid entries) - items are value
    // types, so deinit alone frees everything. OOM panics inline (the
    // config-layer convention - DESIGN → Error Handling) and skips
    // errdefer: the dying process owns the partial build.
    errdefer splits.deinit(allocator);
    for (section.entry_groups) |group| {
        for (group.pairs) |pair| {
            const material = parseEnum(MaterialType, pair.key) orelse return error.InvalidData;
            const parts = asU32(pair.value) orelse return error.InvalidData;
            splits.append(allocator, .{
                .material = material,
                .parts = parts,
            }) catch @panic("failed to append salvage split");
        }
    }

    return .{
        .splits = splits.toOwnedSlice(allocator) catch @panic("failed to own salvage splits slice"),
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
    const weapon_type_field_names = @typeInfo(WeaponType).@"enum".field_names;
    // Empty-split defaults: an unfilled slot's free is a no-op, so the
    // errdefer can sweep the whole array even when an error fires
    // partway through the fill.
    var weapon_definitions: [types.weapon_type_count]SalvageDefinition =
        @as([types.weapon_type_count]SalvageDefinition, @splat(.{ .splits = &.{} }));
    errdefer {
        for (weapon_definitions) |definition| allocator.free(definition.splits);
    }

    inline for (weapon_type_field_names, 0..) |field_name, index| {
        const capitalized = comptime blk: {
            var name: [field_name.len]u8 = undefined;
            @memcpy(&name, field_name);
            name[0] = std.ascii.toUpper(name[0]);
            break :blk name;
        };
        weapon_definitions[index] = try loadWeaponSalvage(sections, &capitalized, allocator);
    }

    // The gear/skill-tome sections in declaration order. A missing later
    // section is InvalidData AFTER the earlier sections' splits are
    // already owned - the errdefer sweeps both arrays (weapon + the
    // partial gear fill).
    const gear_headers = .{ "Amulet", "Coat", "Gloves", "Pants", "Boots", "SkillTome" };
    var gear_definitions: [gear_headers.len]SalvageDefinition =
        @as([gear_headers.len]SalvageDefinition, @splat(.{ .splits = &.{} }));
    errdefer {
        for (gear_definitions) |definition| allocator.free(definition.splits);
    }
    inline for (gear_headers, 0..) |header, index| {
        gear_definitions[index] = try parseSalvageSplits(
            findSection(sections, header) orelse return error.InvalidData,
            allocator,
        );
    }

    return .{
        .weapon = weapon_definitions,
        .amulet = gear_definitions[0],
        .coat = gear_definitions[1],
        .gloves = gear_definitions[2],
        .pants = gear_definitions[3],
        .boots = gear_definitions[4],
        .skill_tome = gear_definitions[5],
    };
}

test "salvage: InvalidData mid-list leaks nothing (parseSalvageSplits)" {
    // The error-path ownership contract: the unknown material key fires
    // AFTER two valid splits were appended - the errdefer must free the
    // partial list, testing.allocator flags any leak.
    const allocator = std.testing.allocator;
    const raw_text =
        \\Sword
        \\
        \\metal 2
        \\wood 1
        \\
        \\unobtainium 5
    ;
    const sections = try parseConfigFile(raw_text, allocator, &parser.salvage_sections);
    defer freeParsedSections(sections, allocator);
    try std.testing.expectError(
        error.InvalidData,
        parseSalvageSplits(sections[0], allocator),
    );
}

test "salvage: a missing gear section InvalidData leaks nothing (loadSalvageDefinitions)" {
    // Sword + Amulet parse (owned splits), then no Coat section: the
    // error must free the weapon + amulet splits on the way out.
    const allocator = std.testing.allocator;
    const raw_text =
        \\Sword
        \\
        \\metal 2
        \\
        \\Amulet
        \\
        \\cloth 1
    ;
    const sections = try parseConfigFile(raw_text, allocator, &parser.salvage_sections);
    defer freeParsedSections(sections, allocator);
    try std.testing.expectError(
        error.InvalidData,
        loadSalvageDefinitions(sections, allocator),
    );
}

/// Load the tips file (data/tips.txt): one self-owned prose string per
/// `tip` pair in the Tips section, in file order. Freed by `freeTips`.
/// Production retains the bytes + sections process-lifetime
/// (loadConfigWithFallback); tests free via `freeTips` under
/// `testing.allocator`.
pub fn loadTips(
    sections: []const Section,
    allocator: std.mem.Allocator,
) ![]const []const u8 {
    _ = try validateFileFormatVersion(
        sections,
        "Metadata",
        parser.tips_file_format_version,
        parser.tips_file_format_version,
    );
    const tips_section = findSection(sections, "Tips") orelse return error.MissingTipsSection;
    var tips: std.ArrayList([]const u8) = .empty;
    // Error-path ownership: dupeString panics on OOM (the config-layer
    // convention - DESIGN → Error Handling); the errdefer covers the
    // input-error returns (version gate fires before allocation;
    // MissingTipsSection fires before the list exists).
    errdefer {
        for (tips.items) |tip| allocator.free(tip);
        tips.deinit(allocator);
    }
    for (tips_section.entry_groups) |group| {
        for (group.pairs) |pair| {
            if (std.mem.eql(u8, pair.key, "tip")) {
                tips.append(allocator, dupeString(allocator, pair.value)) catch
                    @panic("failed to append tip");
            }
        }
    }
    return tips.toOwnedSlice(allocator);
}

/// Free a tips list from `loadTips`.
pub fn freeTips(
    tips: []const []const u8,
    allocator: std.mem.Allocator,
) void {
    for (tips) |tip| allocator.free(tip);
    allocator.free(tips);
}

test "loadTips parses the shipped tips file; ownership is self-owned" {
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    const parsed = try parseConfigFileFromPath(
        &file_source,
        "data/tips.txt",
        allocator,
        &parser.tips_sections,
    );

    const tips = try loadTips(parsed.sections, allocator);
    // Ownership contract: free the parse BEFORE the assertions (no
    // borrows by construction) + the free is leak-checked under
    // testing.allocator.
    freeParsedSections(parsed.sections, allocator);
    allocator.free(parsed.raw_text);
    defer freeTips(tips, allocator);

    // The file grows by design (tips are authored content) - assert
    // existence + a known tip by SEARCH, not by index or count.
    try std.testing.expect(tips.len > 0);
    var found_move_step_tip = false;
    for (tips) |tip| {
        try std.testing.expect(tip.len > 0);
        if (std.mem.indexOf(u8, tip, "move step") != null) found_move_step_tip = true;
    }
    try std.testing.expect(found_move_step_tip);
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
        &settings_sections,
    );
    defer allocator.free(parsed.raw_text);
    defer freeParsedSections(parsed.sections, allocator);

    const settings = try loadSettings(parsed.sections, allocator, null, null);
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
    specs: []const struct {
        key: []const u8,
        ctrl: bool = false,
        action: types.Action,
    },
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
    // DEFAULT bindings (injected) - so a new official binding reaches
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
    // aliases them otherwise) - only the merged result is freed here (same
    // ownership shape as the session_setup overlay test).

    // User file mentions ONLY skip (rebound to Enter) - e.g. an old install
    // whose file predates the dump_event_log + undo defaults.
    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name Enter
        \\action skip
        \\context game
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    const merged = try loadSettings(sections, allocator, base, null);
    defer freeSettings(merged, allocator);

    // The user's rebinding of skip wins (Enter), and the default Space→skip
    // is NOT carried over (mentioned = user-authoritative).
    try std.testing.expectEqual(@as(usize, 3), merged.input_bindings.len);
    // The user's skip binding is the ONLY skip binding (Enter, not the
    // default Space) - mentioned means user-authoritative, not additive.
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
    // loadSettings consumes the base's bindings - free merged only.

    // The post-write file: skip (still default) + dump_event_log (still
    // default) - the exact content writeSettings would emit after injection.
    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name Space
        \\action skip
        \\context game
        \\
        \\input_type key
        \\input_name L
        \\ctrl true
        \\action dump_event_log
        \\context anytime
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    const merged = try loadSettings(sections, allocator, base, null);
    defer freeSettings(merged, allocator);

    // Exactly the user file's two bindings - no duplicate injection.
    try std.testing.expectEqual(@as(usize, 2), merged.input_bindings.len);
}

test "loadSettings accepts a context-less binding (contexts are derived)" {
    // The `context` line is optional + informational - a binding's active
    // contexts are DERIVED from the action (`actionBindingContexts`); the
    // loader ignores the line entirely. A pre-migration context-less user
    // file therefore loads as-is (no drop, no warning). See DESIGN → Input
    // → Binding contexts.
    const allocator = std.testing.allocator;

    const base = Settings{
        .input_bindings = try testOwnedBindings(allocator, &.{
            .{ .key = "Space", .action = .skip },
        }),
    };
    // loadSettings consumes the base's bindings on replace - free merged only.

    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name Enter
        \\action skip
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |message| allocator.free(message);
        warnings.deinit(allocator);
    }
    const merged = try loadSettings(sections, allocator, base, &warnings);
    defer freeSettings(merged, allocator);

    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    // The user's rebinding is authoritative - skip bound to Enter, the
    // default (Space) replaced, nothing dropped.
    try std.testing.expectEqual(@as(usize, 1), merged.input_bindings.len);
    try std.testing.expectEqual(.skip, merged.input_bindings[0].action);
    try std.testing.expectEqualStrings("Enter", merged.input_bindings[0].input.key);
}

test "loadSettings ignores the binding context line (contexts are derived)" {
    // `context game` on an editor-context action - under the OLD authored-
    // context model this was a dead binding (warned + dropped); with derived
    // contexts the line is ignored and the binding's active contexts come
    // from `actionBindingContexts` (select_editor_tool → editor). The
    // engine's context gate (checkAction) is where that lands - covered by
    // the editor-inactive-on-level tests in input.zig. See DESIGN → Input →
    // Binding contexts.
    const allocator = std.testing.allocator;

    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name KeyZ
        \\action select_editor_tool
        \\context game
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |message| allocator.free(message);
        warnings.deinit(allocator);
    }
    const settings = try loadSettings(sections, allocator, null, &warnings);
    defer freeSettings(settings, allocator);

    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqual(@as(usize, 1), settings.input_bindings.len);
    try std.testing.expectEqual(.select_editor_tool, settings.input_bindings[0].action);
}

test "loadSettings warns + drops a conflicting combo (same context, different actions)" {
    // One combo fires ONE action per context: Enter bound to confirm AND
    // skip (both game-context actions) would co-fire. The first listed
    // wins; the later entry is warned + dropped. See DESIGN → Input →
    // Hybrid precedence + binding conflicts.
    const allocator = std.testing.allocator;

    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name Enter
        \\action confirm
        \\context game
        \\
        \\input_type key
        \\input_name Enter
        \\action skip
        \\context game
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |message| allocator.free(message);
        warnings.deinit(allocator);
    }
    const settings = try loadSettings(sections, allocator, null, &warnings);
    defer freeSettings(settings, allocator);

    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "already fires") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "confirm") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "skip") != null);
    // First listed wins - confirm kept, the skip binding dropped.
    try std.testing.expectEqual(@as(usize, 1), settings.input_bindings.len);
    try std.testing.expectEqual(.confirm, settings.input_bindings[0].action);
}

test "loadSettings warns + drops a duplicate combo (same action twice)" {
    // Same combo on the SAME action is redundant, not conflicting - but the
    // file should carry one entry per combo; the later duplicate is warned
    // + dropped (the repair write cleans it).
    const allocator = std.testing.allocator;

    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name Enter
        \\action confirm
        \\context game
        \\
        \\input_type key
        \\input_name Enter
        \\action confirm
        \\context game
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |message| allocator.free(message);
        warnings.deinit(allocator);
    }
    const settings = try loadSettings(sections, allocator, null, &warnings);
    defer freeSettings(settings, allocator);

    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "duplicates") != null);
    try std.testing.expectEqual(@as(usize, 1), settings.input_bindings.len);
    try std.testing.expectEqual(.confirm, settings.input_bindings[0].action);
}

test "loadSettings keeps cross-context same-combo bindings (no conflict)" {
    // Overlap ACROSS contexts is legal (Digit1 = skill 1 in game, select
    // tool in editor - never simultaneously active). Also covers modifier-
    // distinguished combos on one key: plain Enter (confirm) + ctrl Enter
    // (skip) are different combos. Neither pair warns or drops. See
    // DESIGN → Input → Hybrid precedence + binding conflicts.
    const allocator = std.testing.allocator;

    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name Digit1
        \\action skill_slot_1
        \\context game
        \\
        \\input_type key
        \\input_name Digit1
        \\action editor_select_tool
        \\context editor
        \\
        \\input_type key
        \\input_name Enter
        \\action confirm
        \\context game
        \\
        \\input_type key
        \\input_name Enter
        \\ctrl true
        \\action skip
        \\context game
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |message| allocator.free(message);
        warnings.deinit(allocator);
    }
    const settings = try loadSettings(sections, allocator, null, &warnings);
    defer freeSettings(settings, allocator);

    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqual(@as(usize, 4), settings.input_bindings.len);
}

test "loadSettings: a user combo colliding with an injected default drops the default silently" {
    // The no-popup-loop contract: the user bound Enter to skip; the
    // per-action injection still injects confirm's default (Enter -
    // confirm is unmentioned in the user file), and the conflict scan
    // drops the INJECTED default. It must drop SILENTLY: nothing in the
    // user's file is wrong, and the injection re-runs every launch - a
    // warning would pop the same message every launch with nothing to
    // repair (the repair write can't remove an injection). See DESIGN →
    // Input → Hybrid precedence + binding conflicts.
    const allocator = std.testing.allocator;

    // Defaults: confirm → Enter, skip → Space.
    const base = Settings{
        .input_bindings = try testOwnedBindings(allocator, &.{
            .{ .key = "Enter", .action = .confirm },
            .{ .key = "Space", .action = .skip },
        }),
    };
    // loadSettings consumes the base's bindings on replace - free merged only.

    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name Enter
        \\action skip
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |message| allocator.free(message);
        warnings.deinit(allocator);
    }
    const merged = try loadSettings(sections, allocator, base, &warnings);
    defer freeSettings(merged, allocator);

    // Silent: no warning (and therefore no repair-write trigger).
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    // The user's rebinding wins; the injected confirm default is gone.
    try std.testing.expectEqual(@as(usize, 1), merged.input_bindings.len);
    try std.testing.expectEqual(.skip, merged.input_bindings[0].action);
    try std.testing.expectEqualStrings("Enter", merged.input_bindings[0].input.key);
}

test "loadSettings warns + drops a binding naming an unknown action" {
    const allocator = std.testing.allocator;

    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name KeyZ
        \\action no_such_action
        \\context anytime
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |message| allocator.free(message);
        warnings.deinit(allocator);
    }
    const settings = try loadSettings(sections, allocator, null, &warnings);
    defer freeSettings(settings, allocator);

    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "unknown action") != null);
    try std.testing.expectEqual(@as(usize, 0), settings.input_bindings.len);
}

test "loadSettings without an InputBindings section keeps the base bindings untouched" {
    // A user file that only touches scalars (no bindings section) leaves the
    // defaults in place - the injection lives in the bindings branch only.
    const allocator = std.testing.allocator;

    const base = Settings{
        .input_bindings = try testOwnedBindings(allocator, &.{
            .{ .key = "Space", .action = .skip },
        }),
    };
    // No InputBindings section → the base's bindings are aliased into the
    // merged result (not consumed) - free merged only.

    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\Audio
        \\master_volume 40
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    const merged = try loadSettings(sections, allocator, base, null);
    defer freeSettings(merged, allocator);

    try std.testing.expectEqual(@as(u32, 40), merged.master_volume);
    try std.testing.expectEqual(@as(usize, 1), merged.input_bindings.len);
    try std.testing.expectEqual(.skip, merged.input_bindings[0].action);
}

test "entity utility slots: a weapon skill is warned + dropped, utility skills kept" {
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
        \\Entities
        \\character_code 1
        \\name Skeleton
        \\slot_4 slice
        \\slot_5 blink
        \\
        \\Decorations
        \\
        \\Items
    ;

    const sections = try parseConfigFile(raw_text, allocator, &level_sections);
    defer freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer warnings.deinit(allocator);
    const level = try loadLevel(sections, null, allocator, "level.txt", &warnings);
    defer freeLevel(level, allocator);

    // The enemy is entity index 1 (the player is 0). slot_4 (slice, a
    // weapon skill) dropped; slot_5 (blink, a cantrip) kept.
    try std.testing.expectEqual(null, level.entities[1].equipped_utility_skills[0]);
    try std.testing.expectEqual(types.SkillId.blink, level.entities[1].equipped_utility_skills[1]);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "slice") != null);
    for (warnings.items) |w| allocator.free(w);
}

test "loadPlayerLoadout: save-shaped player.txt - loadout fields, default stats, name defaults to Player" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\MainHandWeapon
        \\item_name Starter Sword
        \\weapon_type sword
        \\damage 3
        \\
        \\Inventory
        \\slot 0
        \\item_type weapon
        \\item_name Spare Dagger
        \\weapon_type dagger
        \\damage 1
        \\
        \\UtilitySkills
        \\slot_4 replenish
        \\
    ;

    const sections = try parseConfigFile(raw_text, allocator, &player_loadout_sections);
    defer freeParsedSections(sections, allocator);

    const template = try loadPlayerLoadout(sections, allocator, "player.txt", null);

    // The loadout fields map onto the template (build_player_from_data's
    // set); the name defaults (the loadout sections carry none).
    try std.testing.expectEqualStrings("Player", template.name);
    try std.testing.expectEqualStrings("player", template.sprite);
    try std.testing.expectEqualStrings("Starter Sword", template.main_hand_weapon.?.name);
    try std.testing.expectEqualStrings("Spare Dagger", template.inventory.slots[0].?.weapon.name);
    try std.testing.expectEqual(types.SkillId.replenish, template.equipped_utility_skills[0]);
    // Base stats are NOT authorable - the Entity defaults hold.
    try std.testing.expectEqual(@as(u32, 20), template.max_health);
    try std.testing.expectEqual(@as(u32, 0), template.defense);
    try std.testing.expectEqual(@as(u32, 1), template.speed);
    try std.testing.expectEqual(@as(u32, 3), template.aggro_range);
}

test "loadPlayerLoadout: the v1 PlayerLoadout format is rejected" {
    const allocator = std.testing.allocator;
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\
        \\PlayerLoadout
        \\name Player
        \\
    ;

    // The per-format header grammar rejects the old format's PlayerLoadout
    // header at the PARSE (UnknownSectionHeader) - not a loadout section,
    // so no list recognizes it.
    try std.testing.expectError(
        error.UnknownSectionHeader,
        parseConfigFile(raw_text, allocator, &player_loadout_sections),
    );
}

test "data/max_player.txt parses: max gear equipped, weapons in inventory, all skills learned, hub discovered" {
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    const parsed = try parseConfigFileFromPath(&file_source, "data/max_player.txt", allocator, &player_save_sections);
    defer allocator.free(parsed.raw_text);
    defer freeParsedSections(parsed.sections, allocator);

    const player_data = try loadPlayerSave(parsed.sections, allocator, "", null);
    defer allocator.free(player_data.learned_skills);
    defer allocator.free(player_data.clones);
    defer {
        for (player_data.discovered_hubs) |group| allocator.free(group.hub_uuids);
        allocator.free(player_data.discovered_hubs);
    }

    try std.testing.expectEqualStrings("New Player", player_data.player_name);
    // No weapons or utility skills EQUIPPED - the arsenal is inventory + learned.
    try std.testing.expect(player_data.main_hand_weapon == null);
    try std.testing.expect(player_data.off_hand_weapon == null);
    for (player_data.equipped_utility_skills) |slot| try std.testing.expect(slot == null);
    // The five armor slots at the max_* bounds.
    try std.testing.expectEqual(types.max_spell_damage, player_data.amulet.?.spell_damage);
    try std.testing.expectEqual(types.max_defense_bonus, player_data.coat.?.defense_bonus);
    try std.testing.expectEqual(types.max_health_bonus, player_data.coat.?.health_bonus);
    try std.testing.expectEqual(types.max_gloves_damage, player_data.gloves.?.damage_bonus);
    try std.testing.expectEqual(types.max_pickup_radius, player_data.pants.?.pickup_radius_bonus);
    try std.testing.expectEqual(types.max_boots_speed, player_data.boots.?.speed_bonus);
    // Two of each weapon type in the inventory, all at max damage.
    var weapon_counts: [@typeInfo(types.WeaponType).@"enum".field_names.len]u32 = @splat(0);
    var inventory_items: u32 = 0;
    for (player_data.inventory.slots) |maybe_item| {
        const item = maybe_item orelse continue;
        inventory_items += 1;
        switch (item) {
            .weapon => |weapon| {
                try std.testing.expectEqual(types.max_weapon_damage, weapon.weapon_damage);
                weapon_counts[@intCast(@backingInt(weapon.weapon_type))] += 1;
            },
            else => return error.TestUnexpectedItem,
        }
    }
    try std.testing.expectEqual(@as(u32, 12), inventory_items);
    for (weapon_counts) |count| try std.testing.expectEqual(@as(u32, 2), count);
    // Every utility skill learned; the campaign's hub discovered.
    try std.testing.expectEqual(@as(usize, 7), player_data.learned_skills.len);
    try std.testing.expectEqual(@as(usize, 1), player_data.discovered_hubs.len);
    try std.testing.expectEqual(@as(usize, 1), player_data.discovered_hubs[0].hub_uuids.len);
    try std.testing.expectEqualStrings(
        "03aeefda-c68b-4853-b65a-d46edb9790f1",
        player_data.discovered_hubs[0].hub_uuids[0],
    );

    // The editor fallback maps it onto the player template.
    const template = playerLoadoutEntity(player_data);
    try std.testing.expectEqualStrings("New Player", template.name);
    try std.testing.expect(template.main_hand_weapon == null);
    try std.testing.expectEqual(types.max_spell_damage, template.amulet.?.spell_damage);
    try std.testing.expectEqual(@as(u32, 12), blk: {
        var count: u32 = 0;
        for (template.inventory.slots) |maybe_item| {
            if (maybe_item != null) count += 1;
        }
        break :blk count;
    });
}

test "the shipped beginnings player.txt loads in the save-shaped format" {
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    const parsed = try parseConfigFileFromPath(
        &file_source,
        "campaigns/main_campaign/missions/beginnings/player.txt",
        allocator,
        &player_loadout_sections,
    );
    defer allocator.free(parsed.raw_text);
    defer freeParsedSections(parsed.sections, allocator);

    const template = try loadPlayerLoadout(parsed.sections, allocator, "player.txt", null);
    try std.testing.expectEqualStrings("Player", template.name);
    try std.testing.expectEqualStrings("Starter Sword", template.main_hand_weapon.?.name);
    try std.testing.expectEqual(@as(u32, 3), template.main_hand_weapon.?.weapon_damage);
    try std.testing.expectEqualStrings("Starter Shield", template.off_hand_weapon.?.name);
    try std.testing.expectEqualStrings("Starter Amulet", template.amulet.?.name);
    try std.testing.expectEqual(types.SkillId.replenish, template.equipped_utility_skills[0]);
}

test "loadLevel parses per-role gradient overrides, absent keys auto-derive" {
    // Arena-wrapped: the instantiateEditorLevel result at the end is not
    // freed (a separate ownership ride); buildEditorMission itself is
    // self-owned now (freeEditorBuild) - see AGENTS → Testing discipline
    // for the arena policy.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const allocator = backing.allocator();
    const raw_text =
        \\Metadata
        \\file_format_version 1
        \\name Themed
        \\color_wheel_index 2
        \\enemy_gradient_index 5
        \\player_gradient_index 0
        \\
        \\Layout
        \\!.
        \\.=
        \\
        \\Entities
        \\
        \\Decorations
        \\
        \\Items
    ;

    const sections = try parseConfigFile(raw_text, allocator, &level_sections);
    defer freeParsedSections(sections, allocator);

    const level = try loadLevel(sections, null, allocator, "", null);
    defer freeLevel(level, allocator);

    try std.testing.expectEqual(@as(u32, 2), level.color_wheel_index);
    try std.testing.expectEqual(@as(?u32, 5), level.enemy_gradient_index);
    try std.testing.expectEqual(@as(?u32, 0), level.player_gradient_index);

    // Absent keys = null (auto-derive from the world index).
    const plain_text =
        \\Metadata
        \\file_format_version 1
        \\name Plain
        \\
        \\Layout
        \\!.
        \\.=
        \\
        \\Entities
        \\
        \\Decorations
        \\
        \\Items
    ;
    const plain_sections = try parseConfigFile(plain_text, allocator, &level_sections);
    defer freeParsedSections(plain_sections, allocator);
    const plain_level = try loadLevel(plain_sections, null, allocator, "", null);
    defer freeLevel(plain_level, allocator);
    try std.testing.expectEqual(@as(?u32, null), plain_level.enemy_gradient_index);
    try std.testing.expectEqual(@as(?u32, null), plain_level.player_gradient_index);

    // The overrides round-trip through the editor shapes: loadLevel →
    // buildEditorMission's EditorLevel → instantiateEditorLevel's Level.
    const mission = types.Mission{ .name = "M", .level_count = 1 };
    const parsed_levels = [_][]const Section{sections};
    const editor = try buildEditorMission(mission, .{}, parsed_levels[0..], null, allocator, "", null);
    try std.testing.expectEqual(@as(?u32, 5), editor.levels[0].enemy_gradient_index);
    try std.testing.expectEqual(@as(?u32, 0), editor.levels[0].player_gradient_index);

    const instantiated = instantiateEditorLevel(editor, 0, allocator);
    try std.testing.expectEqual(@as(?u32, 5), instantiated.enemy_gradient_index);
    try std.testing.expectEqual(@as(?u32, 0), instantiated.player_gradient_index);
    try std.testing.expectEqual(@as(u32, 2), instantiated.color_wheel_index);
}

test "loadSettings warns (keeps) a binding naming an unproducible input id" {
    // The dead-binding advisory (the missing-Escape regression's class): a
    // binding naming an id no platform table can produce can never fire.
    // Warned - with the exact failure mode - but KEPT (dropping would lose
    // the entry; the id may be valid on another platform or a future
    // table). The popup deliberately repeats until the file names a
    // producible id. See `types.producible_key_ids`.
    const allocator = std.testing.allocator;

    const raw_text =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name Escapee
        \\action escape
    ;
    const sections = try parseConfigFile(raw_text, allocator, &settings_sections);
    defer freeParsedSections(sections, allocator);

    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |message| allocator.free(message);
        warnings.deinit(allocator);
    }
    const settings = try loadSettings(sections, allocator, null, &warnings);
    defer freeSettings(settings, allocator);

    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "can never fire") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings.items[0], "Escapee") != null);
    // Kept, not dropped - the advisory leaves the entry in place.
    try std.testing.expectEqual(@as(usize, 1), settings.input_bindings.len);
    try std.testing.expectEqual(.escape, settings.input_bindings[0].action);
}
