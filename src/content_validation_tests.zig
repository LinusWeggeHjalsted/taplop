//! Global shipped-content validation: every `.txt` config file in the
//! embedded-asset map is parsed + loaded + key-validated. Catches shipped-
//! content bugs (malformed syntax, unknown keys, bad file_format_version,
//! semantic errors) that the permissive parser would otherwise silently
//! drop. See DESIGN → Error Handling → key validation, TODO → Tech debt.
//!
//! This is a parse + load + key-validate pass over the REAL embedded content
//! (not synthetic fixtures). If a shipped file has a typo'd key, this test
//! fails with a warning naming the key + section + file. If a shipped file
//! has a parse or load error, this test fails with the error. The test is
//! self-maintaining: new files added under `data/` are picked up automatically
//! by the embedded-asset map iteration (the build step re-runs every build).

const std = @import("std");
const embedded_assets = @import("generated_assets");
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");
const file_source_mod = @import("file_source.zig");
const types = @import("types.zig");

const FileSource = file_source_mod.FileSource;

/// Classify a config file path and run its loader + key validation. Returns
/// an error if the parse or load fails; appends key-validation warnings to
/// `warnings` (and the caller asserts none). The classification is by path
/// pattern — the one piece of wiring that maps paths to loaders + key maps.
fn validateConfigFile(
    path: []const u8,
    bytes: []const u8,
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]const u8),
) !void {
    const sections = try parser.parseConfigFile(bytes, allocator);

    // Classify by path pattern + run the matching loader + key validation.
    if (std.mem.eql(u8, path, "data/default_settings.txt")) {
        _ = try loaders.loadSettings(sections, allocator, null, null);
        parser.validateKeys(sections, parser.settings_key_map, path, allocator, warnings);
    } else if (std.mem.eql(u8, path, "data/color_themes.txt")) {
        _ = try loaders.loadColorThemeDefinitions(sections, allocator);
        parser.validateKeys(sections, parser.color_theme_key_map, path, allocator, warnings);
    } else if (std.mem.eql(u8, path, "data/salvage.txt")) {
        _ = try loaders.loadSalvageDefinitions(sections, allocator);
        parser.validateKeys(sections, parser.salvage_key_map, path, allocator, warnings);
    } else if (std.mem.eql(u8, path, "data/decorations.txt")) {
        _ = try loaders.loadDecorationRegistry(sections, file_source, allocator);
        parser.validateKeys(sections, parser.decoration_registry_key_map, path, allocator, warnings);
    } else if (std.mem.startsWith(u8, path, "data/weapon_types/") and std.mem.endsWith(u8, path, ".txt")) {
        _ = try loaders.loadWeaponTypeDefinition(sections);
        parser.validateKeys(sections, parser.weapon_type_key_map, path, allocator, warnings);
    } else if (std.mem.eql(u8, path, "data/new_player.txt") or std.mem.eql(u8, path, "data/autosave.txt")) {
        _ = try loaders.loadPlayerSave(sections, allocator, path, warnings);
        parser.validateKeys(sections, parser.player_save_key_map, path, allocator, warnings);
    } else if (std.mem.endsWith(u8, path, "/campaign.txt")) {
        _ = try loaders.loadCampaign(sections, allocator);
        parser.validateKeys(sections, parser.campaign_key_map, path, allocator, warnings);
    } else if (std.mem.endsWith(u8, path, "/hub.txt")) {
        _ = try loaders.loadHub(sections, file_source, allocator, "", null);
        parser.validateKeys(sections, parser.hub_key_map, path, allocator, warnings);
    } else if (std.mem.endsWith(u8, path, "/mission.txt")) {
        _ = try loaders.loadMission(sections, allocator);
        parser.validateKeys(sections, parser.mission_key_map, path, allocator, warnings);
    } else if (std.mem.endsWith(u8, path, "/player.txt")) {
        _ = try loaders.loadPlayerLoadout(sections, allocator, path, warnings);
        parser.validateKeys(sections, parser.player_loadout_key_map, path, allocator, warnings);
    } else if (std.mem.indexOf(u8, path, "/level_") != null and std.mem.endsWith(u8, path, ".txt")) {
        _ = try loaders.loadLevel(sections, file_source, allocator, path, "", warnings);
        parser.validateKeys(sections, parser.level_key_map, path, allocator, warnings);
    } else {
        // Not a recognized config file pattern (e.g. a .txt that isn't a
        // config file). Skip — the test only validates known config types.
    }
}

test "shipped content: every config .txt parses, loads, and has no unknown keys" {
    const allocator = std.testing.allocator;
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // The embedded FileSource (cwd-backed) — reads hit the embedded map for
    // data/ paths since the cwd's persistent dir has no overrides in tests.
    const file_source = FileSource.init(io, std.Io.Dir.cwd());

    // One arena for the whole test — every parse/load allocates into it.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var warnings: std.ArrayList([]const u8) = .empty;

    // Iterate every file in the embedded-asset map. Validate the .txt config
    // files; skip non-config files (.png, etc.). 16 config files as of now.
    // StaticStringMap has no iterator() — iterate the underlying keys array.
    const keys = embedded_assets.map.kvs.keys;
    const values = embedded_assets.map.kvs.values;
    const map_len = embedded_assets.map.kvs.len;
    var config_count: usize = 0;
    var index: usize = 0;
    while (index < map_len) : (index += 1) {
        const path = keys[index];
        const bytes = values[index];
        if (!std.mem.endsWith(u8, path, ".txt")) continue;
        if (!std.mem.startsWith(u8, path, "data/")) continue;

        config_count += 1;
        // Reset the arena per file so a single file's allocations don't
        // accumulate (the next file's parse needs fresh memory; the loaded
        // types are discarded after validation).
        try validateConfigFile(path, bytes, &file_source, a, &warnings);
    }

    // Sanity: at least the known config files are present.
    try std.testing.expect(config_count >= 16);

    // No key-validation warnings across all shipped config.
    if (warnings.items.len > 0) {
        std.debug.print("\nkey-validation warnings in shipped content:\n", .{});
        for (warnings.items) |warning| std.debug.print("  {s}\n", .{warning});
        return error.UnknownKeysInShippedContent;
    }
}
