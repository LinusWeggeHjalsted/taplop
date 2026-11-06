//! Input consumption - the semantic layer that turns a `PlayerInput` into
//! gameplay actions (event pushes) and transient state changes.
//!
//! `input.zig` is the *translation* layer (raw platform events → semantic
//! `PlayerInput`); this file is the *consumption* layer: `handleAnytimeInput`,
//! `handleIdleInput`, and `resolveTileCursor` resolve a player input into
//! event pushes (via `event_push.pushEvents`) or direct `SessionState`
//! writes (transient view/input state - never undoable `GameState`).
//! Session-log dev tooling (`dumpEventLog`, the build-version advisory
//! warn, the timestamp formatter) lives here too, called from the anytime
//! path. The pointer gestures (drag/click/pan/sliders/right-click intents
//! + the editor viewport gestures) live in `input_gestures.zig`; the
//! editor mission save/export/import in `editor/mission_io.zig`.

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const loaders = @import("loaders.zig");
const writers = @import("writers.zig");
const session_log = @import("session_log.zig");
const session_log_bundle = @import("session_log_bundle.zig");
const lookups = @import("generated_lookups.zig");
const ui = @import("ui.zig");
const file_source_mod = @import("file_source.zig");
const browser_url = @import("browser_url.zig");
const parser = @import("parser.zig");
const event_handlers = @import("event_handlers.zig");
const game_zip = @import("game_zip.zig");
const player_handlers = @import("handlers/player.zig");
const event_push = @import("event_push.zig");
const planning = @import("editor/planning.zig");
const editor_handlers = @import("editor/handlers.zig");
const mission_io = @import("editor/mission_io.zig");
const input_gestures = @import("input_gestures.zig");
const skillsSlotUnderPointer = input_gestures.skillsSlotUnderPointer;
const handleRightClickEditorDelete = input_gestures.handleRightClickEditorDelete;
const handleEditorMarquee = input_gestures.handleEditorMarquee;
const handleEditorMoveDrag = input_gestures.handleEditorMoveDrag;
const dragActionWouldChange = input_gestures.dragActionWouldChange;
const functions = @import("functions.zig");
const view_mod = @import("view.zig");
const build_info = @import("build_info");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;

/// Mouse-wheel zoom cadence + bounds. Additive in fixed steps (one zoom-in
/// then one zoom-out returns to the exact same value - no float drift).
/// Default 0.5; scroll up zooms in, scroll down zooms out. The minimum is
/// always one step (so the floor divides evenly into the range). Tune from
/// feel; if linear spacing feels uneven across the range, swap the additive
/// step for a generated level table (a localized change here).
const camera_zoom_step: u32 = 25;
const min_camera_zoom: u32 = 25;
const max_camera_zoom: u32 = 100;
const default_camera_zoom: u32 = 50;

/// Camera zoom (wheel + keyboard) is a world-view control: only the screens
/// that render a camera (levels, hubs, the editor viewport) zoom. The main
/// menu and the replay viewer have no meaningful zoom - the wheel and the
/// zoom keys are simply unused there instead of silently mutating the
/// `camera_zoom` setting. The consumption-site gate (not a binding context):
/// the wheel isn't a binding at all, and the keys must gate uniformly across
/// installs whose user files still carry the old `anytime` zoom bindings.
fn cameraZoomAllowed(screen: state.Screen) bool {
    return switch (screen) {
        .hub, .level, .editor => true,
        else => false,
    };
}

const PlayerInput = input.PlayerInput;
const Vector2 = types.Vector2;
const Entity = types.Entity;
const SkillId = types.SkillId;
const Level = types.Level;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const Settings = types.Settings;
const utility_skill_count = types.utility_skill_count;
const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;
const WeaponType = types.WeaponType;

pub fn warnIfSessionLogFromDifferentBuild(log_game_version: []const u8) void {
    if (!std.mem.eql(u8, log_game_version, build_info.game_version)) {
        std.debug.print(
            "warning: session log recorded on game_version {s}, this build is {s}; replay may diverge\n",
            .{ log_game_version, build_info.game_version },
        );
    }
}

/// Write the full session event history + reconstruction cache as a
/// session-log bundle to `logs/session_<YYYYMMDD_HHMMSS>/` in the persistent
/// data dir (session_log.txt + content/ byte copies; see
/// session_log_bundle.writeSessionLogBundle) - the bundle embeds every file
/// the session's reconstruction reads, so it replays deterministically
/// regardless of later file changes (the autosave is overwritten by later
/// sessions; custom missions are re-saved by the editor). A dev tool bound
/// to ctrl+L. Runs only from the input path, so it never fires during replay.
/// The timestamp is UTC (no timezone handling) - fine for a folder name.
fn dumpEventLog(history: *GameStateHistory) void {
    var arena = std.heap.ArenaAllocator.init(history.backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const created = session_log.formatSessionTimestamp(allocator, history.io);
    const bundle_dir = std.fmt.allocPrint(
        allocator,
        "logs/session_{s}",
        .{created},
    ) catch @panic("failed to format session-log bundle dir name");
    session_log_bundle.writeSessionLogBundle(
        history.file_source,
        history.event_history.items,
        history.reconstruction_cache.items,
        bundle_dir,
        created,
        allocator,
    ) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to write session log bundle",
        );
        return;
    };

    // Feedback for this dev tool: the bundle lands in the persistent data
    // dir (~/.ziglop/logs/).
    std.debug.print("wrote session log bundle: {s} ({d} events)\n", .{
        bundle_dir,
        history.event_history.items.len,
    });
}

/// Push a player-action orchestrator event and drain it (plus its handler-
/// pushed children) to completion within this call. Used by the
/// options_action dispatch and the Escape overlay chain, both inside
/// handleAnytimeInput - which runs before update()'s options-menu/pause
/// gates, so the drain proceeds even while a modal overlay is open. The
/// overlay opened in a previous frame and nothing drains while it's open
/// (update() returns at its gate), so event_stack.len on entry equals the
/// depth when the overlay opened - that's the drain baseline. Draining back
/// DOWN to the baseline leaves anything pushed beneath (e.g. a mid-drain
/// enemy turn) intact. Idle-point recording is left to the normal
/// maybeRecordIdlePoint in gameLoop (no special case): if the stack empties
/// (overlay opened from idle) an undo stop is recorded; mid-enemy-turn the
/// action bundles into that drain's idle point. Aborts on load_error (the
/// drain-loop convention - the error popup takes over).
fn pushPlayerActionAndDrain(
    history: *GameStateHistory,
    action: events.PlayerInputEvent,
) void {
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();
    const baseline = current.event_stack.len;
    event_push.pushPlayerAction(current, action, allocator);
    while (current.event_stack.len > baseline) {
        if (history.load_error) break;
        event_handlers.processEvent(history);
    }
}

/// Resolve a focused text field's keyboard outcome (Enter commits,
/// Escape discards - see DESIGN → UI Framework → Text input widget).
/// Called ONCE per frame from main (after translateInput, before the
/// drain) - never per update() drain iteration.
pub fn resolveTextEditOutcome(
    history: *GameStateHistory,
    outcome: types.TextEditOutcome,
) void {
    switch (outcome) {
        .none => {},
        .commit => commitFocusedTextEdit(history),
        .cancel => history.session.ui_state.text_edit = null,
    }
}

/// Commit the focused text field (Enter/OK, or the M2 click-away path):
/// push the field's wrapper event + drain, then drop focus. The
/// field-kind switch lives HERE - the UI framework is field-agnostic;
/// this is where a TextFieldId becomes a player action. A no-op edit (the
/// buffer equals the current value) records nothing; a stale focus (no
/// editor, or the target type deleted mid-edit) just drops the buffer.
/// Parse a digits-only buffer as u32: null when empty/unparseable (commit
/// nothing); overflow clamps to u32 max (the UNBOUNDED base stats).
fn parseUnboundedStatValue(value: []const u8) ?u32 {
    return std.fmt.parseInt(u32, value, 10) catch |parse_error| switch (parse_error) {
        error.Overflow => std.math.maxInt(u32),
        else => null,
    };
}

/// Parse + clamp to a bounded stat's max (the gear-stat balance bounds -
/// the same max_* the parser clamps with; the single source is types.zig).
fn parseBoundedStatValue(value: []const u8, max: u32) ?u32 {
    const parsed = parseUnboundedStatValue(value) orelse return null;
    return @min(parsed, max);
}

/// The inspector's current edit target as the entity-edit events carry
/// it: the enemy type the inspector is showing, or `player_def` when the
/// player (the fallback target) is showing - NULL when a decoration type
/// is showing (the entity controls don't render for decoration content,
/// so a null here is a crafted click; the caller bails). See
/// `ui.editorInspectorTarget` - the resolution's single seam.
fn editorEntityEditTarget(editor: types.Editor) ?types.EntityEditTarget {
    return switch (ui.editorInspectorTarget(editor)) {
        .entity_type => |type_index| .{ .entity_type = type_index },
        .player => .player_def,
        .decoration_type, .item_type => null,
    };
}

/// The palette item type the inspector currently edits (the Items
/// group's content), or null on any other target. The item commit sites'
/// single seam - the entity-target wrapper's shape.
fn editorItemEditTarget(editor: types.Editor) ?u32 {
    return switch (ui.editorInspectorTarget(editor)) {
        .item_type => |type_index| if (type_index < editor.item_types.len) type_index else null,
        .entity_type, .decoration_type, .player => null,
    };
}

/// The inventory-slot item-def player action: `editorItemDefAction`'s
/// exact shape with the slot index instead of the palette type id (the
/// inventory detail rows' type picks + stat edits - one event, one undo
/// step).
fn editorInventoryItemDefAction(
    slot_index: u32,
    item: types.Item,
) ?events.PlayerInputEvent {
    return switch (item) {
        .weapon => |weapon| .{ .player_set_editor_inventory_item_def = .{
            .index = slot_index,
            .item_kind = .weapon,
            .weapon_type = weapon.weapon_type,
            .name = weapon.name,
            .weapon_damage = weapon.weapon_damage,
        } },
        .amulet => |amulet| .{ .player_set_editor_inventory_item_def = .{
            .index = slot_index,
            .item_kind = .amulet,
            .name = amulet.name,
            .spell_damage = amulet.spell_damage,
        } },
        .coat => |coat| .{ .player_set_editor_inventory_item_def = .{
            .index = slot_index,
            .item_kind = .coat,
            .name = coat.name,
            .health_bonus = coat.health_bonus,
            .defense_bonus = coat.defense_bonus,
        } },
        .gloves => |gloves| .{ .player_set_editor_inventory_item_def = .{
            .index = slot_index,
            .item_kind = .gloves,
            .name = gloves.name,
            .damage_bonus = gloves.damage_bonus,
            .health_bonus = gloves.health_bonus,
        } },
        .pants => |pants| .{ .player_set_editor_inventory_item_def = .{
            .index = slot_index,
            .item_kind = .pants,
            .name = pants.name,
            .pickup_radius_bonus = pants.pickup_radius_bonus,
            .health_bonus = pants.health_bonus,
        } },
        .boots => |boots| .{ .player_set_editor_inventory_item_def = .{
            .index = slot_index,
            .item_kind = .boots,
            .name = boots.name,
            .speed_bonus = boots.speed_bonus,
            .health_bonus = boots.health_bonus,
        } },
        .skill_tome => null,
    };
}

/// The item-def player action carrying a WHOLE item (a type pick, a stat
/// edit - one event, one undo step), flattened to the event's top-level
/// fields. Null for a skill tome (not expressible as an `ItemKind` - the
/// editor authoring surface excludes tomes; unreachable live, defensive
/// for crafted state).
fn editorItemDefAction(
    type_id: u32,
    item: types.Item,
) ?events.PlayerInputEvent {
    return switch (item) {
        .weapon => |weapon| .{ .player_set_editor_item_def = .{
            .type_id = type_id,
            .item_kind = .weapon,
            .weapon_type = weapon.weapon_type,
            .name = weapon.name,
            .weapon_damage = weapon.weapon_damage,
        } },
        .amulet => |amulet| .{ .player_set_editor_item_def = .{
            .type_id = type_id,
            .item_kind = .amulet,
            .name = amulet.name,
            .spell_damage = amulet.spell_damage,
        } },
        .coat => |coat| .{ .player_set_editor_item_def = .{
            .type_id = type_id,
            .item_kind = .coat,
            .name = coat.name,
            .health_bonus = coat.health_bonus,
            .defense_bonus = coat.defense_bonus,
        } },
        .gloves => |gloves| .{ .player_set_editor_item_def = .{
            .type_id = type_id,
            .item_kind = .gloves,
            .name = gloves.name,
            .damage_bonus = gloves.damage_bonus,
            .health_bonus = gloves.health_bonus,
        } },
        .pants => |pants| .{ .player_set_editor_item_def = .{
            .type_id = type_id,
            .item_kind = .pants,
            .name = pants.name,
            .pickup_radius_bonus = pants.pickup_radius_bonus,
            .health_bonus = pants.health_bonus,
        } },
        .boots => |boots| .{ .player_set_editor_item_def = .{
            .type_id = type_id,
            .item_kind = .boots,
            .name = boots.name,
            .speed_bonus = boots.speed_bonus,
            .health_bonus = boots.health_bonus,
        } },
        .skill_tome => null,
    };
}

/// The gear-slot player action (create / retype / field-edit / clear -
/// one event, one undo step), carrying the FLATTENED item (a nested
/// `?Weapon`-style value can't round-trip the session log once its name
/// contains a space - see EntityGearPayload in events.zig). A null `item`
/// is the clear (`equipped: false`). The item's kind must match the slot
/// (it always does - items are read from the slot itself or built for
/// it); a mismatch or a skill tome records nothing (crafted state).
fn editorGearSlotAction(
    target: types.EntityEditTarget,
    slot: types.GearSlot,
    item: ?types.Item,
) ?events.PlayerInputEvent {
    var payload: events.EntityGearPayload = .{
        .target = target,
        .slot = slot,
        .equipped = item != null,
    };
    if (item) |value| {
        if (types.itemKindOf(value) != types.gearSlotItemKind(slot)) return null;
        switch (value) {
            .weapon => |weapon| {
                payload.weapon_type = weapon.weapon_type;
                payload.name = weapon.name;
                payload.weapon_damage = weapon.weapon_damage;
            },
            .amulet => |amulet| {
                payload.name = amulet.name;
                payload.spell_damage = amulet.spell_damage;
            },
            .coat => |coat| {
                payload.name = coat.name;
                payload.health_bonus = coat.health_bonus;
                payload.defense_bonus = coat.defense_bonus;
            },
            .gloves => |gloves| {
                payload.name = gloves.name;
                payload.damage_bonus = gloves.damage_bonus;
                payload.health_bonus = gloves.health_bonus;
            },
            .pants => |pants| {
                payload.name = pants.name;
                payload.pickup_radius_bonus = pants.pickup_radius_bonus;
                payload.health_bonus = pants.health_bonus;
            },
            .boots => |boots| {
                payload.name = boots.name;
                payload.speed_bonus = boots.speed_bonus;
                payload.health_bonus = boots.health_bonus;
            },
            .skill_tome => return null,
        }
    }
    return .{ .player_set_editor_entity_gear = payload };
}

/// A default item for an EMPTY gear slot (the Add button / a weapon-type
/// pick on an empty hand): "New <Slot>", zero stats. Weapons are created
/// by the TYPE row (not here) - null for the hands.
fn defaultItemForSlot(history: *GameStateHistory, slot: types.GearSlot) ?types.Item {
    const name = std.fmt.allocPrint(
        history.current_arena.allocator(),
        "New {s}",
        .{types.gearSlotLabel(slot)},
    ) catch @panic("failed to allocate default item name");
    return switch (slot) {
        .main_hand, .off_hand => null,
        .amulet => .{ .amulet = .{ .name = name } },
        .coat => .{ .coat = .{ .name = name } },
        .gloves => .{ .gloves = .{ .name = name } },
        .pants => .{ .pants = .{ .name = name } },
        .boots => .{ .boots = .{ .name = name } },
    };
}

/// The shared gate for the picker-pick arms: the open picker must be
/// kind `kind`, else null (no picker open, or another kind - each pick
/// arm handles its own kind; a crafted click while the wrong picker is
/// open no-ops). The switch enumerates every EditorPickerTarget variant
/// so adding a kind is a compile error HERE, not a silent no-op gap in
/// the eight pick arms.
fn expectPickerKind(
    editor: *const types.Editor,
    comptime kind: std.meta.Tag(types.EditorPickerTarget),
) ?@FieldType(types.EditorPickerTarget, @tagName(kind)) {
    const picker = editor.picker orelse return null;
    return switch (picker) {
        .utility_skill_slot => |slot_index| if (kind == .utility_skill_slot) slot_index else null,
        .entity_sprite => if (kind == .entity_sprite) {} else null,
        .decoration_sprite => if (kind == .decoration_sprite) {} else null,
        .entity_layer => |layer_index| if (kind == .entity_layer) layer_index else null,
        .decoration_layer => |layer_index| if (kind == .decoration_layer) layer_index else null,
        .decoration_footprint => |type_id| if (kind == .decoration_footprint) type_id else null,
        .level_gradient => |target| if (kind == .level_gradient) target else null,
    };
}

pub fn commitFocusedTextEdit(history: *GameStateHistory) void {
    if (history.session.ui_state.text_edit == null) return;
    const text_edit: *ui.TextEditState = &history.session.ui_state.text_edit.?;
    const field = text_edit.field;
    // Dupe the buffer into the current arena BEFORE dropping focus: the
    // payload slice must not point into UiState once the optional is
    // cleared (recordEvent's deep copy happens during the drain below;
    // the dupe makes that ordering irrelevant).
    const value = history.current_arena.allocator().dupe(
        u8,
        text_edit.buffer.currentText(),
    ) catch @panic("failed to allocate text field commit value");
    history.session.ui_state.text_edit = null;

    switch (field.id) {
        .entity_name => {
            if (history.current_state.editor == null) return;
            const editor: *types.Editor = &history.current_state.editor.?;
            const entity_target = field.target.entity;
            const template = editor_handlers.editorEntityTemplate(editor, entity_target) orelse return;
            const current_value = template.name;
            // Would-change gate: an unchanged value never records (no
            // dead undo step).
            if (std.mem.eql(u8, current_value, value)) return;
            history.session.queueSound(history.backing_allocator, .button_base_up);
            pushPlayerActionAndDrain(history, .{ .player_set_editor_entity_name = .{
                .target = entity_target,
                .value = value,
            } });
        },
        .entity_stat => |stat| {
            if (history.current_state.editor == null) return;
            const editor: *types.Editor = &history.current_state.editor.?;
            const entity_target = field.target.entity;
            const template = editor_handlers.editorEntityTemplate(editor, entity_target) orelse return;
            // Base stats are UNBOUNDED by design - see DESIGN → Level
            // Editor → Inspector fields.
            const parsed = parseUnboundedStatValue(value) orelse return;
            // Would-change gate with NUMERIC semantics ("020" == 20).
            const current_formatted = template.textFieldValue(
                history.current_arena.allocator(),
                field.id,
            ) catch @panic("failed to format entity field value");
            const current = parseUnboundedStatValue(current_formatted) orelse return;
            if (parsed == current) return;
            history.session.queueSound(history.backing_allocator, .button_base_up);
            const action: events.PlayerInputEvent = switch (stat) {
                .max_health => .{ .player_set_editor_entity_max_health = .{
                    .target = entity_target,
                    .value = parsed,
                } },
                .defense => .{ .player_set_editor_entity_defense = .{
                    .target = entity_target,
                    .value = parsed,
                } },
                .speed => .{ .player_set_editor_entity_speed = .{
                    .target = entity_target,
                    .value = parsed,
                } },
                .aggro_range => .{ .player_set_editor_entity_aggro_range = .{
                    .target = entity_target,
                    .value = parsed,
                } },
                .team => .{ .player_set_editor_entity_team = .{
                    .target = entity_target,
                    .value = parsed,
                } },
            };
            pushPlayerActionAndDrain(history, action);
        },
        .item_name => |slot| {
            if (history.current_state.editor == null) return;
            const editor: *types.Editor = &history.current_state.editor.?;
            const entity_target = field.target.entity;
            const template = editor_handlers.editorEntityTemplate(editor, entity_target) orelse return;
            // An empty slot commits nothing (nothing to rename).
            const item = template.gearSlotItem(slot) orelse return;
            if (std.mem.eql(u8, types.itemName(item), value)) return;
            history.session.queueSound(history.backing_allocator, .button_base_up);
            const action = editorGearSlotAction(
                entity_target,
                slot,
                types.itemWithName(item, value),
            ) orelse return;
            pushPlayerActionAndDrain(history, action);
        },
        .item_stat => |item_field| {
            if (history.current_state.editor == null) return;
            const editor: *types.Editor = &history.current_state.editor.?;
            const entity_target = field.target.entity;
            const template = editor_handlers.editorEntityTemplate(editor, entity_target) orelse return;
            // An empty slot, or a stat the item kind doesn't carry, commits
            // nothing.
            const item = template.gearSlotItem(item_field.slot) orelse return;
            const current = types.itemStatValue(item, item_field.stat) orelse return;
            // Item stats are BOUNDED (the player can pick up exactly these
            // items - the same max_* the parser clamps with).
            const parsed = parseBoundedStatValue(value, types.itemStatMax(item_field.stat)) orelse return;
            if (parsed == current) return;
            history.session.queueSound(history.backing_allocator, .button_base_up);
            const action = editorGearSlotAction(
                entity_target,
                item_field.slot,
                types.itemWithStat(item, item_field.stat, parsed),
            ) orelse return;
            pushPlayerActionAndDrain(history, action);
        },
        // The item content's fields (the Items palette group - target:
        // `.item_type`). Same gates as the entity arms: would-change never
        // records; a stat the kind doesn't carry, a stale palette index,
        // or a skill tome commits nothing; stats clamp to `itemStatMax`.
        .item_def_name => {
            if (history.current_state.editor == null) return;
            const editor: *types.Editor = &history.current_state.editor.?;
            const type_id = switch (field.target) {
                .item_type => |index| index,
                else => return,
            };
            if (type_id >= editor.item_types.len) return;
            const item = editor.item_types[type_id].item;
            // A skill tome has no name (unreachable live - tomes are never
            // offered; the gate holds for crafted state).
            if (std.meta.activeTag(item) == .skill_tome) return;
            if (std.mem.eql(u8, types.itemName(item), value)) return;
            history.session.queueSound(history.backing_allocator, .button_base_up);
            pushPlayerActionAndDrain(history, .{ .player_set_editor_item_name = .{
                .type_id = type_id,
                .value = value,
            } });
        },
        .item_def_stat => |stat| {
            if (history.current_state.editor == null) return;
            const editor: *types.Editor = &history.current_state.editor.?;
            const type_id = switch (field.target) {
                .item_type => |index| index,
                else => return,
            };
            if (type_id >= editor.item_types.len) return;
            const item = editor.item_types[type_id].item;
            const current = types.itemStatValue(item, stat) orelse return;
            // Item stats are BOUNDED (the player can pick up exactly these
            // items - the same max_* the parser clamps with).
            const parsed = parseBoundedStatValue(value, types.itemStatMax(stat)) orelse return;
            if (parsed == current) return;
            history.session.queueSound(history.backing_allocator, .button_base_up);
            const action = editorItemDefAction(
                type_id,
                types.itemWithStat(item, stat, parsed),
            ) orelse return;
            pushPlayerActionAndDrain(history, action);
        },
        // The inventory detail rows' fields (the player loadout's
        // Inventory section - target: `.inventory_slot`). Same gates as
        // the item_def arms: would-change never records; an empty slot,
        // a stale slot index, a stat the kind doesn't carry, or a skill
        // tome commits nothing; stats clamp to `itemStatMax`.
        .inventory_item_name => {
            if (history.current_state.editor == null) return;
            const editor: *types.Editor = &history.current_state.editor.?;
            const slot_index = switch (field.target) {
                .inventory_slot => |index| index,
                else => return,
            };
            if (slot_index >= types.inventory_slot_count) return;
            const item = editor.player_def.template.inventory.slots[slot_index] orelse return;
            if (std.meta.activeTag(item) == .skill_tome) return;
            if (std.mem.eql(u8, types.itemName(item), value)) return;
            history.session.queueSound(history.backing_allocator, .button_base_up);
            pushPlayerActionAndDrain(history, .{ .player_set_editor_inventory_item_name = .{
                .index = slot_index,
                .value = value,
            } });
        },
        .inventory_item_stat => |stat| {
            if (history.current_state.editor == null) return;
            const editor: *types.Editor = &history.current_state.editor.?;
            const slot_index = switch (field.target) {
                .inventory_slot => |index| index,
                else => return,
            };
            if (slot_index >= types.inventory_slot_count) return;
            const item = editor.player_def.template.inventory.slots[slot_index] orelse return;
            const current = types.itemStatValue(item, stat) orelse return;
            // Item stats are BOUNDED (the same max_* the parser clamps
            // with - the player can pick up exactly these items).
            const parsed = parseBoundedStatValue(value, types.itemStatMax(stat)) orelse return;
            if (parsed == current) return;
            history.session.queueSound(history.backing_allocator, .button_base_up);
            const action = editorInventoryItemDefAction(
                slot_index,
                types.itemWithStat(item, stat, parsed),
            ) orelse return;
            pushPlayerActionAndDrain(history, action);
        },
        // Settings-sidebar name fields (mission + level). Same would-
        // change gate as the entity name; the level commit addresses the
        // tab the field was focused on (the index rides the ref target, so
        // a mid-edit tab switch can't retarget it).
        .mission_name => {
            if (history.current_state.editor == null) return;
            const editor: *types.Editor = &history.current_state.editor.?;
            if (std.mem.eql(u8, editor.mission.name, value)) return;
            history.session.queueSound(history.backing_allocator, .button_base_up);
            pushPlayerActionAndDrain(history, .{ .player_set_editor_mission_name = .{
                .name = value,
            } });
        },
        .level_name => {
            if (history.current_state.editor == null) return;
            const level_index = field.target.level;
            if (level_index >= history.current_state.editor.?.levels.len) return;
            const current_name = history.current_state.editor.?.levels[level_index].name;
            if (std.mem.eql(u8, current_name, value)) return;
            history.session.queueSound(history.backing_allocator, .button_base_up);
            pushPlayerActionAndDrain(history, .{ .player_set_editor_level_name = .{
                .level_index = level_index,
                .name = value,
            } });
        },
    }

    // A committed edit is ONE undo step: record the idle point HERE. The
    // keyboard-resolution path commits from frame() BEFORE the drain, so
    // no other site would record it (the idle update() sees an empty
    // stack + no input, and its events_processed check comes up false) -
    // without this, undo steps PAST the edit and discards it from the
    // future timeline. The M2 click-away path (inside update()) lands on
    // this same recording; its own later maybeRecordIdlePoint dedupes via
    // the not-already-an-idle-point guard. Mid-drain commits (a non-empty
    // stack) are absorbed into the surrounding drain's idle point - the
    // stack-empty check inside maybeRecordIdlePoint skips them.
    history.maybeRecordIdlePoint(true);
}

/// Focus a text field (its element was clicked): read the field's current
/// value from GameState and seed the edit buffer. Focusing records
/// nothing - the COMMIT is the event.
pub fn beginFocusedTextEdit(
    history: *GameStateHistory,
    field: types.TextFieldRef,
) void {
    var current_value: []const u8 = "";
    if (history.current_state.editor != null) {
        const editor: *types.Editor = &history.current_state.editor.?;
        switch (field.target) {
            .entity => |entity_target| {
                if (editor_handlers.editorEntityTemplate(editor, entity_target)) |template| {
                    current_value = template.textFieldValue(
                        history.current_arena.allocator(),
                        field.id,
                    ) catch @panic("failed to format entity field value");
                }
            },
            .mission => {
                current_value = editor.mission.name;
            },
            .level => |level_index| {
                if (level_index < editor.levels.len) {
                    current_value = editor.levels[level_index].name;
                }
            },
            .item_type => |type_index| {
                if (type_index < editor.item_types.len) {
                    current_value = types.itemTextFieldValue(
                        editor.item_types[type_index].item,
                        history.current_arena.allocator(),
                        field.id,
                    ) catch @panic("failed to format item field value");
                }
            },
            .inventory_slot => |slot_index| {
                if (slot_index < types.inventory_slot_count) {
                    if (editor.player_def.template.inventory.slots[slot_index]) |item| {
                        current_value = types.itemTextFieldValue(
                            item,
                            history.current_arena.allocator(),
                            field.id,
                        ) catch @panic("failed to format item field value");
                    }
                }
            },
        }
    }
    ui.beginTextEdit(&history.session.ui_state, field, current_value);
}

/// The ONE per-action sound choke point: every action that FIRED this
/// frame queues its action layer here (once per action - `fired_actions`
/// is a set, so a same-frame keybind + button + console command on one
/// action queues one layer), replacing the per-flag queue sites across
/// the input handlers. The base halves stay at the button press/release
/// seam (main.zig) - this is the effect-site half, so keyboard-triggered
/// actions play the layer alone (the no-click-sounds-for-keys rule).
/// Two documented exclusions (the layer does NOT ride the firing):
/// `types.actionSoundUnwired` - no action layer by design; and the
/// outcome-gated set (`actionLayerRidesConsumptionSite` below) - those
/// keep their per-site queues. See DESIGN → Audio (layered cues).
pub fn dispatchFiredActionSounds(
    history: *GameStateHistory,
    fired_actions: std.EnumSet(types.Action),
) void {
    if (history.replaying) return;
    var iterator = fired_actions.iterator();
    while (iterator.next()) |action| {
        if (types.actionSoundUnwired(action)) continue;
        if (actionLayerRidesConsumptionSite(action)) continue;
        history.session.queueActionSound(history.backing_allocator, action);
    }
}

/// Actions whose action layer rides the CONSUMPTION site (excluded from the
/// fired-actions choke point): the layer must reflect the consumption
/// OUTCOME, not the firing - undo/redo sound only when a step actually
/// happened (a no-op at the timeline start stays silent), swap_weapons
/// only past its any-weapon/prepared gate, cancel only with a live
/// preparation to cancel, the skill slots play their layer only on
/// prepare/unprepare (an auto-fire cast plays the full skill cue instead -
/// see main.zig's release-seam skill-slot skip), and skip only when the
/// skip orchestrator actually fires (the handler's queue - the layer
/// plays once; a skip that never reaches the orchestrator stays silent).
/// A missing entry here DOUBLE-PLAYS the layer (the choke point + the
/// consumption site) - the shipped skip layer did exactly that before
/// `.skip` joined this set.
fn actionLayerRidesConsumptionSite(action: types.Action) bool {
    return switch (action) {
        .undo, .redo, .swap_weapons, .cancel, .skip => true,
        else => types.actionIsSkillSlot(action),
    };
}

/// The screens where the editor browser and its in-window actions
/// (New Mission, tabs, rows) are consumed: the editor screen (with the
/// editor state populated - the save_editor_mission discipline) and the
/// main menu (the Editor button's entry point). Button-only from the
/// main menu: the browser keybinds ship editor-context, so on the main
/// menu only the button path reaches these consumption sites.
fn editorBrowserReachableScreen(current_state: *const state.GameState) bool {
    if (current_state.screen == .editor) return current_state.editor != null;
    return current_state.screen == .main_menu;
}

/// Escape: close the topmost open overlay; with nothing closable open (and
/// on level/hub), open the options menu. The steps mirror the view's z-order
/// (topmost surface first; the error popup is more-modal still but is
/// consumed by the pending_error gate at the top of handleAnytimeInput).
/// Mission fail/complete reuse the exact orchestrator events their overlay
/// buttons push, so Escape ≡ clicking the button - both land on the undo
/// timeline as recorded player actions. See DESIGN → Input → Escape overlay
/// chain.
// --- Keybinds tab editing (TODO → Keybind editor slice 4) ---
//
// The capture resolution + the confirm/remove/reset mutations. The phase
// transitions live in the `.edit_keybind` options_action arm above; the
// capture seam lives in `translateInput` (`ui.routeKeybindCapture`).

/// Resolve one frame's keybind-capture outcome (`main.frame`'s
/// once-per-frame site - the text-edit-resolution model). Canceled: drop
/// the edit. Captured (only during a LISTENING edit): build the PENDING
/// proposal - the target's action + the captured combo (the held
/// modifiers became the requirements) - and scan for the steal. Pure
/// UiState writes; the settings mutation happens only at Confirm.
pub fn resolveKeybindCaptureOutcome(
    history: *GameStateHistory,
    outcome: types.KeybindCaptureOutcome,
) void {
    const ui_state = &history.session.ui_state;
    const edit_state = &(ui_state.keybind_edit orelse return);
    switch (outcome) {
        .none => {},
        .canceled => ui_state.keybind_edit = null,
        // Enter during pending: apply the proposal (the modal-capture-state
        // convention - the Confirm button's keyboard path).
        .confirmed => applyKeybindEdit(history),
        .captured => {
            const target = switch (edit_state.edit) {
                .listening => |listening_target| listening_target,
                // A capture outside listening never happens (the seam gates
                // on the phase); defensive no-op.
                else => return,
            };
            const action = switch (target) {
                .binding => |index| history.settings.input_bindings[index].action,
                .add => |add_action| add_action,
                // A standalone add never listens before its action pick.
                .add_new => return,
            };
            const candidate: types.InputBinding = .{
                .input = edit_state.capture.rawInput(),
                .modifiers = edit_state.capture.modifiers,
                .action = action,
            };
            const exclude_index: ?usize = switch (target) {
                .binding => |index| index,
                .add, .add_new => null,
            };
            edit_state.edit = .{ .pending = .{
                .binding = candidate,
                .replace_index = exclude_index,
                .stolen_index = findKeybindSteal(history.settings.input_bindings, candidate, exclude_index),
            } };
        },
    }
}

/// The steal scan (the keybind UI's half of the one-combo-one-action rule -
/// see DESIGN → Input → Hybrid precedence + binding conflicts): the first
/// binding other than `exclude_index` (the row being edited) that occupies
/// the candidate's combo AND would co-fire with it (different actions whose
/// derived contexts intersect) or duplicates it (same action - a redundant
/// entry; confirming dedupes). Cross-context same-combo pairs are LEGAL
/// (kept - the scan continues past them). Confirming REMOVES the returned
/// entry - the edited row wins (the loader's first-listed-wins rule).
fn findKeybindSteal(
    bindings: []const types.InputBinding,
    candidate: types.InputBinding,
    exclude_index: ?usize,
) ?usize {
    for (bindings, 0..) |binding, index| {
        if (exclude_index != null and index == exclude_index.?) continue;
        if (!types.sameCombo(binding, candidate)) continue;
        if (binding.action == candidate.action) return index;
        if (types.bindingContextsCoFire(
            types.actionBindingContexts(binding.action),
            types.actionBindingContexts(candidate.action),
        )) {
            return index;
        }
    }
    return null;
}

/// Dupe a binding's input id so a rebuilt list owns its strings (the
/// loadSettings ownership contract - see DESIGN → File System & IO →
/// Settings ownership).
fn dupeBindingInput(raw_input: types.RawInput, allocator: std.mem.Allocator) types.RawInput {
    return switch (raw_input) {
        .key => |id| .{ .key = allocator.dupe(u8, id) catch @panic("failed to dupe binding id") },
        .mouse_button => |id| .{ .mouse_button = allocator.dupe(u8, id) catch @panic("failed to dupe binding id") },
        .gamepad_button => |id| .{ .gamepad_button = allocator.dupe(u8, id) catch @panic("failed to dupe binding id") },
    };
}

/// Rebuild `settings.input_bindings` around an edit: the caller decides per
/// index (keep / drop - freeing the entry's owned string) and supplies the
/// entries to append. Kept entries' strings MOVE into the new list (only the
/// old slice backing is freed, not the strings); dropped + appended
/// entries' strings are freed / duped respectively. The camera_zoom
/// discipline: mutate + mark dirty.
fn rebuildInputBindings(
    history: *GameStateHistory,
    drop_mask: []const bool,
    appended: []const types.InputBinding,
) void {
    const allocator = history.backing_allocator;
    const old = history.settings.input_bindings;
    var bindings: std.ArrayList(types.InputBinding) = .empty;
    for (old, 0..) |binding, index| {
        if (drop_mask[index]) {
            loaders.freeRawInputString(binding.input, allocator);
            continue;
        }
        bindings.append(allocator, binding) catch @panic("failed to rebuild input bindings");
    }
    for (appended) |binding| {
        bindings.append(allocator, .{
            .input = dupeBindingInput(binding.input, allocator),
            .modifiers = binding.modifiers,
            .action = binding.action,
        }) catch @panic("failed to rebuild input bindings");
    }
    if (old.len > 0) allocator.free(old);
    history.settings.input_bindings = bindings.toOwnedSlice(allocator) catch
        @panic("failed to rebuild input bindings");
    state.markSettingsDirty(history);
}

/// Apply the pending proposal (Confirm): replace the target entry (or
/// append - an add) and REMOVE the stolen entry. The pending combo's id
/// lives in the capture's buffer - duped into the settings allocation here.
fn applyKeybindEdit(history: *GameStateHistory) void {
    const ui_state = &history.session.ui_state;
    const edit_state = &(ui_state.keybind_edit orelse return);
    const pending = switch (edit_state.edit) {
        .pending => |pending_keybind| pending_keybind,
        else => return,
    };
    const allocator = history.backing_allocator;
    const old = history.settings.input_bindings;
    const drop_mask = allocator.alloc(bool, old.len) catch
        @panic("failed to allocate binding rebuild mask");
    defer allocator.free(drop_mask);
    for (old, 0..) |_, index| {
        drop_mask[index] = (pending.stolen_index == index) or (pending.replace_index == index);
    }
    // The replace entry + the append entry: same proposal, one binding.
    rebuildInputBindings(history, drop_mask, &.{pending.binding});
    ui_state.keybind_edit = null;
}

/// Remove one binding (the row's X - direct, no confirm; Reset to defaults
/// is the safety net).
fn removeKeybindBinding(history: *GameStateHistory, index: usize) void {
    const allocator = history.backing_allocator;
    if (index >= history.settings.input_bindings.len) return;
    const drop_mask = allocator.alloc(bool, history.settings.input_bindings.len) catch
        @panic("failed to allocate binding rebuild mask");
    defer allocator.free(drop_mask);
    for (drop_mask, 0..) |*drop, drop_index| drop.* = drop_index == index;
    rebuildInputBindings(history, drop_mask, &.{});
    history.session.ui_state.keybind_edit = null;
}

/// Replace ALL settings (every preference + bindings) with the shipped
/// defaults (Reset to Defaults): back up the current settings first (see
/// `backUpSettingsFile`), then re-load the embedded
/// `data/default_settings.txt` wholesale - the current settings are freed
/// via `freeSettings` and replaced. `Settings` carries no identity data
/// (no player name - that lives in the player save), so a full reset is
/// purely preferences + bindings. The fresh settings' strings are
/// loadSettings-owned (the standard ownership contract). Reset to Defaults
/// is the undo for the whole editing UI (settings changes carry no undo
/// steps).
fn resetSettingsToDefaults(history: *GameStateHistory) void {
    backUpSettingsFile(history);
    const allocator = history.backing_allocator;
    const bytes = history.file_source.readEmbeddedFile(allocator, "data/default_settings.txt") catch return;
    defer allocator.free(bytes);
    const sections = parser.parseConfigFile(bytes, allocator) catch return;
    defer parser.freeParsedSections(sections, allocator);
    const fresh = loaders.loadSettings(sections, allocator, null, null) catch return;
    loaders.freeSettings(history.settings, allocator);
    history.settings = fresh;
    history.session.ui_state.keybind_edit = null;
    history.session.ui_state.keybind_scroll_offset = 0;
    state.markSettingsDirty(history);
}

/// Back up `settings.txt` before Reset to Defaults overwrites it (the
/// `backup_autosave` policy - see DESIGN → File System & IO): a
/// synchronous flush FIRST (the debounced writer, so the file is the exact
/// current settings, not up to the 5s debounced-write max-stale), then a
/// byte copy to `settings-backup-<timestamp>.txt` in the persistent root
/// (next to `settings.txt` - `saves/` stays for save files). Best-effort:
/// a failure surfaces the recoverable-error popup but does NOT stop the
/// reset (the reset is what the user asked for; informed destruction). A
/// fresh install with no `settings.txt` yet has nothing to back up -
/// silent skip. Same-second collision overwrites (accepted - the
/// autosave-backup convention). Live-path side effect (input handling is
/// never replayed), so no `!replaying` gate needed.
fn backUpSettingsFile(history: *GameStateHistory) void {
    const allocator = history.backing_allocator;
    state.writeSettingsToFile(history);
    if (!history.file_source.fileExists("settings.txt")) return;
    const bytes = history.file_source.readFile(allocator, "settings.txt") catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to back up settings",
        );
        return;
    };
    defer allocator.free(bytes);
    const timestamp = session_log.formatSessionTimestamp(allocator, history.io);
    defer allocator.free(timestamp);
    const backup_path = std.fmt.allocPrint(allocator, "settings-backup-{s}.txt", .{timestamp}) catch
        @panic("failed to allocate backup path");
    defer allocator.free(backup_path);
    history.file_source.writeFile(backup_path, bytes) catch {
        history.session.setPendingError(
            history.history_arena.allocator(),
            "failed to back up settings",
        );
        return;
    };
}

fn handleEscapeKey(history: *GameStateHistory) void {
    const current = &history.current_state;
    const surfaces = &current.ui_surfaces;

    // The chain is ordered to mirror the view's z-order (topmost first);
    // the census test in view.zig pins the emission ladder this mirrors.
    // Every close/open is a `player_toggle_ui_surface` push + drain (the
    // class-1 surface state rides the undo timeline - see DESIGN → UI
    // Framework → UI state classification); the immediate drain is what
    // lets this frame's own options-menu gate below see the flipped state
    // (the swap_weapons interjection discipline).

    // Editor browser (opens over the editor, on top of the options menu,
    // or over the main menu): Escape steps back one layer - only the
    // browser closes. Above the settings screen in the ladder (the
    // browser block emits after it in view()).
    if (surfaces.editor_browser_open) {
        pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
            .surface = .editor_browser,
        } });
        return;
    }

    // Settings overlay. In-game
    // it opens on top of the options menu, so Escape steps back to the menu
    // underneath - only the settings layer closes.
    if (surfaces.settings_open) {
        pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
            .surface = .settings,
        } });
        return;
    }

    // Mission-complete overlay: Escape fires the Continue button's
    // dismiss_mission_complete (on the undo timeline - undo re-shows, redo
    // dismisses). Above the mission-fail overlay in the ladder (never
    // co-rendered - complete shows in the hub/editor, fail on a level).
    if (current.last_completed_mission != null) {
        pushPlayerActionAndDrain(history, .dismiss_mission_complete);
        return;
    }

    // Mission-fail overlay: Escape fires the same orchestrator its Exit
    // Mission button does (end_level routes PlayerData persistence + the
    // return to the hub). Undo (processed earlier in handleAnytimeInput)
    // remains the other escape from the fail state.
    if (view_mod.playerDead(current)) {
        if (current.screen != .level) return;
        pushPlayerActionAndDrain(history, .player_exit_mission);
        return;
    }

    // Main-menu overlays (load-save browser, credits - both reachable
    // from the main menu's own stack/options menu; they open on top of
    // the options menu, so they sit topmost whenever they're up).
    if (surfaces.load_save_menu_open) {
        pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
            .surface = .load_save_menu,
        } });
        return;
    }
    if (surfaces.credits_open) {
        pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
            .surface = .credits,
        } });
        return;
    }

    // Options menu (always-on-top modal): close it, leaving any full-screen
    // overlay beneath it open.
    if (surfaces.options_menu_open) {
        pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
            .surface = .options_menu,
        } });
        return;
    }

    // Full-screen overlays (world map, full combat log): close the topmost
    // open one (the last occupied slot draws on top).
    var topmost_overlay: ?types.FullScreenOverlayId = null;
    for (surfaces.open_full_screen_overlays) |maybe_overlay| {
        if (maybe_overlay) |overlay| topmost_overlay = overlay;
    }
    if (topmost_overlay) |overlay_id| {
        pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
            .surface = fullScreenOverlaySurfaceId(overlay_id),
        } });
        return;
    }

    // Nothing to close: open the options menu. Every screen has a variant
    // - the main menu's carries Settings/Credits/Exit Game instead of the
    // session verbs (see buildOptionsMenu).
    pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
        .surface = .options_menu,
    } });
}

/// Map a full-screen overlay id to its surface-event id (the two enums
/// name the same surfaces; the overlay enum is the state representation,
/// the surface enum is the event vocabulary).
fn fullScreenOverlaySurfaceId(overlay_id: types.FullScreenOverlayId) types.UiSurfaceId {
    return switch (overlay_id) {
        .world_map => .world_map,
        .full_combat_log => .full_combat_log,
    };
}

/// The value `payloadAs` returns for `tag`: the variant's payload type,
/// with an inner optional flattened - `.editor_layer`'s ?u32 stays ?u32
/// (not ??u32), so the null-meaningful variants read exactly like the old
/// per-field optionals did.
fn PayloadAsType(comptime tag: types.ButtonPayloadTag) type {
    // The inline field walk with comptime name compares crosses the default
    // eval-branch quota once payloadAs is instantiated for many variants.
    @setEvalBranchQuota(10_000);
    inline for (@typeInfo(types.ButtonPayload).@"union".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, @tagName(tag))) {
            return switch (@typeInfo(field.type)) {
                .optional => field.type,
                else => ?field.type,
            };
        }
    }
}

/// The frame's clicked-button payload when it is `tag`, else null - the
/// consumption-site read shape: "my arm's variant, or the click didn't
/// happen". Belt-and-suspenders behind main.zig's relay fail-fast check
/// (the console path fires payload-needing actions with no payload - they
/// no-op here by design; the payload IS the click).
fn payloadAs(
    comptime tag: types.ButtonPayloadTag,
    clicked_payload: ?types.ButtonPayload,
) PayloadAsType(tag) {
    const payload = clicked_payload orelse return null;
    if (std.meta.activeTag(payload) != tag) return null;
    return @field(payload, @tagName(tag));
}

pub fn handleAnytimeInput(
    history: *GameStateHistory,
    anytime: input.AnytimeInput,
    /// The frame's clicked-button payload (see `types.ButtonPayload`),
    /// riding alongside `anytime.options_action` - the handler arm that
    /// fires the action reads its variant.
    clicked_payload: ?types.ButtonPayload,
    /// Pointer position this frame, for scroll-delta routing (skills browser
    /// scroll vs camera zoom). The skills panel is scrolled when the pointer
    /// is over one of its slots - see `skillsSlotUnderPointer`.
    pointer_position: types.ScreenPosition,
    /// Last frame's UI elements - the pointer is over what was just drawn.
    ui_elements: []const ui.UiElement,
) void {
    // Recoverable error popup is modal: when a pending error is set, only
    // `dismiss_error` and the scroll actions get through; everything else
    // (including undo/redo, the options-menu toggle, and the camera-zoom
    // wheel) is swallowed until the popup is dismissed. The state has
    // already been reverted by the time the error is set, so there is
    // nothing to undo. The wheel (`scroll_delta`) is redirected here to
    // scroll the popup body instead of zooming the camera. Scrolling is
    // LINE-based - the game-wide row-scroll convention (the inspector /
    // skills-panel / browser model): the offset is the first visible body
    // line, the wheel scrolls one line per notch with wheel-up = earlier
    // lines (offset decreases), and the arrow keys 3 lines per press.
    // Lower clamp here; `buildErrorPopup` clamps the upper bound in place
    // (authoritative - only the view knows the wrapped line count).
    // See DESIGN → Error Handling → Recoverable error surface.
    if (history.session.pending_error != null) {
        if (anytime.dismiss_error) {
            history.session.clearPendingError();
            return;
        }
        if (anytime.error_scroll_up) {
            history.session.error_scroll_offset -= 3;
        }
        if (anytime.error_scroll_down) {
            history.session.error_scroll_offset += 3;
        }
        const delta_lines: i32 = @intFromFloat(anytime.scroll_delta);
        history.session.error_scroll_offset -= delta_lines;
        if (history.session.error_scroll_offset < 0) {
            history.session.error_scroll_offset = 0;
        }
        return;
    }

    if (anytime.undo) {
        // Sound only when a step actually undid (a no-op at the timeline
        // start stays silent).
        if (history.undo(&event_handlers.processEvent)) {
            if (!history.replaying) history.session.queueActionSound(history.backing_allocator, .undo);
        }
    }

    if (anytime.redo) {
        if (history.redo(&event_handlers.processEvent)) {
            if (!history.replaying) history.session.queueActionSound(history.backing_allocator, .redo);
        }
    }

    if (anytime.dump_event_log) {
        dumpEventLog(history);
    }

    if (anytime.save_editor_mission) {
        // The editor's save: a pure side effect (the dump_event_log class -
        // no recorded event, no undo step; replay never runs the input
        // layer). Editor-only; every other screen no-ops (the
        // delete_editor_selection discipline).
        if (history.current_state.screen == .editor and history.current_state.editor != null) {
            // The popup on failure is surfaced inside; the return value is
            // irrelevant to the bare save button.
            _ = mission_io.saveEditorMission(history);
        }
    }

    if (anytime.export_editor_mission) {
        // The mission export - same side-effect class + gates as the save.
        if (history.current_state.screen == .editor and history.current_state.editor != null) {
            mission_io.exportEditorMission(history);
        }
    }

    if (anytime.toggle_editor_browser) {
        // The editor browser (the main-menu Editor button, the options-menu
        // Open Mission button, the browser's Back button, ctrl+O). Reachable
        // on the editor + main-menu screens; every other screen no-ops (the
        // save_editor_mission discipline).
        if (editorBrowserReachableScreen(&history.current_state)) {
            // Fresh view state on every open (the load-save browser's
            // reset-on-open pattern): scroll to the top + the local tab
            // (your collection is the primary target), then scan now -
            // decided from the pre-toggle state (class-2 view state, direct
            // writes; the open/close itself is the recorded surface event).
            if (!history.current_state.ui_surfaces.editor_browser_open) {
                history.session.ui_state.editor_mission_scroll_offset = 0;
                history.session.ui_state.editor_mission_browser_tab = .local;
                mission_io.rescanEditorMissionsNow(history);
            }
            pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
                .surface = .editor_browser,
            } });
        }
    }

    if (anytime.new_editor_mission) {
        // The fresh-mission open (the editor browser's New Mission button,
        // the options-menu New Mission button, ctrl+N): a RECORDED player
        // action (`open_editor` with a null path, the same event the
        // browser rows fire with a path), so replay + undo reproduce the
        // open/swap. The open_editor handler bumps world_generation, so
        // the post-update UI reset closes the options menu / browser /
        // pickers over it. Reachable on the editor + main-menu screens;
        // every other screen no-ops (the save_editor_mission discipline).
        if (editorBrowserReachableScreen(&history.current_state)) {
            pushPlayerActionAndDrain(history, .{ .open_editor = .{ .mission_path = null } });
        }
    }

    if (anytime.escape) {
        handleEscapeKey(history);
    }

    // Options menu actions dispatch before the modal gate so they take effect
    // immediately despite the menu pausing the game. Draining is
    // pushPlayerActionAndDrain's job (see its doc for the baseline reasoning).
    if (anytime.options_action) |action| {
        // The action's layer queues ONCE at the fired-actions choke point
        // (`dispatchFiredActionSounds` - see DESIGN → Audio, layered cues);
        // the release seam owns the base up.
        const current = &history.current_state;
        const allocator = history.current_arena.allocator();
        switch (action) {
            .save_game => {
                // Never during an editor run (playtest/validate): the run's
                // player_data is temporary (rebuilt from the editor loadout,
                // restored on exit), so a save would write the throwaway run
                // data as a campaign save - the same reason buildOptionsMenu
                // hides the Export Save button mid-run. `save_game` is
                // button-only today (no binding ships), so this gate is the
                // defensive half for a future keybind; the button half lives
                // in the view.
                if (current.editor) |editor| {
                    if (editor.mode != .edit) return;
                }
                const timestamp = session_log.formatSessionTimestamp(allocator, history.io);
                const save_path = std.fmt.allocPrint(
                    allocator,
                    "saves/save_{s}.txt",
                    .{timestamp},
                ) catch @panic("failed to format save path");
                pushPlayerActionAndDrain(history, .{ .save_game = .{ .save_path = save_path } });
            },
            // Export Game (web only - the view gates on the web signal,
            // `persistent_dir_path == null`; the comptime gate here is the
            // defensive half for a future keybind, the Exit Game
            // discipline). The autosave write (a game in progress) drains
            // FIRST via the orchestrator arm - mid-level progress is in the
            // zip - then the zip + download run here (a live-path side
            // effect, the reset-to-defaults class: input handling never
            // replays, so no replay gate).
            .export_game => {
                if (@import("builtin").os.tag != .emscripten) return;
                pushPlayerActionAndDrain(history, .export_game);
                game_zip.exportGameFolder(history);
            },
            // Exit-path buttons: push the player orchestrator event, then
            // drain. The orchestrator handler pushes the machinery (end_level
            // or end_hub + open_main_menu) as children. See events.zig.
            .restart_mission => {
                if (current.screen != .level) return;
                pushPlayerActionAndDrain(history, .player_restart_mission);
            },
            .exit_mission => {
                if (current.screen != .level) return;
                pushPlayerActionAndDrain(history, .player_exit_mission);
            },
            .exit_to_menu => {
                pushPlayerActionAndDrain(history, .player_exit_to_menu);
            },
            // Mission-complete overlay: Continue pushes dismiss_mission_complete
            // (on the undo timeline - undo re-shows, redo dismisses). Replay
            // re-enters the mission: end_hub syncs the hub player entity first
            // (LIFO), then start_mission reloads from the completed-mission
            // path. The overlay disappears on the screen transition (renders
            // only in the hub); undo from the level back to the hub re-shows
            // it (last_completed_mission is in the snapshot).
            .continue_after_mission => {
                pushPlayerActionAndDrain(history, .dismiss_mission_complete);
            },
            .replay_mission => {
                if (current.last_completed_mission == null) return;
                pushPlayerActionAndDrain(history, .player_replay_mission);
            },
            .overwrite_clone => {
                const info = current.last_completed_mission orelse return;
                if (!info.overwrite_offered) return;
                pushPlayerActionAndDrain(history, .player_overwrite_clone);
            },
            // The validation stats screen's manual Overwrite Replay button:
            // write the STASHED slower-run replay bytes over the personal
            // best (a pure side effect - the bytes are session-side, no
            // recorded event; the mission_io fn owns the write + the
            // stash/offer/pb cleanup). Gated on the offer: the button only
            // shows while offered, but a stale click (an offer retired by
            // a newer run) no-ops.
            .overwrite_validation_replay => {
                if (!history.session.validation_replay_overwrite_offered) return;
                mission_io.overwritePendingValidationReplay(history);
            },
            // Settings button (main menu OR options menu): toggle the
            // settings overlay. From the options menu it opens on top
            // (drill-in; Back returns here); from the main menu it opens
            // over the menu directly. Routed through `options_action` so
            // one handler serves both contexts. See DESIGN → UI Framework
            // → Settings screen.
            .open_settings => pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
                .surface = .settings,
            } }),
            // Credits (the main-menu options menu variant): toggle the
            // overlay - it opens on top of this menu, and the Back button
            // reuses this action to close (the load-save browser's toggle
            // pattern). Routed through `options_action` because idle input
            // is gated while the options menu is open.
            .open_credits => pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
                .surface = .credits,
            } }),
            // Exit Game (the main-menu options menu variant, native only -
            // the button is not emitted on web, where closing the tab is
            // the user's). A request, not a state transform: the game loop's
            // exit condition consumes it and the shutdown defers flush.
            // The comptime os gate is the defensive half for a future
            // keybind; the button half lives in the view.
            .exit_game => {
                if (@import("builtin").os.tag != .emscripten) {
                    history.session.quit_requested = true;
                }
            },
            // A settings edit command was clicked (the whole editing UI
            // rides this one action + the `KeybindCommand` payload). All
            // phase transitions are direct UiState writes (off the undo
            // timeline); the SETTINGS mutation happens only at remove /
            // confirm / reset (the camera_zoom discipline - mutate + mark
            // dirty). The key-capture seam lives in `translateInput`
            // (`ui.routeKeybindCapture`) + main.frame's
            // `resolveKeybindCaptureOutcome`; the builder renders the
            // phases. The keybinds-tab commands only fire on the keybinds
            // tab; `.reset_defaults` is a whole-settings command (its
            // bottom-right button shows on both tabs). See DESIGN → UI
            // Framework → Settings screen.
            .edit_keybind => {
                if (!history.current_state.ui_surfaces.settings_open) return;
                const command = payloadAs(.keybind_command, clicked_payload) orelse return;
                if (history.session.ui_state.settings_tab != .keybinds and command != .reset_defaults) return;
                const ui_state = &history.session.ui_state;
                switch (command) {
                    .rekey => |index| {
                        if (index >= history.settings.input_bindings.len) return;
                        ui_state.keybind_edit = .{ .edit = .{ .listening = .{ .binding = index } } };
                    },
                    .reassign => |index| {
                        if (index >= history.settings.input_bindings.len) return;
                        ui_state.keybind_picker_scroll_offset = 0;
                        ui_state.keybind_edit = .{ .edit = .{ .picker = .{ .binding = index } } };
                    },
                    .add => |add_action| {
                        ui_state.keybind_edit = .{ .edit = .{ .listening = .{ .add = add_action } } };
                    },
                    .add_open => {
                        ui_state.keybind_picker_scroll_offset = 0;
                        ui_state.keybind_edit = .{ .edit = .{ .picker = .add_new } };
                    },
                    .remove => |index| removeKeybindBinding(history, index),
                    .pick => |picked_action| {
                        const edit_state = &(ui_state.keybind_edit orelse return);
                        switch (edit_state.edit) {
                            .picker => |picker_target| switch (picker_target) {
                                // Reassign: the target row's combo + the
                                // picked action → pending (the steal scan
                                // excludes the row itself).
                                .binding => |index| {
                                    if (index >= history.settings.input_bindings.len) return;
                                    const target = history.settings.input_bindings[index];
                                    const candidate: types.InputBinding = .{
                                        .input = target.input,
                                        .modifiers = target.modifiers,
                                        .action = picked_action,
                                    };
                                    edit_state.edit = .{ .pending = .{
                                        .binding = candidate,
                                        .replace_index = index,
                                        .stolen_index = findKeybindSteal(history.settings.input_bindings, candidate, index),
                                    } };
                                },
                                // Standalone add: the action is known now →
                                // listen for the combo.
                                .add_new => edit_state.edit = .{ .listening = .{ .add = picked_action } },
                                // A row's `+` never opens the picker.
                                .add => return,
                            },
                            else => return,
                        }
                    },
                    .confirm => applyKeybindEdit(history),
                    .cancel => ui_state.keybind_edit = null,
                    .reset_defaults => resetSettingsToDefaults(history),
                }
            },
            // A settings screen content tab was clicked (Settings /
            // Keybinds). A view affordance - direct UiState write, off the
            // undo timeline (the editor-browser tab convention); the scroll
            // resets on switch (the other tab's list has its own extent)
            // and an active keybind edit is discarded (a hidden surface
            // must not carry edit state).
            .select_settings_tab => {
                if (!history.current_state.ui_surfaces.settings_open) return;
                const settings_tab = payloadAs(.settings_tab, clicked_payload) orelse return;
                if (history.session.ui_state.settings_tab == settings_tab) return;
                history.session.ui_state.settings_tab = settings_tab;
                history.session.ui_state.keybind_scroll_offset = 0;
                history.session.ui_state.keybind_edit = null;
            },
            // A settings toggle or choice was clicked (the `SettingRef`
            // payload). Mutate `history.settings` (a
            // direct write - settings are off the undo timeline, like
            // `ui_state` toggles) + mark dirty for debounced persistence.
            // See DESIGN → UI Framework → Settings screen.
            .change_setting => {
                const sref = payloadAs(.setting, clicked_payload) orelse return;
                const settings = &history.settings;
                switch (sref.id) {
                    .vsync => settings.vsync = !settings.vsync,
                    .auto_skip_attack_step_out_of_combat => settings.auto_skip_attack_step_out_of_combat = !settings.auto_skip_attack_step_out_of_combat,
                    .auto_target_at_cursor => settings.auto_target_at_cursor = !settings.auto_target_at_cursor,
                    .show_fps => settings.show_fps = !settings.show_fps,
                    .camera_zoom => settings.camera_zoom = sref.choice_value orelse return,
                    .player_color_index => settings.player_color_index = sref.choice_value orelse return,
                    // Choice buttons carry the preset's int tag; the live
                    // apply (frame diff-and-apply) swaps the render target.
                    .render_resolution => settings.render_resolution = @enumFromInt(sref.choice_value orelse return),
                    // Sliders are handled by the drag handler (slice 3b),
                    // not by this click path. A click on a slider label
                    // area without a choice_value is a no-op here.
                    .master_volume,
                    .music_volume,
                    .sound_effects_volume,
                    .render_fps_cap,
                    .animation_fps,
                    => return,
                }
                state.markSettingsDirty(history);
            },
            // Editor palette group header (expand/collapse). The group
            // index rides the payload. View-side
            // display state - a direct UiState write, off the undo timeline
            // (same class as the panel-toggle flags). Accordion: expanding
            // a group collapses the others (one group open at a time);
            // collapsing just closes the clicked one.
            .toggle_editor_palette_group => {
                const group_index = payloadAs(.editor_group, clicked_payload) orelse return;
                if (group_index >= 3) return;
                if (history.session.ui_state.editor_palette_collapsed[group_index]) {
                    for (&history.session.ui_state.editor_palette_collapsed) |*is_collapsed| {
                        is_collapsed.* = true;
                    }
                    history.session.ui_state.editor_palette_collapsed[group_index] = false;
                } else {
                    history.session.ui_state.editor_palette_collapsed[group_index] = true;
                }
            },
            // Palette group "+" (add-new type): push the per-kind
            // orchestrator + drain - the handler builds the type from the
            // shipped defaults (data/editor_defaults.txt), makes it the
            // active tool, and opens the inspector. For enemies +
            // decorations the base-sprite picker then opens on the new
            // type (the mission rescan + Mission-tab reset - the inspector
            // Sprite row's open path; the picker's commit targets the new
            // type through the active tool it set). Ground items have no
            // sprite to pick.
            .add_editor_palette_type => {
                const group_index = payloadAs(.editor_group, clicked_payload) orelse return;
                if (current.editor == null) return;
                switch (group_index) {
                    0 => pushPlayerActionAndDrain(history, .player_add_editor_entity_type),
                    1 => pushPlayerActionAndDrain(history, .player_add_editor_decoration_type),
                    2 => pushPlayerActionAndDrain(history, .player_add_editor_item_type),
                    else => return,
                }
                // A failed defaults read reverts the action (the popup path)
                // - no picker on top of a reverted creation.
                if (history.load_error) return;
                // The new type lands at the END of its group's list (the
                // handler appends + points the active tool at it), so the
                // group expands - accordion: the others collapse, the
                // header-toggle discipline - and its window scrolls to the
                // end, making the new cell the last visible one. View-side
                // display state, off the undo timeline (the toggle branch's
                // class).
                {
                    const editor_after_add = &(history.current_state.editor orelse return);
                    const group_size: usize = switch (group_index) {
                        0 => editor_after_add.entity_types.len,
                        1 => editor_after_add.decoration_types.len,
                        2 => editor_after_add.item_types.len,
                        else => return,
                    };
                    for (&history.session.ui_state.editor_palette_collapsed) |*is_collapsed| {
                        is_collapsed.* = true;
                    }
                    history.session.ui_state.editor_palette_collapsed[group_index] = false;
                    history.session.ui_state.editor_palette_scroll[group_index] =
                        @intCast(group_size -| ui.editor_palette_max_tools);
                }
                // The tool switch the handler made retargets the inspector -
                // any picker still open is stale, so a group 0/1 click
                // OPENS the fresh picker (the open event REPLACES the stale
                // one - dropdown semantics, one action); a group 2 click
                // closes any stale picker. The picker state rides
                // GameState (`Editor.picker`) - see DESIGN → UI Framework
                // → UI state classification.
                if (group_index <= 1) {
                    const editor = &(history.current_state.editor orelse return);
                    mission_io.rescanEditorMissionSprites(history, editor.*);
                    const picker_target: types.EditorPickerTarget = if (group_index == 0)
                        .{ .entity_sprite = {} }
                    else
                        .{ .decoration_sprite = {} };
                    history.session.ui_state.editor_picker_sprite_tab = .mission_local;
                    pushPlayerActionAndDrain(history, .{ .player_open_editor_picker = .{
                        .target = picker_target,
                    } });
                } else if (history.current_state.editor != null and
                    history.current_state.editor.?.picker != null)
                {
                    pushPlayerActionAndDrain(history, .player_close_editor_picker);
                }
            },
            // Palette tool-cell delete button: push the per-kind
            // orchestrator + drain - the editor_delete_type handler fans
            // out into the per-placement deletes (across ALL levels),
            // removes the type, remaps the ids above it, and reconciles
            // the active tool; one undo step restores everything. The
            // fixed tools have no delete button - a crafted
            // select/tile-targeted click does nothing.
            .delete_editor_palette_type => {
                const tool = payloadAs(.editor_tool, clicked_payload) orelse return;
                if (current.editor == null) return;
                switch (tool) {
                    .entity_type => |type_id| pushPlayerActionAndDrain(history, .{
                        .player_delete_editor_type = .{ .type_kind = .entity, .type_id = type_id },
                    }),
                    .decoration_type => |type_id| pushPlayerActionAndDrain(history, .{
                        .player_delete_editor_type = .{ .type_kind = .decoration, .type_id = type_id },
                    }),
                    .item_type => |type_id| pushPlayerActionAndDrain(history, .{
                        .player_delete_editor_type = .{ .type_kind = .item, .type_id = type_id },
                    }),
                    .select, .tile => return,
                }
            },
            // Top-bar add-level "+": push the orchestrator + drain - the
            // handler reads the shipped template (data/default_level.txt)
            // through the reconstruction cache, appends the level, switches
            // to it, and syncs level_count; one undo step reverts it all.
            .add_editor_level => {
                if (current.editor == null) return;
                pushPlayerActionAndDrain(history, .player_add_editor_level);
            },
            // Level-tab ×: push the orchestrator + drain - the handler
            // removes the level, shifts later levels down, syncs
            // level_count, and adjusts the active tab. Gated here too (the
            // UI only offers the × above one level, but a crafted click
            // must not reach the handler's invariant panic).
            .delete_editor_level => {
                const level_index = payloadAs(.editor_level, clicked_payload) orelse return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                if (editor.levels.len <= 1) return;
                if (level_index >= editor.levels.len) return;
                pushPlayerActionAndDrain(history, .{ .player_delete_editor_level = .{
                    .level_index = level_index,
                } });
            },
            // Inspector section header (expand/collapse). The section id
            // rides the payload. View-side display
            // state - a direct UiState write, off the undo timeline (same
            // class as the palette accordion). INDEPENDENT toggles, no
            // accordion - sections are per-topic and often wanted together
            // (e.g. Weapons + Gear).
            .toggle_editor_inspector_section => {
                const section = payloadAs(.editor_section, clicked_payload) orelse return;
                const section_index: usize = @intFromEnum(section);
                history.session.ui_state.editor_inspector_section_expanded[section_index] =
                    !history.session.ui_state.editor_inspector_section_expanded[section_index];
            },
            // The inspector's Sprite row: open the centered sprite picker.
            // The mission-local scan happens HERE (idle input - interactive
            // IO lives at open time, never in the view or handlers; the
            // list is cached on SessionState, re-scanned on every open so
            // a png dropped into the mission dir appears on the next
            // open). The tab resets to Mission (custom assets take
            // priority over shipped ones). The picker KIND follows the
            // inspector target: the decoration content's row opens the
            // decoration picker (registry-fed Official tab, prefab-adopting
            // commits) - the same panel, target-resolved inside the builder.
            .open_editor_sprite_picker => {
                const editor = if (current.editor) |*some_editor| some_editor else return;
                mission_io.rescanEditorMissionSprites(history, editor.*);
                const picker_target: types.EditorPickerTarget = switch (ui.editorInspectorTarget(editor.*)) {
                    .decoration_type => .{ .decoration_sprite = {} },
                    .entity_type, .player => .{ .entity_sprite = {} },
                    // No sprite row in the item content - a crafted click
                    // opens nothing.
                    .item_type => return,
                };
                history.session.ui_state.editor_picker_sprite_tab = .mission_local;
                pushPlayerActionAndDrain(history, .{ .player_open_editor_picker = .{
                    .target = picker_target,
                } });
            },
            // A Layers-section sprite button (add + per-layer re-pick): the
            // same open path - the mission rescan, the Mission-tab reset -
            // with the picker kind fixed by the button's content and the
            // layer index riding the payload (null = add mode).
            .open_editor_entity_layer_picker => {
                const editor = if (current.editor) |*some_editor| some_editor else return;
                mission_io.rescanEditorMissionSprites(history, editor.*);
                history.session.ui_state.editor_picker_sprite_tab = .mission_local;
                pushPlayerActionAndDrain(history, .{ .player_open_editor_picker = .{
                    .target = .{ .entity_layer = payloadAs(.editor_layer, clicked_payload) },
                } });
            },
            .open_editor_decoration_layer_picker => {
                const editor = if (current.editor) |*some_editor| some_editor else return;
                mission_io.rescanEditorMissionSprites(history, editor.*);
                history.session.ui_state.editor_picker_sprite_tab = .mission_local;
                pushPlayerActionAndDrain(history, .{ .player_open_editor_picker = .{
                    .target = .{ .decoration_layer = payloadAs(.editor_layer, clicked_payload) },
                } });
            },
            // The Footprint row's button: open the centered footprint
            // editor - seed the draft grid from the type's current
            // footprint (a direct UiState write; the draft is transient
            // view state, the confirm is what records). The picker target
            // carries the TYPE ID, so a mid-edit tool switch can never
            // silently retarget the draft. A grid beyond the draft
            // capacity (custom art >8x8 tiles) doesn't open - a deliberate
            // UI gate, not a rejection (huge art keeps its committed
            // footprint; see DESIGN → Custom Missions & Online Services →
            // Custom-asset dimensions).
            .open_editor_footprint_picker => {
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const type_id = switch (ui.editorInspectorTarget(editor.*)) {
                    .decoration_type => |resolved_type_id| resolved_type_id,
                    .entity_type, .item_type, .player => return,
                };
                const definition = editor.decoration_types[type_id];
                const grid_width: i32 = @divTrunc(definition.pixel_dims.x + 255, 256);
                const grid_height: i32 = @divTrunc(definition.pixel_dims.y + 255, 256);
                if (grid_width <= 0 or grid_height <= 0) return;
                if (@as(usize, @intCast(grid_width * grid_height)) > ui.editor_footprint_grid_cell_limit) return;
                history.session.ui_state.editor_footprint_draft =
                    .{false} ** ui.editor_footprint_grid_cell_limit;
                for (definition.footprint) |tile| {
                    if (tile.x < 0 or tile.y < 0 or tile.x >= grid_width or tile.y >= grid_height) continue;
                    history.session.ui_state.editor_footprint_draft[
                        @intCast(tile.y * grid_width + tile.x)
                    ] = true;
                }
                pushPlayerActionAndDrain(history, .{ .player_open_editor_picker = .{
                    .target = .{ .decoration_footprint = type_id },
                } });
            },
            // A footprint-editor tile cell: flip that draft cell - a
            // direct UiState write (off the undo timeline; the confirm is
            // the event). The cell index is bounds-checked against the
            // stored type's CURRENT grid (a stale index can't come from
            // the live buttons - the builder re-derives the grid every
            // frame).
            .toggle_editor_footprint_tile => {
                const editor: *types.Editor = &(history.current_state.editor orelse return);
                const type_id = expectPickerKind(editor, .decoration_footprint) orelse return;
                const cell_index = payloadAs(.editor_footprint_tile, clicked_payload) orelse return;
                if (type_id >= editor.decoration_types.len) return;
                const definition = editor.decoration_types[type_id];
                const grid_width: i32 = @divTrunc(definition.pixel_dims.x + 255, 256);
                const grid_height: i32 = @divTrunc(definition.pixel_dims.y + 255, 256);
                if (cell_index >= @as(u32, @intCast(grid_width * grid_height))) return;
                history.session.ui_state.editor_footprint_draft[cell_index] =
                    !history.session.ui_state.editor_footprint_draft[cell_index];
            },
            // The footprint editor's Confirm: close the picker and commit
            // the draft IF it differs (row-major sprite-grid coords). An
            // UNCHANGED draft closes without recording; an EMPTY draft
            // stays open - a footprint must reserve at least one tile
            // (the load-time invariant), so the confirm visibly doesn't
            // take. The handler prunes the type's now-invalid placements
            // (an edited footprint re-anchors).
            .confirm_editor_footprint => {
                const editor: *types.Editor = &(history.current_state.editor orelse return);
                const type_id = expectPickerKind(editor, .decoration_footprint) orelse return;
                if (type_id >= editor.decoration_types.len) return;
                const definition = editor.decoration_types[type_id];
                const grid_width: i32 = @divTrunc(definition.pixel_dims.x + 255, 256);
                const grid_height: i32 = @divTrunc(definition.pixel_dims.y + 255, 256);

                var footprint: std.ArrayList(types.Vector2) = .empty;
                for (0..@as(usize, @intCast(grid_height))) |row| {
                    for (0..@as(usize, @intCast(grid_width))) |column| {
                        if (history.session.ui_state.editor_footprint_draft[row * @as(usize, @intCast(grid_width)) + column]) {
                            footprint.append(history.current_arena.allocator(), .{
                                .x = @intCast(column),
                                .y = @intCast(row),
                            }) catch @panic("failed to allocate footprint draft");
                        }
                    }
                }
                if (footprint.items.len == 0) return;
                // An UNCHANGED draft closes without committing - the close
                // itself is the recorded change (the picker surface event;
                // a changed draft commits, and the commit orchestrator's
                // handler pushes the close as a child - pick+close is one
                // undo step).
                if (loaders.decorationFootprintEqual(definition.footprint, footprint.items)) {
                    pushPlayerActionAndDrain(history, .player_close_editor_picker);
                    return;
                }
                pushPlayerActionAndDrain(history, .{ .player_set_editor_decoration_footprint = .{
                    .type_id = type_id,
                    .value = footprint.items,
                } });
            },
            // The metadata sidebar's gradient swatch: open the centered
            // theme picker for that role. The target snapshots the ACTIVE
            // level index - a mid-edit tab switch can't retarget the pick
            // (the footprint editor's convention).
            .open_editor_level_gradient_picker => {
                if (current.editor == null) return;
                const editor: *types.Editor = &current.editor.?;
                const role = payloadAs(.editor_gradient_role, clicked_payload) orelse return;
                if (editor.levels.len == 0) return;
                const level_index = @min(editor.active_level_index, editor.levels.len - 1);
                pushPlayerActionAndDrain(history, .{ .player_open_editor_picker = .{
                    .target = .{ .level_gradient = .{
                        .level_index = @intCast(level_index),
                        .role = role,
                    } },
                } });
                // Scroll the CURRENT gradient into view on open (the level
                // tab follow's rule - the highlight is the point of the
                // list, an offscreen one reads as broken): the smallest
                // offset whose window still contains it. The builder clamps
                // authoritatively next frame.
                const level = editor.levels[level_index];
                const current_gradient: i32 = @intCast(switch (role) {
                    .world => level.color_wheel_index,
                    .enemy => level.enemy_gradient_index orelse
                        loaders.autoDerivedGradientIndex(history.color_theme_definitions, level.color_wheel_index, .enemy),
                    .player => level.player_gradient_index orelse
                        loaders.autoDerivedGradientIndex(history.color_theme_definitions, level.color_wheel_index, .player),
                });
                const visible_rows: i32 = @intCast(ui.editorThemePickerVisibleRowLimit());
                history.session.ui_state.editor_theme_picker_scroll_offset =
                    @max(current_gradient + 1 - visible_rows, 0);
            },
            // A theme-picker row: set the level's index for the picker's
            // role and close. Same-value picks close WITHOUT COMMITTING
            // (the close itself is the recorded change - the picker surface
            // event); a changed pick commits, and the commit orchestrator's
            // handler pushes the close as a child (pick+close is one undo
            // step). A pick while an enemy/player role is on AUTO flips it
            // to manual in the same commit (the explicit pick IS the manual
            // choice - the state change null→index records even when the
            // derived gradient was visually the same).
            .select_editor_level_gradient => {
                const editor: *types.Editor = &(history.current_state.editor orelse return);
                const target = expectPickerKind(editor, .level_gradient) orelse return;
                const gradient_index = payloadAs(.editor_gradient, clicked_payload) orelse return;
                if (target.level_index >= editor.levels.len) return;
                const level = editor.levels[target.level_index];
                switch (target.role) {
                    .world => {
                        if (level.color_wheel_index == gradient_index) {
                            pushPlayerActionAndDrain(history, .player_close_editor_picker);
                            return;
                        }
                        pushPlayerActionAndDrain(history, .{ .player_set_editor_level_color_wheel = .{
                            .level_index = target.level_index,
                            .color_wheel_index = gradient_index,
                        } });
                    },
                    .enemy => {
                        if (level.enemy_gradient_index != null and
                            level.enemy_gradient_index.? == gradient_index)
                        {
                            pushPlayerActionAndDrain(history, .player_close_editor_picker);
                            return;
                        }
                        pushPlayerActionAndDrain(history, .{ .player_set_editor_level_enemy_gradient = .{
                            .level_index = target.level_index,
                            .gradient_index = gradient_index,
                        } });
                    },
                    .player => {
                        if (level.player_gradient_index != null and
                            level.player_gradient_index.? == gradient_index)
                        {
                            pushPlayerActionAndDrain(history, .player_close_editor_picker);
                            return;
                        }
                        pushPlayerActionAndDrain(history, .{ .player_set_editor_level_player_gradient = .{
                            .level_index = target.level_index,
                            .gradient_index = gradient_index,
                        } });
                    },
                }
            },
            // An enemy/player gradient row's Auto button - a TRUE toggle
            // both ways: while MANUAL it reverts to auto-derivation (the
            // null override); while AUTO it flips to manual by FREEZING
            // the currently-derived index as the explicit pick (the
            // visuals don't change - the outline moves from the Auto
            // button to the swatch; a later pick replaces the frozen
            // index). The world row has no Auto button (its index is
            // always picked).
            .toggle_editor_level_gradient_auto => {
                if (current.editor == null) return;
                const editor: *types.Editor = &current.editor.?;
                const role = payloadAs(.editor_gradient_role, clicked_payload) orelse return;
                if (editor.levels.len == 0) return;
                const level_index: u32 =
                    @intCast(@min(editor.active_level_index, editor.levels.len - 1));
                const level = editor.levels[level_index];
                switch (role) {
                    .world => return,
                    .enemy => {
                        const gradient_index: ?u32 = if (level.enemy_gradient_index != null)
                            null
                        else
                            loaders.autoDerivedGradientIndex(
                                history.color_theme_definitions,
                                level.color_wheel_index,
                                .enemy,
                            );
                        pushPlayerActionAndDrain(history, .{ .player_set_editor_level_enemy_gradient = .{
                            .level_index = level_index,
                            .gradient_index = gradient_index,
                        } });
                    },
                    .player => {
                        const gradient_index: ?u32 = if (level.player_gradient_index != null)
                            null
                        else
                            loaders.autoDerivedGradientIndex(
                                history.color_theme_definitions,
                                level.color_wheel_index,
                                .player,
                            );
                        pushPlayerActionAndDrain(history, .{ .player_set_editor_level_player_gradient = .{
                            .level_index = level_index,
                            .gradient_index = gradient_index,
                        } });
                    },
                }
            },
            // A sprite picker cell: set the edited type's base sprite (the
            // stem rides the payload) and close the
            // picker. Same-value picks close WITHOUT COMMITTING (the close
            // itself is the recorded change); a changed pick commits, and
            // the commit orchestrator's handler pushes the close as a
            // child (pick+close is one undo step).
            .select_editor_entity_sprite => {
                const editor: *types.Editor = &(history.current_state.editor orelse return);
                expectPickerKind(editor, .entity_sprite) orelse return;
                const sprite = payloadAs(.editor_sprite, clicked_payload) orelse return;
                const target = editorEntityEditTarget(editor.*) orelse return;
                const template = editor_handlers.editorEntityTemplate(editor, target) orelse return;
                // Pick-commit backstop (the picker filter's defense-in-depth
                // - a stale scan or crafted input): a custom sprite that
                // doesn't resolve to exactly the fixed 512x640 frame no-ops
                // the COMMIT - only the close records. The load + render
                // sides degrade the same art anyway; committing it would
                // only mint a guaranteed-magenta type.
                if (std.mem.startsWith(u8, sprite, "custom/") and
                    !loaders.customEntitySpriteConforms(
                        history.file_source,
                        editor.mission.path,
                        sprite,
                        history.current_arena.allocator(),
                    ))
                {
                    pushPlayerActionAndDrain(history, .player_close_editor_picker);
                    return;
                }
                if (std.mem.eql(u8, template.sprite, sprite)) {
                    pushPlayerActionAndDrain(history, .player_close_editor_picker);
                    return;
                }
                // Pick-time default follows the art source: official stems
                // tint (false), mission-local custom art keeps its own
                // colors (true) - see DESIGN → Entity & UI Coloring,
                // keep_original_colors. The same-sprite gate above keeps a
                // manual override intact on a re-pick.
                const keep_original_colors = std.mem.startsWith(u8, sprite, "custom/");
                // Dupe into the current arena BEFORE pushing - the payload
                // slice must not point into the view's frame allocation
                // (the text-commit path's ordering rule).
                const value = history.current_arena.allocator().dupe(u8, sprite) catch
                    @panic("failed to allocate sprite commit value");
                pushPlayerActionAndDrain(history, .{ .player_set_editor_entity_sprite = .{
                    .target = target,
                    .value = value,
                    .keep_original_colors = keep_original_colors,
                } });
            },
            // A DECORATION picker cell: adopt the picked sprite into the
            // edited decoration type and close the picker. An Official-tab
            // pick (a registry stem) adopts the WHOLE prefab - footprint,
            // pixel dims, color, layers ("loading a prefab"); a Mission-tab
            // pick stores the namespaced stem with pixel dims read from the
            // PNG and a default single-tile footprint at the sprite grid's
            // BOTTOM-LEFT corner (the authored footprint editor is a later
            // slice; dims verification for custom art is a TODO). The def
            // commit prunes the type's now-invalid placements (see the
            // handler). Same-definition picks close WITHOUT COMMITTING (the
            // close itself is the recorded change) - a
            // re-pick of the current prefab AFTER a color tweak does record
            // (it re-adopts the authored color). A pick that fails its dims
            // resolution keeps the picker OPEN, nothing recorded - the
            // pick visibly didn't take (the decoration-LAYER arm's semantic).
            .select_editor_decoration_sprite => {
                const editor: *types.Editor = &(history.current_state.editor orelse return);
                expectPickerKind(editor, .decoration_sprite) orelse return;
                const sprite = payloadAs(.editor_sprite, clicked_payload) orelse return;
                const type_id = switch (ui.editorInspectorTarget(editor.*)) {
                    .decoration_type => |resolved_type_id| resolved_type_id,
                    .entity_type, .item_type, .player => return,
                };
                const current_definition = editor.decoration_types[type_id];
                const arena = history.current_arena.allocator();

                // Resolve the new definition from the pick: a registry
                // stem adopts its prefab, anything else is a mission-local
                // stem (`custom/<mission-dir>/<file-stem>` - the file stem
                // is the last path segment; file names carry no '/').
                var prefab: ?types.DecorationTypeDef = null;
                for (history.session.editor_decoration_registry) |definition| {
                    if (std.mem.eql(u8, definition.sprite, sprite)) {
                        prefab = definition;
                        break;
                    }
                }
                const new_definition: types.DecorationTypeDef = if (prefab) |definition| .{
                    .id = definition.sprite,
                    .sprite = definition.sprite,
                    .footprint = definition.footprint,
                    .pixel_dims = definition.pixel_dims,
                    .color_index = definition.color_index,
                    // Prefabs are shipped (grayscale) art - an official
                    // pick adopts the prefab's flag (false).
                    .keep_original_colors = definition.keep_original_colors,
                    .layers = definition.layers,
                } else blk: {
                    const slash = std.mem.lastIndexOfScalar(u8, sprite, '/') orelse return;
                    const file_stem = sprite[slash + 1 ..];
                    const pixel_dims = loaders.resolveMissionSpriteDimensions(
                        history.file_source,
                        editor.mission.path,
                        file_stem,
                        arena,
                    ) orelse return;
                    // Pick-commit backstop (the picker filter's
                    // defense-in-depth): whole 256px tiles only - also
                    // covers the old positive-dims check (conforming dims
                    // are strictly positive).
                    if (!types.decorationSpriteDimsConform(pixel_dims)) return;
                    // The sprite grid's tile rows (256px per tile); the
                    // default footprint reserves the bottom-left tile.
                    // Duped HERE (an arena slice) - a runtime-sized array
                    // literal can't safely escape this block as a pointer.
                    const sprite_grid_rows = @divTrunc(pixel_dims.y + 255, 256);
                    const default_footprint = [_]types.Vector2{.{ .x = 0, .y = sprite_grid_rows - 1 }};
                    break :blk .{
                        .id = sprite,
                        .sprite = sprite,
                        .footprint = arena.dupe(types.Vector2, &default_footprint) catch
                            @panic("failed to allocate default decoration footprint"),
                        .pixel_dims = pixel_dims,
                        // A custom stem has no authored values - the type's
                        // current color + layers stay (the swatch adjusts
                        // color; layer editing is deferred). The custom
                        // art IS pre-colored - the pick-time default flips
                        // the untinted-render flag on (see DESIGN → Entity
                        // & UI Coloring, keep_original_colors).
                        .color_index = current_definition.color_index,
                        .keep_original_colors = true,
                        .layers = current_definition.layers,
                    };
                };

                // Same-definition picks never fire (the FULL definition -
                // sprite, footprint, dims, color, layers, the untinted flag).
                const unchanged = std.mem.eql(u8, current_definition.sprite, new_definition.sprite) and
                    loaders.decorationFootprintEqual(current_definition.footprint, new_definition.footprint) and
                    current_definition.pixel_dims.x == new_definition.pixel_dims.x and
                    current_definition.pixel_dims.y == new_definition.pixel_dims.y and
                    current_definition.color_index == new_definition.color_index and
                    current_definition.keep_original_colors == new_definition.keep_original_colors and
                    loaders.decorationLayersEqual(current_definition.layers, new_definition.layers);
                if (unchanged) {
                    pushPlayerActionAndDrain(history, .player_close_editor_picker);
                    return;
                }

                // Dupe into the current arena BEFORE pushing (the
                // entity-sprite commit's ordering rule). The registry /
                // current-state strings the struct slices point at outlive
                // the push, and recordEvent + arena compaction deep-copy
                // everything downstream.
                const sprite_value = arena.dupe(u8, new_definition.sprite) catch
                    @panic("failed to allocate decoration sprite commit value");
                const footprint_value = arena.dupe(types.Vector2, new_definition.footprint) catch
                    @panic("failed to allocate decoration footprint commit value");
                const layers_value = arena.dupe(types.DecorationLayer, new_definition.layers) catch
                    @panic("failed to allocate decoration layers commit value");
                pushPlayerActionAndDrain(history, .{ .player_set_editor_decoration_def = .{
                    .type_id = type_id,
                    .sprite = sprite_value,
                    .footprint = footprint_value,
                    .pixel_dims = new_definition.pixel_dims,
                    .color_index = new_definition.color_index,
                    .keep_original_colors = new_definition.keep_original_colors,
                    .layers = layers_value,
                } });
            },
            // An ENTITY layer picker cell: add a new layer (add mode) or
            // re-pick the edited layer's sprite (edit mode - the layer's
            // color is kept, the weapon-retype semantics). A new layer
            // starts at color 0 (no authored source for entity layers).
            // Same-layer picks close WITHOUT COMMITTING (the close itself
            // is the recorded change). Entities share the
            // fixed 512×640 frame - no dims to check.
            .select_editor_entity_layer => {
                const editor: *types.Editor = &(history.current_state.editor orelse return);
                const layer_index = expectPickerKind(editor, .entity_layer) orelse return;
                const sprite = payloadAs(.editor_sprite, clicked_payload) orelse return;
                const target = editorEntityEditTarget(editor.*) orelse return;
                const template = editor_handlers.editorEntityTemplate(editor, target) orelse return;
                const arena = history.current_arena.allocator();
                // Pick-commit backstop (same rule as the base-sprite arm):
                // a custom layer sprite that isn't the fixed 512x640 frame
                // no-ops - nothing recorded.
                if (std.mem.startsWith(u8, sprite, "custom/") and
                    !loaders.customEntitySpriteConforms(
                        history.file_source,
                        editor.mission.path,
                        sprite,
                        arena,
                    ))
                {
                    pushPlayerActionAndDrain(history, .player_close_editor_picker);
                    return;
                }
                const sprite_value = arena.dupe(u8, sprite) catch
                    @panic("failed to allocate layer sprite commit value");
                if (layer_index) |index| {
                    if (index >= template.layers.len) return;
                    const current_layer = template.layers[index];
                    if (std.mem.eql(u8, current_layer.sprite, sprite)) {
                        pushPlayerActionAndDrain(history, .player_close_editor_picker);
                        return;
                    }
                    pushPlayerActionAndDrain(history, .{ .player_set_editor_entity_layer = .{
                        .target = target,
                        .layer_index = index,
                        .sprite = sprite_value,
                        .color_index = current_layer.color_index,
                    } });
                } else {
                    pushPlayerActionAndDrain(history, .{ .player_add_editor_entity_layer = .{
                        .target = target,
                        .sprite = sprite_value,
                        .color_index = 0,
                    } });
                }
            },
            // A DECORATION layer picker cell - the entity arm's shape plus
            // the dims invariant: the layer's pixel dims must equal the
            // base type's (a mismatch warns + degrades at load - see
            // DESIGN → Custom Missions & Online Services → Custom-asset
            // dimensions). A custom stem's dims come from its PNG; an
            // official stem's from the comptime metadata table. A MISMATCH
            // (or a vanished/corrupt file) keeps the picker OPEN and
            // records nothing - the pick visibly didn't take (the official
            // tab already filters to matching dims, so this only guards
            // mission-local picks). A new layer's color adopts a registry
            // prefab's authored layer color when the stem is one (tree_1's
            // canopy is 2), else 0; a re-pick keeps the layer's color. Same
            // for `behind`: a new layer adopts the authored stem's draw
            // side (tree_1's grass_back is true), else false; a re-pick
            // keeps the layer's.
            .select_editor_decoration_layer => {
                const editor: *types.Editor = &(history.current_state.editor orelse return);
                const layer_index = expectPickerKind(editor, .decoration_layer) orelse return;
                const sprite = payloadAs(.editor_sprite, clicked_payload) orelse return;
                const type_id = switch (ui.editorInspectorTarget(editor.*)) {
                    .decoration_type => |resolved_type_id| resolved_type_id,
                    .entity_type, .item_type, .player => return,
                };
                const current_definition = editor.decoration_types[type_id];
                const arena = history.current_arena.allocator();

                // Resolve the picked sprite's dims.
                const pixel_dims = blk: {
                    if (std.mem.startsWith(u8, sprite, "custom/")) {
                        const slash = std.mem.lastIndexOfScalar(u8, sprite, '/') orelse return;
                        break :blk loaders.resolveMissionSpriteDimensions(
                            history.file_source,
                            editor.mission.path,
                            sprite[slash + 1 ..],
                            arena,
                        ) orelse return;
                    }
                    break :blk loaders.resolveShippedDecorationSpriteDimensions(sprite, arena) orelse return;
                };
                if (pixel_dims.x != current_definition.pixel_dims.x or
                    pixel_dims.y != current_definition.pixel_dims.y) return;

                const color_index: u32 = if (layer_index) |index| blk: {
                    if (index >= current_definition.layers.len) return;
                    break :blk current_definition.layers[index].color_index;
                } else blk: {
                    // A registry prefab's authored layer color, if the stem
                    // is one; else 0.
                    for (history.session.editor_decoration_registry) |definition| {
                        for (definition.layers) |layer| {
                            if (std.mem.eql(u8, layer.sprite, sprite)) break :blk layer.color_index;
                        }
                    }
                    break :blk 0;
                };
                const behind: bool = if (layer_index) |index| blk: {
                    if (index >= current_definition.layers.len) return;
                    break :blk current_definition.layers[index].behind;
                } else blk: {
                    // A registry prefab's authored layer draw side, if the
                    // stem is one; else false (an overlay).
                    for (history.session.editor_decoration_registry) |definition| {
                        for (definition.layers) |layer| {
                            if (std.mem.eql(u8, layer.sprite, sprite)) break :blk layer.behind;
                        }
                    }
                    break :blk false;
                };
                const sprite_value = arena.dupe(u8, sprite) catch
                    @panic("failed to allocate layer sprite commit value");
                const new_layer: types.DecorationLayer = .{
                    .sprite = sprite_value,
                    .color_index = color_index,
                    .behind = behind,
                    .pixel_dims = pixel_dims,
                };
                if (layer_index) |index| {
                    const current_layer = current_definition.layers[index];
                    if (std.mem.eql(u8, current_layer.sprite, sprite)) {
                        pushPlayerActionAndDrain(history, .player_close_editor_picker);
                        return;
                    }
                    pushPlayerActionAndDrain(history, .{ .player_set_editor_decoration_layer = .{
                        .type_id = type_id,
                        .layer_index = index,
                        .sprite = new_layer.sprite,
                        .color_index = new_layer.color_index,
                        .behind = new_layer.behind,
                        .pixel_dims = new_layer.pixel_dims,
                    } });
                } else {
                    pushPlayerActionAndDrain(history, .{ .player_add_editor_decoration_layer = .{
                        .type_id = type_id,
                        .sprite = new_layer.sprite,
                        .color_index = new_layer.color_index,
                        .behind = new_layer.behind,
                        .pixel_dims = new_layer.pixel_dims,
                    } });
                }
            },
            // A sprite picker tab button (Mission / Official): switch tabs -
            // a direct UiState write (view affordance).
            .select_editor_sprite_tab => {
                const tab = payloadAs(.editor_sprite_tab, clicked_payload) orelse return;
                history.session.ui_state.editor_picker_sprite_tab = tab;
            },
            // Editor tool cell click (make it the active tool). The
            // EditorToolId rides the payload. Push the
            // orchestrator and drain (same as level tabs): the tool pointer
            // lives on the Editor (GameState), so the switch - and the
            // selection clear it carries - rides the undo timeline
            // (`editor_set_tool`). Re-selecting the active tool changes
            // nothing (no event, no undo step).
            .select_editor_tool => {
                const tool = payloadAs(.editor_tool, clicked_payload) orelse return;
                if (current.editor == null) return;
                if (std.meta.eql(tool, current.editor.?.active_tool)) return;
                pushPlayerActionAndDrain(history, .{ .player_set_editor_tool = .{
                    .tool = tool,
                } });
            },
            // Level-tab click: push the orchestrator (the EditorEvent owns
            // the mutation; the switch rides the undo timeline) and drain.
            // Re-clicking the ACTIVE tab fires nothing - beyond the dead
            // undo step, the same-value event would also clear the
            // selection as a side effect (the select_editor_tool
            // same-value gate).
            .select_editor_level => {
                const level_index = payloadAs(.editor_level, clicked_payload) orelse return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                if (level_index == editor.active_level_index) return;
                pushPlayerActionAndDrain(history, .{ .player_set_editor_level = .{
                    .level_index = level_index,
                } });
            },
            // Inspector toggle button (editor top-left, below options): push
            // the orchestrator (the open flag lives on the Editor, GameState,
            // so the toggle rides the undo timeline) and drain. No payload -
            // the event is a bare flip.
            .toggle_editor_inspector => {
                if (current.editor == null) return;
                pushPlayerActionAndDrain(history, .player_toggle_editor_inspector);
            },
            // Settings-sidebar toggle button (editor top-right, at the
            // inspector toggle's height): same shape - push the orchestrator
            // and drain.
            .toggle_editor_metadata_sidebar => {
                if (current.editor == null) return;
                pushPlayerActionAndDrain(history, .player_toggle_editor_metadata_sidebar);
            },
            // Top-bar Test button: start the single-level playtest of the
            // active level.
            .test_editor_level => {
                if (current.editor == null) return;
                pushPlayerActionAndDrain(history, .player_start_playtest);
            },
            // Top-bar Validate button: start the full-mission validation
            // run of the SAVED mission dir (file-based - the run certifies
            // the artifact a player receives, not the editor memory; see
            // DESIGN → Level Editor → Playtest/validate framing). SAVE
            // FIRST: the run needs a dir to read, and the eventual
            // validation_replay.txt needs a dir to live in. A failed save
            // surfaces its own popup - abort without starting the run.
            // The payload borrows the memo's durable dir string: valid
            // through the drain (no other save can run mid-drain), and
            // deep-copied when the orchestrator is recorded.
            .validate_editor_mission => {
                if (current.editor == null) return;
                const saved_dir = mission_io.saveEditorMission(history) orelse return;
                pushPlayerActionAndDrain(history, .{ .player_start_validation = .{
                    .mission_path = saved_dir,
                } });
            },
            // Options-menu Revalidate Mission: re-certify the stored
            // validation replay against the current SAVED content. SAVE
            // FIRST - same contract as Validate (the check certifies the
            // files a player receives, and the hash binding must match
            // them). A failed save surfaces its own popup - abort without
            // revalidating.
            .revalidate_editor_mission => {
                if (current.editor == null) return;
                const saved_dir = mission_io.saveEditorMission(history) orelse return;
                pushPlayerActionAndDrain(history, .{ .player_revalidate_mission = .{
                    .mission_path = saved_dir,
                } });
            },
            // Player inspector Import button: copy the session's player
            // data (or the new-game default, with none) into the editor
            // player loadout.
            .import_editor_player => {
                if (current.editor == null) return;
                pushPlayerActionAndDrain(history, .player_import_editor_player);
            },
            // Player inspector Max player Import button: the shipped
            // data/max_player.txt loadout (the author-times tool for
            // official missions).
            .import_editor_max_player => {
                if (current.editor == null) return;
                pushPlayerActionAndDrain(history, .player_import_editor_max_player);
            },
            // Inspector color swatch: set the edited type's color_index. The
            // gradient index rides the payload; the
            // target is the inspector's resolved target (the swatches only
            // render for the enemy content). Same-value picks never fire.
            .select_editor_entity_color => {
                const color_index = payloadAs(.editor_color, clicked_payload) orelse return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const target = editorEntityEditTarget(editor.*) orelse return;
                const template = editor_handlers.editorEntityTemplate(editor, target) orelse return;
                if (template.color_index == color_index) return;
                pushPlayerActionAndDrain(history, .{ .player_set_editor_entity_color_index = .{
                    .target = target,
                    .value = color_index,
                } });
            },
            // The DECORATION inspector's color swatch: set the edited
            // decoration type's color_index (the WORLD gradient index).
            // Same-value picks never fire.
            .select_editor_decoration_color => {
                const color_index = payloadAs(.editor_color, clicked_payload) orelse return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const type_id = switch (ui.editorInspectorTarget(editor.*)) {
                    .decoration_type => |resolved_type_id| resolved_type_id,
                    .entity_type, .item_type, .player => return,
                };
                if (editor.decoration_types[type_id].color_index == color_index) return;
                pushPlayerActionAndDrain(history, .{ .player_set_editor_decoration_color_index = .{
                    .type_id = type_id,
                    .value = color_index,
                } });
            },
            // A layer's Delete button (enemy + decoration): remove the
            // layer. The index rides the payload.
            .delete_editor_entity_layer => {
                const layer_index = payloadAs(.editor_layer, clicked_payload) orelse return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const target = editorEntityEditTarget(editor.*) orelse return;
                const template = editor_handlers.editorEntityTemplate(editor, target) orelse return;
                if (layer_index >= template.layers.len) return;
                pushPlayerActionAndDrain(history, .{ .player_remove_editor_entity_layer = .{
                    .target = target,
                    .layer_index = layer_index,
                } });
            },
            .delete_editor_decoration_layer => {
                const layer_index = payloadAs(.editor_layer, clicked_payload) orelse return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const type_id = switch (ui.editorInspectorTarget(editor.*)) {
                    .decoration_type => |resolved_type_id| resolved_type_id,
                    .entity_type, .item_type, .player => return,
                };
                if (layer_index >= editor.decoration_types[type_id].layers.len) return;
                pushPlayerActionAndDrain(history, .{ .player_remove_editor_decoration_layer = .{
                    .type_id = type_id,
                    .layer_index = layer_index,
                } });
            },
            // A layer's color swatch (enemy + decoration): swap the layer's
            // color_index, committing the WHOLE layer value through the set
            // event (sprite + dims kept). Same-color picks never fire.
            .select_editor_entity_layer_color => {
                const swatch = payloadAs(.editor_layer_color, clicked_payload) orelse return;
                const layer_index = swatch.layer_index;
                const color_index = swatch.color_index;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const target = editorEntityEditTarget(editor.*) orelse return;
                const template = editor_handlers.editorEntityTemplate(editor, target) orelse return;
                if (layer_index >= template.layers.len) return;
                const current_layer = template.layers[layer_index];
                if (current_layer.color_index == color_index) return;
                const sprite_value = history.current_arena.allocator().dupe(u8, current_layer.sprite) catch
                    @panic("failed to allocate layer sprite commit value");
                pushPlayerActionAndDrain(history, .{ .player_set_editor_entity_layer = .{
                    .target = target,
                    .layer_index = layer_index,
                    .sprite = sprite_value,
                    .color_index = color_index,
                } });
            },
            .select_editor_decoration_layer_color => {
                const swatch = payloadAs(.editor_layer_color, clicked_payload) orelse return;
                const layer_index = swatch.layer_index;
                const color_index = swatch.color_index;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const type_id = switch (ui.editorInspectorTarget(editor.*)) {
                    .decoration_type => |resolved_type_id| resolved_type_id,
                    .entity_type, .item_type, .player => return,
                };
                const definition = editor.decoration_types[type_id];
                if (layer_index >= definition.layers.len) return;
                const current_layer = definition.layers[layer_index];
                if (current_layer.color_index == color_index) return;
                pushPlayerActionAndDrain(history, .{ .player_set_editor_decoration_layer = .{
                    .type_id = type_id,
                    .layer_index = layer_index,
                    .sprite = current_layer.sprite,
                    .color_index = color_index,
                    .behind = current_layer.behind,
                    .pixel_dims = current_layer.pixel_dims,
                } });
            },
            // A decoration layer's draw-side toggle (the Back/Front button
            // on the layer's slot row): flip the layer's `behind` flag,
            // committing the WHOLE layer value through the set event
            // (sprite + color + dims kept - the color swatch's commit
            // shape). Always changes (a flip), so no would-change gate.
            .toggle_editor_decoration_layer_behind => {
                const layer_index = payloadAs(.editor_layer, clicked_payload) orelse return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const type_id = switch (ui.editorInspectorTarget(editor.*)) {
                    .decoration_type => |resolved_type_id| resolved_type_id,
                    .entity_type, .item_type, .player => return,
                };
                if (layer_index >= editor.decoration_types[type_id].layers.len) return;
                const current_layer = editor.decoration_types[type_id].layers[layer_index];
                pushPlayerActionAndDrain(history, .{ .player_set_editor_decoration_layer = .{
                    .type_id = type_id,
                    .layer_index = layer_index,
                    .sprite = current_layer.sprite,
                    .color_index = current_layer.color_index,
                    .behind = !current_layer.behind,
                    .pixel_dims = current_layer.pixel_dims,
                } });
            },
            // Inspector displays-weapons toggle: flip the edited type's flag.
            // Always changes (a flip), so no would-change gate.
            .toggle_editor_entity_displays_weapons => {
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const target = editorEntityEditTarget(editor.*) orelse return;
                const template = editor_handlers.editorEntityTemplate(editor, target) orelse return;
                pushPlayerActionAndDrain(history, .{ .player_set_editor_entity_displays_weapons = .{
                    .target = target,
                    .value = !template.displays_weapons,
                } });
            },
            // Inspector keep-original-colors toggles (entity + decoration):
            // flip the edited type's flag - always changes (a flip), so no
            // would-change gate. Same shape as the displays-weapons toggle.
            .toggle_editor_entity_keep_original_colors => {
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const target = editorEntityEditTarget(editor.*) orelse return;
                const template = editor_handlers.editorEntityTemplate(editor, target) orelse return;
                pushPlayerActionAndDrain(history, .{ .player_set_editor_entity_keep_original_colors = .{
                    .target = target,
                    .value = !template.keep_original_colors,
                } });
            },
            .toggle_editor_decoration_keep_original_colors => {
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const type_id = switch (ui.editorInspectorTarget(editor.*)) {
                    .decoration_type => |resolved_type_id| resolved_type_id,
                    .entity_type, .item_type, .player => return,
                };
                if (type_id >= editor.decoration_types.len) return;
                pushPlayerActionAndDrain(history, .{ .player_set_editor_decoration_keep_original_colors = .{
                    .type_id = type_id,
                    .value = !editor.decoration_types[type_id].keep_original_colors,
                } });
            },
            // Weapon-type cell: CREATE a default weapon while the hand is
            // empty ("New <Type>", damage 0), or RETYPE in place keeping
            // name/damage. Same-type picks never fire.
            .select_editor_weapon_type => {
                const cell = payloadAs(.editor_weapon_type_cell, clicked_payload) orelse return;
                const hand = cell.gear_slot;
                const weapon_type = cell.weapon_type;
                if (hand != .main_hand and hand != .off_hand) return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const target = editorEntityEditTarget(editor.*) orelse return;
                const template = editor_handlers.editorEntityTemplate(editor, target) orelse return;
                const equipped: ?types.Weapon = switch (hand) {
                    .main_hand => template.main_hand_weapon,
                    .off_hand => template.off_hand_weapon,
                    else => unreachable,
                };
                if (equipped) |weapon| {
                    if (weapon.weapon_type == weapon_type) return;
                    // Retype in place - identity (name/damage) stay stable.
                    var retyped = weapon;
                    retyped.weapon_type = weapon_type;
                    const retype_action = editorGearSlotAction(target, hand, .{ .weapon = retyped }) orelse return;
                    pushPlayerActionAndDrain(history, retype_action);
                } else {
                    const name = std.fmt.allocPrint(
                        history.current_arena.allocator(),
                        "New {s}",
                        .{types.weaponTypeLabel(weapon_type)},
                    ) catch @panic("failed to allocate default weapon name");
                    const weapon: types.Weapon = .{
                        .name = name,
                        .weapon_type = weapon_type,
                        .weapon_damage = 0,
                    };
                    const create_action = editorGearSlotAction(target, hand, .{ .weapon = weapon }) orelse return;
                    pushPlayerActionAndDrain(history, create_action);
                }
            },
            // Item-TYPE pick cell (the Items group's inspector content):
            // RESET-EVERYTHING semantics (author decision) - any pick that
            // differs from the current item replaces it with a
            // "New <Kind>" default (weapon: "New <WeaponType>"), zeroed
            // stats. No retype-keeps-identity case (unlike the entity
            // weapon slots); an identical pick never fires. A weapon cell
            // without its weapon-type payload, or a tome-kind target
            // item, commits nothing (defensive - the cells always carry
            // both, tomes are never offered).
            .select_editor_item_type => {
                const cell = payloadAs(.editor_item_kind_cell, clicked_payload) orelse return;
                const kind = cell.kind;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const type_id = editorItemEditTarget(editor.*) orelse return;
                const current_item = editor.item_types[type_id].item;
                const same_pick = switch (current_item) {
                    .weapon => |weapon| kind == .weapon and
                        weapon.weapon_type == (cell.weapon_type orelse return),
                    else => types.itemKindOf(current_item) == kind,
                };
                if (same_pick) return;
                const arena = history.current_arena.allocator();
                const item: types.Item = switch (kind) {
                    .weapon => .{ .weapon = .{
                        .name = std.fmt.allocPrint(
                            arena,
                            "New {s}",
                            .{types.weaponTypeLabel(cell.weapon_type orelse return)},
                        ) catch @panic("failed to allocate default item name"),
                        .weapon_type = cell.weapon_type orelse return,
                    } },
                    else => types.itemOfKind(kind, std.fmt.allocPrint(
                        arena,
                        "New {s}",
                        .{types.itemKindLabel(kind)},
                    ) catch @panic("failed to allocate default item name")),
                };
                const item_action = editorItemDefAction(type_id, item) orelse return;
                pushPlayerActionAndDrain(history, item_action);
            },
            // Gear Add: create a default item in the EMPTY slot (a
            // present item never re-adds - its fields edit in place).
            .add_editor_item => {
                const slot = payloadAs(.editor_gear_slot, clicked_payload) orelse return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const target = editorEntityEditTarget(editor.*) orelse return;
                const template = editor_handlers.editorEntityTemplate(editor, target) orelse return;
                if (template.gearSlotItem(slot) != null) return;
                const item = defaultItemForSlot(history, slot) orelse return;
                const add_action = editorGearSlotAction(target, slot, item) orelse return;
                pushPlayerActionAndDrain(history, add_action);
            },
            // Item Delete: clear the slot to null (an empty slot is a
            // no-op - the button isn't rendered then, but the gate holds
            // for crafted input).
            // An inspector utility-slot button: open the centered skill
            // picker for that slot - the open is the recorded surface
            // event (the picker state rides GameState; the PICK is a
            // separate action).
            .open_editor_skill_picker => {
                const slot_index = payloadAs(.editor_utility_slot, clicked_payload) orelse return;
                if (slot_index >= types.utility_skill_count) return;
                pushPlayerActionAndDrain(history, .{ .player_open_editor_picker = .{
                    .target = .{ .utility_skill_slot = slot_index },
                } });
            },
            // A picker cell: assign to the picker's slot (the skill rode in
            // skill; a null editor_skill payload = the None cell) and close.
            // The picker is a DROPDOWN, not a modal - everything else stays
            // live while it's open (see DESIGN → Level Editor → Editor UI
            // layout); this arm just no-ops when no picker is open.
            // Same-value picks (incl. None-on-empty) close WITHOUT
            // COMMITTING (the close itself is the recorded change).
            .select_editor_utility_skill => {
                const editor: *types.Editor = &(history.current_state.editor orelse return);
                const slot_index = expectPickerKind(editor, .utility_skill_slot) orelse return;
                const entity_target = editorEntityEditTarget(editor.*) orelse return;
                if (slot_index >= types.utility_skill_count) return;
                const template = editor_handlers.editorEntityTemplate(editor, entity_target) orelse return;
                const picked = payloadAs(.editor_skill, clicked_payload);
                if (template.equipped_utility_skills[slot_index] == picked) {
                    pushPlayerActionAndDrain(history, .player_close_editor_picker);
                    return;
                }
                pushPlayerActionAndDrain(history, .{ .player_set_editor_entity_utility_skill = .{
                    .target = entity_target,
                    .slot_index = slot_index,
                    .value = picked,
                } });
            },
            // The picker's close button.
            .close_editor_picker => pushPlayerActionAndDrain(history, .player_close_editor_picker),
            .delete_editor_item => {
                const slot = payloadAs(.editor_gear_slot, clicked_payload) orelse return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const target = editorEntityEditTarget(editor.*) orelse return;
                const template = editor_handlers.editorEntityTemplate(editor, target) orelse return;
                if (template.gearSlotItem(slot) == null) return;
                const clear_action = editorGearSlotAction(target, slot, null) orelse return;
                pushPlayerActionAndDrain(history, clear_action);
            },
            // An inventory slot cell (the player inspector's Inventory
            // section): select it - a direct UiState write (selection is
            // navigation, not authored content - the section-expansion
            // discipline); clicking the already-selected slot deselects
            // (the detail block collapses). A crafted out-of-range index
            // never selects.
            .select_editor_inventory_slot => {
                const slot = payloadAs(.editor_inventory_slot, clicked_payload) orelse return;
                if (slot >= types.inventory_slot_count) return;
                if (history.session.ui_state.editor_inventory_selected_slot == slot) {
                    history.session.ui_state.editor_inventory_selected_slot = null;
                } else {
                    history.session.ui_state.editor_inventory_selected_slot = slot;
                }
            },
            // Inventory-slot Add: create the default sword in the EMPTY
            // slot (the button only renders while empty; the gate holds
            // for crafted input).
            .add_editor_inventory_item => {
                const slot = payloadAs(.editor_inventory_slot, clicked_payload) orelse return;
                if (slot >= types.inventory_slot_count) return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                if (editor.player_def.template.inventory.slots[slot] != null) return;
                pushPlayerActionAndDrain(history, .{ .player_add_editor_inventory_item = .{
                    .index = slot,
                } });
            },
            // Inventory-slot Delete: clear the slot to null (an empty
            // slot is a no-op - the button isn't rendered then, but the
            // gate holds for crafted input).
            .delete_editor_inventory_item => {
                const slot = payloadAs(.editor_inventory_slot, clicked_payload) orelse return;
                if (slot >= types.inventory_slot_count) return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                if (editor.player_def.template.inventory.slots[slot] == null) return;
                pushPlayerActionAndDrain(history, .{ .player_delete_editor_inventory_item = .{
                    .index = slot,
                } });
            },
            // An inventory-slot item-TYPE pick cell (the detail block's
            // type rows): same reset-everything semantics as
            // `.select_editor_item_type`, targeting the SELECTED slot's
            // item. The rows only render while the slot is occupied - an
            // empty selection commits nothing (author decision: an empty
            // slot shows Add until an item exists).
            .select_editor_inventory_item_type => {
                const cell = payloadAs(.editor_item_kind_cell, clicked_payload) orelse return;
                const kind = cell.kind;
                const slot = history.session.ui_state.editor_inventory_selected_slot orelse return;
                if (slot >= types.inventory_slot_count) return;
                const editor = if (current.editor) |*some_editor| some_editor else return;
                const current_item = editor.player_def.template.inventory.slots[slot] orelse return;
                const same_pick = switch (current_item) {
                    .weapon => |weapon| kind == .weapon and
                        weapon.weapon_type == (cell.weapon_type orelse return),
                    else => types.itemKindOf(current_item) == kind,
                };
                if (same_pick) return;
                const arena = history.current_arena.allocator();
                const item: types.Item = switch (kind) {
                    .weapon => .{ .weapon = .{
                        .name = std.fmt.allocPrint(
                            arena,
                            "New {s}",
                            .{types.weaponTypeLabel(cell.weapon_type orelse return)},
                        ) catch @panic("failed to allocate default item name"),
                        .weapon_type = cell.weapon_type orelse return,
                    } },
                    else => types.itemOfKind(kind, std.fmt.allocPrint(
                        arena,
                        "New {s}",
                        .{types.itemKindLabel(kind)},
                    ) catch @panic("failed to allocate default item name")),
                };
                const item_action = editorInventoryItemDefAction(slot, item) orelse return;
                pushPlayerActionAndDrain(history, item_action);
            },
            // Editor-browser kind tab switch (Mission today; Hub /
            // Campaign when those editors land): switches the browser
            // content to that kind. A view affordance - direct UiState
            // write, off the undo timeline; the scroll resets like a
            // list-tab switch (the other kind's list has its own extent).
            .select_editor_kind_tab => {
                if (!history.current_state.ui_surfaces.editor_browser_open) return;
                const kind = payloadAs(.editor_kind, clicked_payload) orelse return;
                history.session.ui_state.editor_browser_kind = kind;
                history.session.ui_state.editor_mission_scroll_offset = 0;
            },
            // Mission-list tab switch (Your Missions / Official - the
            // active kind's content tab). A view affordance - direct UiState
            // write, off the undo timeline (the sprite-picker tab's
            // convention).
            .select_editor_mission_tab => {
                if (!history.current_state.ui_surfaces.editor_browser_open) return;
                const tab = payloadAs(.editor_mission_tab, clicked_payload) orelse return;
                history.session.ui_state.editor_mission_browser_tab = tab;
                // A tab switch resets the scroll - the other tab's list has
                // its own extent, and a stale offset can clamp past its end.
                history.session.ui_state.editor_mission_scroll_offset = 0;
            },
            // A mission row was clicked: open that mission in the editor
            // (replacing the one being edited - no unsaved-changes confirm,
            // by design). The recorded event is the ordinary `open_editor`
            // with the row's path (already a whitelisted player action); the
            // acquisition (the scan that produced the row) happened in idle
            // input, so replay re-reads the files silently - the
            // player_load_save shape. On failure the recoverable popup
            // surfaces and the browser stays open (the revert restores
            // world_generation, so the transition UI reset never fires).
            .open_editor_mission_row => {
                if (!history.current_state.ui_surfaces.editor_browser_open) return;
                const row = payloadAs(.editor_mission_row, clicked_payload) orelse return;
                const missions = switch (history.session.ui_state.editor_mission_browser_tab) {
                    .local => history.session.editor_local_missions,
                    .official => history.session.editor_official_missions,
                };
                if (row >= missions.len) return; // stale-list belt (list can't shift mid-open, but cheap)
                // Dupe the path into the current arena: the session list's
                // strings are backing-owned and a later scan frees them -
                // the recorded event must not borrow across frames
                // (recordEvent deep-copies at drain time, next frame).
                const mission_path = allocator.dupe(u8, missions[row].path) catch
                    @panic("failed to allocate mission path");
                pushPlayerActionAndDrain(history, .{ .open_editor = .{
                    .mission_path = mission_path,
                } });
            },
            else => {},
        }
    }

    // Editor browser: a modal on top of everything but the error
    // popup (which gated above) and above the options menu it opened from.
    // Its own interactions were folded into the anytime / options_action
    // fields above (toggle, tabs, rows - the options-menu-before-the-gate
    // dispatch); while it's open, everything else is blocked. The wheel
    // scrolls the row list - whole-row ticks (the load-save browser's
    // model), lower clamp here, upper clamp authoritative in the builder.
    // No periodic rescan while open (see SessionState.editor_local_missions).
    // The zip-import marker is polled here: a completed web upload extracts
    // into missions/ + rescans, so the new row appears immediately.
    if (history.current_state.ui_surfaces.editor_browser_open) {
        // The Import trigger (web-only effect at the seam; native no-ops -
        // the button is never emitted there and the binding parses +
        // no-ops, the skip_level discipline).
        if (anytime.import_editor_mission) {
            file_source_mod.triggerBrowserMissionUpload();
        }
        mission_io.pollMissionImportMarker(history);
        if (anytime.scroll_delta != 0) {
            const delta_rows: i32 = @intFromFloat(anytime.scroll_delta);
            history.session.ui_state.editor_mission_scroll_offset -= delta_rows;
            if (history.session.ui_state.editor_mission_scroll_offset < 0) {
                history.session.ui_state.editor_mission_scroll_offset = 0;
            }
        }
        return;
    }

    // Keybinds tab list scroll, BEFORE the options-menu gate: the settings
    // overlay opens ON TOP of the options menu in-game, so its wheel must
    // run before the gate's return (the slider-drag-before-the-gate
    // pattern in main's frame). One wheel notch = one row (whole visible
    // rows); lower clamp here, upper clamp authoritative in the builder.
    // The Settings tab has no scrollable content - the wheel no-ops there.
    if (history.current_state.ui_surfaces.settings_open and
        history.session.ui_state.settings_tab == .keybinds and
        anytime.scroll_delta != 0)
    {
        const delta_rows: i32 = @intFromFloat(anytime.scroll_delta);
        // While the action picker is open, the wheel scrolls the PICKER
        // (the picker owns the interaction - the binding list behind it
        // scrolls once it closes).
        if (history.session.ui_state.keybind_edit) |*edit_state| {
            if (edit_state.edit == .picker) {
                history.session.ui_state.keybind_picker_scroll_offset -= delta_rows;
                if (history.session.ui_state.keybind_picker_scroll_offset < 0) {
                    history.session.ui_state.keybind_picker_scroll_offset = 0;
                }
                return;
            }
        }
        history.session.ui_state.keybind_scroll_offset -= delta_rows;
        if (history.session.ui_state.keybind_scroll_offset < 0) {
            history.session.ui_state.keybind_scroll_offset = 0;
        }
    }

    // When options menu is open, block all other input
    if (history.current_state.ui_surfaces.options_menu_open) return;

    if (anytime.scroll_delta != 0) {
        // Editor palette group under the pointer, if any. Computed up front
        // (the screen + editor gating lives here, not in the chain below).
        // Geometric detection over the emitted tool cells - see
        // `ui.editorPaletteGroupAt`.
        const editor_palette_group: ?usize = if (history.current_state.screen == .editor)
            if (history.current_state.editor) |editor|
                ui.editorPaletteGroupAt(
                    editor,
                    history.session.ui_state.editor_palette_collapsed,
                    ui_elements,
                    pointer_position,
                )
            else
                null
        else
            null;
        // Load-save browser open: the wheel scrolls the save list, one full
        // row per notch (whole-row ticks keep text placement identical at
        // every offset). The panel is a fullscreen modal, so any wheel input
        // while it's open belongs to the list - never the camera (which has
        // no meaning on the main menu anyway). Upper clamp is authoritative
        // in the builder; the lower clamp here prevents negative drift.
        if (history.current_state.ui_surfaces.load_save_menu_open) {
            const delta_rows: i32 = @intFromFloat(anytime.scroll_delta);
            history.session.ui_state.load_save_scroll_offset -= delta_rows;
            if (history.session.ui_state.load_save_scroll_offset < 0) {
                history.session.ui_state.load_save_scroll_offset = 0;
            }
        } else if (history.current_state.screen == .editor and
            history.current_state.editor != null and
            history.current_state.editor.?.inspector_open and
            ui.editorInspectorPanelRect().contains(pointer_position))
        {
            // Editor inspector content scroll (vertical): one wheel notch =
            // one row. The wheel over the OPEN inspector panel belongs to
            // the panel - never the camera - whether or not a field target
            // exists (the empty state clamps to 0). Lower clamp here; the
            // builder clamps the upper bound in place (authoritative - it
            // knows the content height). See DESIGN → Architecture →
            // Level Editor → Editor UI layout (inspector).
            const delta_rows: i32 = @intFromFloat(anytime.scroll_delta);
            history.session.ui_state.editor_inspector_scroll -= delta_rows;
            if (history.session.ui_state.editor_inspector_scroll < 0) {
                history.session.ui_state.editor_inspector_scroll = 0;
            }
        } else if (history.current_state.screen == .editor and
            history.current_state.editor != null and
            history.current_state.editor.?.picker != null and
            history.current_state.editor.?.picker.? == .level_gradient)
        {
            // The theme picker owns the wheel while it's open (the keybind
            // action picker's rule - a modal picker's list scrolls, not the
            // world behind it): one notch = one gradient row, wheel-up =
            // earlier rows. Lower clamp here; the builder clamps the upper
            // bound (authoritative - it knows the visible row count).
            const delta_rows: i32 = @intFromFloat(anytime.scroll_delta);
            history.session.ui_state.editor_theme_picker_scroll_offset -= delta_rows;
            if (history.session.ui_state.editor_theme_picker_scroll_offset < 0) {
                history.session.ui_state.editor_theme_picker_scroll_offset = 0;
            }
        } else if (history.current_state.screen == .editor and
            history.current_state.editor != null and
            history.current_state.editor.?.metadata_sidebar_open and
            ui.editorMetadataSidebarPanelRect().contains(pointer_position))
        {
            // The metadata sidebar's content scroll - the inspector's exact
            // model: one wheel notch = one row, lower clamp here, the
            // builder clamps the upper bound (authoritative).
            const delta_rows: i32 = @intFromFloat(anytime.scroll_delta);
            history.session.ui_state.editor_metadata_scroll -= delta_rows;
            if (history.session.ui_state.editor_metadata_scroll < 0) {
                history.session.ui_state.editor_metadata_scroll = 0;
            }
        } else if (history.current_state.screen == .editor and
            history.current_state.editor != null and
            ui.editorLevelTabScrollRegion().contains(pointer_position))
        {
            // Level-tab window scroll (horizontal): one wheel notch = one
            // tab, wheel-up = earlier tabs (the palette window model).
            // Lower clamp here; `buildEditorLevelTabs` clamps the upper
            // bound in place (authoritative - it knows the tab widths).
            const delta_tabs: i32 = @intFromFloat(anytime.scroll_delta);
            history.session.ui_state.editor_level_tab_scroll -= delta_tabs;
            if (history.session.ui_state.editor_level_tab_scroll < 0) {
                history.session.ui_state.editor_level_tab_scroll = 0;
            }
        } else if (skillsSlotUnderPointer(ui_elements, pointer_position)) {
            const delta_rows: i32 = @intFromFloat(anytime.scroll_delta);
            history.session.ui_state.skills_scroll_offset -= delta_rows;
            if (history.session.ui_state.skills_scroll_offset < 0) {
                history.session.ui_state.skills_scroll_offset = 0;
            }
        } else if (editor_palette_group) |group_index| {
            // Editor palette window scroll (horizontal): one wheel notch =
            // one tool cell, wheel-up = earlier tools (matches the skills
            // panel's wheel-up = earlier rows). Both bounds clamped here;
            // the builder clamps in place too (authoritative).
            const editor = history.current_state.editor.?;
            const delta: i32 = @intFromFloat(anytime.scroll_delta);
            const group_size = ui.editorPaletteGroupSize(editor, group_index);
            const max_offset: i32 = @intCast(group_size -| ui.editor_palette_max_tools);
            const scrolled: i32 = @min(
                @max(history.session.ui_state.editor_palette_scroll[group_index] - delta, 0),
                max_offset,
            );
            history.session.ui_state.editor_palette_scroll[group_index] = scrolled;
        } else if (cameraZoomAllowed(history.current_state.screen)) {
            // Additive zoom in fixed steps, clamped to [min, max]. Additive
            // (not multiplicative) so one zoom-in followed by one zoom-out
            // always returns to the exact same value. scroll_delta is
            // accumulated wheel notches (positive = scroll up = zoom in); a
            // single notch is ±1 step (25 hundredths). Only 25/50/75/100 are
            // valid, so the step lands exactly on a choice value.
            const delta_steps: i32 = @intFromFloat(anytime.scroll_delta);
            const delta: i32 = delta_steps * @as(i32, @intCast(camera_zoom_step));
            const clamped: u32 = @intCast(@max(@as(i32, @intCast(min_camera_zoom)), @min(@as(i32, @intCast(max_camera_zoom)), @as(i32, @intCast(history.settings.camera_zoom)) + delta)));
            if (clamped != history.settings.camera_zoom) {
                history.settings.camera_zoom = clamped;
                state.markSettingsDirty(history);
            }
        }
    }

    // Keyboard zoom shortcuts (PgUp / PgDn / ctrl+0). Same additive
    // step + bounds as the wheel, same screen gate. Reset snaps to the
    // default.
    if (anytime.zoom_in and cameraZoomAllowed(history.current_state.screen)) {
        const new_zoom = @min(max_camera_zoom, history.settings.camera_zoom + camera_zoom_step);
        if (new_zoom != history.settings.camera_zoom) {
            history.settings.camera_zoom = new_zoom;
            state.markSettingsDirty(history);
        }
    }
    if (anytime.zoom_out and cameraZoomAllowed(history.current_state.screen)) {
        const new_zoom = @max(min_camera_zoom, history.settings.camera_zoom - camera_zoom_step);
        if (new_zoom != history.settings.camera_zoom) {
            history.settings.camera_zoom = new_zoom;
            state.markSettingsDirty(history);
        }
    }
    if (anytime.zoom_reset and cameraZoomAllowed(history.current_state.screen)) {
        if (history.settings.camera_zoom != default_camera_zoom) {
            history.settings.camera_zoom = default_camera_zoom;
            state.markSettingsDirty(history);
        }
    }

    // In-game inputs only apply when in a hub or level
    const current = &history.current_state;
    const allocator = history.current_arena.allocator();
    if (current.screen == .hub or current.screen == .level) {
        const in_game = anytime.in_game;

        // Middle-panel + overlay toggles: one `player_toggle_ui_surface`
        // per key (the surface state rides GameState - see DESIGN → UI
        // Framework → UI state classification). The push+drain is the
        // swap_weapons interjection shape: processed inside this update
        // call, so the frame's own gates below see the flipped state.
        if (in_game.toggle_inventory) {
            pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
                .surface = .inventory,
            } });
        }

        if (in_game.toggle_gear) {
            pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
                .surface = .gear,
            } });
        }

        if (in_game.toggle_skills) {
            pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
                .surface = .skills,
            } });
        }

        if (in_game.toggle_entity_inspect) {
            pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
                .surface = .entity_inspect,
            } });
        }

        // Entity inspect is also right-click driven (handleRightClickInspect,
        // run later in update); a keyboard binding for it is not wired.

        if (in_game.toggle_world_map) {
            pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
                .surface = .world_map,
            } });
        }

        // Cursor resolution (mouse vs arrows vs UI occlusion) happens in a
        // dedicated step in update(), after UI arbitration - it needs
        // ui_elements + world tiles, which live in main.zig's world.

        if (in_game.swap_weapons) {
            // No-op gate: with both hands empty and nothing prepared, the
            // swap is a recorded no-op (swap_hands also cancels a
            // preparation, which IS a change - see the handler).
            const player = ui.playerEntity(current) orelse types.Entity{};
            const skill_prepared = if (current.level) |level|
                level.prepared_skill != null
            else
                false;
            const any_weapon = player.main_hand_weapon != null or player.off_hand_weapon != null;
            if (any_weapon or skill_prepared) {
                if (!history.replaying) history.session.queueActionSound(history.backing_allocator, .swap_weapons);
                event_push.pushPlayerAction(current, .swap_hands, allocator);
            }
        }
    }
}

/// Handle inputs that are only accepted when the event stack is empty.
/// A resolved skill-bar slot press: use the skill now (auto-target hit or
/// no-targeting skill, with an optional target tile), begin targeting
/// (prepare), or toggle an already-prepared skill back off (unprepare -
/// re-preparing the same skill would be a recorded no-op undo step).
/// Produced by `resolveSkillSlotAction` and consumed by both the
/// player_move and player_attack turn phases.
const SkillSlotAction = union(enum) {
    use: struct { skill_id: SkillId, target: ?Vector2 },
    prepare: SkillId,
    unprepare: void,
};

/// Resolve a skill-bar slot press into a concrete action. Returns null when
/// the slot is empty, the skill is on cooldown, or the skill definition is
/// missing - the caller drops the input silently (matching the prior inline
/// behavior). Shared by the player_move (skip-to-skill) and player_attack
/// (in-phase) paths so both follow one resolution path. Targeting
/// resolution depends on the transient `tile_cursor` (SessionState, off
/// GameState), so it lives here in the input path, not in an event handler
/// (replay doesn't re-resolve input - the orchestrator carries the result).
fn resolveSkillSlotAction(
    history: *GameStateHistory,
    current: *GameState,
    level: *const Level,
    slot: u8,
    allocator: std.mem.Allocator,
) ?SkillSlotAction {
    const player = level.entities[0];
    const skill_id = player.skillInSlot(slot, history.weapon_type_definitions) orelse return null;
    if (player.skill_cooldowns.get(skill_id) > 0) return null;
    const skill_definition = lookups.getSkillDefinition(skill_id) orelse return null;
    if (!skill_definition.uses_targeting) {
        return .{ .use = .{ .skill_id = skill_id, .target = null } };
    }
    // Targeted skill: auto-target at the cursor if it sits on a valid target.
    if (history.settings.auto_target_at_cursor) {
        if (history.session.tile_cursor) |cursor_position| {
            const valid_targets = skill_definition.getValidTargets(0, current.*, allocator);
            if (valid_targets) |targets| {
                for (targets) |target| {
                    if (target.x == cursor_position.x and target.y == cursor_position.y) {
                        return .{ .use = .{ .skill_id = skill_id, .target = cursor_position } };
                    }
                }
            }
        }
    }
    // Same skill already prepared → toggle it off. Auto-target above wins
    // when the cursor sits on a valid target (the press fires there), so
    // this only claims the press that would otherwise re-prepare
    // identically - a recorded no-op undo step.
    if (level.prepared_skill == skill_id) return .unprepare;
    return .{ .prepare = skill_id };
}

/// Rescan saves/ into `session.save_files`, freeing the previous list.
/// Allocation goes through the backing allocator (session-lifetime, like
/// the sound/anim queues); the only leak is the final list at process exit.
fn rescanSaveFilesNow(history: *GameStateHistory) void {
    const files = history.file_source.listSaveFiles(history.backing_allocator) catch {
        // Unreadable dir mid-session (permissions, external deletion):
        // keep the previous list rather than blanking the browser.
        return;
    };
    file_source_mod.freeSaveFiles(history.backing_allocator, history.session.save_files);
    history.session.save_files = files;
    history.session.save_files_last_scan_us = history.session.animation_clock;
}

/// Rescan interval in animation-clock microseconds. One directory iterate +
/// stat-per-file + sort per interval - cheap, but not free, so not per-frame.
const save_file_rescan_interval_us: u64 = 500_000;

/// Throttled wrapper: rescans only when the interval elapsed since the last
/// scan (the on-open scan stamps the clock, so the first periodic rescan is
/// one full interval after open).
fn rescanSaveFilesIfDue(history: *GameStateHistory) void {
    if (history.session.save_files_last_scan_us == state.SessionState.save_files_never_scanned) {
        rescanSaveFilesNow(history);
        return;
    }
    if (history.session.animation_clock - history.session.save_files_last_scan_us >=
        save_file_rescan_interval_us)
    {
        rescanSaveFilesNow(history);
    }
}

/// Consume the web import marker, if present: the picked file has landed in
/// saves/ - delete the marker, rescan (so the file shows in the list), and
/// load it. A parse failure inside the load surfaces the recoverable popup
/// and leaves the browser open with the imported file visible for retry.
fn pollImportMarker(history: *GameStateHistory) void {
    if (!history.file_source.fileExists(file_source_mod.import_marker_path)) return;

    const allocator = history.backing_allocator;
    const marker_bytes = history.file_source.readFile(allocator, file_source_mod.import_marker_path) catch {
        // Unreadable marker: delete it so we don't spin on a corrupt file;
        // the imported save (if any) still shows up via the periodic rescan.
        history.file_source.deleteFile(file_source_mod.import_marker_path) catch {};
        return;
    };
    defer allocator.free(marker_bytes);
    history.file_source.deleteFile(file_source_mod.import_marker_path) catch {};

    // The marker body is the persistent-relative save path written by the
    // import JS. Trim any trailing newline for robustness.
    const save_path = std.mem.trim(u8, marker_bytes, "\r\n");
    if (save_path.len == 0) return;

    const path_copy = allocator.dupe(u8, save_path) catch
        @panic("failed to allocate imported save path");
    rescanSaveFilesNow(history);
    event_push.pushPlayerAction(&history.current_state, .{ .player_load_save = .{
        .save_path = path_copy,
    } }, history.current_arena.allocator());
}

pub fn handleIdleInput(
    history: *GameStateHistory,
    idle_input: input.IdleInput,
    /// The frame's clicked-button payload (see `types.ButtonPayload`),
    /// riding alongside the menu action that consumed the click - the
    /// `.load_save_row` arm reads `.save_row`.
    clicked_payload: ?types.ButtonPayload,
    modifiers: input.Modifiers,
) void {
    // Enter acts as a click on the active tile cursor: fold it into
    // tile_clicked so the existing click handlers (player_move, player_attack,
    // hub) do the work - one path, no duplication. Only when a real click
    // didn't already happen this frame (a click takes precedence).
    var idle = idle_input;
    if (idle.confirm and idle.tile_clicked == null) {
        if (history.session.tile_cursor) |cursor| {
            idle.tile_clicked = cursor;
        }
    }

    const current = &history.current_state;
    const allocator = history.current_arena.allocator();

    // Main menu: menu buttons emit a menu_action (no keybind path).
    if (current.screen == .main_menu) {
        if (idle.menu_action) |action| {
            // The action's layer queues once at the fired-actions choke
            // point (`dispatchFiredActionSounds` - the menu actions are
            // keybindable too since the dispatch convergence); the release
            // seam owns the base up.
            switch (action) {
                .new_game => event_push.pushPlayerAction(current, .start_new_game, allocator),
                // Continue: resume the last game. Two branches in the handler
                // (populated PlayerData → resume from memory; empty → load the
                // autosave first).
                .continue_game => event_push.pushPlayerAction(current, .player_continue, allocator),
                // Load-save browser: toggle the panel; on open, scan now +
                // reset the scroll (the list may be stale from a previous
                // open or never scanned this session).
                .toggle_load_save_menu => {
                    // On open, scan now + reset the scroll (the list may be
                    // stale from a previous open or never scanned this
                    // session) - decided from the pre-toggle state; the
                    // open/close itself is the recorded surface event.
                    if (!history.current_state.ui_surfaces.load_save_menu_open) {
                        history.session.ui_state.load_save_scroll_offset = 0;
                        rescanSaveFilesNow(history);
                    }
                    pushPlayerActionAndDrain(history, .{ .player_toggle_ui_surface = .{
                        .surface = .load_save_menu,
                    } });
                },
                // A save row was clicked. The row index rides the
                // `.save_row` payload (set by the button-release dispatch
                // in main.zig) and refers to the list the CLICKED BUTTON was
                // rendered from - which is why the rescan/poll below runs
                // AFTER this switch: it must not replace the list between
                // the dispatch (start of update) and this resolution.
                // Bounds-checked against the current list as a belt-and-
                // suspenders stale guard.
                .load_save_row => {
                    if (!history.current_state.ui_surfaces.load_save_menu_open) return;
                    const row = payloadAs(.save_row, clicked_payload) orelse return;
                    if (row >= history.session.save_files.len) return;
                    // Dupe the path into the current arena: the session
                    // list's strings are backing-owned and the housekeeping
                    // rescan below can free them THIS frame, while the
                    // pushed event isn't recorded (deep-copied) until the
                    // next frame's drain - a borrowed path could dangle.
                    const save_path = allocator.dupe(u8, history.session.save_files[row].path) catch
                        @panic("failed to allocate save path");
                    event_push.pushPlayerAction(current, .{ .player_load_save = .{
                        .save_path = save_path,
                    } }, allocator);
                },
                // Web import: open the browser file picker. The picked file
                // lands in saves/ and the import marker is written; the poll
                // above picks it up next frame. No-op on native (the button
                // is never emitted there - drop files into the persistent
                // saves/ dir by hand instead).
                .import_save => file_source_mod.triggerBrowserUpload(),
                // Import Game: open the browser file picker for a full
                // ziglop.zip. The picked file lands at the staging temp +
                // the game import marker is written; the EVERY-FRAME poll
                // in main.frame consumes it whenever it lands - the
                // overlay runs there, then the session re-boots at the
                // frame boundary. No-op on native (the button is never
                // emitted there - the real persistent dir IS the game
                // folder). A pure input-path side effect (no event,
                // nothing recorded: the import replaces the session, so
                // there is no timeline to record into).
                .import_game => file_source_mod.triggerBrowserGameUpload(),
                // The upstream-repo link (bottom-right, next to the version
                // stamp): web opens a new browser tab, native queues a
                // clipboard copy - browser_url owns the split. A pure
                // input-path side effect, the import_game class (no event,
                // nothing recorded).
                .open_repo_link => browser_url.handleRepoLinkClick(history),
                else => {},
            }
        }

        // Load-save browser housekeeping (every frame while open, AFTER the
        // action switch - see the load_save_row arm for why). Poll the
        // import marker (web - a picked file has landed in saves/) and
        // rescan the directory on a throttle so files dropped in from
        // outside appear live. Both are acquisition steps in idle input -
        // never in an event handler (see DESIGN → Custom Missions for the
        // replay-safety rationale).
        if (history.current_state.ui_surfaces.load_save_menu_open) {
            pollImportMarker(history);
            rescanSaveFilesIfDue(history);
        }
        return;
    }

    // Dev tool: skip the current level (ctrl+Enter). Gated to dev builds
    // (`-Ddev-mode`, defaulted to debug) - the binding ships in
    // default_settings.txt and no-ops in release/web builds. Pushes end_level
    // with the default continuation (next level or mission-end cascade -
    // the same path the options-menu exit uses). handleIdleInput only runs
    // with an empty stack + no active wait, so this never interleaves with a
    // draining enemy turn. See DESIGN → Input + AGENTS → Dev Tools.
    if (idle.skip_level and build_info.dev_mode and current.screen == .level) {
        event_push.pushPlayerAction(current, .player_skip_level, allocator);
        return;
    }

    // Editor edit mode: viewport clicks are fully modal on the active
    // tool. The press-side world/UI arbitration in update() already
    // consumed clicks over blocking UI (palette, tabs), so a surviving
    // tile_clicked is a viewport click. Enter folds into tile_clicked at
    // the top of handleIdleInput, so the keyboard path acts at the tile
    // cursor too. Landed tools: tile paint + enemy + decoration + ground
    // item placement + selection; all tools have viewport input now.
    // No-op gate: a click whose plan is empty never fires the player
    // action - it would land in the event log as an undo/replay step that
    // changes nothing (see the planEditor*Actions planners / DESIGN →
    // Level Editor → Active-tool model).
    if (current.screen == .editor) {
        // Delete key: delete the current selection (the select tool's bulk
        // delete - see planEditorSelectionDeleteActions). Same no-op gate:
        // an empty or all-marker selection never fires.
        if (idle.delete_editor_selection) {
            if (current.editor) |*editor| {
                const plan = planning.planEditorSelectionDeleteActions(editor, allocator);
                if (plan.len > 0) {
                    event_push.pushPlayerAction(current, .player_delete_editor_selection, allocator);
                }
            }
        }
        // ctrl+D: clear the whole selection. Gated on a nonempty selection
        // - an empty one never fires (no dead undo step).
        if (idle.clear_editor_selection) {
            if (current.editor) |*editor| {
                if (editor.selection.len > 0) {
                    event_push.pushPlayerAction(current, .player_clear_editor_selection, allocator);
                }
            }
        }
        // ctrl+A: select everything in the active level. Tool-agnostic -
        // the action switches to the select tool when it isn't active
        // (the selection can only live there; see the handler). Gated on a
        // nonempty plan (an all-selected level never fires - no dead undo
        // step).
        if (idle.select_editor_all) {
            if (current.editor) |*editor| {
                if (planning.planEditorSelectAllActions(editor, allocator).len > 0) {
                    event_push.pushPlayerAction(current, .player_select_editor_all, allocator);
                }
            }
        }
        if (idle.tile_clicked) |clicked_position| {
            if (current.editor) |*editor| {
                switch (editor.active_tool) {
                    .tile => {
                        // The paint-drag gesture owns the pointer press
                        // (press paints immediately, held paints each
                        // newly-visited tile - handleEditorTileDrag); the
                        // arm defers while a drag is active so a claimed
                        // press can't double-fire. The keyboard confirm-
                        // at-cursor path still lands here when no drag is
                        // in progress.
                        if (history.session.ui_state.editor_tile_drag) return;
                        const plan = planning.planEditorTilePaintActions(editor, clicked_position, allocator);
                        if (plan.len > 0) {
                            event_push.pushPlayerAction(current, .{ .player_paint_editor_tile = .{
                                .position = clicked_position,
                            } }, allocator);
                        }
                    },
                    .entity_type => |type_id| {
                        const plan = planning.planEditorEntityPlacementActions(editor, type_id, clicked_position, allocator);
                        if (plan.len > 0) {
                            event_push.pushPlayerAction(current, .{ .player_place_editor_entity = .{
                                .type_id = type_id,
                                .position = clicked_position,
                            } }, allocator);
                        }
                    },
                    .decoration_type => |type_id| {
                        const plan = planning.planEditorDecorationPlacementActions(editor, type_id, clicked_position, allocator);
                        if (plan.len > 0) {
                            event_push.pushPlayerAction(current, .{ .player_place_editor_decoration = .{
                                .type_id = type_id,
                                .position = clicked_position,
                            } }, allocator);
                        }
                    },
                    .item_type => |type_id| {
                        const plan = planning.planEditorItemPlacementActions(editor, type_id, clicked_position, allocator);
                        if (plan.len > 0) {
                            event_push.pushPlayerAction(current, .{ .player_place_editor_item = .{
                                .type_id = type_id,
                                .position = clicked_position,
                            } }, allocator);
                        }
                    },
                    .select => {
                        // While Shift is held the marquee gesture owns the
                        // press (`handleEditorMarquee` - shift+click is the
                        // TOGGLE path), and while a move drag is in
                        // progress it owns the press (`handleEditorMoveDrag`
                        // - an unpromoted release fires the replace from
                        // there). An unclaimed plain press REPLACES the
                        // selection with the clicked group (empty ground →
                        // the clear alone).
                        if (modifiers.shift) return;
                        if (history.session.ui_state.editor_move_drag != null) return;
                        const plan = planning.planEditorReplaceSelectionActions(editor, clicked_position, allocator);
                        if (plan.len > 0) {
                            event_push.pushPlayerAction(current, .{ .player_replace_editor_selection = .{
                                .position = clicked_position,
                            } }, allocator);
                        }
                    },
                }
            }
        }
        return;
    }

    // Level turn phase input handling
    if (current.level) |*level| {
        if (level.turn_phase) |turn_phase| {
            switch (turn_phase) {
                .player_move => {
                    // Pressing a skill slot during the move step skips the
                    // move and acts in the attack step instead - no need to
                    // manually skip the move when you don't intend to move.
                    if (idle.skill_slot_selected) |slot| {
                        if (resolveSkillSlotAction(history, current, level, slot, allocator)) |action| {
                            switch (action) {
                                .use => |use| event_push.pushPlayerAction(current, .{ .player_skip_move_to_skill = .{
                                    .skill_id = use.skill_id,
                                    .target = use.target,
                                    .prepare = false,
                                } }, allocator),
                                .prepare => |skill_id| {
                                    if (!history.replaying) history.session.queueCue(history.backing_allocator, .{
                                        .base = .button_base_up,
                                        .layer = .{ .action = ui.skillSlotAction(slot) },
                                    });
                                    event_push.pushPlayerAction(current, .{ .player_skip_move_to_skill = .{
                                        .skill_id = skill_id,
                                        .target = null,
                                        .prepare = true,
                                    } }, allocator);
                                },
                                .unprepare => {
                                    // Unreachable in the move phase (a skill
                                    // is only prepared during the attack
                                    // phase) - the arm keeps the shared union
                                    // switch total; the cancel is the sane
                                    // behavior if that invariant ever breaks.
                                    if (!history.replaying) history.session.queueCue(history.backing_allocator, .{
                                        .base = .button_base_up,
                                        .layer = .{ .action = ui.skillSlotAction(slot) },
                                    });
                                    event_push.pushPlayerAction(current, .player_cancel_skill, allocator);
                                },
                            }
                            return;
                        }
                    }

                    if (idle.tile_clicked) |clicked_position| {
                        // Check if the clicked tile is in the highlighted (reachable) set
                        var is_reachable = false;
                        for (level.highlighted_tiles) |tile| {
                            if (tile.x == clicked_position.x and tile.y == clicked_position.y) {
                                is_reachable = true;
                                break;
                            }
                        }
                        if (is_reachable) {
                            event_push.pushPlayerAction(current, .{ .player_move_action = .{
                                .destination = clicked_position,
                                .force_attack_step = modifiers.ctrl,
                            } }, allocator);
                        }
                    }

                    if (idle.skip) {
                        // Skip movement, go straight to attack phase
                        event_push.pushPlayerAction(current, .{ .player_skip_move = .{
                            .force_attack_step = modifiers.ctrl,
                        } }, allocator);
                    }
                },
                .player_attack => {
                    if (idle.skill_slot_selected) |slot| {
                        if (resolveSkillSlotAction(history, current, level, slot, allocator)) |action| {
                            switch (action) {
                                .use => |use| event_push.pushPlayerSkillUse(
                                    current,
                                    use.skill_id,
                                    use.target,
                                    allocator,
                                ),
                                .prepare => |skill_id| {
                                    if (!history.replaying) history.session.queueCue(history.backing_allocator, .{
                                        .base = .button_base_up,
                                        .layer = .{ .action = ui.skillSlotAction(slot) },
                                    });
                                    event_push.pushPlayerAction(current, .{ .player_prepare_skill = .{
                                        .caster_index = 0,
                                        .skill_id = skill_id,
                                    } }, allocator);
                                },
                                .unprepare => {
                                    // Toggle the prepared skill back off -
                                    // the same cancel path as the cancel
                                    // binding (clear highlights + clear the
                                    // preparation), so the press is a real
                                    // undo step instead of a recorded no-op.
                                    if (!history.replaying) history.session.queueCue(history.backing_allocator, .{
                                        .base = .button_base_up,
                                        .layer = .{ .action = ui.skillSlotAction(slot) },
                                    });
                                    event_push.pushPlayerAction(current, .player_cancel_skill, allocator);
                                },
                            }
                            return;
                        }
                    }

                    // Mouse path: a tile click on a highlighted (valid) tile
                    // fires the prepared skill at that tile. Mirrors how
                    // player_move consumes tile_clicked.
                    if (idle.tile_clicked) |clicked_position| {
                        if (level.prepared_skill) |skill_id| {
                            var is_valid = false;
                            for (level.highlighted_tiles) |tile| {
                                if (tile.x == clicked_position.x and tile.y == clicked_position.y) {
                                    is_valid = true;
                                    break;
                                }
                            }
                            if (is_valid) {
                                if (lookups.getSkillDefinition(skill_id) != null) {
                                    event_push.pushPlayerSkillUse(current, skill_id, clicked_position, allocator);
                                }
                            }
                        }
                    }

                    // Enter (confirm) is folded into tile_clicked at the top
                    // of handleIdleInput, so the mouse tile_clicked handler
                    // above already covers the keyboard path when a cursor
                    // is active.

                    if (idle.cancel) {
                        // Cancel skill targeting
                        if (level.prepared_skill != null) {
                            // Stay in player_attack phase
                            if (!history.replaying) history.session.queueActionSound(history.backing_allocator, .cancel);
                            event_push.pushPlayerAction(current, .player_cancel_skill, allocator);
                        }
                    }

                    if (idle.skip) {
                        // Skip attack, end turn
                        event_push.pushPlayerAction(current, .player_skip_attack, allocator);
                    }
                },
            }
            return;
        }
    }

    if (idle.tile_clicked) |clicked_position| {
        if (current.hub) |hub| {
            // An NPC on the clicked tile: interaction is an unimplemented
            // stub (TODO → NPC Interaction), so the click does nothing -
            // firing interact_with_npc would record a no-op undo step, and
            // walking onto the NPC would misread a click addressed to the
            // NPC as a click addressed to the tile. When the system lands,
            // this is where the click → interact_with_npc push goes.
            var clicked_npc = false;
            for (hub.npcs) |npc| {
                if (npc.position.x == clicked_position.x and
                    npc.position.y == clicked_position.y)
                {
                    clicked_npc = true;
                    break;
                }
            }

            // Move to the clicked tile if walkable. The player's own tile
            // is walkable (they stand on it), but a same-position move
            // would be a recorded no-op - gated. The player never overlaps
            // a mission exit (hubs spawn them at the layout's '!'), so an
            // own-tile click can't be an intentional mission entry.
            var is_walkable = false;
            for (hub.hub_tiles) |tile| {
                if (tile.x == clicked_position.x and tile.y == clicked_position.y) {
                    is_walkable = true;
                    break;
                }
            }
            const own_tile = clicked_position.x == hub.player.position.x and
                clicked_position.y == hub.player.position.y;
            if (is_walkable and !own_tile and !clicked_npc) {
                event_push.pushPlayerAction(current, .{ .move_player = .{
                    .destination = clicked_position,
                } }, allocator);
            }
        }
    }
}

/// Resolve the logical tile cursor (`session.tile_cursor`) for this frame.
///
/// Mouse takes precedence when it moved this tick: the cursor follows the
/// mouse, but is cleared when the pointer is over a blocking UI element (so
/// panels/buttons don't leave a world-cursor ghost) or over a non-tile. When
/// the mouse didn't move, arrow keys nudge the cursor one tile; if the cursor
/// is null, it snaps to the player's tile first. A nudge onto empty space
/// CROSSES THE GAP: the cursor jumps to the first tile on the ray in the
/// nudge direction (no tile in that direction → it stays). Runs in a
/// level/hub (needs world tiles + the player position); the editor screen
/// has its own arm with paint semantics (`resolveEditorTileCursor` - no
/// tile-membership check, no nudge clamp, always one step).
pub fn resolveTileCursor(
    history: *GameStateHistory,
    player_input: PlayerInput,
    ui_elements: []const ui.UiElement,
) void {
    const current = &history.current_state;

    // Editor edit mode: every tool resolves the tile cursor (paint / place
    // / anchor / select target - the view branches per tool for the
    // outline: single tile, footprint region, or the select tool's
    // hovered-decoration preview).
    if (current.screen == .editor) {
        resolveEditorTileCursor(history, player_input, ui_elements);
        return;
    }

    if (current.screen != .level and current.screen != .hub) return;

    const in_game = player_input.anytime.in_game;
    const world_tiles: []const types.Vector2 = if (current.level) |*level|
        level.level_tiles
    else if (current.hub) |*hub|
        hub.hub_tiles
    else
        &.{};

    if (in_game.mouse_moved_this_tick) {
        // Mouse owns the cursor this frame.
        if (ui.blockingElementAt(ui_elements, player_input.pointer.position.toScreenPosition()) != null) {
            history.session.tile_cursor = null;
            return;
        }
        if (in_game.mouse_tile) |mouse_tile| {
            for (world_tiles) |tile| {
                if (tile.x == mouse_tile.x and tile.y == mouse_tile.y) {
                    history.session.tile_cursor = mouse_tile;
                    return;
                }
            }
        }
        history.session.tile_cursor = null;
        return;
    }

    // Mouse idle - arrow keys nudge the cursor. The four move_cursor_* bools
    // are the TRIGGER (an edge/repeat fired this frame); the nudge VECTOR is
    // derived from HELD cursor keys (cursor_direction), so a diagonal nudge
    // fires when any one of the two held keys edges/repeats - two physical
    // presses rarely land in one tick, and per-key repeat timers drift, so
    // requiring both to fire in the same frame was inconsistent.
    const nudge_up = in_game.move_cursor_up;
    const nudge_down = in_game.move_cursor_down;
    const nudge_left = in_game.move_cursor_left;
    const nudge_right = in_game.move_cursor_right;
    if (!nudge_up and !nudge_down and !nudge_left and !nudge_right) return;

    // Snap to the player's tile if the cursor is null.
    const origin = history.session.tile_cursor orelse blk: {
        const player_pos = if (current.level) |*level|
            level.entities[0].position
        else if (current.hub) |*hub|
            hub.player.position
        else
            return;
        break :blk player_pos;
    };

    // Nudge by the held-key direction (each axis independently; diagonals
    // work via two held keys, opposite keys cancel). FALLBACK when the held
    // vector cancels to zero: a REAL press edge that landed while its
    // opposite was still held (key rollover at fast input speeds) nudges by
    // the press's own direction instead - the edge is the intent signal,
    // and it would otherwise be consumed into a zero vector and never
    // re-fire (the opposite's release produces no edge). Synthetic repeats
    // keep the cancel: deliberately holding both opposites stays frozen
    // (cursor_press_direction is repeats-excluded by construction).
    const direction = if (in_game.cursor_direction.x == 0 and in_game.cursor_direction.y == 0)
        in_game.cursor_press_direction
    else
        in_game.cursor_direction;
    const nudged = types.Vector2{
        .x = origin.x + direction.x,
        .y = origin.y + direction.y,
    };

    // If the nudged position is a world tile, move there. Otherwise CROSS
    // THE GAP: jump to the first tile on the ray in the nudge direction
    // (keyboard navigation reaches disconnected tile groups instead of
    // stopping at the edge). No tile in that direction at all → stay.
    for (world_tiles) |tile| {
        if (tile.x == nudged.x and tile.y == nudged.y) {
            history.session.tile_cursor = nudged;
            return;
        }
    }
    if (functions.nearestTileAlongDirection(world_tiles, origin, direction)) |target| {
        history.session.tile_cursor = target;
    }
}
/// Editor arm of the tile-cursor resolution. The cursor follows the mouse
/// to ANY tile position (cleared over blocking UI, like levels/hubs); arrow
/// keys nudge freely - there is no clamp-to-real-tile because acting over
/// empty space is the point. A null cursor snaps to the active level's
/// player_start (the '!', the editor's player-position analog). What the
/// cursor MEANS is per-tool (view renders the fitting outline); for the
/// decoration tools the cursor tile is the placement ANCHOR tile.
fn resolveEditorTileCursor(
    history: *GameStateHistory,
    player_input: PlayerInput,
    ui_elements: []const ui.UiElement,
) void {
    const current = &history.current_state;

    const in_game = player_input.anytime.in_game;
    if (in_game.mouse_moved_this_tick) {
        // Mouse owns the cursor this frame.
        if (ui.blockingElementAt(ui_elements, player_input.pointer.position.toScreenPosition()) != null) {
            history.session.tile_cursor = null;
            return;
        }
        history.session.tile_cursor = in_game.mouse_tile;
        return;
    }

    // Mouse idle - arrow keys nudge the cursor (same trigger/derive split
    // as levels/hubs: the move_cursor_* edges fire, the direction comes
    // from held keys).
    const nudge_up = in_game.move_cursor_up;
    const nudge_down = in_game.move_cursor_down;
    const nudge_left = in_game.move_cursor_left;
    const nudge_right = in_game.move_cursor_right;
    if (!nudge_up and !nudge_down and !nudge_left and !nudge_right) return;

    var cursor = history.session.tile_cursor orelse blk: {
        const editor = current.editor orelse return;
        if (editor.levels.len == 0) return;
        break :blk editor.levels[@min(editor.active_level_index, editor.levels.len - 1)].player_start;
    };

    // Same trigger/derive split + rollover fallback as levels/hubs (see
    // resolveTileCursor's nudge block): the held vector, unless it cancels
    // to zero and a real press edge carries the intent instead.
    const direction = if (in_game.cursor_direction.x == 0 and in_game.cursor_direction.y == 0)
        in_game.cursor_press_direction
    else
        in_game.cursor_direction;
    cursor.x += direction.x;
    cursor.y += direction.y;
    history.session.tile_cursor = cursor;
}

test "handleRightClickEditorDelete: clean click fires, drag cancels, UI press no-ops" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const delete_tiles = [_]types.Vector2{.{ .x = 1, .y = 0 }};
    const levels = [_]types.EditorLevel{.{ .level_tiles = &delete_tiles }};
    var history = harness.newHistory(.{
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
    });

    // Camera centered on (0,0) at zoom 1 with the reference viewport: the
    // screen center maps to tile (0,0), +256px x to tile (1,0).
    const camera = types.Camera{ .position = .{ .x = 128, .y = 128 } };
    const viewport = input.ViewportSize{ .width = 3840, .height = 2160 };
    // One tile right of center → tile (1,0), a bare deletable tile (the
    // plan is nonempty; the input gate no-ops empty ground).
    const center = input.PointerPosition{ .x = 1920, .y = 1080 };
    const over_tile = input.PointerPosition{ .x = center.x + 256, .y = center.y };

    // Clean press + release over the tile → the delete event is pushed
    // (targeting the pressed tile (1,0)).
    handleRightClickEditorDelete(
        &history,
        .{ .right_pressed = true, .position = over_tile },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.pending_right_click != null);
    handleRightClickEditorDelete(
        &history,
        .{ .right_released = true, .position = over_tile },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try std.testing.expectEqual(
        types.Vector2{ .x = 1, .y = 0 },
        history.current_state.event_stack[0].player_input_event.player_delete_editor_at.position,
    );
    try std.testing.expect(history.session.ui_state.pending_right_click == null);

    // Process it: the player action's handler pushes the tile-erase
    // sub-event; processing that empties the stack.
    @import("event_handlers.zig").processEvent(&history);
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    @import("event_handlers.zig").processEvent(&history);
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Press then move beyond the drag threshold → the pending cancels (the
    // press became a camera pan); release pushes nothing.
    handleRightClickEditorDelete(
        &history,
        .{ .right_pressed = true, .position = center },
        &.{},
        camera,
        1.0,
        viewport,
    );
    handleRightClickEditorDelete(
        &history,
        .{ .right_held = true, .position = .{ .x = center.x + ui.drag_threshold_pixels + 1, .y = center.y } },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.pending_right_click == null);
    handleRightClickEditorDelete(
        &history,
        .{ .right_released = true, .position = center },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Press over blocking UI → no pending; release pushes nothing.
    const blocking_panel = [_]ui.UiElement{.{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = .{ .x = 1800, .y = 1000 },
        .width = 400,
        .height = 400,
    } }};
    handleRightClickEditorDelete(
        &history,
        .{ .right_pressed = true, .position = center },
        &blocking_panel,
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.pending_right_click == null);
    handleRightClickEditorDelete(
        &history,
        .{ .right_released = true, .position = center },
        &blocking_panel,
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

/// A shift+click toggle (the player orchestrator - exactly what the
/// marquee gesture's unpromoted shift release fires) drained to idle -
/// the contract-level toggle used by the selection tests.
fn toggleSelectionAt(history: *GameStateHistory, position: types.Vector2) void {
    event_push.pushPlayerAction(
        &history.current_state,
        .{ .player_toggle_editor_selection = .{ .position = position } },
        history.current_arena.allocator(),
    );
    @import("test_harness.zig").runToIdle(history);
}

test "player_toggle_editor_selection (shift+click): toggles the tile + occupants group, singletons, decoration; undo/redo restores" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const footprint = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 256, .y = 256 },
    }};
    const decoration_placements = [_]types.DecorationPlacement{.{
        .type_id = 0,
        .position = .{ .x = 7, .y = 7 },
    }};
    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 } };
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 1, .y = 1 },
    }};
    const item_placements = [_]types.ItemPlacement{.{
        .type_id = 0,
        .position = .{ .x = 1, .y = 1 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 2, .y = 2 },
        .entity_placements = &entity_placements,
        .item_placements = &item_placements,
        .decoration_placements = &decoration_placements,
    }};
    var history = harness.newHistory(.{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{
            .levels = &levels,
            .decoration_types = &decoration_types,
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    @import("test_harness.zig").runToIdle(&history);

    // A tile with an enemy + item on it: all three added in one click.
    toggleSelectionAt(&history, .{ .x = 1, .y = 1 });
    {
        const selection = history.current_state.editor.?.selection;
        try std.testing.expectEqual(@as(usize, 3), selection.len);
        try std.testing.expectEqual(types.Selectable{ .tile = .{ .x = 1, .y = 1 } }, selection[0]);
        try std.testing.expectEqual(@as(u32, 0), selection[1].entity_placement);
        try std.testing.expectEqual(@as(u32, 0), selection[2].ground_item_placement);
    }

    // Clicking the same tile again toggles the WHOLE group off - the tile
    // AND its occupants leave together.
    toggleSelectionAt(&history, .{ .x = 1, .y = 1 });
    try std.testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);
    // A third click toggles it back on.
    toggleSelectionAt(&history, .{ .x = 1, .y = 1 });
    try std.testing.expectEqual(@as(usize, 3), history.current_state.editor.?.selection.len);

    // The '!' and '=' singletons are selectable - and toggleable.
    toggleSelectionAt(&history, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(
        types.Selectable.player_start,
        history.current_state.editor.?.selection[3],
    );
    toggleSelectionAt(&history, .{ .x = 2, .y = 2 });
    try std.testing.expectEqual(
        types.Selectable.level_end,
        history.current_state.editor.?.selection[4],
    );
    toggleSelectionAt(&history, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(usize, 4), history.current_state.editor.?.selection.len);

    // The covering decoration (by index) - and toggling it off.
    toggleSelectionAt(&history, .{ .x = 7, .y = 7 });
    try std.testing.expectEqual(
        @as(u32, 0),
        history.current_state.editor.?.selection[4].decoration_placement,
    );
    toggleSelectionAt(&history, .{ .x = 7, .y = 7 });
    try std.testing.expectEqual(@as(usize, 4), history.current_state.editor.?.selection.len);

    // Empty ground: nothing to select - the toggle PLANS empty (the
    // input gate never fires a player action for it).
    try std.testing.expectEqual(
        @as(usize, 0),
        planning.planEditorSelectionActions(
            &history.current_state.editor.?,
            .{ .x = 9, .y = 9 },
            history.current_arena.allocator(),
        ).len,
    );
    try std.testing.expectEqual(@as(usize, 4), history.current_state.editor.?.selection.len);

    // The selection rides the undo timeline: undo reverts the decoration
    // OFF-toggle (the last recorded click) - the decoration entry returns.
    // Redo walks forward again.
    try std.testing.expect(history.undo(event_handlers.processEvent));
    {
        const selection = history.current_state.editor.?.selection;
        try std.testing.expectEqual(@as(usize, 5), selection.len);
        try std.testing.expectEqual(@as(u32, 0), selection[4].decoration_placement);
    }
    try std.testing.expect(history.redo(event_handlers.processEvent));
    try std.testing.expectEqual(@as(usize, 4), history.current_state.editor.?.selection.len);
}

test "handleEditorMarquee: shift-drag adds the region, shift-click toggles, shift-release cancels" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 3, .y = 3 } };
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles }};
    var history = harness.newHistory(.{
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
    });
    // The select tool is the default; state it for the reader.
    history.current_state.editor.?.active_tool = .select;

    // Camera centered on (0,0) at zoom 1 with the reference viewport: the
    // screen center maps to tile (0,0), +256px per tile.
    const camera = types.Camera{ .position = .{ .x = 128, .y = 128 } };
    const viewport = input.ViewportSize{ .width = 3840, .height = 2160 };
    const center = types.ScreenPosition{ .x = 1920, .y = 1080 };
    const shift: types.Modifiers = .{ .shift = true };
    const no_shift: types.Modifiers = .{};
    const tilePosition = struct {
        fn call(tile: types.Vector2) input.PointerPosition {
            return .{
                .x = center.x + @as(f32, @floatFromInt(tile.x)) * 256,
                .y = center.y + @as(f32, @floatFromInt(tile.y)) * 256,
            };
        }
    }.call;

    // --- Shift+drag: press records, threshold promotes, release fires
    // the region add. ---
    handleEditorMarquee(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 1, .y = 1 }), .modifiers = shift },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_marquee != null);
    try std.testing.expect(!history.session.ui_state.editor_marquee.?.promoted);

    // Not yet beyond the threshold (moving only along x, same row): still
    // unpromoted (the end corner does not track before promotion).
    handleEditorMarquee(
        &history,
        .{ .held = true, .position = .{ .x = tilePosition(.{ .x = 1, .y = 1 }).x + ui.drag_threshold_pixels, .y = tilePosition(.{ .x = 1, .y = 1 }).y }, .modifiers = shift },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(!history.session.ui_state.editor_marquee.?.promoted);

    // Beyond the threshold: promoted, the end corner tracks the pointer.
    handleEditorMarquee(
        &history,
        .{ .held = true, .position = tilePosition(.{ .x = 3, .y = 3 }), .modifiers = shift },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_marquee.?.promoted);
    try std.testing.expectEqual(types.Vector2{ .x = 3, .y = 3 }, history.session.ui_state.editor_marquee.?.end_position);

    // Release with Shift still held: the region add fires ((1,1)-(3,3)).
    handleEditorMarquee(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 3, .y = 3 }), .modifiers = shift },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    {
        const region = history.current_state.event_stack[0].player_input_event.player_select_editor_region;
        try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 1 }, region.start_position);
        try std.testing.expectEqual(types.Vector2{ .x = 3, .y = 3 }, region.end_position);
    }
    try std.testing.expect(history.session.ui_state.editor_marquee == null);
    @import("event_handlers.zig").processEvent(&history);
    @import("test_harness.zig").runToIdle(&history);
    try std.testing.expectEqual(@as(usize, 2), history.current_state.editor.?.selection.len);

    // --- Shift+click WITHOUT drag: the TOGGLE path - the toggle fires
    // at the press tile (the select arm deferred to the gesture while
    // Shift was held; a plain click would REPLACE). ---
    handleEditorMarquee(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 1, .y = 1 }), .modifiers = shift },
        &.{},
        camera,
        1.0,
        viewport,
    );
    handleEditorMarquee(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 1, .y = 1 }), .modifiers = shift },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try std.testing.expectEqual(
        types.Vector2{ .x = 1, .y = 1 },
        history.current_state.event_stack[0].player_input_event.player_toggle_editor_selection.position,
    );
    @import("event_handlers.zig").processEvent(&history);
    @import("test_harness.zig").runToIdle(&history);

    // --- Shift released mid-drag: the marquee cancels - no region, no
    // toggle (the gesture consumed the press). ---
    handleEditorMarquee(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 1, .y = 1 }), .modifiers = shift },
        &.{},
        camera,
        1.0,
        viewport,
    );
    handleEditorMarquee(
        &history,
        .{ .held = true, .position = tilePosition(.{ .x = 3, .y = 3 }), .modifiers = shift },
        &.{},
        camera,
        1.0,
        viewport,
    );
    handleEditorMarquee(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 3, .y = 3 }), .modifiers = no_shift },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try std.testing.expect(history.session.ui_state.editor_marquee == null);

    // --- A press WITHOUT Shift never starts a marquee (the plain-click
    // path owns it via handleIdleInput). ---
    handleEditorMarquee(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 1, .y = 1 }), .modifiers = no_shift },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_marquee == null);
}

test "handleEditorMoveDrag: selected press moves, unselected press claims and drags select-and-move, empty ground never claims" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 4, .y = 4 } };
    const levels = [_]types.EditorLevel{.{ .level_tiles = &tiles, .player_start = .{ .x = 0, .y = 0 } }};
    var history = harness.newHistory(.{
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
    });
    const seeded_selection = [_]types.Selectable{.{ .tile = .{ .x = 1, .y = 1 } }};
    history.current_state.editor.?.selection = &seeded_selection;

    // Camera centered on (0,0) at zoom 1 with the reference viewport: the
    // screen center maps to tile (0,0), +256px per tile.
    const camera = types.Camera{ .position = .{ .x = 128, .y = 128 } };
    const viewport = input.ViewportSize{ .width = 3840, .height = 2160 };
    const center = input.PointerPosition{ .x = 1920, .y = 1080 };
    const tilePosition = struct {
        fn call(tile: types.Vector2) input.PointerPosition {
            return .{
                .x = center.x + @as(f32, @floatFromInt(tile.x)) * 256,
                .y = center.y + @as(f32, @floatFromInt(tile.y)) * 256,
            };
        }
    }.call;

    // --- Plain press ON the selected tile claims the gesture; the same
    // frame's tile_clicked does NOT toggle (the gesture owns the press). ---
    handleEditorMoveDrag(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 1, .y = 1 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag != null);
    try std.testing.expect(!history.session.ui_state.editor_move_drag.?.promoted);
    try std.testing.expect(history.session.ui_state.editor_move_drag.?.selected_at_press);
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 1, .y = 1 } }, null, .{});
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // --- Drag beyond the threshold promotes; the live delta tracks the
    // pointer; release fires the move with the pointer delta. ---
    handleEditorMoveDrag(
        &history,
        .{ .held = true, .position = tilePosition(.{ .x = 4, .y = 4 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag.?.promoted);
    try std.testing.expectEqual(types.Vector2{ .x = 4, .y = 4 }, history.session.ui_state.editor_move_drag.?.current_position_tile);
    handleEditorMoveDrag(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 4, .y = 4 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    {
        const move_event = history.current_state.event_stack[0].player_input_event.player_move_editor_selection;
        try std.testing.expectEqual(types.Vector2{ .x = 3, .y = 3 }, move_event.delta);
    }
    try std.testing.expect(history.session.ui_state.editor_move_drag == null);
    @import("event_handlers.zig").processEvent(&history);
    @import("test_harness.zig").runToIdle(&history);
    // The moved tile painted at (4,4) (already a tile there - the paint
    // plan is empty, so the tile was deleted fully) and the move
    // deselects.
    try std.testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);

    // --- A promoted release with a ZERO delta never fires. ---
    history.current_state.editor.?.selection = &seeded_selection;
    handleEditorMoveDrag(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 1, .y = 1 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    // Promote via a sub-threshold-then-back wobble: move beyond the
    // threshold, then return to the press tile before releasing.
    handleEditorMoveDrag(
        &history,
        .{ .held = true, .position = .{ .x = tilePosition(.{ .x = 1, .y = 1 }).x + ui.drag_threshold_pixels + 10, .y = tilePosition(.{ .x = 1, .y = 1 }).y } },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag.?.promoted);
    handleEditorMoveDrag(
        &history,
        .{ .held = true, .position = tilePosition(.{ .x = 1, .y = 1 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    handleEditorMoveDrag(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 1, .y = 1 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try std.testing.expect(history.session.ui_state.editor_move_drag == null);

    // --- An UNPROMOTED release acts as a plain click: the REPLACE fires
    // at the press tile, collapsing the selection to the clicked group.
    // (The re-seeded selection must reference things that still EXIST -
    // the first move deleted (1,1) fully when it landed on the existing
    // tile at (4,4) - and must contain MORE than the clicked group, or
    // the replace would be a no-op that never fires.) ---
    const surviving_selection = [_]types.Selectable{ .{ .tile = .{ .x = 4, .y = 4 } }, .player_start };
    history.current_state.editor.?.selection = &surviving_selection;
    handleEditorMoveDrag(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 4, .y = 4 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    handleEditorMoveDrag(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 4, .y = 4 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try std.testing.expectEqual(
        types.Vector2{ .x = 4, .y = 4 },
        history.current_state.event_stack[0].player_input_event.player_replace_editor_selection.position,
    );

    // --- An UNSELECTED-but-selectable press CLAIMS: the player-start
    // marker at (0,0) is not selected (the selection is the (4,4) group
    // after the replace above), but dragging it selects it and moves it
    // in one gesture. The release pushes the move + replace PAIR - the
    // replace on top, so the LIFO drain selects the grabbed group before
    // the move orchestrator plans against it. ---
    @import("event_handlers.zig").processEvent(&history);
    @import("test_harness.zig").runToIdle(&history);
    handleEditorMoveDrag(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 0, .y = 0 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag != null);
    try std.testing.expect(!history.session.ui_state.editor_move_drag.?.selected_at_press);
    handleEditorMoveDrag(
        &history,
        .{ .held = true, .position = tilePosition(.{ .x = 1, .y = 1 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag.?.promoted);
    handleEditorMoveDrag(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 1, .y = 1 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag == null);
    try std.testing.expectEqual(@as(usize, 2), history.current_state.event_stack.len);
    // The push order is the correctness mechanism: the replace sits ON
    // TOP of the move, so the drain selects the group first (a flipped
    // order would plan the move against the unreplaced selection).
    try std.testing.expectEqual(
        types.Vector2{ .x = 0, .y = 0 },
        history.current_state.event_stack[1].player_input_event.player_replace_editor_selection.position,
    );
    try std.testing.expectEqual(
        types.Vector2{ .x = 1, .y = 1 },
        history.current_state.event_stack[0].player_input_event.player_move_editor_selection.delta,
    );
    @import("event_handlers.zig").processEvent(&history);
    @import("test_harness.zig").runToIdle(&history);
    // The marker moved to (1,1) and the move deselects (the move
    // machinery's clear + chained-commit semantics have their own tests
    // - this pins that the gesture's push order delivers them a replaced
    // selection).
    try std.testing.expectEqual(
        types.Vector2{ .x = 1, .y = 1 },
        history.current_state.editor.?.levels[0].player_start,
    );
    try std.testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);

    // --- ONE undo step reverts the whole drag: both actions were pushed
    // in the same frame, drained together, and share one idle point (it
    // is recorded when the stack EMPTIES, not per action). Back to the
    // post-replace selection of the plain click above. ---
    try std.testing.expect(history.undo(@import("event_handlers.zig").processEvent));
    try std.testing.expectEqual(
        types.Vector2{ .x = 0, .y = 0 },
        history.current_state.editor.?.levels[0].player_start,
    );
    try std.testing.expectEqual(@as(usize, 1), history.current_state.editor.?.selection.len);
    try std.testing.expectEqual(
        types.Selectable{ .tile = .{ .x = 4, .y = 4 } },
        history.current_state.editor.?.selection[0],
    );

    // --- A zero-delta unselected-claim drag (the grab-and-drop-in-place
    // wobble): just the replace fires - the thing ends up selected, like
    // a click. ---
    handleEditorMoveDrag(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 0, .y = 0 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(!history.session.ui_state.editor_move_drag.?.selected_at_press);
    handleEditorMoveDrag(
        &history,
        .{ .held = true, .position = .{ .x = tilePosition(.{ .x = 0, .y = 0 }).x + ui.drag_threshold_pixels + 10, .y = tilePosition(.{ .x = 0, .y = 0 }).y } },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag.?.promoted);
    handleEditorMoveDrag(
        &history,
        .{ .held = true, .position = tilePosition(.{ .x = 0, .y = 0 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    handleEditorMoveDrag(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 0, .y = 0 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try std.testing.expectEqual(
        types.Vector2{ .x = 0, .y = 0 },
        history.current_state.event_stack[0].player_input_event.player_replace_editor_selection.position,
    );
    @import("event_handlers.zig").processEvent(&history);
    @import("test_harness.zig").runToIdle(&history);
    try std.testing.expectEqual(@as(usize, 1), history.current_state.editor.?.selection.len);
    try std.testing.expectEqual(types.Selectable.player_start, history.current_state.editor.?.selection[0]);

    // --- An UNPROMOTED unselected-claim release acts as a plain click
    // (the claim is invisible without a drag): press the unselected
    // (4,4) tile group and release without moving. ---
    handleEditorMoveDrag(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 4, .y = 4 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag != null);
    try std.testing.expect(!history.session.ui_state.editor_move_drag.?.selected_at_press);
    handleEditorMoveDrag(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 4, .y = 4 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try std.testing.expectEqual(
        types.Vector2{ .x = 4, .y = 4 },
        history.current_state.event_stack[0].player_input_event.player_replace_editor_selection.position,
    );
    @import("event_handlers.zig").processEvent(&history);
    @import("test_harness.zig").runToIdle(&history);
    try std.testing.expectEqual(@as(usize, 1), history.current_state.editor.?.selection.len);

    // --- EMPTY GROUND never claims (the click-to-deselect stays the
    // plain release path's job; a drag from empty ground does nothing).
    // (2,2) has no tile, marker, or decoration. ---
    handleEditorMoveDrag(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 2, .y = 2 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag == null);
    handleEditorMoveDrag(
        &history,
        .{ .held = true, .position = tilePosition(.{ .x = 3, .y = 3 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    handleEditorMoveDrag(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 3, .y = 3 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    // The plain click on empty ground still deselects (the idle arm's
    // replace fires the clear alone).
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 2, .y = 2 } }, null, .{});
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    @import("event_handlers.zig").processEvent(&history);
    @import("test_harness.zig").runToIdle(&history);
    try std.testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);
}

test "handleEditorMoveDrag: a marker dragged onto the other marker never fires the move" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    // '!' at (0,0), '=' at (3,3). Dragging '=' onto (0,0) would leave both
    // markers on one tile - no file representation - so the move is
    // VETOED at the input gate (no dead undo step). The unselected-claim
    // path still fires its replace (the selection change is legal on its
    // own); the selected-at-press path fires nothing at all.
    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 3 } };
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .level_end = .{ .x = 3, .y = 3 },
    }};
    var history = harness.newHistory(.{
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
    });

    const camera = types.Camera{ .position = .{ .x = 128, .y = 128 } };
    const viewport = input.ViewportSize{ .width = 3840, .height = 2160 };
    const center = input.PointerPosition{ .x = 1920, .y = 1080 };
    const tilePosition = struct {
        fn call(tile: types.Vector2) input.PointerPosition {
            return .{
                .x = center.x + @as(f32, @floatFromInt(tile.x)) * 256,
                .y = center.y + @as(f32, @floatFromInt(tile.y)) * 256,
            };
        }
    }.call;

    // --- Unselected-claim drag of the '=' onto the '!': the move never
    // fires; the replace (the legal half of the gesture) does. ---
    handleEditorMoveDrag(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 3, .y = 3 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag != null);
    try std.testing.expect(!history.session.ui_state.editor_move_drag.?.selected_at_press);
    handleEditorMoveDrag(
        &history,
        .{ .held = true, .position = tilePosition(.{ .x = 0, .y = 0 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag.?.promoted);
    handleEditorMoveDrag(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 0, .y = 0 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try std.testing.expectEqual(
        types.Vector2{ .x = 3, .y = 3 },
        history.current_state.event_stack[0].player_input_event.player_replace_editor_selection.position,
    );
    @import("event_handlers.zig").processEvent(&history);
    @import("test_harness.zig").runToIdle(&history);
    // The '=' never moved; the replace left it selected.
    try std.testing.expectEqual(
        types.Vector2{ .x = 3, .y = 3 },
        history.current_state.editor.?.levels[0].level_end.?,
    );
    try std.testing.expectEqual(@as(usize, 1), history.current_state.editor.?.selection.len);
    try std.testing.expectEqual(types.Selectable.level_end, history.current_state.editor.?.selection[0]);

    // --- Selected-at-press drag of the '=' onto the '!': nothing fires at
    // all (the move is vetoed; this path has no replace). ---
    handleEditorMoveDrag(
        &history,
        .{ .pressed = true, .position = tilePosition(.{ .x = 3, .y = 3 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag.?.selected_at_press);
    handleEditorMoveDrag(
        &history,
        .{ .held = true, .position = tilePosition(.{ .x = 0, .y = 0 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.ui_state.editor_move_drag.?.promoted);
    handleEditorMoveDrag(
        &history,
        .{ .released = true, .position = tilePosition(.{ .x = 0, .y = 0 }) },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try std.testing.expectEqual(
        types.Vector2{ .x = 3, .y = 3 },
        history.current_state.editor.?.levels[0].level_end.?,
    );
    try std.testing.expectEqual(
        types.Vector2{ .x = 0, .y = 0 },
        history.current_state.editor.?.levels[0].player_start,
    );
}

test "camera zoom (wheel + keys): gated to camera-bearing screens" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    var history = harness.newHistory(null);
    const pointer = types.ScreenPosition{ .x = 0, .y = 0 };
    const zoom_before = history.settings.camera_zoom;

    // Main menu: neither the wheel nor the zoom keys touch the setting.
    history.current_state.screen = .main_menu;
    handleAnytimeInput(&history, .{ .scroll_delta = 3 }, null, pointer, &.{});
    handleAnytimeInput(&history, .{ .zoom_in = true }, null, pointer, &.{});
    try std.testing.expectEqual(zoom_before, history.settings.camera_zoom);

    // Replay viewer: same - no camera, no zoom.
    history.current_state.screen = .replay_viewer;
    handleAnytimeInput(&history, .{ .scroll_delta = 3 }, null, pointer, &.{});
    try std.testing.expectEqual(zoom_before, history.settings.camera_zoom);

    // Hub: the wheel and the keys zoom (1 notch + one key step).
    history.current_state.screen = .hub;
    handleAnytimeInput(&history, .{ .scroll_delta = 1 }, null, pointer, &.{});
    handleAnytimeInput(&history, .{ .zoom_in = true }, null, pointer, &.{});
    try std.testing.expectEqual(zoom_before + 2 * camera_zoom_step, history.settings.camera_zoom);
}

test "handleCameraPan: pan engages only past the drag threshold" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const level_tiles = [_]types.Vector2{.{ .x = 1, .y = 0 }};
    const levels = [_]types.EditorLevel{.{ .level_tiles = &level_tiles }};
    var history = harness.newHistory(.{
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
    });

    const camera = types.Camera{ .position = .{ .x = 128, .y = 128 } };
    const viewport = input.ViewportSize{ .width = 3840, .height = 2160 };
    const center = input.PointerPosition{ .x = 1920, .y = 1080 };

    // Press records the anchor + press position but does not pan yet.
    input_gestures.handleCameraPan(
        &history,
        .{ .right_pressed = true, .position = center },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.camera_pan_anchor != null);
    try std.testing.expect(history.session.camera_pan_press != null);
    try std.testing.expect(history.session.camera_pan == null);

    // Exactly AT the threshold (strict `>`): still no pan - a sub-threshold
    // wiggle pans nothing, so a clean right-click stays clean.
    input_gestures.handleCameraPan(
        &history,
        .{ .right_held = true, .position = .{ .x = center.x + @as(f32, @floatFromInt(ui.drag_threshold_pixels)), .y = center.y } },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.camera_pan_press != null);
    try std.testing.expect(history.session.camera_pan == null);

    // Past the threshold: the pan engages (press record dropped, offset
    // solved against the press-time anchor).
    input_gestures.handleCameraPan(
        &history,
        .{ .right_held = true, .position = .{ .x = center.x + ui.drag_threshold_pixels + 1, .y = center.y } },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.camera_pan_press == null);
    try std.testing.expect(history.session.camera_pan != null);

    // Release: anchor + press clear; the offset persists (sticky pan -
    // cleared on player move / screen transition, not on release).
    input_gestures.handleCameraPan(
        &history,
        .{ .right_released = true, .position = .{ .x = center.x + ui.drag_threshold_pixels + 1, .y = center.y } },
        &.{},
        camera,
        1.0,
        viewport,
    );
    try std.testing.expect(history.session.camera_pan_anchor == null);
    try std.testing.expect(history.session.camera_pan_press == null);
    try std.testing.expect(history.session.camera_pan != null);
}

// --- Drag no-op gate (pure predicate) ---------------------------------------
// A drop that would change nothing never fires (no dead undo step). The
// predicate is pure over the player entity; the handleDrag wiring is
// covered by the gate tests in handler_tests_gear.zig.

/// Fixture: a sword in inventory slot 0, boots in slot 1, a main-hand
/// weapon equipped, Flash Strike in utility slot 0.
fn dragGatePlayer() types.Entity {
    var player_entity = types.Entity{};
    player_entity.inventory.slots[0] = .{ .weapon = .{
        .name = "sword",
        .weapon_type = .sword,
        .weapon_damage = 4,
    } };
    player_entity.inventory.slots[1] = .{ .boots = .{ .name = "boots" } };
    player_entity.main_hand_weapon = .{ .name = "equipped", .weapon_type = .sword, .weapon_damage = 5 };
    player_entity.equipped_utility_skills[0] = .flash_strike;
    return player_entity;
}

test "dragActionWouldChange: equip fit conditions" {
    const player_entity = dragGatePlayer();
    // A weapon into a hand slot: fits → fires.
    try std.testing.expect(dragActionWouldChange(player_entity, false, .{ .player_equip_to_gear = .{
        .inventory_slot_index = 0,
        .gear_slot = .main_hand,
    } }));
    // A weapon into the boots slot: doesn't fit → never fires.
    try std.testing.expect(!dragActionWouldChange(player_entity, false, .{ .player_equip_to_gear = .{
        .inventory_slot_index = 0,
        .gear_slot = .boots,
    } }));
    // Boots into the boots slot: fits → fires.
    try std.testing.expect(dragActionWouldChange(player_entity, false, .{ .player_equip_to_gear = .{
        .inventory_slot_index = 1,
        .gear_slot = .boots,
    } }));
    // An empty inventory slot: nothing to equip → never fires.
    try std.testing.expect(!dragActionWouldChange(player_entity, false, .{ .player_equip_to_gear = .{
        .inventory_slot_index = 2,
        .gear_slot = .main_hand,
    } }));
}

test "dragActionWouldChange: unequip fit conditions" {
    const player_entity = dragGatePlayer();
    // Main hand (occupied) into an empty inventory slot: fires.
    try std.testing.expect(dragActionWouldChange(player_entity, false, .{ .player_unequip_from_gear = .{
        .gear_slot = .main_hand,
        .inventory_slot_index = 2,
    } }));
    // Into a slot holding boots (doesn't fit a hand): never fires.
    try std.testing.expect(!dragActionWouldChange(player_entity, false, .{ .player_unequip_from_gear = .{
        .gear_slot = .main_hand,
        .inventory_slot_index = 1,
    } }));
    // Into a slot holding a weapon (fits the hand): fires.
    try std.testing.expect(dragActionWouldChange(player_entity, false, .{ .player_unequip_from_gear = .{
        .gear_slot = .main_hand,
        .inventory_slot_index = 0,
    } }));
    // From an empty gear slot (amulet): never fires.
    try std.testing.expect(!dragActionWouldChange(player_entity, false, .{ .player_unequip_from_gear = .{
        .gear_slot = .amulet,
        .inventory_slot_index = 2,
    } }));
}

test "dragActionWouldChange: utility-skill conditions" {
    var player_entity = dragGatePlayer();
    // Re-assigning the skill already in the slot: only a change when a
    // preparation is active (the handler cancels it).
    const assign_same: events.PlayerInputEvent = .{ .player_assign_utility_skill = .{
        .skill_id = .flash_strike,
        .slot_index = 0,
    } };
    try std.testing.expect(!dragActionWouldChange(player_entity, false, assign_same));
    try std.testing.expect(dragActionWouldChange(player_entity, true, assign_same));
    // A different skill: always fires.
    try std.testing.expect(dragActionWouldChange(player_entity, false, .{ .player_assign_utility_skill = .{
        .skill_id = .replenish,
        .slot_index = 0,
    } }));
    // Swapping two slots holding the same skill (a duplicate assignment):
    // only a change when a preparation is active.
    player_entity.equipped_utility_skills[1] = .flash_strike;
    const swap_same: events.PlayerInputEvent = .{ .player_swap_utility_skills = .{
        .slot_a_index = 0,
        .slot_b_index = 1,
    } };
    try std.testing.expect(!dragActionWouldChange(player_entity, false, swap_same));
    try std.testing.expect(dragActionWouldChange(player_entity, true, swap_same));
    // Swapping a skill with an empty slot: a real move → fires.
    player_entity.equipped_utility_skills[1] = null;
    try std.testing.expect(dragActionWouldChange(player_entity, false, .{ .player_swap_utility_skills = .{
        .slot_a_index = 0,
        .slot_b_index = 1,
    } }));
}

test "player_replace_editor_selection (plain click): replaces the selection, empty ground clears it, no-op clicks never fire" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 } };
    const entity_placements = [_]types.EntityPlacement{.{
        .type_id = 0,
        .position = .{ .x = 1, .y = 1 },
    }};
    const levels = [_]types.EditorLevel{.{
        .level_tiles = &tiles,
        .player_start = .{ .x = 0, .y = 0 },
        .entity_placements = &entity_placements,
    }};
    var history = harness.newHistory(.{
        .screen = .editor,
        .event_stack = &.{},
        .player_data = .{},
        .camera = null,
        .editor = .{
            .levels = &levels,
            .entity_types = &.{.{ .id = "Skeleton", .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1 } }},
        },
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    });
    @import("test_harness.zig").runToIdle(&history);

    // A plain click on (1,1) with an EMPTY selection: the group (tile +
    // entity) becomes the selection.
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 1, .y = 1 } }, null, .{});
    @import("test_harness.zig").runToIdle(&history);
    {
        const selection = history.current_state.editor.?.selection;
        try std.testing.expectEqual(@as(usize, 2), selection.len);
        try std.testing.expectEqual(types.Selectable{ .tile = .{ .x = 1, .y = 1 } }, selection[0]);
        try std.testing.expectEqual(@as(u32, 0), selection[1].entity_placement);
    }

    // A plain click elsewhere REPLACES the selection entirely (the old
    // entries go, the clicked group becomes the selection).
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 2, .y = 2 } }, null, .{});
    @import("test_harness.zig").runToIdle(&history);
    {
        const selection = history.current_state.editor.?.selection;
        try std.testing.expectEqual(@as(usize, 1), selection.len);
        try std.testing.expectEqual(types.Selectable{ .tile = .{ .x = 2, .y = 2 } }, selection[0]);
    }

    // Clicking the exact current selection is a NO-OP - no event fires.
    const history_length_before = history.event_history.items.len;
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 2, .y = 2 } }, null, .{});
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try std.testing.expectEqual(history_length_before, history.event_history.items.len);

    // A plain click on EMPTY GROUND clears the selection - the clicky
    // deselect-all.
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 9, .y = 9 } }, null, .{});
    @import("test_harness.zig").runToIdle(&history);
    try std.testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);

    // Clicking empty ground with an ALREADY-EMPTY selection is a no-op.
    const history_length_before_empty = history.event_history.items.len;
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 9, .y = 9 } }, null, .{});
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
    try std.testing.expectEqual(history_length_before_empty, history.event_history.items.len);

    // One undo step reverts a replace (the clear + the new group share the
    // click's idle point).
    try std.testing.expect(history.undo(event_handlers.processEvent));
    {
        const selection = history.current_state.editor.?.selection;
        try std.testing.expectEqual(@as(usize, 1), selection.len);
        try std.testing.expectEqual(types.Selectable{ .tile = .{ .x = 2, .y = 2 } }, selection[0]);
    }
}

test "isSkillLearned: found / not found" {
    const learned = [_]types.SkillId{ .slice, .bash };
    try std.testing.expect(player_handlers.isSkillLearned(&learned, .slice));
    try std.testing.expect(!player_handlers.isSkillLearned(&learned, .blink));
}

test "resolveEditorTileCursor: mouse follows to any tile position, blocked over UI, nudges unclamped" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{ .player_start = .{ .x = 2, .y = 3 } }};
    var history = harness.newHistory(.{
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
    });

    // Mouse owns the cursor when it moved - at a position with NO tile
    // (paint semantics: any tile position is a legal target).
    history.current_state.editor.?.active_tool = .tile;
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .mouse_moved_this_tick = true,
            .mouse_tile = .{ .x = 9, .y = 9 },
        } }, .pointer = .{ .position = .{ .x = 500, .y = 500 } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 9, .y = 9 }, history.session.tile_cursor.?);

    // Over a blocking UI element the cursor clears (no world-cursor ghost
    // behind panels).
    const blocking_panel = [_]ui.UiElement{.{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = .{ .x = 400, .y = 400 },
        .width = 400,
        .height = 400,
    } }};
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .mouse_moved_this_tick = true,
            .mouse_tile = .{ .x = 9, .y = 9 },
        } }, .pointer = .{ .position = .{ .x = 500, .y = 500 } } },
        &blocking_panel,
    );
    try std.testing.expectEqual(@as(?types.Vector2, null), history.session.tile_cursor);

    // Arrow nudge with a null cursor snaps to player_start first, then
    // nudges - no clamp-to-real-tile (empty space is a legal paint target).
    history.current_state.editor.?.active_tool = .tile;
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .move_cursor_right = true,
            .cursor_direction = .{ .x = 1, .y = 0 },
        } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 3, .y = 3 }, history.session.tile_cursor.?);

    // The select tool resolves the tile cursor as well (its outline
    // previews what a click would select - a covering decoration's
    // footprint region, else the single tile).
    history.current_state.editor.?.active_tool = .select;
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .mouse_moved_this_tick = true,
            .mouse_tile = .{ .x = 9, .y = 9 },
        } }, .pointer = .{ .position = .{ .x = 500, .y = 500 } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 9, .y = 9 }, history.session.tile_cursor.?);

    // The entity tool is a tile-cursor tool too (same semantics - any
    // position is a legal place target).
    history.current_state.editor.?.active_tool = .{ .entity_type = 0 };
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .mouse_moved_this_tick = true,
            .mouse_tile = .{ .x = 8, .y = 8 },
        } }, .pointer = .{ .position = .{ .x = 500, .y = 500 } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 8, .y = 8 }, history.session.tile_cursor.?);

    // The decoration tool as well - the cursor tile is the placement
    // ANCHOR tile (the view draws the footprint region outline around it).
    history.current_state.editor.?.active_tool = .{ .decoration_type = 0 };
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .mouse_moved_this_tick = true,
            .mouse_tile = .{ .x = 7, .y = 7 },
        } }, .pointer = .{ .position = .{ .x = 500, .y = 500 } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 7, .y = 7 }, history.session.tile_cursor.?);

    // The ground-item tool too (single-tile outline, like tile/enemy).
    history.current_state.editor.?.active_tool = .{ .item_type = 0 };
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .mouse_moved_this_tick = true,
            .mouse_tile = .{ .x = 6, .y = 6 },
        } }, .pointer = .{ .position = .{ .x = 500, .y = 500 } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 6, .y = 6 }, history.session.tile_cursor.?);
}

test "select_editor_tool: changing tools clears the selection, re-selecting keeps it, undo reverts the tool" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{}};
    var history = harness.newHistory(.{
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
    });
    const seeded_selection = [_]types.Selectable{.{ .tile = .{ .x = 1, .y = 1 } }};
    history.current_state.editor.?.active_tool = .select;
    history.current_state.editor.?.selection = &seeded_selection;
    @import("test_harness.zig").runToIdle(&history);

    // Re-selecting the ACTIVE tool changes nothing (no event fired).
    handleAnytimeInput(&history, .{
        .options_action = .select_editor_tool,
    }, .{ .editor_tool = .select }, .{ .x = 0, .y = 0 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), history.current_state.editor.?.selection.len);

    // Changing to a different tool clears the selection (the clear rides
    // the editor_set_tool event, so it is atomic with the switch).
    handleAnytimeInput(&history, .{
        .options_action = .select_editor_tool,
    }, .{ .editor_tool = .tile }, .{ .x = 0, .y = 0 }, &.{});
    @import("test_harness.zig").runToIdle(&history);
    try std.testing.expectEqual(types.EditorToolId.tile, history.current_state.editor.?.active_tool);
    try std.testing.expectEqual(@as(usize, 0), history.current_state.editor.?.selection.len);

    // The tool pointer AND the selection ride the undo timeline - one undo
    // step reverts the switch together with its selection clear.
    try std.testing.expect(history.undo(event_handlers.processEvent));
    try std.testing.expectEqual(types.EditorToolId.select, history.current_state.editor.?.active_tool);
    const selection = history.current_state.editor.?.selection;
    try std.testing.expectEqual(@as(usize, 1), selection.len);
    try std.testing.expectEqual(types.Selectable{ .tile = .{ .x = 1, .y = 1 } }, selection[0]);
}

test "error popup scroll: line-based offset, wheel-up scrolls toward the top" {
    // The game-wide scroll convention, pinned for the error popup (the
    // old code stepped in pixels, added the wheel delta - wheel-up scrolled
    // DOWN - and its step unit (56px) didn't even match the view's line
    // height (67px), so windows were never line-aligned). See DESIGN →
    // Error Handling → Recoverable error surface.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());
    var history = harness.newHistory(.{
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
    });
    history.session.setPendingError(backing.allocator(), "some recoverable failure");

    // Arrows: 3 lines per press, up = toward the top.
    handleAnytimeInput(&history, .{ .error_scroll_down = true }, null, .{ .x = 0, .y = 0 }, &.{});
    try std.testing.expectEqual(@as(i32, 3), history.session.error_scroll_offset);
    handleAnytimeInput(&history, .{ .error_scroll_up = true }, null, .{ .x = 0, .y = 0 }, &.{});
    try std.testing.expectEqual(@as(i32, 0), history.session.error_scroll_offset);

    // Wheel: one line per notch; POSITIVE delta (wheel up) scrolls toward
    // the top - offset DECREASES (the load-save browser / inspector /
    // skills-panel model).
    history.session.error_scroll_offset = 5;
    handleAnytimeInput(&history, .{ .scroll_delta = 1.0 }, null, .{ .x = 0, .y = 0 }, &.{});
    try std.testing.expectEqual(@as(i32, 4), history.session.error_scroll_offset);
    handleAnytimeInput(&history, .{ .scroll_delta = -2.0 }, null, .{ .x = 0, .y = 0 }, &.{});
    try std.testing.expectEqual(@as(i32, 6), history.session.error_scroll_offset);

    // Lower clamp at the input site (the upper clamp is the view's - only
    // the view knows the wrapped line count).
    history.session.error_scroll_offset = 1;
    handleAnytimeInput(&history, .{ .error_scroll_up = true }, null, .{ .x = 0, .y = 0 }, &.{});
    try std.testing.expectEqual(@as(i32, 0), history.session.error_scroll_offset);

    // Dismiss still clears through the same gate.
    handleAnytimeInput(&history, .{ .dismiss_error = true }, null, .{ .x = 0, .y = 0 }, &.{});
    try std.testing.expect(history.session.pending_error == null);
}

// --- Prepared-skill toggle (same-slot re-activation) ------------------------
// Re-activating the slot of an already-prepared skill toggles the
// preparation off (the auto-target hit still fires the skill instead -
// resolveSkillSlotAction resolves the press one way or the other, never to
// a recorded no-op). Flash Strike (targeting, range 3) in utility slot 4
// is the fixture.

/// Attack-phase history with Flash Strike equipped in utility slot 4,
/// prepared, with its highlight set, and the tile cursor cleared.
fn preparedSkillToggleHistory(
    backing: *std.heap.ArenaAllocator,
    prepared: ?types.SkillId,
) state.GameStateHistory {
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const entities = [_]types.Entity{.{
        .name = "Player",
        .position = .{ .x = 0, .y = 0 },
        .team = 0,
        .equipped_utility_skills = .{ .flash_strike, null, null, null, null },
    }};
    const tiles = [_]types.Vector2{ .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 } };
    var history = harness.newHistory(@import("test_harness.zig").levelStateWithEntities(
        backing.allocator(),
        &entities,
        &tiles,
    ));
    history.current_state.level.?.turn_phase = .player_attack;
    history.current_state.level.?.prepared_skill = prepared;
    history.current_state.level.?.highlighted_tiles = &tiles;
    history.session.tile_cursor = null;
    return history;
}

test "resolveSkillSlotAction: same prepared skill resolves to unprepare" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var history = preparedSkillToggleHistory(&backing, .flash_strike);

    const action = resolveSkillSlotAction(
        &history,
        &history.current_state,
        &history.current_state.level.?,
        4,
        history.current_arena.allocator(),
    );
    try std.testing.expect(action != null);
    try std.testing.expectEqual(
        @as(std.meta.Tag(SkillSlotAction), .unprepare),
        std.meta.activeTag(action.?),
    );
}

test "resolveSkillSlotAction: auto-target hit fires instead of unprepare" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var history = preparedSkillToggleHistory(&backing, .flash_strike);

    // The cursor sits on (1,0) - an empty tile within range 3, a valid
    // Flash Strike target. The press fires there, NOT a toggle.
    history.session.tile_cursor = .{ .x = 1, .y = 0 };
    const action = resolveSkillSlotAction(
        &history,
        &history.current_state,
        &history.current_state.level.?,
        4,
        history.current_arena.allocator(),
    );
    try std.testing.expect(action != null);
    try std.testing.expectEqual(
        @as(std.meta.Tag(SkillSlotAction), .use),
        std.meta.activeTag(action.?),
    );
    try std.testing.expectEqual(types.SkillId.flash_strike, action.?.use.skill_id);
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, action.?.use.target.?);
}

test "resolveSkillSlotAction: different prepared skill still prepares" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var history = preparedSkillToggleHistory(&backing, .spinblade);

    const action = resolveSkillSlotAction(
        &history,
        &history.current_state,
        &history.current_state.level.?,
        4,
        history.current_arena.allocator(),
    );
    try std.testing.expect(action != null);
    try std.testing.expectEqual(
        @as(std.meta.Tag(SkillSlotAction), .prepare),
        std.meta.activeTag(action.?),
    );
    try std.testing.expectEqual(types.SkillId.flash_strike, action.?.prepare);
}

test "attack-phase slot press on the prepared skill unprepares it" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var history = preparedSkillToggleHistory(&backing, .flash_strike);
    @import("test_harness.zig").runToIdle(&history);

    handleIdleInput(&history, .{ .skill_slot_selected = 4 }, null, .{});
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try std.testing.expect(history.current_state.event_stack[0].player_input_event == .player_cancel_skill);
    @import("test_harness.zig").runToIdle(&history);

    // Both the preparation and its highlight are cleared - a real change,
    // so undo is a meaningful step (restores both).
    try std.testing.expect(history.current_state.level.?.prepared_skill == null);
    try std.testing.expectEqual(@as(usize, 0), history.current_state.level.?.highlighted_tiles.len);

    try std.testing.expect(history.undo(event_handlers.processEvent));
    try std.testing.expectEqual(types.SkillId.flash_strike, history.current_state.level.?.prepared_skill.?);
    try std.testing.expectEqual(@as(usize, 2), history.current_state.level.?.highlighted_tiles.len);
}

test "hub clicks: own tile and NPC tiles fire nothing, walkable tile moves" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } };
    const npcs = [_]types.NPC{.{
        .npc_type = .gear_upgrader,
        .position = .{ .x = 2, .y = 0 },
    }};
    var history = harness.newHistory(.{
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
            .player = .{ .position = .{ .x = 0, .y = 0 } },
            .npcs = &npcs,
        },
    });
    @import("test_harness.zig").runToIdle(&history);

    // Own tile: a same-position move would be a recorded no-op - no fire.
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 0, .y = 0 } }, null, .{});
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // NPC tile: the interact_with_npc handler is an unimplemented stub -
    // no fire (no recorded no-op).
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 2, .y = 0 } }, null, .{});
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // A walkable other tile: fires move_player and moves.
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 1, .y = 0 } }, null, .{});
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try std.testing.expect(history.current_state.event_stack[0].player_input_event == .move_player);
    @import("test_harness.zig").runToIdle(&history);
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, history.current_state.hub.?.player.position);

    // A non-walkable tile: no fire.
    handleIdleInput(&history, .{ .tile_clicked = .{ .x = 5, .y = 5 } }, null, .{});
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "swap_weapons with both hands empty fires nothing" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const entities = [_]types.Entity{.{ .name = "Player", .team = 0 }};
    const tiles = [_]types.Vector2{.{ .x = 0, .y = 0 }};
    var history = harness.newHistory(@import("test_harness.zig").levelStateWithEntities(
        backing.allocator(),
        &entities,
        &tiles,
    ));
    @import("test_harness.zig").runToIdle(&history);

    // Both hands empty, nothing prepared: the swap would be a recorded
    // no-op - no fire (and no click sound).
    handleAnytimeInput(&history, .{ .in_game = .{ .swap_weapons = true } }, null, .{ .x = 0, .y = 0 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);

    // Positive control: with a main-hand weapon, the swap fires.
    @import("test_harness.zig").levelEntity(&history, 0).main_hand_weapon = .{
        .name = "sword",
        .weapon_type = .sword,
        .weapon_damage = 4,
    };
    handleAnytimeInput(&history, .{ .in_game = .{ .swap_weapons = true } }, null, .{ .x = 0, .y = 0 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try std.testing.expect(history.current_state.event_stack[0].player_input_event == .swap_hands);
}

test "resolveTileCursor: nudge onto a gap jumps to the first tile in the direction" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    // A row with a gap: (0,0), (1,0), then nothing until (5,0). The player
    // stands on (0,0).
    const entities = [_]types.Entity{.{ .name = "Player", .team = 0, .position = .{ .x = 0, .y = 0 } }};
    const tiles = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 5, .y = 0 } };
    var history = harness.newHistory(@import("test_harness.zig").levelStateWithEntities(
        backing.allocator(),
        &entities,
        &tiles,
    ));
    @import("test_harness.zig").runToIdle(&history);
    history.session.tile_cursor = .{ .x = 1, .y = 0 };

    // Right from (1,0): (2,0) is empty - the cursor crosses the gap to
    // (5,0) instead of stopping.
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .move_cursor_right = true,
            .cursor_direction = .{ .x = 1, .y = 0 },
        } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 5, .y = 0 }, history.session.tile_cursor.?);

    // Right from (5,0): no tile in that direction at all - the cursor stays.
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .move_cursor_right = true,
            .cursor_direction = .{ .x = 1, .y = 0 },
        } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 5, .y = 0 }, history.session.tile_cursor.?);

    // Left from (5,0): back across the gap to the adjacent (1,0) on the ray.
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .move_cursor_left = true,
            .cursor_direction = .{ .x = -1, .y = 0 },
        } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, history.session.tile_cursor.?);
}

test "findKeybindSteal: co-firing conflicts + duplicates steal; cross-context is legal" {
    // undo (anytime) + skip (game) on Enter - contexts intersect (they would
    // co-fire): steal. skill_slot_1 (game) + editor_select_tool (editor) on
    // Digit1 - cross-context: LEGAL. undo on KeyZ: the candidate's own row
    // (excluded) never steals; another undo combo on the same combo steals
    // as a redundant duplicate.
    const bindings = [_]types.InputBinding{
        .{ .input = .{ .key = "Enter" }, .action = .undo },
        .{ .input = .{ .key = "Enter" }, .action = .skip },
        .{ .input = .{ .key = "Digit1" }, .action = .skill_slot_1 },
        .{ .input = .{ .key = "Digit1" }, .action = .editor_select_tool },
        .{ .input = .{ .key = "KeyZ" }, .modifiers = .{ .ctrl = true }, .action = .undo },
    };
    // A rekey of undo (index 0) to Enter: co-fires with skip - steal.
    const candidate: types.InputBinding = .{ .input = .{ .key = "Enter" }, .action = .undo };
    try std.testing.expectEqual(@as(?usize, 1), findKeybindSteal(&bindings, candidate, 0));
    // The excluded row itself never steals.
    const self_combo: types.InputBinding = .{ .input = .{ .key = "KeyZ" }, .modifiers = .{ .ctrl = true }, .action = .undo };
    try std.testing.expectEqual(@as(?usize, null), findKeybindSteal(&bindings, self_combo, 4));
    // A same-action duplicate steals (confirming dedupes).
    const duplicate: types.InputBinding = .{ .input = .{ .key = "KeyZ" }, .modifiers = .{ .ctrl = true }, .action = .undo };
    try std.testing.expectEqual(@as(?usize, 4), findKeybindSteal(&bindings, duplicate, 0));
    // Cross-context same-combo is legal - never stolen.
    const cross_context: types.InputBinding = .{ .input = .{ .key = "Digit1" }, .action = .skill_slot_1 };
    try std.testing.expectEqual(@as(?usize, null), findKeybindSteal(&bindings, cross_context, 2));
}

test "keybind confirm/remove: the rebuild-ownership path (leak-checked)" {
    // The rebuild path frees + dupes binding strings via the history's
    // BACKING allocator, so the leak check only fires when the history
    // runs on std.testing.allocator AND the binding strings are
    // SELF-OWNED under it (the overlay-test model - an arena would mask
    // a forgotten free). The harness arena carries only the config
    // bootstrap, untouched by this flow; the history itself runs on
    // testing.allocator, so any allocation anywhere in the confirm/
    // remove flow that isn't freed surfaces at test end - the flow must
    // be pure settings/ui mutation.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const harness = @import("test_harness.zig").Harness.init(backing.allocator());
    var history = state.GameStateHistory.init(
        std.testing.allocator,
        @import("test_harness.zig").defaultStartingState(),
        harness.settings,
        &harness.weapon_type_definitions,
        harness.color_theme_definitions,
        harness.salvage_definitions,
        &harness.file_source,
        harness.file_source.io,
    );

    // Self-owned bindings: escape/Escape, skip/Enter, undo/ctrl+KeyZ.
    const binding_count = 3;
    const owned_bindings = try std.testing.allocator.alloc(types.InputBinding, binding_count);
    owned_bindings[0] = .{
        .input = .{ .key = try std.testing.allocator.dupe(u8, "Escape") },
        .action = .escape,
    };
    owned_bindings[1] = .{
        .input = .{ .key = try std.testing.allocator.dupe(u8, "Enter") },
        .action = .skip,
    };
    owned_bindings[2] = .{
        .input = .{ .key = try std.testing.allocator.dupe(u8, "KeyZ") },
        .modifiers = .{ .ctrl = true },
        .action = .undo,
    };
    history.settings.input_bindings = owned_bindings;

    // --- A rekey that STEALS: keep (row 2 moves) + drop (the stolen row's
    // string + the old slice freed) + replace (the new combo duped onto
    // the replaced row's slot). Listening on row 0 (escape), capture
    // Enter - Enter currently fires skip (game); escape is anytime, so
    // the contexts intersect and the proposal steals row 1.
    history.session.ui_state.keybind_edit = .{
        .edit = .{ .listening = .{ .binding = 0 } },
    };
    history.session.ui_state.keybind_edit.?.capture.store(.key, "Enter", .{});
    resolveKeybindCaptureOutcome(&history, .captured);
    const stolen_proposal = switch (history.session.ui_state.keybind_edit.?.edit) {
        .pending => |proposal| proposal,
        else => return error.TestExpectedPendingProposal,
    };
    try std.testing.expectEqual(@as(?usize, 0), stolen_proposal.replace_index);
    try std.testing.expectEqual(@as(?usize, 1), stolen_proposal.stolen_index);
    resolveKeybindCaptureOutcome(&history, .confirmed);
    try std.testing.expect(history.session.ui_state.keybind_edit == null);
    // REPLACE is drop + append: the rekeyed row moves to the END of the
    // list (the keybinds tab sorts its rows by action, and the conflict
    // rule leaves no co-firing same-combo pair whose order could matter
    // for first-match-wins - list order carries no meaning).
    try std.testing.expectEqual(@as(usize, 2), history.settings.input_bindings.len);
    try std.testing.expectEqualStrings("KeyZ", history.settings.input_bindings[0].input.key);
    try std.testing.expectEqual(types.Action.undo, history.settings.input_bindings[0].action);
    try std.testing.expectEqualStrings("Enter", history.settings.input_bindings[1].input.key);
    try std.testing.expectEqual(types.Action.escape, history.settings.input_bindings[1].action);

    // --- A clean ADD: every row kept, one entry appended (its id duped
    // from the capture buffer into the settings allocation).
    history.session.ui_state.keybind_edit = .{
        .edit = .{ .listening = .{ .add = .skill_slot_1 } },
    };
    history.session.ui_state.keybind_edit.?.capture.store(.key, "KeyQ", .{});
    resolveKeybindCaptureOutcome(&history, .captured);
    const added_proposal = switch (history.session.ui_state.keybind_edit.?.edit) {
        .pending => |proposal| proposal,
        else => return error.TestExpectedPendingProposal,
    };
    try std.testing.expectEqual(@as(?usize, null), added_proposal.replace_index);
    try std.testing.expectEqual(@as(?usize, null), added_proposal.stolen_index);
    resolveKeybindCaptureOutcome(&history, .confirmed);
    try std.testing.expectEqual(@as(usize, 3), history.settings.input_bindings.len);
    try std.testing.expectEqualStrings("KeyQ", history.settings.input_bindings[2].input.key);
    try std.testing.expectEqual(types.Action.skill_slot_1, history.settings.input_bindings[2].action);

    // --- REMOVE a row (its string + the old slice freed); an
    // out-of-range index is a no-op (the gate holds for crafted input).
    removeKeybindBinding(&history, 0);
    removeKeybindBinding(&history, binding_count);
    try std.testing.expectEqual(@as(usize, 2), history.settings.input_bindings.len);
    try std.testing.expectEqualStrings("Enter", history.settings.input_bindings[0].input.key);
    try std.testing.expectEqual(types.Action.escape, history.settings.input_bindings[0].action);
    try std.testing.expectEqualStrings("KeyQ", history.settings.input_bindings[1].input.key);
    try std.testing.expectEqual(types.Action.skill_slot_1, history.settings.input_bindings[1].action);

    // Each mutation marks settings dirty (the mutate + mark-dirty
    // discipline) - one debounced settings write is pending.
    var settings_write_pending = false;
    for (history.session.pending_writes) |slot| {
        if (slot) |entry| {
            if (entry.tag == .settings) settings_write_pending = true;
        }
    }
    try std.testing.expect(settings_write_pending);

    // Teardown balances the ownership ledger: the final list's kept
    // entries MOVED from the self-owned set, the replaced/added entries
    // were duped by the rebuild, and the slice is rebuild-allocated -
    // freeSettings frees exactly those under testing.allocator. Any
    // imbalance (a rebuild that forgot a free, freed a moved string, or
    // leaked the slice) fails the leak check at test end.
    loaders.freeSettings(history.settings, std.testing.allocator);
}

test "resetSettingsToDefaults: full reset + flush-then-copy settings backup" {
    // The full-settings reset: every preference + the binding set replaced
    // by the embedded defaults; the backup is a flush-then-copy of
    // settings.txt (the exact pre-reset bytes) to a timestamped sibling.
    // The history runs on std.testing.allocator (the keybind-edit test's
    // leak-checked model - the handler's alloc/free ledger must balance).
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const harness = @import("test_harness.zig").Harness.init(backing.allocator());
    var history = state.GameStateHistory.init(
        std.testing.allocator,
        @import("test_harness.zig").defaultStartingState(),
        harness.settings,
        &harness.weapon_type_definitions,
        harness.color_theme_definitions,
        harness.salvage_definitions,
        &harness.file_source,
        harness.file_source.io,
    );

    // Custom settings to be destroyed: non-default values + a self-owned
    // binding set + an active keybind edit on a scrolled keybinds tab.
    const owned_bindings = try std.testing.allocator.alloc(types.InputBinding, 1);
    owned_bindings[0] = .{
        .input = .{ .key = try std.testing.allocator.dupe(u8, "KeyX") },
        .action = .dump_event_log,
    };
    history.settings.input_bindings = owned_bindings;
    history.settings.music_volume = 10;
    history.settings.show_fps = true;
    history.settings.camera_zoom = 100;
    history.session.ui_state.settings_tab = .keybinds;
    history.session.ui_state.keybind_scroll_offset = 7;
    history.session.ui_state.keybind_edit = .{ .edit = .{ .listening = .{ .binding = 0 } } };

    // The expected backup bytes: the exact pre-reset serialization (the
    // flush writes the same bytes to settings.txt before the copy).
    const expected_bytes = try writers.writeSettings(history.settings, std.testing.allocator);
    defer std.testing.allocator.free(expected_bytes);

    // Backup-name candidates: the timestamp second the handler runs in,
    // formatted before AND after the call so a second boundary crossing
    // mid-handler can't flake the lookup.
    const timestamp_before = session_log.formatSessionTimestamp(std.testing.allocator, history.file_source.io);
    defer std.testing.allocator.free(timestamp_before);

    resetSettingsToDefaults(&history);

    const timestamp_after = session_log.formatSessionTimestamp(std.testing.allocator, history.file_source.io);
    defer std.testing.allocator.free(timestamp_after);

    // Full reset: preferences back at the shipped defaults + the default
    // binding set (derived from the same embedded file the handler loads).
    {
        const bytes = history.file_source.readEmbeddedFile(std.testing.allocator, "data/default_settings.txt") catch return error.TestUnexpectedError;
        defer std.testing.allocator.free(bytes);
        const sections = parser.parseConfigFile(bytes, std.testing.allocator) catch return error.TestUnexpectedError;
        defer parser.freeParsedSections(sections, std.testing.allocator);
        const defaults = loaders.loadSettings(sections, std.testing.allocator, null, null) catch return error.TestUnexpectedError;
        defer loaders.freeSettings(defaults, std.testing.allocator);
        try std.testing.expectEqual(defaults.music_volume, history.settings.music_volume);
        try std.testing.expectEqual(defaults.show_fps, history.settings.show_fps);
        try std.testing.expectEqual(defaults.camera_zoom, history.settings.camera_zoom);
        try std.testing.expectEqual(defaults.input_bindings.len, history.settings.input_bindings.len);
        for (defaults.input_bindings, history.settings.input_bindings) |expected, actual| {
            try std.testing.expect(std.meta.eql(expected.modifiers, actual.modifiers));
            try std.testing.expectEqual(expected.action, actual.action);
            const expected_id = switch (expected.input) {
                .key => |id| id,
                .mouse_button => |id| id,
                .gamepad_button => |id| id,
            };
            const actual_id = switch (actual.input) {
                .key => |id| id,
                .mouse_button => |id| id,
                .gamepad_button => |id| id,
            };
            try std.testing.expectEqualStrings(expected_id, actual_id);
        }
    }

    // The editing state clears with the settings.
    try std.testing.expect(history.session.ui_state.keybind_edit == null);
    try std.testing.expectEqual(@as(i32, 0), history.session.ui_state.keybind_scroll_offset);

    // The synchronous flush landed: settings.txt holds the exact pre-reset
    // bytes.
    {
        const on_disk = history.file_source.readFile(std.testing.allocator, "settings.txt") catch return error.TestUnexpectedError;
        defer std.testing.allocator.free(on_disk);
        try std.testing.expectEqualSlices(u8, expected_bytes, on_disk);
    }

    // The backup: one of the two timestamp-second candidates exists and
    // holds the same pre-reset bytes.
    var backup_seen = false;
    for ([_][]const u8{ timestamp_before, timestamp_after }) |timestamp| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "settings-backup-{s}.txt", .{timestamp});
        defer std.testing.allocator.free(path);
        const backup_bytes = history.file_source.readFile(std.testing.allocator, path) catch continue;
        defer std.testing.allocator.free(backup_bytes);
        try std.testing.expectEqualSlices(u8, expected_bytes, backup_bytes);
        backup_seen = true;
    }
    try std.testing.expect(backup_seen);

    // The reset marks the debounced settings write (the mutate + mark-dirty
    // discipline).
    var settings_write_pending = false;
    for (history.session.pending_writes) |slot| {
        if (slot) |entry| {
            if (entry.tag == .settings) settings_write_pending = true;
        }
    }
    try std.testing.expect(settings_write_pending);

    // Teardown: the fresh bindings are history-owned under
    // testing.allocator - freeSettings balances the ledger.
    loaders.freeSettings(history.settings, std.testing.allocator);
}

test "the skip action layers exactly once (the consumption site, not the choke point)" {
    // Regression: `.skip` was missing from `actionLayerRidesConsumptionSite`,
    // so a skip queued its layer at BOTH the fired-actions choke point and
    // the skip orchestrator handler - two plays per skip. On fast native
    // the two plays landed in one frame's playSounds (two pool entries
    // overlapping almost perfectly - one louder blip, not hearable); on
    // web the orchestrator often drains a frame later (budget + waits), so
    // the two plays were separated - "the skip sound repeated quickly",
    // the shipped web skip burst. The live-path pin: applyAction records
    // the firing, the choke point dispatches (skip excluded - it rides the
    // consumption site), idle input consumes the skip, and the drain queues
    // EXACTLY ONE skip layer cue.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());
    var history = harness.newHistory(@import("test_harness.zig").levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } },
    ));
    @import("test_harness.zig").runToIdle(&history);
    history.current_state.level.?.turn_phase = .player_attack;

    var player_input = input.PlayerInput{};
    input.applyAction(&player_input, .skip);
    dispatchFiredActionSounds(&history, player_input.fired_actions);
    handleIdleInput(&history, player_input.idle, null, .{});
    @import("test_harness.zig").runToIdle(&history);

    // Exactly ONE skip layer cue total (the consumption site's).
    var skip_layers: usize = 0;
    for (history.session.pending_sounds.items) |cue| {
        if (cue.layer) |layer| switch (layer) {
            .action => |action| {
                if (action == .skip) skip_layers += 1;
            },
            else => {},
        };
    }
    try std.testing.expectEqual(@as(usize, 1), skip_layers);
}

test "dispatchFiredActionSounds: one layer per fired action, exclusions silent" {
    // The per-action sound choke point: exactly ONE action layer per
    // fired action, and only for the non-excluded classes. The
    // `.change_setting` DOUBLE-PLAY (the options_action top-of-switch
    // queue + the arm's own queue - two layers per click) shipped for
    // months because only ears could catch it; this pins it headless.
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());
    var history = harness.newHistory(null);

    // A same-frame keybind + button + console command on ONE action fires
    // applyAction repeatedly - the set dedupes, one layer.
    var player_input = input.PlayerInput{};
    input.applyAction(&player_input, .change_setting);
    input.applyAction(&player_input, .change_setting);
    input.applyAction(&player_input, .toggle_inventory);
    // Exclusions: the unwired set (a dropped layer file must stay silent)
    // and the outcome-gated set (their layer rides the consumption site).
    input.applyAction(&player_input, .zoom_in);
    input.applyAction(&player_input, .skip_level);
    input.applyAction(&player_input, .undo);
    input.applyAction(&player_input, .swap_weapons);
    input.applyAction(&player_input, .skip);

    dispatchFiredActionSounds(&history, player_input.fired_actions);

    // One layer cue per non-excluded fired action, and nothing else -
    // layer alone, no base (keys stay click-sound-free).
    const sounds = history.session.pending_sounds.items;
    try std.testing.expectEqual(@as(usize, 2), sounds.len);
    var seen_change_setting = false;
    var seen_toggle_inventory = false;
    for (sounds) |cue| {
        try std.testing.expect(cue.base == null);
        const layer = cue.layer orelse return error.TestExpectedLayerCue;
        switch (layer) {
            .action => |action| switch (action) {
                .change_setting => seen_change_setting = true,
                .toggle_inventory => seen_toggle_inventory = true,
                else => return error.TestUnexpectedActionLayer,
            },
            else => return error.TestUnexpectedLayerKind,
        }
    }
    try std.testing.expect(seen_change_setting);
    try std.testing.expect(seen_toggle_inventory);
}

test "resolveTileCursor: rollover press nudges by the pressed direction; repeats keep the frozen cancel" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    // A 5-wide row; the cursor starts on (1,0) (the position a right
    // press just moved it to).
    const entities = [_]types.Entity{.{ .name = "Player", .team = 0, .position = .{ .x = 0, .y = 0 } }};
    const tiles = [_]types.Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
        .{ .x = 3, .y = 0 }, .{ .x = 4, .y = 0 },
    };
    var history = harness.newHistory(@import("test_harness.zig").levelStateWithEntities(
        backing.allocator(),
        &entities,
        &tiles,
    ));
    @import("test_harness.zig").runToIdle(&history);
    history.session.tile_cursor = .{ .x = 1, .y = 0 };

    // ROLLOVER: the left edge fires while right is still held - the held
    // vector cancels to zero, the press direction carries the intent, and
    // the cursor moves LEFT. This is the fast-input shape the held-vector
    // model swallowed whole (the press edge consumed into a zero vector,
    // never re-fired on the opposite's release).
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .move_cursor_left = true,
            .cursor_direction = .{ .x = 0, .y = 0 },
            .cursor_press_direction = .{ .x = -1, .y = 0 },
        } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 0, .y = 0 }, history.session.tile_cursor.?);

    // REPEATS ONLY: a synthetic repeat edge with both opposites held (a
    // deliberate freeze) - no real press, so the cancel holds and the
    // cursor stays put. The fallback must not oscillate on per-key
    // repeat-timer drift.
    history.session.tile_cursor = .{ .x = 2, .y = 0 };
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .move_cursor_left = true,
            .cursor_direction = .{ .x = 0, .y = 0 },
            .cursor_press_direction = .{ .x = 0, .y = 0 },
        } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 2, .y = 0 }, history.session.tile_cursor.?);

    // A NONZERO held vector ignores the press direction entirely (the
    // diagonal-derive model unchanged): up held + left pressed nudges
    // diagonally, not by the press axis alone.
    history.session.tile_cursor = .{ .x = 2, .y = 1 };
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .move_cursor_left = true,
            .cursor_direction = .{ .x = -1, .y = -1 },
            .cursor_press_direction = .{ .x = -1, .y = 0 },
        } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 0 }, history.session.tile_cursor.?);
}

test "resolveEditorTileCursor: rollover press nudges by the pressed direction (same fallback)" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());

    const levels = [_]types.EditorLevel{.{ .player_start = .{ .x = 2, .y = 3 } }};
    var history = harness.newHistory(.{
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
    });
    history.current_state.editor.?.active_tool = .tile;

    // Null cursor + a rollover left press (right still held): snap to
    // player_start, then nudge by the PRESS direction - unclamped (empty
    // space is a legal paint target).
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .move_cursor_left = true,
            .cursor_direction = .{ .x = 0, .y = 0 },
            .cursor_press_direction = .{ .x = -1, .y = 0 },
        } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 3 }, history.session.tile_cursor.?);

    // Repeats only (both held, no real press): the frozen cancel holds.
    resolveTileCursor(
        &history,
        .{ .anytime = .{ .in_game = .{
            .move_cursor_right = true,
            .cursor_direction = .{ .x = 0, .y = 0 },
            .cursor_press_direction = .{ .x = 0, .y = 0 },
        } } },
        &.{},
    );
    try std.testing.expectEqual(types.Vector2{ .x = 1, .y = 3 }, history.session.tile_cursor.?);
}
