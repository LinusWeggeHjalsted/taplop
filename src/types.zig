//! All game data types: entities, levels, hubs, missions, campaigns, player
//! data, gear, items, skills/effects (via generated enums), color themes,
//! input/settings, and the view-state drawables. `Entity` carries the
//! gameplay stat accessors (`getEffective*`, `skillInSlot`, `collectSkillSlots`).
//! See DESIGN → Architecture (player always entity 0, derived-from-entity
//! single source of truth) and Entity & UI Coloring.

const std = @import("std");
const generated = @import("generated");
const build_info = @import("build_info");

pub const SkillId = generated.SkillId;
pub const EffectId = generated.EffectId;

pub const utility_skill_count = 5;

/// One-shot sound effects, one variant per sfx file under `assets/audio/sfx/`.
/// The BASE sounds of layered cues (skill-type bases `*_base`, the item
/// base, the button base pair) and the plain one-shots — see
/// `skillTypeBaseSound` + DESIGN → Audio (layered cues). Pushed onto
/// `SessionState.pending_sounds` (as cue bases) by event handlers (gated
/// `!replaying`) and input handlers, then drained by `frame()` and played
/// via the backend. Music is a stream stack, not a `SoundId`.
pub const SoundId = enum {
    move,
    weapon_base,
    spell_base,
    cantrip_base,
    enchantment_base,
    curse_base,
    item_base,
    damage,
    collision,
    pickup,
    swap_skill,
    button_base_down,
    button_base_up,
    defeat,
    mission_completion,
    heal,
    stun,
    knockback,
    retreat,
    death,
    level_complete,
    aggro,
};

/// Upper bound on probed music intensity layers (a pathological-dir guard —
/// probing stops at the first missing file long before this in practice).
/// Shared by the backend's probe loop + the sound-report tool. See DESIGN →
/// Audio (layered music).
pub const max_music_layers: usize = 16;

/// The item-action layer keys (see `SoundLayer.item`): one per item-action
/// event handler that queues an item cue. Tag names are the file stems at
/// `assets/audio/sfx/items/<tag>_layer`.
pub const ItemActionSound = enum {
    equip,
    salvage,
    learn_skill,
};

/// The specific half of a layered cue (the LAYER, resolved to a file by
/// enum key): skill layers at `assets/audio/sfx/skills/<id>_layer.ogg`,
/// action layers at `assets/audio/sfx/buttons/<action>_layer.ogg`, item
/// layers at `assets/audio/sfx/items/<tag>_layer.ogg` (`.wav` accepted —
/// see FileSource.readAudioFile). A missing layer file plays NOTHING — no
/// placeholder, no fallback; silence IS the "not authored yet" signal for
/// the sound designer. Whether the base is percussive and the layer
/// ambient (or the reverse) is a per-file authoring choice — the names are
/// deliberately neutral. See DESIGN → Audio (layered cues).
pub const SoundLayer = union(enum) {
    skill: SkillId,
    action: Action,
    /// Item-action layer (equip / salvage / learn_skill), keyed by
    /// `ItemActionSound`. The cue's base is the shared `item_base`.
    item: ItemActionSound,
};

/// One queued sound cue: a category BASE layer plus an optional specific
/// LAYER, played simultaneously. Plain one-shots (damage, move, ...) are
/// base-only cues; skill casts, button releases, and item actions layer
/// their specific sound over the base. Layer mix balance is baked into
/// the asset files, not expressed here. A missing base or layer file is
/// SILENT — no fallbacks anywhere, so silence always means "asset not
/// authored yet" (the report tool lists every path; see
/// scripts/sound_report.sh). See DESIGN → Audio (layered cues).
pub const SoundCue = struct {
    base: ?SoundId = null,
    layer: ?SoundLayer = null,
};

pub const Vector2 = struct {
    x: i32,
    y: i32,
};

/// The fixed sprite frame EVERY entity sprite shares (bodies, layers,
/// weapons): 512x640 source pixels, normalized pivot (0.5, 0.8). One tile
/// is 256px. Custom entity art MUST be exactly this size — the render-side
/// gate (`customSpriteDimsPassGate`) magentas non-conforming art (see
/// DESIGN → Custom Missions & Online Services → Custom-asset dimensions).
pub const entity_sprite_frame_width: i32 = 512;
pub const entity_sprite_frame_height: i32 = 640;

/// Entity art spec: exactly the fixed 512x640 frame.
pub fn entitySpriteDimsConform(dims: Vector2) bool {
    return dims.x == entity_sprite_frame_width and dims.y == entity_sprite_frame_height;
}

/// Decoration art spec: whole multiples of 256 in both axes (the view
/// math chunks one 256px piece per bbox tile), strictly positive.
pub fn decorationSpriteDimsConform(dims: Vector2) bool {
    return dims.x > 0 and dims.y > 0 and @rem(dims.x, 256) == 0 and @rem(dims.y, 256) == 0;
}

/// The mission directory's NAME (the last path segment) — the namespace
/// for mission-local sprite ids (`custom/<mission-dir>/<stem>`). The id
/// convention's own helper: the scan mints the ids (mission_io), the
/// picker + the load side read them back.
pub fn missionDirectoryName(mission_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, mission_path, '/')) |slash| {
        return mission_path[slash + 1 ..];
    }
    return mission_path;
}

/// The render-side custom-art gate: does this sprite id's kind accept these
/// pixel dims? Custom (mission-bundled) art must follow the shipped asset
/// structure — entity sprites exactly the fixed 512x640 frame, decoration
/// sprites whole multiples of 256 in both axes. A false return makes the
/// texture store treat the sprite as missing (the magenta fallback):
/// off-grid art is never silently rendered — the load side already warned
/// + degraded the geometry (loaders.zig). Non-custom ids are never gated
/// (shipped art is certified by the build-time metadata table; other
/// prefixes — ui/, world/, items/ — follow their own conventions).
pub fn customSpriteDimsPassGate(sprite_id: []const u8, dims: Vector2) bool {
    if (std.mem.startsWith(u8, sprite_id, "entities/custom/")) {
        return entitySpriteDimsConform(dims);
    }
    if (std.mem.startsWith(u8, sprite_id, "decorations/custom/")) {
        return decorationSpriteDimsConform(dims);
    }
    return true;
}

test "customSpriteDimsPassGate: entity art must be exactly 512x640" {
    const conforming = Vector2{ .x = entity_sprite_frame_width, .y = entity_sprite_frame_height };
    try std.testing.expect(customSpriteDimsPassGate("entities/custom/mission/hero", conforming));
    // Wrong dims in either axis → gated (magenta).
    try std.testing.expect(!customSpriteDimsPassGate("entities/custom/mission/hero", .{ .x = 512, .y = 641 }));
    try std.testing.expect(!customSpriteDimsPassGate("entities/custom/mission/hero", .{ .x = 256, .y = 640 }));
}

test "customSpriteDimsPassGate: decoration art must be whole multiples of 256" {
    try std.testing.expect(customSpriteDimsPassGate("decorations/custom/mission/tree", .{ .x = 768, .y = 768 }));
    // Huge art passes (no size cap — the >4096 warning at load is advisory).
    try std.testing.expect(customSpriteDimsPassGate("decorations/custom/mission/tree", .{ .x = 8192, .y = 256 }));
    // Non-multiples, zero/negative dims → gated.
    try std.testing.expect(!customSpriteDimsPassGate("decorations/custom/mission/tree", .{ .x = 1000, .y = 1024 }));
    try std.testing.expect(!customSpriteDimsPassGate("decorations/custom/mission/tree", .{ .x = 250, .y = 256 }));
    try std.testing.expect(!customSpriteDimsPassGate("decorations/custom/mission/tree", .{ .x = 0, .y = 256 }));
}

test "customSpriteDimsPassGate: non-custom ids are never gated" {
    // Shipped world art (the tile source is not a multiple of 256), UI
    // icons (128x128), and every other prefix pass untouched — the gate is
    // scoped to custom art only.
    try std.testing.expect(customSpriteDimsPassGate("world/tile", .{ .x = 600, .y = 600 }));
    try std.testing.expect(customSpriteDimsPassGate("ui/icon_gear", .{ .x = 128, .y = 128 }));
    try std.testing.expect(customSpriteDimsPassGate("entities/skeleton_1", .{ .x = 123, .y = 45 }));
    try std.testing.expect(customSpriteDimsPassGate("custom/mission/tree", .{ .x = 123, .y = 45 }));
}

pub const Action = enum {
    undo,
    redo,
    /// Escape. Generic "close topmost overlay": closes the settings overlay,
    /// load-save browser, credits, world map / full combat log, or the
    /// options menu (whichever is topmost); on mission fail / mission
    /// complete it fires the overlay's primary button (exit mission /
    /// continue); with nothing open it opens the options menu (any screen —
    /// the main-menu variant carries its own content). Named for the key
    /// behavior, not the menu: the chain (see
    /// DESIGN → Input → Escape overlay chain) is the action's whole
    /// meaning. Previously `toggle_options_menu`; installs with a user
    /// settings.txt naming the old action warn + drop it at load and pick
    /// up this action's default binding.
    escape,
    toggle_inventory,
    toggle_gear,
    toggle_skills,
    toggle_entity_inspect,
    toggle_world_map,
    confirm,
    cancel,
    skip,
    skill_slot_1,
    skill_slot_2,
    skill_slot_3,
    skill_slot_4,
    skill_slot_5,
    skill_slot_6,
    skill_slot_7,
    skill_slot_8,
    swap_weapons,
    // Tile-cursor nudging (arrow keys; see session.tile_cursor resolution).
    // When the mouse is idle, these move the logical cursor one tile. If the
    // cursor is null, it snaps to the player's tile before nudging.
    move_cursor_up,
    move_cursor_down,
    move_cursor_left,
    move_cursor_right,
    // Dump the full session event history to a config-format log file (dev
    // tooling; see session_log.writeEventLog). Anytime, side-effecting.
    dump_event_log,
    // Dismiss a recoverable error popup (see SessionState.pending_error).
    // Modal — when a pending error is shown, this is the only action that
    // reaches the game; all other input is swallowed until the popup is
    // dismissed. Bound to Escape + Enter so either key clears it.
    dismiss_error,
    // Scroll the error popup body (arrow keys, 3 lines per press; the
    // mouse wheel also scrolls it — one line per notch — via a redirect in
    // the modal input gate). Only consumed while a pending error is shown.
    // Bound to the same Up/Down keys as the tile-cursor nudge — the
    // binding contexts resolve the pair (error_popup context is active
    // only while the popup is up, so the cursor binding never co-fires;
    // see DESIGN → Input → Binding contexts). See DESIGN → Error Handling.
    error_scroll_up,
    error_scroll_down,
    // Camera zoom (keyboard shortcuts; the mouse wheel also zooms via
    // scroll_delta). PgDn = zoom in, PgUp = zoom out (up = the camera moves
    // away from the scene), ctrl+0 = reset to 1.0. Letters/digits are
    // layout-stable (physical key positions), unlike the +/- symbol keys
    // whose raylib tokens are layout-labeled and degrade on ISO layouts.
    // See DESIGN → Input.
    zoom_in,
    zoom_out,
    zoom_reset,
    // Options menu commands (context-specific: hub vs level).
    save_game,
    // Save the edited mission to the persistent dir (the editor options
    // menu's Save Mission button + the ctrl+S binding). A pure side effect
    // — the dump_event_log class, not the save_game class: there is no
    // GameState component to record, so it pushes no event and takes no
    // undo step. See editor/mission_io.zig's saveEditorMission.
    save_editor_mission,
    // Export the edited mission as a .zip (the editor options menu's
    // Export Mission button — button-only, no keybind). Same side-effect
    // class; saves first, then bundles. See
    // editor/mission_io.zig's exportEditorMission.
    export_editor_mission,
    restart_mission,
    exit_mission,
    exit_to_menu,
    /// Quit the application (the main-menu options menu's Exit Game button,
    /// native-only — never emitted on web, where closing the tab is the
    /// user's). Button-only: no binding ships; the handler's screen gate is
    /// the defensive half for a future keybind.
    exit_game,
    // Mission-complete overlay commands.
    continue_after_mission,
    replay_mission,
    overwrite_clone,
    // The validation stats screen's manual Overwrite Replay button — writes
    // the stashed slower-run replay bytes over the personal best (a
    // session-side side effect, no recorded event). See DESIGN → Custom
    // Missions & Online Services → Validation replay.
    overwrite_validation_replay,
    // Dev tool: skip the current level (pushes end_level with the default
    // continuation — next level or mission-end). Bound to ctrl+Enter; gated
    // to dev builds via `@import("build_info").dev_mode` at the handler site,
    // so the binding in default_settings.txt is a no-op in release/web builds.
    // See DESIGN → Input + AGENTS → Dev Tools.
    skip_level,
    // Main menu commands.
    continue_game,
    new_game,
    // Opens/closes the load-save browser (main-menu "Load Save" + the
    // browser's Back button).
    toggle_load_save_menu,
    // A save row in the load-save browser. The row index rides the click
    // payload (the `save_row` variant, set at the release-dispatch site —
    // Action alone can't carry a payload).
    load_save_row,
    // Load-save browser's "Import External Save" (web only): opens a file
    // picker; the picked file lands in saves/ and loads. Native builds never
    // emit the button (drop files into the persistent saves/ dir by hand).
    import_save,
    open_settings,
    open_credits,
    // A settings toggle or choice button was clicked. The SettingRef (which
    // field + which value) rides the click payload (the `setting` variant). See
    // DESIGN → UI Framework → Settings screen.
    change_setting,
    // A keybinds-tab edit command was clicked (rekey / reassign / add /
    // remove / pick / confirm / cancel / reset — the whole editing UI
    // rides ONE action + the `KeybindCommand` payload in
    // the click payload (the `keybind_command` variant)). See DESIGN → UI Framework →
    // Settings screen (the Keybinds tab editing flows).
    edit_keybind,
    // A settings screen tab button was clicked (Settings / Keybinds). The
    // tab rides the click payload (the `settings_tab` variant). Routed through
    // `options_action` (the settings screen is reachable from the main
    // menu AND the in-game options menu). See DESIGN → UI Framework →
    // Settings screen.
    select_settings_tab,
    // An editor palette group header was clicked (expand/collapse the
    // group). The group index rides the click payload (the `editor_group` variant).
    // Routed through `options_action` so one handler serves it regardless
    // of screen state. See DESIGN → Architecture → Level Editor → Editor
    // UI layout (tool palette).
    toggle_editor_palette_group,
    // An editor palette group's "+" cell was clicked (add a new type to
    // that group, built from the shipped defaults). The group index rides
    // the click payload (the `editor_group` variant) — the same variant as
    // the group-header toggle. See DESIGN → Architecture → Level Editor →
    // Editor UI layout (tool palette).
    add_editor_palette_type,
    // An editor palette tool cell's delete button (the small close-button
    // in the cell's top-right corner) was clicked: delete that palette
    // type + every placement referencing it across all levels. The
    // EditorToolId rides the click payload (the `editor_tool` variant) — the same
    // payload field as the tool cells. See DESIGN → Architecture → Level
    // Editor → Editor UI layout (tool palette).
    delete_editor_palette_type,
    // The top-bar add-level "+" (right of the level tabs) was clicked:
    // append a new level from the shipped template (data/default_level.txt)
    // and switch to it. No payload — the template is fixed shipped content.
    add_editor_level,
    // A level tab's × button was clicked: delete that level (gated on more
    // than one — a mission always keeps ≥1; the button isn't offered on a
    // single-level mission). The level index rides in
    // the click payload (the `editor_level` variant) — the same payload field as the
    // tab itself.
    delete_editor_level,
    // An editor tool cell was clicked (make it the active tool). The
    // EditorToolId rides the click payload (the `editor_tool` variant). See DESIGN
    // → Architecture → Level Editor (active-tool model).
    select_editor_tool,
    // An editor level-tab was clicked (make that level active). The level
    // index rides the click payload (the `editor_level` variant). Routed through
    // `options_action` like the other payload-carrying editor clicks. See
    // DESIGN → Architecture → Level Editor → Editor UI layout (tabs).
    select_editor_level,
    // The editor's inspector toggle button (top-left, below options): flip
    // the inspector sidebar open/closed. The open flag lives on the Editor
    // (GameState) via `player_toggle_editor_inspector` →
    // `editor_toggle_inspector`, so it rides the undo timeline. See DESIGN
    // → Architecture → Level Editor → Editor UI layout (inspector).
    toggle_editor_inspector,
    // The editor's settings-sidebar toggle button (top-right, at the
    // inspector toggle's height, flush to the right screen edge): flip the
    // metadata sidebar open/closed. Same convention as the inspector
    // toggle — the flag lives on the Editor via
    // `player_toggle_editor_metadata_sidebar` →
    // `editor_toggle_metadata_sidebar` (undo timeline + replay).
    toggle_editor_metadata_sidebar,
    // The top-bar Test button (top-right corner, the options/undo icon
    // class): start a single-level playtest of the ACTIVE level. Pushes
    // `player_start_playtest` → `start_playtest` (the machinery handler
    // owns instantiation + dormancy + the transition); `end_level`'s
    // editor guard returns to the editor. See DESIGN → Architecture →
    // Level Editor → Editor UI layout (primary actions).
    test_editor_level,
    // The top-bar Validate button (right of Test): save the mission, then
    // start a full-mission validation run of the SAVED dir. Pushes
    // `player_start_validation{mission_path}` → `start_validation` (which
    // reads the files — the run certifies the artifact, not the editor
    // memory); completing the last level (or any restart/exit continuation)
    // ends the run back in the editor. See DESIGN → Level Editor
    // (playtest/validate framing).
    validate_editor_mission,
    // The options-menu Revalidate Mission button (editor screen only):
    // re-certify the stored validation replay against the current saved
    // content — the recorded run is replayed in checking mode against the
    // files as they are now, and on success the replay is re-bound to the
    // new content hash. Pushes `player_revalidate_mission{mission_path}`
    // (the consumption site saves first, the Validate contract). See
    // DESIGN → Custom Missions & Online Services → Validation replay.
    revalidate_editor_mission,
    // A settings-sidebar gradient swatch (world / enemy / player row):
    // open the centered theme picker for that role. The role rides in
    // the click payload (the `editor_gradient_role` variant); the picker target
    // snapshots the active level index (a mid-edit tab switch can't
    // retarget the pick).
    open_editor_level_gradient_picker,
    // A theme-picker gradient row: set the level's index for the picker's
    // role. The gradient index rides in
    // the click payload (the `editor_gradient` variant). For enemy/player, a pick
    // while on auto flips that role to manual in the same commit.
    select_editor_level_gradient,
    // An enemy/player gradient row's AUTO button: revert that role to
    // auto-derivation (commits the null override). A no-op while already
    // auto (same-value picks never fire). The role rides in
    // the click payload (the `editor_gradient_role` variant).
    toggle_editor_level_gradient_auto,
    // An inspector section header (expand/collapse that section). The
    // section id rides the click payload (the `editor_section` variant) — a
    // direct UiState write (view affordance, off the undo timeline, like
    // the palette accordion).
    toggle_editor_inspector_section,
    // The inspector's Sprite row (enemy identity): open the centered
    // sprite picker for the base sprite. The mission-local scan happens
    // at this site (idle input — interactive IO lives here, never in the
    // view or handlers).
    open_editor_sprite_picker,
    // A sprite picker cell: set the edited entity type's base sprite (the
    // stem rode the click payload (the `editor_sprite` variant)) and close the
    // picker. Same-value picks close without recording.
    select_editor_entity_sprite,
    // The decoration picker's cell: adopt the picked prefab (official tab)
    // or custom stem (mission tab) into the edited decoration type — see
    // `editor_set_decoration_def`. The stem rode in
    // the click payload (the `editor_sprite` variant). Same-value picks close without
    // recording.
    select_editor_decoration_sprite,
    // A sprite picker tab button (Mission / Official): switch the picker's
    // tab. The tab rode the click payload (the `editor_sprite_tab` variant) — a
    // direct UiState write (view affordance).
    select_editor_sprite_tab,
    // The player inspector's Import button: copy the session's player
    // data (or, with none, the new-game default save) into the editor
    // player loadout. No payload — the handler reads live state.
    import_editor_player,
    // The player inspector's Max player Import button: load the shipped
    // data/max_player.txt into the editor player loadout (the author-times
    // tool for official missions). No payload.
    import_editor_max_player,
    // An inspector color swatch was clicked (set the edited entity type's
    // color_index — the gradient index into the enemy gradient). The index
    // rides the click payload (the `editor_color` variant). Routed through
    // `options_action` like the other payload-carrying editor clicks.
    select_editor_entity_color,
    // The decoration inspector's color swatch was clicked (set the edited
    // decoration type's color_index — the gradient index into the WORLD
    // gradient). The index rides the click payload (the `editor_color` variant).
    select_editor_decoration_color,
    // The Layers sections' controls (enemy + decoration types). The layer
    // index rides the click payload (the `editor_layer` variant — null on
    // the add-layer button, the picker's add mode).
    open_editor_entity_layer_picker,
    open_editor_decoration_layer_picker,
    // A layer-picker cell: the stem rode in
    // the click payload (the `editor_sprite` variant); the layer identity (add vs
    // edit index) rides in the open picker's target on the Editor
    select_editor_entity_layer,
    select_editor_decoration_layer,
    delete_editor_entity_layer,
    delete_editor_decoration_layer,
    select_editor_entity_layer_color,
    select_editor_decoration_layer_color,
    // The decoration inspector's Footprint row: open the centered
    // footprint editor (the tile-grid picker over the full-size sprite).
    // No payload — the edited type resolves from the inspector target.
    open_editor_footprint_picker,
    // A footprint-editor tile cell: toggle that sprite-grid tile in/out
    // of the draft footprint. The grid cell index (row-major) rode in
    // the click payload (the `editor_footprint_tile` variant) — a direct UiState
    // write (the draft is transient view state, off the undo timeline).
    toggle_editor_footprint_tile,
    // The footprint editor's Confirm button: close the picker and commit
    // the draft IF it differs (an unchanged draft closes without
    // recording; an empty draft stays open — a footprint needs ≥1 tile).
    confirm_editor_footprint,
    // The inspector's displays-weapons toggle (flip the edited entity
    // type's flag). No payload — the handler reads + flips live state.
    toggle_editor_entity_displays_weapons,
    toggle_editor_entity_keep_original_colors,
    toggle_editor_decoration_keep_original_colors,
    // The inspector's per-layer draw-side toggle (decoration layers): flip
    // the layer's `behind` flag (back layers draw before the base). The
    // layer index rides the click payload (the `editor_layer` variant).
    toggle_editor_decoration_layer_behind,
    // An inspector weapon-type cell was clicked (create the slot's weapon
    // while empty, or retype in place keeping name/damage). The hand
    // (`GearSlot`, main/off) + the type ride the click payload together
    // (one compound `editor_weapon_type_cell` variant).
    select_editor_weapon_type,
    // The inspector's gear Add button (create a default item in the empty
    // slot — the slot rides the click payload (the `editor_gear_slot` variant)).
    add_editor_item,
    // The inspector's item Delete button (clear the slot to null — the
    // slot rides the click payload (the `editor_gear_slot` variant)).
    delete_editor_item,
    // An inspector item-TYPE cell was clicked (the Items group's content:
    // the two type-pick rows). Any pick that differs from the current
    // item RESETS it to a "New <Kind>" default with zeroed stats — no
    // retype-keeps-identity case (author decision); an identical pick
    // never fires. The kind (+ the weapon type on weapon cells) rides the
    // click payload (the `editor_item_kind_cell` variant).
    select_editor_item_type,
    // An inventory slot cell in the player inspector's Inventory section
    // was clicked (select it — the detail rows insert below its slot row;
    // clicking the already-selected slot deselects). The slot index rides
    // the click payload (the `editor_inventory_slot` variant).
    select_editor_inventory_slot,
    // The inspector's inventory-slot Add button (create the default
    // sword — the slot index rides in
    // the click payload (the `editor_inventory_slot` variant)).
    add_editor_inventory_item,
    // The inspector's inventory-slot Delete button (clear the slot to
    // null — the slot index rides in
    // the click payload (the `editor_inventory_slot` variant)).
    delete_editor_inventory_item,
    // An inventory-slot item-TYPE cell was clicked (the detail block's
    // type-pick rows): same reset-everything semantics as
    // `select_editor_item_type`, targeting the SELECTED slot's item
    // (an empty slot has no type rows — the arm gates on occupied).
    select_editor_inventory_item_type,
    // An inspector utility-slot button was clicked (open the centered
    // skill picker for that slot). The slot index rides in
    // the click payload (the `editor_utility_slot` variant).
    open_editor_skill_picker,
    // The skill picker's close button (top-right, the middle-panel
    // convention). No payload.
    close_editor_picker,
    // A skill picker cell was clicked (assign to the picker's slot). The
    // skill rides the click payload (the `editor_skill` variant); the None cell
    // carries no payload (clears the slot). Only UTILITY skills are
    // offered — see src/utility_skills.zig.
    select_editor_utility_skill,
    // Delete the select tool's current selection (editor viewport, Delete
    // key). Fans out into the per-entry delete events via
    // `player_delete_editor_selection`; consumed in handleIdleInput's
    // editor arm — a no-op on every other screen (the binding ships in
    // default_settings.txt regardless, like `skip_level`). The '!' / '='
    // and the tiles under them are never deleted.
    delete_editor_selection,
    // Clear the select tool's current selection (editor viewport, ctrl+D).
    // Pushes `player_clear_editor_selection` → `editor_clear_selection` —
    // a single event (a clear is one operation, not a per-entry fan-out:
    // a 100-entry marquee clearing as 100 deselect lines is log noise).
    // Consumed in handleIdleInput's editor arm, gated on a nonempty
    // selection — a no-op on every other screen.
    clear_editor_selection,
    // Select everything in the editor's active level (editor viewport,
    // ctrl+A). Pushes `player_select_editor_all` → a batch of granular
    // `editor_select` adds sharing one idle point (one undo step),
    // skipping entries already selected — an all-selected level is a
    // no-op. Consumed in handleIdleInput's editor arm, gated on the
    // select tool active — a no-op on every other screen.
    select_editor_all,
    // Opens/closes the editor browser — the tabbed full-screen modal
    // (one tab per editor kind, default Mission) that owns browsing AND
    // creating editor content. Emitters: the main-menu Editor button, the
    // browser's Back button, the editor options-menu Open Mission button,
    // and the ctrl+O binding (editor context — the keybind path stays
    // editor-scoped; the button path also works from the main menu, where
    // the consumption site accepts both screens). See DESIGN →
    // Architecture → Level Editor → The editor browser.
    toggle_editor_browser,
    // A mission-list TAB button was clicked (Your Missions / Official —
    // the active kind's content tab). The tab rides in
    // the click payload (the `editor_mission_tab` variant). Routed through
    // `options_action` so it works while the browser is open over the
    // options menu.
    select_editor_mission_tab,
    // An editor-browser KIND tab was clicked (Mission today; Hub /
    // Campaign when those editors land) — switches the browser's content
    // to that editor kind. The kind rides in
    // the click payload (the `editor_kind` variant). Same options_action routing as
    // the mission-list tabs.
    select_editor_kind_tab,
    // A mission-browser ROW was clicked (open that mission in the editor,
    // replacing the one being edited — no unsaved-changes confirm by
    // design). The row index rides the click payload (the `editor_mission_row` variant)
    // (an index into the CURRENT tab's list; the tab is read from UiState at
    // resolution). Pushes `open_editor` with the row's mission path.
    open_editor_mission_row,
    // The mission browser's "Import" (web only): opens a file picker for a
    // mission .zip; the picked zip lands in imported_missions/ and the Zig
    // side extracts it into missions/ (see
    // editor/mission_io.zig's pollMissionImportMarker). Also on ctrl+I (the binding
    // ships in default_settings.txt and no-ops on native, where the button
    // is never emitted — the skip_level discipline).
    import_editor_mission,
    // The fresh-mission open (the editor browser's New Mission button, the
    // options-menu New Mission button, and the ctrl+N binding): pushes
    // `open_editor` with a null path — a fresh one-level template mission
    // from the main menu or a from-inside-the-editor replacement of the
    // mission being edited (no unsaved-changes confirm — the
    // editor-browser-row discipline). The consumption site accepts the
    // editor + main-menu screens (the toggle_editor_browser discipline).
    new_editor_mission,
    // Editor tool/palette keyboard shortcuts (Digit1–5, context editor —
    // the first same-combo cross-context pair: Digit1–8 are the in-game
    // skill slots). Payload-less keybind-only actions: `translateInput`
    // bridges them onto the click paths' `options_action` + payload pairs
    // (select_editor_tool + the `editor_tool` variant /
    // toggle_editor_palette_group + the `editor_group` variant), so keybind and
    // click share consumption sites exactly — the tool switch rides the
    // undo timeline via `player_set_editor_tool` (same-value = no-op), the
    // group toggle is the accordion UiState write. No button carries these
    // (the palette cells use the payload-carrying click actions).
    editor_select_tool,
    editor_tile_tool,
    toggle_editor_entity_group,
    toggle_editor_decoration_group,
    toggle_editor_item_group,
};

/// One per editable `Settings` scalar field. Drives the settings-screen
/// control→field binding (see DESIGN → UI Framework → Settings screen).
pub const SettingId = enum {
    master_volume,
    music_volume,
    sound_effects_volume,
    vsync,
    render_fps_cap,
    camera_zoom,
    animation_fps,
    render_resolution,
    auto_skip_attack_step_out_of_combat,
    auto_target_at_cursor,
    show_fps,
    player_color_index,
};

/// Carried on a settings control `Button` so the input handler knows which
/// field to mutate and how. For toggles, `choice_value` is null (the
/// handler flips the bool). For choices, `choice_value` is the value this
/// button represents (e.g. camera_zoom 50, player_color_index 3). Sliders
/// carry the id only and handle their own drag state (slice 3b).
pub const SettingRef = struct {
    id: SettingId,
    choice_value: ?u32 = null,
};

/// The context-specific sound an action plays on button release, if any.
/// Actions without a specific sound use the generic `button_click_up`.
/// Press-down is always `button_click_down` regardless of action. See
/// DESIGN → Audio.
/// The base layer of a skill cue, by skill type. The dedicated
/// cantrip/enchantment/curse base FILES may not have shipped yet — the
/// backend's `soundFallback` chain plays `spell` in their place until they
/// do, so this mapping always names the eventual base, never the
/// placeholder. See DESIGN → Audio (layered cues).
pub fn skillTypeBaseSound(skill_type: SkillType) SoundId {
    return switch (skill_type) {
        .weapon_skill => .weapon_base,
        .spell => .spell_base,
        .cantrip => .cantrip_base,
        .enchantment => .enchantment_base,
        .curse => .curse_base,
    };
}

/// Whether `action` is one of the eight skill-slot actions. The release
/// seam suppresses the base up for these: auto-fire plays the full skill
/// cue from the use_skill event (which subsumes any button sound), and the
/// prepare path plays its own up base at the consumption site. See DESIGN
/// → Audio (layered cues).
pub fn actionIsSkillSlot(action: Action) bool {
    return switch (action) {
        .skill_slot_1, .skill_slot_2, .skill_slot_3, .skill_slot_4, .skill_slot_5, .skill_slot_6, .skill_slot_7, .skill_slot_8 => true,
        else => false,
    };
}

/// Actions with NO action-layer sound BY DESIGN: the input dispatch's
/// sound choke point (input_handlers.dispatchFiredActionSounds) skips them,
/// and the sound report excludes their layer files from the shopping list
/// (a dropped file would not play). The reasons: the zoom + cursor keys (the
/// wheel/mouse paths carry no sound; keys shouldn't be noisier),
/// error-scroll ticks, `dump_event_log` + `skip_level` (dev tools), and
/// `confirm` (the simulated tile click plays the move/skill sounds
/// instead).
pub fn actionSoundUnwired(action: Action) bool {
    return switch (action) {
        .zoom_in,
        .zoom_out,
        .zoom_reset,
        .move_cursor_up,
        .move_cursor_down,
        .move_cursor_left,
        .move_cursor_right,
        .error_scroll_up,
        .error_scroll_down,
        .dump_event_log,
        .skip_level,
        .confirm,
        => true,
        else => false,
    };
}

/// Raw input identifier — uses human-readable strings so config files
/// are legible and editable. Key codes follow the W3C KeyboardEvent.code
/// spec (e.g. "KeyA", "Space", "ShiftLeft"). Mouse buttons are "left",
/// "right", "middle". Gamepad buttons follow the Gamepad API names.
pub const RawInput = union(enum) {
    key: []const u8,
    mouse_button: []const u8,
    gamepad_button: []const u8,
};

/// Every key id the platform backend's key table can produce (the W3C
/// KeyboardEvent.code names — `src/raylib/input_poll.zig` maps every
/// raylib-reported key to one of these). A comptime cross-check there
/// keeps this list and the table in lockstep (both directions — a table id
/// missing here, or a list entry with no table row, is a compile error).
/// `loadSettings` warns (advisively — the entry is kept) when a binding
/// names an id outside this set: nothing can ever produce it, so the
/// binding can never fire (the dead-binding class the missing-Escape
/// regression exposed — see DONE.md). The initial list was generated from
/// the table (machine-walked), not hand-copied.
pub const producible_key_ids = [_][]const u8{
    "ControlLeft",  "ControlRight",   "ShiftLeft",      "ShiftRight",      "AltLeft",     "AltRight",
    "KeyA",         "KeyB",           "KeyC",           "KeyD",            "KeyE",        "KeyF",
    "KeyG",         "KeyH",           "KeyI",           "KeyJ",            "KeyK",        "KeyL",
    "KeyM",         "KeyN",           "KeyO",           "KeyP",            "KeyQ",        "KeyR",
    "KeyS",         "KeyT",           "KeyU",           "KeyV",            "KeyW",        "KeyX",
    "KeyY",         "KeyZ",           "Digit0",         "Digit1",          "Digit2",      "Digit3",
    "Digit4",       "Digit5",         "Digit6",         "Digit7",          "Digit8",      "Digit9",
    "Quote",        "Comma",          "Minus",          "Period",          "Slash",       "Semicolon",
    "Equal",        "BracketLeft",    "Backslash",      "BracketRight",    "Backquote",   "Space",
    "Escape",       "Enter",          "Tab",            "Backspace",       "Insert",      "Delete",
    "ArrowUp",      "ArrowDown",      "ArrowLeft",      "ArrowRight",      "PageUp",      "PageDown",
    "Home",         "End",            "CapsLock",       "ScrollLock",      "NumLock",     "PrintScreen",
    "Pause",        "F1",             "F2",             "F3",              "F4",          "F5",
    "F6",           "F7",             "F8",             "F9",              "F10",         "F11",
    "F12",          "Numpad0",        "Numpad1",        "Numpad2",         "Numpad3",     "Numpad4",
    "Numpad5",      "Numpad6",        "Numpad7",        "Numpad8",         "Numpad9",     "NumpadDecimal",
    "NumpadDivide", "NumpadMultiply", "NumpadSubtract", "NumpadAdd",       "NumpadEnter", "NumpadEqual",
    "ContextMenu",  "BrowserBack",    "AudioVolumeUp",  "AudioVolumeDown",
};

/// Every mouse button id the backend's mouse table can produce. Gamepad
/// ids appear here when a gamepad table lands (until then a gamepad binding
/// warns as unproducible — nothing can produce it).
pub const producible_mouse_ids = [_][]const u8{ "left", "right", "middle" };

/// True if `input` names an id the backend tables can produce (the binding
/// CAN fire). False = a dead binding (warned at load, kept — the id may be
/// valid on another platform or a future table; see `producible_key_ids`).
pub fn inputIdProducible(input: RawInput) bool {
    const ids = switch (input) {
        .key => producible_key_ids[0..],
        .mouse_button => producible_mouse_ids[0..],
        // No gamepad table exists yet — no gamepad id is producible.
        .gamepad_button => return false,
    };
    const id = switch (input) {
        .key => |name| name,
        .mouse_button => |name| name,
        .gamepad_button => |name| name,
    };
    for (ids) |producible_id| {
        if (std.mem.eql(u8, id, producible_id)) return true;
    }
    return false;
}

test "inputIdProducible: the backend tables' id sets, per input kind" {
    // Every W3C key id is producible; a typo'd id is not; mouse ids are
    // producible as mouse only (a key binding naming "left" is dead — the
    // check is per-variant); no gamepad table exists yet.
    try std.testing.expect(inputIdProducible(.{ .key = "KeyZ" }));
    try std.testing.expect(inputIdProducible(.{ .key = "Escape" }));
    try std.testing.expect(!inputIdProducible(.{ .key = "Escapee" }));
    try std.testing.expect(inputIdProducible(.{ .mouse_button = "left" }));
    try std.testing.expect(!inputIdProducible(.{ .key = "left" }));
    try std.testing.expect(!inputIdProducible(.{ .gamepad_button = "a" }));
}

/// True if two `RawInput`s name the same physical input (same variant +
/// id string). The combo-equality half of the binding-conflict predicate
/// (same input + same modifiers = same combo) — see `sameCombo`.
pub fn rawInputsEqual(a: RawInput, b: RawInput) bool {
    return switch (a) {
        .key => |a_key| switch (b) {
            .key => |b_key| std.mem.eql(u8, a_key, b_key),
            else => false,
        },
        .mouse_button => |a_button| switch (b) {
            .mouse_button => |b_button| std.mem.eql(u8, a_button, b_button),
            else => false,
        },
        .gamepad_button => |a_button| switch (b) {
            .gamepad_button => |b_button| std.mem.eql(u8, a_button, b_button),
            else => false,
        },
    };
}

/// True if two `InputBinding`s occupy the same key combo (same input +
/// same required modifiers). The conflict predicate pairs this with
/// `BindingContextSet.intersects` over the two actions' derived contexts:
/// same combo + different actions + intersecting contexts = a conflict
/// (they would co-fire). Used at load (`loadSettings` warns + drops) and
/// by the keybind UI's steal warning. See DESIGN → Input → Hybrid
/// precedence + binding conflicts.
pub fn sameCombo(a: InputBinding, b: InputBinding) bool {
    if (!rawInputsEqual(a.input, b.input)) return false;
    return a.modifiers.ctrl == b.modifiers.ctrl and
        a.modifiers.shift == b.modifiers.shift and
        a.modifiers.alt == b.modifiers.alt;
}

pub const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

/// Where a keybinding is active — DERIVED from the action
/// (`actionBindingContexts`), never authored per binding. Actions in
/// different contexts may share the same key combo (Digit1 = skill 1 in
/// game, select tool in editor); only bindings whose derived contexts are
/// active reach `checkAction`, so same-combo cross-context pairs never
/// co-fire. `anytime` is active on every screen except while the error
/// popup is up; `error_popup` is active ONLY while the popup is up (the
/// popup is modal — see DESIGN → Input → Binding contexts). Named
/// `error_popup`, not `error`, because `error` is a Zig keyword. `menu` is
/// the main-menu screen. The settings file still carries a `context` line
/// per binding (informational, written as the derived primary; ignored at
/// load) — see DESIGN → Input → Binding contexts. See DESIGN → Input.
pub const BindingContext = enum {
    anytime,
    game,
    editor,
    menu,
    error_popup,
};

/// A set of active `BindingContext`s — what `translateInput` is handed each
/// frame (computed by the caller from the screen + pending_error; see
/// main.zig's frame). Backs the derived binding gate in `checkAction`/
/// `isActionHeld`/`isSuppressed`: a binding is active iff
/// `actionBindingContexts(binding.action)` intersects the frame's active
/// set (`intersects`).
pub const BindingContextSet = struct {
    anytime: bool = false,
    game: bool = false,
    editor: bool = false,
    menu: bool = false,
    error_popup: bool = false,

    pub fn contains(self: BindingContextSet, context: BindingContext) bool {
        return switch (context) {
            .anytime => self.anytime,
            .game => self.game,
            .editor => self.editor,
            .menu => self.menu,
            .error_popup => self.error_popup,
        };
    }

    /// True if any context is set in BOTH sets — the derived binding gate
    /// (see the struct doc).
    pub fn intersects(self: BindingContextSet, other: BindingContextSet) bool {
        return (self.anytime and other.anytime) or
            (self.game and other.game) or
            (self.editor and other.editor) or
            (self.menu and other.menu) or
            (self.error_popup and other.error_popup);
    }
};

/// True if two binding context sets can be SIMULTANEOUSLY ACTIVE (a
/// same-combo pair on them would co-fire — the binding-CONFLICT predicate
/// at load + in the keybind UI's steal scan). NOT plain intersection: the
/// activation model (see DESIGN → Input → Binding contexts) has exactly
/// one of game/editor/menu active with `anytime` riding along (everywhere
/// except the modal error popup), so {anytime} ∩ {game} is empty YET both
/// are active in-game — intersection would miss the conflict. Cross-screen
/// sets (game vs editor) never co-fire; `error_popup` is active ALONE
/// (co-fires only with itself).
pub fn bindingContextsCoFire(a: BindingContextSet, b: BindingContextSet) bool {
    if (a.error_popup or b.error_popup) {
        return a.error_popup and b.error_popup;
    }
    if (a.anytime and b.anytime) return true;
    if (a.anytime and (b.game or b.editor or b.menu)) return true;
    if (b.anytime and (a.game or a.editor or a.menu)) return true;
    return (a.game and b.game) or (a.editor and b.editor) or (a.menu and b.menu);
}

/// The single `BindingContext` written to a binding's settings-file line —
/// informational only (contexts are derived at load; see `BindingContext`).
/// The first set member in `BindingContext` declaration order, deterministic
/// for the writer. An older binary reading the file still validates this
/// against its own `actionBindingContexts` (any member passes).
pub fn primaryBindingContext(action: Action) BindingContext {
    const contexts = actionBindingContexts(action);
    if (contexts.anytime) return .anytime;
    if (contexts.game) return .game;
    if (contexts.editor) return .editor;
    if (contexts.menu) return .menu;
    return .error_popup;
}

/// The switch body of `actionBindingContexts` — the single source of
/// truth the comptime table below is derived from (kept as a separate fn
/// so the table can call it at comptime).
fn actionBindingContextsSwitch(action: Action) BindingContextSet {
    return switch (action) {
        // Always active (except during the error popup, where everything
        // except `error` is inactive).
        .undo,
        .redo,
        .escape,
        .dump_event_log,
        .zoom_in,
        .zoom_out,
        .zoom_reset,
        => .{ .anytime = true },

        // The recoverable-error popup only (modal — replaces every other
        // context while up).
        .dismiss_error,
        .error_scroll_up,
        .error_scroll_down,
        => .{ .error_popup = true },

        // Level + hub screens (playtest/validation runs are level screens,
        // so the run's gameplay bindings come along for free).
        .toggle_inventory,
        .toggle_gear,
        .toggle_skills,
        .toggle_entity_inspect,
        .toggle_world_map,
        .confirm,
        .cancel,
        .skip,
        .skill_slot_1,
        .skill_slot_2,
        .skill_slot_3,
        .skill_slot_4,
        .skill_slot_5,
        .skill_slot_6,
        .skill_slot_7,
        .skill_slot_8,
        .swap_weapons,
        .move_cursor_up,
        .move_cursor_down,
        .move_cursor_left,
        .move_cursor_right,
        .save_game,
        .restart_mission,
        .exit_mission,
        .replay_mission,
        .overwrite_clone,
        .skip_level,
        => .{ .game = true },

        // The editor screen (edit mode — during a playtest/validation run
        // the screen is `.level`, so these go inactive and the game set
        // above takes over).
        .save_editor_mission,
        .export_editor_mission,
        .toggle_editor_palette_group,
        .add_editor_palette_type,
        .delete_editor_palette_type,
        .add_editor_level,
        .delete_editor_level,
        .select_editor_tool,
        .select_editor_level,
        .toggle_editor_inspector,
        .toggle_editor_metadata_sidebar,
        .test_editor_level,
        .validate_editor_mission,
        .revalidate_editor_mission,
        .open_editor_level_gradient_picker,
        .select_editor_level_gradient,
        .toggle_editor_level_gradient_auto,
        .toggle_editor_inspector_section,
        .open_editor_sprite_picker,
        .select_editor_entity_sprite,
        .select_editor_decoration_sprite,
        .select_editor_sprite_tab,
        .import_editor_player,
        .import_editor_max_player,
        .select_editor_entity_color,
        .select_editor_decoration_color,
        .open_editor_entity_layer_picker,
        .open_editor_decoration_layer_picker,
        .select_editor_entity_layer,
        .select_editor_decoration_layer,
        .delete_editor_entity_layer,
        .delete_editor_decoration_layer,
        .select_editor_entity_layer_color,
        .select_editor_decoration_layer_color,
        .open_editor_footprint_picker,
        .toggle_editor_footprint_tile,
        .confirm_editor_footprint,
        .toggle_editor_entity_displays_weapons,
        .toggle_editor_entity_keep_original_colors,
        .toggle_editor_decoration_keep_original_colors,
        .toggle_editor_decoration_layer_behind,
        .select_editor_weapon_type,
        .add_editor_item,
        .delete_editor_item,
        .select_editor_item_type,
        .select_editor_inventory_slot,
        .add_editor_inventory_item,
        .delete_editor_inventory_item,
        .select_editor_inventory_item_type,
        .open_editor_skill_picker,
        .close_editor_picker,
        .select_editor_utility_skill,
        .delete_editor_selection,
        .clear_editor_selection,
        .select_editor_all,
        // The editor browser + its in-window controls. The browser OPENS
        // from the main menu too (its buttons — clicks bypass the context
        // gate; the consumption sites keep their
        // `editorBrowserReachableScreen` gate for those), but the
        // keyboard shortcuts are EDITOR-ONLY: a main-menu surface has no
        // editor semantics for them.
        .toggle_editor_browser,
        .select_editor_kind_tab,
        .select_editor_mission_tab,
        .open_editor_mission_row,
        .import_editor_mission,
        .new_editor_mission,
        .overwrite_validation_replay,
        .editor_select_tool,
        .editor_tile_tool,
        .toggle_editor_entity_group,
        .toggle_editor_decoration_group,
        .toggle_editor_item_group,
        => .{ .editor = true },

        // The main-menu screen.
        .continue_game,
        .new_game,
        .toggle_load_save_menu,
        .load_save_row,
        .import_save,
        .open_credits,
        .exit_game,
        => .{ .menu = true },

        // Multi-screen: fires on more than one screen's surface.
        // The settings overlay is reachable from the main menu AND the
        // in-game options menu.
        .open_settings,
        .change_setting,
        .select_settings_tab,
        .edit_keybind,
        => .{ .menu = true, .game = true },
        // Exit to Main Menu: the level/hub options menu and the editor's
        // (where it ends an editor run + closes the editor).
        .exit_to_menu,
        // Continue on the mission-complete overlay: in the hub (campaign)
        // or over the editor (the validation stats screen).
        .continue_after_mission,
        => .{ .game = true, .editor = true },
    };
}

/// Comptime-materialized action→contexts table (the generated-lookups
/// pattern), derived from the switch above: `actionBindingContexts` reads
/// this instead of running the 175-way switch — the context gate runs once
/// per binding in `translateInput`'s dispatch loop and once per competitor
/// inside `isSuppressed`, so the switch was the most-executed line of the
/// input path. A new Action variant still fails compilation until the
/// switch classifies it.
const action_binding_contexts_lut: [@typeInfo(Action).@"enum".fields.len]BindingContextSet = blk: {
    var table: [@typeInfo(Action).@"enum".fields.len]BindingContextSet = undefined;
    for (&table, 0..) |*slot, index| {
        slot.* = actionBindingContextsSwitch(@enumFromInt(index));
    }
    break :blk table;
};

/// Which `BindingContext`s an action fires in — the single declaration of
/// "where does this action fire" (consumption sites mirror it). DERIVED:
/// a binding's active contexts ARE this set (there is no per-binding
/// context). Exhaustive by construction (no else-arm): adding an Action
/// variant is a compile error until it's classified here. Button clicks
/// are NOT context-gated (`applyAction` sets actions directly) — buttons
/// only render in their context, so this map governs keyboard/gamepad
/// bindings only. Actions valid on multiple screens carry multiple flags
/// (e.g. `exit_to_menu` fires from the level/hub options menu and the
/// editor's). Reads the comptime-materialized table above (one array read
/// per call).
pub fn actionBindingContexts(action: Action) BindingContextSet {
    return action_binding_contexts_lut[@intFromEnum(action)];
}

/// The settings screen's content tabs (the Keybinds tab is the in-game
/// rebinding UI's list — see TODO → Keybind editor).
pub const SettingsTab = enum { settings, keybinds };

/// One keybinds-tab edit command — the `.edit_keybind` action's payload
/// (the whole editing UI rides one action + this union as the click
/// payload's `keybind_command` variant). See DESIGN → UI Framework →
/// Settings screen.
pub const KeybindCommand = union(enum) {
    /// Start listening to rekey the binding at `settings.input_bindings[`
    /// index]` (its action is kept; a new combo is captured).
    rekey: usize,
    /// Open the right-column action picker for the binding at
    /// `settings.input_bindings[index]` (reassign its action).
    reassign: usize,
    /// Start listening to add another combo for the action (a row's `+`).
    add: Action,
    /// Standalone add (the list's Add button): open the action picker to
    /// pick the action first, then listen.
    add_open,
    /// Remove the binding at `settings.input_bindings[index]` — direct,
    /// no confirm (Reset to defaults is the safety net).
    remove: usize,
    /// The picker's pick of an action (what the open picker targets decides
    /// what happens: reassign the target row, or move on to listening for
    /// the standalone add).
    pick: Action,
    /// Apply the pending proposal (the Confirm button).
    confirm,
    /// Discard the edit / close the picker (the Cancel button).
    cancel,
    /// Replace ALL bindings with the shipped defaults' set (the Reset
    /// button — the safety net for removals and bad rebinds).
    reset_defaults,
};

/// One frame's keybind-listening outcome, produced by the `translateInput`
/// capture seam (the text-edit-outcome model): a key was captured (the
/// edit moves to its pending state), Escape was pressed (cancel), Enter
/// was pressed during pending (confirm — the modal-capture-state
/// convention), or nothing happened. Resolved once per frame in
/// `main.frame` — see `input_handlers.resolveKeybindCaptureOutcome`.
pub const KeybindCaptureOutcome = enum { none, captured, canceled, confirmed };

/// The identity of a clicked button BEYOND its action — what the click
/// was on (which row, which tab, which cell), riding the frame's input
/// (`PlayerInput.clicked_payload`) alongside the action `applyAction` folds
/// (`AnytimeInput.options_action` / `IdleInput.menu_action`). Same-frame
/// only: valid in the frame it was set, read by the consumption arm that
/// fired its action, dead after. Inert data — it never fires anything by
/// itself, which is why it rides `PlayerInput` rather than the anytime/idle
/// sub-structs (see DESIGN → Input → Button payloads). The variant is the
/// clicked thing's identity kind; a button whose identity is compound
/// (a weapon-type cell: which hand + which type) carries one struct
/// variant, not two. Null-meaningful identities keep the optional INSIDE
/// the variant (`.editor_layer` null = the picker's add mode;
/// `.editor_skill` null = the picker's None cell).
pub const ButtonPayload = union(enum) {
    /// A settings toggle/choice control: which field, and for choices which
    /// value this button represents.
    setting: SettingRef,
    /// A load-save browser row (index into the browser's session list).
    save_row: u32,
    /// An editor palette group (the header's expand/collapse or the
    /// group's "+" add-new cell).
    editor_group: usize,
    /// An inspector section header (expand/collapse).
    editor_section: EditorInspectorSectionId,
    /// A sprite picker cell (the sprite stem; namespaced `custom/<mission>/`
    /// for mission-local picks).
    editor_sprite: []const u8,
    /// A sprite picker tab button (Mission / Official).
    editor_sprite_tab: EditorSpritePickerTab,
    /// An editor tool cell (make it the active tool).
    editor_tool: EditorToolId,
    /// An editor level tab.
    editor_level: u32,
    /// An entity/decoration color swatch (the gradient index).
    editor_color: u32,
    /// A layers-section control (sprite button / delete / behind toggle);
    /// null on the add-layer button = the picker's add mode.
    editor_layer: ?u32,
    /// A layer's color swatch (layer + gradient index together).
    editor_layer_color: struct { layer_index: u32, color_index: u32 },
    /// An inspector gear-slot control (Add / Delete).
    editor_gear_slot: GearSlot,
    /// A weapon-type cell (which hand + which type).
    editor_weapon_type_cell: struct { gear_slot: GearSlot, weapon_type: WeaponType },
    /// An item-type pick cell (the kind; weapon cells carry the type —
    /// non-weapon cells leave it null, the default).
    editor_item_kind_cell: struct { kind: ItemKind, weapon_type: ?WeaponType = null },
    /// A player-inspector inventory-slot control (slot cell / Add / Delete).
    editor_inventory_slot: u32,
    /// An inspector utility-slot button (opens the skill picker).
    editor_utility_slot: u32,
    /// A footprint-editor grid cell (row-major).
    editor_footprint_tile: u32,
    /// A settings-sidebar gradient row's role (its swatch or Auto button).
    editor_gradient_role: LevelGradientRole,
    /// A theme-picker gradient row.
    editor_gradient: u32,
    /// A skill-picker cell (null = the None cell, clears the slot).
    editor_skill: ?SkillId,
    /// An editor-browser kind tab (Mission today; Hub / Campaign later).
    editor_kind: EditorKind,
    /// A mission-browser tab (Your Missions / Official).
    editor_mission_tab: EditorMissionBrowserTab,
    /// A mission-browser row (index into the current tab's list).
    editor_mission_row: u32,
    /// The settings screen's content tab (Settings / Keybinds).
    settings_tab: SettingsTab,
    /// A keybinds-tab edit command (the whole editing UI rides one action).
    keybind_command: KeybindCommand,
};

/// The payload variant an action's clicks carry, if any — the single
/// declaration of "which payload rides this action" (the
/// `actionBindingContexts` pattern: exhaustive by construction, no
/// else-arm, so adding an Action is a compile error until it is classified
/// here). One variant per action: a button needing two identities carries
/// one compound variant, so a second entry here would mean a compound is
/// missing. Read at the button-release relay (main.zig) as a fail-fast
/// check — a payload on a payload-less action, or of the wrong variant,
/// panics there instead of being silently eaten by a consumption arm's
/// `orelse return` (the exact bug class the union exists to kill). Actions
/// fired without a payload (console `action` commands, which cannot carry
/// one) no-op at the consumption arm by design — the payload IS the click.
pub fn actionButtonPayload(action: Action) ?ButtonPayloadTag {
    return switch (action) {
        .load_save_row => .save_row,
        .change_setting => .setting,
        .edit_keybind => .keybind_command,
        .select_settings_tab => .settings_tab,
        .toggle_editor_palette_group,
        .add_editor_palette_type,
        => .editor_group,
        .delete_editor_palette_type => .editor_tool,
        .select_editor_tool => .editor_tool,
        .select_editor_level => .editor_level,
        .delete_editor_level => .editor_level,
        .toggle_editor_inspector_section => .editor_section,
        .select_editor_sprite_tab => .editor_sprite_tab,
        .select_editor_entity_sprite,
        .select_editor_decoration_sprite,
        .select_editor_entity_layer,
        .select_editor_decoration_layer,
        => .editor_sprite,
        .open_editor_level_gradient_picker,
        .toggle_editor_level_gradient_auto,
        => .editor_gradient_role,
        .select_editor_level_gradient => .editor_gradient,
        .select_editor_entity_color,
        .select_editor_decoration_color,
        => .editor_color,
        .open_editor_entity_layer_picker,
        .open_editor_decoration_layer_picker,
        .delete_editor_entity_layer,
        .delete_editor_decoration_layer,
        .toggle_editor_decoration_layer_behind,
        => .editor_layer,
        .select_editor_entity_layer_color,
        .select_editor_decoration_layer_color,
        => .editor_layer_color,
        .select_editor_weapon_type => .editor_weapon_type_cell,
        .add_editor_item,
        .delete_editor_item,
        => .editor_gear_slot,
        .select_editor_item_type,
        .select_editor_inventory_item_type,
        => .editor_item_kind_cell,
        .select_editor_inventory_slot,
        .add_editor_inventory_item,
        .delete_editor_inventory_item,
        => .editor_inventory_slot,
        .open_editor_skill_picker => .editor_utility_slot,
        .select_editor_utility_skill => .editor_skill,
        .toggle_editor_footprint_tile => .editor_footprint_tile,
        .select_editor_kind_tab => .editor_kind,
        .select_editor_mission_tab => .editor_mission_tab,
        .open_editor_mission_row => .editor_mission_row,

        // Payload-less actions: every action below carries no button
        // identity beyond its own name. Grouped, not elided — an `else =>
        // null` would silently swallow a new Action; naming them all keeps
        // adding one a compile error until its payload story is decided.
        .undo,
        .redo,
        .escape,
        .toggle_inventory,
        .toggle_gear,
        .toggle_skills,
        .toggle_entity_inspect,
        .toggle_world_map,
        .confirm,
        .cancel,
        .skip,
        .skill_slot_1,
        .skill_slot_2,
        .skill_slot_3,
        .skill_slot_4,
        .skill_slot_5,
        .skill_slot_6,
        .skill_slot_7,
        .skill_slot_8,
        .swap_weapons,
        .move_cursor_up,
        .move_cursor_down,
        .move_cursor_left,
        .move_cursor_right,
        .dump_event_log,
        .dismiss_error,
        .error_scroll_up,
        .error_scroll_down,
        .zoom_in,
        .zoom_out,
        .zoom_reset,
        .save_game,
        .save_editor_mission,
        .export_editor_mission,
        .restart_mission,
        .exit_mission,
        .exit_to_menu,
        .exit_game,
        .continue_after_mission,
        .replay_mission,
        .overwrite_clone,
        .overwrite_validation_replay,
        .skip_level,
        .continue_game,
        .new_game,
        .toggle_load_save_menu,
        .import_save,
        .open_settings,
        .open_credits,
        .add_editor_level,
        .toggle_editor_inspector,
        .toggle_editor_metadata_sidebar,
        .test_editor_level,
        .validate_editor_mission,
        .revalidate_editor_mission,
        .open_editor_sprite_picker,
        .import_editor_player,
        .import_editor_max_player,
        .open_editor_footprint_picker,
        .confirm_editor_footprint,
        .toggle_editor_entity_displays_weapons,
        .toggle_editor_entity_keep_original_colors,
        .toggle_editor_decoration_keep_original_colors,
        .close_editor_picker,
        .delete_editor_selection,
        .clear_editor_selection,
        .select_editor_all,
        .toggle_editor_browser,
        .import_editor_mission,
        .new_editor_mission,
        .editor_select_tool,
        .editor_tile_tool,
        .toggle_editor_entity_group,
        .toggle_editor_decoration_group,
        .toggle_editor_item_group,
        => null,
    };
}

/// `ButtonPayload`'s variant tags.
pub const ButtonPayloadTag = std.meta.Tag(ButtonPayload);

// No-orphan check (machine-walked): every ButtonPayload variant must be
// named by at least one action's `actionButtonPayload` entry — a variant
// no action can carry is a dead union member, and this makes it a compile
// error instead of dead scaffolding. Runs at comptime over the table
// itself, so it can never drift from the switch above.
comptime {
    var carried: [@typeInfo(ButtonPayloadTag).@"enum".fields.len]bool =
        .{false} ** @typeInfo(ButtonPayloadTag).@"enum".fields.len;
    for (0..@typeInfo(Action).@"enum".fields.len) |action_index| {
        if (actionButtonPayload(@enumFromInt(action_index))) |payload_tag| {
            carried[@intFromEnum(payload_tag)] = true;
        }
    }
    for (std.meta.tags(ButtonPayloadTag)) |payload_tag| {
        if (!carried[@intFromEnum(payload_tag)]) {
            @compileError(
                "ButtonPayload variant ." ++ @tagName(payload_tag) ++
                    " is carried by no action — dead variant, or actionButtonPayload is stale",
            );
        }
    }
}

pub const InputBinding = struct {
    input: RawInput,
    modifiers: Modifiers = .{},
    action: Action,
    // Where this binding is active is DERIVED from the action
    // (`actionBindingContexts`) — there is no per-binding context field.
    // The settings file's informational `context` line is written from
    // `primaryBindingContext` and ignored at load. See DESIGN → Input →
    // Binding contexts.
};

pub const Settings = struct {
    // Volumes are u32 percentages 0–100 (clamped at parse). The backend
    // converts to f32 0.0–1.0 at the raylib seam (`applyVolumes` /
    // `playSounds`). See DESIGN → UI Framework → Settings screen (Volume
    // integer migration).
    master_volume: u32 = 100, // 0–100, scales music + sfx alike
    music_volume: u32 = 50, // 0–100, before master
    sound_effects_volume: u32 = 50, // 0–100, before master
    vsync: bool = true,
    // Frames-per-second cap for rendering. 0 = no explicit cap. Ignored when
    // vsync is on (vsync paces renders to the monitor refresh rate). When
    // vsync is off and this is >0, renders are gated to 1/cap seconds; when 0
    // and vsync off, the loop renders every iteration (uncapped).
    render_fps_cap: u32 = 0,
    /// Animation frame rate for ALL sprite animations (currently the flag
    /// banner). One global rate so pacing is uniform; frame
    /// duration = 1_000_000 / animation_fps microseconds. Read by `view()`
    /// only (never by event handlers — see DESIGN → Animation). Default 8.
    animation_fps: u32 = 8,
    auto_skip_attack_step_out_of_combat: bool = true,
    auto_target_at_cursor: bool = true,
    /// Render an FPS counter in the top-left corner. Diagnostic overlay —
    /// off the undoable GameState (read live by `view()`), so replay-safe
    /// by construction. Default off.
    show_fps: bool = false,
    /// Player color index into the current theme's player gradient. Read at
    /// render time to tint the player entity + UI. Default 0 (lightest).
    player_color_index: u32 = 0,
    input_bindings: []const InputBinding,
    /// Camera zoom, in hundredths (0–100). Only the values 25/50/75/100
    /// are valid (a 4-choice, not a continuous slider): 100 = 1.0× (zoomed
    /// in), 25 = 0.25× (max zoom out), default 50. The f32 lives at the
    /// render/input seam only (`@as(f32, @floatFromInt(zoom)) / 100.0`).
    camera_zoom: u32 = 50,
    /// Offscreen render target resolution. Live-applied by `frame()` (the
    /// backend recreates its `RenderTexture` on change); a failed apply
    /// reverts this to the currently-running preset. See DESIGN → Platform
    /// Seam → Render target resolution.
    render_resolution: RenderResolution = default_render_resolution,
};

pub const Camera = struct {
    position: Vector2,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// The ONE outline width constant: the outline family (the clickable-tile
/// highlight, cursor/range/radius/aggro region outlines, the UI icon halo
/// masks, the spriteless button hover rects) draws at THIS width in
/// reference pixels, CONSTANT — independent of world zoom and of the size
/// of the outlined thing. Mask generation (the silhouette-hugging halos)
/// compensates for the drawn scale: the band in source pixels is
/// ceil(outline_thickness / drawn_scale), cached per (sprite, band).
pub const outline_thickness: i32 = 8;

pub const gradient_color_count = 6;

pub const ColorGradient = struct {
    colors: [gradient_color_count]Color,
};

pub const ColorThemeDefinitions = struct {
    lightest: Color,
    darkest: Color,
    gradients: []const ColorGradient,
};

pub const ActiveColorTheme = struct {
    lightest: Color,
    darkest: Color,
    world_gradient: ColorGradient,
    enemy_gradient: ColorGradient,
    player_gradient: ColorGradient,
};

/// One overlay layer of a decoration: a sprite drawn over the base at the same
/// position, colored independently. Must be the same pixel dimensions as the
/// base (validated at load). See DESIGN → Decorations & Footprint.
pub const DecorationLayer = struct {
    sprite: []const u8,
    color_index: u32,
    /// Draws BEHIND the base sprite (before it) instead of over it — the
    /// `behind` config key (e.g. the trees' grass_back layer). Default false:
    /// a layer is an overlay unless authored otherwise.
    behind: bool = false,
    /// Pixel dims (validated == base pixel_dims at load; stored so view() stays
    /// pure and replay reproduces without re-reading).
    pixel_dims: Vector2,
};

pub const Decoration = struct {
    name: []const u8,
    /// World position of the anchor tile (bottom-most-then-left-most footprint
    /// tile). The layout char sits here; non-anchor footprint tiles are
    /// implicit. See DESIGN → Decorations & Footprint.
    position: Vector2,
    /// Footprint tile coordinates in the SPRITE's own tile-grid (top-left of
    /// the sprite bbox = (0,0)). Not anchor-relative — the list is authored
    /// by marking the solid tiles of the sprite. The anchor is DERIVED from
    /// this list (bottom-most-then-left-most).
    footprint: []const Vector2,
    /// Pixel dimensions of the BASE sprite (from the PNG IHDR). view() uses
    /// these to compute the tile bbox and per-tile source rectangles for
    /// splitting. Populated by the parser: comptime table for shipped sprites,
    /// PNG-byte parse for custom sprites. Stored on the GameState so view()
    /// stays pure (no I/O) and replay reproduces it without re-reading the PNG.
    pixel_dims: Vector2,
    /// Color index into the current theme's world gradient. Default 0
    /// (lightest world color). Tiles use 1/3, background uses 2; decorations
    /// should use 0/4/5 for distinction.
    color_index: u32 = 0,
    /// Render the base sprite + overlay layers UNTINTED — the art keeps
    /// its own colors (custom mission-bundled art is authored pre-colored).
    /// Default-off: shipped art is authored grayscale for gradient
    /// tinting. See DESIGN → Entity & UI Coloring (keep_original_colors).
    keep_original_colors: bool = false,
    /// Overlay layers (same pixel dims as the base), drawn over the base in
    /// declaration order, each colored independently.
    layers: []const DecorationLayer = &.{},
};

pub const SkillType = enum {
    weapon_skill,
    spell,
    cantrip,
    enchantment,
    curse,
};

pub const WeaponType = enum {
    sword,
    shield,
    spear,
    dagger,
    axe,
    staff,
};

pub const WeaponTypeDefinition = struct {
    skill_1: SkillId,
    skill_2: SkillId,
    skill_3: SkillId,
};

/// The session's weapon-type → skills mapping (session config, owned by
/// SessionSetup / GameStateHistory — see DESIGN → Architecture). Alias so
/// the many fns that receive it (skillInSlot, the AI range/threat math,
/// every skill priority fn) don't spell out the array-pointer type.
pub const WeaponTypeDefinitions = *const [weapon_type_count]WeaponTypeDefinition;

pub const ItemType = union(enum) {
    weapon: WeaponType,
    amulet: void,
    coat: void,
    gloves: void,
    pants: void,
    boots: void,
    skill_tome: SkillId,
};

/// The authorable item KINDS (everything `Item` carries except skill
/// tomes — a tome is not level-authorable, so the level file's Items
/// section and the editor's item palette both exclude it). The kind tag
/// of the flattened `editor_set_item_def` event + the item-type pick
/// payload.
pub const ItemKind = enum {
    weapon,
    amulet,
    coat,
    gloves,
    pants,
    boots,
};

/// The kind's display name (the "New <Kind>" default item names). pub:
/// shared by the input handler's default-item construction + the pick
/// cells' tooltips.
pub fn itemKindLabel(kind: ItemKind) []const u8 {
    return switch (kind) {
        .weapon => "Weapon",
        .amulet => "Amulet",
        .coat => "Coat",
        .gloves => "Gloves",
        .pants => "Pants",
        .boots => "Boots",
    };
}

/// The kind an item belongs to, or null for a skill tome (not expressible
/// as an `ItemKind` — the editor authoring surface excludes tomes; the
/// null is the defensive seam for crafted state).
pub fn itemKindOf(item: Item) ?ItemKind {
    return switch (item) {
        .weapon => .weapon,
        .amulet => .amulet,
        .coat => .coat,
        .gloves => .gloves,
        .pants => .pants,
        .boots => .boots,
        .skill_tome => null,
    };
}

/// A zeroed-stat item of `kind` carrying `name` (the pick-reset default
/// the input handler commits, + the icon resolution for the kind's pick
/// cell). Weapons take `sword` unless the caller overrides the type.
pub fn itemOfKind(kind: ItemKind, name: []const u8) Item {
    return switch (kind) {
        .weapon => .{ .weapon = .{ .name = name } },
        .amulet => .{ .amulet = .{ .name = name } },
        .coat => .{ .coat = .{ .name = name } },
        .gloves => .{ .gloves = .{ .name = name } },
        .pants => .{ .pants = .{ .name = name } },
        .boots => .{ .boots = .{ .name = name } },
    };
}

/// The equippable gear slots on an entity. Weapons occupy main_hand/off_hand;
/// the rest map one-to-one to their gear fields.
pub const GearSlot = enum {
    main_hand,
    off_hand,
    amulet,
    coat,
    gloves,
    pants,
    boots,
};

/// The slot's display name (the inspector's entry labels, and the "New X"
/// default item names). pub: shared by the ui builder + the input handlers'
/// default-item construction.
pub fn gearSlotLabel(slot: GearSlot) []const u8 {
    return switch (slot) {
        .main_hand => "Main hand",
        .off_hand => "Off hand",
        .amulet => "Amulet",
        .coat => "Coat",
        .gloves => "Gloves",
        .pants => "Pants",
        .boots => "Boots",
    };
}

/// The item kind a gear slot takes (weapons on the hands, each gear kind
/// on its own slot). pub: the input-side gear action builder's kind-match
/// gate reads it.
pub fn gearSlotItemKind(slot: GearSlot) ItemKind {
    return switch (slot) {
        .main_hand, .off_hand => .weapon,
        .amulet => .amulet,
        .coat => .coat,
        .gloves => .gloves,
        .pants => .pants,
        .boots => .boots,
    };
}

/// The weapon type's display name (tooltips + the "New X" default weapon
/// names — capitalized, unlike @tagName).
pub fn weaponTypeLabel(weapon_type: WeaponType) []const u8 {
    return switch (weapon_type) {
        .sword => "Sword",
        .shield => "Shield",
        .spear => "Spear",
        .dagger => "Dagger",
        .axe => "Axe",
        .staff => "Staff",
    };
}

pub const Weapon = struct {
    name: []const u8 = &.{},
    weapon_type: WeaponType = .sword,
    weapon_damage: u32 = 0,
};

pub const Amulet = struct {
    name: []const u8 = &.{},
    spell_damage: u32 = 0,
};

pub const Coat = struct {
    name: []const u8 = &.{},
    health_bonus: u32 = 0,
    defense_bonus: u32 = 0,
};

pub const Gloves = struct {
    name: []const u8 = &.{},
    health_bonus: u32 = 0,
    damage_bonus: u32 = 0,
};

pub const Pants = struct {
    name: []const u8 = &.{},
    health_bonus: u32 = 0,
    pickup_radius_bonus: u32 = 0,
};

pub const Boots = struct {
    name: []const u8 = &.{},
    health_bonus: u32 = 0,
    speed_bonus: u32 = 0,
};

pub const SkillTome = struct {
    skill: SkillId = .slice,
    value: u32 = 5,
};

pub const Item = union(enum) {
    weapon: Weapon,
    amulet: Amulet,
    coat: Coat,
    gloves: Gloves,
    pants: Pants,
    boots: Boots,
    skill_tome: SkillTome,
};

// ── Gear-stat balance bounds (the single source) ──
//
// Shared by the parser's `boundedU32` clamp (loaders.zig) and the editor
// inspector's commit-time clamp — a bound can't exist in one place only
// (the coupling contract, DESIGN → Level Editor → Inspector fields).
// Entity base stats are deliberately NOT bounded here (enemies may be as
// unbalanced as the author wants); these bound the ITEM stats because the
// player can pick up exactly those items. See DESIGN → Custom Missions →
// Balance bounds.
pub const max_weapon_damage: u32 = 10;
pub const max_spell_damage: u32 = 10;
pub const max_health_bonus: u32 = 10;
pub const max_defense_bonus: u32 = 5;
pub const max_gloves_damage: u32 = 5;
pub const max_pickup_radius: u32 = 5;
pub const max_boots_speed: u32 = 2;

/// One of the entity's unbounded base stats (the inspector's numeric
/// fields — see DESIGN → Level Editor → Inspector fields).
pub const EntityStatField = enum {
    max_health,
    defense,
    speed,
    aggro_range,
    /// Team rides the stat-field machinery but is identity, not a stat:
    /// 0 = the player's team (helpers the player doesn't control), 1+ =
    /// mutually hostile enemy teams. Enemy-authorable only — the commit
    /// path rejects the player_def target.
    team,
};

/// One numeric stat an equipped item can carry. Not every item kind has
/// every stat — `itemStatValue` returns null for the non-applicable ones
/// (the inspector only offers the applicable set).
pub const ItemStatField = enum {
    weapon_damage,
    spell_damage,
    health_bonus,
    defense_bonus,
    damage_bonus,
    pickup_radius_bonus,
    speed_bonus,
};

/// The item's display name (every item kind carries one).
pub fn itemName(item: Item) []const u8 {
    return switch (item) {
        .weapon => |weapon| weapon.name,
        .amulet => |amulet| amulet.name,
        .coat => |coat| coat.name,
        .gloves => |gloves| gloves.name,
        .pants => |pants| pants.name,
        .boots => |boots| boots.name,
        // A skill tome carries no name (it IS its skill).
        .skill_tome => "",
    };
}

/// A copy of `item` with its name replaced.
pub fn itemWithName(item: Item, name: []const u8) Item {
    var modified = item;
    switch (modified) {
        .weapon => |*weapon| weapon.name = name,
        .amulet => |*amulet| amulet.name = name,
        .coat => |*coat| coat.name = name,
        .gloves => |*gloves| gloves.name = name,
        .pants => |*pants| pants.name = name,
        .boots => |*boots| boots.name = name,
        // A skill tome carries no name (it IS its skill) — unchanged.
        .skill_tome => {},
    }
    return modified;
}

/// The item's current value for `stat`, or null when the item kind doesn't
/// carry that stat (a weapon has no health_bonus; a coat has no damage).
pub fn itemStatValue(item: Item, stat: ItemStatField) ?u32 {
    return switch (item) {
        .weapon => |weapon| switch (stat) {
            .weapon_damage => weapon.weapon_damage,
            else => null,
        },
        .amulet => |amulet| switch (stat) {
            .spell_damage => amulet.spell_damage,
            else => null,
        },
        .coat => |coat| switch (stat) {
            .health_bonus => coat.health_bonus,
            .defense_bonus => coat.defense_bonus,
            else => null,
        },
        .gloves => |gloves| switch (stat) {
            .damage_bonus => gloves.damage_bonus,
            .health_bonus => gloves.health_bonus,
            else => null,
        },
        .pants => |pants| switch (stat) {
            .pickup_radius_bonus => pants.pickup_radius_bonus,
            .health_bonus => pants.health_bonus,
            else => null,
        },
        .boots => |boots| switch (stat) {
            .speed_bonus => boots.speed_bonus,
            .health_bonus => boots.health_bonus,
            else => null,
        },
        .skill_tome => null,
    };
}

/// A copy of `item` with `stat` set to `value` (assumes the stat applies —
/// callers gate on `itemStatValue != null`).
pub fn itemWithStat(item: Item, stat: ItemStatField, value: u32) Item {
    var modified = item;
    switch (modified) {
        .weapon => |*weapon| switch (stat) {
            .weapon_damage => weapon.weapon_damage = value,
            else => {},
        },
        .amulet => |*amulet| switch (stat) {
            .spell_damage => amulet.spell_damage = value,
            else => {},
        },
        .coat => |*coat| switch (stat) {
            .health_bonus => coat.health_bonus = value,
            .defense_bonus => coat.defense_bonus = value,
            else => {},
        },
        .gloves => |*gloves| switch (stat) {
            .damage_bonus => gloves.damage_bonus = value,
            .health_bonus => gloves.health_bonus = value,
            else => {},
        },
        .pants => |*pants| switch (stat) {
            .pickup_radius_bonus => pants.pickup_radius_bonus = value,
            .health_bonus => pants.health_bonus = value,
            else => {},
        },
        .boots => |*boots| switch (stat) {
            .speed_bonus => boots.speed_bonus = value,
            .health_bonus => boots.health_bonus = value,
            else => {},
        },
        .skill_tome => {},
    }
    return modified;
}

/// The balance bound for an item stat (the same constant the parser clamps
/// with — the single source, see the max_* block above).
pub fn itemStatMax(stat: ItemStatField) u32 {
    return switch (stat) {
        .weapon_damage => max_weapon_damage,
        .spell_damage => max_spell_damage,
        .health_bonus => max_health_bonus,
        .defense_bonus => max_defense_bonus,
        .damage_bonus => max_gloves_damage,
        .pickup_radius_bonus => max_pickup_radius,
        .speed_bonus => max_boots_speed,
    };
}

/// The stats an item kind carries, in display order (the inspector's
/// item content offers exactly these — a stat the kind doesn't carry
/// commits nothing by construction). A skill tome carries none.
pub fn itemStatSet(item: Item) []const ItemStatField {
    return switch (item) {
        .weapon => &.{.weapon_damage},
        .amulet => &.{.spell_damage},
        .coat => &.{ .health_bonus, .defense_bonus },
        .gloves => &.{ .damage_bonus, .health_bonus },
        .pants => &.{ .pickup_radius_bonus, .health_bonus },
        .boots => &.{ .speed_bonus, .health_bonus },
        .skill_tome => &.{},
    };
}

/// A palette item type's field value as the text-input widget shows it
/// (the item content's single value source — display text, focus seeding,
/// and the commit path's would-change gate; mirrors `Entity.textFieldValue`).
/// A skill tome shows empty for every field (tomes are not authorable —
/// the editor item surface never offers them); ids that don't resolve
/// against an item return empty too.
pub fn itemTextFieldValue(
    item: Item,
    allocator: std.mem.Allocator,
    field_id: TextFieldId,
) ![]const u8 {
    return switch (field_id) {
        .item_def_name => itemName(item),
        .item_def_stat => |stat| if (itemStatValue(item, stat)) |value|
            try std.fmt.allocPrint(allocator, "{d}", .{value})
        else
            "",
        .inventory_item_name => itemName(item),
        .inventory_item_stat => |stat| if (itemStatValue(item, stat)) |value|
            try std.fmt.allocPrint(allocator, "{d}", .{value})
        else
            "",
        // Entity/metadata ids never resolve against an item type (their
        // targets are entities / the mission / levels); the arms exist so
        // the switch stays exhaustive.
        .entity_name,
        .entity_stat,
        .item_name,
        .item_stat,
        .mission_name,
        .level_name,
        => "",
    };
}

pub const AdditiveEffectModifiers = struct {
    outgoing_damage: i32 = 0,
    incoming_damage: i32 = 0,
    speed: i32 = 0,
    range: i32 = 0,
    radius: i32 = 0,
    distance: i32 = 0,
    outgoing_skill_duration: i32 = 0,
    incoming_skill_duration: i32 = 0,
    outgoing_stun_duration: i32 = 0,
    incoming_stun_duration: i32 = 0,
    cooldown: i32 = 0,
    pickup_radius: i32 = 0,
    defense: i32 = 0,
};

pub const Effect = struct {
    effect_id: EffectId,
    duration: u32,
    additive_effect_modifiers: AdditiveEffectModifiers = .{},
};

/// One overlay layer of an entity: a sprite drawn over the base body at the
/// same frame + pivot, colored independently. Shares the entity's fixed
/// 512×640 frame (no per-layer pixel dims needed). See DESIGN → Decorations
/// & Footprint for the layer model.
pub const EntityLayer = struct {
    sprite: []const u8,
    color_index: u32,
};

pub const Entity = struct {
    name: []const u8 = &.{},
    /// Sprite identifier (asset stem under assets/entities/, e.g. "player",
    /// "skeleton_1"). Distinct from `name`, which is the display name.
    sprite: []const u8 = &.{},
    team: u32 = 0,
    position: Vector2 = .{ .x = 0, .y = 0 },
    max_health: u32 = 20,
    current_health: u32 = 20,
    momentum: u32 = 0,
    speed: u32 = 1,
    defense: u32 = 0,
    aggro_range: u32 = 3,
    is_active: bool = false,
    stun_duration: u32 = 0,
    /// Whether weapons are drawn on this entity. Default true (humanoids);
    /// enemies like wolves set `displays_weapons false` to suppress weapon
    /// overlays. Parsed from the level file's enemy definition.
    displays_weapons: bool = true,
    /// Render the base sprite + overlay layers UNTINTED — the art keeps
    /// its own colors (custom mission-bundled art is authored
    /// pre-colored). Weapons stay gradient-tinted (our art); health bars
    /// + effect overlays unaffected. Default-off: shipped art is
    /// authored grayscale for gradient tinting. See DESIGN → Entity &
    /// UI Coloring (keep_original_colors).
    keep_original_colors: bool = false,
    /// Color index into the team's gradient (enemy → enemy_gradient, player
    /// → player_gradient). The player's index is overridden by a settings
    /// field at render time; enemies read this directly. Default 0.
    color_index: u32 = 0,
    /// Overlay sprite layers drawn over the base body, each colored
    /// independently. Same 512×640 frame + pivot as the base (no per-layer
    /// dims). Drawn after base, before weapons. See DESIGN → Decorations &
    /// Footprint for the layer model (entities reuse it).
    layers: []const EntityLayer = &.{},

    main_hand_weapon: ?Weapon = null,
    off_hand_weapon: ?Weapon = null,
    amulet: ?Amulet = null,
    coat: ?Coat = null,
    gloves: ?Gloves = null,
    pants: ?Pants = null,
    boots: ?Boots = null,

    equipped_utility_skills: [utility_skill_count]?SkillId = .{null} ** utility_skill_count,
    inventory: Inventory = .{},
    skill_cooldowns: std.EnumArray(SkillId, u32) = std.EnumArray(SkillId, u32).initFill(0),
    active_effects: []const Effect = &.{},

    /// The item equipped in `slot`, as the generic union (null when the
    /// slot is empty). The single slot→item mapping — the gear panel (via
    /// ui.gearSlotItem's delegate) and the editor inspector both read it.
    pub fn gearSlotItem(self: Entity, slot: GearSlot) ?Item {
        return switch (slot) {
            .main_hand => if (self.main_hand_weapon) |weapon| .{ .weapon = weapon } else null,
            .off_hand => if (self.off_hand_weapon) |weapon| .{ .weapon = weapon } else null,
            .amulet => if (self.amulet) |amulet| .{ .amulet = amulet } else null,
            .coat => if (self.coat) |coat| .{ .coat = coat } else null,
            .gloves => if (self.gloves) |gloves| .{ .gloves = gloves } else null,
            .pants => if (self.pants) |pants| .{ .pants = pants } else null,
            .boots => if (self.boots) |boots| .{ .boots = boots } else null,
        };
    }

    /// The field's current value as the text-input widget shows it (strings
    /// verbatim, numbers decimal-formatted) — the single source shared by
    /// the inspector builder (display text), focus seeding, and the commit
    /// path's would-change gate. An item field on an empty slot (or a stat
    /// the item kind doesn't carry) shows empty — its commit no-ops.
    pub fn textFieldValue(
        self: Entity,
        allocator: std.mem.Allocator,
        field_id: TextFieldId,
    ) ![]const u8 {
        return switch (field_id) {
            .entity_name => self.name,
            .entity_stat => |stat| switch (stat) {
                .max_health => try std.fmt.allocPrint(allocator, "{d}", .{self.max_health}),
                .defense => try std.fmt.allocPrint(allocator, "{d}", .{self.defense}),
                .speed => try std.fmt.allocPrint(allocator, "{d}", .{self.speed}),
                .aggro_range => try std.fmt.allocPrint(allocator, "{d}", .{self.aggro_range}),
                .team => try std.fmt.allocPrint(allocator, "{d}", .{self.team}),
            },
            .item_name => |slot| if (self.gearSlotItem(slot)) |item|
                itemName(item)
            else
                "",
            .item_stat => |field| if (self.gearSlotItem(field.slot)) |item|
                (if (itemStatValue(item, field.stat)) |value|
                    try std.fmt.allocPrint(allocator, "{d}", .{value})
                else
                    "")
            else
                "",
            // Settings-sidebar + item-type + inventory ids never resolve
            // against an entity (their targets are `.mission` / `.level` /
            // `.item_type` / `.inventory_slot`); the arms exist so the
            // switch stays exhaustive.
            .mission_name, .level_name, .item_def_name, .item_def_stat => "",
            .inventory_item_name, .inventory_item_stat => "",
        };
    }

    /// Sum a single modifier field across all active effects.
    fn sumEffectModifier(
        self: Entity,
        comptime field: std.meta.FieldEnum(AdditiveEffectModifiers),
    ) i32 {
        var total: i32 = 0;
        for (self.active_effects) |effect| {
            total += @field(effect.additive_effect_modifiers, @tagName(field));
        }
        return total;
    }

    /// Apply an additive modifier to a base u32 value, clamping to minimum 0.
    fn applyModifier(base: u32, modifier: i32) u32 {
        const result = @as(i32, @intCast(base)) + modifier;
        return @intCast(@max(0, result));
    }

    /// Floor of base-2 logarithm of momentum, or 0 if momentum is 0.
    pub fn getConvertedMomentum(self: Entity) u32 {
        if (self.momentum == 0) return 0;
        return std.math.log2(self.momentum);
    }

    pub fn getEffectiveOutgoingDamage(self: Entity, base_damage: u32) u32 {
        const gloves_bonus: u32 = if (self.gloves) |gloves| gloves.damage_bonus else 0;
        const modifier = self.sumEffectModifier(.outgoing_damage) +
            @as(i32, @intCast(gloves_bonus)) +
            @as(i32, @intCast(self.getConvertedMomentum()));
        return applyModifier(base_damage, modifier);
    }

    /// Effective spell damage from the amulet, mirroring `getEffectiveOutgoingDamage`:
    /// amulet's `spell_damage` as the base + gloves `damage_bonus` + converted
    /// momentum + the `outgoing_damage` effect modifier. No amulet = base 0.
    pub fn getEffectiveSpellDamage(self: Entity) u32 {
        const base: u32 = if (self.amulet) |amulet| amulet.spell_damage else 0;
        const gloves_bonus: u32 = if (self.gloves) |gloves| gloves.damage_bonus else 0;
        const modifier = self.sumEffectModifier(.outgoing_damage) +
            @as(i32, @intCast(gloves_bonus)) +
            @as(i32, @intCast(self.getConvertedMomentum()));
        return applyModifier(base, modifier);
    }

    pub fn getEffectiveIncomingDamage(self: Entity, base_damage: u32) u32 {
        const modifier = self.sumEffectModifier(.incoming_damage) -
            @as(i32, @intCast(self.getEffectiveDefense()));
        return applyModifier(base_damage, modifier);
    }

    pub fn getEffectiveRange(self: Entity, base_range: u32) u32 {
        return applyModifier(base_range, self.sumEffectModifier(.range));
    }

    pub fn getEffectiveRadius(self: Entity, base_radius: u32) u32 {
        return applyModifier(base_radius, self.sumEffectModifier(.radius));
    }

    pub fn getEffectiveDistance(self: Entity, base_distance: u32) u32 {
        return applyModifier(base_distance, self.sumEffectModifier(.distance));
    }

    pub fn getEffectiveOutgoingSkillDuration(self: Entity, base_duration: u32) u32 {
        return applyModifier(base_duration, self.sumEffectModifier(.outgoing_skill_duration));
    }

    pub fn getEffectiveIncomingSkillDuration(self: Entity, base_duration: u32) u32 {
        return applyModifier(base_duration, self.sumEffectModifier(.incoming_skill_duration));
    }

    pub fn getEffectiveOutgoingStunDuration(self: Entity, base_duration: u32) u32 {
        return applyModifier(base_duration, self.sumEffectModifier(.outgoing_stun_duration));
    }

    pub fn getEffectiveIncomingStunDuration(self: Entity, base_duration: u32) u32 {
        return applyModifier(base_duration, self.sumEffectModifier(.incoming_stun_duration));
    }

    pub fn getEffectiveCooldown(self: Entity, base_cooldown: u32) u32 {
        return applyModifier(base_cooldown, self.sumEffectModifier(.cooldown));
    }

    pub fn getEffectiveSpeed(self: Entity) u32 {
        const boots_bonus: u32 = if (self.boots) |boots| boots.speed_bonus else 0;
        const modifier = self.sumEffectModifier(.speed) +
            @as(i32, @intCast(boots_bonus));
        return applyModifier(self.speed, modifier);
    }

    pub fn getEffectivePickupRadius(self: Entity, base_radius: u32) u32 {
        const pants_bonus: u32 = if (self.pants) |pants| pants.pickup_radius_bonus else 0;
        const modifier = self.sumEffectModifier(.pickup_radius) +
            @as(i32, @intCast(pants_bonus));
        return applyModifier(base_radius, modifier);
    }

    pub fn getEffectiveDefense(self: Entity) u32 {
        const coat_bonus: u32 = if (self.coat) |coat| coat.defense_bonus else 0;
        const modifier = self.sumEffectModifier(.defense) +
            @as(i32, @intCast(coat_bonus));
        return applyModifier(self.defense, modifier);
    }

    /// Effective max health = base `max_health` + the `health_bonus` from
    /// every equipped gear piece that carries one (coat/gloves/pants/boots).
    /// No effect modifier field exists for max health, so gear-only. Derived
    /// on every read — gear changes clamp `current_health` to this (see
    /// `applyGearChangeSideEffects`), so the invariant
    /// `current_health ≤ getEffectiveMaxHealth()` holds.
    pub fn getEffectiveMaxHealth(self: Entity) u32 {
        const coat_bonus: u32 = if (self.coat) |coat| coat.health_bonus else 0;
        const gloves_bonus: u32 = if (self.gloves) |gloves| gloves.health_bonus else 0;
        const pants_bonus: u32 = if (self.pants) |pants| pants.health_bonus else 0;
        const boots_bonus: u32 = if (self.boots) |boots| boots.health_bonus else 0;
        return self.max_health + coat_bonus + gloves_bonus + pants_bonus + boots_bonus;
    }

    /// Resolve a skill bar slot (1-8) to a SkillId for this entity.
    /// Slots 1-2 are main-hand weapon skills, slot 3 the off-hand weapon
    /// skill, slots 4-8 the equipped utility skills (indices 0-4).
    pub fn skillInSlot(
        self: Entity,
        slot: u8,
        weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    ) ?SkillId {
        return switch (slot) {
            1 => if (self.main_hand_weapon) |weapon| weapon_type_definitions[@intFromEnum(weapon.weapon_type)].skill_1 else null,
            2 => if (self.main_hand_weapon) |weapon| weapon_type_definitions[@intFromEnum(weapon.weapon_type)].skill_2 else null,
            3 => if (self.off_hand_weapon) |weapon| weapon_type_definitions[@intFromEnum(weapon.weapon_type)].skill_3 else null,
            4, 5, 6, 7, 8 => self.equipped_utility_skills[slot - 4],
            else => null,
        };
    }

    /// All skill bar slots (1-8) collected in order at indices 0-7.
    pub fn collectSkillSlots(
        self: Entity,
        weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    ) [utility_skill_count + 3]?SkillId {
        var result: [utility_skill_count + 3]?SkillId = undefined;
        for (&result, 0..) |*entry, index| {
            entry.* = self.skillInSlot(@intCast(index + 1), weapon_type_definitions);
        }
        return result;
    }

    /// Every skill id on the entity's combat bar, INCLUDING the
    /// swap-available third skills of BOTH equipped weapons (hand-swap
    /// exposes them) plus the equipped utility skills. Slot order: main
    /// weapon 1-3, off weapon 1-3 (deduped when both hands carry the same
    /// type), then utility slots. Distinct from collectSkillSlots (the 8
    /// EXPOSED slots) — this is the full equippable set; used by Adrenaline
    /// Surge's reset + rating (both sides share it so they cannot drift).
    pub fn onBarSkillIds(
        self: Entity,
        weapon_type_definitions: WeaponTypeDefinitions,
    ) [on_bar_skill_count]?SkillId {
        var result: [on_bar_skill_count]?SkillId = .{null} ** on_bar_skill_count;
        var length: usize = 0;

        const hands = [2]?Weapon{ self.main_hand_weapon, self.off_hand_weapon };
        for (hands) |maybe_weapon| {
            const weapon = maybe_weapon orelse continue;
            const definition = weapon_type_definitions[@intFromEnum(weapon.weapon_type)];
            const type_skills = [weapon_skills_per_type]SkillId{
                definition.skill_1,
                definition.skill_2,
                definition.skill_3,
            };
            for (type_skills) |skill_id| {
                var duplicate = false;
                for (result[0..length]) |existing| {
                    if (existing == skill_id) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    result[length] = skill_id;
                    length += 1;
                }
            }
        }

        for (self.equipped_utility_skills) |maybe_skill_id| {
            const skill_id = maybe_skill_id orelse continue;
            var duplicate = false;
            for (result[0..length]) |existing| {
                if (existing == skill_id) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                result[length] = skill_id;
                length += 1;
            }
        }

        return result;
    }
};

pub const GroundItems = struct {
    position: Vector2,
    items: []const Item,
};

pub const MaterialType = enum {
    wood,
    metal,
    leather,
    cloth,
    knowledge,
};

pub const Materials = struct {
    wood: u32 = 0,
    metal: u32 = 0,
    leather: u32 = 0,
    cloth: u32 = 0,
    knowledge: u32 = 0,

    pub fn add(self: *Materials, other: Materials) void {
        self.wood += other.wood;
        self.metal += other.metal;
        self.leather += other.leather;
        self.cloth += other.cloth;
        self.knowledge += other.knowledge;
    }
};

pub const SalvageSplit = struct {
    material: MaterialType,
    parts: u32,
};

pub const SalvageDefinition = struct {
    splits: []const SalvageSplit,
};

pub const item_type_count = @typeInfo(ItemType).@"union".fields.len;
pub const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;

/// Skills per weapon type (skill_1..skill_3 in WeaponTypeDefinition).
const weapon_skills_per_type: usize = 3;

/// Size of Entity.onBarSkillIds: both equipped weapons' full skill sets
/// (swap-available thirds included) + the utility slots.
const on_bar_skill_count: usize = 2 * weapon_skills_per_type + utility_skill_count;

/// Salvage definitions for all item types.
/// Non-weapon items are indexed by their position in the ItemType union
/// (skipping .weapon, which uses per-weapon-type definitions).
pub const SalvageDefinitions = struct {
    weapon: [weapon_type_count]SalvageDefinition,
    amulet: SalvageDefinition,
    coat: SalvageDefinition,
    gloves: SalvageDefinition,
    pants: SalvageDefinition,
    boots: SalvageDefinition,
    skill_tome: SalvageDefinition,
};

pub const inventory_columns = 8;
pub const inventory_rows = 12;
pub const inventory_slot_count = inventory_columns * inventory_rows;

pub const Inventory = struct {
    slots: [inventory_slot_count]?Item = .{null} ** inventory_slot_count,
};

pub const Clone = struct {
    /// The mission this clone records (the key — see DESIGN → Custom Missions
    /// & Online Services → Content identity). Replaces the old name-keying.
    mission_uuid: []const u8 = &.{},
    /// Display label (denormalized from the mission at save time so a
    /// clones-list UI can render without re-reading mission files).
    name: []const u8 = &.{},
    turns_to_complete: u32 = 0,
    materials_collected: Materials = .{},
};

pub const PlayerData = struct {
    player_name: []const u8 = &.{},
    current_campaign: []const u8 = &.{},
    current_hub: []const u8 = &.{},
    materials: Materials = .{},
    clones: []const Clone = &.{}, // will also be used to identify completed missions - maybe per campaign also?
    discovered_hubs: []const Hub = &.{}, // change to be per campaign
    learned_skills: []const SkillId = &.{},
    turns: u32 = 0,
    deaths: u32 = 0,
    defeated_enemies: u32 = 0,
    skills_used: u32 = 0,

    main_hand_weapon: ?Weapon = null,
    off_hand_weapon: ?Weapon = null,
    amulet: ?Amulet = null,
    coat: ?Coat = null,
    gloves: ?Gloves = null,
    pants: ?Pants = null,
    boots: ?Boots = null,
    inventory: Inventory = .{},
    equipped_utility_skills: [utility_skill_count]?SkillId = .{null} ** utility_skill_count,
};

// A palette entry: a reusable entity definition (the "prefab"). Placements
// reference a type by index into Editor.entity_types. The template is a full
// Entity (reuses the type + deepCopy); runtime fields (current_health,
// is_active, momentum, stun, cooldowns, active_effects, inventory) are
// meaningless on the template and reset by instantiateEditorLevel. Editing
// the template updates every placement referencing this type — no
// propagation sweep.
pub const EntityTypeDef = struct {
    id: []const u8 = &.{}, // user-facing name, e.g. "Skeleton Warrior"
    template: Entity = .{},
};

pub const DecorationTypeDef = struct {
    id: []const u8 = &.{}, // user-facing name / sprite stem
    sprite: []const u8 = &.{},
    // Sprite-grid footprint + pixel dims; see Decoration for semantics.
    footprint: []const Vector2 = &.{},
    pixel_dims: Vector2 = .{ .x = 0, .y = 0 },
    color_index: u32 = 0,
    /// Untinted rendering (base + layers keep the art's colors) — see
    /// Decoration.keep_original_colors.
    keep_original_colors: bool = false,
    layers: []const DecorationLayer = &.{},
};

/// A palette entry for a loose ground item (loot not tied to an enemy).
/// The `item` carries the full Item union (the authorable kinds — never
/// a skill tome in practice); the inspector commits it via the FLATTENED
/// `editor_set_item_def` event (whole item, one undo step) +
/// `editor_set_item_name` for renames. See DESIGN → Architecture →
/// Level Editor → Editor UI layout (Inspector fields, item types).
pub const ItemTypeDef = struct {
    id: []const u8 = &.{}, // user-facing name, e.g. "Iron Sword"
    item: Item = .{ .weapon = .{} },
};

/// Which entity-type-like target an entity-edit event applies to. The
/// player loadout (`Editor.player_def`) is an EntityTypeDef too, just not
/// in the `entity_types` array — this union lets the entity-edit events
/// cover both without a parallel `editor_set_player_*` event set. See
/// DESIGN → Architecture → Level Editor → Editor UI layout.
pub const EntityEditTarget = union(enum) {
    entity_type: u32, // index into Editor.entity_types
    player_def: void, // the editor-global player loadout
};

/// Which GameState field a focused text-input widget is editing (see
/// DESIGN → UI Framework → Text input widget). The id tells the commit
/// path (input_handlers) how to parse the buffer and which wrapper event
/// to push; `target` names the entity being edited. Ids land incrementally
/// with the inspector slices. UiState-only — never serialized into events
/// (the events carry values).
pub const TextFieldId = union(enum) {
    entity_name,
    entity_stat: EntityStatField,
    /// The equipped item's name in `slot` (an empty slot commits nothing).
    item_name: GearSlot,
    /// One numeric stat of the equipped item in `slot` (a stat the item
    /// kind doesn't carry commits nothing).
    item_stat: struct { slot: GearSlot, stat: ItemStatField },
    /// A palette item TYPE's name (the Items group's inspector content —
    /// a skill tome commits nothing, tomes aren't authorable). Target:
    /// `.item_type` carries the palette index.
    item_def_name: void,
    /// One numeric stat of a palette item type (same target + tome rule
    /// as `item_def_name`; clamped to `itemStatMax` at commit).
    item_def_stat: ItemStatField,
    /// An INVENTORY slot item's name (the player inspector's Inventory
    /// section detail rows — a tome commits nothing, tomes aren't
    /// authorable). Target: `.inventory_slot` carries the slot index.
    inventory_item_name: void,
    /// One numeric stat of an inventory slot item (same target + tome
    /// rule as `inventory_item_name`; clamped to `itemStatMax` at
    /// commit).
    inventory_item_stat: ItemStatField,
    /// The edited mission's name (metadata sidebar). Target: `.mission`.
    mission_name: void,
    /// The edited level's name (metadata sidebar, the tab it was focused
    /// on). Target: `.level` carries the level index.
    level_name: void,
};

/// What a focused text field edits: an entity template (inspector), the
/// mission's name, or a level's name (metadata sidebar — the level index
/// rides the target so a mid-edit tab switch can't retarget the commit).
pub const TextEditTarget = union(enum) {
    entity: EntityEditTarget,
    /// A palette item type (the Items group's inspector content). Carries
    /// the palette index so a mid-edit tool switch can't retarget the
    /// commit (the level-name pattern).
    item_type: u32,
    /// An inventory slot in the player loadout (the Inventory section's
    /// detail rows). Carries the slot index so a mid-edit selection
    /// change can't retarget the commit (the level-name pattern).
    inventory_slot: u32,
    mission: void,
    level: u32,
};

/// Identity of one focused text field.
pub const TextFieldRef = struct {
    id: TextFieldId,
    target: TextEditTarget,
};

/// A focused text field's per-frame keyboard outcome (Enter commits,
/// Escape discards — see DESIGN → UI Framework → Text input widget).
pub const TextEditOutcome = enum { none, commit, cancel };

// A reference-based level: placements point into the editor's palette instead
// of carrying full entity/decoration definitions. Serializes back to the
// existing inline level format (the editor save flattens placements into
// per-level Entries/Decorations groups). The player spawn is the '!' in
// level_tiles (as in shipped levels); the player loadout is editor-global
// (Editor.player_def), not per-level.
pub const EditorLevel = struct {
    name: []const u8 = &.{},
    color_wheel_index: u32 = 0,
    /// Optional per-role gradient override. Null (the default) = derived
    /// from `color_wheel_index` (enemy = world + N/3, player = world +
    /// 2·N/3, N = gradients in the theme — the `deriveActiveColorTheme`
    /// rule). See DESIGN → Architecture → Level Editor → Level theme.
    enemy_gradient_index: ?u32 = null,
    player_gradient_index: ?u32 = null,
    level_tiles: []const Vector2 = &.{},
    player_start: Vector2 = .{ .x = 0, .y = 0 }, // the '!' position
    level_end: ?Vector2 = null,
    entity_placements: []const EntityPlacement = &.{},
    decoration_placements: []const DecorationPlacement = &.{},
    /// Loose floor items placed via the Items palette (loot not tied
    /// to an enemy). Mirrors Level.ground_items but reference-based: each
    /// placement points into Editor.item_types. See DESIGN → Architecture →
    /// Level Editor → Editor UI layout (Ground items — the Items palette).
    item_placements: []const ItemPlacement = &.{},
};

pub const EntityPlacement = struct {
    type_id: u32, // index into Editor.entity_types
    position: Vector2,
};

pub const ItemPlacement = struct {
    type_id: u32, // index into Editor.item_types
    position: Vector2,
};

pub const DecorationPlacement = struct {
    type_id: u32, // index into Editor.decoration_types
    position: Vector2,
};

pub const EditorMode = enum {
    edit, // UI/input = editor; levels array is the source of truth
    playtest, // UI/input = gameplay; current.level is live, editor dormant
    validate, // UI/input = gameplay, forced full-mission; editor dormant
};

/// The active editor tool (the palette selection) — what a viewport click
/// does (see DESIGN → Architecture → Level Editor → Active-tool model).
/// Lives on the Editor (GameState, undo timeline): any event whose effect
/// depends on it (the click orchestrators) must read it from reconstructable
/// state, and undo/redo of a tool switch restores what the author had
/// active. Indices are into the corresponding Editor palette arrays.
/// Which tab the editor's centered sprite picker is showing (see
/// DESIGN → Architecture → Level Editor → Editor UI layout — the centered
/// sprite picker). Mission-local first: custom assets take priority over
/// shipped ones.
pub const EditorSpritePickerTab = enum {
    mission_local,
    official,
};

/// Which editor kind the editor browser shows — one tab per kind (the
/// tab row derives from this enum). Mission is the only editor kind
/// today; hub + campaign append when those editors land (the
/// editor-browser label switch is exhaustive, so a new member is a
/// compile error until classified). See DESIGN → Architecture →
/// Level Editor → The editor browser.
pub const EditorKind = enum {
    mission,
};

/// Which tab the editor browser's mission list is showing (see DESIGN →
/// Architecture → Level Editor → The editor browser). Local = the
/// player's saved/imported missions under `missions/` in the persistent
/// dir; Official = the shipped embedded campaign missions.
pub const EditorMissionBrowserTab = enum {
    local,
    official,
};

/// One collapsible section of the editor's side panels. The ids key BOTH
/// the inspector's content (enemy or player) and the METADATA sidebar's
/// Mission / Current-level sections — one shared expansion-state array
/// (`UiState.editor_inspector_section_expanded`), one toggle action. The
/// id is the section's IDENTITY across contents (Weapons expanded while
/// editing an enemy stays expanded on the player) and the key into that
/// array — collapse is a VIEW affordance (off the undo timeline, like the
/// palette accordion), not GameState. Labels via
/// `ui.editorInspectorSectionLabel`.
pub const EditorInspectorSectionId = enum {
    identity,
    stats,
    weapons,
    gear,
    utility_skills,
    inventory,
    player,
    /// The decoration type's footprint (tile count summary + the future
    /// footprint editor's home). Decoration content only.
    footprint,
    /// The layer stack (enemy + decoration types; the player loadout has
    /// no layers).
    layers,
    /// The item type's fields (the Items palette group's inspector
    /// content: the type-pick rows + name + stats). Item content only.
    item,
    /// The metadata sidebar's Mission section (the mission's name).
    mission,
    /// The metadata sidebar's Current-level section (the active level's
    /// name + gradient rows).
    current_level,
};

pub const EditorToolId = union(enum) {
    select: void,
    tile: void,
    entity_type: u32,
    decoration_type: u32,
    item_type: u32,
};

/// Which gradient role a settings-sidebar gradient row (or its picker)
/// addresses: the world index is always picked; enemy / player are
/// optional overrides that auto-derive from it when unset (see DESIGN →
/// Architecture → Level Editor → Level theme).
pub const LevelGradientRole = enum {
    world,
    enemy,
    player,
};

/// One selectable thing in the editor viewport (the select tool's click
/// target; see DESIGN → Architecture → Level Editor → Selection model).
/// Placement entries address the ACTIVE level's placement lists by index
/// — kept consistent by the delete arms (the deleted entry is pruned and
/// the indices above it are remapped; the render's bounds-check is
/// defensive only). The selection set lives on the Editor (GameState, on
/// the undo timeline) and is mutated only via the `editor_select` /
/// `editor_deselect` events — so undo/redo restores the selection of that
/// time, and selection-dependent operations (group move) replay safely.
pub const Selectable = union(enum) {
    /// A floor tile at `position` (a paint/erase target).
    tile: Vector2,
    entity_placement: u32,
    decoration_placement: u32,
    ground_item_placement: u32,
    /// The '!' — singleton, movable never deletable.
    player_start: void,
    /// The '=' — singleton, movable never deletable.
    level_end: void,
};

/// One backed-up thing in a selection MOVE (the commit event's worklist —
/// see `player_move_editor_selection` / `editor_commit_selection_move`).
/// The backup is concrete (kind + type_id + TARGET position) because the
/// delete phase destroys the placements the selection addressed — the
/// type ids must survive in the payload. Placed sequentially by the
/// chained commit event, each against the live post-delete state via the
/// placement planners (the current placement rules — see DESIGN →
/// Architecture → Level Editor → Selection model).
pub const EditorSelectionMoveEntry = union(enum) {
    entity: struct {
        type_id: u32,
        position: Vector2,
    },
    decoration: struct {
        type_id: u32,
        position: Vector2,
    },
    item: struct {
        type_id: u32,
        position: Vector2,
    },
    /// A moved floor tile (paints at the target).
    tile: Vector2,
    /// The moved '!' (a tile is ensured under the new position).
    player_start: Vector2,
    /// The moved '=' (a tile is ensured under the new position).
    level_end: Vector2,
};

/// Inclusive tile-coordinate bounding box (min corner tile .. max
/// corner tile, both inclusive) of a set of tiles. Zoom-independent —
/// the camera clamp converts to world pixels per frame.
pub const TileBounds = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
};

/// The in-game middle-panel ids (the middle band between the world and
/// the bottom bar). Ordered by open time inside `UiSurfaceState` — slot
/// order IS display order.
pub const MiddlePanelId = enum {
    inventory,
    gear,
    skills,
    entity_inspect,
};

/// The stackable full-screen overlays (drawn over the world + panels;
/// the last occupied slot draws on top).
pub const FullScreenOverlayId = enum {
    world_map,
    full_combat_log,
};

pub const max_middle_panels: usize = 4;
pub const max_full_screen_overlays: usize = 2;

/// One semantic UI surface the player can open/close — the event
/// vocabulary for `toggle_ui_surface`. The enum names the surface;
/// `UiSurfaceState` owns the grouped representation (display order,
/// stacking) behind these ids.
pub const UiSurfaceId = enum {
    options_menu,
    settings,
    load_save_menu,
    credits,
    editor_browser,
    inventory,
    gear,
    skills,
    entity_inspect,
    world_map,
    full_combat_log,
};

/// Class-1 semantic surface state: WHAT UI is open. Lives on GameState
/// (`ui_surfaces`) so it rides the undo timeline, replays, and is
/// reconstructable from the event log — which is what lets
/// `validatePlayerAction` gate gameplay orchestrators on the surface
/// that supplies their trigger. All mutation flows through the surface
/// events (`toggle_ui_surface` / `inspect_entity`); the handlers call
/// these methods. View affordances (tabs, scrolls, gesture lifecycles)
/// stay on `SessionState.ui_state` — see DESIGN → UI Framework → UI
/// state classification.
pub const UiSurfaceState = struct {
    /// Middle section panels, ordered by open time (first opened =
    /// leftmost). The open panels always occupy a contiguous prefix of
    /// the slots (closing compacts), so slot order IS display order and a
    /// reopened panel lands rightmost instead of recalling its pre-close
    /// slot.
    open_middle_panels: [max_middle_panels]?MiddlePanelId =
        .{null} ** max_middle_panels,

    /// Full-screen overlays that can stack (world map, full combat log).
    open_full_screen_overlays: [max_full_screen_overlays]?FullScreenOverlayId =
        .{null} ** max_full_screen_overlays,

    /// Options menu — always-on-top modal, locks input + pauses the world.
    options_menu_open: bool = false,

    /// Settings screen — modal overlay; opens on top of the options menu
    /// (in-game) or over the main menu.
    settings_open: bool = false,

    /// Load-save browser (main menu, full screen).
    load_save_menu_open: bool = false,

    /// Credits screen (main menu, full screen).
    credits_open: bool = false,

    /// Editor browser (main menu or editor, full screen).
    editor_browser_open: bool = false,

    /// The entity-inspect panel's target (null = no target). Bounds-
    /// checked at every read — a stale index (the entity died and the
    /// array shrank) renders nothing, never crashes.
    inspected_entity_index: ?u32 = null,

    /// Flip one surface — the verb behind `toggle_ui_surface` (the
    /// keyboard / menu-button semantics). The entity-inspect toggle also
    /// drops the panel's target (opens untargeted, like the keybind
    /// always did).
    pub fn toggle(self: *UiSurfaceState, surface: UiSurfaceId) void {
        switch (surface) {
            .options_menu => self.options_menu_open = !self.options_menu_open,
            .settings => self.settings_open = !self.settings_open,
            .load_save_menu => self.load_save_menu_open = !self.load_save_menu_open,
            .credits => self.credits_open = !self.credits_open,
            .editor_browser => self.editor_browser_open = !self.editor_browser_open,
            .inventory => self.toggleMiddlePanel(.inventory),
            .gear => self.toggleMiddlePanel(.gear),
            .skills => self.toggleMiddlePanel(.skills),
            .entity_inspect => {
                self.toggleMiddlePanel(.entity_inspect);
                self.inspected_entity_index = null;
            },
            .world_map => self.toggleFullScreenOverlay(.world_map),
            .full_combat_log => self.toggleFullScreenOverlay(.full_combat_log),
        }
    }

    pub fn isSurfaceOpen(self: *const UiSurfaceState, surface: UiSurfaceId) bool {
        return switch (surface) {
            .options_menu => self.options_menu_open,
            .settings => self.settings_open,
            .load_save_menu => self.load_save_menu_open,
            .credits => self.credits_open,
            .editor_browser => self.editor_browser_open,
            .inventory => self.isMiddlePanelOpen(.inventory),
            .gear => self.isMiddlePanelOpen(.gear),
            .skills => self.isMiddlePanelOpen(.skills),
            .entity_inspect => self.isMiddlePanelOpen(.entity_inspect),
            .world_map => self.isFullScreenOverlayOpen(.world_map),
            .full_combat_log => self.isFullScreenOverlayOpen(.full_combat_log),
        };
    }

    /// The right-click inspect verb: a non-null index OPENS (or retargets)
    /// the entity-inspect panel, null CLOSES it. The gesture resolves
    /// same/different/none against current state and pushes the resolved
    /// intent — the event itself is unconditional.
    pub fn inspectEntity(self: *UiSurfaceState, entity_index: ?u32) void {
        if (entity_index) |index| {
            self.openMiddlePanel(.entity_inspect);
            self.inspected_entity_index = index;
        } else {
            self.closeMiddlePanel(.entity_inspect);
            self.inspected_entity_index = null;
        }
    }

    /// Close every surface. The screen-transition / world-install reset —
    /// HANDLER-side (`transitionScreen` / the start_* world installs) so
    /// replay reproduces it; the classes-2–4 wholesale reset stays in the
    /// live loop. See DESIGN → UI Framework → UI state classification.
    pub fn closeAll(self: *UiSurfaceState) void {
        self.open_middle_panels = .{null} ** max_middle_panels;
        self.open_full_screen_overlays = .{null} ** max_full_screen_overlays;
        self.options_menu_open = false;
        self.settings_open = false;
        self.load_save_menu_open = false;
        self.credits_open = false;
        self.editor_browser_open = false;
        self.inspected_entity_index = null;
    }

    fn toggleMiddlePanel(self: *UiSurfaceState, panel_id: MiddlePanelId) void {
        if (self.isMiddlePanelOpen(panel_id)) {
            self.closeMiddlePanel(panel_id);
        } else {
            self.openMiddlePanel(panel_id);
        }
    }

    /// Open a panel (no-op when already open or all slots are taken).
    pub fn openMiddlePanel(self: *UiSurfaceState, panel_id: MiddlePanelId) void {
        if (self.isMiddlePanelOpen(panel_id)) return;
        var target_index: usize = 0;
        for (self.open_middle_panels, 0..) |maybe_panel, index| {
            if (maybe_panel != null) target_index = index + 1;
        }
        if (target_index < max_middle_panels) {
            self.open_middle_panels[target_index] = panel_id;
        }
    }

    /// Close a panel and compact the remaining ones down (the
    /// contiguous-prefix invariant above).
    fn closeMiddlePanel(self: *UiSurfaceState, panel_id: MiddlePanelId) void {
        for (&self.open_middle_panels) |*slot| {
            if (slot.*) |open| {
                if (open == panel_id) {
                    slot.* = null;
                    var write_index: usize = 0;
                    for (self.open_middle_panels) |maybe_panel| {
                        if (maybe_panel) |remaining| {
                            self.open_middle_panels[write_index] = remaining;
                            write_index += 1;
                        }
                    }
                    while (write_index < max_middle_panels) : (write_index += 1) {
                        self.open_middle_panels[write_index] = null;
                    }
                    return;
                }
            }
        }
    }

    /// Whether `panel_id` is currently open (the read-side companion of
    /// the toggles; view-side producers need to know a panel is showing
    /// without walking the slot array themselves).
    pub fn isMiddlePanelOpen(self: *const UiSurfaceState, panel_id: MiddlePanelId) bool {
        for (self.open_middle_panels) |maybe_panel| {
            if (maybe_panel) |open| {
                if (open == panel_id) return true;
            }
        }
        return false;
    }

    fn toggleFullScreenOverlay(self: *UiSurfaceState, overlay_id: FullScreenOverlayId) void {
        if (self.isFullScreenOverlayOpen(overlay_id)) {
            self.closeFullScreenOverlay(overlay_id);
        } else {
            self.openFullScreenOverlay(overlay_id);
        }
    }

    fn openFullScreenOverlay(self: *UiSurfaceState, overlay_id: FullScreenOverlayId) void {
        if (self.isFullScreenOverlayOpen(overlay_id)) return;
        for (&self.open_full_screen_overlays) |*slot| {
            if (slot.* == null) {
                slot.* = overlay_id;
                return;
            }
        }
    }

    fn closeFullScreenOverlay(self: *UiSurfaceState, overlay_id: FullScreenOverlayId) void {
        for (&self.open_full_screen_overlays) |*slot| {
            if (slot.*) |open| {
                if (open == overlay_id) {
                    slot.* = null;
                    return;
                }
            }
        }
    }

    fn isFullScreenOverlayOpen(self: *const UiSurfaceState, overlay_id: FullScreenOverlayId) bool {
        for (self.open_full_screen_overlays) |maybe_overlay| {
            if (maybe_overlay) |open| {
                if (open == overlay_id) return true;
            }
        }
        return false;
    }
};

test "UiSurfaceState.toggleMiddlePanel: open order is display order; reopen lands rightmost" {
    const Panels = [max_middle_panels]?MiddlePanelId;
    var surfaces = UiSurfaceState{};

    // Open order = slot order (leftmost first).
    surfaces.toggleMiddlePanel(.inventory);
    surfaces.toggleMiddlePanel(.skills);
    try std.testing.expectEqual(
        Panels{ .inventory, .skills, null, null },
        surfaces.open_middle_panels,
    );

    // Closing a middle panel compacts the rest (contiguous prefix).
    surfaces.toggleMiddlePanel(.inventory);
    try std.testing.expectEqual(
        Panels{ .skills, null, null, null },
        surfaces.open_middle_panels,
    );

    // Reopening appends rightmost — it does not recall its pre-close slot.
    surfaces.toggleMiddlePanel(.inventory);
    try std.testing.expectEqual(
        Panels{ .skills, .inventory, null, null },
        surfaces.open_middle_panels,
    );

    // Closing the rightmost panel leaves the prefix intact.
    surfaces.toggleMiddlePanel(.inventory);
    try std.testing.expectEqual(
        Panels{ .skills, null, null, null },
        surfaces.open_middle_panels,
    );
    surfaces.toggleMiddlePanel(.skills);
    try std.testing.expectEqual(
        Panels{ null, null, null, null },
        surfaces.open_middle_panels,
    );
}

test "UiSurfaceState.toggleMiddlePanel: a full panel strip ignores a new open" {
    const Panels = [max_middle_panels]?MiddlePanelId;
    var surfaces = UiSurfaceState{};
    for ([_]MiddlePanelId{ .inventory, .gear, .skills, .entity_inspect }) |panel_id| {
        surfaces.toggleMiddlePanel(panel_id);
    }
    // All four are open — a fifth panel id cannot be stored, so this
    // close-then-reopen pair must not clobber anything.
    surfaces.toggleMiddlePanel(.inventory);
    try std.testing.expectEqual(
        Panels{ .gear, .skills, .entity_inspect, null },
        surfaces.open_middle_panels,
    );
    surfaces.toggleMiddlePanel(.inventory);
    try std.testing.expectEqual(
        Panels{ .gear, .skills, .entity_inspect, .inventory },
        surfaces.open_middle_panels,
    );
    // The strip is full again; toggling a panel that is already open still
    // closes it, and the freed slot is usable.
    surfaces.toggleMiddlePanel(.entity_inspect);
    try std.testing.expectEqual(
        Panels{ .gear, .skills, .inventory, null },
        surfaces.open_middle_panels,
    );
}

test "UiSurfaceState.toggle routes each surface id to its field" {
    var surfaces = UiSurfaceState{};
    surfaces.toggle(.options_menu);
    surfaces.toggle(.settings);
    surfaces.toggle(.load_save_menu);
    surfaces.toggle(.credits);
    surfaces.toggle(.editor_browser);
    surfaces.toggle(.inventory);
    surfaces.toggle(.gear);
    surfaces.toggle(.world_map);
    surfaces.toggle(.full_combat_log);
    try std.testing.expect(surfaces.options_menu_open);
    try std.testing.expect(surfaces.settings_open);
    try std.testing.expect(surfaces.load_save_menu_open);
    try std.testing.expect(surfaces.credits_open);
    try std.testing.expect(surfaces.editor_browser_open);
    try std.testing.expectEqual(@as(?u32, null), surfaces.inspected_entity_index);
    try std.testing.expectEqualSlices(
        ?MiddlePanelId,
        &.{ .inventory, .gear, null, null },
        &surfaces.open_middle_panels,
    );
    try std.testing.expectEqualSlices(
        ?FullScreenOverlayId,
        &.{ .world_map, .full_combat_log },
        &surfaces.open_full_screen_overlays,
    );
    // isSurfaceOpen agrees with every route above.
    try std.testing.expect(surfaces.isSurfaceOpen(.options_menu));
    try std.testing.expect(surfaces.isSurfaceOpen(.settings));
    try std.testing.expect(surfaces.isSurfaceOpen(.inventory));
    try std.testing.expect(surfaces.isSurfaceOpen(.world_map));
    // Toggle flips back.
    surfaces.toggle(.options_menu);
    try std.testing.expect(!surfaces.options_menu_open);
}

test "UiSurfaceState.toggle entity_inspect drops the target (the keyboard shape)" {
    var surfaces = UiSurfaceState{};
    surfaces.inspectEntity(2);
    try std.testing.expect(surfaces.isSurfaceOpen(.entity_inspect));
    try std.testing.expectEqual(@as(?u32, 2), surfaces.inspected_entity_index);
    // The keyboard toggle closes a targeted panel...
    surfaces.toggle(.entity_inspect);
    try std.testing.expect(!surfaces.isSurfaceOpen(.entity_inspect));
    try std.testing.expectEqual(@as(?u32, null), surfaces.inspected_entity_index);
    // ...and opens it UNTARGETED (the panel shows no entity).
    surfaces.toggle(.entity_inspect);
    try std.testing.expect(surfaces.isSurfaceOpen(.entity_inspect));
    try std.testing.expectEqual(@as(?u32, null), surfaces.inspected_entity_index);
}

test "UiSurfaceState.inspectEntity opens, retargets, and closes" {
    var surfaces = UiSurfaceState{};
    surfaces.inspectEntity(1);
    try std.testing.expect(surfaces.isSurfaceOpen(.entity_inspect));
    try std.testing.expectEqual(@as(?u32, 1), surfaces.inspected_entity_index);
    // A retarget keeps one panel slot (never a second copy).
    surfaces.inspectEntity(4);
    try std.testing.expectEqual(@as(?u32, 4), surfaces.inspected_entity_index);
    try std.testing.expectEqualSlices(
        ?MiddlePanelId,
        &.{ .entity_inspect, null, null, null },
        &surfaces.open_middle_panels,
    );
    // Close.
    surfaces.inspectEntity(null);
    try std.testing.expect(!surfaces.isSurfaceOpen(.entity_inspect));
    try std.testing.expectEqual(@as(?u32, null), surfaces.inspected_entity_index);
}

test "UiSurfaceState.closeAll clears every surface" {
    var surfaces = UiSurfaceState{};
    surfaces.toggle(.options_menu);
    surfaces.toggle(.settings);
    surfaces.toggle(.credits);
    surfaces.toggle(.inventory);
    surfaces.toggle(.skills);
    surfaces.toggle(.world_map);
    surfaces.inspectEntity(3);
    surfaces.closeAll();
    try std.testing.expectEqual(UiSurfaceState{}, surfaces);
}

/// Which field the editor's centered picker is assigning (see
/// DESIGN → Architecture → Level Editor → Editor UI layout — the
/// centered sprite picker section; the skill picker is the first
/// consumer). The OPEN/CLOSE of the picker itself is class-1 surface
/// state: it lives on `Editor.picker` (GameState), mutated only via the
/// `editor_open_picker` / `editor_close_picker` events, so it rides the
/// undo timeline and replays — see DESIGN → UI Framework → UI state
/// classification. The transient side state (the footprint draft,
/// the sprite tab) stays on `UiState`.
pub const EditorPickerTarget = union(enum) {
    utility_skill_slot: u32,
    /// The edited entity type's base sprite (the inspector's Sprite row).
    entity_sprite: void,
    /// The edited decoration type's base sprite (the decoration
    /// inspector's Sprite row — official tab adopts a registry prefab,
    /// mission tab picks a custom stem).
    decoration_sprite: void,
    /// An ENTITY layer sprite (the enemy content's Layers section): the
    /// layer index being edited, null = add-new (the skill picker's slot
    /// pattern).
    entity_layer: ?u32,
    /// A DECORATION layer sprite — same shape; the official tab filters
    /// to the base type's dims (the load-time layer invariant).
    decoration_layer: ?u32,
    /// The decoration type's FOOTPRINT editor (the Footprint row): the
    /// full-size sprite with toggleable 256×256 grid cells; the draft
    /// rides `UiState.editor_footprint_draft`. Carries the TYPE ID it was
    /// opened on — the editor stays self-contained while tools switch
    /// mid-edit (the dropdown convention), and toggles/confirm can never
    /// silently apply to a different type.
    decoration_footprint: u32,
    /// The metadata sidebar's THEME PICKER (a gradient row's swatch):
    /// every gradient as a full-width strip, one pick per row. Carries
    /// the LEVEL INDEX it was opened on + the ROLE being picked (the
    /// world index, or an enemy/player override) — a mid-edit tab switch
    /// can't retarget the pick.
    level_gradient: struct { level_index: u32, role: LevelGradientRole },
};

pub const Editor = struct {
    mission: Mission = .{}, // metadata + path (the mission being edited)
    levels: []const EditorLevel = &.{}, // all levels, reference-based
    // Palette (editor-global). Derived by dedup on open_editor from the
    // levels' inline definitions; not persisted to disk (unused types are
    // lost on editor close — accepted as cleaner). See DESIGN → Architecture
    // → Level Editor.
    entity_types: []const EntityTypeDef = &.{},
    decoration_types: []const DecorationTypeDef = &.{},
    /// Palette of loose ground-item types (loot not tied to an enemy). See
    /// DESIGN → Architecture → Level Editor → Editor UI layout (Ground
    /// items — the Items palette).
    item_types: []const ItemTypeDef = &.{},
    // The editor-global player start loadout. Persistent as player.txt in the
    // mission directory (so a recorded validation replay is reproducible and
    // players picking up a custom mission can see the author's loadout).
    player_def: EntityTypeDef = .{},
    active_level_index: usize = 0, // which tab is open
    /// Snapshot of the ACTIVE level's tile bbox, refreshed only when the
    /// active level switches (open_editor / editor_set_active_level /
    /// editor_add_level / editor_delete_level clamping onto new content
    /// — see `refreshEditorClampBounds`). The camera clamp reads THIS, not
    /// the live tiles, so mid-edit tile changes never reframe the camera;
    /// undo/redo + replay reproduce it because the refresh rides the same
    /// events. Null = no tiles at snapshot time (the level was empty) —
    /// the unclamped editor camera. See DESIGN → Platform Seam → Camera
    /// clamping.
    clamp_bounds: ?TileBounds = null,
    /// The currently active tool (see `EditorToolId`). Set only via the
    /// `editor_set_tool` event; invariant: the select tool's selection is
    /// nonempty only while this is `.select` (a tool switch away from
    /// select clears it in the same event).
    active_tool: EditorToolId = .select,
    /// The select tool's selection set (see `Selectable`). Active-level-
    /// relative; cleared by `editor_set_active_level` and by any
    /// `editor_set_tool` to a non-select tool. Mutated only via the
    /// `editor_select` / `editor_deselect` events; the placement-delete
    /// arms keep it consistent within the same event (prune + remap).
    selection: []const Selectable = &.{},
    /// The session's real PlayerData, backed up while a playtest/validate
    /// run is active. The run BUILDS its own player_data (from
    /// `player_def`, all utility skills learned) because in-level events
    /// (use_skill_tome, salvage) mutate player_data directly — without the
    /// backup a playtest would corrupt campaign progress. Null while in
    /// edit mode (set on enter from .edit, restored + cleared by
    /// end_playtest / end_validation). On the undo timeline with the rest
    /// of the Editor. See DESIGN → Architecture → Level Editor →
    /// Playtest/validate framing.
    pre_playtest_player_data: ?PlayerData = null,
    /// The inspector sidebar's open state (the top-left toggle button;
    /// open by default). Lives on the Editor — not UiState — so the settled
    /// auto-open-on-new-type behavior can mutate it from the
    /// `editor_add_*_type` handlers, and replay reproduces it. Mutated only
    /// via `editor_toggle_inspector`.
    inspector_open: bool = true,
    /// The metadata sidebar's open state (the top-right toggle button;
    /// CLOSED on editor open — the metadata is a reference panel, not
    /// the first thing an author needs, unlike the inspector). Same
    /// convention as the inspector flag: on the Editor, mutated only via
    /// `editor_toggle_metadata_sidebar`, so the toggle rides the undo
    /// timeline and replay reproduces it.
    metadata_sidebar_open: bool = false,
    /// The centered picker's target, if open — which field the picker is
    /// assigning (see `EditorPickerTarget`). Same convention as the
    /// inspector flag: on the Editor, mutated only via `editor_open_picker`
    /// / `editor_close_picker` (the picker-commit handlers push the close
    /// as a child of the commit — one undo step for pick+close), so it
    /// rides the undo timeline and replay reproduces it. See DESIGN → UI
    /// Framework → UI state classification.
    picker: ?EditorPickerTarget = null,
    mode: EditorMode = .edit,
};

pub const ReplayViewer = struct {};

pub const Campaign = struct {
    name: []const u8 = &.{},
    start_hub: []const u8 = &.{},
};

/// Info carried through the end_level → end_mission → start_hub cascade for
/// the mission-complete overlay (mission name + path). Lives on GameState
/// (on the undo timeline) so undo/redo handles the overlay naturally — undo
/// to before completion clears it, redo re-shows it. See DESIGN → Architecture.
/// Info carried through the end_level → end_mission → start_hub cascade for
/// the mission-complete overlay. Lives on GameState (on the undo timeline) so
/// undo/redo handles the overlay naturally — undo to before completion clears
/// it, redo re-shows it. The `uuid` is the clone key (see DESIGN → Custom
/// Missions & Online Services → Content identity); `turns_spent` +
/// `converted_materials` snapshot the run so the hub-side overlay + the
/// manual-overwrite orchestrator can reconstruct `save_clone_info` without the
/// `Mission` (which is gone by the time the overlay renders in the hub). See
/// DESIGN → Architecture.
pub const MissionCompleteInfo = struct {
    uuid: []const u8 = &.{},
    name: []const u8,
    path: []const u8,
    turns_spent: u32 = 0,
    converted_materials: Materials = .{},
    /// Materials gained this run from harvesting all old clones (the
    /// `harvest_clones` payout). Shown in the mission-complete clone-rewards
    /// panel. See DESIGN → Clones (clone system).
    harvested_materials: Materials = .{},
    /// Run stats for the mission-complete stats panel.
    tiles_moved: u32 = 0,
    damage_dealt: u32 = 0,
    damage_taken: u32 = 0,
    skills_used: u32 = 0,
    /// True when a clone for this mission already exists AND the just-completed
    /// run was not strictly faster (turns — the personal-best rule). The
    /// overlay offers a manual "Overwrite Clone" button. False on a first
    /// completion (auto-saved) or a strictly-faster run (auto-overwrote). See
    /// DESIGN → Clones (clone system).
    overwrite_offered: bool = false,
    /// True when this "completion" was a VALIDATION RUN — end_validation
    /// populated the info so the mission-complete overlay renders over the
    /// editor as the validation stats screen (the session-side personal
    /// best / medal context rides SessionState; view() builds it). False
    /// for ordinary campaign completions (the end_mission → start_hub
    /// cascade). See DESIGN → Custom Missions & Online Services →
    /// Validation replay.
    validation: bool = false,
};

pub const Mission = struct {
    /// Stable identifier for this mission (clone key + custom-mission identity).
    /// See DESIGN → Custom Missions & Online Services → Content identity.
    uuid: []const u8 = &.{},
    name: []const u8 = &.{},
    path: []const u8 = &.{},
    level_count: u32 = 0,
    current_level_index: u32 = 0,
    /// Runtime working-copy flag: this mission is a VALIDATION RUN (loaded
    /// from the saved dir by start_validation). The live editor ALSO keys
    /// run behavior on editor.mode == .validate, but a cross-session replay
    /// of a validation replay has no Editor — this flag is what end_level's
    /// guard reads for the no-editor case. It rides the working copy so
    /// replay reproduces it and the end_validation transition discards it
    /// with the mission. Campaign missions never set it. See DESIGN →
    /// Custom Missions & Online Services → Validation replay.
    validation_run: bool = false,
    start_hub: ?[]const u8 = null,
    end_hub: ?[]const u8 = null,
    turns_spent: u32 = 0,
    /// Tiles the player moved this mission (incremented in `move_entity`,
    /// player-only). Shown on the mission-complete stats panel. See DESIGN
    /// → Clones (clone system).
    tiles_moved: u32 = 0,
    converted_materials_collected: Materials = .{},
    damage_dealt: u32 = 0,
    damage_taken: u32 = 0,
    skills_used: u32 = 0,
};

pub const TurnPhase = enum {
    player_move,
    player_attack,
};

pub const Level = struct {
    name: []const u8 = &.{},
    color_wheel_index: u32 = 0,
    /// Optional per-role gradient override (same semantics as
    /// EditorLevel's). Set by the editor's metadata sidebar; serialized as
    /// level-file Metadata keys.
    enemy_gradient_index: ?u32 = null,
    player_gradient_index: ?u32 = null,
    level_tiles: []const Vector2 = &.{},
    entities: []const Entity = &.{},
    ground_items: []const GroundItems = &.{},
    decorations: []const Decoration = &.{},
    level_end: ?Vector2 = null,
    highlighted_tiles: []const Vector2 = &.{},
    prepared_skill: ?SkillId = null,
    turn_phase: ?TurnPhase = null,

    /// Does the level still hold active enemies — anything alive,
    /// active, and on a team other than the player's (entity 0)? The one
    /// completability rule: shared by the win condition
    /// (`check_level_end`), the attack-step auto-skip, and the flag
    /// banner rendering (the banner waves only while this is false —
    /// see DESIGN → Animation).
    pub fn hasActiveEnemies(self: *const Level) bool {
        if (self.entities.len == 0) return false;
        const player_team = self.entities[0].team;
        for (self.entities, 0..) |entity, entity_index| {
            if (entity_index == 0) continue;
            if (entity.current_health == 0) continue;
            if (!entity.is_active) continue;
            if (entity.team != player_team) return true;
        }
        return false;
    }
};

pub const MissionExit = struct {
    mission_id: []const u8,
    position: Vector2,
};

pub const Hub = struct {
    name: []const u8 = &.{},
    color_wheel_index: u32 = 0,
    hub_tiles: []const Vector2 = &.{},
    player: Entity = .{},
    npcs: []const NPC = &.{},
    decorations: []const Decoration = &.{},
    mission_exits: []const MissionExit = &.{},
};

pub const NPC = struct {
    entity: Entity,
};

test "Level.hasActiveEnemies: alive + active + hostile; dead / inactive / same-team are not" {
    // The one completability rule: an enemy counts only when ALL THREE
    // hold — alive, active, hostile team. The win condition
    // (`check_level_end`), the attack-step auto-skip, and the flag banner
    // gate on it (see the method's doc).
    const enemy = Entity{ .team = 1, .is_active = true };

    // Alive + active + hostile → true.
    {
        const entities = [_]Entity{ .{}, enemy };
        try std.testing.expect((Level{ .entities = &entities }).hasActiveEnemies());
    }
    // Dead → not an active enemy.
    {
        var dead = enemy;
        dead.current_health = 0;
        const entities = [_]Entity{ .{}, dead };
        try std.testing.expect(!(Level{ .entities = &entities }).hasActiveEnemies());
    }
    // Inactive → not an active enemy.
    {
        var inactive = enemy;
        inactive.is_active = false;
        const entities = [_]Entity{ .{}, inactive };
        try std.testing.expect(!(Level{ .entities = &entities }).hasActiveEnemies());
    }
    // Same team as the player (a helper) → not an enemy.
    {
        var helper = enemy;
        helper.team = 0;
        const entities = [_]Entity{ .{}, helper };
        try std.testing.expect(!(Level{ .entities = &entities }).hasActiveEnemies());
    }
    // Only the player → false; no entities at all → false (defensive —
    // levels always carry the player first, but the method must not read
    // entities[0] on an empty slice).
    {
        const entities = [_]Entity{.{}};
        try std.testing.expect(!(Level{ .entities = &entities }).hasActiveEnemies());
        try std.testing.expect(!(Level{ .entities = &.{} }).hasActiveEnemies());
    }
}

// ============================================================
// View state — output of view(), input to renderer
// ============================================================

/// Fixed reference (design) resolution. The view function + all UI layout
/// math produce coordinates in this space; the renderer draws them into a
/// separate (possibly smaller) render target via a camera zoom, then blits
/// to the window. See DESIGN → Platform Seam → Render target resolution.
pub const reference_width: i32 = 3840;
pub const reference_height: i32 = 2160;

/// Offscreen render target resolution (the `render_resolution` setting, a
/// runtime 4-choice — see `RenderResolution` below). The backend creates its
/// `RenderTexture` at this size and scales 4K design-space content into it
/// via `beginMode2D`. Lower than reference → less fill rate. All presets
/// share the reference aspect ratio (16:9, comptime-checked below) — the
/// camera zoom is uniform, so a mismatched aspect would squish content.
pub const RenderResolution = enum {
    p720,
    p1080,
    p1440,
    p2160,

    /// The value as written in settings files and shown on the settings
    /// screen. The single mapping source for parse (loader), write
    /// (writer), and display (settings screen) — one spelling everywhere.
    pub fn label(resolution: RenderResolution) []const u8 {
        return switch (resolution) {
            .p720 => "720p",
            .p1080 => "1080p",
            .p1440 => "1440p",
            .p2160 => "2160p",
        };
    }

    /// Offscreen target pixel dimensions. 16:9 by construction (the presets
    /// are the only values, comptime-checked below).
    pub fn pixelDimensions(resolution: RenderResolution) struct { width: i32, height: i32 } {
        return switch (resolution) {
            .p720 => .{ .width = 1280, .height = 720 },
            .p1080 => .{ .width = 1920, .height = 1080 },
            .p1440 => .{ .width = 2560, .height = 1440 },
            .p2160 => .{ .width = 3840, .height = 2160 },
        };
    }
};

/// Default `render_resolution`. Both the `Settings` default and the render
/// target the backend creates at init (before settings load), so the
/// last-applied snapshot starts in sync with the backend's actual target.
pub const default_render_resolution: RenderResolution = .p1080;

// Comptime aspect-ratio guard: the camera zoom (`render_width /
// reference_width`) must be uniform, so the render target's aspect ratio
// must match the reference's. A preset with a mismatched aspect fails at
// compile time with a clear message rather than rendering squished content.
comptime {
    for (std.meta.tags(RenderResolution)) |resolution| {
        const dims = resolution.pixelDimensions();
        if (dims.width * reference_height != dims.height * reference_width) {
            @compileError("render target aspect ratio must match reference (16:9): " ++
                resolution.label() ++ " must be in the same ratio as 3840/2160");
        }
    }
}

/// Screen-space position in the reference resolution coordinate system.
/// Integer because we work in a fixed logical resolution.
pub const ScreenPosition = struct {
    x: i32,
    y: i32,
};

/// Horizontal or vertical alignment of a child within a parent.
pub const Align = enum { start, center, end };

/// Axis-aligned rectangle in screen space.
///
/// Layout is expressed by deriving new rectangles from existing ones:
/// shrink a panel to its content area with `inset`, slide a group with
/// `translate`, and drop a fixed-size child into a region with the
/// `place*` family (a 3\u00d73 grid of named anchors). Every method is pure
/// — it returns a new value and never mutates the receiver.
pub const Rectangle = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    // -- derived coordinates --

    pub fn position(self: Rectangle) ScreenPosition {
        return .{ .x = self.x, .y = self.y };
    }
    pub fn right(self: Rectangle) i32 {
        return self.x + self.width;
    }
    pub fn bottom(self: Rectangle) i32 {
        return self.y + self.height;
    }
    /// True when `point` lies inside the rectangle. Right/bottom edges are
    /// exclusive, matching the hit-testing convention used elsewhere.
    pub fn contains(self: Rectangle, point: ScreenPosition) bool {
        return point.x >= self.x and point.x < self.right() and
            point.y >= self.y and point.y < self.bottom();
    }

    // -- transforms --

    /// Slide the rectangle by an offset (used to scroll a group as one).
    pub fn translate(self: Rectangle, delta_x: i32, delta_y: i32) Rectangle {
        return .{ .x = self.x + delta_x, .y = self.y + delta_y, .width = self.width, .height = self.height };
    }

    /// Shrink inward on all four sides (e.g. panel border \u2192 content area).
    pub fn inset(self: Rectangle, amount: i32) Rectangle {
        return .{
            .x = self.x + amount,
            .y = self.y + amount,
            .width = self.width - 2 * amount,
            .height = self.height - 2 * amount,
        };
    }

    // -- child placement (3\u00d73 named anchors) --
    // Each drops a `child_width`\u00d7`child_height` box inside self at the
    // named anchor. `margin` insets from whichever edges are used; the
    // center axis ignores it.

    fn placeChild(
        self: Rectangle,
        child_width: i32,
        child_height: i32,
        horizontal: Align,
        vertical: Align,
        margin: i32,
    ) Rectangle {
        const x = switch (horizontal) {
            .start => self.x + margin,
            .center => self.x + @divTrunc(self.width - child_width, 2),
            .end => self.right() - child_width - margin,
        };
        const y = switch (vertical) {
            .start => self.y + margin,
            .center => self.y + @divTrunc(self.height - child_height, 2),
            .end => self.bottom() - child_height - margin,
        };
        return .{ .x = x, .y = y, .width = child_width, .height = child_height };
    }

    pub fn placeTopCenter(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .center, .start, margin);
    }
    pub fn placeCenter(self: Rectangle, w: i32, h: i32) Rectangle {
        return self.placeChild(w, h, .center, .center, 0);
    }
    pub fn placeBottomLeft(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .start, .end, margin);
    }
    pub fn placeBottomCenter(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .center, .end, margin);
    }
};

// -- Layer 1: Tiles --

pub const TileDrawable = struct {
    screen_position: ScreenPosition,
    color: Color,
};

// -- Layer 2: Tile overlays --

pub const TileOverlayType = enum {
    highlight,
    range_outline,
    radius_outline,
    aggro_outline,
    cursor,
    /// One edge segment of an arbitrary tile-region outline (the editor
    /// decoration footprint preview): the drawable's 1-tile square is a
    /// region tile and `edge` says which of its sides to stroke. The
    /// producer emits one segment per boundary edge (a side whose
    /// neighbor is outside the region), so any region shape — L-shapes,
    /// disjoint regions — renders as a continuous outline.
    region_edge,
};

/// Which side of a `region_edge` overlay's tile square gets stroked.
pub const TileOverlayEdge = enum { top, bottom, left, right };

pub const TileOverlayDrawable = struct {
    screen_position: ScreenPosition,
    overlay_type: TileOverlayType,
    color: Color,
    /// Square side in tiles. 1 for per-tile overlays (highlight, cursor,
    /// region_edge); the range/radius outline spans `extent` tiles centered
    /// on the player.
    extent: u32 = 1,
    /// Which side of the tile square a `region_edge` overlay strokes.
    /// Unused by the other overlay types.
    edge: TileOverlayEdge = .top,
};

// -- Layer 3: Ground drawables --

pub const SpriteDrawable = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    /// Offset from screen_position for rendering (e.g. decoration
    /// overhang drawn above the footprint tile).
    draw_offset: ScreenPosition,
    /// Region of the sprite to draw. Null means the full sprite.
    source_rectangle: ?Rectangle,
    color: Color,
    /// Mirror the sprite left-right when drawn. Used for off-hand weapons: the
    /// weapon art is authored on the left (main hand); flipping puts it on the
    /// right for the off hand.
    flip_horizontal: bool = false,
};

pub const HealthBarDrawable = struct {
    screen_position: ScreenPosition,
    width: i32,
    height: i32,
    /// 0 = empty, 1 = full. `current_health / max_health`.
    fill_fraction: f32,
    /// Depleted portion (the background drawn full). Global theme darkest.
    depleted_color: Color,
    /// Filled portion. Team gradient index 1 (player → player gradient,
    /// enemy → enemy gradient).
    fill_color: Color,
};

pub const EntityDrawable = struct {
    back_effect_sprites: []const SpriteDrawable,
    base_sprite: SpriteDrawable,
    /// Overlay body layers (armor/clothing), drawn after base, before weapons.
    /// Each colored independently. See DESIGN → Decorations & Footprint.
    layer_sprites: []const SpriteDrawable,
    weapon_sprites: [2]?SpriteDrawable,
    gear_sprites: []const SpriteDrawable,
    front_effect_sprites: []const SpriteDrawable,
    health_bar: ?HealthBarDrawable,
};

pub const DecorationPieceDrawable = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    draw_offset: ScreenPosition,
    source_rectangle: Rectangle,
    color: Color,
    /// Back layer chunks (`behind` layers) drawn BEFORE the base at the same
    /// position + source rect, each with its own sprite + color. Config
    /// order preserved within the slice. Empty for single-sprite decorations.
    back_layers: []const SpriteDrawable = &.{},
    /// Overlay layer chunks drawn over the base at the same position + source
    /// rect, each with its own sprite + color. Empty for single-sprite
    /// decorations. Drawn in slice order after the base.
    layers: []const SpriteDrawable = &.{},
};

pub const GroundItemDrawable = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    color: Color,
    item_count: u32,
};

pub const LevelEndDrawable = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    color: Color,
    /// Tint for the animated banner overlay (drawn over the pole). The pole
    /// and banner are colored independently — pole = world gradient index 5,
    /// banner = index 0 (see DESIGN → Decorations & Footprint / flag pole).
    banner_color: Color = .{ .r = 255, .g = 255, .b = 255 },
    /// Source rectangle for the animated banner overlay (`world/flag`), or
    /// null when there is no banner (keeps the drawable backward-compatible).
    /// The banner is drawn over the pole at the same screen position + pivot;
    /// each frame is 256x512, advanced at `settings.animation_fps`. Computed
    /// in view() from `session.animation_clock` (looping anim — no per-instance
    /// state). See DESIGN → Animation.
    banner_source_rectangle: ?Rectangle = null,
};

pub const GroundDrawable = union(enum) {
    entity: EntityDrawable,
    decoration_piece: DecorationPieceDrawable,
    ground_items: GroundItemDrawable,
    level_end: LevelEndDrawable,
};

// -- Layer 3.5: World overlays (floating indicators above world sprites) --

/// A one-shot sprite animation tied to a gameplay moment (see DESIGN →
/// Animation). `event_index` is the index of the triggering event in
/// `event_history` (stored as `current_event_index - 1` at push time, since
/// `processEvent` increments before dispatch). `duration_us` is the display
/// duration in microseconds; `frame()` stamps `end_clock` when it moves the
/// anim from the pending queue to the active list. The kind carries the
/// payload `view()` needs to place and draw it.
/// The opaque-pixel bounding box of a sprite, in SOURCE pixels (0-based from
/// the top-left). Each edge is the coordinate of the outermost non-transparent
/// pixel on that side, or null if the sprite can't be loaded/decoded or is
/// fully transparent (the caller falls back to the frame edge). Lazily decoded
/// + cached in the backend, threaded through `RenderContext.sprite_bounds` so
/// `view()` can place overlays against an entity's actual rendered art
/// (skill icon above the top, hit flash at the vertical center, damage number
/// at a corner). See DESIGN → Animation.
pub const SpriteBounds = struct {
    top: ?i32,
    bottom: ?i32,
    left: ?i32,
    right: ?i32,
};

pub const AnimKind = union(enum) {
    /// Show a skill's icon above the casting entity for `duration_us`.
    skill_icon: struct { entity_index: u32, skill_id: SkillId },
    /// Flash the hit sprite centered on a damaged entity's rendered art
    /// for `duration_us`. Triggered by `attack`/`collision` only when the
    /// defender takes nonzero damage. See DESIGN → Animation.
    hit_flash: struct { entity_index: u32 },
    /// Float a damage number away from the defender's sprite, in the
    /// normalized attacker→defender direction (one of 8), starting from the
    /// bbox edge/corner nearest that direction and traveling 1 tile with
    /// ease-out. `value` is the incoming damage dealt (may be 0 — a
    /// fully-absorbed hit still renders a "0" so the connection is
    /// observable; only the hit flash is gated on > 0). Triggered by
    /// `attack`/`collision`. Per-entity staggered (0.125s gap) so
    /// same-entity multi-hits (e.g. Bash's attack+collision) don't
    /// overlap. See DESIGN → Animation.
    damage_number: struct {
        entity_index: u32,
        value: u32,
        /// Unit vector (-1/0/1 per axis) the number travels along.
        direction: Vector2,
    },
    /// Show the aggro indicator above an entity's head for `duration_us`
    /// when it gets aggroed (its `is_active` flips true in the `aggro_check`
    /// handler). Placed above the health bar like the skill icon, tinted with
    /// the active theme's `lightest`. See DESIGN → Animation.
    aggro_indicator: struct { entity_index: u32 },
    /// Float a heal number (`+value`) up-right from the entity's top-left
    /// bbox corner, traveling 1 tile with ease-out. Heals have no attacker,
    /// so the direction is fixed. Triggered by the `heal` event. Shares the
    /// per-entity stagger queue with damage numbers. See DESIGN → Animation.
    heal_number: struct { entity_index: u32, value: u32 },
};

/// A pending one-shot anim pushed by an event handler (gated `!replaying`,
/// same convention as `pending_sounds`). `frame()` drains the pending queue
/// after the update drain, stamps `end_clock = animation_clock + duration_us`,
/// and appends to `active_anims`. See DESIGN → Animation / Audio.
pub const PendingAnim = struct {
    event_index: u32,
    kind: AnimKind,
    duration_us: u32,
};

/// An active one-shot anim. `view()` shows it when `event_index <
/// current_event_index` (the triggering event is in the projected history —
/// same exclusive bound the combat log uses, so undo hides it) AND
/// `animation_clock < end_clock` (not yet elapsed) AND `animation_clock >=
/// start_clock` (a staggered number anim hasn't started yet → invisible).
/// No explicit clearing: elapsed anims are gated out by time, undone anims
/// by index; a screen/world transition clears the whole list (see DESIGN →
/// Animation). `start_clock` is the session-relative microsecond the anim
/// begins visibly advancing; for non-staggered anims it equals
/// `end_clock - duration_us` (starts immediately).
pub const ActiveAnim = struct {
    event_index: u32,
    kind: AnimKind,
    start_clock: u64,
    end_clock: u64,
};

/// A floating icon drawn above world sprites, after ground drawables and
/// before the UI. The `screen_position` is the top-left in reference world
/// space (camera + zoom already applied); the renderer scales `size` by
/// `world_scale`.
pub const FloatingIconDrawable = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    /// Square edge length in reference-world pixels; multiplied by
    /// `world_scale` at draw time.
    size: i32,
    color: Color,
};

/// An INNER outline of an occluded ground thing (entity / ground items /
/// flag pole), drawn over a decoration that renders in front of it so the
/// silhouette reads through. Drawn over the FULL sprite rect (no scissor):
/// the unoccluded portion merges into the art's own black outline; the
/// One sprite layer in a composited silhouette stack (see
/// `OcclusionInsetDrawable`). The renderer ORs each layer's alpha into a
/// frame-sized opaque mask, then dilates the union — so a weapon overlapping
/// the body doesn't produce a spurious internal outline edge. `sprite_id` is
/// the full asset-relative path (`entities/skeleton_1`, `weapons/sword`,
/// `world/flag`). `source_rectangle` selects a sub-region (null = whole
/// sprite); `flip_horizontal` mirrors the alpha within the frame (off-hand
/// weapons).
pub const StackSprite = struct {
    sprite_id: []const u8,
    source_rectangle: ?Rectangle = null,
    flip_horizontal: bool = false,
};

/// An INNER outline of an occluded ground thing (entity / ground items /
/// flag pole), drawn over a decoration that renders in front of it so the
/// silhouette reads through. The silhouette is composited from a STACK of
/// sprites (entity: base + layers + weapons; flag: pole + current banner
/// frame; ground items: single sprite) before dilation, so overlapping
/// layers don't produce spurious internal edges. Drawn over the FULL frame
/// rect (no scissor): the unoccluded portion merges into the art's own black
/// outline; the occluded portion darkens the decoration. `screen_position` is
/// the top-left of the frame in reference world space; `frame_width`/
/// `frame_height` are the compositing canvas (512×640 entity, 256×512 flag,
/// 256×256 ground items). See DESIGN → Decorations & Footprint → Occlusion inset.
pub const OcclusionInsetDrawable = struct {
    sprite_stack: []const StackSprite,
    screen_position: ScreenPosition,
    frame_width: i32,
    frame_height: i32,
    /// Draw alpha for the black tint (128 = 50%).
    alpha: u8,
};

pub const WorldOverlayDrawable = union(enum) {
    floating_icon: FloatingIconDrawable,
    /// Floating text (damage/heal numbers). The `screen_position` is the
    /// top-left of the text's drawn bbox in reference world space (camera +
    /// zoom already applied). The renderer draws a black edge-outline band
    /// (dilation of a rasterized string, same machinery as sprite outlines)
    /// under the fill text so it reads over any art. `font_size` is the
    /// native reference font size; `world_scale` scales it at draw time.
    floating_text: struct {
        text: []const u8,
        screen_position: ScreenPosition,
        font_size: i32,
        color: Color,
    },
};

// -- Layer 4+5: UI elements --
// UI is a flat list of UiElement from the ui module (src/ui/), sorted back
// to front.
// The view function builds and flattens the full UI layout.
// Options menu elements are included at the end when open.

// -- Top-level view state --

pub const ViewState = struct {
    background_color: Color,
    active_color_theme: ActiveColorTheme,
    /// Multiplier applied by the renderer to world sprite sizes (tiles, ground
    /// drawables, overlays), which are drawn at native texture size x this.
    /// Equals the camera zoom; world screen_positions already bake it in. UI
    /// elements are unaffected (they carry explicit reference-space sizes).
    world_scale: f32,
    /// The outline stripe shader's cycle phase, 0..1 (fraction of one
    /// light-dark cycle; see DESIGN → Platform Seam → Outline stripe
    /// shader). View-side only, stepped at animation_fps from the animation
    /// clock — freezes on pause like every looping anim; never game state,
    /// so there is no replay impact.
    outline_stripe_phase: f32,
    tiles: []const TileDrawable,
    tile_overlays: []const TileOverlayDrawable,
    ground_drawables: []const GroundDrawable,
    /// INNER outlines of ground things occluded by decoration overhang, drawn
    /// after the ground pass and before floating world overlays. See DESIGN
    /// → Decorations & Footprint → Occlusion inset.
    occlusion_insets: []const OcclusionInsetDrawable,
    /// Floating indicators (one-shot anims) drawn above world sprites, after
    /// ground drawables and before the UI. Built per-frame from
    /// `session.active_anims`; see DESIGN → Animation.
    world_overlays: []const WorldOverlayDrawable,
    ui_elements: []const @import("ui.zig").UiElement,
    /// The font metrics the ui_elements were laid out with this frame. The
    /// NEXT frame's input resolution reads it off `previous_view_state`
    /// (e.g. mapping a text-field click x to a caret index) — the one
    /// backend-derived value the input side needs.
    font_metrics: @import("ui.zig").FontMetrics,
    /// Chronological combat-log projection of the current level's events up to
    /// the current position (empty outside a level). Built per-frame in the
    /// frame arena; the UI renders it (top-bar coarse recent + detailed log).
    combat_log: []const @import("events.zig").Event,
};
