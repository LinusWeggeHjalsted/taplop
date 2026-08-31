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
/// Pushed onto `SessionState.pending_sounds` by event handlers (gated
/// `!replaying`) and input handlers, then drained by `frame()` and played via
/// the backend. Music is a single always-on stream, not a `SoundId`. See
/// DESIGN → Audio.
pub const SoundId = enum {
    move,
    weapon_swing,
    spell,
    damage,
    pickup,
    skip,
    equip,
    learn_skill,
    salvage,
    swap_skill,
    button_click_down,
    button_click_up,
    menu,
    defeat,
    mission_completion,
};

pub const Vector2 = struct {
    x: i32,
    y: i32,
};

pub const Action = enum {
    undo,
    redo,
    /// Escape. Generic "close topmost overlay": closes the settings overlay,
    /// load-save browser, credits, world map / full combat log, or the
    /// options menu (whichever is topmost); on mission fail / mission
    /// complete it fires the overlay's primary button (exit mission /
    /// continue); with nothing open (level/hub only) it opens the options
    /// menu. Named for the historical options-menu toggle — renaming awaits
    /// the InputBindings per-action migration (a user settings.txt replaces
    /// the binding set, so a rename strands existing installs). See DESIGN →
    /// Input → Escape overlay chain.
    toggle_options_menu,
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
    // Scroll the error popup body (arrows; the mouse wheel also scrolls
    // it via a redirect in the modal input gate). Only consumed while a
    // pending error is shown. Bound to the same Up/Down keys as the tile-
    // cursor nudge — the modal gate routes them to scroll, not cursor, while
    // the popup is up. See DESIGN → Error Handling.
    error_scroll_up,
    error_scroll_down,
    // Camera zoom (keyboard shortcuts; the mouse wheel also zooms via
    // scroll_delta). ctrl+I = zoom in, ctrl+O = zoom out, ctrl+0 = reset to
    // 1.0. Letters/digits are layout-stable (physical key positions), unlike
    // the +/- symbol keys whose raylib tokens are layout-labeled and degrade
    // on ISO layouts. See DESIGN → Input.
    zoom_in,
    zoom_out,
    zoom_reset,
    // Options menu commands (context-specific: hub vs level).
    save_game,
    restart_mission,
    exit_mission,
    exit_to_menu,
    // Mission-complete overlay commands.
    continue_after_mission,
    replay_mission,
    overwrite_clone,
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
    // A save row in the load-save browser. The row index rides alongside
    // in IdleInput.clicked_save_row (set from the button's SlotRef at the
    // release-dispatch site — Action alone can't carry a payload).
    load_save_row,
    // Load-save browser's "Import External Save" (web only): opens a file
    // picker; the picked file lands in saves/ and loads. Native builds never
    // emit the button (drop files into the persistent saves/ dir by hand).
    import_save,
    open_editor,
    open_settings,
    open_credits,
    // A settings toggle or choice button was clicked. The SettingRef (which
    // field + which value) rides in `AnytimeInput.clicked_setting`. See
    // DESIGN → UI Framework → Settings screen.
    change_setting,
    // An editor palette group header was clicked (expand/collapse the
    // group). The group index rides in `AnytimeInput.clicked_editor_group`.
    // Routed through `options_action` so one handler serves it regardless
    // of screen state. See DESIGN → Architecture → Level Editor → Editor
    // UI layout (tool palette).
    toggle_editor_palette_group,
    // An editor tool cell was clicked (make it the active tool). The
    // EditorToolId rides in `AnytimeInput.clicked_editor_tool`. See DESIGN
    // → Architecture → Level Editor (active-tool model).
    select_editor_tool,
    // An editor level-tab was clicked (make that level active). The level
    // index rides in `AnytimeInput.clicked_editor_level`. Routed through
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
    // A settings-sidebar gradient swatch (world / enemy / player row):
    // open the centered theme picker for that role. The role rides in
    // `AnytimeInput.clicked_editor_gradient_role`; the picker target
    // snapshots the active level index (a mid-edit tab switch can't
    // retarget the pick).
    open_editor_level_gradient_picker,
    // A theme-picker gradient row: set the level's index for the picker's
    // role. The gradient index rides in
    // `AnytimeInput.clicked_editor_gradient`. For enemy/player, a pick
    // while on auto flips that role to manual in the same commit.
    select_editor_level_gradient,
    // An enemy/player gradient row's AUTO button: revert that role to
    // auto-derivation (commits the null override). A no-op while already
    // auto (same-value picks never fire). The role rides in
    // `AnytimeInput.clicked_editor_gradient_role`.
    toggle_editor_level_gradient_auto,
    // An inspector section header (expand/collapse that section). The
    // section id rides in `AnytimeInput.clicked_editor_section` — a
    // direct UiState write (view affordance, off the undo timeline, like
    // the palette accordion).
    toggle_editor_inspector_section,
    // The inspector's Sprite row (enemy identity): open the centered
    // sprite picker for the base sprite. The mission-local scan happens
    // at this site (idle input — interactive IO lives here, never in the
    // view or handlers).
    open_editor_sprite_picker,
    // A sprite picker cell: set the edited entity type's base sprite (the
    // stem rode in `AnytimeInput.clicked_editor_sprite`) and close the
    // picker. Same-value picks close without recording.
    select_editor_entity_sprite,
    // The decoration picker's cell: adopt the picked prefab (official tab)
    // or custom stem (mission tab) into the edited decoration type — see
    // `editor_set_decoration_def`. The stem rode in
    // `AnytimeInput.clicked_editor_sprite`. Same-value picks close without
    // recording.
    select_editor_decoration_sprite,
    // A sprite picker tab button (Mission / Official): switch the picker's
    // tab. The tab rode in `AnytimeInput.clicked_editor_sprite_tab` — a
    // direct UiState write (view affordance).
    select_editor_sprite_tab,
    // The player inspector's Import button: copy the session's player
    // data (or, with none, the new-game default save) into the editor
    // player loadout. No payload — the handler reads live state.
    import_editor_player,
    // An inspector color swatch was clicked (set the edited entity type's
    // color_index — the gradient index into the enemy gradient). The index
    // rides in `AnytimeInput.clicked_editor_color`. Routed through
    // `options_action` like the other payload-carrying editor clicks.
    select_editor_entity_color,
    // The decoration inspector's color swatch was clicked (set the edited
    // decoration type's color_index — the gradient index into the WORLD
    // gradient). The index rides in `AnytimeInput.clicked_editor_color`.
    select_editor_decoration_color,
    // The Layers sections' controls (enemy + decoration types). The layer
    // index rides in `AnytimeInput.clicked_editor_layer` (null on the
    // add-layer button — the picker's add mode).
    open_editor_entity_layer_picker,
    open_editor_decoration_layer_picker,
    // A layer-picker cell: the stem rode in
    // `AnytimeInput.clicked_editor_sprite`; the layer identity (add vs
    // edit index) rides in the open picker's UiState target.
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
    // `AnytimeInput.clicked_editor_footprint_tile` — a direct UiState
    // write (the draft is transient view state, off the undo timeline).
    toggle_editor_footprint_tile,
    // The footprint editor's Confirm button: close the picker and commit
    // the draft IF it differs (an unchanged draft closes without
    // recording; an empty draft stays open — a footprint needs ≥1 tile).
    confirm_editor_footprint,
    // The inspector's displays-weapons toggle (flip the edited entity
    // type's flag). No payload — the handler reads + flips live state.
    toggle_editor_entity_displays_weapons,
    // An inspector weapon-type cell was clicked (create the slot's weapon
    // while empty, or retype in place keeping name/damage). The hand
    // (`GearSlot`, main/off) rides in `AnytimeInput.clicked_editor_gear_slot`
    // + the type in `clicked_editor_weapon_type`.
    select_editor_weapon_type,
    // The inspector's gear Add button (create a default item in the empty
    // slot — the slot rides in `AnytimeInput.clicked_editor_gear_slot`).
    add_editor_item,
    // The inspector's item Delete button (clear the slot to null — the
    // slot rides in `AnytimeInput.clicked_editor_gear_slot`).
    delete_editor_item,
    // An inspector utility-slot button was clicked (open the centered
    // skill picker for that slot). The slot index rides in
    // `AnytimeInput.clicked_editor_utility_slot`.
    open_editor_skill_picker,
    // The skill picker's close button (top-right, the middle-panel
    // convention). No payload.
    close_editor_picker,
    // A skill picker cell was clicked (assign to the picker's slot). The
    // skill rides in `AnytimeInput.clicked_editor_skill`; the None cell
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
pub fn releaseSoundForAction(action: Action) ?SoundId {
    return switch (action) {
        .skip => .skip,
        .swap_weapons => .swap_skill,
        .toggle_inventory, .toggle_gear, .toggle_skills, .toggle_entity_inspect, .toggle_world_map, .toggle_options_menu, .toggle_editor_inspector => .menu,
        // Undo/redo: reuses the menu sound (no dedicated sfx).
        .undo, .redo => .menu,
        .save_game => .menu,
        .restart_mission, .exit_mission, .exit_to_menu => .menu,
        .continue_after_mission, .replay_mission, .overwrite_clone => .menu,
        // Skill slots: suppress the generic button-up (the use_skill event
        // plays weapon_swing/spell on auto-fire; the prepare path plays
        // button_click_up explicitly). See DESIGN → Audio.
        .skill_slot_1, .skill_slot_2, .skill_slot_3, .skill_slot_4,
        .skill_slot_5, .skill_slot_6, .skill_slot_7, .skill_slot_8 => .button_click_up,
        else => null,
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

pub const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub const InputBinding = struct {
    input: RawInput,
    modifiers: Modifiers = .{},
    action: Action,
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
};

pub const Camera = struct {
    position: Vector2,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

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

pub const ItemType = union(enum) {
    weapon: WeaponType,
    amulet: void,
    coat: void,
    gloves: void,
    pants: void,
    boots: void,
    skill_tome: SkillId,
};

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
            },
            .item_name => |slot| if (self.gearSlotItem(slot)) |item|
                itemName(item)
            else
                "",
            .item_stat => |field| if (self.gearSlotItem(field.slot)) |item|
                (
                    if (itemStatValue(item, field.stat)) |value|
                        try std.fmt.allocPrint(allocator, "{d}", .{value})
                    else
                        ""
                )
            else
                "",
            // Settings-sidebar ids never resolve against an entity (their
            // targets are `.mission` / `.level`); the arms exist so the
            // switch stays exhaustive.
            .mission_name, .level_name => "",
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
    layers: []const DecorationLayer = &.{},
};

/// A palette entry for a loose ground item (loot not tied to an enemy).
/// The `item` carries the full Item union (weapon/amulet/.../skill_tome)
/// since the union's variety makes per-field granularity impractical — the
/// inspector edits the whole item and pushes one `editor_set_item_def`
/// event per commit. See DESIGN → Architecture → Level Editor → Editor UI
/// layout (Ground Items palette group).
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
    /// Loose floor items placed via the Ground Items palette (loot not tied
    /// to an enemy). Mirrors Level.ground_items but reference-based: each
    /// placement points into Editor.item_types. See DESIGN → Architecture →
    /// Level Editor → Editor UI layout (Ground Items palette group).
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
    /// DESIGN → Architecture → Level Editor → Editor UI layout (Ground Items
    /// palette group).
    item_types: []const ItemTypeDef = &.{},
    // The editor-global player start loadout. Persistent as player.txt in the
    // mission directory (so a recorded validation replay is reproducible and
    // players picking up a custom mission can see the author's loadout).
    player_def: EntityTypeDef = .{},
    active_level_index: usize = 0, // which tab is open
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
    mode: EditorMode = .edit,
};

pub const ReplayViewer = struct {

};

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
    /// run was NOT strictly better (Pareto) — the overlay offers a manual
    /// "Overwrite Clone" button. False on a first completion (auto-saved) or a
    /// strictly-better run (auto-overwrote). See DESIGN → Clones (clone system).
    overwrite_offered: bool = false,
};

pub const Mission = struct {
    /// Stable identifier for this mission (clone key + custom-mission identity).
    /// See DESIGN → Custom Missions & Online Services → Content identity.
    uuid: []const u8 = &.{},
    name: []const u8 = &.{},
    path: []const u8 = &.{},
    level_count: u32 = 0,
    current_level_index: u32 = 0,
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

// ============================================================
// View state — output of view(), input to renderer
// ============================================================

/// Fixed reference (design) resolution. The view function + all UI layout
/// math produce coordinates in this space; the renderer draws them into a
/// separate (possibly smaller) render target via a camera zoom, then blits
/// to the window. See DESIGN → Platform Seam → Render target resolution.
pub const reference_width: i32 = 3840;
pub const reference_height: i32 = 2160;

/// Offscreen render target resolution (from the `-Drender-width`/`-Drender-
/// height` build options, default 1920×1080). The backend creates its
/// `RenderTexture` at this size and scales 4K design-space content into it
/// via `beginMode2D`. Lower than reference → less fill rate. MUST share the
/// reference aspect ratio (16:9) — the camera zoom is uniform, so a
/// mismatched aspect would squish content (comptime-checked below).
pub const render_width: i32 = build_info.render_width;
pub const render_height: i32 = build_info.render_height;

// Comptime aspect-ratio guard: the camera zoom (`render_width /
// reference_width`) must be uniform, so the render target's aspect ratio
// must match the reference's. A build with a mismatched aspect fails at
// compile time with a clear message rather than rendering squished content.
comptime {
    const ref_ar = reference_width * reference_height; // unused, keeps both live
    _ = ref_ar;
    if (render_width * reference_height != render_height * reference_width) {
        @compileError("render target aspect ratio must match reference (16:9): " ++
            "render-width/render-height must be in the same ratio as 3840/2160");
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
    pub fn centerX(self: Rectangle) i32 {
        return self.x + @divTrunc(self.width, 2);
    }
    pub fn centerY(self: Rectangle) i32 {
        return self.y + @divTrunc(self.height, 2);
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

    pub fn placeTopLeft(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .start, .start, margin);
    }
    pub fn placeTopCenter(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .center, .start, margin);
    }
    pub fn placeTopRight(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .end, .start, margin);
    }
    pub fn placeCenterLeft(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .start, .center, margin);
    }
    pub fn placeCenter(self: Rectangle, w: i32, h: i32) Rectangle {
        return self.placeChild(w, h, .center, .center, 0);
    }
    pub fn placeCenterRight(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .end, .center, margin);
    }
    pub fn placeBottomLeft(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .start, .end, margin);
    }
    pub fn placeBottomCenter(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .center, .end, margin);
    }
    pub fn placeBottomRight(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .end, .end, margin);
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
    /// Source rectangle into the overlay sprite (for sprite-based overlays
    /// like the animated tile highlight). Null for primitive overlays.
    source_rectangle: ?Rectangle = null,
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
    /// Overlay layer chunks drawn over the base at the same position + source
    /// rect, each with its own sprite + color. Empty for single-sprite
    /// decorations. Drawn in slice order (base first, then layers).
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
// UI is a flat list of UiElement from ui.zig, sorted back to front.
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

