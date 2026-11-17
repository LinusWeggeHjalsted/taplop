//! Editor event handling: `handleEditorEvent` - the pure state transform
//! behind processEvent's `.editor_event` arm (the cache-needing framing
//! events are handled inline in the dispatch and call the session
//! helpers here) - plus those session helpers (playtest player data, the
//! player-import sources, palette defaults, the fresh-mission open, the
//! decoration registry) and the selection-mutation + template/layer
//! edit helpers. The pure click planners live in planning.zig; the
//! cross-category helpers in handlers/shared.zig. See DESIGN →
//! Architecture → Level Editor.

const std = @import("std");
const types = @import("../types.zig");
const events = @import("../events.zig");
const state = @import("../state.zig");
const parser = @import("../parser.zig");
const loaders = @import("../loaders.zig");
const functions = @import("../functions.zig");
const utility_skills = @import("../utility_skills.zig");
const deep_copy = @import("../deep_copy.zig");
const event_push = @import("../event_push.zig");
const shared = @import("../handlers/shared.zig");
const planning = @import("planning.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;
const Vector2 = types.Vector2;
const Entity = types.Entity;

const deepCopy = deep_copy.deepCopy;
const pushEvents = event_push.pushEvents;
const failReconstructionRead = shared.failReconstructionRead;
const surfaceWarnings = shared.surfaceWarnings;
const validateConfigKeys = shared.validateConfigKeys;
const tileBefore = functions.tileBefore;

/// Build the playtest PlayerData from the editor player loadout: the
/// entity fields a level reads (name, gear, inventory, utility skills)
/// plus learned_skills = EVERY utility skill - the editor player knows
/// everything, so tome pickups read already-learned, skill-tome salvage
/// is consistent, and any future learned-gated path is permissive.
/// Deep copies (the template's slices stay owned by the editor graph).
/// Learned is implied, not authored - player.txt never carries it.
pub fn buildPlaytestPlayerData(
    allocator: std.mem.Allocator,
    template: types.Entity,
) types.PlayerData {
    var player_data: types.PlayerData = .{
        .player_name = deepCopy([]const u8, template.name, allocator),
        .main_hand_weapon = deepCopy(?types.Weapon, template.main_hand_weapon, allocator),
        .off_hand_weapon = deepCopy(?types.Weapon, template.off_hand_weapon, allocator),
        .amulet = deepCopy(?types.Amulet, template.amulet, allocator),
        .coat = deepCopy(?types.Coat, template.coat, allocator),
        .gloves = deepCopy(?types.Gloves, template.gloves, allocator),
        .pants = deepCopy(?types.Pants, template.pants, allocator),
        .boots = deepCopy(?types.Boots, template.boots, allocator),
        .equipped_utility_skills = template.equipped_utility_skills,
        .inventory = deepCopy(types.Inventory, template.inventory, allocator),
    };
    player_data.learned_skills = deepCopy(
        []const types.SkillId,
        utility_skills.utility_skill_ids,
        allocator,
    );
    return player_data;
}

/// Restore the session's real PlayerData after a playtest/validate run
/// (the run's own data was built on enter + mutated by in-level events).
pub fn restorePrePlaytestPlayerData(current: *GameState) void {
    const editor = &(current.editor orelse @panic("editor event with no editor"));
    if (editor.pre_playtest_player_data) |backed_up| {
        current.player_data = backed_up;
        editor.pre_playtest_player_data = null;
    } else {
        // Defensive (the enter arms always set the backup): a null backup
        // means the run began with the fresh-session default.
        current.player_data = .{};
    }
}

/// The player inspector's Import: copy the session's player data - or,
/// when the session has none (an empty `player_name` - a fresh editor
/// launch from the main menu), the new-game default save - into the
/// editor player loadout. The copied field set mirrors
/// `build_player_from_data`'s (name, gear, inventory, utility skills;
/// PlayerData carries no base stats, so the template keeps its own). The
/// copy is a DEEP one: the source's name slices stay owned by their own
/// graph. The default-save read goes through the reconstruction cache -
/// the import event is recorded, so replay re-reads the same bytes.
/// Which loadout source an import pulls from: the session's player data
/// (falling back to data/new_player.txt with none - the Player data
/// button) or the shipped max loadout (data/max_player.txt - the Max
/// player button, the author-times tool for official missions).
const EditorPlayerImportSource = enum { session, max_player };

pub fn importEditorPlayer(
    history: *GameStateHistory,
    current: *GameState,
    allocator: std.mem.Allocator,
    source: EditorPlayerImportSource,
) void {
    const loadout: types.Entity = switch (source) {
        .session => blk: {
            var source_data: types.PlayerData = current.player_data;
            if (source_data.player_name.len == 0) {
                const bytes = history.readReconstructionFile("data/new_player.txt") catch {
                    failReconstructionRead(history, "failed to read new_player.txt");
                    return;
                };
                const sections = parser.parseConfigFile(bytes, allocator, &parser.player_save_sections) catch {
                    failReconstructionRead(history, "failed to parse new_player.txt");
                    return;
                };
                validateConfigKeys(history, sections, parser.player_save_key_map, "data/new_player.txt", allocator);
                source_data = loaders.loadPlayerSave(sections, allocator, "data/new_player.txt", null) catch {
                    failReconstructionRead(history, "failed to parse new_player.txt");
                    return;
                };
            }
            break :blk loaders.playerLoadoutEntity(source_data);
        },
        .max_player => blk: {
            var warnings: std.ArrayList([]const u8) = .empty;
            const max_loadout = loadMaxPlayerLoadout(history, allocator, &warnings) orelse return;
            surfaceWarnings(history, &warnings, allocator);
            break :blk max_loadout;
        },
    };
    const editor = &(current.editor orelse @panic("editor event with no editor"));
    const template = &editor.player_def.template;
    template.name = deepCopy([]const u8, loadout.name, allocator);
    template.main_hand_weapon = deepCopy(?types.Weapon, loadout.main_hand_weapon, allocator);
    template.off_hand_weapon = deepCopy(?types.Weapon, loadout.off_hand_weapon, allocator);
    template.amulet = deepCopy(?types.Amulet, loadout.amulet, allocator);
    template.coat = deepCopy(?types.Coat, loadout.coat, allocator);
    template.gloves = deepCopy(?types.Gloves, loadout.gloves, allocator);
    template.pants = deepCopy(?types.Pants, loadout.pants, allocator);
    template.boots = deepCopy(?types.Boots, loadout.boots, allocator);
    template.equipped_utility_skills = loadout.equipped_utility_skills;
    template.inventory = deepCopy(types.Inventory, loadout.inventory, allocator);
}

/// Append a new palette type built from the shipped defaults
/// (data/editor_defaults.txt) to `kind`'s palette group, make it the active
/// tool, and open the inspector. The defaults read goes through the
/// reconstruction cache - the add events are recorded, so replay re-reads
/// the same bytes and reproduces the creation. The read is a recoverable
/// failure (the in-event-read pattern): a missing/corrupt defaults file
/// reverts the event + surfaces the popup instead of failing the editor.
/// One event = one undo step covering the append + the tool switch + the
/// inspector open (and the selection clear the tool switch carries - the
/// editor_set_tool invariant).
/// Read + parse data/editor_defaults.txt (the add-palette-type template
/// source - a recorded read, so the add event replays identically).
/// Returns null with the recoverable error already surfaced. Shared by
/// the mission editor's add (`addEditorPaletteType`) and the hub
/// editor's decoration add (campaign_editor/hub_handlers).
pub fn readEditorDefaults(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
) ?loaders.EditorDefaults {
    const bytes = history.readReconstructionFile("data/editor_defaults.txt") catch {
        failReconstructionRead(history, "failed to read data/editor_defaults.txt");
        return null;
    };
    const sections = parser.parseConfigFile(bytes, allocator, &parser.editor_defaults_sections) catch {
        failReconstructionRead(history, "failed to parse data/editor_defaults.txt");
        return null;
    };
    validateConfigKeys(history, sections, parser.level_key_map, "data/editor_defaults.txt", allocator);
    return loaders.loadEditorDefaults(sections, history.file_source, allocator, "data/editor_defaults.txt", null) catch {
        failReconstructionRead(history, "failed to parse data/editor_defaults.txt (a palette default entry is missing)");
        return null;
    };
}

pub fn addEditorPaletteType(
    history: *GameStateHistory,
    current: *GameState,
    allocator: std.mem.Allocator,
    kind: events.EditorTypeKind,
) void {
    const defaults = readEditorDefaults(history, allocator) orelse return;

    const editor = &(current.editor orelse @panic("editor event with no editor"));
    switch (kind) {
        .entity => {
            layerListAppend(types.EntityTypeDef, &editor.entity_types, defaults.entity, allocator);
            editor.active_tool = .{ .entity_type = @intCast(editor.entity_types.len - 1) };
        },
        .decoration => {
            layerListAppend(types.DecorationTypeDef, &editor.decoration_types, defaults.decoration, allocator);
            editor.active_tool = .{ .decoration_type = @intCast(editor.decoration_types.len - 1) };
        },
        .item => {
            layerListAppend(types.ItemTypeDef, &editor.item_types, defaults.item, allocator);
            editor.active_tool = .{ .item_type = @intCast(editor.item_types.len - 1) };
        },
    }
    // The tool switch carries the selection clear (the editor_set_tool
    // invariant: selection nonempty ⇔ active tool is select).
    editor.selection = &.{};
    editor.inspector_open = true;
}

/// Read + parse the shipped new-level template (data/default_level.txt)
/// through the reconstruction cache. Shared by the add-level handler and
/// the fresh-mission editor open. Returns null after surfacing the
/// recoverable error (the caller aborts).
fn readEditorDefaultLevel(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
) ?types.EditorLevel {
    const bytes = history.readReconstructionFile("data/default_level.txt") catch {
        failReconstructionRead(history, "failed to read data/default_level.txt");
        return null;
    };
    const sections = parser.parseConfigFile(bytes, allocator, &parser.level_sections) catch {
        failReconstructionRead(history, "failed to parse data/default_level.txt");
        return null;
    };
    validateConfigKeys(history, sections, parser.level_key_map, "data/default_level.txt", allocator);
    return loaders.loadEditorDefaultLevel(sections, history.file_source, allocator, "data/default_level.txt", null) catch {
        failReconstructionRead(history, "failed to parse data/default_level.txt (the template must be the minimal != layout)");
        return null;
    };
}

/// The maxed default loadout (data/max_player.txt) as an editor player
/// template - the fallback when a mission carries no player.txt AND the
/// fresh-mission seed (DESIGN → Level Editor → Player loadout). Returns
/// null after surfacing the recoverable error (the caller aborts).
/// pub: shared with the dispatch's open-editor arm (its player.txt
/// fallback read).
pub fn loadMaxPlayerLoadout(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]const u8),
) ?types.Entity {
    const bytes = history.readReconstructionFile("data/max_player.txt") catch {
        failReconstructionRead(history, "failed to read max_player.txt");
        return null;
    };
    const sections = parser.parseConfigFile(bytes, allocator, &parser.player_save_sections) catch {
        failReconstructionRead(history, "failed to parse max_player.txt");
        return null;
    };
    validateConfigKeys(history, sections, parser.player_save_key_map, "data/max_player.txt", allocator);
    const default_data = loaders.loadPlayerSave(sections, allocator, "data/max_player.txt", warnings) catch {
        failReconstructionRead(history, "failed to parse max_player.txt");
        return null;
    };
    return loaders.playerLoadoutEntity(default_data);
}

/// Refresh `Editor.clamp_bounds` from the ACTIVE level's live tiles -
/// the one place the camera-clamp snapshot is taken. Called only when the
/// active level switches (open_editor both branches, editor_set_active_level,
/// editor_add_level, editor_delete_level clamping onto new content): mid-edit
/// tile changes deliberately do NOT re-run this, so the camera clamp stays
/// fixed while the author paints (see DESIGN → Platform Seam → Camera
/// clamping). Defensive against crafted states: an out-of-range active index
/// or an empty tile list snapshots null (the unclamped editor camera).
pub fn refreshEditorClampBounds(editor: *types.Editor) void {
    if (editor.active_level_index >= editor.levels.len) {
        editor.clamp_bounds = null;
        return;
    }
    const tiles = editor.levels[editor.active_level_index].level_tiles;
    if (tiles.len == 0) {
        editor.clamp_bounds = null;
        return;
    }
    var min_x = tiles[0].x;
    var max_x = tiles[0].x;
    var min_y = tiles[0].y;
    var max_y = tiles[0].y;
    for (tiles[1..]) |tile| {
        if (tile.x < min_x) min_x = tile.x;
        if (tile.x > max_x) max_x = tile.x;
        if (tile.y < min_y) min_y = tile.y;
        if (tile.y > max_y) max_y = tile.y;
    }
    editor.clamp_bounds = .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

/// Append a new level built from the shipped template
/// (data/default_level.txt - the minimal `!=` layout), switch the active
/// tab to it, and sync mission.level_count. The template read goes through
/// the reconstruction cache - the add event is recorded, so replay re-reads
/// the same bytes and reproduces the creation; a read/parse failure takes
/// the recoverable in-event-read path (revert + popup). One event = one
/// undo step covering the append + the tab switch (and the selection clear
/// it carries - the editor_set_active_level semantics).
pub fn addEditorLevel(
    history: *GameStateHistory,
    current: *GameState,
    allocator: std.mem.Allocator,
) void {
    const template = readEditorDefaultLevel(history, allocator) orelse return;

    const editor = &(current.editor orelse @panic("editor event with no editor"));
    layerListAppend(types.EditorLevel, &editor.levels, template, allocator);
    // The author lands on the thing they just created (the add-type
    // behavior); the tab switch carries the selection clear.
    editor.active_level_index = editor.levels.len - 1;
    editor.selection = &.{};
    editor.mission.level_count = @intCast(editor.levels.len);
    refreshEditorClampBounds(editor);
}

/// The fresh-mission branch of open_editor (null mission_path - the
/// main-menu Editor button): "New Mission" with one default-template
/// level, empty palettes, and the max-player loadout. The mission uuid
/// stays EMPTY - identity is minted at save time, write-only, never held
/// in state (a random value in GameState would diverge on every replay;
/// see DESIGN → Level Editor → Mission identity). Sets `current.editor`;
/// a failed read surfaces the recoverable error and returns with the
/// editor unset (the arm's null check skips the transition).
pub fn openFreshEditorMission(
    history: *GameStateHistory,
    current: *GameState,
    allocator: std.mem.Allocator,
    balance_warnings: *std.ArrayList([]const u8),
) void {
    openEditorMissionTemplate(history, current, allocator, balance_warnings, "New Mission", "missions/New Mission");
}

/// The fresh-template mission open (the shared body under
/// openFreshEditorMission's fixed constants + the campaign hand-off's
/// fresh branch): one default-template level, empty palettes, the
/// max-player loadout, the given name + path (the path anchors the
/// mission-local art scan - a fresh mission's dir usually does not
/// exist yet; the standalone fresh mission's "missions/New Mission"
/// placeholder convention). The mission uuid stays EMPTY - identity is
/// minted at save time, write-only, never held in state (a random value
/// in GameState would diverge on every replay; see DESIGN → Level
/// Editor → Mission identity). Sets `current.editor`; a failed read
/// surfaces the recoverable error and returns with the editor unset
/// (the arm's null check skips the transition).
pub fn openEditorMissionTemplate(
    history: *GameStateHistory,
    current: *GameState,
    allocator: std.mem.Allocator,
    balance_warnings: *std.ArrayList([]const u8),
    mission_name: []const u8,
    mission_path: []const u8,
) void {
    const template = readEditorDefaultLevel(history, allocator) orelse return;
    const player_entity = loadMaxPlayerLoadout(history, allocator, balance_warnings) orelse return;
    var level_list: std.ArrayList(types.EditorLevel) = .empty;
    level_list.append(allocator, template) catch @panic("failed to append editor level");
    current.editor = .{
        .mission = .{
            .name = mission_name,
            .path = mission_path,
            .level_count = 1,
        },
        .levels = level_list.toOwnedSlice(allocator) catch @panic("failed to own editor levels slice"),
        .player_def = .{ .id = "Player", .template = player_entity },
    };
    refreshEditorClampBounds(&current.editor.?);
}

/// Open the mission editor on an existing mission DIRECTORY (the
/// open_editor path branch + the campaign-editor hand-off share this):
/// mission.txt + player.txt (the max-player fallback when absent) +
/// level_1..level_N through the reconstruction cache (recorded-event
/// reads), built into the Editor payload. Returns false when a
/// recoverable error was surfaced and the editor left unset (the
/// caller's null check skips the transition). The CALLER owns the
/// postlude (path, campaign context, registry, warnings, the
/// world-generation bump, the transition).
pub fn openEditorMissionFromDir(
    history: *GameStateHistory,
    current: *GameState,
    allocator: std.mem.Allocator,
    balance_warnings: *std.ArrayList([]const u8),
    mission_path: []const u8,
) bool {
    const mission_file_path = std.fmt.allocPrint(
        allocator,
        "{s}/mission.txt",
        .{mission_path},
    ) catch @panic("failed to allocate mission path");
    const mission_sections = blk: {
        const bytes = history.readReconstructionFile(mission_file_path) catch {
            failReconstructionRead(history, "failed to read mission file");
            return false;
        };
        break :blk parser.parseConfigFile(bytes, allocator, &parser.mission_sections) catch {
            failReconstructionRead(history, "failed to parse mission file");
            return false;
        };
    };
    validateConfigKeys(history, mission_sections, parser.mission_key_map, mission_file_path, allocator);
    var mission = loaders.loadMission(
        mission_sections,
        allocator,
    ) catch {
        failReconstructionRead(history, "failed to parse mission file");
        return false;
    };
    // The derived level count (same reconstruction-sound probe as
    // start_mission - open_editor is a reconstruction-read event).
    mission.level_count = shared.countMissionLevelsCached(
        history,
        mission_path,
        allocator,
    ) catch {
        failReconstructionRead(history, "failed to read mission level files");
        return false;
    };
    const player_file_path = std.fmt.allocPrint(
        allocator,
        "{s}/player.txt",
        .{mission_path},
    ) catch @panic("failed to allocate player path");
    const player_entity: types.Entity = blk: {
        const bytes = history.readReconstructionFile(player_file_path) catch |read_error| {
            if (read_error != error.FileNotFound) {
                failReconstructionRead(history, "failed to read player.txt");
                return false;
            }
            // No player.txt in the mission - the maxed default
            // loadout (the shared fresh-mission seed helper -
            // data/max_player.txt, a full player save; its loadout
            // sections map onto the template).
            break :blk loadMaxPlayerLoadout(history, allocator, balance_warnings) orelse return false;
        };
        const sections = parser.parseConfigFile(bytes, allocator, &parser.player_loadout_sections) catch {
            failReconstructionRead(history, "failed to parse player.txt");
            return false;
        };
        validateConfigKeys(history, sections, parser.player_loadout_key_map, player_file_path, allocator);
        break :blk loaders.loadPlayerLoadout(sections, allocator, player_file_path, balance_warnings) catch {
            failReconstructionRead(history, "failed to parse player.txt");
            return false;
        };
    };
    var level_sections: std.ArrayList([]const parser.Section) = .empty;
    var level_index: u32 = 1;
    while (level_index <= mission.level_count) : (level_index += 1) {
        const level_path = std.fmt.allocPrint(
            allocator,
            "{s}/level_{d}.txt",
            .{ mission_path, level_index },
        ) catch @panic("failed to allocate level path");
        const sections = blk: {
            const bytes = history.readReconstructionFile(level_path) catch {
                failReconstructionRead(history, "failed to read level file");
                return false;
            };
            break :blk parser.parseConfigFile(bytes, allocator, &parser.level_sections) catch {
                failReconstructionRead(history, "failed to parse level file");
                return false;
            };
        };
        validateConfigKeys(history, sections, parser.level_key_map, level_path, allocator);
        level_sections.append(allocator, sections) catch @panic("failed to append level sections");
    }
    current.editor = loaders.buildEditorMission(
        mission,
        player_entity,
        level_sections.items,
        history.file_source,
        allocator,
        mission_path,
        balance_warnings,
    ) catch {
        failReconstructionRead(history, "failed to build editor mission");
        return false;
    };
    // The mission's own path (the payload slice - same borrow as
    // start_mission's): the sprite picker's mission-local scan +
    // the editor save read it.
    current.editor.?.mission.path = mission_path;
    refreshEditorClampBounds(&current.editor.?);
    return true;
}

/// Load the decoration registry (`data/decorations.txt` prefabs) into
/// `session.editor_decoration_registry` - the decoration sprite picker's
/// Official tab + the commit site's prefab-adoption source. Called from
/// the open_editor handler (gated `!replaying`: the registry feeds the
/// input/view layers only - a replay never opens a picker - so it is a
/// session-side asset like `editor_mission_sprites`, not replayed
/// state). The owned deep copy lives in the backing allocator (strings +
/// arrays); the previous list is freed on reload, so the only leak is the
/// final list at process exit. A read/parse failure DEGRADES to an empty
/// list + a popup rather than failing the editor open: the editor stays
/// usable (the picker's Mission tab lists the mission's own art).
pub fn loadEditorDecorationRegistry(history: *GameStateHistory, allocator: std.mem.Allocator) void {
    if (history.replaying) return;
    const backing = history.backing_allocator;
    const session = &history.session;
    const degrade = struct {
        fn note(history_arg: *GameStateHistory, reason: []const u8) void {
            history_arg.session.setPendingError(
                history_arg.history_arena.allocator(),
                reason,
            );
        }
    };
    const bytes = history.readReconstructionFile("data/decorations.txt") catch {
        degrade.note(history, "failed to read data/decorations.txt - the decoration picker's Official tab is unavailable");
        return;
    };
    const sections = parser.parseConfigFile(bytes, allocator, &parser.decoration_registry_sections) catch {
        degrade.note(history, "failed to parse data/decorations.txt - the decoration picker's Official tab is unavailable");
        return;
    };
    validateConfigKeys(history, sections, parser.decoration_registry_key_map, "data/decorations.txt", allocator);
    const loaded = loaders.loadDecorationRegistry(sections, history.file_source, allocator) catch {
        degrade.note(history, "failed to parse data/decorations.txt - the decoration picker's Official tab is unavailable");
        return;
    };

    // The owned copy: `loadDecorationRegistry` returns defs whose strings
    // BORROW the parsed sections (event-arena lifetime), so every string +
    // array is duped into the backing allocator before the arena goes.
    // `id` aliases `sprite` (one dupe - a decoration's name IS its sprite
    // path; freed once below).
    const owned = backing.alloc(types.DecorationTypeDef, loaded.len) catch
        @panic("failed to allocate decoration registry");
    for (loaded, 0..) |definition, index| {
        const layers = backing.alloc(types.DecorationLayer, definition.layers.len) catch
            @panic("failed to allocate decoration registry layers");
        for (definition.layers, 0..) |layer, layer_index| {
            layers[layer_index] = .{
                .sprite = backing.dupe(u8, layer.sprite) catch
                    @panic("failed to dupe decoration layer sprite"),
                .color_index = layer.color_index,
                .behind = layer.behind,
                .pixel_dims = layer.pixel_dims,
            };
        }
        const sprite = backing.dupe(u8, definition.sprite) catch
            @panic("failed to dupe decoration sprite");
        owned[index] = .{
            .id = sprite,
            .sprite = sprite,
            .footprint = backing.dupe(types.Vector2, definition.footprint) catch
                @panic("failed to dupe decoration footprint"),
            .pixel_dims = definition.pixel_dims,
            .color_index = definition.color_index,
            .layers = layers,
        };
    }

    // The previous registry's free (the shared session-owned free - the
    // history deinit uses the same one).
    state.freeEditorDecorationRegistry(session.editor_decoration_registry, backing);
    session.editor_decoration_registry = owned;
}

/// Handle an EditorEvent (the non-`editor_set_active_level` variants). Pure
/// state transform on `current.editor.?.levels[]` or the palette. Called from
/// the `.editor_event` arm of `processEvent`; the switch there dispatches the
/// one inline case and routes the rest here. Arms land incrementally with
/// the editor UI slices; unimplemented variants still panic so an unhooked
/// editor event fails fast rather than silently no-op'ing (which would let
/// the UI believe it edited something). The select tool's selection set
/// lives on the Editor (`Editor.selection`, on the undo timeline); the
/// placement-removal arms keep it consistent (prune the deleted entry,
/// remap the indices above it) in the same event, so undo/redo restores
/// the edit and its selection bookkeeping together.
pub fn handleEditorEvent(
    current: *GameState,
    event: events.EditorEvent,
    allocator: std.mem.Allocator,
) void {
    const editor = &(current.editor orelse @panic("editor event with no editor"));
    switch (event) {
        .editor_set_tool => |set| {
            // Defensive against crafted logs: a tool index outside its
            // palette is ignored (same posture as editor_set_active_level's
            // range check - validatePlayerAction rejects it at the replay
            // seam, the live path can't produce it).
            const tool_valid = switch (set.tool) {
                .select, .tile => true,
                .entity_type => |type_id| type_id < editor.entity_types.len,
                .decoration_type => |type_id| type_id < editor.decoration_types.len,
                .item_type => |type_id| type_id < editor.item_types.len,
            };
            if (!tool_valid) return;
            editor.active_tool = set.tool;
            // Invariant: selection nonempty ⇔ active tool is select - a
            // switch away from the select tool takes the selection with it
            // (same event, so one undo step reverts both).
            if (set.tool != .select) editor.selection = &.{};
        },
        // Delete a level: order-preserving removal + active-tab adjustment
        // + level_count sync, one undo step. The guards PANIC (fail-fast):
        // the ≥1-level invariant is the event's documented contract, the
        // UI + the input layer + validatePlayerAction all gate it, and a
        // crafted log that reaches these has bypassed three gates - the
        // crash dump is the right response (the placement-delete posture).
        .editor_delete_level => |delete| {
            if (editor.levels.len <= 1) {
                @panic("editor_delete_level: a mission always keeps at least one level");
            }
            if (delete.level_index >= editor.levels.len) {
                @panic("editor_delete_level: level index out of range");
            }
            layerListRemoveAt(types.EditorLevel, &editor.levels, delete.level_index, allocator);
            editor.mission.level_count = @intCast(editor.levels.len);
            // The selection is active-level-relative: deleting the ACTIVE
            // level switches content under it - clamp + clear (the
            // editor_set_active_level semantics); a delete below the active
            // tab shifts the tab down with its level; a delete above leaves
            // both alone (the active level's placements are untouched).
            if (delete.level_index == editor.active_level_index) {
                editor.active_level_index = @min(editor.active_level_index, editor.levels.len - 1);
                editor.selection = &.{};
                refreshEditorClampBounds(editor);
            } else if (delete.level_index < editor.active_level_index) {
                editor.active_level_index -= 1;
            }
        },
        // Delete a palette type + every placement referencing it across ALL
        // levels (the palette is mission-shared). The orchestrator of the
        // editor set: it fans out into `editor_delete_*_placement` sub-
        // events (they own the order-preserving removal + the active-level
        // selection prune/remap), then removes the type + decrements every
        // same-kind type id above it + reconciles the active tool. All the
        // events share the triggering player action's idle point - one
        // undo step restores everything. Defensive against crafted logs: an
        // out-of-range type id is ignored (the editor_set_tool posture).
        .editor_delete_type => |delete| {
            const type_valid = switch (delete.type_kind) {
                .entity => delete.type_id < editor.entity_types.len,
                .decoration => delete.type_id < editor.decoration_types.len,
                .item => delete.type_id < editor.item_types.len,
            };
            if (!type_valid) return;

            // The fan-out plan: one delete sub-event per referencing
            // placement, pushed in ascending (level, placement) order. The
            // stack is LIFO, so they PROCESS high-before-low within each
            // level - every planned index is valid at its turn (removing a
            // higher index never shifts a lower one). Type-id remapping
            // below doesn't shift placement indices, so the plan stays
            // addressable even though it runs after this handler returns.
            var deletes: std.ArrayList(Event) = .empty;
            for (editor.levels, 0..) |level, level_index| {
                const level_index_u32: u32 = @intCast(level_index);
                switch (delete.type_kind) {
                    .entity => for (level.entity_placements, 0..) |placement, placement_index| {
                        if (placement.type_id == delete.type_id) {
                            deletes.append(allocator, .{ .editor_event = .{ .editor_delete_entity_placement = .{
                                .level_index = level_index_u32,
                                .placement_index = @intCast(placement_index),
                            } } }) catch @panic("failed to allocate type-delete plan");
                        }
                    },
                    .decoration => for (level.decoration_placements, 0..) |placement, placement_index| {
                        if (placement.type_id == delete.type_id) {
                            deletes.append(allocator, .{ .editor_event = .{ .editor_delete_decoration_placement = .{
                                .level_index = level_index_u32,
                                .placement_index = @intCast(placement_index),
                            } } }) catch @panic("failed to allocate type-delete plan");
                        }
                    },
                    .item => for (level.item_placements, 0..) |placement, placement_index| {
                        if (placement.type_id == delete.type_id) {
                            deletes.append(allocator, .{ .editor_event = .{ .editor_delete_item_placement = .{
                                .level_index = level_index_u32,
                                .placement_index = @intCast(placement_index),
                            } } }) catch @panic("failed to allocate type-delete plan");
                        }
                    },
                }
            }
            pushEvents(current, deletes.items, allocator);

            // Remove the type + decrement every same-kind reference above
            // it (palette indices shift down). Placements of OTHER kinds
            // and the player_def are untouched (separate palettes).
            switch (delete.type_kind) {
                .entity => {
                    layerListRemoveAt(types.EntityTypeDef, &editor.entity_types, delete.type_id, allocator);
                    for (@constCast(editor.levels)) |*level| {
                        for (@constCast(level.entity_placements)) |*placement| {
                            if (placement.type_id > delete.type_id) placement.type_id -= 1;
                        }
                    }
                },
                .decoration => {
                    layerListRemoveAt(types.DecorationTypeDef, &editor.decoration_types, delete.type_id, allocator);
                    for (@constCast(editor.levels)) |*level| {
                        for (@constCast(level.decoration_placements)) |*placement| {
                            if (placement.type_id > delete.type_id) placement.type_id -= 1;
                        }
                    }
                },
                .item => {
                    layerListRemoveAt(types.ItemTypeDef, &editor.item_types, delete.type_id, allocator);
                    for (@constCast(editor.levels)) |*level| {
                        for (@constCast(level.item_placements)) |*placement| {
                            if (placement.type_id > delete.type_id) placement.type_id -= 1;
                        }
                    }
                },
            }

            // Active-tool reconciliation: the deleted tool → select; a
            // higher same-kind index → decremented. The selection is NOT
            // force-cleared - the placement deletes prune entries
            // referencing removed placements, and select + a surviving
            // selection is a legal state.
            switch (editor.active_tool) {
                .entity_type => |type_id| {
                    if (delete.type_kind == .entity) {
                        if (type_id == delete.type_id) {
                            editor.active_tool = .select;
                        } else if (type_id > delete.type_id) {
                            editor.active_tool = .{ .entity_type = type_id - 1 };
                        }
                    }
                },
                .decoration_type => |type_id| {
                    if (delete.type_kind == .decoration) {
                        if (type_id == delete.type_id) {
                            editor.active_tool = .select;
                        } else if (type_id > delete.type_id) {
                            editor.active_tool = .{ .decoration_type = type_id - 1 };
                        }
                    }
                },
                .item_type => |type_id| {
                    if (delete.type_kind == .item) {
                        if (type_id == delete.type_id) {
                            editor.active_tool = .select;
                        } else if (type_id > delete.type_id) {
                            editor.active_tool = .{ .item_type = type_id - 1 };
                        }
                    }
                },
                .select, .tile => {},
            }
        },
        .editor_toggle_inspector => {
            editor.inspector_open = !editor.inspector_open;
        },
        .editor_toggle_metadata_sidebar => {
            editor.metadata_sidebar_open = !editor.metadata_sidebar_open;
        },
        // The centered picker's open/close - class-1 surface state on the
        // Editor (see DESIGN → UI Framework → UI state classification).
        // Opening REPLACES any stale picker still open (the palette-group
        // dropdown semantics - one action, not a close+open pair); closing
        // a closed picker is a graceful no-op (crafted logs).
        .editor_open_picker => |open| {
            editor.picker = open.target;
        },
        .editor_close_picker => {
            editor.picker = null;
        },
        // Inspector field edit (entity name). The target's palette index
        // is guarded defensively (a crafted log could name a deleted
        // type; the live path resolves the target from the still-focused
        // field and commits nothing when stale).
        .editor_set_entity_name => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.name = set.value;
        },
        .editor_set_entity_sprite => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.sprite = set.value;
            // The pick-time default rides the pick event (one undo step -
            // see DESIGN → Entity & UI Coloring, keep_original_colors).
            template.keep_original_colors = set.keep_original_colors;
        },
        .editor_set_entity_color_index => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.color_index = set.value;
        },
        .editor_set_entity_displays_weapons => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.displays_weapons = set.value;
        },
        .editor_set_entity_keep_original_colors => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.keep_original_colors = set.value;
        },
        .editor_set_entity_max_health => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.max_health = set.value;
        },
        .editor_set_entity_defense => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.defense = set.value;
        },
        .editor_set_entity_speed => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.speed = set.value;
        },
        .editor_set_entity_aggro_range => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.aggro_range = set.value;
        },
        .editor_set_entity_team => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.team = set.value;
        },
        // The equipped-slot commit (ONE slot-parameterized event - see
        // EntityGearPayload in events.zig). `equipped: false` clears the
        // slot; otherwise the slot's kind's fields rebuild the item, with
        // stats clamped to the `max_*` bounds (the item-def posture - the
        // editor never holds a state its own load path would clamp away).
        // Both entity targets are valid (gear is player-authorable too).
        .editor_set_entity_gear => |set| {
            const template = editorEntityTemplate(editor, set.target) orelse return;
            switch (set.slot) {
                .main_hand => template.main_hand_weapon = if (set.equipped)
                    .{ .name = set.name, .weapon_type = set.weapon_type, .weapon_damage = @min(set.weapon_damage, types.max_weapon_damage) }
                else
                    null,
                .off_hand => template.off_hand_weapon = if (set.equipped)
                    .{ .name = set.name, .weapon_type = set.weapon_type, .weapon_damage = @min(set.weapon_damage, types.max_weapon_damage) }
                else
                    null,
                .amulet => template.amulet = if (set.equipped)
                    .{ .name = set.name, .spell_damage = @min(set.spell_damage, types.max_spell_damage) }
                else
                    null,
                .coat => template.coat = if (set.equipped)
                    .{ .name = set.name, .health_bonus = @min(set.health_bonus, types.max_health_bonus), .defense_bonus = @min(set.defense_bonus, types.max_defense_bonus) }
                else
                    null,
                .gloves => template.gloves = if (set.equipped)
                    .{ .name = set.name, .damage_bonus = @min(set.damage_bonus, types.max_gloves_damage), .health_bonus = @min(set.health_bonus, types.max_health_bonus) }
                else
                    null,
                .pants => template.pants = if (set.equipped)
                    .{ .name = set.name, .pickup_radius_bonus = @min(set.pickup_radius_bonus, types.max_pickup_radius), .health_bonus = @min(set.health_bonus, types.max_health_bonus) }
                else
                    null,
                .boots => template.boots = if (set.equipped)
                    .{ .name = set.name, .speed_bonus = @min(set.speed_bonus, types.max_boots_speed), .health_bonus = @min(set.health_bonus, types.max_health_bonus) }
                else
                    null,
            }
        },
        .editor_set_entity_utility_skill => |set| {
            // Defensive against crafted logs: the slot must be in range and
            // only UTILITY skills may sit on the bar (the live path can't
            // produce a weapon skill here - the picker filters + validation
            // rejects; see src/utility_skills.zig).
            if (set.slot_index >= types.utility_skill_count) return;
            if (set.value) |skill_id| {
                if (!utility_skills.isUtilitySkill(skill_id)) return;
            }
            const template = editorEntityTemplate(editor, set.target) orelse return;
            template.equipped_utility_skills[set.slot_index] = set.value;
        },
        // Entity layer edits (the enemy content's Layers section - the
        // player loadout has NO layers: a player_def target is ignored,
        // defensive against crafted logs; validation rejects them at the
        // replay seam). The layer index guards are the same posture.
        .editor_add_entity_layer => |add| {
            const template = entityLayerEditTemplate(editor, add.target) orelse return;
            layerListAppend(types.EntityLayer, &template.layers, .{
                .sprite = add.sprite,
                .color_index = add.color_index,
            }, allocator);
        },
        .editor_remove_entity_layer => |remove| {
            const template = entityLayerEditTemplate(editor, remove.target) orelse return;
            if (remove.layer_index >= template.layers.len) return;
            layerListRemoveAt(types.EntityLayer, &template.layers, remove.layer_index, allocator);
        },
        .editor_set_entity_layer => |set| {
            const template = entityLayerEditTemplate(editor, set.target) orelse return;
            if (set.layer_index >= template.layers.len) return;
            layerListReplaceAt(types.EntityLayer, &template.layers, set.layer_index, .{
                .sprite = set.sprite,
                .color_index = set.color_index,
            }, allocator);
        },
        // Decoration whole-def commit (a picker pick): adopt the full
        // definition - sprite, footprint, pixel dims, color index, layers -
        // with the palette label tracking the sprite (a decoration's name
        // IS its sprite path), then prune the type's placements the new
        // footprint invalidates (same event, so one undo step covers the
        // retype + the prune). Defensive against crafted logs: a type id
        // outside the palette is ignored (the live path resolves the
        // target from the inspector; the delete arms keep it valid), and
        // an empty footprint is ignored - every pick path derives a
        // nonempty one (authored prefab or the custom-stem bottom-left
        // default).
        .editor_set_decoration_def => |set| {
            if (set.type_id >= editor.decoration_types.len) return;
            if (set.footprint.len == 0) return;
            const definition = &@constCast(editor.decoration_types)[set.type_id];
            definition.id = set.sprite;
            definition.sprite = set.sprite;
            definition.footprint = set.footprint;
            definition.pixel_dims = set.pixel_dims;
            definition.color_index = set.color_index;
            definition.keep_original_colors = set.keep_original_colors;
            definition.layers = set.layers;
            pruneDecorationPlacementsForType(editor, set.type_id, allocator);
        },
        // Decoration keep_original_colors toggle (the flag never affects
        // placement validity - no prune).
        .editor_set_decoration_keep_original_colors => |set| {
            if (set.type_id >= editor.decoration_types.len) return;
            @constCast(editor.decoration_types)[set.type_id].keep_original_colors = set.value;
        },
        // Decoration color swatch commit (color never affects placement
        // validity - no prune).
        .editor_set_decoration_color_index => |set| {
            if (set.type_id >= editor.decoration_types.len) return;
            @constCast(editor.decoration_types)[set.type_id].color_index = set.value;
        },
        // Decoration layer edits (the decoration content's Layers
        // section). The load-time invariant - a layer's pixel dims must
        // equal the base's (the level parser panics otherwise) - is
        // enforced here too: a mismatched payload is ignored, so the
        // editor can never hold a state its own load path would reject
        // (the editor_set_entity_utility_skill posture; the live commit
        // site rejects mismatches before pushing).
        .editor_add_decoration_layer => |add| {
            if (add.type_id >= editor.decoration_types.len) return;
            const definition = &@constCast(editor.decoration_types)[add.type_id];
            if (!decorationLayerDimsMatch(definition, .{
                .sprite = add.sprite,
                .color_index = add.color_index,
                .pixel_dims = add.pixel_dims,
            })) return;
            layerListAppend(types.DecorationLayer, &definition.layers, .{
                .sprite = add.sprite,
                .color_index = add.color_index,
                .behind = add.behind,
                .pixel_dims = add.pixel_dims,
            }, allocator);
        },
        .editor_remove_decoration_layer => |remove| {
            if (remove.type_id >= editor.decoration_types.len) return;
            const definition = &@constCast(editor.decoration_types)[remove.type_id];
            if (remove.layer_index >= definition.layers.len) return;
            layerListRemoveAt(types.DecorationLayer, &definition.layers, remove.layer_index, allocator);
        },
        .editor_set_decoration_layer => |set| {
            if (set.type_id >= editor.decoration_types.len) return;
            const definition = &@constCast(editor.decoration_types)[set.type_id];
            if (set.layer_index >= definition.layers.len) return;
            if (!decorationLayerDimsMatch(definition, .{
                .sprite = set.sprite,
                .color_index = set.color_index,
                .pixel_dims = set.pixel_dims,
            })) return;
            layerListReplaceAt(types.DecorationLayer, &definition.layers, set.layer_index, .{
                .sprite = set.sprite,
                .color_index = set.color_index,
                .behind = set.behind,
                .pixel_dims = set.pixel_dims,
            }, allocator);
        },
        // The footprint editor's confirm: adopt the new footprint (the
        // draft grid resolves to sprite-grid coords), then prune the
        // type's placements the new footprint invalidates - an edited
        // footprint re-anchors (the anchor is derived bottom-most-then-
        // left-most), so a placement's world tiles can shift onto level
        // tiles or other decorations exactly like a sprite retype. Same
        // event = one undo step covering both. Defensive against crafted
        // logs: a type id outside the palette, an EMPTY footprint (the
        // load-time invariant - a decoration must reserve at least one
        // tile), or a tile outside the sprite grid (the parser's
        // footprint-in-bbox check) is ignored - the live confirm site
        // can't produce any of them.
        .editor_set_decoration_footprint => |set| {
            if (set.type_id >= editor.decoration_types.len) return;
            if (set.value.len == 0) return;
            const definition = &@constCast(editor.decoration_types)[set.type_id];
            const grid_width = @divTrunc(definition.pixel_dims.x + 255, 256);
            const grid_height = @divTrunc(definition.pixel_dims.y + 255, 256);
            for (set.value) |tile| {
                if (tile.x < 0 or tile.y < 0 or
                    tile.x >= grid_width or tile.y >= grid_height) return;
            }
            definition.footprint = set.value;
            pruneDecorationPlacementsForType(editor, set.type_id, allocator);
        },
        // Item-type whole-def commit (a type pick or a stat edit). Stats
        // are clamped to the `max_*` bounds here too - the live path
        // clamps before pushing, the handler clamps again so the editor
        // can never hold a state its own load path (boundedU32) would
        // clamp away (the utility-skill posture). The palette label
        // (`id`) always tracks the item's display name (the decoration
        // id-tracks-the-sprite rule). Defensive against crafted logs: a
        // type id outside the palette is ignored.
        .editor_set_item_def => |set| {
            if (set.type_id >= editor.item_types.len) return;
            const item = itemFromDefSet(set);
            const definition = &@constCast(editor.item_types)[set.type_id];
            definition.item = item;
            definition.id = loaders.itemDisplayName(item, allocator);
        },
        // Item-type name commit: rename in place; the label tracks (same
        // event, one undo step). A skill tome has no name - the rename is
        // a no-op (itemWithName passes a tome through unchanged).
        .editor_set_item_name => |set| {
            if (set.type_id >= editor.item_types.len) return;
            const definition = &@constCast(editor.item_types)[set.type_id];
            const item = types.itemWithName(definition.item, set.value);
            definition.item = item;
            definition.id = loaders.itemDisplayName(item, allocator);
        },
        // Player-loadout inventory slot commits (the inspector's
        // Inventory section). The player_def template is the only owner -
        // index-gated, no palette lookup. Defensive against crafted logs:
        // an index outside `inventory_slot_count` is ignored, an Add onto
        // an occupied slot, a Delete on an empty one, and a def/name
        // commit on an empty slot are no-ops (the live path can't produce
        // any of them - the Add/Delete buttons and the detail fields only
        // render in the matching state).
        .editor_add_inventory_item => |add| {
            if (add.index >= types.inventory_slot_count) return;
            const template = &editor.player_def.template;
            if (template.inventory.slots[add.index] != null) return;
            template.inventory.slots[add.index] = defaultInventoryItem();
        },
        .editor_delete_inventory_item => |delete| {
            if (delete.index >= types.inventory_slot_count) return;
            editor.player_def.template.inventory.slots[delete.index] = null;
        },
        // A type pick (reset-everything semantics) or a stat edit - the
        // whole slot's item commits in ONE event, one undo step. Stats
        // clamp to the max_* bounds (itemFromDefSet, shared with the item
        // palette path - the editor never holds a state its own load path
        // would clamp away).
        .editor_set_inventory_item_def => |set| {
            if (set.index >= types.inventory_slot_count) return;
            if (editor.player_def.template.inventory.slots[set.index] == null) return;
            editor.player_def.template.inventory.slots[set.index] = itemFromDefSet(set);
        },
        .editor_set_inventory_item_name => |set| {
            if (set.index >= types.inventory_slot_count) return;
            const slot = &editor.player_def.template.inventory.slots[set.index];
            if (slot.* == null) return;
            slot.* = types.itemWithName(slot.*.?, set.value);
        },
        .editor_select => |select| {
            // Defensive against crafted logs: the select workflow only, and
            // placement entries must address the active level's lists (a
            // live plan can't violate either - validatePlayerAction rejects
            // the tool case at the replay seam).
            if (editor.active_tool != .select) return;
            const level = planning.activeEditorLevel(editor) orelse return;
            const entry_valid = switch (select.entry) {
                .entity_placement => |index| index < level.entity_placements.len,
                .decoration_placement => |index| index < level.decoration_placements.len,
                .ground_item_placement => |index| index < level.item_placements.len,
                .tile, .player_start, .level_end => true,
                // Hub-grid kinds: a mission level's lists are empty by
                // invariant, so the bounds check rejects naturally.
                .npc_placement => |index| index < level.npc_placements.len,
                .exit_placement => |index| index < level.exit_placements.len,
            };
            if (!entry_valid) return;
            if (planning.selectionContains(editor.selection, select.entry)) return;
            editor.selection = planning.selectionWithEntry(editor.selection, select.entry, allocator);
        },
        .editor_deselect => |deselect| {
            if (editor.active_tool != .select) return;
            editor.selection = planning.selectionWithoutEntry(editor.selection, deselect.entry, allocator);
        },
        .editor_clear_selection => {
            editor.selection = &.{};
        },
        .editor_set_tile => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_tile: level index out of range");
            }
            const level = &@constCast(editor.levels)[set.level_index];
            // A selected tile leaves the selection when the tile is
            // actually erased (an erase of an absent tile is an idempotent
            // no-op - nothing to prune). Gated on the erase targeting the
            // active level (selection entries are active-level-relative).
            if (!set.is_floor and
                set.level_index == editor.active_level_index and
                functions.tileListContains(level.level_tiles, set.position))
            {
                editor.selection = planning.selectionWithoutTile(editor.selection, set.position, allocator);
            }
            level.level_tiles = setLevelTile(level.level_tiles, set.position, set.is_floor, allocator);
        },
        .editor_delete_decoration_placement => |delete| {
            if (delete.level_index >= editor.levels.len) {
                @panic("editor_delete_decoration_placement: level index out of range");
            }
            const level = &@constCast(editor.levels)[delete.level_index];
            if (delete.placement_index >= level.decoration_placements.len) {
                @panic("editor_delete_decoration_placement: placement index out of range");
            }
            var placements = allocator.alloc(
                types.DecorationPlacement,
                level.decoration_placements.len - 1,
            ) catch @panic("failed to allocate decoration placements");
            // Order-preserving removal - placement indices are the identity
            // the move/delete events address, so reordering would corrupt
            // them (the orchestrator deletes high-before-low for exactly
            // this reason).
            @memcpy(
                placements[0..delete.placement_index],
                level.decoration_placements[0..delete.placement_index],
            );
            @memcpy(
                placements[delete.placement_index..],
                level.decoration_placements[delete.placement_index + 1 ..],
            );
            level.decoration_placements = placements;
            if (delete.level_index == editor.active_level_index) {
                editor.selection = reconcileSelectionAfterPlacementDelete(
                    editor.selection,
                    .decoration_placement,
                    delete.placement_index,
                    allocator,
                );
            }
        },
        .editor_place_entity => |place| {
            if (place.level_index >= editor.levels.len) {
                @panic("editor_place_entity: level index out of range");
            }
            const level = &@constCast(editor.levels)[place.level_index];
            // One thing per placed tile (see the placement-tools bullet in
            // DESIGN → Level Editor → Active-tool model): a placement never
            // lands on a tile that already carries an entity or item. The
            // click orchestrator clears occupants first, so reaching here
            // occupied is a logic bug - fail fast.
            for (level.entity_placements) |placement| {
                if (placement.position.x == place.position.x and
                    placement.position.y == place.position.y)
                {
                    @panic("editor_place_entity onto a tile that already has an entity");
                }
            }
            for (level.item_placements) |placement| {
                if (placement.position.x == place.position.x and
                    placement.position.y == place.position.y)
                {
                    @panic("editor_place_entity onto a tile that already has a ground item");
                }
            }
            var placements = allocator.alloc(
                types.EntityPlacement,
                level.entity_placements.len + 1,
            ) catch @panic("failed to allocate entity placements");
            @memcpy(placements[0..level.entity_placements.len], level.entity_placements);
            placements[level.entity_placements.len] = .{
                .type_id = place.type_id,
                .position = place.position,
            };
            level.entity_placements = placements;
        },
        .editor_set_entity_placement_type => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_entity_placement_type: level index out of range");
            }
            const level = &@constCast(editor.levels)[set.level_index];
            if (set.placement_index >= level.entity_placements.len) {
                @panic("editor_set_entity_placement_type: placement index out of range");
            }
            // In-place retype: identity (index) + position stay stable, so
            // nothing referencing the placement shifts.
            @constCast(level.entity_placements)[set.placement_index].type_id = set.type_id;
        },
        .editor_delete_item_placement => |delete| {
            if (delete.level_index >= editor.levels.len) {
                @panic("editor_delete_item_placement: level index out of range");
            }
            const level = &@constCast(editor.levels)[delete.level_index];
            if (delete.placement_index >= level.item_placements.len) {
                @panic("editor_delete_item_placement: placement index out of range");
            }
            var placements = allocator.alloc(
                types.ItemPlacement,
                level.item_placements.len - 1,
            ) catch @panic("failed to allocate item placements");
            // Order-preserving removal (same reasoning as the decoration
            // delete - indices are the identity the move/delete events
            // address).
            @memcpy(
                placements[0..delete.placement_index],
                level.item_placements[0..delete.placement_index],
            );
            @memcpy(
                placements[delete.placement_index..],
                level.item_placements[delete.placement_index + 1 ..],
            );
            level.item_placements = placements;
            if (delete.level_index == editor.active_level_index) {
                editor.selection = reconcileSelectionAfterPlacementDelete(
                    editor.selection,
                    .ground_item_placement,
                    delete.placement_index,
                    allocator,
                );
            }
        },
        .editor_delete_entity_placement => |delete| {
            if (delete.level_index >= editor.levels.len) {
                @panic("editor_delete_entity_placement: level index out of range");
            }
            const level = &@constCast(editor.levels)[delete.level_index];
            if (delete.placement_index >= level.entity_placements.len) {
                @panic("editor_delete_entity_placement: placement index out of range");
            }
            var placements = allocator.alloc(
                types.EntityPlacement,
                level.entity_placements.len - 1,
            ) catch @panic("failed to allocate entity placements");
            // Order-preserving removal (indices are the identity the
            // move/delete/retype events address).
            @memcpy(
                placements[0..delete.placement_index],
                level.entity_placements[0..delete.placement_index],
            );
            @memcpy(
                placements[delete.placement_index..],
                level.entity_placements[delete.placement_index + 1 ..],
            );
            level.entity_placements = placements;
            if (delete.level_index == editor.active_level_index) {
                editor.selection = reconcileSelectionAfterPlacementDelete(
                    editor.selection,
                    .entity_placement,
                    delete.placement_index,
                    allocator,
                );
            }
        },
        .editor_place_decoration => |place| {
            if (place.level_index >= editor.levels.len) {
                @panic("editor_place_decoration: level index out of range");
            }
            if (place.type_id >= editor.decoration_types.len) {
                @panic("editor_place_decoration: type id out of range");
            }
            const level = &@constCast(editor.levels)[place.level_index];
            const footprint_tiles = loaders.decorationFootprintWorldTiles(
                editor.decoration_types[place.type_id].footprint,
                place.position,
                allocator,
            );
            // A decoration's footprint tiles are EXCLUSIVE - no level tile,
            // no entity / item placement, no other decoration's footprint
            // under any of them (the parse-time placement invariant, now
            // enforced at the placement event; the click orchestrator
            // clears occupants first, so reaching here occupied is a logic
            // bug - fail fast). See DESIGN → Decorations & Footprint →
            // Placement invariant.
            for (footprint_tiles) |tile| {
                if (functions.tileListContains(level.level_tiles, tile)) {
                    @panic("editor_place_decoration onto a tile");
                }
                for (level.entity_placements) |placement| {
                    if (placement.position.x == tile.x and placement.position.y == tile.y) {
                        @panic("editor_place_decoration onto an entity placement");
                    }
                }
                for (level.item_placements) |placement| {
                    if (placement.position.x == tile.x and placement.position.y == tile.y) {
                        @panic("editor_place_decoration onto an item placement");
                    }
                }
            }
            for (level.decoration_placements) |placement| {
                const other_definition = editor.decoration_types[placement.type_id];
                for (footprint_tiles) |tile| {
                    if (loaders.decorationFootprintCovers(other_definition.footprint, placement.position, tile, allocator)) {
                        @panic("editor_place_decoration onto another decoration's footprint");
                    }
                }
            }
            var placements = allocator.alloc(
                types.DecorationPlacement,
                level.decoration_placements.len + 1,
            ) catch @panic("failed to allocate decoration placements");
            @memcpy(placements[0..level.decoration_placements.len], level.decoration_placements);
            placements[level.decoration_placements.len] = .{
                .type_id = place.type_id,
                .position = place.position,
            };
            level.decoration_placements = placements;
        },
        .editor_place_item => |place| {
            if (place.level_index >= editor.levels.len) {
                @panic("editor_place_item: level index out of range");
            }
            const level = &@constCast(editor.levels)[place.level_index];
            // One thing per placed tile (see `editor_place_entity`): an
            // item never lands on a tile that already carries an entity or
            // item placement. The click orchestrator clears occupants
            // first, so reaching here occupied is a logic bug - fail fast.
            for (level.entity_placements) |placement| {
                if (placement.position.x == place.position.x and
                    placement.position.y == place.position.y)
                {
                    @panic("editor_place_item onto a tile that already has an entity");
                }
            }
            for (level.item_placements) |placement| {
                if (placement.position.x == place.position.x and
                    placement.position.y == place.position.y)
                {
                    @panic("editor_place_item onto a tile that already has a ground item");
                }
            }
            var placements = allocator.alloc(
                types.ItemPlacement,
                level.item_placements.len + 1,
            ) catch @panic("failed to allocate item placements");
            @memcpy(placements[0..level.item_placements.len], level.item_placements);
            placements[level.item_placements.len] = .{
                .type_id = place.type_id,
                .position = place.position,
            };
            level.item_placements = placements;
        },
        .editor_set_item_placement_type => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_item_placement_type: level index out of range");
            }
            const level = &@constCast(editor.levels)[set.level_index];
            if (set.placement_index >= level.item_placements.len) {
                @panic("editor_set_item_placement_type: placement index out of range");
            }
            // In-place retype: identity (index) + position stay stable, so
            // nothing referencing the placement shifts.
            @constCast(level.item_placements)[set.placement_index].type_id = set.type_id;
        },
        .editor_set_player_start => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_player_start: level index out of range");
            }
            @constCast(editor.levels)[set.level_index].player_start = set.position;
        },
        .editor_set_level_end => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_level_end: level index out of range");
            }
            @constCast(editor.levels)[set.level_index].level_end = set.position;
        },
        // Settings-sidebar commits (mission + level metadata). Level-index
        // guards match the other level-addressed verbs.
        .editor_set_level_name => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_level_name: level index out of range");
            }
            @constCast(editor.levels)[set.level_index].name = set.name;
        },
        .editor_set_mission_name => |set| {
            editor.mission.name = set.name;
            // The campaign-context dual-write (the hand-off): the names
            // never diverge - the campaign graph's denormalized name (map
            // labels, the full save's lean mission.txt sync) tracks the
            // mission editor's live edit. One event, two mirrored writes,
            // both deterministic (the names agree at every save).
            if (editor.campaign_mission) |mission_handle| {
                if (current.campaign_editor) |*campaign| {
                    for (@constCast(campaign.missions)) |*mission| {
                        if (mission.handle == mission_handle) {
                            mission.name = allocator.dupe(u8, set.name) catch
                                @panic("failed to dupe campaign mission name");
                        }
                    }
                }
            }
        },
        .editor_set_level_color_wheel => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_level_color_wheel: level index out of range");
            }
            @constCast(editor.levels)[set.level_index].color_wheel_index = set.color_wheel_index;
        },
        .editor_set_level_enemy_gradient => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_level_enemy_gradient: level index out of range");
            }
            @constCast(editor.levels)[set.level_index].enemy_gradient_index = set.gradient_index;
        },
        .editor_set_level_player_gradient => |set| {
            if (set.level_index >= editor.levels.len) {
                @panic("editor_set_level_player_gradient: level index out of range");
            }
            @constCast(editor.levels)[set.level_index].player_gradient_index = set.gradient_index;
        },
        .editor_commit_selection_move => |commit| {
            // Final link: the worklist is exhausted - a move deselects
            // (nothing is reselected; the clear phase's reconcile already
            // pruned the deleted entries, this drops the rest).
            if (commit.next_index >= commit.entries.len) {
                editor.selection = &.{};
                return;
            }
            const entry = commit.entries[commit.next_index];

            // Plan THIS entry against the live post-clear state - the
            // placement planners are the current placement rules (a
            // marker target plans empty, so that thing was deleted fully
            // in the clear phase and simply doesn't place). Type ids from
            // a crafted worklist are skipped defensively (the live path
            // derives them from real placements, and the clear phase
            // never deletes palette types).
            var plan: std.ArrayList(Event) = .empty;
            switch (entry) {
                .entity => |move_entry| {
                    if (move_entry.type_id < editor.entity_types.len) {
                        plan.appendSlice(
                            allocator,
                            planning.planEditorEntityPlacementActions(editor, move_entry.type_id, move_entry.position, allocator),
                        ) catch @panic("failed to allocate editor selection move plan");
                    }
                },
                .decoration => |move_entry| {
                    if (move_entry.type_id < editor.decoration_types.len) {
                        plan.appendSlice(
                            allocator,
                            planning.planEditorDecorationPlacementActions(editor, move_entry.type_id, move_entry.position, allocator),
                        ) catch @panic("failed to allocate editor selection move plan");
                    }
                },
                .item => |move_entry| {
                    if (move_entry.type_id < editor.item_types.len) {
                        plan.appendSlice(
                            allocator,
                            planning.planEditorItemPlacementActions(editor, move_entry.type_id, move_entry.position, allocator),
                        ) catch @panic("failed to allocate editor selection move plan");
                    }
                },
                .tile => |position| {
                    plan.appendSlice(
                        allocator,
                        planning.planEditorTilePaintActions(editor, position, allocator),
                    ) catch @panic("failed to allocate editor selection move plan");
                },
                // Hub-grid kinds: a mission worklist never carries them
                // (the mission move plan derives entries from mission
                // levels, whose hub lists are empty by invariant).
                .npc, .exit_marker => {},
                .player_start, .level_end => |position| {
                    // Defensive (a crafted worklist - the live plan is vetoed
                    // upstream in planning.planEditorSelectionMoveActions): a
                    // marker never lands on the STAYING other marker's cell
                    // ('!' and '=' take one cell each in the layout format).
                    // A LATER entry may still move the other marker away (a
                    // swap - each marker lands where the other stood), so
                    // only a staying other blocks. A blocked entry plans
                    // empty: the marker simply doesn't place (it stays where
                    // it stands - markers are never deletable, and rendering
                    // and the layout writer need no floor tile under it).
                    var blocked = false;
                    if (planning.activeEditorLevel(editor)) |level| {
                        const other_position: ?types.Vector2 = if (entry == .player_start)
                            level.level_end
                        else
                            level.player_start;
                        if (other_position) |other| {
                            blocked = other.x == position.x and other.y == position.y and
                                !markerMovesLater(commit.entries, @as(usize, commit.next_index) + 1, if (entry == .player_start) .level_end else .player_start);
                        }
                    }
                    if (!blocked) {
                        // A tile is ensured under the moved marker (paint = the
                        // current replacement rules), then the marker moves.
                        plan.appendSlice(
                            allocator,
                            planning.planEditorTilePaintActions(editor, position, allocator),
                        ) catch @panic("failed to allocate editor selection move plan");
                        const marker_variant: events.EditorEvent = if (entry == .player_start)
                            .{ .editor_set_player_start = .{
                                .level_index = @intCast(editor.active_level_index),
                                .position = position,
                            } }
                        else
                            .{ .editor_set_level_end = .{
                                .level_index = @intCast(editor.active_level_index),
                                .position = position,
                            } };
                        plan.append(allocator, .{ .editor_event = marker_variant }) catch
                            @panic("failed to allocate editor selection move plan");
                    }
                },
            }

            // Push [next link, ...plan] - LIFO runs this entry's plan first,
            // then the next link plans the following entry against the
            // result (the chain exists precisely so each entry sees the
            // fully-processed state; see the event's doc in events.zig).
            var push: std.ArrayList(Event) = .empty;
            push.append(allocator, .{ .editor_event = .{ .editor_commit_selection_move = .{
                .entries = commit.entries,
                .next_index = commit.next_index + 1,
            } } }) catch @panic("failed to allocate editor selection move plan");
            push.appendSlice(allocator, plan.items) catch
                @panic("failed to allocate editor selection move plan");
            pushEvents(current, push.items, allocator);
        },
        else => @panic("editor event handler not implemented"),
    }
}

/// Does the move worklist still move `marker_tag` at or after `from_index`?
/// A later move vacates that marker's current cell (a swap - each marker
/// lands where the other stood), so a target overlapping the other
/// marker's CURRENT position is legal after all. Used by the commit
/// chain's marker arm (see `editor_commit_selection_move`).
fn markerMovesLater(
    entries: []const types.EditorSelectionMoveEntry,
    from_index: usize,
    marker_tag: std.meta.Tag(types.EditorSelectionMoveEntry),
) bool {
    for (entries[from_index..]) |later| {
        if (later == marker_tag) return true;
    }
    return false;
}

/// Set or erase one tile in a level's tile list, returning the new list.
/// Idempotent: painting an existing tile / erasing an absent one returns
/// the input unchanged. Inserts keep `tileBefore` (row-major) order so the
/// list stays canonical with the parser's layout-scan order.
pub fn setLevelTile(
    tiles: []const Vector2,
    position: Vector2,
    is_floor: bool,
    allocator: std.mem.Allocator,
) []const Vector2 {
    if (is_floor) {
        for (tiles) |tile| {
            if (tile.x == position.x and tile.y == position.y) return tiles;
        }
        var new_tiles = allocator.alloc(Vector2, tiles.len + 1) catch
            @panic("failed to allocate level tiles");
        var insert_index: usize = tiles.len;
        for (tiles, 0..) |tile, index| {
            if (!tileBefore(tile, position)) {
                insert_index = index;
                break;
            }
        }
        @memcpy(new_tiles[0..insert_index], tiles[0..insert_index]);
        new_tiles[insert_index] = position;
        @memcpy(new_tiles[insert_index + 1 ..], tiles[insert_index..]);
        return new_tiles;
    }
    for (tiles, 0..) |tile, index| {
        if (tile.x == position.x and tile.y == position.y) {
            var new_tiles = allocator.alloc(Vector2, tiles.len - 1) catch
                @panic("failed to allocate level tiles");
            @memcpy(new_tiles[0..index], tiles[0..index]);
            @memcpy(new_tiles[index..], tiles[index + 1 ..]);
            return new_tiles;
        }
    }
    return tiles;
}

/// Keep the select tool's selection consistent after a placement removal:
/// drop the deleted entry and DECREMENT the selected indices above it - a
/// removal shifts later placements down, so without the remap the
/// surviving entries would point at the WRONG placements (skipping only
/// out-of-range entries isn't enough). `kind` selects which placement
/// list the indices refer to; entries of other kinds are untouched.
/// Callers gate on the removal targeting the ACTIVE level (selection
/// entries are active-level-relative). Returns the original slice when no
/// entry of `kind` is present.
pub fn reconcileSelectionAfterPlacementDelete(
    selection: []const types.Selectable,
    kind: std.meta.Tag(types.Selectable),
    removed_index: u32,
    allocator: std.mem.Allocator,
) []const types.Selectable {
    var has_relevant = false;
    for (selection) |selected| {
        if (std.meta.activeTag(selected) == kind) {
            has_relevant = true;
            break;
        }
    }
    if (!has_relevant) return selection;

    const rebuilt = allocator.alloc(types.Selectable, selection.len) catch
        @panic("failed to allocate editor selection");
    var length: usize = 0;
    for (selection) |selected| {
        const relevant: ?u32 = switch (selected) {
            .entity_placement => |value| if (kind == .entity_placement) value else null,
            .decoration_placement => |value| if (kind == .decoration_placement) value else null,
            .ground_item_placement => |value| if (kind == .ground_item_placement) value else null,
            else => null,
        };
        if (relevant) |value| {
            if (value == removed_index) continue;
            if (value > removed_index) {
                switch (selected) {
                    .entity_placement => |shifted| rebuilt[length] = .{ .entity_placement = shifted - 1 },
                    .decoration_placement => |shifted| rebuilt[length] = .{ .decoration_placement = shifted - 1 },
                    .ground_item_placement => |shifted| rebuilt[length] = .{ .ground_item_placement = shifted - 1 },
                    else => unreachable,
                }
                length += 1;
                continue;
            }
        }
        rebuilt[length] = selected;
        length += 1;
    }
    return rebuilt[0..length];
}

/// Delete the type's placements that its (already-updated) footprint
/// invalidates: a placement goes when its translated footprint covers a
/// level tile or ANOTHER decoration placement's footprint - the placement
/// invariant `editor_place_decoration` enforces. Entity/item placements
/// always sit ON level tiles, so the tile check subsumes them. The things
/// under the new footprint are never touched - the decoration itself is
/// deleted. Runs across EVERY level (the palette is mission-shared); the
/// selection is reconciled for the active level's removals only
/// (selection entries reference the active level - level-tab switches
/// clear the selection inside their own events). Shared by
/// editor_set_decoration_def (a picker pick retypes the footprint) and
/// the future editor_set_decoration_footprint handler.
fn pruneDecorationPlacementsForType(
    editor: *types.Editor,
    type_id: u32,
    allocator: std.mem.Allocator,
) void {
    for (editor.levels, 0..) |*level, level_index| {
        var removed_indices: std.ArrayList(u32) = .empty;
        defer removed_indices.deinit(allocator);
        var kept: usize = 0;
        for (level.decoration_placements, 0..) |placement, placement_index| {
            if (placement.type_id != type_id) {
                kept += 1;
                continue;
            }
            const footprint_tiles = loaders.decorationFootprintWorldTiles(
                editor.decoration_types[type_id].footprint,
                placement.position,
                allocator,
            );
            var invalid = false;
            for (footprint_tiles) |tile| {
                if (functions.tileListContains(level.level_tiles, tile)) {
                    invalid = true;
                    break;
                }
            }
            if (!invalid) {
                for (level.decoration_placements, 0..) |other, other_index| {
                    if (other_index == placement_index) continue;
                    const other_definition = editor.decoration_types[other.type_id];
                    for (footprint_tiles) |tile| {
                        if (loaders.decorationFootprintCovers(
                            other_definition.footprint,
                            other.position,
                            tile,
                            allocator,
                        )) {
                            invalid = true;
                            break;
                        }
                    }
                    if (invalid) break;
                }
            }
            if (invalid) {
                removed_indices.append(allocator, @intCast(placement_index)) catch
                    @panic("failed to allocate decoration prune list");
            } else {
                kept += 1;
            }
        }
        if (removed_indices.items.len == 0) continue;

        const placements = allocator.alloc(types.DecorationPlacement, kept) catch
            @panic("failed to allocate decoration placements");
        var write_index: usize = 0;
        for (level.decoration_placements, 0..) |placement, placement_index| {
            var was_removed = false;
            for (removed_indices.items) |removed_index| {
                if (removed_index == placement_index) {
                    was_removed = true;
                    break;
                }
            }
            if (was_removed) continue;
            placements[write_index] = placement;
            write_index += 1;
        }
        @constCast(level).decoration_placements = placements;

        // Selection reconcile: one pass per removed index, DESCENDING so
        // earlier removals don't shift the indices still to process.
        if (level_index == editor.active_level_index) {
            var removal: usize = removed_indices.items.len;
            while (removal > 0) {
                removal -= 1;
                editor.selection = reconcileSelectionAfterPlacementDelete(
                    editor.selection,
                    .decoration_placement,
                    removed_indices.items[removal],
                    allocator,
                );
            }
        }
    }
}

/// The editable template an `EntityEditTarget` addresses (a palette type's
/// template, or the editor-global player definition), or null when the
/// target is out of range - the inspector field-edit handlers no-op on
/// null (defensive: the live path commits nothing when a focused field's
/// type was deleted mid-edit; crafted logs can name any index). pub: shared
/// with input_handlers' text-field commit path.
pub fn editorEntityTemplate(
    editor: *types.Editor,
    target: types.EntityEditTarget,
) ?*types.Entity {
    return switch (target) {
        .entity_type => |type_id| blk: {
            if (type_id >= editor.entity_types.len) break :blk null;
            break :blk &@constCast(editor.entity_types)[type_id].template;
        },
        .player_def => &editor.player_def.template,
    };
}

/// The template an entity-LAYER edit applies to - `editorEntityTemplate`
/// minus the player (the player loadout has no layers; the Layers section
/// is enemy content only).
fn entityLayerEditTemplate(
    editor: *types.Editor,
    target: types.EntityEditTarget,
) ?*types.Entity {
    return switch (target) {
        .entity_type => editorEntityTemplate(editor, target),
        .player_def => null,
    };
}

/// Does a decoration layer's pixel dims match its base type's? The
/// load-time invariant (a mismatch degrades to warn + keep - see DESIGN →
/// Custom Missions & Online Services → Custom-asset dimensions) -
/// shared by the layer-edit handler arms + the replay validation.
fn decorationLayerDimsMatch(
    definition: *const types.DecorationTypeDef,
    layer: types.DecorationLayer,
) bool {
    return layer.pixel_dims.x == definition.pixel_dims.x and
        layer.pixel_dims.y == definition.pixel_dims.y;
}

/// Append to a `[]const T` layer-list field (Entity.layers /
/// DecorationTypeDef.layers - both `[]const`, so mutation is
/// copy-and-reassign).
fn layerListAppend(
    comptime T: type,
    layers: *[]const T,
    layer: T,
    allocator: std.mem.Allocator,
) void {
    const grown = allocator.alloc(T, layers.len + 1) catch
        @panic("failed to allocate layers");
    @memcpy(grown[0..layers.len], layers.*);
    grown[layers.len] = layer;
    layers.* = grown;
}

/// Remove the index from a `[]const T` layer-list field (order-preserving
/// compact). The caller guards the index.
fn layerListRemoveAt(
    comptime T: type,
    layers: *[]const T,
    index: u32,
    allocator: std.mem.Allocator,
) void {
    const shrunk = allocator.alloc(T, layers.len - 1) catch
        @panic("failed to allocate layers");
    @memcpy(shrunk[0..index], layers.*[0..index]);
    @memcpy(shrunk[index..], layers.*[index + 1 ..]);
    layers.* = shrunk;
}

/// Replace the index in a `[]const T` layer-list field. The caller guards
/// the index.
fn layerListReplaceAt(
    comptime T: type,
    layers: *[]const T,
    index: u32,
    layer: T,
    allocator: std.mem.Allocator,
) void {
    const replaced = allocator.dupe(T, layers.*) catch
        @panic("failed to allocate layers");
    replaced[index] = layer;
    layers.* = replaced;
}

/// Rebuild an `Item` from a flattened item-def event payload
/// (`editor_set_item_def` / `player_set_editor_inventory_item_def` share
/// the field set - hence `anytype`). Stats clamp to the `max_*` bounds (the
/// editor never holds a state its own load path would clamp away); only the
/// picked kind's fields are meaningful, the rest are ignored.
fn itemFromDefSet(set: anytype) types.Item {
    return switch (set.item_kind) {
        .weapon => .{ .weapon = .{
            .name = set.name,
            .weapon_type = set.weapon_type,
            .weapon_damage = @min(set.weapon_damage, types.max_weapon_damage),
        } },
        .amulet => .{ .amulet = .{
            .name = set.name,
            .spell_damage = @min(set.spell_damage, types.max_spell_damage),
        } },
        .coat => .{ .coat = .{
            .name = set.name,
            .health_bonus = @min(set.health_bonus, types.max_health_bonus),
            .defense_bonus = @min(set.defense_bonus, types.max_defense_bonus),
        } },
        .gloves => .{ .gloves = .{
            .name = set.name,
            .damage_bonus = @min(set.damage_bonus, types.max_gloves_damage),
            .health_bonus = @min(set.health_bonus, types.max_health_bonus),
        } },
        .pants => .{ .pants = .{
            .name = set.name,
            .pickup_radius_bonus = @min(set.pickup_radius_bonus, types.max_pickup_radius),
            .health_bonus = @min(set.health_bonus, types.max_health_bonus),
        } },
        .boots => .{ .boots = .{
            .name = set.name,
            .speed_bonus = @min(set.speed_bonus, types.max_boots_speed),
            .health_bonus = @min(set.health_bonus, types.max_health_bonus),
        } },
    };
}

/// The default item an inventory-slot Add creates: the new-sword default
/// (the `data/editor_defaults.txt` Items entry - the palette "+" default,
/// kept in sync with it).
fn defaultInventoryItem() types.Item {
    return .{ .weapon = .{
        .name = "New Sword",
        .weapon_type = .sword,
        .weapon_damage = 0,
    } };
}
