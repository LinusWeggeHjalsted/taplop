//! View - builds a `ViewState` each frame from the current game state.
//!
//! `view()` is pure over `GameState` + `SessionState` + the per-frame arena;
//! everything the ViewState points at lives until the next frame. The world
//! layers (tiles, overlays, ground drawables, occlusion insets) and the flat
//! `ui_elements` slice are assembled here. Camera math (`computeCamera`,
//! `tileToScreen`) lives here too - `gameLoop` computes the camera once per
//! frame and feeds it to both `view()` and input translation so input/render
//! never drift.

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const tween = @import("tween.zig");
const ui = @import("ui.zig");
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");
const functions = @import("functions.zig");
const combat_log = @import("combat_log.zig");
const validation_replay = @import("validation_replay.zig");
const event_handlers = @import("event_handlers.zig");
const lookups = @import("generated_lookups.zig");
const test_harness = @import("test_harness.zig");

const GameState = state.GameState;
const SessionState = state.SessionState;
const Vector2 = types.Vector2;
const Rectangle = types.Rectangle;
const Entity = types.Entity;
const Level = types.Level;
const Editor = types.Editor;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const ColorThemeDefinitions = types.ColorThemeDefinitions;
const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;
const WeaponType = types.WeaponType;

/// Per-frame render context: the camera, timing, event log view, and
/// frame arena that change every frame. Bundled so `view()` doesn't take a
/// long flat parameter list - the remaining params are session/game-state
/// that live across frames.
pub const RenderContext = struct {
    camera: types.Camera,
    camera_zoom: f32,
    event_history: []const events.Event,
    level_start_index: ?u32,
    current_event_index: u32,
    frame_allocator: std.mem.Allocator,
    /// Per-glyph font advances for the loaded font, so `view()` and the UI
    /// builders measure text with the same advances the renderer draws with.
    /// Extracted from the loaded raylib `Font` by the backend; raylib-free
    /// value type so it threads through the headless-tested `view()` path.
    font_metrics: ui.FontMetrics,
    /// Per-frame lookup of entity-sprite opaque-pixel bounding boxes: bare
    /// sprite stem (e.g. `skeleton_1`) -> `SpriteBounds` (top/bottom/left/
    /// right in SOURCE pixels), or null if the sprite can't be loaded/decoded.
    /// Built by `frame()` by querying the backend (which lazily decodes +
    /// caches -- same shape as the outline-mask cache) for each entity in the
    /// current world. Used by `view()` to place overlays against an entity's
    /// actual rendered art (skill icon above the top, hit flash at the
    /// vertical center, damage number at a corner) rather than the 512x640
    /// frame edges. Frame-arena-backed (no deinit). See AGENTS Animation.
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
    /// Whether undo / redo is available right now (`GameStateHistory.
    /// canUndo`/`canRedo`, computed by `frame()` where the history lives) -
    /// the dim state of the global top bar's undo/redo buttons.
    can_undo: bool,
    can_redo: bool,
};

pub fn view(
    current_state: *const GameState,
    session: *state.SessionState,
    settings: types.Settings,
    color_theme_definitions: types.ColorThemeDefinitions,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    tips: []const []const u8,
    render: RenderContext,
) types.ViewState {
    // Unpack the render context (local aliases keep the body readable).
    const camera = render.camera;
    const camera_zoom = render.camera_zoom;
    const frame_allocator = render.frame_allocator;
    const event_history = render.event_history;
    const level_start_index = render.level_start_index;
    const current_event_index = render.current_event_index;
    const font_metrics = render.font_metrics;

    const active_theme = activeThemeFor(current_state, color_theme_definitions);
    // Button panels tint with player gradient index 5 to read as buttons
    // against background panels (theme `darkest`). Threaded into every
    // panel-button builder.
    const button_color = active_theme.player_gradient.colors[@min(@as(u32, 5), types.gradient_color_count - 1)];

    // World layer: checkerboard tiles + entity sprites for the hub/level.
    var tiles: std.ArrayList(types.TileDrawable) = .empty;
    var tile_overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
    // Ground drawables (entities, decoration pieces, level-end / mission-start
    // markers) are collected into a sortable list and unified y-sorted so
    // decoration overhang pieces interleave correctly with entities (see
    // DESIGN → Decorations & Footprint). Tiles + overlays are separate layers.
    var ground_entries: std.ArrayList(GroundEntry) = .empty;
    if (current_state.level) |*level| {
        buildTiles(&tiles, frame_allocator, level.level_tiles, active_theme, camera, camera_zoom);
        buildHighlightOverlays(&tile_overlays, frame_allocator, level.highlighted_tiles, active_theme, camera, camera_zoom);
        buildCursorOverlay(&tile_overlays, frame_allocator, level.level_tiles, session, active_theme, camera, camera_zoom);
        buildPreparedSkillRadiusOutline(&tile_overlays, frame_allocator, level, session, active_theme, camera, camera_zoom);
        buildInspectedAggroOutline(&tile_overlays, frame_allocator, level, &current_state.ui_surfaces, active_theme, camera, camera_zoom);
        if (level.level_end) |end_position| {
            ground_entries.append(frame_allocator, .{
                .sort_y = end_position.y,
                .sort_x = end_position.x,
                .drawable = .{ .level_end = levelEndDrawable(end_position, active_theme, camera, camera_zoom, session.animation_clock, settings.animation_fps, !level.hasActiveEnemies()) },
            }) catch @panic("failed to append level-end entry");
        }
        // Level entities: build a pointer slice for the unified collector.
        {
            const entity_ptrs = frame_allocator.alloc(*const Entity, level.entities.len) catch
                @panic("failed to alloc entity pointer slice");
            for (level.entities, 0..) |*entity, index| entity_ptrs[index] = entity;
            collectEntityEntries(&ground_entries, frame_allocator, entity_ptrs, active_theme, settings.player_color_index, camera, camera_zoom, render.sprite_bounds, true);
        }
        for (level.decorations) |decoration| {
            const pieces = buildDecorationPieces(decoration, active_theme, camera, camera_zoom, frame_allocator);
            for (pieces) |entry| ground_entries.append(frame_allocator, entry) catch
                @panic("failed to append decoration piece entry");
        }
        for (level.ground_items) |stack| {
            ground_entries.append(frame_allocator, .{
                .sort_y = stack.position.y,
                .sort_x = stack.position.x,
                .drawable = .{ .ground_items = groundItemsDrawable(stack.position, @intCast(stack.items.len), active_theme, camera, camera_zoom) },
            }) catch @panic("failed to append ground-items entry");
        }
    } else if (current_state.hub) |*hub| {
        buildTiles(&tiles, frame_allocator, hub.hub_tiles, active_theme, camera, camera_zoom);
        buildCursorOverlay(&tile_overlays, frame_allocator, hub.hub_tiles, session, active_theme, camera, camera_zoom);
        for (hub.mission_exits) |exit| {
            ground_entries.append(frame_allocator, .{
                .sort_y = exit.position.y,
                .sort_x = exit.position.x,
                .drawable = .{ .level_end = levelEndDrawable(exit.position, active_theme, camera, camera_zoom, session.animation_clock, settings.animation_fps, true) },
            }) catch @panic("failed to append mission-start entry");
        }
        // Hub entities: the player rides the entity path; NPCs are plain
        // {npc_type, position} - their drawables derive from the type.
        {
            const player_ptrs = [_]*const Entity{&hub.player};
            collectEntityEntries(&ground_entries, frame_allocator, &player_ptrs, active_theme, settings.player_color_index, camera, camera_zoom, render.sprite_bounds, false);
        }
        for (hub.npcs) |npc| {
            ground_entries.append(frame_allocator, .{
                .sort_y = npc.position.y,
                .sort_x = npc.position.x,
                .drawable = .{ .entity = npcEntityDrawable(npc, active_theme, camera, camera_zoom) },
                .entity_sprite = npc.npc_type.spriteId(),
            }) catch @panic("failed to append npc ground entry");
        }
        for (hub.decorations) |decoration| {
            const pieces = buildDecorationPieces(decoration, active_theme, camera, camera_zoom, frame_allocator);
            for (pieces) |entry| ground_entries.append(frame_allocator, entry) catch
                @panic("failed to append decoration piece entry");
        }
    } else if (current_state.editor) |*editor| {
        // Edit mode: project the active EditorLevel into the same drawable
        // kinds the in-game view builds - no concrete Level exists. (During
        // playtest/validate the live `current.level` takes precedence above.)
        // See DESIGN → Architecture → Level Editor → Editor viewport
        // rendering.
        buildEditorScene(
            &tiles,
            &ground_entries,
            frame_allocator,
            editor,
            active_theme,
            settings.player_color_index,
            camera,
            camera_zoom,
            render.sprite_bounds,
            session.animation_clock,
            settings.animation_fps,
        );
        // Tile-cursor overlay: outline at the cursor (unconditional -
        // paints/placements target empty space too); the decoration tool
        // shows its footprint region outline, the select tool previews what
        // a click would select. The select tool's selection set renders as
        // WHITE outlines. See buildEditorCursorOverlay /
        // buildEditorSelectionOverlay.
        buildEditorCursorOverlay(
            &tile_overlays,
            frame_allocator,
            editor,
            session,
            active_theme,
            camera,
            camera_zoom,
        );
        buildEditorSelectionOverlay(
            &tile_overlays,
            frame_allocator,
            editor,
            // While a selection move drag is promoted on a
            // selected-at-press claim, the outlines preview the
            // translation (null otherwise - an unselected claim previews
            // via buildEditorMoveDragOverlay below, and its old selection
            // must NOT slide around: it is still the real selection).
            if (session.ui_state.editor_move_drag) |move_drag| blk: {
                if (!move_drag.promoted or !move_drag.selected_at_press) break :blk null;
                break :blk Vector2{
                    .x = move_drag.current_position_tile.x - move_drag.press_position_tile.x,
                    .y = move_drag.current_position_tile.y - move_drag.press_position_tile.y,
                };
            } else null,
            active_theme,
            camera,
            camera_zoom,
        );
        // The unselected-claim move-drag preview: the grabbed click
        // group's outline follows the pointer (see
        // buildEditorMoveDragOverlay).
        buildEditorMoveDragOverlay(
            &tile_overlays,
            frame_allocator,
            editor,
            session.ui_state.editor_move_drag,
            active_theme,
            camera,
            camera_zoom,
        );
        // The in-progress marquee rectangle (shift+left-drag, promoted):
        // a lightest region outline around the dragged region - the same
        // color as the selection it will add to. View-side transient state
        // (UiState.editor_marquee); the RESULT goes through events.
        buildEditorMarqueeOverlay(
            &tile_overlays,
            frame_allocator,
            session.ui_state.editor_marquee,
            active_theme,
            camera,
            camera_zoom,
        );
    }

    // Unified y-sort (ascending sort_y, then sort_x) and extract into the
    // ground_drawables list the ViewState carries.
    std.mem.sort(GroundEntry, ground_entries.items, {}, groundEntryBefore);
    var ground_drawables: std.ArrayList(types.GroundDrawable) = .empty;
    for (ground_entries.items) |entry| {
        ground_drawables.append(frame_allocator, entry.drawable) catch
            @panic("failed to append ground drawable");
    }

    // Occlusion insets: for each non-decoration ground entry, emit an inner
    // outline if a decoration piece drawn AFTER it (greater sort order)
    // overlaps the entry's screen rect. Pure view-side → replay-safe. See
    // DESIGN → Decorations & Footprint → Occlusion inset.
    const occlusion_insets = buildOcclusionInsets(
        frame_allocator,
        ground_entries.items,
        camera_zoom,
        render.sprite_bounds,
    );

    // World overlays: one-shot anims (skill icons, etc.) drawn above ground
    // sprites. Built from `session.active_anims`; see DESIGN → Animation.
    const world_overlays = buildWorldOverlays(
        frame_allocator,
        session,
        current_state,
        camera,
        camera_zoom,
        current_event_index,
        render.sprite_bounds,
        active_theme,
        font_metrics,
    );

    var ui_elements: std.ArrayList(ui.UiElement) = .empty;

    if (current_state.screen == .level or current_state.screen == .hub) {
        const drag_source: ?ui.SlotRef = if (session.ui_state.drag) |d| d.source else null;
        ui.buildBottomBar(
            &ui_elements,
            frame_allocator,
            font_metrics,
            ui.screenRect(),
            current_state,
            weapon_type_definitions,
            active_theme,
            settings.player_color_index,
            drag_source,
        ) catch @panic("failed to build bottom bar");

        // Middle panels (inventory / gear / skills / entity inspect): stacked
        // left-to-right, flush against the left edge of the screen, within the
        // band between the top and bottom bars. Each open panel with a builder
        // is placed at the current x cursor; `ui_gap` separates consecutive
        // panels. Horizontal scrolling when panels exceed the screen width is
        // not wired (`ui_state.middle_section_scroll_offset` exists); see TODO
        // → UI Framework.
        buildMiddlePanels(
            &ui_elements,
            frame_allocator,
            font_metrics,
            session,
            current_state,
            active_theme,
            weapon_type_definitions,
        ) catch @panic("failed to build middle panels");

        // Range/radius outline: when the pointer hovers a skill button,
        // preview the skill's reach as a single square outline (Chebyshev
        // ≤ range, else ≤ radius) centered on the player. Pure, off
        // SessionState - replay-safe like the cursor/tooltip. See AGENTS
        // → Input (hover-driven previews).
        buildSkillRangeOutline(
            &tile_overlays,
            frame_allocator,
            ui_elements.items,
            session,
            current_state,
            weapon_type_definitions,
            active_theme,
            camera,
            camera_zoom,
        );
    } else if (current_state.screen == .editor) {
        // Editor top row: one level tab per mission level plus the pinned
        // + / Test / Validate actions. The options/undo/redo buttons come
        // from the GLOBAL top bar (emitted at the end of this assembly, on
        // top of everything); the tab row starts right of its three cells.
        // Built before the bottom bar so the bottom bar's hover-highlight
        // pass wins overlaps, matching the level/hub order.
        // The editor is non-null on this screen by invariant (open_editor
        // sets it, close_editor transitions away).
        if (current_state.editor) |editor| {
            ui.buildEditorLevelTabs(
                &ui_elements,
                frame_allocator,
                font_metrics,
                editor,
                active_theme,
                &session.ui_state,
            ) catch @panic("failed to build editor level tabs");
            ui.buildEditorPrimaryActions(
                &ui_elements,
                frame_allocator,
                active_theme,
            ) catch @panic("failed to build editor primary actions");
            ui.buildEditorInspectorPanel(
                &ui_elements,
                frame_allocator,
                font_metrics,
                editor,
                active_theme,
                editor.inspector_open,
                &session.ui_state,
            ) catch @panic("failed to build editor inspector panel");
            ui.buildEditorMetadataSidebar(
                &ui_elements,
                frame_allocator,
                font_metrics,
                editor,
                active_theme,
                color_theme_definitions,
                editor.metadata_sidebar_open,
                &session.ui_state,
            ) catch @panic("failed to build editor metadata sidebar");
            ui.buildEditorBottomBar(
                &ui_elements,
                frame_allocator,
                font_metrics,
                ui.screenRect(),
                editor,
                active_theme,
                &session.ui_state.editor_palette_scroll,
                &session.ui_state.editor_palette_collapsed,
                editor.active_tool,
            ) catch @panic("failed to build editor bottom bar");
            // The centered picker draws LAST, above every editor surface
            // (modal - see handleAnytimeInput's gate). The picker's open
            // state rides GameState (Editor.picker - see DESIGN → UI
            // Framework → UI state classification); the view-side tab +
            // draft state stays on UiState.
            if (editor.picker) |picker_target| {
                switch (picker_target) {
                    .utility_skill_slot => ui.buildEditorSkillPicker(
                        &ui_elements,
                        frame_allocator,
                        font_metrics,
                        editor,
                        picker_target,
                        active_theme,
                    ) catch @panic("failed to build editor skill picker"),
                    // The entity + decoration sprite pickers (base +
                    // layer modes): the SAME panel - the builder resolves
                    // the picker kind from the target + the inspector
                    // target from the editor state.
                    .entity_sprite, .decoration_sprite, .entity_layer, .decoration_layer => ui.buildEditorSpritePicker(
                        &ui_elements,
                        frame_allocator,
                        font_metrics,
                        editor,
                        active_theme,
                        session.editor_mission_sprites,
                        session.editor_decoration_registry,
                        picker_target,
                        session.ui_state.editor_picker_sprite_tab,
                    ) catch @panic("failed to build editor sprite picker"),
                    // The decoration footprint editor: its own panel -
                    // the full-size sprite + the toggleable tile grid
                    // (the type id rides the picker target).
                    .decoration_footprint => |type_id| ui.buildEditorFootprintEditor(
                        &ui_elements,
                        frame_allocator,
                        font_metrics,
                        editor,
                        active_theme,
                        type_id,
                        &session.ui_state,
                    ) catch @panic("failed to build editor footprint editor"),
                    // The metadata sidebar's theme picker: every gradient
                    // as a strip (the level index + role ride the picker
                    // target; the list scrolls - see UiState).
                    .level_gradient => |gradient_target| ui.buildEditorThemePicker(
                        &ui_elements,
                        frame_allocator,
                        font_metrics,
                        editor,
                        color_theme_definitions,
                        active_theme,
                        .{ .level_index = gradient_target.level_index, .role = gradient_target.role },
                        &session.ui_state.editor_theme_picker_scroll_offset,
                    ) catch @panic("failed to build editor theme picker"),
                }
            }
        }
    } else if (current_state.screen == .main_menu) {
        // Continue is available when there is a game to resume: either
        // PlayerData is already populated (mid-session exit to menu) OR an
        // autosave exists from a prior session (fresh launch - detected once
        // at startup into session.autosave_available). See DESIGN → File
        // System & IO (autosave).
        const continue_available =
            current_state.player_data.current_campaign.len > 0 or session.autosave_available;
        ui.buildMainMenu(
            &ui_elements,
            frame_allocator,
            font_metrics,
            ui.screenRect(),
            continue_available,
            // The web signal (the buildOptionsMenu convention): null on web
            // (the Import Game button + the web storage disclaimer derive
            // from it), the resolved path on native.
            session.persistent_dir_path,
            button_color,
        ) catch @panic("failed to build main menu");
    }

    // Drag ghost: the dragged content follows the pointer, drawn last (on
    // top). Pointer position is in reference-resolution space (see
    // translateInput). Skill-bar/learned-skill drags render the button
    // background (player-gradient index 3, matching the bar's `c_border`)
    // under the icon (index 1); inventory/gear drags are icon-only (index 1,
    // matching `buildInventoryPanel`'s item_color). See DESIGN → Entity & UI
    // Coloring.
    if (session.ui_state.drag) |drag| {
        const pointer = session.input_state.mouse_screen_position;
        const ghost_pos = pointer.toScreenPosition();
        const p = active_theme.player_gradient.colors;
        const icon_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];
        const ghost_rect = types.Rectangle{
            .x = ghost_pos.x - @divTrunc(drag.size, 2),
            .y = ghost_pos.y - @divTrunc(drag.size, 2),
            .width = drag.size,
            .height = drag.size,
        };
        switch (drag.source) {
            .skill_bar, .learned_skill => {
                const bg_color = p[@min(@as(u32, 3), types.gradient_color_count - 1)];
                ui_elements.append(frame_allocator, .{ .image = .{
                    .sprite_id = "ui/skill_button",
                    .screen_position = ghost_rect.position(),
                    .width = drag.size,
                    .height = drag.size,
                    .color = bg_color,
                    .blocks_input = false,
                } }) catch @panic("failed to append drag ghost background");
                ui_elements.append(frame_allocator, .{ .image = .{
                    .sprite_id = drag.icon_sprite_id,
                    .screen_position = ghost_rect.position(),
                    .width = drag.size,
                    .height = drag.size,
                    .color = icon_color,
                    .blocks_input = false,
                } }) catch @panic("failed to append drag ghost icon");
            },
            .inventory, .gear => {
                ui_elements.append(frame_allocator, .{
                    .image = .{
                        .sprite_id = drag.icon_sprite_id,
                        .screen_position = ghost_rect.position(),
                        .width = drag.size,
                        .height = drag.size,
                        .color = icon_color,
                        // Follows the pointer; must not occlude drop-target hit-testing.
                        .blocks_input = false,
                    },
                }) catch @panic("failed to append drag ghost");
            },
        }
    }

    // The active editor run (playtest/validate), if any: the options menu
    // and the mission-fail overlay label their restart/exit buttons for
    // the run, and the campaign Export Save path stays hidden (the run's
    // player_data is temporary). Null on every other screen/context.
    const editor_run: ?types.EditorMode = if (current_state.editor) |editor|
        (if (editor.mode != .edit) editor.mode else null)
    else
        null;

    // Options menu: full-screen modal panel with a context-specific button
    // stack. Drawn on top of normal UI (bottom/top bars) but under the error
    // popup (which is the most-modal surface). Pure over
    // GameState.ui_surfaces.options_menu_open. See DESIGN → UI Framework.
    if (current_state.ui_surfaces.options_menu_open) {
        ui.buildOptionsMenu(
            &ui_elements,
            frame_allocator,
            font_metrics,
            ui.screenRect(),
            current_state.screen,
            editor_run,
            button_color,
            session.persistent_dir_path,
        ) catch @panic("failed to build options menu");
    }

    // Main-menu overlays (load-save browser, credits): both open ON TOP of
    // the options menu (the credits button lives in its main-menu variant;
    // the browser is reachable while the menu is closed), so they emit
    // AFTER it - painter order is draw order, and a full-screen panel
    // emitted earlier would be covered entirely. The list for the browser
    // lives on SessionState (scanned from the input path - view stays
    // file-free; see SessionState.save_files).
    if (current_state.screen == .main_menu) {
        if (current_state.ui_surfaces.load_save_menu_open) {
            ui.buildLoadSavePanel(
                &ui_elements,
                frame_allocator,
                font_metrics,
                ui.screenRect(),
                session.save_files,
                &session.ui_state.load_save_scroll_offset,
                button_color,
            ) catch @panic("failed to build load save panel");
        }

        // Modal like the load-save browser - the panel blocks input to the
        // buttons behind it.
        if (current_state.ui_surfaces.credits_open) {
            ui.buildCreditsPanel(
                &ui_elements,
                frame_allocator,
                font_metrics,
                ui.screenRect(),
                button_color,
            ) catch @panic("failed to build credits panel");
        }
    }

    // Tips overlay (any screen - opened from the global top bar's `?`
    // button): a full-screen modal like the credits panel. Emitted after
    // the options menu + main-menu overlays so it covers them; the error
    // popup (next) stays the most-modal surface, and the global top bar
    // (last) stays clickable above it.
    if (current_state.ui_surfaces.tips_open) {
        ui.buildTipsPanel(
            &ui_elements,
            frame_allocator,
            font_metrics,
            ui.screenRect(),
            tips,
            session.ui_state.tips_index,
            active_theme,
            button_color,
        ) catch @panic("failed to build tips panel");
    }

    // Mission-fail overlay: full-screen modal shown when the player is dead
    // (derived from level.entities[0].current_health == 0). Drawn on top of
    // the options menu (death takes precedence over a manually opened menu)
    // but under the error popup. The buttons reuse the options_action dispatch.
    // See DESIGN → Architecture.
    if (playerDead(current_state)) {
        ui.buildMissionFail(
            &ui_elements,
            frame_allocator,
            font_metrics,
            ui.screenRect(),
            editor_run,
            button_color,
        ) catch @panic("failed to build mission fail overlay");
    }

    // Mission-complete overlay: full-screen modal shown after the player
    // completes the last level of a mission - in the HUB for campaign
    // missions, or OVER THE EDITOR as the validation stats screen (the
    // info's validation flag; end_validation populated it). Derived from
    // GameState.last_completed_mission (on the undo timeline) so undo/redo
    // handles it naturally - undo to before completion clears it, redo re-
    // shows it, dismiss_mission_complete (Continue) clears it on the timeline.
    // The validation context (personal best + medal targets + the overwrite
    // offer) is session-side - built here; view is file-free, so the write
    // site captured the best. Drawn on top of the mission_fail overlay
    // (mutually exclusive) but under the error popup. See DESIGN →
    // Architecture + DESIGN → Custom Missions & Online Services →
    // Validation replay.
    if (current_state.last_completed_mission) |info| {
        const validation: ?ui.ValidationCompleteContext = if (info.validation) .{
            .personal_best_turns = session.validation_personal_best_turns,
            .medal_targets = validation_replay.medalTargets(
                session.validation_personal_best_turns orelse info.turns_spent,
            ),
            .overwrite_offered = session.validation_replay_overwrite_offered,
        } else null;
        ui.buildMissionComplete(
            &ui_elements,
            frame_allocator,
            font_metrics,
            ui.screenRect(),
            info,
            active_theme,
            validation,
        ) catch @panic("failed to build mission complete overlay");
    }

    // Settings screen: full-screen modal overlay. Opens on top of the
    // options menu (in-game drill-in) or directly over the main menu (main-
    // menu Settings button). Drawn under the error popup so a recoverable
    // error still surfaces on top. `blocks_input` panel shields the surface
    // behind it. See DESIGN → UI Framework → Settings screen.
    if (current_state.ui_surfaces.settings_open) {
        ui.buildSettingsPanel(
            &ui_elements,
            frame_allocator,
            font_metrics,
            ui.screenRect(),
            settings,
            active_theme.player_gradient,
            button_color,
            session.ui_state.settings_tab,
            &session.ui_state.keybind_scroll_offset,
            if (session.ui_state.keybind_edit != null)
                &session.ui_state.keybind_edit.?
            else
                null,
            &session.ui_state.keybind_picker_scroll_offset,
        ) catch @panic("failed to build settings panel");
    }

    // Editor browser: full-screen modal over the editor or the main
    // menu, on top of the options menu it opened from (the settings
    // screen's stacking - drawn under the error popup, which stays the
    // most-modal surface). The lists live on SessionState (scanned from
    // the input path when the browser opens - view stays file-free; see
    // SessionState.editor_local_missions).
    if (current_state.ui_surfaces.editor_browser_open) {
        ui.buildEditorBrowser(
            &ui_elements,
            frame_allocator,
            font_metrics,
            ui.screenRect(),
            session.ui_state.editor_browser_kind,
            session.editor_local_missions,
            session.editor_official_missions,
            session.ui_state.editor_mission_browser_tab,
            &session.ui_state.editor_mission_scroll_offset,
            button_color,
        ) catch @panic("failed to build editor browser");
    }

    // Recoverable error popup: modal, centered, drawn on top of all other
    // UI (including tooltips). Pure over SessionState.pending_error. See
    // DESIGN → Error Handling.
    if (session.pendingError()) |message| {
        ui.buildErrorPopup(&ui_elements, frame_allocator, font_metrics, session, message, button_color) catch
            @panic("failed to build error popup");
    }

    // GLOBAL TOP BAR (options / undo / redo): emitted last so the painter's-
    // order list draws it above every other element - options menu, mission
    // overlays, error popup - and hitTest's topmost-first scan gives it
    // click priority. Undo/redo stay reachable from any screen, including
    // over the mission-complete overlay (undoing the completing move
    // dismisses it - it's on the timeline). The editor's level tabs are NOT
    // part of this layer (they sit under overlays by design). See DESIGN →
    // UI Framework (global top bar).
    ui.buildGlobalTopBar(
        &ui_elements,
        frame_allocator,
        font_metrics,
        ui.screenRect(),
        active_theme,
        render.can_undo,
        render.can_redo,
        tips.len > 0,
    ) catch @panic("failed to build global top bar");

    // Hover tooltip: the topmost element under the pointer that carries
    // tooltip content spawns a tooltip, appended here so it draws on top of
    // all gameplay + overlay UI - bars, panels, options menu, mission
    // overlays, and the global top bar itself (which is why this pass runs
    // AFTER the top bar is emitted: its buttons must be in the list for a
    // hover to resolve to them). Modal 9-slice panels shield tooltip-bearing
    // elements behind them via `hitTest`'s blocks_input short-circuit, so a
    // tooltip never bleeds through a modal surface from an element
    // underneath; the only tooltip that can draw over a modal popup is one
    // spawned by the top bar, which sits above modals by design. Suppressed
    // while dragging.
    if (session.ui_state.drag == null) {
        const pointer = session.input_state.mouse_screen_position;
        const point = pointer.toScreenPosition();
        if (ui.tooltipAt(ui_elements.items, point)) |hovered| {
            const bounds = ui.boundsOf(hovered);
            ui.buildTooltip(
                &ui_elements,
                frame_allocator,
                font_metrics,
                bounds.position(),
                bounds.width,
                bounds.height,
                ui.tooltipOf(hovered).?,
            ) catch @panic("failed to build tooltip");
        }
    }

    // Hover highlight: the topmost button under the pointer gets an edge
    // outline (same `highlighted` path as the active turn-step indicator).
    // Suppressed while dragging (the pointer is dragging, not hovering).
    // Mutates the element in place by index so the renderer sees the flag.
    // Occlusion-aware: a modal popup on top shields buttons behind it.
    if (session.ui_state.drag == null) {
        const hover_pointer = session.input_state.mouse_screen_position;
        const hover_point = hover_pointer.toScreenPosition();
        if (ui.buttonIndexAt(ui_elements.items, hover_point)) |i| {
            ui_elements.items[i].button.highlighted = true;
        }
    }

    // Combat log: project the current level's events (up to the current
    // position) into a chronological filtered slice. None when not in a level
    // (no enclosing start_level in the prefix). Pure, per-frame, frame-arena.
    const projected_log: []const events.Event = if (level_start_index) |start|
        combat_log.projectCombatLog(event_history, start, current_event_index, frame_allocator)
    else
        &.{};

    // FPS diagnostic overlay: drawn on top of all UI in the top-left corner
    // when `settings.show_fps` is on - BELOW the global top bar, which owns
    // the corner now. Non-blocking so it can't steal clicks; outlined for
    // readability over any background. Reads the EMA maintained in
    // `frame()`'s render gate - pure over SessionState, so replay-safe.
    if (settings.show_fps) {
        const fps_rounded: i32 = @intFromFloat(@round(session.fps_smoothed));
        const fps_text = std.fmt.allocPrint(frame_allocator, "FPS {d}", .{fps_rounded}) catch
            @panic("failed to format fps label");
        ui_elements.append(frame_allocator, .{ .text_label = .{
            .text = fps_text,
            .screen_position = .{ .x = 16, .y = ui.top_bar_height + ui.ui_gap },
            .font_size = ui.settings_row_font_size,
            .outlined = true,
            .blocks_input = false,
        } }) catch @panic("failed to append fps label");
    }

    return .{
        .background_color = worldGradientColor(active_theme, 2),
        .active_color_theme = active_theme,
        .world_scale = camera_zoom,
        .outline_stripe_phase = outlineStripePhase(session.session_clock, settings.animation_fps),
        .tiles = tiles.items,
        .tile_overlays = tile_overlays.items,
        .ground_drawables = ground_drawables.items,
        .occlusion_insets = occlusion_insets,
        .world_overlays = world_overlays,
        .ui_elements = ui_elements.items,
        .font_metrics = font_metrics,
        .combat_log = projected_log,
    };
}

/// The active color theme for the current screen, derived from its
/// color_wheel_index (level/hub); a neutral default elsewhere.
fn activeThemeFor(
    current_state: *const GameState,
    color_theme_definitions: types.ColorThemeDefinitions,
) types.ActiveColorTheme {
    // In edit mode the editor screen has no live level/hub, so the theme
    // follows the ACTIVE level tab's settings. (During playtest/validate
    // the instantiated `current.level` exists and takes precedence above.)
    // Hubs carry no per-role overrides (wheel-only derivation).
    const world_index: u32, const enemy_override: ?u32, const player_override: ?u32 = if (current_state.level) |level|
        .{ level.color_wheel_index, level.enemy_gradient_index, level.player_gradient_index }
    else if (current_state.hub) |hub|
        .{ hub.color_wheel_index, null, null }
    else if (current_state.editor) |editor| blk: {
        if (editor.levels.len == 0) break :blk .{ 0, null, null };
        const level = editor.levels[@min(editor.active_level_index, editor.levels.len - 1)];
        break :blk .{ level.color_wheel_index, level.enemy_gradient_index, level.player_gradient_index };
    } else .{ 0, null, null };
    return loaders.deriveActiveColorTheme(color_theme_definitions, world_index, enemy_override, player_override);
}

/// Layout region for the middle panels: the horizontal band between the top
/// and bottom bars, full screen width. Panels stack left-to-right from x=0.
fn middleSectionRect() Rectangle {
    return .{
        .x = 0,
        .y = ui.top_bar_height,
        .width = types.reference_width,
        .height = types.reference_height - ui.top_bar_height - ui.bottom_bar_height,
    };
}

/// The width one open middle panel contributes to the left-flush stack,
/// or null when it renders nothing this frame (the inspect panel disappears
/// when its target is dead or absent). Shared by `buildMiddlePanels`
/// (layout) and `middlePanelsOccupiedWidth` (the camera clamp region) so
/// the two stay in lockstep.
fn middlePanelWidth(
    panel_id: ui.MiddlePanelId,
    current_state: *const GameState,
    font_metrics: ui.FontMetrics,
) ?i32 {
    return switch (panel_id) {
        .inventory => ui.inventory_panel_width,
        .gear => ui.gearPanelWidth(font_metrics),
        .skills => ui.skills_panel_width,
        // A dead target renders no panel: death is derivable from health
        // == 0 (the mission-fail-overlay precedent - no flag or event
        // needed), and undo (target alive again) reopens it for free. The
        // press site gates NEW inspects on alive; this only hides a target
        // that died while inspected.
        .entity_inspect => blk: {
            const entity_index = current_state.ui_surfaces.inspected_entity_index orelse break :blk null;
            const level = current_state.level orelse break :blk null;
            if (entity_index >= level.entities.len) break :blk null;
            if (level.entities[entity_index].current_health == 0) break :blk null;
            break :blk ui.entity_inspect_panel_width;
        },
    };
}

/// Total reference-space width the open middle panels occupy (the right
/// edge of the left-flush stack, `ui_gap` between consecutive rendered
/// panels) - the x extent the camera clamp region excludes. 0 when nothing
/// renders.
fn middlePanelsOccupiedWidth(
    current_state: *const GameState,
    font_metrics: ui.FontMetrics,
) i32 {
    var occupied: i32 = 0;
    var rendered: u32 = 0;
    for (current_state.ui_surfaces.open_middle_panels) |maybe_panel| {
        const panel_id = maybe_panel orelse continue;
        const panel_width = middlePanelWidth(panel_id, current_state, font_metrics) orelse continue;
        if (rendered > 0) occupied += ui.ui_gap;
        occupied += panel_width;
        rendered += 1;
    }
    return occupied;
}

/// Dispatch each open middle panel to its builder, stacking them left-to-
/// right flush against the left edge of the screen. Each panel is TOP-
/// ANCHORED in the middle section (`middle_panel_height` is the content
/// exact-fit, not the section height) so the strip between the panels'
/// bottom edge and the bottom bar stays clear - the bottom-bar indicator
/// row (momentum / effects / turn steps) lives there, and must not sit
/// behind open panels. A panel that renders nothing this frame (the
/// inspect panel's target dying) reserves no space. The x cursor advances
/// by `ui_gap` between consecutive built panels. Panel widths come from
/// `middlePanelWidth`, shared with the camera clamp region. See DESIGN →
/// UI Framework.
fn buildMiddlePanels(
    elements: *std.ArrayList(ui.UiElement),
    allocator: std.mem.Allocator,
    font_metrics: ui.FontMetrics,
    session: *state.SessionState,
    current_state: *const GameState,
    active_theme: types.ActiveColorTheme,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
) !void {
    const section = middleSectionRect();
    var cursor_x: i32 = 0;
    for (current_state.ui_surfaces.open_middle_panels) |maybe_panel| {
        const panel_id = maybe_panel orelse continue;
        const panel_width = middlePanelWidth(panel_id, current_state, font_metrics) orelse continue;
        const bounds = Rectangle{
            .x = cursor_x,
            .y = section.y,
            .width = panel_width,
            .height = ui.middle_panel_height,
        };
        switch (panel_id) {
            .inventory => {
                // The live inventory rides on the player entity (in-level
                // pickups land on `entity.inventory`; `player_data.inventory`
                // is the persistent copy synced only on exit). Materials live
                // on PlayerData (no entity field), so the sidebar reads
                // `player_data.materials`.
                const inventory = if (ui.playerEntity(current_state)) |player| player.inventory else types.Inventory{};
                // Comparison baseline for item tooltips: the player's
                // equipped gear (entity 0 in a level, the hub player
                // outside one).
                const equipped_gear = if (ui.playerEntity(current_state)) |player|
                    ui.equippedGearFromEntity(player)
                else
                    null;
                const drag_source: ?ui.SlotRef = if (session.ui_state.drag) |d| d.source else null;
                try ui.buildInventoryPanel(
                    elements,
                    allocator,
                    font_metrics,
                    bounds,
                    inventory,
                    current_state.player_data.materials,
                    current_state.player_data.learned_skills,
                    equipped_gear,
                    active_theme,
                    drag_source,
                    session.held_modifiers,
                    session.ui_state.salvage_region,
                );
            },
            .gear => {
                const player = if (ui.playerEntity(current_state)) |pl| pl else types.Entity{};
                const drag_source: ?ui.SlotRef = if (session.ui_state.drag) |d| d.source else null;
                try ui.buildGearPanel(
                    elements,
                    allocator,
                    font_metrics,
                    bounds,
                    player,
                    current_state.player_data.learned_skills,
                    active_theme,
                    drag_source,
                );
            },
            .skills => {
                const drag_source: ?ui.SlotRef = if (session.ui_state.drag) |d| d.source else null;
                try ui.buildSkillsPanel(
                    elements,
                    allocator,
                    font_metrics,
                    bounds,
                    current_state.player_data.learned_skills,
                    active_theme,
                    &session.ui_state.skills_scroll_offset,
                    drag_source,
                );
            },
            .entity_inspect => {
                // `middlePanelWidth` returned non-null above, so the target
                // resolves (fail-fast unwrap, the level-handler precedent).
                const entity_index = current_state.ui_surfaces.inspected_entity_index.?;
                const level = current_state.level.?;
                const entity = level.entities[entity_index];
                try ui.buildEntityInspectPanel(
                    elements,
                    allocator,
                    font_metrics,
                    bounds,
                    entity,
                    current_state.player_data.learned_skills,
                    // Compare the inspected entity's gear against the
                    // player's - unless the inspected entity IS the player
                    // (entity 0 in a level; inspect only opens in levels).
                    if (entity_index == 0) null else if (ui.playerEntity(current_state)) |player| ui.equippedGearFromEntity(player) else null,
                    active_theme,
                    weapon_type_definitions,
                );
            },
        }
        cursor_x += panel_width + ui.ui_gap;
    }
}

/// Whether the player is dead in the current level (entity 0 health == 0).
/// Used by view() to render the mission_fail overlay and by update()/gameLoop
/// to pause event processing. Derived from GameState (not a flag) so it's
/// automatically undo-safe: undoing past the death restores health, clearing
/// the overlay. Returns false outside a level or when the level has no entities.
pub fn playerDead(current_state: *const GameState) bool {
    if (current_state.level) |level| {
        if (level.entities.len > 0) return level.entities[0].current_health == 0;
    }
    return false;
}

/// The player's tile position for the current screen (entity 0 in a level,
/// the hub player), or the origin when neither is active.
fn playerPosition(current_state: *const GameState) types.Vector2 {
    if (current_state.level) |level| {
        if (level.entities.len > 0) return level.entities[0].position;
    }
    if (current_state.hub) |hub| return hub.player.position;
    // Edit mode: the active level's player start is the editor's "player
    // position" analog, so the camera centers there (pan + zoom apply as
    // usual). Playtest/validate keep the live level, which takes precedence
    // above.
    if (current_state.editor) |editor| {
        if (editor.levels.len == 0) return .{ .x = 0, .y = 0 };
        return editor.levels[@min(editor.active_level_index, editor.levels.len - 1)].player_start;
    }
    return .{ .x = 0, .y = 0 };
}

/// World-pixel bounding box of the current screen's tile grid, full tile
/// extents (min tile origin .. max tile far edge). Levels and hubs scan
/// their LIVE tile lists (levels are non-rectangular (`level_tiles` is a
/// flat position list), so the bbox is the natural "level rectangle"). The
/// editor arm reads the ACTIVE level's `clamp_bounds` SNAPSHOT instead -
/// taken at level-switch time, so mid-edit tile changes never reframe the
/// camera (see DESIGN → Platform Seam → Camera clamping). Null when the
/// screen has no live world or no tiles (a level that was empty at
/// snapshot stays unclamped). The live level takes precedence over the
/// editor arm - during playtest/validate the editor state persists on a
/// `.level` screen and the INSTANTIATED level bounds apply.
const WorldPixelBounds = struct {
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
};

fn screenWorldBounds(
    current_state: *const GameState,
    tile_pixels: f32,
) ?WorldPixelBounds {
    if (current_state.level) |level| {
        return tileListWorldBounds(level.level_tiles, tile_pixels);
    } else if (current_state.hub) |hub| {
        return tileListWorldBounds(hub.hub_tiles, tile_pixels);
    } else if (current_state.editor) |editor| {
        const snapshot = editor.clamp_bounds orelse return null;
        return .{
            .min_x = @as(f32, @floatFromInt(snapshot.min_x)) * tile_pixels,
            .max_x = @as(f32, @floatFromInt(snapshot.max_x + 1)) * tile_pixels,
            .min_y = @as(f32, @floatFromInt(snapshot.min_y)) * tile_pixels,
            .max_y = @as(f32, @floatFromInt(snapshot.max_y + 1)) * tile_pixels,
        };
    }
    return null;
}

/// The live tile-list scan behind the level/hub arms of `screenWorldBounds`.
fn tileListWorldBounds(
    tiles: []const types.Vector2,
    tile_pixels: f32,
) ?WorldPixelBounds {
    if (tiles.len == 0) return null;
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
    return .{
        .min_x = @as(f32, @floatFromInt(min_x)) * tile_pixels,
        .max_x = @as(f32, @floatFromInt(max_x + 1)) * tile_pixels,
        .min_y = @as(f32, @floatFromInt(min_y)) * tile_pixels,
        .max_y = @as(f32, @floatFromInt(max_y + 1)) * tile_pixels,
    };
}

/// One axis of the camera clamp (pure, directly tested):
///
/// - Level-flush bounds for the AUTOMATIC camera (pan_slack == 0): the
///   visible world window stays inside the level, so auto-centering never
///   shows void. When the level is narrower than the region, it is centered
///   as a whole.
/// - The player-margin band (player keeps `margin` clearance from the
///   region edge) applies only to the automatic camera and only when the
///   level overflows the region: it caps how far the flush clamp may push
///   the camera away from the player-centered position. Sequential
///   clamping gives the spec'd behavior - shift toward the flush bound as
///   far as possible WITHOUT pushing the player past the margin.
/// - A deliberate pan (pan_slack > 0, `camera_pan_void_tiles` scaled to
///   world pixels) skips the margin band and widens the bounds by the
///   slack: the pan may push that many tiles of void past an edge (or past
///   the centered position on a fitting axis) before stopping - wiggle
///   room, so the edge clamp doesn't feel like a hard wall.
fn clampCameraAxis(
    camera_center: f32,
    world_lo: f32,
    world_hi: f32,
    region_lo: f32,
    region_hi: f32,
    reference_half: f32,
    player_center: f32,
    margin: f32,
    pan_slack: f32,
) f32 {
    const a = region_lo - reference_half;
    const b = region_hi - reference_half;
    const flush_min = world_lo - a;
    const flush_max = world_hi - b;
    const automatic = pan_slack == 0.0;
    if (flush_min > flush_max) {
        // The level fits inside the region on this axis: center it as a
        // whole. The margin band is skipped - centering wins (the whole
        // level is already visible; nothing better exists). A pan wiggles
        // around the centered position by the slack.
        const centered = (world_lo + world_hi) / 2.0 - (a + b) / 2.0;
        if (automatic) return centered;
        return std.math.clamp(camera_center, centered - pan_slack, centered + pan_slack);
    }
    var clamped = std.math.clamp(camera_center, flush_min - pan_slack, flush_max + pan_slack);
    if (automatic) {
        const margin_min = player_center - b + margin;
        const margin_max = player_center - a - margin;
        if (margin_min <= margin_max) clamped = std.math.clamp(clamped, margin_min, margin_max);
    }
    return clamped;
}

/// Camera centered on the player (plus an optional right-drag pan offset):
/// places the player tile's center at the screen center, then adds `pan`,
/// then - when `view_region` is non-null (levels/hubs/editor viewport; see
/// cameraViewRegion) - clamps the result: level-flush bounds (a deliberate
/// pan gets `camera_pan_void_tiles` of wiggle past them), the
/// `camera_edge_margin_tiles` margin for the automatic (unpanned) camera.
/// EXCEPT in the editor viewport, where a pan is completely free (no
/// bounds at all): unpanned = clamped framing, panned = roam anywhere.
/// Position is in the same world-pixel space screenToTile inverts
/// (tile coord * tile_size_pixels * zoom). `pan` is in world pixels too.
/// Both the input camera and the render camera pass through here so input
/// and rendering never drift relative to each other or the pan offset. The
/// pan gesture's solve passes `view_region = null` to get the unclamped
/// player-centered reference its pan math is relative to.
pub fn computeCamera(
    current_state: *const GameState,
    zoom: f32,
    pan: ?types.Vector2,
    view_region: ?Rectangle,
) types.Camera {
    const player_tile = playerPosition(current_state);
    const tile_pixels = input.tile_size_pixels * zoom;
    const player_center_x = (@as(f32, @floatFromInt(player_tile.x)) + 0.5) * tile_pixels;
    const player_center_y = (@as(f32, @floatFromInt(player_tile.y)) + 0.5) * tile_pixels;
    var pos = types.Vector2{
        .x = @intFromFloat(player_center_x),
        .y = @intFromFloat(player_center_y),
    };
    if (pan) |offset| {
        pos.x += offset.x;
        pos.y += offset.y;
    }
    if (view_region) |region| {
        // The editor viewport's pan is completely free (no flush bounds, no
        // wiggle). The level==null guard matters: during playtest/validate
        // the editor state persists on a `.level` screen, and there the
        // LEVEL clamp (with wiggle) applies.
        const editor_viewport = current_state.editor != null and current_state.level == null;
        if (editor_viewport and pan != null) return .{ .position = pos };
        const bounds = screenWorldBounds(current_state, tile_pixels) orelse
            return .{ .position = pos };
        const margin = @as(f32, @floatFromInt(camera_edge_margin_tiles)) * tile_pixels;
        // A deliberate pan buys camera_pan_void_tiles of void past the
        // level edges (wiggle room); the automatic camera is strictly
        // void-free. pan_slack == 0 is the "automatic camera" signal the
        // axis clamp keys its margin band on.
        const pan_slack: f32 = if (pan != null)
            @as(f32, @floatFromInt(camera_pan_void_tiles)) * tile_pixels
        else
            0.0;
        const camera_x = clampCameraAxis(
            @floatFromInt(pos.x),
            bounds.min_x,
            bounds.max_x,
            @as(f32, @floatFromInt(region.x)),
            @as(f32, @floatFromInt(region.x + region.width)),
            @as(f32, @floatFromInt(@divTrunc(types.reference_width, 2))),
            player_center_x,
            margin,
            pan_slack,
        );
        const camera_y = clampCameraAxis(
            @floatFromInt(pos.y),
            bounds.min_y,
            bounds.max_y,
            @as(f32, @floatFromInt(region.y)),
            @as(f32, @floatFromInt(region.y + region.height)),
            @as(f32, @floatFromInt(@divTrunc(types.reference_height, 2))),
            player_center_y,
            margin,
            pan_slack,
        );
        pos = .{ .x = @intFromFloat(@round(camera_x)), .y = @intFromFloat(@round(camera_y)) };
    }
    return .{ .position = pos };
}

/// The camera-recenter key: what a frame's pan-clear check compares
/// before/after `update()` (main.zig). The player's tile, plus the editor's
/// active level index - a level-tab switch recenters even when two levels
/// share a player_start (fresh levels all come from the same template, so
/// identical spawns across tabs are the common case, not a freak accident).
pub fn cameraRecenterKey(current_state: *const GameState) struct { position: types.Vector2, editor_level_index: ?usize } {
    return .{
        .position = playerPosition(current_state),
        .editor_level_index = if (current_state.editor) |editor| editor.active_level_index else null,
    };
}

/// Tunable: minimum clearance (tiles) the automatic camera keeps between
/// the player and the view region edge. Eyeball in `zig build run` (the
/// `skill_icon_size_native` precedent).
const camera_edge_margin_tiles: i32 = 2;

/// Tunable: how many tiles of void a deliberate pan may show past a level
/// edge before the clamp stops it (wiggle room past the strict bounds).
/// The automatic camera never shows void. Eyeball in `zig build run`.
const camera_pan_void_tiles: i32 = 4;

/// The camera clamp region for the current screen: the reference-space
/// rectangle the camera keeps level content inside (and the player inside
/// with `camera_edge_margin_tiles` clearance, when not panning). The top
/// and bottom bars bound it vertically; open middle panels bound it from
/// the left. The EDITOR viewport uses the same band at full width - the
/// sidebars and pickers are deliberately ignored (they never reframe the
/// camera). Null outside levels/hubs/the editor. See DESIGN → Platform
/// Seam → Camera clamping.
pub fn cameraViewRegion(
    current_state: *const GameState,
    font_metrics: ui.FontMetrics,
    zoom: f32,
) ?Rectangle {
    if (current_state.screen == .editor) {
        if (current_state.editor == null) return null;
        return cameraViewRegionFor(0, zoom);
    }
    if (current_state.screen != .level and current_state.screen != .hub) return null;
    if (current_state.level == null and current_state.hub == null) return null;
    return cameraViewRegionFor(middlePanelsOccupiedWidth(current_state, font_metrics), zoom);
}

/// Pure core of `cameraViewRegion`. The panels' occupied width is dropped
/// ("act as if no panels open") when the remaining width can't fit the
/// player-margin band on both sides - the fully-covered-screen case, and
/// any sliver too narrow to guarantee the margin.
fn cameraViewRegionFor(occupied_width: i32, zoom: f32) Rectangle {
    const margin_band: f32 = @as(f32, @floatFromInt(2 * camera_edge_margin_tiles)) * input.tile_size_pixels * zoom;
    var x: i32 = 0;
    if (occupied_width > 0) {
        const remaining: f32 = @floatFromInt(types.reference_width - occupied_width);
        if (remaining >= margin_band) x = occupied_width;
    }
    return .{
        .x = x,
        .y = ui.top_bar_height,
        .width = types.reference_width - x,
        .height = types.reference_height - ui.top_bar_height - ui.bottom_bar_height,
    };
}

/// Convert a tile coordinate to its top-left screen position (reference space).
/// Exact inverse of input.screenToTile so clicks land on the drawn tile.
fn tileToScreen(tile: types.Vector2, camera: types.Camera, zoom: f32) types.ScreenPosition {
    const tile_pixels = input.tile_size_pixels * zoom;
    const half_width: f32 = @floatFromInt(@divTrunc(types.reference_width, 2));
    const half_height: f32 = @floatFromInt(@divTrunc(types.reference_height, 2));
    const x = @as(f32, @floatFromInt(tile.x)) * tile_pixels - @as(f32, @floatFromInt(camera.position.x)) + half_width;
    const y = @as(f32, @floatFromInt(tile.y)) * tile_pixels - @as(f32, @floatFromInt(camera.position.y)) + half_height;
    return .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
}

/// The tile's center point in reference space - a click point that
/// `input.screenToTile` resolves back to this tile (the camera transform at
/// its half-tile offset). The console level dump prints these so a script
/// can click a tile straight off the dump line.
pub fn tileClickCenter(tile: types.Vector2, camera: types.Camera, zoom: f32) types.ScreenPosition {
    const top_left = tileToScreen(tile, camera, zoom);
    const half_tile: i32 = @intFromFloat(@round(input.tile_size_pixels * zoom / 2.0));
    return .{ .x = top_left.x + half_tile, .y = top_left.y + half_tile };
}

/// Pure white - the "no tint" color for `keep_original_colors` rendering
/// (the multiply identity: the art keeps its own colors). See DESIGN →
/// Entity & UI Coloring.
const no_tint_color: types.Color = .{ .r = 255, .g = 255, .b = 255 };

/// Entity sprite frame: all entities/weapons share one 512x640 frame (2 tiles
/// wide x 2.5 tall) authored at tile_size_pixels, with one normalized pivot
/// (horizontal center, at the feet with 0.5 tile of foot/shadow overflow).
const entity_frame_width: f32 = @floatFromInt(types.entity_sprite_frame_width);
const entity_frame_height: f32 = @floatFromInt(types.entity_sprite_frame_height);
/// Integer frame dims for the compositing canvas (occlusion inset stack).
const entity_frame_width_int: i32 = types.entity_sprite_frame_width;
const entity_frame_height_int: i32 = types.entity_sprite_frame_height;
const entity_pivot_x: f32 = 0.5;
const entity_pivot_y: f32 = 0.8;

/// One-shot skill-icon anim: square edge in native reference pixels (the
/// renderer multiplies by `world_scale`, matching tiles/entities), and the
/// gap above the entity's actual art top (found at runtime from the sprite's
/// topmost non-transparent pixel - see `RenderContext.sprite_bounds`). Tunable
/// - eyeball in `zig build run`. See DESIGN → Animation.
const skill_icon_size_native: i32 = 256;
const skill_icon_gap_native: i32 = 16;
/// Native (unscaled) pixel size of the aggro indicator icon drawn above an
/// entity's health bar when it gets aggroed (one-shot, 500ms). 1:1 with the
/// ported EnemyAggro.png art (128×128). Placed like the skill icon. See
/// DESIGN → Animation.
const aggro_indicator_size_native: i32 = 128;
/// Native (unscaled) pixel size of the stun overlay icon drawn above the
/// health bar of a stunned entity (while `stun_duration > 0`). 1:1 with the
/// StunEffect.png art (128×128). Tunable. See DESIGN → Animation.
const stun_icon_size_native: i32 = 128;

/// One-shot hit-flash anim: the `world/hit_flash` sprite (256x256, ported
/// from the Unity project's 512x512 Hit.png at 0.5x) flashed over a damaged
/// entity's rendered art center for 250ms, tinted with the active theme's
/// `lightest` color (the artist's offwhite). Drawn centered on the entity's
/// horizontal frame center and the real vertical center of its opaque art
/// (via `sprite_bounds` top + bottom). Tunable -- eyeball in
/// `zig build run`. See DESIGN → Animation.
const hit_flash_size_native: i32 = 256;
/// Native (unscaled) pixel size of an effect overlay sprite (drawn centered
/// on the entity's art bbox, scaled by `zoom` at render time). Tunable.
const effect_overlay_size_native: i32 = 90;

/// One-shot number anims (damage/heal): the number travels 1 tile from the
/// entity's sprite bbox edge/corner, eased with `tween.easeOutCubic` (fast
/// then slow). 500ms duration (queued by handlers; the constant lives here
/// for the `view()`-side travel distance + font size). Font size is
/// independent of the tooltip body - damage numbers read best large.
/// Tunable - eyeball in `zig build run`. See DESIGN → Animation.
const number_anim_duration_microseconds: u32 = 500_000;
const number_travel_tiles: f32 = 0.5;
const number_font_size: i32 = 112;

/// Entity health bar. The bar + outline sprites are 155x31 native (cropped
/// to the outline's opaque bbox and downscaled 0.5x from the 384x128 Unity
/// art). Drawn above the entity's actual art top (same `sprite_bounds` scan
/// as the skill icon). The skill icon sits above the health bar, so it's
/// offset by the bar's height + this gap. Tunable - eyeball in `zig build
/// run`. See DESIGN → Entity & UI Coloring.
const health_bar_native_width: i32 = 155;
const health_bar_native_height: i32 = 31;
const health_bar_gap_native: i32 = 8;

/// Ground-items sprite: `world/ground_items.png` (256x256, centered pivot
/// 0.5/0.5). Tinted at world gradient index 5 (a fixed color independent of
/// the player's body color, like the UI palette). Drawn at the stack's tile;
/// `item_count` is unused at draw time (the renderer draws just the sprite).
const ground_items_sprite_id = "world/ground_items";
const ground_items_size: f32 = 256.0;
/// Integer frame dim for the ground-items compositing canvas (occlusion inset).
const ground_items_size_int: i32 = 256;
const ground_items_pivot_x: f32 = 0.5;
const ground_items_pivot_y: f32 = 0.5;

/// Flag pole frame: 256x512 (1 tile wide x 2 tall). Pivot (0.5, 0.75) centers
/// the bottom tile-half of the frame on the marker's tile. Used for both level
/// ends and hub mission-start markers; only the static pole is drawn here.
const flag_pole_width: f32 = 256.0;
const flag_pole_height: f32 = 512.0;
/// Integer frame dims for the flag compositing canvas (occlusion inset).
const flag_pole_width_int: i32 = 256;
const flag_pole_height_int: i32 = 512;
const flag_pivot_x: f32 = 0.5;
const flag_pivot_y: f32 = 0.75;

/// Animated banner sprite (`world/flag.png`): a horizontal strip of 8 frames,
/// each 256x512 (same dims + pivot as the pole). Drawn over the pole at the
/// same screen position. Looping at `settings.animation_fps` (default 8 →
/// 125 ms/frame, 1.0 s loop). See DESIGN → Animation.
const flag_banner_sprite_id = "world/flag";
const flag_banner_frame_count: u32 = 8;
const flag_banner_frame_width: i32 = 256;
const flag_banner_frame_height: i32 = 512;

/// Steps per full outline-stripe cycle (one light + one dark band) - the
/// crawl speed of the outline stripe shader (see DESIGN → Platform Seam →
/// Outline stripe shader): one full cycle per `outline_stripe_steps`
/// frames at `animation_fps` - the shared animation rate (one animation
/// system), stepped from the UNGATED session clock so stripes march even
/// while the world is paused.
const outline_stripe_steps: u32 = 8;

/// The outline stripe phase (0..1) for the UNGATED `session_clock`
/// (outlines are UI + decorative - they animate during pause; see DESIGN
/// → Animation), stepped at `animation_fps`. The clock wraps mod the cycle
/// IN u64 BEFORE the f32 conversion - f32 mantissa holds only ~16.8s of
/// microseconds, so an unwrapped clock loses phase precision after
/// minutes.
fn outlineStripePhase(session_clock_microseconds: u64, animation_fps: u32) f32 {
    const effective_fps: u32 = if (animation_fps == 0) 8 else animation_fps;
    const frame_duration_us: u64 = 1_000_000 / effective_fps;
    const elapsed_frames = session_clock_microseconds / frame_duration_us;
    const step = elapsed_frames % outline_stripe_steps;
    return @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(outline_stripe_steps));
}
fn levelEndDrawable(
    tile: types.Vector2,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
    animation_clock_microseconds: u64,
    animation_fps: u32,
    banner_visible: bool,
) types.LevelEndDrawable {
    const tile_top_left = tileToScreen(tile, camera, zoom);
    const tile_pixels = input.tile_size_pixels * zoom;
    const center_x = @as(f32, @floatFromInt(tile_top_left.x)) + tile_pixels / 2;
    const center_y = @as(f32, @floatFromInt(tile_top_left.y)) + tile_pixels / 2;

    // Pick the banner frame: frame = (elapsed / frame_duration) % frame_count.
    // animation_fps is the one global rate all anims share (settings). A zero
    // fps is treated as the default (8) to avoid a divide-by-zero.
    const effective_fps: u32 = if (animation_fps == 0) 8 else animation_fps;
    const frame_duration_us: u64 = 1_000_000 / effective_fps;
    const elapsed_frames: u64 = animation_clock_microseconds / frame_duration_us;
    const frame_index: u32 = @intCast(elapsed_frames % flag_banner_frame_count);

    return .{
        .sprite_id = "world/flag_pole",
        .screen_position = .{
            .x = @intFromFloat(@round(center_x - flag_pivot_x * flag_pole_width * zoom)),
            .y = @intFromFloat(@round(center_y - flag_pivot_y * flag_pole_height * zoom)),
        },
        .color = worldGradientColor(active_theme, 5),
        .banner_color = worldGradientColor(active_theme, 0),
        // The banner waves only while the level is completable - on the
        // level screen `!level.hasActiveEnemies()`, the SAME rule the win
        // condition checks (`Level.hasActiveEnemies`); hub mission-start
        // and editor markers always wave (not levels - no enemies).
        // See DESIGN → Animation.
        .banner_source_rectangle = if (banner_visible) .{
            .x = @as(i32, @intCast(frame_index)) * flag_banner_frame_width,
            .y = 0,
            .width = flag_banner_frame_width,
            .height = flag_banner_frame_height,
        } else null,
    };
}

/// Build a `GroundItemDrawable` for a ground-item stack at `tile`. The sprite
/// is centered on the tile (pivot 0.5/0.5), tinted at world gradient index 5
/// (fixed, independent of the player's body color). `item_count` is carried
/// on the drawable but unused at draw time (the renderer draws just the
/// sprite, no count badge).
fn groundItemsDrawable(
    tile: types.Vector2,
    item_count: u32,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) types.GroundItemDrawable {
    const tile_top_left = tileToScreen(tile, camera, zoom);
    const tile_pixels = input.tile_size_pixels * zoom;
    const center_x = @as(f32, @floatFromInt(tile_top_left.x)) + tile_pixels / 2;
    const center_y = @as(f32, @floatFromInt(tile_top_left.y)) + tile_pixels / 2;
    return .{
        .sprite_id = ground_items_sprite_id,
        .screen_position = .{
            .x = @intFromFloat(@round(center_x - ground_items_pivot_x * ground_items_size * zoom)),
            .y = @intFromFloat(@round(center_y - ground_items_pivot_y * ground_items_size * zoom)),
        },
        .color = worldGradientColor(active_theme, 5),
        .item_count = item_count,
    };
}

/// Top-left of an entity's 512x640 frame in reference-resolution space,
/// aligning the shared pivot (0.5, 0.8) to the center of the entity's tile.
/// Shared by `entityDrawable` (body + weapons + layers register here) and
/// the world-overlay builder (floating icons place above this point).
fn entityFrameTopLeft(position: types.Vector2, camera: types.Camera, zoom: f32) types.ScreenPosition {
    const tile_top_left = tileToScreen(position, camera, zoom);
    const tile_pixels = input.tile_size_pixels * zoom;
    const center_x = @as(f32, @floatFromInt(tile_top_left.x)) + tile_pixels / 2;
    const center_y = @as(f32, @floatFromInt(tile_top_left.y)) + tile_pixels / 2;
    const draw_width = entity_frame_width * zoom;
    const draw_height = entity_frame_height * zoom;
    return .{
        .x = @intFromFloat(@round(center_x - entity_pivot_x * draw_width)),
        .y = @intFromFloat(@round(center_y - entity_pivot_y * draw_height)),
    };
}

/// Build the world-overlay list from `session.active_anims`. An anim shows
/// when its triggering event is in the projected history (`event_index <
/// current_event_index` - same exclusive bound the combat log uses, so undo
/// hides it) AND it hasn't elapsed (`animation_clock < end_clock`). Skill
/// icons track the entity (resolved from the CURRENT level each frame) and
/// skip dead entities; a screen/world transition clears the list, so an anim
/// never outlives its level. Later-pushed anims append later → draw later →
/// stack on top (the most recent skill use reads on top). See DESIGN →
/// Animation.
fn buildWorldOverlays(
    allocator: std.mem.Allocator,
    session: *state.SessionState,
    current_state: *const GameState,
    camera: types.Camera,
    zoom: f32,
    current_event_index: u32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
    active_theme: types.ActiveColorTheme,
    font_metrics: ui.FontMetrics,
) []const types.WorldOverlayDrawable {
    const level = current_state.level orelse return &.{};
    var overlays: std.ArrayList(types.WorldOverlayDrawable) = .empty;
    for (session.active_anims.items) |anim| {
        if (anim.event_index >= current_event_index) continue;
        // `start_clock` gate: a staggered number anim is invisible before its
        // start; all anims vanish past `end_clock`. See AGENTS Animation.
        if (session.animation_clock < anim.start_clock) continue;
        if (session.animation_clock >= anim.end_clock) continue;
        switch (anim.kind) {
            .skill_icon => |info| {
                if (info.entity_index >= level.entities.len) continue;
                const entity = &level.entities[info.entity_index];
                if (entity.current_health == 0) continue;

                const top_left = entityFrameTopLeft(entity.position, camera, zoom);
                const draw_width = entity_frame_width * zoom;
                const drawn_size: f32 = @as(f32, @floatFromInt(skill_icon_size_native)) * zoom;
                const gap: f32 = @as(f32, @floatFromInt(skill_icon_gap_native)) * zoom;
                const icon_x = @as(f32, @floatFromInt(top_left.x)) + draw_width / 2 - drawn_size / 2;
                const art_top_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
                    if (maybe_bounds) |bounds|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
                    else
                        @as(f32, @floatFromInt(top_left.y))
                else
                    @as(f32, @floatFromInt(top_left.y));
                // The health bar sits above the art top (always-on), so the
                // icon is offset further by the bar's height + gap to avoid
                // overlap. See DESIGN → Animation / Entity & UI Coloring.
                const health_bar_total: f32 =
                    @as(f32, @floatFromInt(health_bar_native_height + health_bar_gap_native)) * zoom;
                const icon_y = art_top_y - health_bar_total - drawn_size - gap;
                const sprite_id = std.fmt.allocPrint(allocator, "skills/{s}", .{@tagName(info.skill_id)}) catch
                    @panic("failed to build skill-icon sprite id");
                // Tinted with the caster's team gradient index 1 (player →
                // player gradient, enemy → enemy gradient - same convention
                // as weapon colors). See DESIGN → Entity & UI Coloring.
                const icon_color = if (entity.team == 0)
                    playerColor(active_theme, 1)
                else
                    enemyColor(active_theme, 1);
                overlays.append(allocator, .{ .floating_icon = .{
                    .sprite_id = sprite_id,
                    .screen_position = .{
                        .x = @intFromFloat(@round(icon_x)),
                        .y = @intFromFloat(@round(icon_y)),
                    },
                    .size = skill_icon_size_native,
                    .color = icon_color,
                } }) catch @panic("failed to append world overlay");
            },
            .aggro_indicator => |info| {
                // Mirrors the skill-icon placement (above the health bar)
                // but tinted with the active theme's `lightest`. The
                // indicator is a one-shot cosmetic marker that the entity
                // was aggroed this event; skip dead entities (a newly-dead
                // aggroed entity shouldn't show it). See DESIGN → Animation.
                if (info.entity_index >= level.entities.len) continue;
                const entity = &level.entities[info.entity_index];
                if (entity.current_health == 0) continue;

                const top_left = entityFrameTopLeft(entity.position, camera, zoom);
                const draw_width = entity_frame_width * zoom;
                const drawn_size: f32 = @as(f32, @floatFromInt(aggro_indicator_size_native)) * zoom;
                const gap: f32 = @as(f32, @floatFromInt(skill_icon_gap_native)) * zoom;
                const icon_x = @as(f32, @floatFromInt(top_left.x)) + draw_width / 2 - drawn_size / 2;
                const art_top_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
                    if (maybe_bounds) |bounds|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
                    else
                        @as(f32, @floatFromInt(top_left.y))
                else
                    @as(f32, @floatFromInt(top_left.y));
                const health_bar_total: f32 =
                    @as(f32, @floatFromInt(health_bar_native_height + health_bar_gap_native)) * zoom;
                const icon_y = art_top_y - health_bar_total - drawn_size - gap;
                overlays.append(allocator, .{ .floating_icon = .{
                    .sprite_id = "world/aggro",
                    .screen_position = .{
                        .x = @intFromFloat(@round(icon_x)),
                        .y = @intFromFloat(@round(icon_y)),
                    },
                    .size = aggro_indicator_size_native,
                    .color = active_theme.lightest,
                } }) catch @panic("failed to append world overlay");
            },
            .hit_flash => |info| {
                // A killing blow still flashes: `death` zeroes health but
                // leaves the entity slot in the array, so the index stays
                // valid. We bounds-check only (not `current_health == 0`,
                // which the skill-icon path uses to skip dead casters).
                if (info.entity_index >= level.entities.len) continue;
                const entity = &level.entities[info.entity_index];

                const top_left = entityFrameTopLeft(entity.position, camera, zoom);
                const draw_width = entity_frame_width * zoom;
                const draw_height = entity_frame_height * zoom;
                // Horizontal: entities are always horizontally centered in
                // the frame, so the art center is the frame's horizontal
                // center.
                const center_x: f32 = @as(f32, @floatFromInt(top_left.x)) + draw_width / 2;
                // Vertical: real center of the opaque art via top-y +
                // bottom-y; fall back to the frame's vertical center on a
                // miss/transparent sprite.
                const art_top_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
                    if (maybe_bounds) |bounds|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
                    else
                        @as(f32, @floatFromInt(top_left.y))
                else
                    @as(f32, @floatFromInt(top_left.y));
                const art_bottom_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
                    if (maybe_bounds) |bounds|
                        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.bottom.?)) * zoom
                    else
                        @as(f32, @floatFromInt(top_left.y)) + draw_height
                else
                    @as(f32, @floatFromInt(top_left.y)) + draw_height;
                const center_y: f32 = (art_top_y + art_bottom_y) / 2;
                const drawn_size: f32 = @as(f32, @floatFromInt(hit_flash_size_native)) * zoom;
                overlays.append(allocator, .{ .floating_icon = .{
                    .sprite_id = "world/hit_flash",
                    .screen_position = .{
                        .x = @intFromFloat(@round(center_x - drawn_size / 2)),
                        .y = @intFromFloat(@round(center_y - drawn_size / 2)),
                    },
                    .size = hit_flash_size_native,
                    .color = active_theme.lightest,
                } }) catch @panic("failed to append world overlay");
            },
            .damage_number => |info| {
                if (info.entity_index >= level.entities.len) continue;
                const entity = &level.entities[info.entity_index];
                const progress = animProgress(anim, session.animation_clock);
                const text = std.fmt.allocPrint(allocator, "{d}", .{info.value}) catch
                    @panic("failed to format damage number");
                const pos = numberAnimPosition(
                    entity,
                    sprite_bounds,
                    camera,
                    zoom,
                    info.direction,
                    progress,
                    font_metrics,
                    text,
                );
                overlays.append(allocator, .{
                    .floating_text = .{
                        .text = text,
                        .screen_position = pos,
                        .font_size = number_font_size,
                        // Damage reads red regardless of magnitude - including 0.
                        .color = ui.negative_color,
                    },
                }) catch @panic("failed to append world overlay");
            },
            .heal_number => |info| {
                if (info.entity_index >= level.entities.len) continue;
                const entity = &level.entities[info.entity_index];
                const progress = animProgress(anim, session.animation_clock);
                // Heals have no attacker: fixed up-right from the top-left
                // bbox corner. See AGENTS Animation.
                const text = std.fmt.allocPrint(allocator, "+{d}", .{info.value}) catch
                    @panic("failed to format heal number");
                const pos = numberAnimPosition(
                    entity,
                    sprite_bounds,
                    camera,
                    zoom,
                    .{ .x = 1, .y = -1 },
                    progress,
                    font_metrics,
                    text,
                );
                overlays.append(allocator, .{
                    .floating_text = .{
                        .text = text,
                        .screen_position = pos,
                        .font_size = number_font_size,
                        // Heals read green regardless of magnitude - including 0.
                        .color = ui.positive_color,
                    },
                }) catch @panic("failed to append world overlay");
            },
        }
    }

    // Stun overlay: a persistent icon drawn above the health bar of any
    // entity with `stun_duration > 0`. Not an anim - no clock, no duration,
    // no `active_anims` entry - just a direct GameState read, so it's
    // replay-safe by construction (stun_duration is on the snapshot
    // timeline). Shares the skill-icon's placement (above the health bar,
    // which sits above the art top). A stunned entity skips its turn (no
    // skill use) so the stun icon and a skill-icon pop never co-occur on
    // the same entity - same position is safe. See DESIGN → Animation.
    for (level.entities) |*entity| {
        if (entity.stun_duration == 0) continue;
        if (entity.current_health == 0) continue;

        const top_left = entityFrameTopLeft(entity.position, camera, zoom);
        const draw_width = entity_frame_width * zoom;
        const drawn_size: f32 = @as(f32, @floatFromInt(stun_icon_size_native)) * zoom;
        const gap: f32 = @as(f32, @floatFromInt(skill_icon_gap_native)) * zoom;
        const icon_x = @as(f32, @floatFromInt(top_left.x)) + draw_width / 2 - drawn_size / 2;
        const art_top_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
            if (maybe_bounds) |bounds|
                @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
            else
                @as(f32, @floatFromInt(top_left.y))
        else
            @as(f32, @floatFromInt(top_left.y));
        const health_bar_total: f32 =
            @as(f32, @floatFromInt(health_bar_native_height + health_bar_gap_native)) * zoom;
        const icon_y = art_top_y - health_bar_total - drawn_size - gap;
        overlays.append(allocator, .{ .floating_icon = .{
            .sprite_id = "effects/stun",
            .screen_position = .{
                .x = @intFromFloat(@round(icon_x)),
                .y = @intFromFloat(@round(icon_y)),
            },
            .size = stun_icon_size_native,
            .color = active_theme.lightest,
        } }) catch @panic("failed to append stun overlay");
    }
    return overlays.items;
}

/// Eased progress for a one-shot anim: `(clock - start) / duration` clamped
/// to [0, 1], passed through `tween.easeOutCubic` (fast then slow). Callers
/// that don't move (skill icon, hit flash) ignore this; number anims use it
/// to interpolate position. Pure, rendering-side, reads the pause-gated
/// session clock. See AGENTS Animation.
fn animProgress(anim: types.ActiveAnim, animation_clock: u64) f32 {
    if (anim.end_clock <= anim.start_clock) return 1.0;
    const elapsed: f32 = @floatFromInt(animation_clock - anim.start_clock);
    const duration: f32 = @floatFromInt(anim.end_clock - anim.start_clock);
    const raw = std.math.clamp(elapsed / duration, 0.0, 1.0);
    return tween.easeOutCubic(raw);
}

/// Compute the screen-space top-left for a floating number anim, given the
/// entity, its sprite bbox, the travel `direction` (-1/0/1 per axis), and the
/// eased `progress` in [0, 1]. The number starts at the bbox edge/corner
/// nearest the direction and travels `number_travel_tiles` along the
/// normalized direction. The text is offset so it grows AWAY from the sprite
/// (left-going → right edge at anchor; up-going → bottom at anchor; centered
/// on the pure-vertical/horizontal axes). See AGENTS Animation.
fn numberAnimPosition(
    entity: *const types.Entity,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
    camera: types.Camera,
    zoom: f32,
    direction: types.Vector2,
    progress: f32,
    font_metrics: ui.FontMetrics,
    text: []const u8,
) types.ScreenPosition {
    const top_left = entityFrameTopLeft(entity.position, camera, zoom);
    const draw_width = entity_frame_width * zoom;
    const draw_height = entity_frame_height * zoom;
    // Resolve the opaque-art bbox in screen space; fall back to the frame
    // edges on a miss/transparent sprite.
    const maybe_bounds = sprite_bounds.get(entity.sprite);
    const left_x: f32 = if (maybe_bounds) |b| if (b) |bounds|
        @as(f32, @floatFromInt(top_left.x)) + @as(f32, @floatFromInt(bounds.left.?)) * zoom
    else
        @as(f32, @floatFromInt(top_left.x)) else @as(f32, @floatFromInt(top_left.x));
    const right_x: f32 = if (maybe_bounds) |b| if (b) |bounds|
        @as(f32, @floatFromInt(top_left.x)) + @as(f32, @floatFromInt(bounds.right.?)) * zoom
    else
        @as(f32, @floatFromInt(top_left.x)) + draw_width else @as(f32, @floatFromInt(top_left.x)) + draw_width;
    const top_y: f32 = if (maybe_bounds) |b| if (b) |bounds|
        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
    else
        @as(f32, @floatFromInt(top_left.y)) else @as(f32, @floatFromInt(top_left.y));
    const bottom_y: f32 = if (maybe_bounds) |b| if (b) |bounds|
        @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.bottom.?)) * zoom
    else
        @as(f32, @floatFromInt(top_left.y)) + draw_height else @as(f32, @floatFromInt(top_left.y)) + draw_height;

    // Start point: the bbox edge/corner nearest the travel direction.
    const dx: i32 = direction.x;
    const dy: i32 = direction.y;
    const start_x: f32 = if (dx < 0) left_x else if (dx > 0) right_x else (left_x + right_x) / 2;
    const start_y: f32 = if (dy < 0) top_y else if (dy > 0) bottom_y else (top_y + bottom_y) / 2;

    // Travel 1 tile along the normalized direction (diagonal → magnitude 1,
    // not √2, so the visual distance is consistent across the 8 directions).
    const mag = @sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy)));
    const unit_x = @as(f32, @floatFromInt(dx)) / mag;
    const unit_y = @as(f32, @floatFromInt(dy)) / mag;
    const travel = number_travel_tiles * input.tile_size_pixels * zoom;
    const end_x = start_x + unit_x * travel;
    const end_y = start_y + unit_y * travel;
    var x = start_x + (end_x - start_x) * progress;
    var y = start_y + (end_y - start_y) * progress;

    // Offset so the text grows away from the sprite: left-going → right edge
    // at anchor; up-going → bottom at anchor; pure vertical → horizontally
    // centered; pure horizontal → vertically centered.
    const text_width: f32 = @as(f32, @floatFromInt(
        font_metrics.measureSpanWidth(.{ .text = text }, number_font_size),
    )) * zoom;
    const text_height: f32 = @as(f32, @floatFromInt(number_font_size)) * zoom;
    if (dx < 0) {
        x -= text_width;
    } else if (dx == 0) {
        x -= text_width / 2;
    }
    if (dy < 0) {
        y -= text_height;
    } else if (dy == 0) {
        y -= text_height / 2;
    }
    return .{
        .x = @intFromFloat(@round(x)),
        .y = @intFromFloat(@round(y)),
    };
}

/// Build an EntityDrawable for `entity`, aligning the shared sprite pivot to
/// the center of the entity's tile. Populates the base sprite, body overlay
/// layers, and weapons; active-effect overlays populate front_effect_sprites
/// from each effect's `effect_sprite`. Gear sprites are not wired. The health
/// bar is populated (always-on for alive entities), placed above the entity's
/// actual art top via the `sprite_bounds` lookup. See DESIGN → Entity & UI
/// Coloring.
fn entityDrawable(
    entity: *const Entity,
    active_theme: types.ActiveColorTheme,
    player_color_index: u32,
    is_player: bool,
    camera: types.Camera,
    zoom: f32,
    allocator: std.mem.Allocator,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
    show_health_bar: bool,
) types.EntityDrawable {
    const top_left = entityFrameTopLeft(entity.position, camera, zoom);
    const base_sprite_id = std.fmt.allocPrint(allocator, "entities/{s}", .{entity.sprite}) catch
        @panic("failed to build entity sprite id");

    // Body color: the gradient by team (player team → player gradient,
    // enemy teams → enemy gradient); the INDEX - the player entity uses
    // the settings-driven player_color_index, every other entity (enemy-
    // authored team-0 helpers included) its own color_index. Untinted
    // (pure white) instead when keep_original_colors is set - the art
    // keeps its own colors (weapons + health bar stay themed; see DESIGN
    // → Entity & UI Coloring).
    const body_color = if (entity.keep_original_colors)
        no_tint_color
    else if (entity.team == 0)
        playerColor(active_theme, if (is_player) player_color_index else entity.color_index)
    else
        enemyColor(active_theme, entity.color_index);

    // Overlay layers: same frame + pivot as the base, drawn after base and
    // before weapons. Each colored by its own index into the team gradient
    // (untinted with the base when keep_original_colors is set).
    var layer_sprites: std.ArrayList(types.SpriteDrawable) = .empty;
    for (entity.layers) |layer| {
        const layer_sprite_id = std.fmt.allocPrint(allocator, "entities/{s}", .{layer.sprite}) catch
            @panic("failed to build entity layer sprite id");
        const layer_color = if (entity.keep_original_colors)
            no_tint_color
        else if (entity.team == 0)
            playerColor(active_theme, layer.color_index)
        else
            enemyColor(active_theme, layer.color_index);
        layer_sprites.append(allocator, .{
            .sprite_id = layer_sprite_id,
            .screen_position = top_left,
            .draw_offset = .{ .x = 0, .y = 0 },
            .source_rectangle = null,
            .color = layer_color,
        }) catch @panic("failed to append entity layer sprite");
    }
    const layer_slice = layer_sprites.toOwnedSlice(allocator) catch
        @panic("failed to own entity layer sprites");

    // Weapons: main hand drawn as-authored (left), off hand mirrored (right).
    // Suppressed for entities that don't display weapons (e.g. wolves).
    // Color = team gradient index 1 (player → player gradient, enemy → enemy
    // gradient).
    const weapon_color = if (entity.team == 0)
        playerColor(active_theme, 1)
    else
        enemyColor(active_theme, 1);
    var weapon_sprites: [2]?types.SpriteDrawable = .{ null, null };
    if (entity.displays_weapons) {
        if (entity.main_hand_weapon) |weapon| {
            weapon_sprites[0] = weaponSprite(entity, weapon.weapon_type, top_left, false, weapon_color, allocator);
        }
        if (entity.off_hand_weapon) |weapon| {
            weapon_sprites[1] = weaponSprite(entity, weapon.weapon_type, top_left, true, weapon_color, allocator);
        }
    }

    // Active-effect overlays: one front_effect_sprite per effect that
    // declares an `effect_sprite`, centered on the entity's opaque-art bbox
    // (horizontal = frame center; vertical = midpoint of the bbox top/bottom,
    // falling back to the frame's vertical center on a miss/transparent
    // sprite - same resolution as the hit-flash one-shot). Tinted with the
    // active theme's lightest color. See DESIGN → Entity & UI Coloring.
    var front_effect_sprites: std.ArrayList(types.SpriteDrawable) = .empty;
    if (entity.active_effects.len > 0) {
        const draw_width = entity_frame_width * zoom;
        const draw_height = entity_frame_height * zoom;
        const center_x: f32 = @as(f32, @floatFromInt(top_left.x)) + draw_width / 2;
        const maybe_bounds = sprite_bounds.get(entity.sprite);
        const art_top_y: f32 = if (maybe_bounds) |maybe| if (maybe) |bounds|
            @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
        else
            @as(f32, @floatFromInt(top_left.y)) else @as(f32, @floatFromInt(top_left.y));
        const art_bottom_y: f32 = if (maybe_bounds) |maybe| if (maybe) |bounds|
            @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(bounds.bottom.?)) * zoom
        else
            @as(f32, @floatFromInt(top_left.y)) + draw_height else @as(f32, @floatFromInt(top_left.y)) + draw_height;
        const center_y: f32 = (art_top_y + art_bottom_y) / 2;
        const drawn_size: f32 = @as(f32, @floatFromInt(effect_overlay_size_native)) * zoom;
        const overlay_top_left: types.ScreenPosition = .{
            .x = @intFromFloat(@round(center_x - drawn_size / 2)),
            .y = @intFromFloat(@round(center_y - drawn_size / 2)),
        };
        for (entity.active_effects) |active_effect| {
            const definition = lookups.getEffectDefinition(active_effect.effect_id);
            const effect_stem = definition.effect_sprite orelse continue;
            const sprite_id = std.fmt.allocPrint(allocator, "effects/{s}", .{effect_stem}) catch
                @panic("failed to build effect overlay sprite id");
            front_effect_sprites.append(allocator, .{
                .sprite_id = sprite_id,
                .screen_position = overlay_top_left,
                .draw_offset = .{ .x = 0, .y = 0 },
                .source_rectangle = null,
                .color = active_theme.lightest,
            }) catch @panic("failed to append effect overlay sprite");
        }
    }
    const front_effect_slice = front_effect_sprites.toOwnedSlice(allocator) catch
        @panic("failed to own effect overlay sprites");

    return .{
        .back_effect_sprites = &.{},
        .base_sprite = .{
            .sprite_id = base_sprite_id,
            .screen_position = top_left,
            .draw_offset = .{ .x = 0, .y = 0 },
            .source_rectangle = null,
            .color = body_color,
        },
        .layer_sprites = layer_slice,
        .weapon_sprites = weapon_sprites,
        .gear_sprites = &.{},
        .front_effect_sprites = front_effect_slice,
        .health_bar = if (show_health_bar) buildHealthBar(entity, active_theme, top_left, zoom, sprite_bounds) else null,
    };
}

/// Build the always-on health bar above the entity's actual art top.
/// Depleted = global theme darkest; fill = team gradient index 1. The bar
/// canvas (155x31 native) is centered horizontally over the entity frame;
/// the outline sprite is drawn on top by the renderer at the same rect.
/// See DESIGN → Entity & UI Coloring.
fn buildHealthBar(
    entity: *const Entity,
    active_theme: types.ActiveColorTheme,
    frame_top_left: types.ScreenPosition,
    zoom: f32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
) ?types.HealthBarDrawable {
    if (entity.getEffectiveMaxHealth() == 0) return null;
    const draw_width = entity_frame_width * zoom;
    const art_top_y: f32 = if (sprite_bounds.get(entity.sprite)) |maybe_bounds|
        if (maybe_bounds) |bounds|
            // `bounds.top` is in source pixels (0..640); the drawn frame height is
            // `entity_frame_height * zoom`, so the art top in screen space is
            // `frame_top + bounds.top * zoom`.
            @as(f32, @floatFromInt(frame_top_left.y)) + @as(f32, @floatFromInt(bounds.top.?)) * zoom
        else
            @as(f32, @floatFromInt(frame_top_left.y))
    else
        @as(f32, @floatFromInt(frame_top_left.y));
    const bar_width: f32 = @as(f32, @floatFromInt(health_bar_native_width)) * zoom;
    const bar_height: f32 = @as(f32, @floatFromInt(health_bar_native_height)) * zoom;
    const gap: f32 = @as(f32, @floatFromInt(health_bar_gap_native)) * zoom;
    const bar_x = @as(f32, @floatFromInt(frame_top_left.x)) + draw_width / 2 - bar_width / 2;
    const bar_y = art_top_y - bar_height - gap;
    const fill_color = if (entity.team == 0)
        playerColor(active_theme, 1)
    else
        enemyColor(active_theme, 1);
    return .{
        .screen_position = .{
            .x = @intFromFloat(@round(bar_x)),
            .y = @intFromFloat(@round(bar_y)),
        },
        .width = health_bar_native_width,
        .height = health_bar_native_height,
        .fill_fraction = @as(f32, @floatFromInt(entity.current_health)) / @as(f32, @floatFromInt(entity.getEffectiveMaxHealth())),
        .depleted_color = active_theme.darkest,
        .fill_color = fill_color,
    };
}

/// Build a weapon overlay sprite for an entity. The weapon art shares the
/// entity frame + pivot, so it uses the same top-left as the body. Player
/// bodies (team 0) use the plain art; enemy silhouettes use the enemy_ variant.
/// Off-hand weapons are mirrored to sit on the right.
fn weaponSprite(
    entity: *const Entity,
    weapon_type: types.WeaponType,
    top_left: types.ScreenPosition,
    flip_horizontal: bool,
    color: types.Color,
    allocator: std.mem.Allocator,
) types.SpriteDrawable {
    const variant_prefix = if (entity.team == 0) "" else "enemy_";
    const sprite_id = std.fmt.allocPrint(allocator, "weapons/{s}{s}", .{ variant_prefix, @tagName(weapon_type) }) catch
        @panic("failed to build weapon sprite id");
    return .{
        .sprite_id = sprite_id,
        .screen_position = top_left,
        .draw_offset = .{ .x = 0, .y = 0 },
        .source_rectangle = null,
        .color = color,
        .flip_horizontal = flip_horizontal,
    };
}

/// Order entities back-to-front for painter's-algorithm occlusion. tileToScreen
/// maps higher tile.y to a LARGER screen y (lower on screen = nearer the
/// viewer), so lower tile.y is further back and drawn first (ascending y).
/// One entry in the unified ground-drawable sort. `sort_y` is the tile y
/// the drawable sorts at (entity tile y, decoration piece's assigned
/// footprint y, marker tile y); `sort_x` is the horizontal tiebreak.
/// `entity_sprite` carries the entity's bare sprite stem for entries built
/// from an entity (used by the occlusion test's tight-bbox lookup); null for
/// non-entity entries.
const GroundEntry = struct {
    sort_y: i32,
    sort_x: i32,
    drawable: types.GroundDrawable,
    entity_sprite: ?[]const u8 = null,
};

/// Unified back-to-front order: ascending sort_y, then ascending sort_x.
/// Lower y is further back (drawn first); same-y ties break by lower x
/// (left-first), matching the previous entity-only sort convention.
fn groundEntryBefore(_: void, a: GroundEntry, b: GroundEntry) bool {
    if (a.sort_y != b.sort_y) return a.sort_y < b.sort_y;
    return a.sort_x < b.sort_x;
}

/// Append entity drawables into the unified ground-entry list, each keyed by
/// its tile (y, x). Replaces the old `buildEntities` (which sorted and
/// appended directly); the unified sort happens once after all entries
/// (entities + decorations + markers) are collected.
/// Build an NPC's EntityDrawable from {npc_type, position}: the type's
/// sprite in the shared entity frame, tinted by the player gradient at
/// index 0 (the npcs/ art is grayscale, the same convention as entity
/// art - the same tint a default team-0 entity renders with). No layers,
/// weapons, or health bar: the NPC is not an Entity. See DESIGN →
/// Campaigns & the Campaign Editor → File formats.
fn npcEntityDrawable(
    npc: types.NPC,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) types.EntityDrawable {
    return .{
        .back_effect_sprites = &.{},
        .base_sprite = .{
            .sprite_id = npc.npc_type.spriteId(),
            .screen_position = entityFrameTopLeft(npc.position, camera, zoom),
            .draw_offset = .{ .x = 0, .y = 0 },
            .source_rectangle = null,
            .color = playerColor(active_theme, 0),
        },
        .layer_sprites = &.{},
        .weapon_sprites = .{ null, null },
        .gear_sprites = &.{},
        .front_effect_sprites = &.{},
        .health_bar = null,
    };
}

fn collectEntityEntries(
    list: *std.ArrayList(GroundEntry),
    allocator: std.mem.Allocator,
    entities: []const *const Entity,
    active_theme: types.ActiveColorTheme,
    player_color_index: u32,
    camera: types.Camera,
    zoom: f32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
    show_health_bar: bool,
) void {
    // Dead entities (current_health == 0) are not rendered - their sprite
    // vanishes on death.
    // The player entity is the FIRST pointer in every caller's slice
    // (level entities[0], hub player, editor player template - the
    // entity-index-0 invariant); only it renders with the settings-driven
    // player_color_index.
    for (entities, 0..) |entity, index| {
        if (entity.current_health == 0) continue;
        list.append(allocator, .{
            .sort_y = entity.position.y,
            .sort_x = entity.position.x,
            .drawable = .{ .entity = entityDrawable(entity, active_theme, player_color_index, index == 0, camera, zoom, allocator, sprite_bounds, show_health_bar) },
            .entity_sprite = entity.sprite,
        }) catch @panic("failed to append entity entry");
    }
}

/// Tile size in pixels (decorations are authored at 256px/tile). Matches
/// input.tile_size_pixels - duplicated here to avoid a cross-module constant
/// for a value that's part of the rendering contract.
const tile_size_pixels: i32 = 256;

/// Float rect in reference screen space, used by the occlusion overlap test.
const ScreenRect = struct { x: f32, y: f32, w: f32, h: f32 };

fn rectsOverlap(a: ScreenRect, b: ScreenRect) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}

/// The screen-space bounding rect of a ground entry. Entities use the opaque-
/// art bbox (tight, via `sprite_bounds`) so an entity standing NEXT TO a
/// decoration doesn't falsely trigger an inset; falls back to the full
/// 512×640 frame when bounds are unavailable. Decoration pieces, ground
/// items, and flag poles use their full sprite frame (single-sprite drawables
/// whose frame is tight enough).
fn groundEntryScreenRect(
    entry: GroundEntry,
    zoom: f32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
) ScreenRect {
    return switch (entry.drawable) {
        .entity => |e| entityScreenRect(e, entry.entity_sprite, zoom, sprite_bounds),
        .decoration_piece => |d| rectFromTopLeft(d.screen_position, tile_size_pixels, tile_size_pixels, zoom),
        .ground_items => |g| rectFromTopLeft(g.screen_position, ground_items_size, ground_items_size, zoom),
        .level_end => |l| rectFromTopLeft(l.screen_position, flag_pole_width, flag_pole_height, zoom),
    };
}

fn rectFromTopLeft(top_left: types.ScreenPosition, width: f32, height: f32, zoom: f32) ScreenRect {
    return .{
        .x = @floatFromInt(top_left.x),
        .y = @floatFromInt(top_left.y),
        .w = width * zoom,
        .h = height * zoom,
    };
}

fn entityScreenRect(
    entity: types.EntityDrawable,
    sprite_bare_stem: ?[]const u8,
    zoom: f32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
) ScreenRect {
    const top_left = entity.base_sprite.screen_position;
    if (sprite_bare_stem) |stem| {
        if (sprite_bounds.get(stem)) |maybe_bounds| {
            if (maybe_bounds) |b| {
                return .{
                    .x = @as(f32, @floatFromInt(top_left.x)) + @as(f32, @floatFromInt(b.left.?)) * zoom,
                    .y = @as(f32, @floatFromInt(top_left.y)) + @as(f32, @floatFromInt(b.top.?)) * zoom,
                    .w = @as(f32, @floatFromInt(b.right.? - b.left.?)) * zoom,
                    .h = @as(f32, @floatFromInt(b.bottom.? - b.top.?)) * zoom,
                };
            }
        }
    }
    return rectFromTopLeft(top_left, entity_frame_width, entity_frame_height, zoom);
}

/// The inset draw target (sprite stack + frame dims + frame top-left) for a
/// ground entry, or null for decoration pieces (which are occluders, never
/// occluded). The stack is built into `allocator`: entity = base + layers +
/// weapons; flag = pole + current banner frame; ground items = single sprite.
const InsetTarget = struct {
    sprite_stack: []const types.StackSprite,
    screen_position: types.ScreenPosition,
    frame_width: i32,
    frame_height: i32,
};

fn occlusionInsetTarget(entry: GroundEntry, allocator: std.mem.Allocator) ?InsetTarget {
    return switch (entry.drawable) {
        .decoration_piece => null,
        .entity => |e| entityInsetTarget(e, allocator),
        .ground_items => |g| .{
            .sprite_stack = singleStack(allocator, g.sprite_id),
            .screen_position = g.screen_position,
            .frame_width = ground_items_size_int,
            .frame_height = ground_items_size_int,
        },
        .level_end => |l| flagInsetTarget(l, allocator),
    };
}

fn singleStack(allocator: std.mem.Allocator, sprite_id: []const u8) []const types.StackSprite {
    const stack = allocator.alloc(types.StackSprite, 1) catch
        @panic("failed to alloc single-stack");
    stack[0] = .{ .sprite_id = sprite_id };
    return stack;
}

fn entityInsetTarget(entity: types.EntityDrawable, allocator: std.mem.Allocator) InsetTarget {
    // base + layers + weapons (non-null). Gear and effect sprites are
    // excluded - gear is a separate concern and effects are transient
    // (including them would make the outline flicker and balloon the cache).
    var stack: std.ArrayList(types.StackSprite) = .empty;
    stack.append(allocator, .{ .sprite_id = entity.base_sprite.sprite_id }) catch
        @panic("failed to append base to entity stack");
    for (entity.layer_sprites) |layer| {
        stack.append(allocator, .{
            .sprite_id = layer.sprite_id,
            .source_rectangle = layer.source_rectangle,
            .flip_horizontal = layer.flip_horizontal,
        }) catch @panic("failed to append layer to entity stack");
    }
    for (entity.weapon_sprites) |maybe_weapon| {
        if (maybe_weapon) |weapon| {
            stack.append(allocator, .{
                .sprite_id = weapon.sprite_id,
                .source_rectangle = weapon.source_rectangle,
                .flip_horizontal = weapon.flip_horizontal,
            }) catch @panic("failed to append weapon to entity stack");
        }
    }
    return .{
        .sprite_stack = stack.toOwnedSlice(allocator) catch @panic("failed to own entity stack"),
        .screen_position = entity.base_sprite.screen_position,
        .frame_width = entity_frame_width_int,
        .frame_height = entity_frame_height_int,
    };
}

fn flagInsetTarget(marker: types.LevelEndDrawable, allocator: std.mem.Allocator) InsetTarget {
    // pole + current banner frame. The banner's source rectangle selects the
    // animation frame from the 2048×512 sheet; compositing it with the pole
    // means the occluded flag shows the animated banner's silhouette, not just
    // the static pole.
    var stack: std.ArrayList(types.StackSprite) = .empty;
    stack.append(allocator, .{ .sprite_id = marker.sprite_id }) catch
        @panic("failed to append pole to flag stack");
    if (marker.banner_source_rectangle) |banner_rect| {
        stack.append(allocator, .{
            .sprite_id = flag_banner_sprite_id,
            .source_rectangle = banner_rect,
        }) catch @panic("failed to append banner to flag stack");
    }
    return .{
        .sprite_stack = stack.toOwnedSlice(allocator) catch @panic("failed to own flag stack"),
        .screen_position = marker.screen_position,
        .frame_width = flag_pole_width_int,
        .frame_height = flag_pole_height_int,
    };
}

/// Run the occlusion test over the sorted ground entries. For each non-
/// decoration entry, emit one `OcclusionInsetDrawable` if any decoration
/// piece at a higher sort index (drawn after it) has an overlapping screen
/// rect. O(entries × decoration_pieces) per frame - fine at current caps.
/// Pure, view-side → off GameState → replay-safe. See DESIGN → Decorations &
/// Footprint → Occlusion inset.
fn buildOcclusionInsets(
    allocator: std.mem.Allocator,
    entries: []const GroundEntry,
    zoom: f32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
) []const types.OcclusionInsetDrawable {
    if (entries.len == 0) return &.{};

    // Screen rects parallel to `entries`.
    const entry_rects = allocator.alloc(ScreenRect, entries.len) catch
        @panic("failed to alloc entry rects");
    for (entries, 0..) |entry, i| {
        entry_rects[i] = groundEntryScreenRect(entry, zoom, sprite_bounds);
    }

    // Decoration piece indices (the occluders).
    var deco_indices: std.ArrayList(usize) = .empty;
    for (entries, 0..) |entry, i| {
        if (entry.drawable == .decoration_piece) deco_indices.append(allocator, i) catch
            @panic("failed to append decoration index");
    }

    var insets: std.ArrayList(types.OcclusionInsetDrawable) = .empty;
    for (entries, 0..) |entry, i| {
        const target = occlusionInsetTarget(entry, allocator) orelse continue;
        for (deco_indices.items) |j| {
            if (j <= i) continue; // only decorations drawn AFTER this entry occlude it
            if (rectsOverlap(entry_rects[i], entry_rects[j])) {
                insets.append(allocator, .{
                    .sprite_stack = target.sprite_stack,
                    .screen_position = target.screen_position,
                    .frame_width = target.frame_width,
                    .frame_height = target.frame_height,
                    .alpha = 128,
                }) catch @panic("failed to append occlusion inset");
                break;
            }
        }
    }
    return insets.toOwnedSlice(allocator) catch @panic("failed to own occlusion insets");
}

/// Build per-bbox-tile ground entries for one decoration, each carrying its
/// sort key (assigned footprint y for overhang tiles, own y for footprint
/// tiles) and the `DecorationPieceDrawable`. The sprite is split into 256px
/// chunks; each chunk is one bbox tile. Overhang bbox tiles (art but not
/// footprint) are assigned to their nearest footprint tile (Chebyshev
/// distance, tie-break bottom-most-then-left-most) and sort at that footprint
/// tile's y so wide entities don't clip through the decoration (see AGENTS
/// → Decorations & Footprint). Horizontal tiebreak among same-y pieces uses
/// the piece's own world x.
fn buildDecorationPieces(
    decoration: types.Decoration,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
    allocator: std.mem.Allocator,
) []GroundEntry {
    const tiles_w: i32 = @divTrunc(decoration.pixel_dims.x, tile_size_pixels);
    const tiles_h: i32 = @divTrunc(decoration.pixel_dims.y, tile_size_pixels);
    const anchor = decorationAnchor(decoration.footprint) orelse
        @panic("decoration has no anchor in view");
    // Untinted (pure white) when keep_original_colors is set - the art
    // keeps its own colors, base + layers together (see DESIGN → Entity
    // & UI Coloring).
    const base_color = if (decoration.keep_original_colors)
        no_tint_color
    else
        worldGradientColor(active_theme, decoration.color_index);

    // Build a set of footprint sprite-grid coords for O(1) membership.
    var footprint_set = std.AutoHashMap(types.Vector2, void).init(allocator);
    defer footprint_set.deinit();
    for (decoration.footprint) |fp| {
        footprint_set.put(fp, {}) catch @panic("failed to insert footprint tile");
    }

    var entries: std.ArrayList(GroundEntry) = .empty;
    var grid_y: i32 = 0;
    while (grid_y < tiles_h) : (grid_y += 1) {
        var grid_x: i32 = 0;
        while (grid_x < tiles_w) : (grid_x += 1) {
            const grid_tile = types.Vector2{ .x = grid_x, .y = grid_y };
            const is_footprint = footprint_set.contains(grid_tile);

            // World tile this piece is drawn at (for screen position + sort x).
            const world_tile = types.Vector2{
                .x = decoration.position.x + (grid_x - anchor.x),
                .y = decoration.position.y + (grid_y - anchor.y),
            };

            // Sort y: footprint tiles sort at their own world y; overhang
            // tiles sort at their assigned footprint tile's world y.
            const sort_y = if (is_footprint)
                world_tile.y
            else
                decoration.position.y + (nearestFootprint(grid_tile, decoration.footprint).y - anchor.y);

            const screen_top_left = tileToScreen(world_tile, camera, zoom);
            const source_rect = types.Rectangle{
                .x = grid_x * tile_size_pixels,
                .y = grid_y * tile_size_pixels,
                .width = tile_size_pixels,
                .height = tile_size_pixels,
            };

            // Build layer chunks for this bbox tile (same source rect +
            // screen position, different sprite + color), split into back
            // layers (drawn before the base - the `behind` config key) and
            // overlay layers (drawn after it); config order preserved
            // within each slice.
            var back_layer_sprites: std.ArrayList(types.SpriteDrawable) = .empty;
            var layer_sprites: std.ArrayList(types.SpriteDrawable) = .empty;
            for (decoration.layers) |layer| {
                const target = if (layer.behind) &back_layer_sprites else &layer_sprites;
                target.append(allocator, .{
                    .sprite_id = decorationLayerSpriteId(layer.sprite, allocator),
                    .screen_position = screen_top_left,
                    .draw_offset = .{ .x = 0, .y = 0 },
                    .source_rectangle = source_rect,
                    .color = if (decoration.keep_original_colors)
                        no_tint_color
                    else
                        worldGradientColor(active_theme, layer.color_index),
                }) catch @panic("failed to append layer sprite");
            }
            const back_layer_slice = back_layer_sprites.toOwnedSlice(allocator) catch
                @panic("failed to own back layer sprites");
            const layer_slice = layer_sprites.toOwnedSlice(allocator) catch
                @panic("failed to own layer sprites");

            const piece = types.DecorationPieceDrawable{
                .sprite_id = decorationSpriteId(decoration, allocator),
                .screen_position = screen_top_left,
                .draw_offset = .{ .x = 0, .y = 0 },
                .source_rectangle = source_rect,
                .color = base_color,
                .back_layers = back_layer_slice,
                .layers = layer_slice,
            };
            entries.append(allocator, .{
                .sort_y = sort_y,
                .sort_x = world_tile.x,
                .drawable = .{ .decoration_piece = piece },
            }) catch @panic("failed to append decoration piece entry");
        }
    }
    return entries.toOwnedSlice(allocator) catch @panic("failed to own decoration entries");
}

/// Find the nearest footprint tile to a sprite-grid coord by Chebyshev
/// distance, tie-breaking by footprint scan order (bottom-most-then-left-most
/// - the anchor convention, which is how `decorationAnchor` orders). Used to
/// assign overhang bbox tiles to a footprint tile for render sorting.
fn nearestFootprint(grid_tile: types.Vector2, footprint: []const types.Vector2) types.Vector2 {
    std.debug.assert(footprint.len > 0);
    var best = footprint[0];
    var best_dist = chebyshev(grid_tile, best);
    for (footprint[1..]) |fp| {
        const dist = chebyshev(grid_tile, fp);
        if (dist < best_dist) {
            best = fp;
            best_dist = dist;
        }
        // Tie: keep the first found (footprint scan order). Since the
        // footprint list is authored in sprite-grid order and the anchor is
        // bottom-most-then-left-most, the scan order is deterministic. We
        // don't re-sort the footprint here - the caller's authoring order is
        // the tiebreak, matching `decorationAnchor`'s convention.
    }
    return best;
}

fn chebyshev(a: types.Vector2, b: types.Vector2) i32 {
    const dx: i32 = @intCast(@abs(a.x - b.x));
    const dy: i32 = @intCast(@abs(a.y - b.y));
    return @max(dx, dy);
}

/// Build the sprite id (`decorations/<name>`) for a decoration. The
/// decoration's `name` field carries the sprite stem (e.g. `tree_1` or
/// `decorations/tree_1` - the parser stores the `sprite` value as-is).
fn decorationSpriteId(decoration: types.Decoration, allocator: std.mem.Allocator) []const u8 {
    return decorationSpriteIdFromName(decoration.name, allocator);
}

/// Build the sprite id for a layer (`decorations/<name>` or the name as-is
/// if it already contains `/`). Same convention as the base sprite id.
fn decorationLayerSpriteId(sprite_name: []const u8, allocator: std.mem.Allocator) []const u8 {
    return decorationSpriteIdFromName(sprite_name, allocator);
}

fn decorationSpriteIdFromName(name: []const u8, allocator: std.mem.Allocator) []const u8 {
    // Config stores the bare stem (e.g. `tree_1`); the `decorations/` folder
    // is a code-level convention, same as `entities/{s}` for entity sprites.
    // Custom decorations use a content-addressed stem (`custom/<path>/<name>`)
    // which lands under `decorations/custom/<path>/<name>`.
    return std.fmt.allocPrint(allocator, "decorations/{s}", .{name}) catch
        @panic("failed to build decoration sprite id");
}

/// Resolve a world-gradient color by index. Clamps to the valid range
/// (0..gradient_color_count-1) so a bad index draws something sane rather
/// than crashing - the config is authored, so an out-of-range value is a
/// content bug, but view() stays robust.
fn worldGradientColor(active_theme: types.ActiveColorTheme, color_index: u32) types.Color {
    const idx = @min(color_index, types.gradient_color_count - 1);
    return active_theme.world_gradient.colors[idx];
}

/// Resolve a player-gradient color by index (clamped).
fn playerColor(active_theme: types.ActiveColorTheme, color_index: u32) types.Color {
    const idx = @min(color_index, types.gradient_color_count - 1);
    return active_theme.player_gradient.colors[idx];
}

/// Resolve an enemy-gradient color by index (clamped).
fn enemyColor(active_theme: types.ActiveColorTheme, color_index: u32) types.Color {
    const idx = @min(color_index, types.gradient_color_count - 1);
    return active_theme.enemy_gradient.colors[idx];
}

/// Derive the anchor (bottom-most-then-left-most) from a sprite-grid
/// footprint. Mirrors `loaders.decorationAnchor` - duplicated in view to keep
/// view.zig dependency-free from parser.zig (the parser's version operates on
/// the same coordinate convention). Returns null if the footprint is empty.
fn decorationAnchor(footprint: []const types.Vector2) ?types.Vector2 {
    if (footprint.len == 0) return null;
    var anchor = footprint[0];
    for (footprint[1..]) |tile| {
        if (tile.y > anchor.y or (tile.y == anchor.y and tile.x < anchor.x)) {
            anchor = tile;
        }
    }
    return anchor;
}

/// Clickable-tile highlights: one overlay per targetable tile, drawn as an
/// inset square outline in the outline class (shared thickness + marching
/// stripe treatment as the cursor/range outlines; inset -
/// `ui.tile_highlight_inset_divisor` - matching the prototype
/// `world/tile_highlight` sheet's band position). See DESIGN → Platform
/// Seam → Outline stripe shader.
fn buildHighlightOverlays(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    highlighted_tiles: []const types.Vector2,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    for (highlighted_tiles) |tile| {
        list.append(allocator, .{
            .screen_position = tileToScreen(tile, camera, zoom),
            .overlay_type = .highlight,
            .color = active_theme.lightest,
        }) catch @panic("failed to append highlight overlay");
    }
}

/// Hover cursor: an outline on the tile under the logical cursor
/// (session.tile_cursor), when it is a real tile. The cursor is resolved in
/// the input/update path (mouse-move + arrow keys + UI occlusion) and stored
/// on SessionState; view() just renders it - no GameState mutation, so it is
/// replay-safe like the tooltip/drag-ghost.
fn buildCursorOverlay(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    world_tiles: []const types.Vector2,
    session: *const state.SessionState,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    const cursor = session.tile_cursor orelse return;
    for (world_tiles) |tile| {
        if (tile.x == cursor.x and tile.y == cursor.y) {
            list.append(allocator, .{
                .screen_position = tileToScreen(cursor, camera, zoom),
                .overlay_type = .cursor,
                .color = active_theme.lightest,
            }) catch @panic("failed to append cursor overlay");
            return;
        }
    }
}

/// Editor tile-cursor overlay, per tool: the tile / enemy / item tools
/// draw the single-tile outline at the cursor position, UNCONDITIONALLY
/// (no tile-membership check) - any tile position is a legal
/// paint/place target, so the outline over empty space is the affordance
/// that a click can act there (unlike levels/hubs, which only cursor over
/// real tiles). The decoration tool draws a CONTINUOUS outline around the
/// active type's footprint region, anchored so the ANCHOR tile sits at
/// the cursor. The select tool shows what a click would select: a
/// covering decoration's footprint region, else the single tile.
/// Same replay-safe shape as `buildCursorOverlay` (pure over
/// SessionState).
/// The select tool's click-group outline at `position`: what a click there
/// would grab - the FIRST covering decoration's footprint region, else
/// the single tile (the hover preview ≡ click; the group resolution is
/// `editorClickGroup`'s, kept in step by sharing the same
/// first-covering-decoration rule). Rendered translated by `delta` (zero
/// for the hover preview; the live drag delta for the unselected-claim
/// move preview - the grabbed group follows the pointer before the
/// release's replace + move events select it). Shared by
/// buildEditorCursorOverlay (select arm, at the cursor) and
/// buildEditorMoveDragOverlay (at the press tile).
fn appendEditorClickGroupOutline(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    editor: *const Editor,
    position: Vector2,
    delta: Vector2,
    outline_color: types.Color,
    camera: types.Camera,
    zoom: f32,
) void {
    if (selectEditorLevel(editor)) |level| {
        for (level.decoration_placements) |placement| {
            const type_definition = editor.decoration_types[placement.type_id];
            if (loaders.decorationFootprintCovers(type_definition.footprint, placement.position, position, allocator)) {
                const region_tiles = loaders.decorationFootprintWorldTiles(
                    type_definition.footprint,
                    .{ .x = placement.position.x + delta.x, .y = placement.position.y + delta.y },
                    allocator,
                );
                appendRegionOutline(list, allocator, region_tiles, outline_color, camera, zoom);
                return;
            }
        }
    }
    appendSingleTileOutline(
        list,
        allocator,
        .{ .x = position.x + delta.x, .y = position.y + delta.y },
        outline_color,
        camera,
        zoom,
    );
}

fn buildEditorCursorOverlay(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    editor: *const Editor,
    session: *const state.SessionState,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    const tool = editor.active_tool;
    const cursor = session.tile_cursor orelse return;

    if (tool == .decoration_type) {
        const type_definition = editor.decoration_types[tool.decoration_type];
        const region_tiles = loaders.decorationFootprintWorldTiles(
            type_definition.footprint,
            cursor,
            allocator,
        );
        appendRegionOutline(list, allocator, region_tiles, active_theme.lightest, camera, zoom);
        return;
    }

    if (tool == .select) {
        // Hover preview ≡ click: what a click at the cursor would grab,
        // outlined (see appendEditorClickGroupOutline).
        appendEditorClickGroupOutline(
            list,
            allocator,
            editor,
            cursor,
            Vector2{ .x = 0, .y = 0 },
            active_theme.lightest,
            camera,
            zoom,
        );
        return;
    }

    list.append(allocator, .{
        .screen_position = tileToScreen(cursor, camera, zoom),
        .overlay_type = .cursor,
        .color = active_theme.lightest,
    }) catch @panic("failed to append editor cursor overlay");
}

/// The select tool's selection set, outlined in the theme's lightest (the
/// same color as every other world outline - cursor, range, region
/// previews): a single-tile outline per tile / singleton / placement
/// position, and a continuous region outline per decoration placement.
/// Pure over the editor (replay-safe). Stale placement
/// entries (a selected placement later deleted - indices shift/go out of
/// range) are skipped.
fn buildEditorSelectionOverlay(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    editor: *const Editor,
    move_delta: ?Vector2,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    if (editor.selection.len == 0) return;
    const level = selectEditorLevel(editor) orelse return;
    const outline_color = active_theme.lightest;
    const delta = move_delta orelse Vector2{ .x = 0, .y = 0 };
    const translated = struct {
        fn call(position: Vector2, by: Vector2) Vector2 {
            return .{ .x = position.x + by.x, .y = position.y + by.y };
        }
    }.call;

    // While a selection MOVE drag is promoted, every outline translates by
    // the live delta (the world stays put - only the outlines preview the
    // move; see `handleEditorMoveDrag`).
    for (editor.selection) |selected| switch (selected) {
        .tile => |position| appendSingleTileOutline(list, allocator, translated(position, delta), outline_color, camera, zoom),
        .player_start => appendSingleTileOutline(list, allocator, translated(level.player_start, delta), outline_color, camera, zoom),
        .level_end => {
            if (level.level_end) |level_end_position| {
                appendSingleTileOutline(list, allocator, translated(level_end_position, delta), outline_color, camera, zoom);
            }
        },
        .entity_placement => |placement_index| {
            if (placement_index < level.entity_placements.len) {
                appendSingleTileOutline(list, allocator, translated(level.entity_placements[placement_index].position, delta), outline_color, camera, zoom);
            }
        },
        .ground_item_placement => |placement_index| {
            if (placement_index < level.item_placements.len) {
                appendSingleTileOutline(list, allocator, translated(level.item_placements[placement_index].position, delta), outline_color, camera, zoom);
            }
        },
        .decoration_placement => |placement_index| {
            if (placement_index < level.decoration_placements.len) {
                const placement = level.decoration_placements[placement_index];
                const type_definition = editor.decoration_types[placement.type_id];
                const region_tiles = loaders.decorationFootprintWorldTiles(
                    type_definition.footprint,
                    translated(placement.position, delta),
                    allocator,
                );
                appendRegionOutline(list, allocator, region_tiles, outline_color, camera, zoom);
            }
        },
    };
}

/// The in-progress marquee rectangle (see `UiState.editor_marquee`): the
/// inclusive tile region between the two corners, outlined in the theme's
/// lightest via the shared region-outline builder - the same color as the
/// selection it will add to. Nothing renders before the drag threshold
/// promotes the press (an unpromoted release is a plain click, not a
/// region).
fn buildEditorMarqueeOverlay(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    marquee: ?ui.EditorMarquee,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    const region = marquee orelse return;
    if (!region.promoted) return;
    const min_x = @min(region.start_position.x, region.end_position.x);
    const max_x = @max(region.start_position.x, region.end_position.x);
    const min_y = @min(region.start_position.y, region.end_position.y);
    const max_y = @max(region.start_position.y, region.end_position.y);

    var region_tiles: std.ArrayList(Vector2) = .empty;
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            region_tiles.append(allocator, .{ .x = x, .y = y }) catch
                @panic("failed to allocate marquee region tiles");
        }
    }
    appendRegionOutline(list, allocator, region_tiles.items, active_theme.lightest, camera, zoom);
}

/// The unselected-claim selection MOVE drag preview (see
/// `handleEditorMoveDrag`): while the drag is promoted on a press that
/// claimed an UNSELECTED thing, the grabbed click group's outline renders
/// translated by the live delta - the world stays put, the thing follows
/// the pointer before the release's replace + move events select it.
/// Mirrors the selected-claim preview (buildEditorSelectionOverlay's
/// translated outlines - the same shape the group renders as once
/// selected). Nothing renders before promotion (an unpromoted release is
/// a plain click) or on a selected-at-press claim.
fn buildEditorMoveDragOverlay(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    editor: *const Editor,
    move_drag: ?ui.EditorMoveDrag,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    const drag = move_drag orelse return;
    if (!drag.promoted or drag.selected_at_press) return;
    appendEditorClickGroupOutline(
        list,
        allocator,
        editor,
        drag.press_position_tile,
        // The delta anchors the grabbed group's ANCHOR at the pointer -
        // `current_position_tile` keeps the last valid tile over blocking
        // UI, so the preview pauses there like the marquee's corner.
        Vector2{
            .x = drag.current_position_tile.x - drag.press_position_tile.x,
            .y = drag.current_position_tile.y - drag.press_position_tile.y,
        },
        active_theme.lightest,
        camera,
        zoom,
    );
}

/// The active editor level (clamped), or null when there are no levels -
/// the select tool's click + rendering resolution target.
fn selectEditorLevel(editor: *const Editor) ?*const types.EditorLevel {
    if (editor.levels.len == 0) return null;
    return &editor.levels[@min(editor.active_level_index, editor.levels.len - 1)];
}

fn appendSingleTileOutline(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    position: Vector2,
    color: types.Color,
    camera: types.Camera,
    zoom: f32,
) void {
    list.append(allocator, .{
        .screen_position = tileToScreen(position, camera, zoom),
        .overlay_type = .cursor,
        .color = color,
    }) catch @panic("failed to append editor selection outline");
}

/// One `region_edge` segment per boundary edge of `region_tiles` (a side
/// whose neighbor is outside the region) - any region shape renders as a
/// continuous closed outline. Shared by the decoration-tool preview, the
/// select-tool hover preview, the selection overlay, and the move-drag
/// preview.
fn appendRegionOutline(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    region_tiles: []const Vector2,
    color: types.Color,
    camera: types.Camera,
    zoom: f32,
) void {
    for (region_tiles) |tile| {
        const screen_position = tileToScreen(tile, camera, zoom);
        // A side is a boundary edge when the neighbor across it is
        // outside the region. Screen y grows downward, so the neighbor
        // at y-1 borders the tile's TOP edge.
        if (!functions.tileListContains(region_tiles, .{ .x = tile.x, .y = tile.y - 1 })) {
            appendRegionEdge(list, allocator, screen_position, .top, color);
        }
        if (!functions.tileListContains(region_tiles, .{ .x = tile.x, .y = tile.y + 1 })) {
            appendRegionEdge(list, allocator, screen_position, .bottom, color);
        }
        if (!functions.tileListContains(region_tiles, .{ .x = tile.x - 1, .y = tile.y })) {
            appendRegionEdge(list, allocator, screen_position, .left, color);
        }
        if (!functions.tileListContains(region_tiles, .{ .x = tile.x + 1, .y = tile.y })) {
            appendRegionEdge(list, allocator, screen_position, .right, color);
        }
    }
}

fn appendRegionEdge(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    screen_position: types.ScreenPosition,
    edge: types.TileOverlayEdge,
    color: types.Color,
) void {
    list.append(allocator, .{
        .screen_position = screen_position,
        .overlay_type = .region_edge,
        .color = color,
        .edge = edge,
    }) catch @panic("failed to append region edge overlay");
}

/// Range/radius outline: when the pointer hovers a skill button on the
/// bottom bar, preview that skill's reach as a single square outline
/// centered on the player. The square's half-side is the skill's `range`
/// (preferred) or `radius` (fallback); a skill with neither draws nothing.
/// Drawn in full (may extend past level edges / over gaps) at Chebyshev
/// ≤ N - a geometric preview, not pathfinding reachability. Tinted with
/// `active_theme.lightest`, same as the cursor. Suppressed while dragging
/// (the pointer is dragging, not hovering). Works in levels and hubs
/// (skill slots appear on the bottom bar in both). Pure over SessionState
/// (off the undoable GameState) → replay-safe by construction.
fn buildSkillRangeOutline(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    ui_elements: []const ui.UiElement,
    session: *const state.SessionState,
    current_state: *const GameState,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    if (session.ui_state.drag != null) return;

    const pointer = session.input_state.mouse_screen_position;
    const point = pointer.toScreenPosition();
    const button = ui.buttonAt(ui_elements, point) orelse return;
    const slot = ui.actionSkillSlot(button.action) orelse return;

    const player = ui.playerEntity(current_state) orelse return;
    const skill_id = player.skillInSlot(slot, weapon_type_definitions) orelse return;
    const definition = lookups.getSkillDefinition(skill_id) orelse return;

    const n: u32 = if (definition.range) |r| r else if (definition.radius) |rad| rad else return;
    const overlay_type: types.TileOverlayType = if (definition.range != null) .range_outline else .radius_outline;

    const top_left = types.Vector2{ .x = player.position.x - @as(i32, @intCast(n)), .y = player.position.y - @as(i32, @intCast(n)) };
    list.append(allocator, .{
        .screen_position = tileToScreen(top_left, camera, zoom),
        .overlay_type = overlay_type,
        .color = active_theme.lightest,
        .extent = 2 * n + 1,
    }) catch @panic("failed to append skill range outline");
}

/// Radius outline around the tile cursor while a targeting skill with a
/// radius is prepared (e.g. Flash Strike: teleport to a target tile within
/// range, then attack within radius of the landing). The valid-target
/// highlights show where the player can land; this previews the AoE that
/// will hit around the cursor's current tile as the player aims. Drawn in
/// full (may extend past level edges / over gaps) at Chebyshev ≤ radius -
/// a geometric preview. Tinted with `active_theme.lightest`. Levels only
/// (`prepared_skill` is null in a hub). Pure over SessionState (off the
/// undoable GameState) → replay-safe by construction.
fn buildPreparedSkillRadiusOutline(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    level: *const types.Level,
    session: *const state.SessionState,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    const prepared = level.prepared_skill orelse return;
    const definition = lookups.getSkillDefinition(prepared) orelse return;
    if (!definition.uses_targeting) return;
    const radius = definition.radius orelse return;
    const cursor = session.tile_cursor orelse return;

    const n: i32 = @intCast(radius);
    const top_left = types.Vector2{ .x = cursor.x - n, .y = cursor.y - n };
    list.append(allocator, .{
        .screen_position = tileToScreen(top_left, camera, zoom),
        .overlay_type = .radius_outline,
        .color = active_theme.lightest,
        .extent = 2 * radius + 1,
    }) catch @panic("failed to append prepared-skill radius outline");
}

/// Aggro-range outline: while the entity-inspect panel is open, preview the
/// inspected entity's detection range as a single square outline (Chebyshev
/// ≤ aggro_range) centered on the entity - the world-space companion of the
/// panel's "Aggro Range" stat row. Same shape as the skill-range outline
/// (drawn in full, may extend past level edges / over gaps; theme lightest,
/// unified 8px thickness). Levels only (inspect only opens in levels), any
/// inspected entity including the player, while ALIVE (the panel's
/// dead-target gate - a dead target shows neither panel nor outline). Pure
/// over SessionState + GameState reads → replay-safe by construction.
fn buildInspectedAggroOutline(
    list: *std.ArrayList(types.TileOverlayDrawable),
    allocator: std.mem.Allocator,
    level: *const types.Level,
    surfaces: *const types.UiSurfaceState,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    if (!surfaces.isMiddlePanelOpen(.entity_inspect)) return;
    const entity_index = surfaces.inspected_entity_index orelse return;
    if (entity_index >= level.entities.len) return;
    const entity = level.entities[entity_index];
    // The panel's dead-target gate (see the .entity_inspect view arm): a
    // dead target shows neither the panel nor its aggro outline.
    if (entity.current_health == 0) return;

    const n: i32 = @intCast(entity.aggro_range);
    const top_left = types.Vector2{ .x = entity.position.x - n, .y = entity.position.y - n };
    list.append(allocator, .{
        .screen_position = tileToScreen(top_left, camera, zoom),
        .overlay_type = .aggro_outline,
        .color = active_theme.lightest,
        .extent = 2 * entity.aggro_range + 1,
    }) catch @panic("failed to append inspected-entity aggro outline");
}

/// Append a checkerboard TileDrawable per tile. The two shades come from world
/// gradient indices 1 and 3, chosen by (x + y) parity.
/// Editor viewport scene: project the ACTIVE EditorLevel into tiles + ground
/// entries via the existing drawable builders. The player template stands at
/// `player_start` (the '!' marker); entity/decoration/item placements resolve
/// through their palette types to sprites + gradients; the level-end flag is
/// the '=' marker. Health bars are hidden - runtime state, not definition
/// state (max health shows in the inspector instead). Ground-item bags group
/// co-located placements into one drawable with the placement count.
fn buildEditorScene(
    tiles: *std.ArrayList(types.TileDrawable),
    ground_entries: *std.ArrayList(GroundEntry),
    allocator: std.mem.Allocator,
    editor: *const Editor,
    active_theme: types.ActiveColorTheme,
    player_color_index: u32,
    camera: types.Camera,
    camera_zoom: f32,
    sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds),
    animation_clock: u64,
    animation_fps: u32,
) void {
    if (editor.levels.len == 0) return;
    const editor_level = editor.levels[@min(editor.active_level_index, editor.levels.len - 1)];

    buildTiles(tiles, allocator, editor_level.level_tiles, active_theme, camera, camera_zoom);

    if (editor_level.level_end) |end_position| {
        ground_entries.append(allocator, .{
            .sort_y = end_position.y,
            .sort_x = end_position.x,
            .drawable = .{ .level_end = levelEndDrawable(end_position, active_theme, camera, camera_zoom, animation_clock, animation_fps, true) },
        }) catch @panic("failed to append editor level-end entry");
    }

    // Entities: the player template plus one per placement, resolved through
    // the entity palette. Shallow struct copies with the placement position
    // (borrowed strings - rendering only, frame-arena lifetime).
    {
        const entity_count = 1 + editor_level.entity_placements.len;
        const entities = allocator.alloc(Entity, entity_count) catch
            @panic("failed to alloc editor entity instances");
        entities[0] = editor.player_def.template;
        entities[0].position = editor_level.player_start;
        for (editor_level.entity_placements, 0..) |placement, index| {
            entities[index + 1] = editor.entity_types[placement.type_id].template;
            entities[index + 1].position = placement.position;
        }
        const entity_ptrs = allocator.alloc(*const Entity, entity_count) catch
            @panic("failed to alloc editor entity pointer slice");
        for (entities, 0..) |*entity, index| entity_ptrs[index] = entity;
        collectEntityEntries(ground_entries, allocator, entity_ptrs, active_theme, player_color_index, camera, camera_zoom, sprite_bounds, false);
    }

    // Decorations: resolve each placement through its palette type (same
    // shape as instantiateEditorLevel's concrete decorations).
    for (editor_level.decoration_placements) |placement| {
        const type_definition = editor.decoration_types[placement.type_id];
        const pieces = buildDecorationPieces(.{
            .name = type_definition.sprite,
            .position = placement.position,
            .footprint = type_definition.footprint,
            .pixel_dims = type_definition.pixel_dims,
            .color_index = type_definition.color_index,
            .layers = type_definition.layers,
        }, active_theme, camera, camera_zoom, allocator);
        for (pieces) |entry| ground_entries.append(allocator, entry) catch
            @panic("failed to append editor decoration piece entry");
    }

    // Ground items: one bag per position; the count is the number of
    // co-located placements (one item each - level files author single-item
    // stacks; the editor UI can stack placements on one tile).
    for (editor_level.item_placements, 0..) |placement, index| {
        var first_at_position = true;
        var item_count: u32 = 0;
        for (editor_level.item_placements, 0..) |other, other_index| {
            if (other.position.x == placement.position.x and
                other.position.y == placement.position.y)
            {
                if (other_index < index) first_at_position = false;
                item_count += 1;
            }
        }
        if (!first_at_position) continue;
        ground_entries.append(allocator, .{
            .sort_y = placement.position.y,
            .sort_x = placement.position.x,
            .drawable = .{ .ground_items = groundItemsDrawable(placement.position, item_count, active_theme, camera, camera_zoom) },
        }) catch @panic("failed to append editor ground-items entry");
    }
}

fn buildTiles(
    list: *std.ArrayList(types.TileDrawable),
    allocator: std.mem.Allocator,
    tiles: []const types.Vector2,
    active_theme: types.ActiveColorTheme,
    camera: types.Camera,
    zoom: f32,
) void {
    for (tiles) |tile| {
        const color = if (@mod(tile.x + tile.y, 2) == 0)
            active_theme.world_gradient.colors[1]
        else
            active_theme.world_gradient.colors[3];
        list.append(allocator, .{
            .screen_position = tileToScreen(tile, camera, zoom),
            .color = color,
        }) catch @panic("failed to append tile drawable");
    }
}

test "flag banner: frame advances with the animation clock and wraps" {
    // The flag banner is a looping anim: frame = (clock / frame_duration)
    // % frame_count. At fps=8 (default), frame_duration = 125ms and the loop
    // is 8 frames = 1.0s. Verify frame 0 at t=0, frame 4 at t=500ms, wraps to
    // frame 0 at t=1000ms. A camera at the origin + zoom 1.0 keeps screen
    // position stable so the test can focus on the source rectangle. A dummy
    // active theme is used (the colors are not asserted here).
    const camera = types.Camera{ .position = .{ .x = 0, .y = 0 } };
    const dummy_theme = types.ActiveColorTheme{
        .lightest = .{ .r = 255, .g = 255, .b = 255 },
        .darkest = .{ .r = 0, .g = 0, .b = 0 },
        .world_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .enemy_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .player_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
    };

    const d0 = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 0, 8, true);
    const rect0 = d0.banner_source_rectangle.?;
    try std.testing.expectEqual(@as(i32, 0), rect0.x);
    try std.testing.expectEqual(@as(i32, 0), rect0.y);
    try std.testing.expectEqual(@as(i32, 256), rect0.width);
    try std.testing.expectEqual(@as(i32, 512), rect0.height);

    // 500ms / 125ms = frame 4.
    const d4 = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 500_000, 8, true);
    try std.testing.expectEqual(@as(i32, 4 * 256), d4.banner_source_rectangle.?.x);

    // 1000ms = 8 frames elapsed → wraps to frame 0.
    const d_wrap = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 1_000_000, 8, true);
    try std.testing.expectEqual(@as(i32, 0), d_wrap.banner_source_rectangle.?.x);

    // fps=16 → frame_duration 62.5ms (integer div → 62ms); 500_000/62 = 8064
    // frames elapsed, % 8 = 0. Just assert it doesn't divide-by-zero and
    // produces a valid frame index (the exact frame at a fractional-duration
    // boundary isn't worth pinning).
    const d_fast = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 500_000, 16, true);
    try std.testing.expect(d_fast.banner_source_rectangle.?.x >= 0);
    try std.testing.expect(d_fast.banner_source_rectangle.?.x < 8 * 256);

    // fps=0 is treated as 8 (no divide-by-zero).
    const d_zero = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 500_000, 0, true);
    try std.testing.expectEqual(@as(i32, 4 * 256), d_zero.banner_source_rectangle.?.x);

    // banner_visible = false → NO banner (pole only): the level-screen
    // flag while active enemies remain - see the level-end flag test for
    // the view() gating.
    const d_hidden = levelEndDrawable(.{ .x = 0, .y = 0 }, dummy_theme, camera, 1.0, 500_000, 8, false);
    try std.testing.expect(d_hidden.banner_source_rectangle == null);
}

test "level-end flag: the banner waves only while no active enemies remain" {
    // The banner is the completability signal (DESIGN → Animation): on the
    // level screen it renders only while `Level.hasActiveEnemies` is false
    // - the SAME rule the win condition checks, so the flag can never lie
    // about completability. The pole always renders; hub mission-start
    // markers always wave (not levels - no enemies).
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const camera_for = struct {
        fn call(state__: *const GameState) types.Camera {
            return computeCamera(state__, 1.0, null, null);
        }
    }.call;
    const runView = struct {
        fn call(
            state__: *const GameState,
            session__: *state.SessionState,
            arena__: std.mem.Allocator,
            harness__: *test_harness.Harness,
        ) types.ViewState {
            return view(
                state__,
                session__,
                .{ .input_bindings = &.{} },
                harness__.color_theme_definitions,
                &harness__.weapon_type_definitions,
                &.{},
                .{
                    .camera = camera_for(state__),
                    .camera_zoom = 1.0,
                    .event_history = &.{},
                    .level_start_index = null,
                    .current_event_index = 0,
                    .frame_allocator = arena__,
                    .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
                    .sprite_bounds = .{},
                    .can_undo = false,
                    .can_redo = false,
                },
            );
        }
    }.call;
    const levelEndMarker = struct {
        fn call(view_state: types.ViewState) ?types.LevelEndDrawable {
            for (view_state.ground_drawables) |drawable| switch (drawable) {
                .level_end => |marker| return marker,
                else => {},
            };
            return null;
        }
    }.call;

    // An alive, active, hostile enemy → pole only (the banner is null).
    {
        const enemy = types.Entity{ .team = 1, .is_active = true };
        var state_ = test_harness.levelStateWithEntities(arena, &.{ .{}, enemy }, &.{.{ .x = 0, .y = 0 }});
        state_.level.?.level_end = .{ .x = 2, .y = 2 };
        var session = state.SessionState{};
        const view_state = runView(&state_, &session, arena, &harness);
        const marker = levelEndMarker(view_state);
        try std.testing.expect(marker != null);
        try std.testing.expect(marker.?.banner_source_rectangle == null);
    }
    // The enemy dead → the banner waves.
    {
        var enemy = types.Entity{ .team = 1, .is_active = true };
        enemy.current_health = 0;
        var state_ = test_harness.levelStateWithEntities(arena, &.{ .{}, enemy }, &.{.{ .x = 0, .y = 0 }});
        state_.level.?.level_end = .{ .x = 2, .y = 2 };
        var session = state.SessionState{};
        const view_state = runView(&state_, &session, arena, &harness);
        const marker = levelEndMarker(view_state);
        try std.testing.expect(marker != null);
        try std.testing.expect(marker.?.banner_source_rectangle != null);
    }
    // No enemies at all → the banner waves.
    {
        var state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{.{ .x = 0, .y = 0 }});
        state_.level.?.level_end = .{ .x = 2, .y = 2 };
        var session = state.SessionState{};
        const view_state = runView(&state_, &session, arena, &harness);
        const marker = levelEndMarker(view_state);
        try std.testing.expect(marker != null);
        try std.testing.expect(marker.?.banner_source_rectangle != null);
    }
    // Hub mission-start markers always wave (not levels - no enemies).
    {
        const exits = [_]types.MissionExit{.{ .mission_id = "m1", .position = .{ .x = 1, .y = 1 } }};
        const state_ = GameState{
            .screen = .hub,
            .event_stack = &.{},
            .player_data = .{},
            .camera = null,
            .editor = null,
            .replay_viewer = null,
            .campaign = null,
            .mission = null,
            .level = null,
            .hub = .{ .mission_exits = &exits },
        };
        var session = state.SessionState{};
        const view_state = runView(&state_, &session, arena, &harness);
        const marker = levelEndMarker(view_state);
        try std.testing.expect(marker != null);
        try std.testing.expect(marker.?.banner_source_rectangle != null);
    }
}

test "skill range outline: range/radius/none/drag" {
    // Hovering a skill button previews the skill's reach as a single square
    // outline centered on the player: Chebyshev ≤ range (else ≤ radius),
    // extent = 2*N + 1. A skill with neither draws nothing; dragging
    // suppresses the preview. Pure, off SessionState.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const dummy_theme = types.ActiveColorTheme{
        .lightest = .{ .r = 255, .g = 255, .b = 255 },
        .darkest = .{ .r = 0, .g = 0, .b = 0 },
        .world_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .enemy_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .player_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
    };
    const camera = types.Camera{ .position = .{ .x = 0, .y = 0 } };

    // Player at (5, 5) with a sword (slot 1 -> Slice, range 1) and a utility
    // skill in slot 4 we swap per case.
    const player = types.Entity{
        .position = .{ .x = 5, .y = 5 },
        .main_hand_weapon = .{ .weapon_type = .sword },
    };

    // Case 1: slot 1 -> Slice (range 1) -> range_outline, extent 3.
    {
        const state_ = test_harness.levelStateWithEntities(arena, &.{player}, &.{});
        var session = state.SessionState{};
        session.input_state.mouse_screen_position = .{ .x = 200, .y = 200 };
        const ui_elements = [_]ui.UiElement{.{ .button = .{
            .action = .skill_slot_1,
            .screen_position = .{ .x = 100, .y = 100 },
            .width = 256,
            .height = 256,
        } }};
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildSkillRangeOutline(&overlays, arena, &ui_elements, &session, &state_, &harness.weapon_type_definitions, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 1), overlays.items.len);
        const ov = overlays.items[0];
        try std.testing.expectEqual(types.TileOverlayType.range_outline, ov.overlay_type);
        try std.testing.expectEqual(@as(u32, 3), ov.extent);
        try std.testing.expectEqual(dummy_theme.lightest, ov.color);
    }

    // Case 2: slot 4 -> Slam (radius 1) -> radius_outline, extent 3.
    {
        var p2 = player;
        p2.equipped_utility_skills[0] = .slam;
        const state_ = test_harness.levelStateWithEntities(arena, &.{p2}, &.{});
        var session = state.SessionState{};
        session.input_state.mouse_screen_position = .{ .x = 200, .y = 200 };
        const ui_elements = [_]ui.UiElement{.{ .button = .{
            .action = .skill_slot_4,
            .screen_position = .{ .x = 100, .y = 100 },
            .width = 256,
            .height = 256,
        } }};
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildSkillRangeOutline(&overlays, arena, &ui_elements, &session, &state_, &harness.weapon_type_definitions, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 1), overlays.items.len);
        const ov = overlays.items[0];
        try std.testing.expectEqual(types.TileOverlayType.radius_outline, ov.overlay_type);
        try std.testing.expectEqual(@as(u32, 3), ov.extent);
    }

    // Case 3: slot 4 -> Focus (no range, no radius) -> no outline.
    {
        var p3 = player;
        p3.equipped_utility_skills[0] = .focus;
        const state_ = test_harness.levelStateWithEntities(arena, &.{p3}, &.{});
        var session = state.SessionState{};
        session.input_state.mouse_screen_position = .{ .x = 200, .y = 200 };
        const ui_elements = [_]ui.UiElement{.{ .button = .{
            .action = .skill_slot_4,
            .screen_position = .{ .x = 100, .y = 100 },
            .width = 256,
            .height = 256,
        } }};
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildSkillRangeOutline(&overlays, arena, &ui_elements, &session, &state_, &harness.weapon_type_definitions, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }

    // Case 4: drag suppresses the outline even for a range skill.
    {
        const state_ = test_harness.levelStateWithEntities(arena, &.{player}, &.{});
        var session = state.SessionState{};
        session.input_state.mouse_screen_position = .{ .x = 200, .y = 200 };
        session.ui_state.drag = .{ .icon_sprite_id = "skills/slice", .source = .{ .skill_bar = 0 }, .size = ui.slot_size };
        const ui_elements = [_]ui.UiElement{.{ .button = .{
            .action = .skill_slot_1,
            .screen_position = .{ .x = 100, .y = 100 },
            .width = 256,
            .height = 256,
        } }};
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildSkillRangeOutline(&overlays, arena, &ui_elements, &session, &state_, &harness.weapon_type_definitions, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }
}

test "prepared skill radius outline: follows cursor while targeting" {
    // While a targeting skill with a radius is prepared (e.g. Flash Strike),
    // a radius outline follows the tile cursor - previewing the AoE around
    // the landing tile the player is aiming at. Extent = 2*radius + 1,
    // .radius_outline, theme lightest. Levels only (prepared_skill is null
    // in a hub); no overlay when no skill is prepared, the skill has no
    // radius, or the cursor is null.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    const dummy_theme = types.ActiveColorTheme{
        .lightest = .{ .r = 255, .g = 255, .b = 255 },
        .darkest = .{ .r = 0, .g = 0, .b = 0 },
        .world_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .enemy_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .player_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
    };
    const camera = types.Camera{ .position = .{ .x = 0, .y = 0 } };

    // Case 1: Flash Strike prepared (uses_targeting, radius 1), cursor at
    // (5,5) -> radius_outline, extent 3, centered on cursor.
    {
        var state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{});
        state_.level.?.prepared_skill = .flash_strike;
        var session = state.SessionState{};
        session.tile_cursor = .{ .x = 5, .y = 5 };
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildPreparedSkillRadiusOutline(&overlays, arena, &state_.level.?, &session, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 1), overlays.items.len);
        const ov = overlays.items[0];
        try std.testing.expectEqual(types.TileOverlayType.radius_outline, ov.overlay_type);
        try std.testing.expectEqual(@as(u32, 3), ov.extent);
        try std.testing.expectEqual(dummy_theme.lightest, ov.color);
    }

    // Case 2: no skill prepared -> no overlay.
    {
        const state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{});
        var session = state.SessionState{};
        session.tile_cursor = .{ .x = 5, .y = 5 };
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildPreparedSkillRadiusOutline(&overlays, arena, &state_.level.?, &session, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }

    // Case 3: a non-targeting radius skill (Spinblade) prepared -> no overlay
    // (uses_targeting is false; its radius is already shown as the skill's own
    // reach, not a cursor-following preview).
    {
        var state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{});
        state_.level.?.prepared_skill = .spinblade;
        var session = state.SessionState{};
        session.tile_cursor = .{ .x = 5, .y = 5 };
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildPreparedSkillRadiusOutline(&overlays, arena, &state_.level.?, &session, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }

    // Case 4: Flash Strike prepared but cursor null -> no overlay.
    {
        var state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{});
        state_.level.?.prepared_skill = .flash_strike;
        var session = state.SessionState{};
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildPreparedSkillRadiusOutline(&overlays, arena, &state_.level.?, &session, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }
}

test "inspected entity aggro outline: square centered on the inspected entity" {
    // While the entity-inspect panel is open, the inspected entity's aggro
    // range draws as a Chebyshev square outline (extent = 2*aggro_range + 1)
    // centered on the entity. No overlay when the panel is closed, no
    // entity is inspected, or the index is stale (out of range).
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    const dummy_theme = types.ActiveColorTheme{
        .lightest = .{ .r = 255, .g = 255, .b = 255 },
        .darkest = .{ .r = 0, .g = 0, .b = 0 },
        .world_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .enemy_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
        .player_gradient = .{ .colors = [_]types.Color{.{ .r = 0, .g = 0, .b = 0 }} ** 6 },
    };
    const camera = types.Camera{ .position = .{ .x = 0, .y = 0 } };

    var enemy: types.Entity = .{};
    enemy.team = 1;
    enemy.position = .{ .x = 5, .y = 5 };
    enemy.aggro_range = 3;

    // Case 1: panel open + entity 1 inspected -> aggro_outline, extent 7.
    {
        const state_ = test_harness.levelStateWithEntities(arena, &.{ .{}, enemy }, &.{});
        var surfaces = types.UiSurfaceState{};
        surfaces.inspectEntity(1);
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildInspectedAggroOutline(&overlays, arena, &state_.level.?, &surfaces, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 1), overlays.items.len);
        const ov = overlays.items[0];
        try std.testing.expectEqual(types.TileOverlayType.aggro_outline, ov.overlay_type);
        try std.testing.expectEqual(@as(u32, 7), ov.extent);
        try std.testing.expectEqual(dummy_theme.lightest, ov.color);
    }

    // Case 2: panel closed -> no outline (even with an inspected index set).
    {
        const state_ = test_harness.levelStateWithEntities(arena, &.{ .{}, enemy }, &.{});
        var surfaces = types.UiSurfaceState{};
        surfaces.inspected_entity_index = 1;
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildInspectedAggroOutline(&overlays, arena, &state_.level.?, &surfaces, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }

    // Case 3: panel open but no inspected entity -> no outline.
    {
        const state_ = test_harness.levelStateWithEntities(arena, &.{ .{}, enemy }, &.{});
        var surfaces = types.UiSurfaceState{};
        surfaces.toggle(.entity_inspect);
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildInspectedAggroOutline(&overlays, arena, &state_.level.?, &surfaces, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }

    // Case 4: stale index (entity died and the array shrank) -> no outline,
    // no crash.
    {
        const state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{});
        var surfaces = types.UiSurfaceState{};
        surfaces.inspectEntity(9);
        var overlays: std.ArrayList(types.TileOverlayDrawable) = .empty;
        buildInspectedAggroOutline(&overlays, arena, &state_.level.?, &surfaces, dummy_theme, camera, 1.0);
        try std.testing.expectEqual(@as(usize, 0), overlays.items.len);
    }
}

test "editor scene: viewport projects tiles, placements, and markers" {
    // The editor world branch (edit mode): no concrete Level exists, so the
    // active EditorLevel is projected into the same drawables the in-game
    // view builds - tiles, the player template at player_start (the '!'),
    // palette-resolved entity/decoration/item placements, the level-end flag
    // ('='), and no health bars. Ground-item bags group co-located
    // placements (count = placements at the position).
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{
            .name = "Skeleton",
            .sprite = "skeleton_1",
            .team = 1,
            .max_health = 20,
            .current_health = 20,
        },
    }};
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 3, .y = 1 },
    }};
    const footprint = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 256, .y = 256 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 4, .y = 0 },
    }};
    const item_types = [_]types.ItemTypeDef{.{
        .id = "Boots",
        .item = .{ .boots = .{ .name = "Boots" } },
    }};
    const item_placements = [_]types.ItemPlacement{
        .{ .type_id = 0, .position = .{ .x = 1, .y = 2 } },
        .{ .type_id = 0, .position = .{ .x = 1, .y = 2 } }, // co-located
    };
    const level_tiles = [_]types.Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
        .{ .x = 3, .y = 1 }, .{ .x = 1, .y = 2 }, .{ .x = 4, .y = 2 },
    };
    const levels = [_]types.EditorLevel{.{
        .name = "Test Level",
        .level_tiles = &level_tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 4, .y = 2 },
        .entity_placements = &entity_placements,
        .decoration_placements = &decoration_placements,
        .item_placements = &item_placements,
    }};
    const editor = types.Editor{
        .levels = &levels,
        .entity_types = &entity_types,
        .decoration_types = &decoration_types,
        .item_types = &item_types,
        .player_def = .{
            .id = "Player",
            .template = .{
                .name = "Player",
                .sprite = "player",
                .team = 0,
                .max_health = 10,
                .current_health = 10,
            },
        },
    };
    const state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = editor,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
    var session = state.SessionState{};

    // The camera centers on the active level's player_start (the editor's
    // "player position" analog) - the plain player-center projection.
    const camera = computeCamera(&state_, 1.0, null, null);
    try std.testing.expectEqual(playerCenter(.{ .x = 0, .y = 0 }), camera.position);

    const view_state = view(
        &state_,
        &session,
        .{ .input_bindings = &.{} },
        harness.color_theme_definitions,
        &harness.weapon_type_definitions,
        &.{},
        .{
            .camera = camera,
            .camera_zoom = 1.0,
            .event_history = &.{},
            .level_start_index = null,
            .current_event_index = 0,
            .frame_allocator = arena,
            .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
            .sprite_bounds = .{},
            .can_undo = false,
            .can_redo = false,
        },
    );

    try std.testing.expectEqual(@as(usize, 6), view_state.tiles.len);

    // Ground drawables, unified (sort_y, sort_x) ascending: player (0,0),
    // decoration piece (0,4), enemy (1,3), item bag (2,1), flag (2,4).
    // The two co-located item placements group into ONE bag with count 2.
    try std.testing.expectEqual(@as(usize, 5), view_state.ground_drawables.len);
    const drawables = view_state.ground_drawables;

    try std.testing.expect(std.mem.eql(u8, "entities/player", drawables[0].entity.base_sprite.sprite_id));
    try std.testing.expect(drawables[0].entity.health_bar == null); // no health bars in the editor
    try std.testing.expect(std.mem.eql(u8, "decorations/stone_2", drawables[1].decoration_piece.sprite_id));
    try std.testing.expect(std.mem.eql(u8, "entities/skeleton_1", drawables[2].entity.base_sprite.sprite_id));
    try std.testing.expect(drawables[2].entity.health_bar == null);
    try std.testing.expect(std.mem.eql(u8, "world/ground_items", drawables[3].ground_items.sprite_id));
    try std.testing.expectEqual(@as(u32, 2), drawables[3].ground_items.item_count);
    try std.testing.expect(std.mem.eql(u8, "world/flag_pole", drawables[4].level_end.sprite_id));
}

test "editor cursor overlay: every tool outlines the cursor tile" {
    // The tile-tool cursor draws at the cursor position UNCONDITIONALLY -
    // over empty space too (the affordance that a tile can be placed
    // there), unlike the level/hub cursor which only draws on real tiles.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const levels = [_]types.EditorLevel{.{
        .level_tiles = &.{}, // no tiles - the outline must still draw
        .player_start = .{ .x = 0, .y = 0 },
    }};
    var state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = &levels },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
    var session = state.SessionState{};
    state_.editor.?.active_tool = .tile;
    session.tile_cursor = .{ .x = 2, .y = 1 };

    const camera = computeCamera(&state_, 1.0, null, null);
    const view_state = view(
        &state_,
        &session,
        .{ .input_bindings = &.{} },
        harness.color_theme_definitions,
        &harness.weapon_type_definitions,
        &.{},
        .{
            .camera = camera,
            .camera_zoom = 1.0,
            .event_history = &.{},
            .level_start_index = null,
            .current_event_index = 0,
            .frame_allocator = arena,
            .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
            .sprite_bounds = .{},
            .can_undo = false,
            .can_redo = false,
        },
    );

    try std.testing.expectEqual(@as(usize, 1), view_state.tile_overlays.len);
    const overlay = view_state.tile_overlays[0];
    try std.testing.expectEqual(types.TileOverlayType.cursor, overlay.overlay_type);
    try std.testing.expectEqual(
        tileToScreen(.{ .x = 2, .y = 1 }, camera, 1.0),
        overlay.screen_position,
    );

    // The select tool draws the single-tile outline too (its hover
    // preview - a covering decoration's footprint region, else the tile);
    // an entity tool does (same overlay - its click target is a tile
    // position too).
    state_.editor.?.active_tool = .select;
    const view_state_select = view(
        &state_,
        &session,
        .{ .input_bindings = &.{} },
        harness.color_theme_definitions,
        &harness.weapon_type_definitions,
        &.{},
        .{
            .camera = camera,
            .camera_zoom = 1.0,
            .event_history = &.{},
            .level_start_index = null,
            .current_event_index = 0,
            .frame_allocator = arena,
            .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
            .sprite_bounds = .{},
            .can_undo = false,
            .can_redo = false,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), view_state_select.tile_overlays.len);
    try std.testing.expectEqual(types.TileOverlayType.cursor, view_state_select.tile_overlays[0].overlay_type);

    state_.editor.?.active_tool = .{ .entity_type = 0 };
    const view_state_entity = view(
        &state_,
        &session,
        .{ .input_bindings = &.{} },
        harness.color_theme_definitions,
        &harness.weapon_type_definitions,
        &.{},
        .{
            .camera = camera,
            .camera_zoom = 1.0,
            .event_history = &.{},
            .level_start_index = null,
            .current_event_index = 0,
            .frame_allocator = arena,
            .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
            .sprite_bounds = .{},
            .can_undo = false,
            .can_redo = false,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), view_state_entity.tile_overlays.len);
    try std.testing.expectEqual(types.TileOverlayType.cursor, view_state_entity.tile_overlays[0].overlay_type);

    // The ground-item tool draws the same single-tile outline.
    state_.editor.?.active_tool = .{ .item_type = 0 };
    const view_state_item = view(
        &state_,
        &session,
        .{ .input_bindings = &.{} },
        harness.color_theme_definitions,
        &harness.weapon_type_definitions,
        &.{},
        .{
            .camera = camera,
            .camera_zoom = 1.0,
            .event_history = &.{},
            .level_start_index = null,
            .current_event_index = 0,
            .frame_allocator = arena,
            .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
            .sprite_bounds = .{},
            .can_undo = false,
            .can_redo = false,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), view_state_item.tile_overlays.len);
    try std.testing.expectEqual(types.TileOverlayType.cursor, view_state_item.tile_overlays[0].overlay_type);
}

test "editor cursor overlay: decoration tool outlines the footprint region continuously" {
    // The decoration tool's preview: a continuous outline around the
    // type's footprint region, anchored so the ANCHOR tile sits at the
    // cursor. A 2-wide footprint emits 6 boundary edges - top + bottom per
    // tile, one left, one right - and NO edge between the two region tiles
    // (that side is interior).
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "ruin_1",
        .sprite = "ruin_1",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
    }};
    const levels = [_]types.EditorLevel{.{ .player_start = .{ .x = 0, .y = 0 } }};
    var state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = &levels, .decoration_types = &decoration_types },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
    var session = state.SessionState{};
    state_.editor.?.active_tool = .{ .decoration_type = 0 };
    session.tile_cursor = .{ .x = 2, .y = 1 }; // the anchor tile

    const camera = computeCamera(&state_, 1.0, null, null);
    const view_state = view(
        &state_,
        &session,
        .{ .input_bindings = &.{} },
        harness.color_theme_definitions,
        &harness.weapon_type_definitions,
        &.{},
        .{
            .camera = camera,
            .camera_zoom = 1.0,
            .event_history = &.{},
            .level_start_index = null,
            .current_event_index = 0,
            .frame_allocator = arena,
            .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
            .sprite_bounds = .{},
            .can_undo = false,
            .can_redo = false,
        },
    );

    var top_count: usize = 0;
    var bottom_count: usize = 0;
    var left_count: usize = 0;
    var right_count: usize = 0;
    var left_edge_position: ?types.ScreenPosition = null;
    for (view_state.tile_overlays) |overlay| {
        try std.testing.expectEqual(types.TileOverlayType.region_edge, overlay.overlay_type);
        switch (overlay.edge) {
            .top => top_count += 1,
            .bottom => bottom_count += 1,
            .left => {
                left_count += 1;
                left_edge_position = overlay.screen_position;
            },
            .right => right_count += 1,
        }
    }
    // 2 tiles × (top + bottom) + 1 left + 1 right = 6; the shared side
    // between the two region tiles is interior - no edge there.
    try std.testing.expectEqual(@as(usize, 2), top_count);
    try std.testing.expectEqual(@as(usize, 2), bottom_count);
    try std.testing.expectEqual(@as(usize, 1), left_count);
    try std.testing.expectEqual(@as(usize, 1), right_count);
    // The left edge belongs to the anchor tile (the cursor tile).
    try std.testing.expectEqual(
        tileToScreen(.{ .x = 2, .y = 1 }, camera, 1.0),
        left_edge_position.?,
    );
}

test "editor select tool: hover previews the covering decoration's footprint, else the tile" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const footprint = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 256, .y = 256 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 4, .y = 1 },
    }};
    const levels = [_]types.EditorLevel{.{
        .player_start = .{ .x = 0, .y = 0 },
        .decoration_placements = &decoration_placements,
    }};
    var state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = &levels, .decoration_types = &decoration_types },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
    var session = state.SessionState{};
    state_.editor.?.active_tool = .select;

    const camera = computeCamera(&state_, 1.0, null, null);
    const runView = struct {
        fn call(
            state__: *const GameState,
            session__: *state.SessionState,
            arena__: std.mem.Allocator,
            harness__: *test_harness.Harness,
            camera__: types.Camera,
        ) types.ViewState {
            return view(
                state__,
                session__,
                .{ .input_bindings = &.{} },
                harness__.color_theme_definitions,
                &harness__.weapon_type_definitions,
                &.{},
                .{
                    .camera = camera__,
                    .camera_zoom = 1.0,
                    .event_history = &.{},
                    .level_start_index = null,
                    .current_event_index = 0,
                    .frame_allocator = arena__,
                    .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
                    .sprite_bounds = .{},
                    .can_undo = false,
                    .can_redo = false,
                },
            );
        }
    }.call;

    // Over the decoration's footprint tile: the region outline (a 1-tile
    // footprint = 4 edges).
    session.tile_cursor = .{ .x = 4, .y = 1 };
    const over_decoration = runView(&state_, &session, arena, &harness, camera);
    try std.testing.expectEqual(@as(usize, 4), over_decoration.tile_overlays.len);
    for (over_decoration.tile_overlays) |overlay| {
        try std.testing.expectEqual(types.TileOverlayType.region_edge, overlay.overlay_type);
    }

    // Anywhere else: the single-tile outline.
    session.tile_cursor = .{ .x = 2, .y = 2 };
    const over_ground = runView(&state_, &session, arena, &harness, camera);
    try std.testing.expectEqual(@as(usize, 1), over_ground.tile_overlays.len);
    try std.testing.expectEqual(types.TileOverlayType.cursor, over_ground.tile_overlays[0].overlay_type);
}

test "editor selection overlay: lightest-color outlines around all selected regions" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "ruin_1",
        .sprite = "ruin_1",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 5, .y = 1 },
    }};
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 1, .y = 1 },
    }};
    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Skeleton",
        .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 },
    }};
    const levels = [_]types.EditorLevel{.{
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 9, .y = 0 },
        .entity_placements = &entity_placements,
        .decoration_placements = &decoration_placements,
    }};
    var state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{
            .levels = &levels,
            .entity_types = &entity_types,
            .decoration_types = &decoration_types,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
    var session = state.SessionState{};
    // A tile (with its enemy), the player start, the level end, and the
    // 2-wide decoration - the union of everything selectable. Cursor null
    // so only the selection overlays emit.
    state_.editor.?.active_tool = .select;
    const seeded_selection = [_]types.Selectable{
        .{ .tile = .{ .x = 1, .y = 1 } },
        .{ .entity_placement = 0 },
        .player_start,
        .level_end,
        .{ .decoration_placement = 0 },
    };
    state_.editor.?.selection = &seeded_selection;

    const camera = computeCamera(&state_, 1.0, null, null);
    // The selection outlines use the active theme's lightest - the same
    // color as every other world outline (a fix: the first cut used
    // "pure white" {1,1,1}, but types.Color channels are u8 0-255, so that
    // rendered near-BLACK).
    const outline_color = activeThemeFor(&state_, harness.color_theme_definitions).lightest;
    const view_state = view(
        &state_,
        &session,
        .{ .input_bindings = &.{} },
        harness.color_theme_definitions,
        &harness.weapon_type_definitions,
        &.{},
        .{
            .camera = camera,
            .camera_zoom = 1.0,
            .event_history = &.{},
            .level_start_index = null,
            .current_event_index = 0,
            .frame_allocator = arena,
            .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
            .sprite_bounds = .{},
            .can_undo = false,
            .can_redo = false,
        },
    );

    var tile_outlines: usize = 0;
    var region_edges: usize = 0;
    for (view_state.tile_overlays) |overlay| {
        try std.testing.expect(std.meta.eql(outline_color, overlay.color));
        switch (overlay.overlay_type) {
            .cursor => tile_outlines += 1,
            .region_edge => region_edges += 1,
            else => {},
        }
    }
    // Single-tile outlines: the tile (1,1), the enemy on it (same rect -
    // opaque redraw, invisible), the '!' (0,0), the '=' (9,0) = 4.
    try std.testing.expectEqual(@as(usize, 4), tile_outlines);
    // The 2-wide decoration's region = 6 boundary edges.
    try std.testing.expectEqual(@as(usize, 6), region_edges);
}

test "editor move-drag preview: unselected claim translates the grabbed group, selected claim the selection" {
    // A promoted move drag previews its move: a selected-at-press claim
    // translates the SELECTION outlines (the pre-existing path); an
    // unselected claim renders the grabbed click group translated instead
    // - the selection is not in state yet, and the OLD selection must NOT
    // slide around (it is still the real selection). Nothing previews
    // before promotion (an unpromoted release is a plain click). See
    // `handleEditorMoveDrag` / `buildEditorMoveDragOverlay`.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "ruin_1",
        .sprite = "ruin_1",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 1, .y = 1 },
    }};
    const tiles = [_]types.Vector2{ .{ .x = 5, .y = 5 }, .{ .x = 7, .y = 7 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .decoration_placements = &decoration_placements,
    }};
    var state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = &levels, .decoration_types = &decoration_types },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
    var session = state.SessionState{};
    state_.editor.?.active_tool = .select;
    // The OLD selection (a tile elsewhere) - an unselected-claim drag
    // must not slide it around. Cursor null so only the selection + drag
    // overlays emit.
    const old_selection = [_]types.Selectable{.{ .tile = .{ .x = 5, .y = 5 } }};
    state_.editor.?.selection = &old_selection;
    session.tile_cursor = null;

    const camera = computeCamera(&state_, 1.0, null, null);
    const runView = struct {
        fn call(
            state__: *const GameState,
            session__: *state.SessionState,
            arena__: std.mem.Allocator,
            harness__: *test_harness.Harness,
            camera__: types.Camera,
        ) types.ViewState {
            return view(
                state__,
                session__,
                .{ .input_bindings = &.{} },
                harness__.color_theme_definitions,
                &harness__.weapon_type_definitions,
                &.{},
                .{
                    .camera = camera__,
                    .camera_zoom = 1.0,
                    .event_history = &.{},
                    .level_start_index = null,
                    .current_event_index = 0,
                    .frame_allocator = arena__,
                    .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
                    .sprite_bounds = .{},
                    .can_undo = false,
                    .can_redo = false,
                },
            );
        }
    }.call;

    // --- Before promotion nothing previews - the old selection renders
    // where it is. ---
    session.ui_state.editor_move_drag = .{
        .press_position_tile = .{ .x = 1, .y = 1 },
        .current_position_tile = .{ .x = 3, .y = 1 },
        .press_position = .{ .x = 0, .y = 0 },
        .promoted = false,
        .selected_at_press = false,
    };
    const unpromoted = runView(&state_, &session, arena, &harness, camera);
    try std.testing.expectEqual(@as(usize, 1), unpromoted.tile_overlays.len);
    try std.testing.expectEqual(
        tileToScreen(.{ .x = 5, .y = 5 }, camera, 1.0),
        unpromoted.tile_overlays[0].screen_position,
    );

    // --- Promoted UNSELECTED claim on a covering decoration (press its
    // anchor tile (1,1), drag to (3,1)): the grabbed footprint region
    // renders translated (anchor (3,1)-(4,1)) and the old selection
    // stays put. ---
    session.ui_state.editor_move_drag.?.promoted = true;
    const promoted_decoration = runView(&state_, &session, arena, &harness, camera);
    var region_edges: usize = 0;
    var at_translated_anchor: usize = 0;
    var at_original_anchor: usize = 0;
    var selection_outlines: usize = 0;
    for (promoted_decoration.tile_overlays) |overlay| {
        switch (overlay.overlay_type) {
            .region_edge => {
                region_edges += 1;
                if (std.meta.eql(
                    tileToScreen(.{ .x = 3, .y = 1 }, camera, 1.0),
                    overlay.screen_position,
                ) or std.meta.eql(
                    tileToScreen(.{ .x = 4, .y = 1 }, camera, 1.0),
                    overlay.screen_position,
                )) at_translated_anchor += 1;
                if (std.meta.eql(
                    tileToScreen(.{ .x = 1, .y = 1 }, camera, 1.0),
                    overlay.screen_position,
                ) or std.meta.eql(
                    tileToScreen(.{ .x = 2, .y = 1 }, camera, 1.0),
                    overlay.screen_position,
                )) at_original_anchor += 1;
            },
            .cursor => {
                selection_outlines += 1;
                try std.testing.expectEqual(
                    tileToScreen(.{ .x = 5, .y = 5 }, camera, 1.0),
                    overlay.screen_position,
                );
            },
            else => {},
        }
    }
    // The 2-wide region's 6 boundary edges, ALL on the translated
    // anchor - none at the original.
    try std.testing.expectEqual(@as(usize, 6), region_edges);
    try std.testing.expectEqual(@as(usize, 6), at_translated_anchor);
    try std.testing.expectEqual(@as(usize, 0), at_original_anchor);
    try std.testing.expectEqual(@as(usize, 1), selection_outlines);

    // --- Promoted UNSELECTED claim on a plain tile (press (7,7), drag to
    // (7,9)): the grabbed tile's outline follows the pointer; the old
    // selection stays put. ---
    session.ui_state.editor_move_drag = .{
        .press_position_tile = .{ .x = 7, .y = 7 },
        .current_position_tile = .{ .x = 7, .y = 9 },
        .press_position = .{ .x = 0, .y = 0 },
        .promoted = true,
        .selected_at_press = false,
    };
    const promoted_tile = runView(&state_, &session, arena, &harness, camera);
    try std.testing.expectEqual(@as(usize, 2), promoted_tile.tile_overlays.len);
    {
        var at_drag_target: usize = 0;
        var at_old_selection: usize = 0;
        for (promoted_tile.tile_overlays) |overlay| {
            if (std.meta.eql(
                tileToScreen(.{ .x = 7, .y = 9 }, camera, 1.0),
                overlay.screen_position,
            )) at_drag_target += 1;
            if (std.meta.eql(
                tileToScreen(.{ .x = 5, .y = 5 }, camera, 1.0),
                overlay.screen_position,
            )) at_old_selection += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), at_drag_target);
        try std.testing.expectEqual(@as(usize, 1), at_old_selection);
    }

    // --- Promoted SELECTED-at-press claim (press the selected (5,5)
    // tile, drag to (6,5)): the selection outline translates - today's
    // path, no group preview on top. ---
    session.ui_state.editor_move_drag = .{
        .press_position_tile = .{ .x = 5, .y = 5 },
        .current_position_tile = .{ .x = 6, .y = 5 },
        .press_position = .{ .x = 0, .y = 0 },
        .promoted = true,
        .selected_at_press = true,
    };
    const promoted_selected = runView(&state_, &session, arena, &harness, camera);
    try std.testing.expectEqual(@as(usize, 1), promoted_selected.tile_overlays.len);
    try std.testing.expectEqual(
        tileToScreen(.{ .x = 6, .y = 5 }, camera, 1.0),
        promoted_selected.tile_overlays[0].screen_position,
    );
}

test "entity body color: gradient by team, index by player-vs-helper" {
    // The coloring rule (DESIGN → Entity & UI Coloring): team 0 → player
    // gradient, else enemy gradient; the player ENTITY (index 0) uses the
    // settings player_color_index, every other entity - enemy-authored
    // team-0 helpers included - its own color_index.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const player_four: types.Color = .{ .r = 44, .g = 44, .b = 44 };
    const enemy_four: types.Color = .{ .r = 55, .g = 55, .b = 55 };
    const enemy_one: types.Color = .{ .r = 66, .g = 66, .b = 66 };
    const player_two: types.Color = .{ .r = 22, .g = 22, .b = 22 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    var player_gradient: [types.gradient_color_count]types.Color = .{black} ** types.gradient_color_count;
    player_gradient[2] = player_two;
    player_gradient[4] = player_four;
    var enemy_gradient: [types.gradient_color_count]types.Color = .{black} ** types.gradient_color_count;
    enemy_gradient[4] = enemy_four;
    // The weapon color (gradient index 1) - needed by the
    // keep_original_colors block below; set BEFORE the theme copy.
    enemy_gradient[1] = enemy_one;
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** types.gradient_color_count },
        .enemy_gradient = .{ .colors = enemy_gradient },
        .player_gradient = .{ .colors = player_gradient },
    };
    const camera: types.Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const sprite_bounds: std.StringHashMapUnmanaged(?types.SpriteBounds) = .{};

    // All three entities carry color_index 4 - the resolution differs only
    // by team + player-ness.
    const player_entity = types.Entity{ .team = 0, .color_index = 4 };
    const helper_entity = types.Entity{ .team = 0, .color_index = 4 };
    const enemy_entity = types.Entity{ .team = 2, .color_index = 4 };

    const player_drawable = entityDrawable(&player_entity, theme, 2, true, camera, 1.0, arena, sprite_bounds, false);
    const helper_drawable = entityDrawable(&helper_entity, theme, 2, false, camera, 1.0, arena, sprite_bounds, false);
    const enemy_drawable = entityDrawable(&enemy_entity, theme, 2, false, camera, 1.0, arena, sprite_bounds, false);

    // The player: settings index 2 into the player gradient (its own
    // color_index ignored).
    try std.testing.expect(std.meta.eql(player_two, player_drawable.base_sprite.color));
    // The helper: same player GRADIENT, but its own color_index (4).
    try std.testing.expect(std.meta.eql(player_four, helper_drawable.base_sprite.color));
    // The team-2 enemy: enemy gradient at its own color_index.
    try std.testing.expect(std.meta.eql(enemy_four, enemy_drawable.base_sprite.color));

    // keep_original_colors: base + layers UNTINTED (pure white); the
    // WEAPONS stay themed (enemy gradient index 1 - our art, not the
    // asset's).
    {
        const layers = [_]types.EntityLayer{.{ .sprite = "bear", .color_index = 4 }};
        const custom_entity = types.Entity{
            .team = 2,
            .color_index = 4,
            .keep_original_colors = true,
            .layers = &layers,
            .main_hand_weapon = .{ .weapon_type = .sword },
        };
        const drawable = entityDrawable(&custom_entity, theme, 2, false, camera, 1.0, arena, sprite_bounds, false);
        try std.testing.expect(std.meta.eql(no_tint_color, drawable.base_sprite.color));
        try std.testing.expectEqual(@as(usize, 1), drawable.layer_sprites.len);
        try std.testing.expect(std.meta.eql(no_tint_color, drawable.layer_sprites[0].color));
        try std.testing.expect(std.meta.eql(enemy_one, drawable.weapon_sprites[0].?.color));
    }
}

test "decoration pieces: keep_original_colors untints base + layers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const world_four: types.Color = .{ .r = 77, .g = 77, .b = 77 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    var world_gradient: [types.gradient_color_count]types.Color = .{black} ** types.gradient_color_count;
    world_gradient[4] = world_four;
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = world_gradient },
        .enemy_gradient = .{ .colors = .{black} ** types.gradient_color_count },
        .player_gradient = .{ .colors = .{black} ** types.gradient_color_count },
    };
    const camera: types.Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const footprint = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const layers = [_]types.DecorationLayer{.{
        .sprite = "tree_1_canopy",
        .color_index = 4,
        .pixel_dims = .{ .x = 256, .y = 256 },
    }};

    const pieces = buildDecorationPieces(.{
        .name = "tree_1",
        .position = .{ .x = 0, .y = 0 },
        .footprint = &footprint,
        .pixel_dims = .{ .x = 256, .y = 256 },
        .color_index = 4,
        .keep_original_colors = true,
        .layers = &layers,
    }, theme, camera, 1.0, arena);
    try std.testing.expectEqual(@as(usize, 1), pieces.len);
    const piece = pieces[0].drawable.decoration_piece;
    try std.testing.expect(std.meta.eql(no_tint_color, piece.color));
    try std.testing.expectEqual(@as(usize, 1), piece.layers.len);
    try std.testing.expect(std.meta.eql(no_tint_color, piece.layers[0].color));

    // Flag off: the world gradient at the authored indices.
    const tinted = buildDecorationPieces(.{
        .name = "tree_1",
        .position = .{ .x = 0, .y = 0 },
        .footprint = &footprint,
        .pixel_dims = .{ .x = 256, .y = 256 },
        .color_index = 4,
        .layers = &layers,
    }, theme, camera, 1.0, arena);
    const tinted_piece = tinted[0].drawable.decoration_piece;
    try std.testing.expect(std.meta.eql(world_four, tinted_piece.color));
    try std.testing.expect(std.meta.eql(world_four, tinted_piece.layers[0].color));
}

test "decoration pieces: behind layers split into back_layers, config order kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** types.gradient_color_count },
        .enemy_gradient = .{ .colors = .{black} ** types.gradient_color_count },
        .player_gradient = .{ .colors = .{black} ** types.gradient_color_count },
    };
    const camera: types.Camera = .{ .position = .{ .x = 0, .y = 0 } };
    const footprint = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    // Config order: canopy (front), grass_back (behind), grass (front),
    // moss (behind) - interleaved, so order WITHIN each side is what's
    // under test, not just the split.
    const layers = [_]types.DecorationLayer{
        .{ .sprite = "tree_1_canopy", .color_index = 2, .pixel_dims = .{ .x = 256, .y = 256 } },
        .{ .sprite = "tree_1_grass_back", .color_index = 2, .behind = true, .pixel_dims = .{ .x = 256, .y = 256 } },
        .{ .sprite = "tree_1_grass", .color_index = 2, .pixel_dims = .{ .x = 256, .y = 256 } },
        .{ .sprite = "tree_1_moss", .color_index = 2, .behind = true, .pixel_dims = .{ .x = 256, .y = 256 } },
    };

    const pieces = buildDecorationPieces(.{
        .name = "tree_1",
        .position = .{ .x = 0, .y = 0 },
        .footprint = &footprint,
        .pixel_dims = .{ .x = 256, .y = 256 },
        .color_index = 4,
        .layers = &layers,
    }, theme, camera, 1.0, arena);
    const piece = pieces[0].drawable.decoration_piece;
    try std.testing.expectEqual(@as(usize, 2), piece.back_layers.len);
    try std.testing.expectEqual(@as(usize, 2), piece.layers.len);
    try std.testing.expectEqualStrings("decorations/tree_1_grass_back", piece.back_layers[0].sprite_id);
    try std.testing.expectEqualStrings("decorations/tree_1_moss", piece.back_layers[1].sprite_id);
    try std.testing.expectEqualStrings("decorations/tree_1_canopy", piece.layers[0].sprite_id);
    try std.testing.expectEqualStrings("decorations/tree_1_grass", piece.layers[1].sprite_id);
    // Back layers share the piece's position + source rect (the same
    // chunking, just drawn before the base).
    try std.testing.expectEqual(piece.screen_position, piece.back_layers[0].screen_position);
    try std.testing.expectEqual(piece.source_rectangle, piece.back_layers[0].source_rectangle);
}

// ============================================================
// Camera clamp region tests (slice 1: region builder, no consumer yet)
// ============================================================

test "middle panel width: inspect panel renders only for a live in-range target" {
    const font_metrics = ui.FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const entities = [_]types.Entity{ .{}, .{ .current_health = 0 } };
    const level = types.Level{ .entities = &entities };
    var level_state = GameState{
        .screen = .level,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = level,
        .hub = null,
    };
    const hub_state = GameState{
        .screen = .hub,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = types.Hub{},
    };

    level_state.ui_surfaces.inspected_entity_index = 0;
    try std.testing.expectEqual(
        ui.entity_inspect_panel_width,
        middlePanelWidth(.entity_inspect, &level_state, font_metrics),
    );
    // Dead target: no panel, no space.
    level_state.ui_surfaces.inspected_entity_index = 1;
    try std.testing.expectEqual(
        @as(?i32, null),
        middlePanelWidth(.entity_inspect, &level_state, font_metrics),
    );
    // Out-of-range target index: no panel.
    level_state.ui_surfaces.inspected_entity_index = 5;
    try std.testing.expectEqual(
        @as(?i32, null),
        middlePanelWidth(.entity_inspect, &level_state, font_metrics),
    );
    // Inspect is level-only: a hub screen reserves no space.
    level_state.ui_surfaces.inspected_entity_index = 0;
    try std.testing.expectEqual(
        @as(?i32, null),
        middlePanelWidth(.entity_inspect, &hub_state, font_metrics),
    );

    // The unconditional panels have fixed widths.
    try std.testing.expectEqual(
        @as(?i32, ui.inventory_panel_width),
        middlePanelWidth(.inventory, &level_state, font_metrics),
    );
    try std.testing.expectEqual(
        @as(?i32, ui.skills_panel_width),
        middlePanelWidth(.skills, &level_state, font_metrics),
    );
}

test "middle panels occupied width: gaps only between rendered panels" {
    const font_metrics = ui.FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const entities = [_]types.Entity{ .{}, .{ .current_health = 0 } };
    const level = types.Level{ .entities = &entities };
    var level_state = GameState{
        .screen = .level,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = level,
        .hub = null,
    };

    // Two rendered panels: one ui_gap between them.
    level_state.ui_surfaces.open_middle_panels = .{ .inventory, .skills, null, null };
    try std.testing.expectEqual(
        ui.inventory_panel_width + ui.ui_gap + ui.skills_panel_width,
        middlePanelsOccupiedWidth(&level_state, font_metrics),
    );

    // A dead inspect target renders nothing, so it contributes neither
    // width nor a gap on either side.
    level_state.ui_surfaces.inspected_entity_index = 1;
    level_state.ui_surfaces.open_middle_panels = .{ .inventory, .entity_inspect, .skills, null };
    try std.testing.expectEqual(
        ui.inventory_panel_width + ui.ui_gap + ui.skills_panel_width,
        middlePanelsOccupiedWidth(&level_state, font_metrics),
    );

    // A live inspect target: width plus the gap.
    level_state.ui_surfaces.inspected_entity_index = 0;
    try std.testing.expectEqual(
        ui.inventory_panel_width + 2 * ui.ui_gap + ui.skills_panel_width + ui.entity_inspect_panel_width,
        middlePanelsOccupiedWidth(&level_state, font_metrics),
    );
}

test "camera view region: bars bound vertically, panels bound horizontally" {
    const font_metrics = ui.FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var level_state = GameState{
        .screen = .level,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = types.Level{},
        .hub = null,
    };

    // No panels: the full band between the bars.
    const full = cameraViewRegion(&level_state, font_metrics, 1.0).?;
    try std.testing.expectEqual(types.Rectangle{
        .x = 0,
        .y = ui.top_bar_height,
        .width = types.reference_width,
        .height = types.reference_height - ui.top_bar_height - ui.bottom_bar_height,
    }, full);

    // Panels open: the region starts at the occupied right edge.
    level_state.ui_surfaces.open_middle_panels = .{ .inventory, null, null, null };
    const occupied = cameraViewRegion(&level_state, font_metrics, 1.0).?;
    try std.testing.expectEqual(ui.inventory_panel_width, occupied.x);
    try std.testing.expectEqual(types.reference_width - ui.inventory_panel_width, occupied.width);
    // The vertical bounds are the same either way.
    try std.testing.expectEqual(full.y, occupied.y);
    try std.testing.expectEqual(full.height, occupied.height);
}

test "camera view region: fully covered screen acts as if no panels open" {
    // The feasibility boundary: the margin band needs
    // 2 * camera_edge_margin_tiles of remaining width (the same constant
    // cameraViewRegionFor derives its band from; the margin scales with
    // zoom).
    const tile_px: i32 = @intFromFloat(input.tile_size_pixels);
    const margin_band_100 = 2 * camera_edge_margin_tiles * tile_px;
    // Exactly enough: panels honored - the region starts at the occupied
    // width.
    try std.testing.expectEqual(
        types.reference_width - margin_band_100,
        cameraViewRegionFor(types.reference_width - margin_band_100, 1.0).x,
    );
    // One pixel short: fallback to the full band.
    try std.testing.expectEqual(
        @as(i32, 0),
        cameraViewRegionFor(types.reference_width - margin_band_100 + 1, 1.0).x,
    );
    // Lower zoom shrinks the band (the margin scales with zoom), so the
    // same rule at half zoom: the occupied width leaves exactly the
    // half-zoom band.
    const margin_band_050 = @divTrunc(margin_band_100, 2);
    try std.testing.expectEqual(
        types.reference_width - margin_band_050,
        cameraViewRegionFor(types.reference_width - margin_band_050, 0.5).x,
    );
    // Degenerate: occupied beyond the screen width - fallback.
    try std.testing.expectEqual(
        @as(i32, 0),
        cameraViewRegionFor(types.reference_width, 1.0).x,
    );
}

test "camera view region: null outside levels, hubs, and the editor" {
    const font_metrics = ui.FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const editor_state = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = &.{} },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
    const main_menu_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    try std.testing.expectEqual(
        @as(?types.Rectangle, null),
        cameraViewRegion(&main_menu_state, font_metrics, 1.0),
    );

    // The editor viewport gets the same band as the game (top row + tool
    // palette bound it vertically), at full width - sidebars and pickers
    // are deliberately not accounted for.
    try std.testing.expectEqual(
        types.Rectangle{
            .x = 0,
            .y = ui.top_bar_height,
            .width = types.reference_width,
            .height = types.reference_height - ui.top_bar_height - ui.bottom_bar_height,
        },
        cameraViewRegion(&editor_state, font_metrics, 1.0).?,
    );

    // A hub screen gets the same full band as a level.
    const hub_state = GameState{
        .screen = .hub,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = types.Hub{},
    };
    try std.testing.expectEqual(
        types.Rectangle{
            .x = 0,
            .y = ui.top_bar_height,
            .width = types.reference_width,
            .height = types.reference_height - ui.top_bar_height - ui.bottom_bar_height,
        },
        cameraViewRegion(&hub_state, font_metrics, 1.0).?,
    );
}

// ============================================================
// Camera clamp tests (slice 2: the clamp math inside computeCamera)
// ============================================================

/// Comptime rectangular tile grid.
fn tileGrid(comptime width: i32, comptime height: i32) [width * height]types.Vector2 {
    var tiles: [width * height]types.Vector2 = undefined;
    var index: usize = 0;
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        var x: i32 = 0;
        while (x < width) : (x += 1) {
            tiles[index] = .{ .x = x, .y = y };
            index += 1;
        }
    }
    return tiles;
}

/// A level screen with a tile grid and the player (entity 0) at
/// `player_position`. The player entity lives in file-scope storage: the
/// returned GameState would otherwise dangle a pointer into this helper's
/// dead frame (entities is a by-reference slice, and the old function-local
/// array only worked by stack-layout luck).
var level_state_player_storage: [1]types.Entity = undefined;

fn levelStateWithPlayer(
    tiles: []const types.Vector2,
    player_position: types.Vector2,
) GameState {
    level_state_player_storage[0] = .{ .position = player_position };
    return .{
        .screen = .level,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = .{ .level_tiles = tiles, .entities = &level_state_player_storage },
        .hub = null,
    };
}

/// The full-band clamp region (no panels): x [0, reference_width), y
/// [top_bar_height, reference_height − bottom_bar_height).
fn fullBandRegion() Rectangle {
    return .{
        .x = 0,
        .y = ui.top_bar_height,
        .width = types.reference_width,
        .height = types.reference_height - ui.top_bar_height - ui.bottom_bar_height,
    };
}

// Camera-clamp test helpers: the clamp's semantic contracts expressed
// over the same constants `computeCamera` uses (DESIGN → Platform Seam →
// Camera clamping) - no hand-computed pixel literals, so band/geometry
// changes can't stale them (the 128px top-bar pass updated every literal
// here by hand and left the comments lying).

/// The player's world-pixel center: (tile + 0.5) × tile pixels - the
/// position `computeCamera` centers on.
fn playerCenter(tile: types.Vector2) types.Vector2 {
    const tile_px: i32 = @intFromFloat(input.tile_size_pixels);
    return .{
        .x = @divTrunc((2 * tile.x + 1) * tile_px, 2),
        .y = @divTrunc((2 * tile.y + 1) * tile_px, 2),
    };
}

/// A w×h tile grid's world-pixel center (`tileGrid` builds from (0,0)).
fn gridCenterPx(width_tiles: i32, height_tiles: i32) types.Vector2 {
    const tile_px: i32 = @intFromFloat(input.tile_size_pixels);
    return .{
        .x = @divTrunc(width_tiles * tile_px, 2),
        .y = @divTrunc(height_tiles * tile_px, 2),
    };
}

/// The camera the margin band pins while the player sits against the
/// region's LEFT/TOP edge: the player lands exactly
/// `camera_edge_margin_tiles` inside the region's low edges (the
/// reference-centered projection - the region's own screen offset is
/// subtracted).
fn marginCameraLow(player_center: types.Vector2, region: Rectangle) types.Vector2 {
    const tile_px: i32 = @intFromFloat(input.tile_size_pixels);
    const margin = camera_edge_margin_tiles * tile_px;
    return .{
        .x = player_center.x - region.x + @divTrunc(types.reference_width, 2) - margin,
        .y = player_center.y - region.y + @divTrunc(types.reference_height, 2) - margin,
    };
}

/// The camera the margin band pins while the player sits against the
/// region's RIGHT/BOTTOM edge.
fn marginCameraHigh(player_center: types.Vector2, region: Rectangle) types.Vector2 {
    const tile_px: i32 = @intFromFloat(input.tile_size_pixels);
    const margin = camera_edge_margin_tiles * tile_px;
    return .{
        .x = player_center.x - (region.x + region.width) + @divTrunc(types.reference_width, 2) + margin,
        .y = player_center.y - (region.y + region.height) + @divTrunc(types.reference_height, 2) + margin,
    };
}

/// The camera for a level that FITS the region: centered on the level's
/// center as a whole (centering wins over the margin band - the whole
/// level is visible).
fn wholeLevelCenteredCamera(level_center: types.Vector2, region: Rectangle) types.Vector2 {
    return .{
        .x = level_center.x - @divTrunc(2 * region.x + region.width, 2) + @divTrunc(types.reference_width, 2),
        .y = level_center.y - @divTrunc(2 * region.y + region.height, 2) + @divTrunc(types.reference_height, 2),
    };
}

test "camera clamp: near-edge player keeps the 2-tile margin, void shed" {
    // 30x17 level - overflows the region on both axes at zoom 1.0.
    const tiles = tileGrid(30, 17);
    const region = fullBandRegion();

    // Player in the top-left corner: the camera shifts toward the level
    // center (shedding the void) only until the player is exactly
    // camera_edge_margin_tiles inside the region's left/top edges.
    var state_ = levelStateWithPlayer(&tiles, .{ .x = 0, .y = 0 });
    var camera = computeCamera(&state_, 1.0, null, region);
    try std.testing.expectEqual(marginCameraLow(playerCenter(.{ .x = 0, .y = 0 }), region), camera.position);

    // Bottom-right corner: symmetric - the margin inside the region's
    // right/bottom edges.
    state_ = levelStateWithPlayer(&tiles, .{ .x = 29, .y = 16 });
    camera = computeCamera(&state_, 1.0, null, region);
    try std.testing.expectEqual(marginCameraHigh(playerCenter(.{ .x = 29, .y = 16 }), region), camera.position);
}

test "camera clamp: mid-level player stays exactly player-centered" {
    const tiles = tileGrid(30, 17);
    // No void to shed and the margin holds: the camera is the plain
    // player-centered position (2 tiles of margin are available in every
    // direction from here).
    const state_ = levelStateWithPlayer(&tiles, .{ .x = 10, .y = 8 });
    const camera = computeCamera(&state_, 1.0, null, fullBandRegion());
    try std.testing.expectEqual(playerCenter(.{ .x = 10, .y = 8 }), camera.position);
}

test "camera clamp: a level that fits is centered as a whole" {
    // 4x3 level - fits inside the region on both axes, so it is centered
    // in the band regardless of the player's position.
    const tiles = tileGrid(4, 3);
    const region = fullBandRegion();
    const centered = wholeLevelCenteredCamera(gridCenterPx(4, 3), region);
    var state_ = levelStateWithPlayer(&tiles, .{ .x = 1, .y = 1 });
    var camera = computeCamera(&state_, 1.0, null, region);
    try std.testing.expectEqual(centered, camera.position);

    // Even with the player at a corner - centering wins over the margin.
    state_ = levelStateWithPlayer(&tiles, .{ .x = 0, .y = 0 });
    camera = computeCamera(&state_, 1.0, null, region);
    try std.testing.expectEqual(centered, camera.position);

    // A pan wiggles the centered view by up to camera_pan_void_tiles each
    // way instead of being a no-op: a far pan clamps at the budget's edge.
    state_ = levelStateWithPlayer(&tiles, .{ .x = 0, .y = 0 });
    camera = computeCamera(&state_, 1.0, .{ .x = 10_000, .y = -10_000 }, region);
    const tile_px: i32 = @intFromFloat(input.tile_size_pixels);
    const pan_slack = camera_pan_void_tiles * tile_px;
    try std.testing.expectEqual(centered.x + pan_slack, camera.position.x);
    try std.testing.expectEqual(centered.y - pan_slack, camera.position.y);
}

test "camera clamp: one axis fits, the other clamps" {
    // 4 wide (fits, centered) x 40 tall (overflows, margin at the bottom).
    const tiles = tileGrid(4, 40);
    const region = fullBandRegion();
    const state_ = levelStateWithPlayer(&tiles, .{ .x = 1, .y = 39 });
    const camera = computeCamera(&state_, 1.0, null, region);
    // x: the level fits - centered as a whole.
    try std.testing.expectEqual(
        wholeLevelCenteredCamera(gridCenterPx(4, 40), region).x,
        camera.position.x,
    );
    // y: the player one tile from the bottom - the margin band pins them
    // camera_edge_margin_tiles inside the region's bottom edge.
    try std.testing.expectEqual(
        marginCameraHigh(playerCenter(.{ .x = 1, .y = 39 }), region).y,
        camera.position.y,
    );
}

test "camera clamp: pan gets 4 tiles of wiggle past the level edges" {
    // A deliberate pan skips the player margin (the point of panning is to
    // look away from the player) and may show up to camera_pan_void_tiles
    // of void past an edge before the clamp stops it - so the edge clamp
    // doesn't feel like a hard wall.
    const tiles = tileGrid(30, 17);
    const region = fullBandRegion();
    const tile_px: i32 = @intFromFloat(input.tile_size_pixels);
    const level_max_x = 30 * tile_px;
    const pan_slack = camera_pan_void_tiles * tile_px;
    var state_ = levelStateWithPlayer(&tiles, .{ .x = 0, .y = 0 });

    // Pan far right: the window's right edge stops exactly the void budget
    // past the level's right edge.
    var camera = computeCamera(&state_, 1.0, .{ .x = 10_000, .y = 0 }, region);
    try std.testing.expectEqual(
        level_max_x - (region.x + region.width) + @divTrunc(types.reference_width, 2) + pan_slack,
        camera.position.x,
    );
    // The y margin is suspended while panned: the plain player-centered y
    // passes (its top void is inside the budget).
    try std.testing.expectEqual(playerCenter(.{ .x = 0, .y = 0 }).y, camera.position.y);

    // Pan far left: the window's left edge stops exactly the budget before
    // the level's left edge (tileGrid builds from (0,0)).
    camera = computeCamera(&state_, 1.0, .{ .x = -10_000, .y = 0 }, region);
    try std.testing.expectEqual(
        0 - region.x + @divTrunc(types.reference_width, 2) - pan_slack,
        camera.position.x,
    );

    // Interior pan passes through untouched: the plain player-centered
    // position plus the pan.
    camera = computeCamera(&state_, 1.0, .{ .x = 1000, .y = 0 }, region);
    try std.testing.expectEqual(playerCenter(.{ .x = 0, .y = 0 }).x + 1000, camera.position.x);
}

test "camera clamp: panels shift the margin band to the viewable region" {
    // The same 30x17 level with an inventory panel open: the region is
    // narrowed to the un-occupied band. The player at the left edge is
    // kept camera_edge_margin_tiles inside the PANEL's right edge, not
    // the screen edge.
    const tiles = tileGrid(30, 17);
    const region = Rectangle{
        .x = ui.inventory_panel_width,
        .y = ui.top_bar_height,
        .width = types.reference_width - ui.inventory_panel_width,
        .height = types.reference_height - ui.top_bar_height - ui.bottom_bar_height,
    };
    const state_ = levelStateWithPlayer(&tiles, .{ .x = 0, .y = 0 });
    const camera = computeCamera(&state_, 1.0, null, region);
    try std.testing.expectEqual(marginCameraLow(playerCenter(.{ .x = 0, .y = 0 }), region), camera.position);
}

test "camera clamp: hub screens clamp against the hub tile grid" {
    // The hub arm of screenWorldBounds: a 4x3 hub centers like a small
    // level (the hub player rides `hub.player`, not entities).
    const tiles = tileGrid(4, 3);
    const state_ = GameState{
        .screen = .hub,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = .{
            .hub_tiles = &tiles,
            .player = .{ .position = .{ .x = 1, .y = 1 } },
        },
    };
    const camera = computeCamera(&state_, 1.0, null, fullBandRegion());
    try std.testing.expectEqual(
        wholeLevelCenteredCamera(gridCenterPx(4, 3), fullBandRegion()),
        camera.position,
    );
}

test "camera clamp: null region is the unclamped behavior" {
    // The pan-solve reference contract: no region, no clamp - the camera is
    // the plain player-centered position plus pan, even at a level edge.
    const tiles = tileGrid(30, 17);
    const state_ = levelStateWithPlayer(&tiles, .{ .x = 0, .y = 0 });
    const camera = computeCamera(&state_, 1.0, .{ .x = 10_000, .y = -10_000 }, null);
    try std.testing.expectEqual(playerCenter(.{ .x = 0, .y = 0 }).x + 10_000, camera.position.x);
    try std.testing.expectEqual(playerCenter(.{ .x = 0, .y = 0 }).y - 10_000, camera.position.y);
}

// ============================================================
// Editor viewport camera tests
// ============================================================

test "editor viewport: clamps the active level around its player_start" {
    // The editor's "player position" is the active level's player_start
    // (the '!' marker): the same clamp rules as gameplay apply around it.
    // The clamp bounds come from `Editor.clamp_bounds` - the SNAPSHOT the
    // level-switch handlers take (set here as refreshEditorClampBounds
    // would) - so the bounds follow the ACTIVE level's tab.
    const big_tiles = tileGrid(30, 17);
    const small_tiles = tileGrid(4, 3);
    // Two levels sharing a player_start (fresh levels come from one
    // template) with different layouts.
    const levels = [_]types.EditorLevel{
        .{ .level_tiles = &big_tiles, .player_start = .{ .x = 0, .y = 0 } },
        .{ .level_tiles = &small_tiles, .player_start = .{ .x = 0, .y = 0 } },
    };
    var state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = &levels },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    // Big level, player_start at the corner: same framing as the level
    // test - the margin band pins the player_start camera_edge_margin_tiles
    // inside the region's low edges.
    state_.editor.?.active_level_index = 0;
    state_.editor.?.clamp_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 29, .max_y = 16 };
    var camera = computeCamera(&state_, 1.0, null, fullBandRegion());
    try std.testing.expectEqual(
        marginCameraLow(playerCenter(.{ .x = 0, .y = 0 }), fullBandRegion()),
        camera.position,
    );

    // Tab to the small level: centered as a whole - the tab switch
    // re-clamps on the new layout (the snapshot refresh).
    state_.editor.?.active_level_index = 1;
    state_.editor.?.clamp_bounds = .{ .min_x = 0, .min_y = 0, .max_x = 3, .max_y = 2 };
    camera = computeCamera(&state_, 1.0, null, fullBandRegion());
    try std.testing.expectEqual(
        wholeLevelCenteredCamera(gridCenterPx(4, 3), fullBandRegion()),
        camera.position,
    );
}

test "editor viewport: mid-edit tile changes never reframe the camera" {
    // The clamp reads the SNAPSHOT, not the live tiles: after the level
    // switch takes its bounds, painting/deleting tiles (which changes the
    // live bbox) must not shift the camera. Only the next level switch
    // re-clamps. See DESIGN → Platform Seam → Camera clamping.
    const snapshot_tiles = tileGrid(30, 17);
    const edited_tiles = tileGrid(4, 3);
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &edited_tiles,
        .player_start = .{ .x = 0, .y = 0 },
    }};
    const state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{
            .levels = &levels,
            // The snapshot from switch time (the full 30x17 grid) - the
            // live tiles have since been edited down to 4x3.
            .clamp_bounds = tileBoundsOf(&snapshot_tiles),
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    // The clamp is against the SNAPSHOT bounds: the player_start-corner
    // framing of the big grid - the margin band over the snapshot - not
    // the small live grid (which would center as a whole).
    const camera = computeCamera(&state_, 1.0, null, fullBandRegion());
    try std.testing.expectEqual(
        marginCameraLow(playerCenter(.{ .x = 0, .y = 0 }), fullBandRegion()),
        camera.position,
    );
}

/// Test helper: the tile bbox snapshot `refreshEditorClampBounds` would
/// take of `tiles` (inclusive tile coords).
fn tileBoundsOf(tiles: []const types.Vector2) ?types.TileBounds {
    if (tiles.len == 0) return null;
    var bounds = types.TileBounds{ .min_x = tiles[0].x, .min_y = tiles[0].y, .max_x = tiles[0].x, .max_y = tiles[0].y };
    for (tiles[1..]) |tile| {
        bounds.min_x = @min(bounds.min_x, tile.x);
        bounds.max_x = @max(bounds.max_x, tile.x);
        bounds.min_y = @min(bounds.min_y, tile.y);
        bounds.max_y = @max(bounds.max_y, tile.y);
    }
    return bounds;
}

test "editor viewport: pan is completely free" {
    const tiles = tileGrid(30, 17);
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
    }};
    const state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = &levels },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    // No flush bounds, no wiggle budget, no margin: a panned editor
    // camera is the plain player_start-centered position plus the raw
    // offset - roam anywhere. The pan clears on the next tab switch or
    // screen transition (cameraRecenterKey), restoring the clamped frame.
    const camera = computeCamera(&state_, 1.0, .{ .x = 100_000, .y = -100_000 }, fullBandRegion());
    try std.testing.expectEqual(playerCenter(.{ .x = 0, .y = 0 }).x + 100_000, camera.position.x);
    try std.testing.expectEqual(playerCenter(.{ .x = 0, .y = 0 }).y - 100_000, camera.position.y);
}

test "editor viewport: an empty level stays unclamped" {
    // No tiles -> no bounds -> the plain player_start-centered camera.
    const levels = [_]types.EditorLevel{.{ .player_start = .{ .x = 2, .y = 3 } }};
    const state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = &levels },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
    const camera = computeCamera(&state_, 1.0, null, fullBandRegion());
    try std.testing.expectEqual(playerCenter(.{ .x = 2, .y = 3 }), camera.position);
}

test "camera recenter key: editor level tabs change it even with identical player starts" {
    // Two levels with the SAME player_start: the position alone wouldn't
    // detect the tab switch - the active level index rides the key.
    const levels = [_]types.EditorLevel{
        .{ .player_start = .{ .x = 5, .y = 5 } },
        .{ .player_start = .{ .x = 5, .y = 5 } },
    };
    var state_ = GameState{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{ .levels = &levels },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    const key_zero = cameraRecenterKey(&state_);
    try std.testing.expectEqual(@as(?usize, 0), key_zero.editor_level_index);
    try std.testing.expectEqual(types.Vector2{ .x = 5, .y = 5 }, key_zero.position);

    state_.editor.?.active_level_index = 1;
    const key_one = cameraRecenterKey(&state_);
    try std.testing.expect(std.meta.eql(key_zero, key_zero));
    try std.testing.expect(!std.meta.eql(key_one, key_zero));

    // Outside the editor there is no editor index to ride along.
    const level_state = levelStateWithPlayer(&.{}, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(?usize, null), cameraRecenterKey(&level_state).editor_level_index);
}

test "global top bar: hovering options/undo/redo spawns their tooltips" {
    // Regression contract: the hover-tooltip pass must run AFTER the global
    // top bar is emitted (the top bar is the LAST element block appended, so
    // its buttons are invisible to a pass that runs earlier). Before the
    // fix the pass ran before the emission and no tooltip could ever spawn
    // for the top bar - its buttons resolved to nothing under the pointer.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    const state_ = test_harness.levelStateWithEntities(arena, &.{.{}}, &.{});
    var session = state.SessionState{};
    const font_metrics = ui.FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // Button centers: a row of `top_bar_slot_size` cells flush top-left,
    // separated by `ui_gap` (options, undo, redo).
    const stride = ui.top_bar_slot_size + ui.ui_gap;
    const cell_center_y = @divTrunc(ui.top_bar_height, 2);
    const cases = [_]struct { x: i32, header: []const u8 }{
        .{ .x = @divTrunc(ui.top_bar_slot_size, 2), .header = "Options" },
        .{ .x = stride + @divTrunc(ui.top_bar_slot_size, 2), .header = "Undo" },
        .{ .x = 2 * stride + @divTrunc(ui.top_bar_slot_size, 2), .header = "Redo" },
    };
    for (cases) |case| {
        session.input_state.mouse_screen_position = .{
            .x = @floatFromInt(case.x),
            .y = @floatFromInt(cell_center_y),
        };
        const view_state = view(
            &state_,
            &session,
            .{ .input_bindings = &.{} },
            harness.color_theme_definitions,
            &harness.weapon_type_definitions,
            &.{},
            .{
                .camera = computeCamera(&state_, 1.0, null, null),
                .camera_zoom = 1.0,
                .event_history = &.{},
                .level_start_index = null,
                .current_event_index = 0,
                .frame_allocator = arena,
                .font_metrics = font_metrics,
                .sprite_bounds = .{},
                .can_undo = true,
                .can_redo = true,
            },
        );
        // The tooltip's header label: text == the button's header, at the
        // tooltip header font size (the size only tooltip headers use).
        var found = false;
        for (view_state.ui_elements) |element| {
            switch (element) {
                .text_label => |label| {
                    if (label.font_size == ui.tooltip_header_font_size and
                        std.mem.eql(u8, label.text, case.header))
                    {
                        found = true;
                    }
                },
                else => {},
            }
        }
        try std.testing.expect(found);
    }

    // Negative control: the gap between buttons resolves to nothing - none
    // of the three headers may spawn there. (Scoped to the header texts, not
    // the font size alone: other UI legitimately uses size-64 labels.)
    session.input_state.mouse_screen_position = .{
        .x = @floatFromInt(ui.top_bar_slot_size + @divTrunc(ui.ui_gap, 2)),
        .y = @floatFromInt(cell_center_y),
    };
    const view_state = view(
        &state_,
        &session,
        .{ .input_bindings = &.{} },
        harness.color_theme_definitions,
        &harness.weapon_type_definitions,
        &.{},
        .{
            .camera = computeCamera(&state_, 1.0, null, null),
            .camera_zoom = 1.0,
            .event_history = &.{},
            .level_start_index = null,
            .current_event_index = 0,
            .frame_allocator = arena,
            .font_metrics = font_metrics,
            .sprite_bounds = .{},
            .can_undo = true,
            .can_redo = true,
        },
    );
    for (view_state.ui_elements) |element| {
        switch (element) {
            .text_label => |label| {
                if (label.font_size == ui.tooltip_header_font_size) {
                    for (cases) |case| {
                        try std.testing.expect(!std.mem.eql(u8, label.text, case.header));
                    }
                }
            },
            else => {},
        }
    }
}

test "tips overlay: top-bar ? button, panel structure, cycle payloads" {
    // The ? button lives in the global top bar (any screen, only when
    // the tips list is non-empty); the open panel is the credits model:
    // the wrapped tip's text, Back (the open_tips toggle, payload-less),
    // and prev/next (cycle_tips, opposite tips_direction payloads).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const harness = test_harness.Harness.init(arena);
    const font_metrics = ui.FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const main_menu_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    const findButton = struct {
        fn find(
            elements: []const ui.UiElement,
            action: types.Action,
            /// The expected tips_direction payload, or null for a
            /// payload-less button.
            direction: ?types.TipsDirection,
        ) ?usize {
            for (elements, 0..) |element, index| {
                if (element == .button and element.button.action == action) {
                    const matches = if (direction) |expected| blk: {
                        const actual = element.button.payload orelse break :blk false;
                        break :blk std.meta.activeTag(actual) == .tips_direction and
                            actual.tips_direction == expected;
                    } else element.button.payload == null;
                    if (matches) return index;
                }
            }
            return null;
        }
    }.find;

    // Closed, tips loaded: exactly the top-bar ? button (no panel).
    {
        var session = state.SessionState{};
        const tips = [_][]const u8{ "alpha", "beta" };
        const view_state = view(
            &main_menu_state,
            &session,
            .{ .input_bindings = &.{} },
            harness.color_theme_definitions,
            &harness.weapon_type_definitions,
            &tips,
            .{
                .camera = types.Camera{ .position = .{ .x = 0, .y = 0 } },
                .camera_zoom = 1.0,
                .event_history = &.{},
                .level_start_index = null,
                .current_event_index = 0,
                .frame_allocator = arena,
                .font_metrics = font_metrics,
                .sprite_bounds = .{},
                .can_undo = false,
                .can_redo = false,
            },
        );
        const elements = view_state.ui_elements;
        try std.testing.expect(findButton(elements, .open_tips, null) != null);
        try std.testing.expect(findButton(elements, .cycle_tips, .previous) == null);
        try std.testing.expect(findButton(elements, .cycle_tips, .next) == null);
    }

    // Open at index 1: the second tip's text, both nav buttons with
    // opposite payloads, and the two payload-less open_tips buttons in
    // painter order - the panel's Back first (the tips block emits before
    // the global top bar), the top-bar ? last (the bar is the list's
    // final layer).
    {
        var open_state = main_menu_state;
        open_state.ui_surfaces.tips_open = true;
        var session = state.SessionState{};
        session.ui_state.tips_index = 1;
        const tips = [_][]const u8{ "alpha", "beta" };
        const view_state = view(
            &open_state,
            &session,
            .{ .input_bindings = &.{} },
            harness.color_theme_definitions,
            &harness.weapon_type_definitions,
            &tips,
            .{
                .camera = types.Camera{ .position = .{ .x = 0, .y = 0 } },
                .camera_zoom = 1.0,
                .event_history = &.{},
                .level_start_index = null,
                .current_event_index = 0,
                .frame_allocator = arena,
                .font_metrics = font_metrics,
                .sprite_bounds = .{},
                .can_undo = false,
                .can_redo = false,
            },
        );
        const elements = view_state.ui_elements;
        // Two payload-less open_tips buttons: the panel's Back (emitted
        // in the tips block) then the top-bar ? (the bar emits last).
        var open_tips_buttons: usize = 0;
        var first_index: usize = 0;
        var last_index: usize = 0;
        for (elements, 0..) |element, index| {
            if (element == .button and element.button.action == .open_tips and element.button.payload == null) {
                if (open_tips_buttons == 0) first_index = index;
                last_index = index;
                open_tips_buttons += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), open_tips_buttons);
        // The viewed tip's text is present as a label.
        var found_tip_text = false;
        for (elements) |element| {
            if (element == .text_label and std.mem.eql(u8, element.text_label.text, "beta")) {
                found_tip_text = true;
            }
        }
        try std.testing.expect(found_tip_text);
        // The n/N ordinal under the header (index 1 of 2).
        var found_count = false;
        for (elements) |element| {
            if (element == .text_label and std.mem.eql(u8, element.text_label.text, "2/2")) {
                found_count = true;
            }
        }
        try std.testing.expect(found_count);
        // Both nav buttons sit between Back and the top-bar ? (inside the
        // panel's emission range).
        const previous = findButton(elements, .cycle_tips, .previous);
        const next = findButton(elements, .cycle_tips, .next);
        try std.testing.expect(previous != null and next != null);
        try std.testing.expect(first_index < previous.? and previous.? < last_index);
        try std.testing.expect(first_index < next.? and next.? < last_index);
    }

    // Empty tips list: the ? button hides (a modded-but-valid empty
    // file), and an open surface renders no panel content.
    {
        var open_state = main_menu_state;
        open_state.ui_surfaces.tips_open = true;
        var session = state.SessionState{};
        const view_state = view(
            &open_state,
            &session,
            .{ .input_bindings = &.{} },
            harness.color_theme_definitions,
            &harness.weapon_type_definitions,
            &.{},
            .{
                .camera = types.Camera{ .position = .{ .x = 0, .y = 0 } },
                .camera_zoom = 1.0,
                .event_history = &.{},
                .level_start_index = null,
                .current_event_index = 0,
                .frame_allocator = arena,
                .font_metrics = font_metrics,
                .sprite_bounds = .{},
                .can_undo = false,
                .can_redo = false,
            },
        );
        // Empty list: the top-bar ? hides, and the open panel degrades to
        // background + header + Back (no nav buttons - nothing to cycle).
        try std.testing.expect(findButton(view_state.ui_elements, .open_tips, null) != null);
        try std.testing.expect(findButton(view_state.ui_elements, .cycle_tips, .next) == null);
    }
}

test "main menu: credits draws ON TOP of the options menu (painter order)" {
    // Regression: the credits panel used to be emitted in the main-menu
    // branch, BEFORE the screen-independent options menu block - two
    // full-screen panels, so the options menu covered it entirely (the
    // credits flag was logically open; Escape correctly closed credits
    // first, but nothing rendered). The contract: with both up, the
    // options menu's panel + buttons emit FIRST, the credits panel after.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);

    var main_menu_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };
    var session = state.SessionState{};
    main_menu_state.ui_surfaces.options_menu_open = true;
    main_menu_state.ui_surfaces.credits_open = true;

    const view_state = view(
        &main_menu_state,
        &session,
        .{ .input_bindings = &.{} },
        harness.color_theme_definitions,
        &harness.weapon_type_definitions,
        &.{},
        .{
            .camera = types.Camera{ .position = .{ .x = 0, .y = 0 } },
            .camera_zoom = 1.0,
            .event_history = &.{},
            .level_start_index = null,
            .current_event_index = 0,
            .frame_allocator = arena,
            .font_metrics = .{ .base_size = 100, .advances = [_]i32{50} ** 95 },
            .sprite_bounds = .{},
            .can_undo = false,
            .can_redo = false,
        },
    );

    // Both overlays emit exactly one full-screen panel each. The options
    // menu's panel comes first, then its buttons (Exit Game identifies the
    // block), then the credits panel - drawn on top.
    var full_screen_panel_indices: [2]usize = undefined;
    var panel_count: usize = 0;
    var exit_game_index: ?usize = null;
    for (view_state.ui_elements, 0..) |element, index| {
        switch (element) {
            .nine_slice_panel => |panel| {
                const is_full_screen = panel.screen_position.x == 0 and
                    panel.screen_position.y == 0 and
                    panel.width == types.reference_width and
                    panel.height == types.reference_height;
                if (is_full_screen and panel_count < 2) {
                    full_screen_panel_indices[panel_count] = index;
                    panel_count += 1;
                }
            },
            .button => |button| {
                if (button.action == .exit_game and exit_game_index == null) {
                    exit_game_index = index;
                }
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), panel_count);
    try std.testing.expect(exit_game_index != null);
    // options-menu panel < Exit Game button < credits panel (painter order).
    try std.testing.expect(full_screen_panel_indices[0] < exit_game_index.?);
    try std.testing.expect(exit_game_index.? < full_screen_panel_indices[1]);
}

// Z-ORDER CENSUS (DESIGN → Modal overlays → the z-order ladder): two
// forced frames, every reachable overlay flag set at once, asserting the
// surfaces' marker elements emit in the canonical ladder order (painter
// order = draw order). The Escape chain mirrors this ladder topmost-first;
// this census is what keeps the two from drifting apart again - both a
// silent view() reorder and a chain-arm reorder without the emission
// following fail here.
test "z-order census: forced frames emit every overlay surface in the canonical ladder order" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();
    var harness = test_harness.Harness.init(arena);
    const font_metrics = ui.FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    // A non-empty tips list: the tips rung (panel + top-bar `?`) only
    // exists when tips are loaded (the `?` hides for an empty list).
    const census_tips = [_][]const u8{"census tip"};

    // Marker finders: index of the first/last button carrying `action`
    // (LAST for surfaces whose action also appears in a lower surface -
    // the lower one emitted first), the tooltip header label, and the FPS
    // diagnostic label (the ladder's topmost rung).
    const firstButton = struct {
        fn find(elements: []const ui.UiElement, action: types.Action) usize {
            for (elements, 0..) |element, index| {
                if (element == .button and element.button.action == action) return index;
            }
            @panic("census marker button not found");
        }
    }.find;
    const lastButton = struct {
        fn find(elements: []const ui.UiElement, action: types.Action) usize {
            var found: ?usize = null;
            for (elements, 0..) |element, index| {
                if (element == .button and element.button.action == action) found = index;
            }
            return found orelse @panic("census marker button not found");
        }
    }.find;
    const tooltipHeader = struct {
        fn find(elements: []const ui.UiElement, header: []const u8) usize {
            for (elements, 0..) |element, index| {
                if (element == .text_label) {
                    const label = element.text_label;
                    if (label.font_size == ui.tooltip_header_font_size and
                        std.mem.eql(u8, label.text, header)) return index;
                }
            }
            @panic("census tooltip header not found");
        }
    }.find;
    const fpsLabel = struct {
        fn find(elements: []const ui.UiElement) usize {
            for (elements, 0..) |element, index| {
                if (element == .text_label and std.mem.startsWith(u8, element.text_label.text, "FPS")) {
                    return index;
                }
            }
            @panic("census FPS label not found");
        }
    }.find;

    // Both frames hover the top-bar undo button (the tooltip rung) and
    // enable show_fps (the FPS rung).
    const stride = ui.top_bar_slot_size + ui.ui_gap;
    const hover = types.ScreenPosition{
        .x = stride + @divTrunc(ui.top_bar_slot_size, 2),
        .y = @divTrunc(ui.top_bar_height, 2),
    };

    // ── Frame 1: the main menu - every main-menu-reachable surface up.
    // Ladder: base < options menu < load-save browser < credits < tips
    // overlay < settings screen < editor browser < error popup < top bar
    // < tooltip < FPS label.
    {
        var main_menu_state = GameState{
            .screen = .main_menu,
            .event_stack = &.{},
            .player_data = .{},
            .camera = null,
            .editor = null,
            .replay_viewer = null,
            .campaign = null,
            .mission = null,
            .level = null,
            .hub = null,
        };
        var session = state.SessionState{};
        main_menu_state.ui_surfaces.options_menu_open = true;
        main_menu_state.ui_surfaces.load_save_menu_open = true;
        main_menu_state.ui_surfaces.credits_open = true;
        main_menu_state.ui_surfaces.tips_open = true;
        main_menu_state.ui_surfaces.settings_open = true;
        main_menu_state.ui_surfaces.editor_browser_open = true;
        session.setPendingError(arena, "census frame");
        session.input_state.mouse_screen_position = .{ .x = @floatFromInt(hover.x), .y = @floatFromInt(hover.y) };

        const view_state = view(
            &main_menu_state,
            &session,
            .{ .input_bindings = &.{}, .show_fps = true },
            harness.color_theme_definitions,
            &harness.weapon_type_definitions,
            &census_tips,
            .{
                .camera = types.Camera{ .position = .{ .x = 0, .y = 0 } },
                .camera_zoom = 1.0,
                .event_history = &.{},
                .level_start_index = null,
                .current_event_index = 0,
                .frame_allocator = arena,
                .font_metrics = font_metrics,
                .sprite_bounds = .{},
                .can_undo = false,
                .can_redo = false,
            },
        );
        const elements = view_state.ui_elements;
        const main_menu_base = firstButton(elements, .new_game);
        const options_menu = firstButton(elements, .exit_game);
        const load_save_browser = lastButton(elements, .toggle_load_save_menu);
        const credits = lastButton(elements, .open_credits);
        // The tips panel's Back is the FIRST open_tips button (the panel
        // emits before the global top bar, whose `?` is the last).
        const tips_back = firstButton(elements, .open_tips);
        const settings_screen = firstButton(elements, .change_setting);
        const editor_browser = lastButton(elements, .toggle_editor_browser);
        const error_popup = firstButton(elements, .dismiss_error);
        const top_bar = firstButton(elements, .undo);
        const tooltip = tooltipHeader(elements, "Undo");
        const fps = fpsLabel(elements);
        try std.testing.expect(main_menu_base < options_menu);
        try std.testing.expect(options_menu < load_save_browser);
        try std.testing.expect(load_save_browser < credits);
        try std.testing.expect(credits < tips_back);
        try std.testing.expect(tips_back < settings_screen);
        try std.testing.expect(settings_screen < editor_browser);
        try std.testing.expect(editor_browser < error_popup);
        try std.testing.expect(error_popup < top_bar);
        try std.testing.expect(top_bar < tooltip);
        try std.testing.expect(tooltip < fps);
    }

    // ── Frame 2: a level, player dead - every level-reachable surface up.
    // Ladder: bottom bar < options menu < tips overlay < mission-fail <
    // mission-complete < settings screen < editor browser < error popup <
    // top bar < FPS label. (complete above fail is the pinned never-co-rendered order;
    // the load-save browser + credits are main-menu-gated and absent
    // here.)
    {
        const dead_player = types.Entity{
            .team = 0,
            .position = .{ .x = 0, .y = 0 },
            .current_health = 0,
        };
        var level_state = test_harness.levelStateWithEntities(arena, &.{dead_player}, &.{});
        level_state.last_completed_mission = .{ .name = "census mission", .path = "missions/census" };
        var session = state.SessionState{};
        level_state.ui_surfaces.options_menu_open = true;
        level_state.ui_surfaces.tips_open = true;
        level_state.ui_surfaces.settings_open = true;
        level_state.ui_surfaces.editor_browser_open = true;
        session.setPendingError(arena, "census frame");
        session.input_state.mouse_screen_position = .{ .x = @floatFromInt(hover.x), .y = @floatFromInt(hover.y) };

        const view_state = view(
            &level_state,
            &session,
            .{ .input_bindings = &.{}, .show_fps = true },
            harness.color_theme_definitions,
            &harness.weapon_type_definitions,
            &census_tips,
            .{
                .camera = computeCamera(&level_state, 1.0, null, null),
                .camera_zoom = 1.0,
                .event_history = &.{},
                .level_start_index = null,
                .current_event_index = 0,
                .frame_allocator = arena,
                .font_metrics = font_metrics,
                .sprite_bounds = .{},
                .can_undo = false,
                .can_redo = false,
            },
        );
        const elements = view_state.ui_elements;
        const bottom_bar = firstButton(elements, .skip);
        const options_menu = firstButton(elements, .restart_mission);
        const tips_back = firstButton(elements, .open_tips);
        const mission_fail = lastButton(elements, .restart_mission);
        const mission_complete = firstButton(elements, .continue_after_mission);
        const settings_screen = firstButton(elements, .change_setting);
        const editor_browser = lastButton(elements, .toggle_editor_browser);
        const error_popup = firstButton(elements, .dismiss_error);
        const top_bar = firstButton(elements, .undo);
        const fps = fpsLabel(elements);
        try std.testing.expect(bottom_bar < options_menu);
        try std.testing.expect(options_menu < tips_back);
        try std.testing.expect(tips_back < mission_fail);
        try std.testing.expect(mission_fail < mission_complete);
        try std.testing.expect(mission_complete < settings_screen);
        try std.testing.expect(settings_screen < editor_browser);
        try std.testing.expect(editor_browser < error_popup);
        try std.testing.expect(error_popup < top_bar);
        try std.testing.expect(top_bar < fps);
    }
}

test "outlineStripePhase: steps at animation_fps, wraps per cycle" {
    // 8 steps per cycle at 8fps (one step per 125ms).
    try std.testing.expectEqual(0.0, outlineStripePhase(0, 8));
    try std.testing.expectEqual(0.125, outlineStripePhase(125_000, 8));
    try std.testing.expectEqual(0.875, outlineStripePhase(875_000, 8));
    // Wraps: the 8th step restarts the cycle (1s at 8fps).
    try std.testing.expectEqual(0.0, outlineStripePhase(1_000_000, 8));
    // animation_fps 0 falls back to the default 8 (the sheet's convention).
    try std.testing.expectEqual(0.25, outlineStripePhase(250_000, 0));
    // Fractional frames floor to the stepped frame (750ms at 2fps = frame 1).
    try std.testing.expectEqual(0.125, outlineStripePhase(750_000, 2));
}
