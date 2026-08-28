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

    // Gameplay
    try buffer.appendSlice(allocator, "\nGameplay\n");
    try buffer.print(allocator, "auto_skip_attack_step_out_of_combat {}\n", .{settings.auto_skip_attack_step_out_of_combat});
    try buffer.print(allocator, "auto_target_at_cursor {}\n", .{settings.auto_target_at_cursor});
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
