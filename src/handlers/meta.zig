//! Session-flow events: `handleMetaEvent`, the `.meta_event` arm of
//! processEvent - screen transitions, save/load, campaign/hub/mission
//! flow, level lifecycle, the editor framing (open/close + playtest/
//! validate enter/exit), and the autosave/export side effects. The
//! checkpoint policy for start_level/start_hub lives in the dispatch
//! (processEvent), not here.

const std = @import("std");
const types = @import("../types.zig");
const events = @import("../events.zig");
const state = @import("../state.zig");
const parser = @import("../parser.zig");
const loaders = @import("../loaders.zig");
const writers = @import("../writers.zig");
const file_source_mod = @import("../file_source.zig");
const deep_copy = @import("../deep_copy.zig");
const event_push = @import("../event_push.zig");
const skill_helpers = @import("../skill_helpers.zig");
const shared = @import("shared.zig");
const player_handlers = @import("player.zig");
const editor_handlers = @import("../editor/handlers.zig");
const editor_mission_io = @import("../editor/mission_io.zig");
const session_log = @import("../session_log.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;
const deepCopy = deep_copy.deepCopy;
const pushEvents = event_push.pushEvents;
const failReconstructionRead = shared.failReconstructionRead;
const surfaceWarnings = shared.surfaceWarnings;
const validateConfigKeys = shared.validateConfigKeys;
const hubDirForUuid = shared.hubDirForUuid;
const discoverHub = shared.discoverHub;
const loadCampaignAndPushHub = shared.loadCampaignAndPushHub;
const pushGameplayStartEvents = shared.pushGameplayStartEvents;

/// Handle a `MetaEvent` - session-flow transitions (menus, saves, campaign/
/// hub/mission/level lifecycle, editor framing, waits). Called from
/// processEvent's `.meta_event` arm, which owns the start_level/start_hub
/// checkpoint policy.
pub fn handleMetaEvent(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    meta: events.MetaEvent,
) void {
    const current = &history.current_state;
    switch (meta) {
        .open_main_menu => {
            current.transitionScreen(.main_menu);
        },
        .load_save => |load| {
            var balance_warnings: std.ArrayList([]const u8) = .empty;
            const parsed_sections = blk: {
                const bytes = history.readReconstructionFile(load.save_path) catch {
                    // Missing/unreadable save (e.g. a deleted
                    // autosave after the menu offered Continue) is
                    // recoverable per DESIGN → Error Handling →
                    // context 2 - popup + revert, not a crash. If it
                    // was the autosave, hide Continue so the user
                    // doesn't retry into the same error.
                    if (std.mem.eql(u8, load.save_path, writers.autosave_path)) {
                        history.session.autosave_available = false;
                    }
                    failReconstructionRead(history, "failed to read save file");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator, &parser.player_save_sections) catch {
                    failReconstructionRead(history, "failed to parse save file");
                    return;
                };
            };
            validateConfigKeys(history, parsed_sections, parser.player_save_key_map, load.save_path, allocator);

            current.player_data = loaders.loadPlayerSave(
                parsed_sections,
                allocator,
                load.save_path,
                &balance_warnings,
            ) catch {
                failReconstructionRead(history, "failed to parse save file");
                return;
            };
            surfaceWarnings(history, &balance_warnings, allocator);

            loadCampaignAndPushHub(current, history, allocator);
            if (history.load_error) return;
        },
        .write_save => |write| {
            // Side effect: skip during replay so undo/redo scrubbing
            // doesn't rewrite the save (or spam download prompts on web).
            if (history.replaying) return;
            // A write failure is recoverable: the state is fine, just
            // the file didn't write. Surface a popup + abort the write;
            // don't crash. See DESIGN → Error Handling → three contexts.
            writers.writePlayerSaveToFile(
                history.file_source,
                write.save_path,
                current.player_data,
                allocator,
            ) catch {
                history.session.setPendingError(
                    history.history_arena.allocator(),
                    "failed to write save file",
                );
                return;
            };
            // On web, the timestamped save (not the autosave - that's
            // the in-session resume path in the in-memory persistent dir)
            // is also offered to the player as a browser download, so a
            // save file on disk doesn't require digging through browser
            // storage. No-op on native. See DESIGN → File System & IO.
            if (!std.mem.eql(u8, write.save_path, writers.autosave_path)) {
                file_source_mod.triggerBrowserDownload(allocator, write.save_path, std.fs.path.basename(write.save_path));
            }
        },
        .backup_autosave => {
            // Side effect: skip during replay (undo/redo scrubbing
            // must not re-copy files). See DESIGN → File System & IO.
            if (history.replaying) return;
            // No autosave present → nothing to back up.
            if (!history.file_source.fileExists(writers.autosave_path)) return;
            // Pure file copy: read the autosave bytes, write them at
            // a timestamped backup path. Best-effort - a failure
            // surfaces the popup but does NOT abort the new game
            // (the backup is preservation, not a prerequisite).
            const autosave_bytes = history.file_source.readFile(
                allocator,
                writers.autosave_path,
            ) catch {
                history.session.setPendingError(
                    history.history_arena.allocator(),
                    "failed to back up autosave",
                );
                return;
            };
            defer allocator.free(autosave_bytes);
            // The backup file name: the shared session-log timestamp with
            // the autosave- prefix. See TODO → Logging & Replay.
            const timestamp = session_log.formatSessionTimestamp(allocator, history.io);
            defer allocator.free(timestamp);
            const backup_path = std.fmt.allocPrint(
                allocator,
                "saves/autosave-{s}.txt",
                .{timestamp},
            ) catch @panic("failed to allocate backup path");
            defer allocator.free(backup_path);
            history.file_source.writeFile(backup_path, autosave_bytes) catch {
                history.session.setPendingError(
                    history.history_arena.allocator(),
                    "failed to back up autosave",
                );
                return;
            };
        },
        .install_campaign => |install| {
            // Cross-campaign world-map acting (see DESIGN → Campaigns &
            // the Campaign Editor → Campaign switching): swap the active
            // campaign to the event's named one. The graph loads through
            // the reconstruction cache (a recorded read - replay is
            // deterministic), the PlayerData identity fields follow, and
            // NO screen transition happens - the event rides inside a
            // map-acting cascade beneath the real arrival/entry (the
            // player_travel_to_hub / player_start_mission_from_map
            // orchestrators). A read/parse failure takes the recoverable
            // path (popup + revert).
            shared.installCampaignGraph(current, history, allocator, install.campaign_dir);
            if (current.campaign == null) return; // failReconstructionRead fired
            // The recorded payload's uuid is the identity the click
            // resolved against (the viewed graph); a mismatch means the
            // dir's content changed between the click and the drain -
            // the untrusted-content posture (warn + proceed).
            if (install.campaign_uuid.len > 0 and
                current.campaign.?.uuid.len > 0 and
                !std.mem.eql(u8, install.campaign_uuid, current.campaign.?.uuid))
            {
                var campaign_warnings: std.ArrayList([]const u8) = .empty;
                defer campaign_warnings.deinit(allocator);
                campaign_warnings.append(allocator, std.fmt.allocPrint(
                    allocator,
                    "campaign '{s}' identity changed since the map click (expected uuid {s}, found {s})",
                    .{ current.campaign.?.dir, install.campaign_uuid, current.campaign.?.uuid },
                ) catch @panic("failed to format campaign identity warning")) catch
                    @panic("failed to append campaign identity warning");
                surfaceWarnings(history, &campaign_warnings, allocator);
            }
        },
        .start_hub => |start| {
            var balance_warnings: std.ArrayList([]const u8) = .empty;
            // Resolve the hub uuid to its dir through the loaded
            // campaign's table (state, never the filesystem - replay
            // derives the same path from the same state). A hub uuid the
            // table can't resolve is a hand-edited dangling reference:
            // the recoverable popup, not a crash.
            const hub_dir = hubDirForUuid(current, start.hub_id) orelse {
                const message = std.fmt.allocPrint(
                    history.history_arena.allocator(),
                    "start_hub: no hub resolves to uuid '{s}' in campaign '{s}'",
                    .{ start.hub_id, current.player_data.current_campaign },
                ) catch @panic("failed to format hub resolution error");
                history.session.setPendingError(history.history_arena.allocator(), message);
                return;
            };
            // Build hub file path: campaigns/{campaign}/hubs/{hub_dir}/hub.txt
            // (content-root-relative - see DESIGN → Campaigns & the
            // Campaign Editor → Campaign content paths).
            const hub_path = std.fmt.allocPrint(
                allocator,
                "campaigns/{s}/hubs/{s}/hub.txt",
                .{ current.player_data.current_campaign, hub_dir },
            ) catch @panic("failed to allocate hub path");

            const hub_sections = blk: {
                const bytes = history.readReconstructionFile(hub_path) catch {
                    failReconstructionRead(history, "failed to read hub file");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator, &parser.hub_sections) catch {
                    failReconstructionRead(history, "failed to parse hub file");
                    return;
                };
            };
            validateConfigKeys(history, hub_sections, parser.hub_key_map, hub_path, allocator);

            current.hub = loaders.loadHub(
                hub_sections,
                history.file_source,
                allocator,
                hub_path,
                &balance_warnings,
            ) catch {
                failReconstructionRead(history, "failed to parse hub file");
                return;
            };
            surfaceWarnings(history, &balance_warnings, allocator);

            current.player_data.current_hub = start.hub_id;
            // Discovery: arriving IS discovering (the ONE rule - new
            // game, mission completion, travel, cross-campaign entry,
            // mission-from-map all land here). Idempotent append into
            // the active campaign's group (DESIGN → Campaigns & the
            // Campaign Editor → Discovery + travel).
            discoverHub(current, allocator, start.hub_id);
            current.world_generation +%= 1;
            current.transitionScreen(.hub);

            // Set/clear the mission-complete overlay info. Non-null
            // when this hub entry follows a mission completion (the
            // overlay renders); null on a normal entry (clears any
            // stale value). On the undo timeline via GameState. See
            // DESIGN → Architecture.
            current.last_completed_mission = start.completed_mission;

            // Sync player entity from PlayerData
            pushEvents(current, &.{.{ .super_event = .{ .build_player_from_data = .{
                .entity_index = 0,
            } } }}, allocator);
        },
        .end_hub => {
            // Preserve the player entity's changes back into PlayerData
            // before the hub is discarded/replaced, then autosave the
            // synced data. Pushed on top so both run before whatever
            // continuation the exit path stacked below (LIFO): sync
            // first, then the write reads the synced PlayerData. All
            // hub-exit paths must route through here. See DESIGN →
            // File System & IO (autosave).
            pushEvents(current, &.{
                .{ .meta_event = .{ .write_save = .{ .save_path = writers.autosave_path } } },
                .{ .super_event = .{ .build_data_from_player = .{
                    .entity_index = 0,
                } } },
            }, allocator);
        },
        .close_editor => {
            // Tear down the editor session and return to the main menu.
            // transitionScreen clears editor (old scope .editor, new
            // scope .main_menu has no editor).
            current.transitionScreen(.main_menu);
        },
        .start_playtest => |start| {
            // Instantiate the chosen level from the editor's palette +
            // player_def into a concrete gameplay Level. Discard
            // semantics: the editor's levels/palette are untouched.
            const editor = &current.editor.?;
            current.level = loaders.instantiateEditorLevel(editor.*, start.level_index, allocator);
            current.mission = deepCopy(types.Mission, editor.mission, allocator);
            current.mission.?.current_level_index = start.level_index + 1; // 1-based for gameplay handlers
            // Dormancy (only when ENTERING from edit mode - a
            // validation run chains later levels via start_playtest
            // in .validate mode, and re-backing-up would capture the
            // run's own data): back up the session's real player
            // data, build the run's (all utility skills learned).
            if (editor.mode == .edit) {
                editor.pre_playtest_player_data = deepCopy(types.PlayerData, current.player_data, allocator);
                current.player_data = editor_handlers.buildPlaytestPlayerData(allocator, editor.player_def.template);
            }
            if (editor.mode == .edit) editor.mode = .playtest;
            current.world_generation +%= 1;
            current.transitionScreen(.level);
            pushGameplayStartEvents(current, allocator, false);
        },
        .end_playtest => {
            // Discard the playtest level + mission, restore the editor.
            // transitionScreen(.editor) clears level + mission (out of
            // scope) but keeps editor (.level scope includes editor).
            current.editor.?.mode = .edit;
            editor_handlers.restorePrePlaytestPlayerData(current);
            current.transitionScreen(.editor);
        },
        .start_validation => |start| {
            // A new run retires the previous validation's manual-overwrite
            // offer (side-effect state - gated so replay scrubbing can't
            // eat a pending offer).
            if (!history.replaying) {
                editor_mission_io.clearPendingValidationReplay(history);
            }
            // File-based validation: run the SAVED artifact, not the editor
            // memory - the run certifies the files a player receives (the
            // save's bounding-box translation + palette dedup make file ≠
            // memory, so this doubles as a round-trip test of the writer).
            // Reads mission.txt + player.txt from the saved dir through the
            // reconstruction cache, then chains the campaign's own
            // start_level path (which reads each level_N.txt the same
            // way). The editor stays dormant and untouched. See DESIGN →
            // Level Editor → Playtest/validate framing + DESIGN → Custom
            // Missions & Online Services → Validation replay.
            const mission_file_path = std.fmt.allocPrint(
                allocator,
                "{s}/mission.txt",
                .{start.mission_path},
            ) catch @panic("failed to allocate mission path");
            const mission_sections = blk: {
                const bytes = history.readReconstructionFile(mission_file_path) catch {
                    failReconstructionRead(history, "failed to read mission file");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator, &parser.mission_sections) catch {
                    failReconstructionRead(history, "failed to parse mission file");
                    return;
                };
            };
            validateConfigKeys(history, mission_sections, parser.mission_key_map, mission_file_path, allocator);
            current.mission = loaders.loadMission(mission_sections, allocator) catch {
                failReconstructionRead(history, "failed to parse mission file");
                return;
            };
            current.mission.?.path = start.mission_path;
            current.mission.?.current_level_index = 1;
            current.mission.?.level_count = shared.countMissionLevelsCached(
                history,
                start.mission_path,
                allocator,
            ) catch {
                failReconstructionRead(history, "failed to read mission level files");
                return;
            };
            // The no-editor validation marker (end_level's guard reads it
            // when no Editor exists - cross-session replay of a validation
            // replay). Rides the working copy: replay reproduces it, and
            // the end_validation transition discards it with the mission.
            current.mission.?.validation_run = true;
            // Entering a run retires any prior completion overlay info.
            current.last_completed_mission = null;

            // The run's player data: the SAVED player.txt loadout with
            // every utility skill learned (the playtest path builds from
            // the in-memory player_def instead - quick iteration on the
            // draft). playerLoadoutEntity maps the same field set
            // build_player_from_data maps, so the chained start_level's
            // player sync round-trips the loadout identically.
            const player_file_path = std.fmt.allocPrint(
                allocator,
                "{s}/player.txt",
                .{start.mission_path},
            ) catch @panic("failed to allocate player path");
            const player_sections = blk: {
                const bytes = history.readReconstructionFile(player_file_path) catch {
                    failReconstructionRead(history, "failed to read player file");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator, &parser.player_loadout_sections) catch {
                    failReconstructionRead(history, "failed to parse player file");
                    return;
                };
            };
            validateConfigKeys(history, player_sections, parser.player_loadout_key_map, player_file_path, allocator);
            const player_template = loaders.loadPlayerLoadout(
                player_sections,
                allocator,
                player_file_path,
                null,
            ) catch {
                failReconstructionRead(history, "failed to parse player file");
                return;
            };
            // Dormancy - the playtest shape, but only when an Editor
            // exists: a cross-session replay of a validation replay starts
            // with no editor, and there is nothing to back up or restore
            // (the run data is rebuilt below either way).
            if (current.editor) |*editor| {
                editor.pre_playtest_player_data = deepCopy(types.PlayerData, current.player_data, allocator);
                editor.mode = .validate;
            }
            current.player_data = editor_handlers.buildPlaytestPlayerData(allocator, player_template);
            // start_level owns the transition, the level read, and the
            // player sync (the campaign path - its world_generation bump
            // is the editor→level UI reset signal).
            pushEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                .mission_path = start.mission_path,
                .level_index = 1,
            } } }}, allocator);
        },
        .end_validation => |end| {
            // A successful run writes its replay (the personal-best guard
            // decides auto-write vs stash+offer) - a save_game-class side
            // effect: the recorded event owns it, replay never re-fires.
            // See DESIGN → Custom Missions & Online Services →
            // Validation replay.
            if (end.success and !history.replaying) {
                editor_mission_io.writeValidationReplay(history);
            }
            if (end.success) {
                // The stats screen: populate the mission-complete info so
                // the overlay renders over the editor (view() draws it
                // whenever last_completed_mission is set - no hub gating).
                // A pure GameState write - reproduced on replay (the
                // overlay itself is view-side; the session-side personal
                // best / medal context is captured at the write site).
                // The clone fields are zeroed - validation is
                // discard-semantics, no clone harvest.
                if (current.mission) |*mission| {
                    current.last_completed_mission = .{
                        .uuid = mission.uuid,
                        .name = mission.name,
                        .path = mission.path,
                        .turns_spent = mission.turns_spent,
                        .converted_materials = mission.converted_materials_collected,
                        .tiles_moved = mission.tiles_moved,
                        .damage_dealt = mission.damage_dealt,
                        .damage_taken = mission.damage_taken,
                        .skills_used = mission.skills_used,
                        .validation = true,
                    };
                }
            }
            // Restore after a validation run. Live (editor present): edit
            // mode + the editor screen, the session's real player data
            // restored, the run's mission + level discarded by the
            // transition (validation_run dies with the mission). In
            // cross-session replay of a validation replay there is no
            // editor - nothing to restore, land on the main menu (this is
            // the slice's last event; the post-run state is irrelevant to
            // what the replay certifies).
            if (current.editor) |*editor| {
                editor.mode = .edit;
                editor_handlers.restorePrePlaytestPlayerData(current);
                current.transitionScreen(.editor);
            } else {
                current.transitionScreen(.main_menu);
            }
        },
        .start_mission => |start| {
            const mission_file_path = std.fmt.allocPrint(
                allocator,
                "{s}/mission.txt",
                .{start.mission_path},
            ) catch @panic("failed to allocate mission path");

            const mission_sections = blk: {
                const bytes = history.readReconstructionFile(mission_file_path) catch {
                    failReconstructionRead(history, "failed to read mission file");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator, &parser.mission_sections) catch {
                    failReconstructionRead(history, "failed to parse mission file");
                    return;
                };
            };
            validateConfigKeys(history, mission_sections, parser.mission_key_map, mission_file_path, allocator);

            current.mission = loaders.loadMission(
                mission_sections,
                allocator,
            ) catch {
                failReconstructionRead(history, "failed to parse mission file");
                return;
            };

            current.mission.?.path = start.mission_path;
            current.mission.?.current_level_index = 1;
            current.mission.?.level_count = shared.countMissionLevelsCached(
                history,
                start.mission_path,
                allocator,
            ) catch {
                failReconstructionRead(history, "failed to read mission level files");
                return;
            };

            // Clear the mission-complete overlay info - entering a
            // mission (new game or replay) retires any prior
            // completion. On the undo timeline via GameState. See
            // DESIGN → Architecture.
            current.last_completed_mission = null;

            // Return destination: the event's end_hub_id override is the
            // ONLY source - the exit-click path passes the exit's
            // destination_hub (the campaign edge), restarts pass the live
            // value through, dreams pass null and return to the hub the
            // player was at. The override lives on the live mission
            // working copy (current_arena), so it is captured by deepCopy
            // and reproduced on replay (start_mission re-applies it from
            // the recorded event). See DESIGN → Custom Missions & Online
            // Services → Dreams + DESIGN → Campaigns & the Campaign
            // Editor → The graph model.
            if (start.end_hub_id) |hub_id| {
                current.mission.?.end_hub = hub_id;
            }

            // The world-map entry's hub of origin: the edge's start hub
            // becomes current_hub on the way in (abandoning the mission
            // returns there). A pure PlayerData write, no transition -
            // the exit-tile + restart paths pass null (they stand in the
            // hub already). See DESIGN → Campaigns & the Campaign
            // Editor → Discovery + travel.
            if (start.enter_hub_id) |hub_id| {
                current.player_data.current_hub = hub_id;
            }

            // Push the first level
            pushEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                .mission_path = start.mission_path,
                .level_index = 1,
            } } }}, allocator);
        },
        .end_mission => |end| {
            // Editor exit guard: in an editor session, end_mission
            // should never be reached (end_level's guard redirects to
            // end_validation / end_playtest), but suppress the
            // start_hub continuation defensively if it ever is. Same for
            // a no-editor validation run (cross-session replay - the
            // mission working copy carries the marker).
            if (current.editor != null) return;
            if (current.mission != null and current.mission.?.validation_run) return;
            // Return to the destination hub. Pass completed_mission
            // through so start_hub sets last_completed_mission (the
            // mission-complete overlay). Null for abandon/exits.
            if (end.hub_id) |hub_id| {
                pushEvents(current, &.{.{ .meta_event = .{ .start_hub = .{
                    .hub_id = hub_id,
                    .completed_mission = end.completed_mission,
                } } }}, allocator);
            }
        },
        .start_level => |start| {
            var balance_warnings: std.ArrayList([]const u8) = .empty;
            const level_path = std.fmt.allocPrint(
                allocator,
                "{s}/level_{d}.txt",
                .{ start.mission_path, start.level_index },
            ) catch @panic("failed to allocate level path");

            const level_sections = blk: {
                const bytes = history.readReconstructionFile(level_path) catch {
                    failReconstructionRead(history, "failed to read level file");
                    return;
                };
                break :blk parser.parseConfigFile(bytes, allocator, &parser.level_sections) catch {
                    failReconstructionRead(history, "failed to parse level file");
                    return;
                };
            };

            // Key validation: warn on unknown keys (advisory - the
            // file still loads). Catches typo'd keys that the
            // permissive parser would silently drop. See DESIGN →
            // Error Handling.
            validateConfigKeys(history, level_sections, parser.level_key_map, level_path, allocator);

            current.level = loaders.loadLevel(
                level_sections,
                history.file_source,
                allocator,
                level_path,
                &balance_warnings,
            ) catch {
                failReconstructionRead(history, "failed to parse level file");
                return;
            };
            surfaceWarnings(history, &balance_warnings, allocator);

            if (current.mission) |*mission| {
                mission.current_level_index = start.level_index;
            }

            current.world_generation +%= 1;
            current.transitionScreen(.level);
            pushGameplayStartEvents(current, allocator, true);
        },
        .end_level => |end| {
            // Validation-run exit guard: a validation run owns its exit
            // continuation whether an Editor is present (live) or not
            // (cross-session replay of a validation replay - the marker
            // rides the mission working copy, so replay reproduces it).
            // The continuation mirrors the campaign's own next-
            // start_level chaining, with validation ends instead of
            // end_mission → start_hub. build_data_from_player + the
            // autosave are skipped (discard semantics). See DESIGN →
            // Level Editor (exit guard) + DESIGN → Custom Missions &
            // Online Services → Validation replay.
            const validation_run = if (current.editor) |editor|
                editor.mode == .validate
            else
                current.mission != null and current.mission.?.validation_run;
            if (validation_run) {
                if (end.continuation == .restart_mission) {
                    // Re-run the whole mission from level 1: inline
                    // teardown (an editor's real player data + edit
                    // mode - a transitionScreen would CLEAR the event
                    // stack, eating the queued re-entry), then re-entry
                    // via the ORCHESTRATOR so every attempt in the
                    // linear stream begins with a seedable top-level
                    // player action (the validation-replay slice rule).
                    // start_validation needs no prior state, so a
                    // fresh-state reconstruction of the final attempt ≡
                    // the live re-entry.
                    if (current.editor) |*editor| {
                        editor.mode = .edit;
                        editor_handlers.restorePrePlaytestPlayerData(current);
                    }
                    pushEvents(current, &.{.{ .player_input_event = .{ .player_start_validation = .{
                        .mission_path = current.mission.?.path,
                    } } }}, allocator);
                } else if (end.continuation == .exit_to_menu) {
                    // The button means the MAIN MENU. With an editor:
                    // inline teardown + close_editor (the restore must
                    // precede close_editor, whose scope swap discards
                    // the Editor carrying the backup). Without one
                    // (cross-session replay): nothing to tear down.
                    if (current.editor) |*editor| {
                        editor.mode = .edit;
                        editor_handlers.restorePrePlaytestPlayerData(current);
                        pushEvents(current, &.{.{ .meta_event = .close_editor }}, allocator);
                    } else {
                        pushEvents(current, &.{.{ .meta_event = .open_main_menu }}, allocator);
                    }
                } else if (end.continuation != .default) {
                    // Exit Mission: abort the run - only successful
                    // runs write a replay.
                    pushEvents(current, &.{.{ .meta_event = .{ .end_validation = .{
                        .success = false,
                    } } }}, allocator);
                } else if (current.mission.?.current_level_index < current.mission.?.level_count) {
                    // Natural completion with levels left: the
                    // campaign's own next-level chain (start_level
                    // re-reads the level file through the cache; turns
                    // accumulate on the mission across levels).
                    pushEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                        .mission_path = current.mission.?.path,
                        .level_index = current.mission.?.current_level_index + 1,
                    } } }}, allocator);
                } else {
                    // Last level done: the run succeeded.
                    pushEvents(current, &.{.{ .meta_event = .{ .end_validation = .{
                        .success = true,
                    } } }}, allocator);
                }
                return;
            }
            // Editor PLAYTEST exit guard (the validation case is owned
            // above): when an editor session is active, it owns the exit
            // continuation - the gameplay default (next start_level /
            // end_mission → start_hub) is suppressed/redirected.
            // build_data_from_player is also skipped (playtest is
            // discard-semantics; the player's real PlayerData is
            // unchanged). See DESIGN → Architecture → Level Editor.
            if (current.editor) |editor| {
                switch (editor.mode) {
                    .playtest => {
                        // A restart re-runs the level FRESH. The
                        // run's teardown is done INLINE (restore the
                        // session's real player data + edit mode)
                        // rather than via end_playtest: a
                        // transitionScreen would CLEAR the event
                        // stack (see state.transitionScreen), eating
                        // the queued re-entry. The pushed
                        // start_playtest then takes the fresh-entry
                        // path (backup + rebuild from player_def).
                        // Exit-to-menu also tears down inline (the
                        // backup lives ON the Editor, which
                        // close_editor's scope swap discards) and
                        // chains close_editor - the button means the
                        // MAIN MENU, not the editor. Any OTHER exit -
                        // natural level completion or Exit Mission -
                        // drops back to the editor (the run is
                        // bracketed).
                        if (end.continuation == .restart_mission) {
                            current.editor.?.mode = .edit; // the capture is by value - mutate through the optional
                            editor_handlers.restorePrePlaytestPlayerData(current);
                            const restart_level_index = current.mission.?.current_level_index - 1; // 1-based gameplay -> 0-based
                            pushEvents(current, &.{.{ .meta_event = .{ .start_playtest = .{
                                .level_index = restart_level_index,
                            } } }}, allocator);
                        } else if (end.continuation == .exit_to_menu) {
                            current.editor.?.mode = .edit; // the capture is by value - mutate through the optional
                            editor_handlers.restorePrePlaytestPlayerData(current);
                            pushEvents(current, &.{.{ .meta_event = .close_editor }}, allocator);
                        } else {
                            pushEvents(current, &.{.{ .meta_event = .end_playtest }}, allocator);
                        }
                    },
                    .edit => {}, // shouldn't happen (no level loaded in edit mode)
                    .validate => {}, // unreachable - the validation_run block above owns the validate continuation
                }
                return;
            }
            // Clone-system scratch locals, populated by the .default
            // last-level branch below and consumed by the trailing
            // push block (LIFO: harvest → save → write_save run before
            // the end_mission/start_mission already pushed). See DESIGN
            // → Clones (clone system).
            var clone_harvest_turns: ?u32 = null;
            var clone_save_info: ?struct {
                mission_uuid: []const u8,
                mission_name: []const u8,
                total_turns: u32,
                total_materials: types.Materials,
            } = null;
            switch (end.continuation) {
                .default => {
                    if (current.mission) |mission| {
                        if (mission.current_level_index < mission.level_count) {
                            // More levels - push the next one. The
                            // level-complete sting (distinct from the
                            // final level's mission_completion below).
                            if (!history.replaying) {
                                history.session.queueSound(history.backing_allocator, .level_complete);
                            }
                            const next_index = mission.current_level_index + 1;
                            pushEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                                .mission_path = mission.path,
                                .level_index = next_index,
                            } } }}, allocator);
                        } else {
                            // Last level done - end the mission.
                            // Play the completion sound (live play
                            // only) + carry the mission info through
                            // the cascade for the mission-complete
                            // overlay (end_mission → start_hub sets
                            // GameState.last_completed_mission).
                            if (!history.replaying) {
                                history.session.queueSound(history.backing_allocator, .mission_completion);
                            }
                            // Clone decision: harvest from all old
                            // clones, then auto-save a clone for this
                            // mission on first completion or a
                            // strictly-FASTER run - turns only, the
                            // same personal-best rule as the validation
                            // replay (replayOverwriteDecision):
                            // strictly fewer turns wins, ties and slower
                            // runs keep the old clone. Otherwise flag
                            // the overlay to offer a manual overwrite
                            // button. See DESIGN → Clones (clone
                            // system).
                            const turns = mission.turns_spent;
                            const converted = mission.converted_materials_collected;
                            var existing_clone: ?types.Clone = null;
                            for (current.player_data.clones) |clone| {
                                if (std.mem.eql(u8, clone.mission_uuid, mission.uuid)) {
                                    existing_clone = clone;
                                    break;
                                }
                            }
                            var overwrite_offered = false;
                            var harvested: types.Materials = .{};
                            if (turns > 0) {
                                clone_harvest_turns = turns;
                                harvested = player_handlers.computeHarvest(current.player_data.clones, turns);
                                if (existing_clone) |old| {
                                    if (turns < old.turns_to_complete) {
                                        clone_save_info = .{
                                            .mission_uuid = mission.uuid,
                                            .mission_name = mission.name,
                                            .total_turns = turns,
                                            .total_materials = converted,
                                        };
                                    } else {
                                        overwrite_offered = true;
                                    }
                                } else {
                                    clone_save_info = .{
                                        .mission_uuid = mission.uuid,
                                        .mission_name = mission.name,
                                        .total_turns = turns,
                                        .total_materials = converted,
                                    };
                                }
                            }
                            pushEvents(current, &.{.{
                                .meta_event = .{
                                    .end_mission = .{
                                        // The override (the exit's destination) or
                                        // the entering hub - the campaign edge or
                                        // the dream fallback.
                                        .hub_id = mission.end_hub orelse current.player_data.current_hub,
                                        .completed_mission = .{
                                            .uuid = mission.uuid,
                                            .name = mission.name,
                                            .path = mission.path,
                                            .turns_spent = turns,
                                            .converted_materials = converted,
                                            .harvested_materials = harvested,
                                            .tiles_moved = mission.tiles_moved,
                                            .damage_dealt = mission.damage_dealt,
                                            .damage_taken = mission.damage_taken,
                                            .skills_used = mission.skills_used,
                                            .overwrite_offered = overwrite_offered,
                                        },
                                    },
                                },
                            }}, allocator);
                        }
                    }
                },
                // Restart: replay the mission from level 1 with the
                // current PlayerData (synced below before start_mission
                // runs). The player keeps their gear; only level
                // progress resets.
                .restart_mission => {
                    if (current.mission) |mission| {
                        pushEvents(current, &.{.{
                            .meta_event = .{
                                .start_mission = .{
                                    .mission_path = mission.path,
                                    // Carry the return destination through the
                                    // restart (a re-completed campaign mission
                                    // still ends at its edge's destination).
                                    .end_hub_id = mission.end_hub,
                                },
                            },
                        }}, allocator);
                    }
                },
                // Abandon the mission: return to the hub the player
                // was at before entering it. player_data.current_hub
                // still names the entering hub during a mission (only
                // start_hub's handler changes it). The map-acting
                // cascades suppress the return and queue their own
                // arrival beneath this end_level (the return's
                // transitionScreen would eat it - see
                // player_travel_to_hub / player_start_mission_from_map).
                .exit_mission => {
                    if (current.mission != null and !end.suppress_return_hub) {
                        const hub_id = current.player_data.current_hub;
                        pushEvents(current, &.{.{ .meta_event = .{ .end_mission = .{
                            .hub_id = hub_id,
                        } } }}, allocator);
                    }
                },
                // Quit to main menu: PlayerData is synced below
                // before open_main_menu clears the level scope.
                .exit_to_menu => {
                    pushEvents(current, &.{.{ .meta_event = .open_main_menu }}, allocator);
                },
            }
            // Preserve the player entity's changes back into PlayerData
            // before the level is discarded/replaced, then autosave the
            // synced data. Pushed last so both run on top of the
            // continuation above (LIFO): sync first, then the write
            // reads the synced PlayerData. All level-exit paths must
            // route through here. The editor early-returns above before
            // this push, so playtest/validate never autosave (discard
            // semantics - the real PlayerData is unchanged). See DESIGN
            // → File System & IO (autosave).
            //
            // On a last-level completion (.default branch above), the
            // clone system also injects `harvest_clones` (payout from
            // all old clones) and `save_clone_info` (auto-save /
            // auto-overwrite the clone for this mission) between the
            // sync and the write - LIFO array order is [write_save,
            // save_clone_info?, harvest_clones?, build_data_from_player]
            // so execution is sync → harvest → save → write. See
            // DESIGN → Clones (clone system).
            var exit_events: std.ArrayList(Event) = .empty;
            exit_events.append(allocator, .{ .meta_event = .{ .write_save = .{
                .save_path = writers.autosave_path,
            } } }) catch @panic("failed to append exit event");
            if (clone_save_info) |info| {
                exit_events.append(allocator, .{ .super_event = .{ .save_clone_info = .{
                    .mission_uuid = info.mission_uuid,
                    .mission_name = info.mission_name,
                    .total_turns = info.total_turns,
                    .total_materials = info.total_materials,
                } } }) catch @panic("failed to append save_clone_info");
            }
            if (clone_harvest_turns) |turns| {
                exit_events.append(allocator, .{ .super_event = .{ .harvest_clones = .{
                    .turns_spent = turns,
                } } }) catch @panic("failed to append harvest_clones");
            }
            exit_events.append(allocator, .{ .super_event = .{ .build_data_from_player = .{
                .entity_index = 0,
            } } }) catch @panic("failed to append build_data_from_player");
            pushEvents(current, exit_events.items, allocator);
        },
        // UI surface toggles - the class-1 surface state on GameState
        // (`ui_surfaces`); the methods own the grouped representation
        // (middle-panel order, overlay stacking). See DESIGN → UI
        // Framework → UI state classification.
        .toggle_ui_surface => |toggle| {
            current.ui_surfaces.toggle(toggle.surface);
        },
        .inspect_entity => |inspect| {
            current.ui_surfaces.inspectEntity(inspect.entity_index);
        },
        .wait => |wait_event| {
            // Begin a real-time pause; update() drains it as frames
            // elapse before the next event is processed. Record the
            // stack depth so anytime interjections (swap_weapons)
            // pushed during the wait are processed immediately down
            // to this baseline instead of delaying until the wait
            // elapses. The wait event is already popped, so this is
            // the depth of the remaining enemy-turn events.
            current.waiting = .{
                .remaining_microseconds = @as(u64, wait_event.duration_milliseconds) * 1000,
                .baseline_stack_depth = current.event_stack.len,
            };
        },
        .accelerating_wait => {
            // The intra-effect pacing wait (the accelerating counterpart of
            // `wait` - see DESIGN → Architecture → Skill pacing). Duration is
            // COMPUTED from `wait_acceleration` (how many accelerating waits
            // have elapsed since `use_skill` reset the chain): 125ms decayed
            // by 3/4 per prior gap, so a multi-hit skill winds up. The counter
            // increment is event-driven GameState, recomputed identically on
            // replay/undo - the derived durations stay deterministic.
            const duration_milliseconds = skill_helpers.acceleratedEffectStepWaitMilliseconds(
                current.wait_acceleration,
            );
            current.wait_acceleration += 1;
            current.waiting = .{
                .remaining_microseconds = @as(u64, duration_milliseconds) * 1000,
                .baseline_stack_depth = current.event_stack.len,
            };
        },
        else => {},
    }
}
