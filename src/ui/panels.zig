//! The in-game middle panels: inventory (grid + material sidebar +
//! salvage region), gear (equipped slots + stat sidebar), skills (the
//! learned-skills grid), and the read-only entity inspect — plus the
//! shared slot-content support (slotContentSize/slotContentIcon/
//! gearSlotItem) and the player-entity accessor used by the view.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const emit = @import("emit.zig");
const tooltip = @import("tooltip.zig");
const state = @import("../state.zig");
const lookups = @import("../generated_lookups.zig");
const Effect = @import("../effect.zig").Effect;

const Action = types.Action;
const ScreenPosition = types.ScreenPosition;
const Rectangle = types.Rectangle;
const Color = types.Color;
const Entity = types.Entity;
const SkillId = types.SkillId;
const GearSlot = types.GearSlot;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const weapon_type_count = @typeInfo(types.WeaponType).@"enum".fields.len;
const GameState = state.GameState;
const Tooltip = ui_element.Tooltip;
const TooltipRow = ui_element.TooltipRow;
const text = ui_element.text;
const FontMetrics = ui_element.FontMetrics;
const UiElementList = ui_element.UiElementList;
const Slot = ui_element.Slot;
const Image = ui_element.Image;
const SlotRef = ui_element.SlotRef;
const slot_size = ui_element.slot_size;
const ui_gap = ui_element.ui_gap;
const small_icon_size = ui_element.small_icon_size;
const middle_panel_height = ui_element.middle_panel_height;
const middle_panel_header_height = ui_element.middle_panel_header_height;
const inventory_slot_size = ui_element.inventory_slot_size;
const skills_panel_width = ui_element.skills_panel_width;
const skills_panel_columns = ui_element.skills_panel_columns;
const skills_scrollbar_width = ui_element.skills_scrollbar_width;
const entity_inspect_panel_width = ui_element.entity_inspect_panel_width;
const buildItemTooltip = tooltip.buildItemTooltip;
const buildSkillTooltip = tooltip.buildSkillTooltip;
const EquippedGear = tooltip.EquippedGear;
const positive_color = tooltip.positive_color;
const negative_color = tooltip.negative_color;
const spanRow = tooltip.spanRow;
const emitCenteredNumber = emit.emitCenteredNumber;
const emitCornerNumber = emit.emitCornerNumber;
const emitPanelHeader = emit.emitPanelHeader;
const emitSkillButton = emit.emitSkillButton;
const skillIconSpriteId = emit.skillIconSpriteId;
const itemIconSpriteId = emit.itemIconSpriteId;
const effectIconSpriteId = emit.effectIconSpriteId;
const emitMaterialIcons = emit.emitMaterialIcons;
const emitItemStatLabels = emit.emitItemStatLabels;
const material_count_font_size = emit.material_count_font_size;
const material_count_inset = emit.material_count_inset;
const material_kinds = emit.material_kinds;
const Grid = ui_element.Grid;
const SalvageRegion = @import("state.zig").SalvageRegion;
const cooldown_font_size = emit.cooldown_font_size;



/// The player entity is index 0 in a level, or the dedicated hub player.
pub fn playerEntity(game_state: *const GameState) ?Entity {
    if (game_state.level) |level| {
        if (level.entities.len > 0) return level.entities[0];
        return null;
    }
    if (game_state.hub) |hub| return hub.player;
    return null;
}

/// Render size for a slot's content, by domain. Inventory + gear slots are
/// 128×128 (`inventory_slot_size`); skill-bar + learned-skill slots are
/// 256×256 (`slot_size`). Pure function of the ref's domain.
pub fn slotContentSize(ref: SlotRef) i32 {
    return switch (ref) {
        .inventory, .gear => inventory_slot_size,
        .skill_bar, .learned_skill => slot_size,
        // Unreachable: save rows never start drags (slotContentIcon is
        // null for them). Size value is arbitrary.
        .save_file => slot_size,
    };
}

/// The content icon for a slot ref, resolved against the live player entity
/// (inventory/gear/skill-bar contents) or the skill-id tag (learned-skill
/// pool). Returns null for an empty slot — the caller must not start a drag
/// from an empty slot. This is the "what is actually being dragged" lookup,
/// distinct from a slot element's `icon_sprite_id` (which is the frame
/// background, always present).
pub fn slotContentIcon(game_state: *const GameState, ref: SlotRef) ?[]const u8 {
    const player = playerEntity(game_state) orelse return null;
    return switch (ref) {
        .inventory => |i| blk: {
            if (i >= player.inventory.slots.len) break :blk null;
            if (player.inventory.slots[i]) |item| break :blk itemIconSpriteId(item);
            break :blk null;
        },
        .gear => |g| switch (g) {
            .main_hand => if (player.main_hand_weapon) |w| itemIconSpriteId(.{ .weapon = w }) else null,
            .off_hand => if (player.off_hand_weapon) |w| itemIconSpriteId(.{ .weapon = w }) else null,
            .amulet => if (player.amulet) |a| itemIconSpriteId(.{ .amulet = a }) else null,
            .coat => if (player.coat) |c| itemIconSpriteId(.{ .coat = c }) else null,
            .gloves => if (player.gloves) |gv| itemIconSpriteId(.{ .gloves = gv }) else null,
            .pants => if (player.pants) |p| itemIconSpriteId(.{ .pants = p }) else null,
            .boots => if (player.boots) |b| itemIconSpriteId(.{ .boots = b }) else null,
        },
        .skill_bar => |i| blk: {
            if (i >= player.equipped_utility_skills.len) break :blk null;
            if (player.equipped_utility_skills[i]) |skill_id| break :blk skillIconSpriteId(skill_id);
            break :blk null;
        },
        .learned_skill => |skill_id| skillIconSpriteId(skill_id),
        // Save rows have no drag content — null here is what keeps the drag
        // machinery from ever starting on them (a press can't promote).
        .save_file => null,
    };
}

/// The Item in a gear slot, or null if empty. Used by panel builders for
/// item icons + tooltips. Mirrors the handler-side `gearSlotItem`.
pub fn gearSlotItem(player: Entity, gear_slot: GearSlot) ?types.Item {
    return player.gearSlotItem(gear_slot);
}

pub fn buildInventoryPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    inventory: types.Inventory,
    materials: types.Materials,
    learned_skills: []const types.SkillId,
    /// The player's equipped gear — baseline for item-tooltip stat
    /// comparisons. Null suppresses them.
    equipped: ?EquippedGear,
    active_theme: types.ActiveColorTheme,
    /// The slot currently being dragged from, if any. The item `Image` is
    /// suppressed on the source slot so the item reads as "in flight"
    /// (shown only as the drag ghost following the pointer). The frame +
    /// tooltip still emit (the tooltip is globally suppressed while a drag
    /// is active — see view.zig — so it's moot here, but the frame keeps
    /// the slot's hit-test identity intact).
    drag_source: ?SlotRef,
    /// Held keyboard modifiers this frame. Drives the salvage-tool indicator
    /// highlight (outlined while Shift is held).
    held_modifiers: types.Modifiers,
    /// In-progress shift-drag region selection, if any. Rendered as a lightest
    /// outline around the bounding box of the two corner slots.
    salvage_region: ?SalvageRegion,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, "Inventory", .toggle_inventory);

    const p = active_theme.player_gradient.colors;
    const slot_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    // Item icons render at player-gradient index 1.
    const item_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const origin = content.position();
    const grid = Grid{
        .origin = .{ .x = origin.x + ui_gap, .y = origin.y + ui_gap },
        .cell_width = inventory_slot_size,
        .cell_height = inventory_slot_size,
        .gap = 0,
        .columns = types.inventory_columns,
    };
    var index: i32 = 0;
    while (index < types.inventory_slot_count) : (index += 1) {
        const cell = grid.cell(index);
        // Slot frame. Carries the slot identity so press/click handlers
        // can resolve which slot was acted on (drag/drop + click intents).
        // When the slot holds an item, the tooltip rides on the frame: the
        // item Image on top is non-blocking, so `tooltipAt` falls through to
        // the Slot beneath (the blocking surface) — one tooltip target per
        // slot.
        const occupied_slot = inventory.slots[@intCast(index)];
        const slot_tooltip: ?Tooltip = if (occupied_slot) |item|
            try buildItemTooltip(allocator, item, learned_skills, equipped)
        else
            null;
        try elements.append(allocator, .{ .slot = .{
            .screen_position = cell.position(),
            .size = inventory_slot_size,
            .icon_sprite_id = "ui/item_slot",
            .icon_color = slot_color,
            .ref = .{ .inventory = @intCast(index) },
            .tooltip = slot_tooltip,
        } });
        // Item icon on top of the frame. Passes hover/click through to the
        // slot beneath so the slot stays the single interaction target.
        // Suppressed on the drag source: the item reads as "in flight"
        // (the drag ghost follows the pointer instead).
        const is_drag_source = if (drag_source) |src| switch (src) {
            .inventory => |si| si == @as(u32, @intCast(index)),
            else => false,
        } else false;
        if (!is_drag_source) {
            if (inventory.slots[@intCast(index)]) |item| {
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = itemIconSpriteId(item),
                    .screen_position = cell.position(),
                    .width = inventory_slot_size,
                    .height = inventory_slot_size,
                    .color = item_color,
                    .blocks_input = false,
                } });
                // The item's stat numbers, colored by the equipped
                // comparison (plus the unlearned-tome "!" marker) — the
                // at-a-glance version of the slot tooltip's stat rows
                // (see emitItemStatLabels).
                try emitItemStatLabels(
                    elements,
                    allocator,
                    font_metrics,
                    cell.position(),
                    inventory_slot_size,
                    item,
                    learned_skills,
                    equipped,
                    active_theme,
                );
            }
        }
    }

    // Material sidebar: a 128-wide column to the right of the grid
    // (`ui_gap` between them). The five material icons stack bottom-aligned
    // — the stack's bottom edge aligns with the grid's bottom edge. Order
    // top-to-bottom: wood, metal, leather, cloth, knowledge, each tinted
    // with its fixed player-gradient index. Each icon carries an outlined
    // count label in its bottom-right corner.
    const sidebar_x = origin.x + ui_gap + types.inventory_columns * inventory_slot_size + ui_gap;
    const grid_top = origin.y + ui_gap;
    const grid_bottom = grid_top + types.inventory_rows * inventory_slot_size;
    const stack_height = @as(i32, material_kinds.len) * inventory_slot_size;
    const icon_top = grid_bottom - stack_height;
    try emitMaterialIcons(
        elements,
        allocator,
        font_metrics,
        .{ .x = sidebar_x, .y = icon_top },
        inventory_slot_size,
        .vertical,
        materials,
        active_theme,
    );

    // Salvage-tool indicator: top of the material sidebar column (the
    // materials are bottom-aligned, so the top of that column is empty).
    // Display-only (no action) — it signals that Shift+drag multi-salvages.
    // Outlined via the programmatic sprite-silhouette highlight while Shift
    // is held so the player sees the mode is active.
    const lightest = active_theme.lightest;
    const salvage_tool_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];
    try elements.append(allocator, .{ .image = .{
        .sprite_id = "ui/salvage_tool",
        .screen_position = .{ .x = sidebar_x, .y = grid_top },
        .width = inventory_slot_size,
        .height = inventory_slot_size,
        .color = salvage_tool_color,
        .highlighted = held_modifiers.shift,
        .tooltip = .{ .header = try spanRow(allocator, text(
            "Hold Shift to salvage items into materials - hold and drag to multi-salvage",
        )) },
        .blocks_input = false,
    } });

    // Shift-drag region outline: a lightest stroked rectangle around the
    // bounding box of the two corner slots. Drawn over the grid (non-blocking)
    // so hover/click still reach the slots beneath.
    if (salvage_region) |region| {
        const start_row = @divTrunc(@as(i32, @intCast(region.start_slot)), types.inventory_columns);
        const start_col = @rem(@as(i32, @intCast(region.start_slot)), types.inventory_columns);
        const end_row = @divTrunc(@as(i32, @intCast(region.end_slot)), types.inventory_columns);
        const end_col = @rem(@as(i32, @intCast(region.end_slot)), types.inventory_columns);
        const min_row = @min(start_row, end_row);
        const min_col = @min(start_col, end_col);
        const max_row = @max(start_row, end_row);
        const max_col = @max(start_col, end_col);
        const region_origin = ScreenPosition{
            .x = grid.origin.x + min_col * inventory_slot_size,
            .y = grid.origin.y + min_row * inventory_slot_size,
        };
        const region_width = (max_col - min_col + 1) * inventory_slot_size;
        const region_height = (max_row - min_row + 1) * inventory_slot_size;
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = region_origin,
            .width = region_width,
            .height = region_height,
            .color = lightest,
            .filled = false,
            .blocks_input = false,
        } });
    }
}

/// Font size for the gear-panel combat-stat lines.
pub const gear_stat_font_size: i32 = 56;

/// The combat-stat labels shown in the gear panel, in display order. Shared
/// between `gearPanelWidth` (measures the longest line for the panel width)
/// and `buildGearPanel` (renders them). Values are runtime, so width is
/// measured against a max-digit template, not the live value.
const gear_stat_labels = [_][]const u8{
    "Main Hand Damage",
    "Off Hand Damage",
    "Spell Damage",
    "Max Health",
    "Defense",
    "Pickup Radius",
    "Speed",
};

/// Gear panel width, derived from the longest stat line so the stats
/// column (flush against the gear stack) fits without truncation.
/// Mirrors the tooltip/error-popup approach (`measureSpanWidth` → content
/// width + padding). Layout: weapon row (2 slots + gap) on top; gear stack
/// (1 slot) under main-hand; stats flush against the gear stack's right
/// edge, starting under the off-hand. Width = margin + slot + stats +
/// margin.
pub fn gearPanelWidth(font_metrics: FontMetrics) i32 {
    // Value gutter: space + up to 2 digits (stats are bounded; see balance
    // bounds in loaders.zig). Keeps the width stable as values change.
    const value_gutter = font_metrics.measureSpanWidth(text(" 99"), gear_stat_font_size);
    var stats_width: i32 = 0;
    for (gear_stat_labels) |label| {
        const line_width = font_metrics.measureSpanWidth(text(label), gear_stat_font_size) + value_gutter;
        if (line_width > stats_width) stats_width = line_width;
    }
    // Non-weapon row content: panel margin (ui_gap) + 1 slot.
    const non_weapon_row_width = ui_gap + inventory_slot_size;
    // Stats content: stats text + panel margin (ui_gap).
    const stats_column_width = stats_width + ui_gap;
    return non_weapon_row_width + stats_column_width;
}

/// Gear panel: equipped weapons (main/off hand) top-left, then amulet →
/// coat → gloves → pants → boots stacked below the main-hand, and combat
/// stats flush against the gear stack's right edge (starting under the
/// off-hand). All slots + item icons 128×128 (`inventory_slot_size`).
/// Panel width is derived from the longest stat line (`gearPanelWidth`);
/// height shares `middle_panel_height` with the other middle panels.
/// Slots carry `ref = .{ .gear = ... }` so drag to/from inventory works
/// (equip/unequip via the existing orchestrator mapping). The item icon is
/// suppressed on the drag source (shown only as the ghost).
pub fn buildGearPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    player: Entity,
    learned_skills: []const types.SkillId,
    active_theme: types.ActiveColorTheme,
    drag_source: ?SlotRef,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, "Gear", .toggle_gear);

    const p = active_theme.player_gradient.colors;
    const slot_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const item_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const origin = content.position();
    const cell_size = inventory_slot_size;

    // Emit one gear slot: frame + item icon (suppressed on drag source) +
    // tooltip. The frame carries the ref (drag source + drop target).
    const emitGearSlot = struct {
        fn run(
            elems: *UiElementList,
            alloc: std.mem.Allocator,
            metrics: FontMetrics,
            theme: types.ActiveColorTheme,
            cell_pos: ScreenPosition,
            gear_slot: GearSlot,
            pl: Entity,
            skills: []const types.SkillId,
            s_color: Color,
            i_color: Color,
            src: ?SlotRef,
        ) !void {
            const ref: SlotRef = .{ .gear = gear_slot };
            const is_drag_source = if (src) |s| s.eql(ref) else false;
            const item = gearSlotItem(pl, gear_slot);
            // Equipped-item tooltips show no comparisons (an item
            // compared to itself is all zeros).
            const slot_tooltip: ?Tooltip = if (item) |it|
                try buildItemTooltip(alloc, it, skills, null)
            else
                null;
            try elems.append(alloc, .{ .slot = .{
                .screen_position = cell_pos,
                .size = cell_size,
                .icon_sprite_id = "ui/item_slot",
                .icon_color = s_color,
                .ref = ref,
                .tooltip = slot_tooltip,
            } });
            // Item icon on top, suppressed on the drag source ("in flight").
            if (!is_drag_source) {
                if (item) |it| {
                    try elems.append(alloc, .{ .image = .{
                        .sprite_id = itemIconSpriteId(it),
                        .screen_position = cell_pos,
                        .width = cell_size,
                        .height = cell_size,
                        .color = i_color,
                        .blocks_input = false,
                    } });
                    // The equipped item's stat numbers — plain LIGHTEST (no
                    // baseline: this gear IS the baseline, the same
                    // convention as the suppressed tooltip comparisons).
                    try emitItemStatLabels(
                        elems,
                        alloc,
                        metrics,
                        cell_pos,
                        cell_size,
                        it,
                        skills,
                        null,
                        theme,
                    );
                }
            }
        }
    }.run;

    // Weapons: main_hand + off_hand side by side on the top row.
    const top_y = origin.y + ui_gap;
    const col0_x = origin.x + ui_gap;
    const col1_x = col0_x + cell_size + ui_gap;
    try emitGearSlot(elements, allocator, font_metrics, active_theme, .{ .x = col0_x, .y = top_y }, .main_hand, player, learned_skills, slot_color, item_color, drag_source);
    try emitGearSlot(elements, allocator, font_metrics, active_theme, .{ .x = col1_x, .y = top_y }, .off_hand, player, learned_skills, slot_color, item_color, drag_source);

    // Gear stack: amulet → coat → gloves → pants → boots, each one row below
    // the weapons, under the main-hand column.
    const gear_slots = [_]GearSlot{ .amulet, .coat, .gloves, .pants, .boots };
    var row_y = top_y + cell_size + ui_gap;
    for (gear_slots) |gs| {
        try emitGearSlot(elements, allocator, font_metrics, active_theme, .{ .x = col0_x, .y = row_y }, gs, player, learned_skills, slot_color, item_color, drag_source);
        row_y += cell_size + ui_gap;
    }

    // Combat stats flush against the gear stack's right edge (no gap),
    // flowing down under the off-hand. Effective values (gear + effect
    // modifiers + momentum where applicable). See `getEffective*` on Entity.
    const stats_x = col0_x + cell_size;
    const stats_top = top_y + cell_size + ui_gap;
    const stat_line_height: i32 = gear_stat_font_size + 16;

    const main_damage = if (player.main_hand_weapon) |w| player.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const off_damage = if (player.off_hand_weapon) |w| player.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const stat_values = [_]u32{
        main_damage,
        off_damage,
        player.getEffectiveSpellDamage(),
        player.getEffectiveMaxHealth(),
        player.getEffectiveDefense(),
        player.getEffectivePickupRadius(0),
        player.getEffectiveSpeed(),
    };

    var stat_y = stats_top;
    for (gear_stat_labels, stat_values) |label, value| {
        const line = try std.fmt.allocPrint(allocator, "{s} {d}", .{ label, value });
        try elements.append(allocator, .{ .text_label = .{
            .text = line,
            .screen_position = .{ .x = stats_x, .y = stat_y },
            .font_size = gear_stat_font_size,
            .blocks_input = false,
        } });
        stat_y += stat_line_height;
    }
}

/// Entity-inspect panel (right-click an entity in a level). Read-only
/// mirror of the player's skill bar + active effects + gear panel, tinted
/// with the inspected entity's TEAM gradient (player gradient for team 0,
/// enemy gradient otherwise). No slots carry a `SlotRef` and no buttons
/// carry an `Action` — nothing is draggable or clickable; tooltips still
/// work on hover. Opened by right-clicking a tile with an entity (see
/// `handleRightClickInspect` in input_handlers). See DESIGN → UI Framework
/// → Entity inspect.
///
/// Layout (top to bottom inside the panel):
///   1. Skill bar — 4×2 grid of `slot_size` (256) slots, slots 1-4 top row,
///      5-8 bottom. Empty slots show the diamond marker; cooldowns show
///      the translucent wash + remaining-turns number.
///   2. Active effects — `small_icon_size` (128) icons flowing left→right
///      then wrapping down, max 8 columns. Omitted entirely when the entity
///      has no active effects.
///   3. Gear mirror — weapons (main/off hand) top-left, amulet→coat→gloves→
///      pants→boots stacked below the main-hand, combat-stat column flush
///      against the gear stack's right edge (under the off-hand). All 128×128 (`inventory_slot_size`).
pub fn buildEntityInspectPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    entity: Entity,
    learned_skills: []const types.SkillId,
    /// The PLAYER's equipped gear — baseline for the inspected entity's
    /// gear-tooltip comparisons (dropped enemy gear is directly usable,
    /// so the comparison is actionable). Null (inspecting the player
    /// itself, or no player) suppresses comparisons.
    equipped: ?EquippedGear,
    active_theme: types.ActiveColorTheme,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, entity.name, .toggle_entity_inspect);

    // Team gradient: player (team 0) vs enemy (team ≠ 0). Same fixed
    // indices the bottom bar + gear panel use, resolved against the team's
    // own gradient instead of always the player's.
    const g = if (entity.team == 0) active_theme.player_gradient.colors else active_theme.enemy_gradient.colors;
    const c_skill_frame = g[@min(@as(u32, 3), types.gradient_color_count - 1)];
    const c_skill_icon = g[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const c_gear_slot = g[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const c_gear_item = g[@min(@as(u32, 1), types.gradient_color_count - 1)];
    const cooldown_overlay_color = active_theme.darkest;

    const origin = content.position();

    // --- Skill bar: 4×2 grid of slot_size slots ---
    const skill_grid_origin: ScreenPosition = .{
        .x = origin.x + ui_gap,
        .y = origin.y + ui_gap,
    };
    const skill_grid = Grid{
        .origin = skill_grid_origin,
        .cell_width = slot_size,
        .cell_height = slot_size,
        .gap = 0,
        .columns = 4,
    };
    const skill_slots = entity.collectSkillSlots(weapon_type_definitions);
    for (skill_slots, 0..) |maybe_skill, index| {
        const cell = skill_grid.cell(@intCast(index));
        if (maybe_skill) |skill_id| {
            const definition = lookups.getSkillDefinition(skill_id) orelse {
                // Unknown skill id — render the empty marker rather than crash.
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = "ui/skill_slot_empty",
                    .screen_position = cell.position(),
                    .width = cell.width,
                    .height = cell.height,
                    .color = c_skill_frame,
                } });
                continue;
            };
            try elements.append(allocator, .{ .image = .{
                .sprite_id = "ui/skill_button",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = c_skill_frame,
                .tooltip = try buildSkillTooltip(allocator, definition),
            } });
            try elements.append(allocator, .{ .image = .{
                .sprite_id = skillIconSpriteId(skill_id),
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = c_skill_icon,
                .blocks_input = false,
            } });
            const cooldown = entity.skill_cooldowns.get(skill_id);
            if (cooldown > 0) {
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = "ui/skill_button",
                    .screen_position = cell.position(),
                    .width = cell.width,
                    .height = cell.height,
                    .color = cooldown_overlay_color,
                    .alpha = 128,
                    .blocks_input = false,
                } });
                try emitCenteredNumber(elements, allocator, font_metrics, cell, cooldown, cooldown_font_size);
            }
        } else {
            // Empty slot — diamond marker, same as the skill bar.
            try elements.append(allocator, .{ .image = .{
                .sprite_id = "ui/skill_slot_empty",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = c_skill_frame,
            } });
        }
    }

    // --- Active effects: 128px icons, max 8 columns, left→right then down ---
    var cursor_y = skill_grid_origin.y + 2 * slot_size + ui_gap;
    if (entity.active_effects.len > 0) {
        const effects_origin: ScreenPosition = .{
            .x = origin.x + ui_gap,
            .y = cursor_y,
        };
        const effect_columns: i32 = 8;
        for (entity.active_effects, 0..) |effect, index| {
            const ordinal: i32 = @intCast(index);
            const column = @mod(ordinal, effect_columns);
            const grid_row = @divFloor(ordinal, effect_columns);
            const cell: Rectangle = .{
                .x = effects_origin.x + column * small_icon_size,
                .y = effects_origin.y + grid_row * small_icon_size,
                .width = small_icon_size,
                .height = small_icon_size,
            };
            const definition = lookups.getEffectDefinition(effect.effect_id);
            try elements.append(allocator, .{ .image = .{
                .sprite_id = effectIconSpriteId(effect.effect_id, definition),
                .screen_position = cell.position(),
                .width = small_icon_size,
                .height = small_icon_size,
                .color = c_skill_icon,
                .tooltip = .{
                    .header = try spanRow(allocator, text(definition.name)),
                    .body = try allocator.dupe(TooltipRow, &.{
                        try spanRow(allocator, text(definition.description)),
                        try spanRow(allocator, text(
                            try std.fmt.allocPrint(allocator, "Current duration {d}", .{effect.duration}),
                        )),
                    }),
                },
            } });
            try emitCornerNumber(elements, allocator, font_metrics, cell, effect.duration);
        }
        const effect_rows = @divTrunc(@as(i32, @intCast(entity.active_effects.len)) + effect_columns - 1, effect_columns);
        cursor_y += effect_rows * small_icon_size + ui_gap;
    }

    // --- Gear mirror: weapons row + gear stack + stat column ---
    const gear_top_y = cursor_y;
    const gear_cell_size = inventory_slot_size;
    const col0_x = origin.x + ui_gap;
    const col1_x = col0_x + gear_cell_size + ui_gap;

    const emitGearSlot = struct {
        fn run(
            elems: *UiElementList,
            alloc: std.mem.Allocator,
            metrics: FontMetrics,
            theme: types.ActiveColorTheme,
            cell_pos: ScreenPosition,
            gear_slot: GearSlot,
            ent: Entity,
            skills: []const types.SkillId,
            item_equipped: ?EquippedGear,
            s_color: Color,
            i_color: Color,
        ) !void {
            const item = gearSlotItem(ent, gear_slot);
            const slot_tooltip: ?Tooltip = if (item) |it|
                try buildItemTooltip(alloc, it, skills, item_equipped)
            else
                null;
            try elems.append(alloc, .{ .image = .{
                .sprite_id = "ui/item_slot",
                .screen_position = cell_pos,
                .width = gear_cell_size,
                .height = gear_cell_size,
                .color = s_color,
                .tooltip = slot_tooltip,
            } });
            if (item) |it| {
                try elems.append(alloc, .{ .image = .{
                    .sprite_id = itemIconSpriteId(it),
                    .screen_position = cell_pos,
                    .width = gear_cell_size,
                    .height = gear_cell_size,
                    .color = i_color,
                    .blocks_input = false,
                } });
                // The item's stat numbers, the same baseline as the slot
                // tooltip's comparisons: the PLAYER's equipped gear when
                // inspecting an enemy (dropped enemy gear is directly
                // usable), plain lightest when inspecting the player (no
                // baseline — its own gear).
                try emitItemStatLabels(
                    elems,
                    alloc,
                    metrics,
                    cell_pos,
                    gear_cell_size,
                    it,
                    skills,
                    item_equipped,
                    theme,
                );
            }
        }
    }.run;

    try emitGearSlot(elements, allocator, font_metrics, active_theme, .{ .x = col0_x, .y = gear_top_y }, .main_hand, entity, learned_skills, equipped, c_gear_slot, c_gear_item);
    try emitGearSlot(elements, allocator, font_metrics, active_theme, .{ .x = col1_x, .y = gear_top_y }, .off_hand, entity, learned_skills, equipped, c_gear_slot, c_gear_item);

    const gear_slots = [_]GearSlot{ .amulet, .coat, .gloves, .pants, .boots };
    var row_y = gear_top_y + gear_cell_size + ui_gap;
    for (gear_slots) |gs| {
        try emitGearSlot(elements, allocator, font_metrics, active_theme, .{ .x = col0_x, .y = row_y }, gs, entity, learned_skills, equipped, c_gear_slot, c_gear_item);
        row_y += gear_cell_size + ui_gap;
    }

    // Combat-stat column (flush against the gear stack, same as
    // buildGearPanel).
    const stats_x = col0_x + gear_cell_size;
    const stats_top = gear_top_y + gear_cell_size + ui_gap;
    const stat_line_height: i32 = gear_stat_font_size + 16;
    // The inspect stat column leads with the entity's team, then its
    // live combat state (current health, momentum, aggro range), then
    // the effective gear stats — the player gear panel shares only the
    // gear-stat tail.
    const entity_stat_labels = [_][]const u8{ "Team", "Current Health", "Momentum", "Aggro Range" } ++ gear_stat_labels;
    const main_damage = if (entity.main_hand_weapon) |w| entity.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const off_damage = if (entity.off_hand_weapon) |w| entity.getEffectiveOutgoingDamage(w.weapon_damage) else 0;
    const stat_values = [_]u32{
        entity.team,
        entity.current_health,
        entity.momentum,
        entity.aggro_range,
        main_damage,
        off_damage,
        entity.getEffectiveSpellDamage(),
        entity.getEffectiveMaxHealth(),
        entity.getEffectiveDefense(),
        entity.getEffectivePickupRadius(0),
        entity.getEffectiveSpeed(),
    };
    var stat_y = stats_top;
    for (entity_stat_labels, stat_values) |label, value| {
        const line = try std.fmt.allocPrint(allocator, "{s} {d}", .{ label, value });
        try elements.append(allocator, .{ .text_label = .{
            .text = line,
            .screen_position = .{ .x = stats_x, .y = stat_y },
            .font_size = gear_stat_font_size,
            .blocks_input = false,
        } });
        stat_y += stat_line_height;
    }
}

/// Skills browser panel: a 9-slice background, then a 4-wide grid of
/// `slot_size` (256) skill slots filling downward from the top-left, one
/// per learned skill in `learned_skills` order (parsed order — no
/// sorting/grouping/search yet). Each slot is a `ui/skill_button` frame
/// tinted with player-gradient index 3 carrying `ref = .{ .learned_skill =
/// ... }` (drag source/drop target) + a non-blocking `skills/<tag>` icon
/// overlay tinted with index 1, mirroring the skill bar. No `action` —
/// clicking a browser entry doesn't fire a skill (it's not on the bar);
/// drag-to-bar is not wired (see TODO → UI Framework). The drag source's
/// icon is suppressed ("in flight"), matching inventory/gear.
///
/// Vertical overflow is cut at a full skill's bottom (no half-skills): only
/// whole rows within the visible height are emitted. A scrollbar (track +
/// proportional thumb) sits in the right `ui_gap` margin when the skill
/// count exceeds the visible rows. `scroll_offset` (in rows) is clamped to
/// `[0, max_scroll_row]` here — the authoritative clamp, since only the
/// view knows `max_scroll_row`.
pub fn buildSkillsPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    bounds: Rectangle,
    learned_skills: []const SkillId,
    active_theme: types.ActiveColorTheme,
    /// In/out: current scroll offset in rows; clamped here to `[0, max_scroll_row]`.
    scroll_offset: *i32,
    /// The slot currently being dragged from, if any. The skill icon is
    /// suppressed on the source slot so it reads as "in flight" (shown only
    /// as the drag ghost). The frame + ref still emit so the slot stays a
    /// drop target.
    drag_source: ?SlotRef,
) !void {
    // Solid panel background — blocks input through the panel area.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
    } });
    const content = try emitPanelHeader(elements, allocator, bounds, "Skills", .toggle_skills);

    const p = active_theme.player_gradient.colors;
    const frame_color = p[@min(@as(u32, 3), types.gradient_color_count - 1)];
    const icon_color = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const origin = content.position();
    const grid_origin: ScreenPosition = .{
        .x = origin.x + ui_gap,
        .y = origin.y + ui_gap,
    };
    const grid_height = content.height - 2 * ui_gap;
    const visible_rows = @divFloor(grid_height, slot_size);
    const total_rows = @divTrunc(@as(i32, @intCast(learned_skills.len)) + skills_panel_columns - 1, skills_panel_columns);
    const max_scroll_row = @max(@as(i32, 0), total_rows - visible_rows);
    // Authoritative clamp (the input handler can't know max_scroll_row).
    if (scroll_offset.* < 0) scroll_offset.* = 0;
    if (scroll_offset.* > max_scroll_row) scroll_offset.* = max_scroll_row;
    const first_row = scroll_offset.*;

    const grid = Grid{
        .origin = grid_origin,
        .cell_width = slot_size,
        .cell_height = slot_size,
        .gap = 0,
        .columns = skills_panel_columns,
    };

    // Emit only the fully-visible rows, drawn at the TOP of the grid region
    // (view-relative positions — the scrollbar thumb conveys the scroll
    // position, same pattern as `buildErrorPopup`'s body window). A row that
    // wouldn't fully fit is not emitted (no half-skills).
    const visible_row_count = @min(visible_rows, @max(@as(i32, 0), total_rows - first_row));
    var view_row: i32 = 0;
    while (view_row < visible_row_count) : (view_row += 1) {
        var column: i32 = 0;
        while (column < skills_panel_columns) : (column += 1) {
            const index: usize = @intCast((first_row + view_row) * skills_panel_columns + column);
            if (index >= learned_skills.len) break;
            const skill_id = learned_skills[index];
            const cell = grid.cell(view_row * skills_panel_columns + column);
            const ref: SlotRef = .{ .learned_skill = skill_id };
            const is_drag_source = if (drag_source) |src| src.eql(ref) else false;
            // Drag source: render the empty-slot diamond so the skill reads
            // as "in flight" (shown only as the drag ghost following the
            // pointer). The frame keeps its ref so the slot stays a drop
            // target for a same-slot drop (a no-op). Mirrors `emitSkillButton`'s
            // drag-source / empty handling. No tooltip — globally suppressed
            // while a drag is active anyway (see view.zig).
            if (is_drag_source) {
                try elements.append(allocator, .{ .slot = .{
                    .screen_position = cell.position(),
                    .size = slot_size,
                    .icon_sprite_id = "ui/skill_slot_empty",
                    .icon_color = frame_color,
                    .ref = ref,
                } });
                continue;
            }
            const definition = lookups.getSkillDefinition(skill_id);
            const slot_tooltip: ?Tooltip = if (definition) |def|
                try buildSkillTooltip(allocator, def)
            else
                null;
            // Frame carries the slot identity (drag source + drop target).
            try elements.append(allocator, .{ .slot = .{
                .screen_position = cell.position(),
                .size = slot_size,
                .icon_sprite_id = "ui/skill_button",
                .icon_color = frame_color,
                .ref = ref,
                .tooltip = slot_tooltip,
            } });
            // Skill icon on top.
            {
                try elements.append(allocator, .{ .image = .{
                    .sprite_id = skillIconSpriteId(skill_id),
                    .screen_position = cell.position(),
                    .width = slot_size,
                    .height = slot_size,
                    .color = icon_color,
                    .blocks_input = false,
                } });
            }
        }
    }

    // Scrollbar (only when the skill count overflows the visible rows). Track
    // + proportional thumb in the right `ui_gap` margin, spanning the grid's
    // height. Mirrors `buildErrorPopup`'s scrollbar geometry.
    if (total_rows > visible_rows) {
        const track_x = origin.x + bounds.width - ui_gap +
            @divFloor(ui_gap - skills_scrollbar_width, 2);
        const track_y = grid_origin.y;
        const track_height = visible_rows * slot_size;
        const track_color: types.Color = .{ .r = 80, .g = 80, .b = 80 };
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = track_y },
            .width = skills_scrollbar_width,
            .height = track_height,
            .color = track_color,
        } });
        const thumb_height = @max(
            @as(i32, 40),
            @divTrunc(track_height * visible_rows, total_rows),
        );
        const thumb_y = track_y +
            @divTrunc(scroll_offset.* * (track_height - thumb_height), max_scroll_row);
        const thumb_color: types.Color = .{ .r = 180, .g = 180, .b = 180 };
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = track_x, .y = thumb_y },
            .width = skills_scrollbar_width,
            .height = thumb_height,
            .color = thumb_color,
        } });
    }

    _ = font_metrics;
}

test "buildInventoryPanel: item stat numbers in the icon corners, colored by the equipped comparison" {
    // The stat numbers ride the item icons (see emitItemStatLabels): the
    // stat VALUE (not the signed difference — the tooltip carries that),
    // material-count label recipe (font size + inset + outlined,
    // non-blocking so the slot keeps its tooltip). An unlearned skill
    // tome wears a green outlined "!" (a learned one shows nothing).
    // Colors: green while
    // better than equipped, red while worse, lightest while equal; a
    // weapon compares INCLUSIVELY against both hands — green while ≥ each
    // hand and strictly better than at least one, red while ≤ each hand
    // and strictly worse than at least one, lightest when equal to BOTH
    // hands (a pure sidegrade) or strictly between them. Expected
    // positions are
    // DERIVED from the emitted slot elements' own cells (not re-derived
    // layout math).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 9, .g = 9, .b = 9 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = ui_element.inventory_panel_width,
        .height = middle_panel_height,
    };

    // Equipped baseline: main hand 5, off hand 3, boots (health 4,
    // speed 1), no amulet (empty slot compares against 0).
    const equipped = EquippedGear{
        .main_hand_weapon = .{ .weapon_damage = 5 },
        .off_hand_weapon = .{ .weapon_damage = 3 },
        .boots = .{ .health_bonus = 4, .speed_bonus = 1 },
    };

    var inventory = types.Inventory{};
    // Slot 0: weapon 7 beats both hands → green.
    inventory.slots[0] = .{ .weapon = .{ .weapon_damage = 7 } };
    // Slot 1: weapon 5 EQUALS the main hand, beats the off hand → green
    // (the inclusive rule: ≥ each hand — a weapon matching your best
    // hand is still green, it upgrades the other).
    inventory.slots[1] = .{ .weapon = .{ .weapon_damage = 5 } };
    // Slot 2: weapon 4 beats the off hand (3), strictly loses to the main
    // (5) → lightest (strictly between the two hands: no clear upgrade).
    inventory.slots[2] = .{ .weapon = .{ .weapon_damage = 4 } };
    // Slot 3: boots — health 4 equal → lightest (bottom-left), speed 2 > 1 →
    // green (bottom-right).
    inventory.slots[3] = .{ .boots = .{ .health_bonus = 4, .speed_bonus = 2 } };
    // Slot 4: amulet 3 vs nothing equipped (0) → green.
    inventory.slots[4] = .{ .amulet = .{ .spell_damage = 3 } };
    // Slot 5: skill tome (default skill .slice, NOT in the empty learned
    // set) — a green outlined "!" bottom-left, no stat numbers.
    inventory.slots[5] = .{ .skill_tome = .{} };
    // Slot 6: weapon 3 EQUALS the off hand, strictly loses to the main →
    // red (the inclusive red: ≤ each hand — no hand is an upgrade).
    inventory.slots[6] = .{ .weapon = .{ .weapon_damage = 3 } };
    // Slot 7: weapon 2 strictly loses to both → red.
    inventory.slots[7] = .{ .weapon = .{ .weapon_damage = 2 } };

    var elements: UiElementList = .empty;
    try buildInventoryPanel(
        &elements,
        arena.allocator(),
        metrics,
        bounds,
        inventory,
        .{},
        &.{},
        equipped,
        theme,
        null,
        .{},
        null,
    );

    // A slot's cell position, read off the emitted slot element (the
    // grid layout itself is not re-derived here).
    const slotCell = struct {
        fn call(items: []const ui_element.UiElement, index: u32) ScreenPosition {
            for (items) |element| switch (element) {
                .slot => |slot| if (slot.ref) |slot_ref| switch (slot_ref) {
                    .inventory => |slot_index| {
                        if (slot_index == index) return slot.screen_position;
                    },
                    else => {},
                },
                else => {},
            };
            @panic("inventory slot element not found");
        }
    }.call;
    // Expected label positions for the two corners (the emitter's own
    // formula — the bottom-right one measures the label's width through
    // the same metrics).
    const bottomLeft = struct {
        fn call(cell: ScreenPosition) ScreenPosition {
            return .{
                .x = cell.x + material_count_inset,
                .y = cell.y + inventory_slot_size - material_count_font_size - material_count_inset,
            };
        }
    }.call;
    const bottomRight = struct {
        fn call(cell: ScreenPosition, label_text: []const u8) ScreenPosition {
            const width = metrics.measureSpanWidth(text(label_text), material_count_font_size);
            return .{
                .x = cell.x + inventory_slot_size - width - material_count_inset,
                .y = cell.y + inventory_slot_size - material_count_font_size - material_count_inset,
            };
        }
    }.call;
    // Exactly one stat label at the expected position with the expected
    // text + color, carrying the full recipe (font size, outline,
    // non-blocking).
    const assertLabel = struct {
        fn call(
            items: []const ui_element.UiElement,
            expected_text: []const u8,
            expected_position: ScreenPosition,
            expected_color: Color,
        ) !void {
            var matches: usize = 0;
            for (items) |element| switch (element) {
                .text_label => |label| {
                    if (std.mem.eql(u8, label.text, expected_text) and
                        label.screen_position.x == expected_position.x and
                        label.screen_position.y == expected_position.y)
                    {
                        matches += 1;
                        try std.testing.expectEqual(expected_color, label.color);
                        try std.testing.expectEqual(material_count_font_size, label.font_size);
                        try std.testing.expect(label.outlined);
                        try std.testing.expect(!label.blocks_input);
                    }
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 1), matches);
        }
    }.call;

    // The weapon comparison band against hands (5, 3): beats both →
    // green; equals the main hand (inclusive ≥) → green; strictly between
    // → lightest; equals the off hand (inclusive ≤) → red; loses to both
    // → red.
    try assertLabel(elements.items, "7", bottomLeft(slotCell(elements.items, 0)), positive_color);
    try assertLabel(elements.items, "5", bottomLeft(slotCell(elements.items, 1)), positive_color);
    try assertLabel(elements.items, "4", bottomLeft(slotCell(elements.items, 2)), lightest);
    try assertLabel(elements.items, "3", bottomLeft(slotCell(elements.items, 6)), negative_color);
    try assertLabel(elements.items, "2", bottomLeft(slotCell(elements.items, 7)), negative_color);
    // The boots' two stats: health equal → lightest bottom-left, speed
    // better → green bottom-right.
    try assertLabel(elements.items, "4", bottomLeft(slotCell(elements.items, 3)), lightest);
    try assertLabel(
        elements.items,
        "2",
        bottomRight(slotCell(elements.items, 3), "2"),
        positive_color,
    );
    // The amulet vs nothing equipped (baseline 0) → green.
    try assertLabel(elements.items, "3", bottomLeft(slotCell(elements.items, 4)), positive_color);
    // The UNLEARNED skill tome: a green outlined "!" bottom-left (the
    // learned set is empty — see the tie pass for the learned case).
    try assertLabel(elements.items, "!", bottomLeft(slotCell(elements.items, 5)), positive_color);

    // Census: the stat numbers over the item GRID are exactly the nine
    // above (the material sidebar's count labels sit beyond the grid's
    // right edge, the empty slots contribute none).
    {
        const grid_left = slotCell(elements.items, 0).x;
        const grid_right = grid_left + types.inventory_columns * inventory_slot_size;
        var stat_labels: usize = 0;
        for (elements.items) |element| switch (element) {
            .text_label => |label| {
                if (label.font_size == material_count_font_size and
                    label.screen_position.x >= grid_left and label.screen_position.x < grid_right)
                {
                    stat_labels += 1;
                }
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 9), stat_labels);
    }

    // The FULL-TIE case (weapon 5 vs hands 5/5): swapping changes
    // nothing — lightest, not green (the inclusive ≥ rule needs strictly
    // better than at least one hand).
    {
        var elements_tie: UiElementList = .empty;
        const learned = [_]SkillId{.slice};
        try buildInventoryPanel(
            &elements_tie,
            arena.allocator(),
            metrics,
            bounds,
            inventory,
            .{},
            &learned,
            EquippedGear{
                .main_hand_weapon = .{ .weapon_damage = 5 },
                .off_hand_weapon = .{ .weapon_damage = 5 },
            },
            theme,
            null,
            .{},
            null,
        );
        try assertLabel(elements_tie.items, "5", bottomLeft(slotCell(elements_tie.items, 1)), lightest);
        // And strictly-below-both stays red under the inclusive operators.
        try assertLabel(elements_tie.items, "4", bottomLeft(slotCell(elements_tie.items, 2)), negative_color);
        // A LEARNED skill tome (slice ∈ learned) shows NO marker —
        // nothing in the grid reads "!".
        for (elements_tie.items) |element| switch (element) {
            .text_label => |label| try std.testing.expect(!std.mem.eql(u8, label.text, "!")),
            else => {},
        };
    }

    // Drag-source suppression: the dragged slot's item reads as in
    // flight — icon + stat numbers + the tome marker all suppressed
    // (two fewer: the boots' health + speed — 9 → 7).
    {
        var elements_dragged: UiElementList = .empty;
        try buildInventoryPanel(
            &elements_dragged,
            arena.allocator(),
            metrics,
            bounds,
            inventory,
            .{},
            &.{},
            equipped,
            theme,
            .{ .inventory = 3 },
            .{},
            null,
        );
        const grid_left = slotCell(elements_dragged.items, 0).x;
        const grid_right = grid_left + types.inventory_columns * inventory_slot_size;
        var stat_labels: usize = 0;
        for (elements_dragged.items) |element| switch (element) {
            .text_label => |label| {
                if (label.font_size == material_count_font_size and
                    label.screen_position.x >= grid_left and label.screen_position.x < grid_right)
                {
                    stat_labels += 1;
                }
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 7), stat_labels);
    }
}

test "buildGearPanel: equipped items wear plain-lightest stat numbers, suppressed on the drag source" {
    // The gear panel's own items have NO comparison baseline (this gear IS
    // the baseline — the same convention as its suppressed tooltip
    // comparisons), so every stat number renders plain lightest. Same
    // recipe as the inventory numbers (corners, font size, outline,
    // non-blocking), suppressed on the drag source with the icon.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 9, .g = 9, .b = 9 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };

    // The player's equipped gear: main-hand weapon (damage 5) + coat
    // (health 4, defense 2).
    const player = Entity{
        .main_hand_weapon = .{ .weapon_damage = 5 },
        .coat = .{ .health_bonus = 4, .defense_bonus = 2 },
    };

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = gearPanelWidth(metrics),
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildGearPanel(&elements, arena.allocator(), metrics, bounds, player, &.{}, theme, null);

    // A gear slot's cell position, read off the emitted slot element by
    // its ref (no re-derived layout math).
    const gearCell = struct {
        fn call(items: []const ui_element.UiElement, gear_slot: GearSlot) ScreenPosition {
            for (items) |element| switch (element) {
                .slot => |slot| if (slot.ref) |slot_ref| switch (slot_ref) {
                    .gear => |gs| {
                        if (gs == gear_slot) return slot.screen_position;
                    },
                    else => {},
                },
                else => {},
            };
            @panic("gear slot element not found");
        }
    }.call;
    const bottomLeft = struct {
        fn call(cell: ScreenPosition) ScreenPosition {
            return .{
                .x = cell.x + material_count_inset,
                .y = cell.y + inventory_slot_size - material_count_font_size - material_count_inset,
            };
        }
    }.call;
    const bottomRight = struct {
        fn call(cell: ScreenPosition, label_text: []const u8) ScreenPosition {
            const width = metrics.measureSpanWidth(text(label_text), material_count_font_size);
            return .{
                .x = cell.x + inventory_slot_size - width - material_count_inset,
                .y = cell.y + inventory_slot_size - material_count_font_size - material_count_inset,
            };
        }
    }.call;
    const assertLabel = struct {
        fn call(
            items: []const ui_element.UiElement,
            expected_text: []const u8,
            expected_position: ScreenPosition,
            expected_color: Color,
        ) !void {
            var matches: usize = 0;
            for (items) |element| switch (element) {
                .text_label => |label| {
                    if (std.mem.eql(u8, label.text, expected_text) and
                        label.screen_position.x == expected_position.x and
                        label.screen_position.y == expected_position.y)
                    {
                        matches += 1;
                        try std.testing.expectEqual(expected_color, label.color);
                        try std.testing.expectEqual(material_count_font_size, label.font_size);
                        try std.testing.expect(label.outlined);
                        try std.testing.expect(!label.blocks_input);
                    }
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 1), matches);
        }
    }.call;

    // Plain lightest — no baseline, this gear IS the baseline.
    try assertLabel(elements.items, "5", bottomLeft(gearCell(elements.items, .main_hand)), lightest);
    try assertLabel(elements.items, "4", bottomLeft(gearCell(elements.items, .coat)), lightest);
    try assertLabel(
        elements.items,
        "2",
        bottomRight(gearCell(elements.items, .coat), "2"),
        lightest,
    );

    // Drag-source suppression: dragging the main hand suppresses its
    // icon + number; the coat's pair remains.
    {
        var elements_dragged: UiElementList = .empty;
        try buildGearPanel(
            &elements_dragged,
            arena.allocator(),
            metrics,
            bounds,
            player,
            &.{},
            theme,
            .{ .gear = .main_hand },
        );
        for (elements_dragged.items) |element| switch (element) {
            .text_label => |label| {
                if (label.font_size == material_count_font_size) {
                    try std.testing.expect(!std.mem.eql(u8, label.text, "5"));
                }
            },
            else => {},
        };
        try assertLabel(
            elements_dragged.items,
            "4",
            bottomLeft(gearCell(elements_dragged.items, .coat)),
            lightest,
        );
    }
}

test "buildEntityInspectPanel: item stat numbers colored against the player's equipped gear" {
    // The inspect panel's numbers use the SAME baseline as its slot
    // tooltips: the PLAYER's equipped gear when inspecting an enemy
    // (dropped enemy gear is directly usable), plain lightest when
    // inspecting the player itself (no baseline). The inspect slots are
    // read-only IMAGES (no SlotRef), so cell positions come from the
    // item-slot FRAMES in emission order: main hand, off hand, then
    // amulet, coat, gloves, pants, boots.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lightest: types.Color = .{ .r = 9, .g = 9, .b = 9 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = lightest,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    // An enemy with a weapon (damage 6) and a coat (health 2, defense 3).
    var enemy: Entity = .{};
    enemy.team = 1;
    enemy.main_hand_weapon = .{ .weapon_damage = 6 };
    enemy.coat = .{ .health_bonus = 2, .defense_bonus = 3 };

    // The player's equipped gear — the baseline: main hand 5, off hand 3,
    // coat (health 4, defense 1).
    const player_equipped = EquippedGear{
        .main_hand_weapon = .{ .weapon_damage = 5 },
        .off_hand_weapon = .{ .weapon_damage = 3 },
        .coat = .{ .health_bonus = 4, .defense_bonus = 1 },
    };

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(
        &elements,
        arena.allocator(),
        metrics,
        bounds,
        enemy,
        &.{},
        player_equipped,
        theme,
        &weapon_types,
    );

    const inspectCell = struct {
        fn call(items: []const ui_element.UiElement, ordinal: usize) ScreenPosition {
            var seen: usize = 0;
            for (items) |element| switch (element) {
                .image => |img| {
                    if (std.mem.eql(u8, img.sprite_id, "ui/item_slot")) {
                        if (seen == ordinal) return img.screen_position;
                        seen += 1;
                    }
                },
                else => {},
            };
            @panic("inspect gear frame not found");
        }
    }.call;
    const bottomLeft = struct {
        fn call(cell: ScreenPosition) ScreenPosition {
            return .{
                .x = cell.x + material_count_inset,
                .y = cell.y + inventory_slot_size - material_count_font_size - material_count_inset,
            };
        }
    }.call;
    const bottomRight = struct {
        fn call(cell: ScreenPosition, label_text: []const u8) ScreenPosition {
            const width = metrics.measureSpanWidth(text(label_text), material_count_font_size);
            return .{
                .x = cell.x + inventory_slot_size - width - material_count_inset,
                .y = cell.y + inventory_slot_size - material_count_font_size - material_count_inset,
            };
        }
    }.call;
    const assertLabel = struct {
        fn call(
            items: []const ui_element.UiElement,
            expected_text: []const u8,
            expected_position: ScreenPosition,
            expected_color: Color,
        ) !void {
            var matches: usize = 0;
            for (items) |element| switch (element) {
                .text_label => |label| {
                    if (std.mem.eql(u8, label.text, expected_text) and
                        label.screen_position.x == expected_position.x and
                        label.screen_position.y == expected_position.y)
                    {
                        matches += 1;
                        try std.testing.expectEqual(expected_color, label.color);
                        try std.testing.expectEqual(material_count_font_size, label.font_size);
                        try std.testing.expect(label.outlined);
                        try std.testing.expect(!label.blocks_input);
                    }
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 1), matches);
        }
    }.call;

    // The enemy's weapon (6) vs the player's hands (5, 3): ≥ each +
    // strictly better than both → green. The coat vs the player's coat:
    // health 2 < 4 → red bottom-left; defense 3 > 1 → green bottom-right.
    try assertLabel(elements.items, "6", bottomLeft(inspectCell(elements.items, 0)), positive_color);
    try assertLabel(elements.items, "2", bottomLeft(inspectCell(elements.items, 3)), negative_color);
    try assertLabel(
        elements.items,
        "3",
        bottomRight(inspectCell(elements.items, 3), "3"),
        positive_color,
    );

    // Inspecting the PLAYER itself: no baseline → plain-lightest numbers.
    {
        var elements_player: UiElementList = .empty;
        var player_entity: Entity = .{};
        player_entity.main_hand_weapon = .{ .weapon_damage = 5 };
        player_entity.coat = .{ .health_bonus = 4, .defense_bonus = 2 };
        try buildEntityInspectPanel(
            &elements_player,
            arena.allocator(),
            metrics,
            bounds,
            player_entity,
            &.{},
            null,
            theme,
            &weapon_types,
        );
        try assertLabel(
            elements_player.items,
            "5",
            bottomLeft(inspectCell(elements_player.items, 0)),
            lightest,
        );
        try assertLabel(
            elements_player.items,
            "4",
            bottomLeft(inspectCell(elements_player.items, 3)),
            lightest,
        );
        try assertLabel(
            elements_player.items,
            "2",
            bottomRight(inspectCell(elements_player.items, 3), "2"),
            lightest,
        );
    }
}

test "buildSkillsPanel: few skills — one row, slots + icons, no scrollbar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const learned = [_]SkillId{ .slice, .stab, .chop };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    var scroll_offset: i32 = 5; // clamped to 0 (no overflow)

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = skills_panel_width,
        .height = middle_panel_height,
    };
    try buildSkillsPanel(&elements, arena.allocator(), metrics, bounds, &learned, theme, &scroll_offset, null);

    // 1 panel + 2 header (title + close button) + 2 per skill (slot + icon),
    // no scrollbar.
    try std.testing.expectEqual(@as(usize, 1 + 2 + 2 * learned.len), elements.items.len);
    try std.testing.expectEqual(@as(i32, 0), scroll_offset); // clamped
    for (elements.items) |element| switch (element) {
        .solid_rect => @panic("unexpected scrollbar for few skills"),
        else => {},
    };
}

test "buildSkillsPanel: overflow — scrollbar present, only visible rows emitted, no half-skills" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 25 skills → more rows than fit → overflow (the exact row/window
    // arithmetic is the builder's; the test asserts the properties).
    const learned = [_]SkillId{
        .slice, .stab, .chop, .cleave,
        .slam, .skewer, .impale, .bash,
        .blink, .blitz, .focus, .howl,
        .meteor, .reflect, .replenish, .retreating_swipe,
        .spark, .spinblade, .stone_form, .swap,
        .that_which_lingers, .throw, .toss, .vampiric_strike,
        .flash_strike,
    };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    var scroll_offset: i32 = 100; // over-scrolled: clamps to the max row

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = skills_panel_width,
        .height = middle_panel_height,
    };
    try buildSkillsPanel(&elements, arena.allocator(), metrics, bounds, &learned, theme, &scroll_offset, null);

    // The over-scroll clamped somewhere in range (not 100), and the
    // LAST row is visible at the max — the last learned skill's slot
    // renders (max scroll reaches the end).
    try std.testing.expect(scroll_offset >= 0 and scroll_offset < 100);
    var last_skill_slot_seen = false;
    var slot_count: usize = 0;
    var icon_count: usize = 0;
    var solid_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .slot => |slot| {
            slot_count += 1;
            if (slot.ref != null and slot.ref.?.eql(.{ .learned_skill = .flash_strike })) {
                last_skill_slot_seen = true;
            }
        },
        .image => icon_count += 1,
        .solid_rect => solid_count += 1,
        else => {},
    };
    try std.testing.expect(last_skill_slot_seen);
    // Only the visible window's slots emit (fewer than all 25), each with
    // its icon; the scrollbar (track + thumb) is present.
    try std.testing.expect(slot_count < learned.len);
    try std.testing.expectEqual(slot_count, icon_count);
    try std.testing.expect(solid_count >= 2);

    // No slot's bottom edge exceeds the visible grid bottom (no
    // half-skills): the grid keeps one ui_gap of padding above the
    // panel's bottom edge, and windowed emission never crosses it.
    const grid_bottom = middle_panel_height - ui_gap;
    for (elements.items) |element| switch (element) {
        .slot => |slot| {
            const bottom = slot.screen_position.y + slot.size;
            try std.testing.expect(bottom <= grid_bottom);
        },
        else => {},
    };
}

test "buildSkillsPanel: drag source suppresses the icon, keeps the slot ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const learned = [_]SkillId{ .slice, .stab };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    var elements: UiElementList = .empty;
    var scroll_offset: i32 = 0;
    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = skills_panel_width,
        .height = middle_panel_height,
    };
    try buildSkillsPanel(
        &elements,
        arena.allocator(),
        metrics,
        bounds,
        &learned,
        theme,
        &scroll_offset,
        SlotRef{ .learned_skill = .slice }, // dragging the first skill
    );

    // The first slot keeps its ref (drop target) and renders the empty-slot
    // diamond ("in flight"); the second emits the skill_button frame + icon.
    var found_source_slot = false;
    var found_source_diamond = false;
    var image_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .slot => |slot| if (slot.ref != null and slot.ref.?.eql(.{ .learned_skill = .slice })) {
            found_source_slot = true;
            found_source_diamond = std.mem.eql(u8, slot.icon_sprite_id orelse "", "ui/skill_slot_empty");
        },
        .image => image_count += 1,
        else => {},
    };
    try std.testing.expect(found_source_slot);
    try std.testing.expect(found_source_diamond);
    // Only the second skill's icon emits; the drag source's is suppressed.
    try std.testing.expectEqual(@as(usize, 1), image_count);
}


fn testWeaponTypeDefinitions() [weapon_type_count]WeaponTypeDefinition {
    var defs: [weapon_type_count]WeaponTypeDefinition = undefined;
    for (&defs) |*d| d.* = .{ .skill_1 = .stab, .skill_2 = .chop, .skill_3 = .throw };
    return defs;
}

test "buildEntityInspectPanel: player entity emits skill + gear slots, read-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const player_color: types.Color = .{ .r = 10, .g = 20, .b = 30 };
    const enemy_color: types.Color = .{ .r = 90, .g = 80, .b = 70 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{enemy_color} ** 6 },
        .player_gradient = .{ .colors = .{player_color} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 0;
    entity.main_hand_weapon = .{ .weapon_type = .sword };
    entity.off_hand_weapon = .{ .weapon_type = .shield };
    entity.equipped_utility_skills = .{ .slice, .stab, null, null, null };
    entity.current_health = 30;
    entity.momentum = 4;

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // No .slot elements and no gameplay-clickable .button — everything is
    // read-only .image, except the panel-header close button (a .button
    // carrying the toggle_entity_inspect action).
    for (elements.items) |element| switch (element) {
        .slot => @panic("inspect panel emitted a draggable .slot"),
        .button => |btn| if (btn.action != .toggle_entity_inspect) {
            @panic("inspect panel emitted a clickable .button other than close");
        },
        else => {},
    };

    // The skill-bar frame images are tinted with the PLAYER gradient (team 0).
    const expected_frame = player_color; // index 3 → player_color (all 6 are same)
    var found_skill_frame = false;
    for (elements.items) |element| switch (element) {
        .image => |img| if (std.mem.eql(u8, img.sprite_id, "ui/skill_button")) {
            try std.testing.expectEqual(expected_frame, img.color);
            found_skill_frame = true;
        },
        else => {},
    };
    try std.testing.expect(found_skill_frame);

    // The stat column leads with live combat state in order: Current
    // Health, then Momentum (immediately below it), then Aggro Range,
    // before the gear-stat tail. Adjacency in emission order pins the
    // row's position, not just its presence.
    var stat_lines: [24][]const u8 = undefined;
    var stat_line_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .text_label => |label| {
            if (stat_line_count == stat_lines.len) @panic("stat-line overflow in test");
            stat_lines[stat_line_count] = label.text;
            stat_line_count += 1;
        },
        else => {},
    };
    var current_health_index: ?usize = null;
    for (stat_lines[0..stat_line_count], 0..) |line, index| {
        if (std.mem.startsWith(u8, line, "Current Health ")) current_health_index = index;
    }
    try std.testing.expect(current_health_index != null);
    try std.testing.expectEqualStrings("Momentum 4", stat_lines[current_health_index.? + 1]);
    try std.testing.expect(
        std.mem.startsWith(u8, stat_lines[current_health_index.? + 2], "Aggro Range "),
    );
}

test "buildEntityInspectPanel: enemy entity uses enemy gradient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const player_color: types.Color = .{ .r = 10, .g = 20, .b = 30 };
    const enemy_color: types.Color = .{ .r = 90, .g = 80, .b = 70 };
    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{enemy_color} ** 6 },
        .player_gradient = .{ .colors = .{player_color} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 1; // enemy
    entity.main_hand_weapon = .{ .weapon_type = .sword };
    entity.current_health = 7;
    entity.aggro_range = 5;

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // Skill-bar frame tinted with the ENEMY gradient (team ≠ 0).
    var found_enemy_frame = false;
    // The stat column LEADS with the entity's team, then its live combat
    // state.
    var found_team = false;
    var found_current_health = false;
    var found_momentum = false;
    var found_aggro_range = false;
    var stat_lines: usize = 0;
    var first_stat_lines: [4][]const u8 = undefined;
    for (elements.items) |element| switch (element) {
        .image => |img| if (std.mem.eql(u8, img.sprite_id, "ui/skill_button")) {
            try std.testing.expectEqual(enemy_color, img.color);
            found_enemy_frame = true;
        },
        .text_label => |label| {
            // Stat lines live in the column flush against the gear stack
            // (x = 16 + 128); the panel title shares the font size, so gate
            // on position, not just text.
            if (label.screen_position.x == ui_gap + inventory_slot_size and label.font_size == gear_stat_font_size) {
                if (stat_lines < 4) first_stat_lines[stat_lines] = label.text;
                stat_lines += 1;
                if (std.mem.eql(u8, label.text, "Team 1")) found_team = true;
                if (std.mem.eql(u8, label.text, "Current Health 7")) found_current_health = true;
                if (std.mem.eql(u8, label.text, "Momentum 0")) found_momentum = true;
                if (std.mem.eql(u8, label.text, "Aggro Range 5")) found_aggro_range = true;
            }
        },
        else => {},
    };
    try std.testing.expect(found_enemy_frame);
    try std.testing.expect(found_team);
    try std.testing.expect(found_current_health);
    try std.testing.expect(found_momentum);
    try std.testing.expect(found_aggro_range);
    // The team row + the three live-state rows lead the column (before
    // the gear stats).
    try std.testing.expect(stat_lines == 11);
    try std.testing.expectEqualStrings("Team 1", first_stat_lines[0]);
    try std.testing.expectEqualStrings("Current Health 7", first_stat_lines[1]);
    try std.testing.expectEqualStrings("Momentum 0", first_stat_lines[2]);
    try std.testing.expectEqualStrings("Aggro Range 5", first_stat_lines[3]);
}

test "buildEntityInspectPanel: cooldown overlay + number when skill on cooldown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 0;
    entity.main_hand_weapon = .{ .weapon_type = .sword };
    // Slot 1 = stab (sword skill_1); put it on cooldown.
    entity.skill_cooldowns.set(.stab, 3);

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // A cooldown overlay is a translucent (alpha 128) skill_button image on
    // top of the filled slot. Count them — exactly one skill is on cooldown.
    var overlay_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .image => |img| if (std.mem.eql(u8, img.sprite_id, "ui/skill_button") and img.alpha == 128) {
            overlay_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), overlay_count);
}

test "buildEntityInspectPanel: active effects emit 128px icons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };
    const theme: types.ActiveColorTheme = .{
        .lightest = black,
        .darkest = black,
        .world_gradient = .{ .colors = .{black} ** 6 },
        .enemy_gradient = .{ .colors = .{black} ** 6 },
        .player_gradient = .{ .colors = .{black} ** 6 },
    };
    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const weapon_types = testWeaponTypeDefinitions();

    var entity: Entity = .{};
    entity.team = 1;
    // Allocate active_effects in the arena (Entity.active_effects is a slice).
    const effects = try arena.allocator().alloc(types.Effect, 2);
    effects[0] = .{ .effect_id = .reflect, .duration = 2 };
    effects[1] = .{ .effect_id = .stone_form, .duration = 4 };
    entity.active_effects = effects;

    const bounds = Rectangle{
        .x = 0,
        .y = 0,
        .width = entity_inspect_panel_width,
        .height = middle_panel_height,
    };
    var elements: UiElementList = .empty;
    try buildEntityInspectPanel(&elements, arena.allocator(), metrics, bounds, entity, &.{}, null, theme, &weapon_types);

    // Two effect icons at 128px, carrying tooltips.
    var effect_icon_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .image => |img| if (img.width == small_icon_size and img.height == small_icon_size and img.tooltip != null) {
            // Effect icons use the effect definition name as the sprite id.
            // Effect icons use the SKILL icon (`skills/<tag>`) when the
            // effect shares a tag with a skill (reflect/stone_form do).
            if (std.mem.eql(u8, img.sprite_id, "skills/reflect") or std.mem.eql(u8, img.sprite_id, "skills/stone_form")) {
                effect_icon_count += 1;
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), effect_icon_count);
}
