//! Event dispatch: `processEvent` - the single funnel through which all
//! undoable gameplay state mutates. Pops one event from
//! `GameState.event_stack`, records it into the session log when not
//! replaying, and routes it to its category handler:
//! meta → handlers/meta.zig, super/player → handlers/player.zig,
//! player-input orchestrators → handlers/player_input.zig,
//! level/sub-level → handlers/level.zig, editor → editor/handlers.zig
//! (plus the pure planners in editor/planning.zig). The recording/replay
//! bookkeeping, the start_level/start_hub checkpoint policy, and the
//! editor arm's cache-needing inline cases live here; the input handlers
//! (input_handlers.zig) and the live game loop (main.zig) call
//! `processEvent`, and state.zig's undo/redo/reconstruct machinery
//! receives it as an `apply_event` function pointer.

const std = @import("std");
const events = @import("events.zig");
const state = @import("state.zig");

const shared = @import("handlers/shared.zig");
const editor_handlers = @import("editor/handlers.zig");
const campaign_editor_handlers = @import("campaign_editor/handlers.zig");
const hub_editor_handlers = @import("campaign_editor/hub_handlers.zig");

const player_handlers = @import("handlers/player.zig");
const player_input = @import("handlers/player_input.zig");
const level_handlers = @import("handlers/level.zig");
const meta_handlers = @import("handlers/meta.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;

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
    // are already recorded, applying them to rebuild a past state - it must
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
            // post-event index - replaying from it would hit in-level sub-
            // events (aggro_check) with no level loaded and crash.
            const should_checkpoint = switch (meta) {
                .start_level => |level| level.sets_checkpoint,
                .start_hub => |hub| hub.sets_checkpoint,
                else => false,
            };

            meta_handlers.handleMetaEvent(history, allocator, meta);

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
                            // The selection is active-level-relative - a
                            // tab switch takes it with it (same event, so
                            // undo restores the tab AND its selection).
                            editor.selection = &.{};
                            // The tab switch re-frames the camera clamp
                            // onto the new level (see DESIGN → Platform
                            // Seam → Camera clamping).
                            editor_handlers.refreshEditorClampBounds(editor);
                        }
                    }
                },
                // The imports need the reconstruction cache (the
                // default-save / max-loadout reads) - handled inline here,
                // not in editor_handlers.handleEditorEvent.
                .editor_import_player => {
                    if (current.editor != null) editor_handlers.importEditorPlayer(history, current, allocator, .session);
                },
                .editor_import_max_player => {
                    if (current.editor != null) editor_handlers.importEditorPlayer(history, current, allocator, .max_player);
                },
                // The palette add-type events need the reconstruction cache
                // too (the defaults read) - same inline-handling reason as
                // the import above.
                .editor_add_entity_type => editor_handlers.addEditorPaletteType(history, current, allocator, .entity),
                .editor_add_decoration_type => editor_handlers.addEditorPaletteType(history, current, allocator, .decoration),
                .editor_add_item_type => editor_handlers.addEditorPaletteType(history, current, allocator, .item),
                // The add-level event needs the cache as well (the template
                // read) - same inline-handling reason.
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
        .campaign_editor_event => |campaign_editor_event| {
            // The campaign editor's own category (the EditorEvent sibling -
            // the parallel-state settle): pure transforms on
            // current.campaign_editor.?, plus the set-background dims read
            // (the one live seam - history passed for it).
            campaign_editor_handlers.handleCampaignEditorEvent(
                history,
                current,
                campaign_editor_event,
                allocator,
            );
        },
        .hub_editor_event => |hub_editor_event| {
            // The hub editor drill-in's category (the slice-4 family):
            // pure transforms writing through into
            // current.campaign_editor.?.hubs by the drill-in's handle.
            hub_editor_handlers.handleHubEditorEvent(
                history,
                current,
                hub_editor_event,
                allocator,
            );
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
