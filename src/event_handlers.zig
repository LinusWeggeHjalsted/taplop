//! Event processing — the `processEvent` dispatch and its handler helpers.
//!
//! `processEvent` pops one event from `GameState.event_stack` and applies it
//! (a pure state transform), recording it into the session log when not
//! replaying. It is the single funnel through which all undoable gameplay
//! state mutates; the input handlers (input_handlers.zig) and the live game
//! loop (main.zig) call it, and state.zig's undo/redo/reconstruct machinery
//! receives it as an `apply_event` function pointer. The editor events
//! delegate to `editor/handlers.zig`; the pure editor click planners live in
//! `editor/planning.zig`; the cross-category helpers in
//! `handlers/shared.zig`.
//!
//! Handler-internal helpers (entity accessors, gear mutators, move-highlight
//! refresh, prepared-skill cancel, AI min-range, tile tiebreak) live here too,
//! alongside the event-pushing utilities shared with the input handlers
//! (`pushEvents`/`pushPlayerSkillUse`/`pushPlayerAction` — event_push.zig). The pure editor click planners
//! (`planEditor*Actions`) + editor selection algebra live in
//! `editor/planning.zig` (see DESIGN → Level Editor → Active-tool model).

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const functions = @import("functions.zig");
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");
const writers = @import("writers.zig");
const file_source_mod = @import("file_source.zig");
const lookups = @import("generated_lookups.zig");
const deep_copy = @import("deep_copy.zig");
const Skill = @import("skills/skill.zig").Skill;
const planning = @import("editor/planning.zig");
const event_push = @import("event_push.zig");

const pushEvents = event_push.pushEvents;

const shared = @import("handlers/shared.zig");
const editor_handlers = @import("editor/handlers.zig");

const failReconstructionRead = shared.failReconstructionRead;
const surfaceWarnings = shared.surfaceWarnings;
const validateConfigKeys = shared.validateConfigKeys;
const getPlayerEntity = shared.getPlayerEntity;
const getLevelEntity = shared.getLevelEntity;
const loadCampaignAndPushHub = shared.loadCampaignAndPushHub;
const pushGameplayStartEvents = shared.pushGameplayStartEvents;
const tileBefore = functions.tileBefore;
const refreshMoveHighlights = shared.refreshMoveHighlights;
const player_handlers = @import("handlers/player.zig");
const player_input = @import("handlers/player_input.zig");
const level_handlers = @import("handlers/level.zig");

const deepCopy = deep_copy.deepCopy;

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;
const Vector2 = types.Vector2;
const Entity = types.Entity;
const SkillId = types.SkillId;
const Level = types.Level;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;
const WeaponType = types.WeaponType;

// Real-time pause inserted between enemy turn actions (before moving, before
// each skill) so enemy turns don't resolve instantly. Not skippable — see the
// wait handling in update() (main.zig).

/// Process a single event from the stack. Applies the event to the current

/// Process a single event from the stack. Applies the event to the current
/// state and records it in event history. Also used by undo/redo replay.
pub fn processEvent(
    history: *GameStateHistory,
) void {
    const current = &history.current_state;
    // All live state mutations allocate into current_arena (reclaimed by
    // compaction at idle points and by reconstruction on undo/redo). Durable
    // event recording goes through history.recordEvent into history_arena.
    const allocator = history.current_arena.allocator();

    if (current.event_stack.len == 0) return;

    // Pop the last event from the stack
    const next_event = current.event_stack[current.event_stack.len - 1];
    current.event_stack = current.event_stack[0 .. current.event_stack.len - 1];

    // Record in event history. Skip during replay: replay walks events that
    // are already recorded, applying them to rebuild a past state — it must
    // not create new events. The index still advances so replayTo's loop
    // progresses. (See recordEvent for the undo-branch handling.)
    if (!history.replaying) {
        history.recordEvent(next_event);
    }
    history.current_event_index += 1;

    switch (next_event) {
        .meta_event => |meta| {
            // Checkpoint AFTER the handler runs so the saved state reflects
            // the post-transition scope (level/hub loaded, screen set). A
            // checkpoint taken before the handler would capture the PRE-
            // transition state (e.g. hub with level=null) labeled with the
            // post-event index — replaying from it would hit in-level sub-
            // events (aggro_check) with no level loaded and crash.
            const should_checkpoint = switch (meta) {
                .start_level => |level| level.sets_checkpoint,
                .start_hub => |hub| hub.sets_checkpoint,
                else => false,
            };

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
                            // context 2 — popup + revert, not a crash. If it
                            // was the autosave, hide Continue so the user
                            // doesn't retry into the same error.
                            if (std.mem.eql(u8, load.save_path, writers.autosave_path)) {
                                history.session.autosave_available = false;
                            }
                            failReconstructionRead(history, "failed to read save file");
                            return;
                        };
                        break :blk parser.parseConfigFile(bytes, allocator) catch {
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
                    // On web, the timestamped save (not the autosave — that's
                    // the smooth-resume path in IDBFS) is also offered to the
                    // player as a browser download, so a save file on disk
                    // doesn't require digging through browser storage. No-op
                    // on native. See DESIGN → File System & IO.
                    if (!std.mem.eql(u8, write.save_path, writers.autosave_path)) {
                        file_source_mod.triggerBrowserDownload(allocator, write.save_path);
                    }
                },
                .backup_autosave => {
                    // Side effect: skip during replay (undo/redo scrubbing
                    // must not re-copy files). See DESIGN → File System & IO.
                    if (history.replaying) return;
                    // No autosave present → nothing to back up.
                    if (!history.file_source.fileExists(writers.autosave_path)) return;
                    // Pure file copy: read the autosave bytes, write them at
                    // a timestamped backup path. Best-effort — a failure
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
                    // Timestamp format "YYYYMMDD_HHMMSS" — mirrors
                    // `input_handlers.formatSessionTimestamp` /
                    // `crash_dump.formatTimestamp` (inlined here to avoid a
                    // circular import; event_handlers is imported by
                    // input_handlers). See TODO → Logging & Replay.
                    const seconds: u64 = @intCast(std.Io.Clock.now(.real, history.io).toSeconds());
                    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
                    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
                    const month_day = year_day.calculateMonthDay();
                    const day_seconds = epoch_seconds.getDaySeconds();
                    const backup_path = std.fmt.allocPrint(
                        allocator,
                        "saves/autosave-{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.txt",
                        .{
                            year_day.year,
                            month_day.month.numeric(),
                            @as(u32, month_day.day_index) + 1,
                            day_seconds.getHoursIntoDay(),
                            day_seconds.getMinutesIntoHour(),
                            day_seconds.getSecondsIntoMinute(),
                        },
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
                .start_hub => |start| {
                    // Build hub file path: data/campaigns/{campaign}/hubs/{hub_id}/hub.txt
                    const hub_path = std.fmt.allocPrint(
                        allocator,
                        "data/campaigns/{s}/hubs/{s}/hub.txt",
                        .{ current.player_data.current_campaign, start.hub_id },
                    ) catch @panic("failed to allocate hub path");

                    const hub_sections = blk: {
                        const bytes = history.readReconstructionFile(hub_path) catch {
                            failReconstructionRead(history, "failed to read hub file");
                            return;
                        };
                        break :blk parser.parseConfigFile(bytes, allocator) catch {
                            failReconstructionRead(history, "failed to parse hub file");
                            return;
                        };
                    };
                    validateConfigKeys(history, hub_sections, parser.hub_key_map, hub_path, allocator);

                    current.hub = loaders.loadHub(
                        hub_sections,
                        history.file_source,
                        allocator,
                    ) catch {
                        failReconstructionRead(history, "failed to parse hub file");
                        return;
                    };

                    current.player_data.current_hub = start.hub_id;
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
                    // Dormancy (only when ENTERING from edit mode — a
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
                .start_validation => {
                    // Forced full-mission playthrough from level 1. Same as
                    // playtest but mode=.validate and always level 0. end_level's
                    // guard pushes the next level or end_validation.
                    const editor = &current.editor.?;
                    current.level = loaders.instantiateEditorLevel(editor.*, 0, allocator);
                    current.mission = deepCopy(types.Mission, editor.mission, allocator);
                    current.mission.?.current_level_index = 1;
                    // Dormancy — same as start_playtest (the run's own
                    // player_data, all skills learned; the real data backed
                    // up for restore on end_validation).
                    editor.pre_playtest_player_data = deepCopy(types.PlayerData, current.player_data, allocator);
                    current.player_data = editor_handlers.buildPlaytestPlayerData(allocator, editor.player_def.template);
                    editor.mode = .validate;
                    current.world_generation +%= 1;
                    current.transitionScreen(.level);
                    pushGameplayStartEvents(current, allocator, false);
                },
                .end_validation => {
                    // Restore the editor after a validation run. Returns to
                    // edit mode; validation result + replay attachment are
                    // not wired.
                    current.editor.?.mode = .edit;
                    editor_handlers.restorePrePlaytestPlayerData(current);
                    current.transitionScreen(.editor);
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
                        break :blk parser.parseConfigFile(bytes, allocator) catch {
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

                    // Clear the mission-complete overlay info — entering a
                    // mission (new game or replay) retires any prior
                    // completion. On the undo timeline via GameState. See
                    // DESIGN → Architecture.
                    current.last_completed_mission = null;

                    // Return-hub override: when the caller passes a non-null
                    // end_hub_id, the mission returns THERE on end_mission
                    // instead of its authored end_hub. Used by dreams
                    // (custom missions): the authored end_hub may name a hub
                    // that doesn't exist in the player's campaign, so the
                    // caller overrides the return to the hub the player was
                    // at. Official missions pass null and keep the authored
                    // end_hub (existing behavior). The override lives on the
                    // live mission working copy (current_arena), so it is
                    // captured by deepCopy and reproduced on replay
                    // (start_mission re-applies it from the recorded event).
                    // See DESIGN → Custom Missions & Online Services → Dreams.
                    if (start.end_hub_id) |hub_id| {
                        current.mission.?.end_hub = hub_id;
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
                    // start_hub continuation defensively if it ever is.
                    if (current.editor != null) return;
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
                        break :blk parser.parseConfigFile(bytes, allocator) catch {
                            failReconstructionRead(history, "failed to parse level file");
                            return;
                        };
                    };

                    // Key validation: warn on unknown keys (advisory — the
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
                    // Editor exit guard: when an editor session is active, it
                    // owns the exit continuation — the gameplay default
                    // (next start_level / end_mission → start_hub) is
                    // suppressed/redirected. build_data_from_player is also
                    // skipped (playtest/validate are discard-semantics; the
                    // player's real PlayerData is unchanged). See DESIGN →
                    // Architecture → Level Editor.
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
                                // chains close_editor — the button means the
                                // MAIN MENU, not the editor. Any OTHER exit —
                                // natural level completion or Exit Mission —
                                // drops back to the editor (the run is
                                // bracketed).
                                if (end.continuation == .restart_mission) {
                                    current.editor.?.mode = .edit; // the capture is by value — mutate through the optional
                                    editor_handlers.restorePrePlaytestPlayerData(current);
                                    const restart_level_index = current.mission.?.current_level_index - 1; // 1-based gameplay -> 0-based
                                    pushEvents(current, &.{.{ .meta_event = .{ .start_playtest = .{
                                        .level_index = restart_level_index,
                                    } } }}, allocator);
                                } else if (end.continuation == .exit_to_menu) {
                                    current.editor.?.mode = .edit; // the capture is by value — mutate through the optional
                                    editor_handlers.restorePrePlaytestPlayerData(current);
                                    pushEvents(current, &.{.{ .meta_event = .close_editor }}, allocator);
                                } else {
                                    pushEvents(current, &.{.{ .meta_event = .end_playtest }}, allocator);
                                }
                            },
                            .validate => {
                                // A restart re-runs the WHOLE run fresh from
                                // level 1: same inline-teardown shape as the
                                // playtest restart (end_validation's
                                // transitionScreen would clear the queued
                                // re-entry), then a fresh start_validation.
                                // Exit-to-menu tears down inline + closes the
                                // editor (same as the playtest arm). Any OTHER
                                // exit continuation (Exit Mission) aborts the
                                // run: success=false, back to the editor.
                                // Only the natural level completion advances
                                // the run.
                                if (end.continuation == .restart_mission) {
                                    current.editor.?.mode = .edit; // the capture is by value — mutate through the optional
                                    editor_handlers.restorePrePlaytestPlayerData(current);
                                    pushEvents(current, &.{.{ .meta_event = .start_validation }}, allocator);
                                } else if (end.continuation == .exit_to_menu) {
                                    current.editor.?.mode = .edit; // the capture is by value — mutate through the optional
                                    editor_handlers.restorePrePlaytestPlayerData(current);
                                    pushEvents(current, &.{.{ .meta_event = .close_editor }}, allocator);
                                } else if (end.continuation != .default) {
                                    pushEvents(current, &.{.{ .meta_event = .{ .end_validation = .{
                                        .success = false,
                                    } } }}, allocator);
                                } else {
                                    const current_level_index = current.mission.?.current_level_index;
                                    if (current_level_index < editor.levels.len) {
                                        const next_index = current_level_index; // 0-based: current is 1-based, next is current
                                        pushEvents(current, &.{.{ .meta_event = .{ .start_playtest = .{
                                            .level_index = next_index,
                                        } } }}, allocator);
                                    } else {
                                        pushEvents(current, &.{.{ .meta_event = .{ .end_validation = .{
                                            .success = true,
                                        } } }}, allocator);
                                    }
                                }
                            },
                            .edit => {}, // shouldn't happen (no level loaded in edit mode)
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
                                    // More levels — push the next one
                                    const next_index = mission.current_level_index + 1;
                                    pushEvents(current, &.{.{ .meta_event = .{ .start_level = .{
                                        .mission_path = mission.path,
                                        .level_index = next_index,
                                    } } }}, allocator);
                                } else {
                                    // Last level done — end the mission.
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
                                    // strictly-better run (Pareto per-material
                                    // rate). Otherwise flag the overlay to
                                    // offer a manual overwrite button. See
                                    // DESIGN → Clones (clone system).
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
                                            if (player_handlers.cloneIsStrictlyBetter(turns, converted, old.turns_to_complete, old.materials_collected)) {
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
                                    pushEvents(current, &.{.{ .meta_event = .{ .end_mission = .{
                                        .hub_id = mission.end_hub,
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
                                    } } }}, allocator);
                                }
                            }
                        },
                        // Restart: replay the mission from level 1 with the
                        // current PlayerData (synced below before start_mission
                        // runs). The player keeps their gear; only level
                        // progress resets.
                        .restart_mission => {
                            if (current.mission) |mission| {
                                pushEvents(current, &.{.{ .meta_event = .{ .start_mission = .{
                                    .mission_path = mission.path,
                                    .start_hub_id = null,
                                    .end_hub_id = null,
                                } } }}, allocator);
                            }
                        },
                        // Abandon the mission: return to the hub the player
                        // was at before entering it (the mission's start_hub).
                        // end_mission's handler pushes start_hub with the
                        // given hub_id.
                        .exit_mission => {
                            if (current.mission) |mission| {
                                const hub_id = mission.start_hub orelse current.player_data.current_hub;
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
                    // semantics — the real PlayerData is unchanged). See DESIGN
                    // → File System & IO (autosave).
                    //
                    // On a last-level completion (.default branch above), the
                    // clone system also injects `harvest_clones` (payout from
                    // all old clones) and `save_clone_info` (auto-save /
                    // auto-overwrite the clone for this mission) between the
                    // sync and the write — LIFO array order is [write_save,
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
                else => {},
            }

            // Now that the handler has loaded the new scope, checkpoint it.
            if (should_checkpoint) {
                history.setCheckpoint();
            }
        },
        .super_event => |super| {
            player_handlers.handleSuperEvent(history, allocator, super);
        },
        .player_event => |player_event| {
            player_handlers.handlePlayerEvent(history, allocator, player_event);
        },
        .player_input_event => |pi| {
            player_input.handlePlayerInputEvent(history, current, pi, allocator);
        },
        .editor_event => |editor_event| {
            switch (editor_event) {
                .editor_set_active_level => |set| {
                    if (current.editor) |*editor| {
                        if (set.level_index < editor.levels.len) {
                            editor.active_level_index = set.level_index;
                            // The selection is active-level-relative — a
                            // tab switch takes it with it (same event, so
                            // undo restores the tab AND its selection).
                            editor.selection = &.{};
                        }
                    }
                },
                // The imports need the reconstruction cache (the
                // default-save / max-loadout reads) — handled inline here,
                // not in editor_handlers.handleEditorEvent.
                .editor_import_player => {
                    if (current.editor != null) editor_handlers.importEditorPlayer(history, current, allocator, .session);
                },
                .editor_import_max_player => {
                    if (current.editor != null) editor_handlers.importEditorPlayer(history, current, allocator, .max_player);
                },
                // The palette add-type events need the reconstruction cache
                // too (the defaults read) — same inline-handling reason as
                // the import above.
                .editor_add_entity_type => editor_handlers.addEditorPaletteType(history, current, allocator, .entity),
                .editor_add_decoration_type => editor_handlers.addEditorPaletteType(history, current, allocator, .decoration),
                .editor_add_item_type => editor_handlers.addEditorPaletteType(history, current, allocator, .item),
                // The add-level event needs the cache as well (the template
                // read) — same inline-handling reason.
                .editor_add_level => editor_handlers.addEditorLevel(history, current, allocator),
                // The remaining editor events are handled in the dedicated
                // editor handler block below (editor_handlers.handleEditorEvent). They are
                // pure state transforms on current.editor.?.levels[] or the
                // palette; undo/redo works by construction via deepCopy.
                else => |ev| editor_handlers.handleEditorEvent(
                    current,
                    ev,
                    allocator,
                ),
            }
        },
        .replay_viewer_event => |replay_event| {
            _ = replay_event;
            _ = current.replay_viewer;
        },
        .level_event => |level_event| {
            level_handlers.handleLevelEvent(history, allocator, level_event);
        },
        .sub_level_event => |sub_level_event| {
            level_handlers.handleSubLevelEvent(history, allocator, sub_level_event);
        },
    }
}

