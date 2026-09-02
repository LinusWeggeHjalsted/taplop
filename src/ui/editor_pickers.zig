//! The editor's centered pickers: the utility-skill picker, the sprite
//! picker (Mission/Official tabs, entity + decoration + layer modes), the
//! level-theme gradient picker, and the footprint tile-grid editor — all
//! rendered in the one fixed overlay rect between the sidebars (see
//! DESIGN → Level Editor → Editor UI layout — the picker overlay). The
//! official sprite tables (comptime from the sprite metadata) live here.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const emit = @import("emit.zig");
const shell = @import("editor_shell.zig");
const inspector = @import("editor_inspector.zig");
const ui_state_mod = @import("state.zig");
const utility_skills = @import("../utility_skills.zig");
const lookups = @import("../generated_lookups.zig");
const loaders = @import("../loaders.zig");
const sprite_metadata = @import("generated_sprite_metadata");
const state = @import("../state.zig");

const Action = types.Action;
const Rectangle = types.Rectangle;
const Color = types.Color;
const UiState = ui_state_mod.UiState;
const editor_footprint_grid_cell_limit = ui_state_mod.editor_footprint_grid_cell_limit;
const EditorPickerTarget = ui_state_mod.EditorPickerTarget;
const ScreenPosition = types.ScreenPosition;
const Span = ui_element.Span;
const Tooltip = ui_element.Tooltip;
const text = ui_element.text;
const colored = ui_element.colored;
const FontMetrics = ui_element.FontMetrics;
const UiElement = ui_element.UiElement;
const UiElementList = ui_element.UiElementList;
const Button = ui_element.Button;
const Image = ui_element.Image;
const SolidRect = ui_element.SolidRect;
const slot_size = ui_element.slot_size;
const ui_gap = ui_element.ui_gap;
const slot_padding = ui_element.slot_padding;
const small_icon_size = ui_element.small_icon_size;
const default_tint = ui_element.default_tint;
const close_button_size = ui_element.close_button_size;
const scaleToFit = shell.scaleToFit;
const emitPanelHeader = emit.emitPanelHeader;
const emitIconButton = emit.emitIconButton;
const emitPanelButton = emit.emitPanelButton;
const skillIconSpriteId = emit.skillIconSpriteId;
const editorPickerOverlayRect = inspector.editorPickerOverlayRect;
const editorInspectorTarget = inspector.editorInspectorTarget;
const InspectorEntityContext = inspector.InspectorEntityContext;
const InspectorDecorationContext = inspector.InspectorDecorationContext;
const emitInspectorLayerButton = inspector.emitInspectorLayerButton;
const GameState = state.GameState;
const editor_entity_frame_width = shell.editor_entity_frame_width;
const middle_panel_header_height = ui_element.middle_panel_header_height;
const button_background_sprite_id = emit.button_background_sprite_id;
const buildSkillTooltip = @import("tooltip.zig").buildSkillTooltip;
const allInspectorSectionsExpanded = inspector.allInspectorSectionsExpanded;
const editor_entity_frame_height = shell.editor_entity_frame_height;
const editor_inspector_row_height = inspector.editor_inspector_row_height;
const spanRow = @import("tooltip.zig").spanRow;
const buildEditorInspectorPanel = inspector.buildEditorInspectorPanel;
const TextLabel = ui_element.TextLabel;
const middle_panel_header_font_size = ui_element.middle_panel_header_font_size;
const editor_group_header_font_size = shell.editor_group_header_font_size;
const close_button_sprite_id = ui_element.close_button_sprite_id;

/// The OFFICIAL enemy sprites (shipped `assets/entities/*.png`) as bare
/// stems — the sprite picker's Official tab. The player body is EXCLUDED
/// (the player sprite isn't an enemy base-sprite option). Comptime from
/// the sprite-metadata table; sorted for a stable picker order.
const official_entity_sprite_stems: []const []const u8 = build: {
    var stems: []const []const u8 = &.{};
    for (sprite_metadata.map.kvs.keys[0..sprite_metadata.map.kvs.len]) |key| {
        if (!std.mem.startsWith(u8, key, "entities/")) continue;
        if (std.mem.eql(u8, key, "entities/player")) continue;
        const stem = key["entities/".len..];
        // Insert in sorted position (comptime slices have const elements —
        // no in-place sort).
        var insert_index: usize = 0;
        while (insert_index < stems.len and std.mem.lessThan(u8, stems[insert_index], stem)) : (insert_index += 1) {}
        stems = stems[0..insert_index] ++ [_][]const u8{stem} ++ stems[insert_index..];
    }
    break :build stems;
};

/// One shipped decoration sprite (stem + pixel dims) for the picker's
/// layer-mode Official tab.
const OfficialDecorationSprite = struct {
    stem: []const u8,
    width: i32,
    height: i32,
};

/// The OFFICIAL decoration sprites (shipped `assets/decorations/*.png`) as
/// stems + pixel dims — the sprite picker's LAYER-mode Official tab (the
/// base-sprite mode lists the registry prefabs instead). Comptime from
/// the sprite-metadata table; a malformed dims string is a build bug.
const official_decoration_sprites: []const OfficialDecorationSprite = build: {
    @setEvalBranchQuota(20000);
    var list: []const OfficialDecorationSprite = &.{};
    for (sprite_metadata.map.kvs.keys[0..sprite_metadata.map.kvs.len]) |key| {
        if (!std.mem.startsWith(u8, key, "decorations/")) continue;
        const stem = key["decorations/".len..];
        const dims = sprite_metadata.map.get(key).?;
        const space = std.mem.indexOfScalar(u8, dims, ' ').?;
        const width = std.fmt.parseInt(i32, dims[0..space], 10) catch
            @compileError("malformed sprite dims string");
        const height = std.fmt.parseInt(i32, dims[space + 1 ..], 10) catch
            @compileError("malformed sprite dims string");
        var insert_index: usize = 0;
        while (insert_index < list.len and std.mem.lessThan(u8, list[insert_index].stem, stem)) : (insert_index += 1) {}
        list = list[0..insert_index] ++
            [_]OfficialDecorationSprite{.{ .stem = stem, .width = width, .height = height }} ++
            list[insert_index..];
    }
    break :build list;
};

/// The centered utility-skill picker (the picker framework's first
/// consumer — see DESIGN → Architecture → Level Editor → Editor UI
/// layout). A modal panel: the None option + one cell per
/// utility-eligible skill (the flat list from src/utility_skills.zig —
/// weapon skills are never offered), 4-wide skill-button cells with the
/// icon + name; the currently-assigned skill is highlighted; a close
/// button top-right (the middle-panel convention). `target` names the
/// slot being assigned.
pub fn buildEditorSkillPicker(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    target: EditorPickerTarget,
    active_theme: types.ActiveColorTheme,
) !void {
    const slot_index = switch (target) {
        .utility_skill_slot => |index| index,
        // The sprite/footprint/theme targets aren't this picker's (the
        // view dispatches on the target); defensive for crafted calls.
        .entity_sprite, .decoration_sprite, .entity_layer, .decoration_layer, .decoration_footprint, .level_gradient => return,
    };
    var current: ?types.SkillId = null;
    if (slot_index < types.utility_skill_count) {
        current = switch (editorInspectorTarget(editor)) {
            .entity_type => |type_index| if (type_index < editor.entity_types.len)
                editor.entity_types[type_index].template.equipped_utility_skills[slot_index]
            else
                null,
            .player => editor.player_def.template.equipped_utility_skills[slot_index],
            // No utility-skill row in the decoration or item content —
            // nothing to show as current (defensive; the picker never
            // opens on either).
            .decoration_type, .item_type => null,
        };
    }

    // The FIXED picker overlay (the band between the sidebars) + a
    // FIXED-SIZE grid: 6 columns of `slot_size` cells, centered in the
    // area below the header (top-aligned if it ever outgrows it). The
    // overlay never resizes with its content — see
    // `editorPickerOverlayRect`.
    const options: i32 = @intCast(1 + utility_skills.utility_skill_ids.len); // None + skills
    const columns: i32 = 6;
    const rows: i32 = @divTrunc(options + columns - 1, columns);
    const cell = slot_size;
    const bounds = editorPickerOverlayRect();

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
        .color = active_theme.darkest,
    } });
    const title = try std.fmt.allocPrint(allocator, "Assign Slot {d}", .{slot_index + 4});
    const content = try emitPanelHeader(elements, allocator, bounds, title, .close_editor_picker);

    // The entity-inspect panel's skill coloring convention: frame at the
    // team gradient's index 3, icon at index 1 — the enemy gradient here
    // (the picker edits an enemy type).
    const enemy = active_theme.enemy_gradient.colors;
    const skill_frame_color = enemy[@min(@as(u32, 3), types.gradient_color_count - 1)];
    const skill_icon_color = enemy[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const grid_width = columns * cell + (columns - 1) * ui_gap;
    const grid_height = rows * cell + (rows - 1) * ui_gap;
    const grid_origin: ScreenPosition = .{
        .x = content.x + @divFloor(content.width - grid_width, 2),
        .y = content.y + @max(ui_gap, @divFloor(content.height - grid_height, 2)),
    };

    // Cell 0: the None option (clears the slot) — no editor_skill payload;
    // the one cell that carries a text label.
    try emitPickerSkillCell(
        elements,
        allocator,
        font_metrics,
        .{ .x = grid_origin.x, .y = grid_origin.y, .width = cell, .height = cell },
        null,
        "None",
        "ui/skill_slot_empty",
        current == null,
        skill_frame_color,
        skill_icon_color,
        active_theme.lightest,
    );
    // One cell per utility skill, in enum order (index + 1: cell 0 is
    // None). Icon-only — the icon is the identity at full cell size; the
    // tooltip carries the name.
    for (utility_skills.utility_skill_ids, 0..) |skill_id, index| {
        const definition = lookups.getSkillDefinition(skill_id) orelse continue;
        const column: i32 = @intCast((index + 1) % @as(usize, @intCast(columns)));
        const row: i32 = @intCast((index + 1) / @as(usize, @intCast(columns)));
        const cell_rect: Rectangle = .{
            .x = grid_origin.x + column * (cell + ui_gap),
            .y = grid_origin.y + row * (cell + ui_gap),
            .width = cell,
            .height = cell,
        };
        try emitPickerSkillCell(
            elements,
            allocator,
            font_metrics,
            cell_rect,
            skill_id,
            definition.name,
            "ui/skill_button",
            current == skill_id,
            skill_frame_color,
            skill_icon_color,
            active_theme.lightest,
        );
    }
}

/// The centered SPRITE picker (the picker framework's second consumer):
/// pick the edited entity type's base sprite. Two tabs top-left — Mission
/// (the .pngs scanned from the mission directory, stored as namespaced
/// `custom/<mission-dir>/<stem>` ids) and Official (the shipped entity
/// sprites, minus the player body); close top-right. One 256×256 cell per
/// option (the palette tool-cell look). Dropdown semantics like the skill
/// picker: blocks only where it sits, stays open until a pick or close.
/// No scrolling — 6 fixed columns, all rows (overflow is a follow-up if
/// real content needs it).
pub fn buildEditorSpritePicker(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    mission_sprites: []const []const u8,
    decoration_registry: []const types.DecorationTypeDef,
    picker_target: EditorPickerTarget,
    tab: types.EditorSpritePickerTab,
) !void {
    // What the picker is picking: a BASE sprite (entity / decoration) or
    // a LAYER sprite (entity / decoration — the layer index rides the
    // picker target, null = add-new; the skill picker's slot pattern).
    // The base modes resolve through the inspector target; a skill-slot
    // target is the skill picker's own builder (the view dispatches).
    const PickerKind = enum { entity_base, decoration_base, entity_layer, decoration_layer };
    const picker_kind: PickerKind = switch (picker_target) {
        .utility_skill_slot, .decoration_footprint, .level_gradient => return,
        .entity_sprite => .entity_base,
        .decoration_sprite => .decoration_base,
        .entity_layer => .entity_layer,
        .decoration_layer => .decoration_layer,
    };
    const layer_mode = picker_kind == .entity_layer or picker_kind == .decoration_layer;
    const layer_index: ?u32 = switch (picker_target) {
        .entity_layer => |index| index,
        .decoration_layer => |index| index,
        else => null,
    };

    // The edited definition (highlight target + tint source) — the target
    // resolution's single seam, same as the skill picker. Entity content
    // tints with the enemy gradient; decoration content with the WORLD
    // gradient (the in-game decoration tinting). The player target keeps
    // the entity shape (the player has no sprite/layer rows, so the
    // picker only opens on it via a stale open — picks commit nothing).
    // The item target has no sprite either — nothing to pick (defensive;
    // the picker never opens on it).
    const target = editorInspectorTarget(editor);
    if (target == .item_type) return;
    const entity_context: ?InspectorEntityContext = switch (target) {
        .entity_type => |index| .{
            .template = editor.entity_types[index].template,
            .edit_target = .{ .entity_type = index },
            .gradient_colors = active_theme.enemy_gradient.colors,
        },
        .player => .{
            .template = editor.player_def.template,
            .edit_target = .player_def,
            .gradient_colors = active_theme.player_gradient.colors,
        },
        .decoration_type, .item_type => null,
    };
    const decoration_context: ?InspectorDecorationContext = switch (target) {
        .decoration_type => |index| .{
            .type_definition = editor.decoration_types[index],
        },
        .entity_type, .player, .item_type => null,
    };
    const base_sprite: []const u8 = if (decoration_context) |context|
        context.type_definition.sprite
    else
        entity_context.?.template.sprite;
    const base_color_index: u32 = if (decoration_context) |context|
        context.type_definition.color_index
    else
        entity_context.?.template.color_index;
    // In layer-EDIT mode the edited layer is the highlight target + tint
    // source; ADD mode highlights nothing and tints with the base. A
    // stale state — the layer index out of range, or the picker kind
    // mismatched with the target (the tool switched mid-open; the
    // dropdown stays open by design) — also falls back to the base
    // values, and every pick no-ops at the commit gate.
    const edited_layer_sprite: ?[]const u8 = blk: {
        const index = layer_index orelse break :blk null;
        if (picker_kind == .entity_layer) {
            const context = entity_context orelse break :blk null;
            if (index >= context.template.layers.len) break :blk null;
            break :blk context.template.layers[index].sprite;
        }
        const context = decoration_context orelse break :blk null;
        if (index >= context.type_definition.layers.len) break :blk null;
        break :blk context.type_definition.layers[index].sprite;
    };
    const edited_layer_color_index: ?u32 = blk: {
        const index = layer_index orelse break :blk null;
        if (picker_kind == .entity_layer) {
            const context = entity_context orelse break :blk null;
            if (index >= context.template.layers.len) break :blk null;
            break :blk context.template.layers[index].color_index;
        }
        const context = decoration_context orelse break :blk null;
        if (index >= context.type_definition.layers.len) break :blk null;
        break :blk context.type_definition.layers[index].color_index;
    };
    const gradient = if (picker_kind == .decoration_base or picker_kind == .decoration_layer)
        active_theme.world_gradient.colors
    else
        active_theme.enemy_gradient.colors;
    const current_sprite: ?[]const u8 = if (layer_mode) edited_layer_sprite else base_sprite;
    const current_color_index: u32 = edited_layer_color_index orelse base_color_index;
    const graphic_color = gradient[@min(current_color_index, types.gradient_color_count - 1)];
    const button_color = gradient[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const pick_action: types.Action = switch (picker_kind) {
        .entity_base => .select_editor_entity_sprite,
        .decoration_base => .select_editor_decoration_sprite,
        .entity_layer => .select_editor_entity_layer,
        .decoration_layer => .select_editor_decoration_layer,
    };

    // One cell per offered sprite, built per frame into the frame arena:
    // the stored id (a bare stem or a namespaced `custom/<mission>/<stem>`),
    // the cell label, the renderable graphic (null = a text-only cell —
    // custom art isn't renderable yet), and the graphic's aspect-fit
    // frame. The Official tab's list differs per kind: the shipped entity
    // sprites (base + layer — a layer may be any entity art, the fixed
    // 512×640 frame), the registry prefabs (decoration base — each pick
    // adopts the whole prefab), or the shipped decoration sprites
    // FILTERED to the base type's dims (decoration layers must match
    // their base — the load-time invariant; mismatched art is never
    // offered). Mission-local art is the same list for every kind (dims
    // are checked at the pick commit).
    const PickerCell = struct {
        stored_id: []const u8,
        label: []const u8,
        graphic_id: ?[]const u8,
        frame_width: i32,
        frame_height: i32,
    };
    var cells: std.ArrayList(PickerCell) = .empty;
    const mission_directory = missionDirectoryName(editor.mission.path);
    switch (tab) {
        .mission_local => {
            for (mission_sprites) |file_name| {
                const stem = file_name[0 .. std.mem.lastIndexOfScalar(u8, file_name, '.') orelse file_name.len];
                try cells.append(allocator, .{
                    .stored_id = try std.fmt.allocPrint(
                        allocator,
                        "custom/{s}/{s}",
                        .{ mission_directory, stem },
                    ),
                    .label = stem,
                    .graphic_id = null,
                    .frame_width = editor_entity_frame_width,
                    .frame_height = editor_entity_frame_height,
                });
            }
        },
        .official => switch (picker_kind) {
            .entity_base, .entity_layer => {
                for (official_entity_sprite_stems) |stem| {
                    try cells.append(allocator, .{
                        .stored_id = stem,
                        .label = stem,
                        .graphic_id = try std.fmt.allocPrint(allocator, "entities/{s}", .{stem}),
                        .frame_width = editor_entity_frame_width,
                        .frame_height = editor_entity_frame_height,
                    });
                }
            },
            .decoration_base => {
                for (decoration_registry) |definition| {
                    try cells.append(allocator, .{
                        .stored_id = definition.sprite,
                        .label = definition.sprite,
                        .graphic_id = try std.fmt.allocPrint(
                            allocator,
                            "decorations/{s}",
                            .{definition.sprite},
                        ),
                        .frame_width = definition.pixel_dims.x,
                        .frame_height = definition.pixel_dims.y,
                    });
                }
            },
            .decoration_layer => {
                // A stale open on a non-decoration target: no base dims to
                // match against — no cells ("No sprites"), picks no-op.
                if (decoration_context) |context| {
                    const base_dims = context.type_definition.pixel_dims;
                    for (official_decoration_sprites) |sprite| {
                        if (sprite.width != base_dims.x or sprite.height != base_dims.y) continue;
                        try cells.append(allocator, .{
                            .stored_id = sprite.stem,
                            .label = sprite.stem,
                            .graphic_id = try std.fmt.allocPrint(
                                allocator,
                                "decorations/{s}",
                                .{sprite.stem},
                            ),
                            .frame_width = sprite.width,
                            .frame_height = sprite.height,
                        });
                    }
                }
            },
        },
    }
    // The FIXED picker overlay (the band between the sidebars) + a
    // FIXED-SIZE grid: 6 columns of `slot_size` cells, centered in the
    // area below the header (top-aligned if it ever outgrows it). The
    // overlay never resizes with its content — see
    // `editorPickerOverlayRect`.
    const columns: i32 = 6;
    const rows: i32 = @max(@divTrunc(@as(i32, @intCast(cells.items.len)) + columns - 1, columns), 1);
    const cell = slot_size;
    const bounds = editorPickerOverlayRect();

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
        .color = active_theme.darkest,
    } });

    // The header: tab buttons top-left, close top-right (no title — the
    // tabs ARE the header). Tab state is UiState (a view affordance).
    const origin = bounds.position();
    const tab_specs = [_]struct { tab: types.EditorSpritePickerTab, label: []const u8 }{
        .{ .tab = .mission_local, .label = "Mission" },
        .{ .tab = .official, .label = "Official" },
    };
    var tab_x = origin.x + ui_gap;
    for (tab_specs) |spec| {
        const label_width = font_metrics.measureSpanWidth(text(spec.label), middle_panel_header_font_size);
        const tab_width = label_width + 2 * ui_gap;
        const active = spec.tab == tab;
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = .{ .x = tab_x, .y = origin.y },
            .width = tab_width,
            .height = middle_panel_header_height,
            // Darkest always (the background-panel class) — the active
            // tab's highlight outline is the indication, no tint change.
            .color = active_theme.darkest,
        } });
        try elements.append(allocator, .{ .button = .{
            .screen_position = .{ .x = tab_x, .y = origin.y },
            .width = tab_width,
            .height = middle_panel_header_height,
            .action = .select_editor_sprite_tab,
            .editor_sprite_tab = spec.tab,
            .highlighted = active,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = spec.label,
            .screen_position = .{
                .x = tab_x + ui_gap,
                .y = origin.y + @divFloor(middle_panel_header_height - middle_panel_header_font_size, 2),
            },
            .font_size = middle_panel_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        tab_x += tab_width + ui_gap;
    }
    try elements.append(allocator, .{ .button = .{
        .sprite_id = close_button_sprite_id,
        .screen_position = .{
            .x = origin.x + bounds.width - close_button_size,
            .y = origin.y,
        },
        .width = close_button_size,
        .height = close_button_size,
        .action = .close_editor_picker,
    } });
    const content: Rectangle = .{
        .x = bounds.x,
        .y = bounds.y + middle_panel_header_height,
        .width = bounds.width,
        .height = bounds.height - middle_panel_header_height,
    };

    // The edited template's colors were resolved above (the target's
    // single seam) — nothing further to derive here. The grid is centered
    // horizontally (fixed 6-column width), top-anchored below the header
    // with the vertical centering clamp.
    const grid_width = columns * cell + (columns - 1) * ui_gap;
    const grid_height = rows * cell + (rows - 1) * ui_gap;
    const grid_origin: ScreenPosition = .{
        .x = content.x + @divFloor(content.width - grid_width, 2),
        .y = content.y + @max(ui_gap, @divFloor(content.height - grid_height, 2)),
    };

    if (cells.items.len == 0) {
        try elements.append(allocator, .{ .text_label = .{
            .text = "No sprites",
            .screen_position = grid_origin,
            .font_size = editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        return;
    }

    for (cells.items, 0..) |picker_cell, index| {
        const column: i32 = @intCast(index % @as(usize, @intCast(columns)));
        const row: i32 = @intCast(index / @as(usize, @intCast(columns)));
        const cell_rect: Rectangle = .{
            .x = grid_origin.x + column * (cell + ui_gap),
            .y = grid_origin.y + row * (cell + ui_gap),
            .width = cell,
            .height = cell,
        };
        // Nothing highlighted in layer-ADD mode (no current layer); a
        // stale layer index likewise highlights nothing.
        const highlighted = if (current_sprite) |sprite|
            std.mem.eql(u8, sprite, picker_cell.stored_id)
        else
            false;
        try emitPickerSpriteCell(
            elements,
            allocator,
            font_metrics,
            cell_rect,
            picker_cell.stored_id,
            picker_cell.label,
            picker_cell.graphic_id,
            graphic_color,
            button_color,
            highlighted,
            active_theme.lightest,
            pick_action,
            picker_cell.frame_width,
            picker_cell.frame_height,
        );
    }
}

/// The decoration FOOTPRINT editor (the `.decoration_footprint` picker):
/// a centered panel showing the type's sprite FULL-SIZE (1:1 — 256 screen
/// px per sprite-grid tile) with one toggleable cell per tile, a
/// continuous WHITE outline around the draft-selected region (the
/// placement preview's region-edge style — 8px bars centered on the
/// boundary, seamless at corners), a close button top-right (discard),
/// and a Confirm button bottom-center. The draft rides
/// `UiState.editor_footprint_draft`; the type id rides the picker target
/// (see the union). Custom-stem art isn't renderable yet — its cells get
/// a dark fill so the grid stays visible.
/// The metadata sidebar's THEME PICKER (the `.level_gradient` target):
/// a centered panel listing every gradient in `color_themes.txt` as a
/// full-width swatch strip — one row per gradient, bare strips (no
/// labels — the colors ARE the content), a close button top-right. The
/// row for the level's CURRENT index (the world pick, or the override —
/// the DERIVED index while a role is on auto) carries a lightest frame
/// (the unified 8px outline convention). A pick commits through the
/// slice-1 player wrappers (same-value picks close without recording;
/// an auto-role pick flips it to manual — see the input arm). Dropdown
/// semantics like every editor picker: blocks only where it sits.
pub fn buildEditorThemePicker(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    color_theme_definitions: types.ColorThemeDefinitions,
    active_theme: types.ActiveColorTheme,
    target: struct { level_index: u32, role: types.LevelGradientRole },
) !void {
    _ = font_metrics;
    const gradients = color_theme_definitions.gradients;
    // FIXED-SIZE rows: full-gradient strips at 6 × `slot_size` blocks
    // (1536 wide, one row of `slot_size` height), centered in the FIXED
    // picker overlay (the band between the sidebars) — the overlay never
    // resizes with the wheel's gradient count. See
    // `editorPickerOverlayRect`.
    const row_height = slot_size;
    const strip_width = types.gradient_color_count * slot_size;
    const rows: i32 = @intCast(gradients.len);
    const grid_height = rows * row_height + @max(rows - 1, 0) * ui_gap;
    const bounds = editorPickerOverlayRect();

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
        .color = active_theme.darkest,
    } });
    const title = try std.fmt.allocPrint(allocator, "Pick {s}", .{switch (target.role) {
        .world => "World colors",
        .enemy => "Enemy colors",
        .player => "Player colors",
    }});
    const content = try emitPanelHeader(elements, allocator, bounds, title, .close_editor_picker);
    const rows_origin_y = content.y + @max(ui_gap, @divFloor(content.height - grid_height, 2));

    // The level's current index for the role (the DERIVED one while an
    // enemy/player role is on auto — it's what's in effect). A stale
    // level index (defensive; picks gate at the input layer) highlights
    // nothing.
    var current_index: ?u32 = null;
    if (target.level_index < editor.levels.len) {
        const level = editor.levels[target.level_index];
        current_index = switch (target.role) {
            .world => level.color_wheel_index,
            .enemy => level.enemy_gradient_index orelse
                loaders.autoDerivedGradientIndex(color_theme_definitions, level.color_wheel_index, .enemy),
            .player => level.player_gradient_index orelse
                loaders.autoDerivedGradientIndex(color_theme_definitions, level.color_wheel_index, .player),
        };
    }

    for (gradients, 0..) |gradient, index| {
        const row_rect: Rectangle = .{
            .x = content.x + @divFloor(content.width - strip_width, 2),
            .y = rows_origin_y + @as(i32, @intCast(index)) * (row_height + ui_gap),
            .width = strip_width,
            .height = row_height,
        };
        const block_width = @divFloor(row_rect.width, types.gradient_color_count);
        for (0..types.gradient_color_count) |color_index| {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{
                    .x = row_rect.x + @as(i32, @intCast(color_index)) * block_width,
                    .y = row_rect.y,
                },
                .width = block_width,
                .height = row_rect.height,
                .color = gradient.colors[color_index],
            } });
        }
        try elements.append(allocator, .{ .button = .{
            .screen_position = row_rect.position(),
            .width = row_rect.width,
            .height = row_rect.height,
            .action = .select_editor_level_gradient,
            .editor_gradient = @intCast(index),
            .highlighted = current_index != null and current_index.? == index,
        } });
        // A VISIBLE current marker (Button.highlighted doesn't render —
        // see TODO): a lightest frame around the current row, the unified
        // 8px outline convention.
        if (current_index != null and current_index.? == index) {
            const thickness: i32 = 8;
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = row_rect.x, .y = row_rect.y },
                .width = row_rect.width,
                .height = thickness,
                .color = active_theme.lightest,
            } });
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = row_rect.x, .y = row_rect.y + row_rect.height - thickness },
                .width = row_rect.width,
                .height = thickness,
                .color = active_theme.lightest,
            } });
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = row_rect.x, .y = row_rect.y },
                .width = thickness,
                .height = row_rect.height,
                .color = active_theme.lightest,
            } });
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = row_rect.x + row_rect.width - thickness, .y = row_rect.y },
                .width = thickness,
                .height = row_rect.height,
                .color = active_theme.lightest,
            } });
        }
    }
}

pub fn buildEditorFootprintEditor(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    editor: types.Editor,
    active_theme: types.ActiveColorTheme,
    type_id: u32,
    ui_state: *const UiState,
) !void {
    // The type deleted mid-edit (or a stale open): nothing to edit —
    // the panel vanishes; the close button is unreachable, so the input
    // arms' own guards are the real defense (the toggle no-ops on an
    // out-of-range type).
    if (type_id >= editor.decoration_types.len) return;
    const definition = editor.decoration_types[type_id];
    const grid_width: i32 = @divTrunc(definition.pixel_dims.x + 255, 256);
    const grid_height: i32 = @divTrunc(definition.pixel_dims.y + 255, 256);
    if (grid_width <= 0 or grid_height <= 0) return;
    const cell_count: usize = @intCast(grid_width * grid_height);
    if (cell_count > editor_footprint_grid_cell_limit) return;

    // The FIXED picker overlay (the band between the sidebars). The grid
    // SCALES DOWN to fit the area between the header and the Confirm
    // button (never upscaled — 1:1 is the design size; an 8×8 custom
    // sprite is the case that shrinks). See `editorPickerOverlayRect`.
    const tile: i32 = 256;
    const header_height = middle_panel_header_height;
    const confirm_height = editor_inspector_row_height;
    const bounds = editorPickerOverlayRect();
    const avail_width = bounds.width - 2 * ui_gap;
    const avail_height = bounds.height - header_height - confirm_height - 3 * ui_gap;
    const scale: f32 = @min(
        @as(f32, 1.0),
        @min(
            @as(f32, @floatFromInt(avail_width)) / @as(f32, @floatFromInt(grid_width * tile)),
            @as(f32, @floatFromInt(avail_height)) / @as(f32, @floatFromInt(grid_height * tile)),
        ),
    );
    const scaled_tile: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(tile)) * scale)));
    const grid_width_pixels = grid_width * scaled_tile;
    const grid_height_pixels = grid_height * scaled_tile;

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
        .color = active_theme.darkest,
    } });

    // The header: title left, close right (the sprite picker's idiom).
    const origin = bounds.position();
    try elements.append(allocator, .{ .text_label = .{
        .text = "Footprint",
        .screen_position = .{
            .x = origin.x + ui_gap,
            .y = origin.y + @divFloor(header_height - middle_panel_header_font_size, 2),
        },
        .font_size = middle_panel_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = close_button_sprite_id,
        .screen_position = .{
            .x = origin.x + bounds.width - close_button_size,
            .y = origin.y,
        },
        .width = close_button_size,
        .height = close_button_size,
        .action = .close_editor_picker,
    } });

    // The sprite grid: the art SCALED, centered in the area between the
    // header and the Confirm button; custom stems get a dark fill per
    // cell so the grid stays visible without art.
    const grid_origin: ScreenPosition = .{
        .x = origin.x + @divFloor(bounds.width - grid_width_pixels, 2),
        .y = origin.y + header_height + ui_gap +
            @divFloor(avail_height - grid_height_pixels, 2),
    };
    if (std.mem.startsWith(u8, definition.sprite, "custom/")) {
        for (0..cell_count) |cell_index| {
            const column: i32 = @intCast(cell_index % @as(usize, @intCast(grid_width)));
            const row: i32 = @intCast(cell_index / @as(usize, @intCast(grid_width)));
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{
                    .x = grid_origin.x + column * tile,
                    .y = grid_origin.y + row * tile,
                },
                .width = tile,
                .height = tile,
                .color = .{ .r = 40, .g = 40, .b = 40 },
            } });
        }
    } else {
        const graphic_id = try std.fmt.allocPrint(allocator, "decorations/{s}", .{definition.sprite});
        const scaled_width: i32 = @max(1, @as(i32, @intFromFloat(
            @as(f32, @floatFromInt(definition.pixel_dims.x)) * scale,
        )));
        const scaled_height: i32 = @max(1, @as(i32, @intFromFloat(
            @as(f32, @floatFromInt(definition.pixel_dims.y)) * scale,
        )));
        try elements.append(allocator, .{ .image = .{
            .sprite_id = graphic_id,
            .screen_position = grid_origin,
            .width = scaled_width,
            .height = scaled_height,
            .color = default_tint,
            .blocks_input = false,
        } });
    }

    // One invisible toggle button per grid cell (the draft flips at the
    // input site — a direct UiState write, off the undo timeline).
    for (0..cell_count) |cell_index| {
        const column: i32 = @intCast(cell_index % @as(usize, @intCast(grid_width)));
        const row: i32 = @intCast(cell_index / @as(usize, @intCast(grid_width)));
        try elements.append(allocator, .{ .button = .{
            .screen_position = .{
                .x = grid_origin.x + column * scaled_tile,
                .y = grid_origin.y + row * scaled_tile,
            },
            .width = scaled_tile,
            .height = scaled_tile,
            .action = .toggle_editor_footprint_tile,
            .editor_footprint_tile = @intCast(cell_index),
        } });
    }

    // The draft-selected region's outline: one 8px bar per boundary side
    // (the neighbor across it unselected or off-grid), centered on the
    // boundary — the editor's region-edge outline, in white, so corners
    // join seamlessly for any shape.
    const outline_thickness: i32 = 8;
    const half_thickness: i32 = @divFloor(outline_thickness, 2);
    const draftSelected = struct {
        fn check(
            draft: *const [editor_footprint_grid_cell_limit]bool,
            grid_width_: i32,
            grid_height_: i32,
            x: i32,
            y: i32,
        ) bool {
            if (x < 0 or y < 0 or x >= grid_width_ or y >= grid_height_) return false;
            return draft[@intCast(y * grid_width_ + x)];
        }
    }.check;
    for (0..cell_count) |cell_index| {
        if (!ui_state.editor_footprint_draft[cell_index]) continue;
        const column: i32 = @intCast(cell_index % @as(usize, @intCast(grid_width)));
        const row: i32 = @intCast(cell_index / @as(usize, @intCast(grid_width)));
        const cell_x = grid_origin.x + column * scaled_tile;
        const cell_y = grid_origin.y + row * scaled_tile;
        const draft = &ui_state.editor_footprint_draft;
        if (!draftSelected(draft, grid_width, grid_height, column, row - 1)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x, .y = cell_y - half_thickness },
                .width = scaled_tile,
                .height = outline_thickness,
                .color = default_tint,
            } });
        }
        if (!draftSelected(draft, grid_width, grid_height, column, row + 1)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x, .y = cell_y + scaled_tile - half_thickness },
                .width = scaled_tile,
                .height = outline_thickness,
                .color = default_tint,
            } });
        }
        if (!draftSelected(draft, grid_width, grid_height, column - 1, row)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x - half_thickness, .y = cell_y },
                .width = outline_thickness,
                .height = scaled_tile,
                .color = default_tint,
            } });
        }
        if (!draftSelected(draft, grid_width, grid_height, column + 1, row)) {
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = cell_x + scaled_tile - half_thickness, .y = cell_y },
                .width = outline_thickness,
                .height = scaled_tile,
                .color = default_tint,
            } });
        }
    }

    // The Confirm button (bottom-center of the overlay, the layer-button
    // visual class) — a FIXED position now (the grid scales above it).
    const confirm_rect: Rectangle = .{
        .x = origin.x + @divFloor(bounds.width - @divFloor(bounds.width, 2), 2),
        .y = origin.y + bounds.height - confirm_height - ui_gap,
        .width = @divFloor(bounds.width, 2),
        .height = confirm_height,
    };
    try emitInspectorLayerButton(
        elements,
        allocator,
        font_metrics,
        confirm_rect,
        "Confirm",
        .confirm_editor_footprint,
        null,
        active_theme.world_gradient.colors[@min(@as(u32, 5), types.gradient_color_count - 1)],
        active_theme.lightest,
    );
}

/// The mission directory's NAME (the last path segment) — the namespace
/// for mission-local sprite ids.
fn missionDirectoryName(mission_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, mission_path, '/')) |slash| {
        return mission_path[slash + 1 ..];
    }
    return mission_path;
}

/// One sprite-picker cell: the button background (carrying the pick + the
/// stored-id payload) + the option's graphic. Official options draw the
/// sprite; mission-local options carry a text label (their art isn't
/// renderable until custom-asset rendering lands).
fn emitPickerSpriteCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell_rect: Rectangle,
    sprite_id: []const u8,
    label: []const u8,
    graphic_sprite_id: ?[]const u8,
    graphic_color: Color,
    button_color: Color,
    highlighted: bool,
    label_color: Color,
    pick_action: types.Action,
    frame_width: i32,
    frame_height: i32,
) !void {
    try elements.append(allocator, .{ .button = .{
        .sprite_id = button_background_sprite_id,
        .screen_position = cell_rect.position(),
        .width = cell_rect.width,
        .height = cell_rect.height,
        .action = pick_action,
        .editor_sprite = sprite_id,
        .color = button_color,
        .highlighted = highlighted,
        .tooltip = .{ .header = try spanRow(allocator, text(label)) },
    } });
    if (graphic_sprite_id) |graphic_id| {
        const fitted = scaleToFit(cell_rect, frame_width, frame_height);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = graphic_id,
            .screen_position = fitted.position(),
            .width = fitted.width,
            .height = fitted.height,
            .color = graphic_color,
            .blocks_input = false,
        } });
    } else {
        const label_width = font_metrics.measureSpanWidth(text(label), editor_group_header_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = cell_rect
                .placeCenter(label_width, editor_group_header_font_size)
                .position(),
            .font_size = editor_group_header_font_size,
            .color = label_color,
            .blocks_input = false,
        } });
    }
}

/// One picker cell: the frame button (carrying the pick; null skill_id =
/// the None cell) + the skill icon at FULL cell size. Real skills are
/// icon-only (the tooltip carries the name); the None cell keeps its text
/// label.
fn emitPickerSkillCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell_rect: Rectangle,
    skill_id: ?types.SkillId,
    label: []const u8,
    frame_sprite_id: []const u8,
    highlighted: bool,
    frame_color: Color,
    icon_color: Color,
    label_color: Color,
) !void {
    const tooltip: ?Tooltip = if (skill_id) |some_id|
        if (lookups.getSkillDefinition(some_id)) |definition|
            try buildSkillTooltip(allocator, definition)
        else
            null
    else
        .{ .header = try spanRow(allocator, text("None")) };
    try elements.append(allocator, .{ .button = .{
        .sprite_id = frame_sprite_id,
        .screen_position = cell_rect.position(),
        .width = cell_rect.width,
        .height = cell_rect.height,
        .action = .select_editor_utility_skill,
        .editor_skill = skill_id,
        .color = frame_color,
        .highlighted = highlighted,
        .tooltip = tooltip,
    } });
    if (skill_id) |some_id| {
        // Full cell size — the icon is the identity.
        try elements.append(allocator, .{ .image = .{
            .sprite_id = skillIconSpriteId(some_id),
            .screen_position = cell_rect.position(),
            .width = cell_rect.width,
            .height = cell_rect.height,
            .color = icon_color,
            .blocks_input = false,
        } });
    } else {
        const font_size: i32 = 48;
        const label_width = font_metrics.measureSpanWidth(text(label), font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = cell_rect
                .placeBottomCenter(label_width, font_size, ui_gap)
                .position(),
            .font_size = font_size,
            .color = label_color,
            .blocks_input = false,
        } });
    }
}

test "buildEditorSkillPicker: header + close + None + one cell per utility skill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{ black, .{ .r = 30, .g = 30, .b = 30 }, black, black, black, .{ .r = 40, .g = 40, .b = 40 } } },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // Slot 1 (Slot 5) already carries blink — its cell is highlighted,
    // the None cell is not.
    const entity_types = [_]types.EntityTypeDef{.{ .id = "Skeleton", .template = .{
        .equipped_utility_skills = .{ null, .blink, null, null, null },
    } }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
    };

    var elements: UiElementList = .empty;
    try buildEditorSkillPicker(&elements, arena.allocator(), metrics, editor, .{ .utility_skill_slot = 1 }, theme);

    // The panel is the FIXED picker overlay — the band between the
    // sidebars (full sidebar-panel height, a ui_gap in from each).
    const panel = elements.items[0].nine_slice_panel;
    try std.testing.expectEqual(
        editorPickerOverlayRect(),
        Rectangle{
            .x = panel.screen_position.x,
            .y = panel.screen_position.y,
            .width = panel.width,
            .height = panel.height,
        },
    );
    try std.testing.expectEqual(@as(i32, 1760), editorPickerOverlayRect().width);
    try std.testing.expectEqual(@as(i32, 1328), editorPickerOverlayRect().height);

    // Panel + header label + close + None (button + label) + 9 ×
    // (button + full-size icon) = 23 — real skills are icon-only.
    try std.testing.expectEqual(@as(usize, 23), elements.items.len);

    var picker_buttons: usize = 0;
    var highlighted_skill: ?types.SkillId = null;
    var none_highlighted = false;
    var saw_blink_cell = false;
    var saw_header = false;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_editor_utility_skill) {
            picker_buttons += 1;
            if (button.editor_skill == null) {
                none_highlighted = button.highlighted;
            } else if (button.highlighted) {
                highlighted_skill = button.editor_skill;
            }
            if (button.editor_skill == .blink) saw_blink_cell = true;
        },
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "Assign Slot 5")) saw_header = true;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 10), picker_buttons); // None + 9 skills
    try std.testing.expectEqual(types.SkillId.blink, highlighted_skill.?);
    try std.testing.expect(!none_highlighted);
    try std.testing.expect(saw_blink_cell);
    try std.testing.expect(saw_header);
    // No weapon-skill payload anywhere.
    for (elements.items) |element| switch (element) {
        .button => |button| try std.testing.expect(
            button.editor_skill == null or utility_skills.isUtilitySkill(button.editor_skill.?),
        ),
        else => {},
    };

    // The PLAYER fallback target: the picker reads the player loadout's
    // slots (the '!' selected under the select tool resolves to the
    // player).
    {
        const player_editor: types.Editor = .{
            .player_def = .{ .id = "Player", .template = .{
                .equipped_utility_skills = .{ null, .stone_form, null, null, null },
            } },
            .active_tool = .select,
            .selection = &.{.{ .player_start = {} }},
        };
        var player_elements: UiElementList = .empty;
        try buildEditorSkillPicker(
            &player_elements,
            arena.allocator(),
            metrics,
            player_editor,
            .{ .utility_skill_slot = 1 },
            theme,
        );
        var player_highlighted: ?types.SkillId = null;
        for (player_elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_utility_skill and
                button.highlighted and button.editor_skill != null)
            {
                player_highlighted = button.editor_skill;
            },
            else => {},
        };
        try std.testing.expectEqual(types.SkillId.stone_form, player_highlighted.?);
    }
}

test "buildEditorSpritePicker: tabs, official cells (player excluded), mission-local namespaced cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const entity_types = [_]types.EntityTypeDef{.{
        .id = "Bear",
        .template = .{ .name = "Bear", .sprite = "bear", .team = 1 },
    }};
    const editor: types.Editor = .{
        .entity_types = &entity_types,
        .active_tool = .{ .entity_type = 0 },
        .mission = .{ .path = "missions/artists_den" },
    };

    // Official tab: one cell per shipped enemy sprite, the player body
    // excluded; the current sprite (bear) highlighted; every cell carries
    // its stem payload + the shipped sprite graphic.
    {
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(&elements, arena.allocator(), metrics, editor, theme, &.{}, &.{}, .entity_sprite, .official);
        var pick_buttons: usize = 0;
        var highlighted: ?[]const u8 = null;
        var saw_player = false;
        var saw_bear_graphic = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_sprite) {
                pick_buttons += 1;
                if (std.mem.eql(u8, button.editor_sprite.?, "player")) saw_player = true;
                if (button.highlighted) highlighted = button.editor_sprite;
            } else if (button.action == .select_editor_sprite_tab) {
                // Tabs: Mission + Official, the active one highlighted.
                if (button.editor_sprite_tab.? == .official) {
                    try std.testing.expect(button.highlighted);
                } else {
                    try std.testing.expect(!button.highlighted);
                }
            },
            .image => |image| if (std.mem.eql(u8, image.sprite_id, "entities/bear")) {
                saw_bear_graphic = true;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 9), pick_buttons); // 10 shipped minus player
        try std.testing.expect(!saw_player);
        try std.testing.expectEqualStrings("bear", highlighted.?);
        try std.testing.expect(saw_bear_graphic);
    }

    // Mission tab: the scanned file names become namespaced
    // `custom/<mission-dir>/<stem>` payloads, shown as TEXT cells (the art
    // isn't renderable until custom-asset rendering lands).
    {
        const mission_sprites = [_][]const u8{ "boss.png", "minion.png" };
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &mission_sprites,
            &.{},
            .entity_sprite,
            .mission_local,
        );
        var payloads: [2][]const u8 = .{ "", "" };
        var pick_buttons: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_sprite) {
                payloads[pick_buttons] = button.editor_sprite.?;
                pick_buttons += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), pick_buttons);
        try std.testing.expectEqualStrings("custom/artists_den/boss", payloads[0]);
        try std.testing.expectEqualStrings("custom/artists_den/minion", payloads[1]);
        // The mission tab's cells carry text labels, no sprite graphics.
        try std.testing.expectEqualStrings("boss", findLabel(&elements, "boss").text);
    }
}

test "buildEditorSpritePicker: decoration target — registry official cells, namespaced mission cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const world_four: types.Color = .{ .r = 20, .g = 20, .b = 20 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{ black, black, black, black, world_four, black } },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const tree_footprint = [_]types.Vector2{.{ .x = 1, .y = 2 }};
    const tree_layers = [_]types.DecorationLayer{.{
        .sprite = "tree_1_canopy",
        .color_index = 2,
        .pixel_dims = .{ .x = 512, .y = 768 },
    }};
    const registry = [_]types.DecorationTypeDef{
        .{
            .id = "tree_1",
            .sprite = "tree_1",
            .footprint = &tree_footprint,
            .pixel_dims = .{ .x = 512, .y = 768 },
            .color_index = 4,
            .layers = &tree_layers,
        },
        .{ .id = "stone_2", .sprite = "stone_2", .pixel_dims = .{ .x = 512, .y = 256 } },
    };
    const stone_footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &stone_footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
        .color_index = 4,
    }};
    const editor: types.Editor = .{
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
        .mission = .{ .path = "missions/artists_den" },
    };

    // Official tab: one cell per registry prefab — the decoration pick
    // action, the shipped `decorations/<stem>` graphic, the current sprite
    // (stone_2) highlighted, world-gradient tint at the type's color.
    {
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &.{},
            &registry,
            .decoration_sprite,
            .official,
        );
        var pick_buttons: usize = 0;
        var highlighted: ?[]const u8 = null;
        var saw_tree_graphic = false;
        var saw_world_tint = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_sprite) {
                pick_buttons += 1;
                if (button.highlighted) highlighted = button.editor_sprite;
            },
            .image => |image| {
                if (std.mem.eql(u8, image.sprite_id, "decorations/tree_1")) saw_tree_graphic = true;
                if (std.meta.eql(image.color, world_four)) saw_world_tint = true;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), pick_buttons);
        try std.testing.expectEqualStrings("stone_2", highlighted.?);
        try std.testing.expect(saw_tree_graphic);
        try std.testing.expect(saw_world_tint);
    }

    // Mission tab: same namespacing as the entity picker; text cells (the
    // art isn't renderable until custom-asset rendering lands).
    {
        const mission_sprites = [_][]const u8{"banner.png"};
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &mission_sprites,
            &registry,
            .decoration_sprite,
            .mission_local,
        );
        var pick_buttons: usize = 0;
        var payload: ?[]const u8 = null;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_sprite) {
                pick_buttons += 1;
                payload = button.editor_sprite;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), pick_buttons);
        try std.testing.expectEqualStrings("custom/artists_den/banner", payload.?);
    }
}

test "buildEditorSpritePicker: layer modes — entity stems, dims-filtered decoration stems" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // ENTITY layer mode (editing layer 0, sprite "bear"): the Official
    // tab lists the shipped entity sprites (player excluded) with the
    // entity-layer pick action; the edited layer's sprite highlights.
    {
        const entity_layers = [_]types.EntityLayer{.{ .sprite = "bear", .color_index = 2 }};
        const entity_types = [_]types.EntityTypeDef{.{
            .id = "Skeleton",
            .template = .{ .name = "Skeleton", .sprite = "skeleton_1", .team = 1, .layers = &entity_layers },
        }};
        const editor: types.Editor = .{
            .entity_types = &entity_types,
            .active_tool = .{ .entity_type = 0 },
        };
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &.{},
            &.{},
            .{ .entity_layer = 0 },
            .official,
        );
        var pick_buttons: usize = 0;
        var highlighted: ?[]const u8 = null;
        var saw_player = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_entity_layer) {
                pick_buttons += 1;
                if (std.mem.eql(u8, button.editor_sprite.?, "player")) saw_player = true;
                if (button.highlighted) highlighted = button.editor_sprite;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 9), pick_buttons);
        try std.testing.expect(!saw_player);
        try std.testing.expectEqualStrings("bear", highlighted.?);
    }

    // DECORATION layer mode (add — null index): the Official tab lists
    // ONLY the shipped decoration sprites whose dims match the base
    // type's (512x256 here) — the load-time layer invariant — with the
    // decoration-layer pick action; nothing highlights in add mode.
    {
        const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
        const decoration_types = [_]types.DecorationTypeDef{.{
            .id = "stone_2",
            .sprite = "stone_2",
            .footprint = &footprint,
            .pixel_dims = .{ .x = 512, .y = 256 },
        }};
        const editor: types.Editor = .{
            .decoration_types = &decoration_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        var elements: UiElementList = .empty;
        try buildEditorSpritePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            theme,
            &.{},
            &.{},
            .{ .decoration_layer = null },
            .official,
        );
        var pick_buttons: usize = 0;
        var highlighted_count: usize = 0;
        var saw_mismatched_dims = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_decoration_layer) {
                pick_buttons += 1;
                if (button.highlighted) highlighted_count += 1;
            },
            .image => |image| {
                // The cells' graphics all aspect-fit at 512x256 (the
                // entity-frame convention is 512x640 — a mismatched
                // filter leak would show up as a taller fit).
                if (image.height > @divFloor(slot_size * 256, 512)) saw_mismatched_dims = true;
            },
            else => {},
        };
        try std.testing.expect(pick_buttons > 0);
        try std.testing.expectEqual(@as(usize, 0), highlighted_count);
        try std.testing.expect(!saw_mismatched_dims);
    }
}

test "buildEditorFootprintEditor: tile cells, white region outline, confirm; inspector row opens it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "stone_2",
        .sprite = "stone_2",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
    }};
    const editor: types.Editor = .{
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
    };

    // The editor panel with the draft selecting ONLY cell (0,0): two
    // toggle cells, the shipped-sprite graphic, a 4-bar white outline
    // around the lone selected cell (every side is a boundary — the
    // neighbor (1,0) is unselected, the others off-grid), and the
    // Confirm button.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        ui_state.editor_footprint_draft[0] = true;
        try buildEditorFootprintEditor(&elements, arena.allocator(), metrics, editor, theme, 0, &ui_state);

        var toggle_buttons: usize = 0;
        var saw_graphic = false;
        var saw_confirm = false;
        var saw_close = false;
        var white_bars: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .toggle_editor_footprint_tile) {
                    toggle_buttons += 1;
                    try std.testing.expect(button.editor_footprint_tile != null);
                }
                if (button.action == .confirm_editor_footprint) saw_confirm = true;
                if (button.action == .close_editor_picker) saw_close = true;
            },
            .image => |image| {
                if (std.mem.eql(u8, image.sprite_id, "decorations/stone_2")) saw_graphic = true;
            },
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, default_tint)) white_bars += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), toggle_buttons);
        try std.testing.expect(saw_graphic);
        try std.testing.expect(saw_confirm);
        try std.testing.expect(saw_close);
        try std.testing.expectEqual(@as(usize, 4), white_bars);
    }

    // A custom-stem type: no renderable art — the cells get dark fills so
    // the grid stays visible (2 fills, no image).
    {
        const custom_types = [_]types.DecorationTypeDef{.{
            .id = "custom/x/banner",
            .sprite = "custom/x/banner",
            .footprint = &footprint,
            .pixel_dims = .{ .x = 512, .y = 256 },
        }};
        const custom_editor: types.Editor = .{
            .decoration_types = &custom_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{};
        ui_state.editor_footprint_draft[0] = true;
        ui_state.editor_footprint_draft[1] = true;
        try buildEditorFootprintEditor(&elements, arena.allocator(), metrics, custom_editor, theme, 0, &ui_state);

        var saw_image = false;
        var dark_fills: usize = 0;
        var white_bars: usize = 0;
        for (elements.items) |element| switch (element) {
            .image => saw_image = true,
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, .{ .r = 40, .g = 40, .b = 40 })) dark_fills += 1;
                if (std.meta.eql(rect.color, default_tint)) white_bars += 1;
            },
            else => {},
        };
        try std.testing.expect(!saw_image);
        try std.testing.expectEqual(@as(usize, 2), dark_fills);
        // Both cells selected: the region's boundary is the 2x1 block's
        // outer rectangle — 6 bars (2 top + 2 bottom + 1 left + 1 right).
        try std.testing.expectEqual(@as(usize, 6), white_bars);
    }

    // The inspector's Footprint row: a "<N> tiles" button that opens the
    // editor.
    {
        var elements: UiElementList = .empty;
        var ui_state: UiState = .{ .editor_inspector_section_expanded = allInspectorSectionsExpanded() };
        try buildEditorInspectorPanel(&elements, arena.allocator(), metrics, editor, theme, true, &ui_state);
        var saw_footprint_button = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .open_editor_footprint_picker) {
                saw_footprint_button = true;
            },
            else => {},
        };
        try std.testing.expect(saw_footprint_button);
    }

    // An oversized sprite SCALES DOWN to fit the fixed overlay: a
    // 4096×256 (16×1-grid) sprite scales to 1728/4096 of 1:1 — the
    // toggle cells shrink to 108px, the fixed overlay unchanged.
    {
        const wide_types = [_]types.DecorationTypeDef{.{
            .id = "wide",
            .sprite = "wide",
            .footprint = &.{.{ .x = 0, .y = 0 }},
            .pixel_dims = .{ .x = 4096, .y = 256 },
        }};
        const wide_editor: types.Editor = .{
            .decoration_types = &wide_types,
            .active_tool = .{ .decoration_type = 0 },
        };
        var wide_elements: UiElementList = .empty;
        var wide_ui_state: UiState = .{};
        try buildEditorFootprintEditor(&wide_elements, arena.allocator(), metrics, wide_editor, theme, 0, &wide_ui_state);
        var saw_scaled_cell = false;
        for (wide_elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .toggle_editor_footprint_tile) {
                    try std.testing.expectEqual(@as(i32, 108), button.width);
                    saw_scaled_cell = true;
                }
            },
            else => {},
        };
        try std.testing.expect(saw_scaled_cell);
        const panel = wide_elements.items[0].nine_slice_panel;
        try std.testing.expectEqual(
            editorPickerOverlayRect(),
            Rectangle{
                .x = panel.screen_position.x,
                .y = panel.screen_position.y,
                .width = panel.width,
                .height = panel.height,
            },
        );
    }
}

test "buildEditorThemePicker: one strip per gradient, current row framed, close button" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    var gradients: [3]types.ColorGradient = undefined;
    for (&gradients, 0..) |*gradient, index| {
        const value: u8 = @intCast(index * 40 + 10);
        gradient.* = .{ .colors = .{types.Color{ .r = value, .g = value, .b = value }} ** types.gradient_color_count };
    }
    const definitions: types.ColorThemeDefinitions = .{
        .lightest = lightest,
        .darkest = black,
        .gradients = &gradients,
    };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = gradients[0],
        .enemy_gradient = gradients[1],
        .player_gradient = gradients[2],
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const levels = [_]types.EditorLevel{.{ .color_wheel_index = 2 }};
    const editor: types.Editor = .{ .levels = &levels };

    // World role: the current index is the wheel index (2) — row 2 framed.
    {
        var elements: UiElementList = .empty;
        try buildEditorThemePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            definitions,
            theme,
            .{ .level_index = 0, .role = .world },
        );
        // The FIXED picker overlay + header label + close + 3 rows ×
        // (6 blocks + button) + 4 frame rects on the current row = 28.
        const panel = elements.items[0].nine_slice_panel;
        try std.testing.expectEqual(
            editorPickerOverlayRect(),
            Rectangle{
                .x = panel.screen_position.x,
                .y = panel.screen_position.y,
                .width = panel.width,
                .height = panel.height,
            },
        );
        try std.testing.expectEqual(@as(usize, 28), elements.items.len);
        // The strips are FIXED-SIZE (6 × slot_size wide, slot_size tall),
        // not stretched to the overlay — the row's button spans the whole
        // strip (the 6 blocks beneath it are slot_size/6 each).
        try std.testing.expectEqual(@as(?u32, 0), elements.items[9].button.editor_gradient);
        try std.testing.expectEqual(6 * slot_size, elements.items[9].button.width);
        try std.testing.expectEqual(slot_size, elements.items[9].button.height);
        try std.testing.expectEqual(@as(i32, 256), elements.items[3].solid_rect.width);

        var pick_buttons: usize = 0;
        var current_button: ?Button = null;
        var close_seen = false;
        var frame_rects: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| switch (button.action) {
                .select_editor_level_gradient => {
                    pick_buttons += 1;
                    if (button.highlighted) current_button = button;
                },
                .close_editor_picker => close_seen = true,
                else => {},
            },
            .solid_rect => |rect| {
                if (std.meta.eql(rect.color, lightest)) frame_rects += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 3), pick_buttons);
        try std.testing.expect(close_seen);
        try std.testing.expectEqual(@as(usize, 4), frame_rects);
        try std.testing.expect(current_button != null);
        try std.testing.expectEqual(@as(?u32, 2), current_button.?.editor_gradient);
    }

    // Enemy role on auto: the current index is the DERIVED one (wheel 2,
    // 3 gradients → enemy = 2 + 1 = 0 mod 3).
    {
        var elements: UiElementList = .empty;
        try buildEditorThemePicker(
            &elements,
            arena.allocator(),
            metrics,
            editor,
            definitions,
            theme,
            .{ .level_index = 0, .role = .enemy },
        );
        var current_button: ?Button = null;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_level_gradient and button.highlighted) {
                current_button = button;
            },
            else => {},
        };
        try std.testing.expect(current_button != null);
        try std.testing.expectEqual(@as(?u32, 0), current_button.?.editor_gradient);
    }
}

/// Find the first text label with exactly `label_text` (test helper).
fn findLabel(elements: *const UiElementList, label_text: []const u8) TextLabel {
    for (elements.items) |element| switch (element) {
        .text_label => |label| if (std.mem.eql(u8, label.text, label_text)) return label,
        else => {},
    };
    @panic("label not found");
}
