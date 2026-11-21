//! The player-input orchestrator handler: `handlePlayerInputEvent`, the
//! fn behind processEvent's `.player_input_event` arm. Each variant is a
//! player-initiated action (keybind or click); simple variants do inline
//! work, orchestrator variants push machinery events as children via
//! `pushEvents` (the orchestrator convention - see DESIGN → Architecture
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
const campaign_editor_handlers = @import("../campaign_editor/handlers.zig");
const campaign_editor_load = @import("../campaign_editor/load.zig");
const planning = @import("../editor/planning.zig");
const hub_editor_handlers = @import("../campaign_editor/hub_handlers.zig");
const session_log = @import("../session_log.zig");
const validation_replay = @import("../validation_replay.zig");
const event_handlers = @import("../event_handlers.zig");

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
const missionDirForUuid = shared.missionDirForUuid;
const campaignEdgeForMissionUuid = shared.campaignEdgeForMissionUuid;
const getPlayerEntity = shared.getPlayerEntity;
const getLevelEntity = shared.getLevelEntity;
const loadCampaignAndPushHub = shared.loadCampaignAndPushHub;
const pushGameplayStartEvents = shared.pushGameplayStartEvents;
const refreshMoveHighlights = shared.refreshMoveHighlights;
const cancelPreparedSkill = shared.cancelPreparedSkill;
const isSkillLearned = player_handlers.isSkillLearned;
const salvageRegionOccupiedSlots = player_handlers.salvageRegionOccupiedSlots;

/// Handle a `PlayerInputEvent` - the handler for the `.player_input_event`
/// arm in `processEvent`. Each variant is a player-initiated action (keybind
/// or click). Simple variants do inline work; orchestrator variants push
/// machinery events as children via `pushEvents`. See `PlayerInputEvent` in
/// events.zig + DESIGN → Determinism & Tiebreaking → Replay PLAYER-ACTION
/// LEGALITY.
/// The revalidate orchestrator's body: load the stored validation replay,
/// re-certify it against the current content (validation_replay.
/// revalidateMission - the checking-mode replay), and on success rewrite
/// the file with the same events + the NEW content hash (the original
/// created stamp is kept - same run, re-certified; the derived turn count
/// is unchanged with it). Every failure surfaces via the error popup
/// (recoverable class - the live session's state is untouched; the old
/// replay file is kept so it still certifies the content it was recorded
/// against).
/// One stem's spec check for the Revalidate art report: skips non-custom
/// + already-reported stems, then appends a violation line when the PNG is
/// unresolvable or its dims fail the kind's spec.
fn reportStemIfViolating(
    lines: *std.ArrayList([]const u8),
    seen: *std.ArrayList([]const u8),
    file_source: *const @import("../file_source.zig").FileSource,
    mission_path: []const u8,
    stem: []const u8,
    entity_kind: bool,
    allocator: std.mem.Allocator,
) void {
    if (!std.mem.startsWith(u8, stem, "custom/")) return;
    for (seen.items) |seen_stem| {
        if (std.mem.eql(u8, seen_stem, stem)) return;
    }
    seen.append(allocator, stem) catch @panic("failed to append seen stem");

    const slash = std.mem.lastIndexOfScalar(u8, stem, '/') orelse return;
    const dims = loaders.resolveMissionSpriteDimensions(
        file_source,
        mission_path,
        stem[slash + 1 ..],
        allocator,
    ) orelse {
        const kind: []const u8 = if (entity_kind) "entity" else "decoration";
        const line = std.fmt.allocPrint(
            allocator,
            "{s} art '{s}' is missing or invalid",
            .{ kind, stem },
        ) catch @panic("failed to format art spec report line");
        lines.append(allocator, line) catch @panic("failed to append art spec report line");
        return;
    };
    const conforms = if (entity_kind)
        types.entitySpriteDimsConform(dims)
    else
        types.decorationSpriteDimsConform(dims);
    if (conforms) return;
    const line = if (entity_kind)
        std.fmt.allocPrint(
            allocator,
            "entity art '{s}' is {d}x{d} (must be 512x640)",
            .{ stem, dims.x, dims.y },
        ) catch @panic("failed to format art spec report line")
    else
        std.fmt.allocPrint(
            allocator,
            "decoration art '{s}' is {d}x{d} (must be whole multiples of 256)",
            .{ stem, dims.x, dims.y },
        ) catch @panic("failed to format art spec report line");
    lines.append(allocator, line) catch @panic("failed to append art spec report line");
}

/// The publish-checkpoint art-spec scan for Revalidate: list every custom
/// sprite the mission references that violates its kind's spec - an
/// unresolvable PNG (missing/invalid) or wrong dims (entity art must be
/// 512x640, decoration art whole 256px tiles; same rules as the load-side
/// warnings + the render gate). Returns null when everything conforms;
/// otherwise a newline-joined report (one line per distinct stem).
/// Revalidation still PASSES on violations - they degrade to the magenta
/// fallback at runtime; the report rides the success message so the
/// author certifies with eyes open. Requires the live editor (Revalidate
/// is editor-only); null editor → no report.
fn customSpriteSpecReport(history: *GameStateHistory, allocator: std.mem.Allocator) ?[]const u8 {
    const editor = history.current_state.editor orelse return null;

    var lines: std.ArrayList([]const u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);

    // Entity art: the player template + every entity type (base + layers).
    reportStemIfViolating(&lines, &seen, history.file_source, editor.mission.path, editor.player_def.template.sprite, true, allocator);
    for (editor.player_def.template.layers) |layer| {
        reportStemIfViolating(&lines, &seen, history.file_source, editor.mission.path, layer.sprite, true, allocator);
    }
    for (editor.entity_types) |type_definition| {
        reportStemIfViolating(&lines, &seen, history.file_source, editor.mission.path, type_definition.template.sprite, true, allocator);
        for (type_definition.template.layers) |layer| {
            reportStemIfViolating(&lines, &seen, history.file_source, editor.mission.path, layer.sprite, true, allocator);
        }
    }
    // Decoration art: every decoration type (base + layers).
    for (editor.decoration_types) |type_definition| {
        reportStemIfViolating(&lines, &seen, history.file_source, editor.mission.path, type_definition.sprite, false, allocator);
        for (type_definition.layers) |layer| {
            reportStemIfViolating(&lines, &seen, history.file_source, editor.mission.path, layer.sprite, false, allocator);
        }
    }

    if (lines.items.len == 0) return null;
    var report: std.ArrayList(u8) = .empty;
    for (lines.items, 0..) |line, index| {
        if (index > 0) report.appendSlice(allocator, "\n") catch @panic("failed to join art spec report");
        report.appendSlice(allocator, line) catch @panic("failed to join art spec report");
    }
    return report.items;
}

fn revalidateMissionArtifact(history: *GameStateHistory, mission_dir: []const u8) void {
    const scratch = history.current_arena.allocator();

    const replay_path = std.fmt.allocPrint(scratch, "{s}/validation_replay.txt", .{mission_dir}) catch
        @panic("failed to allocate the validation replay path");
    const replay_bytes = history.file_source.readFile(scratch, replay_path) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "This mission has no validation replay yet - run Validate first.",
        );
        return;
    };
    const sections = parser.parseConfigFile(replay_bytes, scratch, &parser.session_log_sections) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "Revalidation failed: the stored validation replay is malformed.",
        );
        return;
    };
    const replay = validation_replay.loadValidationReplay(sections, scratch) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "Revalidation failed: the stored validation replay is malformed.",
        );
        return;
    };

    const result = validation_replay.revalidateMission(
        history,
        mission_dir,
        replay,
        scratch,
        event_handlers.processEvent,
    );
    switch (result) {
        .invalid => |invalid| {
            history.session.setPendingError(history.history_arena.allocator(), invalid.reason);
        },
        .valid => |valid| {
            const replay_out = session_log.writeEventLogWithMetadata(
                replay.events,
                replay.created,
                &.{
                    .{ .name = "mission_uuid", .value = replay.mission_uuid },
                    .{ .name = "content_hash", .value = &valid.content_hash_hex },
                },
                scratch,
            ) catch {
                history.session.setPendingError(
                    history.history_arena.allocator(),
                    "Revalidation failed: could not serialize the replay.",
                );
                return;
            };
            history.file_source.writeFile(replay_path, replay_out) catch {
                history.session.setPendingError(
                    history.history_arena.allocator(),
                    "Revalidation failed: could not write validation_replay.txt.",
                );
                return;
            };
            // The publish-checkpoint art-spec report: revalidation PASSES
            // regardless (violations degrade to the magenta fallback at
            // runtime), but the author certifies with eyes open - the
            // success message carries the violation list when there is
            // one (customSpriteSpecReport - same spec as the load warnings
            // + the render gate).
            const spec_report = customSpriteSpecReport(history, scratch);
            if (spec_report) |report| {
                const message = std.fmt.allocPrint(
                    scratch,
                    "Revalidation passed - the stored replay again certifies the current mission content.\n\nCustom art spec warnings:\n{s}",
                    .{report},
                ) catch @panic("failed to format the revalidation success message");
                history.session.setPendingError(history.history_arena.allocator(), message);
            } else {
                history.session.setPendingError(
                    history.history_arena.allocator(),
                    "Revalidation passed - the stored replay again certifies the current mission content.",
                );
            }
        },
    }
}

pub fn handlePlayerInputEvent(
    history: *GameStateHistory,
    current: *GameState,
    pi: events.PlayerInputEvent,
    allocator: std.mem.Allocator,
) void {
    switch (pi) {
        // --- Meta: overlay dismiss ---
        .dismiss_mission_complete => {
            // Payload + stack slot together (setCompletedMission); this
            // is the one clear that runs on the SAME screen (the hub /
            // editor the overlay sits on), so the explicit close is
            // load-bearing - no transition follows to do it.
            current.setCompletedMission(null);
        },

        // --- Meta: continue (main-menu Continue button) ---
        // Two branches by PlayerData state. Populated (the mid-session
        // exit-to-menu case) → resume directly from in-memory data, no file
        // read. Empty (the fresh-launch case) → load the autosave first, then
        // loadCampaignAndPushHub resumes at player_data.current_hub. See
        // DESIGN → File System & IO (autosave).
        .player_continue => {
            if (current.player_data.current_campaign_uuid.len > 0) {
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
        // revert) - the browser stays open for another pick.
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
                break :blk parser.parseConfigFile(bytes, allocator, &parser.player_save_sections) catch {
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

        // Export Game's autosave half (the zip + download are an
        // input-path side effect, the reset-to-defaults class - see
        // game_zip.zig): a game in progress syncs PlayerData + writes the
        // AUTOSAVE first, so mid-level progress is in the exported zip.
        // Skipped during an editor run (playtest/validate) - the run's
        // player_data is throwaway (the save_game discipline); the folder
        // export itself still proceeds.
        .export_game => {
            if (current.editor) |editor| {
                if (editor.mode != .edit) return;
            }
            if (current.level != null or current.hub != null) {
                pushEvents(current, &.{
                    .{ .meta_event = .{ .write_save = .{ .save_path = writers.autosave_path } } },
                    .{ .super_event = .{ .build_data_from_player = .{ .entity_index = 0 } } },
                }, allocator);
            }
        },

        // --- Meta: open campaign editor ---
        .open_campaign_editor => |start| {
            if (start.campaign_dir == null) {
                campaign_editor_handlers.openFreshCampaignEditor(history, current, allocator);
                // The newly installed campaign is a new world: bump so the
                // transition UI reset fires (stale view state must not
                // survive the swap) - the openFreshEditorMission
                // convention.
                current.world_generation +%= 1;
                current.transitionScreen(.campaign_editor);
                return;
            }
            // The dir-open path (the browser's Campaign tab rows): the
            // inverse projection - campaign.txt + every hub.txt + the
            // mission table - through the reconstruction cache (the
            // open_editor convention).
            var campaign_warnings: std.ArrayList([]const u8) = .empty;
            if (!campaign_editor_load.loadCampaignEditorIntoState(
                history,
                current,
                allocator,
                start.campaign_dir.?,
                &campaign_warnings,
            )) {
                shared.failReconstructionRead(history, "failed to read campaign file");
                return;
            }
            shared.surfaceWarnings(history, &campaign_warnings, allocator);
            current.world_generation +%= 1;
            current.transitionScreen(.campaign_editor);
        },

        // --- Meta: open the hub editor drill-in ---
        .open_hub_editor => |start| {
            // The hub inspector's Open Hub Editor button. A failed open
            // surfaced the recoverable error and left hub_editor unset -
            // skip the transition (the drain loop reverts). No
            // world_generation bump: the drill-in views part of the SAME
            // world (the authored graph), and the screen change itself
            // resets the classes-2-4 view state.
            var balance_warnings: std.ArrayList([]const u8) = .empty;
            campaign_editor_handlers.openHubEditor(history, current, allocator, &balance_warnings, start.hub);
            if (current.hub_editor == null) return;
            surfaceWarnings(history, &balance_warnings, allocator);
            current.transitionScreen(.hub_editor);
        },

        // --- Meta: open the mission-editor hand-off ---
        .open_mission_editor => |start| {
            // The mission inspector's Open Mission Editor button. A
            // failed open surfaced the recoverable error and left the
            // editor unset - skip the transition (the drain loop
            // reverts). The registry load + new-world bump + warning
            // surface mirror open_editor: the hand-off installs editor
            // content too (the mission payload swap must reset stale
            // view state, and the mission editor's palettes read the
            // registry).
            var balance_warnings: std.ArrayList([]const u8) = .empty;
            campaign_editor_handlers.openMissionEditorHandoff(
                history,
                current,
                allocator,
                &balance_warnings,
                start.mission,
                start.mission_path,
            );
            if (current.editor == null) return;
            editor_handlers.loadEditorDecorationRegistry(history, allocator);
            surfaceWarnings(history, &balance_warnings, allocator);
            current.world_generation +%= 1;
            current.transitionScreen(.editor);
        },

        // --- Meta: return to the campaign map from the drill-ins ---
        .player_close_mission_editor => {
            // The mission editor hand-off's world-map return: back to the
            // campaign map (the recorded close drops the editor payload
            // via the scope rule; the campaign graph survives).
            pushEvents(current, &.{.{ .meta_event = .{ .close_mission_editor = {} } }}, allocator);
        },
        .player_close_hub_editor => {
            // The hub editor drill-in's world-map return: back to the
            // campaign map (the recorded close drops the drill-in state
            // via the scope rule; the campaign graph survives).
            pushEvents(current, &.{.{ .meta_event = .{ .close_hub_editor = {} } }}, allocator);
        },

        // --- Meta: open editor ---
        .open_editor => |start| {
            var balance_warnings: std.ArrayList([]const u8) = .empty;
            // The foreign-open rule (the campaign hand-off): opening other
            // content while a campaign-context mission editor is open would
            // orphan the live campaign below - the editor screen's scope
            // keeps campaign_editor, but the replacement payload carries no
            // context, so no surface ever reaches the campaign again. The
            // open clears it in the same event (undo restores both).
            if (current.editor != null and current.editor.?.campaign_mission != null) {
                current.campaign_editor = null;
            }
            // Null path = the fresh empty mission (the main-menu Editor
            // button) - the short-circuit branch below; a path = the
            // mission-directory open (the future mission browser + the
            // round-trip tests).
            if (start.mission_path == null) {
                editor_handlers.openFreshEditorMission(history, current, allocator, &balance_warnings);
                // A failed open surfaced the recoverable error and left
                // the editor unset - skip the transition (the drain loop
                // reverts).
                if (current.editor == null) return;
                editor_handlers.loadEditorDecorationRegistry(history, allocator);
                surfaceWarnings(history, &balance_warnings, allocator);
                // A newly installed editor mission is a new world: bump so
                // the transition UI reset in the driver fires even when the
                // screen STAYS .editor (an open-from-the-editor via the
                // mission browser) - stale view state (open panels, the
                // browser itself, scroll offsets) must not survive the
                // mission swap. start_level/start_hub bump for the same
                // reason.
                current.world_generation +%= 1;
                current.transitionScreen(.editor);
                return;
            }
            const mission_path = start.mission_path.?;
            const opened = editor_handlers.openEditorMissionFromDir(
                history,
                current,
                allocator,
                &balance_warnings,
                mission_path,
            );
            if (!opened) return;
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
        .player_restart_mission => |restart| {
            pushEvents(current, &.{.{ .meta_event = .{ .end_level = .{
                .continuation = .restart_mission,
                .mission_path = restart.mission_path,
            } } }}, allocator);
        },
        .player_exit_mission => {
            pushEvents(current, &.{.{ .meta_event = .{ .end_level = .{
                .continuation = .exit_mission,
            } } }}, allocator);
        },
        // World-map travel (a hub click): jump to a DISCOVERED hub. The
        // hub uuid rides the event; the arrival resolves through the
        // loaded campaign's table inside start_hub (state, never the
        // filesystem). From a hub: the exit-tile shape (end_hub syncs +
        // autosaves below the arrival). Mid-level: the abandon ride -
        // the arrival is queued BENEATH end_level{.exit_mission} with the
        // exit's own return suppressed (the return's transitionScreen
        // would clear the stack and eat the queued arrival - the
        // state.transitionScreen contract). Pickups preserved by the
        // end_level sync invariant; no clone (the run is not completed).
        // See DESIGN → Campaigns & the Campaign Editor → Discovery +
        // travel.
        .player_travel_to_hub => |travel| {
            const hub_id = allocator.dupe(u8, travel.hub_uuid) catch
                @panic("failed to allocate travel hub id");
            // Cross-campaign: the install rides BENEATH the arrival
            // (LIFO - it runs first), switching the active campaign +
            // its graph so start_hub resolves through the NEW table.
            const install_events: []const Event = if (travel.campaign_dir) |campaign_dir| blk: {
                const dir = allocator.dupe(u8, campaign_dir) catch
                    @panic("failed to allocate travel campaign dir");
                const uuid = allocator.dupe(u8, travel.campaign_uuid orelse "") catch
                    @panic("failed to allocate travel campaign uuid");
                break :blk &.{.{ .meta_event = .{ .install_campaign = .{
                    .campaign_dir = dir,
                    .campaign_uuid = uuid,
                } } }};
            } else &.{};
            if (current.screen == .level) {
                var stack: std.ArrayList(Event) = .empty;
                stack.append(allocator, .{ .meta_event = .{ .start_hub = .{
                    .hub_id = hub_id,
                } } }) catch @panic("failed to append arrival");
                stack.appendSlice(allocator, install_events) catch @panic("failed to append install");
                stack.append(allocator, .{ .meta_event = .{ .end_level = .{
                    .continuation = .exit_mission,
                    .suppress_return_hub = true,
                } } }) catch @panic("failed to append abandon");
                pushEvents(current, stack.items, allocator);
            } else if (current.screen == .hub) {
                var stack: std.ArrayList(Event) = .empty;
                stack.append(allocator, .{ .meta_event = .{ .start_hub = .{
                    .hub_id = hub_id,
                } } }) catch @panic("failed to append arrival");
                stack.appendSlice(allocator, install_events) catch @panic("failed to append install");
                stack.append(allocator, .{ .meta_event = .end_hub }) catch @panic("failed to append hub exit");
                pushEvents(current, stack.items, allocator);
            }
        },
        // World-map mission entry (an edge click): equivalent to standing
        // on the exit in the edge's start hub - the mission is entered
        // FROM the edge's start hub (start_mission's enter_hub_id sets
        // current_hub on the way in, so abandoning the mission returns
        // there). The payload is the click-time resolved edge (the
        // mission-browser-row precedent). Mid-level, the abandon ride
        // runs beneath: end_level{.exit_mission} with the return
        // suppressed, the entry queued beneath it.
        .player_start_mission_from_map => |entry| {
            const mission_path = allocator.dupe(u8, entry.mission_path) catch
                @panic("failed to allocate map mission path");
            const end_hub_id = if (entry.end_hub_id) |hub|
                (allocator.dupe(u8, hub) catch @panic("failed to allocate map mission end hub"))
            else
                null;
            const start_hub_id = allocator.dupe(u8, entry.start_hub_id) catch
                @panic("failed to allocate map mission start hub");
            // Cross-campaign: the install rides BENEATH the entry (LIFO -
            // it runs first), switching the active campaign + its graph
            // so the mission's campaign-relative path resolves against
            // the NEW campaign and the enter hub's discovery lands in the
            // NEW campaign's group (start_hub discovers through the
            // installed graph's uuid).
            const install_events: []const Event = if (entry.campaign_dir) |campaign_dir| blk: {
                const dir = allocator.dupe(u8, campaign_dir) catch
                    @panic("failed to allocate entry campaign dir");
                const uuid = allocator.dupe(u8, entry.campaign_uuid orelse "") catch
                    @panic("failed to allocate entry campaign uuid");
                break :blk &.{.{ .meta_event = .{ .install_campaign = .{
                    .campaign_dir = dir,
                    .campaign_uuid = uuid,
                } } }};
            } else &.{};
            if (current.screen == .level) {
                var stack: std.ArrayList(Event) = .empty;
                stack.append(allocator, .{ .meta_event = .{ .start_mission = .{
                    .mission_path = mission_path,
                    .end_hub_id = end_hub_id,
                    .enter_hub_id = start_hub_id,
                } } }) catch @panic("failed to append entry");
                stack.appendSlice(allocator, install_events) catch @panic("failed to append install");
                stack.append(allocator, .{ .meta_event = .{ .end_level = .{
                    .continuation = .exit_mission,
                    .suppress_return_hub = true,
                } } }) catch @panic("failed to append abandon");
                pushEvents(current, stack.items, allocator);
            } else if (current.screen == .hub) {
                var stack: std.ArrayList(Event) = .empty;
                stack.append(allocator, .{ .meta_event = .{ .start_mission = .{
                    .mission_path = mission_path,
                    .end_hub_id = end_hub_id,
                    .enter_hub_id = start_hub_id,
                } } }) catch @panic("failed to append entry");
                stack.appendSlice(allocator, install_events) catch @panic("failed to append install");
                stack.append(allocator, .{ .meta_event = .end_hub }) catch @panic("failed to append hub exit");
                pushEvents(current, stack.items, allocator);
            }
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
                // the editor via the screen-scope swap) - no sibling
                // open_main_menu needed.
                pushEvents(current, &.{.{ .meta_event = .close_editor }}, allocator);
            } else if (current.screen == .campaign_editor) {
                // The same shape for the campaign editor:
                // close_campaign_editor owns the teardown + transition.
                pushEvents(current, &.{.{ .meta_event = .close_campaign_editor }}, allocator);
            } else if (current.screen == .hub_editor) {
                // Exit to the main menu from the hub editor discards the
                // whole editing session (the scope swap clears hub_editor
                // AND campaign_editor) - open_main_menu's plain
                // transition, no teardown event needed.
                pushEvents(current, &.{.{ .meta_event = .open_main_menu }}, allocator);
            }
        },
        .player_replay_mission => {
            const info = current.last_completed_mission orelse return;
            const mission_path = allocator.dupe(u8, info.path) catch
                @panic("failed to allocate replay mission path");
            // Return destination: the campaign edge for this mission (the
            // edge IS the graph data - campaign.txt's Missions section,
            // matched by mission uuid, not path; the hub's exit marker is
            // pure tile materialization). No edge, or a dangling
            // destination (a dream, or a hand-edit) -> null -> the
            // entering-hub fallback.
            var end_hub_id: ?[]const u8 = null;
            if (campaignEdgeForMissionUuid(current, info.uuid)) |edge| {
                if (edge.destination.len > 0) end_hub_id = edge.destination;
            }
            pushEvents(current, &.{
                .{ .meta_event = .{ .start_mission = .{
                    .mission_path = mission_path,
                    .end_hub_id = end_hub_id,
                } } },
                .{ .meta_event = .end_hub },
            }, allocator);
        },
        // Level-tab click: switch the editor's active level. Thin orchestrator
        // - the EditorEvent owns the mutation (undo rides the timeline).
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
        // lives on the Editor - the toggle is undoable).
        .player_toggle_editor_metadata_sidebar => {
            pushEvents(current, &.{.{ .editor_event = .editor_toggle_metadata_sidebar }}, allocator);
        },
        // Surface-toggle orchestrator (escape chain, panel keybinds, modal
        // buttons): thin - the meta `toggle_ui_surface` owns the flip; the
        // surface state rides GameState (`ui_surfaces`), so a toggle fired
        // while idle is its own undo step. See DESIGN → UI Framework → UI
        // state classification.
        .player_toggle_ui_surface => |toggle| {
            pushEvents(current, &.{.{ .meta_event = .{ .toggle_ui_surface = .{
                .surface = toggle.surface,
            } } }}, allocator);
        },
        // Right-click entity inspect: thin - the meta `inspect_entity` verb
        // owns the open/retarget/close (the resolved intent rides the
        // payload; the gesture computed same/different/none).
        .player_inspect_entity => |inspect| {
            pushEvents(current, &.{.{ .meta_event = .{ .inspect_entity = .{
                .entity_index = inspect.entity_index,
            } } }}, allocator);
        },
        // Editor picker open/close (the picker's own buttons, the rows
        // that open it, a no-change pick's close): thin - the
        // `editor_open_picker` / `editor_close_picker` events own the
        // mutation. The picker state rides GameState (`Editor.picker`),
        // so it rides the undo timeline. See DESIGN → UI Framework → UI
        // state classification.
        .player_open_editor_picker => |open| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_open_picker = .{
                .target = open.target,
            } } }}, allocator);
        },
        .player_close_editor_picker => {
            pushEvents(current, &.{.{ .editor_event = .editor_close_picker }}, allocator);
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
        // from the SAVED mission dir (the input layer saved first - the
        // machinery handler reads the files, not the editor memory). Also
        // the validate-RESTART re-entry (pushed by end_level's guard):
        // every attempt begins with this seedable orchestrator, which is
        // what lets the validation replay slice start at the last one.
        .player_start_validation => |start| {
            pushEvents(current, &.{.{ .meta_event = .{ .start_validation = .{
                .mission_path = start.mission_path,
            } } }}, allocator);
        },
        // Options-menu Revalidate Mission (see the event's doc): entirely
        // live-only - the artifact write is a side effect, and the check
        // reads the mission files as they are NOW (not a pure function of
        // recorded state), so a replayed/reconstructed session re-records
        // the click but re-runs nothing.
        .player_revalidate_mission => |revalidate| {
            if (history.replaying) return;
            revalidateMissionArtifact(history, revalidate.mission_path);
        },
        // Player inspector Import-button click: push the machinery event
        // (the loadout fields ride GameState - the import is undoable).
        .player_import_editor_player => {
            pushEvents(current, &.{.{ .editor_event = .editor_import_player }}, allocator);
        },
        // The Max player Import (the shipped data/max_player.txt loadout -
        // the author-times tool for official missions): thin forward, the
        // EditorEvent owns the mutation.
        .player_import_editor_max_player => {
            pushEvents(current, &.{.{ .editor_event = .editor_import_max_player }}, allocator);
        },
        // Palette group "+" clicks: push the machinery event (the handler
        // builds the type from the shipped defaults, makes it the active
        // tool, and opens the inspector - one undo step covers it all).
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
        // orchestrator - the editor_delete_type handler fans out into the
        // per-placement deletes + removes the type + remaps ids + fixes
        // the active tool, all as one undo step.
        .player_delete_editor_type => |delete| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_delete_type = .{
                .type_kind = delete.type_kind,
                .type_id = delete.type_id,
            } } }}, allocator);
        },
        // Add-level "+" click (top bar): push the machinery event - the
        // handler reads the shipped template through the reconstruction
        // cache, appends the level, switches to it, and syncs level_count;
        // one undo step reverts the whole creation.
        .player_add_editor_level => {
            pushEvents(current, &.{.{ .editor_event = .editor_add_level }}, allocator);
        },
        // Level-tab × click: push the machinery event - the handler removes
        // the level, shifts later levels down, syncs level_count, and
        // adjusts the active tab; one undo step restores it.
        .player_delete_editor_level => |delete| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_delete_level = .{
                .level_index = delete.level_index,
            } } }}, allocator);
        },
        // Settings-sidebar commits (mission + active-level metadata): thin
        // forwards - the EditorEvents own the mutations. The level-indexed
        // wrappers address the level the sidebar showed at click time.
        .player_set_editor_mission_name => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_mission_name = .{
                .name = set.name,
            } } }}, allocator);
        },
        .player_set_campaign_name => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_set_campaign_name = .{
                .name = set.name,
            } } }}, allocator);
        },
        .player_set_campaign_tool => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_set_tool = .{
                .tool = set.tool,
            } } }}, allocator);
        },
        .player_select_campaign_hub => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_select_hub = .{
                .hub = set.hub,
            } } }}, allocator);
        },
        .player_place_campaign_hub => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_place_hub = .{
                .position = set.position,
            } } }}, allocator);
        },
        .player_move_campaign_hub => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_set_hub_position = .{
                .hub = set.hub,
                .position = set.position,
            } } }}, allocator);
        },
        .player_set_campaign_start_hub => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_set_start_hub = .{
                .hub = set.hub,
            } } }}, allocator);
        },
        .player_delete_campaign_hub => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_delete_hub = .{
                .hub = set.hub,
            } } }}, allocator);
        },
        .player_open_campaign_picker => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_open_picker = .{
                .picker = set.picker,
            } } }}, allocator);
        },
        .player_close_campaign_picker => {
            pushEvents(current, &.{.{ .campaign_editor_event = .editor_campaign_close_picker }}, allocator);
        },
        .player_toggle_campaign_inspector => {
            pushEvents(current, &.{.{ .campaign_editor_event = .editor_campaign_toggle_inspector }}, allocator);
        },
        .player_toggle_campaign_metadata_sidebar => {
            pushEvents(current, &.{.{ .campaign_editor_event = .editor_campaign_toggle_metadata_sidebar }}, allocator);
        },
        .player_select_campaign_mission => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_select_mission = .{
                .mission = set.mission,
            } } }}, allocator);
        },
        .player_place_campaign_mission => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_place_mission = .{
                .start = set.start,
                .destination = set.destination,
            } } }}, allocator);
        },
        .player_set_campaign_mission_name => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_set_mission_name = .{
                .mission = set.mission,
                .name = set.name,
            } } }}, allocator);
        },
        .player_set_campaign_mission_direction => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_set_mission_direction = .{
                .mission = set.mission,
                .direction = set.direction,
            } } }}, allocator);
        },
        .player_reattach_campaign_mission => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_reattach_mission = .{
                .mission = set.mission,
                .end = set.end,
                .hub = set.hub,
            } } }}, allocator);
        },
        .player_delete_campaign_mission => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_delete_mission = .{
                .mission = set.mission,
            } } }}, allocator);
        },
        .player_import_campaign_mission => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_import_mission = .{
                .uuid = set.uuid,
                .dir = set.dir,
                .name = set.name,
            } } }}, allocator);
        },
        .player_set_campaign_background => |set| {
            // The pick + its close are ONE undo step (the editor-picker
            // convention: the close rides as a child of the commit).
            pushEvents(current, &.{
                .{ .campaign_editor_event = .{ .editor_campaign_set_background = .{
                    .stem = set.stem,
                } } },
                .{ .campaign_editor_event = .editor_campaign_close_picker },
            }, allocator);
        },
        .player_set_campaign_hub_name => |set| {
            pushEvents(current, &.{.{ .campaign_editor_event = .{ .editor_campaign_set_hub_name = .{
                .hub = set.hub,
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
            // The theme-picker commit closes its picker in the same action
            // (pick + close = one undo step).
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_set_level_color_wheel = .{
                .level_index = set.level_index,
                .color_wheel_index = set.color_wheel_index,
            } } } }, allocator);
        },
        .player_set_editor_level_enemy_gradient => |set| {
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_set_level_enemy_gradient = .{
                .level_index = set.level_index,
                .gradient_index = set.gradient_index,
            } } } }, allocator);
        },
        .player_set_editor_level_player_gradient => |set| {
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_set_level_player_gradient = .{
                .level_index = set.level_index,
                .gradient_index = set.gradient_index,
            } } } }, allocator);
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
        // Inspector entity-sprite commit: closes the centered sprite
        // picker, then commits the id + keep_original_colors flag (see
        // DESIGN → Level Editor → Editor UI layout).
        .player_set_editor_entity_sprite => |set| {
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_set_entity_sprite = .{
                .target = set.target,
                .value = set.value,
                .keep_original_colors = set.keep_original_colors,
            } } } }, allocator);
        },
        // Inspector scalar commits (swatch pick, toggle flip, stat fields):
        // thin forwards - the EditorEvents own the mutations.
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
        .player_set_editor_entity_keep_original_colors => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_entity_keep_original_colors = .{
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
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_set_entity_utility_skill = .{
                .target = set.target,
                .slot_index = set.slot_index,
                .value = set.value,
            } } } }, allocator);
        },
        // Inspector decoration commits: thin forwards (the EditorEvents own
        // the mutations - the def event's handler also prunes the type's
        // now-invalid placements).
        .player_set_editor_decoration_def => |set| {
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_set_decoration_def = .{
                .type_id = set.type_id,
                .sprite = set.sprite,
                .footprint = set.footprint,
                .pixel_dims = set.pixel_dims,
                .color_index = set.color_index,
                .keep_original_colors = set.keep_original_colors,
                .layers = set.layers,
            } } } }, allocator);
        },
        // Surface-polymorphic (the inspector reuse): on the hub editor
        // screen the same commits target the campaign palette (the hub
        // events); the mission editor keeps its editor events.
        .player_set_editor_decoration_color_index => |set| {
            if (current.screen == .hub_editor) {
                if (current.hub_editor == null or current.campaign_editor == null) return;
                pushEvents(current, &.{.{ .hub_editor_event = .{ .hub_set_decoration_color_index = .{
                    .type_id = set.type_id,
                    .value = set.value,
                } } }}, allocator);
                return;
            }
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_decoration_color_index = .{
                .type_id = set.type_id,
                .value = set.value,
            } } }}, allocator);
        },
        .player_set_editor_decoration_keep_original_colors => |set| {
            if (current.screen == .hub_editor) {
                if (current.hub_editor == null or current.campaign_editor == null) return;
                pushEvents(current, &.{.{ .hub_editor_event = .{ .hub_set_decoration_keep_original_colors = .{
                    .type_id = set.type_id,
                    .value = set.value,
                } } }}, allocator);
                return;
            }
            pushEvents(current, &.{.{ .editor_event = .{ .editor_set_decoration_keep_original_colors = .{
                .type_id = set.type_id,
                .value = set.value,
            } } }}, allocator);
        },
        // The footprint editor's confirm: thin forward (the EditorEvent
        // owns the mutation + the placement prune).
        .player_set_editor_decoration_footprint => |set| {
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_set_decoration_footprint = .{
                .type_id = set.type_id,
                .value = set.value,
            } } } }, allocator);
        },
        // Inspector item commits (the Items palette group): thin forwards
        // - the EditorEvents own the mutations + the id sync.
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
        // Inventory section) - thin forwards, the EditorEvents own the
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
        // The player loadout has no layers - the handler ignores a
        // player_def entity-layer target (validation rejects it at the
        // replay seam).
        .player_add_editor_entity_layer => |set| {
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_add_entity_layer = .{
                .target = set.target,
                .sprite = set.sprite,
                .color_index = set.color_index,
            } } } }, allocator);
        },
        .player_remove_editor_entity_layer => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_remove_entity_layer = .{
                .target = set.target,
                .layer_index = set.layer_index,
            } } }}, allocator);
        },
        .player_set_editor_entity_layer => |set| {
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_set_entity_layer = .{
                .target = set.target,
                .layer_index = set.layer_index,
                .sprite = set.sprite,
                .color_index = set.color_index,
            } } } }, allocator);
        },
        .player_add_editor_decoration_layer => |set| {
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_add_decoration_layer = .{
                .type_id = set.type_id,
                .sprite = set.sprite,
                .color_index = set.color_index,
                .behind = set.behind,
                .pixel_dims = set.pixel_dims,
            } } } }, allocator);
        },
        .player_remove_editor_decoration_layer => |set| {
            pushEvents(current, &.{.{ .editor_event = .{ .editor_remove_decoration_layer = .{
                .type_id = set.type_id,
                .layer_index = set.layer_index,
            } } }}, allocator);
        },
        .player_set_editor_decoration_layer => |set| {
            pushEvents(current, &.{ .{ .editor_event = .editor_close_picker }, .{ .editor_event = .{ .editor_set_decoration_layer = .{
                .type_id = set.type_id,
                .layer_index = set.layer_index,
                .sprite = set.sprite,
                .color_index = set.color_index,
                .behind = set.behind,
                .pixel_dims = set.pixel_dims,
            } } } }, allocator);
        },
        // Select-tool click: thin over the shared planner (the input layer
        // fires only nonempty plans - see planning.planEditorSelectionActions).
        .player_toggle_editor_selection => |toggle| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorSelectionActions(editor, toggle.position, allocator), allocator);
            }
        },
        // Select-tool plain click: thin over the shared planner (the input
        // layer fires only nonempty plans - see
        // planning.planEditorReplaceSelectionActions).
        .player_replace_editor_selection => |replace| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorReplaceSelectionActions(editor, replace.position, allocator), allocator);
            }
        },
        // Select-tool marquee release: thin over the shared planner (the
        // gesture handler fires only nonempty plans - see
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
        // ctrl+A select-all: thin over the shared planner (the input layer
        // fires only nonempty plans - see planning.planEditorSelectAllActions).
        // Tool-agnostic: when another tool is active the action also
        // switches to select - the selection can only live there (the
        // selection ⇔ select-tool invariant), and the follow-ups (move /
        // delete / refine) are select-tool verbs anyway. The switch rides
        // the same idle point (one undo step restores the previous tool +
        // the empty selection). It sits LAST in the push: the stack drains
        // back-to-front, so the switch processes FIRST and the
        // editor_select events run with the select tool active (keeping
        // editor_select's defensive tool guard honest).
        .player_select_editor_all => {
            if (current.editor) |*editor| {
                const plan = planning.planEditorSelectAllActions(editor, allocator);
                if (editor.active_tool == .select) {
                    pushEvents(current, plan, allocator);
                } else {
                    var select_all_events: std.ArrayList(Event) = .empty;
                    select_all_events.appendSlice(allocator, plan) catch
                        @panic("failed to allocate select-all events");
                    select_all_events.append(allocator, .{ .editor_event = .{ .editor_set_tool = .{
                        .tool = .select,
                    } } }) catch @panic("failed to allocate select-all events");
                    pushEvents(current, select_all_events.items, allocator);
                }
            }
        },
        // Select-tool Delete key: thin over the shared planner (the input
        // layer fires only nonempty plans - see
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
        // Select-tool move drag release: thin over the shared planner (the
        // plan covers the marker-overlap veto - an empty plan is a move
        // that never happened; see
        // planning.planEditorSelectionMoveActions).
        .player_move_editor_selection => |move| {
            if (current.editor) |*editor| {
                pushEvents(
                    current,
                    planning.planEditorSelectionMoveActions(editor, move.delta, allocator),
                    allocator,
                );
            }
        },
        // Tile-paint click: thin over the shared planner (the input layer
        // fires only nonempty plans - see planning.planEditorTilePaintActions).
        .player_paint_editor_tile => |paint| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorTilePaintActions(editor, paint.position, allocator), allocator);
            }
        },
        // Enemy-tool click: thin over the shared planner (the input layer
        // fires only nonempty plans - see planning.planEditorEntityPlacementActions).
        .player_place_editor_entity => |place| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorEntityPlacementActions(editor, place.type_id, place.position, allocator), allocator);
            }
        },
        // Decoration-tool click: thin over the shared planner (the input
        // layer fires only nonempty plans - see
        // planning.planEditorDecorationPlacementActions).
        .player_place_editor_decoration => |place| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorDecorationPlacementActions(editor, place.type_id, place.position, allocator), allocator);
            }
        },
        // Ground-item-tool click: thin over the shared planner (the input
        // layer fires only nonempty plans - see
        // planning.planEditorItemPlacementActions).
        .player_place_editor_item => |place| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorItemPlacementActions(editor, place.type_id, place.position, allocator), allocator);
            }
        },
        // Editor right-click delete: thin over the shared planner (the
        // input layer fires only nonempty plans - see
        // planning.planEditorDeleteActions).
        .player_delete_editor_at => |delete| {
            if (current.editor) |*editor| {
                pushEvents(current, planning.planEditorDeleteActions(editor, delete.position, allocator), allocator);
            }
        },

        // --- Hub editor viewport verbs (the slice-4 drill-in; thin over
        // the shared planning facades - the input layer fires only
        // nonempty plans, so a dead-handle or no-op click records
        // nothing) ---
        .player_toggle_hub_inspector => {
            pushEvents(current, &.{.{ .hub_editor_event = .hub_toggle_inspector }}, allocator);
        },
        .player_toggle_hub_metadata_sidebar => {
            pushEvents(current, &.{.{ .hub_editor_event = .hub_toggle_metadata }}, allocator);
        },
        .player_set_hub_tool => |set| {
            const hub_editor = &(current.hub_editor orelse return);
            if (std.meta.eql(set.tool, hub_editor.active_tool)) return;
            pushEvents(current, &.{.{ .hub_editor_event = .{ .hub_set_tool = .{
                .tool = set.tool,
            } } }}, allocator);
        },
        .player_paint_hub_tile => |paint| {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(current, planning.planHubTilePaintActions(hub, current.campaign_editor.?.decoration_types, paint.position, allocator), allocator);
            }
        },
        .player_place_hub_npc => |place| {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(
                    current,
                    planning.gridStepsToHubEvents(
                        planning.planGridNpcPlacement(&hub.grid, current.campaign_editor.?.decoration_types, place.npc_type, place.position, allocator),
                        allocator,
                    ),
                    allocator,
                );
            }
        },
        .player_delete_hub_decoration_type => |delete| {
            if (current.hub_editor == null or current.campaign_editor == null) return;
            pushEvents(current, &.{.{ .hub_editor_event = .{ .hub_delete_decoration_type = .{
                .type_id = delete.type_id,
            } } }}, allocator);
        },
        .player_open_hub_picker => |open| {
            if (current.hub_editor == null) return;
            pushEvents(current, &.{.{ .hub_editor_event = .{ .hub_open_picker = .{
                .target = open.target,
            } } }}, allocator);
        },
        .player_close_hub_picker => {
            if (current.hub_editor == null) return;
            pushEvents(current, &.{.{ .hub_editor_event = .hub_close_picker }}, allocator);
        },
        .player_set_hub_decoration_def => |set| {
            if (current.hub_editor == null or current.campaign_editor == null) return;
            // The pick's commit: the def event + the close as its child
            // (one undo step - the editor-picker convention).
            pushEvents(current, &.{
                .{ .hub_editor_event = .{ .hub_set_decoration_def = .{
                    .type_id = set.type_id,
                    .sprite = set.sprite,
                    .footprint = set.footprint,
                    .pixel_dims = set.pixel_dims,
                    .color_index = set.color_index,
                    .keep_original_colors = set.keep_original_colors,
                    .layers = set.layers,
                } } },
                .{ .hub_editor_event = .hub_close_picker },
            }, allocator);
        },
        .player_add_hub_decoration_type => {
            if (current.hub_editor == null or current.campaign_editor == null) return;
            pushEvents(current, &.{.{ .hub_editor_event = .hub_add_decoration_type }}, allocator);
        },
        .player_set_hub_gradient => |set| {
            if (current.hub_editor == null or current.campaign_editor == null) return;
            // The theme-picker commit closes its picker in the same action
            // (pick + close = one undo step - the mission arm's rule).
            pushEvents(current, &.{
                .{ .hub_editor_event = .hub_close_picker },
                .{ .hub_editor_event = .{ .hub_set_gradient = .{
                    .role = set.role,
                    .gradient_index = set.gradient_index,
                } } },
            }, allocator);
        },
        .player_place_hub_decoration => |place| {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(current, planning.planHubDecorationPlacementActions(hub, current.campaign_editor.?.decoration_types, place.type_id, place.position, allocator), allocator);
            }
        },
        .player_place_hub_exit_marker => |place| {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(
                    current,
                    planning.gridStepsToHubEvents(
                        planning.planGridExitPlacement(&hub.grid, current.campaign_editor.?.decoration_types, place.mission, place.position, allocator),
                        allocator,
                    ),
                    allocator,
                );
            }
        },
        .player_toggle_hub_selection => |toggle| {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(current, planning.planHubToggleSelectionActions(hub, current.campaign_editor.?.decoration_types, current.hub_editor.?.selection, toggle.position, allocator), allocator);
            }
        },
        .player_replace_hub_selection => |replace| {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(current, planning.planHubReplaceSelectionActions(hub, current.campaign_editor.?.decoration_types, current.hub_editor.?.selection, replace.position, allocator), allocator);
            }
        },
        .player_select_hub_region => |region| {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(current, planning.planHubRegionSelectActions(hub, current.campaign_editor.?.decoration_types, current.hub_editor.?.selection, region.start_position, region.end_position, allocator), allocator);
            }
        },
        .player_select_hub_all => {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(current, planning.planHubSelectAllActions(hub, current.hub_editor.?.selection, allocator), allocator);
            }
        },
        .player_delete_hub_selection => {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(current, planning.planHubSelectionDeleteActions(hub, current.hub_editor.?.selection, allocator), allocator);
            }
        },
        .player_clear_hub_selection => {
            if (current.hub_editor == null) return;
            pushEvents(current, &.{.{ .hub_editor_event = .hub_clear_selection }}, allocator);
        },
        .player_move_hub_selection => |move| {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(current, planning.planHubSelectionMoveActions(hub, current.hub_editor.?.selection, move.delta, allocator), allocator);
            }
        },
        .player_delete_hub_at => |delete| {
            if (hub_editor_handlers.drilledHub(current)) |hub| {
                pushEvents(current, planning.planHubDeleteActions(hub, current.campaign_editor.?.decoration_types, delete.position, allocator), allocator);
            }
        },
        .player_overwrite_clone => {
            // Replace the existing clone for this mission with the just-
            // completed run's data. Only offered when overwrite_offered is
            // set (a clone exists + the run was not strictly faster). See
            // DESIGN → Clones (clone system).
            const info = current.last_completed_mission orelse return;
            // Consuming the offer retires the button (the overlay's
            // Overwrite Clone disappears once clicked - no dead re-
            // clickable button with no feedback, the playtester
            // confusion; the validation variant's Overwrite Replay
            // behaves the same way). A GameState write inside the
            // replayed handler - undo restores the offer with the rest
            // of the timeline.
            current.last_completed_mission.?.overwrite_offered = false;
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
                        // The exit's mission dir resolves through the
                        // loaded campaign's mission table (the load scan
                        // built it; replay reads the recorded path - the
                        // mission-browser-row precedent).
                        const mission_dir = missionDirForUuid(current, exit.mission_uuid) orelse {
                            // An exit whose mission cannot be resolved
                            // (hand-edited dangling reference): warn via
                            // the recoverable popup + no mission start.
                            history.session.setPendingError(
                                history.history_arena.allocator(),
                                "mission exit does not resolve to any installed mission",
                            );
                            break;
                        };
                        const mission_path = std.fmt.allocPrint(
                            allocator,
                            "campaigns/{s}/missions/{s}",
                            .{ current.campaign.?.dir, mission_dir },
                        ) catch @panic("failed to allocate mission path");
                        // The campaign edge's to-end: the edge table's
                        // destination for this mission rides the event (a
                        // dangling/empty destination passes null - the
                        // mission returns to this hub, the entering-hub
                        // fallback; the exit marker itself carries no
                        // edge data - DESIGN → File formats). See DESIGN →
                        // Campaigns & the Campaign Editor → The graph
                        // model.
                        var end_hub_id: ?[]const u8 = null;
                        if (campaignEdgeForMissionUuid(current, exit.mission_uuid)) |edge| {
                            if (edge.destination.len > 0) end_hub_id = edge.destination;
                        }
                        pushEvents(current, &.{
                            .{ .meta_event = .{ .start_mission = .{
                                .mission_path = mission_path,
                                .end_hub_id = end_hub_id,
                            } } },
                            .{ .meta_event = .end_hub },
                        }, allocator);
                        break;
                    }
                }
            }
        },
        // Hub NPC interaction: thin - the interacted NPC's TYPE routes it.
        // The upgrade vendor (gear_upgrader) is the first real consumer:
        // the click toggles the vendor panel (re-clicking the NPC closes
        // it - DESIGN → Gear Upgrading → The surface). A dream_guide has
        // no consumer yet (the dreams browser is unbuilt), so the live
        // click site never fires it - a recorded no-op would be worse
        // than a silent tile; a crafted log carrying one is rejected at
        // the validator.
        .interact_with_npc => |interact| {
            const hub = current.hub orelse return;
            if (interact.npc_index >= hub.npcs.len) return;
            switch (hub.npcs[interact.npc_index].npc_type) {
                .gear_upgrader => pushEvents(current, &.{.{ .meta_event = .{ .toggle_ui_surface = .{
                    .surface = .gear_upgrading,
                } } }}, allocator),
                .dream_guide => {},
            }
        },

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
            if (!history.replaying) history.session.queueActionSound(history.backing_allocator, .skip);
            pushEvents(current, &.{
                .{ .level_event = .{ .player_turn_attack = .{
                    .force_attack_step = skip.force_attack_step,
                } } },
                .{ .level_event = .clear_highlights },
            }, allocator);
        },
        .player_skip_move_to_skill => |skip| {
            // Inline composition, never a player_input orchestrator child:
            // the orchestrator convention is load-bearing for replay - every
            // recorded player_input event is seeded as input-origin, so a
            // handler-pushed player_input copy strands on the replay stack
            // forever (replay seeds the recorded event a second time on top,
            // and the handler-pushed original never pops). A slow-path
            // restore into such a region then drains + records the stray
            // against the wrong state - the undo-mangle crash's root cause.
            // The pop order below matches the old phantom flow exactly:
            // clear_highlights, player_turn_attack, then the prepare/use
            // arm's own composition.
            if (skip.prepare) {
                // The player_prepare_skill arm's body, inlined (order-safe:
                // player_turn_attack only flips the phase, and
                // clear_highlights is a no-op over the already-cleared set).
                const level = &current.level.?;
                level.highlighted_tiles = &.{};
                level.prepared_skill = skip.skill_id;
                const prepare_event: ?Event = if (lookups.getSkillDefinition(skip.skill_id)) |skill_definition|
                    skill_definition.playerPrepareSkill(0, current.*, allocator)
                else
                    null;
                if (prepare_event) |event| {
                    pushEvents(current, &.{
                        event,
                        .{ .level_event = .{ .player_turn_attack = .{
                            .force_attack_step = true,
                        } } },
                        .{ .level_event = .clear_highlights },
                    }, allocator);
                } else {
                    pushEvents(current, &.{
                        .{ .level_event = .{ .player_turn_attack = .{
                            .force_attack_step = true,
                        } } },
                        .{ .level_event = .clear_highlights },
                    }, allocator);
                }
            } else {
                // The player_use_skill arm's composition, inlined.
                const ends_turn = if (lookups.getSkillDefinition(skip.skill_id)) |def|
                    (def.skill_type == .weapon_skill or def.skill_type == .spell)
                else
                    false;
                if (ends_turn) {
                    pushEvents(current, &.{
                        .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
                        .{ .level_event = .{ .use_skill = .{
                            .caster_index = 0,
                            .skill_id = skip.skill_id,
                            .target = skip.target,
                        } } },
                        .{ .level_event = .clear_highlights },
                        .{ .level_event = .clear_prepared_skill },
                        .{ .level_event = .{ .player_turn_attack = .{
                            .force_attack_step = true,
                        } } },
                        .{ .level_event = .clear_highlights },
                    }, allocator);
                } else {
                    pushEvents(current, &.{
                        .{ .level_event = .{ .use_skill = .{
                            .caster_index = 0,
                            .skill_id = skip.skill_id,
                            .target = skip.target,
                        } } },
                        .{ .level_event = .clear_highlights },
                        .{ .level_event = .clear_prepared_skill },
                        .{ .level_event = .{ .player_turn_attack = .{
                            .force_attack_step = true,
                        } } },
                        .{ .level_event = .clear_highlights },
                    }, allocator);
                }
            }
        },
        .player_cancel_skill => {
            pushEvents(current, &.{
                .{ .level_event = .clear_highlights },
                .{ .level_event = .clear_prepared_skill },
            }, allocator);
        },
        .player_skip_attack => {
            if (!history.replaying) history.session.queueActionSound(history.backing_allocator, .skip);
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
            // Switching skills RESETS the previous skill's targeting UI:
            // the new skill's prepare event replaces the highlights only
            // when it has targets (a no-target prepare pushes no event -
            // `hostilesInRange` returns null, not empty - so without this
            // clear the previous skill's tiles would linger as stale
            // targeting UI; the observed bug).
            level.highlighted_tiles = &.{};
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
            // box - the slot list comes from the shared region helper (the
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
        .player_upgrade_item => |purchase| {
            // The legality (panel open, item carries the stat, not maxed,
            // affordable) is validated at record time; the machinery
            // re-runs its own no-op guards.
            pushEvents(current, &.{.{ .player_event = .{ .upgrade_item = purchase } }}, allocator);
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
