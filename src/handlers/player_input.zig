//! The player-input orchestrator handler: `handlePlayerInputEvent`, the
//! fn behind processEvent's `.player_input_event` arm. Each variant is a
//! player-initiated action (keybind or click); simple variants do inline
//! work, orchestrator variants push machinery events as children via
//! `pushEvents` (the orchestrator convention — see DESIGN → Architecture
//! + DESIGN → Determinism & Tiebreaking → Replay PLAYER-ACTION LEGALITY).

const std = @import("std");
const types = @import("../types.zig");
const events = @import("../events.zig");
const state = @import("../state.zig");
const parser = @import("../parser.zig");
const loaders = @import("../loaders.zig");
const writers = @import("../writers.zig");
const lookups = @import("../generated_lookups.zig");
const functions = @import("../functions.zig");
const utility_skills = @import("../utility_skills.zig");
const event_push = @import("../event_push.zig");
const shared = @import("shared.zig");
const player_handlers = @import("player.zig");
const editor_handlers = @import("../editor/handlers.zig");
const planning = @import("../editor/planning.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Vector2 = types.Vector2;
const utility_skill_count = types.utility_skill_count;
const Event = events.Event;
const Entity = types.Entity;

const pushEvents = event_push.pushEvents;
const pushPlayerAction = event_push.pushPlayerAction;
const pushPlayerSkillUse = event_push.pushPlayerSkillUse;
const failReconstructionRead = shared.failReconstructionRead;
const surfaceWarnings = shared.surfaceWarnings;
const validateConfigKeys = shared.validateConfigKeys;
const getPlayerEntity = shared.getPlayerEntity;
const getLevelEntity = shared.getLevelEntity;
const loadCampaignAndPushHub = shared.loadCampaignAndPushHub;
const pushGameplayStartEvents = shared.pushGameplayStartEvents;
const refreshMoveHighlights = shared.refreshMoveHighlights;
const cancelPreparedSkill = shared.cancelPreparedSkill;
const isSkillLearned = player_handlers.isSkillLearned;
const salvageRegionOccupiedSlots = player_handlers.salvageRegionOccupiedSlots;

/// Handle a `PlayerInputEvent` — the handler for the `.player_input_event`
/// arm in `processEvent`. Each variant is a player-initiated action (keybind
/// or click). Simple variants do inline work; orchestrator variants push
/// machinery events as children via `pushEvents`. See `PlayerInputEvent` in
/// events.zig + DESIGN → Determinism & Tiebreaking → Replay PLAYER-ACTION
/// LEGALITY.
pub fn handlePlayerInputEvent(
    history: *GameStateHistory,
    current: *GameState,
    pi: events.PlayerInputEvent,
    allocator: std.mem.Allocator,
) void {
    switch (pi) {
        // --- Meta: overlay dismiss ---
        .dismiss_mission_complete => {
            current.last_completed_mission = null;
        },

        // --- Meta: continue (main-menu Continue button) ---
        // Two branches by PlayerData state. Populated (the mid-session
        // exit-to-menu case) → resume directly from in-memory data, no file
        // read. Empty (the fresh-launch case) → load the autosave first, then
        // loadCampaignAndPushHub resumes at player_data.current_hub. See
        // DESIGN → File System & IO (autosave).
        .player_continue => {
            if (current.player_data.current_campaign.len > 0) {
                loadCampaignAndPushHub(current, history, allocator);
                if (history.load_error) return;
            } else {
                pushEvents(current, &.{.{ .meta_event = .{ .load_save = .{
                    .save_path = writers.autosave_path,
                } } }}, allocator);
            }
        },

        // --- Meta: load a save from the load-save browser ---
        // Thin orchestrator: the browser's acquisition (scan/pick) happened
        // in idle input; here we just feed the resident path to the normal
        // load path (read → parse → load → resume at the save's hub). A
        // corrupt/missing file fails inside `load_save` recoverably (popup +
        // revert) — the browser stays open for another pick.
        .player_load_save => |load| {
            pushEvents(current, &.{.{ .meta_event = .{ .load_save = .{
                .save_path = load.save_path,
            } } }}, allocator);
        },

        // --- Meta: new game ---
        .start_new_game => {
            var balance_warnings: std.ArrayList([]const u8) = .empty;
            const parsed_sections = blk: {
                const bytes = history.readReconstructionFile("data/new_player.txt") catch {
                    failReconstructionRead(history, "failed to read new_player.txt");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator) catch {
                    failReconstructionRead(history, "failed to parse new_player.txt");
                    return;
                };
            };
            validateConfigKeys(history, parsed_sections, parser.player_save_key_map, "data/new_player.txt", allocator);
            current.player_data = loaders.loadPlayerSave(
                parsed_sections,
                allocator,
                "data/new_player.txt",
                &balance_warnings,
            ) catch {
                failReconstructionRead(history, "failed to parse new_player.txt");
                return;
            };
            surfaceWarnings(history, &balance_warnings, allocator);
            loadCampaignAndPushHub(current, history, allocator);
            if (history.load_error) return;
            // Push backup_autosave AFTER loadCampaignAndPushHub so it lands
            // ON TOP of start_hub (LIFO → runs first). If it were pushed
            // before, start_hub would run first and its transitionScreen(.hub)
            // would clear the event stack, wiping backup_autosave before it
            // runs. The backup reads the autosave file (independent of
            // GameState), so running before start_hub is correct. See DESIGN
            // → File System & IO (Autosave).
            pushEvents(current, &.{.{ .meta_event = .backup_autosave }}, allocator);
        },

        // --- Meta: save ---
        // Writes a timestamped save AND updates the autosave. Both write_save
        // events read the synced PlayerData (build_data_from_player runs first
        // via LIFO). The autosave is the recovery path for a player who saves
        // mid-mission then quits: without it, Continue would resume at the
        // last hub transition and lose any loot picked up since. See DESIGN →
        // File System & IO (autosave).
        .save_game => |save| {
            if (current.level != null or current.hub != null) {
                pushEvents(current, &.{
                    .{ .meta_event = .{ .write_save = .{ .save_path = writers.autosave_path } } },
                    .{ .meta_event = .{ .write_save = .{ .save_path = save.save_path } } },
                    .{ .super_event = .{ .build_data_from_player = .{ .entity_index = 0 } } },
                }, allocator);
            } else {
                pushEvents(current, &.{
                    .{ .meta_event = .{ .write_save = .{ .save_path = writers.autosave_path } } },
                    .{ .meta_event = .{ .write_save = .{ .save_path = save.save_path } } },
                }, allocator);
            }
        },

        // --- Meta: open editor ---
        .open_editor => |start| {
            var balance_warnings: std.ArrayList([]const u8) = .empty;
            // Null path = the fresh empty mission (the main-menu Editor
            // button) — the short-circuit branch below; a path = the
            // mission-directory open (the future mission browser + the
            // round-trip tests).
            if (start.mission_path == null) {
                editor_handlers.openFreshEditorMission(history, current, allocator, &balance_warnings);
                // A failed open surfaced the recoverable error and left
                // the editor unset — skip the transition (the drain loop
                // reverts).
                if (current.editor == null) return;
                editor_handlers.loadEditorDecorationRegistry(history, allocator);
                surfaceWarnings(history, &balance_warnings, allocator);
                // A newly installed editor mission is a new world: bump so
                // the transition UI reset in the driver fires even when the
                // screen STAYS .editor (an open-from-the-editor via the
                // mission browser) — stale view state (open panels, the
                // browser itself, scroll offsets) must not survive the
                // mission swap. start_level/start_hub bump for the same
                // reason.
                current.world_generation +%= 1;
                current.transitionScreen(.editor);
                return;
            }
            const mission_path = start.mission_path.?;
            const mission_file_path = std.fmt.allocPrint(
                allocator,
                "{s}/mission.txt",
                .{mission_path},
            ) catch @panic("failed to allocate mission path");
            const mission_sections = blk: {
                const bytes = history.readReconstructionFile(mission_file_path) catch {
                    failReconstructionRead(history, "failed to read mission file");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator) catch {
                    failReconstructionRead(history, "failed to parse mission file");
                    return;
                };
            };
            validateConfigKeys(history, mission_sections, parser.mission_key_map, mission_file_path, allocator);
            const mission = loaders.loadMission(
                mission_sections,
                allocator,
            ) catch {
                failReconstructionRead(history, "failed to parse mission file");
                return;
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
                        return;
                    }
                    // No player.txt in the mission — the maxed default
                    // loadout (the shared fresh-mission seed helper —
                    // data/max_player.txt, a full player save; its loadout
                    // sections map onto the template).
                    break :blk editor_handlers.loadMaxPlayerLoadout(history, allocator, &balance_warnings) orelse return;
                };
                const sections = parser.parseConfigFile(bytes, allocator) catch {
                    failReconstructionRead(history, "failed to parse player.txt");
                    return;
                };
                validateConfigKeys(history, sections, parser.player_loadout_key_map, player_file_path, allocator);
                break :blk loaders.loadPlayerLoadout(sections, allocator, player_file_path, &balance_warnings) catch {
                    failReconstructionRead(history, "failed to parse player.txt");
                    return;
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
                        return;
                    };
                    break :blk parser.parseConfigFile(bytes, allocator) catch {
                        failReconstructionRead(history, "failed to parse level file");
                        return;
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
                &balance_warnings,
            ) catch {
                failReconstructionRead(history, "failed to build editor mission");
                return;
            };
            // The mission's own path (the payload slice — same borrow as
            // start_mission's): the sprite picker's mission-local scan +
            // the editor save read it.
            current.editor.?.mission.path = mission_path;
            editor_handlers.refreshEditorClampBounds(&current.editor.?);
            editor_handlers.loadEditorDecorationRegistry(history, allocator);
            surfaceWarnings(history, &balance_warnings, allocator);
            // Same new-world bump as the fresh branch above.
            current.world_generation +%= 1;
            current.transitionScreen(.editor);
        },

        // --- Meta: exit/skip orchestrators ---
        .player_skip_level => {
            pushEvents(current, &.{.{ .meta_event = .{ .end_level = .{} } }}, allocator);
        },
        .player_restart_mission => {
            pushEvents(current, &.{.{ .meta_event = .{ .end_level = .{
                .continuation = .restart_mission,
            } } }}, allocator);
        },
        .player_exit_mission => {
            pushEvents(current, &.{.{ .meta_event = .{ .end_level = .{
                .continuation = .exit_mission,
            } } }}, allocator);
        },
        .player_exit_to_menu => {
            if (current.screen == .level) {
                pushEvents(current, &.{.{ .meta_event = .{ .end_level = .{
                    .continuation = .exit_to_menu,
                } } }}, allocator);
            } else if (current.screen == .hub) {
                pushEvents(current, &.{
                    .{ .meta_event = .open_main_menu },
                    .{ .meta_event = .end_hub },
                }, allocator);
            } else if (current.screen == .editor) {
                // close_editor owns the teardown AND the transition (its
                // handler calls transitionScreen(.main_menu), which clears
                // the editor via the screen-scope swap) — no sibling
                // open_main_menu needed.
                pushEvents(current, &.{.{ .meta_event = .close_editor }}, allocator);
            }
        },
        .player_replay_mission => {
            const info = current.last_completed_mission orelse return;
            const mission_path = allocator.dupe(u8, info.path) catch
                @panic("failed to allocate replay mission path");
            pushEvents(current, &.{
                .{ .meta_event = .{ .start_mission = .{
                    .mission_path = mission_path,
                    .start_hub_id = current.player_data.current_hub,
                    .end_hub_id = null,
                } } },
                .{ .meta_event = .end_hub },
            }, allocator);
        },
        // Level-tab click: switch the editor's active level. Thin orchestrator
        // — the EditorEvent owns the mutation (undo rides the timeline).
        .player_set_editor_level => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_active_level = .{
                .level_index = set.level_index,
            } } }}, allocator);
        },
        // Tool-cell click: push the machinery event (the tool pointer + the
        // selection clear live on the undo timeline together).
        .player_set_editor_tool => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_tool = .{
                .tool = set.tool,
            } } }}, allocator);
        },
        // Inspector toggle-button click: push the machinery event (the
        // panel's open state rides the undo timeline with the edits).
        .player_toggle_editor_inspector => {
            pushEvents(current, &.{.{ .editor_event = .editor_toggle_inspector }}, allocator);
        },
        // Settings-sidebar toggle-button click: same shape (the flag
        // lives on the Editor — the toggle is undoable).
        .player_toggle_editor_metadata_sidebar => {
            pushEvents(current, &.{.{ .editor_event = .editor_toggle_metadata_sidebar }}, allocator);
        },
        // Top-bar Test button: start a playtest of the ACTIVE level (the
        // machinery handler owns instantiation + dormancy + the screen
        // transition). validatePlayerAction guarantees the editor screen +
        // edit mode, so the force-unwrap is the fail-fast invariant.
        .player_start_playtest => {
            const editor = &current.editor.?;
            pushEvents(current, &.{.{ .meta_event = .{ .start_playtest = .{
                .level_index = @intCast(editor.active_level_index),
            } } }}, allocator);
        },
        // Top-bar Validate button: start the full-mission validation run
        // from the SAVED mission dir (the input layer saved first — the
        // machinery handler reads the files, not the editor memory). Also
        // the validate-RESTART re-entry (pushed by end_level's guard):
        // every attempt begins with this seedable orchestrator, which is
        // what lets the validation replay slice start at the last one.
        .player_start_validation => |start| {
            pushEvents(current, &.{.{ .meta_event = .{ .start_validation = .{
                .mission_path = start.mission_path,
            } } }}, allocator);
        },
        // Player inspector Import-button click: push the machinery event
        // (the loadout fields ride GameState — the import is undoable).
        .player_import_editor_player => {
            pushEvents(current, &.{.{ .editor_event = .editor_import_player }}, allocator);
        },
        // The Max player Import (the shipped data/max_player.txt loadout —
        // the author-times tool for official missions): thin forward, the
        // EditorEvent owns the mutation.
        .player_import_editor_max_player => {
            pushEvents(current, &.{.{ .editor_event = .editor_import_max_player }}, allocator);
        },
        // Palette group "+" clicks: push the machinery event (the handler
        // builds the type from the shipped defaults, makes it the active
        // tool, and opens the inspector — one undo step covers it all).
        .player_add_editor_entity_type => {
            pushEvents(current, &.{.{ .editor_event = .editor_add_entity_type }}, allocator);
        },
        .player_add_editor_decoration_type => {
            pushEvents(current, &.{.{ .editor_event = .editor_add_decoration_type }}, allocator);
        },
        .player_add_editor_item_type => {
            pushEvents(current, &.{.{ .editor_event = .editor_add_item_type }}, allocator);
        },
        // Palette tool-cell delete-button click: push the machinery
        // orchestrator — the editor_delete_type handler fans out into the
        // per-placement deletes + removes the type + remaps ids + fixes
        // the active tool, all as one undo step.
        .player_delete_editor_type => |delete| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_delete_type = .{
                .type_kind = delete.type_kind,
                .type_id = delete.type_id,
            } } }}, allocator);
        },
        // Add-level "+" click (top bar): push the machinery event — the
        // handler reads the shipped template through the reconstruction
        // cache, appends the level, switches to it, and syncs level_count;
        // one undo step reverts the whole creation.
        .player_add_editor_level => {
            pushEvents(current, &.{.{ .editor_event = .editor_add_level }}, allocator);
        },
        // Level-tab × click: push the machinery event — the handler removes
        // the level, shifts later levels down, syncs level_count, and
        // adjusts the active tab; one undo step restores it.
        .player_delete_editor_level => |delete| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_delete_level = .{
                .level_index = delete.level_index,
            } } }}, allocator);
        },
        // Settings-sidebar commits (mission + active-level metadata): thin
        // forwards — the EditorEvents own the mutations. The level-indexed
        // wrappers address the level the sidebar showed at click time.
        .player_set_editor_mission_name => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_mission_name = .{
                .name = set.name,
            } } }}, allocator);
        },
        .player_set_editor_level_name => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_level_name = .{
                .level_index = set.level_index,
                .name = set.name,
            } } }}, allocator);
        },
        .player_set_editor_level_color_wheel => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_level_color_wheel = .{
                .level_index = set.level_index,
                .color_wheel_index = set.color_wheel_index,
            } } }}, allocator);
        },
        .player_set_editor_level_enemy_gradient => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_level_enemy_gradient = .{
                .level_index = set.level_index,
                .gradient_index = set.gradient_index,
            } } }}, allocator);
        },
        .player_set_editor_level_player_gradient => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_level_player_gradient = .{
                .level_index = set.level_index,
                .gradient_index = set.gradient_index,
            } } }}, allocator);
        },
        // Inspector entity-name commit: thin forward (the EditorEvent owns
        // the mutation; recordEvent deep-copies the value slice into the
        // durable log arena).
        .player_set_editor_entity_name => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_name = .{
                .target = set.target,
                .value = set.value,
            } } }}, allocator);
        },
        // Inspector entity-sprite commit: same shape (the sprite id is a
        // plain text field in v1 — the centered sprite picker replaces it
        // later; see DESIGN → Level Editor → Editor UI layout).
        .player_set_editor_entity_sprite => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_sprite = .{
                .target = set.target,
                .value = set.value,
            } } }}, allocator);
        },
        // Inspector scalar commits (swatch pick, toggle flip, stat fields):
        // thin forwards — the EditorEvents own the mutations.
        .player_set_editor_entity_color_index => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_color_index = .{
                .target = set.target,
                .value = set.value,
            } } }}, allocator);
        },
        .player_set_editor_entity_displays_weapons => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_displays_weapons = .{
                .target = set.target,
                .value = set.value,
            } } }}, allocator);
        },
        .player_set_editor_entity_max_health => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_max_health = .{
                .target = set.target,
                .value = set.value,
            } } }}, allocator);
        },
        .player_set_editor_entity_defense => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_defense = .{
                .target = set.target,
                .value = set.value,
            } } }}, allocator);
        },
        .player_set_editor_entity_speed => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_speed = .{
                .target = set.target,
                .value = set.value,
            } } }}, allocator);
        },
        .player_set_editor_entity_aggro_range => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_aggro_range = .{
                .target = set.target,
                .value = set.value,
            } } }}, allocator);
        },
        .player_set_editor_entity_team => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_team = .{
                .target = set.target,
                .value = set.value,
            } } }}, allocator);
        },
        // The equipped-slot commit: the shared payload forwards verbatim
        // (the EditorEvent owns the mutation + the stat clamps).
        .player_set_editor_entity_gear => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_gear = set } }}, allocator);
        },
        // Inspector utility-skill commit: thin forward.
        .player_set_editor_entity_utility_skill => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_utility_skill = .{
                .target = set.target,
                .slot_index = set.slot_index,
                .value = set.value,
            } } }}, allocator);
        },
        // Inspector decoration commits: thin forwards (the EditorEvents own
        // the mutations — the def event's handler also prunes the type's
        // now-invalid placements).
        .player_set_editor_decoration_def => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_decoration_def = .{
                .type_id = set.type_id,
                .sprite = set.sprite,
                .footprint = set.footprint,
                .pixel_dims = set.pixel_dims,
                .color_index = set.color_index,
                .layers = set.layers,
            } } }}, allocator);
        },
        .player_set_editor_decoration_color_index => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_decoration_color_index = .{
                .type_id = set.type_id,
                .value = set.value,
            } } }}, allocator);
        },
        // The footprint editor's confirm: thin forward (the EditorEvent
        // owns the mutation + the placement prune).
        .player_set_editor_decoration_footprint => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_decoration_footprint = .{
                .type_id = set.type_id,
                .value = set.value,
            } } }}, allocator);
        },
        // Inspector item commits (the Items palette group): thin forwards
        // — the EditorEvents own the mutations + the id sync.
        .player_set_editor_item_def => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_item_def = .{
                .type_id = set.type_id,
                .item_kind = set.item_kind,
                .weapon_type = set.weapon_type,
                .name = set.name,
                .weapon_damage = set.weapon_damage,
                .spell_damage = set.spell_damage,
                .health_bonus = set.health_bonus,
                .defense_bonus = set.defense_bonus,
                .damage_bonus = set.damage_bonus,
                .pickup_radius_bonus = set.pickup_radius_bonus,
                .speed_bonus = set.speed_bonus,
            } } }}, allocator);
        },
        .player_set_editor_item_name => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_item_name = .{
                .type_id = set.type_id,
                .value = set.value,
            } } }}, allocator);
        },
        // Inspector inventory-slot commits (the player loadout's
        // Inventory section) — thin forwards, the EditorEvents own the
        // mutations.
        .player_add_editor_inventory_item => |add| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_add_inventory_item = .{
                .index = add.index,
            } } }}, allocator);
        },
        .player_delete_editor_inventory_item => |delete| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_delete_inventory_item = .{
                .index = delete.index,
            } } }}, allocator);
        },
        .player_set_editor_inventory_item_def => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_inventory_item_def = .{
                .index = set.index,
                .item_kind = set.item_kind,
                .weapon_type = set.weapon_type,
                .name = set.name,
                .weapon_damage = set.weapon_damage,
                .spell_damage = set.spell_damage,
                .health_bonus = set.health_bonus,
                .defense_bonus = set.defense_bonus,
                .damage_bonus = set.damage_bonus,
                .pickup_radius_bonus = set.pickup_radius_bonus,
                .speed_bonus = set.speed_bonus,
            } } }}, allocator);
        },
        .player_set_editor_inventory_item_name => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_inventory_item_name = .{
                .index = set.index,
                .value = set.value,
            } } }}, allocator);
        },
        // Inspector layer commits (the Layers sections): thin forwards.
        // The player loadout has no layers — the handler ignores a
        // player_def entity-layer target (validation rejects it at the
        // replay seam).
        .player_add_editor_entity_layer => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_add_entity_layer = .{
                .target = set.target,
                .sprite = set.sprite,
                .color_index = set.color_index,
            } } }}, allocator);
        },
        .player_remove_editor_entity_layer => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_remove_entity_layer = .{
                .target = set.target,
                .layer_index = set.layer_index,
            } } }}, allocator);
        },
        .player_set_editor_entity_layer => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_layer = .{
                .target = set.target,
                .layer_index = set.layer_index,
                .sprite = set.sprite,
                .color_index = set.color_index,
            } } }}, allocator);
        },
        .player_add_editor_decoration_layer => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_add_decoration_layer = .{
                .type_id = set.type_id,
                .sprite = set.sprite,
                .color_index = set.color_index,
                .pixel_dims = set.pixel_dims,
            } } }}, allocator);
        },
        .player_remove_editor_decoration_layer => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_remove_decoration_layer = .{
                .type_id = set.type_id,
                .layer_index = set.layer_index,
            } } }}, allocator);
        },
        .player_set_editor_decoration_layer => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_decoration_layer = .{
                .type_id = set.type_id,
                .layer_index = set.layer_index,
                .sprite = set.sprite,
                .color_index = set.color_index,
                .pixel_dims = set.pixel_dims,
            } } }}, allocator);
        },
        // Select-tool click: thin over the shared planner (the input layer
        // fires only nonempty plans — see planning.planEditorSelectionActions).
        .player_toggle_editor_selection => |toggle| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorSelectionActions(editor, toggle.position, allocator), allocator);
            }
        },
        // Select-tool plain click: thin over the shared planner (the input
        // layer fires only nonempty plans — see
        // planning.planEditorReplaceSelectionActions).
        .player_replace_editor_selection => |replace| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorReplaceSelectionActions(editor, replace.position, allocator), allocator);
            }
        },
        // Select-tool marquee release: thin over the shared planner (the
        // gesture handler fires only nonempty plans — see
        // planning.planEditorRegionSelectActions).
        .player_select_editor_region => |select| {
            if (current.editor) |*editor| {
                pushEvents(
                    current,
                    planning.planEditorRegionSelectActions(editor, select.start_position, select.end_position, allocator),
                    allocator,
                );
            }
        },
        // Select-tool ctrl+A: thin over the shared planner (the input layer
        // fires only nonempty plans — see planning.planEditorSelectAllActions).
        .player_select_editor_all => {
            if (current.editor) |*editor| {
                pushEvents(
                    current,
                    planning.planEditorSelectAllActions(editor, allocator),
                    allocator,
                );
            }
        },
        // Select-tool Delete key: thin over the shared planner (the input
        // layer fires only nonempty plans — see
        // planning.planEditorSelectionDeleteActions).
        .player_delete_editor_selection => {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorSelectionDeleteActions(editor, allocator), allocator);
            }
        },
        // Select-tool ctrl+D: push the single clear event.
        .player_clear_editor_selection => {
            pushEvents(current, &.{.{ .editor_event = .editor_clear_selection }}, allocator);
        },
        // Select-tool move-drag release: back the selection up as concrete
        // things at their translated positions, then push [commit link 0,
        // …clear plan] — LIFO runs the clear phase first, then the commit
        // chain places the worklist one entry at a time against the live
        // post-clear state (see editor_commit_selection_move).
        .player_move_editor_selection => |move| {
            if (current.editor) |*editor| {
                const level = planning.activeEditorLevel(editor) orelse return;
                var entries: std.ArrayList(types.EditorSelectionMoveEntry) = .empty;
                for (editor.selection) |selected| {
                    switch (selected) {
                        .entity_placement => |index| {
                            if (index < level.entity_placements.len) {
                                const placement = level.entity_placements[index];
                                entries.append(allocator, .{ .entity = .{
                                    .type_id = placement.type_id,
                                    .position = planning.translatedPosition(placement.position, move.delta),
                                } }) catch @panic("failed to allocate editor selection move entries");
                            }
                        },
                        .decoration_placement => |index| {
                            if (index < level.decoration_placements.len) {
                                const placement = level.decoration_placements[index];
                                entries.append(allocator, .{ .decoration = .{
                                    .type_id = placement.type_id,
                                    .position = planning.translatedPosition(placement.position, move.delta),
                                } }) catch @panic("failed to allocate editor selection move entries");
                            }
                        },
                        .ground_item_placement => |index| {
                            if (index < level.item_placements.len) {
                                const placement = level.item_placements[index];
                                entries.append(allocator, .{ .item = .{
                                    .type_id = placement.type_id,
                                    .position = planning.translatedPosition(placement.position, move.delta),
                                } }) catch @panic("failed to allocate editor selection move entries");
                            }
                        },
                        .tile => |position| {
                            entries.append(allocator, .{ .tile = planning.translatedPosition(position, move.delta) }) catch
                                @panic("failed to allocate editor selection move entries");
                        },
                        .player_start => {
                            entries.append(allocator, .{ .player_start = planning.translatedPosition(level.player_start, move.delta) }) catch
                                @panic("failed to allocate editor selection move entries");
                        },
                        .level_end => {
                            if (level.level_end) |level_end_position| {
                                entries.append(allocator, .{ .level_end = planning.translatedPosition(level_end_position, move.delta) }) catch
                                    @panic("failed to allocate editor selection move entries");
                            }
                        },
                    }
                }
                var push: std.ArrayList(Event) = .empty;
                push.append(allocator, .{ .editor_event = .{ .editor_commit_selection_move = .{
                    .entries = entries.items,
                    .next_index = 0,
                } } }) catch @panic("failed to allocate editor selection move plan");
                push.appendSlice(allocator, planning.planEditorSelectionMoveDeleteActions(editor, allocator)) catch
                    @panic("failed to allocate editor selection move plan");
                pushEvents(current, push.items, allocator);
            }
        },
        // Tile-paint click: thin over the shared planner (the input layer
        // fires only nonempty plans — see planning.planEditorTilePaintActions).
        .player_paint_editor_tile => |paint| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorTilePaintActions(editor, paint.position, allocator), allocator);
            }
        },
        // Enemy-tool click: thin over the shared planner (the input layer
        // fires only nonempty plans — see planning.planEditorEntityPlacementActions).
        .player_place_editor_entity => |place| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorEntityPlacementActions(editor, place.type_id, place.position, allocator), allocator);
            }
        },
        // Decoration-tool click: thin over the shared planner (the input
        // layer fires only nonempty plans — see
        // planning.planEditorDecorationPlacementActions).
        .player_place_editor_decoration => |place| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorDecorationPlacementActions(editor, place.type_id, place.position, allocator), allocator);
            }
        },
        // Ground-item-tool click: thin over the shared planner (the input
        // layer fires only nonempty plans — see
        // planning.planEditorItemPlacementActions).
        .player_place_editor_item => |place| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorItemPlacementActions(editor, place.type_id, place.position, allocator), allocator);
            }
        },
        // Editor right-click delete: thin over the shared planner (the
        // input layer fires only nonempty plans — see
        // planning.planEditorDeleteActions).
        .player_delete_editor_at => |delete| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorDeleteActions(editor, delete.position, allocator), allocator);
            }
        },
        .player_overwrite_clone => {
            // Replace the existing clone for this mission with the just-
            // completed run's data. Only offered when overwrite_offered is
            // set (a clone exists + the run was not strictly better). See
            // DESIGN → Clones (clone system).
            const info = current.last_completed_mission orelse return;
            pushEvents(current, &.{.{ .super_event = .{ .save_clone_info = .{
                .mission_uuid = info.uuid,
                .mission_name = info.name,
                .total_turns = info.turns_spent,
                .total_materials = info.converted_materials,
            } } }}, allocator);
        },

        // --- Player: swap weapons ---
        .swap_hands => {
            const player = getPlayerEntity(current, 0);
            const held_weapon = player.main_hand_weapon;
            player.main_hand_weapon = player.off_hand_weapon;
            player.off_hand_weapon = held_weapon;
            cancelPreparedSkill(current);
        },

        // --- Hub: movement + NPC interaction ---
        .move_player => |move| {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .move);
            if (current.hub) |*hub| {
                hub.player.position = move.destination;
                for (hub.mission_exits) |exit| {
                    if (exit.position.x == move.destination.x and
                        exit.position.y == move.destination.y)
                    {
                        const mission_path = std.fmt.allocPrint(
                            allocator,
                            "data/campaigns/{s}/missions/{s}",
                            .{ current.player_data.current_campaign, exit.mission_id },
                        ) catch @panic("failed to allocate mission path");
                        pushEvents(current, &.{
                            .{ .meta_event = .{ .start_mission = .{
                                .mission_path = mission_path,
                                .start_hub_id = current.player_data.current_hub,
                                .end_hub_id = null,
                            } } },
                            .{ .meta_event = .end_hub },
                        }, allocator);
                        break;
                    }
                }
            }
        },
        .interact_with_npc => {},

        // --- Level: player-action orchestrators ---
        .player_move_action => |action| {
            pushEvents(current, &.{
                .{ .level_event = .{ .player_turn_attack = .{
                    .force_attack_step = action.force_attack_step,
                } } },
                .{ .level_event = .clear_highlights },
                .{ .level_event = .{ .move_entity = .{
                    .entity_index = 0,
                    .destination = action.destination,
                } } },
            }, allocator);
        },
        .player_skip_move => |skip| {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .skip);
            pushEvents(current, &.{
                .{ .level_event = .{ .player_turn_attack = .{
                    .force_attack_step = skip.force_attack_step,
                } } },
                .{ .level_event = .clear_highlights },
            }, allocator);
        },
        .player_skip_move_to_skill => |skip| {
            if (skip.prepare) {
                pushEvents(current, &.{
                    .{ .player_input_event = .{ .player_prepare_skill = .{
                        .caster_index = 0,
                        .skill_id = skip.skill_id,
                    } } },
                    .{ .level_event = .{ .player_turn_attack = .{
                        .force_attack_step = true,
                    } } },
                    .{ .level_event = .clear_highlights },
                }, allocator);
            } else {
                pushEvents(current, &.{
                    .{ .player_input_event = .{ .player_use_skill = .{
                        .skill_id = skip.skill_id,
                        .target = skip.target,
                    } } },
                    .{ .level_event = .{ .player_turn_attack = .{
                        .force_attack_step = true,
                    } } },
                    .{ .level_event = .clear_highlights },
                }, allocator);
            }
        },
        .player_cancel_skill => {
            pushEvents(current, &.{
                .{ .level_event = .clear_highlights },
                .{ .level_event = .clear_prepared_skill },
            }, allocator);
        },
        .player_skip_attack => {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .skip);
            pushEvents(current, &.{
                .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
                .{ .level_event = .clear_highlights },
                .{ .level_event = .clear_prepared_skill },
            }, allocator);
        },
        .player_use_skill => |use| {
            const ends_turn = if (lookups.getSkillDefinition(use.skill_id)) |def|
                (def.skill_type == .weapon_skill or def.skill_type == .spell)
            else
                false;
            if (ends_turn) {
                pushEvents(current, &.{
                    .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
                    .{ .level_event = .{ .use_skill = .{
                        .caster_index = 0,
                        .skill_id = use.skill_id,
                        .target = use.target,
                    } } },
                    .{ .level_event = .clear_highlights },
                    .{ .level_event = .clear_prepared_skill },
                }, allocator);
            } else {
                pushEvents(current, &.{
                    .{ .level_event = .{ .use_skill = .{
                        .caster_index = 0,
                        .skill_id = use.skill_id,
                        .target = use.target,
                    } } },
                    .{ .level_event = .clear_highlights },
                    .{ .level_event = .clear_prepared_skill },
                }, allocator);
            }
        },
        .player_prepare_skill => |prepare| {
            const level = &current.level.?;
            level.prepared_skill = prepare.skill_id;
            if (lookups.getSkillDefinition(prepare.skill_id)) |skill_definition| {
                if (skill_definition.playerPrepareSkill(prepare.caster_index, current.*, allocator)) |event| {
                    pushEvents(current, &.{event}, allocator);
                }
            }
        },

        // --- Inventory/gear/skill: click + drag orchestrators ---
        // Each pushes the machinery event(s) as a child. The orchestrator
        // carries only the player's intent; all mutation is in the verbs.
        // See DESIGN → Architecture (orchestrator convention) + DESIGN →
        // Determinism & Tiebreaking (replay whitelist).
        .player_use_inventory_item => |use| {
            const player = getPlayerEntity(current, 0);
            const slot = &player.inventory.slots[use.inventory_slot_index];
            const item = slot.* orelse return;
            switch (item) {
                .weapon => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = if (use.off_hand) .off_hand else .main_hand,
                } } }}, allocator),
                .amulet => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = .amulet,
                } } }}, allocator),
                .coat => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = .coat,
                } } }}, allocator),
                .gloves => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = .gloves,
                } } }}, allocator),
                .pants => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = .pants,
                } } }}, allocator),
                .boots => pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                    .inventory_slot_index = use.inventory_slot_index,
                    .gear_slot = .boots,
                } } }}, allocator),
                .skill_tome => |tome| {
                    if (isSkillLearned(current.player_data.learned_skills, tome.skill)) {
                        pushEvents(current, &.{.{ .player_event = .{ .salvage_item = .{
                            .inventory_slot_index = use.inventory_slot_index,
                        } } }}, allocator);
                    } else {
                        pushEvents(current, &.{.{ .player_event = .{ .learn_skill = .{
                            .inventory_slot_index = use.inventory_slot_index,
                        } } }}, allocator);
                    }
                },
            }
        },
        .player_salvage_inventory_item => |salvage| {
            pushEvents(current, &.{.{ .player_event = .{ .salvage_item = .{
                .inventory_slot_index = salvage.inventory_slot_index,
            } } }}, allocator);
        },
        .player_salvage_inventory_region => |region| {
            // One salvage_item per occupied slot in the region's bounding
            // box — the slot list comes from the shared region helper (the
            // input-side no-op gate reads the same definition).
            const player = getPlayerEntity(current, 0);
            const occupied_slots = salvageRegionOccupiedSlots(
                player.*,
                region.start_slot,
                region.end_slot,
                allocator,
            );
            var salvage_events: std.ArrayList(Event) = .empty;
            for (occupied_slots) |slot_index| {
                salvage_events.append(allocator, .{ .player_event = .{ .salvage_item = .{
                    .inventory_slot_index = slot_index,
                } } }) catch @panic("failed to allocate salvage events");
            }
            pushEvents(current, salvage_events.items, allocator);
        },
        .player_equip_to_gear => |equip| {
            pushEvents(current, &.{.{ .player_event = .{ .equip_item = .{
                .inventory_slot_index = equip.inventory_slot_index,
                .gear_slot = equip.gear_slot,
            } } }}, allocator);
        },
        .player_unequip_from_gear => |unequip| {
            pushEvents(current, &.{.{ .player_event = .{ .unequip_item = .{
                .gear_slot = unequip.gear_slot,
                .inventory_slot_index = unequip.inventory_slot_index,
            } } }}, allocator);
        },
        .player_swap_inventory_items => |swap| {
            pushEvents(current, &.{.{ .player_event = .{ .swap_inventory_items = .{
                .slot_a_index = swap.slot_a_index,
                .slot_b_index = swap.slot_b_index,
            } } }}, allocator);
        },
        .player_assign_utility_skill => |assign| {
            // Enforce no duplicate utility skills on the bar: if the dragged
            // skill already occupies a utility slot, swap the target slot with
            // that slot (the skill moves, the displaced target contents land
            // where the skill was) instead of assigning a second copy. A drop
            // onto the slot that already holds this skill is a no-op. The bar's
            // weapon skills (slots 1-3, derived from the equipped weapon) are
            // a separate, non-overlapping set in shipped content, so the
            // search is over the utility slots only. See DESIGN → Architecture.
            if (assign.slot_index >= utility_skill_count) return;
            const player = getPlayerEntity(current, 0);
            var existing_slot: ?u32 = null;
            for (player.equipped_utility_skills, 0..) |slot_skill, index| {
                if (slot_skill) |skill| if (skill == assign.skill_id) {
                    existing_slot = @intCast(index);
                    break;
                };
            }
            if (existing_slot) |source_index| {
                if (source_index == assign.slot_index) return; // already there
                pushEvents(current, &.{.{ .player_event = .{ .swap_utility_skills = .{
                    .slot_a_index = assign.slot_index,
                    .slot_b_index = source_index,
                } } }}, allocator);
                return;
            }
            pushEvents(current, &.{.{ .player_event = .{ .equip_utility_skill = .{
                .skill_id = assign.skill_id,
                .slot_index = assign.slot_index,
            } } }}, allocator);
        },
        .player_swap_utility_skills => |swap| {
            pushEvents(current, &.{.{ .player_event = .{ .swap_utility_skills = .{
                .slot_a_index = swap.slot_a_index,
                .slot_b_index = swap.slot_b_index,
            } } }}, allocator);
        },
        .player_clear_utility_skill => |clear| {
            pushEvents(current, &.{.{ .player_event = .{ .unequip_utility_skill = .{
                .slot_index = clear.slot_index,
            } } }}, allocator);
        },
    }
}
